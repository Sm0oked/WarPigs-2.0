# WarPigs — Editing guide (no programming experience needed)

This guide covers the handful of edits you may ever need to make yourself —
mostly "a new bot came out and I want WarPigs to use it". Every recipe is
copy-paste with clearly marked `CHANGE-THIS` spots.

---

## Golden rules (read once)

1. **Back up before editing.** Copy the file you're about to change (e.g.
   `plugin_registry.lua` → `plugin_registry.lua.bak`) so you can always undo.
2. **Use a plain text editor.** Notepad or Notepad++ is perfect. Do **not**
   use Word/WordPad — they replace normal quotes `'` with curly quotes `’`,
   which breaks the file.
3. **One change at a time.** Make one edit, check it (next rule), then the next.
4. **After every edit, double-click `check_syntax.bat`** in this folder. If it
   says `ALL FILES OK`, you're safe to reload scripts in QQT. If it shows an
   error, it prints the file and line number of the typo — fix it or restore
   your backup.
5. **Add new things at the END of lists — never delete or reorder existing
   entries.** Your saved dropdown picks are stored as positions; reordering
   shifts everyone's saved choices, and shrinking a list can crash the game
   menu.
6. **Watch the commas.** Every entry in a list ends with a comma. When you
   copy a block, keep its trailing comma.

---

## The only files you should ever edit

| File | What's in it | You edit it when… |
| ---- | ------------ | ----------------- |
| `core/plugin_registry.lua` | The dropdown options for each role (Pit, Helltide, Hordes, Boss, Alfred, …) | A new bot should appear as a choice |
| `core/plugin_catalog.lua` | Maps folder names and `.pack` filenames to roles | A bot's folder/pack isn't detected by **Scan entries** |
| `core/orchestrator.lua` | The list of WarPlans quest names (near the top, `quest_plugin_map`) | Blizzard adds a new boss / quest name |
| `core/settings.lua` | Default picks on a fresh install | You want a different out-of-the-box default |

**Never edit** anything else (`plugin_resolver.lua`, `transitions.lua`,
`navigation.lua`, `gui.lua`, …) — that's the machinery, not the configuration.

---

## Recipe 1 — Add a new bot as a dropdown option (most common)

Say a new helltide bot called **"HellStorm"** comes out and you want it as an
option under **Plugin Selection → Helltide**.

### Step 1: Find the bot's *global name*

Every QQT bot announces itself with a name in code, usually ending in
`Plugin` (e.g. `HelltideRevampedPlugin`). To find it:

- Easiest: ask in the bot's release thread / Discord — "what's the plugin
  global?"
- Or open the bot's `main.lua` (if it ships as a folder) in Notepad and look
  near the bottom for a line like `HellStormPlugin = ...`.
- Or check the QQT console when the bot loads — many print their name.

For this example, assume it's `HellStormPlugin`.

### Step 2: Add a choice in `core/plugin_registry.lua`

Open `core/plugin_registry.lua`. Find the role you want — each role is a
block like `helltide = { ... }`. Inside it, find `choices = {` and the list
of `{ ... },` blocks. **At the end of that list** (after the last `},` but
before the closing `},` of `choices`), paste:

```lua
            {
                id     = 'hellstorm',            -- CHANGE-THIS: short unique name, lowercase, no spaces
                label  = 'HellStorm',            -- CHANGE-THIS: what the dropdown shows
                global = 'HellStormPlugin',      -- CHANGE-THIS: the global name from Step 1
                folder = 'HellStorm',            -- CHANGE-THIS: the bot's folder name under scripts\ (or pack name, see Recipe 3)
            },
```

### Step 3: Tell Auto-detect and the handoff logic about it

Still in the same role block, near the top you'll see two lists:

```lua
        all_globals  = { 'HelltideRevampedPlugin', 'HelltideLitePlugin', 'BetterHelltidePlugin' },
        auto_globals = { 'HelltideRevampedPlugin', 'HelltideLitePlugin', 'BetterHelltidePlugin' },
```

Add the new global name to **both** lists (inside the `{ }`, with quotes and
a comma):

- `all_globals` — **required.** This is how WarPigs knows the bot belongs to
  this role, so it can shut it down when handing off to another activity.
  Skipping this means two bots can end up running at once.
- `auto_globals` — put it where you want it in the **Auto priority order**
  (first entry wins when several bots are loaded). Add it at the end if the
  existing bots should still win Auto.

### Step 4 (optional but recommended): Make **Scan entries** find it

Open `core/plugin_catalog.lua` and add a folder entry in the `M.folders`
list (again: at the end, before the closing `}`):

```lua
    HellStorm = {                                       -- CHANGE-THIS: folder name under scripts\
        helltide = { global = 'HellStormPlugin', label = 'HellStorm' },   -- CHANGE-THIS: role, global, label
    },
```

(The role word must be one of: `pit`, `helltide`, `undercity`, `horde`,
`boss`, `nav`, `alfred`. Note: only `pit`, `helltide`, `horde`, `boss` and
`alfred` have a dropdown in the menu — `undercity` and `nav` work
automatically in the background and show no dropdown.)

### Step 5: Verify

1. Double-click `check_syntax.bat` → wait for `ALL FILES OK`.
2. Reload scripts in QQT.
3. Open **Z | War Pigs → Plugin Selection**. The new option is in the
   dropdown, and the `->` line under it shows whether the bot is loaded.

---

## Recipe 2 — A new WarPlans boss quest name

If a WarPlans boss quest isn't picked up (console shows nothing, HUD stays
idle while the quest is active), the quest's internal name is probably new.

Open `core/orchestrator.lua` and find the block of lines that look like:

```lua
    WarPlans_QST_BossLair_Andariel = boss_map_entry('andariel'),  -- CONFIRMED
```

Add a new line next to them:

```lua
    WarPlans_QST_BossLair_NewBoss = boss_map_entry('newboss'),   -- CHANGE-THIS: quest name + boss id
```

- The left side is the quest's internal name (it always starts with
  `WarPlans_QST`). Partial names are fine — it matches as "contains".
- The right side (`'newboss'`) must be a boss id Reaper knows:
  `duriel, andariel, varshan, grigoire, zir, beast, harbinger, urivar,
  butcher, belial` (check Reaper's docs for new ones).

Then run `check_syntax.bat` and reload.

---

## Recipe 3 — A `.pack` file isn't detected after an update

Pack files change names between versions (`BetterHelltide-v1.7.9.pack` →
`BetterHelltide-v1.8.0.pack`). WarPigs matches packs by how the filename
**starts**, so version bumps normally just work. If a pack gets a genuinely
new name, open `core/plugin_catalog.lua`, find the block of lines like:

```lua
    if basename:match('^BetterHelltide') then return 'BetterHelltide' end
```

and add one for the new pack (the word after `^` is "filename starts with",
the word after `return` must match a folder key from `M.folders`):

```lua
    if basename:match('^HellStorm') then return 'HellStorm' end   -- CHANGE-THIS
```

Then `check_syntax.bat`, reload, and click **Scan entries** — the pack should
appear in the "Packs found:" line.

---

## Recipe 4 — Change which bot Auto prefers

In `core/plugin_registry.lua`, each role has an `auto_globals` list. When a
role is set to **Auto**, WarPigs uses the **first** name in that list that is
actually loaded. Reorder the names inside the `{ }` to change the preference.
(Reordering `auto_globals` is safe — it's the `choices` list you must never
reorder.)

---

## Recipe 5 — Change the default pick on a fresh install

In `core/settings.lua`, near the top:

```lua
    plugin_boss_choice = 'reaper30',
```

The value is a choice **id** from `plugin_registry.lua` (e.g. `'auto'`,
`'reaper30'`, `'better_helltide'`). This only affects fresh installs — anyone
who already picked something keeps their pick.

---

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| Game menu crashes after your edit | Restore your `.bak` file. You probably removed or reordered a `choices` entry — new entries go at the END only. |
| `check_syntax.bat` shows an error | Read the line number it prints. 9 times out of 10 it's a missing quote `'`, a missing comma, or a missing `}` — compare against a neighbouring block. |
| New dropdown option shows but says `NOT loaded` | The bot itself isn't enabled in QQT Scripts, or the `global = '...'` name in Step 2 is wrong (check spelling — it's case-sensitive). |
| Two bots fighting / both running | The new bot's global is missing from `all_globals` (Recipe 1, Step 3). |
| Quest active but WarPigs idle | Console will say which plugin is missing. If it says nothing at all, the quest name is new — Recipe 2. |
| Scan doesn't see a pack | Recipe 3. Also confirm the `.pack` sits directly in `c:\diablo_qqt\scripts\`, not in a subfolder. |

---

## Mini Lua survival guide

- Text values need straight quotes: `'HellStormPlugin'` — never curly `’ ’`.
- Lists live inside `{ }` and every item ends with `,` (a comma after the
  last item is allowed and safe — when in doubt, keep it).
- Lines starting with `--` are comments — notes for humans, ignored by the
  game. Add your own freely.
- Spelling and capitalization matter everywhere: `HellstormPlugin` and
  `HellStormPlugin` are different names.
