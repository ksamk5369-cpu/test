--[[
    Shared helpers and English message catalogue.
    Loaded on both the client and the server.
]]

el_RESOURCE = GetCurrentResourceName()

-- Every user-facing message. Keys are used as error codes between server, client and NUI.
el_Lang = {
    printer_ready = 'Printer Ready',
    printing_started = 'Printing Started',
    printing_completed = 'Printing Completed',
    printing_queued = 'Print Job Queued',
    printing_cancelled = 'Printing Cancelled',
    unable_to_print = 'Unable to Complete Printing',
    not_enough_paper = 'Not Enough Paper',
    not_enough_ink = 'Not Enough Ink',
    not_enough_money = 'Not Enough Money',
    access_denied = 'Access Denied',
    printer_busy = 'Printer Is Busy',
    queue_full = 'Print Queue Is Full',
    too_many_jobs = 'You Already Have Print Jobs Pending',
    document_saved = 'Document Saved',
    document_revoked = 'Document Revoked',
    document_is_revoked = 'This Document Has Been Revoked',
    document_expired = 'This Document Has Expired',
    document_not_found = 'Document Not Found',
    document_type_unavailable = 'This Printer Cannot Print That Document Type',
    print_limit_reached = 'Print Limit Reached For This Document',
    printer_requires_maintenance = 'Printer Requires Maintenance',
    printer_in_maintenance = 'Printer Is In Maintenance Mode',
    printer_repairing = 'Printer Is Being Repaired',
    printer_offline = 'Printer Is Offline',
    printer_not_found = 'Printer Not Found',
    printer_full = 'Printer Is Already Full',
    printer_repaired = 'Printer Repaired',
    repair_started = 'Repair Started',
    printer_not_damaged = 'Printer Does Not Need Repairs',
    maintenance_enabled = 'Maintenance Mode Enabled',
    maintenance_disabled = 'Maintenance Mode Disabled',
    paper_loaded = 'Paper Loaded',
    ink_loaded = 'Ink Loaded',
    missing_paper_item = 'You Have No Printer Paper',
    missing_ink_item = 'You Have No Printer Ink',
    too_far = 'You Are Too Far From The Printer',
    left_printer = 'You Moved Away From The Printer',
    inventory_full = 'Your Inventory Is Full',
    invalid_input = 'Some Fields Are Invalid',
    invalid_request = 'Invalid Request',
    citizen_not_found = 'Citizen Not Found',
    rate_limited = 'Slow Down',
    database_error = 'Database Unavailable - Nothing Was Saved',
    internal_error = 'Unexpected Error - Nothing Was Changed',
    timeout = 'The Server Did Not Respond',
    job_not_found = 'Print Job Not Found',
    placement_disabled = 'Printer Placement Is Disabled',
    placement_invalid = 'You Cannot Place A Printer Here',
    placement_too_close = 'Too Close To Another Printer',
    placement_limit = 'You Have Reached The Printer Limit',
    placement_cancelled = 'Placement Cancelled',
    printer_placed = 'Printer Placed',
    printer_removed = 'Printer Removed',
    missing_printer_item = 'You Do Not Have A Printer',
    no_player_nearby = 'No One Is Nearby',
    document_shown = 'Document Shown',
    feature_disabled = 'This Feature Is Disabled',
}

-- Notification type per message key (success | error | info | warning).
el_LangType = {
    printer_ready = 'success', printing_started = 'info', printing_completed = 'success',
    printing_queued = 'info', printing_cancelled = 'warning', document_saved = 'success',
    document_revoked = 'warning', printer_repaired = 'success', maintenance_enabled = 'warning', repair_started = 'info',
    maintenance_disabled = 'success', paper_loaded = 'success', ink_loaded = 'success',
    printer_placed = 'success', printer_removed = 'success', document_shown = 'success',
    rate_limited = 'warning', placement_cancelled = 'warning',
}

function el_Text(key)
    return el_Lang[key] or el_Lang.internal_error
end

function el_TextType(key)
    return el_LangType[key] or 'error'
end

function el_Debug(...)
    if not Config.Debug then return end
    local parts = {}
    for i = 1, select('#', ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    print(('^3[el_printer]^7 %s'):format(table.concat(parts, ' ')))
end

function el_Warn(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    print(('^1[el_printer]^7 %s'):format(table.concat(parts, ' ')))
end

function el_Clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

function el_Round(value, decimals)
    local mult = 10 ^ (decimals or 0)
    return math.floor(value * mult + 0.5) / mult
end

function el_TableContains(list, value)
    if type(list) ~= 'table' then return false end
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

-- Returns x, y, z, heading from a vector3/vector4 or a table.
function el_UnpackCoords(coords)
    if type(coords) == 'vector4' then
        return coords.x, coords.y, coords.z, coords.w
    elseif type(coords) == 'vector3' then
        return coords.x, coords.y, coords.z, 0.0
    elseif type(coords) == 'table' then
        return tonumber(coords.x) or 0.0, tonumber(coords.y) or 0.0, tonumber(coords.z) or 0.0,
            tonumber(coords.w or coords.h or coords.heading) or 0.0
    end
    return 0.0, 0.0, 0.0, 0.0
end
