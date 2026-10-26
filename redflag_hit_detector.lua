--[[
================================================================================
  RedFlag Hit Detector v4 (single-file)
  Rolling Thunder DCS Red Flag — Bryan / Hyperion

  Install:
    1. Add redflag_hit_detector.lua to the mission.
    2. In the mission editor, add a trigger:
         Trigger:   MISSION START
         Action:    DO SCRIPT FILE -> redflag_hit_detector.lua
       The script initializes as soon as it loads; no hook script required.
    3. (Optional) CSV logging needs io/lfs un-sanitized in the server's
       Scripts/MissionScripting.lua. On a stock server the script still runs
       and simply skips logging, with an on-screen notice.

  Behavior:
    1. On load:
         - Registers the hit and player handlers.
         - Optional: SetImmortal on human-player groups (CONFIG.SET_PLAYERS_IMMORTAL),
           re-applied on every spawn / slot-in (S_EVENT_BIRTH, S_EVENT_PLAYER_ENTER_UNIT).
         - Opens the CSV log in Saved Games\DCS...\Logs\ (CONFIG.LOG_FILE).
    2. On S_EVENT_HIT against a human-player unit:
         - Filters: weapon-category allowlist, collisions, self-fire,
           friendly fire (toggles in CONFIG).
         - Anti-spam: per-player cooldown (CONFIG.COOLDOWN_SECONDS).
         - "Knock it off" text + sound to the hit player only
           (outTextForUnit / outSoundForUnit by unit ID).
         - "[HIT]" broadcast via outText (visible to all, incl. white cell / GM).
         - Appends a row to the CSV log for GM review.

  Status: passes the offline harness (tests/test_hit_detector.lua, mocked DCS
  API, Lua 5.1). NOT yet validated in DCS. Before event use, confirm on the dev
  machine: SetImmortal is honored for client groups, PLAYER_SOUND plays, and
  the CSV lands in Saved Games\DCS...\Logs\. DCS server `bravo` is off-limits.
================================================================================
]]--

--------------------
-- CONFIG  -- edit per mission
--------------------
local CONFIG = {
    -- ===== Notifications =====
    COOLDOWN_SECONDS       = 15,    -- min seconds between hit messages per player
    PLAYER_MSG_DURATION    = 15,    -- seconds the "knock it off" banner stays up
    WC_MSG_DURATION        = 10,    -- seconds the white-cell "[HIT]" line stays up
    PLAYER_MSG             = "REDFLAG CONTROL: Knock it Off! You have been HIT. "
                                .. "Go to Marshal and wait for your flight.",

    -- %s placeholders, in order: player name, unit type, initiator, weapon category name, weapon name
    WC_MSG_FORMAT          = "[HIT] %s in %s by %s — %s (%s)",

    -- ===== Sound (played only for the hit player) =====
    -- Unverified: outSoundForUnit may only play files packed into the .miz.
    -- If silent in testing, add the .wav/.ogg to the mission and use its name.
    PLAYER_SOUND           = "Effects/Aircrafts/Cockpits/MasterCaution.wav",

    -- ===== Hit filter =====
    -- Weapon category allowlist (DCS Weapon.Category enum).
    -- Empty = allow all weapon categories.
    --   0 = SHELL, 1 = MISSILE, 2 = ROCKET, 3 = BOMB, 4 = TORPEDO
    -- Examples:
    --   { 1 }              -- missiles only (typical Red Flag: SAMs/AAMs)
    --   { 0, 1, 2 }        -- guns + missiles + rockets
    --   {}                 -- all weapons
    WEAPON_CATEGORY_ALLOWLIST = {},

    EXCLUDE_COLLISIONS     = true,  -- skip hits with no initiator (world/terrain/static)
    EXCLUDE_SELF_FIRE      = true,  -- skip hits from the target's own weapons
    EXCLUDE_FRIENDLY_FIRE  = false, -- skip hits from coaltion-mates

    -- ===== Logging =====
    -- CSV log file. A relative name is written to Saved Games\DCS...\Logs\
    -- (via lfs.writedir()); an absolute path is used as-is. nil = no logging.
    -- Requires io/lfs to be un-sanitized in the server's MissionScripting.lua;
    -- on a stock server logging is skipped with a warning (hits still work).
    LOG_FILE               = "redflag_hits.csv",

    -- ===== Immortal =====
    -- Apply SetImmortal=true to human-player groups: once at load, and again
    -- whenever a player spawns or takes a slot (players join after start).
    SET_PLAYERS_IMMORTAL   = true,
}

--------------------
-- Helpers
--------------------
local WEAPON_CATEGORY_NAMES = {
    [0] = "Shell",
    [1] = "Missile",
    [2] = "Rocket",
    [3] = "Bomb",
    [4] = "Torpedo",
}

local function categoryAllowed(cat)
    if not CONFIG.WEAPON_CATEGORY_ALLOWLIST or #CONFIG.WEAPON_CATEGORY_ALLOWLIST == 0 then
        return true  -- empty allowlist = allow all
    end
    for _, allowed in ipairs(CONFIG.WEAPON_CATEGORY_ALLOWLIST) do
        if allowed == cat then return true end
    end
    return false
end

-- Weapon:getCategory() returns the *object* category (Object.Category.WEAPON),
-- not shell/missile/rocket. The weapon category lives in getDesc().category.
local function weaponCategory(weapon)
    if not weapon then return nil end
    local ok, desc = pcall(function() return weapon:getDesc() end)
    if ok and type(desc) == "table" then return desc.category end
    return nil
end

-- Best display name for whoever fired: player name, else unit name.
local function shooterName(obj)
    if not obj then return "world" end
    local name = obj.getPlayerName and obj:getPlayerName()
    if not name and obj.getName then name = obj:getName() end
    return name or "unknown"
end

-- All the strings the broadcast and the CSV log need, built once.
local function describeHit(target, initiator, weapon)
    local cat = weaponCategory(weapon)
    return {
        player   = target:getPlayerName(),
        unitType = (target.getTypeName and target:getTypeName()) or "aircraft",
        shooter  = shooterName(initiator),
        category = (cat and WEAPON_CATEGORY_NAMES[cat]) or "Threat",
        -- getTypeName() is the weapon type (e.g. "AIM_120C"); getName() is a runtime ID
        weapon   = (weapon and weapon.getTypeName and weapon:getTypeName()) or "simulated",
    }
end

local function isCollision(initiator)
    if not CONFIG.EXCLUDE_COLLISIONS then return false end
    return initiator == nil
end

local function isSelfFire(initiator, target)
    if not CONFIG.EXCLUDE_SELF_FIRE then return false end
    if not initiator then return false end
    local initPlayer = (initiator.getPlayerName and initiator:getPlayerName())
                    or (initiator.getPlayerName and initiator.getPlayerName(initiator))
    if initPlayer and target:getPlayerName() == initPlayer then return true end
    return false
end

local function isFriendlyFire(initiator, target)
    if not CONFIG.EXCLUDE_FRIENDLY_FIRE then return false end
    if not initiator then return false end
    if not (initiator.getCoalition and target.getCoalition) then return false end
    return initiator:getCoalition() == target:getCoalition()
end

local cooldown = {}  -- playerName -> last-hit timestamp (seconds)

local function getTime()
    if timer and timer.getTime then return timer.getTime() end
    return os.clock()
end

--------------------
-- Logging
--------------------
-- DCS strips io/os/lfs from the mission environment unless the server's
-- MissionScripting.lua is edited ("desanitized"). Never assume they exist.
local logHandle = nil
local logPath   = nil

local CSV_HEADER = "timestamp,player_name,unit_type,initiator,weapon_category,weapon_name"

local function resolveLogPath(p)
    if p:match("^%a:[/\\]") or p:match("^[/\\]") then return p end  -- already absolute
    if lfs and lfs.writedir then
        return lfs.writedir() .. "Logs/" .. p  -- Saved Games\DCS...\Logs\
    end
    return p
end

local function timestamp()
    if os and os.date then return os.date("%Y-%m-%dT%H:%M:%S") end
    return string.format("T+%.0fs", getTime())  -- mission time fallback
end

-- Quote a CSV field if it contains a comma, quote, or newline.
local function csv(v)
    v = tostring(v == nil and "" or v)
    if v:find('[,"\r\n]') then
        v = '"' .. v:gsub('"', '""') .. '"'
    end
    return v
end

local function openLog()
    if not CONFIG.LOG_FILE then return end
    if not (io and io.open) then
        trigger.action.outText("[RedFlagHitDetector] Logging disabled: 'io' is sanitized "
            .. "in this server's MissionScripting.lua. Hit detection is still active.", 10)
        return
    end
    logPath = resolveLogPath(CONFIG.LOG_FILE)

    -- Only write the header for a new/empty file so restarts don't repeat it.
    -- DCS file handles lack some methods (no seek in the mission env), so
    -- probe with read and treat any failure as "already has a header".
    local isNew = true
    local existing = io.open(logPath, "r")
    if existing then
        local ok, firstByte = pcall(function() return existing:read(1) end)
        isNew = ok and firstByte == nil
        pcall(function() existing:close() end)
    end

    local ok, fh = pcall(io.open, logPath, "a")
    if not ok or not fh then
        trigger.action.outText("[RedFlagHitDetector] WARNING: could not open log '"
            .. tostring(logPath) .. "' — logging disabled.", 10)
        logPath = nil
        return
    end
    logHandle = fh
    if isNew then
        logHandle:write(CSV_HEADER .. "\n")
        logHandle:flush()
    end
end

local function writeLog(info)
    if not logHandle then return end
    local row = { timestamp(), info.player, info.unitType, info.shooter, info.category, info.weapon }
    for i = 1, #row do row[i] = csv(row[i]) end
    logHandle:write(table.concat(row, ",") .. "\n")
    logHandle:flush()
end

--------------------
-- Hit handler
--------------------
-- event.target can be a static object, scenery, or a weapon; only Units have
-- getPlayerName(). Returns the player's name, or nil for anything else.
local function playerNameOf(obj)
    if not obj then return nil end
    local ok, name = pcall(function()
        if Object.getCategory(obj) ~= Object.Category.UNIT then return nil end
        return obj:getPlayerName()
    end)
    if ok then return name end
    return nil
end

local HitHandler = {}

local function handleHit(event)
    if event.id ~= world.event.S_EVENT_HIT then return end

    local target    = event.target
    local initiator = event.initiator
    local weapon    = event.weapon

    local playerName = playerNameOf(target)
    if not playerName then return end  -- AI, static, scenery or no target: ignore

    -- Filters
    if weapon and not categoryAllowed(weaponCategory(weapon)) then return end
    if isCollision(initiator) then return end
    if isSelfFire(initiator, target) then return end
    if isFriendlyFire(initiator, target) then return end

    -- Anti-spam
    local now = getTime()
    if cooldown[playerName] and (now - cooldown[playerName]) < CONFIG.COOLDOWN_SECONDS then
        return
    end
    cooldown[playerName] = now

    local info = describeHit(target, initiator, weapon)

    -- 1) Targeted message + per-player sound (hit player only)
    local unitId = target:getID()
    trigger.action.outTextForUnit(unitId, CONFIG.PLAYER_MSG, CONFIG.PLAYER_MSG_DURATION, false)
    trigger.action.outSoundForUnit(unitId, CONFIG.PLAYER_SOUND)

    -- 2) White-cell / GM broadcast (visible to all players)
    local wcMsg = string.format(CONFIG.WC_MSG_FORMAT,
        info.player, info.unitType, info.shooter, info.category, info.weapon)
    trigger.action.outText(wcMsg, CONFIG.WC_MSG_DURATION)

    -- 3) CSV log
    writeLog(info)
end

-- Never let one bad event take the handler down; report to dcs.log instead.
function HitHandler:onEvent(event)
    local ok, err = pcall(handleHit, event)
    if not ok and env and env.error then
        env.error("[RedFlagHitDetector] hit handler error: " .. tostring(err))
    end
end

--------------------
-- Immortality
--------------------
-- NOTE: whether SetImmortal is honored for client (human) groups must be
-- confirmed in the mission editor / on the dev server.
local function makeGroupImmortal(group)
    if not group then return end
    local ctrl = group:getController()
    if ctrl then
        ctrl:setCommand({ id = "SetImmortal", params = { value = true } })
    end
end

local function setAllPlayersImmortal()
    if not CONFIG.SET_PLAYERS_IMMORTAL then return end
    local sides = { coalition.side.BLUE, coalition.side.RED }
    for _, side in ipairs(sides) do
        local groups = coalition.getGroups(side) or {}
        for _, group in ipairs(groups) do
            local units = group:getUnits() or {}
            for _, unit in ipairs(units) do
                if unit:getPlayerName() then
                    makeGroupImmortal(group)
                    break
                end
            end
        end
    end
end

-- In multiplayer, players occupy slots after the script has loaded, so the
-- sweep above usually finds nobody. Re-apply on every spawn / slot-in.
local PlayerHandler = {}
function PlayerHandler:onEvent(event)
    if not CONFIG.SET_PLAYERS_IMMORTAL then return end
    if event.id ~= world.event.S_EVENT_BIRTH
       and event.id ~= world.event.S_EVENT_PLAYER_ENTER_UNIT then
        return
    end
    local unit = event.initiator
    if not (unit and unit.getPlayerName and unit:getPlayerName()) then return end
    if unit.getGroup then makeGroupImmortal(unit:getGroup()) end
end

--------------------
-- Init + self-register
--------------------
-- Runs as soon as the script is loaded. A MISSION START "DO SCRIPT FILE"
-- trigger executes after S_EVENT_MISSION_START has already been dispatched,
-- so waiting for that event (as v3 did) means init never runs.
local function init()
    -- Logging is optional; a failure there must not skip immortality.
    local ok, err = pcall(openLog)
    if not ok then
        logHandle = nil
        if env and env.error then
            env.error("[RedFlagHitDetector] log setup error: " .. tostring(err))
        end
        trigger.action.outText("[RedFlagHitDetector] WARNING: log setup failed — logging disabled.", 10)
    end
    setAllPlayersImmortal()
    local msg = "[RedFlagHitDetector] Active"
    if logHandle then
        msg = msg .. " — logging to " .. logPath
    end
    trigger.action.outText(msg, 5)
end

world.addEventHandler(HitHandler)
world.addEventHandler(PlayerHandler)
init()
