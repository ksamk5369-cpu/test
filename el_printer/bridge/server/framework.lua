--[[
    Server framework bridge (QBCore).
    All player identity, job and money data used for authorization comes from here.
]]

local QBCore = nil
if GetResourceState('qb-core') == 'started' then
    QBCore = exports['qb-core']:GetCoreObject()
else
    el_Warn('qb-core is not started. el_printer requires qb-core and will not work.')
end

el_Bridge.Server = {}

function el_Bridge.Server.IsReady()
    return QBCore ~= nil
end

function el_Bridge.Server.GetCore()
    return QBCore
end

local function el_GetPlayer(src)
    if not QBCore then return nil end
    return QBCore.Functions.GetPlayer(src)
end

el_Bridge.Server.GetPlayer = el_GetPlayer

local function el_NormalizeJob(job)
    job = job or {}
    local grade, gradeLabel = 0, ''
    if type(job.grade) == 'table' then
        grade = tonumber(job.grade.level) or 0
        gradeLabel = job.grade.name or ''
    else
        grade = tonumber(job.grade) or 0
    end
    return {
        name = job.name or 'unemployed',
        label = job.label or job.name or 'Unemployed',
        grade = grade,
        gradeLabel = gradeLabel,
        onduty = job.onduty == true,
    }
end

local function el_NormalizeCharinfo(citizenid, charinfo)
    charinfo = charinfo or {}
    local first = tostring(charinfo.firstname or '')
    local last = tostring(charinfo.lastname or '')
    local name = (first .. ' ' .. last):gsub('^%s+', ''):gsub('%s+$', '')
    local gender = charinfo.gender
    if gender == 0 or gender == '0' then
        gender = 'Male'
    elseif gender == 1 or gender == '1' then
        gender = 'Female'
    else
        gender = gender and tostring(gender) or ''
    end
    return {
        citizenid = citizenid,
        name = name ~= '' and name or 'Unknown',
        firstname = first,
        lastname = last,
        birthdate = charinfo.birthdate and tostring(charinfo.birthdate) or '',
        gender = gender,
        nationality = charinfo.nationality and tostring(charinfo.nationality) or '',
    }
end

-- Returns a normalized identity for an online player, or nil.
function el_Bridge.Server.GetIdentity(src)
    local player = el_GetPlayer(src)
    if not player or not player.PlayerData then return nil end
    local data = player.PlayerData
    local identity = el_NormalizeCharinfo(data.citizenid, data.charinfo)
    identity.source = src
    identity.job = el_NormalizeJob(data.job)
    return identity
end

function el_Bridge.Server.GetSourceByCitizenId(citizenid)
    if not QBCore or type(citizenid) ~= 'string' then return nil end
    local player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    return player and player.PlayerData and player.PlayerData.source or nil
end

-- Looks up a citizen (online first, then the QBCore players table when oxmysql is available).
-- Returns identity or nil. Never trusts client-supplied names.
function el_Bridge.Server.FindCitizen(citizenid)
    if type(citizenid) ~= 'string' or not citizenid:match('^[%w]+$') or #citizenid > 16 then
        return nil
    end
    citizenid = citizenid:upper()

    local src = el_Bridge.Server.GetSourceByCitizenId(citizenid)
    if src then
        return el_Bridge.Server.GetIdentity(src)
    end

    if el_DB and el_DB.IsAvailable() then
        local rows = el_DB.Query('SELECT `citizenid`, `charinfo`, `job` FROM `players` WHERE `citizenid` = ? LIMIT 1', { citizenid })
        local row = rows and rows[1]
        if row then
            local okChar, charinfo = pcall(json.decode, row.charinfo or '{}')
            local okJob, job = pcall(json.decode, row.job or '{}')
            local identity = el_NormalizeCharinfo(row.citizenid, okChar and charinfo or {})
            identity.job = el_NormalizeJob(okJob and job or {})
            return identity
        end
    end
    return nil
end

function el_Bridge.Server.GetMoney(src, account)
    local player = el_GetPlayer(src)
    if not player then return 0 end
    return tonumber(player.Functions.GetMoney(account)) or 0
end

function el_Bridge.Server.RemoveMoney(src, account, amount, reason)
    if amount <= 0 then return true end
    local player = el_GetPlayer(src)
    if not player then return false end
    if (tonumber(player.Functions.GetMoney(account)) or 0) < amount then return false end
    return player.Functions.RemoveMoney(account, amount, reason) == true
end

function el_Bridge.Server.AddMoney(src, account, amount, reason)
    if amount <= 0 then return true end
    local player = el_GetPlayer(src)
    if not player then return false end
    return player.Functions.AddMoney(account, amount, reason) == true
end

function el_Bridge.Server.Notify(src, message, notifyType)
    local provider = el_Bridge.ResolveNotify()
    if provider == 'qb' then
        local qbType = notifyType == 'warning' and 'primary' or notifyType
        TriggerClientEvent('QBCore:Notify', src, message, qbType, Config.NotifyDuration)
    elseif provider == 'ox' then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Printer',
            description = message,
            type = notifyType,
            duration = Config.NotifyDuration,
        })
    else
        TriggerClientEvent('el_printer:client:notify', src, message, notifyType)
    end
end

-- Logout without disconnecting (character switch) is treated like a disconnect.
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    TriggerEvent('el_printer:server:playerLeft', src)
end)
