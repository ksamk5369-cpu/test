--[[
    Client framework bridge (QBCore).
    Only used for display decisions (e.g. which target options to show).
    Every authorization decision is made again on the server.
]]

local QBCore = nil
if GetResourceState('qb-core') == 'started' then
    QBCore = exports['qb-core']:GetCoreObject()
else
    el_Warn('qb-core is not started. el_printer requires qb-core.')
end

el_Bridge.Client = el_Bridge.Client or {}

local el_PlayerData = {}

function el_Bridge.Client.IsReady()
    return QBCore ~= nil
end

function el_Bridge.Client.RefreshPlayerData()
    if QBCore then
        el_PlayerData = QBCore.Functions.GetPlayerData() or {}
    end
    return el_PlayerData
end

function el_Bridge.Client.GetPlayerData()
    return el_PlayerData
end

function el_Bridge.Client.IsLoggedIn()
    return el_PlayerData ~= nil and el_PlayerData.citizenid ~= nil
end

function el_Bridge.Client.GetCitizenId()
    return el_PlayerData and el_PlayerData.citizenid
end

-- Returns jobName, gradeLevel, onDuty.
function el_Bridge.Client.GetJob()
    local job = el_PlayerData and el_PlayerData.job
    if not job then return nil, 0, false end
    local grade = 0
    if type(job.grade) == 'table' then
        grade = tonumber(job.grade.level) or 0
    else
        grade = tonumber(job.grade) or 0
    end
    return job.name, grade, job.onduty == true
end

function el_Bridge.Client.Notify(message, notifyType, duration)
    local provider = el_Bridge.ResolveNotify()
    duration = duration or Config.NotifyDuration
    if provider == 'qb' and QBCore then
        local qbType = notifyType == 'warning' and 'primary' or notifyType
        QBCore.Functions.Notify(message, qbType, duration)
    elseif provider == 'ox' then
        TriggerEvent('ox_lib:notify', {
            title = 'Printer',
            description = message,
            type = notifyType == 'warning' and 'warning' or notifyType,
            duration = duration,
        })
    else
        el_NuiSend('notify', { message = message, type = notifyType, duration = duration })
    end
end

-- Framework lifecycle -> generic resource events.
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    el_Bridge.Client.RefreshPlayerData()
    TriggerEvent('el_printer:client:playerLoaded')
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    el_PlayerData = {}
    TriggerEvent('el_printer:client:playerUnloaded')
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    el_PlayerData.job = job
end)

RegisterNetEvent('QBCore:Client:SetDuty', function(onDuty)
    if el_PlayerData.job then
        el_PlayerData.job.onduty = onDuty
    end
end)

RegisterNetEvent('QBCore:Player:SetPlayerData', function(data)
    el_PlayerData = data or el_PlayerData
end)
