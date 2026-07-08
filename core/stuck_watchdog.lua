-- Stuck-recovery watchdog.
--
-- Detects "we are stuck / not making progress" and recovers by disabling all
-- managed activity plugins, teleporting the player to Temis, and re-arming
-- WarPigs so the next WarPlans match goes through the full cold-start
-- preamble. Designed to catch failure modes the orchestrator's normal disable/
-- enable state machine doesn't escape on its own — e.g. an Alfred cycle that
-- hangs on a missing stash item, a HordeDev "Walking to Horde" that never
-- arrives, a Reaper rotation that loops on an altar interact, a death+revive
-- flow that lands far from any quest and never resumes.
--
-- Signal: player world position has not moved more than STUCK_RADIUS yards
-- for >= timeout seconds. Two tiers:
--
--   SOFT_TIMEOUT — fires only when NO "fragile / expected stationary" state
--     is in progress (Alfred actively processing, HordeDev mid-chest-interact,
--     Reaper mid-interact, WarPigs orchestrator in a transition state). This
--     tier catches "the bot stopped and there is no good reason for it".
--
--   HARD_TIMEOUT — fires REGARDLESS of fragile state. Catches deadlocks INSIDE
--     those expected-stationary states themselves (Alfred restock cycle that
--     can't clear, HordeDev hung mid-cycle, TEMIS_ALFRED step that never
--     exits, Reaper altar lockout that fails to release).
--
-- The watchdog does NOT trigger when the bot has nothing to do — no active
-- WarPlans quest match, no owned plugin, no in-flight transition. Sitting at
-- Temis between WarPlans cycles is not "stuck", it's "waiting".
--
-- A POST_RECOVERY_GRACE window after each recovery ignores movement so the
-- teleport + plugin re-enable cycle has time to settle before the next
-- evaluation window starts.

local alfred_coord = require 'core.orchestrator.alfred_coordination'
local resolver     = require 'core.plugin_resolver'

local M = {}

-- Tuning.
local STUCK_RADIUS         = 6.0      -- yards
local SOFT_TIMEOUT_SECS    = 150.0    -- 2.5 min, fragile-state-aware
local HARD_TIMEOUT_SECS    = 420.0    -- 7 min, unconditional
local POST_RECOVERY_GRACE  = 60.0     -- ignore movement / timeouts after recovery
local LOG_INTERVAL         = 30.0     -- verbose log cadence

-- Anchor state.
local anchor_x, anchor_y   = nil, nil
local anchor_since         = nil
local last_recovery_at     = -math.huge
local last_status_log      = -math.huge
local last_status_msg      = nil

-- Init-time callbacks (filled by M.init).
local cb_recover           = nil
local cb_snapshot          = nil
local cb_log               = function(msg) console.print('[WarPigs] ' .. msg) end
local cb_verbose           = function() return false end

local function get_player_xy()
    if not get_local_player then return nil end
    local lp = get_local_player()
    if not lp then return nil end
    local ok, p = pcall(function() return lp:get_position() end)
    if not ok or not p then return nil end
    local okx, x = pcall(function() return p:x() end)
    local oky, y = pcall(function() return p:y() end)
    if not okx or not oky then return nil end
    return x, y
end

-- Plugin status surfaces that mean "actively doing a fragile thing the player
-- is supposed to be standing still for". Returns a label string or nil.
local function fragile_reason(snap)
    if snap and snap.transition_state and snap.transition_state ~= 'IDLE' then
        return 'wp_transition:' .. tostring(snap.transition_state)
    end
    local alfred = alfred_coord.get_plugin()
    if alfred and type(alfred.get_status) == 'function' then
        local ok, s = pcall(alfred.get_status)
        if ok and type(s) == 'table' then
            if s.external_trigger or s.trigger_tasks then return 'alfred_busy' end
        end
    end
    local horde = resolver.get_plugin_instance('horde')
    if horde and type(horde.getState) == 'function' then
        local ok, st = pcall(horde.getState)
        if ok and st == 'OPENING_CHESTS' then return 'horde_chests' end
    end
    local reaper = resolver.get_plugin_instance('boss')
    if reaper and type(reaper.status) == 'function' then
        local ok, s = pcall(reaper.status)
        if ok and type(s) == 'table' and type(s.task) == 'table' then
            local n = s.task.name
            if n == 'Open Chest' or n == 'Interact Altar' or n == 'Loot Boss' then
                return 'reaper_interact:' .. tostring(n)
            end
        end
    end
    return nil
end

-- "Does the bot have something to do right now?" If not, no anchor — being
-- stationary is correct behavior.
local function has_active_goal(snap)
    if not snap then return false end
    if snap.have_active_quest then return true end
    if snap.have_owned        then return true end
    if snap.teleport_pending  then return true end
    if snap.transition_state and snap.transition_state ~= 'IDLE' then return true end
    return false
end

function M.init(opts)
    cb_recover  = opts.recover
    cb_snapshot = opts.snapshot
    if opts.log     then cb_log     = opts.log     end
    if opts.verbose then cb_verbose = opts.verbose end
end

function M.reset()
    anchor_x, anchor_y, anchor_since = nil, nil, nil
    last_status_log = -math.huge
    last_status_msg = nil
end

function M.mark_recovery(t)
    last_recovery_at = t or get_time_since_inject()
    anchor_x, anchor_y, anchor_since = nil, nil, nil
end

function M.tick(now)
    if not cb_recover then return end

    if (now - last_recovery_at) < POST_RECOVERY_GRACE then
        anchor_x, anchor_y, anchor_since = nil, nil, nil
        return
    end

    local snap = cb_snapshot and cb_snapshot() or nil
    if not has_active_goal(snap) then
        anchor_x, anchor_y, anchor_since = nil, nil, nil
        return
    end

    local x, y = get_player_xy()
    if not x then return end

    if not anchor_since then
        anchor_x, anchor_y, anchor_since = x, y, now
        return
    end

    local dx, dy = x - anchor_x, y - anchor_y
    if (dx * dx + dy * dy) >= (STUCK_RADIUS * STUCK_RADIUS) then
        anchor_x, anchor_y, anchor_since = x, y, now
        if cb_verbose() then
            cb_log(string.format(
                'stuck_watchdog: progress detected — anchor reset (moved %.1fy)',
                math.sqrt(dx * dx + dy * dy)))
        end
        return
    end

    local age     = now - anchor_since
    local fragile = fragile_reason(snap)

    if cb_verbose() and (now - last_status_log) >= LOG_INTERVAL then
        last_status_log = now
        local msg = string.format(
            'stuck_watchdog: anchor age %.0fs (fragile=%s, soft_in=%.0fs, hard_in=%.0fs)',
            age, fragile or 'none',
            math.max(0, SOFT_TIMEOUT_SECS - age),
            math.max(0, HARD_TIMEOUT_SECS - age))
        if msg ~= last_status_msg then
            cb_log(msg)
            last_status_msg = msg
        end
    end

    if age >= HARD_TIMEOUT_SECS then
        local reason = string.format(
            'hard-stuck %.0fs (fragile=%s)', age, fragile or 'none')
        anchor_x, anchor_y, anchor_since = nil, nil, nil
        last_recovery_at = now
        pcall(cb_recover, reason)
        return
    end

    if age >= SOFT_TIMEOUT_SECS and not fragile then
        local reason = string.format('soft-stuck %.0fs (no fragile state)', age)
        anchor_x, anchor_y, anchor_since = nil, nil, nil
        last_recovery_at = now
        pcall(cb_recover, reason)
        return
    end
end

function M.get_status()
    return {
        anchor_since     = anchor_since,
        anchor_x         = anchor_x,
        anchor_y         = anchor_y,
        last_recovery_at = last_recovery_at,
        soft_timeout     = SOFT_TIMEOUT_SECS,
        hard_timeout     = HARD_TIMEOUT_SECS,
    }
end

return M
