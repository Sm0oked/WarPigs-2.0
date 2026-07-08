-- Unified WarPigs orchestrator state — one snapshot per tick for HUD, menu, and debug files.

local stuck_watchdog = require 'core.stuck_watchdog'

local M = {}

M.PHASE = {
    OFF            = 'OFF',
    DEAD           = 'DEAD',
    IDLE           = 'IDLE',
    TRANSITION     = 'TRANSITION',
    MISSING_PLUGIN = 'MISSING_PLUGIN',
    BLOCKED        = 'BLOCKED',
    WRAPPING_UP    = 'WRAPPING_UP',
    RUNNING        = 'RUNNING',
    TASK           = 'TASK',
    PIT_FILLER     = 'PIT_FILLER',
}

local snapshot = {
    phase         = M.PHASE.IDLE,
    phase_detail  = '',
    updated_at    = 0,
    warpigs_on    = false,
    active_quests = {},
    owned_plugins = {},
    wanted_plugins = {},
    blocked       = {},
    missing       = {},
    pending_disable = {},
    transition    = { state = 'IDLE', pending = false },
    task          = nil,
    pit_filler    = false,
    gate_reason   = nil,
    combat_managed = false,
    stuck         = {},
}

local last_phase      = nil
local last_file_write = -math.huge
local FILE_INTERVAL   = 2.0

local function sorted_keys(t)
    local keys = {}
    if type(t) ~= 'table' then return keys end
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

local function copy_keys(t)
    return sorted_keys(t)
end

local function quest_label(pattern)
    return pattern:gsub('^WarPlans_QST_', '')
end

local function find_active_task(ctx)
    if not ctx.matches or not ctx.quest_plugin_map or not ctx.normalize then return nil end
    for pattern in pairs(ctx.matches) do
        local raw = ctx.quest_plugin_map[pattern]
        if raw then
            local entry = ctx.normalize(raw)
            if entry and entry.task then
                local state = '?'
                if type(entry.task.get_state) == 'function' then
                    local ok, s = pcall(entry.task.get_state)
                    if ok and s then state = tostring(s) end
                end
                return {
                    pattern = pattern,
                    label   = quest_label(pattern),
                    state   = state,
                }
            end
        end
    end
    return nil
end

local function collect_blocked(ctx)
    local blocked = {}
    for plugin, reason in pairs(ctx.enable_blocked or {}) do
        blocked[#blocked + 1] = { plugin = plugin, reason = reason }
    end
    table.sort(blocked, function(a, b) return a.plugin < b.plugin end)
    return blocked
end

local function collect_missing(ctx)
    local missing = {}
    for pattern, plugin in pairs(ctx.matched_blocked or {}) do
        missing[#missing + 1] = {
            pattern = pattern,
            label   = quest_label(pattern),
            plugin  = plugin,
        }
    end
    table.sort(missing, function(a, b) return a.pattern < b.pattern end)
    return missing
end

local function derive_phase(ctx, task, missing, blocked)
    if not ctx.warpigs_on then
        return M.PHASE.OFF, 'WarPigs disabled'
    end
    if ctx.player_dead then
        return M.PHASE.DEAD, 'reviving'
    end
    if task then
        return M.PHASE.TASK, task.label .. ' [' .. task.state .. ']'
    end
    if #missing > 0 then
        return M.PHASE.MISSING_PLUGIN,
            missing[1].label .. ' needs ' .. missing[1].plugin
    end
    local tt = ctx.transition_state or 'IDLE'
    if tt ~= 'IDLE' or ctx.teleport_pending then
        local detail = tt
        if ctx.teleport_pending and tt == 'IDLE' then
            detail = 'PENDING'
        end
        if ctx.gate_reason then
            detail = detail .. ' — ' .. ctx.gate_reason
        end
        return M.PHASE.TRANSITION, detail
    end
    local owned = copy_keys(ctx.owned)
    if #owned > 0 then
        return M.PHASE.RUNNING, table.concat(owned, ', ')
    end
    local pending = copy_keys(ctx.pending_disable)
    if #pending > 0 then
        return M.PHASE.WRAPPING_UP, 'finishing ' .. pending[1]
    end
    if #blocked > 0 then
        return M.PHASE.BLOCKED, blocked[1].plugin .. ': ' .. blocked[1].reason
    end
    if ctx.pit_filler then
        return M.PHASE.PIT_FILLER, 'run_pit_after_turnin'
    end
    local quests = copy_keys(ctx.matches)
    if #quests > 0 then
        return M.PHASE.IDLE, 'waiting — ' .. quest_label(quests[1])
    end
    return M.PHASE.IDLE, 'watching quests'
end

local function data_dir()
    local root = _G.__WARPIGS_PLUGIN_ROOT
    if not root or root == '' then return nil end
    return root:gsub('/', '\\') .. '\\data'
end

local function write_state_file()
    -- Public release: in-memory status only (no debug file on disk).
end

function M.publish(ctx)
    ctx = ctx or {}
    local task    = find_active_task(ctx)
    local missing = collect_missing(ctx)
    local blocked = collect_blocked(ctx)
    local phase, detail = derive_phase(ctx, task, missing, blocked)

    local active_quests = {}
    for _, pattern in ipairs(sorted_keys(ctx.matches)) do
        if pattern:find('WarPlans_QST', 1, true) then
            active_quests[#active_quests + 1] = quest_label(pattern)
        end
    end

    local matched_reason_copy = {}
    for plugin, pattern in pairs(ctx.matched_reason or {}) do
        matched_reason_copy[plugin] = pattern
    end

    snapshot.phase           = phase
    snapshot.phase_detail    = detail
    snapshot.updated_at      = ctx.now or 0
    snapshot.warpigs_on      = ctx.warpigs_on == true
    snapshot.active_quests   = active_quests
    snapshot.owned_plugins   = copy_keys(ctx.owned)
    snapshot.wanted_plugins  = copy_keys(ctx.wants)
    snapshot.blocked         = blocked
    snapshot.missing         = missing
    snapshot.pending_disable = copy_keys(ctx.pending_disable)
    snapshot.transition      = {
        state   = ctx.transition_state or 'IDLE',
        pending = ctx.teleport_pending == true,
    }
    snapshot.task            = task
    snapshot.pit_filler        = ctx.pit_filler == true
    snapshot.gate_reason     = ctx.gate_reason
    snapshot.matched_reason  = matched_reason_copy
    snapshot.combat_managed  = ctx.combat_managed == true
    snapshot.stuck           = stuck_watchdog.get_status()

    if phase ~= last_phase then
        last_phase = phase
        write_state_file()
        last_file_write = snapshot.updated_at
    elseif snapshot.updated_at - last_file_write >= FILE_INTERVAL then
        write_state_file()
        last_file_write = snapshot.updated_at
    end
end

function M.get_snapshot()
    return snapshot
end

function M.get_status_line()
    if snapshot.phase == M.PHASE.OFF then
        return 'WarPigs: off'
    end
    if snapshot.phase == M.PHASE.RUNNING then
        return 'WarPigs: running ' .. snapshot.phase_detail
    end
    if snapshot.phase == M.PHASE.TASK and snapshot.task then
        return 'WarPigs: task ' .. snapshot.task.label .. ' [' .. snapshot.task.state .. ']'
    end
    if snapshot.phase == M.PHASE.MISSING_PLUGIN then
        return 'WarPigs: MISSING PLUGIN — ' .. snapshot.phase_detail
    end
    if snapshot.phase == M.PHASE.TRANSITION then
        return 'WarPigs: transition ' .. snapshot.phase_detail
    end
    if snapshot.phase == M.PHASE.BLOCKED then
        return 'WarPigs: blocked — ' .. snapshot.phase_detail
    end
    if snapshot.phase == M.PHASE.WRAPPING_UP then
        return 'WarPigs: wrapping up — ' .. snapshot.phase_detail
    end
    if snapshot.phase == M.PHASE.PIT_FILLER then
        return 'WarPigs: pit filler'
    end
    if snapshot.phase == M.PHASE.DEAD then
        return 'WarPigs: dead — reviving'
    end
    if #snapshot.active_quests > 0 then
        return 'WarPigs: ' .. snapshot.phase_detail
    end
    return 'WarPigs: watching quests'
end

function M.publish_off(now)
    snapshot.phase            = M.PHASE.OFF
    snapshot.phase_detail     = 'WarPigs disabled'
    snapshot.updated_at       = now or 0
    snapshot.warpigs_on       = false
    snapshot.active_quests    = {}
    snapshot.owned_plugins    = {}
    snapshot.wanted_plugins   = {}
    snapshot.blocked          = {}
    snapshot.missing          = {}
    snapshot.pending_disable  = {}
    snapshot.transition       = { state = 'IDLE', pending = false }
    snapshot.task             = nil
    snapshot.pit_filler       = false
    snapshot.gate_reason      = nil
    snapshot.matched_reason   = {}
    snapshot.combat_managed   = false
    last_phase                = M.PHASE.OFF
    write_state_file()
    last_file_write           = snapshot.updated_at
end

function M.get_menu_lines()
    if not snapshot.warpigs_on then
        return {
            'Phase: OFF — WarPigs disabled',
            'Teleport / transition state is cleared while off.',
        }
    end
    local lines = {
        'Phase: ' .. snapshot.phase .. ' — ' .. snapshot.phase_detail,
    }
    if #snapshot.active_quests > 0 then
        lines[#lines + 1] = 'WarPlans: ' .. table.concat(snapshot.active_quests, ', ')
    end
    if #snapshot.owned_plugins > 0 then
        lines[#lines + 1] = 'Running: ' .. table.concat(snapshot.owned_plugins, ', ')
    end
    if snapshot.transition.state ~= 'IDLE' or snapshot.transition.pending then
        lines[#lines + 1] = string.format(
            'Teleport: %s%s',
            snapshot.transition.state,
            snapshot.transition.pending and ' (pending)' or '')
    end
    if snapshot.gate_reason then
        lines[#lines + 1] = 'Gate: ' .. snapshot.gate_reason
    end
    if #snapshot.missing > 0 then
        for _, m in ipairs(snapshot.missing) do
            lines[#lines + 1] = 'LOAD: ' .. m.plugin .. ' for ' .. m.label
        end
    end
    if #snapshot.blocked > 0 then
        lines[#lines + 1] = 'Blocked: ' .. snapshot.blocked[1].plugin
    end
    local dir = data_dir()
    if dir then
        lines[#lines + 1] = 'State file: ' .. dir .. '\\orchestrator_state.txt'
    end
    return lines
end

function M.reset()
    last_phase = nil
    last_file_write = -math.huge
    snapshot.phase          = M.PHASE.IDLE
    snapshot.phase_detail   = ''
    snapshot.active_quests  = {}
    snapshot.owned_plugins  = {}
    snapshot.wanted_plugins = {}
    snapshot.blocked        = {}
    snapshot.missing        = {}
    snapshot.pending_disable = {}
    snapshot.transition     = { state = 'IDLE', pending = false }
    snapshot.task           = nil
    snapshot.pit_filler     = false
    snapshot.gate_reason    = nil
    snapshot.matched_reason = {}
end

return M
