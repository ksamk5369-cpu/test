--[[
    ox_inventory item definitions.
    Copy the entries inside the table below into ox_inventory/data/items.lua
    and copy html/img/*.png into ox_inventory/web/images/.

    The item names must match Config.Items in el_printer/config.lua.
    consume = 0 keeps the item when it is used; el_printer removes the printer item itself
    only after the server accepted the placement.
    This file is documentation only and is not loaded by the resource.
]]

local el_OxInventoryItems = {
    ['printer'] = {
        label = 'Portable Printer',
        weight = 3000,
        stack = false,
        close = true,
        consume = 0,
        description = 'A compact office printer. Use it to place it on a flat surface.',
        server = {
            export = 'el_printer.el_usePrinterItem',
        },
    },

    ['printer_paper'] = {
        label = 'Printer Paper',
        weight = 500,
        stack = true,
        close = false,
        description = 'A pack of 50 sheets for printers.',
    },

    ['printer_ink'] = {
        label = 'Printer Ink',
        weight = 300,
        stack = true,
        close = false,
        description = 'An ink cartridge for printers.',
    },

    ['printer_document'] = {
        label = 'Printed Document',
        weight = 10,
        stack = false,
        close = true,
        consume = 0,
        description = 'A printed document. Use it to read it.',
        server = {
            export = 'el_printer.el_useDocumentItem',
        },
    },
}

return el_OxInventoryItems
