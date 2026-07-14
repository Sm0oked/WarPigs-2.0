-- WarPigs navigation layer: resolves the configured nav plugin (Batmobile / Frigate)
-- for town walks (Tyrael, crow) and whirlwind teardown before teleports.

local resolver = require 'core.plugin_resolver'

local M = {}

local NAV_LABEL = 'war_pigs'

function M.label()
    return NAV_LABEL
end

function M.global_name()
    return resolver.resolve_global('nav')
end

function M.get_plugin()
    return resolver.get_plugin_instance('nav')
end

-- Stops whirlwind on both nav plugins — channel cast spam cancels waypoint teleports.
--
-- Barbarian/whirlwind fix: a one-shot channel teardown is NOT enough on
-- Frigate. Its whirlwind runs in a per-tick spam mode (cast_spell.position
-- every pulse — it even "whirls in place to maintain buff" with an empty
-- path), so as long as any nav driver is still active (leftover target from
-- the just-disabled activity bot, or autonomous long-path navigation), the
-- spell comes right back one tick after the soft stop and cancels the 5s
-- teleport channel anyway. Result: TO_TEMIS/TELEPORTING retry loops with the
-- barb stuck spinning. Kill the SOURCE too: stop long-path navigation and
-- clear the short-path target so the driver goes idle, try_cast_whirlwind
-- stops firing, and Frigate's own per-pulse idle teardown keeps the channel
-- down for the whole teleport. Called before every teleport attempt/retry.
function M.stop_whirlwind_for_teleport(label)
    local who = label or NAV_LABEL
    local function stop_one(plugin)
        if type(plugin) ~= 'table' then return end
        if type(plugin.whirlwind_soft_stop) == 'function' then
            pcall(plugin.whirlwind_soft_stop, who)
        elseif type(plugin.whirlwind_force_stop) == 'function' then
            pcall(plugin.whirlwind_force_stop, who)
        end
        if type(plugin.stop_long_path) == 'function' then
            pcall(plugin.stop_long_path, who)
        end
        if type(plugin.clear_target) == 'function' then
            pcall(plugin.clear_target, who)
        end
    end
    stop_one(rawget(_G, 'BatmobilePlugin'))
    stop_one(rawget(_G, 'FrigatePlugin'))
end

function M.clear_target(label)
    local who = label or NAV_LABEL
    local bp = M.get_plugin()
    if bp and type(bp.clear_target) == 'function' then
        pcall(bp.clear_target, who)
    end
end

-- Drive toward world position. Returns status, distance (see transitions crow_walk).
function M.walk_toward(pos, started_at, now, opts)
    opts = opts or {}
    local arrival_radius = opts.arrival_radius or 3.5
    local timeout        = opts.timeout or 30.0
    local disable_spell_dist = opts.disable_spell_dist or 4

    local lp = get_local_player and get_local_player() or nil
    if not lp or not lp.get_position then return 'timeout', math.huge end
    local ok, pp = pcall(function() return lp:get_position() end)
    if not ok or not pp then return 'timeout', math.huge end

    local dx   = pp:x() - pos.x
    local dy   = pp:y() - pos.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist <= arrival_radius then return 'arrived', dist end
    if started_at and (now - started_at) >= timeout then
        return 'timeout', dist
    end

    local bp = M.get_plugin()
    if not (bp and vec3 and vec3.new
        and type(bp.set_target) == 'function'
        and type(bp.move) == 'function')
    then
        if pathfinder and pathfinder.request_move and vec3 and vec3.new then
            pathfinder.request_move(vec3:new(pos.x, pos.y, pos.z))
        end
        return 'walking', dist
    end

    if type(bp.pause)  == 'function' then pcall(bp.pause,  NAV_LABEL) end
    if type(bp.update) == 'function' then pcall(bp.update, NAV_LABEL, true) end
    local nav_pos       = vec3:new(pos.x, pos.y, pos.z)
    local disable_spell = (dist <= disable_spell_dist)
    local ok_set, accepted = pcall(bp.set_target, NAV_LABEL, nav_pos, disable_spell)
    if ok_set and accepted == false then
        if pathfinder and pathfinder.request_move then
            pathfinder.request_move(nav_pos)
        end
    else
        pcall(bp.move, NAV_LABEL)
    end
    return 'walking', dist
end

return M
