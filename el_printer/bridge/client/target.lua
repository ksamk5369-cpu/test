--[[
    Client target bridge (qb-target / ox_target).

    Options are passed in a neutral format:
      { name = 'el_printer_open', label = 'Use Printer', icon = 'fa-solid fa-print',
        onSelect = function(entity) end, canInteract = function(entity) return true end }
]]

el_Bridge.Target = {}

local el_TargetName = nil
local el_Zones = {}      -- id -> backend handle
local el_Entities = {}   -- entity -> option names

local function el_GetTarget()
    if not el_TargetName then
        el_TargetName = el_Bridge.ResolveTarget()
        if not el_TargetName then
            el_Warn('No target resource found. Start qb-target or ox_target.')
        else
            el_Debug('Target bridge:', el_TargetName)
        end
    end
    return el_TargetName
end

local function el_ToQbOptions(options)
    local result = {}
    for i = 1, #options do
        local option = options[i]
        result[i] = {
            type = 'client',
            icon = option.icon,
            label = option.label,
            action = function(entity) option.onSelect(entity) end,
            canInteract = option.canInteract and function(entity) return option.canInteract(entity) end or nil,
        }
    end
    return result
end

local function el_ToOxOptions(options, distance)
    local result = {}
    for i = 1, #options do
        local option = options[i]
        result[i] = {
            name = option.name,
            icon = option.icon,
            label = option.label,
            distance = distance,
            onSelect = function(data) option.onSelect(data and data.entity) end,
            canInteract = option.canInteract and function(entity) return option.canInteract(entity) end or nil,
        }
    end
    return result
end

-- Adds a box/sphere zone at coords. Returns true on success.
function el_Bridge.Target.AddZone(id, coords, size, heading, options, distance)
    local target = el_GetTarget()
    if not target then return false end
    el_Bridge.Target.RemoveZone(id)

    local x, y, z = el_UnpackCoords(coords)
    size = size or vector3(1.0, 1.0, 1.2)

    if target == 'ox_target' then
        el_Zones[id] = exports.ox_target:addBoxZone({
            coords = vector3(x, y, z + (size.z / 2) - 0.2),
            size = size,
            rotation = heading or 0.0,
            debug = Config.Debug,
            options = el_ToOxOptions(options, distance),
        })
    else
        exports['qb-target']:AddBoxZone(id, vector3(x, y, z), size.x, size.y, {
            name = id,
            heading = heading or 0.0,
            debugPoly = Config.Debug,
            minZ = z - 0.2,
            maxZ = z + size.z,
        }, {
            options = el_ToQbOptions(options),
            distance = distance,
        })
        el_Zones[id] = id
    end
    return true
end

function el_Bridge.Target.RemoveZone(id)
    local handle = el_Zones[id]
    if not handle then return end
    if el_TargetName == 'ox_target' then
        exports.ox_target:removeZone(handle)
    elseif el_TargetName == 'qb-target' then
        exports['qb-target']:RemoveZone(handle)
    end
    el_Zones[id] = nil
end

function el_Bridge.Target.AddEntity(entity, options, distance)
    local target = el_GetTarget()
    if not target or not DoesEntityExist(entity) then return false end

    local names, labels = {}, {}
    for i = 1, #options do
        names[i] = options[i].name
        labels[i] = options[i].label
    end

    if target == 'ox_target' then
        exports.ox_target:addLocalEntity(entity, el_ToOxOptions(options, distance))
        el_Entities[entity] = names
    else
        exports['qb-target']:AddTargetEntity(entity, {
            options = el_ToQbOptions(options),
            distance = distance,
        })
        el_Entities[entity] = labels
    end
    return true
end

function el_Bridge.Target.RemoveEntity(entity)
    local keys = el_Entities[entity]
    if not keys then return end
    if el_TargetName == 'ox_target' then
        exports.ox_target:removeLocalEntity(entity, keys)
    elseif el_TargetName == 'qb-target' then
        exports['qb-target']:RemoveTargetEntity(entity, keys)
    end
    el_Entities[entity] = nil
end

function el_Bridge.Target.RemoveAll()
    for id in pairs(el_Zones) do
        el_Bridge.Target.RemoveZone(id)
    end
    for entity in pairs(el_Entities) do
        el_Bridge.Target.RemoveEntity(entity)
    end
end
