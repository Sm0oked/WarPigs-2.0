-- Alfred stash/salvage coordination shared by the orchestrator, turn-in task,
-- and stuck watchdog. Uses plugin_resolver for the configured Alfred variant.

local resolver = require 'core.plugin_resolver'

local M = {}

local EXTERNAL_CALLER          = 'WarPigs'
local CERRIGAR_ZONE            = 'Scos_Cerrigar'
local STUCK_NEED_TRIGGER_GRACE = 20.0
local ALFRED_KICK_COOLDOWN     = 5.0

local last_alfred_completion_at = nil
local last_alfred_kick_at       = -math.huge
local kick_blocked_fn           = nil

function M.get_plugin()
    return resolver.get_plugin_instance('alfred')
end

function M.player_in_cerrigar()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, zname = pcall(function() return w:get_current_zone_name() end)
    return ok2 and zname == CERRIGAR_ZONE
end

function M.is_steroid()
    local a = M.get_plugin()
    return a ~= nil and type(a.create_task) == 'function'
end

function M.pause()
    if M.is_steroid() then return end
    local alfred = M.get_plugin()
    if alfred and type(alfred.pause) == 'function' then
        pcall(alfred.pause, EXTERNAL_CALLER)
    end
end

function M.resume()
    if M.is_steroid() then return end
    local alfred = M.get_plugin()
    if alfred and type(alfred.resume) == 'function' then
        pcall(alfred.resume, EXTERNAL_CALLER)
    end
end

function M.on_complete()
    last_alfred_completion_at = get_time_since_inject()
    if not M.is_steroid() then
        M.pause()
    end
end

function M.set_kick_blocked(fn)
    kick_blocked_fn = fn
end

function M.fire_trigger(use_teleport)
    local alfred = M.get_plugin()
    if not alfred then return false end
    local ok_raven, raven = pcall(require, 'core.orchestrator.raven_coordination')
    if ok_raven and raven and raven.player_in_town() and not raven.is_paused_by_us() then
        raven.pause()
    end
    M.resume()
    if use_teleport and type(alfred.trigger_tasks_with_teleport) == 'function' then
        pcall(alfred.trigger_tasks_with_teleport, EXTERNAL_CALLER, M.on_complete)
    elseif type(alfred.trigger_tasks) == 'function' then
        pcall(alfred.trigger_tasks, EXTERNAL_CALLER, M.on_complete)
    else
        return false
    end
    return true
end

local function looteer_busy()
    local lp = _G.LooteerPlugin
    if not lp or type(lp.getSettings) ~= 'function' then return false end
    local ok, val = pcall(lp.getSettings, 'looting')
    return ok and val == true
end

function M.idle()
    if looteer_busy() then return false end
    local alfred = M.get_plugin()
    if not alfred or type(alfred.get_status) ~= 'function' then return true end
    local ok, s = pcall(alfred.get_status)
    if not ok or type(s) ~= 'table' then return true end
    if not s.enabled then return true end
    if s.paused and s.external_caller == EXTERNAL_CALLER then return true end
    if s.trigger_tasks and not M.player_in_cerrigar() and not s.teleport then
        M.pause()
        return true
    end
    if s.need_trigger or s.inventory_full or s.need_repair then
        local stash_full = s.stash_full
        local now = get_time_since_inject()
        if last_alfred_completion_at
            and (now - last_alfred_completion_at) < STUCK_NEED_TRIGGER_GRACE
            and (not s.inventory_full or stash_full)
            and not s.need_repair
        then
            return true
        end
        return false
    end
    if s.trigger_tasks then return false end
    return true
end

function M.kick_if_needed(log_fn)
    if kick_blocked_fn and kick_blocked_fn() then return end
    local ok_raven, raven = pcall(require, 'core.orchestrator.raven_coordination')
    if ok_raven and raven and raven.is_running() then return end
    local lp = get_local_player()
    if not lp then return end
    if _G.attributes and _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA ~= nil then
        local ok, val = pcall(function()
            return lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1
        end)
        if not (ok and val == true) then return end
    end
    if looteer_busy() then return end
    local alfred = M.get_plugin()
    if not alfred or type(alfred.get_status) ~= 'function' then return end
    local ok, s = pcall(alfred.get_status)
    if not ok or type(s) ~= 'table' then return end
    if not s.enabled then return end
    if s.paused and s.external_caller == EXTERNAL_CALLER then return end
    if s.trigger_tasks then return end
    if not (s.need_trigger or s.inventory_full) then return end
    local now = get_time_since_inject()
    if (now - last_alfred_kick_at) < ALFRED_KICK_COOLDOWN then return end
    last_alfred_kick_at = now
    if M.fire_trigger(not M.player_in_cerrigar()) and log_fn then
        log_fn('Alfred had work pending but was not processing — triggered (in town, pre-transition)')
    end
end

function M.trigger_now()
    local alfred = M.get_plugin()
    if not alfred or type(alfred.trigger_tasks) ~= 'function' then return false end
    if type(alfred.get_status) == 'function' then
        local ok, s = pcall(alfred.get_status)
        if not (ok and type(s) == 'table' and s.enabled) then return false end
    end
    return M.fire_trigger(not M.player_in_cerrigar())
end

function M.reset_session()
    last_alfred_completion_at = nil
    last_alfred_kick_at       = -math.huge
end

function M.get_last_kick_at()
    return last_alfred_kick_at
end

function M.set_last_kick_at(t)
    last_alfred_kick_at = t
end

function M.install_on(orchestrator)
    orchestrator._player_in_cerrigar   = M.player_in_cerrigar
    orchestrator._is_steroid_alfred    = M.is_steroid
    orchestrator._alfred_pause         = M.pause
    orchestrator._alfred_resume        = M.resume
    orchestrator._alfred_on_complete   = M.on_complete
    orchestrator._alfred_fire_trigger = M.fire_trigger
end

return M
