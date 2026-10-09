--[[
    Server-side permission checks. Always fed with identity data from the framework bridge,
    never with values sent by the client.
]]

el_Perm = {}

local function el_JobEntry(identity)
    local job = identity and identity.job
    if not job then return nil end
    local entry = Config.Jobs[job.name]
    if not entry then return nil end
    if entry.requireDuty and not job.onduty then return nil end
    return entry
end

local function el_Grants(value, grade)
    if value == nil or value == false then return false end
    if value == true then return true end
    return grade >= (tonumber(value) or math.huge)
end

-- action: 'create' | 'view' | 'reprint' | 'revoke'
function el_Perm.HasDocument(identity, docType, action)
    if not identity then return false end

    local everyone = Config.Jobs['*']
    local everyoneDoc = everyone and everyone.documents and everyone.documents[docType]
    if everyoneDoc and everyoneDoc[action] ~= nil and everyoneDoc[action] ~= false then
        return true
    end

    local entry = el_JobEntry(identity)
    local jobDoc = entry and entry.documents and entry.documents[docType]
    return jobDoc ~= nil and el_Grants(jobDoc[action], identity.job.grade)
end

-- action: 'access' | 'refill' | 'maintain' | 'place' | 'remove'
function el_Perm.HasPrinter(identity, action)
    if not identity then return false end

    local everyone = Config.Jobs['*']
    if everyone and everyone.printer and everyone.printer[action] ~= nil and everyone.printer[action] ~= false then
        return true
    end

    local entry = el_JobEntry(identity)
    return entry ~= nil and entry.printer ~= nil and el_Grants(entry.printer[action], identity.job.grade)
end

-- Document types the player may view beyond their own documents.
function el_Perm.ViewableTypes(identity)
    local types = {}
    for docType in pairs(Config.DocumentTypes) do
        local entry = el_JobEntry(identity)
        local jobDoc = entry and entry.documents and entry.documents[docType]
        if jobDoc and el_Grants(jobDoc.view, identity.job.grade) then
            types[#types + 1] = docType
        end
    end
    table.sort(types)
    return types
end

-- Can this player open the given printer at all?
function el_Perm.CanAccessPrinter(identity, printer)
    if not identity or not printer then return false end

    if printer.kind == 'placed' then
        local mode = Config.Placement.Access
        if mode == 'owner' then
            return printer.owner == identity.citizenid
        elseif mode == 'job' then
            return printer.owner == identity.citizenid
                or (printer.ownerJob ~= '' and printer.ownerJob == identity.job.name)
        end
        return true
    end

    if not printer.jobs then return true end
    local minGrade = printer.jobs[identity.job.name]
    if minGrade == nil then return false end
    local entry = Config.Jobs[identity.job.name]
    if entry and entry.requireDuty and not identity.job.onduty then return false end
    return identity.job.grade >= (tonumber(minGrade) or 0)
end

function el_Perm.PrinterAllowsType(printer, docType)
    if not Config.DocumentTypes[docType] then return false end
    if not printer.documents then return true end
    return el_TableContains(printer.documents, docType)
end

function el_Perm.CanRemovePrinter(identity, printer)
    if not identity or not printer or printer.kind ~= 'placed' then return false end
    if Config.Placement.OwnerCanRemove and printer.owner == identity.citizenid then return true end
    local entry = el_JobEntry(identity)
    return entry ~= nil and entry.printer ~= nil and el_Grants(entry.printer.remove, identity.job.grade)
end

function el_Perm.CanMaintain(identity, printer)
    if not Config.Maintenance.MaintenanceMode and not Config.Maintenance.Repair.Enabled then return false end
    if printer and printer.kind == 'placed' and printer.owner == identity.citizenid then return true end
    return el_Perm.HasPrinter(identity, 'maintain')
end

-- Document-level checks ---------------------------------------------------------------------------

function el_Perm.CanViewDocument(identity, doc)
    if not identity or not doc then return false end
    if doc.owner_cid == identity.citizenid or doc.issuer_cid == identity.citizenid then return true end
    return el_Perm.HasDocument(identity, doc.doc_type, 'view')
end

-- First print: the issuer. Later prints: owner (when allowed by the template) or a reprint permission.
function el_Perm.CanPrintDocument(identity, doc)
    local template = Config.DocumentTypes[doc.doc_type]
    if not template or not identity then return false end

    if doc.print_count == 0 and doc.issuer_cid == identity.citizenid then
        return true
    end

    if doc.owner_cid == identity.citizenid and template.ownerCanReprint then
        return true
    end

    if doc.issuer_cid == identity.citizenid and el_Perm.HasDocument(identity, doc.doc_type, 'create') then
        return true
    end

    return el_Perm.HasDocument(identity, doc.doc_type, 'reprint')
        and el_Perm.CanViewDocument(identity, doc)
end

function el_Perm.CanRevokeDocument(identity, doc)
    if not identity or not doc then return false end
    return el_Perm.HasDocument(identity, doc.doc_type, 'revoke')
end
