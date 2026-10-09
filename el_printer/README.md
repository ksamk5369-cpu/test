# el_printer — Empire Line Printer System

A printer resource for **QBCore**. It includes fixed and placeable printers, document templates, server-validated printing, a print queue, paper and ink supplies, maintenance, and an Empire Line NUI dashboard.

## 1. Dependencies
| Resource | Required |
|---|---|
| `qb-core` | Yes |
| `qb-target` **or** `ox_target` | Yes (auto-detected) |
| `qb-inventory` **or** `ox_inventory` | Yes (auto-detected) |
| `oxmysql` | Optional. Needed for persistent storage. Without it, documents are kept for the current session only. |
| OneSync | Required, because the server checks player distance itself |

Fonts (Manrope) and icons (Font Awesome 6) are bundled in `html/vendor`, so the UI needs no internet access.

## 2–4. Installation, start order and `server.cfg`
1. Copy the `el_printer` folder into your `resources` directory.
2. Add the items (see section 6).
3. Add these lines to `server.cfg`, in this order:
```cfg
ensure oxmysql
ensure qb-core
ensure ox_lib        # only if Config.Notify = 'ox'
ensure qb-target     # or ox_target
ensure qb-inventory  # or ox_inventory
ensure el_printer
```

## 5. Database
The tables are created automatically on start (`Config.Persistence.AutoCreateTables = true`). To create them manually, import `sql/el_printer.sql`. If the database is unreachable:
- The dashboard shows **Session Storage**.
- Saving a document returns **Database Unavailable - Nothing Was Saved**. A failed save is never reported as successful.

## 6. Inventory items
- **qb-inventory:** copy the entries from `items/qb-core.lua` into `qb-core/shared/items.lua`. Copy `html/img/*.png` into `qb-inventory/html/images/`.
- **ox_inventory:** copy the entries from `items/ox_inventory.lua` into `ox_inventory/data/items.lua`. Copy the images into `ox_inventory/web/images/`. The printer and document items use the server exports `el_printer.el_usePrinterItem` and `el_printer.el_useDocumentItem`.

You can rename the items in `Config.Items`.

## 7. Printer props
`Config.Models.Default` sets the prop for fixed printers that have `spawnProp = true`. `Config.Placement.Model` sets the prop for portable printers. Props are spawned locally only when a player is within `Config.Placement.StreamDistance`.

## 8. Fixed printers
```lua
Config.Printers.my_office = {
    label = 'Office Printer',
    coords = vector4(x, y, z, heading),
    spawnProp = true,
    jobs = { police = 0 },          -- nil = public
    documents = { 'general' },      -- nil = all types
    usePaper = true, useInk = true,
    durationMultiplier = 1.0, distance = 2.0,
    zoneSize = vector3(1.0, 1.0, 1.2), enabled = true,
}
```

## 9. Placeable printers
To place a printer, a player uses the `printer` item. Controls: **E** places it, the **arrow keys** rotate it, and **Backspace** cancels. The server checks:
- distance and height
- spacing to other printers
- blocked zones
- routing bucket
- per-player and total limits
- that the player really has the item

All settings are in `Config.Placement`. Who can open a placed printer is set by `Access`: `public`, `owner` or `job`.

## 10. Jobs and grades
`Config.Jobs[job].documents[type] = { create, view, reprint, revoke }` and `Config.Jobs[job].printer = { access, refill, maintain, place, remove }`. Each value is the minimum grade. The `'*'` entry applies to every player. `requireDuty = true` means the player must be on duty. The UI only hides actions; the server checks every permission.

## 11. Document templates
`Config.DocumentTypes`. The comment block in `config.lua` documents every option. Main options:
- **Layouts:** `letter`, `official`, `license`, `report`, `invoice`, `contract`.
- **Field types:** `text`, `textarea`, `number`, `date`, `select`, `citizen`. A `citizen` field resolves the citizen on the server.

The server always stamps the issuer, organization, recipient, reference number, dates and expiry.

## 12. UI customization
Design tokens are at the top of `html/style.css` (accent `#CD6529`, surfaces, radii). The document layouts are in `html/render.js`. The preview, saved documents and printed items all use the same renderer.

## 13. Inventory and target selection
`Config.Inventory` and `Config.Target` are set to `'auto'` by default. You can force a value: `'qb-inventory'` or `'ox_inventory'`, and `'qb-target'` or `'ox_target'`. `Config.Notify` accepts `'el'` (Empire Line toasts), `'qb'` or `'ox'`.

## 14. Troubleshooting
- **No "Use Printer" option:** check that a target resource is started, then check the `jobs` setting and on-duty status.
- **Session Storage shown:** oxmysql is not started or the tables could not be created. Check the server console.
- **Item cannot be used:** check the item definition. ox_inventory needs the `server.export` lines.
- **"You Are Too Far From The Printer":** OneSync is disabled, or the printer coords are wrong.

## 15. Debug mode
Set `Config.Debug = true` to get console logging and to show the target zones.

## 16. Security
- All client input is untrusted. The server re-validates printer access, distance, permissions, field values, citizen IDs, item counts and money.
- Supplies are reserved atomically when a job starts and are returned on cancel, failure, disconnect or resource stop.
- Money is charged and items are granted only when the job completes. Every completion step rolls back if a later step fails.
- The print count is reserved with an optimistic `UPDATE ... WHERE print_count = ?`, so concurrent reprints cannot go over `maxPrints`.
- Rate limits and per-action cooldowns are set in `Config.Security`.
- Document IDs are random. A document you cannot access returns "Document Not Found", so IDs cannot be probed.

## Tests
`python3 tests/run_tests.py` (requires `pip install lupa`) runs the server logic against a mocked FiveM/QBCore/oxmysql environment.
