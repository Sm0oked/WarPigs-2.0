-- Discover plugin folders and .pack files in the scripts/ root.
-- Pack listing tries dir /b inside pcall on Scan entries, then io.open probes.

local M = {}

local cached_folders   = nil
local cached_packs     = nil
local cached_pack_files = nil
local last_scan_at     = nil

function M.get_scripts_root()
    if not package or not package.path then return nil end
    for entry in package.path:gmatch('[^;]+') do
        local dir = entry:gsub('%?%.lua$', ''):gsub('[\\/]$', '')
        local from_plugin = dir:match('^(.+)[\\/]WarPigs$')
        if from_plugin then
            return from_plugin:gsub('/', '\\')
        end
    end
    for entry in package.path:gmatch('[^;]+') do
        local cleaned = entry:gsub('%?%.lua$', ''):gsub('\\$', '')
        local cut = cleaned:find('scripts', 1, true)
        if cut then
            return cleaned:sub(1, cut + #'scripts' - 1):gsub('/', '\\')
        end
    end
    return nil
end

local function catalog_mod()
    local ok, catalog = pcall(require, 'core.plugin_catalog')
    if ok then return catalog end
    return nil
end

local function has_main_lua(folder_path)
    if not folder_path or folder_path == '' then return false end
    local sep = folder_path:sub(-1) == '\\' and '' or '\\'
    local f = io.open(folder_path .. sep .. 'main.lua', 'r')
    if f then f:close(); return true end
    return false
end

local function is_pack_path(path)
    return path and path:lower():match('%.pack\\?$') ~= nil
end

local function candidate_folder_keys()
    local keys, seen = {}, {}

    local function add(key)
        if key and key ~= '' and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end

    local catalog = catalog_mod()
    if catalog then
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

local function join_path(root, name)
    local sep = root:sub(-1) == '\\' and '' or '\\'
    return root .. sep .. name
end

local function try_dir_list_packs(root)
    local files, seen = {}, {}
    if not root or root == '' then return files end

    pcall(function()
        local normalized = root:gsub('/', '\\')
        local cmd = 'cmd /c dir /b "' .. normalized .. '\\*.pack" 2>nul'
        local h = io.popen(cmd, 'r')
        if not h then return end
        for line in h:lines() do
            if line and line ~= '' then
                local name = line:match('([^\\/]+)$') or line
                name = name:gsub('^%s+', ''):gsub('%s+$', '')
                if name ~= '' and name:lower():match('%.pack$') and not seen[name] then
                    seen[name] = true
                    files[#files + 1] = name
                end
            end
        end
        pcall(function() h:close() end)
    end)

    return files
end

local function list_pack_files(root, catalog)
    local files, seen = {}, {}
    if not root then return files end

    local function add_if_exists(pack_file)
        if not pack_file or pack_file == '' or seen[pack_file] then return end
        local full = join_path(root, pack_file)
        local f = io.open(full, 'r')
        if f then
            f:close()
            seen[pack_file] = true
            files[#files + 1] = pack_file
        end
    end

    for _, pack_file in ipairs(try_dir_list_packs(root)) do
        add_if_exists(pack_file)
    end

    if catalog and type(catalog.pack_filenames_to_probe) == 'function' then
        for _, pack_file in ipairs(catalog.pack_filenames_to_probe()) do
            add_if_exists(pack_file)
        end
    end

    return files
end

local function packs_on_disk(root)
    local map, packs, pack_files = {}, {}, {}
    local catalog = catalog_mod()
    if not root or not catalog then return map, packs, pack_files end

    local function note_pack(pack_file, full)
        pack_files[#pack_files + 1] = pack_file
        local key = catalog.resolve_scan_key(pack_file) or pack_file
        map[key] = full
        packs[key] = full
    end

    for _, pack_file in ipairs(list_pack_files(root, catalog)) do
        local full = join_path(root, pack_file)
        note_pack(pack_file, full)
    end

    if #pack_files == 0 and type(catalog.pack_filenames_to_probe) == 'function' then
        for _, pack_file in ipairs(catalog.pack_filenames_to_probe()) do
            local full = join_path(root, pack_file)
            local f = io.open(full, 'r')
            if f then
                f:close()
                note_pack(pack_file, full)
            end
        end
    end

    return map, packs, pack_files
end

local function folders_from_package_path(root)
    local map, packs = {}, {}
    if not package or not package.path or not root then return map, packs end

    local catalog = catalog_mod()

    for entry in package.path:gmatch('[^;]+') do
        local plugin_root = entry:match('^(.+)[/\\]%?%.lua$')
        if plugin_root and plugin_root:find(root, 1, true) == 1 then
            local rel = plugin_root:sub(#root + 2):gsub('\\', '/')
            if rel == '' then goto continue end

            local key = catalog and catalog.resolve_scan_key(rel) or rel
            if rel:match('%.pack$') or is_pack_path(plugin_root) then
                map[key] = plugin_root
                packs[key] = plugin_root
            elseif has_main_lua(plugin_root) then
                map[key] = plugin_root
            end
        end
        ::continue::
    end
    return map, packs
end

local function merge_maps(dst, src)
    for k, v in pairs(src or {}) do dst[k] = v end
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

function M.get_packs()
    return cached_packs or {}
end

function M.get_pack_files()
    return cached_pack_files or {}
end

function M.refresh()
    local root = M.get_scripts_root()
    local map  = {}
    local packs = {}

    if root then
        for _, rel in ipairs(candidate_folder_keys()) do
            local full = root .. '\\' .. rel:gsub('/', '\\')
            if has_main_lua(full) then
                map[rel] = full
            end
        end

        local disk_map, disk_packs, disk_pack_files = packs_on_disk(root)
        merge_maps(map, disk_map)
        merge_maps(packs, disk_packs)
        cached_pack_files = disk_pack_files or {}

        local catalog = catalog_mod()
        if catalog and catalog.disk_folder_aliases then
            for disk_name, catalog_key in pairs(catalog.disk_folder_aliases) do
                local full = root .. '\\' .. disk_name
                if has_main_lua(full) then
                    map[catalog_key] = full
                end
            end
        end

        local path_map, path_packs = folders_from_package_path(root)
        merge_maps(map, path_map)
        merge_maps(packs, path_packs)

        for _, full in pairs(path_packs) do
            local name = full:match('([^\\/]+)%.pack$')
            if name then
                name = name .. '.pack'
                local found = false
                for _, existing in ipairs(cached_pack_files) do
                    if existing == name then found = true; break end
                end
                if not found then
                    cached_pack_files[#cached_pack_files + 1] = name
                end
            end
        end
    else
        cached_pack_files = {}
    end

    cached_folders = map
    cached_packs   = packs
    if not cached_pack_files then
        cached_pack_files = {}
    end
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

function M.pack_count()
    return #(cached_pack_files or {})
end

function M.get_folder_path(folder_key)
    return M.get_folders()[folder_key]
end

return M
