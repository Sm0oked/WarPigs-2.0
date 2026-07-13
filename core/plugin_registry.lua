-- Plugin roles WarPigs can assign per activity / support task.
-- Each role lists menu choices; resolver turns the user's pick into a _G global.
--
-- ★ NON-DEVS: to add a new bot as a dropdown option, follow Recipe 1 in
--   HOW-TO-EDIT.md (in the WarPigs folder). Rules that keep saves/menus safe:
--     * Add new `choices` entries at the END of a role's list only.
--     * NEVER delete or reorder existing `choices` entries.
--     * Also add the new global to that role's all_globals AND auto_globals.
--   Run check_syntax.bat after editing, before reloading in QQT.

local M = {}

M.ROLE_MARKERS = {
    pit       = '__pit__',
    helltide  = '__helltide__',
    undercity = '__undercity__',
    horde     = '__horde__',
    boss      = '__boss__',
}

M.roles = {
    pit = {
        label       = 'Pit',
        marker      = '__pit__',
        default     = 0,
        priority    = 100,
        all_globals  = { 'Pit2Plugin', 'ArkhamAsylumPlugin' },
        -- Prefer Pit2Plugin only — ArkhamAsylumPlugin is the same table (legacy alias).
        auto_globals = { 'Pit2Plugin' },
        choices = {
            {
                id     = 'auto',
                label  = 'Auto (Pit 2.0)',
                global = 'Pit2Plugin',
            },
            {
                id     = 'pit2',
                label  = 'Pit 2.0',
                global = 'Pit2Plugin',
                folder = 'Pit2.0',
            },
            {
                id     = 'arkham',
                label  = 'Arkham Asylum (legacy alias)',
                global = 'ArkhamAsylumPlugin',
                folder = 'Pit2.0',
            },
        },
        required_api = { 'enable', 'disable' },
    },

    helltide = {
        label   = 'Helltide',
        marker  = '__helltide__',
        default = 0,
        priority    = 40,
        all_globals  = { 'HelltideRevampedPlugin', 'HelltideLitePlugin', 'BetterHelltidePlugin' },
        -- Auto prefers Revamped when both are loaded. BetterHelltide pack often
        -- sits on disk (or half-loads) and used to win Auto first, so WarPigs
        -- enabled Lite while the user was running / debugging Revamped.
        auto_globals = { 'HelltideRevampedPlugin', 'HelltideLitePlugin', 'BetterHelltidePlugin' },
        choices = {
            {
                id     = 'auto',
                label  = 'Auto (prefer Revamped if both)',
                global = nil,
            },
            {
                id     = 'helltide_revamped',
                label  = 'HelltideRevamped',
                global = 'HelltideRevampedPlugin',
                folder = 'HelltideRevamped',
            },
            {
                id     = 'better_helltide',
                label  = 'BetterHelltide',
                global = 'HelltideLitePlugin',
                alt_global = 'BetterHelltidePlugin',
                folder = 'BetterHelltide',
            },
        },
    },

    undercity = {
        label       = 'Undercity',
        marker      = '__undercity__',
        default     = 0,
        priority    = 50,
        all_globals  = { 'WonderCityPlugin' },
        auto_globals = { 'WonderCityPlugin' },
        choices = {
            {
                id     = 'auto',
                label  = 'Auto (Wonder City)',
                global = 'WonderCityPlugin',
            },
            {
                id     = 'wonder_city',
                label  = 'Wonder City',
                global = 'WonderCityPlugin',
                folder = 'WonderCity-2.0',
            },
        },
        required_api = { 'enable', 'disable' },
    },

    horde = {
        label       = 'Infernal Hordes',
        marker      = '__horde__',
        default     = 0,
        priority    = 90,
        all_globals  = { 'InfernalHordesPlugin' },
        auto_globals = { 'InfernalHordesPlugin' },
        choices = {
            {
                id     = 'auto',
                label  = 'Auto (HordeDev)',
                global = 'InfernalHordesPlugin',
            },
            {
                id     = 'horde_dev',
                label  = 'Infernal Horde',
                global = 'InfernalHordesPlugin',
                folder = 'Infernal Horde',
            },
        },
        required_api = { 'enable', 'disable', 'getState' },
    },

    boss = {
        label       = 'Boss lairs',
        marker      = '__boss__',
        default     = 0,
        priority    = 80,
        all_globals  = { 'ReaperPlugin' },
        auto_globals = { 'ReaperPlugin' },
        choices = {
            {
                id     = 'reaper30',
                label  = 'Reaper 3.0.pack',
                global = 'ReaperPlugin',
                folder = 'Reaper',
            },
            {
                id     = 'auto',
                label  = 'Auto (Reaper3.0.pack → folder)',
                global = 'ReaperPlugin',
            },
            {
                id     = 'reaper',
                label  = 'Reaper (open-source folder)',
                global = 'ReaperPlugin',
                folder = 'Reaper',
            },
        },
        required_api = { 'enable', 'disable' },
    },

    nav = {
        label       = 'Navigation',
        default     = 0,
        all_globals  = { 'BatmobilePlugin', 'FrigatePlugin' },
        auto_globals = { 'BatmobilePlugin', 'FrigatePlugin' },
        choices = {
            {
                id     = 'auto',
                label  = 'Auto (Batmobile → Frigate)',
                global = nil,
            },
            {
                id     = 'batmobile',
                label  = 'Batmobile / Chassis',
                global = 'BatmobilePlugin',
                folder = 'Batmobile',
            },
            {
                id     = 'frigate',
                label  = 'Frigate',
                global = 'FrigatePlugin',
                folder = 'Frigate',
            },
        },
        required_api = { 'set_target', 'move' },
    },

    alfred = {
        label   = 'Alfred',
        default = 0,
        auto_globals = { 'AlfredTheButlerPlugin', 'PLUGIN_alfred_the_butler' },
        choices = {
            {
                id     = 'auto',
                label  = 'Auto (use loaded Alfred)',
                global = 'AlfredTheButlerPlugin',
                alt_global = 'PLUGIN_alfred_the_butler',
            },
            {
                id     = 'steroid',
                label  = 'Steroid Alfred',
                global = 'AlfredTheButlerPlugin',
                alt_global = 'PLUGIN_alfred_the_butler',
                detect = function(plugin)
                    return plugin ~= nil and type(plugin.create_task) == 'function'
                end,
            },
            {
                id     = 'better_alfred',
                label  = 'Better Alfred',
                global = 'AlfredTheButlerPlugin',
                alt_global = 'PLUGIN_alfred_the_butler',
                detect = function(plugin)
                    if plugin == nil or type(plugin.create_task) == 'function' then
                        return false
                    end
                    if type(plugin.get_status) ~= 'function' then return false end
                    local ok, st = pcall(plugin.get_status)
                    return ok and type(st) == 'table' and st.name == 'alfred_the_butler'
                end,
            },
            {
                id     = 'alfred_butler',
                label  = 'Alfred The Butler',
                global = 'AlfredTheButlerPlugin',
                alt_global = 'PLUGIN_alfred_the_butler',
                detect = function(plugin)
                    return plugin ~= nil and type(plugin.create_task) ~= 'function'
                end,
            },
        },
        required_api = { 'get_status', 'trigger_tasks' },
    },
}

-- role_id -> settings field on core.settings (combo_box index, 0-based).
-- undercity and nav have NO menu entry on purpose: undercity has only one
-- bot (Wonder City) and navigation is auto-detected (Batmobile -> Frigate)
-- for WarPigs' own town walks. With no settings key, the resolver falls back
-- to each role's first choice (Auto) — do not add them back here without
-- also re-adding their gui elements.
M.settings_key = {
    pit       = 'plugin_pit',
    helltide  = 'plugin_helltide',
    horde     = 'plugin_horde',
    boss      = 'plugin_boss',
    alfred    = 'plugin_alfred',
}

-- Stable choice id per role (survives scan/filter changing combo indices).
M.settings_choice_id_key = {
    pit       = 'plugin_pit_choice',
    helltide  = 'plugin_helltide_choice',
    horde     = 'plugin_horde_choice',
    boss      = 'plugin_boss_choice',
    alfred    = 'plugin_alfred_choice',
}

-- Roles shown/validated in the Plugin Selection menu (in order).
M.menu_roles = {
    'pit', 'helltide', 'horde', 'boss', 'alfred',
}

-- Friendly name shown in the compact auto-detect status lines.
M.global_labels = {
    Pit2Plugin               = 'Pit 2.0',
    ArkhamAsylumPlugin       = 'Pit 2.0',
    HelltideRevampedPlugin   = 'HelltideRevamped',
    HelltideLitePlugin       = 'BetterHelltide',
    BetterHelltidePlugin     = 'BetterHelltide',
    WonderCityPlugin         = 'Wonder City',
    InfernalHordesPlugin     = 'Infernal Horde',
    ReaperPlugin             = 'Reaper 3.0.pack',
    BatmobilePlugin          = 'Batmobile / Chassis',
    FrigatePlugin            = 'Frigate',
    AlfredTheButlerPlugin    = 'Alfred',
    PLUGIN_alfred_the_butler = 'Alfred',
}

function M.global_label(global_name)
    if not global_name then return nil end
    return M.global_labels[global_name] or global_name
end

-- Ordered list of _G globals WarPigs will probe for a role's "Auto" pick.
-- Prefers the explicit auto_globals list, then falls back to all_globals /
-- all_apis so every role has a sensible candidate set.
function M.role_candidate_globals(role_id)
    local role = M.roles[role_id]
    if not role then return {} end
    if role.auto_globals then return role.auto_globals end
    if role.all_globals then return role.all_globals end
    if role.all_apis then return role.all_apis end
    return {}
end

function M.get_role(role_id)
    return M.roles[role_id]
end

function M.role_for_marker(marker)
    for role_id, m in pairs(M.ROLE_MARKERS) do
        if m == marker then return role_id end
    end
    return nil
end

function M.choice_labels(role_id)
    return M.choice_labels_live(role_id)
end

local function global_key(choice)
    return choice.api_global or choice.global or choice.id
end

local function is_global_loaded(name)
    if not name or name == '' then return false end
    return type(_G[name]) == 'table'
end

local function pack_path(path)
    return path and path:lower():match('%.pack$') ~= nil
end

local function choice_globals_loaded(choice)
    if choice.global and is_global_loaded(choice.global) then return true end
    if choice.alt_global and is_global_loaded(choice.alt_global) then return true end
    return false
end

local function choice_available(choice, installed_only, folder_map, scanned)
    if choice.id == 'auto' or choice.id == 'none' then return true end
    if choice.folder then
        if scanned then
            local catalog = require 'core.plugin_catalog'
            if catalog.installed_scan_hit(choice.folder, folder_map) then
                return true
            end
            if folder_map[choice.folder] ~= nil then
                return true
            end
            if installed_only then return false end
        end
        if not installed_only then return true end
        if choice_globals_loaded(choice) then return true end
        if choice.api_global and is_global_loaded(choice.api_global) then return true end
        if choice.alt_api and is_global_loaded(choice.alt_api) then return true end
        return false
    end
    if installed_only then
        if choice.api_global and is_global_loaded(choice.api_global) then return true end
        if choice.alt_api and is_global_loaded(choice.alt_api) then return true end
        if choice.global and is_global_loaded(choice.global) then return true end
        if choice.alt_global and is_global_loaded(choice.alt_global) then return true end
        return false
    end
    return true
end

function M.get_live_choices(role_id, installed_only)
    local role = M.roles[role_id]
    if not role then return {} end

    local scan_mod = require 'core.scripts_scan'
    local catalog  = require 'core.plugin_catalog'
    local scanned  = scan_mod.has_results()
    local folder_map = scan_mod.get_folders()

    local out, seen = {}, {}
    local function add(choice)
        local key = global_key(choice)
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = choice
    end

    for _, choice in ipairs(role.choices) do
        if choice_available(choice, installed_only, folder_map, scanned) then
            add(choice)
        end
    end

    if scanned then
        for _, choice in ipairs(catalog.discovered_choices_for_role(role_id, folder_map)) do
            if not installed_only or choice_available(choice, true, folder_map, true) then
                add(choice)
            end
        end
    end

    return out
end

function M.choice_labels_live(role_id, installed_only)
    if installed_only == nil then installed_only = true end
    local scan_mod = require 'core.scripts_scan'
    local folder_map = scan_mod.has_results() and scan_mod.get_folders() or {}
    local labels = {}
    for i, choice in ipairs(M.get_live_choices(role_id, installed_only)) do
        local label = choice.label
        if choice.folder and folder_map[choice.folder] then
            local path = folder_map[choice.folder]
            if pack_path(path) and not choice_globals_loaded(choice) then
                local pack_name = path:match('([^\\/]+)$') or 'pack'
                label = label .. ' [' .. pack_name .. ' — enable in QQT]'
            elseif choice.from_scan then
                label = label .. ' [' .. choice.folder .. ']'
            end
        elseif choice.from_scan and choice.folder then
            label = label .. ' [' .. choice.folder .. ']'
        end
        labels[i] = label
    end
    return labels
end

function M.choice_by_id_static(role_id, choice_id)
    if not choice_id or choice_id == '' then return nil end
    local role = M.roles[role_id]
    if not role then return nil end
    for _, choice in ipairs(role.choices) do
        if choice.id == choice_id then return choice end
    end
    return nil
end

function M.choice_at_static(role_id, index)
    local role = M.roles[role_id]
    if not role then return nil end
    return role.choices[(index or 0) + 1]
end

function M.choice_labels_static(role_id)
    local role = M.roles[role_id]
    if not role then return {} end
    local labels = {}
    for i, choice in ipairs(role.choices) do
        labels[i] = choice.label
    end
    return labels
end

function M.choice_index_for_id_static(role_id, choice_id)
    local role = M.roles[role_id]
    if not role or not choice_id or choice_id == '' then return nil end
    for i, choice in ipairs(role.choices) do
        if choice.id == choice_id then return i - 1 end
    end
    return nil
end

function M.choice_by_id(role_id, choice_id, installed_only)
    if not choice_id or choice_id == '' then return nil end
    for _, choice in ipairs(M.get_live_choices(role_id, installed_only)) do
        if choice.id == choice_id then return choice end
    end
    return nil
end

function M.choice_index_for_id(role_id, choice_id, installed_only)
    for i, choice in ipairs(M.get_live_choices(role_id, installed_only)) do
        if choice.id == choice_id then return i - 1 end
    end
    return nil
end

function M.choice_at(role_id, index, installed_only)
    local choices = M.get_live_choices(role_id, installed_only)
    return choices[(index or 0) + 1]
end

function M.scan_summary()
    local scan_mod = require 'core.scripts_scan'
    local catalog  = require 'core.plugin_catalog'
    if not scan_mod.has_results() then
        return {
            scanned      = false,
            folder_count = 0,
            pack_count   = 0,
            folders      = {},
            unmapped     = {},
            scripts_root = scan_mod.get_scripts_root(),
            last_scan_at = nil,
        }
    end
    local folder_map = scan_mod.get_folders()
    return {
        scanned      = true,
        folder_count = scan_mod.folder_count(),
        pack_count   = scan_mod.pack_count(),
        folders      = scan_mod.all_folders(),
        unmapped     = catalog.unmapped_folders(folder_map),
        scripts_root = scan_mod.get_scripts_root(),
        last_scan_at = scan_mod.last_scan_iso(),
    }
end

return M
