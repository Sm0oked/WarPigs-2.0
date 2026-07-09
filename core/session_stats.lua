-- WarPlans session stats — rounds completed + per-activity totals.
-- On-screen overlay: black panel, blue headers, white body text.

local settings = require 'core.settings'

local M = {}

local session = {
    session_start = nil,
    rounds        = 0,
    helltide      = 0,
    boss          = 0,
    horde         = 0,
    pit           = 0,
    undercity     = 0,
    other         = 0,
    last_activity = nil,
    last_round_at = nil,
}

local last_file_write = -math.huge
local FILE_INTERVAL   = 5.0

-- Blue accents on black; body text stays white for readability.
local COL = {
    accent     = function(a) return color.new(90, 175, 255, a or 255) end,
    accent_mid = function(a) return color.new(70, 155, 240, a or 220) end,
    text       = function(a) return color_white(a or 235) end,
    text_dim   = function(a) return color_gray_pale(a or 200) end,
    bg         = function(a) return color_black(a or 170) end,
    border     = function(a) return color.new(50, 130, 220, a or 140) end,
}

local function now()
    return get_time_since_inject()
end

local function ensure_session()
    if not session.session_start then
        session.session_start = now()
    end
end

local function classify_reason(reason)
    if not reason or type(reason) ~= 'string' then return nil end
    if reason:find('filler:', 1, true) then return nil end
    if reason:find('TurnIn', 1, true) then return nil end
    if reason:find('Helltide', 1, true) then return 'helltide' end
    if reason:find('BossLair', 1, true) then return 'boss' end
    if reason:find('InfernalHordes', 1, true) then return 'horde' end
    if reason:find('ThePit', 1, true) then return 'pit' end
    if reason:find('Undercity', 1, true) then return 'undercity' end
    if reason:find('WarPlans', 1, true) then return 'other' end
    return nil
end

local function fmt_duration(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return string.format('%02dh %02dm %02ds', h, m, s)
    end
    return string.format('%02dm %02ds', m, s)
end

local function data_dir()
    local root = _G.__WARPIGS_PLUGIN_ROOT
    if not root or root == '' then return nil end
    return root:gsub('/', '\\') .. '\\data'
end

local function write_file()
    local dir = data_dir()
    if not dir then return end
    local path = dir .. '\\session_stats.txt'
    local lines = {
        'WarPigs Session Stats',
        'Session: ' .. fmt_duration(now() - (session.session_start or now())),
        'War plan rounds: ' .. tostring(session.rounds),
        '',
        'Activities completed:',
        string.format('  Helltide: %d', session.helltide),
        string.format('  Boss:     %d', session.boss),
        string.format('  Hordes:   %d', session.horde),
        string.format('  Pit:      %d', session.pit),
        string.format('  Undercity:%d', session.undercity),
    }
    if session.other > 0 then
        lines[#lines + 1] = string.format('  Other:    %d', session.other)
    end
    local total = session.helltide + session.boss + session.horde
        + session.pit + session.undercity + session.other
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Total activities: ' .. tostring(total)
    if session.last_activity then
        local la = session.last_activity
        lines[#lines + 1] = string.format(
            'Last: %s (%s)', la.category or '?', la.reason or '?')
    end
    local f = io.open(path, 'w')
    if f then
        f:write(table.concat(lines, '\n') .. '\n')
        f:flush()
        f:close()
    end
end

local function maybe_write_file()
    local t = now()
    if t - last_file_write >= FILE_INTERVAL then
        last_file_write = t
        write_file()
    end
end

function M.on_activity_finished(reason, plugin_name)
    local cat = classify_reason(reason)
    if not cat then return end
    ensure_session()
    session[cat] = (session[cat] or 0) + 1
    session.last_activity = {
        category = cat,
        reason   = reason,
        plugin   = plugin_name,
        at       = now(),
    }
    maybe_write_file()
end

function M.on_round_complete()
    ensure_session()
    session.rounds = session.rounds + 1
    session.last_round_at = now()
    maybe_write_file()
end

function M.get_snapshot()
    ensure_session()
    local total = session.helltide + session.boss + session.horde
        + session.pit + session.undercity + session.other
    return {
        session_start = session.session_start,
        rounds        = session.rounds,
        helltide      = session.helltide,
        boss          = session.boss,
        horde         = session.horde,
        pit           = session.pit,
        undercity     = session.undercity,
        other         = session.other,
        total         = total,
        last_activity = session.last_activity,
        last_round_at = session.last_round_at,
    }
end

function M.reset()
    session.session_start = now()
    session.rounds        = 0
    session.helltide      = 0
    session.boss          = 0
    session.horde         = 0
    session.pit           = 0
    session.undercity     = 0
    session.other         = 0
    session.last_activity = nil
    session.last_round_at = nil
    last_file_write       = -math.huge
    write_file()
end

M.reset()

local function draw_line(x, y, text, col, size)
    graphics.text_2d(text, vec2:new(x, y), size or 13, col or COL.text())
    return y + (size or 13) + 2
end

-- gui_ref: main.lua passes the loaded gui module so slider values are read
-- directly each frame (same pattern as LayzTracker draw_offset_x/y).
function M.render(gui_ref)
    local layout
    if gui_ref and type(gui_ref.get_overlay_layout) == 'function' then
        layout = gui_ref.get_overlay_layout()
    end
    if not layout or not layout.enabled then return end
    if not get_local_player() then return end

    local s = M.get_snapshot()
    local pad = 10
    local font = layout.font_size or 17
    local title_font = font + 1
    local lines = {}

    local warpigs_on = settings.is_active()
    local status = warpigs_on and 'Active' or 'Idle'
    lines[#lines + 1] = {
        string.format('WarPigs %s | %s', settings.plugin_version or '?', status),
        COL.accent(), title_font,
    }
    lines[#lines + 1] = { '--- War Plans Session ---', COL.accent_mid(), font }

    local dur = now() - s.session_start
    lines[#lines + 1] = {
        string.format('Duration: %s', fmt_duration(dur)),
        COL.text(), font,
    }
    lines[#lines + 1] = {
        string.format('Rounds completed: %d', s.rounds),
        COL.text(), font,
    }

    lines[#lines + 1] = { '--- Activities ---', COL.accent_mid(), font }
    lines[#lines + 1] = {
        string.format('Helltide: %d', s.helltide),
        COL.text(), font,
    }
    lines[#lines + 1] = {
        string.format('Boss:     %d', s.boss),
        COL.text(), font,
    }
    lines[#lines + 1] = {
        string.format('Hordes:   %d', s.horde),
        COL.text(), font,
    }
    lines[#lines + 1] = {
        string.format('Undercity:%d', s.undercity),
        COL.text(), font,
    }
    lines[#lines + 1] = {
        string.format('Pit:      %d', s.pit),
        COL.text(), font,
    }
    lines[#lines + 1] = {
        string.format('Total: %d', s.total),
        COL.text(), font,
    }

    if s.last_activity then
        local la = s.last_activity
        local ago = fmt_duration(now() - (la.at or now()))
        lines[#lines + 1] = {
            string.format('Last: %s (%s ago)', la.category or '?', ago),
            COL.text_dim(), math.max(10, font - 1),
        }
    end

    local content_h = 0
    for _, row in ipairs(lines) do
        content_h = content_h + row[3] + 2
    end
    local panel_w = 280
    local panel_h = pad * 2 + content_h
    local outer_w = panel_w + pad * 2

    local bg_x = layout.pos_x or 2203
    local bg_y = layout.pos_y or 1094
    local text_x = bg_x + pad
    local text_y = bg_y + pad
    local bg_alpha = math.max(30, layout.bg_alpha or 38)
    local border_alpha = math.max(40, layout.border_alpha or 255)

    pcall(function()
        graphics.rect_filled(
            vec2:new(bg_x, bg_y),
            vec2:new(bg_x + outer_w, bg_y + panel_h),
            COL.bg(bg_alpha))
        graphics.rect(
            vec2:new(bg_x, bg_y),
            vec2:new(bg_x + outer_w, bg_y + panel_h),
            COL.border(border_alpha), 1, 1)
    end)

    local y = text_y
    for _, row in ipairs(lines) do
        y = draw_line(text_x, y, row[1], row[2], row[3])
    end
end

return M
