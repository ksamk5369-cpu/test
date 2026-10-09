--[[
    Client inventory bridge (qb-inventory / ox_inventory).
    Client-side counts are only used to hide options that would fail anyway;
    the server re-checks every item operation.
]]

el_Bridge.Inventory = {}

local el_InventoryName = nil

local function el_GetInventory()
    if not el_InventoryName then
        el_InventoryName = el_Bridge.ResolveInventory()
        el_Debug('Inventory bridge (client):', el_InventoryName)
    end
    return el_InventoryName
end

function el_Bridge.Inventory.GetItemCount(itemName)
    if el_GetInventory() == 'ox_inventory' then
        local ok, count = pcall(function()
            return exports.ox_inventory:Search('count', itemName)
        end)
        return ok and tonumber(count) or 0
    end

    local data = el_Bridge.Client.GetPlayerData()
    local total = 0
    if data and type(data.items) == 'table' then
        for _, item in pairs(data.items) do
            if item and item.name == itemName then
                total = total + (tonumber(item.amount or item.count) or 0)
            end
        end
    end
    return total
end

-- qb-inventory closes itself when an item is used; ox_inventory exposes closeInventory.
function el_Bridge.Inventory.CloseInventory()
    if el_GetInventory() == 'ox_inventory' then
        pcall(function() exports.ox_inventory:closeInventory() end)
    end
end
