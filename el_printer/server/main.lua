--[[
    Server entry point: request dispatcher, rate limiting, action handlers, usable items
    and lifecycle management.

    Every client request goes through 'el_printer:server:request' and is answered with
    'el_printer:client:response'. Handlers read identity, job, inventory and position from the
    server; client payloads are treated as untrusted input.
]]

local el_Ready = false
local el_RateState = {}     -- src -> { windowStart, count, last = { action = time } }
local el_Placing = {}       -- src -> expiry (GetGameTimer)
local el_LastViewed = {}    -- src -> { id, copy }
local el_Handlers = {}

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

local function el_Fail(code, extra)
    local response = { ok = false, error = code, message = el_Text(code) }
    if extra then
        for k, v in pairs(extra) do response[k] = v end
    end
    return response
end

local function el_Ok(data, messageKey)
    local response = { ok = true, data = data }
    if messageKey then
        response.messageKey = messageKey
        response.message = el_Text(messageKey)
        response.messageType = el_TextType(messageKey)
    end
    return response
end

local function el_RateLimit(src, action)
    local now = GetGameTimer()
    local state = el_RateState[src]
    if not state then
        state = { windowStart = now, count = 0, last = {} }
        el_RateState[src] = state
    end

    if now - state.windowStart > Config.Security.RateLimit.Window then
        state.windowStart = now
        state.count = 0
    end
    state.count = state.count + 1
    if state.count > Config.Security.RateLimit.MaxRequests then
        return false
    end

    local cooldown = Config.Security.Cooldowns[action]
    if cooldown then
        local last = state.last[action]
        if last and now - last < cooldown then return false end
        state.last[action] = now
    end
    return true
end

local function el_IsString(value, maxLength)
    return type(value) == 'string' and #value > 0 and #value <= (maxLength or 64)
end

-- Resolves a printer the player is allowed to use and is standing next to.
local function el_RequirePrinter(src, identity, printerId, skipEnabledCheck)
    if not el_IsString(printerId, 48) then return nil, 'invalid_request' end
    local printer = el_PrinterMgr.Get(printerId)
    if not printer then return nil, 'printer_not_found' end
    if not skipEnabledCheck and not printer.enabled then return nil, 'printer_offline' end
    if not el_Perm.CanAccessPrinter(identity, printer) then return nil, 'access_denied' end
    if not el_PrinterMgr.IsNear(src, printer) then return nil, 'too_far' end
    return printer
end

local function el_FormatCost(amount)
    if not amount or amount <= 0 then return 'Free' end
    return el_Docs.FormatMoney(amount)
end

local function el_TemplateList(identity, printer)
    local list = {}
    local seen = {}
    local order = {}
    for _, key in ipairs(Config.DocumentOrder or {}) do order[#order + 1] = key end
    for key in pairs(Config.DocumentTypes) do
        if not el_TableContains(order, key) then order[#order + 1] = key end
    end

    for _, key in ipairs(order) do
        local template = Config.DocumentTypes[key]
        if template and not seen[key] and el_Perm.PrinterAllowsType(printer, key)
            and el_Perm.HasDocument(identity, key, 'create') then
            seen[key] = true
            local fields = {}
            for i, field in ipairs(template.fields) do
                fields[i] = {
                    name = field.name,
                    label = field.label,
                    type = field.type or 'text',
                    required = field.required == true,
                    min = field.min,
                    max = field.max,
                    options = field.options,
                    placeholder = field.placeholder,
                    money = field.format == 'money',
                }
            end
            local paper = (printer.usePaper and Config.Supplies.Paper.Enabled) and (template.paper or 0) or 0
            local ink = (printer.useInk and Config.Supplies.Ink.Enabled) and (template.ink or 0) or 0
            list[#list + 1] = {
                key = key,
                label = template.label,
                description = template.description or '',
                icon = template.icon or 'fa-file',
                category = template.category or 'General',
                official = template.official == true,
                layout = template.layout or 'letter',
                cost = tonumber(template.cost) or 0,
                costLabel = el_FormatCost(tonumber(template.cost) or 0),
                paper = paper,
                ink = ink,
                maxPrints = template.maxPrints,
                expiresDays = template.expiresDays,
                fields = fields,
            }
        end
    end
    return list
end

local function el_DocSummary(identity, printer, doc)
    local template = Config.DocumentTypes[doc.doc_type]
    if not template then return nil end
    local status = el_Docs.EffectiveStatus(doc)
    local relation = 'Department record'
    if doc.issuer_cid == identity.citizenid and doc.owner_cid == identity.citizenid then
        relation = 'Your document'
    elseif doc.issuer_cid == identity.citizenid then
        relation = 'Issued by you'
    elseif doc.owner_cid == identity.citizenid then
        relation = 'Issued to you'
    end

    local limitReached = template.maxPrints ~= nil and doc.print_count >= template.maxPrints
    local canPrint = status == 'active' and not limitReached
        and el_Perm.PrinterAllowsType(printer, doc.doc_type)
        and el_Perm.CanPrintDocument(identity, doc)

    return {
        id = doc.id,
        type = doc.doc_type,
        typeLabel = template.label,
        icon = template.icon or 'fa-file',
        title = doc.title,
        status = status,
        issuerName = doc.issuer_name,
        relation = relation,
        createdAt = os.date('%d %b %Y', doc.created_at),
        createdTs = doc.created_at,
        printCount = doc.print_count,
        maxPrints = template.maxPrints,
        canPrint = canPrint,
        printLabel = doc.print_count == 0 and 'Print' or 'Reprint',
        canRevoke = status == 'active' and el_Perm.CanRevokeDocument(identity, doc),
        printerAllows = el_Perm.PrinterAllowsType(printer, doc.doc_type),
    }
end

local function el_DocumentList(identity, printer)
    local docs, err = el_Docs.ListFor(identity)
    if not docs then return nil, err end
    local list = {}
    for _, doc in ipairs(docs) do
        local summary = el_DocSummary(identity, printer, doc)
        if summary then list[#list + 1] = summary end
    end
    return list
end

local function el_Dashboard(src, identity, printer)
    local documents, docError = el_DocumentList(identity, printer)
    local canMaintain = el_Perm.CanMaintain(identity, printer)
    return {
        printer = el_PrinterMgr.PublicState(printer, src),
        storage = el_Docs.StorageMode(),
        documentsError = documents == nil and el_Text(docError or 'database_error') or nil,
        documents = documents or {},
        templates = el_TemplateList(identity, printer),
        player = {
            name = identity.name,
            job = identity.job.label,
            grade = identity.job.gradeLabel,
        },
        permissions = {
            refill = el_Perm.HasPrinter(identity, 'refill'),
            maintenance = canMaintain and Config.Maintenance.MaintenanceMode,
            repair = canMaintain and Config.Maintenance.Repair.Enabled and Config.Maintenance.Durability.Enabled,
            remove = el_Perm.CanRemovePrinter(identity, printer),
        },
        supplies = {
            paperItems = el_Bridge.ServerInventory.GetItemCount(src, Config.Items.Paper),
            inkItems = el_Bridge.ServerInventory.GetItemCount(src, Config.Items.Ink),
            paperPerItem = Config.Supplies.Paper.PerItem,
            inkPerItem = Config.Supplies.Ink.PerItem,
        },
        settings = {
            maxCopies = Config.Printing.MaxCopies,
            repairCost = el_FormatCost(tonumber(Config.Maintenance.Repair.Cost) or 0),
            repairDuration = Config.Maintenance.Repair.Duration,
            sounds = Config.Sounds.Enabled and Config.Sounds.Printing,
            volume = Config.Sounds.Volume,
        },
    }
end

local function el_DocumentDetail(identity, printer, doc)
    return {
        summary = el_DocSummary(identity, printer, doc),
        model = el_Docs.BuildModel(doc),
    }
end

---------------------------------------------------------------------------------------------------
-- Handlers: function(src, identity, payload) -> response
---------------------------------------------------------------------------------------------------

el_Handlers.openPrinter = function(src, identity, payload)
    local printer, err = el_RequirePrinter(src, identity, payload.printerId)
    if not printer then return el_Fail(err) end
    el_PrinterMgr.RemoveViewer(src)
    el_PrinterMgr.AddViewer(printer, src)
    return el_Ok(el_Dashboard(src, identity, printer))
end

el_Handlers.getDashboard = function(src, identity, payload)
    local printer, err = el_RequirePrinter(src, identity, payload.printerId)
    if not printer then return el_Fail(err) end
    el_PrinterMgr.AddViewer(printer, src)
    return el_Ok(el_Dashboard(src, identity, printer))
end

el_Handlers.closePrinter = function(src)
    el_PrinterMgr.RemoveViewer(src)
    return el_Ok(true)
end

el_Handlers.getDocument = function(src, identity, payload)
    local printer, err = el_RequirePrinter(src, identity, payload.printerId)
    if not printer then return el_Fail(err) end
    local doc, docError = el_Docs.Get(payload.documentId)
    if not doc then return el_Fail(docError) end
    -- Same answer for "missing" and "not yours" so IDs cannot be probed.
    if not el_Perm.CanViewDocument(identity, doc) then return el_Fail('document_not_found') end
    return el_Ok(el_DocumentDetail(identity, printer, doc))
end

local function el_PrepareDocument(src, identity, payload)
    local printer, err = el_RequirePrinter(src, identity, payload.printerId)
    if not printer then return nil, el_Fail(err) end
    if not el_IsString(payload.docType, 40) then return nil, el_Fail('invalid_request') end
    local template = Config.DocumentTypes[payload.docType]
    if not template then return nil, el_Fail('invalid_request') end
    if not el_Perm.PrinterAllowsType(printer, payload.docType) then return nil, el_Fail('document_type_unavailable') end
    if not el_Perm.HasDocument(identity, payload.docType, 'create') then return nil, el_Fail('access_denied') end

    local values, citizensOrErrors = el_Docs.Validate(template, payload.fields)
    if not values then
        return nil, el_Fail('invalid_input', { fieldErrors = citizensOrErrors })
    end
    local record = el_Docs.BuildRecord(payload.docType, template, identity, values, citizensOrErrors, printer.id)
    return { printer = printer, record = record }
end

el_Handlers.previewDocument = function(src, identity, payload)
    local prepared, failure = el_PrepareDocument(src, identity, payload)
    if not prepared then return failure end
    return el_Ok({ model = el_Docs.BuildModel(prepared.record) })
end

el_Handlers.createDocument = function(src, identity, payload)
    local prepared, failure = el_PrepareDocument(src, identity, payload)
    if not prepared then return failure end
    local doc, err = el_Docs.Create(prepared.record)
    if not doc then return el_Fail(err or 'database_error') end
    el_Debug('Document created', doc.id, doc.doc_type, 'by', identity.citizenid)
    return el_Ok(el_DocumentDetail(identity, prepared.printer, doc), 'document_saved')
end

el_Handlers.print = function(src, identity, payload)
    local printer, err = el_RequirePrinter(src, identity, payload.printerId)
    if not printer then return el_Fail(err) end

    local copies = math.tointeger(tonumber(payload.copies) or 1)
    if not copies or copies < 1 or copies > Config.Printing.MaxCopies then return el_Fail('invalid_request') end

    local doc, docError = el_Docs.Get(payload.documentId)
    if not doc then return el_Fail(docError) end
    if not el_Perm.CanViewDocument(identity, doc) then return el_Fail('document_not_found') end

    local job, code = el_Printing.Request(src, identity, printer, doc, copies)
    if not job then return el_Fail(code) end
    return el_Ok({ jobId = job.id, state = job.state }, code)
end

el_Handlers.cancelJob = function(src, _, payload)
    if not el_IsString(payload.jobId, 24) then return el_Fail('invalid_request') end
    local ok, code = el_Printing.Cancel(src, payload.jobId)
    if not ok then return el_Fail(code) end
    return el_Ok(true, code)
end

el_Handlers.refill = function(src, identity, payload)
    local printer, err = el_RequirePrinter(src, identity, payload.printerId)
    if not printer then return el_Fail(err) end
    if payload.kind ~= 'paper' and payload.kind ~= 'ink' then return el_Fail('invalid_request') end
    if not el_Perm.HasPrinter(identity, 'refill') then return el_Fail('access_denied') end

    local ok, code = el_PrinterMgr.Refill(src, printer, payload.kind)
    if not ok then return el_Fail(code) end
    el_Printing.StartNext(printer)
    return el_Ok({
        paperItems = el_Bridge.ServerInventory.GetItemCount(src, Config.Items.Paper),
        inkItems = el_Bridge.ServerInventory.GetItemCount(src, Config.Items.Ink),
    }, code)
end

el_Handlers.setMaintenance = function(src, identity, payload)
    local printer, err = el_RequirePrinter(src, identity, payload.printerId, true)
    if not printer then return el_Fail(err) end
    if not el_Perm.CanMaintain(identity, printer) then return el_Fail('access_denied') end
    if type(payload.enabled) ~= 'boolean' then return el_Fail('invalid_request') end
    local ok, code = el_PrinterMgr.SetMaintenance(printer, payload.enabled)
    if not ok then return el_Fail(code) end
    return el_Ok(true, code)
end

el_Handlers.repair = function(src, identity, payload)
    local printer, err = el_RequirePrinter(src, identity, payload.printerId, true)
    if not printer then return el_Fail(err) end
    if not el_Perm.CanMaintain(identity, printer) then return el_Fail('access_denied') end
    local ok, code = el_PrinterMgr.Repair(src, printer)
    if not ok then return el_Fail(code) end
    return el_Ok(true, code)
end

el_Handlers.revokeDocument = function(src, identity, payload)
    local printer, err = el_RequirePrinter(src, identity, payload.printerId)
    if not printer then return el_Fail(err) end
    local doc, docError = el_Docs.Get(payload.documentId)
    if not doc then return el_Fail(docError) end
    if not el_Perm.CanViewDocument(identity, doc) then return el_Fail('document_not_found') end
    if not el_Perm.CanRevokeDocument(identity, doc) then return el_Fail('access_denied') end
    if doc.status == 'revoked' then return el_Fail('document_is_revoked') end
    local ok, code = el_Docs.Revoke(doc)
    if not ok then return el_Fail(code) end
    el_Debug('Document revoked', doc.id, 'by', identity.citizenid)
    return el_Ok(el_DocumentDetail(identity, printer, doc), 'document_revoked')
end

el_Handlers.placePrinter = function(src, identity, payload)
    local expiry = el_Placing[src]
    if not expiry or GetGameTimer() > expiry then
        el_Placing[src] = nil
        return el_Fail('placement_invalid')
    end

    local ok, point, heading = el_PrinterMgr.ValidatePlacement(src, identity, payload.coords, payload.heading)
    if not ok then return el_Fail(point) end

    el_Placing[src] = nil
    if not el_Bridge.ServerInventory.RemoveItem(src, Config.Items.Printer, 1) then
        return el_Fail('missing_printer_item')
    end

    local printer, err = el_PrinterMgr.CreatePlaced(identity, point, heading)
    if not printer then
        el_Bridge.ServerInventory.AddItem(src, Config.Items.Printer, 1)
        return el_Fail(err or 'database_error')
    end

    el_PrinterMgr.SyncPlaced(-1)
    el_Debug('Printer placed', printer.id, 'by', identity.citizenid)
    return el_Ok({ printerId = printer.id }, 'printer_placed')
end

el_Handlers.cancelPlacement = function(src)
    el_Placing[src] = nil
    return el_Ok(true)
end

el_Handlers.removePrinter = function(src, identity, payload)
    if not el_IsString(payload.printerId, 48) then return el_Fail('invalid_request') end
    local printer = el_PrinterMgr.Get(payload.printerId)
    if not printer or printer.kind ~= 'placed' then return el_Fail('printer_not_found') end
    if not el_Perm.CanRemovePrinter(identity, printer) then return el_Fail('access_denied') end
    if not el_PrinterMgr.IsNear(src, printer) then return el_Fail('too_far') end

    local giveItem = Config.Placement.ReturnItemOnRemove
    if giveItem and not el_Bridge.ServerInventory.CanCarry(src, Config.Items.Printer, 1) then
        return el_Fail('inventory_full')
    end

    local viewers = printer.viewers
    el_Printing.AbortPrinter(printer, 'printer_offline')
    local ok, err = el_PrinterMgr.DeletePlaced(printer)
    if not ok then return el_Fail(err) end

    if giveItem then
        el_Bridge.ServerInventory.AddItem(src, Config.Items.Printer, 1)
    end
    for viewer in pairs(viewers) do
        TriggerClientEvent('el_printer:client:printerRemoved', viewer, printer.id)
    end
    el_PrinterMgr.SyncPlaced(-1)
    return el_Ok(true, 'printer_removed')
end

el_Handlers.showDocument = function(src)
    local last = el_LastViewed[src]
    if not last then return el_Fail('document_not_found') end
    local metadata = el_Bridge.ServerInventory.FindDocumentItem(src, Config.Items.Document, last.id, last.copy)
    if not metadata then return el_Fail('document_not_found') end

    local coords = el_GetPlayerCoords(src)
    if not coords then return el_Fail('no_player_nearby') end
    local bucket = GetPlayerRoutingBucket(src)
    local closest, closestDistance = nil, 3.0
    for _, playerId in ipairs(GetPlayers()) do
        local target = tonumber(playerId)
        if target and target ~= src and GetPlayerRoutingBucket(target) == bucket then
            local targetCoords = el_GetPlayerCoords(target)
            if targetCoords then
                local distance = #(coords - targetCoords)
                if distance < closestDistance then
                    closest, closestDistance = target, distance
                end
            end
        end
    end
    if not closest then return el_Fail('no_player_nearby') end

    local view = el_BuildItemView(metadata)
    if not view then return el_Fail('document_not_found') end
    view.canShow = false
    view.shown = true
    TriggerClientEvent('el_printer:client:viewDocument', closest, view)
    return el_Ok(true, 'document_shown')
end

---------------------------------------------------------------------------------------------------
-- Dispatcher
---------------------------------------------------------------------------------------------------

RegisterNetEvent('el_printer:server:request', function(requestId, action, payload)
    local src = source
    if type(requestId) ~= 'number' or type(action) ~= 'string' then return end

    local function respond(response)
        TriggerClientEvent('el_printer:client:response', src, requestId, response)
    end

    local handler = el_Handlers[action]
    if not handler then return respond(el_Fail('invalid_request')) end
    if not el_Ready then return respond(el_Fail('internal_error')) end
    if not el_RateLimit(src, action) then return respond(el_Fail('rate_limited')) end
    if type(payload) ~= 'table' then payload = {} end

    local identity = el_Bridge.Server.GetIdentity(src)
    if not identity then return respond(el_Fail('access_denied')) end

    local ok, response = pcall(handler, src, identity, payload)
    if not ok then
        el_Warn(('Handler "%s" failed: %s'):format(action, tostring(response)))
        response = el_Fail('internal_error')
    end
    respond(response or el_Fail('internal_error'))
end)

RegisterNetEvent('el_printer:server:requestPlaced', function()
    local src = source
    if not el_Ready or not el_RateLimit(src, 'requestPlaced') then return end
    el_PrinterMgr.SyncPlaced(src)
end)

---------------------------------------------------------------------------------------------------
-- Usable items
---------------------------------------------------------------------------------------------------

-- Builds the read-only view of a printed document from item metadata (server-trusted).
function el_BuildItemView(metadata)
    if type(metadata) ~= 'table' or not el_Docs.IsValidId(metadata.el_document_id) then return nil end

    local doc, err = el_Docs.Get(metadata.el_document_id)
    if doc then
        local template = Config.DocumentTypes[doc.doc_type]
        local model = el_Docs.BuildModel(doc)
        if not model then return nil end
        local status = el_Docs.EffectiveStatus(doc)
        return {
            model = model,
            copy = tonumber(metadata.el_copy),
            verification = template and template.verification and {
                state = status == 'active' and 'verified' or status,
                label = status == 'active' and 'Verified' or (status == 'revoked' and 'Revoked' or 'Expired'),
            } or nil,
            canShow = true,
        }
    end

    if type(metadata.el_snapshot) == 'table' then
        return {
            model = metadata.el_snapshot,
            copy = tonumber(metadata.el_copy),
            verification = {
                state = 'unverified',
                label = err == 'database_error' and 'Verification Unavailable' or 'Record Not Found',
            },
            canShow = true,
        }
    end
    return nil
end

local function el_RegisterItems()
    el_Bridge.ServerInventory.RegisterUsable(Config.Items.Printer, 'el_usePrinterItem', function(src)
        if not el_Ready then return end
        if not Config.Placement.Enabled then
            return el_Bridge.Server.Notify(src, el_Text('placement_disabled'), 'error')
        end
        local identity = el_Bridge.Server.GetIdentity(src)
        if not identity or not el_Perm.HasPrinter(identity, 'place') then
            return el_Bridge.Server.Notify(src, el_Text('access_denied'), 'error')
        end
        if el_Bridge.ServerInventory.GetItemCount(src, Config.Items.Printer) < 1 then
            return el_Bridge.Server.Notify(src, el_Text('missing_printer_item'), 'error')
        end
        el_Placing[src] = GetGameTimer() + (Config.Placement.Timeout * 1000) + 5000
        TriggerClientEvent('el_printer:client:startPlacement', src, {
            model = Config.Placement.Model,
            maxDistance = Config.Placement.MaxDistance,
            timeout = Config.Placement.Timeout,
        })
    end)

    el_Bridge.ServerInventory.RegisterUsable(Config.Items.Document, 'el_useDocumentItem', function(src, metadata)
        if not el_Ready then return end
        if not el_RateLimit(src, 'useDocument') then return end
        local view = el_BuildItemView(metadata)
        if not view then
            return el_Bridge.Server.Notify(src, el_Text('document_not_found'), 'error')
        end
        el_LastViewed[src] = { id = metadata.el_document_id, copy = tonumber(metadata.el_copy) }
        TriggerClientEvent('el_printer:client:viewDocument', src, view)
    end)
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

local function el_PlayerLeft(src)
    el_Printing.PlayerLeft(src)
    el_PrinterMgr.RemoveViewer(src)
    el_RateState[src] = nil
    el_Placing[src] = nil
    el_LastViewed[src] = nil
end

AddEventHandler('playerDropped', function()
    el_PlayerLeft(source)
end)

AddEventHandler('el_printer:server:playerLeft', function(src)
    if type(src) == 'number' then el_PlayerLeft(src) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= el_RESOURCE then return end
    el_Printing.Shutdown()
end)

CreateThread(function()
    if not el_Bridge.Server.IsReady() then
        el_Warn('Startup aborted: qb-core is not available.')
        return
    end

    el_RegisterItems()
    el_PrinterMgr.LoadFixed()
    el_DB.Init()
    el_PrinterMgr.LoadPersistent()

    if GetConvarInt('onesync_enabled', 0) == 0 and GetConvar('onesync', 'off') == 'off' then
        el_Warn('OneSync appears to be disabled. Server-side distance checks require OneSync.')
    end

    el_Ready = true
    el_PrinterMgr.SyncPlaced(-1)
    print(('[el_printer] Started. Storage: %s, printers loaded: %d'):format(el_Docs.StorageMode(), (function()
        local count = 0
        for _ in pairs(el_Printers) do count = count + 1 end
        return count
    end)()))
end)
