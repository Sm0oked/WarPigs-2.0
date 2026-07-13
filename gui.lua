local plugin_label   = 'war_pigs'
local plugin_version = '2.0.8'
console.print('Lua Plugin - WarPigs - v' .. plugin_version)

local registry = require 'core.plugin_registry'
local resolver = require 'core.plugin_resolver'
local session_stats = require 'core.session_stats'
local settings = require 'core.settings'

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
    gui.role_options[role_id] = registry.choice_labels_static(role_id)
end

gui.elements = {
    main_tree     = tree_node:new(0),
    plugins_tree  = tree_node:new(1),
    main_toggle   = create_checkbox(false, 'main_toggle'),
    use_keybind   = create_checkbox(false, 'use_keybind'),
    keybind_toggle= keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle')),
    plugin_pit       = create_plugin_combo('pit'),
    plugin_helltide  = create_plugin_combo('helltide'),
    plugin_horde     = create_plugin_combo('horde'),
    plugin_boss      = create_plugin_combo('boss'),
    plugin_alfred    = create_plugin_combo('alfred'),
    plugin_advanced        = create_checkbox(false, 'plugin_advanced'),
    plugin_scan_installed_only = create_checkbox(true, 'plugin_scan_installed_only'),
    plugin_scan_refresh        = create_checkbox(false, 'plugin_scan_refresh'),
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

-- Undercity and Navigation have no dropdown: Wonder City is the only
-- undercity bot, and navigation is auto-detected (Batmobile -> Frigate).
local PLUGIN_MENU_HINTS = {
    pit       = 'Pit bot for WarPlans pit quests and optional pit filler.',
    helltide  = 'Helltide bot for WarPlans helltide quests.\n'
        .. 'Auto prefers HelltideRevamped when both are loaded.\n'
        .. 'Pick BetterHelltide explicitly to use the pack (HelltideLitePlugin).\n'
        .. 'Disable the unused one in QQT Scripts to avoid handoff fights.',
    horde     = 'Infernal Hordes bot for WarPlans horde quests.',
    boss      = 'Boss-run bot for WarPlans boss lair quests.\nDefault: Reaper 3.0.pack (enable it in QQT Scripts).',
    alfred    = 'Alfred pack for stash/salvage between activities.',
}

local PLUGIN_MENU_LABELS = {
    pit       = 'Pit',
    helltide  = 'Helltide',
    horde     = 'Infernal Hordes',
    boss      = 'Boss lairs',
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

-- One compact line under each dropdown: what the current pick resolves to
-- right now. This is the ground truth the orchestrator uses on the next
-- handoff, so the user can see at a glance which bot each role will run.
local function render_role_status(role_id, installed_only)
    local status = resolver.status(role_id)
    local line
    if status.resolved and status.resolved_loaded then
        line = '-> ' .. status.resolved
        if status.choice_id == 'auto' and status.loaded_count > 1 then
            line = line .. string.format('  (%d loaded - Auto uses first)', status.loaded_count)
        end
    elseif status.resolved then
        local hint = resolver.missing_enable_hint(status.resolved)
        line = '-> ' .. status.resolved .. ' NOT loaded'
        if hint and hint ~= '' then
            line = line .. ' - ' .. hint
        end
    else
        line = '-> nothing loaded for this role'
    end
    if installed_only then
        local scan_mod = require 'core.scripts_scan'
        if scan_mod.has_results() then
            local choice = resolver.get_choice(role_id)
            if choice and choice.folder then
                local catalog = require 'core.plugin_catalog'
                if not catalog.installed_scan_hit(choice.folder, scan_mod.get_folders()) then
                    line = line .. '  [not found on disk in last scan]'
                end
            end
        end
    end
    render_menu_header('      ' .. line)
end

local combo_id_restored = {}

local function clamp_combo_index(el, label_count)
    if not el or not label_count or label_count < 1 then return 0 end
    local ok, idx = pcall(function() return el:get() end)
    if not ok or type(idx) ~= 'number' then idx = 0 end
    if idx < 0 or idx >= label_count then
        idx = 0
        pcall(function() el:set(0) end)
    end
    return idx
end

local function prepare_combo_index(el, role_id, label_count)
    if not el or not label_count or label_count < 1 then return 0 end

    -- Restore saved choice id once per session (index drift after scan/reload).
    if not combo_id_restored[role_id] then
        combo_id_restored[role_id] = true
        local id_key = registry.settings_choice_id_key[role_id]
        if id_key and settings[id_key] and settings[id_key] ~= 'auto' then
            local from_id = registry.choice_index_for_id_static(role_id, settings[id_key])
            if from_id ~= nil and from_id >= 0 and from_id < label_count then
                pcall(function() el:set(from_id) end)
            end
        end
    end

    return clamp_combo_index(el, label_count)
end

local function sync_combo_settings(role_id, el)
    local labels = registry.choice_labels_static(role_id)
    if #labels == 0 then return end
    local idx = clamp_combo_index(el, #labels)
    local combo_key = registry.settings_key[role_id]
    if combo_key then settings[combo_key] = idx end
    local choice = registry.choice_at_static(role_id, idx)
    local id_key = registry.settings_choice_id_key[role_id]
    if id_key and choice then settings[id_key] = choice.id end
end

local function clamp_all_role_combos()
    for _, role_id in ipairs(registry.menu_roles) do
        local el = gui.elements['plugin_' .. role_id]
        local labels = registry.choice_labels_static(role_id)
        if el and #labels > 0 then
            clamp_combo_index(el, #labels)
        end
    end
end

local function render_role_combo(role_id, el, label, hint)
    local labels = registry.choice_labels_static(role_id)
    if #labels == 0 then return end
    prepare_combo_index(el, role_id, #labels)
    pcall(function()
        el:render(label, labels, hint or '')
    end)
    sync_combo_settings(role_id, el)
end

local function render_plugin_selection()
    local scripts_scan = require 'core.scripts_scan'

    clamp_all_role_combos()

    gui.elements.plugin_scan_refresh:render('Scan entries',
        'Scan scripts/ for plugin folders (main.lua) and .pack files.\n' ..
        'Also reads loaded package.path entries. Runs only when you click this.')
    if gui.elements.plugin_scan_refresh:get() then
        local ok, err = pcall(scripts_scan.refresh)
        gui.elements.plugin_scan_refresh:set(false)
        clamp_all_role_combos()
        if ok then
            console.print(string.format(
                '[WarPigs] Plugin scan complete — %d folder(s), %d .pack(s) in %s',
                scripts_scan.folder_count(), scripts_scan.pack_count(),
                scripts_scan.get_scripts_root() or '?'))
        else
            console.print('[WarPigs] Plugin scan failed: ' .. tostring(err))
        end
    end

    local installed_only = gui.elements.plugin_scan_installed_only:get()
    local advanced = gui.elements.plugin_advanced:get()
    if advanced then
        render_menu_header('Manual mode: choose each task plugin below.')
    else
        render_menu_header('Auto mode: each dropdown defaults to Auto; override any role explicitly.')
    end

    for _, role_id in ipairs(registry.menu_roles) do
        local el    = gui.elements['plugin_' .. role_id]
        local label = PLUGIN_MENU_LABELS[role_id] or role_id
        if el then
            render_role_combo(role_id, el, label, PLUGIN_MENU_HINTS[role_id] or '')
            render_role_status(role_id, installed_only)
        end
    end

    gui.elements.plugin_advanced:render('Manual plugin selection',
        'Off (default): dropdowns still show; leave roles on Auto to detect loaded plugins.\n'
            .. 'On: same dropdowns — use when you want to force every pick explicitly.')

    gui.elements.plugin_scan_installed_only:render('Check installs on disk',
        'After Scan entries: flag role picks whose plugin folder / .pack was\n' ..
        'not found on disk ("[not found on disk in last scan]").\n' ..
        'Dropdown lists always stay full — they never shrink (combo crash safety).')

    local summary = registry.scan_summary()
    if summary.scanned then
        local pack_note = (summary.pack_count or 0) > 0
            and string.format(', %d .pack(s)', summary.pack_count)
            or ''
        render_menu_header(string.format(
            'Last scan: %s — %d plugin(s)%s',
            summary.last_scan_at or '?', summary.folder_count, pack_note))
        if summary.scripts_root and summary.scripts_root ~= '' then
            render_menu_header('Scripts folder: ' .. summary.scripts_root)
        end
        local scripts_scan = require 'core.scripts_scan'
        if scripts_scan.pack_count() > 0 then
            local packs = table.concat(scripts_scan.get_pack_files(), ', ')
            render_menu_header('Packs found: ' .. packs)
        end
        if #summary.unmapped > 0 then
            local preview = table.concat(summary.unmapped, ', ', 1, math.min(4, #summary.unmapped))
            if #summary.unmapped > 4 then
                preview = preview .. ', ...'
            end
            render_menu_header('Unmapped plugins: ' .. preview)
        end
    else
        render_menu_header('Plugin scan not run — click Scan entries to detect folders and .pack files')
    end

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

    gui.elements.stuck_recovery:render('Stuck recovery',
        'If movement stalls for several minutes during an activity, disable\n' ..
        'managed plugins, teleport to Temis, and restart the next quest cleanly.')

    gui.elements.show_session_stats_hud:render('Session stats overlay',
        'Show a stats panel on screen while WarPigs Enable is on.')

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
