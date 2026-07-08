-- Discover plugin folders without spawning CMD windows.
-- Scan runs ONLY when the user clicks Refresh in the Plugin Selection menu.

local M = {}

local cached_folders = nil
local last_scan_at     = nil

function M.get_scripts_root()
    if not package or not package.path then return nil end
    for entry in package.path:gmatch('[^;]+') do
        local cleaned = entry:gsub('%?%.lua$', ''):gsub('\\$', '')
        local cut = cleaned:find('scripts', 1, true)
        if cut then
            return cleaned:sub(1, cut + #'scripts' - 1):gsub('/', '\\')
        end
    end
    return nil
end

local function has_main_lua(folder_path)
    if not folder_path or folder_path == '' then return false end
    local sep = folder_path:sub(-1) == '\\' and '' or '\\'
    local f = io.open(folder_path .. sep .. 'main.lua', 'r')
    if f then f:close(); return true end
    return false
end

local function candidate_folder_keys()
    local keys, seen = {}, {}

    local function add(key)
        if key and key ~= '' and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end

    local ok_catalog, catalog = pcall(require, 'core.plugin_catalog')
    if ok_catalog then
        if type(catalog.all_folder_keys) == 'function' then
            for _, key in ipairs(catalog.all_folder_keys()) do
                add(key)
            end
        elseif catalog.folders then
            for folder_key in pairs(catalog.folders) do
                add(folder_key)
            end
        end
    end

    return keys
end

local function folders_from_package_path(root)
    local map = {}
    if not package or not package.path or not root then return map end

    for entry in package.path:gmatch('[^;]+') do
        local plugin_root = entry:match('^(.+)[/\\]%?%.lua$')
        if plugin_root and plugin_root:find(root, 1, true) == 1 then
            local rel = plugin_root:sub(#root + 2):gsub('\\', '/')
            if rel ~= '' and has_main_lua(plugin_root) then
                map[rel] = plugin_root
            end
        end
    end
    return map
end

function M.has_results()
    return cached_folders ~= nil
end

function M.last_scan_iso()
    return last_scan_at
end

function M.get_folders()
    return cached_folders or {}
end

function M.refresh()
    local root = M.get_scripts_root()
    local map  = {}

    if root then
        for _, rel in ipairs(candidate_folder_keys()) do
            local full = root .. '\\' .. rel:gsub('/', '\\')
            if has_main_lua(full) then
                map[rel] = full
            end
        end

        for rel, full in pairs(folders_from_package_path(root)) do
            map[rel] = full
        end
    end

    cached_folders = map
    last_scan_at = os.date('!%Y-%m-%dT%H:%M:%SZ')
    return map
end

function M.has_folder(folder_key)
    if not folder_key or folder_key == '' then return false end
    return M.get_folders()[folder_key] ~= nil
end

function M.all_folders()
    local keys = {}
    for k in pairs(M.get_folders()) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

function M.folder_count()
    return #M.all_folders()
end

function M.get_folder_path(folder_key)
    return M.get_folders()[folder_key]
end

return M
