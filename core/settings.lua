-- Keep in sync with gui.lua plugin_label / plugin_version.
-- Intentionally does NOT require gui at load time — gui -> resolver -> settings
-- would otherwise circular-require and leave a broken cached gui module.

local PLUGIN_LABEL   = 'war_pigs'
local PLUGIN_VERSION = '2.0.1'

local settings = {
    plugin_label    = PLUGIN_LABEL,
    plugin_version  = PLUGIN_VERSION,
    enabled         = false,
    use_keybind     = false,
    use_teleport_transition = false,
    run_pit_after_turnin = false,
    use_silent_raven     = false,
    manage_orbwalker = false,
    skip_boss_chest = false,
    stuck_recovery          = true,
    show_session_stats_hud = true,
    stats_overlay_pos_x    = 2203,
    stats_overlay_pos_y    = 1094,
    stats_overlay_bg_alpha = 38,
    stats_overlay_border_alpha = 255,
    stats_overlay_font_size = 17,
    -- Plugin selection (combo_box index, 0-based).
    plugin_pit       = 0,
    plugin_helltide  = 0,
    plugin_undercity = 0,
    plugin_horde     = 0,
    plugin_boss      = 0,
    plugin_nav       = 0,
    plugin_alfred    = 0,
    plugin_scan_installed_only = true,
    plugin_advanced = false,
}

local bound_gui = nil

local function gui_elements()
    if bound_gui and bound_gui.elements then
        return bound_gui.elements
    end
    error('[WarPigs] GUI not bound — reload WarPigs from QQT Scripts')
end

settings.bind_gui = function(gui_mod)
    bound_gui = gui_mod
end

settings.set_main_toggle = function(on)
    local el = gui_elements()
    if el and el.main_toggle then
        el.main_toggle:set(on == true)
    end
end

settings.update_settings = function()
    local el = gui_elements()
    if not el or not el.main_toggle then
        return
    end
    settings.enabled        = el.main_toggle:get()
    settings.use_keybind    = el.use_keybind:get()
    settings.use_teleport_transition = el.use_teleport_transition:get()
    settings.run_pit_after_turnin = el.run_pit_after_turnin:get()
    settings.use_silent_raven     = el.use_silent_raven:get()
    settings.manage_orbwalker = el.manage_orbwalker:get()
    settings.skip_boss_chest  = el.skip_boss_chest:get()
    settings.stuck_recovery         = el.stuck_recovery:get()
    settings.show_session_stats_hud = el.show_session_stats_hud:get()
    settings.stats_overlay_pos_x    = el.stats_overlay_pos_x:get()
    settings.stats_overlay_pos_y    = el.stats_overlay_pos_y:get()
    settings.stats_overlay_bg_alpha   = el.stats_overlay_bg_alpha:get()
    settings.stats_overlay_border_alpha = el.stats_overlay_border_alpha:get()
    settings.stats_overlay_font_size  = el.stats_overlay_font_size:get()
    settings.plugin_pit       = el.plugin_pit:get()
    settings.plugin_helltide  = el.plugin_helltide:get()
    settings.plugin_undercity = el.plugin_undercity:get()
    settings.plugin_horde     = el.plugin_horde:get()
    settings.plugin_boss      = el.plugin_boss:get()
    settings.plugin_nav       = el.plugin_nav:get()
    settings.plugin_alfred    = el.plugin_alfred:get()
    if el.plugin_scan_installed_only then
        settings.plugin_scan_installed_only = el.plugin_scan_installed_only:get()
    end
    if el.plugin_advanced then
        settings.plugin_advanced = el.plugin_advanced:get()
    end
end

settings.get_keybind_state = function()
    if not settings.use_keybind then return true end
    local kb = gui_elements().keybind_toggle
    return kb:get_key() ~= 0x0A and kb:get_state() == 1
end

settings.is_active = function()
    return settings.enabled and settings.get_keybind_state()
end

return settings
