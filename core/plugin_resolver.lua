local registry = require 'core.plugin_registry'

local resolver = {}

local settings_mod
local function get_settings()
    if not settings_mod then
        settings_mod = require 'core.settings'
    end
    return settings_mod
end

local function plugin_table(global_name)
    if not global_name or global_name == '' then return nil end
    return _G[global_name]
end

local function alfred_instance()
    local p = plugin_table('AlfredTheButlerPlugin')
    if p then return p end
    return plugin_table('PLUGIN_alfred_the_butler')
end

-- Ordered list of a role's candidate globals that are actually loaded right
-- now. Drives the "Auto (detect loaded)" behaviour for every role.
function resolver.loaded_globals(role_id)
    local out, seen = {}, {}
    for _, name in ipairs(registry.role_candidate_globals(role_id)) do
        if name and not seen[name] and resolver.is_loaded(name) then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    return out
end

-- First loaded candidate for a role (nil when none is loaded).
function resolver.auto_detect(role_id)
    return resolver.loaded_globals(role_id)[1]
end

function resolver.get_choice_index(role_id)
    local key = registry.settings_key[role_id]
    local settings = get_settings()
    if key and settings[key] ~= nil then return settings[key] end
    return 0
end

function resolver.get_choice(role_id)
    local settings = get_settings()
    local installed_only = settings.plugin_scan_installed_only ~= false
    return registry.choice_at(role_id, resolver.get_choice_index(role_id), installed_only)
end

function resolver.resolve_global(role_id)
    local choice = resolver.get_choice(role_id)
    if not choice then return nil end
    if choice.id == 'none' then return nil end

    -- Explicit (non-auto) pick: honour the chosen global, preferring an
    -- alternate global/api when only that variant is currently loaded.
    if choice.id ~= 'auto' then
        local primary = choice.api_global or choice.global
        local alt     = choice.alt_api or choice.alt_global
        if primary and plugin_table(primary) then return primary end
        if alt and plugin_table(alt) then return alt end
        return primary or alt
    end

    -- Auto: use the first candidate global that is actually loaded.
    local detected = resolver.auto_detect(role_id)
    if detected then return detected end

    -- Nothing loaded — return the first candidate so validation can name the
    -- exact plugin the user still needs to enable in QQT.
    local cands = registry.role_candidate_globals(role_id)
    return cands[1]
end

-- Compact status used by the menu: what Auto resolved to, and whether the
-- role currently has more than one loaded plugin (i.e. a real choice to make).
function resolver.status(role_id)
    local role     = registry.get_role(role_id)
    local choice   = resolver.get_choice(role_id)
    local loaded   = resolver.loaded_globals(role_id)
    local resolved = resolver.resolve_global(role_id)
    return {
        role_label      = role and role.label or role_id,
        choice_id       = choice and choice.id or 'auto',
        loaded          = loaded,
        loaded_count    = #loaded,
        resolved        = resolved,
        resolved_label  = registry.global_label(resolved),
        resolved_loaded = resolved ~= nil and resolver.is_loaded(resolved),
    }
end

function resolver.resolve_marker(marker)
    local role_id = registry.role_for_marker(marker)
    if role_id then return resolver.resolve_global(role_id) end
    return marker
end

function resolver.is_marker(plugin_field)
    return registry.role_for_marker(plugin_field) ~= nil
end

function resolver.get_plugin_instance(role_id)
    if role_id == 'alfred' then return alfred_instance() end
    if role_id == 'combat' then return plugin_table(resolver.resolve_global('combat')) end
    return plugin_table(resolver.resolve_global(role_id))
end

function resolver.is_loaded(global_name)
    if global_name == 'UNIVERSAL_ROTATION'
        or global_name == 'BARBARIAN_ROTATION'
        or global_name == 'WarlockScmurdPlugin'
        or global_name == 'WARLOCK_ROTATION'
    then
        return type(plugin_table(global_name)) == 'table'
    end
    return plugin_table(global_name) ~= nil
end

function resolver.plugin_is_role(plugin_name, role_id)
    local role = registry.get_role(role_id)
    if not role then return false end
    if role.all_globals then
        for _, name in ipairs(role.all_globals) do
            if plugin_name == name then return true end
        end
    end
    return resolver.resolve_global(role_id) == plugin_name
end

function resolver.plugin_priority(plugin_name)
    for role_id, role in pairs(registry.roles) do
        if role.priority then
            if role.all_globals then
                for _, g in ipairs(role.all_globals) do
                    if g == plugin_name then return role.priority end
                end
            end
            local resolved = resolver.resolve_global(role_id)
            if resolved == plugin_name then return role.priority end
        end
    end
    return 0
end

-- Backward-compatible helltide helpers.
function resolver.helltide_plugin_name()
    return resolver.resolve_global('helltide')
end

function resolver.helltide_plugin_is(plugin_name)
    return resolver.plugin_is_role(plugin_name, 'helltide')
end

function resolver.pit_plugin_name()
    return resolver.resolve_global('pit')
end

function resolver.horde_plugin_name()
    return resolver.resolve_global('horde')
end

function resolver.boss_plugin_name()
    return resolver.resolve_global('boss')
end

function resolver.nav_plugin_name()
    return resolver.resolve_global('nav')
end

function resolver.combat_api_name()
    return resolver.resolve_global('combat')
end

function resolver.has_required_api(role_id)
    if role_id == 'combat' then return true end
    local role = registry.get_role(role_id)
    if not role or not role.required_api then return true end
    local plugin = resolver.get_plugin_instance(role_id)
    if not plugin then return false end
    for _, fn in ipairs(role.required_api) do
        if type(plugin[fn]) ~= 'function' then return false end
    end
    return true
end

local function validate_standard_role(role_id)
    local role = registry.get_role(role_id)
    local choice = resolver.get_choice(role_id)
    if not role or not choice then return true end

    if role_id == 'nav' then
        if choice.id == 'auto' then
            if not resolver.is_loaded('BatmobilePlugin')
                and not resolver.is_loaded('FrigatePlugin')
            then
                return false, 'No navigation plugin loaded (need Batmobile or Frigate)'
            end
            return true
        end
        if not resolver.is_loaded(choice.global) then
            return false, choice.label .. ' not loaded'
        end
        return true
    end

    if choice.id == 'auto' then
        local global = resolver.resolve_global(role_id)
        if not resolver.is_loaded(global) then
            return false, 'No ' .. role.label:lower() .. ' plugin loaded (' .. global .. ')'
        end
        return true
    end

    if choice.global and not resolver.is_loaded(choice.global) then
        return false, choice.label .. ' not loaded'
    end

    if not resolver.has_required_api(role_id) then
        return false, choice.label .. ' is missing required APIs for WarPigs'
    end

    return true
end

function resolver.validate_role(role_id)
    local choice = resolver.get_choice(role_id)
    if not choice then return true end

    if role_id == 'helltide' then
        if choice.id ~= 'auto' then
            if choice.global and not resolver.is_loaded(choice.global) then
                return false, (registry.global_label(choice.global) or choice.label) .. ' not loaded'
            end
            return true
        end
        if not resolver.auto_detect('helltide') then
            return false, 'No helltide plugin loaded (enable HelltideRevamped or BetterHelltide)'
        end
        return true
    end

    if role_id == 'alfred' then
        local plugin = alfred_instance()
        if not plugin then
            return false, 'No Alfred plugin loaded (install Steroid Alfred, Better Alfred, or Alfred The Butler)'
        end
        if choice.id ~= 'auto' and type(choice.detect) == 'function' then
            if not choice.detect(plugin) then
                return false, 'Menu expects ' .. choice.label
                    .. ' but the loaded Alfred does not match (check which Alfred pack is enabled)'
            end
        end
        if not resolver.has_required_api('alfred') then
            return false, 'Loaded Alfred is missing required APIs (get_status / trigger_tasks)'
        end
        return true
    end

    if role_id == 'combat' then
        if choice.id == 'none' then return true end
        if choice.id == 'auto' then
            if not resolver.auto_detect('combat') then
                return false, 'No combat rotation loaded (enable Universal Rotation, WW Barb, or Warlock)'
            end
            return true
        end
        if choice.api_global and not resolver.is_loaded(choice.api_global)
            and not (choice.alt_api and resolver.is_loaded(choice.alt_api))
        then
            return false, choice.label .. ' not loaded'
        end
        return true
    end

    return validate_standard_role(role_id)
end

function resolver.validate_all()
    local warnings = {}
    for _, role_id in ipairs(registry.menu_roles) do
        local ok, msg = resolver.validate_role(role_id)
        if not ok and msg then warnings[#warnings + 1] = msg end
    end
    return warnings
end

-- Globals to force-disable during stuck recovery (activity plugins + Alfred).
function resolver.stuck_recovery_disable_list()
    local seen, list = {}, {}
    local function add(name)
        if name and not seen[name] then
            seen[name] = true
            list[#list + 1] = name
        end
    end
    add('AlfredTheButlerPlugin')
    add('SilentRavenPlugin')
    for _, role_id in ipairs({ 'pit', 'helltide', 'undercity', 'horde', 'boss' }) do
        local role = registry.get_role(role_id)
        if role and role.all_globals then
            for _, g in ipairs(role.all_globals) do add(g) end
        end
        add(resolver.resolve_global(role_id))
    end
    return list
end

function resolver.stuck_recovery_clear_target_list()
    return { 'NavCorePlugin', 'BatmobilePlugin', 'FrigatePlugin' }
end

return resolver
