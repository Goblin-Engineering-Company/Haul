# Haul 2026.11.14.1

**Haul 2026.11.14.1: Less Paperwork**

**This one is all about performance.**

Haul has been doing a lot of busywork behind your back. The longer your history got, the more of it there was. This update fires most of it.

**A smaller saved file.** Every time you logged out or reloaded, Haul wrote out a second full copy of your entire session history. Nobody ever read it. With a long history, that copy was about a third of the whole file. It's gone, so Save, /reload and logout have less to write and finish faster. The old copy clears itself out the first time you log out after updating.

**Less counting every second.** While you track, the bar's totals refresh once a second, and every refresh recounted your whole session from the first loot of the night. Two hours into a farm, that's a lot of recounting for a number that hadn't changed. Now Haul only recounts when something actually happens: new loot, a pause, an exclude. Prices and the clock still update live. Long runs no longer get heavier the longer they go.

**Less memory while you play.** Haul also stopped keeping a spare copy of its item and place lists loaded during your session. It builds that copy once, at logout, when it's actually needed.

The goblin who was copying every ledger twice, by hand, has been moved to quality control, where copying things twice is the job.

**Nothing is lost.** Your sessions, history and settings are exactly where you left them. Tracking, pricing and sessions work the same as before, just with less wheezing.
