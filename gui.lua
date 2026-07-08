local plugin_label   = 'war_pigs'
local plugin_version = '2.0.0'
console.print('Lua Plugin - WarPigs - v' .. plugin_version)

local registry = require 'core.plugin_registry'
local resolver = require 'core.plugin_resolver'
local session_stats = require 'core.session_stats'

local gui = {}

local create_checkbox = function(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

local create_plugin_combo = function(key)
    return combo_box:new(0, get_hash(plugin_label .. '_plugin_' .. key))
end

local create_slider = function(min, max, value, key)
    return slider_int:new(min, max, value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.role_options = {}
for _, role_id in ipairs(registry.menu_roles) do
    gui.role_options[role_id] = registry.choice_labels(role_id)
end

gui.elements = {
    main_tree     = tree_node:new(0),
    plugins_tree  = tree_node:new(1),
    main_toggle   = create_checkbox(false, 'main_toggle'),
    use_keybind   = create_checkbox(false, 'use_keybind'),
    keybind_toggle= keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle')),
    plugin_pit       = create_plugin_combo('pit'),
    plugin_helltide  = create_plugin_combo('helltide'),
    plugin_undercity = create_plugin_combo('undercity'),
    plugin_nmd       = create_plugin_combo('nmd'),
    plugin_horde     = create_plugin_combo('horde'),
    plugin_boss      = create_plugin_combo('boss'),
    plugin_nav       = create_plugin_combo('nav'),
    plugin_combat    = create_plugin_combo('combat'),
    plugin_alfred    = create_plugin_combo('alfred'),
    manage_combat_rotation = create_checkbox(true, 'manage_combat_rotation'),
    plugin_advanced        = create_checkbox(false, 'plugin_advanced'),
    use_teleport_transition = create_checkbox(false, 'use_teleport_transition'),
    run_pit_after_turnin    = create_checkbox(false, 'run_pit_after_turnin'),
    use_silent_raven        = create_checkbox(false, 'use_silent_raven'),
    manage_orbwalker        = create_checkbox(false, 'manage_orbwalker'),
    skip_boss_chest         = create_checkbox(false, 'skip_boss_chest'),
    stuck_recovery          = create_checkbox(true,  'stuck_recovery'),
    show_session_stats_hud  = create_checkbox(true, 'show_session_stats_hud'),
    stats_overlay_tree      = tree_node:new(1),
    stats_overlay_pos_x     = create_slider(0, 3840, 2203, 'stats_overlay_pos_x'),
    stats_overlay_pos_y     = create_slider(0, 2160, 1094, 'stats_overlay_pos_y'),
    stats_overlay_bg_alpha  = create_slider(0, 255, 38, 'stats_overlay_bg_alpha'),
    stats_overlay_border_alpha = create_slider(0, 255, 255, 'stats_overlay_border_alpha'),
    stats_overlay_font_size = create_slider(10, 22, 17, 'stats_overlay_font_size'),
    reset_session_stats     = create_checkbox(false, 'reset_session_stats'),
}

local PLUGIN_MENU_HINTS = {
    pit       = 'Pit bot for WarPlans pit quests and optional pit filler.',
    helltide  = 'Helltide bot for WarPlans helltide quests.\nAuto detects HelltideRevamped or BetterHelltide.',
    undercity = 'Undercity bot for WarPlans undercity quests.',
    nmd       = 'Nightmare dungeon bot for WarPlans NMD quests.',
    horde     = 'Infernal Hordes bot for WarPlans horde quests.',
    boss      = 'Boss-run bot for WarPlans boss lair quests.',
    nav       = 'Navigation for WarPigs town walks (Tyrael, crow).\nAuto prefers Batmobile, then Frigate.',
    combat    = 'Combat rotation while WarPigs is driving a quest.\nAuto picks the rotation that is loaded.',
    alfred    = 'Alfred pack for stash/salvage between activities.',
}

local PLUGIN_MENU_LABELS = {
    pit       = 'Pit',
    helltide  = 'Helltide',
    undercity = 'Undercity',
    nmd       = 'Nightmare dungeons',
    horde     = 'Infernal Hordes',
    boss      = 'Boss lairs',
    nav       = 'Navigation',
    combat    = 'Combat rotation',
    alfred    = 'Alfred',
}

function gui.get_overlay_layout()
    local el = gui.elements
    return {
        enabled      = el.show_session_stats_hud:get(),
        pos_x        = el.stats_overlay_pos_x:get(),
        pos_y        = el.stats_overlay_pos_y:get(),
        bg_alpha     = el.stats_overlay_bg_alpha:get(),
        border_alpha = el.stats_overlay_border_alpha:get(),
        font_size    = el.stats_overlay_font_size:get(),
    }
end

local function render_plugin_selection()
    local scripts_scan = require 'core.scripts_scan'
    if not scripts_scan.has_results() then
        scripts_scan.refresh()
    end

    local advanced = gui.elements.plugin_advanced:get()
    if advanced then
        render_menu_header('Manual mode: choose each task plugin below.')
    else
        render_menu_header('Auto mode: WarPigs uses loaded plugins per task.')
    end

    for _, role_id in ipairs(registry.menu_roles) do
        local status = resolver.status(role_id)
        local el     = gui.elements['plugin_' .. role_id]
        local label  = PLUGIN_MENU_LABELS[role_id] or role_id
        local show_combo = advanced
            or status.loaded_count > 1
            or status.choice_id ~= 'auto'

        if el and show_combo then
            gui.role_options[role_id] = registry.choice_labels_live(role_id, true)
            el:render(label, gui.role_options[role_id], PLUGIN_MENU_HINTS[role_id] or '')
        elseif status.resolved_loaded then
            render_menu_header(label .. ':  ' .. (status.resolved_label or status.resolved))
        elseif status.resolved then
            render_menu_header(label .. ':  ' .. (status.resolved_label or status.resolved) .. ' — not loaded')
        end
    end

    gui.elements.plugin_advanced:render('Manual plugin selection',
        'Off (default): auto-detect loaded plugins.\n' ..
        'On: show every task dropdown for manual picks.')

    for _, warning in ipairs(resolver.validate_all()) do
        render_menu_header('Setup: ' .. warning)
    end
end

gui.render = function()
    if not gui.elements.main_tree:push('Z | War Pigs | Orchestrator | v' .. gui.plugin_version) then return end

    local orchestrator = require 'core.orchestrator'
    for quest_name, raw_entry in pairs(orchestrator.quest_plugin_map) do
        local plugin_name
        if type(raw_entry) == 'string' then
            plugin_name = raw_entry
        elseif type(raw_entry) == 'table' then
            plugin_name = raw_entry.plugin
        end
        if plugin_name and resolver.is_marker(plugin_name) then
            plugin_name = resolver.resolve_marker(plugin_name)
        end
        if plugin_name and _G[plugin_name] == nil then
            render_menu_header(plugin_name .. ' not loaded — ' .. quest_name .. ' will not run')
        end
    end

    gui.elements.main_toggle:render('Enable',
        'Master switch. When on, WarPigs watches WarPlans quests and\n' ..
        'enables the right activity plugins for each task.')
    gui.elements.use_keybind:render('Use keybind', 'Optional hotkey to toggle WarPigs on/off.')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind_toggle:render('Toggle keybind', 'Press to toggle WarPigs on/off.')
    end

    if gui.elements.plugins_tree:push('Plugin Selection') then
        render_plugin_selection()
        gui.elements.plugins_tree:pop()
    end

    gui.elements.use_teleport_transition:render('Use teleport',
        'After each activity, call warplan.teleport_to_activity() before\n' ..
        'starting the next plugin. Waits for the channel to settle.')

    gui.elements.use_silent_raven:render('Use SilentRaven',
        'After Alfred, walk to the Crow of the Tree and trigger SilentRaven\n' ..
        'for pending Tree of Whispers turn-ins. Requires SilentRaven installed.')

    gui.elements.run_pit_after_turnin:render('Run pit after turn-in',
        'After the first WarPlans turn-in, fill idle time with your pit plugin\n' ..
        'until the next WarPlans quest appears.')

    gui.elements.skip_boss_chest:render('Skip boss chest',
        'Disable the boss plugin when the chest spawns instead of opening it.\n' ..
        'Only affects WarPigs-initiated boss runs.')

    gui.elements.manage_orbwalker:render('Manage orbwalker',
        'Force orbwalker clear ON before each managed plugin starts.')

    gui.elements.manage_combat_rotation:render('Manage combat rotation',
        'Enable your chosen combat rotation while a WarPlans quest is active.\n' ..
        'Does not touch rotations while idle in town.')

    gui.elements.stuck_recovery:render('Stuck recovery',
        'If movement stalls for several minutes during an activity, disable\n' ..
        'managed plugins, teleport to Temis, and restart the next quest cleanly.')

    gui.elements.show_session_stats_hud:render('Session stats overlay',
        'Show a stats panel on screen. Works independently of the Enable toggle.')

    if gui.elements.stats_overlay_tree:push('Overlay appearance') then
        gui.elements.stats_overlay_pos_x:render('Position X', 'Panel left edge in pixels.')
        gui.elements.stats_overlay_pos_y:render('Position Y', 'Panel top edge in pixels.')
        gui.elements.stats_overlay_bg_alpha:render('Background opacity', '0 = transparent, 255 = solid.')
        gui.elements.stats_overlay_border_alpha:render('Border opacity', 'Blue border opacity.')
        gui.elements.stats_overlay_font_size:render('Font size', 'Overlay text size.')
        gui.elements.stats_overlay_tree:pop()
    end

    gui.elements.reset_session_stats:render('Reset session stats',
        'Clear overlay counters and restart the session timer.')
    if gui.elements.reset_session_stats:get() then
        session_stats.reset()
        gui.elements.reset_session_stats:set(false)
    end

    gui.elements.main_tree:pop()
end

return gui
