-- WarPigs internal task: when WarPlans_QST_TurnIn_Rewards is active,
-- teleport to Temis, walk to NPC_QST_Tyrael_NonCombat, and interact.
-- Resets to idle once the quest disappears (other tick logic detects the
-- transition and calls tick(false)).

local M = {}

local settings     = require 'core.settings'
local alfred_coord = require 'core.orchestrator.alfred_coordination'
local raven_coord  = require 'core.orchestrator.raven_coordination'
local navigation   = require 'core.navigation'

local TEMIS_WP   = 0x1CE51E       -- Skov_Temis waypoint sno (from existing plugins)
local TEMIS_ZONE = 'Skov_Temis'
local NPC_NAME    = 'NPC_QST_X2_Tyrael_NonCombat'
local VENDOR_NAME = 'Warplans_Vendor'  -- reroll war plan vendor

-- Hardcoded Tyrael standing position in Temis. The game moved the stash far
-- enough from him that he isn't in the actor list when we arrive at the WP,
-- so find_npc() returns nil. Walk to this position first; once we're within
-- the actor render radius we can look him up and interact normally.
local TYRAEL_NAV = { x = 2585.5, y = -488.9, z = 31.5 }

local INTERACT_DIST           = 2.0   -- close enough to interact_with_object directly
local INTERACT_COOLDOWN       = 1.5
local TELEPORT_TIMEOUT        = 30.0

local function stop_whirlwind_before_teleport()
    navigation.stop_whirlwind_for_teleport()
end
-- How long to wait for the dungeon-exit plugin to land us in town before we
-- give up and teleport ourselves. Covers the case where ArkhamAsylum (or
-- WonderCity / HordeDev) self-disabled inside the dungeon, leaving nobody to
-- navigate the player out.
local STUCK_NOT_IN_TOWN_SECS  = 20.0

local STATE = {
    IDLE         = 'IDLE',
    TELEPORTING  = 'TELEPORTING',
    WAIT_RAVEN   = 'WAIT_RAVEN',   -- SilentRaven whispers turn-in before Tyrael
    APPROACH_NPC = 'APPROACH_NPC',
}

local state         = STATE.IDLE
local state_entered = 0
local last_interact = -999
local last_diag     = -999
local raven_fired   = false   -- true once trigger_tasks has been called
local raven_result  = nil     -- set by the SilentRaven callback
-- Debounce for our own teleport_to_waypoint calls. Even with the state machine,
-- if the quest pattern flickers (matched true → false → true), tick(false)
-- resets state to IDLE and the next tick(true) re-fires the IDLE→teleport
-- branch. Without this, two teleport calls within ~5s cancel each other
-- mid-channel. 6s comfortably covers the channel.
local TELEPORT_DEBOUNCE_S     = 6.0
local last_teleport_time      = -math.huge
local stuck_not_in_town_since = nil

local DIAG_INTERVAL = 4.0  -- seconds between "NPC not found" diagnostic dumps

local function log(msg) console.print('[WarPigs:turn_in] ' .. msg) end
local function now() return get_time_since_inject() end

-- Returns true when Alfred has no pending work. Mirrors orchestrator's
-- alfred_idle() — we gate the turn-in here so we never teleport to Temis
-- while Alfred is mid-stash/salvage (that teleport would cancel Alfred's
-- return portal and cause item loss).
local function alfred_idle()
    return alfred_coord.idle()
end
local alfred_wait_logged = false

local function set_state(s)
    if s ~= state then
        if state == STATE.WAIT_RAVEN then
            raven_coord.release('turn_in')
            raven_coord.unpause_if_ours()
        end
        log('state ' .. state .. ' -> ' .. s)
        state         = s
        state_entered = now()
        if s == STATE.WAIT_RAVEN and settings.use_silent_raven then
            raven_coord.hold('turn_in')
            raven_coord.resume()
        end
    end
end

local function get_zone()
    local world = get_current_world()
    if not world then return '' end
    local ok, z = pcall(function() return world:get_current_zone_name() end)
    return (ok and type(z) == 'string') and z or ''
end

-- True if the player is currently in a town level area (any town — Cerrigar,
-- Temis, Kyovashad, Kurast, etc.). Mirrors orchestrator's in_town_disable_when:
-- we use the game's PLAYER_IN_TOWN_LEVEL_AREA attribute and treat any read
-- failure as "true" so we don't deadlock on API quirks. Used to gate the
-- IDLE->teleport branch so we don't fire while a dungeon plugin is still
-- exiting (their teleport_to_waypoint and ours would cancel each other).
local function in_town_attribute()
    local lp = get_local_player()
    if not lp then return false end
    if not _G.attributes or _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA == nil then
        return true
    end
    local ok, val = pcall(function()
        return lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1
    end)
    return ok and val == true
end

local function find_npc()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= 'table' then return nil end
    for _, actor in pairs(actors) do
        local ok, name = pcall(function() return actor:get_skin_name() end)
        if ok and name == NPC_NAME then return actor end
    end
    return nil
end

-- When the exact NPC name isn't found, dump nearby candidates so the user
-- can correct NPC_NAME if the in-game skin differs from what we expect.
local function diagnose_missing_npc()
    if (now() - last_diag) < DIAG_INTERVAL then return end
    last_diag = now()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= 'table' then
        log('NPC not found — actors_manager returned non-table.')
        return
    end
    local pp = get_player_position()
    local matches = {}
    for _, actor in pairs(actors) do
        local ok_n, name = pcall(function() return actor:get_skin_name() end)
        if ok_n and type(name) == 'string'
                and (name:find('Tyrael') or name:find('NPC_QST')) then
            local ok_p, pos = pcall(function() return actor:get_position() end)
            local d = (ok_p and pp) and pp:dist_to(pos) or -1
            matches[#matches+1] = string.format('  %s  dist=%.1f', name, d)
        end
    end
    if #matches == 0 then
        log('NPC not found. No nearby actors match Tyrael/NPC_QST. Looking for: ' .. NPC_NAME)
    else
        log('NPC "' .. NPC_NAME .. '" not found. Nearby candidates:')
        for _, line in ipairs(matches) do log(line) end
    end
end

function M.tick(active)
    if not active then
        if state ~= STATE.IDLE then
            log('Quest gone — resetting.')
            navigation.clear_target()
            set_state(STATE.IDLE)
        end
        stuck_not_in_town_since = nil
        alfred_wait_logged      = false
        raven_fired             = false
        raven_result            = nil
        return
    end

    if state == STATE.IDLE then
        -- Hold until Alfred has finished any pending stash/salvage work.
        -- Teleporting to Temis while Alfred is mid-run (trigger_tasks active
        -- or paused-with-work) cancels Alfred's return portal and causes
        -- item loss — items in transit never land back in inventory.
        if not alfred_idle() then
            if not alfred_wait_logged then
                log('waiting — Alfred busy (stash/salvage in progress)')
                alfred_wait_logged = true
            end
            return
        end
        alfred_wait_logged = false

        -- Keep Alfred parked so turn-in navigation owns Batmobile.
        alfred_coord.pause()

        if get_zone() == TEMIS_ZONE then
            if settings.use_silent_raven then
                log('Already in Temis — checking SilentRaven before Tyrael.')
                raven_fired  = false
                raven_result = nil
                set_state(STATE.WAIT_RAVEN)
            else
                log('Already in Temis — approaching Tyrael.')
                set_state(STATE.APPROACH_NPC)
            end
            return
        end
        -- Don't compete with a dungeon-exit teleport that's already in
        -- progress. ArkhamAsylum's exit_pit, WonderCity's exit_undercity,
        -- and HordeDev's exit_horde each fire their own teleport_to_waypoint
        -- when they're done with a run; if we also fire one here at the
        -- same time, the two cancel each other's channels and the player
        -- ends up running around interrupted in the dungeon. Wait for the
        -- dungeon plugin to land us in a town first, THEN if it isn't Temis
        -- we hop over.
        -- Escape hatch: if the exit plugin self-disabled inside the dungeon
        -- (e.g. ArkhamAsylum hit an internal error), nobody is driving the
        -- player out. After STUCK_NOT_IN_TOWN_SECS we teleport ourselves so
        -- the turn-in doesn't block forever.
        if not in_town_attribute() then
            stuck_not_in_town_since = stuck_not_in_town_since or now()
            local waited = now() - stuck_not_in_town_since
            if waited >= STUCK_NOT_IN_TOWN_SECS
               and (now() - last_teleport_time) >= TELEPORT_DEBOUNCE_S then
                log(string.format(
                    'Stuck outside town for %.0fs — escape-teleporting to Temis (exit plugin may be gone).',
                    waited))
                stop_whirlwind_before_teleport()
                teleport_to_waypoint(TEMIS_WP)
                last_teleport_time = now()
                set_state(STATE.TELEPORTING)
            end
            return
        end
        stuck_not_in_town_since = nil
        if (now() - last_teleport_time) < TELEPORT_DEBOUNCE_S then
            return  -- recent teleport channel still completing
        end
        log('Teleporting to Temis.')
        stop_whirlwind_before_teleport()
        teleport_to_waypoint(TEMIS_WP)
        last_teleport_time = now()
        set_state(STATE.TELEPORTING)
        return
    end

    if state == STATE.TELEPORTING then
        if get_zone() == TEMIS_ZONE then
            if settings.use_silent_raven then
                raven_fired  = false
                raven_result = nil
                set_state(STATE.WAIT_RAVEN)
            else
                set_state(STATE.APPROACH_NPC)
            end
            return
        end
        if (now() - state_entered) > TELEPORT_TIMEOUT then
            -- Same debounce applies on retry so the retry can't end up
            -- cancelling its own previous channel.
            if (now() - last_teleport_time) >= TELEPORT_DEBOUNCE_S then
                log('Teleport timeout — retrying.')
                stop_whirlwind_before_teleport()
                teleport_to_waypoint(TEMIS_WP)
                last_teleport_time = now()
            end
            state_entered = now()
        end
        return
    end

    if state == STATE.WAIT_RAVEN then
        local sr    = _G.SilentRavenPlugin
        local sr_ok = sr and type(sr.is_available) == 'function' and sr.is_available()
        local sr_ready = false
        if sr_ok then
            local ok, s = pcall(sr.get_status)
            sr_ready = ok and type(s) == 'table' and s.ready == true
        end

        if not raven_fired then
            if not sr_ready then
                log('SilentRaven not ready — proceeding to Tyrael.')
                set_state(STATE.APPROACH_NPC)
            else
                raven_fired  = true
                raven_result = nil
                log('SilentRaven turn-in triggered (Grim Favor ready).')
                local on_done = function(result) raven_result = result end
                -- _with_teleport: bypasses SR's per-zone latch (skipped_latched
                -- on repeat visits). SR no-ops the TP cast when already in Temis.
                pcall(sr.trigger_tasks_with_teleport, 'WarPigs', on_done)
            end
        else
            if raven_result then
                log('SilentRaven finished (' .. tostring(raven_result) .. ') — proceeding to Tyrael.')
                raven_fired = false
                set_state(STATE.APPROACH_NPC)
            elseif (now() - state_entered) >= 120.0 then
                log('SilentRaven timeout — proceeding to Tyrael.')
                raven_fired = false
                set_state(STATE.APPROACH_NPC)
            end
        end
        return
    end

    if state == STATE.APPROACH_NPC then
        if get_zone() ~= TEMIS_ZONE then
            log('Left Temis unexpectedly — teleporting back.')
            navigation.clear_target()
            stop_whirlwind_before_teleport()
            teleport_to_waypoint(TEMIS_WP)
            set_state(STATE.TELEPORTING)
            return
        end
        local pp = get_player_position()
        if not pp then return end

        -- Always navigate to the hardcoded Tyrael position. The actor isn't
        -- in actors_manager when we arrive at the WP (stash moved away from
        -- Tyrael), so we can't use the actor's live position to navigate.
        -- Once we're close, the actor enters render range and we interact.
        local npc      = find_npc()
        local nav_pos  = TYRAEL_NAV
        local nav_dist = pp:dist_to(vec3:new(nav_pos.x, nav_pos.y, nav_pos.z))

        if npc and nav_dist <= INTERACT_DIST then
            navigation.clear_target()
            if (now() - last_interact) >= INTERACT_COOLDOWN then
                log('Interacting with Tyrael.')
                loot_manager.interact_with_object(npc)
                last_interact = now()
            end
        else
            if not npc and nav_dist <= INTERACT_DIST then
                diagnose_missing_npc()
            end
            navigation.walk_toward(nav_pos, state_entered, now(), {
                arrival_radius     = INTERACT_DIST,
                timeout            = 120.0,
                disable_spell_dist = 4,
            })
        end
        return
    end
end

function M.get_state() return state end

return M
