-- Maps scripts/ folder names to WarPigs plugin roles.
-- The scanner finds folders; this catalog says what each folder is for.
--
-- ★ NON-DEVS: Recipe 1 Step 4 (new folder) and Recipe 3 (pack filename not
--   detected) in HOW-TO-EDIT.md cover the two edits ever needed here.
--   Run check_syntax.bat after editing, before reloading in QQT.

local M = {}

-- folder_key (as reported by scripts_scan) -> role metadata
M.folders = {
    -- Pit role: Pit Racer (Arkham API drop-in). Globals ArkhamAsylumPlugin +
    -- Pit2Plugin (alias) — see plugin_resolver.normalize_plugin_global.
    ArkhamAsylum = {
        pit = {
            global     = 'ArkhamAsylumPlugin',
            alt_global = 'Pit2Plugin',
            label      = 'Pit Racer / Arkham Asylum',
            id         = 'arkham',
        },
    },
    HelltideRevamped = {
        helltide = { global = 'HelltideRevampedPlugin', label = 'HelltideRevamped' },
    },
    BetterHelltide = {
        helltide = {
            global     = 'HelltideLitePlugin',
            alt_global = 'BetterHelltidePlugin',
            label      = 'BetterHelltide',
        },
    },
    ['WonderCity-2.0'] = {
        undercity = { global = 'WonderCityPlugin', label = 'Wonder City' },
    },
    ['Infernal Horde'] = {
        horde = { global = 'InfernalHordesPlugin', label = 'Infernal Horde' },
    },
    Reaper = {
        boss = { global = 'ReaperPlugin', label = 'Reaper 3.0.pack' },
    },
    Batmobile = {
        nav = { global = 'BatmobilePlugin', label = 'Batmobile / Chassis' },
    },
    Chassis = {
        nav = { global = 'BatmobilePlugin', label = 'Chassis' },
    },
    Frigate = {
        nav = { global = 'FrigatePlugin', label = 'Frigate' },
    },
    BetterAlfred = {
        alfred = {
            global     = 'AlfredTheButlerPlugin',
            alt_global = 'PLUGIN_alfred_the_butler',
            label      = 'Better Alfred (folder)',
            id         = 'scan_better_alfred',
        },
    },
}

-- .pack basename (no extension) -> catalog folder_key used in M.folders
M.pack_aliases = {
    ['BetterHelltide']           = 'BetterHelltide',
    ['BetterHelltide (3)']       = 'BetterHelltide',
    ['Chassis']                  = 'Chassis',
    ['Reaper3.0']                = 'Reaper',
    ['Reaper3']                  = 'Reaper',
    ['Reaper 3.0']               = 'Reaper',
    ['SteroidAlfredV2-1.1.3']    = 'BetterAlfred',
    ['SteroidAlfredV2-1.1.2']    = 'BetterAlfred',
    ['SteroidAlfredV2-1.1.1']    = 'BetterAlfred',
    ['LooteerV3']                 = 'LooteerV3',
    ['HordeDev-1.3.9']           = 'Infernal Horde',
    ['PitRacerV1']               = 'ArkhamAsylum',
    ['PitRacer']                 = 'ArkhamAsylum',
}

-- Unpacked folder names on disk that map to a catalog folder_key.
-- Scan looks for the disk folder's main.lua, then stores it under the catalog key
-- so registry choices with folder = 'ArkhamAsylum' detect PitRacer installs.
M.disk_folder_aliases = {
    ['PitRacer']       = 'ArkhamAsylum',
    ['HordeDev-1.3.9'] = 'Infernal Horde',
}

function M.folder_key_for_pack_basename(basename)
    if not basename or basename == '' then return nil end
    basename = basename:gsub('%.pack$', '')
    if M.pack_aliases[basename] then
        return M.pack_aliases[basename]
    end
    if M.folders[basename] then
        return basename
    end
    if basename:match('^BetterHelltide') then return 'BetterHelltide' end
    if basename:match('^Chassis') then return 'Chassis' end
    if basename:match('^Arkham') or basename:match('^PitRacer') then
        return 'ArkhamAsylum'
    end
    -- Reaper3.0.pack / Reaper-v3.pack / Reaper_3.0.pack → boss role
    if basename:match('^[Rr]eaper') then return 'Reaper' end
    if basename:match('^SteroidAlfred') or basename:match('^SteroidUtils') then return 'BetterAlfred' end
    if basename:match('^Looteer') then return 'LooteerV3' end
    if basename:match('^HordeDev') then return 'Infernal Horde' end
    return basename
end

function M.pack_filenames_to_probe()
    local seen, out = {}, {}
    local function add(name)
        if name and name ~= '' and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    for folder_key in pairs(M.folders) do
        add(folder_key .. '.pack')
    end
    for pack_base in pairs(M.pack_aliases) do
        add(pack_base .. '.pack')
    end
    add('BetterHelltide.pack')
    add('BetterHelltide (3).pack')
    add('Reaper3.0.pack')
    add('Reaper3.pack')
    return out
end

function M.resolve_scan_key(rel_path)
    if not rel_path or rel_path == '' then return nil end
    rel_path = rel_path:gsub('\\', '/')
    local leaf = rel_path:match('([^/]+)$') or rel_path
    if rel_path:match('%.pack$') then
        local base = leaf:gsub('%.pack$', '')
        return M.folder_key_for_pack_basename(base)
    end
    if M.disk_folder_aliases and M.disk_folder_aliases[leaf] then
        return M.disk_folder_aliases[leaf]
    end
    if M.folders[leaf] then return leaf end
    if M.folders[rel_path] then return rel_path end
    return leaf
end

function M.all_folder_keys()
    local keys = {}
    for folder_key in pairs(M.folders) do
        keys[#keys + 1] = folder_key
    end
    table.sort(keys)
    return keys
end

function M.discovered_choices_for_role(role_id, folder_map)
    local choices = {}
    for folder_key, roles in pairs(M.folders) do
        local meta = roles[role_id]
        if meta and folder_map[folder_key] then
            local choice = {
                id           = meta.id or ('scan_' .. folder_key:gsub('[^%w]+', '_')),
                label        = meta.label or folder_key,
                folder       = folder_key,
                from_scan    = true,
                global       = meta.global,
                alt_global   = meta.alt_global,
                api_global   = meta.api_global,
                alt_api      = meta.alt_api,
            }
            choices[#choices + 1] = choice
        end
    end
    table.sort(choices, function(a, b) return a.label < b.label end)
    return choices
end

function M.unmapped_folders(folder_map)
    local mapped = {}
    for folder_key in pairs(M.folders) do
        if folder_map[folder_key] then mapped[folder_key] = true end
    end
    local unknown = {}
    for folder_key in pairs(folder_map) do
        if not mapped[folder_key] and folder_key ~= 'WarPigs' then
            unknown[#unknown + 1] = folder_key
        end
    end
    table.sort(unknown)
    return unknown
end

function M.installed_scan_hit(registry_folder, folder_map)
    if not registry_folder or registry_folder == '' then return false end
    if folder_map[registry_folder] then return true end
    if M.disk_folder_aliases and M.disk_folder_aliases[registry_folder] then
        return folder_map[M.disk_folder_aliases[registry_folder]] ~= nil
    end
    -- Reverse: registry uses catalog key (ArkhamAsylum) while scan may still
    -- briefly key a disk alias path (e.g. PitRacer).
    if M.disk_folder_aliases then
        for disk_name, catalog_key in pairs(M.disk_folder_aliases) do
            if catalog_key == registry_folder and folder_map[disk_name] then
                return true
            end
        end
    end
    for pack_base, catalog_key in pairs(M.pack_aliases) do
        if registry_folder == pack_base and folder_map[catalog_key] then
            return true
        end
    end
    return false
end

return M
