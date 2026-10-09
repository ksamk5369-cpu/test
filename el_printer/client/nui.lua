--[[
    Client <-> server requests and NUI bridge.

    The NUI never talks to the server directly. It posts to whitelisted NUI callbacks, the client
    forwards the request (always attaching the printer the player actually opened) and returns the
    server's answer. Focus is released on every close path.
]]

el_UI = {
    open = false,
    mode = nil,         -- 'dashboard' | 'viewer'
    printerId = nil,
}

local el_Pending = {}
local el_RequestId = 0

-- Sends a request to the server and waits for the response (or a timeout).
function el_ServerRequest(action, payload, timeout)
    el_RequestId = el_RequestId + 1
    local id = el_RequestId
    local p = promise.new()
    el_Pending[id] = p
    TriggerServerEvent('el_printer:server:request', id, action, payload or {})
    SetTimeout(timeout or 15000, function()
        local pending = el_Pending[id]
        if pending then
            el_Pending[id] = nil
            pending:resolve({ ok = false, error = 'timeout', message = el_Text('timeout') })
        end
    end)
    return Citizen.Await(p)
end

RegisterNetEvent('el_printer:client:response', function(id, response)
    local p = el_Pending[id]
    if not p then return end
    el_Pending[id] = nil
    p:resolve(response or { ok = false, error = 'internal_error', message = el_Text('internal_error') })
end)

function el_NuiSend(action, data)
    SendNUIMessage({ action = action, data = data })
end

-- Shows the outcome of a request (success message or error) through the notify bridge.
function el_NotifyResponse(response)
    if not response then return end
    if response.ok and response.message then
        el_Bridge.Client.Notify(response.message, response.messageType or 'success')
    elseif not response.ok and response.message then
        el_Bridge.Client.Notify(response.message, 'error')
    end
end

---------------------------------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------------------------------

local function el_SetFocus(state)
    SetNuiFocus(state, state)
    SetNuiFocusKeepInput(false)
end

function el_CloseUI(notifyServer)
    local wasDashboard = el_UI.mode == 'dashboard'
    el_UI.open = false
    el_UI.mode = nil
    el_UI.printerId = nil
    el_SetFocus(false)
    el_NuiSend('close')
    if wasDashboard and notifyServer ~= false then
        CreateThread(function()
            el_ServerRequest('closePrinter', {})
        end)
    end
end

local el_Opening = false

function el_OpenPrinter(printerId)
    if el_Opening or el_UI.open or el_IsPlacing() then return end
    if IsPauseMenuActive() or IsEntityDead(PlayerPedId()) then return end
    el_Opening = true

    el_NuiSend('loading', { label = 'Connecting to printer' })
    local response = el_ServerRequest('openPrinter', { printerId = printerId })
    el_Opening = false

    if not response.ok then
        el_NuiSend('loading', false)
        el_NotifyResponse(response)
        return
    end

    el_Bridge.Inventory.CloseInventory()
    el_UI.open = true
    el_UI.mode = 'dashboard'
    el_UI.printerId = printerId
    el_SetFocus(true)
    el_NuiSend('openDashboard', response.data)
    el_MonitorOpenPrinter(printerId)
end

function el_OpenViewer(view)
    if el_UI.open and el_UI.mode == 'dashboard' then
        el_CloseUI()
    end
    el_Bridge.Inventory.CloseInventory()
    el_UI.open = true
    el_UI.mode = 'viewer'
    el_UI.printerId = nil
    el_SetFocus(true)
    el_NuiSend('openViewer', view)
end

---------------------------------------------------------------------------------------------------
-- NUI callbacks
---------------------------------------------------------------------------------------------------

local el_AllowedActions = {
    getDashboard = true,
    getDocument = true,
    previewDocument = true,
    createDocument = true,
    print = true,
    cancelJob = true,
    refill = true,
    setMaintenance = true,
    repair = true,
    revokeDocument = true,
    removePrinter = true,
    showDocument = true,
}

-- Actions that don't need an open dashboard.
local el_ViewerActions = { showDocument = true, cancelJob = true }

-- The page asks for its settings once it has loaded (messages sent earlier could be missed).
RegisterNUICallback('el_ready', function(_, cb)
    cb({
        sounds = Config.Sounds.Enabled and Config.Sounds.Printing,
        volume = Config.Sounds.Volume,
        notifyDuration = Config.NotifyDuration,
    })
end)

RegisterNUICallback('el_close', function(_, cb)
    el_CloseUI()
    cb({ ok = true })
end)

RegisterNUICallback('el_request', function(data, cb)
    local action = type(data) == 'table' and data.action
    if type(action) ~= 'string' or not el_AllowedActions[action] then
        return cb({ ok = false, error = 'invalid_request', message = el_Text('invalid_request') })
    end
    if not el_UI.open then
        return cb({ ok = false, error = 'invalid_request', message = el_Text('invalid_request') })
    end
    if el_UI.mode ~= 'dashboard' and not el_ViewerActions[action] then
        return cb({ ok = false, error = 'invalid_request', message = el_Text('invalid_request') })
    end

    local payload = type(data.payload) == 'table' and data.payload or {}
    -- The printer is always the one this client opened, never a value chosen by the page.
    payload.printerId = el_UI.printerId

    local response = el_ServerRequest(action, payload)

    el_NotifyResponse(response)
    if response.ok and action == 'removePrinter' then
        el_CloseUI(false)
    end
    cb(response)
end)

RegisterNUICallback('el_uiSound', function(data, cb)
    if Config.Sounds.Enabled and type(data) == 'table' then
        local sound = data.kind == 'error' and Config.Sounds.Error or Config.Sounds.Complete
        if sound then PlaySoundFrontend(-1, sound.name, sound.set, true) end
    end
    cb({ ok = true })
end)

---------------------------------------------------------------------------------------------------
-- Server -> NUI events
---------------------------------------------------------------------------------------------------

RegisterNetEvent('el_printer:client:printerState', function(state)
    if el_UI.open and el_UI.mode == 'dashboard' and type(state) == 'table' and state.id == el_UI.printerId then
        el_NuiSend('printerState', state)
    end
end)

RegisterNetEvent('el_printer:client:printerRemoved', function(printerId)
    if el_UI.open and el_UI.mode == 'dashboard' and el_UI.printerId == printerId then
        el_CloseUI(false)
    end
end)

RegisterNetEvent('el_printer:client:viewDocument', function(view)
    if type(view) ~= 'table' or type(view.model) ~= 'table' then return end
    el_OpenViewer(view)
end)

RegisterNetEvent('el_printer:client:notify', function(message, notifyType)
    if type(message) ~= 'string' then return end
    el_Bridge.Client.Notify(message, notifyType or 'info')
end)

-- Close automatically when the player dies or walks away.
function el_MonitorOpenPrinter(printerId)
    CreateThread(function()
        while el_UI.open and el_UI.mode == 'dashboard' and el_UI.printerId == printerId do
            Wait(500)
            local ped = PlayerPedId()
            local coords, distance = el_GetPrinterCoords(printerId)
            if IsEntityDead(ped) or not coords
                or #(GetEntityCoords(ped) - coords) > (distance or 2.0) + Config.Security.DistanceTolerance + 1.0 then
                if el_UI.open and el_UI.printerId == printerId then
                    el_CloseUI()
                end
                return
            end
        end
    end)
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= el_RESOURCE then return end
    if el_UI.open then
        SetNuiFocus(false, false)
    end
end)
