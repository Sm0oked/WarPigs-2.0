-- Combat rotation coordination while WarPigs is driving WarPlans quests.
-- Default: UNIVERSAL_ROTATION for all activity handoffs.

local resolver = require 'core.plugin_resolver'
local registry = require 'core.plugin_registry'

local M = {}

local COMBAT_CLASS_APIS = {
    BARBARIAN_ROTATION = true,
    WarlockScmurdPlugin = true,
    WARLOCK_ROTATION = true,
}

local last_applied_target = nil
local last_applied_choice = nil

local function log(msg)
    console.print('[WarPigs:combat] ' .. msg)
end

local function api_table(name)
    if not name or name == '' then return nil end
    return _G[name]
end

local function rotation_enabled(api)
    if not api then return false end
    if type(api.is_enabled) == 'function' then
        local ok, on = pcall(api.is_enabled)
        return ok and on == true
    end
    if type(api.get_enabled) == 'function' then
        local ok, on = pcall(api.get_enabled)
        return ok and on == true
    end
    return false
end

local function rotation_set(api, state)
    if not api then return end
    if type(api.set_enabled) == 'function' then
        pcall(api.set_enabled, state and true or false)
        return
    end
    if state then
        if type(api.enable) == 'function' then pcall(api.enable) end
    elseif type(api.disable) == 'function' then
        pcall(api.disable)
    end
end

local function all_combat_api_names()
    local names, seen = {}, {}
    local function add(name)
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    add('UNIVERSAL_ROTATION')
    add('BARBARIAN_ROTATION')
    add('WarlockScmurdPlugin')
    add('WARLOCK_ROTATION')
    local role = registry.get_role('combat')
    if role then
        for _, choice in ipairs(registry.get_live_choices('combat', false)) do
            add(choice.api_global)
            add(choice.alt_api)
        end
    end
    return names
end

local function disable_class_rotations()
    for name, _ in pairs(COMBAT_CLASS_APIS) do
        local api = api_table(name)
        if api and rotation_enabled(api) then
            rotation_set(api, false)
        end
    end
end

function M.resolve_api_global()
    local choice = resolver.get_choice('combat')
    if choice and choice.id == 'none' then return nil end
    if choice and choice.id == 'ww_barb' then return 'BARBARIAN_ROTATION' end
    return 'UNIVERSAL_ROTATION'
end

function M.resolve_choice_id()
    local choice = resolver.get_choice('combat')
    return choice and choice.id or nil
end

local function apply_target(target_api, choice_id)
    if target_api == last_applied_target and choice_id == last_applied_choice then
        return
    end

    if choice_id == 'none' then
        for _, name in ipairs(all_combat_api_names()) do
            rotation_set(api_table(name), false)
        end
        log('combat rotation set to manual (all managed rotations disabled)')
        last_applied_target = nil
        last_applied_choice = choice_id
        return
    end

    if not target_api then
        log('no combat rotation resolved for menu choice — leaving rotations untouched')
        last_applied_target = nil
        last_applied_choice = choice_id
        return
    end

    local target = api_table(target_api)
    if not target then
        log(target_api .. ' not loaded — cannot apply combat choice')
        last_applied_target = nil
        last_applied_choice = choice_id
        return
    end

    if target_api == 'UNIVERSAL_ROTATION' then
        disable_class_rotations()
        rotation_set(target, true)
        log('enabled Universal Rotation (UNIVERSAL_ROTATION)')
    else
        rotation_set(target, true)
        log('enabled ' .. target_api)
    end

    last_applied_target = target_api
    last_applied_choice = choice_id
end

-- Enforce the menu combat pick while WarPigs is actively questing.
function M.tick(manage_enabled, questing, opts)
    opts = opts or {}
    if opts.pause_for_helltide_search then
        local target = last_applied_target
        if target and rotation_enabled(api_table(target)) then
            rotation_set(api_table(target), false)
        end
        return
    end

    if not manage_enabled or not questing then
        last_applied_target = nil
        last_applied_choice = nil
        return
    end

    local choice_id = M.resolve_choice_id()
    local target    = M.resolve_api_global()

    if choice_id == last_applied_choice and target == last_applied_target then
        if choice_id == 'none' then return end
        if target and rotation_enabled(api_table(target)) then return end
    end

    apply_target(target, choice_id)
end

function M.reset()
    last_applied_target = nil
    last_applied_choice = nil
end

return M
