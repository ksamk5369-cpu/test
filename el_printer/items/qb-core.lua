--[[
    qb-inventory item definitions.
    Copy the entries inside the table below into the QBShared.Items table in qb-core/shared/items.lua
    and copy html/img/*.png into qb-inventory/html/images/.

    The item names must match Config.Items in el_printer/config.lua.
    This file is documentation only and is not loaded by the resource.
]]

local el_QbCoreItems = {
    printer = {
        name = 'printer',
        label = 'Portable Printer',
        weight = 3000,
        type = 'item',
        image = 'printer.png',
        unique = true,
        useable = true,
        shouldClose = true,
        description = 'A compact office printer. Use it to place it on a flat surface.',
    },

    printer_paper = {
        name = 'printer_paper',
        label = 'Printer Paper',
        weight = 500,
        type = 'item',
        image = 'printer_paper.png',
        unique = false,
        useable = false,
        shouldClose = false,
        description = 'A pack of 50 sheets for printers.',
    },

    printer_ink = {
        name = 'printer_ink',
        label = 'Printer Ink',
        weight = 300,
        type = 'item',
        image = 'printer_ink.png',
        unique = false,
        useable = false,
        shouldClose = false,
        description = 'An ink cartridge for printers.',
    },

    printer_document = {
        name = 'printer_document',
        label = 'Printed Document',
        weight = 10,
        type = 'item',
        image = 'printer_document.png',
        unique = true,
        useable = true,
        shouldClose = true,
        description = 'A printed document. Use it to read it.',
    },
}

return el_QbCoreItems
