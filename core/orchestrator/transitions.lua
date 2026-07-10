-- Via-Temis-Alfred preamble + warplan.teleport_to_activity state machine.
-- Extracted from orchestrator.lua to keep tick() under Lua 5.1 upvalue limits.

local alfred_coord = require 'core.orchestrator.alfred_coordination'
local raven_coord  = require 'core.orchestrator.raven_coordination'
local resolver     = require 'core.plugin_resolver'
local navigation   = require 'core.navigation'

local M = {}

local TEMIS_WP                    = 0x1CE51E
local TEMIS_ZONE                  = 'Skov_Temis'
local TEMIS_TELEPORT_TIMEOUT      = 30.0
local TEMIS_TELEPORT_DEBOUNCE     = 6.0
local TEMIS_LINGER_RETRY_INTERVAL = 3.0
-- After this many timed-out Temis waypoint retries, abandon the preamble and
-- go straight to warplan teleport (or IDLE). Stops the overlay sitting on
-- "transition TO_TEMIS" forever when the channel keeps getting cancelled.
local TEMIS_MAX_TIMEOUT_RETRIES   = 5
local ALFRED_MIN_DWELL              = 6.0
local ALFRED_PICKUP_TIMEOUT         = 8.0
local ALFRED_MAX_SECONDS            = 180.0
local POST_ALFRED_SETTLE_SECONDS    = 3.0
local TELEPORT_CHECK_INTERVAL       = 3.0
local TELEPORT_INCOMING_SETTLE     = 2.5
-- Safety net when arrived_when misses mid-run (or warplan teleport is a no-op):
-- stop endless "world/zone unchanged" retries and release the enable gate.
local TELEPORT_MAX_UNCHANGED_RETRIES = 5
local RAVEN_NPC_POSITION  = { x = 2596.38, y = -495.79, z = 30.52 }
local CROW_ARRIVAL_RADIUS = 3.5
local CROW_WALK_TIMEOUT   = 30.0

local PREAMBLE_STATES = {
    TO_TEMIS             = true,
    TEMIS_ALFRED         = true,
    POST_ALFRED_SETTLE   = true,
    TEMIS_SILENT_RAVEN   = true,
    POST_SR_HELLTIDE_HOLD = true,
}

local function in_temis_preamble(state)
    return PREAMBLE_STATES[state] == true
end

local function in_temis()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, zname = pcall(function() return w:get_current_zone_name() end)
    return ok2 and zname == TEMIS_ZONE
end

-- Edge-triggered so we pause/resume SR once per handoff phase, not every tick.
local town_mutex_mode = 'idle'

local function sync_town_mutex(settings, tt, orchestrator, alfred_idle)
    local s = tt.state
    local desired = 'idle'

    if settings.use_silent_raven and s == 'TEMIS_SILENT_RAVEN' then
        desired = 'sr_active'
    elseif raven_coord.player_in_town() then
        local handoff = in_temis_preamble(s)
            or (s == 'IDLE' and M.teleport_pending)
        if handoff then
            local alfred_phase = s == 'TEMIS_ALFRED' or s == 'POST_ALFRED_SETTLE'
                or (s == 'TO_TEMIS' and in_temis())
            local waiting_alfred = s == 'IDLE' and M.teleport_pending and not alfred_idle()
            if alfred_phase or waiting_alfred then
                desired = 'alfred_active'
            end
        end
    end

    if desired == town_mutex_mode then return end
    town_mutex_mode = desired

    if desired == 'sr_active' then
        orchestrator._alfred_pause()
        raven_coord.hold('transition_sr')
        raven_coord.resume()
    elseif desired == 'alfred_active' then
        raven_coord.pause()
    else
        if not raven_coord.is_held() then
            raven_coord.unpause_if_ours()
        end
    end
end

M.teleport_transition = {
    state             = 'IDLE',
    started_at        = -math.huge,
    snap_world        = nil,
    snap_zone         = nil,
    last_temis_tp     = -math.huge,
    alfred_fired_at   = nil,
    alfred_was_busy   = false,
    settle_started_at = nil,
    settle_rearm_logged   = false,
    helltide_hold_logged  = false,
    silent_raven_fired_at = nil,
    silent_raven_result   = nil,
    crow_walk_started_at  = nil,
}

M.teleport_pending             = false
M.teleport_incoming_first_seen = nil
M.teleport_holding_key         = nil   -- stable dedup key (reason strings with countdowns change every tick)
M.teleport_limbo_logged        = false
M.teleport_rearm_logged        = false
M.temis_hold_for_chest_logged  = nil
M.had_active_session           = false

-- Holding reasons that embed live countdowns must not be used as log dedup keys.
local function teleport_holding_key(reason)
    if reason:find('settling incoming', 1, true) then return 'settling_incoming' end
    if reason:find('reaper watchdog post%-disable hold', 1, true) then return 'reaper_watchdog_hold' end
    return reason
end

local function crow_walk(action, started_at, now)
    if action == 'clear' then
        navigation.clear_target()
        return
    end
    return navigation.walk_toward(RAVEN_NPC_POSITION, started_at, now, {
        arrival_radius     = CROW_ARRIVAL_RADIUS,
        timeout            = CROW_WALK_TIMEOUT,
        disable_spell_dist = 4,
    })
end

M.teleport_transition.crow_walk = crow_walk

local function in_bsk_world()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, wname = pcall(function() return w:get_name() end)
    return ok2 and type(wname) == 'string' and wname:find('BSK', 1, true) ~= nil
end

local function horde_teleport_block_reason()
    local p = resolver.get_plugin_instance('horde')
    if p and type(p.getState) == 'function' and in_bsk_world() then
        local ok, state = pcall(p.getState)
        if ok and state == 'OPENING_CHESTS' then return 'opening_chests' end
    end
    local AETHER_BLOCK_THRESHOLD = 50
    if in_bsk_world() and type(get_aether_count) == 'function' then
        local ok, count = pcall(get_aether_count)
        if ok and type(count) == 'number' and count >= AETHER_BLOCK_THRESHOLD then
            return 'has_aether'
        end
    end
    return false
end

function M.reset()
    navigation.clear_target()
    navigation.stop_whirlwind_for_teleport('warpigs_shutdown')
    town_mutex_mode                = 'idle'
    M.teleport_pending             = false
    M.teleport_incoming_first_seen = nil
    M.teleport_holding_key         = nil
    M.teleport_limbo_logged        = false
    M.teleport_rearm_logged        = false
    M.temis_hold_for_chest_logged  = nil
    M.had_active_session           = false
    local tt = M.teleport_transition
    tt.state             = 'IDLE'
    tt.started_at        = -math.huge
    tt.snap_world        = nil
    tt.snap_zone         = nil
    tt.last_temis_tp     = -math.huge
    tt.alfred_fired_at   = nil
    tt.alfred_was_busy   = false
    tt.settle_started_at = nil
    tt.settle_rearm_logged   = false
    tt.helltide_hold_logged  = false
    tt.silent_raven_fired_at = nil
    tt.silent_raven_result   = nil
    tt.crow_walk_started_at  = nil
    tt.temis_timeout_retries = 0
    tt.teleport_unchanged_retries = 0
    raven_coord.reset_session()
end

function M.abort_on_death(log_fn)
    town_mutex_mode = 'idle'
    if M.teleport_transition.state ~= 'IDLE' then
        if log_fn then
            log_fn('died mid-transition (state=' .. M.teleport_transition.state ..
                ') — re-arming teleport sequence for after respawn')
        end
        M.teleport_transition.state             = 'IDLE'
        M.teleport_transition.started_at        = -math.huge
        M.teleport_transition.alfred_fired_at   = nil
        M.teleport_transition.alfred_was_busy   = false
        M.teleport_transition.settle_started_at = nil
        M.teleport_transition.settle_rearm_logged   = false
        M.teleport_transition.helltide_hold_logged  = false
        M.teleport_transition.silent_raven_fired_at = nil
        M.teleport_transition.silent_raven_result   = nil
        M.teleport_transition.crow_walk_started_at  = nil
        raven_coord.reset_session()
        M.teleport_pending = true
        M.teleport_incoming_first_seen = nil
        M.teleport_holding_key         = nil
        M.teleport_limbo_logged        = false
        M.teleport_rearm_logged        = false
    end
end

function M.get_gate_reason()
    if M.teleport_transition.state ~= 'IDLE' then
        return 'teleport transition: ' .. M.teleport_transition.state
    end
    if M.teleport_pending then
        return 'teleport pending (waiting for prerequisites)'
    end
    return nil
end

-- ctx: orchestrator tick context (see orchestrator.tick).
function M.process_tick(ctx)
    if ctx.settings and type(ctx.settings.is_active) == 'function'
        and not ctx.settings.is_active()
    then
        return
    end

    local now          = ctx.now
    local wants        = ctx.wants
    local matches      = ctx.matches
    local pending_disable = ctx.pending_disable
    local settings     = ctx.settings
    local log          = ctx.log
    local orchestrator = ctx.orchestrator
    local tt           = M.teleport_transition

    local function alfred_idle() return alfred_coord.idle() end
    local function alfred_kick_if_needed() alfred_coord.kick_if_needed(log) end
    local function alfred_trigger_now() return alfred_coord.trigger_now() end

    alfred_coord.set_kick_blocked(function()
        return in_temis_preamble(tt.state)
            or (settings.use_silent_raven and raven_coord.is_running())
    end)

    local function start_warplan_teleport(wants_, now_)
        if ctx.incoming_is_helltide(wants_) then
            log('teleport skipped — incoming is helltide; HelltideRevamped search_helltide handles zone navigation')
            tt.state = 'IDLE'
            return
        end
        local task_only_incoming = next(wants_) == nil
        local already_arrived = false
        for _, entry in pairs(wants_) do
            if type(entry.arrived_when) == 'function' and entry.arrived_when() then
                already_arrived = true
                break
            end
        end
        if task_only_incoming then
            log('teleport skipped — incoming is task-only (handles own navigation)')
            tt.state = 'IDLE'
        elseif already_arrived then
            log('teleport skipped — quest actor present, already at destination')
            tt.state = 'IDLE'
        else
            tt.state      = 'TELEPORTING'
            tt.started_at = now_
            tt.teleport_unchanged_retries = 0
            M.teleport_limbo_logged = false
            if _G.warplan and type(warplan.teleport_to_activity) == 'function' then
                local snap_w = get_current_world()
                tt.snap_world = snap_w and snap_w:get_name()
                tt.snap_zone  = snap_w and snap_w:get_current_zone_name()
                orchestrator._stop_whirlwind()
                warplan.teleport_to_activity()
                log(string.format(
                    'warplan.teleport_to_activity() called — world=%s zone=%s check_in=%.1fs',
                    tostring(tt.snap_world),
                    tostring(tt.snap_zone),
                    TELEPORT_CHECK_INTERVAL))
            else
                log('warplan.teleport_to_activity not available — skipping teleport')
                tt.state = 'IDLE'
            end
        end
    end

    if settings.use_teleport_transition
        and M.teleport_pending
        and tt.state == 'IDLE'
    then
        local has_incoming = next(wants) ~= nil
        if not has_incoming then
            for pattern, raw_entry in pairs(ctx.quest_plugin_map) do
                if matches[pattern] then
                    local entry = ctx.normalize(raw_entry)
                    if entry.task then has_incoming = true; break end
                end
            end
        end
        if not has_incoming then
            M.teleport_incoming_first_seen = nil
        elseif M.teleport_incoming_first_seen == nil then
            M.teleport_incoming_first_seen = now
            log(string.format('teleport: incoming activity matched, settling for %.1fs',
                TELEPORT_INCOMING_SETTLE))
        end
        local incoming_settled = M.teleport_incoming_first_seen
            and (now - M.teleport_incoming_first_seen) >= TELEPORT_INCOMING_SETTLE
        alfred_kick_if_needed()
        local alfred_done = (not in_temis()) or alfred_idle()
        local in_helltide_combat = ctx.has_helltide_buff()
            and ctx.enemies_near_player()
            and not ctx.helltide_lingering_post_quest(wants)
        local has_pending = next(pending_disable) ~= nil
        local watchdog_hold_active = ctx.reaper_altar_watchdog.hold_until > now
        local horde_block    = horde_teleport_block_reason()
        local horde_chesting = horde_block == 'opening_chests'
        local horde_aether   = horde_block == 'has_aether'
        local ready = has_incoming and incoming_settled and alfred_done
            and not has_pending and not in_helltide_combat
            and not watchdog_hold_active and not horde_block
        if not ready then
            local reason
            if not has_incoming then
                reason = 'no incoming activity yet'
            elseif horde_aether then
                reason = 'player still holding aether — HordeDev must spend all aether before preamble'
            elseif horde_chesting then
                reason = 'HordeDev is opening chests — chest interact is fragile, refusing to fire Temis preamble'
            elseif has_pending then
                local pname = next(pending_disable)
                reason = 'waiting for ' .. tostring(pname) .. ' to finish (deferred disable)'
            elseif not alfred_done then
                reason = 'Alfred busy (loot/salvage in progress)'
            elseif in_helltide_combat then
                reason = 'in helltide combat — waiting for area to clear before teleport'
            elseif watchdog_hold_active then
                reason = string.format('reaper watchdog post-disable hold (%.1fs left)',
                    ctx.reaper_altar_watchdog.hold_until - now)
            else
                local left = TELEPORT_INCOMING_SETTLE - (now - M.teleport_incoming_first_seen)
                reason = string.format('settling incoming (%.1fs left)', left)
            end
            local hold_key = teleport_holding_key(reason)
            if M.teleport_holding_key ~= hold_key then
                log('teleport holding — ' .. reason)
                M.teleport_holding_key = hold_key
            end
        else
            M.teleport_pending             = false
            M.teleport_incoming_first_seen = nil
            M.teleport_holding_key         = nil
            if ctx.player_in_undercity and ctx.player_in_undercity() then
                log('teleport skipped — player already in Undercity dungeon')
                tt.state = 'IDLE'
            elseif ctx.player_in_pit and ctx.player_in_pit() then
                log('teleport skipped — player already in Pit')
                tt.state = 'IDLE'
            elseif ctx.player_in_boss_lair and ctx.player_in_boss_lair() then
                log('teleport skipped — player already in boss lair')
                tt.state = 'IDLE'
            elseif ctx.incoming_is_helltide(wants)
                and (ctx.is_plugin_on(ctx.helltide_plugin_name()) or ctx.has_helltide_buff())
            then
                log('teleport skipped — incoming is helltide and helltide plugin is already running / in helltide zone')
                tt.state = 'IDLE'
            else
                local can_temis_detour = type(teleport_to_waypoint) == 'function'
                if can_temis_detour and in_temis() then
                    if alfred_trigger_now() then
                        tt.state             = 'TEMIS_ALFRED'
                        tt.started_at        = now
                        tt.alfred_fired_at   = now
                        tt.alfred_was_busy   = false
                        tt.settle_started_at = nil
                        log('via-Temis preamble: already in Temis — entering Alfred step')
                    else
                        tt.state                 = 'TEMIS_SILENT_RAVEN'
                        tt.started_at            = now
                        tt.silent_raven_fired_at = nil
                        tt.silent_raven_result   = nil
                        tt.crow_walk_started_at  = nil
                        log('via-Temis preamble: already in Temis, Alfred unavailable — entering SilentRaven step')
                    end
                elseif can_temis_detour then
                    if (now - tt.last_temis_tp) >= TEMIS_TELEPORT_DEBOUNCE then
                        orchestrator._stop_whirlwind()
                        teleport_to_waypoint(TEMIS_WP)
                        tt.last_temis_tp = now
                    end
                    tt.state      = 'TO_TEMIS'
                    tt.started_at = now
                    tt.temis_timeout_retries = 0
                    log('via-Temis preamble: teleport_to_waypoint(Temis) sent')
                else
                    start_warplan_teleport(wants, now)
                end
            end
        end
    end

    if tt.state == 'TO_TEMIS' then
        if ctx.player_in_undercity and ctx.player_in_undercity() then
            log('via-Temis preamble: cancelled — player in Undercity dungeon')
            tt.state = 'IDLE'
            M.teleport_pending = false
            tt.temis_timeout_retries = 0
        elseif ctx.player_in_pit and ctx.player_in_pit() then
            log('via-Temis preamble: cancelled — player in Pit')
            tt.state = 'IDLE'
            M.teleport_pending = false
            tt.temis_timeout_retries = 0
        elseif ctx.player_in_boss_lair and ctx.player_in_boss_lair() then
            log('via-Temis preamble: cancelled — player in boss lair')
            tt.state = 'IDLE'
            M.teleport_pending = false
            tt.temis_timeout_retries = 0
        elseif in_temis() then
            tt.temis_timeout_retries = 0
            if alfred_trigger_now() then
                tt.state             = 'TEMIS_ALFRED'
                tt.started_at        = now
                tt.alfred_fired_at   = now
                tt.alfred_was_busy   = false
                tt.settle_started_at = nil
                log('via-Temis preamble: arrived in Temis — entering Alfred step')
            else
                tt.state                 = 'TEMIS_SILENT_RAVEN'
                tt.started_at            = now
                tt.silent_raven_fired_at = nil
                tt.silent_raven_result   = nil
                tt.crow_walk_started_at  = nil
                log('via-Temis preamble: arrived in Temis, Alfred unavailable — entering SilentRaven step')
            end
        elseif horde_teleport_block_reason() == 'opening_chests' then
            if M.temis_hold_for_chest_logged ~= tt.started_at then
                log('via-Temis preamble: TO_TEMIS hold — HordeDev is opening chests, refusing to retry waypoint')
                M.temis_hold_for_chest_logged = tt.started_at
            end
            tt.started_at = now
        elseif ctx.helltide_lingering_post_quest(wants)
            and (now - tt.last_temis_tp) >= TEMIS_LINGER_RETRY_INTERVAL
        then
            log('via-Temis preamble: helltide-lingering fast retry — re-firing waypoint')
            orchestrator._stop_whirlwind()
            teleport_to_waypoint(TEMIS_WP)
            tt.last_temis_tp = now
            tt.started_at    = now
        elseif (now - tt.started_at) >= TEMIS_TELEPORT_TIMEOUT then
            if (now - tt.last_temis_tp) >= TEMIS_TELEPORT_DEBOUNCE then
                tt.temis_timeout_retries = (tt.temis_timeout_retries or 0) + 1
                if tt.temis_timeout_retries >= TEMIS_MAX_TIMEOUT_RETRIES then
                    log(string.format(
                        'via-Temis preamble: TO_TEMIS gave up after %d timeouts — skipping to warplan teleport',
                        tt.temis_timeout_retries))
                    tt.temis_timeout_retries = 0
                    start_warplan_teleport(wants, now)
                else
                    log(string.format(
                        'via-Temis preamble: TO_TEMIS timeout — retrying waypoint (%d/%d)',
                        tt.temis_timeout_retries, TEMIS_MAX_TIMEOUT_RETRIES))
                    orchestrator._stop_whirlwind()
                    teleport_to_waypoint(TEMIS_WP)
                    tt.last_temis_tp = now
                    tt.started_at    = now
                end
            end
        end
    end

    if tt.state == 'TEMIS_SILENT_RAVEN' then
        orchestrator._alfred_pause()
        local sr    = settings.use_silent_raven and _G.SilentRavenPlugin or nil
        local sr_ok = sr and type(sr.is_available) == 'function' and sr.is_available()
        local sr_ready = false
        if sr_ok then
            local ok, s = pcall(sr.get_status)
            sr_ready = ok and type(s) == 'table' and s.ready == true
        end

        local function fire_sr()
            tt.crow_walk('clear')
            tt.silent_raven_fired_at = now
            tt.silent_raven_result   = nil
            local on_done = function(result) tt.silent_raven_result = result end
            pcall(sr.trigger_tasks_with_teleport, 'WarPigs', on_done)
        end

        local function proceed_after_sr()
            raven_coord.release('transition_sr')
            raven_coord.unpause_if_ours()
            if ctx.incoming_is_helltide(wants) and not ctx.helltide_active() then
                log('via-Temis preamble: SR done — holding warplan teleport, incoming is helltide, helltide is in off-window (minute 55-59)')
                tt.state                = 'POST_SR_HELLTIDE_HOLD'
                tt.helltide_hold_logged = true
            else
                start_warplan_teleport(wants, now)
            end
        end

        if not tt.silent_raven_fired_at then
            if not sr_ready then
                log('via-Temis preamble: SilentRaven not available / no Grim Favor ready — proceeding past SR step')
                tt.crow_walk('clear')
                tt.crow_walk_started_at = nil
                proceed_after_sr()
            else
                if not tt.crow_walk_started_at then
                    tt.crow_walk_started_at = now
                end
                local status, dist = tt.crow_walk('step', tt.crow_walk_started_at, now)
                if status == 'arrived' then
                    log(string.format(
                        'via-Temis preamble: at crow (dist=%.1f) — SilentRaven turn-in triggered (Grim Favor ready)',
                        dist))
                    fire_sr()
                elseif status == 'timeout' then
                    log(string.format(
                        'via-Temis preamble: crow walk timeout (dist=%.1f) — SilentRaven turn-in triggered anyway',
                        dist))
                    fire_sr()
                end
            end
        else
            local elapsed = now - tt.silent_raven_fired_at
            if tt.silent_raven_result then
                log(string.format(
                    'via-Temis preamble: SilentRaven finished (%s) — proceeding past SR step',
                    tostring(tt.silent_raven_result)))
                tt.silent_raven_fired_at = nil
                tt.crow_walk_started_at  = nil
                proceed_after_sr()
            elseif elapsed >= 120.0 then
                log(string.format(
                    'via-Temis preamble: SilentRaven timeout (%.0fs) — proceeding past SR step',
                    elapsed))
                tt.silent_raven_fired_at = nil
                tt.crow_walk_started_at  = nil
                proceed_after_sr()
            end
        end
    end

    if tt.state == 'POST_SR_HELLTIDE_HOLD' then
        if ctx.helltide_active() then
            log('via-Temis preamble: helltide window active again — proceeding to warplan teleport')
            tt.helltide_hold_logged = false
            start_warplan_teleport(wants, now)
        end
    end

    if tt.state == 'TEMIS_ALFRED' then
        local elapsed  = now - tt.alfred_fired_at
        local busy_now = not alfred_idle()
        if busy_now then tt.alfred_was_busy = true end
        local done = false
        if elapsed < ALFRED_MIN_DWELL then
            -- min dwell hold
        elseif tt.alfred_was_busy and not busy_now then
            done = true
            log('via-Temis preamble: Alfred finished its work')
        elseif elapsed >= ALFRED_PICKUP_TIMEOUT
            and not tt.alfred_was_busy
            and not busy_now
        then
            done = true
            log(string.format('via-Temis preamble: Alfred pickup timeout (%.1fs), proceeding', elapsed))
        elseif elapsed >= ALFRED_MAX_SECONDS then
            done = true
            log(string.format(
                'via-Temis preamble: Alfred max wait (%.0fs) exceeded — proceeding anyway', elapsed))
        end
        if done then
            tt.state                 = 'POST_ALFRED_SETTLE'
            tt.settle_started_at     = now
            tt.settle_rearm_logged   = false
            log(string.format(
                'via-Temis preamble: entering post-Alfred settle (%.1fs)',
                POST_ALFRED_SETTLE_SECONDS))
        end
    end

    if tt.state == 'POST_ALFRED_SETTLE' then
        local settled  = now - tt.settle_started_at
        local busy_now = not alfred_idle()
        if busy_now then
            if not tt.settle_rearm_logged then
                log('via-Temis preamble: Alfred re-armed during settle — back to TEMIS_ALFRED')
                tt.settle_rearm_logged = true
            end
            alfred_trigger_now()
            tt.state             = 'TEMIS_ALFRED'
            tt.alfred_fired_at   = now
            tt.alfred_was_busy   = true
            tt.settle_started_at = nil
        elseif settled >= POST_ALFRED_SETTLE_SECONDS then
            log(string.format(
                'via-Temis preamble: post-Alfred settle clear (%.1fs) — entering SilentRaven step',
                settled))
            orchestrator._alfred_pause()
            tt.alfred_fired_at       = nil
            tt.alfred_was_busy       = false
            tt.settle_started_at     = nil
            tt.state                 = 'TEMIS_SILENT_RAVEN'
            tt.started_at            = now
            tt.silent_raven_fired_at = nil
            tt.silent_raven_result   = nil
            tt.crow_walk_started_at  = nil
        end
    end

    if tt.state == 'TELEPORTING' then
        local blocking_pending
        for p in pairs(pending_disable) do blocking_pending = p; break end
        if blocking_pending then
            log('teleport aborted — deferred disable pending for ' .. tostring(blocking_pending))
            tt.state      = 'IDLE'
            tt.snap_world = nil
            tt.snap_zone  = nil
            M.teleport_pending           = false
            M.teleport_incoming_first_seen = nil
            M.teleport_holding_key       = nil
            M.teleport_limbo_logged      = false
            return 'aborted_limbo'
        elseif (now - tt.started_at) >= TELEPORT_CHECK_INTERVAL then
            local w         = get_current_world()
            local cur_world = w and w:get_name()
            local cur_zone  = w and w:get_current_zone_name()
            local in_limbo = cur_world == 'Limbo' or cur_zone == '[sno none]'
            if in_limbo then
                tt.started_at = now
                if not M.teleport_limbo_logged then
                    log(string.format(
                        'teleport in-flight — world=%s zone=%s, holding for load to finish',
                        tostring(cur_world), tostring(cur_zone)))
                    M.teleport_limbo_logged = true
                end
                return 'limbo'
            end
            M.teleport_limbo_logged = false
            local changed = cur_world ~= tt.snap_world or cur_zone ~= tt.snap_zone
            local arrived_now = false
            if not changed then
                for _, entry in pairs(wants) do
                    if type(entry.arrived_when) == 'function' and entry.arrived_when() then
                        arrived_now = true
                        break
                    end
                end
            end
            if ctx.incoming_is_helltide(wants) and not changed and not arrived_now then
                tt.state      = 'IDLE'
                tt.snap_world = nil
                tt.snap_zone  = nil
                tt.teleport_unchanged_retries = 0
                log('teleport released — helltide incoming; HelltideRevamped handles zone search (no warplan retry loop)')
            elseif changed or arrived_now then
                tt.state      = 'IDLE'
                tt.snap_world = nil
                tt.snap_zone  = nil
                tt.teleport_unchanged_retries = 0
                log(string.format('teleport confirmed (%s world=%s zone=%s) — releasing enable gate',
                    arrived_now and 'arrived_when' or 'world/zone',
                    tostring(cur_world), tostring(cur_zone)))
            else
                tt.teleport_unchanged_retries = (tt.teleport_unchanged_retries or 0) + 1
                if tt.teleport_unchanged_retries >= TELEPORT_MAX_UNCHANGED_RETRIES then
                    log(string.format(
                        'teleport gave up after %d unchanged retries (world=%s zone=%s) — releasing gate',
                        tt.teleport_unchanged_retries, tostring(cur_world), tostring(cur_zone)))
                    tt.state      = 'IDLE'
                    tt.snap_world = nil
                    tt.snap_zone  = nil
                    tt.teleport_unchanged_retries = 0
                else
                    tt.started_at = now
                    if _G.warplan and type(warplan.teleport_to_activity) == 'function' then
                        orchestrator._stop_whirlwind()
                        warplan.teleport_to_activity()
                        log(string.format(
                            'teleport retry — world/zone unchanged (world=%s zone=%s), retrying in %.1fs (%d/%d)',
                            tostring(cur_world), tostring(cur_zone), TELEPORT_CHECK_INTERVAL,
                            tt.teleport_unchanged_retries, TELEPORT_MAX_UNCHANGED_RETRIES))
                    else
                        tt.state      = 'IDLE'
                        tt.snap_world = nil
                        tt.snap_zone  = nil
                        tt.teleport_unchanged_retries = 0
                        log('teleport: warplan not available on retry — releasing gate')
                    end
                end
            end
        end
    end

    sync_town_mutex(settings, tt, orchestrator, alfred_idle)

    return nil
end

return M
