# Haul 2026.08.04.1

Haul used to be a loot tracker. It now tracks the whole run, and it hands you the entire vocabulary to display it.

Experience, currencies, kills, reputation, skill-ups and mail are all first-class citizens. Each one had a number before. Now each one has a full set of words: a running total, a per-hour rate, your best single source, and the last one you picked up, all as template tokens you drop straight onto the header bar. **58 new tokens** in this release.

## How the tokens read

Once you know the pattern you can guess almost any token without looking it up. Every category speaks the same four words.

| You want | You type | You get |
|---|---|---|
| the running total | `{xp}` | everything this session |
| the rate | `{xp.perhour}` | how fast it is coming in |
| your best source | `{xp.top}` | the single biggest contributor, named |
| the most recent one | `{xp.last}` | what just happened |

Swap `xp` for `currency`, `kills`, `rep`, `skill` or `mail` and the same four work. Add `.name`, `.amount` or `.count` to any `.top` or `.last` to pull just that piece out instead of the whole formatted phrase, so `{kills.top}` gives you "Wretched Hooligan x47" while `{kills.top.name}` gives you just the name.

Money tokens take `.short` for the top unit only, or `.full` for gold silver copper. Bare is short. Any token takes a color: `{haul:gold}`, `{kills:red}`, or a hex code if you are particular. And `{br}` starts a new line, with the bar growing to fit.

## Everything new in this release

**Experience** (green)
`{xp.perhour}`
`{xp.top}` `{xp.top.name}` `{xp.top.count}` `{xp.top.amount}`
`{xp.top.category}` `{xp.top.category.name}` `{xp.top.category.amount}` the biggest source TYPE, e.g. "Kills +4,433"
`{xp.last}` `{xp.last.name}` `{xp.last.count}` `{xp.last.amount}` `{xp.last.source}`

**Currency** (blue)
`{currency.name}` `{currency.perhour}` `{currency.top}` `{currency.detail}`
`{currency.last}` `{currency.last.name}` `{currency.last.count}` `{currency.last.amount}`

**Kills** (red)
`{kills.perhour}`
`{kills.top}` `{kills.top.name}` `{kills.top.count}`
`{kills.last}` `{kills.last.name}` `{kills.last.count}`

**Reputation** (pink)
`{rep.perhour}`
`{rep.last}` `{rep.last.name}` `{rep.last.count}` `{rep.last.amount}`

**Skill-ups** (lilac)
`{skill}` `{skill.perhour}`
`{skill.top}` `{skill.top.name}` `{skill.top.count}` `{skill.top.amount}`
`{skill.last}` `{skill.last.name}` `{skill.last.count}` `{skill.last.amount}` `{skill.last.level}`

**Mail** (gold)
`{mail.gold}` `{mail.perhour}` `{gold.perhour}`
`{mail.last}` `{mail.last.value}` `{mail.last.gold}` `{mail.last.item}`

**The last thing of any kind at all**
`{last.kind}` `{last.name}` `{last.count}` `{last.amount}` `{last.source}` `{last.value}` `{last.perhour}`
Whatever you picked up most recently, whichever category it belonged to. Put `{last}` on the bar and it narrates your run.

### Already there, and still there

`{haul}` `{total}` `{loot}` `{cash}` `{gross}` `{perhour}` `{gross.perhour}` `{xp}` `{currency}` `{kills}` `{rep}` `{rep.amount}` `{rep.faction}` `{rep.top}` `{rep.detail}` `{mail}` `{last}`
`{items.count}` `{items.value}` `{items.notable}` `{items.notable.label}` `{items.last}` `{items.last.name}` `{items.last.count}` `{items.last.value}`
`{time}` `{time.current}` `{time.current.ampm}` `{time.ig}` `{time.timer}` `{zone}` `{zone.full}` `{zone.region}` `{zone.zone}` `{zone.sub}`
`{token}` `{token.percent}` `{token.price}` `{token.trend}` `{token.value}` `{source}` `{flushed}`

## Also new

**One color scheme, everywhere.** Each category now wears the same color wherever it shows up: the log, the header tokens, and your Gadgets bars all agree. Experience green, kills red, currency blue, reputation pink, skill-ups lilac, coin and mail gold. Set it once and stop thinking about it.

**Tooltips worth reading.** They follow your cursor now, and every single one carries the full token reference, so you can look up what goes on the bar without alt-tabbing to a wiki.

**WoW Token trend.** The token watch keeps a rolling price history and shows you where the price has been, not just where it is.

---

## Fixed: runs that got thrown away

A session only counted as worth keeping if it had loot or a change in your gold. Which meant a battleground hour, a dungeon you auto-vendored your way through, a crafting session, or a mailbox stuffed with auction gold all told you there was "nothing to save" and got dropped on the floor.

If Haul recorded it, Haul banks it. There is a tab for it, so it counts.

## Fixed: loot landing on the wrong character

Swap characters in a way the game does not report as a fresh login and your old session stayed open, quietly crediting the new character's loot to the old one. Sessions no longer cross characters, ever. Deliberately resuming a saved run on an alt still works and gets credited to whoever picked it up.

## Fixed: sessions that quietly stopped counting

With "reload before new session" turned on, changing zones could leave you with no live session at all. Everything you looted from that point on went nowhere. Zone changes now always start a fresh run and flag the sync for the next time you press Save.

## Fixed: vendor-priced items worth nothing

If you looted something before your client had it cached, Haul priced it at zero. Worse, the zero stuck, to the session and to your saved history, so a good run could go into the books looking like a bad one.

Every place that prices an item now waits for the item to actually load first. And the zeros already sitting in your history get repaired automatically the next time you log in, so old runs finally read what they were worth.

## Fixed: items you bought counted as loot

Combine two saved runs and everything you had purchased at a merchant got valued as if you had looted it. Restock a stack of reagents mid-farm and the combined run came out worth considerably more than it earned. Flattering. Also fiction.

Purchases stay in the vendor ledger where they belong and never inflate a combined run.

## Fixed: experience counted twice

Quest experience was landing in the quest bucket and the catch-all bucket at the same time, inflating your total. That is corrected, XP now survives a lagging experience bar, and the XP you pick up for walking into a new zone is labeled as discovery instead of guessed at.

## Fixed: the Save button that would not save

The reload Save fires was being refused by the game outright. It runs through a path the client accepts now, so pressing Save actually syncs.

## Fixed: loot wearing the wrong label

Fish caught mid-cast are tagged as fish every time. Chests you crack open are no longer tagged as fish, which they never were. The real object you looted is captured instead of inferred. And two of the instant-open fishing chests are now recognized by name.

## Fixed: exclusions that did not stick

Items you excluded from your gold under an older version never wrote the marker that keeps them excluded, so the exclusion could quietly wander off. Those are backfilled now.

## Lighter the longer you farm

Every single thing you picked up used to trigger a full rebuild of the session, so a four-hour run cost more frames than a four-minute one, and it was worst exactly when you could least afford it, mid-pull. Updates are batched now. The bar stops charging you rent.

## Polish

- Quest turn-ins arrive as one batch instead of a scatter of unrelated entries, so the "last" tokens show you the whole handful.
- The empty Saved Sessions panel told you to press Save. Save syncs to disk and has never created a saved session. New is the button that banks a run, and the panel says so.
- The "Auto reload every" option could never reload on its own, because the game only permits a reload from your own click. It is labeled as the reminder it always was.
- The readme named a Reset button that does not exist.
- The Great Vault readout is gone, and the theme picker moved somewhere less in the way.

Happy hauling, and may your gold per hour survive contact with the truth.

GEC Management
