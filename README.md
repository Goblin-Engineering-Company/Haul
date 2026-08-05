# Haul

**The everything-tracker for World of Warcraft.** Every kill, every loot drop,
every experience point, gathering, reputation, and gold in one movable bar.
Whole sessions of anything you farm, saved forever.

Built by the [Goblin Engineering Company](https://goblineng.co).

## Features

- Tracks whole sessions of anything: farming, gathering, gold runs, fishing,
  delves, raids, keys
- Live session bar with fully templated fields, so you show exactly the numbers
  you care about
- Loot capture with vendor / TradeSkillMaster / Auctionator pricing
- XP, reputation, currencies, profession skill-ups, kills and per-mob drops,
  all per session
- Mail gold tracked as its own category, so returned auction listings never
  read as new income
- Saved sessions: save, merge, and combine runs, with per-character attribution
- Per-hour rates for everything

## Install

1. Download the latest release and copy the `Haul/` folder into
   `World of Warcraft/_retail_/Interface/AddOns/`.
2. Enable **Haul** in the AddOns list and log in (or `/reload`).

Optional: install **TradeSkillMaster** or **Auctionator** for market pricing.
Haul detects them automatically. Without either, vendor prices are used.

## Quick start

- Drag the bar wherever you like; click the arrow to expand it.
- **New** banks the run you're on to your history and starts a fresh session.
  **Pause / Resume** stops and restarts counting. **Save** writes your data to
  disk (it reloads the UI to do it). **Options** opens the settings.
- `/haul` shows or hides the bar; `/haul config` opens settings.
- Key bindings live under Key Bindings → Haul (none are set by default).

## Links

- Website, data project, and roadmap: [goblineng.co](https://goblineng.co)
- Bug reports and feature requests: the feedback form on the website. Votes
  decide what ships next.
