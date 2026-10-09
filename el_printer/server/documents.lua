--[[
    Document validation, storage and rendering models.

    Documents are created only here. Issuer identity, organization, recipient identity,
    reference numbers and timestamps are stamped by the server; the client only supplies
    the raw field values, which are validated against the template.
]]

el_Docs = {}

local el_Cache = {}
local el_CacheSize = 0
local el_CacheLimit = 1000

local el_ListColumns = '`id`, `doc_type`, `title`, `owner_cid`, `issuer_cid`, `issuer_name`, `recipient_cid`, `status`, `print_count`, `created_at`, `expires_at`'

local function el_Persistent()
    return el_DB.IsReady()
end

function el_Docs.StorageMode()
    return el_Persistent() and 'database' or 'session'
end

local function el_CachePut(doc)
    if not el_Cache[doc.id] then
        if el_Persistent() and el_CacheSize >= el_CacheLimit then
            el_Cache = {}
            el_CacheSize = 0
        end
        el_CacheSize = el_CacheSize + 1
    end
    el_Cache[doc.id] = doc
end

function el_Docs.IsValidId(id)
    return type(id) == 'string' and #id <= 16 and id:match('^EL%-[A-Z0-9]+$') ~= nil
end

---------------------------------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------------------------------

local function el_FormatDate(timestamp)
    if not timestamp then return nil end
    return os.date('%d %b %Y', math.floor(timestamp))
end

local function el_FormatMoney(value)
    value = tonumber(value) or 0
    local negative = value < 0
    local whole, frac = math.modf(math.abs(value))
    local cents = math.floor(frac * 100 + 0.5)
    if cents >= 100 then whole, cents = whole + 1, cents - 100 end
    local formatted = tostring(math.floor(whole)):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return ('%s$%s.%02d'):format(negative and '-' or '', formatted, cents)
end

el_Docs.FormatMoney = el_FormatMoney

local function el_ParseDate(value)
    local y, m, d = tostring(value):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or y < 1900 or y > 2200 or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
    local ts = os.time({ year = y, month = m, day = d, hour = 12 })
    local check = os.date('*t', ts)
    if check.day ~= d or check.month ~= m then return nil end
    return ts
end

---------------------------------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------------------------------

local function el_CleanText(value, multiline)
    if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
    value = tostring(value)
    if not utf8.len(value) then return nil end
    if multiline then
        value = value:gsub('\r\n', '\n'):gsub('\r', '\n')
        value = value:gsub('[%z\1-\9\11-\31\127]', '')
        value = value:gsub('\n\n\n+', '\n\n')
    else
        value = value:gsub('[%z\1-\31\127]', ' ')
        value = value:gsub('%s%s+', ' ')
    end
    value = value:gsub('^%s+', ''):gsub('%s+$', '')
    return value
end

local function el_Length(value)
    return utf8.len(value) or #value
end

-- Returns values, resolvedCitizens or nil, fieldErrors.
-- Every field value is re-validated; unknown fields are ignored.
function el_Docs.Validate(template, input)
    if type(input) ~= 'table' then return nil, { _form = 'Invalid form data.' } end

    local values, citizens, errors = {}, {}, {}
    local hasError = false

    for _, field in ipairs(template.fields) do
        local raw = input[field.name]
        local fieldType = field.type or 'text'
        local isEmpty = raw == nil or raw == '' or (type(raw) == 'string' and raw:match('^%s*$') ~= nil)

        if isEmpty then
            if field.required then
                errors[field.name] = 'This field is required.'
                hasError = true
            end
        elseif fieldType == 'text' or fieldType == 'textarea' then
            local text = el_CleanText(raw, fieldType == 'textarea')
            local maxLength = math.min(field.max or 255, Config.Security.MaxTextLength)
            if not text then
                errors[field.name] = 'Invalid text.'
                hasError = true
            elseif field.required and text == '' then
                errors[field.name] = 'This field is required.'
                hasError = true
            elseif field.min and el_Length(text) < field.min then
                errors[field.name] = ('Must be at least %d characters.'):format(field.min)
                hasError = true
            elseif el_Length(text) > maxLength then
                errors[field.name] = ('Must be at most %d characters.'):format(maxLength)
                hasError = true
            elseif text ~= '' then
                values[field.name] = text
            end
        elseif fieldType == 'number' then
            local number = tonumber(raw)
            if not number or number ~= number or number == math.huge or number == -math.huge then
                errors[field.name] = 'Enter a valid number.'
                hasError = true
            elseif field.min and number < field.min then
                errors[field.name] = ('Must be at least %s.'):format(field.min)
                hasError = true
            elseif field.max and number > field.max then
                errors[field.name] = ('Must be at most %s.'):format(field.max)
                hasError = true
            else
                values[field.name] = field.format == 'money' and el_Round(number, 2) or math.floor(number)
            end
        elseif fieldType == 'date' then
            if not el_ParseDate(raw) then
                errors[field.name] = 'Enter a valid date.'
                hasError = true
            else
                values[field.name] = raw
            end
        elseif fieldType == 'select' then
            if not el_TableContains(field.options, raw) then
                errors[field.name] = 'Select a valid option.'
                hasError = true
            else
                values[field.name] = raw
            end
        elseif fieldType == 'citizen' then
            local citizenid = type(raw) == 'string' and raw:gsub('%s', ''):upper() or nil
            local identity = citizenid and el_Bridge.Server.FindCitizen(citizenid)
            if not identity then
                errors[field.name] = 'Citizen not found.'
                hasError = true
            else
                values[field.name] = identity.citizenid
                citizens[field.name] = {
                    citizenid = identity.citizenid,
                    name = identity.name,
                    birthdate = identity.birthdate,
                    gender = identity.gender,
                    nationality = identity.nationality,
                }
            end
        end
    end

    if hasError then return nil, errors end
    return values, citizens
end

---------------------------------------------------------------------------------------------------
-- Building records and models
---------------------------------------------------------------------------------------------------

local function el_ResolveOrganization(template, identity)
    local org = template.organization
    if not org then return nil end
    if org == 'job' then
        if not identity.job or identity.job.name == 'unemployed' then return nil end
        return { label = identity.job.label, short = '', icon = 'fa-building', logo = nil }
    end
    local cfg = Config.Organizations[org]
    if not cfg then return nil end
    return { label = cfg.label, short = cfg.short or '', icon = cfg.icon or 'fa-building', logo = cfg.logo }
end

-- Builds the record (not yet stored). id is nil for previews.
function el_Docs.BuildRecord(docType, template, identity, values, citizens, printerId)
    local recipient, recipientCid = nil, nil
    for _, field in ipairs(template.fields) do
        if field.recipient and citizens[field.name] then
            recipient = citizens[field.name]
            recipientCid = recipient.citizenid
        end
    end
    if not recipient and template.recipientSelf then
        recipient = {
            citizenid = identity.citizenid,
            name = identity.name,
            birthdate = identity.birthdate,
            gender = identity.gender,
            nationality = identity.nationality,
        }
        recipientCid = identity.citizenid
    end

    local title = template.title
    if template.titleField and values[template.titleField] then
        title = values[template.titleField]
    end
    title = tostring(title or template.label):sub(1, 96)

    local now = os.time()
    return {
        id = nil,
        doc_type = docType,
        title = title,
        owner_cid = recipientCid or identity.citizenid,
        issuer_cid = identity.citizenid,
        issuer_name = identity.name,
        issuer_job = identity.job.name or '',
        issuer_job_label = identity.job.label or '',
        issuer_grade = identity.job.grade or 0,
        issuer_grade_label = identity.job.gradeLabel or '',
        recipient_cid = recipientCid,
        data = {
            values = values,
            citizens = citizens,
            recipient = recipient,
            organization = el_ResolveOrganization(template, identity),
        },
        status = 'active',
        print_count = 0,
        created_at = now,
        expires_at = template.expiresDays and (now + template.expiresDays * 86400) or nil,
        printer_id = printerId or '',
    }
end

function el_Docs.EffectiveStatus(doc)
    if doc.status == 'revoked' then return 'revoked' end
    if doc.expires_at and os.time() > doc.expires_at then return 'expired' end
    return 'active'
end

local el_StatusLabels = { active = 'Valid', revoked = 'Revoked', expired = 'Expired' }

-- Model used by the NUI renderer. Contains only display data.
function el_Docs.BuildModel(doc)
    local template = Config.DocumentTypes[doc.doc_type]
    if not template then return nil end
    local data = doc.data or {}
    local values = data.values or {}
    local citizens = data.citizens or {}

    local meta, body = {}, {}
    for _, field in ipairs(template.fields) do
        local value = values[field.name]
        if value ~= nil and not field.recipient and field.name ~= template.titleField then
            local display
            if field.type == 'citizen' then
                local citizen = citizens[field.name]
                display = citizen and ('%s (%s)'):format(citizen.name, citizen.citizenid) or tostring(value)
            elseif field.type == 'date' then
                display = el_FormatDate(el_ParseDate(value)) or tostring(value)
            elseif field.type == 'number' and field.format == 'money' then
                display = el_FormatMoney(value)
            else
                display = tostring(value)
            end
            local section = field.section or (field.type == 'textarea' and 'body' or 'meta')
            local entry = { key = field.name, label = field.label, value = display }
            if section == 'body' then body[#body + 1] = entry else meta[#meta + 1] = entry end
        end
    end

    local invoice = nil
    if template.layout == 'invoice' and template.invoice then
        local quantity = tonumber(values[template.invoice.quantityField]) or 0
        local price = tonumber(values[template.invoice.priceField]) or 0
        local subtotal = el_Round(quantity * price, 2)
        local taxPercent = tonumber(template.invoice.taxPercent) or 0
        local tax = el_Round(subtotal * taxPercent / 100, 2)
        invoice = {
            billTo = values.bill_to,
            description = values.description,
            quantity = quantity,
            unitPrice = el_FormatMoney(price),
            subtotal = el_FormatMoney(subtotal),
            taxPercent = taxPercent,
            tax = el_FormatMoney(tax),
            total = el_FormatMoney(subtotal + tax),
            dueDate = values.due_date and el_FormatDate(el_ParseDate(values.due_date)) or nil,
        }
        -- Invoice-specific fields are shown in the invoice table instead of the meta grid.
        local skip = { bill_to = true, description = true, due_date = true,
            [template.invoice.quantityField] = true, [template.invoice.priceField] = true }
        local filtered = {}
        for _, entry in ipairs(meta) do
            if not skip[entry.key] then filtered[#filtered + 1] = entry end
        end
        meta = filtered
    end

    local issuer = nil
    if template.showIssuer then
        issuer = { name = doc.issuer_name }
        if template.official then
            local position = doc.issuer_grade_label ~= '' and doc.issuer_grade_label or nil
            if doc.issuer_job_label ~= '' and doc.issuer_job ~= 'unemployed' then
                position = position and (position .. ', ' .. doc.issuer_job_label) or doc.issuer_job_label
            end
            issuer.position = position
        end
    end

    local status = el_Docs.EffectiveStatus(doc)
    return {
        id = doc.id or 'PENDING',
        pending = doc.id == nil,
        type = doc.doc_type,
        typeLabel = template.label,
        icon = template.icon,
        layout = template.layout or 'letter',
        official = template.official == true,
        title = doc.title,
        organization = data.organization,
        issuer = issuer,
        recipient = data.recipient,
        issuedAt = el_FormatDate(doc.created_at),
        expiresAt = el_FormatDate(doc.expires_at),
        status = status,
        statusLabel = el_StatusLabels[status],
        verification = template.verification == true,
        meta = meta,
        body = body,
        invoice = invoice,
        printCount = doc.print_count or 0,
        maxPrints = template.maxPrints,
    }
end

---------------------------------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------------------------------

local function el_RowToDoc(row)
    local data = row.data
    if type(data) == 'string' then
        local ok, decoded = pcall(json.decode, data)
        data = ok and decoded or {}
    end
    return {
        id = row.id,
        doc_type = row.doc_type,
        title = row.title,
        owner_cid = row.owner_cid,
        issuer_cid = row.issuer_cid,
        issuer_name = row.issuer_name,
        issuer_job = row.issuer_job or '',
        issuer_job_label = row.issuer_job_label or '',
        issuer_grade = tonumber(row.issuer_grade) or 0,
        issuer_grade_label = row.issuer_grade_label or '',
        recipient_cid = row.recipient_cid,
        data = data or {},
        status = row.status,
        print_count = tonumber(row.print_count) or 0,
        created_at = tonumber(row.created_at) or 0,
        expires_at = tonumber(row.expires_at),
        printer_id = row.printer_id or '',
    }
end

-- Stores a new record. Returns doc or nil, errorCode.
function el_Docs.Create(record)
    for _ = 1, 3 do
        local id = el_GenerateId('EL-', 8)
        if not el_Cache[id] then
            record.id = id
            if not el_Persistent() then
                el_CachePut(record)
                return record
            end

            local result = el_DB.Query([[
                INSERT INTO `el_printer_documents`
                    (`id`, `doc_type`, `title`, `owner_cid`, `issuer_cid`, `issuer_name`, `issuer_job`, `issuer_job_label`,
                     `issuer_grade`, `issuer_grade_label`, `recipient_cid`, `data`, `status`, `print_count`, `created_at`,
                     `expires_at`, `printer_id`)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]], {
                record.id, record.doc_type, record.title, record.owner_cid, record.issuer_cid, record.issuer_name,
                record.issuer_job, record.issuer_job_label, record.issuer_grade, record.issuer_grade_label,
                record.recipient_cid, json.encode(record.data), record.status, record.print_count, record.created_at,
                record.expires_at, record.printer_id,
            })
            if result then
                el_CachePut(record)
                return record
            end
            -- Retry once more with another ID only if the database is still reachable.
            if not el_DB.IsAvailable() then break end
        end
    end
    record.id = nil
    return nil, 'database_error'
end

-- Returns doc, or nil + errorCode ('document_not_found' | 'database_error').
function el_Docs.Get(id)
    if not el_Docs.IsValidId(id) then return nil, 'document_not_found' end
    local cached = el_Cache[id]
    if cached then return cached end
    if not el_Persistent() then return nil, 'document_not_found' end

    local rows = el_DB.Query('SELECT * FROM `el_printer_documents` WHERE `id` = ? LIMIT 1', { id })
    if not rows then return nil, 'database_error' end
    if not rows[1] then return nil, 'document_not_found' end
    local doc = el_RowToDoc(rows[1])
    el_CachePut(doc)
    return doc
end

-- Documents visible to the player: own, issued, and job-viewable types.
function el_Docs.ListFor(identity)
    local cid = identity.citizenid
    local viewTypes = el_Perm.ViewableTypes(identity)
    local limit = math.floor(Config.Persistence.DocumentListLimit)

    if not el_Persistent() then
        local list = {}
        for _, doc in pairs(el_Cache) do
            if doc.owner_cid == cid or doc.issuer_cid == cid or el_TableContains(viewTypes, doc.doc_type) then
                list[#list + 1] = doc
            end
        end
        table.sort(list, function(a, b) return a.created_at > b.created_at end)
        while #list > limit do table.remove(list) end
        return list
    end

    local sql = 'SELECT ' .. el_ListColumns .. ' FROM `el_printer_documents` WHERE `owner_cid` = ? OR `issuer_cid` = ?'
    local params = { cid, cid }
    if #viewTypes > 0 then
        local marks = {}
        for i = 1, #viewTypes do
            marks[i] = '?'
            params[#params + 1] = viewTypes[i]
        end
        sql = sql .. ' OR `doc_type` IN (' .. table.concat(marks, ', ') .. ')'
    end
    sql = sql .. ' ORDER BY `created_at` DESC LIMIT ?'
    params[#params + 1] = limit

    local rows = el_DB.Query(sql, params)
    if not rows then return nil, 'database_error' end
    local list = {}
    for i = 1, #rows do
        list[i] = el_RowToDoc(rows[i])
    end
    return list
end

-- Atomically reserves `copies` prints. Fails when the count changed meanwhile (concurrent reprint).
function el_Docs.AddPrints(doc, copies)
    local expected = doc.print_count
    if not el_Persistent() then
        if doc.print_count ~= expected or doc.status ~= 'active' then return false end
        doc.print_count = expected + copies
        return true
    end

    local result = el_DB.Query(
        'UPDATE `el_printer_documents` SET `print_count` = `print_count` + ? WHERE `id` = ? AND `print_count` = ? AND `status` = ?',
        { copies, doc.id, expected, 'active' })
    if not result or (tonumber(result.affectedRows) or 0) ~= 1 then
        -- Drop the cached copy so the next read reflects the database.
        el_Cache[doc.id] = nil
        return false
    end
    doc.print_count = expected + copies
    return true
end

function el_Docs.RemovePrints(doc, copies)
    doc.print_count = math.max(0, doc.print_count - copies)
    if el_Persistent() then
        el_DB.Query('UPDATE `el_printer_documents` SET `print_count` = GREATEST(`print_count` - ?, 0) WHERE `id` = ?',
            { copies, doc.id })
    end
end

function el_Docs.Revoke(doc)
    if el_Persistent() then
        local result = el_DB.Query('UPDATE `el_printer_documents` SET `status` = ? WHERE `id` = ?', { 'revoked', doc.id })
        if not result then return false, 'database_error' end
    end
    doc.status = 'revoked'
    return true
end

-- Item metadata for one printed copy.
function el_Docs.ItemMetadata(doc, copy)
    local template = Config.DocumentTypes[doc.doc_type]
    local metadata = {
        el_document_id = doc.id,
        el_copy = copy,
        label = ('%s'):format(doc.title),
        description = ('%s | Ref %s | Copy %d'):format(template and template.label or 'Document', doc.id, copy),
    }
    -- Without a database the record disappears on restart, so keep a snapshot in the item.
    if not el_Persistent() then
        metadata.el_snapshot = el_Docs.BuildModel(doc)
    end
    return metadata
end
