-- SilentRaven coordination for WarPigs town handoffs only.
-- SR is paused briefly while Alfred runs in Temis during the via-Temis
-- preamble (or turn-in). Outside that window SR is left alone to auto-fire.

local M = {}

local EXTERNAL_CALLER = 'WarPigs'
local TEMIS_ZONE      = 'Skov_Temis'

local holds = {}

function M.get_plugin()
    return _G.SilentRavenPlugin
end

function M.hold(caller)
    holds[caller] = true
end

function M.release(caller)
    holds[caller] = nil
end

function M.is_held()
    for _ in pairs(holds) do return true end
    return false
end

function M.player_in_town()
    local lp = get_local_player()
    if lp and _G.attributes and _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA ~= nil then
        local ok, val = pcall(function()
            return lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1
        end)
        if ok then return val == true end
    end
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, zname = pcall(function() return w:get_current_zone_name() end)
    return ok2 and zname == TEMIS_ZONE
end

function M.is_paused_by_us()
    local sr = M.get_plugin()
    if not sr or type(sr.get_status) ~= 'function' then return false end
    local ok, s = pcall(sr.get_status)
    return ok and type(s) == 'table' and s.paused == true and s.paused_by == EXTERNAL_CALLER
end

function M.pause()
    if M.is_held() then return end
    if M.is_paused_by_us() then return end
    local sr = M.get_plugin()
    if sr and type(sr.pause) == 'function' then
        pcall(sr.pause, EXTERNAL_CALLER)
    end
end

function M.resume()
    local sr = M.get_plugin()
    if sr and type(sr.resume) == 'function' then
        pcall(sr.resume)
    end
end

function M.unpause_if_ours()
    local sr = M.get_plugin()
    if not sr or type(sr.get_status) ~= 'function' then return end
    local ok, s = pcall(sr.get_status)
    if ok and type(s) == 'table' and s.paused and s.paused_by == EXTERNAL_CALLER then
        M.resume()
    end
end

function M.is_running()
    local sr = M.get_plugin()
    if not sr or type(sr.get_status) ~= 'function' then return false end
    local ok, s = pcall(sr.get_status)
    return ok and type(s) == 'table' and s.running == true
end

function M.idle()
    if M.is_running() then return false end
    local sr = M.get_plugin()
    if not sr or type(sr.get_status) ~= 'function' then return true end
    local ok, s = pcall(sr.get_status)
    if not ok or type(s) ~= 'table' then return true end
    if not s.enabled then return true end
    if s.paused and s.paused_by == EXTERNAL_CALLER then return true end
    return true
end

function M.reset_session()
    holds = {}
    M.unpause_if_ours()
end

return M
