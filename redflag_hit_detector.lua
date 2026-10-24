--[[
================================================================================
  RedFlag Hit Detector v3 (single-file)
  Rolling Thunder DCS Red Flag — Bryan / Hyperion
  Author: Joi (per spec 2026-09-06)

  Install:
    1. Copy this file into the mission's scripts/ folder (or mission root).
    2. In the mission editor, add a "DO SCRIPT FILE" trigger:
         Trigger:   MISSION START
         Action:    DO SCRIPT FILE
         File path: redflag_hit_detector_v3.lua
       The script self-registers; no hook script required.

  Behavior:
    1. On S_EVENT_MISSION_START:
         - Optional: applies SetImmortal=true to every human-player unit
           (CONFIG.SET_IMMORTAL_ON_START).
         - Opens the CSV log (CONFIG.LOG_FILE) and writes a header line.
    2. On S_EVENT_HIT:
         - Filters: player-only target, category allowlist, exclude collisions
           / self-fire / friendly fire (toggles in CONFIG).
         - Anti-spam: per-player cooldown (CONFIG.COOLDOWN_SECONDS).
         - Targeted "knock it off" message to the hit player
           (outTextForUnit + outSoundForUnit — only the hit player hears/sees).
         - Broadcast "[HIT]" line via outText (visible to all players, including
           the white cell / GM slots — standard DCS pattern).
         - Appends a row to the CSV log for GM review.

  Tested with: code review only. DCS server `bravo` is off-limits; v3 must be
  validated in the mission editor on the dev machine before event use.
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
    WC_MSG_FORMAT          = "[HIT] %s in %s by %s \u2014 %s (%s)",

    -- ===== Sound (played only for the hit player) =====
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
    -- CSV log file. Relative paths resolve to the mission folder in DCS.
    -- Set to nil to disable logging.
    LOG_FILE               = "redflag_hits.csv",

    -- ===== Immortal =====
    SET_IMMORTAL_ON_START  = true,  -- apply SetImmortal=true to all human-player units at mission start
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
local logHandle = nil

local function openLog()
    if not CONFIG.LOG_FILE then return end
    logHandle = io.open(CONFIG.LOG_FILE, "a")
    if logHandle then
        logHandle:write("timestamp,player_name,unit_type,initiator,weapon_category,weapon_name\n")
        logHandle:write("# log opened " .. os.date("%Y-%m-%dT%H:%M:%S") .. "\n")
        logHandle:flush()
    else
        trigger.action.outText(
            "[RedFlagHitDetector] WARNING: could not open log '" .. tostring(CONFIG.LOG_FILE)
            .. "' \u2014 logging disabled.",
            5)
    end
end

local function writeLog(playerName, target, weapon, initiator)
    if not logHandle then return end
    local ts       = os.date("%Y-%m-%dT%H:%M:%S")
    local unitType = (target and target.getTypeName and target:getTypeName()) or "?"
    local initName = "world"
    if initiator then
        initName = initiator.getName and initiator:getName()
        if not initName and initiator.getPlayerName then initName = initiator:getPlayerName() end
        if not initName then initName = "unknown" end
    end
    local cat     = (weapon and weapon.getCategory and weapon:getCategory()) or -1
    local catName = WEAPON_CATEGORY_NAMES[cat] or "Threat"
    local wpnName = (weapon and weapon.getName and weapon:getName()) or "simulated"
    logHandle:write(string.format("%s,%s,%s,%s,%s,%s\n",
        ts, playerName, unitType, initName, catName, wpnName))
    logHandle:flush()
end

--------------------
-- Hit handler
--------------------
local HitHandler = {}
HitHandler.__index = HitHandler

function HitHandler:onEvent(event)
    if event.id ~= world.event.S_EVENT_HIT then return end

    local target    = event.target
    local initiator = event.initiator
    local weapon    = event.weapon

    if not target then return end
    local playerName = target:getPlayerName()
    if not playerName then return end  -- AI hit, ignore

    -- Filters
    if weapon and not categoryAllowed(weapon:getCategory()) then return end
    if isCollision(initiator) then return end
    if isSelfFire(initiator, target) then return end
    if isFriendlyFire(initiator, target) then return end

    -- Anti-spam
    local now = getTime()
    if cooldown[playerName] and (now - cooldown[playerName]) < CONFIG.COOLDOWN_SECONDS then
        return
    end
    cooldown[playerName] = now

    -- Build context strings for the white-cell message + log
    local unitType  = target:getTypeName() or "aircraft"
    local initName  = "world"
    if initiator then
        initName = initiator.getName and initiator:getName()
        if not initName and initiator.getPlayerName then initName = initiator:getPlayerName() end
        if not initName then initName = "unknown" end
    end
    local cat      = (weapon and weapon:getCategory()) or -1
    local catName  = WEAPON_CATEGORY_NAMES[cat] or "Threat"
    local wpnName  = (weapon and weapon:getName()) or "simulated"

    -- 1) Targeted message + per-player sound (hit player only)
    local unitId = target:getID()
    trigger.action.outTextForUnit(unitId, CONFIG.PLAYER_MSG, CONFIG.PLAYER_MSG_DURATION, false)
    trigger.action.outSoundForUnit(unitId, CONFIG.PLAYER_SOUND)

    -- 2) White-cell / GM broadcast (visible to all players)
    local wcMsg = string.format(CONFIG.WC_MSG_FORMAT,
        playerName, unitType, initName, catName, wpnName)
    trigger.action.outText(wcMsg, CONFIG.WC_MSG_DURATION)

    -- 3) CSV log
    writeLog(playerName, target, weapon, initiator)
end

--------------------
-- Mission start: immortal + log
--------------------
local function setAllPlayersImmortal()
    if not CONFIG.SET_IMMORTAL_ON_START then return end
    local sides = { coalition.side.BLUE, coalition.side.RED }
    for _, side in ipairs(sides) do
        local groups = coalition.getGroups(side) or {}
        for _, group in ipairs(groups) do
            local units = group:getUnits() or {}
            for _, unit in ipairs(units) do
                if unit:getPlayerName() then
                    local ctrl = group:getController()
                    if ctrl then
                        ctrl:setCommand({
                            id = "SetImmortal",
                            params = { value = true },
                        })
                    end
                end
            end
        end
    end
end

--------------------
-- Init + self-register
--------------------
-- Runs as soon as the script is loaded. A MISSION START "DO SCRIPT FILE"
-- trigger executes after S_EVENT_MISSION_START has already been dispatched,
-- so waiting for that event (as v3 did) means init never runs.
local function init()
    openLog()
    setAllPlayersImmortal()
    local msg = "[RedFlagHitDetector] Active"
    if logHandle then
        msg = msg .. " \u2014 logging to " .. CONFIG.LOG_FILE
    end
    trigger.action.outText(msg, 5)
end

world.addEventHandler(HitHandler)
init()
