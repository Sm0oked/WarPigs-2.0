-- Resolve this plugin's folder before any require (QQT has no debug library).
do
    local root
    if debug and debug.getinfo then
        local src = debug.getinfo(1, 'S')
        if src and src.source and src.source:sub(1, 1) == '@' then
            root = src.source:sub(2):gsub('[\\/][^\\/]+$', '')
        end
    end
    if not root and package.searchpath then
        local p = package.searchpath('main', package.path)
        if p then
            root = p:gsub('[\\/]main%.lua$', '')
        end
    end
    if root then
        _G.__WARPIGS_PLUGIN_ROOT = root
        package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
        local stale = {
            'gui', 'core.settings', 'core.orchestrator', 'core.external',
            'core.plugin_registry', 'core.plugin_resolver',
            'core.plugin_catalog', 'core.scripts_scan',
            'core.navigation', 'core.stuck_watchdog',
            'core.orchestrator.alfred_coordination',
            'core.orchestrator.raven_coordination',
            'core.orchestrator.transitions',
            'core.state_tracker',
            'core.session_stats',
            'core.tasks.turn_in_rewards',
        }
        for _, mod in ipairs(stale) do
            package.loaded[mod] = nil
        end
    end
end

local gui          = require 'gui'
local settings     = require 'core.settings'
settings.bind_gui(gui)
local orchestrator = require 'core.orchestrator'
local external     = require 'core.external'
local state_tracker = require 'core.state_tracker'
local session_stats = require 'core.session_stats'

local last_tick      = 0
local tick_interval  = 0.5
local was_enabled    = false

local main_pulse = function()
    if get_time_since_inject() - last_tick < tick_interval then return end
    last_tick = get_time_since_inject()
    settings:update_settings()

    local active = settings.is_active()
    if not active then
        orchestrator.on_inactive(was_enabled)
        was_enabled = false
        state_tracker.publish_off(get_time_since_inject())
        return
    end
    was_enabled = true

    if not get_local_player() then return end
    orchestrator.tick()
end

local render_err_logged = false

local render_pulse = function()
    settings:update_settings()

    if settings.show_session_stats_hud then
        local ok, err = pcall(session_stats.render, gui)
        if not ok and not render_err_logged then
            render_err_logged = true
            console.print('[WarPigs] Session stats overlay error: ' .. tostring(err))
        elseif ok then
            render_err_logged = false
        end
    end

    if not settings.is_active() then return end
    local msg = orchestrator.get_status_line()
    if msg then
        local x_pos = get_screen_width() / 2 - (#msg * 5.5)
        graphics.text_2d(msg, vec2:new(x_pos, 100), 20, color_white(255))
    end
end

on_update(main_pulse)
on_render_menu(function() gui.render() end)
on_render(render_pulse)

WarPigsPlugin = external
