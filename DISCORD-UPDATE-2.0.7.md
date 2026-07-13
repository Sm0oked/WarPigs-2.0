# 🐗 WarPigs v2.0.7 — Update

Big stability + quality-of-life update. TL;DR: **your plugin picks now stick after reload, WW barbs stop getting stuck on teleports, BetterHelltide handoffs are clean, and the menu got simpler.**

## 🐛 Bug fixes

- **Plugin picks no longer reset to Auto after a reload.** If you picked a bot (e.g. BetterHelltide) and reloaded scripts, WarPigs silently ran the Auto pick instead until you opened the Plugin Selection menu once. Your dropdown choice now holds through every reload — no menu visit needed.
- **Barbarian Whirlwind cancelling teleports (Frigate users).** WW barbs would get stuck spinning in place while the console looped `TO_TEMIS timeout — retrying waypoint`. Cause: Frigate re-casts Whirlwind **every tick** (it even "whirls in place to maintain buff"), so WarPigs' one-time WW stop before a teleport didn't hold — the spell came right back and cancelled the 5-second teleport channel. WarPigs now also stops Frigate's navigation (long-path + target) before **every** teleport attempt and retry, so nothing re-casts during the channel. Barb-only bug — Frigate gates WW to barbarians, which is why other classes never saw it.
- **BetterHelltide's broken disable() contained.** BetterHelltide can throw a Lua `module 'tasks.farm' not found` error inside its own disable (pack bug), which half-aborted every handoff and spammed the console. WarPigs now falls back to the other teardown function and stops calling the broken one for the rest of the session. Worst case it logs once and tells you to reload or switch helltide bots.
- **No more silent skips when a plugin is missing.** If a WarPlans quest needs a role with nothing loaded (e.g. a helltide quest with no helltide bot enabled in QQT), you now get a console warning with the exact fix and a `MISSING PLUGIN` status on the HUD. Previously WarPigs just sat there doing nothing.
- Misc: removed a leftover internal global; dead menu logic cleaned up.

## 🧭 Menu changes

- **Every dropdown now shows a `->` status line** — exactly which plugin that role resolves to *right now*: loaded, NOT loaded (with the "enable X in QQT Scripts" hint), or nothing loaded. What you see is what the orchestrator will run on the next handoff.
- **Removed the Undercity and Navigation dropdowns.** Undercity only has one bot (Wonder City — used automatically when loaded) and navigation is auto-detected (Batmobile → Frigate). Less clutter, same behavior.
- **"Only show installed plugins" → "Check installs on disk".** The old toggle did nothing (leftover from the 2.0.2 combo-crash fix). The new one flags picks whose folder/`.pack` wasn't found on disk in the last scan.

## 📝 Edit it yourself (no coding needed)

- **HOW-TO-EDIT.md** (in the WarPigs folder) — copy-paste recipes for non-programmers: add a new bot to a dropdown, add a new boss quest name, fix `.pack` detection after a rename, change what Auto prefers.
- **check_syntax.bat** — double-click after any edit; it points at the exact file + line of a typo *before* you reload in-game.

## ℹ️ Not a WarPigs bug (FYI)

The reported "after finishing an Infernal Horde it keeps trying to leave, then gets placed right back in the same spot" loop is the **horde bot's own exit sequence** (`Reached Central Room Position` / `Waiting to exit Horde` / `Resetting all dungeons` — none of those lines are WarPigs'). If you hit it, grab a longer log: if there are no `[WarPigs]` lines between exit cycles, report it to the horde bot's author.

**To update:** replace your WarPigs folder, reload scripts. Saved settings and picks carry over.
