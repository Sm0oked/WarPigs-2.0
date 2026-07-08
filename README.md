# WarPigs Orchestrator

**Version 2.0.0** — WarPlans quest orchestrator for Diablo IV (QQT scripts).

WarPigs watches your active WarPlans quests and automatically enables the right activity plugins (pit, helltide, undercity, nightmare dungeons, hordes, boss lairs), handles town transitions (Alfred, SilentRaven, teleport), and keeps your combat rotation running while questing.

---

## Major features



### 1. Modular plugin selection (per task)

Each WarPlans activity type maps to a **role**. WarPigs resolves that role to a concrete plugin global at runtime instead of baking in one author’s bot.


| Role                   | Typical plugins                                   | Global API                                                        |
| ---------------------- | ------------------------------------------------- | ----------------------------------------------------------------- |
| **Pit**                | Arkham Asylum                                     | `ArkhamAsylumPlugin`                                              |
| **Helltide**           | HelltideRevamped, BetterHelltide                  | `HelltideRevampedPlugin`, `BetterHelltidePlugin`                  |
| **Undercity**          | Wonder City                                       | `WonderCityPlugin`                                                |
| **Nightmare dungeons** | NightmareCity                                     | `NightmareCityPlugin`                                             |
| **Infernal Hordes**    | Infernal Horde                                    | `InfernalHordesPlugin`                                            |
| **Boss lairs**         | Reaper                                            | `ReaperPlugin`                                                    |
| **Navigation**         | Batmobile, Frigate                                | `BatmobilePlugin`, `FrigatePlugin`                                |
| **Combat rotation**    | Universal Rotation, V1per WW Barb, Scmurd Warlock | `UNIVERSAL_ROTATION`, `BARBARIAN_ROTATION`, `WarlockScmurdPlugin` |
| **Alfred**             | Better Alfred, Steroid Alfred, Alfred The Butler  | `AlfredTheButlerPlugin` / `PLUGIN_alfred_the_butler`              |


Quest entries in `core/orchestrator.lua` use **role markers** (e.g. `__helltide__`, `__pit__`) instead of fixed plugin names. The resolver turns those markers into whatever plugin you (or Auto) selected.

**Example:** Switching from V1per WW Barb to Universal Rotation is a dropdown under **Plugin Selection → Combat rotation** when both rotations are loaded. With only one loaded, Auto picks it with no dropdown.

### 2. Auto-detect (default)

In **Auto mode** (default), WarPigs scans which plugin globals are actually loaded in QQT and uses the first match for each role.

- **One plugin loaded** → used automatically; menu shows a simple status line, e.g. `Helltide: HelltideRevamped`.
- **Two or more loaded** → a dropdown appears so you can choose (e.g. WW Barb vs Universal).
- **None loaded** → setup warning when that activity is needed.

This fixed a critical bug from early modular builds where Helltide was hard-forced to `BetterHelltidePlugin` even when only `HelltideRevamped` was installed.

### 3. Manual plugin selection (optional)

Enable **Manual plugin selection** under **Plugin Selection** to show every task dropdown at once, regardless of how many plugins are loaded.

### 4. Combat rotation management

When **Manage combat rotation** is on, WarPigs enables your chosen rotation while a WarPlans quest (or pit filler / transition) is active and leaves rotations alone while idle in town.

### 5. Session stats overlay

Optional on-screen panel (position, opacity, font size). Works **independently** of the main Enable toggle.

---



## Menu guide (v2.0.0)

Open: **Z | War Pigs | Orchestrator**

### Core

- **Enable** — Master switch for WarPlans orchestration.
- **Use keybind** — Optional hotkey gate on top of Enable.



### Plugin Selection

- Auto status lines per task, or dropdowns when ambiguous / manual mode is on.
- **Manual plugin selection** — Show all task dropdowns.
- **Setup** warnings if a required plugin is not loaded.



### Activity & behavior

- **Use teleport** — `warplan.teleport_to_activity()` between activities.
- **Use SilentRaven** — Crow turn-in after Alfred (requires SilentRaven).
- **Run pit after turn-in** — Pit filler when no WarPlans quest is active.
- **Skip boss chest** — Disable boss plugin when chest spawns.
- **Manage orbwalker** — Force orbwalker clear ON before each managed plugin.
- **Manage combat rotation** — Auto-enable rotation during quests.
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
        ├── core/plugin_catalog.lua    Folder name → role mapping for scanner
        ├── core/scripts_scan.lua      Discover plugin folders under scripts/
        ├── core/combat.lua            Rotation enable/disable coordination
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
| `core/plugin_catalog.lua`  | Map `scripts/` folder names to roles for discovery          |
| `core/orchestrator.lua`    | `quest_plugin_map` — WarPlans quest patterns → role markers |




### Adding support for a new plugin

1. Add the folder → role mapping in `core/plugin_catalog.lua`.
2. Add a choice (and `auto_globals` entry if needed) in `core/plugin_registry.lua`.
3. Ensure the plugin exposes a global (`SomePlugin` or `SOME_ROTATION`) with at least `enable` / `disable` for activity bots.

WarPlans quest keys still go in `orchestrator.quest_plugin_map`; use `registry.ROLE_MARKERS.<role>` for the `plugin` field instead of a hard-coded global.

---



## Supported plugin folders (auto-discovery)

These folder names under `scripts/` are recognized when the plugin scanner runs (automatically on first open of **Plugin Selection**):

- `ArkhamAsylum`, `HelltideRevamped`, `BetterHelltide`, `WonderCity-2.0`
- `NightmareCity`, `Infernal Horde`, `Reaper`
- `Batmobile`, `Frigate`
- `rotation_barbarian`, `UniversalRotation`, `Scmurd-Warlock`
- `BetterAlfred`

Other folders with `main.lua` may appear if registered in the catalog.

---



## Requirements

- **QQT** with Lua script injection
- **WarPlans** quests active on the character
- Per-activity plugins installed and **enabled in QQT Scripts** for the content you run
- Recommended support plugins:
  - **Alfred** (any supported variant) for stash/salvage between activities
  - **Batmobile** or **Frigate** for town navigation
  - **Universal Rotation** or a class rotation for combat
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



### 2.0.0

- Simplified menu for end users
- Removed all dev/debug menu options and quest capture tooling
- Auto plugin scan on first Plugin Selection open (no manual Refresh button)
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