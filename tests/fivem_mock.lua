--[[
    Minimal FiveM + QBCore + oxmysql mock used to execute el_printer's server code outside the game.
    Only implements what the server scripts call.
]]

Mock = {
    now = 0,
    tasks = {},           -- { co, wake }
    netHandlers = {},     -- name -> { fn }
    localHandlers = {},
    clientEvents = {},    -- captured TriggerClientEvent calls
    resources = { ['qb-core'] = 'started' },
    players = {},         -- src -> player
    exportsTable = {},
    useables = {},
    current = {},
    db = { enabled = false, fail = false, documents = {}, placed = {}, state = {}, queries = 0 },
}

-------------------------------------------------------------------------------- vectors
local vecmt = {}
local function vec(x, y, z, w)
    return setmetatable({ x = x, y = y, z = z, w = w, __kind = w and 'vector4' or (z and 'vector3' or 'vector2') }, vecmt)
end
vecmt.__index = function(t, k)
    if k == 'xy' then return vec(rawget(t, 'x'), rawget(t, 'y')) end
    if k == 'xyz' then return vec(rawget(t, 'x'), rawget(t, 'y'), rawget(t, 'z')) end
    return nil
end
vecmt.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z and (a.z - b.z) or nil) end
vecmt.__add = function(a, b) return vec(a.x + b.x, a.y + b.y, a.z and (a.z + b.z) or nil) end
vecmt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + (a.z or 0) ^ 2) end
function vector3(x, y, z) return vec(x, y, z) end
function vector4(x, y, z, w) return vec(x, y, z, w) end
function vector2(x, y) return vec(x, y) end

local rawtype = type
function type(v)
    if rawtype(v) == 'table' and getmetatable(v) == vecmt then return rawget(v, '__kind') end
    return rawtype(v)
end

-------------------------------------------------------------------------------- json (identity tokens)
local jsonStore, jsonCounter = {}, 0
local function deepcopy(t)
    if rawtype(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepcopy(v) end
    return setmetatable(out, getmetatable(t))
end
json = {
    encode = function(t)
        jsonCounter = jsonCounter + 1
        local key = 'JSON#' .. jsonCounter
        jsonStore[key] = deepcopy(t)
        return key
    end,
    decode = function(s)
        if jsonStore[s] then return deepcopy(jsonStore[s]) end
        error('json mock cannot decode ' .. tostring(s))
    end,
}

-------------------------------------------------------------------------------- scheduler
local function schedule(co, wake)
    Mock.tasks[#Mock.tasks + 1] = { co = co, wake = wake }
end

local function resume(co, ...)
    local ok, res = coroutine.resume(co, ...)
    if not ok then
        Mock.errors = Mock.errors or {}
        Mock.errors[#Mock.errors + 1] = tostring(res) .. '\n' .. debug.traceback(co)
        print('COROUTINE ERROR: ' .. tostring(res))
        return
    end
    if coroutine.status(co) == 'dead' then return end
    if rawtype(res) == 'table' and res.wait then
        schedule(co, Mock.now + res.wait)
    elseif rawtype(res) == 'table' and res.await then
        local p = res.await
        p.waiters[#p.waiters + 1] = co
    end
end

function CreateThread(fn)
    local co = coroutine.create(fn)
    schedule(co, Mock.now)
end
Citizen = { CreateThread = CreateThread }

function Wait(ms)
    coroutine.yield({ wait = ms or 0 })
end

function SetTimeout(ms, fn)
    schedule(coroutine.create(fn), Mock.now + ms)
end

promise = {}
promise.__index = promise
function promise.new()
    return setmetatable({ resolved = false, waiters = {} }, promise)
end
function promise:resolve(v)
    if self.resolved then return end
    self.resolved = true
    self.value = v
    for _, co in ipairs(self.waiters) do schedule(co, Mock.now) end
    self.waiters = {}
end
function Citizen.Await(p)
    if not p.resolved then coroutine.yield({ await = p }) end
    return p.value
end

-- Runs tasks until the clock reaches `untilTime` (or nothing is left).
function Mock.Run(ms)
    local target = Mock.now + (ms or 0)
    while true do
        table.sort(Mock.tasks, function(a, b) return a.wake < b.wake end)
        local task = Mock.tasks[1]
        if not task or task.wake > target then break end
        table.remove(Mock.tasks, 1)
        if task.wake > Mock.now then Mock.now = task.wake end
        resume(task.co)
    end
    Mock.now = target
end

-------------------------------------------------------------------------------- natives
function GetCurrentResourceName() return 'el_printer' end
function GetResourceState(name) return Mock.resources[name] or 'missing' end
function GetGameTimer() return Mock.now end
function GetConvarInt() return 1 end
function GetConvar() return 'on' end
function GetPlayerName(src) return Mock.players[src] and Mock.players[src].online and ('Player' .. src) or nil end
function GetPlayers()
    local list = {}
    for src, p in pairs(Mock.players) do if p.online then list[#list + 1] = tostring(src) end end
    return list
end
function GetPlayerPed(src) return Mock.players[src] and Mock.players[src].online and (1000 + src) or 0 end
function DoesEntityExist(ent) return ent ~= 0 end
function GetEntityCoords(ped) local p = Mock.players[ped - 1000] return p and p.coords or vector3(0, 0, 0) end
function GetVehiclePedIsIn() return 0 end
function GetPlayerRoutingBucket() return 0 end

function RegisterNetEvent(name, fn)
    if fn then AddEventHandler(name, fn) end
end
function AddEventHandler(name, fn)
    Mock.localHandlers[name] = Mock.localHandlers[name] or {}
    table.insert(Mock.localHandlers[name], fn)
end
function TriggerEvent(name, ...)
    local args = table.pack(...)
    for _, fn in ipairs(Mock.localHandlers[name] or {}) do
        schedule(coroutine.create(function() fn(table.unpack(args, 1, args.n)) end), Mock.now)
    end
end
function TriggerClientEvent(name, target, ...)
    Mock.clientEvents[#Mock.clientEvents + 1] = { name = name, target = target, args = table.pack(...) }
end

-- Simulates a client sending a net event.
function Mock.FromClient(src, name, ...)
    local args = table.pack(...)
    for _, fn in ipairs(Mock.localHandlers[name] or {}) do
        schedule(coroutine.create(function()
            source = src
            fn(table.unpack(args, 1, args.n))
        end), Mock.now)
    end
end

-------------------------------------------------------------------------------- exports
local function exportProxy(resource)
    return setmetatable({}, {
        __index = function(_, fnName)
            local res = Mock.exportsTable[resource]
            local fn = res and res[fnName]
            if not fn then
                return function() error(('No such export %s in resource %s'):format(fnName, resource)) end
            end
            return function(_, ...) return fn(...) end
        end,
    })
end

exports = setmetatable({}, {
    __call = function(_, name, fn)
        Mock.exportsTable.el_printer = Mock.exportsTable.el_printer or {}
        Mock.exportsTable.el_printer[name] = fn
    end,
    __index = function(_, resource) return exportProxy(resource) end,
})

-------------------------------------------------------------------------------- QBCore
local QBCore = { Functions = {}, Shared = { Items = {} } }

function QBCore.Functions.GetPlayer(src)
    local p = Mock.players[src]
    if not p or not p.online then return nil end
    return p.obj
end

function QBCore.Functions.GetPlayerByCitizenId(cid)
    for _, p in pairs(Mock.players) do
        if p.online and p.obj.PlayerData.citizenid == cid then return p.obj end
    end
    return nil
end

function QBCore.Functions.CreateUseableItem(name, cb) Mock.useables[name] = cb end

Mock.exportsTable['qb-core'] = { GetCoreObject = function() return QBCore end }

local slotCounter = 0
function Mock.AddPlayer(src, cid, first, last, job, grade, onduty, coords, cash)
    local items = {}
    local pd = {
        source = src,
        citizenid = cid,
        charinfo = { firstname = first, lastname = last, birthdate = '1990-01-01', gender = 0, nationality = 'American' },
        job = { name = job, label = job:gsub('^%l', string.upper), grade = { level = grade, name = 'Grade ' .. grade }, onduty = onduty },
        items = items,
        money = { cash = cash or 1000, bank = 0 },
    }
    local obj = { PlayerData = pd, Functions = {} }
    function obj.Functions.GetMoney(account) return pd.money[account] or 0 end
    function obj.Functions.RemoveMoney(account, amount)
        if (pd.money[account] or 0) < amount then return false end
        pd.money[account] = pd.money[account] - amount
        return true
    end
    function obj.Functions.AddMoney(account, amount)
        pd.money[account] = (pd.money[account] or 0) + amount
        return true
    end
    function obj.Functions.AddItem(name, amount, _, info)
        if Mock.inventoryFull then return false end
        slotCounter = slotCounter + 1
        items[slotCounter] = { name = name, amount = amount, info = info or {}, slot = slotCounter }
        return true
    end
    function obj.Functions.RemoveItem(name, amount, slot)
        if slot then
            local it = items[slot]
            if it and it.name == name and it.amount >= amount then
                it.amount = it.amount - amount
                if it.amount <= 0 then items[slot] = nil end
                return true
            end
            return false
        end
        for s, it in pairs(items) do
            if it.name == name and it.amount >= amount then
                it.amount = it.amount - amount
                if it.amount <= 0 then items[s] = nil end
                return true
            end
        end
        return false
    end
    Mock.players[src] = { online = true, obj = obj, coords = coords }
    return obj
end

function Mock.CountItem(src, name)
    local total = 0
    for _, it in pairs(Mock.players[src].obj.PlayerData.items) do
        if it.name == name then total = total + it.amount end
    end
    return total
end

function Mock.Drop(src)
    Mock.players[src].online = false
    for _, fn in ipairs(Mock.localHandlers['playerDropped'] or {}) do
        schedule(coroutine.create(function() source = src fn('quit') end), Mock.now)
    end
end

-------------------------------------------------------------------------------- oxmysql
local function dbReply(cb, result, err)
    SetTimeout(5, function() cb(result, err) end)
end

Mock.exportsTable.oxmysql = {
    query = function(sql, params, cb)
        local db = Mock.db
        db.queries = db.queries + 1
        if db.fail then return dbReply(cb, nil, 'mock failure') end
        sql = sql:gsub('%s+', ' ')
        if sql:find('CREATE TABLE') or sql:find('SELECT 1') then return dbReply(cb, {}) end
        if sql:find('INSERT INTO `el_printer_documents`') then
            local cols = { 'id', 'doc_type', 'title', 'owner_cid', 'issuer_cid', 'issuer_name', 'issuer_job', 'issuer_job_label',
                'issuer_grade', 'issuer_grade_label', 'recipient_cid', 'data', 'status', 'print_count', 'created_at', 'expires_at', 'printer_id' }
            local row = {}
            for i, c in ipairs(cols) do row[c] = params[i] end
            db.documents[row.id] = row
            return dbReply(cb, { affectedRows = 1 })
        end
        if sql:find('SELECT %* FROM `el_printer_documents` WHERE `id`') then
            local row = db.documents[params[1]]
            return dbReply(cb, row and { deepcopy(row) } or {})
        end
        if sql:find('SET `print_count` = `print_count` %+') then
            local row = db.documents[params[2]]
            if row and row.print_count == params[3] and row.status == params[4] then
                row.print_count = row.print_count + params[1]
                return dbReply(cb, { affectedRows = 1 })
            end
            return dbReply(cb, { affectedRows = 0 })
        end
        if sql:find('GREATEST') then
            local row = db.documents[params[2]]
            if row then row.print_count = math.max(0, row.print_count - params[1]) end
            return dbReply(cb, { affectedRows = row and 1 or 0 })
        end
        if sql:find('SET `status` = ?') then
            local row = db.documents[params[2]]
            if row then row.status = params[1] end
            return dbReply(cb, { affectedRows = row and 1 or 0 })
        end
        if sql:find('FROM `el_printer_documents` WHERE `owner_cid`') then
            local out = {}
            for _, row in pairs(db.documents) do
                local match = row.owner_cid == params[1] or row.issuer_cid == params[2]
                for i = 3, #params - 1 do if row.doc_type == params[i] then match = true end end
                if match then out[#out + 1] = deepcopy(row) end
            end
            return dbReply(cb, out)
        end
        if sql:find('el_printer_state') or sql:find('el_printer_placed') then
            if sql:find('^ ?SELECT') then return dbReply(cb, {}) end
            return dbReply(cb, { affectedRows = 1 })
        end
        if sql:find('FROM `players`') then return dbReply(cb, {}) end
        error('Unhandled SQL in mock: ' .. sql)
    end,
}

-------------------------------------------------------------------------------- client response helper
-- Sends a request as a client and returns the server response after running the scheduler.
local reqCounter = 0
function Mock.Request(src, action, payload, runMs)
    reqCounter = reqCounter + 1
    local id = reqCounter
    local mark = #Mock.clientEvents
    -- Like client/nui.lua: the printer the player opened is attached to every request.
    payload = payload or {}
    if payload.printerId == nil and action ~= 'openPrinter' then payload.printerId = Mock.current[src] end
    if action == 'openPrinter' then Mock.current[src] = payload.printerId end
    Mock.FromClient(src, 'el_printer:server:request', id, action, payload)
    Mock.Run(runMs or 800)
    for i = mark + 1, #Mock.clientEvents do
        local e = Mock.clientEvents[i]
        if e.name == 'el_printer:client:response' and e.target == src and e.args[1] == id then
            return e.args[2]
        end
    end
    return nil
end

function Mock.EventsFor(src, name, since)
    local out = {}
    for i = (since or 0) + 1, #Mock.clientEvents do
        local e = Mock.clientEvents[i]
        if e.name == name and (e.target == src or e.target == -1) then out[#out + 1] = e end
    end
    return out
end
