# Haul 2026.09.03.1

**A performance pass, a bug-report button, and a spot in the AddOns menu.**

- **Haul now idles quietly.** We did a performance pass on the live window. Before this, the window redid all of its work every second whether or not anything had changed: it replayed the whole session twice, re-priced every item, and re-laid out every row in the list, even while tracking was paused. Now a paused window does nothing but keep its buttons in sync, and a running window only refreshes the timer and per-hour figures each second, rebuilding the list only when something new lands. Every refresh also does half the work it used to. If Haul was showing up in your CPU usage on long farm sessions, this is the fix.
- **Report a bug, in one click.** There is a new "Report a bug" button at the top of the About tab (also `/haul bug` followed by a short description). It opens a copyable summary of your setup: versions, price source, the settings that affect tracking, how much the current session has captured, and where you are as the new-session triggers see it. Paste it into your report and we can usually reproduce the problem without a back-and-forth. Your character name, realm, guild, and your loot are never included.
- **Haul is listed in the AddOns menu.** Click the AddOns button on the minimap and Haul is there; one click opens the window.

Tracking, pricing, and sessions are unchanged.
