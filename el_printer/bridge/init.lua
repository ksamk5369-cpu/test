--[[
    Bridge bootstrap (shared).
    Resolves which integrations are used so the rest of the resource never has to
    know about qb-target / ox_target or qb-inventory / ox_inventory directly.
]]

el_Bridge = {}

local function el_IsStarted(resource)
    local state = GetResourceState(resource)
    return state == 'started' or state == 'starting'
end

el_Bridge.IsStarted = el_IsStarted

function el_Bridge.ResolveTarget()
    if Config.Target == 'qb-target' or Config.Target == 'ox_target' then
        return Config.Target
    end
    if el_IsStarted('ox_target') then return 'ox_target' end
    if el_IsStarted('qb-target') then return 'qb-target' end
    return nil
end

function el_Bridge.ResolveInventory()
    if Config.Inventory == 'qb-inventory' or Config.Inventory == 'ox_inventory' then
        return Config.Inventory
    end
    if el_IsStarted('ox_inventory') then return 'ox_inventory' end
    return 'qb-inventory'
end

function el_Bridge.ResolveNotify()
    if Config.Notify == 'ox' and not el_IsStarted('ox_lib') then
        return 'el'
    end
    if Config.Notify == 'qb' or Config.Notify == 'ox' then
        return Config.Notify
    end
    return 'el'
end
