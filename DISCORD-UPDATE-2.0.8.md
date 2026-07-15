# 🐗 WarPigs v2.0.8 — Hotfix

**Fixed: enable/disable loop when BetterHelltide is your helltide bot.**

WarPigs would enable BetterHelltide and then instantly disable it, over and over — enable → disable → 5s cooldown → repeat — so it never actually farmed. Cause: BetterHelltide registers under two names (`BetterHelltidePlugin` + `HelltideLitePlugin`), and WarPigs treated the second name as a separate unwanted plugin and force-disabled it. Also fixed the follow-on stall where the console sat on `post-disable cooldown (5.0s left)` for minutes.

⚠️ Separate heads-up for BetterHelltide v1.7.42 users: the pack itself currently reports `no patrol waypoints loaded — check scripts/waypoints/ beside the .pack`, so it teleports to the helltide but won't patrol. Until that's sorted on the pack's side, HelltideRevamped is the more reliable helltide pick.

**To update:** grab the latest from GitHub, replace your WarPigs folder, reload scripts. Settings carry over.
