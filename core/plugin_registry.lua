-- Plugin roles WarPigs can assign per activity / support task.
-- Each role lists menu choices; resolver turns the user's pick into a _G global.

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
        all_globals  = { 'ArkhamAsylumPlugin' },
        auto_globals = { 'ArkhamAsylumPlugin' },
        choices = {
            {
                id     = 'auto',
                label  = 'Auto (Arkham Asylum)',
                global = 'ArkhamAsylumPlugin',
            },
            {
                id     = 'arkham',
                label  = 'Arkham Asylum',
                global = 'ArkhamAsylumPlugin',
                folder = 'ArkhamAsylum',
            },
        },
        required_api = { 'enable', 'disable' },
    },

    helltide = {
        label   = 'Helltide',
        marker  = '__helltide__',
        default = 0,
        priority    = 40,
        all_globals  = { 'HelltideRevampedPlugin', 'BetterHelltidePlugin' },
        auto_globals = { 'HelltideRevampedPlugin', 'BetterHelltidePlugin' },
        choices = {
            {
                id     = 'auto',
                label  = 'Auto (detect loaded)',
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
                global = 'BetterHelltidePlugin',
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
                label  = 'HordeDev',
                global = 'InfernalHordesPlugin',
                folder = 'HordeDev-1.3.9',
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
                id     = 'auto',
                label  = 'Auto (Reaper)',
                global = 'ReaperPlugin',
            },
            {
                id     = 'reaper',
                label  = 'Reaper',
                global = 'ReaperPlugin',
                folder = 'Reaper',
            },
        },
        required_api = { 'enable', 'disable' },
    },

    nav = {
        label       = 'Navigation',
        default     = 0,
        all_globals  = { 'NavCorePlugin', 'BatmobilePlugin', 'FrigatePlugin' },
        auto_globals = { 'NavCorePlugin', 'BatmobilePlugin', 'FrigatePlugin' },
        choices = {
            {
                id     = 'auto',
                label  = 'Auto (NavCore → Batmobile → Frigate)',
                global = nil,
            },
            {
                id     = 'navcore',
                label  = 'NavCore',
                global = 'NavCorePlugin',
                folder = 'NavCore',
            },
            {
                id     = 'batmobile',
                label  = 'Batmobile',
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

    combat = {
        label       = 'Combat rotation',
        default     = 0,
        all_apis     = { 'UNIVERSAL_ROTATION', 'BARBARIAN_ROTATION', 'WarlockScmurdPlugin', 'WARLOCK_ROTATION' },
        auto_globals = { 'UNIVERSAL_ROTATION', 'BARBARIAN_ROTATION', 'WarlockScmurdPlugin' },
        choices = {
            {
                id         = 'auto',
                label      = 'Auto (Universal Rotation)',
                api_global = 'UNIVERSAL_ROTATION',
            },
            {
                id         = 'ww_barb',
                label      = 'V1per WW Barb',
                api_global = 'BARBARIAN_ROTATION',
                folder     = 'rotation_barbarian',
            },
            {
                id         = 'universal',
                label      = 'Universal Rotation',
                api_global = 'UNIVERSAL_ROTATION',
                folder     = 'UniversalRotation',
            },
            {
                id         = 'none',
                label      = 'None (manual)',
                api_global = nil,
            },
        },
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
M.settings_key = {
    pit       = 'plugin_pit',
    helltide  = 'plugin_helltide',
    undercity = 'plugin_undercity',
    horde     = 'plugin_horde',
    boss      = 'plugin_boss',
    nav       = 'plugin_nav',
    combat    = 'plugin_combat',
    alfred    = 'plugin_alfred',
}

-- Roles validated in the Plugin Selection menu (in order).
M.menu_roles = {
    'pit', 'helltide', 'undercity', 'horde', 'boss', 'nav', 'alfred',
}

-- Friendly name shown in the compact auto-detect status lines.
M.global_labels = {
    ArkhamAsylumPlugin       = 'Arkham Asylum',
    HelltideRevampedPlugin   = 'HelltideRevamped',
    BetterHelltidePlugin     = 'BetterHelltide',
    WonderCityPlugin         = 'Wonder City',
    InfernalHordesPlugin     = 'Infernal Horde',
    ReaperPlugin             = 'Reaper',
    BatmobilePlugin          = 'Batmobile',
    FrigatePlugin            = 'Frigate',
    UNIVERSAL_ROTATION       = 'Universal Rotation',
    BARBARIAN_ROTATION       = 'V1per WW Barb',
    WarlockScmurdPlugin      = 'Scmurd Warlock',
    WARLOCK_ROTATION         = 'Scmurd Warlock',
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

local function choice_available(choice, installed_only, folder_map, scanned)
    if choice.id == 'auto' or choice.id == 'none' then return true end
    if choice.folder then
        if scanned then
            local catalog = require 'core.plugin_catalog'
            if catalog.installed_scan_hit(choice.folder, folder_map) then
                return true
            end
            return folder_map[choice.folder] ~= nil
        end
        if not installed_only then return true end
        if choice.api_global and is_global_loaded(choice.api_global) then return true end
        if choice.alt_api and is_global_loaded(choice.alt_api) then return true end
        if choice.global and is_global_loaded(choice.global) then return true end
        if choice.alt_global and is_global_loaded(choice.alt_global) then return true end
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
    local labels = {}
    for i, choice in ipairs(M.get_live_choices(role_id, installed_only)) do
        local label = choice.label
        if choice.from_scan and choice.folder then
            label = label .. ' [' .. choice.folder .. ']'
        end
        labels[i] = label
    end
    return labels
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
