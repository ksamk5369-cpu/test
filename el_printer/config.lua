--[[
    el_printer - Empire Line Printer System
    Main configuration file.

    Everything a server owner is expected to tune lives in this file.
    Values are read on resource start, so restart the resource after changes.
]]

Config = {}

-- Prints verbose diagnostic messages to the client F8 console and the server console.
Config.Debug = false

---------------------------------------------------------------------------------------------------
-- Integrations
---------------------------------------------------------------------------------------------------

-- Only 'qb-core' is supported. The bridge isolates every framework call, so another framework
-- can be added by extending bridge/client/framework.lua and bridge/server/framework.lua.
Config.Framework = 'qb-core'

-- 'auto' picks the first started resource in this order: ox_target, qb-target.
-- Force a specific one with 'qb-target' or 'ox_target'.
Config.Target = 'auto'

-- 'auto' picks ox_inventory when it is started, otherwise qb-inventory.
-- Force a specific one with 'qb-inventory' or 'ox_inventory'.
Config.Inventory = 'auto'

-- Notification provider:
--   'el'  - Empire Line toast rendered by this resource's NUI (default, matches the UI design)
--   'qb'  - QBCore.Functions.Notify
--   'ox'  - ox_lib notifications (ox_lib must be started)
Config.Notify = 'el'

-- Duration of notifications in milliseconds.
Config.NotifyDuration = 4500

---------------------------------------------------------------------------------------------------
-- Items (names must match the items registered in your inventory)
---------------------------------------------------------------------------------------------------

Config.Items = {
    Printer = 'printer',            -- Used to place a printer (when placement is enabled)
    Paper = 'printer_paper',        -- Loaded into a printer to add paper sheets
    Ink = 'printer_ink',            -- Loaded into a printer to add ink
    Document = 'printer_document',  -- Granted to the player when a document is printed
}

---------------------------------------------------------------------------------------------------
-- Printer models
---------------------------------------------------------------------------------------------------

Config.Models = {
    -- Default model for fixed printers with spawnProp = true and for placeable printers.
    Default = 'prop_printer_01',
}

---------------------------------------------------------------------------------------------------
-- Fixed printers
---------------------------------------------------------------------------------------------------
--[[
    Each key is the unique printer ID. Fields:
      label           Display name shown in the dashboard.
      coords          vector4(x, y, z, heading). Heading is optional (vector3 is accepted).
      spawnProp       true = spawn Config.Models.Default (or 'model') at the coordinates.
                      false = target an existing map prop or location.
      model           Optional model override when spawnProp = true.
      jobs            nil = everyone may use it. Otherwise { jobName = minimumGrade }.
      documents       nil = every document type is allowed. Otherwise a list of type keys.
      usePaper        Consume paper on this printer.
      useInk          Consume ink on this printer.
      durationMultiplier  Multiplies the printing duration (1.0 = normal).
      distance        Maximum interaction distance in metres.
      zoneSize        Size of the interaction zone when no prop is spawned (vector3 length/width/height).
      enabled         false disables the printer entirely.
]]
Config.Printers = {
    mrpd_records = {
        label = 'MRPD Records Printer',
        coords = vector4(441.21, -978.62, 30.69, 180.0),
        spawnProp = true,
        jobs = { police = 0 },
        documents = { 'police_report', 'driver_license', 'weapon_license', 'general' },
        usePaper = true,
        useInk = true,
        durationMultiplier = 1.0,
        distance = 2.0,
        zoneSize = vector3(1.0, 1.0, 1.2),
        enabled = true,
    },

    pillbox_records = {
        label = 'Pillbox Medical Records',
        coords = vector4(309.91, -594.38, 43.28, 340.0),
        spawnProp = true,
        jobs = { ambulance = 0 },
        documents = { 'medical_report', 'general' },
        usePaper = true,
        useInk = true,
        durationMultiplier = 1.0,
        distance = 2.0,
        zoneSize = vector3(1.0, 1.0, 1.2),
        enabled = true,
    },

    city_hall = {
        label = 'City Hall Document Office',
        coords = vector4(-262.73, -965.05, 31.22, 205.0),
        spawnProp = true,
        jobs = nil,
        documents = nil,
        usePaper = true,
        useInk = true,
        durationMultiplier = 1.0,
        distance = 2.0,
        zoneSize = vector3(1.0, 1.0, 1.2),
        enabled = true,
    },

    legion_print_shop = {
        label = 'Legion Print Shop',
        coords = vector4(195.17, -933.68, 30.69, 145.0),
        spawnProp = true,
        jobs = nil,
        documents = { 'general', 'personal', 'invoice', 'contract', 'business' },
        usePaper = true,
        useInk = true,
        durationMultiplier = 1.2,
        distance = 2.0,
        zoneSize = vector3(1.0, 1.0, 1.2),
        enabled = true,
    },
}

---------------------------------------------------------------------------------------------------
-- Placeable printers
---------------------------------------------------------------------------------------------------

Config.Placement = {
    Enabled = true,
    Model = 'prop_printer_01',
    Label = 'Portable Printer',

    -- Maximum distance between the player and the placement point.
    MaxDistance = 4.0,
    -- Maximum vertical difference between the player and the placement point.
    MaxHeightDifference = 2.5,
    -- Minimum distance between two printers (fixed or placed).
    MinSpacing = 1.5,
    -- Maximum printers a single character may own (0 = unlimited).
    MaxPerPlayer = 2,
    -- Maximum placed printers on the whole server (0 = unlimited).
    MaxTotal = 150,
    -- Only allow placement inside these routing buckets.
    AllowedRoutingBuckets = { 0 },
    -- Placement is refused inside these spheres.
    BlockedZones = {
        { coords = vector3(441.0, -982.0, 30.7), radius = 25.0 },   -- Mission Row PD lobby
        { coords = vector3(298.0, -584.0, 43.3), radius = 25.0 },   -- Pillbox Hill Medical
    },

    -- Who can open the dashboard of a placed printer:
    --   'public' everyone, 'owner' only the owner, 'job' the owner and members of the owner's job.
    Access = 'public',
    -- Document types available on placed printers (nil = every type).
    Documents = { 'general', 'personal', 'invoice', 'contract', 'business' },
    UsePaper = true,
    UseInk = true,
    DurationMultiplier = 1.0,
    Distance = 2.0,

    -- Starting supplies of a freshly placed printer.
    StartPaper = 0,
    StartInk = 0,

    -- The owner can always pick up their own printer.
    OwnerCanRemove = true,
    -- Give the printer item back when the printer is removed.
    ReturnItemOnRemove = true,

    -- Placed printers are spawned when the player is within this distance.
    StreamDistance = 80.0,

    -- Placement controls (FiveM control IDs).
    Controls = {
        Confirm = 38,       -- E
        Cancel = 177,       -- Backspace / Escape / Right click
        RotateLeft = 174,   -- Arrow left
        RotateRight = 175,  -- Arrow right
    },
    RotateStep = 2.5,
    -- Seconds before an unfinished placement is cancelled automatically.
    Timeout = 60,
}

---------------------------------------------------------------------------------------------------
-- Printing
---------------------------------------------------------------------------------------------------

Config.Printing = {
    -- Base time for one print job in milliseconds.
    BaseDuration = 6000,
    -- Extra time per additional copy in milliseconds.
    PerCopyDuration = 2500,
    -- Maximum copies per print job.
    MaxCopies = 5,

    Queue = {
        Enabled = true,
        MaxSize = 5,        -- Jobs waiting per printer
        MaxPerPlayer = 2,   -- Jobs (waiting + active) per player across all printers
    },

    -- The player must stay close to the printer until the job is complete.
    RequirePresence = true,
    -- Allowed distance while printing = printer distance * this multiplier.
    PresenceDistanceMultiplier = 3.0,

    -- Extra time after the expected end before a job is considered stuck and is failed safely.
    TimeoutGrace = 15000,

    -- How often (ms) the server sends real progress updates to the client.
    ProgressInterval = 1000,

    -- Money account used for printing costs ('cash' or 'bank').
    Account = 'cash',
}

---------------------------------------------------------------------------------------------------
-- Supplies
---------------------------------------------------------------------------------------------------

Config.Supplies = {
    Paper = {
        Enabled = true,
        Max = 200,          -- Sheets a printer can hold
        PerItem = 50,       -- Sheets added by one paper item
        LowThreshold = 20,  -- Low-paper warning
        Default = 120,      -- Starting stock of fixed printers
    },
    Ink = {
        Enabled = true,
        Max = 100,          -- Ink units a printer can hold (shown as a percentage)
        PerItem = 40,       -- Ink units added by one ink item
        LowThreshold = 15,
        Default = 80,
    },
}

---------------------------------------------------------------------------------------------------
-- Maintenance
---------------------------------------------------------------------------------------------------

Config.Maintenance = {
    Durability = {
        Enabled = true,
        Max = 100,
        PerCopy = 0.5,      -- Durability lost per printed copy
        LowThreshold = 20,
        Default = 100,
    },
    -- Allow authorized players to toggle maintenance mode (blocks printing).
    MaintenanceMode = true,
    Repair = {
        Enabled = true,
        Cost = 250,             -- 0 = free
        Account = 'cash',
        Duration = 10000,       -- Downtime in ms while the printer is repaired
    },
}

---------------------------------------------------------------------------------------------------
-- Persistence (requires oxmysql)
---------------------------------------------------------------------------------------------------

Config.Persistence = {
    -- When disabled or oxmysql is missing, documents and placed printers live in memory only
    -- and are lost on restart. The dashboard clearly shows "Session Storage" in that case.
    Enabled = true,
    -- Create the tables automatically on start (sql/el_printer.sql contains the same schema).
    AutoCreateTables = true,
    -- Database operations taking longer than this (ms) are treated as failures.
    QueryTimeout = 10000,
    -- Maximum saved documents returned to the dashboard.
    DocumentListLimit = 60,
}

---------------------------------------------------------------------------------------------------
-- Sounds and animations
---------------------------------------------------------------------------------------------------

Config.Sounds = {
    Enabled = true,
    -- Printing sound synthesized by the NUI (no audio files required). Volume 0.0 - 1.0.
    Printing = true,
    Volume = 0.25,
    -- GTA frontend sounds.
    Complete = { name = 'PICK_UP', set = 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    Error = { name = 'ERROR', set = 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
}

Config.Animations = {
    Enabled = true,
    Printing = {
        dict = 'anim@heists@prison_heiststation@cop_reactions',
        clip = 'cop_b_idle',
        flag = 49,
    },
    Placement = {
        dict = 'pickup_object',
        clip = 'pickup_low',
        duration = 1200,
    },
}

---------------------------------------------------------------------------------------------------
-- Security
---------------------------------------------------------------------------------------------------

Config.Security = {
    -- Extra metres allowed on top of the printer distance (network latency / desync).
    DistanceTolerance = 1.5,

    -- Global request limit per player.
    RateLimit = {
        Window = 10000,
        MaxRequests = 40,
    },

    -- Minimum time between two calls of the same action per player (ms).
    Cooldowns = {
        openPrinter = 750,
        getDashboard = 500,
        getDocument = 250,
        previewDocument = 750,
        createDocument = 3000,
        print = 1500,
        cancelJob = 750,
        refill = 750,
        setMaintenance = 1500,
        repair = 3000,
        revokeDocument = 2000,
        placePrinter = 3000,
        removePrinter = 2000,
        showDocument = 3000,
    },

    -- Hard limit for any text value sent from the UI.
    MaxTextLength = 2000,
}

---------------------------------------------------------------------------------------------------
-- Organizations (letterheads)
---------------------------------------------------------------------------------------------------
-- 'logo' is an optional image URL (https://... or nui://el_printer/html/img/<file>.png).
-- When no logo is set, the Font Awesome 'icon' is used as an emblem.

Config.Organizations = {
    lspd = { label = 'Los Santos Police Department', short = 'LSPD', icon = 'fa-shield-halved', logo = nil },
    ems = { label = 'Pillbox Hill Medical Center', short = 'PHMC', icon = 'fa-staff-snake', logo = nil },
    government = { label = 'State of San Andreas', short = 'SA GOV', icon = 'fa-landmark', logo = nil },
    dmv = { label = 'San Andreas Department of Motor Vehicles', short = 'DMV', icon = 'fa-id-card', logo = nil },
}

---------------------------------------------------------------------------------------------------
-- Jobs and permissions
---------------------------------------------------------------------------------------------------
--[[
    Every value is a minimum job grade. A missing value (nil) or false means "not allowed".

    documents[type].create   Create (and first print) the document type.
    documents[type].view     View every document of that type, not only your own.
    documents[type].reprint  Reprint documents of that type (owners may also reprint when the
                             template sets ownerCanReprint = true).
    documents[type].revoke   Revoke documents of that type.

    printer.access    Open job-restricted printers that list this job.
    printer.refill    Load paper and ink.
    printer.maintain  Toggle maintenance mode and repair printers.
    printer.place     Place portable printers.
    printer.remove    Remove any placed printer (owners can always remove their own).

    requireDuty       The player must be on duty for job permissions to apply.

    The '*' entry applies to every player, including civilians. Its values only need to be
    non-nil numbers (grades are not checked for '*').
]]
Config.Jobs = {
    ['*'] = {
        documents = {
            general = { create = 0, reprint = 0 },
            personal = { create = 0, reprint = 0 },
        },
        printer = { refill = 0, place = 0 },
    },

    police = {
        requireDuty = true,
        documents = {
            police_report = { create = 0, view = 0, reprint = 1, revoke = 3 },
            driver_license = { create = 1, view = 0, reprint = 1, revoke = 2 },
            weapon_license = { create = 3, view = 0, reprint = 3, revoke = 3 },
            general = { create = 0 },
        },
        printer = { access = 0, refill = 0, maintain = 2, place = 2, remove = 3 },
    },

    ambulance = {
        requireDuty = true,
        documents = {
            medical_report = { create = 0, view = 1, reprint = 1, revoke = 3 },
            general = { create = 0 },
        },
        printer = { access = 0, refill = 0, maintain = 2, place = 2, remove = 3 },
    },

    judge = {
        requireDuty = false,
        documents = {
            government = { create = 0, view = 0, reprint = 0, revoke = 0 },
            driver_license = { create = 0, view = 0, reprint = 0, revoke = 0 },
            weapon_license = { create = 0, view = 0, reprint = 0, revoke = 0 },
            contract = { create = 0 },
        },
        printer = { access = 0, refill = 0, maintain = 0, remove = 0 },
    },

    government = {
        requireDuty = false,
        documents = {
            government = { create = 0, view = 0, reprint = 0, revoke = 2 },
            driver_license = { create = 1, view = 0, reprint = 1, revoke = 2 },
            weapon_license = { create = 2, view = 0, reprint = 2, revoke = 2 },
        },
        printer = { access = 0, refill = 0, maintain = 1, remove = 2 },
    },

    lawyer = {
        requireDuty = false,
        documents = {
            contract = { create = 0, view = 2, reprint = 0 },
            business = { create = 0 },
        },
        printer = { access = 0, refill = 0 },
    },

    -- Business employees: invoices, contracts and business documents.
    mechanic = {
        requireDuty = false,
        documents = {
            invoice = { create = 0, view = 2, reprint = 0 },
            contract = { create = 1 },
            business = { create = 1 },
        },
        printer = { access = 0, refill = 0, maintain = 2 },
    },

    cardealer = {
        requireDuty = false,
        documents = {
            invoice = { create = 0, view = 2, reprint = 0 },
            contract = { create = 0, view = 2, reprint = 0 },
            business = { create = 1 },
        },
        printer = { access = 0, refill = 0, maintain = 2 },
    },

    realestate = {
        requireDuty = false,
        documents = {
            invoice = { create = 0, view = 2, reprint = 0 },
            contract = { create = 0, view = 2, reprint = 0 },
            business = { create = 1 },
        },
        printer = { access = 0, refill = 0, maintain = 2 },
    },
}

---------------------------------------------------------------------------------------------------
-- Document templates
---------------------------------------------------------------------------------------------------
--[[
    Template fields:
      label, description, icon (Font Awesome), category
      layout          'letter' | 'official' | 'license' | 'report' | 'invoice' | 'contract'
      official        true = the issuer identity and organization are always stamped by the server.
      organization    Key of Config.Organizations, 'job' (issuer's job label) or nil.
      showIssuer      Print the issuer name and position on the document.
      title           Static title, or titleField = '<field name>' to use a field value.
      fields          Form fields (see below).
      cost            Price per copy (0 = free). account overrides Config.Printing.Account.
      paper / ink     Sheets / ink units consumed per copy.
      duration        Optional base duration override (ms).
      maxPrints       Total copies that may ever be printed (nil = unlimited).
      ownerCanReprint The document owner may reprint without a job permission.
      expiresDays     Expiry date relative to the issue date (nil = no expiry).
      verification    Show the verification status when the printed document is inspected.
      recipientSelf   The creator is also the recipient and owner (personal documents).

    Field definition:
      name, label, type ('text' | 'textarea' | 'number' | 'date' | 'select' | 'citizen'),
      required, min / max (length for text, value for number), options (select),
      placeholder, section ('meta' | 'body'), recipient = true (citizen field that sets the owner),
      format = 'money' (number fields).

    invoice layout: invoice = { quantityField = 'quantity', priceField = 'unit_price', taxPercent = 0 }
]]
Config.DocumentTypes = {
    general = {
        label = 'General Document',
        description = 'Letters, notes and notices for everyday use.',
        icon = 'fa-file-lines',
        category = 'General',
        layout = 'letter',
        official = false,
        organization = nil,
        showIssuer = true,
        titleField = 'title',
        fields = {
            { name = 'title', label = 'Title', type = 'text', required = true, min = 3, max = 64, placeholder = 'Document title' },
            { name = 'addressed_to', label = 'Addressed To', type = 'text', required = false, max = 64, placeholder = 'Optional recipient name' },
            { name = 'body', label = 'Content', type = 'textarea', required = true, min = 10, max = 1500, section = 'body', placeholder = 'Write the content of the document' },
        },
        cost = 10,
        paper = 1,
        ink = 1,
        maxPrints = nil,
        ownerCanReprint = true,
        verification = false,
    },

    personal = {
        label = 'Personal Document',
        description = 'Personal statements, declarations and records issued in your own name.',
        icon = 'fa-user-pen',
        category = 'General',
        layout = 'letter',
        official = false,
        organization = nil,
        showIssuer = true,
        recipientSelf = true,
        titleField = 'title',
        fields = {
            { name = 'title', label = 'Title', type = 'text', required = true, min = 3, max = 64, placeholder = 'e.g. Personal Statement' },
            { name = 'body', label = 'Statement', type = 'textarea', required = true, min = 10, max = 1500, section = 'body' },
        },
        cost = 10,
        paper = 1,
        ink = 1,
        maxPrints = nil,
        ownerCanReprint = true,
        verification = true,
    },

    government = {
        label = 'Government Document',
        description = 'Official notices, permits and decisions of the State of San Andreas.',
        icon = 'fa-landmark',
        category = 'Official',
        layout = 'official',
        official = true,
        organization = 'government',
        showIssuer = true,
        titleField = 'title',
        fields = {
            { name = 'title', label = 'Title', type = 'text', required = true, min = 3, max = 64 },
            { name = 'recipient', label = 'Recipient Citizen ID', type = 'citizen', required = false, recipient = true, placeholder = 'Leave empty for a public notice' },
            { name = 'subject', label = 'Subject', type = 'text', required = true, min = 3, max = 96 },
            { name = 'body', label = 'Content', type = 'textarea', required = true, min = 10, max = 1800, section = 'body' },
        },
        cost = 0,
        paper = 1,
        ink = 2,
        maxPrints = 10,
        ownerCanReprint = false,
        verification = true,
    },

    driver_license = {
        label = 'Driver License',
        description = 'Official San Andreas driving permit bound to a citizen.',
        icon = 'fa-id-card',
        category = 'Licenses',
        layout = 'license',
        official = true,
        organization = 'dmv',
        showIssuer = true,
        title = 'Driver License',
        fields = {
            { name = 'recipient', label = 'Citizen ID', type = 'citizen', required = true, recipient = true },
            { name = 'class', label = 'License Class', type = 'select', required = true, options = { 'Class A - Motorcycle', 'Class B - Car', 'Class C - Commercial', 'Class D - Heavy Vehicle' } },
            { name = 'restrictions', label = 'Restrictions', type = 'text', required = false, max = 64, placeholder = 'e.g. Corrective lenses' },
        },
        cost = 150,
        paper = 1,
        ink = 3,
        maxPrints = 3,
        ownerCanReprint = false,
        expiresDays = 365,
        verification = true,
    },

    weapon_license = {
        label = 'Weapon License',
        description = 'Firearm permit issued by law enforcement.',
        icon = 'fa-gun',
        category = 'Licenses',
        layout = 'license',
        official = true,
        organization = 'lspd',
        showIssuer = true,
        title = 'Weapon License',
        fields = {
            { name = 'recipient', label = 'Citizen ID', type = 'citizen', required = true, recipient = true },
            { name = 'category', label = 'Category', type = 'select', required = true, options = { 'Handgun', 'Long Gun', 'Concealed Carry', 'Security Services' } },
            { name = 'notes', label = 'Conditions', type = 'text', required = false, max = 64 },
        },
        cost = 500,
        paper = 1,
        ink = 3,
        maxPrints = 2,
        ownerCanReprint = false,
        expiresDays = 180,
        verification = true,
    },

    invoice = {
        label = 'Invoice',
        description = 'Itemised invoice issued on behalf of your business.',
        icon = 'fa-file-invoice-dollar',
        category = 'Business',
        layout = 'invoice',
        official = true,
        organization = 'job',
        showIssuer = true,
        title = 'Invoice',
        fields = {
            { name = 'bill_to', label = 'Bill To', type = 'text', required = true, min = 2, max = 64 },
            { name = 'description', label = 'Service / Product', type = 'text', required = true, min = 2, max = 96 },
            { name = 'quantity', label = 'Quantity', type = 'number', required = true, min = 1, max = 999 },
            { name = 'unit_price', label = 'Unit Price', type = 'number', required = true, min = 0, max = 1000000, format = 'money' },
            { name = 'due_date', label = 'Due Date', type = 'date', required = false },
            { name = 'notes', label = 'Notes', type = 'textarea', required = false, max = 400, section = 'body' },
        },
        invoice = { quantityField = 'quantity', priceField = 'unit_price', taxPercent = 0 },
        cost = 5,
        paper = 1,
        ink = 2,
        maxPrints = nil,
        ownerCanReprint = true,
        verification = true,
    },

    contract = {
        label = 'Contract',
        description = 'Binding agreement between you and another citizen.',
        icon = 'fa-file-signature',
        category = 'Business',
        layout = 'contract',
        official = false,
        organization = 'job',
        showIssuer = true,
        titleField = 'title',
        fields = {
            { name = 'title', label = 'Contract Title', type = 'text', required = true, min = 3, max = 64 },
            { name = 'recipient', label = 'Second Party Citizen ID', type = 'citizen', required = true, recipient = true },
            { name = 'effective', label = 'Effective Date', type = 'date', required = true },
            { name = 'ends', label = 'End Date', type = 'date', required = false },
            { name = 'value', label = 'Contract Value', type = 'number', required = false, min = 0, max = 100000000, format = 'money' },
            { name = 'terms', label = 'Terms and Conditions', type = 'textarea', required = true, min = 20, max = 2000, section = 'body' },
        },
        cost = 25,
        paper = 2,
        ink = 2,
        maxPrints = 6,
        ownerCanReprint = true,
        verification = true,
    },

    business = {
        label = 'Business Document',
        description = 'Letterhead correspondence on behalf of your employer.',
        icon = 'fa-briefcase',
        category = 'Business',
        layout = 'official',
        official = true,
        organization = 'job',
        showIssuer = true,
        titleField = 'title',
        fields = {
            { name = 'title', label = 'Title', type = 'text', required = true, min = 3, max = 64 },
            { name = 'addressed_to', label = 'Addressed To', type = 'text', required = false, max = 64 },
            { name = 'subject', label = 'Subject', type = 'text', required = true, min = 3, max = 96 },
            { name = 'body', label = 'Content', type = 'textarea', required = true, min = 10, max = 1800, section = 'body' },
        },
        cost = 10,
        paper = 1,
        ink = 2,
        maxPrints = nil,
        ownerCanReprint = true,
        verification = true,
    },

    police_report = {
        label = 'Police Report',
        description = 'Incident report filed by a sworn officer.',
        icon = 'fa-file-shield',
        category = 'Reports',
        layout = 'report',
        official = true,
        organization = 'lspd',
        showIssuer = true,
        title = 'Incident Report',
        fields = {
            { name = 'incident', label = 'Incident Type', type = 'select', required = true, options = { 'Traffic Incident', 'Theft', 'Assault', 'Burglary', 'Vandalism', 'Narcotics', 'Disturbance', 'Other' } },
            { name = 'location', label = 'Location', type = 'text', required = true, min = 3, max = 80 },
            { name = 'occurred', label = 'Date of Incident', type = 'date', required = true },
            { name = 'subject', label = 'Subject Citizen ID', type = 'citizen', required = false },
            { name = 'involved', label = 'Involved Parties', type = 'textarea', required = false, max = 400, section = 'body' },
            { name = 'narrative', label = 'Narrative', type = 'textarea', required = true, min = 20, max = 2000, section = 'body' },
        },
        cost = 0,
        paper = 2,
        ink = 2,
        maxPrints = 10,
        ownerCanReprint = false,
        verification = true,
    },

    medical_report = {
        label = 'Medical Report',
        description = 'Patient examination and treatment record.',
        icon = 'fa-notes-medical',
        category = 'Reports',
        layout = 'report',
        official = true,
        organization = 'ems',
        showIssuer = true,
        title = 'Medical Report',
        fields = {
            { name = 'recipient', label = 'Patient Citizen ID', type = 'citizen', required = true, recipient = true },
            { name = 'examined', label = 'Examination Date', type = 'date', required = true },
            { name = 'diagnosis', label = 'Diagnosis', type = 'text', required = true, min = 3, max = 120 },
            { name = 'treatment', label = 'Treatment', type = 'textarea', required = true, min = 5, max = 1000, section = 'body' },
            { name = 'notes', label = 'Physician Notes', type = 'textarea', required = false, max = 800, section = 'body' },
            { name = 'follow_up', label = 'Follow-up Date', type = 'date', required = false },
        },
        cost = 0,
        paper = 1,
        ink = 2,
        maxPrints = 5,
        ownerCanReprint = true,
        verification = true,
    },
}

-- Display order of the document types in the dashboard.
Config.DocumentOrder = {
    'general', 'personal', 'government', 'driver_license', 'weapon_license',
    'invoice', 'contract', 'business', 'police_report', 'medical_report',
}
