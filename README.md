# WarPigs Orchestrator

**Version 2.0.3** — WarPlans quest orchestrator for Diablo IV (QQT scripts).

WarPigs watches your active WarPlans quests and automatically enables the right activity plugins (pit, helltide, undercity, hordes, boss lairs), handles town transitions (Alfred, SilentRaven, teleport). Each activity bot handles its own combat rotation.

---

## Major features



### 1. Modular plugin selection (per task)

Each WarPlans activity type maps to a **role**. WarPigs resolves that role to a concrete plugin global at runtime instead of baking in one author’s bot.


| Role                   | Typical plugins                                   | Global API                                                        |
| ---------------------- | ------------------------------------------------- | ----------------------------------------------------------------- |
| **Pit**                | Arkham Asylum                                     | `ArkhamAsylumPlugin`                                              |
| **Helltide**           | HelltideRevamped, BetterHelltide                  | `HelltideRevampedPlugin`, `HelltideLitePlugin` (BetterHelltide pack) |
| **Undercity**          | Wonder City                                       | `WonderCityPlugin`                                                |
| **Infernal Hordes**    | Infernal Horde                                    | `InfernalHordesPlugin`                                            |
| **Boss lairs**         | Reaper                                            | `ReaperPlugin`                                                    |
| **Navigation**         | Batmobile, Frigate                                | `BatmobilePlugin`, `FrigatePlugin`                                |
| **Alfred**             | Better Alfred, Steroid Alfred, Alfred The Butler  | `AlfredTheButlerPlugin` / `PLUGIN_alfred_the_butler`              |


Quest entries in `core/orchestrator.lua` use **role markers** (e.g. `__helltide__`, `__pit__`) instead of fixed plugin names. The resolver turns those markers into whatever plugin you (or Auto) selected.

**Example:** Switching helltide bots is a dropdown under **Plugin Selection → Helltide** when both HelltideRevamped and BetterHelltide are installed. Pick **BetterHelltide** explicitly to use the pack (`HelltideLitePlugin`); Auto prefers BetterHelltide when that global is loaded.

### 2. Auto-detect (default)

In **Auto mode** (default), WarPigs scans which plugin globals are actually loaded in QQT and uses the first match for each role.

- **One plugin loaded** → used automatically; menu shows a simple status line, e.g. `Helltide: HelltideRevamped`.
- **Two or more loaded** → a dropdown appears so you can choose.
- **None loaded** → setup warning when that activity is needed.

### 3. Manual plugin selection (optional)

Enable **Manual plugin selection** under **Plugin Selection** to show every task dropdown at once, regardless of how many plugins are loaded.

### 4. Combat rotation (not managed by WarPigs)

WarPigs does **not** enable or disable Universal Rotation, WW Barb, or other class rotations. Enable your rotation in QQT and let each activity plugin (HelltideRevamped, Arkham Asylum, Reaper, etc.) coordinate combat internally.

### 5. Session stats overlay

Optional on-screen panel (position, opacity, font size). Works **independently** of the main Enable toggle.

---



## Menu guide (v2.0.3)

Open: **Z | War Pigs | Orchestrator**

### Core

- **Enable** — Master switch for WarPlans orchestration.
- **Use keybind** — Optional hotkey gate on top of Enable.



### Plugin Selection

- **Scan entries** — Manually scan `scripts/` for plugin folders and `.pack` files (see [Plugin scan & .pack files](#plugin-scan--pack-files) below). Scan is wrapped in `pcall` so a failed scan will not crash the game.
- **Only show installed plugins** — After a scan, filter which choices count as “installed” for status lines and auto-detect hints. Dropdown option lists stay **fixed** (never shrink) to avoid QQT combo crashes.
- Auto status lines per task, or dropdowns when ambiguous / manual mode is on.
- **Manual plugin selection** — Show all task dropdowns.
- **Setup** warnings if a required plugin is not loaded.



### Activity & behavior

- **Use teleport** — `warplan.teleport_to_activity()` between activities.
- **Use SilentRaven** — Crow turn-in after Alfred (requires SilentRaven).
- **Run pit after turn-in** — Pit filler when no WarPlans quest is active.
- **Skip boss chest** — Disable boss plugin when chest spawns.
- **Manage orbwalker** — Force orbwalker clear ON before each managed plugin.
- **Stuck recovery** — Teleport to Temis and reset if movement stalls for several minutes.



### Session stats

- **Session stats overlay** — Toggle HUD.
- **Overlay appearance** — Position, opacity, font size.
- **Reset session stats** — Clear counters and timer.

---

## Architecture

```
main.lua
  └── gui.lua                    Menu & user settings
  └── core/settings.lua          Settings mirror (no circular require with gui)
  └── core/orchestrator.lua      WarPlans quest → plugin handoff logic
        ├── core/plugin_registry.lua   Roles, choices, auto_globals lists
        ├── core/plugin_resolver.lua   Auto-detect + resolve markers → _G globals
        ├── core/plugin_catalog.lua    Folder / .pack name → role mapping for scanner
        ├── core/scripts_scan.lua      Discover plugin folders and .pack files under scripts/
        ├── core/navigation.lua        Batmobile / Frigate walks
        ├── core/state_tracker.lua     In-memory status (on-screen status line)
        ├── core/session_stats.lua     Overlay counters & persistence
        └── core/orchestrator/         Alfred, Raven, transitions submodules
```



### Key files for contributors


| File                       | Role                                                        |
| -------------------------- | ----------------------------------------------------------- |
| `core/plugin_registry.lua` | Define roles, choices, and `auto_globals` probe order       |
| `core/plugin_resolver.lua` | Turn menu choice / Auto into `_G` plugin name               |
| `core/plugin_catalog.lua`  | Map `scripts/` folder names and `.pack` basenames to roles |
| `core/scripts_scan.lua`    | Discover folders (`main.lua`) and `.pack` files in `scripts/` |
| `core/orchestrator.lua`    | `quest_plugin_map` — WarPlans quest patterns → role markers |




### Adding support for a new plugin

1. Add the folder → role mapping in `core/plugin_catalog.lua`.
2. Add a choice (and `auto_globals` entry if needed) in `core/plugin_registry.lua`.
3. Ensure the plugin exposes a global (`SomePlugin` or `SOME_ROTATION`) with at least `enable` / `disable` for activity bots.

WarPlans quest keys still go in `orchestrator.quest_plugin_map`; use `registry.ROLE_MARKERS.<role>` for the `plugin` field instead of a hard-coded global.

---

## Plugin scan & .pack files

Many closed-source QQT plugins ship as **`.pack` files** placed directly in the `scripts/` root (not inside subfolders). Examples:

```
c:\diablo_qqt\scripts\BetterHelltide-v1.7.9.pack
c:\diablo_qqt\scripts\LooteerV3-1.6.1.pack
c:\diablo_qqt\scripts\SteroidUtils-V-1.0.1.pack
```

WarPigs must discover these so **Only show installed plugins** and manual dropdowns treat pack-only bots (e.g. BetterHelltide) as installed even when there is no unpacked folder with `main.lua`.

### How to scan

1. Open **Z | War Pigs → Plugin Selection**.
2. Click **Scan entries** (runs once per click; no background scanning).
3. Check the summary line and console output, e.g.  
   `[WarPigs] Plugin scan complete — 12 folder(s), 3 .pack(s) in c:\diablo_qqt\scripts`
4. The menu also shows **Scripts folder:** so you can confirm the correct root is used.

On Windows, listing `.pack` files uses a one-shot `dir /b *.pack` via `io.popen` **inside `pcall`** when you click **Scan entries**. If directory listing fails, the scanner falls back to probing known pack filenames with `io.open`. This may cause a brief CMD flash on success (same pattern as Universal Rotation profile discovery).

### What the scanner checks

| Source | What it finds |
| ------ | ------------- |
| **Catalog folders** | Subfolders under `scripts/` that contain `main.lua` (e.g. `HelltideRevamped\main.lua`) |
| **`.pack` on disk** | Every `*.pack` file in the `scripts/` root (versioned names included) |
| **`package.path`** | Plugins already loaded in QQT — including paths ending in `.pack` |
| **Disk aliases** | Alternate folder names (e.g. `HordeDev-1.3.9` → Infernal Horde catalog key) |

### `.pack` filename → plugin mapping

Pack files often include version suffixes. `core/plugin_catalog.lua` maps basenames to catalog keys:

| Pack basename pattern | Catalog key | Typical role |
| --------------------- | ----------- | ------------ |
| `BetterHelltide*` | `BetterHelltide` | Helltide |
| `Looteer*` | `LooteerV3` | (unmapped helper; shown in scan summary) |
| `SteroidAlfred*` / `SteroidUtils*` | `BetterAlfred` | Alfred |
| `HordeDev*` | `Infernal Horde` | Infernal Hordes |
| Exact names in `pack_aliases` | See `plugin_catalog.lua` | Various |

Exact legacy names (e.g. `BetterHelltide.pack`, `SteroidAlfredV2-1.1.3.pack`) are still probed as a fallback if directory listing is unavailable.

### Files changed for .pack support

| File | Change |
| ---- | ------ |
| `core/scripts_scan.lua` | List all `*.pack` in `scripts/` root; track pack file count; improve `get_scripts_root()` via WarPigs `package.path` entry; merge loaded `.pack` paths from `package.path` |
| `core/plugin_catalog.lua` | Add `pack_aliases`, `disk_folder_aliases`, `pack_filenames_to_probe()`, `resolve_scan_key()`, `installed_scan_hit()` for versioned pack names |
| `core/plugin_registry.lua` | `BetterHelltide` choice uses `HelltideLitePlugin`; static choice helpers; stable choice IDs per role |
| `gui.lua` | Restore **Scan entries** and **Only show installed plugins**; static combo labels (crash-safe); clamp combo indices; sync selection after render; show scan summary with folder count, pack count, and scripts path; remove auto-scan on menu open |
| `core/settings.lua` | Persist `plugin_scan_installed_only` and per-role `plugin_*_choice` stable IDs from GUI |

### Bug that was fixed

**Symptom:** Scan reported folders correctly (e.g. 12) but **0 .pack** files.

**Root cause:** Early scanner only probed a **fixed list** of exact filenames (`BetterHelltide.pack`, `SteroidAlfredV2-1.1.3.pack`, etc.). Real installs use **versioned names** in the scripts root (`BetterHelltide-v1.7.9.pack`), so `io.open` never found them.

**Fix:** Enumerate every `*.pack` in the scripts root, then map each basename to a catalog key with prefix rules (`^BetterHelltide`, `^Looteer`, etc.).

### Adding a new `.pack` plugin

1. Add or extend a catalog entry in `core/plugin_catalog.lua` (`M.folders` for the role).
2. Add a prefix rule in `folder_key_for_pack_basename()` if the pack uses a versioned name (e.g. `^MyPlugin` → `MyPlugin`).
3. Optionally add an exact entry to `M.pack_aliases` for legacy filenames.
4. Add a registry choice in `core/plugin_registry.lua` with the matching `folder` key.
5. Click **Scan entries** in-game to refresh the list.

---



## Supported plugin folders (auto-discovery)

These folder names under `scripts/` are recognized when you click **Scan entries**:

- `ArkhamAsylum`, `HelltideRevamped`, `BetterHelltide`, `WonderCity-2.0`
- `Infernal Horde`, `Reaper`
- `Batmobile`, `Frigate`, `Chassis` (nav via `BatmobilePlugin`)
- `BetterAlfred`

**Pack-only plugins** (no unpacked folder) are detected when a matching `*.pack` file sits in the `scripts/` root — see [Plugin scan & .pack files](#plugin-scan--pack-files).

Other folders with `main.lua` may appear if registered in the catalog.

---



## Requirements

- **QQT** with Lua script injection
- **WarPlans** quests active on the character
- Per-activity plugins installed and **enabled in QQT Scripts** for the content you run
- **BetterHelltide:** enable `BetterHelltide-*.pack` in QQT Scripts; for explicit pack use, disable the open-source `HelltideRevamped` folder if both are present
- Recommended support plugins:
  - **Alfred** (any supported variant) for stash/salvage between activities
  - **Chassis.pack** (or Batmobile / Frigate) for navigation — exposes `BatmobilePlugin`
  - **Universal Rotation** or a class rotation — enable yourself in QQT; activity bots use it as configured
  - **SilentRaven** (optional) for Tree of Whispers turn-ins

---

## External API

Other scripts can query WarPigs via the global:

```lua
WarPigsPlugin.enable()
WarPigsPlugin.disable()
local st = WarPigsPlugin.status()
-- st.enabled, st.phase, st.detail, st.version
```

---



## Changelog

### 2.0.3 (dropdown selection fix)

- Fix Helltide (and other role) dropdowns snapping back to **Auto** after picking a plugin — selection is read **after** render, not forced from saved state every frame
- One-time restore of saved choice ID per session (e.g. `better_helltide`) on reload; bounds clamping still runs every frame for crash safety

### 2.0.2 (combo crash fix)

- Fix game crash when opening Plugin Selection, scanning, or changing dropdowns after a scan
- **Root cause:** QQT `combo_box` crashes when the option list shrinks while a persisted index points past the end
- Dropdowns now use a **static label list** that never shrinks after scan or “installed only” filtering
- Combo indices are **clamped** before render; stable **choice IDs** (`plugin_helltide_choice`, etc.) survive scan/filter without breaking resolution
- Plugin scan wrapped in `pcall`; `dir /b` for packs also inside `pcall` with `io.open` probe fallback
- Resolver uses `choice_by_id_static` — no silent fallback to HelltideRevamped when BetterHelltide is explicitly selected
- BetterHelltide pack API: primary global is **`HelltideLitePlugin`** (`enable` / `disable` / `status`)
- Infernal Hordes catalog folder key fixed to **`Infernal Horde`** (was `HordeDev-1.3.9`)
- Auto-detect order: `HelltideLitePlugin` before `HelltideRevampedPlugin`
- Removed registry sync from `settings.update_settings()` every tick (lighter, avoids edge-case require churn)

### 2.0.1 (pack scan fix)

- **Scan entries** button restored in Plugin Selection (manual scan only; no auto-scan on menu open)
- **Only show installed plugins** toggle restored
- Fix `.pack` detection: enumerate all `*.pack` files in `scripts/` root instead of probing exact legacy filenames
- Versioned pack names supported (`BetterHelltide-v1.7.9.pack`, `LooteerV3-1.6.1.pack`, etc.) via prefix mapping in `plugin_catalog.lua`
- Scan summary and console log show pack count and scripts folder path
- `BetterHelltide` registry choice linked to `folder = 'BetterHelltide'` for post-scan availability
- Removed **Manage combat rotation** — activity plugins handle their own attacks; WarPigs no longer toggles WW Barb / Universal Rotation
- Removed combat rotation from Plugin Selection menu

### 2.0.0

- Simplified menu for end users
- Removed all dev/debug menu options and quest capture tooling
- Session overlay independent of Enable toggle
- Version bump; no debug files written during normal operation

- Plugin registry, resolver, catalog, and scripts scanner
- Per-task plugin dropdowns with Auto mode
- Generic auto-detect for all roles (replaced hard-coded helltide/combat paths)
- HelltideRevamped support alongside BetterHelltide
- Combat module for rotation handoff
- Session stats HUD and orchestrator submodules (Alfred, Raven, transitions)



### 1.4.0 (legacy)

- Hard-coded plugin globals in `quest_plugin_map`
- No per-task plugin choice
- Backup preserved at `WarPigs_backup_v1.4.0/`

---

## License / credits

WarPigs orchestrates third-party activity plugins; each activity bot retains its own author and license. Install only plugins you are allowed to use.