--[[
    Database layer (oxmysql through exports, so the resource still starts without oxmysql).
    Every query is parameterized. Failures return nil plus an error string and are never
    reported as success.
]]

el_DB = {}

local el_Ready = false

function el_DB.IsEnabled()
    return Config.Persistence.Enabled == true
end

function el_DB.IsAvailable()
    return el_DB.IsEnabled() and GetResourceState('oxmysql') == 'started'
end

function el_DB.IsReady()
    return el_Ready and el_DB.IsAvailable()
end

-- Runs a query and waits for the result. Returns result or nil, errorMessage.
function el_DB.Query(sql, params)
    if not el_DB.IsAvailable() then
        return nil, 'oxmysql unavailable'
    end

    local p = promise.new()
    local finished = false

    local ok, err = pcall(function()
        exports.oxmysql:query(sql, params or {}, function(result, queryError)
            if finished then return end
            finished = true
            if queryError then
                p:resolve({ ok = false, err = tostring(queryError) })
            elseif result == nil then
                p:resolve({ ok = false, err = 'query failed' })
            else
                p:resolve({ ok = true, result = result })
            end
        end, el_RESOURCE, true)
    end)

    if not ok then
        return nil, tostring(err)
    end

    SetTimeout(Config.Persistence.QueryTimeout, function()
        if finished then return end
        finished = true
        p:resolve({ ok = false, err = 'query timeout' })
    end)

    local response = Citizen.Await(p)
    if not response.ok then
        el_Warn(('Database error: %s | %s'):format(response.err, sql:sub(1, 120)))
        return nil, response.err
    end
    return response.result
end

-- Fire-and-forget write (used for non-critical state saves). Errors are logged.
function el_DB.Execute(sql, params)
    if not el_DB.IsAvailable() then return end
    CreateThread(function()
        el_DB.Query(sql, params)
    end)
end

local el_Schema = {
    [[
    CREATE TABLE IF NOT EXISTS `el_printer_documents` (
        `id` VARCHAR(16) NOT NULL,
        `doc_type` VARCHAR(40) NOT NULL,
        `title` VARCHAR(96) NOT NULL,
        `owner_cid` VARCHAR(16) NOT NULL,
        `issuer_cid` VARCHAR(16) NOT NULL,
        `issuer_name` VARCHAR(96) NOT NULL,
        `issuer_job` VARCHAR(50) NOT NULL DEFAULT '',
        `issuer_job_label` VARCHAR(80) NOT NULL DEFAULT '',
        `issuer_grade` INT NOT NULL DEFAULT 0,
        `issuer_grade_label` VARCHAR(80) NOT NULL DEFAULT '',
        `recipient_cid` VARCHAR(16) DEFAULT NULL,
        `data` LONGTEXT NOT NULL,
        `status` VARCHAR(16) NOT NULL DEFAULT 'active',
        `print_count` INT NOT NULL DEFAULT 0,
        `created_at` BIGINT NOT NULL,
        `expires_at` BIGINT DEFAULT NULL,
        `printer_id` VARCHAR(48) NOT NULL DEFAULT '',
        PRIMARY KEY (`id`),
        KEY `idx_el_owner` (`owner_cid`),
        KEY `idx_el_issuer` (`issuer_cid`),
        KEY `idx_el_type_created` (`doc_type`, `created_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]],
    [[
    CREATE TABLE IF NOT EXISTS `el_printer_placed` (
        `id` VARCHAR(16) NOT NULL,
        `label` VARCHAR(64) NOT NULL,
        `model` VARCHAR(64) NOT NULL,
        `x` DOUBLE NOT NULL,
        `y` DOUBLE NOT NULL,
        `z` DOUBLE NOT NULL,
        `heading` DOUBLE NOT NULL DEFAULT 0,
        `owner_cid` VARCHAR(16) NOT NULL,
        `owner_job` VARCHAR(50) NOT NULL DEFAULT '',
        `created_at` BIGINT NOT NULL,
        PRIMARY KEY (`id`),
        KEY `idx_el_placed_owner` (`owner_cid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]],
    [[
    CREATE TABLE IF NOT EXISTS `el_printer_state` (
        `printer_id` VARCHAR(48) NOT NULL,
        `paper` INT NOT NULL DEFAULT 0,
        `ink` INT NOT NULL DEFAULT 0,
        `durability` DOUBLE NOT NULL DEFAULT 100,
        `maintenance` TINYINT(1) NOT NULL DEFAULT 0,
        `updated_at` BIGINT NOT NULL,
        PRIMARY KEY (`printer_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]],
}

-- Called once on start. Returns true when persistence is usable.
function el_DB.Init()
    if not el_DB.IsEnabled() then
        print('[el_printer] Persistence disabled in config. Using session storage.')
        return false
    end
    if not el_DB.IsAvailable() then
        el_Warn('oxmysql is not started. Documents and placed printers will NOT be saved (session storage).')
        return false
    end

    if Config.Persistence.AutoCreateTables then
        for i = 1, #el_Schema do
            local result = el_DB.Query(el_Schema[i])
            if not result then
                el_Warn('Could not create database tables. Import sql/el_printer.sql manually. Using session storage.')
                return false
            end
        end
    else
        local result = el_DB.Query('SELECT 1 FROM `el_printer_documents` LIMIT 1')
        if not result then
            el_Warn('Table el_printer_documents is missing. Import sql/el_printer.sql. Using session storage.')
            return false
        end
    end

    el_Ready = true
    print('[el_printer] Database ready.')
    return true
end

function el_DB.SetReady(value)
    el_Ready = value == true
end
