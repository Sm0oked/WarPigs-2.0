local settings       = require 'core.settings'
local stuck_watchdog = require 'core.stuck_watchdog'
local registry       = require 'core.plugin_registry'
local resolver       = require 'core.plugin_resolver'
local alfred_coord   = require 'core.orchestrator.alfred_coordination'
local session_stats  = require 'core.session_stats'
local transitions    = require 'core.orchestrator.transitions'
local navigation     = require 'core.navigation'
local state_tracker  = require 'core.state_tracker'

local orchestrator = {}

orchestrator.ROLE_MARKERS = registry.ROLE_MARKERS

-- Helltide plugin resolver on the orchestrator table (not a chunk local) so
-- orchestrator.tick() does not pick up another upvalue — Lua 5.1 cap = 60.
orchestrator.HELLTIDE_PLUGIN_MARKER = registry.ROLE_MARKERS.helltide
orchestrator.helltide_plugin_name = function()
    return resolver.helltide_plugin_name()
end
orchestrator.helltide_plugin_is = resolver.helltide_plugin_is

alfred_coord.install_on(orchestrator)

-- Whirlwind teardown helper: Batmobile/Frigate's Whirlwind channel cast spam
-- (cast_spell.position every tick) cancels the 5s teleport_to_waypoint /
-- teleport_to_activity channel, so the bot gets stuck in the source zone.
-- Call before every teleport entry point. Probes both BatmobilePlugin and
-- FrigatePlugin via pcall so missing plugins / older versions don't error.
-- Stored on the orchestrator table (not a local function) so it doesn't add
-- a new upvalue to the giant orchestrator.tick() — Lua 5.1 has a 60-upvalue
-- function limit that tick() is already brushing against.
orchestrator._stop_whirlwind = function ()
    navigation.stop_whirlwind_for_teleport('warpigs')
end
orchestrator._whirlwind_stopped_outside_ht = false

-- ── transition sequencer ────────────────────────────────────────────────────
-- Goal: never have two activity plugins running at once and never start the
-- next plugin while the previous one is still wrapping up. Sequence per
-- handoff:
--   (1) Wait for outgoing plugin's disable_when() to return true
--       (e.g. Pit/WonderCity → back in town; Reaper → boss kill + 60s).
--   (2) Disable outgoing plugin.
--   (3) Wait TRANSITION_GAP_SECONDS for game state to settle.
--   (4) Enable incoming plugin.
-- MAX_DISABLE_DEFER_SECONDS is a safety cap so a stuck activity can't block
-- the orchestrator forever.
local TRANSITION_GAP_SECONDS    = 5
local MAX_DISABLE_DEFER_SECONDS = 120

-- Temis waypoint for stuck-recovery teleport (orchestrator.recover_from_stuck).
local TEMIS_WP = 0x1CE51E

local function in_bsk_world()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, wname = pcall(function() return w:get_name() end)
    return ok2 and type(wname) == 'string' and wname:find('BSK', 1, true) ~= nil
end

-- Scans all actors for a given skin name. Used by arrived_when predicates so
-- the orchestrator can confirm "we are at the quest destination" without
-- importing plugin-specific utils modules.
local function actor_present(skin_name)
    local ok, actors = pcall(function() return actors_manager:get_all_actors() end)
    if not ok or type(actors) ~= 'table' then return false end
    for _, actor in ipairs(actors) do
        local ok2, name = pcall(function() return actor:get_skin_name() end)
        if ok2 and name == skin_name then return true end
    end
    return false
end

-- Predicate: is the player in a town level area? Reused by Pit / WonderCity /
-- Helltide entries since "back in town" is the natural settle point for all
-- three. Returns true on any failure to read the attribute (don't block on
-- API quirks — MAX_DISABLE_DEFER_SECONDS is the real safety net).
local function in_town_disable_when()
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

-- Predicate: does the player currently have the Helltide buff (= we're inside
-- a helltide zone). Used as arrived_when for the Helltide WarPlans entry so
-- WarPigs skips warplan.teleport_to_activity() when we're already in the right
-- zone — without this, cold-start (or post-respawn re-arm) inside a helltide
-- fires the teleport which is a no-op (world/zone unchanged) and loops on
-- "teleport retry — world/zone unchanged" forever, fighting HR's chest /
-- patrol work the whole time.
local HELLTIDE_BUFF_HASH = 1066539
local function has_helltide_buff()
    local lp = get_local_player()
    if not lp then return false end
    local ok, buffs = pcall(function() return lp:get_buffs() end)
    if not ok or type(buffs) ~= 'table' then return false end
    for _, buff in ipairs(buffs) do
        local ok2, hash = pcall(function() return buff.name_hash end)
        if ok2 and hash == HELLTIDE_BUFF_HASH then return true end
    end
    return false
end

-- Predicate: is helltide currently active in-world? Mirrors HelltideRevamped's
-- `utils.helltide_active` (HelltideRevamped-0.4/core/utils.lua:139): minutes
-- 55-59 of every hour are the off-window when no helltide exists. Used to
-- hold the warplan teleport in POST_ALFRED_SETTLE when incoming is helltide
-- and we'd otherwise teleport into a helltide that doesn't exist yet.
local function helltide_active()
    local m = tonumber(os.date('%M'))
    if not m then return true end
    if m >= 55 and m <= 59 then return false end
    return true
end

-- Predicate: any wanted plugin in `wants_` is the active helltide plugin
-- Helltide handoff: BetterHelltide.pack exposes HelltideLitePlugin (enable/disable/status).
local function incoming_is_helltide(wants_)
    for _, entry in pairs(wants_) do
        if orchestrator.helltide_plugin_is(entry.plugin) then return true end
    end
    return false
end

-- Predicate: is the player already inside an Undercity dungeon zone? Mirrors
-- WonderCity's `utils.player_in_undercity` (zone name match `X1_Undercity_`).
-- Used as part of arrived_when for WarPlans_QST_Undercity so the orchestrator
-- recognises an in-progress run and stops re-firing warplan.teleport_to_activity()
-- — without this, mid-run teleport snapshots inside e.g. X1_Undercity_SnakeTemple_*
-- never confirm (brazier-only arrived_when can't see it deep in the dungeon),
-- and WarPigs loops on "teleport retry — world/zone unchanged" while WonderCity
-- is trying to do its job.
local function in_undercity_zone()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, zname = pcall(function() return w:get_current_zone_name() end)
    if not ok2 or type(zname) ~= 'string' then return false end
    return zname:match('X1_Undercity_') ~= nil
end

-- Mid-Pit: world name is always PIT_* (e.g. PIT_Ancients_Flooded); zone is
-- often PIT_Subzone on every floor. Without this, warplan teleport mid-run is
-- a no-op and TELEPORTING loops on "world/zone unchanged".
local function in_pit_zone()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local okw, wname = pcall(function() return w:get_name() end)
    if okw and type(wname) == 'string' and wname:match('^PIT_') then return true end
    local okz, zname = pcall(function() return w:get_current_zone_name() end)
    return okz and type(zname) == 'string' and zname:find('PIT_', 1, true) ~= nil
end

-- Mid boss-lair: Reaper zones/worlds use Boss_WT* prefixes (and Belial variants).
local function in_boss_lair_zone()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local function is_boss_name(s)
        return type(s) == 'string' and s:find('Boss_WT', 1, true) ~= nil
    end
    local okw, wname = pcall(function() return w:get_name() end)
    if is_boss_name(wname) then return true end
    local okz, zname = pcall(function() return w:get_current_zone_name() end)
    return is_boss_name(zname)
end

-- Predicate: are there live enemies close enough that the teleport channel
-- will be interrupted by incoming damage? Used to defer
-- warplan.teleport_to_activity() out of a helltide zone — once the rotation
-- plugin clears the area, this returns false and the teleport fires
-- immediately on the next tick.
local COMBAT_NEARBY_RANGE = 12
local function enemies_near_player()
    if not _G.target_selector or type(target_selector.get_near_target_list) ~= 'function' then
        return false
    end
    local lp = get_local_player()
    if not lp then return false end
    local ok_pos, pos = pcall(function() return lp:get_position() end)
    if not ok_pos or not pos then return false end
    local ok, list = pcall(target_selector.get_near_target_list, pos, COMBAT_NEARBY_RANGE)
    if not ok or type(list) ~= 'table' then return false end
    for _, e in pairs(list) do
        local ok2, hp = pcall(function() return e:get_current_health() end)
        if ok2 and hp and hp > 1 then
            local ok3, untarg = pcall(function() return e:is_untargetable() end)
            if not (ok3 and untarg) then return true end
        end
    end
    return false
end

-- Reaper run-once tracker. Reaper v1.9+ exposes
-- ReaperPlugin.run_once(boss_id, run_type, on_complete): a callback fires
-- after Reaper kills the boss, loots, and returns to town (just before it
-- self-disables). We register a callback per request and flip `complete`
-- true when it fires; disable_when reads that flag.
--
-- run_id is bumped on every reset so a stale callback from a prior run_once
-- cannot mark a fresh run done. Specifically: when the boss pattern changes
-- mid-run, the old run_once is overwritten in Reaper's `run_once_callback`
-- slot (run_once just reassigns it), but if the new run_once is queued
-- before the orchestrator processes the change, the captured rid in the
-- old closure still wouldn't match the new run_id — so even a stray
-- invocation is a no-op.
local reaper_run_once = { complete = false, run_id = 0, skip_chest_fired = false }

-- Altar-loop watchdog: if Reaper's "Interact Altar" task is still the active
-- task >30s after we first saw it in this run_once session, the single-shot
-- lockout inside Reaper has failed (typical cause: the altar interact never
-- registered, leaving tracker.altar_activated=false so the external lockout
-- clock never starts). Force-disable Reaper to unblock the orchestrator handoff.
-- Reset on every new run_once and on global reset. The timer only accumulates
-- while Reaper's active task stays on Interact Altar (see check_reaper_watchdogs).
local ALTAR_WATCHDOG_COOLDOWN = 45.0
-- Extra hold (beyond the normal TRANSITION_GAP_SECONDS) before the next
-- activity's teleport fires, applied only when the watchdog force-disabled
-- Reaper. Reaper may still be mid-channel (interact_object spam, mounted,
-- mid-attack) when we yank the toggle; an extra beat lets the in-game state
-- settle before warplan.teleport_to_activity() races it.
local REAPER_WATCHDOG_TELEPORT_HOLD = 8.0
local reaper_altar_watchdog = {
    first_seen_at = nil,
    triggered     = false,
    hold_until    = 0,
}

local function reset_reaper_run_once()
    reaper_run_once.complete = false
    reaper_run_once.run_id   = (reaper_run_once.run_id or 0) + 1
    reaper_altar_watchdog.first_seen_at = nil
    reaper_altar_watchdog.triggered     = false
    reaper_altar_watchdog.hold_until    = 0
    reaper_run_once.skip_chest_fired    = false
end

local function make_reaper_callback()
    local rid = reaper_run_once.run_id
    return function()
        if rid ~= reaper_run_once.run_id then return end
        reaper_run_once.complete = true
    end
end

local function reaper_run_boss(p, boss_id)
    reset_reaper_run_once()
    -- Guard: open-source folder tags source='folder' / version='2.6'.
    -- Reaper 3.0.pack should own ReaperPlugin when Boss → Reaper 3.0.pack is selected.
    if p and (p.source == 'folder' or p.version == '2.6') then
        local choice = resolver.get_choice('boss')
        if choice and choice.id == 'reaper30' then
            console.print('[WarPigs] WARNING: Boss is set to Reaper 3.0.pack but open-source Reaper v2.6 is loaded.')
            console.print('[WarPigs] Fix: enable Reaper3.0.pack in QQT Scripts and DISABLE the Reaper folder, then reload.')
        end
    end
    if type(p.run_once) == 'function' then
        p.run_once(boss_id, nil, make_reaper_callback())
    else
        -- Reaper < v1.9: no completion signal. Falling back to run_boss leaves
        -- disable_when stuck on false; max_disable_defer_seconds (per-entry)
        -- becomes the only force-disable path.
        console.print('[WarPigs] WARNING: ReaperPlugin.run_once unavailable (need Reaper v1.9+) — falling back to run_boss')
        p.run_boss(boss_id)
    end
end

local function reaper_run_once_disable_when()
    return reaper_run_once.complete == true
end

local function boss_map_entry(boss_id)
    return {
        plugin = registry.ROLE_MARKERS.boss,
        enable = function(p) reaper_run_boss(p, boss_id) end,
        disable_when = reaper_run_once_disable_when,
        max_disable_defer_seconds = 300,
        -- Already inside any boss lair — don't re-fire warplan teleport.
        arrived_when = in_boss_lair_zone,
    }
end

-- WarPigs always runs Infernal Hordes on 10-wave compasses. HordeDev's GUI
-- wave checkboxes are left untouched; warpigs_mode is a runtime-only override
-- read by start_dungeon and cleared on InfernalHordesPlugin.disable().
local function horde_enable_for_warpigs(p)
    p._warpigs_enable = true
    if type(p.setSettings) == 'function' then
        p.setSettings('warpigs_mode', true)
    end
    p.enable()
end

-- Map keys are matched as PLAIN SUBSTRINGS against the names of active
-- quests. Only quests whose name contains "WarPlans_QST" are eligible —
-- everything else (Bounty_*, story quests, etc.) is ignored. Multiple keys
-- may target the same plugin; the plugin stays enabled while at least one
-- key still matches.
--
-- Each value is either:
--   * a STRING — the plugin global name (calls plugin.enable()/disable())
--   * a TABLE  — {
--         plugin       = 'GlobalName',
--         enable       = fn(p)         -- optional custom enable hook
--         disable      = fn(p)         -- optional custom disable hook
--         disable_when = fn() -> bool  -- optional. When the quest disappears,
--                                      -- disable is deferred until this
--                                      -- returns true. Re-checked every tick.
--                                      -- Use to let the plugin finish a
--                                      -- post-quest wrap-up before WarPigs
--                                      -- flips it off (e.g. Arkham collecting
--                                      -- the glyphstone reward and TPing out
--                                      -- of the pit).
--     }
--   * a TABLE with `task` — {
--         task = require 'core.tasks.<name>'  -- module exposing tick(active)
--     }
--     The task module's tick(true) is called each WarPigs tick while the
--     trigger pattern matches; tick(false) when it stops. Used for actions
--     WarPigs performs itself (teleport, NPC interaction) instead of just
--     toggling another plugin.
-- Activity-plugin preemption priority. When more than one plugin's quest is
-- matched simultaneously, only the highest-priority one stays "wanted" — the
-- rest are treated as if their quest had gone unmatched (disabled per the
-- normal disable/disable_when path).
--
-- Why: WarPlans for short-lived objectives (Pit, Boss runs, Hordes) frequently
-- overlap with ambient/long-running activities (Undercity, Helltide). Without
-- preemption, both plugins stay enabled and fight for BatmobilePlugin/orbwalker
-- — in practice the ambient one wins the per-pulse race because it's already
-- mid-run, and the short-lived objective never starts. Specifically, completing
-- a Kurast boss and returning to Temis with an active Pit WarPlan should hand
-- off to Arkham; before this preemption, WonderCity just looped into the next
-- Undercity run instead.
--
-- Higher number = higher priority (from plugin_registry per role).
local function plugin_priority(plugin_name)
    return resolver.plugin_priority(plugin_name)
end

orchestrator.quest_plugin_map = {
    WarPlans_QST_ThePit = {
        plugin = registry.ROLE_MARKERS.pit,
        -- Pit quest can vanish while still inside the pit (post-quest reward
        -- phase). Wait for the player to fully return to town before letting
        -- the next plugin take over.
        disable_when = in_town_disable_when,
        -- Town tower OR already mid-Pit. Mid-run without the PIT_ check caused
        -- endless "teleport retry — world/zone unchanged" in PIT_Subzone.
        arrived_when = function()
            return actor_present('TWN_Kehj_IronWolves_PitKey_Crafter')
                or in_pit_zone()
        end,
    },

    -- Helltide handoff: no disable_when. The quest disappearing means the
    -- helltide event ended (or the bot left it), and there's no in-zone
    -- wrap-up worth waiting for — HR can be cut immediately. The standard
    -- TRANSITION_GAP_SECONDS (5s) gap still applies via last_disable_time
    -- before the next plugin enables.
    --
    -- arrived_when = has_helltide_buff: when the player is already inside the
    -- helltide zone (cold-start with both plugins enabled, or post-respawn
    -- re-arm), warplan.teleport_to_activity() is a no-op and the orchestrator
    -- otherwise loops on "teleport retry — world/zone unchanged" while HR
    -- tries to do its job (logzewx 3337-3343 confirmed). The buff check is the
    -- ground truth — it fires when we're in the active helltide regardless of
    -- which specific Helltide_* zone we landed in.
    WarPlans_QST_Helltide_TorturedGifts = {
        plugin       = orchestrator.HELLTIDE_PLUGIN_MARKER,
        arrived_when = has_helltide_buff,
    },

    WarPlans_QST_Undercity = {
        plugin       = registry.ROLE_MARKERS.undercity,
        disable_when = in_town_disable_when,  -- wait for the Kurast/Temis return
        -- Two-layer arrived check:
        --   1. Brazier visible (Aubrie_Test_Undercity_Crafter) — we're at the
        --      Undercity town crafter, ready to start a run. Same loop-prevention
        --      as the Pit entry above — if already in town the teleport is a no-op.
        --   2. Already inside an X1_Undercity_* zone — we're mid-run. WonderCity
        --      owns the bot; WarPigs must not re-fire teleport_to_activity()
        --      because the dungeon world/zone snapshot won't change between
        --      retries and arrived_when is the only confirmation path.
        arrived_when = function()
            return actor_present('Aubrie_Test_Undercity_Crafter')
                or in_undercity_zone()
        end,
    },

    -- Confirmed seen in logs as WarPlans_QST_InfernalHordes_BSK; substring
    -- match covers any tier/variant suffix.
    --
    -- Quest vanishes when the wave bosses die, but HordeDev still has to
    -- open chests and pick up loot. Defer disable until we either leave the
    -- BSK world (S05_BSK_Prototype02) or 60s elapse as a safety cap.
    WarPlans_QST_InfernalHordes = {
        plugin = registry.ROLE_MARKERS.horde,
        enable = horde_enable_for_warpigs,
        -- Already inside BSK (e.g. warplan teleport was a no-op) — stop the
        -- "teleport retry — world/zone unchanged" loop and release the gate.
        arrived_when = in_bsk_world,
        -- HARD GATE: when use_teleport_transition is on, never enable HordeDev
        -- unless we are currently inside a BSK world. The teleport state
        -- machine *should* land us there, but its confirmation is just
        -- "world/zone changed" — a stray zone change in town will satisfy it
        -- and the plugin would otherwise enable outside BSK and walk forever.
        -- With teleport off, the user is driving navigation themselves, so we
        -- don't impose the gate.
        enable_gate = function()
            if not settings.use_teleport_transition then return true end
            if in_bsk_world() then return true end
            return false, 'not in BSK world (teleport transition is on — refusing to start HordeDev outside BSK)'
        end,
        -- Quest vanishes when the wave bosses die, but HordeDev still has to
        -- run its full post-boss cycle: open the talisman chest (if enabled),
        -- the greater-affix chest (if enabled), the materials/selected chest,
        -- then exit_horde teleports back to town. WarPigs must not preempt
        -- any of those steps.
        --
        -- Primary gate: chests_done() — HordeDev sets this true only after
        -- finish_chest_opening (or a hard exhaust). While it's false we hold
        -- unconditionally; the previous version's 60s in-BSK timer fired in
        -- the middle of "Waiting Talisman loot" and dropped GA + materials.
        --
        -- Once chests are done we wait for out-of-BSK as confirmation that
        -- exit_horde has actually fired (it teleports the player to Caldeum).
        -- Small safety cap covers a stuck exit_horde channel; while chests
        -- are still progressing the cap is not started.
        --
        -- max_disable_defer_seconds overrides the global MAX_DISABLE_DEFER
        -- so a slow chest sequence (talisman + GA + materials with loot
        -- waits) can't be force-disabled by the orchestrator's safety net.
        max_disable_defer_seconds = 300,
        -- Opt out of same-activity continuation. Back-to-back BSK WarPlans
        -- leave the player in an empty BSK after the prior wave (no sigil,
        -- no chests left). The next run requires the full transition:
        -- exit_horde → Temis → Alfred → warplan.teleport_to_activity() →
        -- HordeDev re-enable inside a fresh horde. Without this flag,
        -- SAME_ACTIVITY_SECS (30s) would short-circuit the preamble and
        -- HordeDev would re-enable in place, doing nothing.
        same_activity_continuation = false,
        disable_when = (function()
            local exit_defer_start
            return function()
                local p = resolver.get_plugin_instance('horde')
                local done = p and type(p.chests_done) == 'function' and p.chests_done()
                if not done then
                    exit_defer_start = nil
                    return false
                end
                local world = get_current_world()
                local name
                if world then
                    local ok, n = pcall(function() return world:get_name() end)
                    if ok then name = n end
                end
                local in_bsk = type(name) == 'string'
                    and name:find('BSK', 1, true) ~= nil
                if not in_bsk then
                    exit_defer_start = nil
                    return true
                end
                exit_defer_start = exit_defer_start or get_time_since_inject()
                if get_time_since_inject() - exit_defer_start >= 60 then
                    exit_defer_start = nil
                    return true
                end
                return false
            end
        end)(),
    },

    -- After a WarPlan finishes, this quest returns to drive the reward
    -- turn-in. WarPigs handles it directly: teleport to Temis, walk to
    -- Tyrael, interact.
    WarPlans_QST_TurnIn_Rewards = { task = require 'core.tasks.turn_in_rewards' },

    -- Boss runs via Reaper. boss_id must match an entry in
    -- Reaper-main/data/enums.lua boss_zones (duriel, andariel, varshan,
    -- grigoire, zir, beast, harbinger, urivar, butcher, belial).
    -- ★ NON-DEVS: to add a new boss quest, copy one line below and change the
    --   quest name + boss id — see Recipe 2 in HOW-TO-EDIT.md.
    --
    -- Quest-name suffixes are confirmed where marked; the rest are best
    -- guesses based on the "Andariel" and "Harby" precedents. Wrong guesses
    -- are harmless (substring just won't match anything) — verify via the
    -- "Log ALL quests" mode and rename as needed.
    -- arrived_when = in_boss_lair_zone stops TELEPORTING retry loops mid-lair.
    WarPlans_QST_BossLair_Andariel = boss_map_entry('andariel'),  -- CONFIRMED
    WarPlans_QST_BossLair_Harby = boss_map_entry('harbinger'),     -- CONFIRMED
    WarPlans_QST_BossLair_Duriel = boss_map_entry('duriel'),
    WarPlans_QST_BossLair_Varshan = boss_map_entry('varshan'),
    WarPlans_QST_BossLair_PenitentKnight = boss_map_entry('grigoire'),  -- CONFIRMED
    WarPlans_QST_BossLair_Zir = boss_map_entry('zir'),  -- CONFIRMED
    -- Beast in Ice: multiple quest-name aliases → same boss_id.
    WarPlans_QST_BossLair_MegaDemon = boss_map_entry('beast'),
    WarPlans_QST_BossLair_Beast = boss_map_entry('beast'),
    WarPlans_QST_BossLair_BeastInIce = boss_map_entry('beast'),
    WarPlans_QST_BossLair_IceBeast = boss_map_entry('beast'),
    WarPlans_QST_BossLair_Wendigo = boss_map_entry('beast'),
    WarPlans_QST_BossLair_Urivar = boss_map_entry('urivar'),
    WarPlans_QST_BossLair_Butcher = boss_map_entry('butcher'),
    WarPlans_QST_BossLair_Belial = boss_map_entry('belial'),
}

local function resolve_map_plugin(plugin_field)
    if type(plugin_field) ~= 'string' then return plugin_field end
    if resolver.is_marker(plugin_field) then
        return resolver.resolve_marker(plugin_field)
    end
    if resolver.normalize_plugin_global then
        return resolver.normalize_plugin_global(plugin_field)
    end
    return plugin_field
end

local function normalize(entry)
    if type(entry) == 'string' then
        return {
            plugin  = resolve_map_plugin(entry),
            role_id = registry.role_for_marker(entry),
        }
    end
    if type(entry) == 'table' and entry.plugin then
        local resolved = {}
        for k, v in pairs(entry) do resolved[k] = v end
        resolved.plugin  = resolve_map_plugin(entry.plugin)
        -- Keep the role so the tick loop can tell "marker resolved to nil
        -- (nothing loaded for the role)" apart from a plain task entry.
        resolved.role_id = registry.role_for_marker(entry.plugin)
        return resolved
    end
    return entry
end

-- WarPigs is the master orchestrator: any plugin in quest_plugin_map is
-- bound to its trigger pattern. When no pattern matches, the plugin is
-- forcibly disabled — even if it was enabled outside WarPigs (e.g. by a
-- manual toggle, a stale state surviving a script reload, or a previous
-- WarPigs session whose owned[] table was lost).
local owned          = {}  -- plugin_name -> true (status confirms enabled)
local managed_by_us  = {}  -- plugin_name -> true (WarPigs called enable this session)
local last_wanted    = {}  -- plugin_name -> true (was-wanted on previous tick)
local last_matches   = {}  -- pattern -> true (for verbose log only)
local pending_disable = {} -- plugin_name -> true (disable deferred by predicate)
local pending_disable_since = {}  -- plugin_name -> time when deferral started (for MAX_DISABLE_DEFER_SECONDS)
local last_disable_time     = {}  -- plugin_name -> time the disable actually fired (for TRANSITION_GAP_SECONDS gate)
local enable_blocked        = {}  -- plugin_name -> stable gate key (suppresses repeat logs)
local enable_fail_logged    = {}  -- plugin_name -> true (enable retry failure logged once)
local enable_fail_count     = {}  -- plugin_name -> consecutive status-not-on after enable()
local reenable_logged       = {}  -- plugin_name -> true (dropout re-enable logged once)
local ENABLE_FAIL_GIVE_UP   = 8   -- stop dropout thrash after this many failed confirms
local missing_plugin_warned = {}  -- plugin_name -> true (log once per session)
local was_off        = {}  -- plugin_name -> true (we believe it is currently off; suppresses repeated logs)
-- Same-activity continuation: when the same plugin re-matches within this
-- window after being disabled (e.g. back-to-back helltide WarPlans), cancel
-- the pending teleport so we don't fire warplan.teleport_to_activity() while
-- the plugin is already positioned in the right zone.
local last_disabled_plugin = nil
local last_disabled_at     = -math.huge
local last_disabled_reason = nil   -- quest pattern that triggered the last disable
local SAME_ACTIVITY_SECS   = 30.0
-- Track which trigger pattern was last used to enable each plugin. When the
-- matched pattern changes mid-run (e.g. ReaperPlugin running Zir but a new
-- Varshan WarPlan appears before Zir's kill+60s defer satisfies), re-fire
-- enable() so the plugin's enable hook switches to the new boss. Without this
-- the orchestrator owns the plugin under the OLD entry, the enable phase's
-- edge-trigger short-circuits, and the plugin keeps running stale context.
local last_enabled_reason   = {}  -- plugin_name -> pattern

local function log(msg)
    console.print('[WarPigs] ' .. msg)
end

-- Gate reasons with live countdowns change every tick; compare stable keys only.
local function stable_gate_key(reason)
    if not reason then return nil end
    local plugin = reason:match('^post%-disable cooldown: ([^%(]+)')
    if plugin then
        return 'post-disable cooldown: ' .. plugin:gsub('%s+$', '')
    end
    return reason
end

local function role_label_for_plugin(plugin_name)
    for role_id, role in pairs(registry.roles) do
        if role.all_globals then
            for _, g in ipairs(role.all_globals) do
                if g == plugin_name then return role.label end
            end
        end
        local resolved = resolver.resolve_global(role_id)
        if resolved == plugin_name then return role.label end
    end
    return plugin_name
end

local function warn_missing_plugin(plugin_name, pattern)
    if missing_plugin_warned[plugin_name] then return end
    missing_plugin_warned[plugin_name] = true
    local hint = resolver.missing_enable_hint(plugin_name)
    local extra = hint and (' — ' .. hint) or ' — load it in QQT Scripts'
    log(string.format(
        'quest %s needs %s (%s) but that plugin is not loaded%s',
        pattern, plugin_name, role_label_for_plugin(plugin_name), extra))
end

-- Hard filter: only quests containing this substring can drive WarPigs.
-- Prevents accidental matches against bounty/story quests when a map key is
-- an unintentionally broad substring.
local QUEST_FILTER = 'WarPlans_QST'

local function get_active_quest_names()
    local names = {}
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= 'table' then return names end
    for _, quest in pairs(quests) do
        local ok_n, name = pcall(function() return quest:get_name() end)
        if ok_n and type(name) == 'string' and name:find(QUEST_FILTER, 1, true) then
            names[#names+1] = name
        end
    end
    return names
end

-- Best-effort check: is the plugin currently reporting itself enabled?
-- Returns true if a status surface says enabled=true. Returns false if no
-- status is exposed — in which case we fall back to our own owned[] table.
-- (Defined ABOVE plugin_enable so the resilient-enable code can reference it
--  — Lua locals aren't hoisted, so a forward reference would resolve to a
--  global nil at call time.)
local function is_plugin_on(plugin_name)
    plugin_name = resolver.normalize_plugin_global(plugin_name)
    local p = _G[plugin_name]
    if not p then return false end
    local status_fn = (type(p.status) == 'function' and p.status)
                   or (type(p.get_status) == 'function' and p.get_status)
                   or nil
    if status_fn then
        local ok, s = pcall(status_fn)
        if ok and type(s) == 'table' then
            if s.enabled == true then return true end
            -- WonderCity (and similar): optional keybind gate can make
            -- enabled=false while Enable is checked after our enable().
            -- Trust gui_enabled only while we manage the plugin.
            if managed_by_us[plugin_name] and s.gui_enabled == true then
                return true
            end
            return false
        end
    end
    return owned[plugin_name] == true or managed_by_us[plugin_name] == true
end

local function we_manage(plugin_name)
    return owned[plugin_name] == true or managed_by_us[plugin_name] == true
end

-- ── teardown workaround (BetterHelltide dead-require) ───────────────────────
-- BetterHelltide v1.7.x: its disable()/hard_disable() can throw
-- "module 'tasks.farm' not found" — the pack lazy-requires a module against a
-- dead package.path entry, and the throw aborts its own teardown half-way.
-- Generic containment for any plugin with a throwing teardown:
--   * prefer hard_disable, fall back to disable() when the first call throws
--   * a function that threw a dead-require error is skipped for the rest of
--     the session (the bug is deterministic — retrying just re-breaks every
--     handoff and can leave the bot half-torn-down)
--   * when every teardown function is broken, manage by ownership only and
--     say so once (fix is reload scripts / switch the role's plugin).
local broken_teardown      = {}  -- plugin_name -> { [fn_name] = true }
local teardown_err_logged  = {}  -- plugin_name .. '.' .. fn_name -> true
local teardown_gave_up_log = {}  -- plugin_name -> true

local function is_dead_require_error(err)
    if type(err) ~= 'string' then return false end
    return (err:find("module '", 1, true) ~= nil and err:find('not found', 1, true) ~= nil)
        or err:find("no file '", 1, true) ~= nil
end

-- Returns 'ok', fn_name  |  'failed', last_err  |  'gave_up'  |  'none'.
local function try_teardown(plugin_name, p)
    local broken = broken_teardown[plugin_name]
    local attempted, last_err, have_any = false, nil, false
    for _, fn_name in ipairs({ 'hard_disable', 'disable' }) do
        if type(p[fn_name]) == 'function' then
            have_any = true
            if not (broken and broken[fn_name]) then
                attempted = true
                local ok, err = pcall(p[fn_name])
                if ok then return 'ok', fn_name end
                last_err = err
                if is_dead_require_error(err) then
                    broken_teardown[plugin_name] = broken_teardown[plugin_name] or {}
                    broken_teardown[plugin_name][fn_name] = true
                    broken = broken_teardown[plugin_name]
                    log(string.format(
                        '%s.%s() threw a dead-require error (plugin bug) — skipping it for the rest of this session, trying next teardown',
                        plugin_name, fn_name))
                else
                    local key = plugin_name .. '.' .. fn_name
                    if not teardown_err_logged[key] then
                        teardown_err_logged[key] = true
                        log(string.format('%s.%s() threw: %s — trying next teardown',
                            plugin_name, fn_name, tostring(err)))
                    end
                end
            end
        end
    end
    if not have_any then return 'none' end
    if not attempted then
        if not teardown_gave_up_log[plugin_name] then
            teardown_gave_up_log[plugin_name] = true
            log(plugin_name .. ': every teardown function throws (plugin bug) — '
                .. 'managing by ownership only. Reload scripts, or switch this role to another plugin.')
        end
        return 'gave_up'
    end
    return 'failed', last_err
end

-- True when the plugin exposes teardown functions but every one of them has
-- thrown (dead-require). Force-disabling such a plugin every tick is pure
-- churn: each attempt refreshes last_disable_time and re-arms the teleport,
-- which starves the enable gate forever (observed with BetterHelltide: the
-- 5s post-disable cooldown showed "5.0s left" for minutes on end). On the
-- orchestrator table so tick() reaches it through an existing upvalue.
orchestrator._teardown_hopeless = function (plugin_name)
    local broken = broken_teardown[plugin_name]
    if not broken then return false end
    local p = _G[plugin_name]
    if type(p) ~= 'table' then return false end
    local have_any = false
    for _, fn_name in ipairs({ 'hard_disable', 'disable' }) do
        if type(p[fn_name]) == 'function' then
            have_any = true
            if not broken[fn_name] then return false end
        end
    end
    return have_any
end

-- Turn off other globals in the same role (e.g. HR when BetterHelltide is selected).
-- Always prefer hard_disable. Soft-paused HR reports enabled=false but Enable
-- stays checked — is_plugin_on misses it, so we also tear down paused siblings.
local function disable_role_siblings(plugin_name)
    for _, role in pairs(registry.roles) do
        if role.all_globals then
            local in_role = false
            for _, g in ipairs(role.all_globals) do
                if g == plugin_name then in_role = true; break end
            end
            if in_role then
                for _, g in ipairs(role.all_globals) do
                    -- Compare NORMALIZED names: BetterHelltidePlugin is an
                    -- alias of HelltideLitePlugin (same table), not a real
                    -- sibling — tearing it down would kill the plugin that
                    -- was just enabled.
                    local g_norm = resolver.normalize_plugin_global(g)
                    if g_norm ~= plugin_name then
                        local p = _G[g]
                        if not p then goto continue end
                        local needs_off = is_plugin_on(g)
                        if not needs_off and type(p.status) == 'function' then
                            local ok, s = pcall(p.status)
                            if ok and type(s) == 'table' then
                                if s.paused == true or s.gui_enabled == true
                                    or s.enabled == true
                                then
                                    needs_off = true
                                end
                            end
                        end
                        if needs_off and not orchestrator._teardown_hopeless(g_norm) then
                            log('disabling ' .. g .. ' — sibling of ' .. plugin_name)
                            try_teardown(g_norm, p)
                            owned[g_norm]         = nil
                            managed_by_us[g_norm] = nil
                        end
                        ::continue::
                    end
                end
            end
        end
    end
end

-- Predicate: helltide quest just ended (or never was incoming) but the player
-- is still in the helltide zone with HR disabled. In this state the 10s
-- monster spawns hit the player, the via-Temis preamble's teleport channel
-- gets cancelled by damage, and HR isn't around to clear the area. Used to
-- (a) bypass the in_helltide_combat hold so the preamble is allowed to fire
-- even while taking hits, and (b) shorten the TO_TEMIS retry cadence to
-- TEMIS_LINGER_RETRY_INTERVAL (3s) so we keep restarting the channel until
-- one attempt lands between hits.
local function helltide_lingering_post_quest(wants_)
    if not has_helltide_buff() then return false end
    if is_plugin_on(orchestrator.helltide_plugin_name()) then return false end
    if incoming_is_helltide(wants_) then return false end
    return true
end

local function plugin_enable(entry, reason)
    local plugin_name = resolver.normalize_plugin_global(entry.plugin)
    local p = _G[plugin_name]
    if not p then
        warn_missing_plugin(entry.plugin, reason or '?')
        return
    end
    -- Force orbwalker clear ON before handing off to the next plugin. Some
    -- plugins (HR cinder gate, Reaper boss approach, manual toggles) leave
    -- clear OFF; the next plugin often assumes it starts ON and never
    -- re-asserts it, so trash gets ignored for the entire run. Gated by
    -- settings.manage_orbwalker so users who hand orbwalker control to their
    -- rotation aren't disturbed.
    if settings.manage_orbwalker and orbwalker and orbwalker.set_clear_toggle then
        local ok = pcall(orbwalker.set_clear_toggle, true)
        if not ok then
            log('orbwalker.set_clear_toggle(true) threw before enabling ' .. entry.plugin)
        end
    end
    -- Wrap enable() in pcall: a misbehaving plugin (e.g. HR.enable referencing
    -- a missing GUI element) used to crash the orchestrator and trigger an
    -- infinite enable loop because owned[] never got set, so the edge check
    -- fired again next tick.
    local ok, err
    if entry.enable then
        ok, err = pcall(entry.enable, p)
    elseif type(p.enable) == 'function' then
        ok, err = pcall(p.enable)
    else
        log('cannot enable ' .. entry.plugin .. ' — no enable function')
        return
    end
    managed_by_us[plugin_name] = true
    if not ok then
        log('enable() of ' .. plugin_name .. ' threw: ' .. tostring(err))
    end
    if is_plugin_on(plugin_name) then
        owned[plugin_name] = true
        enable_blocked[plugin_name] = nil
        enable_fail_logged[plugin_name] = nil
        enable_fail_count[plugin_name] = nil
        reenable_logged[plugin_name] = nil
        if orchestrator._disable_threw_at then
            orchestrator._disable_threw_at[plugin_name] = nil
        end
        last_enabled_reason[plugin_name] = reason
        log('enabled ' .. plugin_name .. ' (' .. (reason or '?') .. ')')
    else
        local n = (enable_fail_count[plugin_name] or 0) + 1
        enable_fail_count[plugin_name] = n
        if n >= ENABLE_FAIL_GIVE_UP then
            -- Stop "dropped off unexpectedly" thrash (e.g. WonderCity keybind
            -- gate reporting enabled=false forever). Clear managed so dropout
            -- re-enable stops; user must fix the plugin menu / reload.
            managed_by_us[plugin_name] = nil
            owned[plugin_name] = nil
            if not enable_fail_logged[plugin_name] or enable_fail_logged[plugin_name] ~= 'gave_up' then
                log(string.format(
                    'giving up enable of %s after %d tries — status.enabled never confirmed (check plugin Enable/keybind)',
                    plugin_name, n))
                enable_fail_logged[plugin_name] = 'gave_up'
            end
        elseif not enable_fail_logged[plugin_name] then
            log('enable of ' .. plugin_name .. ' did not result in enabled status — will retry next tick')
            enable_fail_logged[plugin_name] = true
        end
    end
end

local function plugin_disable(entry, opts)
    local plugin_name = resolver.normalize_plugin_global(entry.plugin)
    local p = _G[plugin_name]
    local quiet = opts and opts.quiet
    -- ALWAYS finish ownership cleanup below, even when disable() throws.
    -- BetterHelltide's disable() can error (lazy require of tasks.farm while
    -- package.path is WarPigs') — a bare call aborted this function mid-way,
    -- left managed_by_us set, then the enable phase thrash-re-enabled
    -- ("plugin dropped off unexpectedly").
    if p then
        local ok, err = true, nil
        local used_hard = false
        local gave_up   = false
        if entry.disable then
            ok, err = pcall(entry.disable, p)
        else
            -- try_teardown prefers hard_disable (soft-pause bots like
            -- HelltideRevamped must fully uncheck Enable), falls back to
            -- disable() when the first call throws, and skips functions that
            -- threw a dead-require error earlier this session (BetterHelltide
            -- workaround). 'none' (no teardown surface) keeps ok = true.
            local status, detail = try_teardown(plugin_name, p)
            if status == 'ok' then
                used_hard = (detail == 'hard_disable')
            elseif status == 'failed' then
                ok, err = false, detail
            elseif status == 'gave_up' then
                ok, gave_up = false, true
            end
        end
        if not ok then
            if not gave_up then
                -- gave_up already logged once inside try_teardown.
                log('disable() of ' .. plugin_name .. ' threw: ' .. tostring(err)
                    .. ' — clearing ownership anyway')
            end
            -- Remember so dropout re-enable can back off (see enable phase).
            orchestrator._disable_threw_at = orchestrator._disable_threw_at or {}
            orchestrator._disable_threw_at[plugin_name] = get_time_since_inject()
        else
            if orchestrator._disable_threw_at then
                orchestrator._disable_threw_at[plugin_name] = nil
            end
            if not quiet then
                if used_hard then
                    log('hard-disabled ' .. entry.plugin)
                else
                    log('disabled ' .. entry.plugin)
                end
            end
        end
    end
    -- Also force-off every other global in the same role (Lite + Revamped both
    -- claim helltide). resolve_marker only tracks one name, so the sibling
    -- would otherwise keep running through a Pit handoff.
    disable_role_siblings(plugin_name)
    owned[plugin_name] = nil
    managed_by_us[plugin_name] = nil
    last_disabled_reason = last_enabled_reason[plugin_name]
    last_enabled_reason[plugin_name] = nil
    last_disable_time[plugin_name] = get_time_since_inject()
    last_disabled_plugin = plugin_name
    last_disabled_at     = get_time_since_inject()
    session_stats.on_activity_finished(last_disabled_reason, plugin_name)
    -- Arm the teleport sequence for the NEXT activity. plugin_disable only
    -- fires after disable_when has satisfied (Reaper: kill+60s, Pit/WC: in
    -- town after Alfred salvage), so we're in a clean state to teleport.
    if settings.use_teleport_transition
        and settings.is_active()
        and not (opts and opts.suppress_teleport)
    then
        transitions.teleport_pending = true
    end
end

-- Returns true if any active quest name contains pattern (plain substring).
local function pattern_has_match(pattern, active_names)
    for _, name in ipairs(active_names) do
        if name:find(pattern, 1, true) then return true end
    end
    return false
end

-- Picks any map entry that targets plugin_name (used when disabling, so the
-- entry's custom disable hook is preserved even if the matching pattern has
-- already gone away).
local function find_entry_for_plugin(plugin_name)
    for _, raw in pairs(orchestrator.quest_plugin_map) do
        local e = normalize(raw)
        if e.plugin == plugin_name then return e end
    end
    return { plugin = plugin_name }
end

-- Build the set of all distinct plugin globals referenced by the map. Used
-- by the state-based disable phase to enforce "off" on plugins WarPigs may
-- not have enabled itself (manual toggle, stale state from before reload).
-- Include every all_globals candidate for each role so e.g. HelltideRevamped
-- is still torn down when Auto resolved to HelltideLitePlugin.
local function get_managed_plugins()
    local set = {}
    for _, raw in pairs(orchestrator.quest_plugin_map) do
        local e = normalize(raw)
        if e.plugin then set[e.plugin] = e end
    end
    for role_id, role in pairs(registry.roles) do
        if role_id ~= 'alfred' and role_id ~= 'nav' and role.all_globals then
            local sample = nil
            for _, raw in pairs(orchestrator.quest_plugin_map) do
                local e = normalize(raw)
                if e.plugin then
                    for _, g in ipairs(role.all_globals) do
                        if g == e.plugin then sample = e; break end
                    end
                end
                if sample then break end
            end
            for _, g in ipairs(role.all_globals) do
                -- Key by NORMALIZED global. BetterHelltidePlugin normalizes
                -- to HelltideLitePlugin (alias, same table); a separate alias
                -- entry here made the disable phase see "an enabled plugin
                -- that isn't wanted" one tick after enabling HelltideLite —
                -- and force-disable the plugin it had just enabled, forever
                -- (enable → phantom disable → 5s cooldown → re-enable loop).
                local key = resolver.normalize_plugin_global(g)
                if not set[key] then
                    set[key] = sample and {
                        plugin       = key,
                        disable_when = sample.disable_when,
                        max_disable_defer_seconds = sample.max_disable_defer_seconds,
                    } or { plugin = key }
                end
            end
        end
    end
    return set
end

-- Soft-paused plugins (HR disable keeps Enable checked) report status.enabled
-- false, so is_plugin_on misses them. Treat "Enable still checked" as on for
-- exclusive handoff teardown.
local function plugin_needs_force_off(plugin_name)
    if is_plugin_on(plugin_name) then return true end
    local p = _G[plugin_name]
    if not p then return false end
    if type(p.status) == 'function' then
        local ok, s = pcall(p.status)
        if ok and type(s) == 'table' then
            if s.paused == true then return true end
            if s.enabled == true then return true end
            if s.gui_enabled == true then return true end
        end
    end
    return false
end

-- Death-handling state: log "died" once on transition so respawn loops don't
-- spam.  Cleared the moment is_dead() goes false.
local was_dead          = false

-- Filler-pit state for `settings.run_pit_after_turnin`.  We arm the filler
-- once at least one WarPlans_QST_TurnIn_Rewards cycle has completed in this
-- session (matched → unmatched edge); after arming, whenever no real WarPlans
-- quest is active and no internal task is running, we inject ArkhamAsylumPlugin
-- into `wants` so pit fills the gap.  Cleared by `release_all`.
local TURN_IN_PATTERN          = 'WarPlans_QST_TurnIn_Rewards'
local turn_in_was_matched      = false
local had_turn_in_complete     = false
local pit_filler_active_logged = false   -- dedup the "filler engaged"/"yielded" logs

local function check_reaper_watchdogs()
    local boss_global = resolver.boss_plugin_name()
    local reaper = boss_global and _G[boss_global] or nil
    if type(reaper) ~= 'table' then return end
    if type(reaper.status) ~= 'function' then return end
    local ok, st = pcall(reaper.status)
    if not ok or type(st) ~= 'table' then return end
    -- Only police runs that WarPigs initiated. Standalone Reaper is the user's call.
    if not (st.enabled and st.external) then return end

    local task_name = st.task and st.task.name

    -- Skip-chest: disable Reaper the moment the chest spawns, before interact.
    -- Count the run first so Reaper's rotation state stays coherent, then hand
    -- off to WarPigs for the town teleport sequence.
    if settings.skip_boss_chest and not reaper_run_once.skip_chest_fired
       and task_name == 'Open Chest' then
        reaper_run_once.skip_chest_fired = true
        reaper_run_once.complete         = true
        console.print('[WarPigs] skip_boss_chest: Open Chest task detected — counting run and disabling Reaper before chest interact')
        if type(reaper.force_complete_external) == 'function' then
            pcall(reaper.force_complete_external)
        end
        if type(reaper.clear_external) == 'function' then
            pcall(reaper.clear_external)
        end
        pcall(reaper.disable)
        return
    end

    -- Altar watchdog: force-disable if Interact Altar loops continuously >30s
    -- (single-shot lockout failed). Reset the timer whenever Reaper is on another
    -- task (Navigate to Boss, Kill Monsters, Open Chest, …) so pathing to the
    -- altar or a long fight does not accumulate against this deadline.
    if reaper_altar_watchdog.triggered then return end
    if task_name ~= 'Interact Altar' then
        reaper_altar_watchdog.first_seen_at = nil
        return
    end

    local now = get_time_since_inject()
    if not reaper_altar_watchdog.first_seen_at then
        reaper_altar_watchdog.first_seen_at = now
        log(string.format('reaper altar watchdog: first Interact Altar at %.1f', now))
        return
    end

    local elapsed = now - reaper_altar_watchdog.first_seen_at
    if elapsed > ALTAR_WATCHDOG_COOLDOWN then
        reaper_altar_watchdog.triggered  = true
        reaper_altar_watchdog.hold_until = now + REAPER_WATCHDOG_TELEPORT_HOLD
        log(string.format(
            'reaper altar watchdog: Interact Altar still active %.0fs after first sighting — single-shot lockout failed, force-disabling Reaper (holding next teleport %.0fs extra)',
            elapsed, REAPER_WATCHDOG_TELEPORT_HOLD))
        if type(reaper.clear_external) == 'function' then
            pcall(reaper.clear_external)
        end
        pcall(reaper.disable)
        reaper_run_once.complete = true
    end
end

function orchestrator.tick()
    if not settings.is_active() then return end

    local matched_blocked = {}
    -- Death recovery — handle this before any other state, in case the player
    -- got killed during the Tab→click→settle teleport sequence (mob aggro on
    -- the way out of town, late-arriving boss attack, etc).  When dead we
    --   (1) abort any in-flight transition + re-arm so it restarts after
    --       respawn — the click was either lost or fired into a death screen,
    --   (2) call ClickRevivePlugin.try_revive() each tick until it takes,
    --   (3) early-return so the orchestrator doesn't try to drive plugins
    --       while the player is on the death screen.
    local lp = get_local_player()
    if lp and lp:is_dead() then
        if not was_dead then
            log('player died — aborting any in-flight transition and reviving')
            was_dead = true
        end
        transitions.abort_on_death(log)
        if settings.use_teleport_transition and not transitions.teleport_pending then
            transitions.teleport_pending = true
        end
        if ClickRevivePlugin and ClickRevivePlugin.try_revive then
            ClickRevivePlugin.try_revive({ player = lp })
        end
        state_tracker.publish({
            now              = get_time_since_inject(),
            warpigs_on       = settings.is_active(),
            player_dead      = true,
            transition_state = transitions.teleport_transition.state,
            teleport_pending = transitions.teleport_pending,
        })
        return
    end
    if was_dead then
        log('player revived — resuming orchestrator')
        was_dead = false
    end

    check_reaper_watchdogs()

    local active_names = get_active_quest_names()
    local now          = get_time_since_inject()

    -- Compute which plugins should be enabled this tick, and drive any
    -- task entries directly. Matching is plain substring (string.find
    -- with plain=true).
    local wants          = {}  -- plugin_name -> entry to use for enable hook
    local matches        = {}  -- pattern -> true (verbose tracking)
    local matched_reason = {}  -- plugin_name -> first matching pattern (log)
    for pattern, raw_entry in pairs(orchestrator.quest_plugin_map) do
        local entry   = normalize(raw_entry)
        local matched = pattern_has_match(pattern, active_names)
        if matched then matches[pattern] = true end

        if entry.task then
            -- Task entries are stateful internally; just signal active/idle.
            -- They do NOT participate in plugin ownership tracking.
            -- While our teleport sequence is mid-flight OR pending (waiting
            -- for settle/alfred prerequisites), hold the task in "inactive"
            -- so it doesn't fire its own teleport / actions and compete
            -- with the orchestrator-driven Tab+Click. Once the sequence
            -- fully completes (state IDLE AND pending cleared), the next
            -- tick passes matched=true and the task picks up normally
            -- (e.g. turn-in task transitions IDLE → APPROACH_NPC since the
            -- orchestrator just landed us in town).
            local task_matched = matched
            if matched
                and (transitions.teleport_transition.state ~= 'IDLE' or transitions.teleport_pending)
            then
                task_matched = false
            end
            local ok, err = pcall(entry.task.tick, task_matched)
            if not ok then log('task error (' .. pattern .. '): ' .. tostring(err)) end
        elseif matched and entry.plugin then
            if not resolver.is_loaded(entry.plugin) then
                warn_missing_plugin(entry.plugin, pattern)
                matched_blocked[pattern] = entry.plugin
            elseif not wants[entry.plugin] then
                wants[entry.plugin]          = entry
                matched_reason[entry.plugin] = pattern
            end
        elseif matched and entry.role_id then
            -- Role marker resolved to nil: the pick is Auto and no plugin for
            -- this role is loaded in QQT. Warn once (console) and surface
            -- MISSING_PLUGIN on the HUD instead of silently ignoring the quest.
            local fallback = registry.role_candidate_globals(entry.role_id)[1]
            if fallback then
                warn_missing_plugin(fallback, pattern)
                matched_blocked[pattern] = fallback
            end
        end
    end

    -- ── PREEMPTION ──────────────────────────────────────────────────────────
    -- When multiple activity plugins match at the same time, only the highest
    -- priority one stays wanted. Demoted plugins fall through to the disable
    -- phase (disable_when still applies, so an in-flight activity gets to
    -- wrap up before being cut). Priorities come from plugin_registry per role.
    do
        local max_priority = -1
        local max_owner    = nil
        for plugin_name in pairs(wants) do
            local p = plugin_priority(plugin_name)
            if p > max_priority then
                max_priority = p
                max_owner    = plugin_name
            end
        end
        if max_priority > 0 then
            for plugin_name in pairs(wants) do
                local p = plugin_priority(plugin_name)
                if p < max_priority then
                    log(string.format('preempting %s (priority %d) — %s (priority %d) also matched',
                        plugin_name, p, max_owner, max_priority))
                    wants[plugin_name]          = nil
                    matched_reason[plugin_name] = nil
                end
            end
        end
    end


    -- ── RUN PIT AFTER TURN-IN ───────────────────────────────────────────────
    -- Track the turn-in pattern's matched→unmatched edge.  First time we see
    -- it, arm the pit filler for the rest of the session.  This way cold-start
    -- with no WarPlans quests doesn't auto-launch pit — the user has to have
    -- completed at least one WarPlans cycle first.
    local turn_in_matched_now = matches[TURN_IN_PATTERN] == true
    if turn_in_was_matched and not turn_in_matched_now and not had_turn_in_complete then
        had_turn_in_complete = true
        session_stats.on_round_complete()
        log('turn-in cycle completed — pit filler armed (run_pit_after_turnin)')
    end
    turn_in_was_matched = turn_in_matched_now

    -- Inject configured pit plugin as filler when:
    --   • setting on
    --   • turn-in has happened at least once this session
    --   • no real WarPlans plugin matched this tick (next(wants) == nil)
    --   • no internal task is currently active (turn-in mid-flight, etc.)
    -- Done AFTER preemption so a real WarPlans match always wins; the filler
    -- only ever fills empty gaps.  When a new WarPlans quest arrives next
    -- tick, the filler skips this block and the normal disable phase pulls
    -- the pit plugin out (deferred by its in_town_disable_when).
    if settings.run_pit_after_turnin
        and had_turn_in_complete
        and next(wants) == nil
    then
        local any_task_active = false
        for pattern, raw_entry in pairs(orchestrator.quest_plugin_map) do
            if matches[pattern] then
                local entry = normalize(raw_entry)
                if entry.task then any_task_active = true; break end
            end
        end
        if not any_task_active then
            local pit_entry
            local pit_global = resolver.pit_plugin_name()
            for _, raw in pairs(orchestrator.quest_plugin_map) do
                if type(raw) == 'table' and raw.plugin == registry.ROLE_MARKERS.pit then
                    pit_entry = raw
                    break
                end
            end
            if pit_entry and pit_global then
                local resolved_pit = normalize(pit_entry)
                wants[resolved_pit.plugin]          = resolved_pit
                matched_reason[resolved_pit.plugin] = 'filler:run_pit_after_turnin'
                -- Suppress the Tab+click teleport sequence for the filler:
                -- the click target the user configured points at a WarPlans
                -- quest icon and we have no quest active, so the click would
                -- land on stale/empty UI.  Arkham handles its own teleport-
                -- to-town-then-walk-to-pit-tower internally.
                if transitions.teleport_pending then
                    transitions.teleport_pending             = false
                    transitions.teleport_incoming_first_seen = nil
                    transitions.teleport_holding_key         = nil
                end
                if not pit_filler_active_logged then
                    log('pit filler engaged — no WarPlans quest active, enabling ' ..
                        pit_global .. ' (teleport sequence skipped)')
                    pit_filler_active_logged = true
                end
            end
        elseif pit_filler_active_logged then
            -- A task is now active (typically turn-in just appeared) — yield
            -- the filler back so future cycles re-log on re-engage.
            pit_filler_active_logged = false
        end
    elseif pit_filler_active_logged then
        -- A real WarPlans plugin matched, or setting was turned off — log the yield.
        log('pit filler yielding — WarPlans activity resumed')
        pit_filler_active_logged = false
    end

    -- ── COLD-START TELEPORT ─────────────────────────────────────────────────
    -- For the very first activity in a WarPigs session there's no preceding
    -- plugin_disable to arm the teleport, so detect "we have something to do
    -- AND have never run before" and fire the sequence here. Plugin →
    -- plugin and plugin → task transitions are armed inside plugin_disable
    -- (which only fires after disable_when satisfies — i.e. AFTER chests
    -- are looted, Alfred has salvaged, and the player is back in town).
    if settings.use_teleport_transition and not transitions.had_active_session then
        local has_any_plugin_want = next(wants) ~= nil
        local has_any_task_match  = false
        for pattern, raw_entry in pairs(orchestrator.quest_plugin_map) do
            if matches[pattern] then
                local entry = normalize(raw_entry)
                if entry.task then has_any_task_match = true; break end
            end
        end
        if has_any_plugin_want or has_any_task_match then
            if in_undercity_zone() then
                log('teleport skipped — already inside Undercity (mid-run / post-reload)')
                transitions.had_active_session = true
            else
                log('teleport queued — cold start (first activity of session)')
                transitions.teleport_pending = true
                transitions.had_active_session = true
            end
        end
    elseif not transitions.had_active_session
        and (next(wants) ~= nil or next(matches) ~= nil)
    then
        -- Even with the option off, mark that we've seen activity so a later
        -- toggle of "Use teleport" doesn't retro-trigger a cold-start fire.
        transitions.had_active_session = true
    end

    -- ── DISABLE PHASE (runs first) ──────────────────────────────────────────
    -- Tear down plugins WarPigs enabled (owned / managed_by_us). When a WarPlans
    -- target is active, also disable any other running activity plugin that is
    -- not wanted (exclusive handoff). With no active target, leave manually
    -- enabled plugins alone (v1.8.8 behaviour).
    local managed = get_managed_plugins()
    local active_warplan = next(wants) ~= nil
    for plugin_name, entry in pairs(managed) do
        if not wants[plugin_name] then
            if not plugin_needs_force_off(plugin_name) then
                if pending_disable[plugin_name] then
                    log('clearing stale pending_disable on ' .. plugin_name ..
                        ' — plugin is no longer reporting enabled')
                end
                if we_manage(plugin_name) then
                    log('detected self-disable of ' .. plugin_name ..
                        ' — applying ' .. TRANSITION_GAP_SECONDS .. 's transition gap')
                    session_stats.on_activity_finished(
                        last_enabled_reason[plugin_name], plugin_name)
                    last_disable_time[plugin_name] = now
                    if settings.use_teleport_transition then
                        transitions.teleport_pending = true
                        log('arming teleport_pending (self-disable handoff)')
                    end
                end
                pending_disable[plugin_name]       = nil
                pending_disable_since[plugin_name] = nil
                owned[plugin_name]                 = nil
                managed_by_us[plugin_name]         = nil
                if not was_off[plugin_name] then was_off[plugin_name] = true end
            elseif we_manage(plugin_name) then
                local force = false
                local cap = entry.max_disable_defer_seconds or MAX_DISABLE_DEFER_SECONDS
                if pending_disable[plugin_name] and pending_disable_since[plugin_name]
                    and now - pending_disable_since[plugin_name] >= cap
                then
                    log(string.format('forcing disable of %s — exceeded disable defer cap (%ds)',
                        plugin_name, cap))
                    force = true
                end
                if not force and entry.disable_when and not entry.disable_when() then
                    if not pending_disable[plugin_name] then
                        log('deferring disable of ' .. plugin_name ..
                            ' — disable_when() not yet satisfied')
                        pending_disable[plugin_name]       = true
                        pending_disable_since[plugin_name] = now
                    end
                    -- Keep this plugin "wanted" (still owned by us) so the enable
                    -- phase doesn't try to re-enable it during the deferral.
                    wants[plugin_name] = entry
                else
                    pending_disable[plugin_name]       = nil
                    pending_disable_since[plugin_name] = nil
                    plugin_disable(entry)
                    was_off[plugin_name] = true
                end
            elseif active_warplan then
                -- Skip plugins whose every teardown function throws (e.g.
                -- BetterHelltide dead-require): re-"disabling" them each tick
                -- does nothing to the plugin but refreshes last_disable_time
                -- and re-arms the teleport, starving the enable gate forever.
                if plugin_needs_force_off(plugin_name)
                    and not orchestrator._teardown_hopeless(plugin_name)
                then
                    local first_attempt = not was_off[plugin_name]
                    if first_attempt then
                        local target_name = next(wants)
                        log(string.format(
                            'disabling %s — not wanted (active target: %s)',
                            plugin_name, tostring(target_name)))
                    end
                    plugin_disable(entry, { quiet = not first_attempt })
                    was_off[plugin_name] = true
                end
            elseif pending_disable[plugin_name] then
                pending_disable[plugin_name]       = nil
                pending_disable_since[plugin_name] = nil
            end
        else
            was_off[plugin_name] = nil  -- wanted again; reset suppress flag
            -- pending_disable can get stuck when the same plugin's quest
            -- re-matches before disable_when() satisfied (e.g. a new Horde
            -- WarPlan appears while still in BSK so the old disable deferred).
            -- Once disable_when() finally clears here (player exited BSK,
            -- landed in Caldeum), force the handoff: plugin_disable arms
            -- transitions.teleport_pending so warplan.teleport_to_activity() fires before
            -- the plugin is re-enabled next cycle.
            if pending_disable[plugin_name] and entry.disable_when and entry.disable_when() then
                log(plugin_name .. ': pending disable resolved while re-wanted — forcing handoff, arming teleport')
                pending_disable[plugin_name]       = nil
                pending_disable_since[plugin_name] = nil
                plugin_disable(entry)
            end
        end
    end

    -- ── SAME-ACTIVITY CONTINUATION ──────────────────────────────────────────
    -- If the plugin we just disabled is the incoming activity (same quest
    -- pattern re-matched, e.g. back-to-back helltide WarPlans), skip the
    -- warplan teleport entirely. The player is already in the right zone and
    -- firing warplan.teleport_to_activity() would either do nothing (world/zone
    -- unchanged → retry loop) or fight with the plugin's own navigation.
    -- The transition gap (last_disable_time) still applies, giving the game
    -- state a beat to settle before the plugin re-enables.
    --
    -- Per-entry opt-out via same_activity_continuation = false: Infernal
    -- Hordes leaves the player in an empty BSK after the wave; back-to-back
    -- BSK WarPlans need the FULL exit_horde → Temis → Alfred → warplan
    -- teleport sequence to actually re-enter a fresh horde. Without the
    -- opt-out, WarPigs would re-enable HordeDev in place and the player
    -- would be stuck in an empty BSK with no sigil opened.
    if transitions.teleport_pending
        and last_disabled_plugin
        and wants[last_disabled_plugin]
        and (now - last_disabled_at) <= SAME_ACTIVITY_SECS
        and matched_reason[last_disabled_plugin] == last_disabled_reason
    then
        local incoming_entry = wants[last_disabled_plugin]
        local opt_out = incoming_entry
            and incoming_entry.same_activity_continuation == false
        if opt_out then
            log(string.format(
                '%s: same-activity continuation OPT-OUT (entry sets same_activity_continuation=false) — proceeding to full transition',
                last_disabled_plugin))
        else
            log(string.format(
                '%s: same-activity continuation pattern=%s (%.1fs since disable) — cancelling teleport, re-enable in place',
                last_disabled_plugin, tostring(last_disabled_reason), now - last_disabled_at))
            transitions.teleport_pending             = false
            transitions.teleport_incoming_first_seen = nil
            transitions.teleport_holding_key         = nil
            transitions.teleport_rearm_logged        = false
            last_disabled_plugin         = nil
            last_disabled_reason         = nil
        end
    end

    local transition_result = transitions.process_tick({
        now               = now,
        wants             = wants,
        matches           = matches,
        pending_disable   = pending_disable,
        settings          = settings,
        log               = log,
        orchestrator      = orchestrator,
        quest_plugin_map  = orchestrator.quest_plugin_map,
        normalize         = normalize,
        reaper_altar_watchdog = reaper_altar_watchdog,
        helltide_plugin_name  = orchestrator.helltide_plugin_name,
        is_plugin_on          = is_plugin_on,
        has_helltide_buff     = has_helltide_buff,
        helltide_active       = helltide_active,
        incoming_is_helltide  = incoming_is_helltide,
        enemies_near_player   = enemies_near_player,
        helltide_lingering_post_quest = helltide_lingering_post_quest,
        player_in_undercity       = in_undercity_zone,
        player_in_pit             = in_pit_zone,
        player_in_boss_lair       = in_boss_lair_zone,
    })
    if transition_result == 'limbo' then
        state_tracker.publish({
            now              = now,
            warpigs_on       = settings.is_active(),
            matches          = matches,
            transition_state = transitions.teleport_transition.state,
            teleport_pending = transitions.teleport_pending,
            gate_reason      = 'limbo — world loading',
        })
        return
    end

    -- ── ENABLE GATE ─────────────────────────────────────────────────────────
    -- Don't start the next plugin while:
    --   (a) any plugin's disable is still deferred (outgoing not finished), or
    --   (b) we just disabled something within TRANSITION_GAP_SECONDS, or
    --   (c) teleport transition state machine is mid-sequence.
    -- This is the actual handoff sequencer — pairs with disable_when to give
    -- the game state a clean break between activities.
    local gate_reason = nil
    for p in pairs(pending_disable) do
        gate_reason = 'pending disable: ' .. p
        break
    end
    if not gate_reason and transitions.teleport_transition.state ~= 'IDLE' then
        gate_reason = 'teleport transition: ' .. transitions.teleport_transition.state
    end
    -- Also gate while transitions.teleport_pending is true but the sequence hasn't
    -- started yet (state still IDLE because we're waiting for incoming /
    -- settle / alfred_idle). Without this, cold-start enables fire BEFORE
    -- the Tab+click runs because the state-machine hasn't transitioned out
    -- of IDLE yet.
    if not gate_reason and transitions.teleport_pending then
        gate_reason = 'teleport pending (waiting for prerequisites)'
    end
    if not gate_reason then
        for p, t in pairs(last_disable_time) do
            local age = now - t
            if age < TRANSITION_GAP_SECONDS then
                gate_reason = string.format('post-disable cooldown: %s (%.1fs left)',
                    p, TRANSITION_GAP_SECONDS - age)
                break
            end
        end
    end

    -- ── ENABLE PHASE ────────────────────────────────────────────────────────
    -- Edge-trigger: enable plugins newly wanted, unless gated.
    -- ALSO re-fire enable when the matched pattern changes for an
    -- already-owned plugin: Reaper's run_boss('zir') vs run_boss('varshan')
    -- both target ReaperPlugin, so without re-firing the plugin would keep
    -- running the old boss while WarPigs thinks the handoff is done.
    for plugin_name, entry in pairs(wants) do
        local newly_wanted = not last_wanted[plugin_name] and not owned[plugin_name]
        local reason       = matched_reason[plugin_name]
        local reason_changed = owned[plugin_name]
            and reason
            and last_enabled_reason[plugin_name]
            and last_enabled_reason[plugin_name] ~= reason
        local dropped_out = managed_by_us[plugin_name] and not is_plugin_on(plugin_name)
        -- After a disable() throw we still clear managed_by_us, so dropped_out
        -- is normally false. If the plugin later self-reports off while we
        -- still think we manage it, skip thrash-re-enable for a short window.
        if dropped_out and orchestrator._disable_threw_at
            and orchestrator._disable_threw_at[plugin_name]
        then
            local threw_age = now - orchestrator._disable_threw_at[plugin_name]
            if threw_age < 30.0 then
                if not reenable_logged[plugin_name] then
                    log(string.format(
                        'skipping re-enable of %s — disable() threw %.0fs ago (plugin bug)',
                        plugin_name, threw_age))
                    reenable_logged[plugin_name] = true
                end
                dropped_out = false
            end
        end
        if dropped_out and (enable_fail_count[plugin_name] or 0) >= ENABLE_FAIL_GIVE_UP then
            dropped_out = false
        end
        -- After give-up, newly_wanted would still fire every tick (owned never
        -- sticks). Only retry if the matched WarPlan pattern changed.
        if (enable_fail_count[plugin_name] or 0) >= ENABLE_FAIL_GIVE_UP then
            if reason_changed then
                enable_fail_count[plugin_name] = nil
                enable_fail_logged[plugin_name] = nil
            else
                newly_wanted = false
                dropped_out = false
            end
        end
        if newly_wanted or reason_changed or dropped_out then
            -- Per-entry hard gate (e.g. InfernalHordes refuses to enable
            -- outside BSK while teleport transition is on). Evaluated AFTER
            -- the transition gate so the orchestrator's normal sequencing
            -- runs first; this is a final safety net for the case where the
            -- teleport state machine "confirmed" without actually landing us
            -- at the destination.
            local entry_gate_reason
            if type(entry.enable_gate) == 'function' then
                local ok, allowed, why = pcall(entry.enable_gate)
                if ok and not allowed then
                    entry_gate_reason = why or 'enable_gate denied'
                end
            end
            if gate_reason then
                local gate_key = stable_gate_key(gate_reason)
                if enable_blocked[plugin_name] ~= gate_key then
                    log('deferring enable of ' .. plugin_name .. ' — ' .. gate_reason)
                    enable_blocked[plugin_name] = gate_key
                end
            elseif entry_gate_reason then
                if enable_blocked[plugin_name] ~= entry_gate_reason then
                    log('BLOCKING enable of ' .. plugin_name .. ' — ' .. entry_gate_reason)
                    enable_blocked[plugin_name] = entry_gate_reason
                end
                -- Re-arm the teleport sequence if it has gone idle without
                -- delivering us to the destination — otherwise the gate would
                -- deadlock. Only re-arm when the state machine isn't already
                -- working: transitions.teleport_pending false AND state IDLE.
                if settings.use_teleport_transition
                    and not transitions.teleport_pending
                    and transitions.teleport_transition.state == 'IDLE'
                then
                    if not transitions.teleport_rearm_logged then
                        log('re-arming teleport_pending — enable_gate denied with state IDLE')
                        transitions.teleport_rearm_logged = true
                    end
                    transitions.teleport_pending = true
                end
            else
                if reason_changed then
                    log(string.format('re-enabling %s — pattern changed: %s -> %s',
                        plugin_name, last_enabled_reason[plugin_name], reason))
                    pending_disable[plugin_name]       = nil
                    pending_disable_since[plugin_name] = nil
                elseif dropped_out then
                    if not reenable_logged[plugin_name] then
                        log('re-enabling ' .. plugin_name .. ' — plugin dropped off unexpectedly')
                        reenable_logged[plugin_name] = true
                    end
                end
                disable_role_siblings(plugin_name)
                plugin_enable(entry, reason)
            end
        end
    end

    -- last_wanted tracks "this plugin was actually owned at end of last tick".
    -- Plugins that were gated out of enabling must NOT be marked wanted, so
    -- the next tick's edge check fires the enable once the gate clears.
    last_wanted = {}
    for plugin_name in pairs(wants) do
        if owned[plugin_name] then last_wanted[plugin_name] = true end
    end
    last_matches = matches

    -- Stuck-recovery watchdog runs LAST so its snapshot (last_matches, owned,
    -- transitions.teleport_transition.state, transitions.teleport_pending) reflects this tick's final
    -- state. Reached via transitions.teleport_transition.stuck_tick to avoid adding a new
    -- upvalue to tick() (Lua 5.1 60-upvalue cap — see crow_walk comment).
    if settings.stuck_recovery then
        transitions.teleport_transition.stuck_tick(now)
    end

    local questing = (next(wants) ~= nil)
        or (next(owned) ~= nil)
        or matches[TURN_IN_PATTERN] == true
        or pit_filler_active_logged
        or transitions.teleport_transition.state ~= 'IDLE'
        or transitions.teleport_pending

    local ht_global = orchestrator.helltide_plugin_name()
    if ht_global then
        local ht_handoff = is_plugin_on(ht_global)
            or wants[ht_global] ~= nil
            or owned[ht_global] == true
            or incoming_is_helltide(wants)
        if ht_handoff and not has_helltide_buff() then
            if not orchestrator._whirlwind_stopped_outside_ht then
                orchestrator._stop_whirlwind()
                orchestrator._whirlwind_stopped_outside_ht = true
            end
        else
            orchestrator._whirlwind_stopped_outside_ht = false
        end
    end

    state_tracker.publish({
        now                = now,
        warpigs_on         = settings.is_active(),
        player_dead        = lp and lp:is_dead(),
        matches            = matches,
        matched_reason     = matched_reason,
        matched_blocked    = matched_blocked,
        owned              = owned,
        wants              = wants,
        pending_disable    = pending_disable,
        enable_blocked     = enable_blocked,
        gate_reason        = gate_reason,
        transition_state   = transitions.teleport_transition.state,
        teleport_pending   = transitions.teleport_pending,
        pit_filler         = pit_filler_active_logged,
        quest_plugin_map   = orchestrator.quest_plugin_map,
        normalize          = normalize,
    })

    -- Activity plugins own combat rotation; WarPigs only orchestrates handoffs.
end

-- Tear down when WarPigs is off. release_all on active→inactive transition;
-- stand_down every other inactive tick so SR/Alfred pauses and transition
-- state never linger after Enable is unchecked.
function orchestrator.on_inactive(was_running)
    if was_running then
        orchestrator.release_all()
    else
        orchestrator.stand_down()
    end
end

-- Release every plugin we currently own and clear orchestrator state.
-- Called when WarPigs is disabled or when stuck recovery fires.
function orchestrator.release_all()
    local to_release = {}
    for plugin_name in pairs(owned) do to_release[plugin_name] = true end
    for plugin_name in pairs(managed_by_us) do to_release[plugin_name] = true end
    for plugin_name in pairs(to_release) do
        plugin_disable(find_entry_for_plugin(plugin_name), { suppress_teleport = true })
    end
    orchestrator.stand_down()
end

-- Clear orchestrator bookkeeping without touching plugins the user enabled
-- manually. Safe to call every tick while WarPigs is off.
function orchestrator.stand_down()
    owned                 = {}
    managed_by_us         = {}
    was_off               = {}
    last_wanted           = {}
    last_matches          = {}
    pending_disable       = {}
    pending_disable_since = {}
    last_disable_time     = {}
    enable_blocked        = {}
    enable_fail_logged    = {}
    enable_fail_count     = {}
    reenable_logged       = {}
    last_enabled_reason   = {}
    broken_teardown       = {}
    teardown_err_logged   = {}
    teardown_gave_up_log  = {}
    orchestrator._disable_threw_at = {}
    transitions.reset()
    alfred_coord.reset_session()
    orchestrator._alfred_resume()
    -- Filler-pit state — re-arm only after the next session sees a turn-in.
    turn_in_was_matched      = false
    had_turn_in_complete     = false
    pit_filler_active_logged = false
    last_disabled_plugin     = nil
    last_disabled_at         = -math.huge
    last_disabled_reason     = nil
    -- Drop any pending Reaper run_once callback by bumping run_id; clear flag.
    reset_reaper_run_once()
    -- Clear the stuck-recovery anchor so the next session starts fresh.
    stuck_watchdog.reset()
end

-- ── Stuck-recovery wiring ───────────────────────────────────────────────────
-- Plugins force-disabled by recover_from_stuck. Includes both orchestrator-
-- managed activity plugins (in case ownership tracking lost them, e.g. after
-- a script reload while a plugin was running) and Alfred (which is otherwise
-- driven only via trigger_tasks, but may be hung mid-cycle in town).
local STUCK_RECOVERY_DISABLE_LIST = resolver.stuck_recovery_disable_list()
local STUCK_RECOVERY_CLEAR_TARGET_LIST = resolver.stuck_recovery_clear_target_list()

local function recover_from_stuck(reason)
    log('STUCK RECOVERY triggered: ' .. tostring(reason))
    -- 1. Tear down everything WarPigs owns (clears transition state, teleport
    --    pending, cold-start flag, deferred disables, watchdog timers, etc.).
    orchestrator.release_all()
    -- 2. Force-disable every plugin that *could* be running externally too.
    --    release_all only touches WarPigs-owned plugins; a plugin that
    --    self-enabled or survived a reload won't be in owned[].
    for _, name in ipairs(STUCK_RECOVERY_DISABLE_LIST) do
        local p = _G[name]
        if p and type(p.disable) == 'function' then
            local ok, err = pcall(p.disable)
            if ok then
                log('  recovery disabled ' .. name)
            else
                log('  recovery disable of ' .. name .. ' threw: ' .. tostring(err))
            end
        end
    end
    -- 3. Drop Batmobile / Frigate ownership so they stop driving any leftover
    --    movement target into the post-recovery teleport channel.
    for _, name in ipairs(STUCK_RECOVERY_CLEAR_TARGET_LIST) do
        local p = _G[name]
        if p and type(p.clear_target) == 'function' then
            pcall(p.clear_target, 'war_pigs_recovery')
        end
    end
    -- 4. Teleport to Temis. This is the standard "known good state" the
    --    orchestrator already uses for its via-Temis preamble; landing here
    --    means cold-start will pick up the next WarPlans match cleanly.
    if type(teleport_to_waypoint) == 'function' then
        local t_now = get_time_since_inject()
        orchestrator._stop_whirlwind()
        local ok, err = pcall(teleport_to_waypoint, TEMIS_WP)
        if ok then
            transitions.teleport_transition.last_temis_tp = t_now
            log('  recovery teleport_to_waypoint(Temis) sent')
        else
            log('  recovery teleport_to_waypoint threw: ' .. tostring(err))
        end
    else
        log('  teleport_to_waypoint unavailable — recovery cannot teleport')
    end
    -- 5. Re-enable Alfred. The disable in step 2 was a state reset to break a
    --    hung mid-cycle; Alfred is otherwise a passive always-on butler that
    --    no other code path will toggle back on. If we leave it disabled,
    --    alfred_trigger_now() reports "Alfred unavailable" on the next
    --    via-Temis preamble and we skip the salvage/restock step entirely.
    do
        local alfred = alfred_coord.get_plugin()
        if alfred and type(alfred.enable) == 'function' then
            local ok, err = pcall(alfred.enable)
            if ok then
                log('  recovery re-enabled AlfredTheButlerPlugin')
            else
                log('  recovery re-enable of AlfredTheButlerPlugin threw: ' .. tostring(err))
            end
        end
    end
    -- 6. Re-mark recovery in the watchdog (release_all reset its anchor
    --    already, but mark_recovery starts the POST_RECOVERY_GRACE clock).
    stuck_watchdog.mark_recovery(get_time_since_inject())
    log('STUCK RECOVERY: all plugins disabled, teleport sent — cold-start re-armed')
end

stuck_watchdog.init({
    recover = recover_from_stuck,
    log     = log,
    verbose = function() return false end,
    -- Snapshot of orchestrator state the watchdog needs to (a) decide whether
    -- the bot has a current goal worth monitoring, and (b) identify fragile
    -- "expected stationary" states. Built fresh each watchdog tick.
    snapshot = function()
        return {
            transition_state  = transitions.teleport_transition.state,
            teleport_pending  = transitions.teleport_pending,
            have_owned        = next(owned) ~= nil,
            have_active_quest = next(last_matches) ~= nil,
        }
    end,
})

-- Expose the watchdog tick through an existing tick() upvalue
-- (transitions.teleport_transition) so orchestrator.tick() doesn't have to add a new
-- upvalue slot — same trick as transitions.teleport_transition.crow_walk. Lua 5.1 caps
-- functions at 60 upvalues and tick() is already at the cap.
transitions.teleport_transition.stuck_tick = function(now_)
    stuck_watchdog.tick(now_)
end

function orchestrator.get_status_line()
    return state_tracker.get_status_line()
end

function orchestrator.get_state()
    return state_tracker.get_snapshot()
end

return orchestrator
