--[[
    Client entry point: fixed printer zones, streamed printer props, placed printers,
    print job feedback (animation, sound, NUI progress) and cleanup.
]]

local el_Fixed = {}         -- id -> { cfg, entity }
local el_Placed = {}        -- id -> { data, entity }
local el_AnimActive = false
local el_ActiveJobs = {}    -- jobId -> printerId

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

function el_GetPrinterCoords(printerId)
    local fixed = el_Fixed[printerId]
    if fixed then
        local x, y, z = el_UnpackCoords(fixed.cfg.coords)
        return vector3(x, y, z), fixed.cfg.distance or 2.0
    end
    local placed = el_Placed[printerId]
    if placed then
        local c = placed.data.coords
        return vector3(c.x, c.y, c.z), placed.data.distance or Config.Placement.Distance
    end
    return nil
end

local function el_CanSeeFixed(cfg)
    if not cfg.jobs then return true end
    local jobName, grade, onDuty = el_Bridge.Client.GetJob()
    local minGrade = jobName and cfg.jobs[jobName]
    if minGrade == nil then return false end
    local entry = Config.Jobs[jobName]
    if entry and entry.requireDuty and not onDuty then return false end
    return grade >= minGrade
end

local function el_CanRemovePlaced(data)
    if data.owner and data.owner == el_Bridge.Client.GetCitizenId() and Config.Placement.OwnerCanRemove then
        return true
    end
    local jobName, grade, onDuty = el_Bridge.Client.GetJob()
    local entry = jobName and Config.Jobs[jobName]
    if not entry or not entry.printer or entry.printer.remove == nil or entry.printer.remove == false then return false end
    if entry.requireDuty and not onDuty then return false end
    return grade >= entry.printer.remove
end

local function el_SpawnProp(model, coords, heading)
    local hash = el_LoadModelHash(model)
    if not hash then
        el_Warn('Printer model could not be loaded: ' .. tostring(model))
        return nil
    end
    local entity = CreateObject(hash, coords.x, coords.y, coords.z, false, false, false)
    SetEntityHeading(entity, heading or 0.0)
    FreezeEntityPosition(entity, true)
    SetEntityInvincible(entity, true)
    SetModelAsNoLongerNeeded(hash)
    return entity
end

---------------------------------------------------------------------------------------------------
-- Fixed printers
---------------------------------------------------------------------------------------------------

local function el_SetupFixed()
    for id, cfg in pairs(Config.Printers) do
        if cfg.enabled ~= false and cfg.coords then
            el_Fixed[id] = { cfg = cfg, entity = nil }
            local x, y, z, h = el_UnpackCoords(cfg.coords)
            el_Bridge.Target.AddZone('el_printer_' .. id, vector3(x, y, z), cfg.zoneSize, h, {
                {
                    name = 'el_printer_use',
                    label = 'Use Printer',
                    icon = 'fa-solid fa-print',
                    onSelect = function() CreateThread(function() el_OpenPrinter(id) end) end,
                    canInteract = function() return el_CanSeeFixed(cfg) end,
                },
            }, cfg.distance or 2.0)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Placed printers
---------------------------------------------------------------------------------------------------

local function el_DespawnPlaced(id)
    local entry = el_Placed[id]
    if entry and entry.entity then
        el_Bridge.Target.RemoveEntity(entry.entity)
        if DoesEntityExist(entry.entity) then DeleteEntity(entry.entity) end
        entry.entity = nil
    end
end

local function el_SpawnPlaced(id)
    local entry = el_Placed[id]
    if not entry or entry.entity then return end
    local data = entry.data
    local entity = el_SpawnProp(data.model, data.coords, data.heading)
    if not entity then return end
    entry.entity = entity

    el_Bridge.Target.AddEntity(entity, {
        {
            name = 'el_printer_use',
            label = 'Use Printer',
            icon = 'fa-solid fa-print',
            onSelect = function() CreateThread(function() el_OpenPrinter(id) end) end,
        },
        {
            name = 'el_printer_remove',
            label = 'Pick Up Printer',
            icon = 'fa-solid fa-hand',
            onSelect = function()
                CreateThread(function()
                    local response = el_ServerRequest('removePrinter', { printerId = id })
                    el_NotifyResponse(response)
                end)
            end,
            canInteract = function() return el_CanRemovePlaced(data) end,
        },
    }, data.distance or Config.Placement.Distance)
end

RegisterNetEvent('el_printer:client:syncPlaced', function(list)
    if type(list) ~= 'table' then return end
    local incoming = {}
    for _, data in ipairs(list) do
        if type(data) == 'table' and type(data.id) == 'string' and type(data.coords) == 'table' then
            incoming[data.id] = data
        end
    end

    for id in pairs(el_Placed) do
        if not incoming[id] then
            el_DespawnPlaced(id)
            el_Placed[id] = nil
        end
    end
    for id, data in pairs(incoming) do
        if not el_Placed[id] then
            el_Placed[id] = { data = data, entity = nil }
        else
            el_Placed[id].data = data
        end
    end
end)

-- Streams props in and out. Runs every 1.5 s, not every frame.
local function el_StreamLoop()
    CreateThread(function()
        local stream = Config.Placement.StreamDistance
        while true do
            local coords = GetEntityCoords(PlayerPedId())

            for id, entry in pairs(el_Placed) do
                local c = entry.data.coords
                local distance = #(coords - vector3(c.x, c.y, c.z))
                if distance <= stream and not entry.entity then
                    el_SpawnPlaced(id)
                elseif distance > stream + 10.0 and entry.entity then
                    el_DespawnPlaced(id)
                end
            end

            for _, entry in pairs(el_Fixed) do
                if entry.cfg.spawnProp then
                    local x, y, z, h = el_UnpackCoords(entry.cfg.coords)
                    local distance = #(coords - vector3(x, y, z))
                    if distance <= stream and not entry.entity then
                        entry.entity = el_SpawnProp(entry.cfg.model or Config.Models.Default, vector3(x, y, z), h)
                    elseif distance > stream + 10.0 and entry.entity then
                        if DoesEntityExist(entry.entity) then DeleteEntity(entry.entity) end
                        entry.entity = nil
                    end
                end
            end

            Wait(1500)
        end
    end)
end

---------------------------------------------------------------------------------------------------
-- Print job feedback
---------------------------------------------------------------------------------------------------

local function el_StartPrintAnim(printerId)
    local anim = Config.Animations.Printing
    if not Config.Animations.Enabled or not anim or el_AnimActive then return end
    local coords = el_GetPrinterCoords(printerId)
    local ped = PlayerPedId()
    if not coords or #(GetEntityCoords(ped) - coords) > 4.0 or IsPedInAnyVehicle(ped, false) then return end

    RequestAnimDict(anim.dict)
    local timeout = GetGameTimer() + 2000
    while not HasAnimDictLoaded(anim.dict) and GetGameTimer() < timeout do Wait(10) end
    if not HasAnimDictLoaded(anim.dict) then return end

    TaskTurnPedToFaceCoord(ped, coords.x, coords.y, coords.z, 600)
    Wait(600)
    TaskPlayAnim(ped, anim.dict, anim.clip, 4.0, -4.0, -1, anim.flag or 49, 0.0, false, false, false)
    RemoveAnimDict(anim.dict)
    el_AnimActive = true
end

local function el_StopPrintAnim()
    if not el_AnimActive then return end
    el_AnimActive = false
    local anim = Config.Animations.Printing
    local ped = PlayerPedId()
    if anim and IsEntityPlayingAnim(ped, anim.dict, anim.clip, 3) then
        StopAnimTask(ped, anim.dict, anim.clip, 2.0)
    end
end

RegisterNetEvent('el_printer:client:jobEvent', function(event)
    if type(event) ~= 'table' or type(event.jobId) ~= 'string' then return end

    if event.state == 'started' then
        el_ActiveJobs[event.jobId] = event.printerId
        CreateThread(function() el_StartPrintAnim(event.printerId) end)
    elseif event.state == 'completed' or event.state == 'failed' or event.state == 'cancelled' then
        if el_ActiveJobs[event.jobId] then
            el_ActiveJobs[event.jobId] = nil
            el_StopPrintAnim()
        end
        if Config.Sounds.Enabled then
            local sound = event.state == 'completed' and Config.Sounds.Complete or Config.Sounds.Error
            if sound then PlaySoundFrontend(-1, sound.name, sound.set, true) end
        end
    end

    el_NuiSend('job', event)
end)

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

local el_Initialized = false

local function el_Init()
    if el_Initialized then return end
    el_Initialized = true
    el_Bridge.Client.RefreshPlayerData()
    el_SetupFixed()
    el_StreamLoop()
    TriggerServerEvent('el_printer:server:requestPlaced')
end

AddEventHandler('el_printer:client:playerLoaded', function()
    el_Init()
    TriggerServerEvent('el_printer:server:requestPlaced')
end)

AddEventHandler('el_printer:client:playerUnloaded', function()
    if el_UI.open then el_CloseUI(false) end
    el_StopPrintAnim()
end)

CreateThread(function()
    -- Resource restart while already in game.
    while not el_Bridge.Client.IsReady() do Wait(500) end
    Wait(1000)
    if LocalPlayer.state.isLoggedIn or el_Bridge.Client.RefreshPlayerData().citizenid then
        el_Init()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= el_RESOURCE then return end
    el_StopPrintAnim()
    el_Bridge.Target.RemoveAll()
    for id in pairs(el_Placed) do el_DespawnPlaced(id) end
    for _, entry in pairs(el_Fixed) do
        if entry.entity and DoesEntityExist(entry.entity) then DeleteEntity(entry.entity) end
    end
end)
