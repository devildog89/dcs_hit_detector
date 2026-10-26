--[[
  Offline test harness for redflag_hit_detector.lua

  Mocks the parts of the DCS mission-scripting API the script uses, loads the
  script into a sandbox, and drives events through it. This checks LOGIC only.
  It is NOT a substitute for testing in the DCS mission editor — mock behavior
  is based on the documented API and may differ from the real sim.

  Run from the repo root with Lua 5.1 or LuaJIT (DCS uses Lua 5.1):
      lua5.1 tests/test_hit_detector.lua [path/to/script.lua]
]]

local SCRIPT = (arg and arg[1]) or "redflag_hit_detector.lua"
local TMP    = os.getenv("TMPDIR") or "/tmp"
math.randomseed(os.time())

local results = { pass = 0, fail = 0 }
local function check(name, cond, detail)
    if cond then
        results.pass = results.pass + 1
        print("PASS  " .. name)
    else
        results.fail = results.fail + 1
        print("FAIL  " .. name .. (detail and ("\n        -> " .. tostring(detail)) or ""))
    end
end

---------------------------------------------------------------------------
-- Mock DCS environment
---------------------------------------------------------------------------
local runCounter = 0
local function newWritedir()
    runCounter = runCounter + 1
    local dir = string.format("%s/rfhd_%d_%d_%d/", TMP, os.time(), math.random(1e6), runCounter)
    os.execute('mkdir -p "' .. dir .. 'Logs"')
    return dir
end

local function newEnv(opts)
    opts = opts or {}
    local env = {
        now = 100, texts = {}, unitTexts = {}, unitSounds = {},
        commands = {}, handlers = {}, errors = {}, groups = {},
        writedir = opts.writedir or newWritedir(),
    }
    -- Stock DCS servers strip io/os/lfs from the mission environment.
    local blocked = opts.sanitized and { io = true, os = true, lfs = true } or {}
    local E = setmetatable({}, { __index = function(_, k)
        if blocked[k] then return nil end
        return _G[k]
    end })

    E.world = {
        event = { S_EVENT_MISSION_START = 1, S_EVENT_HIT = 2,
                  S_EVENT_BIRTH = 15, S_EVENT_PLAYER_ENTER_UNIT = 20 },
        addEventHandler = function(h) table.insert(env.handlers, h) end,
    }
    E.trigger = { action = {
        outText = function(msg) table.insert(env.texts, msg) end,
        -- Real signature: outTextForUnit(number unitId, string text, number time, boolean clear)
        outTextForUnit = function(id, msg)
            assert(type(id) == "number", "outTextForUnit expects a unit ID (number), got " .. type(id))
            table.insert(env.unitTexts, { id = id, msg = msg })
        end,
        -- Real signature: outSoundForUnit(number unitId, string soundfile)
        outSoundForUnit = function(id, file)
            assert(type(id) == "number", "outSoundForUnit expects a unit ID (number), got " .. type(id))
            table.insert(env.unitSounds, { id = id, file = file })
        end,
    } }
    E.timer = { getTime = function() return env.now end }
    E.coalition = {
        side = { NEUTRAL = 0, RED = 1, BLUE = 2 },
        getGroups = function(side) return env.groups[side] or {} end,
    }
    E.Object = {
        Category = { UNIT = 1, WEAPON = 2, STATIC = 3, BASE = 4, SCENERY = 5, CARGO = 6 },
        getCategory = function(o) return o._cat end,
    }
    E.env = {
        info = function() end, warning = function() end,
        error = function(m) table.insert(env.errors, m) end,
    }
    if not opts.sanitized then
        E.lfs = { writedir = function() return env.writedir end }
        -- DCS file handles expose read/write/flush/close but not seek, so
        -- hand the script a proxy with only those methods.
        E.io = { open = function(p, mode)
            local f, err = io.open(p, mode)
            if not f then return nil, err end
            return {
                read  = function(_, ...) return f:read(...) end,
                write = function(_, ...) return f:write(...) end,
                flush = function() return f:flush() end,
                close = function() return f:close() end,
            }
        end }
    end
    env.E = E
    return env
end

local nextId = 1000
local function mkGroup(env, side)
    local g = { units = {} }
    g.ctrl = { setCommand = function(_, cmd) table.insert(env.commands, { group = g, cmd = cmd }) end }
    function g:getUnits() return self.units end
    function g:getController() return self.ctrl end
    function g:getName() return "Group" .. tostring(self.units[1] and self.units[1]._id or "?") end
    if side then
        env.groups[side] = env.groups[side] or {}
        table.insert(env.groups[side], g)
    end
    return g
end

local function mkUnit(o)
    nextId = nextId + 1
    local u = { _cat = 1, _id = nextId, _player = o.player, _type = o.type or "F-16C_50",
                _name = o.name or ("Unit" .. nextId), _coal = o.coal or 2, _group = o.group }
    function u:getPlayerName() return self._player end
    function u:getTypeName() return self._type end
    function u:getName() return self._name end
    function u:getID() return self._id end
    function u:getCoalition() return self._coal end
    function u:getGroup() return self._group end
    function u:getCategory() return 1, 0 end
    function u:isExist() return true end
    if o.group then table.insert(o.group.units, u) end
    return u
end

-- Weapon:getCategory() returns the OBJECT category (WEAPON = 2) like DCS 2.9+;
-- the weapon category (shell/missile/...) is only in getDesc().category.
local function mkWeapon(cat, typeName)
    local w = { _cat = 2 }
    function w:getCategory() return 2, cat end
    function w:getDesc() return { category = cat, typeName = typeName } end
    function w:getTypeName() return typeName end
    function w:getName() return "16777482" end  -- runtime object id, not the type
    return w
end

-- Static objects have no getPlayerName().
local function mkStatic()
    local s = { _cat = 3 }
    function s:getTypeName() return "Hangar" end
    function s:getName() return "Static-1" end
    function s:getCoalition() return 2 end
    return s
end

local function loadScript(env, transform)
    local f = assert(io.open(SCRIPT, "rb"))
    local src = f:read("*a")
    f:close()
    if transform then src = transform(src) end
    local chunk, err = loadstring(src, "@" .. SCRIPT)
    if not chunk then env.loadErr = err; return false end
    setfenv(chunk, env.E)
    local ok, rerr = pcall(chunk)
    if not ok then env.loadErr = rerr; return false end
    return true
end

local function fire(env, ev)
    for _, h in ipairs(env.handlers) do
        local ok, err = pcall(h.onEvent, h, ev)
        if not ok then table.insert(env.errors, err) end
    end
end

local function hasText(list, needle)
    for _, m in ipairs(list) do
        if string.find(m, needle, 1, true) then return true end
    end
    return false
end

local function readFile(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function countHits(env)
    local n = 0
    for _, m in ipairs(env.texts) do if m:find("[HIT]", 1, true) then n = n + 1 end end
    return n
end

-- Standard scenario: blue player in an F-16, red AI SAM site.
local function scenario(opts)
    opts = opts or {}
    local env = newEnv(opts)
    local ok = loadScript(env, opts.transform)
    local g = mkGroup(env)
    local player = mkUnit({ player = opts.playerName or "Viper 1-1 | Bob", coal = 2, group = g })
    local sam = mkUnit({ type = "Kub 2P25 ln", name = "SA-6 Site", coal = 1 })
    return env, ok, player, sam
end

local function hitEvent(env, target, initiator, weapon)
    return { id = 2, time = env.now, target = target, initiator = initiator, weapon = weapon }
end

local function errs(env) return env.loadErr or env.errors[1] end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------
print("Testing " .. SCRIPT .. "\n")

do -- Loading on a stock (sanitized) server
    local env, ok, player, sam = scenario({ sanitized = true })
    check("loads on a stock server (io/os/lfs sanitized)", ok, env.loadErr)
    fire(env, hitEvent(env, player, sam, mkWeapon(1, "SA6_3M9")))
    check("handles a hit on a stock server without errors", #env.errors == 0 and countHits(env) == 1, errs(env))
end

do -- Init runs at load
    local env, ok = scenario()
    check("init runs at script load ('Active' banner shown)", ok and hasText(env.texts, "Active"), errs(env))
    local log = readFile(env.writedir .. "Logs/redflag_hits.csv")
    check("CSV log created under lfs.writedir()/Logs/", log ~= nil, "no file at " .. env.writedir .. "Logs/redflag_hits.csv")
    check("CSV log starts with the header row",
          log ~= nil and log:sub(1, 10) == "timestamp,", log and log:sub(1, 60))
end

do -- Basic missile hit on a player
    local env, ok, player, sam = scenario()
    fire(env, hitEvent(env, player, sam, mkWeapon(1, "SA6_3M9")))
    check("targeted message sent to the hit player's unit ID",
          #env.errors == 0 and env.unitTexts[1] and env.unitTexts[1].id == player._id, errs(env))
    check("targeted sound sent to the hit player's unit ID",
          env.unitSounds[1] and env.unitSounds[1].id == player._id, errs(env))
    local hit
    for _, m in ipairs(env.texts) do if m:find("[HIT]", 1, true) then hit = m end end
    check("broadcast labels the weapon category correctly (Missile)",
          hit and hit:find("Missile", 1, true), hit)
    check("broadcast names the weapon type, not its runtime ID",
          hit and hit:find("SA6_3M9", 1, true) and not hit:find("16777482", 1, true), hit)
    check("broadcast shows a real em dash, not literal 'u2014'",
          hit and hit:find("\226\128\148", 1, true) and not hit:find("u2014", 1, true), hit)
    local log = readFile(env.writedir .. "Logs/redflag_hits.csv") or ""
    check("CSV row written for the hit", log:find("Missile", 1, true) and log:find("SA6_3M9", 1, true), log)
    check("CSV has no '#' comment lines", not log:find("\n#", 1, true), log)
end

do -- Header written once across restarts
    local wd = newWritedir()
    scenario({ writedir = wd })
    local env2, ok2 = scenario({ writedir = wd })
    check("second load with an existing CSV runs init without errors",
          ok2 and hasText(env2.texts, "logging to"), errs(env2))
    local log = readFile(wd .. "Logs/redflag_hits.csv") or ""
    local _, n = log:gsub("timestamp,player_name", "")
    check("CSV header written once across two mission loads", n == 1, "header count = " .. n)
end

do -- Cooldown
    local env, _, player, sam = scenario()
    fire(env, hitEvent(env, player, sam, mkWeapon(1, "SA6_3M9")))
    env.now = env.now + 5
    fire(env, hitEvent(env, player, sam, mkWeapon(1, "SA6_3M9")))
    local within = countHits(env)
    env.now = env.now + 20
    fire(env, hitEvent(env, player, sam, mkWeapon(1, "SA6_3M9")))
    check("cooldown suppresses repeat hits, then allows after window",
          within == 1 and countHits(env) == 2, "hits after 5s = " .. within .. ", after 25s = " .. countHits(env))
end

do -- Non-player / non-unit targets
    local env, _, player, sam = scenario()
    fire(env, hitEvent(env, sam, player, mkWeapon(0, "M61_20_HE")))
    check("AI target is ignored", countHits(env) == 0 and #env.errors == 0, errs(env))
    env.errors = {}
    fire(env, hitEvent(env, mkStatic(), player, mkWeapon(3, "Mk_82")))
    check("static-object target is ignored without errors", countHits(env) == 0 and #env.errors == 0, errs(env))
    env.errors = {}
    fire(env, hitEvent(env, player, nil, nil))
    check("collision (no initiator) is ignored", countHits(env) == 0 and #env.errors == 0, errs(env))
end

do -- Weapon-category allowlist
    local env, _, player, sam = scenario({ transform = function(s)
        return (s:gsub("WEAPON_CATEGORY_ALLOWLIST = {},", "WEAPON_CATEGORY_ALLOWLIST = { 0 },"))
    end })
    fire(env, hitEvent(env, player, sam, mkWeapon(1, "SA6_3M9")))
    local afterMissile = countHits(env)
    env.now = env.now + 60
    fire(env, hitEvent(env, player, sam, mkWeapon(0, "ZU_23_HE")))
    check("allowlist {0}: missile filtered out, gun shell allowed",
          afterMissile == 0 and countHits(env) == 1, "missile hits = " .. afterMissile .. ", total = " .. countHits(env))
end

do -- Immortality for players who join after load
    local env, _, player = scenario()
    fire(env, { id = 15, time = env.now, initiator = player })
    local afterBirth = #env.commands
    fire(env, { id = 20, time = env.now, initiator = player })
    local immortal = env.commands[1] and env.commands[1].cmd.id == "SetImmortal"
                     and env.commands[1].group == player._group
    check("player spawning/slotting in after load gets SetImmortal",
          immortal and afterBirth >= 1 and #env.errors == 0,
          "SetImmortal commands sent = " .. #env.commands .. (errs(env) and ("; " .. errs(env)) or ""))
end

do -- CSV escaping
    local env, _, player, sam = scenario({ playerName = "Bob, the Builder" })
    fire(env, hitEvent(env, player, sam, mkWeapon(1, "SA6_3M9")))
    local log = readFile(env.writedir .. "Logs/redflag_hits.csv") or ""
    check("CSV quotes player names containing commas", log:find('"Bob, the Builder"', 1, true), log)
end

print(string.format("\n%d passed, %d failed", results.pass, results.fail))
os.exit(results.fail == 0 and 0 or 1)
