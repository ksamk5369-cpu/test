--[[
    Placement mode for portable printers.
    The client only proposes a position; the server validates distance, spacing, blocked zones,
    limits and item ownership before anything is created.
]]

local el_Placing = false

function el_IsPlacing()
    return el_Placing
end

local function el_LoadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(hash) do
        if GetGameTimer() > timeout then return nil end
        Wait(10)
    end
    return hash
end

el_LoadModelHash = el_LoadModel

local function el_RotationToDirection(rotation)
    local x = math.rad(rotation.x)
    local z = math.rad(rotation.z)
    local cosX = math.abs(math.cos(x))
    return vector3(-math.sin(z) * cosX, math.cos(z) * cosX, math.sin(x))
end

local function el_RaycastFromCamera(distance, ignore)
    local camCoords = GetGameplayCamCoord()
    local direction = el_RotationToDirection(GetGameplayCamRot(2))
    local destination = camCoords + direction * distance
    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        camCoords.x, camCoords.y, camCoords.z,
        destination.x, destination.y, destination.z,
        1 + 16, ignore, 4)
    local _, hit, endCoords, surfaceNormal = GetShapeTestResult(handle)
    return hit == 1 or hit == true, endCoords, surfaceNormal
end

local function el_PlayPlacementAnim()
    local anim = Config.Animations.Placement
    if not Config.Animations.Enabled or not anim then return end
    RequestAnimDict(anim.dict)
    local timeout = GetGameTimer() + 2000
    while not HasAnimDictLoaded(anim.dict) and GetGameTimer() < timeout do Wait(10) end
    if HasAnimDictLoaded(anim.dict) then
        TaskPlayAnim(PlayerPedId(), anim.dict, anim.clip, 8.0, -8.0, anim.duration or 1200, 0, 0.0, false, false, false)
        RemoveAnimDict(anim.dict)
    end
end

function el_StartPlacement(data)
    if el_Placing or el_UI.open then return end
    if IsPedInAnyVehicle(PlayerPedId(), false) then
        return el_Bridge.Client.Notify(el_Text('placement_invalid'), 'error')
    end

    local hash = el_LoadModel(data.model or Config.Placement.Model)
    if not hash then
        el_Warn('Placement model could not be loaded: ' .. tostring(data.model))
        return el_Bridge.Client.Notify(el_Text('placement_invalid'), 'error')
    end

    el_Placing = true
    local controls = Config.Placement.Controls
    local maxDistance = tonumber(data.maxDistance) or Config.Placement.MaxDistance
    local deadline = GetGameTimer() + (tonumber(data.timeout) or Config.Placement.Timeout) * 1000
    local ped = PlayerPedId()
    local start = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    local ghost = CreateObject(hash, start.x, start.y, start.z - 5.0, false, false, false)
    SetEntityAlpha(ghost, 160, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)
    SetModelAsNoLongerNeeded(hash)

    local submitting = false
    local lastValid = nil
    el_NuiSend('placement', { show = true, valid = false })

    local function el_Finish(cancelled)
        el_Placing = false
        if DoesEntityExist(ghost) then DeleteEntity(ghost) end
        el_NuiSend('placement', { show = false })
        if cancelled then
            CreateThread(function() el_ServerRequest('cancelPlacement', {}) end)
            el_Bridge.Client.Notify(el_Text('placement_cancelled'), 'warning')
        end
    end

    CreateThread(function()
        while el_Placing do
            ped = PlayerPedId()

            DisableControlAction(0, 24, true)    -- attack
            DisableControlAction(0, 25, true)    -- aim
            DisableControlAction(0, 140, true)   -- melee
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 37, true)    -- weapon wheel
            DisableControlAction(0, 200, true)   -- pause menu
            DisableControlAction(0, controls.Confirm, true)

            local hit, point = el_RaycastFromCamera(maxDistance + 6.0, ghost)
            local pedCoords = GetEntityCoords(ped)
            local valid = hit and #(pedCoords.xy - point.xy) <= maxDistance
                and math.abs(pedCoords.z - point.z) <= Config.Placement.MaxHeightDifference
                and not IsPedInAnyVehicle(ped, false)

            if hit then
                SetEntityCoordsNoOffset(ghost, point.x, point.y, point.z, false, false, false)
                SetEntityHeading(ghost, heading)
                PlaceObjectOnGroundProperly(ghost)
            end
            SetEntityAlpha(ghost, valid and 190 or 70, false)

            if valid ~= lastValid then
                lastValid = valid
                el_NuiSend('placement', { show = true, valid = valid })
            end

            if IsDisabledControlPressed(0, controls.RotateLeft) or IsControlPressed(0, controls.RotateLeft) then
                heading = (heading + Config.Placement.RotateStep) % 360.0
            elseif IsDisabledControlPressed(0, controls.RotateRight) or IsControlPressed(0, controls.RotateRight) then
                heading = (heading - Config.Placement.RotateStep) % 360.0
            end

            if IsControlJustPressed(0, controls.Cancel) or IsDisabledControlJustPressed(0, 200)
                or IsEntityDead(ped) or GetGameTimer() > deadline then
                el_Finish(true)
                return
            end

            if not submitting and valid and IsDisabledControlJustPressed(0, controls.Confirm) then
                submitting = true
                local final = GetEntityCoords(ghost)
                CreateThread(function()
                    local response = el_ServerRequest('placePrinter', {
                        coords = { x = final.x, y = final.y, z = final.z },
                        heading = heading,
                    })
                    el_NotifyResponse(response)
                    if response.ok then
                        el_Finish(false)
                        el_PlayPlacementAnim()
                    end
                    submitting = false
                end)
            end

            Wait(0)
        end
    end)
end

RegisterNetEvent('el_printer:client:startPlacement', function(data)
    if type(data) ~= 'table' then return end
    el_StartPlacement(data)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= el_RESOURCE then return end
    el_Placing = false
end)
