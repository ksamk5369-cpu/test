--[[
    Server-controlled print jobs.

    Lifecycle: queued -> printing -> (completed | failed | cancelled)

    * Paper and ink are reserved from the printer when a job starts and given back on failure.
    * Money is charged and items are granted only at completion, after the print count was
      atomically reserved. Any failure rolls every step back.
    * The client never decides that a job finished: progress and completion come from here.
]]

el_Printing = {}

local el_Jobs = {}          -- jobId -> job
local el_JobCounter = 0

local function el_NextJobId()
    el_JobCounter = el_JobCounter + 1
    return ('J%d%04d'):format(el_JobCounter, math.random(0, 9999))
end

local function el_IsOnline(src)
    return GetPlayerName(src) ~= nil
end

local function el_JobCountForPlayer(src)
    local count = 0
    for _, job in pairs(el_Jobs) do
        if job.src == src then count = count + 1 end
    end
    return count
end

local function el_NotifyJob(job, key)
    if el_IsOnline(job.src) then
        el_Bridge.Server.Notify(job.src, el_Text(key), el_TextType(key))
    end
end

local function el_SendJobEvent(job, state, extra)
    if not el_IsOnline(job.src) then return end
    local payload = extra or {}
    payload.jobId = job.id
    payload.printerId = job.printerId
    payload.state = state
    payload.duration = job.duration
    payload.title = job.title
    TriggerClientEvent('el_printer:client:jobEvent', job.src, payload)
end

function el_Printing.GetJob(jobId)
    if type(jobId) ~= 'string' then return nil end
    return el_Jobs[jobId]
end

function el_Printing.CalculateDuration(template, printer, copies)
    local base = tonumber(template.duration) or Config.Printing.BaseDuration
    local total = base + (copies - 1) * Config.Printing.PerCopyDuration
    return math.max(1000, math.floor(total * (printer.durationMultiplier or 1.0)))
end

local function el_Requirements(template, printer, copies)
    local needPaper = (printer.usePaper and Config.Supplies.Paper.Enabled) and (template.paper or 0) * copies or 0
    local needInk = (printer.useInk and Config.Supplies.Ink.Enabled) and (template.ink or 0) * copies or 0
    local cost = (tonumber(template.cost) or 0) * copies
    local account = template.account or Config.Printing.Account
    return needPaper, needInk, cost, account
end

-- Checks everything that can change between queueing and starting.
local function el_CheckPrintable(job, printer, doc, template)
    local blocking = el_PrinterMgr.BlockingError(printer)
    if blocking then return blocking end

    if not el_IsOnline(job.src) then return 'unable_to_print' end
    local identity = el_Bridge.Server.GetIdentity(job.src)
    if not identity or identity.citizenid ~= job.cid then return 'unable_to_print' end
    if not el_Perm.CanAccessPrinter(identity, printer) then return 'access_denied' end
    if not el_Perm.PrinterAllowsType(printer, doc.doc_type) then return 'document_type_unavailable' end
    if not el_Perm.CanPrintDocument(identity, doc) then return 'access_denied' end

    local status = el_Docs.EffectiveStatus(doc)
    if status == 'revoked' then return 'document_is_revoked' end
    if status == 'expired' then return 'document_expired' end
    if template.maxPrints and doc.print_count + job.copies > template.maxPrints then
        return 'print_limit_reached'
    end

    local needPaper, needInk, cost, account = el_Requirements(template, printer, job.copies)
    if needPaper > printer.paper then return 'not_enough_paper' end
    if needInk > printer.ink then return 'not_enough_ink' end
    if cost > 0 and el_Bridge.Server.GetMoney(job.src, account) < cost then return 'not_enough_money' end

    local metadataProbe = { el_document_id = doc.id, el_copy = 0 }
    if not el_Bridge.ServerInventory.CanCarry(job.src, Config.Items.Document, job.copies, metadataProbe) then
        return 'inventory_full'
    end
    return nil, needPaper, needInk, cost, account
end

---------------------------------------------------------------------------------------------------
-- Ending a job
---------------------------------------------------------------------------------------------------

local function el_ReleasePrinter(printer, job)
    if printer.active == job then
        printer.active = nil
    end
    el_Jobs[job.id] = nil
end

-- Gives reserved supplies back and ends the job without granting anything.
local function el_EndFailed(job, reason)
    if job.finished then return end
    job.finished = true
    local printer = el_Printers[job.printerId]

    if printer then
        printer.paper = printer.paper + (job.reservedPaper or 0)
        printer.ink = printer.ink + (job.reservedInk or 0)
        job.reservedPaper, job.reservedInk = 0, 0
        el_ReleasePrinter(printer, job)
        el_PrinterMgr.SaveState(printer)
    else
        el_Jobs[job.id] = nil
    end

    el_Debug('Job', job.id, 'ended:', reason)
    el_NotifyJob(job, reason)
    el_SendJobEvent(job, reason == 'printing_cancelled' and 'cancelled' or 'failed', { reason = reason, message = el_Text(reason) })

    if printer then
        el_PrinterMgr.Broadcast(printer)
        el_Printing.StartNext(printer)
    end
end

el_Printing.Fail = el_EndFailed

local function el_Complete(job)
    if job.finished then return end
    local printer = el_Printers[job.printerId]
    if not printer then return el_EndFailed(job, 'unable_to_print') end

    -- Always work on the freshest record.
    local doc, docError = el_Docs.Get(job.docId)
    if job.finished then return end
    if not doc then return el_EndFailed(job, docError == 'database_error' and 'database_error' or 'document_not_found') end
    local template = Config.DocumentTypes[doc.doc_type]
    if not template then return el_EndFailed(job, 'unable_to_print') end

    if not el_IsOnline(job.src) then return el_EndFailed(job, 'unable_to_print') end
    local identity = el_Bridge.Server.GetIdentity(job.src)
    if not identity or identity.citizenid ~= job.cid or not el_Perm.CanPrintDocument(identity, doc) then
        return el_EndFailed(job, 'access_denied')
    end
    if el_Docs.EffectiveStatus(doc) ~= 'active' then return el_EndFailed(job, 'document_is_revoked') end
    if template.maxPrints and doc.print_count + job.copies > template.maxPrints then
        return el_EndFailed(job, 'print_limit_reached')
    end

    local firstCopy = doc.print_count + 1

    -- 1. Reserve print count atomically (prevents concurrent reprint abuse).
    if not el_Docs.AddPrints(doc, job.copies) then
        return el_EndFailed(job, 'unable_to_print')
    end
    -- The job may have been aborted (disconnect / resource stop) while the database answered.
    if job.finished then
        el_Docs.RemovePrints(doc, job.copies)
        return
    end

    -- 2. Charge money.
    if job.cost > 0 and not el_Bridge.Server.RemoveMoney(job.src, job.account, job.cost, 'el-printer-print') then
        el_Docs.RemovePrints(doc, job.copies)
        return el_EndFailed(job, 'not_enough_money')
    end

    -- 3. Grant one document item per copy.
    local granted = {}
    for i = 0, job.copies - 1 do
        local copy = firstCopy + i
        local metadata = el_Docs.ItemMetadata(doc, copy)
        if el_Bridge.ServerInventory.AddItem(job.src, Config.Items.Document, 1, metadata) then
            granted[#granted + 1] = copy
        else
            for _, grantedCopy in ipairs(granted) do
                el_Bridge.ServerInventory.RemoveDocumentItem(job.src, Config.Items.Document, doc.id, grantedCopy)
            end
            if job.cost > 0 then
                el_Bridge.Server.AddMoney(job.src, job.account, job.cost, 'el-printer-refund')
            end
            el_Docs.RemovePrints(doc, job.copies)
            return el_EndFailed(job, 'inventory_full')
        end
    end

    -- 4. Commit: reserved supplies are consumed, durability wears.
    job.finished = true
    job.reservedPaper, job.reservedInk = 0, 0
    if Config.Maintenance.Durability.Enabled then
        printer.durability = math.max(0, printer.durability - Config.Maintenance.Durability.PerCopy * job.copies)
    end
    el_ReleasePrinter(printer, job)
    el_PrinterMgr.SaveState(printer)

    el_NotifyJob(job, 'printing_completed')
    el_SendJobEvent(job, 'completed', {
        message = el_Text('printing_completed'),
        documentId = doc.id,
        copies = job.copies,
    })
    el_PrinterMgr.Broadcast(printer)
    el_Printing.StartNext(printer)
end

---------------------------------------------------------------------------------------------------
-- Running a job
---------------------------------------------------------------------------------------------------

local function el_RunJob(job)
    CreateThread(function()
        local printer = el_Printers[job.printerId]
        local interval = math.max(250, Config.Printing.ProgressInterval)
        local deadline = job.startedAt + job.duration + Config.Printing.TimeoutGrace

        while not job.finished do
            Wait(math.min(interval, math.max(50, job.startedAt + job.duration - GetGameTimer())))
            if job.finished then return end

            local now = GetGameTimer()
            if el_Printers[job.printerId] ~= printer then return el_EndFailed(job, 'unable_to_print') end
            if job.cancelled then return el_EndFailed(job, 'printing_cancelled') end
            if not el_IsOnline(job.src) then return el_EndFailed(job, 'unable_to_print') end
            if Config.Printing.RequirePresence
                and not el_PrinterMgr.IsNear(job.src, printer, Config.Printing.PresenceDistanceMultiplier) then
                return el_EndFailed(job, 'left_printer')
            end
            if now > deadline then return el_EndFailed(job, 'unable_to_print') end

            local elapsed = now - job.startedAt
            if elapsed >= job.duration then
                local ok, err = pcall(el_Complete, job)
                if not ok then
                    el_Warn('Print completion error: ' .. tostring(err))
                    el_EndFailed(job, 'unable_to_print')
                end
                return
            end

            el_SendJobEvent(job, 'progress', {
                progress = el_Clamp(math.floor(elapsed / job.duration * 100), 0, 99),
                remaining = job.duration - elapsed,
            })
        end
    end)
end

-- Starts the next queued job when the printer is idle.
function el_Printing.StartNext(printer)
    if printer.active or el_PrinterMgr.BlockingError(printer) then return end

    while #printer.queue > 0 do
        local job = table.remove(printer.queue, 1)
        if not job.cancelled and not job.finished then
            local doc, docError = el_Docs.Get(job.docId)
            local template = doc and Config.DocumentTypes[doc.doc_type]
            local errorCode, needPaper, needInk, cost, account
            if not doc then
                errorCode = docError or 'document_not_found'
            elseif not template then
                errorCode = 'unable_to_print'
            else
                errorCode, needPaper, needInk, cost, account = el_CheckPrintable(job, printer, doc, template)
            end
            if not errorCode and Config.Printing.RequirePresence and not el_PrinterMgr.IsNear(job.src, printer, Config.Printing.PresenceDistanceMultiplier) then
                errorCode = 'left_printer'
            end

            -- The printer may have become busy while the document was loaded.
            if printer.active then
                table.insert(printer.queue, 1, job)
                return
            end

            if errorCode then
                job.finished = true
                el_Jobs[job.id] = nil
                el_NotifyJob(job, errorCode)
                el_SendJobEvent(job, 'failed', { reason = errorCode, message = el_Text(errorCode) })
            else
                -- Reserve supplies synchronously, before anything can yield.
                printer.paper = printer.paper - needPaper
                printer.ink = printer.ink - needInk
                job.reservedPaper, job.reservedInk = needPaper, needInk
                job.cost, job.account = cost, account
                job.state = 'printing'
                job.startedAt = GetGameTimer()
                printer.active = job

                el_NotifyJob(job, 'printing_started')
                el_SendJobEvent(job, 'started', { progress = 0, remaining = job.duration })
                el_PrinterMgr.Broadcast(printer)
                el_RunJob(job)
                return
            end
        end
    end
    el_PrinterMgr.Broadcast(printer)
end

-- Validates and queues a print request. Returns job or nil, errorCode.
function el_Printing.Request(src, identity, printer, doc, copies)
    local template = Config.DocumentTypes[doc.doc_type]
    if not template then return nil, 'document_not_found' end

    if el_JobCountForPlayer(src) >= math.max(1, Config.Printing.Queue.MaxPerPlayer) then
        return nil, 'too_many_jobs'
    end

    local busy = printer.active ~= nil or #printer.queue > 0
    if busy then
        if not Config.Printing.Queue.Enabled then return nil, 'printer_busy' end
        if #printer.queue >= Config.Printing.Queue.MaxSize then return nil, 'queue_full' end
    end

    local job = {
        id = el_NextJobId(),
        src = src,
        cid = identity.citizenid,
        printerId = printer.id,
        docId = doc.id,
        title = doc.title,
        typeLabel = template.label,
        copies = copies,
        duration = el_Printing.CalculateDuration(template, printer, copies),
        state = 'queued',
        reservedPaper = 0,
        reservedInk = 0,
        cost = 0,
        account = Config.Printing.Account,
    }

    -- Validate immediately so the player gets instant feedback (re-checked at start).
    local errorCode = el_CheckPrintable(job, printer, doc, template)
    if errorCode then
        -- Supplies may legitimately be refilled before a queued job starts; only block idle printers.
        local supplyError = errorCode == 'not_enough_paper' or errorCode == 'not_enough_ink'
        if not busy or not supplyError then return nil, errorCode end
    end

    el_Jobs[job.id] = job
    printer.queue[#printer.queue + 1] = job

    if busy then
        el_SendJobEvent(job, 'queued', { position = #printer.queue })
        el_PrinterMgr.Broadcast(printer)
        return job, 'printing_queued'
    end

    el_Printing.StartNext(printer)
    return job, 'printing_started'
end

function el_Printing.Cancel(src, jobId)
    local job = el_Printing.GetJob(jobId)
    if not job or job.src ~= src or job.finished then return false, 'job_not_found' end

    if job.state == 'queued' then
        local printer = el_Printers[job.printerId]
        if printer then
            for i = #printer.queue, 1, -1 do
                if printer.queue[i] == job then table.remove(printer.queue, i) end
            end
        end
        job.finished = true
        el_Jobs[job.id] = nil
        el_SendJobEvent(job, 'cancelled', { reason = 'printing_cancelled', message = el_Text('printing_cancelled') })
        if printer then el_PrinterMgr.Broadcast(printer) end
        return true, 'printing_cancelled'
    end

    -- Active job: the job thread performs the cancellation and rollback on its next tick.
    job.cancelled = true
    return true, nil
end

-- Fails every queued job of a printer (maintenance mode, removal).
function el_Printing.FailQueued(printer, reason)
    local queue = printer.queue
    printer.queue = {}
    for _, job in ipairs(queue) do
        if not job.finished then
            job.finished = true
            el_Jobs[job.id] = nil
            el_NotifyJob(job, reason)
            el_SendJobEvent(job, 'failed', { reason = reason, message = el_Text(reason) })
        end
    end
end

-- Cancels everything that belongs to a printer (removal / resource stop).
function el_Printing.AbortPrinter(printer, reason)
    el_Printing.FailQueued(printer, reason)
    if printer.active then
        el_EndFailed(printer.active, reason)
    end
end

-- Player left: drop queued jobs and roll back the active one.
function el_Printing.PlayerLeft(src)
    for _, job in pairs(el_Jobs) do
        if job.src == src and not job.finished then
            if job.state == 'queued' then
                local printer = el_Printers[job.printerId]
                if printer then
                    for i = #printer.queue, 1, -1 do
                        if printer.queue[i] == job then table.remove(printer.queue, i) end
                    end
                    el_PrinterMgr.Broadcast(printer)
                end
                job.finished = true
                el_Jobs[job.id] = nil
            else
                el_EndFailed(job, 'unable_to_print')
            end
        end
    end
end

-- Resource stop: give back every reserved supply and persist the printers.
function el_Printing.Shutdown()
    for _, printer in pairs(el_Printers) do
        local job = printer.active
        if job and not job.finished then
            job.finished = true
            printer.paper = printer.paper + (job.reservedPaper or 0)
            printer.ink = printer.ink + (job.reservedInk or 0)
            job.reservedPaper, job.reservedInk = 0, 0
            printer.active = nil
        end
        printer.queue = {}
        el_PrinterMgr.SaveState(printer)
    end
    el_Jobs = {}
end
