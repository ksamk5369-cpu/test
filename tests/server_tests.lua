--[[
    Executes el_printer server logic against the mock in fivem_mock.lua.
    Run with: python3 tests/run_tests.py
]]

local passed, failed = 0, 0
local function check(name, condition, detail)
    if condition then
        passed = passed + 1
        print('  PASS  ' .. name)
    else
        failed = failed + 1
        print('  FAIL  ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
    end
end

local function err(res) return res and (res.error or (res.ok and 'ok')) or 'no response' end

local MRPD = vector3(441.21, -978.62, 30.69)
local CITY = vector3(-262.73, -965.05, 31.22)
local FAR = vector3(0.0, 0.0, 0.0)

-- Players --------------------------------------------------------------------------------------------
Mock.AddPlayer(1, 'COP001', 'John', 'Doe', 'police', 2, true, MRPD, 1000)
Mock.AddPlayer(2, 'CIV002', 'Jane', 'Smith', 'unemployed', 0, false, CITY, 1000)
Mock.AddPlayer(3, 'COP003', 'Mike', 'Off', 'police', 4, false, MRPD, 1000)  -- off duty

-- Boot -------------------------------------------------------------------------------------------------
Mock.Run(500)
check('resource starts', Mock.errors == nil, Mock.errors and Mock.errors[1])
check('fixed printers loaded', el_Printers.mrpd_records ~= nil and el_Printers.city_hall ~= nil)
check('session storage when oxmysql is missing', el_Docs.StorageMode() == 'session')

print('\n== Access control')
local res = Mock.Request(2, 'openPrinter', { printerId = 'mrpd_records' })
check('civilian denied at police printer', err(res) == 'access_denied', err(res))
res = Mock.Request(3, 'openPrinter', { printerId = 'mrpd_records' })
check('off-duty officer denied (requireDuty)', err(res) == 'access_denied', err(res))
res = Mock.Request(1, 'openPrinter', { printerId = 'nope' })
check('invalid printer id rejected', err(res) == 'printer_not_found', err(res))
res = Mock.Request(1, 'openPrinter', { printerId = 'city_hall' })
check('distance enforced server-side', err(res) == 'too_far', err(res))
res = Mock.Request(1, 'openPrinter', { printerId = 'mrpd_records' })
check('officer opens police printer', res and res.ok, err(res))

local templates = {}
for _, t in ipairs(res.data.templates) do templates[t.key] = true end
check('police report offered', templates.police_report)
check('weapon license hidden below grade 3', not templates.weapon_license)
check('medical report hidden (not allowed on printer)', not templates.medical_report)
check('UI does not open itself (only on request)', #Mock.EventsFor(2, 'el_printer:client:viewDocument') == 0)

print('\n== Document creation & validation')
res = Mock.Request(1, 'createDocument', { docType = 'police_report', fields = { location = 'x' } }, 3500)
check('invalid input rejected with field errors', err(res) == 'invalid_input' and res.fieldErrors and res.fieldErrors.narrative ~= nil, err(res))

res = Mock.Request(1, 'createDocument', { docType = 'weapon_license', fields = { recipient = 'CIV002', category = 'Handgun' } }, 3500)
check('weapon license creation denied below grade 3 (forged request)', err(res) == 'access_denied', err(res))

res = Mock.Request(1, 'previewDocument', { docType = 'police_report', fields = {
    incident = 'Theft', location = 'Legion Square', occurred = '2026-10-01', narrative = 'Suspect fled the scene on foot heading north.',
} }, 1000)
check('preview returns server-built model', res and res.ok and res.data.model.pending == true and res.data.model.issuer.name == 'John Doe', err(res))

local reportFields = {
    incident = 'Theft', location = 'Legion Square', occurred = '2026-10-01',
    narrative = 'Suspect fled the scene on foot heading north.', issuer_name = 'Forged Name', subject = 'CIV002',
}
res = Mock.Request(1, 'createDocument', { docType = 'police_report', fields = reportFields }, 3500)
check('police report created', res and res.ok, err(res))
local reportId = res.data.summary.id
local report = el_Docs.Get(reportId)
check('issuer stamped by server (client field ignored)', report.issuer_name == 'John Doe' and report.data.values.issuer_name == nil)
check('citizen field resolved by server', report.data.citizens.subject and report.data.citizens.subject.name == 'Jane Smith')

local badDate = Mock.Request(1, 'createDocument', { docType = 'police_report', fields = {
    incident = 'Theft', location = 'Legion Square', occurred = '2026-02-31', narrative = 'Suspect fled the scene on foot heading north.',
} }, 3500)
check('invalid calendar date rejected', err(badDate) == 'invalid_input', err(badDate))

local badSelect = Mock.Request(1, 'createDocument', { docType = 'police_report', fields = {
    incident = 'Hacked Option', location = 'Legion Square', occurred = '2026-02-01', narrative = 'Suspect fled the scene on foot heading north.',
} }, 3500)
check('select value outside options rejected', err(badSelect) == 'invalid_input', err(badSelect))

print('\n== Printing workflow')
local printer = el_Printers.mrpd_records
local paperBefore, inkBefore, durBefore = printer.paper, printer.ink, printer.durability
res = Mock.Request(1, 'print', { documentId = reportId, copies = 1 }, 100)
check('print started', res and res.ok and res.messageKey == 'printing_started', err(res))
check('printer busy and supplies reserved', printer.active ~= nil and printer.paper == paperBefore - 2 and printer.ink == inkBefore - 2)
check('no document granted before completion', Mock.CountItem(1, 'printer_document') == 0)
local progress = Mock.EventsFor(1, 'el_printer:client:jobEvent')
Mock.Run(3000)
local progressEvents = 0
for _, e in ipairs(Mock.EventsFor(1, 'el_printer:client:jobEvent')) do
    if e.args[1].state == 'progress' then progressEvents = progressEvents + 1 end
end
check('server sends real progress updates', progressEvents >= 2, progressEvents)
Mock.Run(4000)
check('document granted after completion', Mock.CountItem(1, 'printer_document') == 1)
check('supplies consumed, durability worn', printer.paper == paperBefore - 2 and printer.ink == inkBefore - 2 and printer.durability < durBefore)
check('printer released', printer.active == nil)
check('print count incremented', el_Docs.Get(reportId).print_count == 1)

print('\n== Supplies')
printer.paper = 1
res = Mock.Request(1, 'print', { documentId = reportId, copies = 1 }, 2000)
check('not enough paper blocks printing', err(res) == 'not_enough_paper', err(res))
printer.paper = 100
printer.ink = 0
res = Mock.Request(1, 'print', { documentId = reportId, copies = 1 }, 2000)
check('not enough ink blocks printing', err(res) == 'not_enough_ink', err(res))
check('no item granted on failure', Mock.CountItem(1, 'printer_document') == 1)

printer.ink = 10
Mock.players[1].obj.Functions.AddItem('printer_ink', 1)
res = Mock.Request(1, 'refill', { kind = 'ink' }, 1000)
check('ink refill consumes item', res and res.ok and printer.ink == 50 and Mock.CountItem(1, 'printer_ink') == 0, err(res))
res = Mock.Request(1, 'refill', { kind = 'ink' }, 1000)
check('refill without item rejected', err(res) == 'missing_ink_item', err(res))

print('\n== Cancellation & presence')
paperBefore, inkBefore = printer.paper, printer.ink
res = Mock.Request(1, 'print', { documentId = reportId, copies = 2 }, 1600)
check('second print started', res and res.ok, err(res))
local jobId = res.data.jobId
res = Mock.Request(1, 'cancelJob', { jobId = jobId }, 2000)
check('cancel accepted', res and res.ok, err(res))
check('cancel restores supplies and grants nothing', printer.paper == paperBefore and printer.ink == inkBefore and Mock.CountItem(1, 'printer_document') == 1 and printer.active == nil)

res = Mock.Request(1, 'print', { documentId = reportId, copies = 1 }, 1600)
Mock.players[1].coords = FAR
Mock.Run(3000)
check('walking away fails the job and restores supplies', printer.active == nil and printer.paper == paperBefore and Mock.CountItem(1, 'printer_document') == 1)
Mock.players[1].coords = MRPD

print('\n== Queue limits & concurrency')
Mock.AddPlayer(4, 'COP004', 'Ann', 'Lee', 'police', 1, true, MRPD, 1000)
res = Mock.Request(4, 'openPrinter', { printerId = 'mrpd_records' })
check('second officer opens printer', res and res.ok, err(res))
res = Mock.Request(1, 'print', { documentId = reportId, copies = 1 }, 1600)
check('job A started', res and res.ok, err(res))
-- Officer 4 cannot print a report they did not issue without reprint permission at grade 1? (reprint = 1 -> allowed)
local res4 = Mock.Request(4, 'print', { documentId = reportId, copies = 1 }, 100)
check('second player queued behind busy printer', res4 and res4.ok and res4.messageKey == 'printing_queued', err(res4))
local res1b = Mock.Request(1, 'print', { documentId = reportId, copies = 1 }, 1600)
check('same player may queue a second job', res1b and res1b.ok, err(res1b))
local res1c = Mock.Request(1, 'print', { documentId = reportId, copies = 1 }, 1600)
check('per-player job limit enforced', err(res1c) == 'too_many_jobs', err(res1c))
Mock.Run(40000)
check('queue drained without overconsumption', printer.active == nil and #printer.queue == 0 and printer.paper >= 0)
check('every finished job granted exactly one copy', Mock.CountItem(1, 'printer_document') == 3 and Mock.CountItem(4, 'printer_document') == 1,
    Mock.CountItem(1, 'printer_document') .. '/' .. Mock.CountItem(4, 'printer_document'))
check('print count matches granted copies', el_Docs.Get(reportId).print_count == 4, el_Docs.Get(reportId).print_count)

print('\n== Rate limiting')
local limited = false
for _ = 1, 3 do
    local r = Mock.Request(1, 'print', { documentId = reportId, copies = 1 }, 0)
    if err(r) == 'rate_limited' then limited = true end
end
Mock.Run(30000)
check('rapid duplicate requests are rate limited', limited)
check('only accepted requests produced copies', el_Docs.Get(reportId).print_count == Mock.CountItem(1, 'printer_document') + Mock.CountItem(4, 'printer_document'))

print('\n== Privacy & licences')
res = Mock.Request(2, 'openPrinter', { printerId = 'city_hall' })
check('civilian opens public printer', res and res.ok, err(res))
local civTemplates = {}
for _, t in ipairs(res.data.templates) do civTemplates[t.key] = true end
check('civilian only sees civilian templates', civTemplates.general and not civTemplates.driver_license and not civTemplates.government)
local seesReport = false
for _, d in ipairs(res.data.documents) do if d.id == reportId then seesReport = true end end
check('report about civilian not listed for civilian', not seesReport)
res = Mock.Request(2, 'getDocument', { documentId = reportId }, 1000)
check('civilian cannot open police report by ID', err(res) == 'document_not_found', err(res))
res = Mock.Request(2, 'print', { documentId = reportId, copies = 1 }, 2000)
check('civilian cannot print police report by ID', err(res) == 'document_not_found', err(res))
res = Mock.Request(2, 'createDocument', { docType = 'driver_license', fields = { recipient = 'CIV002', class = 'Class B - Car' } }, 3500)
check('civilian cannot issue a driver license', err(res) == 'access_denied', err(res))

res = Mock.Request(2, 'createDocument', { docType = 'general', fields = { title = 'For Sale', body = 'Selling a used bicycle in good condition.' } }, 3500)
check('civilian creates general document', res and res.ok, err(res))
local generalId = res.data.summary.id
Mock.players[2].obj.PlayerData.money.cash = 5
res = Mock.Request(2, 'print', { documentId = generalId, copies = 1 }, 2000)
check('not enough money blocks printing', err(res) == 'not_enough_money', err(res))
Mock.players[2].obj.PlayerData.money.cash = 1000
res = Mock.Request(2, 'print', { documentId = generalId, copies = 2 }, 15000)
check('civilian prints 2 copies and pays', Mock.CountItem(2, 'printer_document') == 2 and Mock.players[2].obj.PlayerData.money.cash == 980,
    Mock.players[2].obj.PlayerData.money.cash)

-- Driver license issued by officer to civilian; max 3 prints.
res = Mock.Request(1, 'createDocument', { docType = 'driver_license', fields = { recipient = 'CIV002', class = 'Class B - Car' } }, 3500)
check('officer issues driver license', res and res.ok, err(res))
local licenseId = res.data.summary.id
local license = el_Docs.Get(licenseId)
check('license owner is the recipient', license.owner_cid == 'CIV002' and license.expires_at ~= nil)
local docsBefore = Mock.CountItem(1, 'printer_document')
res = Mock.Request(1, 'print', { documentId = licenseId, copies = 3 }, 15000)
check('license printed 3 copies', Mock.CountItem(1, 'printer_document') == docsBefore + 3, Mock.CountItem(1, 'printer_document') - docsBefore)
res = Mock.Request(1, 'print', { documentId = licenseId, copies = 1 }, 2000)
check('max print limit enforced', err(res) == 'print_limit_reached', err(res))
res = Mock.Request(2, 'print', { documentId = licenseId, copies = 1 }, 2000)
check('owner cannot reprint official license', err(res) == 'access_denied' or err(res) == 'too_far', err(res))

print('\n== Revocation & verification')
local view
do
    local before = #Mock.clientEvents
    local item
    for _, it in pairs(Mock.players[1].obj.PlayerData.items) do
        if it.name == 'printer_document' and it.info.el_document_id == licenseId then item = it end
    end
    check('document item carries server metadata', item ~= nil and item.info.el_copy ~= nil)
    CreateThread(function() Mock.useables.printer_document(1, item) end)
    Mock.Run(100)
    local events = Mock.EventsFor(1, 'el_printer:client:viewDocument', before)
    view = events[1] and events[1].args[1]
    check('using document shows verified view', view and view.verification and view.verification.state == 'verified')
end
Mock.Run(3000)
res = Mock.Request(1, 'revokeDocument', { documentId = licenseId }, 3000)
check('grade 2 officer revokes license', res and res.ok and res.data.summary.status == 'revoked', err(res))
check('revoked doc model reports status', el_Docs.BuildModel(el_Docs.Get(licenseId)).status == 'revoked')

print('\n== Disconnect during print')
paperBefore = printer.paper
res = Mock.Request(4, 'print', { documentId = reportId, copies = 1 }, 1600)
check('officer 4 printing', res and res.ok, err(res))
Mock.Drop(4)
Mock.Run(500)
check('disconnect rolls back reservation', printer.active == nil and printer.paper == paperBefore)

print('\n== Placement')
Mock.players[2].obj.Functions.AddItem('printer', 1)
CreateThread(function() Mock.useables.printer(2, {}) end)
Mock.Run(100)
res = Mock.Request(2, 'placePrinter', { coords = { x = CITY.x + 30, y = CITY.y, z = CITY.z }, heading = 90.0 }, 3500)
check('placement too far rejected', err(res) == 'too_far', err(res))
res = Mock.Request(2, 'placePrinter', { coords = { x = CITY.x + 0.5, y = CITY.y, z = CITY.z }, heading = 90.0 }, 3500)
check('placement too close to fixed printer rejected', err(res) == 'placement_too_close', err(res))
res = Mock.Request(2, 'placePrinter', { coords = { x = CITY.x + 3.0, y = CITY.y, z = CITY.z }, heading = 90.0 }, 3500)
check('valid placement creates printer and consumes item', res and res.ok and Mock.CountItem(2, 'printer') == 0, err(res))
local placedId = res.data.printerId
res = Mock.Request(2, 'placePrinter', { coords = { x = CITY.x + 3.0, y = CITY.y + 2, z = CITY.z }, heading = 90.0 }, 3500)
check('placement without a fresh item use rejected', err(res) == 'placement_invalid', err(res))
Mock.players[1].coords = vector3(CITY.x + 3.0, CITY.y, CITY.z)
res = Mock.Request(1, 'removePrinter', { printerId = placedId }, 2500)
check('non-owner without permission cannot remove', err(res) == 'access_denied', err(res))
Mock.players[1].coords = MRPD
res = Mock.Request(2, 'removePrinter', { printerId = placedId }, 2500)
check('owner removes printer and gets item back', res and res.ok and el_Printers[placedId] == nil and Mock.CountItem(2, 'printer') == 1, err(res))

print('\n== Database mode')
Mock.resources.oxmysql = 'started'
el_DB.SetReady(true)
check('storage switches to database', el_Docs.StorageMode() == 'database')
res = Mock.Request(2, 'createDocument', { docType = 'general', fields = { title = 'Stored', body = 'This document is stored in the database.' } }, 3500)
check('document stored in database', res and res.ok and Mock.db.documents[res.data.summary.id] ~= nil, err(res))
local dbDocId = res.data.summary.id

Mock.db.fail = true
res = Mock.Request(2, 'createDocument', { docType = 'general', fields = { title = 'Lost', body = 'This document must not be reported as saved.' } }, 3500)
check('database failure is reported, not faked', err(res) == 'database_error', err(res))
Mock.db.fail = false

local cityPrinter = el_Printers.city_hall
local cityPaper = cityPrinter.paper
local itemsBefore = Mock.CountItem(2, 'printer_document')
local cashBefore = Mock.players[2].obj.PlayerData.money.cash
res = Mock.Request(2, 'print', { documentId = dbDocId, copies = 1 }, 1600)
check('db print started', res and res.ok, err(res))
Mock.db.fail = true
Mock.Run(10000)
Mock.db.fail = false
check('db failure at completion: no item, no charge, supplies restored',
    Mock.CountItem(2, 'printer_document') == itemsBefore and Mock.players[2].obj.PlayerData.money.cash == cashBefore and cityPrinter.paper == cityPaper,
    Mock.CountItem(2, 'printer_document') .. ' ' .. Mock.players[2].obj.PlayerData.money.cash .. ' ' .. cityPrinter.paper)

Mock.inventoryFull = true
Mock.Run(3000)
res = Mock.Request(2, 'print', { documentId = dbDocId, copies = 1 }, 10000)
Mock.inventoryFull = false
check('inventory full at completion: refunded and count rolled back',
    Mock.players[2].obj.PlayerData.money.cash == cashBefore and Mock.db.documents[dbDocId].print_count == 0,
    Mock.players[2].obj.PlayerData.money.cash .. ' / ' .. Mock.db.documents[dbDocId].print_count)

print('\n== Resource stop')
Mock.Run(3000)
res = Mock.Request(2, 'print', { documentId = dbDocId, copies = 1 }, 1600)
local reserved = cityPrinter.paper
el_Printing.Shutdown()
check('shutdown releases reserved supplies', cityPrinter.active == nil and cityPrinter.paper == reserved + 1)

print(('\n%d passed, %d failed'):format(passed, failed))
if Mock.errors then
    for _, e in ipairs(Mock.errors) do print(e) end
end
return failed == 0 and not Mock.errors
