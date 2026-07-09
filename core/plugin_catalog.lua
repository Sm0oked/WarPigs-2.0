-- Maps scripts/ folder names to WarPigs plugin roles.
-- The scanner finds folders; this catalog says what each folder is for.

local M = {}

-- folder_key (as reported by scripts_scan) -> role metadata
M.folders = {
    ArkhamAsylum = {
        pit = { global = 'ArkhamAsylumPlugin', label = 'Arkham Asylum' },
    },
    HelltideRevamped = {
        helltide = { global = 'HelltideRevampedPlugin', label = 'HelltideRevamped' },
    },
    BetterHelltide = {
        helltide = { global = 'BetterHelltidePlugin', label = 'BetterHelltide' },
    },
    ['WonderCity-2.0'] = {
        undercity = { global = 'WonderCityPlugin', label = 'Wonder City' },
    },
    ['Infernal Horde'] = {
        horde = { global = 'InfernalHordesPlugin', label = 'Infernal Horde' },
    },
    Reaper = {
        boss = { global = 'ReaperPlugin', label = 'Reaper' },
    },
    Batmobile = {
        nav = { global = 'BatmobilePlugin', label = 'Batmobile' },
    },
    Frigate = {
        nav = { global = 'FrigatePlugin', label = 'Frigate' },
    },
    rotation_barbarian = {
        combat = { api_global = 'BARBARIAN_ROTATION', label = 'V1per WW Barb' },
    },
    UniversalRotation = {
        combat = { api_global = 'UNIVERSAL_ROTATION', label = 'Universal Rotation' },
    },
    BetterAlfred = {
        alfred = {
            global     = 'AlfredTheButlerPlugin',
            alt_global = 'PLUGIN_alfred_the_butler',
            label      = 'Better Alfred (folder)',
            id         = 'scan_better_alfred',
        },
    },
    ['Scmurd-Warlock'] = {
        combat = {
            api_global = 'WarlockScmurdPlugin',
            alt_api    = 'WARLOCK_ROTATION',
            label      = 'Scmurd Warlock',
            id         = 'scan_warlock',
        },
    },
}

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

return M
