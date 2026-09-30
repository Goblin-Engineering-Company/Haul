# Haul 2026.09.30.2

**Haul now runs on WoW: Forever, and pausing is more reliable.**

- **WoW: Forever support.** Haul now loads and tracks loot, gold per hour and pricing on the Forever client.
- **Fish count as fish on Forever.** Forever uses the older ranked Fishing spells. Haul now recognizes all of them, so your catches are logged as fish instead of being mistaken for chest loot.
- **Fixed: loot could stop counting after a pause.** If you combined saved sessions while tracking was paused, everything you looted after pressing Resume was left out of your haul. Resume now always picks tracking back up. If the affected session is still open, it counts correctly once you save it; sessions you already saved keep their old totals.
- **Fixed: combining could leave out part of a session.** If you combined a session that you had earlier resumed or merged another run into, the combined total left out the run folded into it. New combines now count everything.

**Known issue on the Forever beta:** the beta client currently doesn't load saved addon data between sessions, so Haul's saved sessions and settings reset each time you launch. This is a beta client issue, and Haul will keep your data once it's fixed.

Nothing else changes on retail. Tracking, pricing, and sessions work exactly as before.
