--[[
    Printer registry: fixed printers from the config, placed printers from the database,
    supplies, durability, maintenance state and state broadcasting.
]]

el_Printers = {}
el_PrinterMgr = {}

local el_IdChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

function el_GenerateId(prefix, length)
    local out = {}
    for i = 1, length do
        local index = math.random(1, #el_IdChars)
        out[i] = el_IdChars:sub(index, index)
    end
    return prefix .. table.concat(out)
end

local function el_SuppliesEnabled(kind)
    return Config.Supplies[kind] and Config.Supplies[kind].Enabled == true
end

local function el_DurabilityEnabled()
    return Config.Maintenance.Durability.Enabled == true
end

local function el_NewPrinter(data)
    local x, y, z, h = el_UnpackCoords(data.coords)
    return {
        id = data.id,
        kind = data.kind,
        label = data.label or 'Printer',
        coords = vector3(x, y, z),
        heading = h,
        model = data.model,
        jobs = data.jobs,
        documents = data.documents,
        usePaper = data.usePaper ~= false,
        useInk = data.useInk ~= false,
        durationMultiplier = tonumber(data.durationMultiplier) or 1.0,
        distance = tonumber(data.distance) or 2.0,
        enabled = data.enabled ~= false,
        owner = data.owner,
        ownerJob = data.ownerJob or '',
        paper = data.paper or 0,
        ink = data.ink or 0,
        durability = data.durability or Config.Maintenance.Durability.Default,
        maintenance = false,
        repairUntil = nil,
        active = nil,
        queue = {},
        viewers = {},
    }
end

---------------------------------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------------------------------

function el_PrinterMgr.LoadFixed()
    for id, cfg in pairs(Config.Printers) do
        if type(id) == 'string' and cfg.coords then
            el_Printers[id] = el_NewPrinter({
                id = id,
                kind = 'fixed',
                label = cfg.label,
                coords = cfg.coords,
                model = cfg.spawnProp and (cfg.model or Config.Models.Default) or nil,
                jobs = cfg.jobs,
                documents = cfg.documents,
                usePaper = cfg.usePaper,
                useInk = cfg.useInk,
                durationMultiplier = cfg.durationMultiplier,
                distance = cfg.distance,
                enabled = cfg.enabled,
                paper = Config.Supplies.Paper.Default,
                ink = Config.Supplies.Ink.Default,
            })
        end
    end
end

local function el_PlacedPrinter(row)
    return el_NewPrinter({
        id = row.id,
        kind = 'placed',
        label = row.label or Config.Placement.Label,
        coords = vector4(row.x, row.y, row.z, row.heading or 0.0),
        model = row.model or Config.Placement.Model,
        jobs = nil,
        documents = Config.Placement.Documents,
        usePaper = Config.Placement.UsePaper,
        useInk = Config.Placement.UseInk,
        durationMultiplier = Config.Placement.DurationMultiplier,
        distance = Config.Placement.Distance,
        enabled = true,
        owner = row.owner_cid,
        ownerJob = row.owner_job,
        paper = Config.Placement.StartPaper,
        ink = Config.Placement.StartInk,
        durability = Config.Maintenance.Durability.Max,
    })
end

function el_PrinterMgr.LoadPersistent()
    if not el_DB.IsReady() then return end

    if Config.Placement.Enabled then
        local rows = el_DB.Query('SELECT * FROM `el_printer_placed`')
        for _, row in ipairs(rows or {}) do
            el_Printers[row.id] = el_PlacedPrinter(row)
        end
    end

    local states = el_DB.Query('SELECT * FROM `el_printer_state`')
    for _, row in ipairs(states or {}) do
        local printer = el_Printers[row.printer_id]
        if printer then
            printer.paper = el_Clamp(tonumber(row.paper) or 0, 0, Config.Supplies.Paper.Max)
            printer.ink = el_Clamp(tonumber(row.ink) or 0, 0, Config.Supplies.Ink.Max)
            printer.durability = el_Clamp(tonumber(row.durability) or 0, 0, Config.Maintenance.Durability.Max)
            printer.maintenance = Config.Maintenance.MaintenanceMode and (tonumber(row.maintenance) == 1 or row.maintenance == true) or false
        end
    end
end

function el_PrinterMgr.Get(id)
    if type(id) ~= 'string' or #id > 48 then return nil end
    return el_Printers[id]
end

function el_PrinterMgr.SaveState(printer)
    if not el_DB.IsReady() then return end
    -- Reserved supplies of a running job are stored as if the job had been cancelled.
    local paper, ink = printer.paper, printer.ink
    if printer.active then
        paper = paper + (printer.active.reservedPaper or 0)
        ink = ink + (printer.active.reservedInk or 0)
    end
    el_DB.Execute([[
        INSERT INTO `el_printer_state` (`printer_id`, `paper`, `ink`, `durability`, `maintenance`, `updated_at`)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE `paper` = VALUES(`paper`), `ink` = VALUES(`ink`),
            `durability` = VALUES(`durability`), `maintenance` = VALUES(`maintenance`), `updated_at` = VALUES(`updated_at`)
    ]], { printer.id, math.floor(paper), math.floor(ink), el_Round(printer.durability, 2), printer.maintenance and 1 or 0, os.time() })
end

---------------------------------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------------------------------

function el_PrinterMgr.Status(printer)
    if not printer.enabled then return 'offline' end
    if printer.repairUntil then return 'repairing' end
    if printer.maintenance then return 'maintenance' end
    if el_DurabilityEnabled() and printer.durability <= 0 then return 'broken' end
    if printer.active then return 'busy' end
    if printer.usePaper and el_SuppliesEnabled('Paper') and printer.paper <= 0 then return 'no_paper' end
    if printer.useInk and el_SuppliesEnabled('Ink') and printer.ink <= 0 then return 'no_ink' end
    return 'ready'
end

-- Error code that blocks printing right now, or nil.
function el_PrinterMgr.BlockingError(printer)
    local status = el_PrinterMgr.Status(printer)
    if status == 'offline' then return 'printer_offline' end
    if status == 'repairing' then return 'printer_repairing' end
    if status == 'maintenance' then return 'printer_in_maintenance' end
    if status == 'broken' then return 'printer_requires_maintenance' end
    return nil
end

function el_PrinterMgr.Warnings(printer)
    local warnings = {}
    if printer.usePaper and el_SuppliesEnabled('Paper') and printer.paper > 0
        and printer.paper <= Config.Supplies.Paper.LowThreshold then
        warnings[#warnings + 1] = 'Low paper'
    end
    if printer.useInk and el_SuppliesEnabled('Ink') and printer.ink > 0
        and printer.ink <= Config.Supplies.Ink.LowThreshold then
        warnings[#warnings + 1] = 'Low ink'
    end
    if el_DurabilityEnabled() and printer.durability > 0
        and printer.durability <= Config.Maintenance.Durability.LowThreshold then
        warnings[#warnings + 1] = 'Maintenance recommended'
    end
    return warnings
end

local function el_JobView(job, src, now)
    local mine = job.src == src
    local view = {
        id = job.id,
        mine = mine,
        copies = job.copies,
        state = job.state,
        title = mine and job.title or 'Print job',
        typeLabel = mine and job.typeLabel or nil,
    }
    if job.state == 'printing' and job.startedAt then
        local elapsed = now - job.startedAt
        view.progress = el_Clamp(math.floor(elapsed / job.duration * 100), 0, 99)
        view.remaining = math.max(0, job.duration - elapsed)
        view.duration = job.duration
    end
    return view
end

-- State payload for one viewer (queue entries of other players are anonymized).
function el_PrinterMgr.PublicState(printer, src)
    local now = GetGameTimer()
    local queue = {}
    for i = 1, #printer.queue do
        queue[i] = el_JobView(printer.queue[i], src, now)
    end
    return {
        id = printer.id,
        label = printer.label,
        kind = printer.kind,
        status = el_PrinterMgr.Status(printer),
        warnings = el_PrinterMgr.Warnings(printer),
        paper = {
            enabled = printer.usePaper and el_SuppliesEnabled('Paper'),
            value = math.floor(printer.paper),
            max = Config.Supplies.Paper.Max,
            low = Config.Supplies.Paper.LowThreshold,
        },
        ink = {
            enabled = printer.useInk and el_SuppliesEnabled('Ink'),
            value = math.floor(printer.ink),
            max = Config.Supplies.Ink.Max,
            low = Config.Supplies.Ink.LowThreshold,
        },
        durability = {
            enabled = el_DurabilityEnabled(),
            value = el_Round(printer.durability, 1),
            max = Config.Maintenance.Durability.Max,
            low = Config.Maintenance.Durability.LowThreshold,
        },
        maintenance = printer.maintenance,
        repairRemaining = printer.repairUntil and math.max(0, printer.repairUntil - now) or nil,
        active = printer.active and el_JobView(printer.active, src, now) or nil,
        queue = queue,
        queueEnabled = Config.Printing.Queue.Enabled,
        queueMax = Config.Printing.Queue.MaxSize,
    }
end

function el_PrinterMgr.AddViewer(printer, src)
    printer.viewers[src] = true
end

function el_PrinterMgr.RemoveViewer(src)
    for _, printer in pairs(el_Printers) do
        printer.viewers[src] = nil
    end
end

function el_PrinterMgr.Broadcast(printer)
    for src in pairs(printer.viewers) do
        if GetPlayerName(src) then
            TriggerClientEvent('el_printer:client:printerState', src, el_PrinterMgr.PublicState(printer, src))
        else
            printer.viewers[src] = nil
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Distance
---------------------------------------------------------------------------------------------------

function el_GetPlayerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    return GetEntityCoords(ped)
end

function el_PrinterMgr.IsNear(src, printer, multiplier)
    local coords = el_GetPlayerCoords(src)
    if not coords then return false end
    local limit = printer.distance * (multiplier or 1.0) + Config.Security.DistanceTolerance
    return #(coords - printer.coords) <= limit
end

---------------------------------------------------------------------------------------------------
-- Supplies & maintenance
---------------------------------------------------------------------------------------------------

-- kind: 'paper' | 'ink'. Consumes one item from the player's inventory.
function el_PrinterMgr.Refill(src, printer, kind)
    local cfg = kind == 'paper' and Config.Supplies.Paper or Config.Supplies.Ink
    local itemName = kind == 'paper' and Config.Items.Paper or Config.Items.Ink
    local uses = kind == 'paper' and printer.usePaper or printer.useInk
    if not cfg.Enabled or not uses then return false, 'feature_disabled' end
    if printer.repairUntil then return false, 'printer_repairing' end

    local current = printer[kind]
    if printer.active then
        current = current + (kind == 'paper' and printer.active.reservedPaper or printer.active.reservedInk)
    end
    if current >= cfg.Max then return false, 'printer_full' end

    if el_Bridge.ServerInventory.GetItemCount(src, itemName) < 1 then
        return false, kind == 'paper' and 'missing_paper_item' or 'missing_ink_item'
    end
    if not el_Bridge.ServerInventory.RemoveItem(src, itemName, 1) then
        return false, kind == 'paper' and 'missing_paper_item' or 'missing_ink_item'
    end

    printer[kind] = math.min(printer[kind] + cfg.PerItem, cfg.Max - (current - printer[kind]))
    el_PrinterMgr.SaveState(printer)
    el_PrinterMgr.Broadcast(printer)
    return true, kind == 'paper' and 'paper_loaded' or 'ink_loaded'
end

function el_PrinterMgr.SetMaintenance(printer, enabled)
    if not Config.Maintenance.MaintenanceMode then return false, 'feature_disabled' end
    printer.maintenance = enabled == true
    el_PrinterMgr.SaveState(printer)
    el_PrinterMgr.Broadcast(printer)
    if printer.maintenance then
        el_Printing.FailQueued(printer, 'printer_in_maintenance')
    else
        el_Printing.StartNext(printer)
    end
    return true, printer.maintenance and 'maintenance_enabled' or 'maintenance_disabled'
end

function el_PrinterMgr.Repair(src, printer)
    local repair = Config.Maintenance.Repair
    if not repair.Enabled or not el_DurabilityEnabled() then return false, 'feature_disabled' end
    if printer.repairUntil then return false, 'printer_repairing' end
    if printer.active then return false, 'printer_busy' end
    if printer.durability >= Config.Maintenance.Durability.Max then return false, 'printer_not_damaged' end

    local cost = tonumber(repair.Cost) or 0
    if cost > 0 and not el_Bridge.Server.RemoveMoney(src, repair.Account, cost, 'el-printer-repair') then
        return false, 'not_enough_money'
    end

    local duration = tonumber(repair.Duration) or 0
    if duration <= 0 then
        printer.durability = Config.Maintenance.Durability.Max
        el_PrinterMgr.SaveState(printer)
        el_PrinterMgr.Broadcast(printer)
        el_Printing.StartNext(printer)
        return true, 'printer_repaired'
    end

    printer.repairUntil = GetGameTimer() + duration
    el_PrinterMgr.Broadcast(printer)
    SetTimeout(duration, function()
        if el_Printers[printer.id] ~= printer then return end
        printer.repairUntil = nil
        printer.durability = Config.Maintenance.Durability.Max
        el_PrinterMgr.SaveState(printer)
        el_PrinterMgr.Broadcast(printer)
        if GetPlayerName(src) then
            el_Bridge.Server.Notify(src, el_Text('printer_repaired'), 'success')
        end
        el_Printing.StartNext(printer)
    end)
    return true, 'repair_started'
end

---------------------------------------------------------------------------------------------------
-- Placed printers
---------------------------------------------------------------------------------------------------

function el_PrinterMgr.PlacedList()
    local list = {}
    for _, printer in pairs(el_Printers) do
        if printer.kind == 'placed' then
            list[#list + 1] = {
                id = printer.id,
                label = printer.label,
                model = printer.model,
                coords = { x = printer.coords.x, y = printer.coords.y, z = printer.coords.z },
                heading = printer.heading,
                owner = printer.owner,
                distance = printer.distance,
            }
        end
    end
    return list
end

function el_PrinterMgr.SyncPlaced(target)
    TriggerClientEvent('el_printer:client:syncPlaced', target or -1, el_PrinterMgr.PlacedList())
end

local function el_CountOwned(citizenid)
    local owned, total = 0, 0
    for _, printer in pairs(el_Printers) do
        if printer.kind == 'placed' then
            total = total + 1
            if printer.owner == citizenid then owned = owned + 1 end
        end
    end
    return owned, total
end

-- Validates a placement request. coords/heading come from the client and are fully re-checked.
function el_PrinterMgr.ValidatePlacement(src, identity, coords, heading)
    local cfg = Config.Placement
    if not cfg.Enabled then return false, 'placement_disabled' end
    if not el_Perm.HasPrinter(identity, 'place') then return false, 'access_denied' end

    if type(coords) ~= 'table' or type(heading) ~= 'number' then return false, 'invalid_request' end
    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z then return false, 'invalid_request' end
    if x ~= x or y ~= y or z ~= z or math.abs(x) > 20000 or math.abs(y) > 20000 or math.abs(z) > 3000 then
        return false, 'invalid_request'
    end
    if heading ~= heading then return false, 'invalid_request' end
    local point = vector3(x, y, z)

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'placement_invalid' end
    if GetVehiclePedIsIn(ped, false) ~= 0 then return false, 'placement_invalid' end

    local bucket = GetPlayerRoutingBucket(src)
    if not el_TableContains(cfg.AllowedRoutingBuckets, bucket) then return false, 'placement_invalid' end

    local playerCoords = GetEntityCoords(ped)
    if #(playerCoords.xy - point.xy) > cfg.MaxDistance + Config.Security.DistanceTolerance then
        return false, 'too_far'
    end
    if math.abs(playerCoords.z - point.z) > cfg.MaxHeightDifference then
        return false, 'placement_invalid'
    end

    for _, zone in ipairs(cfg.BlockedZones or {}) do
        if #(point - zone.coords) <= zone.radius then return false, 'placement_invalid' end
    end

    for _, printer in pairs(el_Printers) do
        if #(printer.coords - point) < cfg.MinSpacing then return false, 'placement_too_close' end
    end

    local owned, total = el_CountOwned(identity.citizenid)
    if cfg.MaxPerPlayer > 0 and owned >= cfg.MaxPerPlayer then return false, 'placement_limit' end
    if cfg.MaxTotal > 0 and total >= cfg.MaxTotal then return false, 'placement_limit' end

    return true, point, ((heading % 360.0) + 360.0) % 360.0
end

function el_PrinterMgr.CreatePlaced(identity, point, heading)
    local id
    repeat
        id = el_GenerateId('PL-', 8)
    until not el_Printers[id]

    local row = {
        id = id,
        label = Config.Placement.Label,
        model = Config.Placement.Model,
        x = point.x, y = point.y, z = point.z,
        heading = heading,
        owner_cid = identity.citizenid,
        owner_job = identity.job.name or '',
    }

    if el_DB.IsReady() then
        local result = el_DB.Query([[
            INSERT INTO `el_printer_placed` (`id`, `label`, `model`, `x`, `y`, `z`, `heading`, `owner_cid`, `owner_job`, `created_at`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], { row.id, row.label, row.model, row.x, row.y, row.z, row.heading, row.owner_cid, row.owner_job, os.time() })
        if not result then return nil, 'database_error' end
    end

    local printer = el_PlacedPrinter(row)
    el_Printers[id] = printer
    el_PrinterMgr.SaveState(printer)
    return printer
end

function el_PrinterMgr.DeletePlaced(printer)
    if el_DB.IsReady() then
        local result = el_DB.Query('DELETE FROM `el_printer_placed` WHERE `id` = ?', { printer.id })
        if not result then return false, 'database_error' end
        el_DB.Execute('DELETE FROM `el_printer_state` WHERE `printer_id` = ?', { printer.id })
    end
    el_Printers[printer.id] = nil
    return true
end
