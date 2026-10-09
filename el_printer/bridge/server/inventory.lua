--[[
    Server inventory bridge (qb-inventory / ox_inventory).
    The only place that touches inventory APIs. Every function reads the real inventory
    of the player; nothing here accepts counts or metadata from the client.
]]

el_Bridge.ServerInventory = {}

local el_InventoryName = nil
local el_UsableHandlers = {}

local function el_GetInventory()
    if not el_InventoryName then
        el_InventoryName = el_Bridge.ResolveInventory()
        print(('[el_printer] Inventory bridge: %s'):format(el_InventoryName))
    end
    return el_InventoryName
end

local function el_IsOx()
    return el_GetInventory() == 'ox_inventory'
end

local function el_QbItemBox(src, itemName, action, amount)
    local core = el_Bridge.Server.GetCore()
    local shared = core and core.Shared and core.Shared.Items and core.Shared.Items[itemName]
    if shared then
        TriggerClientEvent('qb-inventory:client:ItemBox', src, shared, action, amount)
    end
end

-- Calls a qb-inventory export when it exists, otherwise returns nil.
local function el_QbExport(name, ...)
    local args = { ... }
    local ok, result, extra = pcall(function()
        return exports['qb-inventory'][name](nil, table.unpack(args))
    end)
    if ok then return true, result, extra end
    return false
end

function el_Bridge.ServerInventory.GetItemCount(src, itemName)
    if el_IsOx() then
        local ok, count = pcall(function()
            return exports.ox_inventory:Search(src, 'count', itemName)
        end)
        return ok and (tonumber(count) or 0) or 0
    end

    -- Sum every stack from the authoritative server-side player data.
    local player = el_Bridge.Server.GetPlayer(src)
    if not player or not player.PlayerData then return 0 end
    local total = 0
    for _, item in pairs(player.PlayerData.items or {}) do
        if item and item.name == itemName then
            total = total + (tonumber(item.amount) or 0)
        end
    end
    return total
end

function el_Bridge.ServerInventory.CanCarry(src, itemName, amount, metadata)
    if el_IsOx() then
        local ok, result = pcall(function()
            return exports.ox_inventory:CanCarryItem(src, itemName, amount, metadata)
        end)
        return ok and result == true
    end

    local exists, canAdd = el_QbExport('CanAddItem', src, itemName, amount)
    if exists then
        return canAdd == true
    end
    -- Older qb-inventory without CanAddItem: AddItem itself refuses when full.
    return true
end

function el_Bridge.ServerInventory.RemoveItem(src, itemName, amount)
    if amount <= 0 then return true end
    if el_Bridge.ServerInventory.GetItemCount(src, itemName) < amount then return false end

    if el_IsOx() then
        local ok, result = pcall(function()
            return exports.ox_inventory:RemoveItem(src, itemName, amount)
        end)
        return ok and result == true
    end

    local removed = false
    local exists, result = el_QbExport('RemoveItem', src, itemName, amount, false, 'el_printer')
    if exists then
        removed = result == true
    else
        local player = el_Bridge.Server.GetPlayer(src)
        removed = player ~= nil and player.Functions.RemoveItem(itemName, amount) == true
    end
    if removed then el_QbItemBox(src, itemName, 'remove', amount) end
    return removed
end

function el_Bridge.ServerInventory.AddItem(src, itemName, amount, metadata)
    if el_IsOx() then
        local ok, success = pcall(function()
            return exports.ox_inventory:AddItem(src, itemName, amount, metadata)
        end)
        return ok and success == true
    end

    local added = false
    local exists, result = el_QbExport('AddItem', src, itemName, amount, false, metadata, 'el_printer')
    if exists then
        added = result == true
    else
        local player = el_Bridge.Server.GetPlayer(src)
        added = player ~= nil and player.Functions.AddItem(itemName, amount, false, metadata) == true
    end
    if added then el_QbItemBox(src, itemName, 'add', amount) end
    return added
end

-- Removes a single document item whose metadata matches documentId and copy (used for rollback).
function el_Bridge.ServerInventory.RemoveDocumentItem(src, itemName, documentId, copy)
    if el_IsOx() then
        local ok, result = pcall(function()
            local slots = exports.ox_inventory:Search(src, 'slots', itemName) or {}
            for _, slotData in pairs(slots) do
                local meta = slotData.metadata
                if type(meta) == 'table' and meta.el_document_id == documentId and meta.el_copy == copy then
                    return exports.ox_inventory:RemoveItem(src, itemName, 1, nil, slotData.slot)
                end
            end
            return false
        end)
        return ok and result == true
    end

    local player = el_Bridge.Server.GetPlayer(src)
    if not player or not player.PlayerData then return false end
    for slot, item in pairs(player.PlayerData.items or {}) do
        local info = item and item.info
        if item and item.name == itemName and type(info) == 'table'
            and info.el_document_id == documentId and info.el_copy == copy then
            local slotNumber = item.slot or slot
            local exists, result = el_QbExport('RemoveItem', src, itemName, 1, slotNumber, 'el_printer')
            if exists then return result == true end
            return player.Functions.RemoveItem(itemName, 1, slotNumber) == true
        end
    end
    return false
end

-- Returns the metadata of a document item the player really holds, or nil.
function el_Bridge.ServerInventory.FindDocumentItem(src, itemName, documentId, copy)
    if el_IsOx() then
        local ok, found = pcall(function()
            local slots = exports.ox_inventory:Search(src, 'slots', itemName) or {}
            for _, slotData in pairs(slots) do
                local meta = slotData.metadata
                if type(meta) == 'table' and meta.el_document_id == documentId
                    and (copy == nil or meta.el_copy == copy) then
                    return meta
                end
            end
            return nil
        end)
        return ok and found or nil
    end

    local player = el_Bridge.Server.GetPlayer(src)
    if not player or not player.PlayerData then return nil end
    for _, item in pairs(player.PlayerData.items or {}) do
        local info = item and item.info
        if item and item.name == itemName and type(info) == 'table'
            and info.el_document_id == documentId and (copy == nil or info.el_copy == copy) then
            return info
        end
    end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Usable items
---------------------------------------------------------------------------------------------------

-- handler(src, metadata)
function el_Bridge.ServerInventory.RegisterUsable(itemName, exportName, handler)
    el_UsableHandlers[itemName] = handler

    -- ox_inventory: the item definition points to exports.el_printer:<exportName>.
    exports(exportName, function(event, item, inventory, slot)
        if event ~= 'usingItem' then return end
        local src = inventory and inventory.id
        if type(src) ~= 'number' then return false end
        local metadata = {}
        local ok, slotData = pcall(function()
            return exports.ox_inventory:GetSlot(src, slot)
        end)
        if ok and slotData and slotData.name == itemName then
            metadata = slotData.metadata or {}
        end
        handler(src, metadata)
        -- Returning false keeps the item: nothing is consumed by "using" it.
        return false
    end)

    if not el_IsOx() then
        local core = el_Bridge.Server.GetCore()
        if core then
            core.Functions.CreateUseableItem(itemName, function(source, item)
                handler(source, (item and item.info) or {})
            end)
        end
    end
end

function el_Bridge.ServerInventory.MetadataKey()
    return el_IsOx() and 'metadata' or 'info'
end
