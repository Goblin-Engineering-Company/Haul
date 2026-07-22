-- Core.lua — session state, controls, stats, public API, SavedVariables.
local ADDON, ns = ...

-- ⚠️ Kill tracking is fed from the CHAT_MSG_COMBAT_XP_GAIN "X dies…" message (ns._recordKill), NOT from
-- COMBAT_LOG_EVENT_UNFILTERED — that event is protected and its RegisterEvent is blocked by cross-addon taint in
-- a real addon environment (four workarounds all failed). See CombatLogInit.lua + auto-memory
-- [[combat-log-protected-registration-taint]]. Trade-off: only XP-granting kills are counted.

Haul = Haul or {}          -- global: public API + Bindings.xml shims

-- Lazy GECReader handle (the one live-getter layer; silent=true -> nil if absent, never errors). Defined
-- at the top so every reader below (identity, faction resolve, rep display) can use it.
local function reader()
  return (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECReader-1.0", true)) or nil
end
-- BUILD STAMP — single source of truth is the `## Version` in Haul.toc (the canonical delivery key the
-- website/Uplink compare). Read it via metadata so it can NEVER drift from the toc. (GetAddOnMetadata
-- reflects the toc as parsed at CLIENT LAUNCH, so a `## Version` bump shows after a full restart, not /reload.)
Haul.BUILD = (((C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata)("Haul", "Version")) or "?"

-- Release CHANNEL of THIS installed copy, read from the `## X-GEC-Channel` .toc field the publish scripts
-- stamp in ("dev" | "prerelease" | "public"). nil when running from unpublished SOURCE (a plain rsync/dev
-- copy carries no marker) — that's a local dev build. (X-prefixed .toc fields are readable via metadata.)
function Haul.Channel()
  local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ch = get and get("Haul", "X-GEC-Channel")
  return (ch and ch ~= "") and ch or nil
end
-- A colored "[channel]" badge for the version / build readouts — shown for every channel EXCEPT public (the
-- default needs no badge). Unpublished source shows [local]. "" when nothing to show. Prerelease=amber, else teal.
function Haul.ChannelBadge()
  local ch = Haul.Channel() or "local"
  if ch == "public" then return "" end
  local col = (ch == "prerelease") and "ffcf40" or "45c4a0"
  return "  |cff" .. col .. "[" .. ch .. "]|r"
end

Haul.DEV = false
function Haul.IsDev()
  return Haul.DEV
end

-- Modern arrow-less scrollbar — now provided by GECTheme; kept as ns.AttachScrollBar for callers.
local GECTheme = LibStub("GECTheme-1.0").ForAddon(function() return (HaulDB and HaulDB.themePreset) or "gruvbox" end)
local Theme = GECTheme   -- alias: Theme.accentHex / Theme.Accent() used below
function ns.AttachScrollBar(sf, barParent)
  return GECTheme.AttachScrollBar(sf, barParent)
end

-- shared fast-loot lib (optional handle: nil-safe if not embedded). ns.ApplyFastLoot pushes Haul's preference
-- into the singleton looter (enable/disable Haul as a requester) and mirrors Haul's debug-log into its chat
-- dump. Idempotent — safe to call on load and on every toggle change.
local GECLoot = LibStub:GetLibrary("GECLoot-1.0", true)
function ns.ApplyFastLoot()
  if not GECLoot then return end
  if HaulDB and HaulDB.fastLoot then GECLoot:Enable("Haul") else GECLoot:Disable("Haul") end
  GECLoot:SetDebug("Haul", HaulDB and HaulDB.debug or false)
end

------------------------------------------------------------------- defaults --
local DB_DEFAULTS = {
  keybinds = {},                     -- bindingName -> "ALT-CTRL-SHIFT-X" (Keybinds tab)
  priceSource = "vendor",            -- "vendor" | "tsm" | "auctionator" (auto-upgraded on first login)
  tsmPriceStr = "dbminbuyout",       -- TSM "current minimum buyout"
  notableQuality = 2,             -- >= Uncommon (green)
  excluded = {},                     -- itemID -> true (exclude from gold)
  fastLoot = false,                  -- fast, silent, framerate-independent auto-loot via GECLoot-1.0 (replaces
                                     -- the client's built-in auto-loot; the loot window still surfaces for
                                     -- locked/high-quality/BoP/bags-full so nothing is lost)
  killsCombatLog = false,            -- Kills: try the combat log for EVERY kill (incl. gray/no-XP). OFF = the
                                     -- popup-free XP-message source (XP-granting kills only). ON may trigger the
                                     -- WoW taint warning on sessions where other addons (Auctionator/TSM) taint
                                     -- the stack — WoW 12.0 blocks COMBAT_LOG registration there. See auto-memory.
  gatherLootWindowSec = 4,           -- Gathering attribution: only log looted items as "gathered" (node loot)
                                     -- when a real gather node ("You perform <skill> on <node>") was opened
                                     -- within this many seconds. Fishing/plain containers fire NO opening line,
                                     -- so their catches are just normal item loot — never logged as "gathered".
  graysMode = "merge",               -- gray items: "show" | "merge" | "ignore"
  boundMode = "merge",               -- bind-on-pickup items: "show" | "merge" | "ignore"
  excludedMode = "show",             -- excluded items: "show" (gray, sunk) | "merge" | "ignore"
  mailMode = "merge",                -- mailbox-source items: "show" (Expanded) | "merge" (Collapsed, default) | "ignore" (Hidden)
  view = "collection",               -- Loot's view: "collection" (aggregated) | "list" (chronological)
  repView = "collection",            -- Reputation's view: "collection" (per-faction) | "list" (chronological)
  currencyView = "collection",       -- Currency's view: "collection" (per-currency) | "list" (chronological)
  profView = "collection",           -- Skills' view: "collection" (per-profession tier) | "list" (chronological)
  xpView = "collection",             -- XP's view: "collection" (total + per-zone discovery) | "list" (discovery stream)
  killView = "collection",           -- Kills' view: "collection" (per-mob counts) | "list" (chronological)
  dataCategory = "loot",             -- Data tab saved-session detail: "loot" | "rep" | "currency" | "prof" | "xp" | "kill"
  dataColPct = false,                -- Data tab: show the % column in the saved-session AccordionList
  dataSessionSort = "recent",        -- Data tab session-list order: "recent" (by save/uid) | "date" (by startedAt)
  dataGroupOpen = {},                -- Data tab: per-session group-open state, keyed by snapshot uid
  priceCacheTTL = 45,                -- secs to memoize a price lookup (per source+item); 0 disables the cache
  sortBy = "value",                  -- Collection sort: "value" | "name" | "count" | "time"
  -- mustache-style header: {time} {haul} {gross} {perhour} {cash}
  -- {items}/{items.count} {items.value}/{items.price} {notable}/{items.notable}
  -- {items.last}(.short/.full) {items.last.name} {items.last.count} {items.last.value}/{items.last.price}
  -- ALL money tokens take .short (largest unit) or .full (g/s/c); bare = short
  -- e.g. {haul.full} {cash.short} {perhour.full} {items.value.full} {token.price.full}
  -- {token} {tokenprice} {zone} {source}
  headerTemplate = "{time}   {haul}   {perhour}/hr",
  -- the body/detail area under the header — rendered through the same template engine
  detailTemplate =
    "Haul value: {haul.full}   (gross {gross.full})\n"
    .. "Per hour: {perhour.full}/hr\n"
    .. "Loot: {loot.full}   Cash: {cash.full}\n"
    .. "Items: {items.count}   {items.notable.label}: {items.notable}\n"
    .. "Token: {token.price}   {token.percent}\n"
    .. "Zone: {zone}   Source: {source}",
  -- display styling
  valueFormat = "short",             -- global money format: "short" (3g) or "long" (3g 47s 21c) — Options → item display
  scale = 1.0,                       -- overall window scale (how big it shows up)
  headerFontSize = 12,               -- header text size
  headerColor = "ffffff",            -- default header text color (literal text)
  headerSpacing = 2,                 -- line spacing for multi-line headers
  headerPad = 4,                     -- padding around the header content
  bgAlpha = 0.88,                    -- window background opacity (Display slider)
  history = {},
  sessionsMineOnly = false,          -- Saved Sessions: filter to current character
  watchers = {},                     -- extra spawnable header bars (see Watchers.lua)
  -- flush / reload-to-sync
  flushEnabled = false,              -- auto-reload timer off by default
  flushSeconds = 600,                -- 10m, used only when flushEnabled
  reloadBeforeNewSession = false,    -- reload the UI just before starting a new session (manual New OR an
                                     -- auto map-change new session), flushing state to disk. Optional, off by default.
  autoStartInstance = false,         -- legacy; migrated into newSessionTriggers.instance
  -- new-session triggers. instance = sideline + resume on leave (independent). map = bank the run +
  -- start fresh when your location changes, at newSessionMapLevel granularity. See CheckZoneTransition.
  newSessionTriggers = { instance = false, map = false, scenario = false },
  -- scenario = treat scenario-system content (world quests, open-world events, delves) as an instance run
  -- (sideline + resume). OFF by default: 9/10 a "scenario" is an open-world area you fly THROUGH on a farm
  -- run (ore/herbs), and you do NOT want that fragmenting your session. Turn on only to track scenarios/delves.
  newSessionMapLevel = "region",     -- region | zone | subzone — a finer tier also fires on coarser moves
  newSessionPrompt = true,           -- ask before starting a new session on a map change
  -- continuous event log (HaulData) — see Log.lua
  logShow = 150,                     -- Log-tab DISPLAY cap: how many recent lines to render (the saved log is
                                     -- never auto-trimmed; purge manually with /haul prune <N>)
  logSearchMode = "highlight",       -- Log-tab search mode: "highlight" (tint + next/prev jump) | "filter" (show only matches)
  countPausedByDefault = false,      -- spec §5.3: paused events excluded from totals by default (Spec 4 uses this)
  -- window — anchored by its TOP-LEFT (left/top screen coords) so collapsing
  -- grows/shrinks DOWNWARD and the top edge stays put. Set on first drag.
  window = {
    left = nil, top = nil, expanded = true, listShown = true, showDetail = true,
    colPct = true,       -- show the "% of drops" column in the loot Collection view (Columns dropdown) — default ON
    colSrc = true,       -- show the loot-source icon column — default ON
    category = "loot",   -- active in-window category: "loot" | "rep" (rotated by the category button)
    groupOpen = {},      -- per-bucket accordion open state (bound/gray/excluded -> bool), seeded from mode
  },
}

local function ApplyDefaults(dst, defaults)
  for k, v in pairs(defaults) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      ApplyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

-------------------------------------------------------------------- helpers --
function ns.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff45c4a0Haul|r: " .. tostring(msg))
end

-- Show a transient message in the window's notification line.
function ns.Notify(msg, secs)
  ns._notifyMsg = msg
  ns._notifyUntil = GetTime() + (secs or 4)
  if ns.RefreshUI then ns.RefreshUI() end
end

-- gold-only short string for the bar, e.g. "1,234g"
function ns.ShortGold(copper)
  local g = math.floor((tonumber(copper) or 0) / 10000)
  return BreakUpLargeNumbers and (BreakUpLargeNumbers(g) .. "g") or (g .. "g")
end

-- full coin texture string (with icons) — kept for anything that wants it
function ns.Coins(copper)
  return GetCoinTextureString(math.max(0, math.floor(tonumber(copper) or 0)))
end

-- In-game style coin text using colored g/s/c letters (no coin icons). Zero
-- denominations are omitted. Colors match the game (gold/silver/copper).
local GOLD_C, SILVER_C, COPPER_C = "ffffd700", "ffc7c7cf", "ffeda55f"
function ns.Money(copper)
  copper = math.max(0, math.floor(tonumber(copper) or 0))
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  -- in-game style: numbers forced WHITE (so the header/text color can't recolor
  -- them), only the g/s/c letter carries the coin color
  local out = {}
  if g > 0 then
    local gs = BreakUpLargeNumbers and BreakUpLargeNumbers(g) or tostring(g)
    out[#out + 1] = "|cffffffff" .. gs .. "|r|c" .. GOLD_C .. "g|r"
  end
  if s > 0 then out[#out + 1] = "|cffffffff" .. s .. "|r|c" .. SILVER_C .. "s|r" end
  if c > 0 or #out == 0 then out[#out + 1] = "|cffffffff" .. c .. "|r|c" .. COPPER_C .. "c|r" end
  return table.concat(out, " ")
end

-- Compact: just the LARGEST non-zero denomination (3g, 40s, 75c) — white number +
-- colored letter. Used in the header where full g/s/c is too much. Showing the top
-- unit (not gold-only) means a sub-gold value reads "40s", not "0g".
-- The GLOBAL value-format toggle (Options → item display) rides HERE: when set to "long", every value
-- that renders through MoneyShort (lists, buckets, header tokens — 30+ sites) shows the full g/s/c
-- instead of the rounded top unit. Default "short" keeps the current compact behavior.
function ns.MoneyShort(copper)
  if HaulDB and HaulDB.valueFormat == "long" then return ns.Money(copper) end
  copper = math.max(0, math.floor(tonumber(copper) or 0))
  if copper >= 10000 then
    local g = math.floor(copper / 10000)
    local gs = BreakUpLargeNumbers and BreakUpLargeNumbers(g) or tostring(g)
    return "|cffffffff" .. gs .. "|r|c" .. GOLD_C .. "g|r"
  elseif copper >= 100 then
    return "|cffffffff" .. math.floor(copper / 100) .. "|r|c" .. SILVER_C .. "s|r"
  end
  return "|cffffffff" .. copper .. "|r|c" .. COPPER_C .. "c|r"
end

-- Friendly price-source label that matches the Options dropdown exactly, e.g.
-- "TSM: Region Min Buyout", "Auctionator", "Vendor".
local TSM_LABELS = {
  dbminbuyout = "Minimum Buyout",
  dbmarket = "Market Value",
  dbregionmarketavg = "Region Market Avg",
  dbregionminbuyoutavg = "Region Min Buyout",
  dbhistorical = "Historical",
}
-- "Name-Realm" for the current character (sessions are saved account-wide). Identity via the getter layer.
function ns.CharName()
  local R = reader()
  local id = R and R.Current and R.Current.identity and R.Current.identity()
  local n = id and id.name
  local r = id and id.realm
  if n and n ~= "" and r and r ~= "" then return n .. "-" .. r end
  return n or "?"
end

-- Current character's class file (e.g. "MAGE"), for class-colored names — via the getter layer.
function ns.CharClass()
  local R = reader()
  local id = R and R.Current and R.Current.identity and R.Current.identity()
  return (id and id.class) or nil
end

-- "ffffff" -> r,g,b in 0..1
function ns.HexToRGB(hex) return GECTheme.HexToRGB(hex) end

function ns.SourceLabel()
  local s = HaulDB and HaulDB.priceSource
  if s == "tsm" then
    return "TSM: " .. (TSM_LABELS[HaulDB.tsmPriceStr] or HaulDB.tsmPriceStr or "?")
  elseif s == "auctionator" then return "Auctionator"
  else return "Vendor" end
end

-- "[Name]" wrapped in the item's quality color, built from quality (NOT from the
-- captured link, whose color format changed to |cn in 12.0 and is unreliable to
-- parse).
function ns.QualityName(name, quality)
  name = "[" .. (name or "?") .. "]"
  local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
  if q then
    if q.color and q.color.WrapTextInColorCode then
      return q.color:WrapTextInColorCode(name)
    elseif q.hex then
      return "|c" .. q.hex .. name .. "|r"
    end
  end
  return name
end

-- Pull the [Name] out of an item link (synchronous — the name is embedded in the link),
-- so a SAVED item renders correctly even when GetItemInfo() hasn't cached it yet. Returns
-- nil for a bare "item:id" string (no embedded name) so callers fall back to "?".
function ns.NameFromLink(link)
  if type(link) ~= "string" then return nil end
  return link:match("%[(.-)%]")
end

--------------------------------------------------------------------- session --
-- Migrate mail gold to the v2 itemized model: returns a `mailGoldLog` list. Uses
-- an existing list as-is; upgrades a legacy v1 `mailGold` scalar (+ optional
-- `mailGoldKeep`) into a single labeled entry; else an empty log.
local function NormalizeMailGold(sv)
  if type(sv) ~= "table" then return {} end
  if type(sv.mailGoldLog) == "table" then return sv.mailGoldLog end
  local legacy = tonumber(sv.mailGold) or 0
  if legacy > 0 then
    return { { amount = legacy, label = "Mail gold", keep = sv.mailGoldKeep or nil, seq = 1 } }
  end
  return {}
end

local function NewSession()
  local s = {
    running = true,
    t0 = GetTime(), accum = 0,            -- elapsed timer
    gold = 0,                             -- looted gold (copper) — only goes up
    mailGoldLog = {},                     -- itemized mail gold: { amount, label, sender, subject, seq, keep }
    mailGoldSeq = 0,                      -- per-entry id counter for mailGoldLog
    items = {},                           -- (id or id.."@"..from) -> { id, link, count, seq, from, keep }
    log = {},                             -- chronological loot events (List view)
    seq = 0,                              -- first-seen order counter (Time sort)
    waypoints = {},
    rep = {},                             -- faction name -> reputation gained this session
    repLog = {},                          -- chronological rep gains { faction, amount, t } (Rep List view)
    currency = {},                        -- currencyID -> amount GAINED this session (gains only; spends are log-only)
    currencyLog = {},                     -- chronological currency gains { id, amount, t } (Currency List view)
    professions = {},                     -- lineID -> skill points gained this session (per profession/tier)
    professionsLog = {},                  -- chronological skill-ups { id, name, prof, amount, level, t } (Skills List view)
    xp = 0,                               -- total experience gained this session (all sources)
    xpDiscovery = 0,                      -- experience gained specifically from zone discovery (a labeled subset of xp)
    xpQuest = 0,                          -- experience from quest turn-ins (base reward; a labeled subset of xp)
    xpKill = 0,                           -- experience from kills (a labeled subset of xp)
    xpMobs = {},                          -- mob name -> { xp, kills } (Kills accordion children)
    xpGather = 0,                         -- experience from gathering (mining/herbing; a labeled subset of xp)
    xpNodes = {},                         -- node name -> { xp, count } (Gathering accordion children)
    xpOther = 0,                          -- unnamed XP with no source signal (bonus objectives, etc.; subset of xp)
    xpOtherLog = {},                      -- chronological unattributed gains { amount, t } (Other accordion children)
    xpZones = {},                         -- zone name -> discovery XP (Discovery accordion children)
    xpLog = {},                           -- chronological ALL-gains stream { amount, t } (Total XP accordion / List view)
    xpQuestLog = {},                      -- chronological quest rewards { amount, t } (Quests accordion children)
    kills = {},                           -- npcID -> { name, count, loot={itemID->{link,count}} } (Kills view + loot-under-kills)
    killCount = 0,                        -- total mobs killed this session
    killLog = {},                         -- chronological kills { id, name, t } (Kills List view)
    gather = {},                          -- node name -> { name, loot={itemID->{link,count}} } (gathered items per node)
    startedAt = time(),
    establishedAt = time(),               -- when THIS run was created (stable; startedAt may slide earlier on merge)
    -- WHO ran this — bound at creation, NOT at save. Sessions persist across relog
    -- (account-wide DB), so capturing the char at snapshot time would mis-attribute
    -- a run to whoever happens to be logged in when it's banked/reset.
    character = ns.CharName(),
    class = ns.CharClass(),   -- classFile, for class-colored names
  }
  if ns.BeginSession then ns.BeginSession(s) end   -- allocate sid + sessions-table row + `start` marker
  return s
end

-- Pack a PAUSED session (the sidelined open-world run held while you're in an
-- instance) for SavedVariables, so a /reload mid-instance doesn't lose it.
local function PackSession(s)
  if not s then return nil end
  local elapsed = (s.accum or 0) + (s.running and (GetTime() - (s.t0 or GetTime())) or 0)
  return {
    accum = elapsed, gold = s.gold or 0, wasRunning = s._wasRunning and true or false,
    mailGoldLog = s.mailGoldLog or {}, mailGoldSeq = s.mailGoldSeq or 0,
    items = s.items, log = s.log, seq = s.seq, waypoints = s.waypoints, startedAt = s.startedAt,
    establishedAt = s.establishedAt, merges = s.merges, sid = s.sid,
    character = s.character, class = s.class,
  }
end
-- Highest `seq` currently present in a mailGoldLog (so re-baselining the counter
-- after a migrate/concat keeps new ids unique).
local function MaxMailGoldSeq(log)
  local m = 0
  for _, e in ipairs(log or {}) do if (e.seq or 0) > m then m = e.seq end end
  return m
end

local function UnpackSession(sv)
  if type(sv) ~= "table" then return nil end
  local mgl = NormalizeMailGold(sv)
  local s = {
    running = false, t0 = GetTime(), accum = tonumber(sv.accum) or 0,
    gold = tonumber(sv.gold) or 0, _wasRunning = sv.wasRunning ~= false,
    mailGoldLog = mgl, mailGoldSeq = tonumber(sv.mailGoldSeq) or MaxMailGoldSeq(mgl),
    items = sv.items or {}, log = sv.log or {}, seq = tonumber(sv.seq) or 0,
    waypoints = sv.waypoints or {}, startedAt = sv.startedAt or time(),
    establishedAt = sv.establishedAt or sv.startedAt, merges = sv.merges,
    sid = sv.sid,   -- string sid; tonumber() nuked it (same bug as RestoreOrNew) — the sidelined instance run kept its sid
    character = sv.character, class = sv.class,
  }
  -- PackSession only persists loot/coin/mail; rep/currency/xp/kills/professions/gather live in the log.
  -- Re-derive them from the restored log (as RestoreOrNew does) so a sidelined instance run that /reloaded
  -- keeps every category instead of coming back with those five empty.
  if ns.SeedAggregates and ns.Replay then ns.SeedAggregates(s, ns.Replay.Rebuild(s.log)) end
  return s
end

-- Persist the live session so it RESUMES across /reload and relog (only Reset
-- clears it). elapsed/coin are banked as absolute values because GetTime()
-- restarts and money may shift while logged out.
local function SaveLive()
  local s = ns.session
  HaulDB.sidelined = PackSession(ns.sidelined)   -- keep the set-aside run too
  if not s then HaulDB.liveSession = nil; return end
  HaulDB.liveSession = {
    running = s.running, accum = ns.Elapsed(), gold = ns.Coin(),
    mailGoldLog = s.mailGoldLog or {}, mailGoldSeq = s.mailGoldSeq or 0,
    items = s.items, log = s.log, seq = s.seq,
    waypoints = s.waypoints, rep = s.rep, repLog = s.repLog,
    currency = s.currency, currencyLog = s.currencyLog,
    professions = s.professions, professionsLog = s.professionsLog,
    xp = s.xp, xpDiscovery = s.xpDiscovery, xpQuest = s.xpQuest, xpKill = s.xpKill, xpMobs = s.xpMobs,
    xpGather = s.xpGather, xpNodes = s.xpNodes, xpOther = s.xpOther, xpOtherLog = s.xpOtherLog,
    kills = s.kills, killCount = s.killCount, killLog = s.killLog, gather = s.gather,
    xpZones = s.xpZones, xpLog = s.xpLog, xpQuestLog = s.xpQuestLog, startedAt = s.startedAt,
    establishedAt = s.establishedAt, merges = s.merges, sid = s.sid,
    character = s.character, class = s.class,
  }
end
ns.SaveLive = SaveLive
ns.UnpackSession = UnpackSession

local function RestoreOrNew()
  local sv = HaulDB and HaulDB.liveSession
  if type(sv) == "table" then
    local mgl = NormalizeMailGold(sv)
    local s = {
      running = sv.running ~= false,
      t0 = GetTime(), accum = tonumber(sv.accum) or 0,
      -- migrate old net-delta moneyAccum (could be negative) to looted gold
      gold = tonumber(sv.gold) or math.max(0, tonumber(sv.moneyAccum) or 0),
      mailGoldLog = mgl, mailGoldSeq = tonumber(sv.mailGoldSeq) or MaxMailGoldSeq(mgl),
      items = sv.items or {}, log = sv.log or {}, seq = tonumber(sv.seq) or 0,
      waypoints = sv.waypoints or {}, rep = sv.rep or {}, repLog = sv.repLog or {},
      currency = sv.currency or {}, currencyLog = sv.currencyLog or {},
      professions = sv.professions or {}, professionsLog = sv.professionsLog or {},
      xp = tonumber(sv.xp) or 0, xpDiscovery = tonumber(sv.xpDiscovery) or 0, xpQuest = tonumber(sv.xpQuest) or 0,
      xpKill = tonumber(sv.xpKill) or 0, xpMobs = sv.xpMobs or {},
      xpGather = tonumber(sv.xpGather) or 0, xpNodes = sv.xpNodes or {},
      xpOther = tonumber(sv.xpOther) or 0, xpOtherLog = sv.xpOtherLog or {},
      kills = sv.kills or {}, killCount = tonumber(sv.killCount) or 0, killLog = sv.killLog or {}, gather = sv.gather or {},
      xpZones = sv.xpZones or {}, xpLog = sv.xpLog or {}, xpQuestLog = sv.xpQuestLog or {},
      startedAt = sv.startedAt or time(),
      establishedAt = sv.establishedAt or sv.startedAt, merges = sv.merges,
      sid = sv.sid,   -- sids are STRINGS ("6a5ade99-e334"); tonumber() nuked them to nil, so every reload
                      -- looked session-less and began a NEW one (then the BeginSession guard closed the
                      -- still-open session as "crash-repair"). Keep the string → /reload RESUMES the same sid.
      character = sv.character, class = sv.class,   -- preserve who ran it across /reload & relog
    }
    -- resumed across /reload: keep the SAME sid (the controller's open-session pointer persists on
    -- HaulData, so no new `start`). A session that predates the log (no sid) gets one now; and if the
    -- controller lost its open run (e.g. across a DATA_VERSION wipe) we start a fresh sid so events
    -- attribute correctly rather than orphaning onto a gone session.
    local ctrl = ns.SessionCtrl and ns.SessionCtrl()
    if not s.sid then
      if ns.BeginSession then ns.BeginSession(s) end
    elseif ctrl and not ctrl:IsOpen() then
      s.sid = nil; if ns.BeginSession then ns.BeginSession(s) end
    end
    -- re-derive the non-loot aggregates from the restored log so they always match it (heals a session
    -- merged/resumed before the SeedAggregates fix, and keeps the log the single source of truth).
    if ns.SeedAggregates and ns.Replay then ns.SeedAggregates(s, ns.Replay.Rebuild(s.log)) end
    return s
  end
  return NewSession()
end

function ns.Elapsed()
  local s = ns.session; if not s then return 0 end
  return s.accum + (s.running and (GetTime() - s.t0) or 0)
end

function ns.Coin()
  local s = ns.session; if not s then return 0 end
  return s.gold or 0      -- accumulated looted gold (added on CHAT_MSG_MONEY)
end

-- seconds since the character logged in (survives /reload, see PLAYER_LOGIN)
function ns.IGSeconds()
  return time() - (HaulDB and HaulDB._loginUnix or time())
end


-- Looted-gold capture, locale-independent: CHAT_MSG_MONEY signals that the last
-- money change was LOOT (not vendor/repair), and GetMoney()'s delta gives the
-- amount (numbers only, no text). The two events can fire in either order, so we
-- reconcile them — and consume each gain exactly once to avoid double-counting.
local function mdbg(...) if HaulDB and HaulDB.debug then print("|cff45c4a0Haul|r |cff808080[money]|r", ...) end end
-- Forward declaration: append a MONEY row to the live session's chronological s.log so the in-window
-- List view shows it interleaved with item drops. Defined below CurrentLocation (which it uses).
-- Rows are money-shaped { kind = "coin"|"quest"|"mailgold", c, from, t, loc }; item rows keep { id, ... }.
local appendMoneyLog
-- ...and rep / vendor rows, so s.log is the COMPLETE chronological session stream (the single source
-- of truth the views are rebuilt from). rep rows carry { kind="rep", f, a }; vendor rows carry
-- { kind="vendorsell|vendorbuy|vendorrepair", c, from="vendor" } and stay log-only (never displayed/counted).
local appendRepLog, appendVendorLog, appendMailGoldLog, appendCurrencyLog
-- prof skill-ups / experience / kills into the session log — forward-declared so the `function appendX`
-- definitions below bind to these file-locals instead of leaking three globals (appendProfLog / appendXPLog /
-- appendKillLog) into _G.
local appendProfLog, appendXPLog, appendKillLog
-- `ls` (optional) tags the coin's SOURCE, e.g. {t="kill",npcID,guid} for mob cash — ONE coin event then both
-- counts toward the total AND attributes to the mob (exactly like a loot event). No separate attribution row.
local function addLootedGold(amount, from, ls)
  if amount and amount > 0 and ns.LogEvent then ns.LogEvent("coin", { amount = amount, from = from, src = ls }) end  -- always-on log (amount signed; src = attribution descriptor)
  if amount and amount > 0 and ns.session and ns.session.running then
    ns.session.gold = (ns.session.gold or 0) + amount
    appendMoneyLog("coin", amount, from, ls)   -- List view; from="container" for chest/bag-opened gold
    mdbg("added", amount, "-> gold", ns.session.gold, from or "")
    if ns.RefreshUI then ns.RefreshUI() end
  elseif amount and amount > 0 then
    mdbg("NOT added", amount, "- session.running =", ns.session and ns.session.running)
  end
end
-- Read looted money STRAIGHT from the CHAT_MSG_MONEY text ("You loot 1 Gold, 2 Silver, 3 Copper").
-- Locale-independent: GOLD_AMOUNT / SILVER_AMOUNT / COPPER_AMOUNT are the client's own localized
-- "%d Gold" / "%d Silver" / "%d Copper" strings, so each becomes a capture pattern.
local function parseLootMoney(msg)
  if not msg then return 0 end
  local function grab(amountStr)
    if not amountStr then return 0 end
    return tonumber(msg:match((amountStr:gsub("%%d", "(%%d+)")))) or 0
  end
  return grab(GOLD_AMOUNT) * 10000 + grab(SILVER_AMOUNT) * 100 + grab(COPPER_AMOUNT)
end
local function onLootMoney(msg)
  local amount = parseLootMoney(msg)
  if amount == 0 then                                    -- coin-icon message etc.: fall back to a delta
    local now = GetMoney()
    amount = math.max(0, now - (ns._lastMoney or now)); ns._lastMoney = now
  end
  mdbg("CHAT_MSG_MONEY '" .. tostring(msg) .. "' ->", amount)
  -- mob-cash attribution returns the ls (and updates the LIVE per-mob cash); pass it so this is ONE coin event
  -- tagged ls=kill — no separate attribution row.
  local ls = ns._attribMobCash and ns._attribMobCash(amount) or nil
  addLootedGold(amount, nil, ls)
  -- re-baseline so the paired PLAYER_MONEY sees no unexplained delta and can't re-book this looted coin as
  -- "container" gold. Without this, using ANY bag item within GECLoot.CONTAINER_WINDOW (2s) — food, a potion,
  -- a lockbox — leaves LastContainer() fresh, and the coin was counted twice (and written twice into the log).
  ns._lastMoney = GetMoney()
end
-- Append one mail-gold pickup to the live session's itemized log (v2). `amount` is
-- copper; `label` is the display label; `sender`/`subject` optional. Returns nothing.
local function addMailGold(amount, label, sender, subject)
  local s = ns.session
  if not (amount and amount > 0 and s and s.running) then return end
  s.mailGoldLog = s.mailGoldLog or {}
  s.mailGoldSeq = (s.mailGoldSeq or 0) + 1
  s.mailGoldLog[#s.mailGoldLog + 1] = {
    amount = amount, label = label, sender = sender, subject = subject,
    seq = s.mailGoldSeq, keep = false,
  }
  -- always-on log: record each mail-gold pickup with its label/sender/subject.
  if ns.LogEvent then ns.LogEvent("mail", { amount = amount, label = label, sender = sender, subject = subject, from = "mail", seq = s.mailGoldSeq }) end
  appendMailGoldLog(amount, label, sender, subject, s.mailGoldSeq)   -- complete row into s.log (the source of truth)
  mdbg("mail gold +", amount, "label", label)
  if ns.RefreshUI then ns.RefreshUI() end
end

-- Record one mail's gold, labeled by its sender/subject, from the inbox index — reading the
-- still-cached header at hook time (the take is async, so the money is still readable here).
local function recordMailGold(index)
  if not (GetInboxHeaderInfo and ns.session and ns.session.running) then return end
  local _, _, sender, subject, money = GetInboxHeaderInfo(index)
  if not (money and money > 0) then return end
  local label = (subject and subject ~= "" and subject) or ("From: " .. (sender or "?"))
  ns._mailHookPending = (ns._mailHookPending or 0) + money   -- for PLAYER_MONEY reconciliation
  addMailGold(money, label, sender, subject)
end

-- Labeled capture (primary): hook BOTH ways the client collects mail gold, so each pickup is
-- attributed to its own mail — TakeInboxMoney (clicking the coin icon) AND AutoLootMailItem
-- (right-click auto-loot + third-party "open all mail" addons, which do NOT call TakeInboxMoney).
-- Registered once at PLAYER_LOGIN. The PLAYER_MONEY safety net reconciles anything neither saw.
local function HookMailGold()
  if ns._mailHookInstalled then return end
  ns._mailHookInstalled = true
  if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", recordMailGold) end
  if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", recordMailGold) end
  -- Repair disambiguation: a repair sets a short-lived flag so the NEXT negative merchant money
  -- delta is logged as `vendorrepair` rather than `vendorbuy` (mirrors the _mailHookPending pattern).
  if RepairAllItems then hooksecurefunc("RepairAllItems", function() ns._expectRepair = true end) end
end

-- keep the fallback baseline current so vendor/repair money isn't mistaken for loot.
-- Live "is the mailbox / a profession window open RIGHT NOW" checks, queried at the moment
-- of capture. These replace the old sticky _atMailbox/_atCraft booleans toggled by paired
-- MAIL_SHOW/MAIL_CLOSED (and TRADE_SKILL_*) events: a single missed close event left the flag
-- stuck "open" for the rest of the session, tagging ALL later world loot as mail. Reading the
-- actual frame/interaction state self-heals — a missed close event can't poison anything.
function ns.MailboxOpen()
  local IM = C_PlayerInteractionManager
  if IM and IM.IsInteractingWithNpcOfType and Enum and Enum.PlayerInteractionType
     and Enum.PlayerInteractionType.MailInfo then
    return IM.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.MailInfo) and true or false
  end
  return (MailFrame and MailFrame:IsShown()) and true or false   -- fallback for older clients
end
function ns.CraftOpen()
  if ProfessionsFrame and ProfessionsFrame:IsShown() then return true end   -- retail professions UI
  if TradeSkillFrame and TradeSkillFrame:IsShown() then return true end      -- classic / fallback
  return false
end
-- Live "is a merchant/vendor open RIGHT NOW" — same robust pattern as MailboxOpen (no sticky flag,
-- so a missed close can't poison later capture). Used to log vendor sell/buy/repair money and to
-- tag purchased items as from="vendor" (which are then kept entirely out of the haul/window).
function ns.MerchantOpen()
  -- TRUE if EITHER the interaction manager reports a merchant OR the merchant frame is shown.
  -- (Checking only the interaction manager and never the frame was the bug: if that API returns
  -- false at a vendor — or a vendor-replacement addon is in use — vendor money went uncaptured.)
  local IM = C_PlayerInteractionManager
  if IM and IM.IsInteractingWithNpcOfType and Enum and Enum.PlayerInteractionType
     and Enum.PlayerInteractionType.Merchant
     and IM.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.Merchant) then
    return true
  end
  return (MerchantFrame and MerchantFrame:IsShown()) and true or false
end

-- While the mailbox is open, a positive GetMoney() delta is mail gold. The labeled
-- TakeInboxMoney hook already recorded the named portion (tracked in _mailHookPending);
-- here we reconcile so only the LEFTOVER (gold that arrived via a path the hook didn't
-- see) is recorded, as an unlabeled "Mail gold" entry — no double-count, no silent loss.
-- Decreases (COD/postage) are ignored. Always re-baseline _lastMoney either way (as before).
local function onPlayerMoney()
  local now = GetMoney()
  if ns.MailboxOpen() then
    local delta = now - (ns._lastMoney or now)
    if delta > 0 and ns.session and ns.session.running and ns.Replay then
      -- consume the hooked/pending amount with this delta (don't reset it — that double-counted);
      -- only money the per-mail hooks never saw becomes an unlabeled leftover entry.
      local leftover
      ns._mailHookPending, leftover = ns.Replay.ReconcileMailDelta(ns._mailHookPending, delta)
      if leftover > 0 then addMailGold(leftover, "Mail gold") end
    end
  elseif ns.MerchantOpen() then
    -- Vendor money is LOG-ONLY: sell (gain) / buy (spend) / repair (spend, disambiguated by the
    -- RepairAllItems hook). NEVER added to ns.session.gold and NEVER added to s.log — it stays out
    -- of the haul and the window entirely; only the always-on event log records it.
    local delta = now - (ns._lastMoney or now)
    if delta > 0 then
      ns.LogEvent("vendor", { amount = delta, vt = "sell", from = "vendor" })
      appendVendorLog("sell", delta)
      mdbg("vendor sell +", delta)
    elseif delta < 0 then
      local spent = -delta
      if ns._expectRepair then
        ns._expectRepair = nil
        ns.LogEvent("vendor", { amount = -spent, vt = "repair", from = "vendor" })   -- signed: spend is negative
        appendVendorLog("repair", spent)
        mdbg("vendor repair -", spent)
      else
        ns.LogEvent("vendor", { amount = -spent, vt = "buy", from = "vendor" })   -- signed: spend is negative
        appendVendorLog("buy", spent)
        mdbg("vendor buy -", spent)
      end
    end
  else
    -- Not at mailbox or merchant: a positive delta with no CHAT_MSG_MONEY. DETERMINISTIC container detection:
    -- a bag container we JUST opened (GECLoot:LastContainer fresh) pushes its gold silently → tag it "container".
    -- Loot / quest gold is accounted by its OWN path (CHAT_MSG_MONEY / QUEST_TURNED_IN), so we do NOTHING here
    -- for it. This replaces the old timing-race reconcile, which logged a phantom "container" duplicate of
    -- nearly every coin gain when the loot/quest message landed later than the reconcile delay.
    local delta = now - (ns._lastMoney or now)
    if delta > 0 then
      local c = GECLoot and GECLoot.LastContainer and GECLoot:LastContainer()
      if c then addLootedGold(delta, "container") end
      -- (genuinely-unattributed gold with no chat/quest/container is rare and intentionally NOT logged here —
      --  the live total still counts it via GetMoney; better than double-counting every real gain.)
    end
    ns._mailHookPending = 0   -- away from mailbox/merchant: clear stale pending so it can't suppress a later leftover
  end
  ns._lastMoney = now   -- always re-baseline so the next delta is measured from here
end
-- quest turn-in reward money (QUEST_TURNED_IN arg3, in copper) — shows as "Received X Gold…" and does
-- NOT come through CHAT_MSG_MONEY, so capture it here. Counts as session income like looted coin.
-- Bypass addLootedGold so this logs a `quest` event (not `coin`) but still adds to
-- the live session's gold like looted coin.
local function onQuestMoney(money, questID)
  money = tonumber(money) or 0
  mdbg("QUEST_TURNED_IN money", money)
  -- ALWAYS carry the quest ID (not just a title) — the ID is the stable identity
  local src = { t = "quest", id = tonumber(questID) or nil }
  if money > 0 and ns.LogEvent then ns.LogEvent("coin", { amount = money, src = src }) end   -- always-on log (coin, labeled quest)
  if money > 0 and ns.session and ns.session.running then
    ns.session.gold = (ns.session.gold or 0) + money
    appendMoneyLog("coin", money, nil, src)   -- quest reward coin (ls=quest) for the List view
    if ns.RefreshUI then ns.RefreshUI() end
  end
  ns._lastMoney = GetMoney()   -- re-baseline (same reason as onLootMoney): keep PLAYER_MONEY from re-booking quest coin as "container"
end

-- Reputation gains: CHAT_MSG_COMBAT_FACTION_CHANGE carries "Reputation with <faction> increased by <n>".
-- Parse it from the FACTION_STANDING_INCREASED global (locale-independent) + accumulate per faction.
local function repPattern(fmt)
  if not fmt then return nil end
  local p = fmt:gsub("%%s", "\001"):gsub("%%d", "\002")       -- protect the format specifiers
  p = p:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")           -- escape Lua pattern magic (incl '.')
  return (p:gsub("\001", "(.-)"):gsub("\002", "(%%d+)"))       -- restore as captures
end
-- Match BOTH the personal "Reputation with %s increased by %d." and the Warband
-- account-wide "Your Warband's reputation with %s increased by %d." (FACTION_STANDING_
-- INCREASED_ACCOUNT_WIDE) — the latter has a different prefix/case, so the personal
-- pattern alone silently dropped Warband rep gains. Patterns derived from the globals
-- so it stays locale-independent; nil globals are skipped.
local REP_PATTERNS = {}
for _, fmt in ipairs({ FACTION_STANDING_INCREASED_ACCOUNT_WIDE, FACTION_STANDING_INCREASED }) do
  local p = repPattern(fmt)
  if p then REP_PATTERNS[#REP_PATTERNS + 1] = p end
end
-- Decreases: "Reputation with %s decreased by %d." (+ the Warband account-wide variant). Same
-- derivation; a matched decrease is recorded as a NEGATIVE amount so faction totals subtract.
local REP_DEC_PATTERNS = {}
for _, fmt in ipairs({ FACTION_STANDING_DECREASED_ACCOUNT_WIDE, FACTION_STANDING_DECREASED }) do
  local p = repPattern(fmt)
  if p then REP_DEC_PATTERNS[#REP_DEC_PATTERNS + 1] = p end
end

-- Reverse map: faction display NAME -> stable factionID. Chat only gives us the name, so we resolve it to
-- the id to key reputation by identity (locale/rename stable) while keeping the name for display. Built
-- lazily from the live faction list (via GECReader) and rebuilt on a miss (a newly-encountered faction).
local factionIdByName
local function resolveFactionID(name)
  if not name then return nil end
  if factionIdByName and factionIdByName[name] then return factionIdByName[name] end
  factionIdByName = {}
  local R = reader()
  local list = (R and R.Current and R.Current.factionList and R.Current.factionList()) or {}
  for _, f in ipairs(list) do
    if f.name and f.factionID then factionIdByName[f.name] = f.factionID end
  end
  return factionIdByName[name]
end
ns.ResolveFactionID = resolveFactionID

-- Display name for a reputation KEY (a factionID number, or a name string when the id was unresolvable).
-- Prefers the shared registry (populated by Note("faction", id) at capture — resolves OFFLINE from a
-- snapshot too), then the live Reader, then a plain fallback. So an id-keyed rep entry always shows a name.
function ns.RepName(key)
  if type(key) ~= "number" then return tostring(key or "?") end
  local Store = LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECStore-1.0", true)
  local row = Store and Store.Resolve and Store.Resolve("faction", key)
  if row and row.name then return row.name end
  local R = reader()
  local f = R and R.Resolve and R.Resolve.faction and R.Resolve.faction(key)
  if f and f.name then return f.name end
  return "faction " .. tostring(key)
end

local function onFactionRep(msg)
  if not msg then return end
  mdbg("[rep raw]", msg)   -- Debug-log (HaulDB.debug): confirm the event fires + see the exact text
  -- Try increases (sign +1) then decreases (sign -1).
  local faction, amount, sign
  for _, pat in ipairs(REP_PATTERNS) do
    faction, amount = msg:match(pat)
    if faction then sign = 1; break end
  end
  if not faction then
    for _, pat in ipairs(REP_DEC_PATTERNS) do
      faction, amount = msg:match(pat)
      if faction then sign = -1; break end
    end
  end
  -- Fallback for prefixed/variant messages the globals miss — notably the Warband account-wide form,
  -- whose global name/format varies by build. Locate the span case-insensitively on a lowercased copy
  -- (handles the "R"→"r" + prefix) for BOTH directions, then slice the faction out of the ORIGINAL msg
  -- so its capitalization is preserved.
  if not faction then
    local lower = msg:lower()
    local fStart, factLower, amtStr = lower:match("reputation with ()(.-) increased by (%d+)")
    if fStart then sign = 1
    else
      fStart, factLower, amtStr = lower:match("reputation with ()(.-) decreased by (%d+)")
      if fStart then sign = -1 end
    end
    if fStart then
      faction = msg:sub(fStart, fStart + #factLower - 1)
      amount = amtStr
    end
  end
  amount = tonumber(amount)
  if not faction or not amount or amount <= 0 then return end
  -- Bonus rep (War Mode, Refer-A-Friend, buff/tabard, etc.) is appended as one or MORE "(+N bonus)"
  -- parentheticals and is ADDITIONAL to the base magnitude — sum every "(+<number>" group. Handles
  -- decimals ("(+7.5 …)") and the double-bonus form. `sign` then makes a decrease negative.
  local base, bonusTotal = amount, 0
  for b in msg:gmatch("%(%+%s*([%d%.]+)") do
    local n = tonumber(b)
    if n then bonusTotal = bonusTotal + n end
  end
  amount = (sign or 1) * math.floor(base + bonusTotal + 0.5)
  if bonusTotal > 0 then   -- Debug-log: show how base + bonus combined, to verify the additive model
    mdbg(("[rep parsed] %s %+d (base %d +bonus %g)"):format(faction, amount, base, bonusTotal))
  end
  -- Key reputation by stable factionID (chat gives only the name): id when resolvable, name as a last
  -- resort. Snapshot the faction into the shared registry so the id renders its name everywhere (incl.
  -- offline reconstruction from an exported snapshot).
  local fid = resolveFactionID(faction)
  local key = fid or faction
  if fid then
    local Store = LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECStore-1.0", true)
    if Store and Store.Note then Store.Note("faction", fid) end
  end
  if ns.LogEvent then ns.LogEvent("rep", { f = key, fid = fid, amount = amount }) end   -- always-on log (id-keyed)
  if ns.session and ns.session.running then
    ns.session.rep = ns.session.rep or {}
    ns.session.rep[key] = (ns.session.rep[key] or 0) + amount           -- accumulate by the id key
    ns.session.repLog = ns.session.repLog or {}
    ns.session.repLog[#ns.session.repLog + 1] = { faction = faction, fid = fid, amount = amount, t = time() }  -- keep the NAME for the List display
    appendRepLog(key, amount)   -- complete session stream (s.log), id-keyed to match the always-on log
    mdbg(("rep %+d %s"):format(amount, faction))
    if ns.RefreshUI then ns.RefreshUI() end
  end
end

-- Currency gains/spends: CURRENCY_DISPLAY_UPDATE(currencyType, quantity, quantityChange, ...). A
-- positive quantityChange (gain) feeds the primary Currency views (s.currency / s.currencyLog); a
-- negative change (spend) is LOG-ONLY — written to the event stream + always-on log but never shown,
-- mirroring how vendor spending is recorded but not displayed. Keyed by currencyType ID (locale-proof);
-- name/icon resolve at display time via C_CurrencyInfo.GetCurrencyInfo.
-- Some content (notably Torghast) fires CURRENCY_DISPLAY_UPDATE for INTERNAL/UI "currencies" — the scoreboard
-- toast/star-value trackers ("Torghast - Scoreboard - Toast Display - …"). They're not real player currencies
-- and should never be logged. Real currencies have a proper icon + show in the backpack; the internal ones
-- don't. Filter on that so the log/Currency view stays clean.
local function isRealCurrency(currencyType)
  local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(currencyType)
  if not info then return false end
  if info.isHeader then return false end
  local icon = info.iconFileID
  return (icon and icon ~= 0) and true or false   -- internal scoreboard "currencies" have no icon
end

local function onCurrencyUpdate(currencyType, quantity, quantityChange)
  if not currencyType or not quantityChange or quantityChange == 0 then return end
  if not isRealCurrency(currencyType) then return end   -- skip Torghast scoreboard + other internal UI currencies
  if ns.LogEvent then ns.LogEvent("currency", { cid = currencyType, id = currencyType, amount = quantityChange }) end   -- always-on log (gains + spends; server labels by cid, keep id too — safe)
  -- snapshot id->NAME into the shared registry: prefer writing the LIVE name (GetCurrencyInfo) so the
  -- record carries it even when the Reader can't resolve later (the server has no currency-name API and
  -- many currencies otherwise come back nameless); fall back to the Reader-resolved Note.
  if GECStore then
    local ci = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(currencyType)
    if ci and ci.name and ci.name ~= "" and GECStore.NoteNamed then
      GECStore.NoteNamed("currency", currencyType, ci.name)
    elseif GECStore.Note then
      GECStore.Note("currency", currencyType)
    end
  end
  local s = ns.session
  if not (s and s.running) then return end
  appendCurrencyLog(currencyType, quantityChange)   -- session stream (signed; spends stay log-only)
  if quantityChange > 0 then                          -- only gains feed the shown totals + list
    s.currency = s.currency or {}
    s.currency[currencyType] = (s.currency[currencyType] or 0) + quantityChange
    s.currencyLog = s.currencyLog or {}
    s.currencyLog[#s.currencyLog + 1] = { id = currencyType, amount = quantityChange, t = time() }
    mdbg(("currency +%d (#%d)"):format(quantityChange, currencyType))
  end
  if ns.RefreshUI then ns.RefreshUI() end
end

-- Profession skill-ups: subscribed from GECStore.OnSkillIncrease (the shared lib scrapes CHAT_MSG_SKILL and
-- fires a self-identifying payload — SBF's fishlog rides the same feed). Keyed by lineID (the expansion-
-- qualified tier, locale-proof); name/icon resolve at display time via GECStore.ProfessionCatalog. `delta`
-- is nil when the prior level is unknown (first skill-up of a cold line); a skill-up is always at least
-- +1, so default to 1. Always-on logged; only accumulates into the shown totals while running.
local function onSkillIncrease(p)
  if not (p and p.lineID) then return end
  local amount = p.delta or 1
  if amount <= 0 then return end
  if ns.LogEvent then ns.LogEvent("skill", { id = p.lineID, amount = amount, name = p.skillName, prof = p.profession, lvl = p.newLevel }) end
  local s = ns.session
  if not (s and s.running) then return end
  appendProfLog(p.lineID, amount, p.skillName, p.profession, p.newLevel)   -- session stream (s.log)
  s.professions = s.professions or {}
  s.professions[p.lineID] = (s.professions[p.lineID] or 0) + amount
  s.professionsLog = s.professionsLog or {}
  s.professionsLog[#s.professionsLog + 1] = { id = p.lineID, name = p.skillName, prof = p.profession, amount = amount, level = p.newLevel, t = time() }
  mdbg(("skill +%d %s -> %s"):format(amount, tostring(p.skillName), tostring(p.newLevel)))
  if ns.RefreshUI then ns.RefreshUI() end
end
if GECStore and GECStore.OnSkillIncrease then GECStore.OnSkillIncrease(onSkillIncrease) end

-- Experience: the authoritative TOTAL comes from PLAYER_XP_UPDATE deltas of UnitXP("player"). A level-up
-- resets UnitXP to a small number, so a raw delta would read negative — when the level rose, the gain is
-- (what remained in the old level) + (the new level's current XP). The baseline is CHARACTER state (updated
-- on every tick regardless of pause/stop, so resuming tracking doesn't book a giant jump); only the
-- accumulation into s.xp is gated on running. Discovery XP is a labeled SUBSET (see onSystemMsg), already
-- included in this total — it is NOT added again here.
local xpBaseline, xpLevelBaseline, xpMaxBaseline   -- nil until first read (login sets them)
local function readXP()
  return tonumber(UnitXP and UnitXP("player")) or 0,
         tonumber(UnitLevel and UnitLevel("player")) or 0,
         tonumber(UnitXPMax and UnitXPMax("player")) or 0
end
function ns.SyncXPBaseline() xpBaseline, xpLevelBaseline, xpMaxBaseline = readXP() end   -- called at login
-- ===== XP LOG reconciliation (one attributed event per gain; no separate no-ls total) =====
-- The authoritative amount is the PLAYER_XP delta; the SOURCE (kill/gather/quest/discovery) comes from a
-- separate chat line, and the two don't always sum (rested XP inflates the delta above the chat's base amount).
-- So we accumulate a WINDOW: onXPUpdate adds each delta to `_delta` (it does NOT log a total); each chat handler
-- logs ONE attributed `xp` event and adds its amount to `_attributed`; a debounced reconcile logs any leftover
-- (`_delta - _attributed`, i.e. rested bonus / bonus-objective XP with no chat line) as a single ls=other event.
-- Net: the LOG has one attributed event per gain, and every xp event's `a` SUMS to the true total. Order-safe
-- (delta vs chat can arrive in either order — only the totals at reconcile time matter). Live s.xp/subsets
-- (below) are unchanged: they update immediately for the live window; this governs only the persistent LOG.
local xpWin = { delta = 0, attributed = 0 }
local xpReconcileScheduled
local function logAttributedXP(amount, ls)   -- log ONE attributed xp event (both logs) + count it in the window
  if not (amount and amount > 0) then return end
  if ns.LogEvent then ns.LogEvent("xp", { amount = amount, src = ls }) end
  appendXPLog(amount, ls)                     -- session stream (guards on running)
  xpWin.attributed = xpWin.attributed + amount
end
local function scheduleXPReconcile()
  if xpReconcileScheduled then return end
  xpReconcileScheduled = true
  C_Timer.After((HaulDB and HaulDB.xpReconcileDelay) or 0.5, function()
    xpReconcileScheduled = nil
    local remainder = xpWin.delta - xpWin.attributed
    xpWin.delta, xpWin.attributed = 0, 0
    if remainder > 0 then   -- rested bonus / unattributed XP with no chat line -> its own "other" entry
      if ns.LogEvent then ns.LogEvent("xp", { amount = remainder, src = { t = "other" } }) end
      appendXPLog(remainder, { t = "other" })
    end
  end)
end
ns._logAttributedXP = logAttributedXP   -- referenced by the kill/quest handlers
ns._scheduleXPReconcile = scheduleXPReconcile
local function onXPUpdate()
  local cur, lvl, maxv = readXP()
  if xpBaseline == nil then xpBaseline, xpLevelBaseline, xpMaxBaseline = cur, lvl, maxv; return end
  local gained
  if lvl == xpLevelBaseline then
    gained = cur - xpBaseline
  else
    gained = (xpMaxBaseline - xpBaseline) + cur   -- crossed a level (intermediate full levels, if any, are rare)
  end
  xpBaseline, xpLevelBaseline, xpMaxBaseline = cur, lvl, maxv
  if not gained or gained <= 0 then return end
  -- LOG: buffer the delta into the window (do NOT log a no-ls total); the reconcile books any unattributed part.
  xpWin.delta = xpWin.delta + gained
  scheduleXPReconcile()
  local s = ns.session
  if not (s and s.running) then return end
  s.xp = (s.xp or 0) + gained
  s.xpLog = s.xpLog or {}
  s.xpLog[#s.xpLog + 1] = { amount = gained, t = time() }   -- every gain, for the XP List view (chronological stream)
  mdbg(("xp +%d (total %d)"):format(gained, s.xp))
  if ns.RefreshUI then ns.RefreshUI() end
end

-- Zone-discovery XP: ERR_ZONE_EXPLORED_XP = "Discovered %s: %d experience gained." arrives on
-- CHAT_MSG_SYSTEM carrying BOTH the place and the XP. It splits out the DISCOVERY source (and which zone)
-- from the PLAYER_XP_UPDATE total — the same total already counts it, so discovery is recorded as a labeled
-- subset (s.xpDiscovery / s.xpZones), never re-added to s.xp. Pattern derived from the global (locale-proof).
local DISCOVERY_PATTERN = repPattern(ERR_ZONE_EXPLORED_XP)
local function onSystemMsg(msg)
  if not (msg and DISCOVERY_PATTERN) then return end
  local zone, amtStr = msg:match(DISCOVERY_PATTERN)
  local amt = tonumber(amtStr)
  if not (zone and amt and amt > 0) then return end
  logAttributedXP(amt, { t = "disc", zone = zone }); scheduleXPReconcile()   -- ONE attributed xp event; window books any leftover
  local s = ns.session
  if not (s and s.running) then return end
  s.xpDiscovery = (s.xpDiscovery or 0) + amt
  s.xpZones = s.xpZones or {}
  s.xpZones[zone] = (s.xpZones[zone] or 0) + amt
  -- NOTE: not appended to s.xpLog — that stream is the all-gains timeline (onXPUpdate); this discovery
  -- amount is already inside the paired PLAYER_XP_UPDATE gain, so it would double-list here.
  mdbg(("discovery +%d xp: %s"):format(amt, tostring(zone)))
  if ns.RefreshUI then ns.RefreshUI() end
end

-- Quest-turn-in XP: QUEST_TURNED_IN(questID, xpReward, moneyReward) hands us the quest's XP reward directly.
-- It is a labeled SUBSET of the PLAYER_XP_UPDATE total (like discovery) — recorded for the source breakdown,
-- NOT re-added to s.xp. xpReward is the BASE reward (rested doubling lands in the "Other" residual).
local lastQuestXPAt = 0   -- GetTime() of the last quest turn-in — lets the unnamed-XP handler skip the quest's
                          -- own "You gain N experience." line (which would otherwise be booked as "Other")
local function onQuestXP(xpReward, questID)
  local amt = tonumber(xpReward)
  if not (amt and amt > 0) then return end
  lastQuestXPAt = GetTime()
  local title = questID and C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
  -- ALWAYS carry the quest ID alongside the title (the ID is the stable identity; GECQuest owns the fuller record)
  logAttributedXP(amt, { t = "quest", id = tonumber(questID) or nil, title = title }); scheduleXPReconcile()   -- ONE attributed xp event
  local s = ns.session
  if not (s and s.running) then return end
  s.xpQuest = (s.xpQuest or 0) + amt
  s.xpQuestLog = s.xpQuestLog or {}
  s.xpQuestLog[#s.xpQuestLog + 1] = { amount = amt, title = title, t = time() }   -- per-turn-in detail (Quests children)
  mdbg(("quest xp +%d (%s)"):format(amt, tostring(title)))
  if ns.RefreshUI then ns.RefreshUI() end
end
ns._onQuestXP = onQuestXP   -- referenced from the QUEST_TURNED_IN dispatch

-- Kill XP: CHAT_MSG_COMBAT_XP_GAIN carries a SELF-ATTRIBUTED line for kills — COMBATLOG_XPGAIN_FIRSTPERSON
-- = "%s dies, you gain %d experience." (rested variants append "(+N exhaustion bonus)"; the pattern matches
-- the leading part, so base kill XP is captured and any rested bonus falls into the "Other" residual). The
-- mob name lets us break kills down per-mob. Unnamed lines ("You gain %d experience." — gathering, quests,
-- bonus objectives) carry NO source, so they're ignored here (gathering needs its own signal). Like
-- discovery/quest, kill XP is a labeled SUBSET of the PLAYER_XP_UPDATE total, never re-added to it.
-- Gathering source: CHAT_MSG_OPENING = "You perform <skill> on <node>." fires just BEFORE the (unnamed) XP
-- line, so it tags the node for the gain that follows. English " on " split; on other locales the node just
-- won't resolve and that XP stays in the "Other" residual (graceful degradation). `gatherPending` is consumed
-- by the next unnamed XP gain within a few seconds — a quest turn-in has NO opening line, so its unnamed XP is
-- never mis-tagged as gathering.
local gatherPending   -- { node, t }  (consumable — XP source tagging)
local lastGatherNode  -- { node, t }  (persistent — gates recordGatherLoot so fishing/containers aren't "gathered")
local function onOpeningMsg(msg)
  if type(msg) ~= "string" then return end
  local node = msg:match(" on (.+)$")
  if not node then return end
  node = node:gsub("%s*%.%s*$", "")   -- drop the trailing period
  if node == "" then return end
  gatherPending = { node = node, t = GetTime() }   -- consumed by the next unnamed XP gain (source tagging)
  lastGatherNode = { node = node, t = GetTime() }  -- NOT consumed — read by recordGatherLoot to gate node-loot
end
ns._onOpeningMsg = onOpeningMsg   -- referenced from the CHAT_MSG_OPENING dispatch

-- Kill XP: CHAT_MSG_COMBAT_XP_GAIN carries a SELF-ATTRIBUTED line for kills — COMBATLOG_XPGAIN_FIRSTPERSON
-- = "%s dies, you gain %d experience." (rested variants append "(+N exhaustion bonus)"; the pattern matches
-- the leading part, so base kill XP is captured and any rested bonus falls into the "Other" residual). The
-- mob name lets us break kills down per-mob. An UNNAMED line ("You gain %d experience.") is gathering IF a
-- CHAT_MSG_OPENING just tagged a node (see gatherPending); otherwise it's quest/bonus and stays in Other.
-- Kill and gather XP are labeled SUBSETS of the PLAYER_XP_UPDATE total, never re-added to it.
local KILL_PATTERN = repPattern(COMBATLOG_XPGAIN_FIRSTPERSON)
local UNNAMED_PATTERN = repPattern(COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED)
local function onXPGainMsg(msg)
  if not msg then return end
  -- DEBUG (2026-07-17): is the kill XP line SECRET in 12.0 (name-filtered) or just failing the pattern?
  -- Secret-safe: check issecretvalue BEFORE printing (printing a secret can error). Toggle with /haul debug.
  if HaulDB and HaulDB.debug then
    mdbg("xpmsg:", (issecretvalue and issecretvalue(msg)) and "<SECRET>" or msg)
  end
  -- kill line?
  local mob, amt
  if KILL_PATTERN then local m, a = msg:match(KILL_PATTERN); mob, amt = m, tonumber(a) end
  if mob and mob ~= "" and amt and amt > 0 then
    -- recover the mob's GUID/npcID from your target FIRST so the kill-XP is stored with its id (reconstitutable)
    local mobGUID = ns._guidForKilledName and ns._guidForKilledName(mob)
    local mobNpc; if mobGUID and ns._parseGUID then local _, i = ns._parseGUID(mobGUID); mobNpc = i end
    -- LOG THE KILL FIRST so the kill event precedes its XP + loot in the stream (a kill "owns" what follows).
    -- ensureKill logs the `kill` event (GUID-deduped) + counts it live; the loot feed may already have.
    local killId = (mobGUID and ns._ensureKill) and ns._ensureKill(mobGUID, mobNpc, mob) or nil
    logAttributedXP(amt, { t = "kill", npcID = mobNpc, name = mob }); scheduleXPReconcile()   -- ONE attributed xp event (after the kill)
    local s = ns.session
    if not (s and s.running) then return end
    s.xpKill = (s.xpKill or 0) + amt
    s.xpMobs = s.xpMobs or {}
    local m = s.xpMobs[mob]; if not m then m = { xp = 0, kills = 0 }; s.xpMobs[mob] = m end
    m.xp = m.xp + amt; m.kills = m.kills + 1
    -- attach the XP to the (already-logged) kill record
    local kk = killId and s.kills and s.kills[killId]
    if kk then kk.xp = (kk.xp or 0) + amt end
    mdbg(("kill xp +%d (%s)"):format(amt, mob))
    if ns.RefreshUI then ns.RefreshUI() end
    return
  end
  -- unnamed gain ("You gain %d experience.") — no source in the line itself. Route it:
  local uAmt = UNNAMED_PATTERN and tonumber(msg:match(UNNAMED_PATTERN))
  if not (uAmt and uAmt > 0) then return end
  local now = GetTime()
  if gatherPending and (now - gatherPending.t) < 3 then
    -- GATHERING: a CHAT_MSG_OPENING just tagged the node this gain belongs to
    local node = gatherPending.node
    gatherPending = nil
    logAttributedXP(uAmt, { t = "gather", node = node }); scheduleXPReconcile()   -- ONE attributed xp event
    local s = ns.session
    if not (s and s.running) then return end
    s.xpGather = (s.xpGather or 0) + uAmt
    s.xpNodes = s.xpNodes or {}
    local nn = s.xpNodes[node]; if not nn then nn = { xp = 0, count = 0 }; s.xpNodes[node] = nn end
    nn.xp = nn.xp + uAmt; nn.count = nn.count + 1
    mdbg(("gather xp +%d (%s)"):format(uAmt, node))
    if ns.RefreshUI then ns.RefreshUI() end
  elseif (now - lastQuestXPAt) < 2 then
    return   -- this is the quest turn-in's own XP line; already counted via QUEST_TURNED_IN (avoid double-count)
  else
    -- OTHER: bonus objective / anything unattributed — recorded with a timestamp so it can be reviewed later
    logAttributedXP(uAmt, { t = "other" }); scheduleXPReconcile()   -- ONE attributed xp event (bonus objective / unnamed)
    local s = ns.session
    if not (s and s.running) then return end
    s.xpOther = (s.xpOther or 0) + uAmt
    s.xpOtherLog = s.xpOtherLog or {}
    s.xpOtherLog[#s.xpOtherLog + 1] = { amount = uAmt, t = time() }   -- timestamped (Other accordion children)
    mdbg(("other xp +%d"):format(uAmt))
    if ns.RefreshUI then ns.RefreshUI() end
  end
end
ns._onXPGainMsg = onXPGainMsg   -- referenced from the CHAT_MSG_COMBAT_XP_GAIN dispatch

-- ===== Kills (unified, GUID-keyed) =====
-- Every kill is ONE record keyed by npcID; the corpse GUID is the correlation key that merges three feeds:
--   • CHAT_MSG_COMBAT_XP_GAIN "X dies…"  → the kill's XP (GUID recovered from your target — the text has none)
--   • LOOT_READY + GetLootSourceInfo     → the kill's loot (also counts looted kills, incl. gray/no-XP mobs)
--   • COMBAT_LOG PARTY_KILL (opt-in)     → catches even untargeted/unlooted kills
-- markKill dedups the COUNT per corpse (whichever feed sees the GUID first counts it once); markLoot dedups the
-- loot CAPTURE separately (LOOT_READY re-fires). Record: { name, count, xp, loot={id->{link,count}}, looted }.
local function parseGUID(guid)
  if type(guid) ~= "string" then return nil, nil end
  local kind = guid:match("^(%a+)")
  local npcID = select(6, strsplit("-", guid))   -- Creature-0-srv-inst-zone-<npcID>-spawn
  -- return npcID as a NUMBER so it matches GECLoot's src.npcID (also numeric). A string/number mismatch keyed
  -- the same mob under s.kills["12345"] AND s.kills[12345] — two records (one count-0) that collided on the
  -- "kill_12345" accordion key, so clicking one toggled the other.
  return kind, (npcID and npcID ~= "" and tonumber(npcID)) or nil
end
ns._parseGUID = parseGUID

-- GUID → creature name from your current target (bounded FIFO) + the reverse (name → most-recent target GUID),
-- so the XP-message "X dies" (name only) can recover the corpse GUID it shares with the loot feed.
local guidName, guidOrder, nameGUID = {}, {}, {}
local lastTargetGUID, lastTargetName
-- PERSIST the learned creature name into the shared registry (npcID -> {name}), so it survives across sessions
-- and resolves later even with no live source — durably fixes "npc <id>" for mobs you've seen before. There's
-- no npcID->name WoW API, so the name MUST be learned live (nameplate / target); the registry is the memory.
-- STATIC creature identity from a LIVE unit (nameplate / target): type / classification / family. These are
-- stable per-npcID, so we intern them into the shared npc registry once (turns "npc 250033" into "Springpaw
-- Lynx, Beast / rare"). Guarded against WoW 12.0 secret values; nil when nothing usable is readable.
local function unitCreatureAttrs(unit)
  if not (unit and UnitExists and UnitExists(unit)) then return nil end
  local function ok(v) return (v and v ~= "" and not (issecretvalue and issecretvalue(v))) and v or nil end
  local ct  = ok(UnitCreatureType and UnitCreatureType(unit))
  local cls = ok(UnitClassification and UnitClassification(unit))
  local fam = ok(UnitCreatureFamily and UnitCreatureFamily(unit))
  if not (ct or cls or fam) then return nil end
  return { creatureType = ct, classification = cls, family = fam }
end
local function internNpc(guid, name, extra)
  if not (GECStore and GECStore.NoteNamed and name and name ~= "") then return end
  local _, npcID = parseGUID(guid)
  if npcID then GECStore.NoteNamed("npc", tonumber(npcID) or npcID, name, extra) end
end
local function onTargetChanged()
  if not (UnitExists and UnitExists("target")) or (UnitIsPlayer and UnitIsPlayer("target")) then return end
  local g, nm = UnitGUID("target"), UnitName("target")
  -- WoW 12.0: unit fields come back as "secret values" during protected actions (mouselook / TurnOrAction);
  -- comparing or using them throws "attempt to compare a secret string value". Bail if either is secret.
  if issecretvalue and (issecretvalue(g) or issecretvalue(nm)) then return end
  if not (g and nm and nm ~= "") then return end
  if not guidName[g] then
    guidOrder[#guidOrder + 1] = g
    if #guidOrder > 400 then local old = table.remove(guidOrder, 1); guidName[old] = nil end
  end
  guidName[g] = nm; nameGUID[nm] = g; lastTargetGUID, lastTargetName = g, nm
  internNpc(g, nm, unitCreatureAttrs("target"))
end
ns._onTargetChanged = onTargetChanged
-- Cache a GUID->name for EVERY mob whose nameplate appears — not just your target. This is the strong name
-- source for kills that grant no XP (max-level / Torghast mobs give no "X dies" line) and for AoE where you
-- never target each mob: you still SEE their nameplates, so we learn the name before you loot the corpse.
local function cacheUnitName(unit)
  if not (unit and UnitExists and UnitExists(unit)) then return end
  if UnitIsPlayer and UnitIsPlayer(unit) then return end
  local g, nm = UnitGUID(unit), UnitName(unit)
  if issecretvalue and (issecretvalue(g) or issecretvalue(nm)) then return end
  if not (g and nm and nm ~= "") then return end
  if not guidName[g] then
    guidOrder[#guidOrder + 1] = g
    if #guidOrder > 400 then local old = table.remove(guidOrder, 1); guidName[old] = nil end
  end
  guidName[g] = nm; nameGUID[nm] = g
  internNpc(g, nm, unitCreatureAttrs(unit))
end
ns._onNamePlateAdded = function(unit) cacheUnitName(unit) end
-- best-guess GUID for a just-killed mob named `name`: your last target if it matches, else the most-recent
-- target of that name. nil if you never targeted it (pure AoE) — that kill can't be GUID-correlated from text.
local function guidForKilledName(name)
  if name and lastTargetName == name and lastTargetGUID then return lastTargetGUID end
  return (name and nameGUID[name]) or nil
end
ns._guidForKilledName = guidForKilledName

-- two dedup sets: kill COUNT vs loot CAPTURE (a corpse counts once even though XP + loot both see its GUID;
-- its loot captures once despite LOOT_READY re-firing).
local seenKill, seenKillOrder, seenLoot, seenLootOrder = {}, {}, {}, {}
local function markKill(guid)
  if not guid or seenKill[guid] then return false end
  seenKill[guid] = true; seenKillOrder[#seenKillOrder + 1] = guid
  if #seenKillOrder > 1500 then local o = table.remove(seenKillOrder, 1); seenKill[o] = nil end
  return true
end
local function markLoot(guid)
  if not guid or seenLoot[guid] then return false end
  seenLoot[guid] = true; seenLootOrder[#seenLootOrder + 1] = guid
  if #seenLootOrder > 1500 then local o = table.remove(seenLootOrder, 1); seenLoot[o] = nil end
  return true
end

-- ensure a kill record exists for this corpse GUID; count it once (markKill). Returns the record key (npcID)
-- so the caller can attach XP / loot. `guid` is the correlation key; without it we don't count (no dedup).
local function ensureKill(guid, npcID, name)
  local id = (npcID and (tonumber(npcID) or npcID)) or guid   -- normalize to a number so string/number npcIDs key the SAME record
  if not id then return nil end
  -- No live name (no-XP / untargeted kill)? Resolve it from the persisted npc registry — a mob you've seen
  -- before (its nameplate/target learned the name) resolves durably instead of falling back to "npc <id>".
  if not (name and name ~= "") and npcID and GECStore and GECStore.Resolve then
    local row = GECStore.Resolve("npc", tonumber(npcID) or npcID)
    if row and row.name then name = row.name end
  end
  -- Persist the name into the shared registry whenever we HAVE it (combat-log destName / target name), so
  -- future untargeted kills of this mob resolve durably AND the exported _registry carries npcID→name for
  -- the server (which has no name API). Without this, instance/AoE kills log as a bare id ("npc <id>").
  if name and name ~= "" and npcID and GECStore and GECStore.NoteNamed then
    GECStore.NoteNamed("npc", tonumber(npcID) or npcID, name)
  end
  local isNew = markKill(guid)
  if isNew and ns.LogEvent then ns.LogEvent("kill", { id = id, name = name, guid = guid }) end
  local s = ns.session
  if not (s and s.running) then return id end
  s.kills = s.kills or {}
  local k = s.kills[id]
  if not k then k = { name = name, count = 0, xp = 0, cash = 0, loot = {}, looted = 0 }; s.kills[id] = k end
  if name and name ~= "" then k.name = name end
  if isNew then
    appendKillLog(id, name, guid)   -- session stream
    k.count = (k.count or 0) + 1
    s.killCount = (s.killCount or 0) + 1
    s.killLog = s.killLog or {}
    s.killLog[#s.killLog + 1] = { id = id, name = name, t = time() }
    mdbg(("kill: %s total=%d"):format(tostring(name), s.killCount))
    if ns.RefreshUI then ns.RefreshUI() end
  end
  return id
end
ns._ensureKill = ensureKill

-- COMBAT_LOG source. WoW 12.0 "Midnight" tightened taint: registering COMBAT_LOG_EVENT_UNFILTERED is REFUSED
-- whenever any tainted frame is on the call stack (co-installed Auctionator/TSM/etc. poison the session). The
-- documented Midnight fix (Rarity et al.): register from a C_Timer.After(0) callback (re-enters on a clean
-- stack via Blizzard's C-side dispatcher) with backoff RETRY. BUT in a persistently-tainted session (this
-- user's Auctionator/TSM keep a tainted frame on the stack every tick) EVERY attempt is blocked and every block
-- shows the "Interface action failed" popup — so retrying just spams popups. Therefore this is OPT-IN
-- (HaulDB.killsCombatLog, default OFF): default is the popup-free CHAT_MSG_COMBAT_XP_GAIN fallback (XP-granting
-- kills only); enabling it makes a BOUNDED number of CLEU attempts (a few popups if the session is tainted) to
-- try for EVERY kill. The frame is created here (safe); registration is deferred + gated (see ns.EnableCombatLogKills).
local clf = CreateFrame("Frame")
clf:SetScript("OnEvent", function()
  local _, sub, _, srcGUID, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
  if sub ~= "PARTY_KILL" then return end
  -- WoW 12.0: combat-log GUIDs/names are secret values in boss/M+ encounters; comparing them throws.
  if issecretvalue and (issecretvalue(srcGUID) or issecretvalue(destGUID) or issecretvalue(destName)) then return end
  if srcGUID ~= UnitGUID("player") and srcGUID ~= UnitGUID("pet") then return end   -- only your / your pet's kills
  local _, npcID = parseGUID(destGUID)
  ensureKill(destGUID, npcID, destName)   -- same GUID-deduped path as loot/XP (no double-count)
end)
local CLEU_BACKOFF = { 0, 1, 3 }   -- bounded: at most 3 attempts (=> at most 3 popups if the session is tainted)
local function tryRegisterCLEU(i)
  if clf:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED") then ns._cleuActive = true; return end
  clf:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")   -- silently no-ops (and pops the taint warning) if this tick's stack is tainted
  if clf:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED") then ns._cleuActive = true; return end
  local nextDelay = CLEU_BACKOFF[i + 1]
  if nextDelay and C_Timer and C_Timer.After then C_Timer.After(nextDelay, function() tryRegisterCLEU(i + 1) end) end
end
-- Called from PLAYER_LOGIN (if the opt-in is on) and when the option is toggled on. No-op if already registered.
function ns.EnableCombatLogKills()
  if clf:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED") then ns._cleuActive = true; return end
  if C_Timer and C_Timer.After then C_Timer.After(CLEU_BACKOFF[1], function() tryRegisterCLEU(1) end)
  else tryRegisterCLEU(1) end
end

-- ===== Loot-source: kill + loot attribution (taint-free — queue on hook, confirm on event) =====
-- On LOOT_READY, GetLootSourceInfo(slot) returns each item's source GUID(s). A Creature GUID = a corpse (a kill
-- + its loot); a GameObject GUID = a gathering node / container (gathered items). All kills funnel through the
-- unified ensureKill above, deduped by GUID, so the loot feed and the XP feed never double-count the same mob.
-- attribute a looted item to the mob that dropped it (loot-under-kills). The kill is recorded first, so its
-- s.kills entry exists.
local function recordMobLoot(id, link, count)
  local s = ns.session
  if not (s and s.running and id and link) then return end
  s.kills = s.kills or {}
  local k = s.kills[id]; if not k then return end
  k.loot = k.loot or {}
  local key = link:match("item:(%-?%d+)") or link
  local it = k.loot[key]; if not it then it = { link = link, count = 0 }; k.loot[key] = it end
  it.count = it.count + (count or 1)
  -- no separate `mobloot` LOG event: the `loot` event (AddLoot) carries ls={t=kill,npcID,guid} and Replay
  -- rebuilds this per-mob loot from it. This LIVE table update stays.
end
-- attribute a gathered item to the node it came from. `node` comes from GECLoot's classified src.node (the
-- CHAT_MSG_OPENING "You perform <skill> on <node>"); if absent, fall back to the last-seen node within the
-- window. Fishing / plain containers have no node → skip (the item is still captured as normal loot, just not
-- logged as "gathered" — no Unknown-node spam).
local function recordGatherLoot(link, count, node)
  local s = ns.session
  if not (s and s.running and link) then return end
  if not (node and node ~= "") then
    local win = (HaulDB and HaulDB.gatherLootWindowSec) or 4
    if lastGatherNode and (GetTime() - lastGatherNode.t) < win then node = lastGatherNode.node end
  end
  if not (node and node ~= "") then return end
  s.gather = s.gather or {}
  local g = s.gather[node]; if not g then g = { name = node, loot = {} }; s.gather[node] = g end
  local key = link:match("item:(%-?%d+)") or link
  local it = g.loot[key]; if not it then it = { link = link, count = 0 }; g.loot[key] = it end
  it.count = it.count + (count or 1)
  -- no separate `gatherloot` LOG event: the `loot` event carries ls={t=gather,node} and Replay rebuilds this
  -- per-node loot from it. This LIVE table update stays.
end

-- a money loot slot's source GUID is the corpse. We remember which mob the money belongs to and let onLootMoney
-- (which parses the amount from CHAT_MSG_MONEY) attribute it. `pendingMobCash` is consumed by ns._attribMobCash.
local pendingMobCash   -- { id, t }
-- Updates the LIVE per-mob cash and RETURNS the mob-cash `ls` descriptor so onLootMoney can log ONE `coin`
-- event tagged ls=kill (which Replay counts in the total AND attributes to the mob — like a loot event).
-- No separate log event here anymore.
function ns._attribMobCash(amount)
  if not (amount and amount > 0 and pendingMobCash) then return nil end
  if (GetTime() - (pendingMobCash.t or 0)) > 3 then pendingMobCash = nil; return nil end
  local s = ns.session
  local k = s and s.running and s.kills and s.kills[pendingMobCash.id]
  if k then k.cash = (k.cash or 0) + amount end   -- LIVE per-mob cash rollup
  -- include the mob NAME (like loot events do) so the coin row reads + correlates by name, not just id/guid
  local name = (pendingMobCash.guid and guidName[pendingMobCash.guid]) or (k and k.name) or nil
  return { t = "kill", npcID = pendingMobCash.id, guid = pendingMobCash.guid, name = name }
end
-- CONSUME GECLoot's source-classified callbacks (unified-schema Phase 2 — the shared looter). GECLoot reads
-- GetLootSourceInfo + the recent action context and fires LOOT_ITEM/LOOT_MONEY(info.src) as each slot is looted
-- (LOOT_SLOT_CLEARED), so Haul no longer runs its OWN GetLootSourceInfo pass. info.src = {t, guid, npcID, objID,
-- node}. Routing:
--   kill/pickpocket  → count the kill (ensureKill, GUID-deduped) + attribute the drop (recordMobLoot) + the
--                      looted flag once per corpse (markLoot).
--   herb/mining/gather → attribute to the node (recordGatherLoot with src.node).
--   fish/chest/container/unknown/nil → NO kill/gather attribution; the item is still captured by Capture.lua
--                      (CHAT_MSG_LOOT). So a missed/absent callback degrades to "item counted, source unknown"
--                      rather than losing loot — the item COUNT never depended on this path.
-- loot SOURCE per itemID, stashed from GECLoot's LOOT_ITEM (which fires on LOOT_SLOT_CLEARED, just BEFORE the
-- CHAT_MSG_LOOT that AddLoot captures). AddLoot reads it to stamp `ls` on the item record — a separate axis
-- from `from` (mail/craft acquisition). Short freshness window; keyed by id so it self-bounds.
ns._lootSrc = ns._lootSrc or {}
local function onGECLootItem(_, info)
  if not (info and info.link) then return end
  local src = info.src
  if not src then return end
  -- stash the FULL attribution descriptor (not just the type) so AddLoot's `loot` event carries it: the log
  -- then reconstructs the per-mob / per-node breakdown from the SAME event (collapse: one loot event, no
  -- separate mobloot/gatherloot). guid drives the derived `looted` count; name from the target cache.
  if src.t and info.itemID then
    ns._lootSrc[info.itemID] = { t = src.t, npcID = src.npcID, guid = src.guid, node = src.node, objID = src.objID,
      name = src.guid and guidName[src.guid] or nil, at = GetTime() }
  end
  local t, n = src.t, info.quantity or 1
  if t == "kill" or t == "pickpocket" then
    -- pass the REAL name only (from the target-GUID cache) or nil — NEVER an "npc <id>" placeholder, which
    -- would clobber the real name the "X dies" XP message already set (ensureKill sets k.name on every call).
    -- A nil name → the display falls back to "npc <id>", and the XP path fills the real name in.
    local id = ensureKill(src.guid, src.npcID, guidName[src.guid])
    recordMobLoot(id, info.link, n)
    if src.guid and markLoot(src.guid) then
      local s = ns.session
      local k = s and s.running and s.kills and s.kills[id]
      if k then k.looted = (k.looted or 0) + 1 end
      -- no separate `looted` LOG event: Replay derives looted from distinct corpse GUIDs on the mob's loot/coin
      -- events (their ls.guid). The LIVE count above stays exact.
    end
  elseif t == "herb" or t == "mining" or t == "gather" then
    recordGatherLoot(info.link, n, src.node)
    if src.objID and src.node and GECStore and GECStore.NoteNamed then GECStore.NoteNamed("object", src.objID, src.node) end
  end
end
-- Money slot: remember the mob so onLootMoney (CHAT_MSG_MONEY) attributes the amount to it.
local function onGECLootMoney(_, info)
  local src = info and info.src
  if src and (src.t == "kill" or src.t == "pickpocket") and src.npcID then
    pendingMobCash = { id = src.npcID, guid = src.guid, t = GetTime() }   -- guid → derived `looted` count
  end
end
if GECLoot and GECLoot.RegisterCallback then
  GECLoot.RegisterCallback(ns, "LOOT_ITEM", onGECLootItem)
  GECLoot.RegisterCallback(ns, "LOOT_MONEY", onGECLootMoney)
  if GECLoot.Observe then GECLoot:Observe("Haul") end   -- classify + fire even when fast-loot is off
end

function ns.SetTracking(on)
  local s = ns.session; if not s then return end
  on = not not on
  if on == s.running then return end
  if on then
    s.t0 = GetTime(); s.running = true
    if s.sid and ns.LogResume then ns.LogResume(s.sid) end
  else
    s.accum = s.accum + (GetTime() - s.t0)
    s.running = false   -- gold accrues only while running (CHAT_MSG_MONEY checks it)
    if s.sid and ns.LogPause then ns.LogPause(s.sid) end
  end
  if ns.ApplyHeaderStyle then ns.ApplyHeaderStyle() end   -- repaint the paused/active background tint
  if ns.RefreshUI then ns.RefreshUI() end
end

function ns.ToggleTracking()
  if ns.session then ns.SetTracking(not ns.session.running) end
end

function ns.IsTracking()
  return ns.session and ns.session.running or false
end

-- Where the player is right now: zone, subzone, instance, map id, and x/y coords.
-- Stored on every loot event so the exported drop list carries full location.
local function CurrentLocation()
  local map = C_Map and C_Map.GetBestMapForUnit("player")
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local x, y = nil, nil
  if pos then
    local px, py = pos:GetXY()
    if px then x = tonumber(string.format("%.2f", px * 100)) end
    if py then y = tonumber(string.format("%.2f", py * 100)) end
  end
  local mapName
  if map and C_Map and C_Map.GetMapInfo then
    local mi = C_Map.GetMapInfo(map); mapName = mi and mi.name
  end
  local loc = { zone = GetZoneText(), map = map, mapName = mapName, x = x, y = y }
  local sub = GetSubZoneText and GetSubZoneText()
  if sub and sub ~= "" then loc.subzone = sub end
  local inInst, instType = IsInInstance()
  if inInst and instType ~= "none" then
    loc.instanceType = instType
    if GetInstanceInfo then loc.instance = (GetInstanceInfo()) end
  end
  return loc
end

-- the FULL zone path (continent > zone > subzone), as the place registry stores it — so the session
-- display always shows the complete path, not just GetZoneText's most-specific name (e.g. "Slayer's Rise").
local function ZonePathNow()
  local cascade = ns.LocationCascade and ns.LocationCascade()
  if not cascade or #cascade == 0 then return GetZoneText() or "" end
  local parts = {}
  for _, c in ipairs(cascade) do if c.name and c.name ~= "" then parts[#parts + 1] = c.name end end
  return (#parts > 0) and table.concat(parts, " > ") or (GetZoneText() or "")
end

-- Append a money row to the live session's s.log (chronological List view). Only while running.
-- `from` tags the origin shown in the List ("mail" for mail gold; nil for looted/quest). Vendor money
-- is NEVER appended here (it's log-only — see onPlayerMoney). Money rows are discriminated from item
-- rows by their `kind` field (item rows carry `id`/`link` instead).
function appendMoneyLog(kind, amount, from, ls)
  local s = ns.session
  if not (amount and amount > 0 and s and s.running) then return end
  s.log = s.log or {}
  s.log[#s.log + 1] = { kind = kind, amount = amount, from = from, src = ls, t = time(), loc = CurrentLocation() }
end
-- rep change (signed) into the session log
function appendRepLog(faction, amount)
  local s = ns.session
  if not (faction and amount and amount ~= 0 and s and s.running) then return end
  s.log = s.log or {}
  s.log[#s.log + 1] = { kind = "rep", f = faction, amount = amount, t = time(), loc = CurrentLocation() }
end
-- currency change (signed) into the session log. Gains AND spends are recorded for the stream; only
-- gains are surfaced (see onCurrencyUpdate / Replay) — spends are log-only, like vendor money.
function appendCurrencyLog(id, amount)
  local s = ns.session
  if not (id and amount and amount ~= 0 and s and s.running) then return end
  s.log = s.log or {}
  s.log[#s.log + 1] = { kind = "currency", cid = id, amount = amount, t = time(), loc = CurrentLocation() }
end
-- profession skill-up into the session log. Skill-ups only ever go up; recorded for the chronological
-- stream + reconstruction. `name`/`prof`/`level` are captured so the display resolves even offline.
function appendProfLog(id, amount, name, prof, level)
  local s = ns.session
  if not (id and amount and amount > 0 and s and s.running) then return end
  s.log = s.log or {}
  s.log[#s.log + 1] = { kind = "skill", pid = id, amount = amount, name = name, prof = prof, lvl = level, t = time(), loc = CurrentLocation() }
end
-- experience into the session log — all kind="xp". A row with no `src` is the authoritative TOTAL; a row with
-- `src` (t=kill/gather/disc/quest/other + name/node/zone/title) is a labeled subset. All go in the stream so a
-- saved session's drops reconstruct the XP breakdown.
-- session-log XP row. `src` nil => the authoritative TOTAL (a PLAYER_XP delta); `src` set => a labeled subset
-- (kill/gather/disc/quest/other) that Replay routes to the breakdown ONLY. All rows are kind="xp".
function appendXPLog(amount, ls)
  local s = ns.session
  if not (amount and amount > 0 and s and s.running) then return end
  s.log = s.log or {}
  s.log[#s.log + 1] = { kind = "xp", amount = amount, src = ls, t = time(), loc = CurrentLocation() }
end
-- a kill into the session log (kind "kill"; carries npcID + display name + corpse GUID for the Kills views
-- and full reconstruction).
function appendKillLog(id, name, guid)
  local s = ns.session
  if not (id and s and s.running) then return end
  s.log = s.log or {}
  s.log[#s.log + 1] = { kind = "kill", id = id, name = name, guid = guid, t = time(), loc = CurrentLocation() }
end
-- Per-mob / per-node attribution events (mobloot / mobcash / looted / gatherloot). Written to BOTH the always-on
-- log (reconstruct-from-log) AND the session drop log (saved-session snapshots), so the Data tab rebuilds the
-- full Kills + gather detail (XP, cash, loot-under-kills, unlooted, gathered items) with GUIDs/ids intact.
function ns._logMobEvent(kind, fields)
  if ns.LogEvent then ns.LogEvent(kind, fields) end
  local s = ns.session
  if not (s and s.running) then return end
  s.log = s.log or {}
  -- location on EVERY session-log event, same as every other appender here. This path was the one exception:
  -- gather/mob events (mobloot/gatherloot/mobcash/looted) had no `loc`, so saved-session gather/kill detail
  -- couldn't be placed on a map. RULE: every data point carries a location. Long-term this moves into the
  -- shared store stamp so it can never be forgotten again — see [[node-map-data]].
  local e = { kind = kind, t = time(), loc = CurrentLocation() }
  if fields then for k, v in pairs(fields) do e[k] = v end end
  s.log[#s.log + 1] = e
end
-- vendor transaction into the session log (log-only: recorded for the stream, never shown/counted)
function appendVendorLog(vt, amount)
  local s = ns.session
  if not (amount and amount > 0 and s and s.running) then return end
  s.log = s.log or {}
  s.log[#s.log + 1] = { kind = "vendor", vt = vt, amount = amount, from = "vendor", t = time(), loc = CurrentLocation() }
end
-- a COMPLETE mail-gold pickup into the session log (label/sender/subject/seq), so Replay rebuilds the
-- itemized Mailbox lines from s.log alone — the log is the source of truth for the Mailbox sub-group.
function appendMailGoldLog(amount, label, sender, subject, seq)
  local s = ns.session
  if not (amount and amount > 0 and s and s.running) then return end
  s.log = s.log or {}
  s.log[#s.log + 1] = { kind = "mail", amount = amount, from = "mail", label = label,
    sender = sender, subject = subject, seq = seq, t = time(), loc = CurrentLocation() }
end

-- Three location tiers for the {zone.*} tokens: region (continent) / zone / sub-zone.
-- In an instance GetZoneText() returns the instance name, which is the right "zone".
function ns.ZoneTiers()
  local sub  = (GetSubZoneText and GetSubZoneText()) or ""
  local zone = GetZoneText() or ""
  if sub == zone then sub = "" end                 -- avoid "Zone : Zone"
  local region, mapID, guard = "", C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"), 0
  while mapID and guard < 12 do
    guard = guard + 1
    local info = C_Map.GetMapInfo(mapID)
    if not info then break end
    if Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Continent then region = info.name or ""; break end
    mapID = info.parentMapID
    if not mapID or mapID == 0 then break end
  end
  return region, zone, sub
end

-- Add looted items to the session (called from Capture). `src` (optional) is the
-- acquisition source: nil = normal loot, "mail" / "craft" (stored on the entry as `from`).
-- Mail/craft entries use a composite key (id.."@"..<acquire>) so they bucket separately and never merge with loot;
-- the entry's .id stays the numeric item ID for EvalItem/pricing/exclude.
function ns.AddLoot(itemLink, count, src)
  if not itemLink then return end
  local id = GetItemInfoInstant(itemLink)
  if not id then return end
  count = count or 1
  -- Freeze the POINT-IN-TIME valuation so the Data view can be reproduced from the log alone (prices
  -- fluctuate, so the resolved value must be captured here, not recomputed later). Embedded on BOTH the
  -- always-on event log AND the per-session drop log so each snapshot is self-reconstructable:
  --   val = TOTAL stack value (unit×count, copper)   ps = price source+metric used (e.g. "tsm:dbminbuyout")
  --   q   = quality                                  b  = soulbound (so gray/bound category rebuilds offline)
  local nm, _, q, _, _, _, _, _, _, _, sell, _, _, bindType = GetItemInfo(itemLink)
  -- gray (Poor) and bind-on-pickup items are ALWAYS vendor-priced here, mirroring EvalItem/ComputeStats: an
  -- AH/TSM price is meaningless for them, and a mis-listed gray can hand back a garbage TSM DBMinBuyout (e.g.
  -- an "all nines" buyout). Forcing vendor AT CAPTURE keeps the FROZEN stored value sane everywhere it's used
  -- (raw log, reconstructed sessions, export) — GetUnitValue only falls back to vendor when TSM has NO value,
  -- so it would otherwise bake the junk price in for a gray that happens to have one.
  local v, ps
  if q == 0 or bindType == 1 then
    v, ps = (sell or 0), "vendor"
  else
    local psUsed
    if ns.GetUnitValue then v, psUsed = ns.GetUnitValue(itemLink, sell) end
    ps = psUsed or (ns.PriceSourceLabel and ns.PriceSourceLabel()) or nil   -- ACTUAL source used
  end
  local b = (bindType == 1) or nil
  -- loot SOURCE (fish/kill/gather/chest/…) from GECLoot, distinct from `from` (acquisition context). GECLoot's
  -- LOOT_ITEM stashed it in ns._lootSrc[id] a beat ago (LOOT_SLOT_CLEARED fires before this CHAT_MSG_LOOT).
  local lse = ns._lootSrc and ns._lootSrc[id]
  local fresh = lse and (GetTime() - lse.at) < 3
  local lsDesc = fresh and { t = lse.t, npcID = lse.npcID, guid = lse.guid, node = lse.node, name = lse.name } or nil
  -- always-on `loot` event, CANONICAL field vocabulary: name/count/val/src (no info record reaches this
  -- CHAT_MSG_LOOT path, so we map scalars directly — `name` from the GetItemInfo fetch above). `val` = the
  -- TOTAL stack value (unit v × count), signed; `v` (unit) rides along in extra for display. `src` carries the
  -- full loot-source DESCRIPTOR (Replay derives the per-mob/node breakdown from it); `from` tags the acquisition
  -- source ("mail"/"craft"), absent for normal loot. `b`/`ps`/`from` are Haul extras (ride to server `extra`).
  -- No unit `v` field: `val` is the TOTAL stack value; unit = `val/count` if ever needed (no short-name keys).
  if ns.LogEvent then ns.LogEvent("loot", { id = id, name = nm, link = itemLink, count = count, q = q, src = lsDesc,
    val = (v or 0) * count, from = src, b = b, ps = ps }) end
  if GECStore and GECStore.Note then GECStore.Note("item", id) end   -- snapshot id->name into the shared registry (uniform display + export)
  -- vendor purchases are LOG-ONLY: never added to the session items/log/waypoints/notify, never
  -- counted, never shown in the window. (Fixes the bug where a bought item showed up as loot.)
  if src == "vendor" then return end
  local s = ns.session
  if not s or not s.running then return end
  local key = src and (id .. "@" .. src) or id
  local e = s.items[key]
  if e then e.count = e.count + count
  else
    s.seq = (s.seq or 0) + 1
    -- entry `from` = ACQUISITION context (nil/"mail"/"craft"), matching s.log's `from`; the loot-SOURCE type
    -- is not stored here (Replay rebuilds it into `src` from the drop-log `src` descriptor's `.t` for display).
    s.items[key] = { id = id, link = itemLink, count = count, seq = s.seq, from = src }
  end
  local loc = CurrentLocation()
  -- chronological loot log: one entry per loot event, with full location (drives the List view; the
  -- location + frozen value/source ride along for the exported drop list and offline reconstruction)
  s.log = s.log or {}
  s.log[#s.log + 1] = { id = id, link = itemLink, count = count, t = time(), loc = loc, from = src, val = (v or 0) * count, q = q, b = b, ps = ps, src = lsDesc }
  -- location waypoint with this loot's contribution (value computed lazily)
  s.waypoints[#s.waypoints + 1] = {
    t = time(), map = loc.map, x = loc.x, y = loc.y, zone = ZonePathNow(), id = id, count = count,
  }
  -- (removed: the last-captured item is no longer force-flashed in the notification line — it's available as
  -- a {loot.last} token to place wherever the user wants; that spot by the category button is freed for a
  -- future sort-order button. Session events — new/resume/merge/set-aside — still use ns.Notify.)
end

---------------------------------------------------------------------- stats --
-- Evaluate one looted item: its name, quality, vendor/AH unit value, category
-- ("gray"/"bound"/nil), display mode (show/merge/ignore), and excluded flag.
-- Shared by the aggregated (Collection) and chronological (List) row builders.
local function EvalItem(id, link, count)
  local name, _, quality, _, _, _, _, _, _, _, sellPrice, _, _, bindType = GetItemInfo(link)
  quality = quality or 1
  -- "can only vendor" categories: gray (Poor) and bind-on-pickup, always vendor-
  -- priced (AH price is meaningless for them).
  local cat
  if quality == 0 then cat = "gray"
  elseif bindType == 1 then cat = "bound" end
  local mode = (cat == "gray" and HaulDB.graysMode)
            or (cat == "bound" and HaulDB.boundMode) or "show"
  local unit = cat and (sellPrice or 0) or (ns.GetUnitValue(link, sellPrice) or 0)
  return name, quality, unit, cat, mode, (HaulDB.excluded[id] and true or false)
end
ns.EvalItem = EvalItem

-- Build the frozen price snapshot for a session at CLOSE (spec §3.3): { [itemID] = { unit, source } }
-- for every item the session captured, priced ONCE here client-side (gray/bound → vendor). This is the
-- only item price data the server sees; value is the pure join count × unit. Handed to Session:Close.
function ns.BuildPriceSnapshot(s)
  local prices = {}
  if not (s and ns.Replay) then return prices end
  local rebuilt = ns.Replay.Rebuild(s.log or {}) or { items = {} }
  for _, e in ipairs(rebuilt.items) do
    local id = e.id
    if id and not prices[id] and e.link then
      local _, _, quality, _, _, _, _, _, _, _, sellPrice, _, _, bindType = GetItemInfo(e.link)
      quality = quality or 1
      local unit, source
      if quality == 0 or bindType == 1 then       -- gray / bind-on-pickup → vendor (AH price is meaningless)
        unit, source = sellPrice or 0, "vendor"
      else
        unit, source = ns.GetUnitValue(e.link, sellPrice)
      end
      prices[id] = { unit = math.floor(unit or 0), source = source or "vendor" }
    end
  end
  return prices
end

-- Returns the live computed session stats + sorted item rows (Collection view).
function ns.ComputeStats()
  local s = ns.session
  local counted, gross, itemCount, notable = 0, 0, 0, 0
  local rows, thr = {}, HaulDB.notableQuality or 2
  local exMode = HaulDB.excludedMode or "show"
  -- STRUCTURE comes from the session log (the single source of truth) via Replay; the ACTIVE session
  -- prices it LIVE here (EvalItem). The one-off `keep` (mail/craft include) is overlay state on the
  -- session cache (s.items / s.mailGoldLog), looked up by key/seq — everything else is rebuilt.
  local rebuilt = (s and s.log and ns.Replay and ns.Replay.Rebuild(s.log)) or { items = {}, mailGoldLog = {} }
  local sItems = (s and s.items) or {}
  for _, e in ipairs(rebuilt.items) do
    local id = e.id
    local name, quality, unit, cat, mode, excluded = EvalItem(id, e.link, e.count)
    local from = e.from   -- acquire: nil loot / "mail" / "craft"
    local key = e.key
    local keep = (sItems[key] and sItems[key].keep) and true or false
    -- ignore = drop entirely; an excluded item obeys excludedMode, which wins over its display mode.
    if not ((cat and mode == "ignore") or (excluded and exMode == "ignore")) then
      local total = unit * e.count
      -- mail-collected loot is informational (Haul's Mail category), NEVER in gross or counted; it still
      -- gets a row below so the Mail category shows it. Matches Resolve/Replay. Craft keeps its one-off keep.
      if from ~= "mail" then
        gross = gross + total
        local inHaul
        if from == "craft" then inHaul = keep
        else inHaul = not excluded end
        if inHaul then counted = counted + total end
      end
      itemCount = itemCount + e.count
      if quality >= thr then notable = notable + e.count end
      -- acquire grouping (mail/craft) wins over gray/bound; loot keeps its merge/excluded marker.
      local merged
      if not from then
        if excluded then merged = (exMode == "merge") and "excluded" or nil
        else merged = (cat and mode == "merge") and cat or nil end
      end
      rows[#rows + 1] = {
        id = id, link = e.link, name = name, quality = quality,
        count = e.count, unit = unit, total = total, excluded = excluded,
        cat = cat, merged = merged, seq = e.seq, from = from, keep = keep, key = key, src = e.src,
      }
    end
  end
  local coin = ns.Coin()
  -- mail gold rebuilt from the log (label/amount/seq); the one-off `keep` is overlaid from the cache.
  -- Each kept row folds into coin/counted; un-kept stays out of gross too (it wasn't looted) — the
  -- Mailbox bucket sums its own rows in Window.lua, so it still totals.
  local mgKeep = {}
  if s and s.mailGoldLog then for _, e in ipairs(s.mailGoldLog) do if e.seq then mgKeep[e.seq] = e.keep and true or false end end end
  local mailGoldRows = {}
  local mailGoldTotal = 0
  for _, e in ipairs(rebuilt.mailGoldLog) do
    local amt = e.amount or 0
    local keep = (e.seq and mgKeep[e.seq]) and true or false
    mailGoldTotal = mailGoldTotal + amt
    mailGoldRows[#mailGoldRows + 1] = { amount = amt, label = e.label, seq = e.seq, keep = keep }
  end
  -- mail gold is informational (Haul's Mail category) — NOT folded into coin/counted (mailGoldRows are
  -- built above for that category). Matches Resolve/Replay: session value is looted coin only.
  counted = counted + coin
  gross = gross + coin
  -- "% of drops": each area-drop's share of the captured count. Base EXCLUDES mail/craft (not area
  -- drops); it still includes gray/bound/excluded (you did get them). Per-row pct set on those rows;
  -- dropBase is returned so the bucket headers can show a group %.
  local dropBase = 0
  for _, r in ipairs(rows) do if r.from ~= "mail" and r.from ~= "craft" then dropBase = dropBase + (r.count or 0) end end
  if dropBase > 0 then
    for _, r in ipairs(rows) do
      if r.from ~= "mail" and r.from ~= "craft" then r.pct = (r.count or 0) / dropBase * 100 end
    end
  end
  local sortBy = HaulDB.sortBy or "value"
  table.sort(rows, function(a, b)
    local am, bm = a.merged ~= nil, b.merged ~= nil
    if am ~= bm then return not am end       -- merged lines sink to the bottom
    if a.excluded ~= b.excluded then return not a.excluded end
    if sortBy == "name" then return (a.name or "") < (b.name or "")
    elseif sortBy == "time" then return (a.seq or 0) < (b.seq or 0)
    elseif sortBy == "count" then
      if (a.count or 0) ~= (b.count or 0) then return (a.count or 0) > (b.count or 0) end
      return (a.total or 0) > (b.total or 0)   -- ties broken by value
    else return (a.total or 0) > (b.total or 0) end
  end)
  local hours = math.max(ns.Elapsed() / 3600, 1 / 3600)
  local xp = (ns.session and ns.session.xp) or 0
  return {
    elapsed = ns.Elapsed(), counted = counted, gross = gross, coin = coin,
    loot = counted - coin,   -- non-excluded item value only (haul minus gold)
    mailGold = mailGoldTotal, mailGoldRows = mailGoldRows,
    vendor = rebuilt.vendor or { sell = 0, buy = 0, repair = 0 },   -- Vendor category ledger (informational)
    itemCount = itemCount, notable = notable, dropBase = dropBase,
    goldPerHour = counted / hours, grossPerHour = gross / hours,
    xp = xp, xpPerHour = ns.PerHour(xp),
    tokenPct = ns.GetTokenPct and ns.GetTokenPct(counted) or nil,
    rows = rows,
  }
end

-- Universal per-hour efficiency facet: rate = quantity / elapsed-hours, over ANY accumulating session
-- quantity (gold, rep, currency, xp, kills, skill-ups). Designed once here so every trackable's /hr uses
-- the same clamped denominator (>= 1/3600 h) instead of a bespoke calc per type.
function ns.PerHour(qty)
  local hours = math.max(ns.Elapsed() / 3600, 1 / 3600)
  return (tonumber(qty) or 0) / hours
end

-- Build a ComputeStats-shaped { rows, dropBase, mailGoldRows } from a SAVED session `h`, so the live
-- window's collection builders can render it (the Data-tab overhaul). Reuses h.items (already row-shaped),
-- resolves any missing quality/category LIVE from the item link (reconstructed items often lack them),
-- computes dropBase + per-row pct, and rebuilds the mail-gold rows. Sorted by HaulDB.dataSortBy.
function ns.SnapshotStats(h)
  local rows, dropBase = {}, 0
  for _, it in ipairs((h and h.items) or {}) do
    local quality, cat = it.quality, it.cat
    if (not quality or not cat) and it.link then
      local _, _, q, _, _, _, _, _, _, _, _, _, _, bindType = GetItemInfo(it.link)
      quality = quality or q
      if not cat then if q == 0 then cat = "gray" elseif bindType == 1 then cat = "bound" end end
    end
    rows[#rows + 1] = { id = it.id, link = it.link, name = it.name, quality = quality, count = it.count,
      unit = it.unit, total = it.total, excluded = it.excluded, cat = cat, from = it.from, src = it.src,
      keep = it.keep, seq = it.seq }
    if it.from ~= "mail" and it.from ~= "craft" then dropBase = dropBase + (it.count or 0) end
  end
  if dropBase > 0 then
    for _, r in ipairs(rows) do
      if r.from ~= "mail" and r.from ~= "craft" then r.pct = (r.count or 0) / dropBase * 100 end
    end
  end
  local sortBy = HaulDB.dataSortBy or "value"
  table.sort(rows, function(a, b)
    if a.excluded ~= b.excluded then return not a.excluded end
    if sortBy == "name" then return (a.name or "") < (b.name or "")
    elseif sortBy == "count" then
      if (a.count or 0) ~= (b.count or 0) then return (a.count or 0) > (b.count or 0) end
      return (a.total or 0) > (b.total or 0)
    else return (a.total or 0) > (b.total or 0) end
  end)
  local mailGoldRows = {}
  for _, e in ipairs((h and h.mailGoldLog) or {}) do
    mailGoldRows[#mailGoldRows + 1] = { amount = e.amount, label = e.label, seq = e.seq, keep = e.keep }
  end
  return { rows = rows, dropBase = dropBase, mailGoldRows = mailGoldRows }
end

-- Chronological loot log as display rows, newest first (List view). One row per
-- loot event; no aggregation. Respects "ignore" but not "merge" (it's a log).
-- Session-log kinds that ARE money (render as Loot-List money rows). Container gold is kind "coin"
-- with from="container", so it's covered here. All other kinds (rep/vendor/kills/loot-source tracking)
-- are record-only and must NOT appear as money rows.
local MONEY_KINDS = { coin = true, mail = true }   -- collapsed: quest coin is `coin`+src.t=quest; mail gold is `mail`
function ns.LogRows()
  local s = ns.session
  local rows = {}
  if not s or not s.log then return rows end
  local exMode = HaulDB.excludedMode or "show"
  for i = #s.log, 1, -1 do
    local ev = s.log[i]
    if ev.kind then
      local k = ev.kind
      -- Only actual MONEY kinds render as money rows in the Loot List. Everything else with a `kind`
      -- (rep/vendor, plus the kills/loot-source tracking kinds kill/mobloot/mobcash/looted/xpkill/…)
      -- lives in the session stream for the record + Replay but is NOT a Loot-List row — otherwise the
      -- non-money kinds (no `ev.amount`) would each show as a bogus "money 0" line.
      -- each coin gain is now ONE event (mob coin carries src.t=kill but IS the real coin), so all money kinds
      -- render as a List line.
      if MONEY_KINDS[k] then
        rows[#rows + 1] = { money = true, kind = k, amount = ev.amount or 0, from = ev.from, src = ev.src }
      end
    elseif ev.id then
      local name, quality, unit, cat, mode, excluded = EvalItem(ev.id, ev.link, ev.count)
      if not ((cat and mode == "ignore") or (excluded and exMode == "ignore")) then
        rows[#rows + 1] = {
          id = ev.id, link = ev.link, name = name, quality = quality,
          count = ev.count, unit = unit, total = unit * ev.count, excluded = excluded,
          cat = cat, src = ev.src and ev.src.t,   -- loot-source column icon type (fish/kill/gather/container)
        }
      end
    end
  end
  return rows
end

------------------------------------------------------------------- controls --
function ns.Reset()
  -- Banking to Saved Sessions ALWAYS happens now — we never want a "wasn't collecting" gap.
  -- Delete unwanted runs from the Data tab later; editing comes later too.
  if ns.SessionHasData() then
    ns.BankSession()
    ns.Print("session banked to history (" .. #HaulDB.history .. " saved)")
  end
  -- Close the current run with a `stop` marker FIRST (every `start` gets a matching `stop`).
  if ns.session and ns.session.sid and ns.LogStop then ns.LogStop(ns.session.sid) end

  if HaulDB.reloadBeforeNewSession and ns.RequestReload then
    -- Reset-with-reload = STOP -> RELOAD -> START. The fresh session is born on LOAD
    -- (RestoreOrNew -> NewSession), so we must NOT create one here: a pre-reload
    -- NewSession() lays a `start` the reload then replaces, orphaning it (start, no
    -- stop) and churning the sid twice. Clear the live run so load starts exactly one
    -- clean session after the reload.
    ns.session = nil
    HaulDB.liveSession = nil
    ns.Print("new session — reloading…"); ns.Notify("|cff80ff80new session|r")
    if not ns.RequestReload() then
      -- reload deferred (in combat / casting / looting): keep tracking with a fresh
      -- session so income isn't dropped in the gap. It resumes by sid across the
      -- eventual reload, so there's still no orphan.
      ns.session = NewSession()
      if ns.RefreshUI then ns.RefreshUI() end
    end
    return
  end

  -- No reload: stop the old run, start a fresh one immediately.
  ns.session = NewSession()
  if ns.RefreshUI then ns.RefreshUI() end
  ns.Print("new session"); ns.Notify("|cff80ff80new session|r")
end

local function SnapshotSession()
  local st = ns.ComputeStats()
  local s = ns.session or {}
  local sid = s.sid
  -- HaulData.sessions[sid] is now the FROZEN §3.3 record (startedAt/closedAt), written by the controller
  -- at close; during a live bank it may not exist yet, so timing falls back to the live session.
  local srow = sid and HaulData and HaulData.sessions and HaulData.sessions[sid]
  -- a unique id PER SNAPSHOT. sid is per-SESSION and a run can be saved many times (so sids repeat
  -- across Data-tab rows) — uid is a fresh global counter each save, so every row's #id is distinct.
  HaulDB.nextUid = (HaulDB.nextUid or 0) + 1
  return {
    startedAt = s.startedAt, durationSec = math.floor(st.elapsed),
    establishedAt = s.establishedAt or s.startedAt,
    -- log-span linkage (Spec 1 §5.4): ties this snapshot back to its log session
    sid = sid, uid = HaulDB.nextUid, logStart = s.startedAt, logStop = srow and srow.closedAt or nil,
    merges = s.merges,
    -- Data-tab row provenance TAG: "resumed" if the fold(s) came from a Resume, else "merged".
    -- (Resume records a via="resume" entry; Merge a via="merge" one.) nil when neither.
    merged = (function()
      if not (s.merges and #s.merges > 0) then return nil end
      for _, m in ipairs(s.merges) do if (m.via or "merge") ~= "resume" then return "merged" end end
      return "resumed"
    end)(),
    -- WHO ran this — read off the session (bound at creation), NOT the current
    -- char. Sessions persist across relog, so the live player at save/reset time
    -- may not be who collected. Fall back only for pre-fix or "?" sessions.
    character = (s.character and s.character ~= "?" and s.character) or ns.CharName(),
    class = s.class or ns.CharClass(),   -- classFile, for class-colored names
    gen = (HaulData and HaulData._gen) or 0,   -- write-generation banked in; on disk once a later gen loads

    countedValue = math.floor(st.counted), grossValue = math.floor(st.gross),
    coin = math.floor(st.coin), itemCount = st.itemCount,
    notable = st.notable, goldPerHour = math.floor(st.goldPerHour),
    tokenPct = st.tokenPct, priceSource = HaulDB.priceSource,
    -- mail gold (v2): the itemized log round-trips so a restored/merged session still
    -- shows each Mailbox gold line + its per-entry include state. Copied verbatim.
    mailGoldLog = (function()
      local t = {}
      for _, e in ipairs((s.mailGoldLog) or {}) do
        t[#t + 1] = { amount = math.floor(e.amount or 0), label = e.label,
                      sender = e.sender, subject = e.subject, seq = e.seq, keep = e.keep or nil }
      end
      return t
    end)(),
    items = (function()
      local t = {}
      for _, r in ipairs(st.rows) do
        t[#t + 1] = { id = r.id, link = r.link, name = r.name or ns.NameFromLink(r.link), quality = r.quality,
                      count = r.count, unit = math.floor(r.unit or 0),
                      total = math.floor(r.total), excluded = r.excluded,
                      cat = r.cat, from = r.from, src = r.src, keep = r.keep or nil }
      end
      return t
    end)(),
    -- full chronological drop list with per-event location (zone/subzone/instance
    -- /map/x/y) so the exported JSON carries where every item came from
    drops = s.log,
    waypoints = s.waypoints,
  }
end
ns.SnapshotSession = SnapshotSession

-- The displayed 6-digit id for a snapshot, hashed from its unique per-snapshot `uid` (the hash is a
-- bijection over the counter range, so distinct uids never collide; it just makes the codes look
-- distinct rather than sequential). Shown on each Data-tab row and the matching merge line.
function ns.SessionUID(uid)
  if not uid then return "------" end
  return string.format("%06d", (uid * 2654435761) % 1000000)
end

-- Reconstruct a session's aggregated data from the event log ALONE (offline-reproducible) via
-- ns.Replay. Prefers the session's own complete drop log (a saved snapshot's `drops`, or the live
-- s.log) when available; otherwise filters the global HaulData.log by sid (note: that stream is
-- pruned to logMaxEntries, so older sessions may be incomplete there). Returns the rebuilt layout.
-- One session's lifecycle MARKERS (start/stop/pause/resume/fold/exclude) from the split markers stream.
-- Replay needs these to derive timing + character; they no longer live inline in the events stream.
function ns.SidMarkers(sid)
  local out = {}
  local ms = HaulData and HaulData.streams and HaulData.streams.markers
  if ms then for _, m in ipairs(ms) do if m.sid == sid then out[#out + 1] = m end end end
  return out
end

function Haul.RebuildFromLog(sid)
  if not ns.Replay then return nil end
  local mk = ns.SidMarkers(sid)   -- timing + character come from the markers stream now
  -- live session
  if ns.session and ns.session.sid == sid and ns.session.log then
    return ns.Replay.Rebuild(ns.session.log, { priceSource = ns.PriceSourceLabel and ns.PriceSourceLabel(), markers = mk })
  end
  -- saved snapshot's own drop log (complete, self-contained)
  if HaulDB and HaulDB.history then
    for _, h in ipairs(HaulDB.history) do
      if h.sid == sid and h.drops then return ns.Replay.Rebuild(h.drops, { priceSource = h.priceSource, markers = mk }) end
    end
  end
  -- fall back to the exported event stream filtered by sid
  local stream = ns.LogStream and ns.LogStream()
  if stream then
    local evs = {}
    for _, e in ipairs(stream) do if e.sid == sid then evs[#evs + 1] = e end end
    return ns.Replay.Rebuild(evs, { priceSource = ns.PriceSourceLabel and ns.PriceSourceLabel(), markers = mk })
  end
  return nil
end

-- "Save" is now just a FLUSH-TO-DISK (reload). Sessions bank to Saved Sessions automatically on
-- every New, so there's no separate manual "save the session" step — this only writes state to disk
-- (so an external tool / Uplink sees the latest). Kept under the ns.SaveSession name so the button,
-- keybind, and /haul save slash all route here.
function ns.SaveSession()
  if ns.RequestReload then ns.RequestReload() end
end

-- True when the live session has anything worth keeping (loot or coin change).
function ns.SessionHasData()
  local s = ns.session
  if not s then return false end
  if ns.Coin() ~= 0 then return true end
  return next(s.items) ~= nil
end

-- Append the current session to history WITHOUT the Save side effects (no reload,
-- no nudge) — used by auto-start so prior runs aren't lost silently.
function ns.BankSession()
  if not ns.session then return end
  HaulDB.history[#HaulDB.history + 1] = SnapshotSession()
  if ns.RefreshSessions then ns.RefreshSessions() end   -- keep the Data tab list in sync if it's open
end

-- Seed a live session's non-loot aggregate FIELDS (currency/rep/xp/kills/gather + XP sub-buckets) from a
-- Replay.Rebuild result. Loot is rebuilt from s.log by ComputeStats every render, but these categories are
-- read from the fields directly — so a resumed/merged run must seed them from the (combined) event log or
-- they show EMPTY (the loot-only bug). Chronological *Log lists Replay doesn't reconstruct (repLog/killLog)
-- stay as-is; the category totals + accordions come from these seeded aggregates.
function ns.SeedAggregates(s, reb)
  reb = reb or {}
  s.rep = reb.rep or {}; s.currency = reb.currency or {}; s.professions = reb.professions or {}
  s.xp = reb.xp or 0; s.xpDiscovery = reb.xpDiscovery or 0; s.xpQuest = reb.xpQuest or 0; s.xpKill = reb.xpKill or 0
  s.xpGather = reb.xpGather or 0; s.xpOther = reb.xpOther or 0
  s.xpMobs = reb.xpMobs or {}; s.xpNodes = reb.xpNodes or {}; s.xpZones = reb.xpZones or {}
  s.kills = reb.kills or {}; s.killCount = reb.killCount or 0; s.gather = reb.gather or {}
  s.xpLog = reb.xpStream or {}; s.xpQuestLog = reb.xpQuestStream or {}; s.xpOtherLog = reb.xpOtherStream or {}
end

-- REPLACE the live run with a saved one: pick a saved session back up exactly where it left off.
-- Your current run is banked to Saved Sessions first (never lost), then DROPPED — its time and data
-- are NOT carried over. The new live run contains ONLY the resumed session's contents (new sid).
-- (Carrying your current run IN is what MERGE does — see MergeFromHistory.)
function ns.ResumeFromHistory(i)
  local h = HaulDB.history and HaulDB.history[i]
  if not h then return false end
  -- bank + close the current run so nothing is lost, then let it go.
  if ns.SessionHasData and ns.SessionHasData() then ns.BankSession() end
  if ns.session and ns.session.sid and ns.LogStop then ns.LogStop(ns.session.sid) end

  local items, seq = {}, 0
  for _, it in ipairs(h.items or {}) do
    seq = seq + 1
    local key = it.from and (it.id .. "@" .. it.from) or it.id   -- keep mail/craft entries distinct
    items[key] = { id = it.id, link = it.link or ("item:" .. it.id), count = it.count, seq = seq,
                   from = it.from, keep = it.keep or nil }
  end
  local mgl = NormalizeMailGold(h)
  local log, wp = {}, {}
  for _, d in ipairs(h.drops or {}) do log[#log + 1] = d end
  for _, w in ipairs(h.waypoints or {}) do wp[#wp + 1] = w end
  ns.session = {
    running = true,
    t0 = GetTime(), accum = (h.durationSec or 0),   -- the SAVED run's elapsed; the clock continues from there
    gold = (h.coin or 0),                           -- the SAVED run's looted gold only
    mailGoldLog = mgl, mailGoldSeq = MaxMailGoldSeq(mgl),
    items = items, log = log, seq = seq,
    -- rep/currency/xp/kills are SEEDED from the resumed log right after this table is built (SeedAggregates),
    -- since h.drops carries all those events — they must NOT stay empty. These zeros are just placeholders.
    rep = {}, repLog = {}, currency = {}, currencyLog = {},
    professions = {}, professionsLog = {},
    xp = 0, xpDiscovery = 0, xpQuest = 0, xpKill = 0, xpMobs = {},
    xpGather = 0, xpNodes = {}, xpOther = 0, xpOtherLog = {},
    kills = {}, killCount = 0, killLog = {}, gather = {},
    xpZones = {}, xpLog = {}, xpQuestLog = {},
    waypoints = wp, startedAt = h.startedAt or time(),
    establishedAt = h.establishedAt or h.startedAt,
    -- provenance: carry the resumed run's prior merges + a "resume" entry so the Data tab shows
    -- "resumed <- <that session>" AND the row tag reads "resumed" (not "merged").
    merges = (function()
      local m = {}
      for _, x in ipairs(h.merges or {}) do m[#m + 1] = x end
      m[#m + 1] = { at = time(), via = "resume", from = { startedAt = h.startedAt, character = h.character,
        counted = h.countedValue, gross = h.grossValue, durationSec = h.durationSec, itemCount = h.itemCount,
        uid = h.uid, sid = h.sid, class = h.class } }
      return m
    end)(),
    character = h.character or ns.CharName(), class = h.class,   -- keep who originally ran it
  }
  if ns.BeginSession then ns.BeginSession(ns.session) end   -- fresh live sid for the resumed run
  do local S = ns.SessionCtrl and ns.SessionCtrl(); if S and h.sid then S:Fold(h.sid, "resume") end end
  h.absorbed = true; h.absorbedInto = ns.session.sid   -- fade the resumed-from source + tag it, same as a rebuild
  if ns.SeedAggregates and ns.Replay then ns.SeedAggregates(ns.session, ns.Replay.Rebuild(ns.session.log)) end
  if ns.RefreshUI then ns.RefreshUI() end
  ns.Print("|cff80ff80resumed a saved session — the current run was banked first|r")
  ns.Notify("|cff80ff80session resumed|r")
  return true
end

-- Fold a saved session INTO the current live session: its items, coin, elapsed
-- time, and loot log are added on top of whatever is running right now (the live
-- clock keeps going). Unlike Resume, nothing is replaced.
function ns.MergeFromHistory(i)
  local h = HaulDB.history and HaulDB.history[i]
  if not h then return false end
  if not ns.session then ns.session = NewSession() end
  local s = ns.session
  s.items = s.items or {}; s.log = s.log or {}; s.waypoints = s.waypoints or {}
  s.establishedAt = s.establishedAt or s.startedAt    -- preserve this run's true creation time
  s.merges = s.merges or {}                           -- provenance: when + what was folded in
  s.merges[#s.merges + 1] = {
    at = time(),
    from = { startedAt = h.startedAt, character = h.character, counted = h.countedValue,
             gross = h.grossValue, durationSec = h.durationSec, itemCount = h.itemCount,
             uid = h.uid, sid = h.sid, class = h.class },   -- uid (the folded run's unique #id) + class (header color)
  }
  for _, it in ipairs(h.items or {}) do
    local key = it.from and (it.id .. "@" .. it.from) or it.id   -- mail/craft folds only into same-acquire
    local e = s.items[key]
    if e then e.count = e.count + (it.count or 0)
    else
      s.seq = (s.seq or 0) + 1
      s.items[key] = { id = it.id, link = it.link or ("item:" .. it.id),
                       count = it.count or 0, seq = s.seq, from = it.from, keep = it.keep or nil }
    end
  end
  s.gold = (s.gold or 0) + (h.coin or 0)         -- looted gold adds on
  -- mail gold (v2): concatenate the itemized logs, reassigning seq so ids stay unique
  s.mailGoldLog = s.mailGoldLog or {}
  for _, e in ipairs(NormalizeMailGold(h)) do
    s.mailGoldSeq = (s.mailGoldSeq or 0) + 1
    s.mailGoldLog[#s.mailGoldLog + 1] = { amount = e.amount or 0, label = e.label,
      sender = e.sender, subject = e.subject, seq = s.mailGoldSeq, keep = e.keep or nil }
  end
  s.accum = (s.accum or 0) + (h.durationSec or 0) -- add the saved run's elapsed time
  for _, d in ipairs(h.drops or {}) do s.log[#s.log + 1] = d end
  for _, w in ipairs(h.waypoints or {}) do s.waypoints[#s.waypoints + 1] = w end
  if (h.startedAt or 0) > 0 and h.startedAt < (s.startedAt or time()) then
    s.startedAt = h.startedAt   -- keep the earliest start so the label spans both
  end
  -- re-derive the non-loot aggregates from the COMBINED log (live events + the folded h.drops), so
  -- currency/rep/xp/kills reflect both runs — not just loot. (Items fold via s.log/s.items above.)
  if ns.SeedAggregates and ns.Replay then ns.SeedAggregates(s, ns.Replay.Rebuild(s.log)) end
  -- record the fold in the always-on log so a deleted merged run can still be reconstructed: the folded
  -- session's events live under ITS sid; this marker (under the live run's sid) links them in.
  do local S = ns.SessionCtrl and ns.SessionCtrl(); if S and h.sid then S:Fold(h.sid, "merge") end end
  h.absorbed = true; h.absorbedInto = s.sid   -- fade the folded-in source + tag it, same as a rebuild does
  if ns.RefreshUI then ns.RefreshUI() end
  ns.Print("|cff80ff80merged a saved session into the live run|r")
  ns.Notify("|cff80ff80session merged|r")
  return true
end

-- Combine two or more saved sessions into ONE new TYPED session (via="combine"). Unlike the old
-- sum-the-baked-fields approach, this creates a REAL record entity: the controller mints a fresh sid and
-- lays start + N fold(via="combine") + stop (pause/resume-bracketed around the live run), and Resolve rolls
-- it up (frozen prices, per-source segments, pause-safe) == the server. The folded sources are marked
-- absorbed (grayed, "absorbed into <combine>") — same as merge/resume — so nothing double-shows, and the
-- combine is uploadable / shareable / re-combinable. Only real, non-absorbed, non-deleted rows qualify.
function ns.CombineHistory(indices)
  local hist = HaulDB.history or {}
  local picked, fromsids = {}, {}
  for _, i in ipairs(indices or {}) do
    local h = hist[i]
    if h and h.sid and not h.absorbed and not h.deleted then
      picked[#picked + 1] = h; fromsids[#fromsids + 1] = h.sid
    end
  end
  if #picked < 2 then return false end
  local S = ns.SessionCtrl and ns.SessionCtrl()
  if not (S and S.Combine) then return false end
  local newSid = S:Combine(fromsids, {})   -- the combine has no items of its own; value comes from its folds
  if not newSid then return false end
  -- the sources are now folded in — fade + tag them (absorbed), exactly like a live merge/resume
  for _, h in ipairs(picked) do h.absorbed = true; h.absorbedInto = newSid end
  -- surface the new combine: reconstruct pulls closed sessions not yet in history (Resolve rolls the
  -- combine up); the already-in-history sources are skipped, so only the combine survivor is added.
  if ns.ReconstructHistoryFromLog then ns.ReconstructHistoryFromLog() end
  ns.Print(string.format("|cff80ff80combined %d sessions|r into a new session (%d in history)",
    #picked, #HaulDB.history))
  return true
end

-- PERMANENT removal (the deliberate two-step purge from an already soft-deleted row).
function ns.DeleteHistory(i)
  if HaulDB.history and HaulDB.history[i] then table.remove(HaulDB.history, i) end
end
-- Soft delete: keep the entry, just flag it (timestamp). It sinks to the bottom of the Data tab and can
-- be Undeleted — non-destructive, and still reconstructable from the log. Pass false to restore.
function ns.SetHistoryDeleted(i, deleted)
  local h = HaulDB.history and HaulDB.history[i]
  if not h then return end
  h.deleted = deleted and time() or nil
end
-- SHIPS (must not be stripped): "Combine selected" (ns.CombineHistory) depends on this to surface the
-- combined survivor into history — stripping it broke Combine in the public build while it still reported
-- success. The dev-only "Rebuild from log" button also calls it, but that button is stripped on its own.
-- Rebuild saved sessions from the always-on event log (HaulData.log). Each event carries its session id
-- (sid); group by sid, Replay each group into a snapshot-shaped entry, and add any sid NOT already in
-- history. Non-destructive recovery: the log is the source of truth, so a purged / never-saved session
-- can be reconstituted (and the future "re-download your logs" flow lands here). Returns # added.
function ns.ReconstructHistoryFromLog()
  local log = ns.LogStream and ns.LogStream()
  local GECStore = LibStub and LibStub:GetLibrary("GECStore-1.0", true)
  local Session = GECStore and GECStore.Session
  -- Session.Resolve is the CANONICAL reduction (== the server): frozen close-time prices + honored
  -- exclusions + fold roll-up. It owns ALL value/timing/provenance; Replay supplies ONLY the category
  -- detail (rep/currency/xp/kills/gather) and item display fields it doesn't compute. This is why a
  -- reconstruct now matches the live window and the server instead of the old Replay-only understatement
  -- (the exported stream drops loot `val`, so Replay alone can't value items).
  if type(log) ~= "table" or not (ns.Replay and ns.Replay.Rebuild) or not (Session and Session.Resolve) then return 0 end
  HaulDB.history = HaulDB.history or {}
  -- the always-on log stores location as a place INDEX (e.p), not a zone string; resolve it back to the
  -- zone name via GECStore so reconstructed runs show zones instead of "Unknown".
  local function zoneOfPlace(p)
    local cascade = GECStore and GECStore.PlaceInfo and p and GECStore.PlaceInfo(p)
    if not cascade or #cascade == 0 then return nil end
    local parts = {}   -- FULL path (continent > zone > area), as Haul stores it — not just the lowest part
    for _, c in ipairs(cascade) do if c.name and c.name ~= "" then parts[#parts + 1] = c.name end end
    return (#parts > 0) and table.concat(parts, " > ") or nil
  end
  local have = {}
  for _, h in ipairs(HaulDB.history) do if h.sid then have[h.sid] = true end end
  -- group income events by sid (source for gather() → Replay's category detail + item display fields)
  local bySid, folds = {}, {}
  for _, e in ipairs(log) do
    local sid = e.sid
    if sid then
      if not bySid[sid] then bySid[sid] = {} end
      bySid[sid][#bySid[sid] + 1] = e
    end
  end
  -- fold markers (merge/resume) live in the MARKERS stream now (session refactor), NOT in `log` — read
  -- them there so a merged/resumed session still gathers its folded-in segments; otherwise it misses their
  -- gold/items/quest-gold entirely (the 144→49 bug). Markers also carry timing + character for Replay.
  -- folds[survivor] = { {sid=fromsid, via=merge|resume, at=t}, … }. Mirrors the LIVE merge: the absorbed
  -- source STAYS as its own record (it's the source), AND the survivor shows the "merged/resumed with X"
  -- provenance — so we do NOT skip absorbed sids here.
  local markers = HaulData and HaulData.streams and HaulData.streams.markers
  if markers then for _, m in ipairs(markers) do
    if m.k == "fold" and m.sid and m.fromsid then
      folds[m.sid] = folds[m.sid] or {}
      folds[m.sid][#folds[m.sid] + 1] = { sid = m.fromsid, via = m.via, at = m.t }
      -- a fold SURVIVOR may have no income events of its own (all data came from the folded-in segment),
      -- so ensure its (possibly empty) bucket exists so gather() can walk it.
      if not bySid[m.sid] then bySid[m.sid] = {} end
    end
  end end
  -- a session's full event set = its own events + everything it folded in (merge/resume), transitively
  local function gather(sid, seen, out)
    if seen[sid] then return end
    seen[sid] = true
    for _, e in ipairs(bySid[sid] or {}) do out[#out + 1] = e end
    for _, f in ipairs(folds[sid] or {}) do gather(f.sid, seen, out) end
  end
  -- markers for a set of sids (timing/character for Replay)
  local function markersFor(seen)
    local out = {}
    if markers then for _, m in ipairs(markers) do if m.sid and seen[m.sid] then out[#out + 1] = m end end end
    return out
  end
  -- resolve a char REGISTRY index to a display name (reconstructed rows show who ran it)
  local function charName(idx)
    local info = idx and GECStore.CharInfo and GECStore.CharInfo(idx)
    return (info and info.name) or nil
  end
  -- zone waypoints from an event set's place indices (ANY activity event, not just loot — a mail-gold-only
  -- run still gets zones). CONTROL kinds carry no place.
  local function waypointsOf(events)
    local CONTROL = { start = true, stop = true, pause = true, resume = true, fold = true, include = true, exclude = true }
    local wp = {}
    for _, e in ipairs(events) do
      local k = e.k or (e.id and "item") or ""
      if e.p and not CONTROL[k] then local z = zoneOfPlace(e.p); if z then wp[#wp + 1] = { zone = z, count = e.count or 1 } end end
    end
    return wp
  end
  -- Merge Resolve's frozen item VALUES (unit/value; no display fields) with Replay's item DISPLAY fields
  -- (link/name/quality/from — but no value, since `val` is dropped from the exported stream), keyed by id.
  local function itemsWithValue(resItems, rebItems)
    local disp = {}
    for _, it in ipairs(rebItems or {}) do if it.id and not disp[it.id] then disp[it.id] = it end end
    local out = {}
    for _, it in ipairs(resItems or {}) do
      local d = disp[it.id]
      out[#out + 1] = { id = it.id, link = d and d.link, name = d and d.name, quality = d and d.quality,
        count = it.count, unit = it.unit, total = it.value, excluded = it.excluded,
        from = d and d.from, cat = d and d.cat, src = d and d.src }
    end
    return out
  end
  -- a folded survivor exposes per-segment items; union them (each already at its own frozen value)
  local function unionSegItems(segments)
    local byId, out = {}, {}
    for _, seg in ipairs(segments or {}) do
      for _, it in ipairs(seg.items or {}) do
        local e = byId[it.id]
        if e then e.count = e.count + (it.count or 0); e.value = e.value + (it.value or 0)
        else e = { id = it.id, count = it.count or 0, unit = it.unit, source = it.source, value = it.value or 0, excluded = it.excluded }
          byId[it.id] = e; out[#out + 1] = e end
      end
    end
    return out
  end

  local added = 0
  -- iterate Resolve's CLOSED sessions (== server; absorbed sources are rolled into their survivor and are
  -- NOT emitted here — they get a grayed row below). Value/timing/exclusions/provenance come from Resolve;
  -- category detail + item display fields come from Replay over the same gathered event set.
  local resolved = Session.Resolve(HaulData)
  for _, rs in ipairs(resolved.sessions) do
    if not have[rs.sid] then
      local events, seen = {}, {}
      gather(rs.sid, seen, events)
      table.sort(events, function(a, b) return (a.t or 0) < (b.t or 0) end)
      local reb = ns.Replay.Rebuild(events, { markers = markersFor(seen) })
      local resItems = rs.items or (rs.segments and unionSegItems(rs.segments)) or {}
      -- "merged/resumed/combined with X" provenance from Resolve's fold segments (FROZEN values)
      local merges, merged
      if rs.via then
        merges = {}
        for _, seg in ipairs(rs.segments or {}) do
          if seg.sid ~= rs.sid then
            local srec = HaulData.sessions and HaulData.sessions[seg.sid]
            merges[#merges + 1] = { at = seg.startedAt, via = rs.via,
              from = { sid = seg.sid, startedAt = seg.startedAt, character = charName(srec and srec.character),
                       counted = math.floor(seg.counted or 0), gross = math.floor(seg.gross or 0),
                       durationSec = math.floor(seg.activeSeconds or 0), itemCount = #(seg.items or {}) } }
          end
        end
        merged = (rs.via == "resume") and "resumed" or ((rs.via == "combine") and "combined" or "merged")
      end
      local gph = (rs.activeSeconds and rs.activeSeconds > 0) and math.floor((rs.counted or 0) / (rs.activeSeconds / 3600)) or 0
      HaulDB.nextUid = (HaulDB.nextUid or 0) + 1
      HaulDB.history[#HaulDB.history + 1] = {
        sid = rs.sid, uid = HaulDB.nextUid, reconstructed = true,
        merges = merges, merged = merged,
        startedAt = rs.startedAt or time(), establishedAt = rs.startedAt or time(),
        durationSec = math.floor(rs.activeSeconds or 0), character = charName(rs.character),
        countedValue = math.floor(rs.counted or 0), grossValue = math.floor(rs.gross or 0),
        coin = math.floor(rs.coin or 0), itemCount = reb.itemCount or 0, notable = reb.notable or 0,
        goldPerHour = gph, priceSource = reb.priceSource,
        mailGoldLog = reb.mailGoldLog or {}, items = itemsWithValue(resItems, reb.items), waypoints = waypointsOf(events),
        drops = events,   -- keep the source events so the Data-tab category detail rebuilds
      }
      added = added + 1
    end
  end
  -- grayed ABSORBED-source rows: a folded-in source rolls into its survivor (above) but must NOT vanish —
  -- show it faded, tagged "absorbed into <survivor>", value = its own frozen segment. Un-absorb is a later
  -- append-only reverse; for now this guarantees a rebuild never looks like data disappeared.
  for _, rs in ipairs(resolved.sessions) do
    for _, seg in ipairs(rs.segments or {}) do
      if seg.sid ~= rs.sid and not have[seg.sid] then
        local srec = HaulData.sessions and HaulData.sessions[seg.sid]
        HaulDB.nextUid = (HaulDB.nextUid or 0) + 1
        HaulDB.history[#HaulDB.history + 1] = {
          sid = seg.sid, uid = HaulDB.nextUid, reconstructed = true, absorbed = true, absorbedInto = rs.sid,
          startedAt = seg.startedAt or time(), establishedAt = seg.startedAt or time(),
          durationSec = math.floor(seg.activeSeconds or 0), character = charName(srec and srec.character),
          countedValue = math.floor(seg.counted or 0), grossValue = math.floor(seg.gross or 0),
          coin = 0, itemCount = #(seg.items or {}), notable = 0, goldPerHour = 0,
          items = {}, waypoints = {}, drops = {},
        }
        have[seg.sid] = true
        added = added + 1
      end
    end
  end
  return added
end


------------------------------------------------------------------ public API --
function Haul.GetSession() return SnapshotSession() end
function Haul.Reset() ns.Reset() end
function Haul.ToggleTracking() ns.ToggleTracking() end
function Haul.SaveSession() ns.SaveSession() end
function Haul.SetActive(b) ns.SetTracking(b) end
function Haul.IsExcluded(id) return HaulDB.excluded[id] and true or false end
function Haul.SetExcluded(id, b)
  HaulDB.excluded[id] = b and true or nil
  -- append-only exclude marker (parallels the mail/craft include markers) so a pure log replay
  -- reconstructs the exclusion state — it's a manual per-item-ID decision, not derivable otherwise.
  if ns.LogExclude then ns.LogExclude(id, b and true or false) end   -- exclusion toggle → markers stream (§3.4)
  if ns.RefreshUI then ns.RefreshUI() end
end

-- One-off include for a mail/craft entry: toggle entry.keep on the live-session entry
-- identified by its composite s.items key (e.g. "12345@mail"). Not persisted by item ID,
-- not remembered across sessions — purely this captured stack, this run.
function Haul.IsEntryKept(key)
  local s = ns.session
  local e = s and s.items and s.items[key]
  return (e and e.keep) and true or false
end
function Haul.ToggleEntryKeep(key)
  local s = ns.session
  local e = s and s.items and s.items[key]
  if not e then return end
  e.keep = not e.keep
  -- append-only marker: record this one-off include/exclude so a pure log replay can recreate it
  -- (the snapshot also round-trips `keep`; both mechanisms agree). Never mutates a past event.
  if ns.LogEvent then ns.LogEvent("include", { ref = key, cat = "item", on = e.keep and true or false, from = e.from }) end
  if ns.RefreshUI then ns.RefreshUI() end
end

-- One-off include for a single mail-gold pickup (the clickable Mailbox gold line),
-- identified by its stable per-entry `seq`. Flips that entry's `keep`; one-off,
-- session-only, not remembered across sessions.
function Haul.ToggleMailGoldKeep(seq)
  local s = ns.session
  if not (s and s.mailGoldLog) then return end
  for _, e in ipairs(s.mailGoldLog) do
    if e.seq == seq then
      e.keep = not e.keep
      -- append-only include marker (see Haul.ToggleEntryKeep) for the recreation guarantee.
      if ns.LogEvent then ns.LogEvent("include", { ref = seq, cat = "mailgold", on = e.keep and true or false, from = "mail" }) end
      if ns.RefreshUI then ns.RefreshUI() end
      return
    end
  end
end

-- Binding labels shown in Key Bindings > Haul
_G.BINDING_HEADER_HAUL = "Haul"
_G.BINDING_NAME_HAUL_RESET = "New session"
_G.BINDING_NAME_HAUL_TOGGLETRACK = "Pause / resume tracking"
_G.BINDING_NAME_HAUL_PAUSE = "Pause tracking"
_G.BINDING_NAME_HAUL_RESUME = "Resume tracking"
_G.BINDING_NAME_HAUL_SAVE = "Save (flush to disk)"
_G.BINDING_NAME_HAUL_FLUSH = "Flush to disk (reload)"
_G.BINDING_NAME_HAUL_WINDOW = "Show / hide window"
_G.BINDING_NAME_HAUL_OPTIONS = "Open options"

-- Bindings.xml shims (globals)
function Haul_Reset() ns.Reset() end
function Haul_ToggleTracking() ns.ToggleTracking() end
function Haul_Pause() ns.SetTracking(false) end    -- explicit (deterministic) pause
function Haul_Resume() ns.SetTracking(true) end    -- explicit resume
function Haul_SaveSession() ns.SaveSession() end
function Haul_ToggleWindow() if ns.ToggleWindow then ns.ToggleWindow() end end
function Haul_Flush() if ns.RequestReload then ns.RequestReload(true) end end
function Haul_Options() if ns.ToggleOptions then ns.ToggleOptions() end end

-- The Keybinds tab assigns key combos to these named bindings. They are NATIVE bindings (declared in
-- Bindings.xml under the "Haul" header), so WoW's own Key Bindings menu is the SINGLE SOURCE OF TRUTH —
-- the Keybinds tab and the game menu always show the same value. (Previously these used override bindings,
-- which never appeared in the game menu — that mismatch is what this fixes.)
ns.KEYBINDS = {
  { name = "HAUL_RESET",  label = "New session" },
  { name = "HAUL_PAUSE",  label = "Pause tracking" },
  { name = "HAUL_RESUME", label = "Resume tracking" },
  { name = "HAUL_SAVE",   label = "Save (flush to disk)" },
  { name = "HAUL_TOGGLETRACK", label = "Pause / resume (toggle)" },
  { name = "HAUL_WINDOW", label = "Show / hide window" },
  { name = "HAUL_FLUSH",  label = "Flush to disk (reload)" },
}
-- One-time-per-load migration: lift any legacy HaulDB.keybinds (the old override-bound combos) into the
-- native bindings via the shared GECBind lib, then drop the old store. Idempotent (the lib only seeds a
-- binding with no native key yet); out of combat only. Native bindings persist themselves — nothing to
-- "re-apply" each login. HaulDB.keybinds is already in the { [command] = combo } shape GECBind.Migrate wants.
function ns.ApplyKeybinds()
  local kb = HaulDB.keybinds
  if not kb then return end
  if InCombatLockdown() then return end   -- defer; native bindings can't change in combat
  LibStub:GetLibrary("GECBind-1.0").Migrate(kb)
  HaulDB.keybinds = nil   -- migrated — native bindings own these now
end

----------------------------------------------------------------- JSON mirror --
-- Minimal JSON encoder so HaulState can be read back without a Lua parser.
local function jsonEncode(v)
  local t = type(v)
  if t == "string" then
    return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
      local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                  ['\r'] = '\\r', ['\t'] = '\\t' }
      return m[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
  elseif t == "number" then return (v == v and v ~= math.huge and tostring(v)) or "0"
  elseif t == "boolean" then return tostring(v)
  elseif t == "table" then
    local parts = {}
    if #v > 0 then
      for _, e in ipairs(v) do parts[#parts + 1] = jsonEncode(e) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, val in pairs(v) do
        parts[#parts + 1] = jsonEncode(tostring(k)) .. ":" .. jsonEncode(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local function WriteState()
  local snap = SnapshotSession()
  HaulState = {
    version = Haul.BUILD, account = true,
    char = (UnitName and UnitName("player")) or "?",
    realm = (GetRealmName and GetRealmName()) or "?",
    session = snap, history = HaulDB.history,
    settings = ns.ExportTable and ns.ExportTable() or nil,  -- editable config for the Helper
    json = jsonEncode({ session = snap }),
  }
end
ns.WriteState = WriteState

--------------------------------------------------------------------- events --
-- True when we're inside instanced content. IsInInstance covers dungeons/raids;
-- delves run on the scenario system and may not report there right away, so an
-- active scenario counts too.
local function InInstanceNow()
  -- A Garrison (Lunarfall / Frostwall) is flagged as an instance by IsInInstance, but it's a home
  -- base, not a dungeon — treat it as open world so the map trigger (ask) handles it, not the
  -- instance sideline. (Housing and other "fake" instances may want the same exclusion later.)
  if C_Garrison and C_Garrison.IsOnGarrisonMap and C_Garrison.IsOnGarrisonMap() then return false end
  local inInstance, instType = IsInInstance()
  if inInstance and instType ~= "none" then return true, instType end
  -- scenario-system content (world quests, open-world events, delves) is OPT-IN — see newSessionTriggers.scenario.
  -- Gated so a fly-through world-quest farm run doesn't get sidelined by default. When off we return false here
  -- (symmetric enter/leave), so the scenario is invisible to the instance sideline entirely.
  if HaulDB and HaulDB.newSessionTriggers and HaulDB.newSessionTriggers.scenario
     and C_ScenarioInfo and C_ScenarioInfo.GetScenarioInfo then
    local ok, info = pcall(C_ScenarioInfo.GetScenarioInfo)
    if ok and info then return true, "scenario" end
  end
  return false, instType
end
-- Is scenario-system content active RIGHT NOW (regardless of the opt-in)? Used only for the dev "you entered a
-- scenario" identification print, so false positives are visible even when scenario-sidelining is off.
function ns._ScenarioActive()
  if C_ScenarioInfo and C_ScenarioInfo.GetScenarioInfo then
    local ok, info = pcall(C_ScenarioInfo.GetScenarioInfo)
    if ok and info then return info end
  end
  return nil
end

-- Bank the prior run and start a fresh session when we cross from "not in an
-- instance" into one. Edge-triggered on ns.wasInInstance, so it fires once per
-- entry no matter which event (PEW / zone change / scenario) wakes us.
local function CheckInstanceTransition()
  local nowIn, instType = InInstanceNow()
  local boundaryChanged = ns.peInit and (nowIn ~= ns.wasInInstance)
  local handled = boundaryChanged and HaulDB.newSessionTriggers and HaulDB.newSessionTriggers.instance and true or false
  if handled then
    if nowIn then
      -- ENTER: pause + set the running session ASIDE (kept in memory, NOT saved to
      -- history) and start a fresh tracker for the instance. Like hitting pause.
      local cur = ns.session
      if cur then
        cur._wasRunning = cur.running and true or false
        if cur.running then cur.accum = (cur.accum or 0) + (GetTime() - cur.t0); cur.running = false end
        if cur.sid and ns.LogPause then ns.LogPause(cur.sid) end   -- suspend A (open-world)
      end
      ns.sidelined = cur
      do local S = ns.SessionCtrl and ns.SessionCtrl(); if S then S:Sideline() end end   -- park A so B's Begin can't clobber it
      ns.session = NewSession()                                    -- start B (instance; Begin inside)
      ns.instLabel = (instType == "scenario") and "scenario" or "instance"
      ns.Print("|cff80ff80Entering " .. ns.instLabel
        .. "|r — your session is paused & set aside; tracking the " .. ns.instLabel .. " fresh.")
      ns.Notify("|cff80ff80" .. ns.instLabel .. ": previous session set aside|r")
    else
      -- LEAVE: SAVE the instance run to Saved Sessions, then RESUME the set-aside
      -- session right where it left off (not stored — you're just un-pausing it).
      local label = ns.instLabel or "instance"
      local saved = ns.SessionHasData()
      if saved then ns.BankSession() end
      if ns.session and ns.session.sid and ns.LogStop then ns.LogStop(ns.session.sid) end  -- stop B (instance)
      local side = ns.sidelined
      ns.sidelined = nil
      if side then
        do local S = ns.SessionCtrl and ns.SessionCtrl(); if S then S:Restore() end end   -- bring A back as the open session
        side.t0 = GetTime(); side.running = (side._wasRunning ~= false); side._wasRunning = nil
        ns.session = side
        -- resume A only if it actually un-pauses; a manually-paused A stays paused
        -- (its excluded span stays open) so the log keeps matching the live state
        if side.sid and side.running and ns.LogResume then ns.LogResume(side.sid) end
        ns.Print("|cff80ff80Left " .. label .. "|r — "
          .. (saved and (label .. " session saved") or "nothing to save")
          .. "; resumed your previous session.")
        ns.Notify("|cff80ff80resumed previous session|r")
      else
        ns.session = NewSession()
        ns.Print("|cff80ff80Left " .. label .. "|r — "
          .. (saved and (label .. " session saved") or "nothing to save") .. "; tracking fresh.")
        ns.Notify("|cff80ff80left " .. label .. "|r")
      end
      ns.instLabel = nil
    end
    if ns.RefreshUI then ns.RefreshUI() end
  end
  ns.wasInInstance = nowIn
  ns.peInit = true
  return handled   -- only suppress the zone/map check when the instance trigger actually handled this boundary
end

-- Zone-tier transitions: start a NEW session when a WATCHED open-world tier (region/zone/sub-zone)
-- changes. Unlike instances (sideline + resume), a zone change banks the run and starts fresh — no
-- return. Instance boundaries are skipped here (the instance trigger owns them).
local function DoZoneNewSession()
  if ns.SessionHasData and ns.SessionHasData() then ns.BankSession() end
  if ns.session and ns.session.sid and ns.LogStop then ns.LogStop(ns.session.sid) end
  -- a zone change is a new session too, so honor "Reload before new session": reload BEFORE the
  -- fresh session (born on load), same stop->reload->start shape as the manual New. If the reload
  -- defers (unsafe), fall through to an immediate new session.
  if HaulDB.reloadBeforeNewSession and ns.RequestReload then
    ns.session = nil; HaulDB.liveSession = nil
    ns.Notify("|cff80ff80new session — zone changed (reloading…)|r")
    if ns.RequestReload() then return end
  end
  ns.session = NewSession()
  if ns.RefreshUI then ns.RefreshUI() end
  ns.Notify("|cff80ff80new session — zone changed|r")
end
-- index directly into the existing global (a FrameXML base table); do NOT reassign it
-- (StaticPopupDialogs = ...) — writing the global from addon code taints the StaticPopup system.
StaticPopupDialogs["HAUL_NEWSESSION_ZONE"] = {
  text = "Haul: you changed zones. Start a new session?\n(the current run is saved to history first)",
  button1 = "New session", button2 = "Keep current",
  OnAccept = function() DoZoneNewSession() end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
local function CheckZoneTransition()
  if not ns.peInit then return end
  local region, zone, sub = ns.ZoneTiers()
  local last = ns._lastTiers
  ns._lastTiers = { region = region, zone = zone, sub = sub }
  if not last then return end                       -- first sample is just the baseline
  local t = HaulDB.newSessionTriggers or {}
  if not t.map then return end
  -- instances belong to the instance trigger ONLY when it's on; otherwise treat them as a map change
  -- (so a garrison / scenario you teleport into still asks instead of being silently swallowed)
  if InInstanceNow() and t.instance then return end
  local level = HaulDB.newSessionMapLevel or "zone"
  local changed
  if level == "region" then changed = (region ~= last.region)
  elseif level == "subzone" then changed = (sub ~= last.sub)   -- finest: any named-area move (also region/zone)
  else changed = (zone ~= last.zone) end                       -- zone (also fires on region moves)
  if not changed then return end
  if HaulDB.newSessionPrompt then StaticPopup_Show("HAUL_NEWSESSION_ZONE") else DoZoneNewSession() end
end
ns.CheckZoneTransition = CheckZoneTransition

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")   -- delves/zone-ins with no loading screen
f:RegisterEvent("ZONE_CHANGED")             -- sub-zone changes (no loading screen)
f:RegisterEvent("ZONE_CHANGED_INDOORS")     -- indoor sub-zone changes
f:RegisterEvent("SCENARIO_UPDATE")          -- delves run on the scenario system
f:RegisterEvent("CHAT_MSG_MONEY")
f:RegisterEvent("PLAYER_MONEY")
f:RegisterEvent("QUEST_TURNED_IN")   -- quest reward money (arg3 = copper); not a CHAT_MSG_MONEY
f:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")   -- reputation gains (per faction)
f:RegisterEvent("CURRENCY_DISPLAY_UPDATE")           -- currency gained/spent (per currency type)
f:RegisterEvent("PLAYER_XP_UPDATE")                  -- experience gained (total; delta of UnitXP)
f:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")           -- per-kill XP ("X dies, you gain N experience.")
f:RegisterEvent("CHAT_MSG_OPENING")                  -- gathering source ("You perform <skill> on <node>.")
f:RegisterEvent("CHAT_MSG_SYSTEM")                   -- zone-discovery XP ("Discovered %s: %d experience gained.")
f:RegisterEvent("PLAYER_TARGET_CHANGED")             -- GUID->name cache for looted corpses
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")             -- GUID->name for EVERY visible mob (no-XP / AoE kill names)
-- (Loot-source kill/gather attribution now rides GECLoot's LOOT_ITEM/LOOT_MONEY callbacks — see onGECLootItem;
--  Haul no longer registers LOOT_READY/LOOT_OPENED. COMBAT_LOG kills are opt-in only; see the clf block.)
f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    HaulDB = HaulDB or {}
    if ns.InitLog then ns.InitLog() end   -- HaulData ready before RestoreOrNew touches sessions
    HaulDB.themePreset = HaulDB.themePreset or "gruvbox"
    -- migrate old trashVendor bool -> graysMode dropdown
    if HaulDB.trashVendor ~= nil and HaulDB.graysMode == nil then
      HaulDB.graysMode = HaulDB.trashVendor and "merge" or "show"
    end
    HaulDB.trashVendor = nil
    -- "list" used to mean aggregated; it now means chronological. Keep existing
    -- users on the aggregated (now "collection") view they had before.
    if not HaulDB._viewMigrated then
      if HaulDB.view == "list" then HaulDB.view = "collection" end
      HaulDB._viewMigrated = true
    end
    ApplyDefaults(HaulDB, DB_DEFAULTS)
    -- "All" category is retired from the selectors for now (not ready) — coerce any persisted "all" back to
    -- "loot" so a saved state doesn't render the dormant all-view or show a dead "All" on the button.
    if HaulDB.window and HaulDB.window.category == "all" then HaulDB.window.category = "loot" end
    if HaulDB.dataCategory == "all" then HaulDB.dataCategory = "loot" end
    -- one-time adoption of the new column defaults (% + Source ON): existing installs saved colPct=false from
    -- the old default, which ApplyDefaults won't overwrite — flip both ON once, then respect manual toggles.
    if HaulDB.window and not HaulDB.window._colDefaults2 then
      HaulDB.window.colPct = true; HaulDB.window.colSrc = true; HaulDB.window._colDefaults2 = true
    end
    -- migrate the renamed session/reload options: reloadOnReset -> reloadBeforeNewSession (preserve the
    -- user's on/off). The old Save-side toggles are gone entirely: Save now always flushes to disk, and
    -- sessions always bank to history on New.
    if HaulDB.reloadOnReset ~= nil then
      if HaulDB.reloadBeforeNewSession == nil then HaulDB.reloadBeforeNewSession = HaulDB.reloadOnReset end
      HaulDB.reloadOnReset = nil
    end
    HaulDB.reloadOnSave, HaulDB.saveOnReset = nil, nil
    local nst = HaulDB.newSessionTriggers   -- migrate legacy settings
    if nst then
      if HaulDB.autoStartInstance then nst.instance = true; HaulDB.autoStartInstance = false end
      if nst.region ~= nil or nst.zone ~= nil or nst.subzone ~= nil then   -- old per-tier booleans -> map + level
        if nst.subzone or nst.zone or nst.region then
          nst.map = true
          HaulDB.newSessionMapLevel = nst.subzone and "subzone" or (nst.zone and "zone") or "region"
        end
        nst.region, nst.zone, nst.subzone = nil, nil, nil
      end
    end
    -- One-time clean slate for the log-sourced architecture: pre-feature sessions have incomplete
    -- per-session logs (no complete mail-gold/rep/vendor rows), and views now rebuild from the log,
    -- so wipe history + the live run once. The event journal is now the APPEND-ONLY GECStore stream
    -- HaulData.streams.events — NEVER truncate it here (that breaks the sync cursor and halts syncing);
    -- the v4 DATA_VERSION bump already handled its clean-start, and the reset lays stop/start markers.
    if not HaulDB._logSourcedReset2 then
      HaulDB._logSourcedReset2 = true
      -- only a pre-feature user with existing (incomplete) sessions actually gets "reset"; a brand-new
      -- install has nothing to wipe, so it must NOT see the scary orange message on first login.
      local hadData = (HaulDB.history and #HaulDB.history > 0) or HaulDB.liveSession ~= nil
        or (HaulData and HaulData.sessions and next(HaulData.sessions) ~= nil)
      HaulDB.history = {}
      HaulDB.liveSession = nil
      HaulDB.sidelined = nil
      HaulDB.nextUid = 0
      if HaulData then HaulData.sessions = {} end   -- session index only; the stream is untouched
      if hadData then ns.Print("|cffffaa44reset to a clean slate for the new log-sourced sessions|r") end
    end
    ns.session = RestoreOrNew()   -- resume across /reload & relog
    -- recover ORPHANED events — a sid with events but no start marker (its lifecycle was lost, e.g. the
    -- markers were wiped/corrupted while events remained). Encapsulate them at their own timestamps so
    -- they're never invisible-to-Resolve and lost to limbo. AFTER RestoreOrNew so the live run's _open is
    -- set (the open run is re-anchored with a start but kept open; other orphans get start+stop + a record).
    do local S = ns.SessionCtrl and ns.SessionCtrl(); if S and S.RepairOrphans then
      local n = S:RepairOrphans()
      if n > 0 then ns.Print("|cffffaa44recovered " .. n .. " orphaned session(s)|r from the log (lifecycle re-derived from their events).") end
    end end
    ns.sidelined = UnpackSession(HaulDB.sidelined)   -- set-aside run, if mid-instance
  elseif event == "CHAT_MSG_MONEY" then
    onLootMoney(arg1)
  elseif event == "PLAYER_MONEY" then
    onPlayerMoney()
  elseif event == "QUEST_TURNED_IN" then
    onQuestMoney(arg3, arg1)   -- arg3 = money reward, arg1 = questID
    if ns._onQuestXP then ns._onQuestXP(arg2, arg1) end   -- arg2 = XP reward, arg1 = questID
  elseif event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
    onFactionRep(arg1)
  elseif event == "CURRENCY_DISPLAY_UPDATE" then
    onCurrencyUpdate(arg1, arg2, arg3)   -- currencyType, quantity, quantityChange
  elseif event == "PLAYER_XP_UPDATE" then
    onXPUpdate()
  elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
    if ns._onXPGainMsg then ns._onXPGainMsg(arg1) end   -- arg1 = the XP-gain message
  elseif event == "CHAT_MSG_OPENING" then
    if ns._onOpeningMsg then ns._onOpeningMsg(arg1) end   -- arg1 = "You perform <skill> on <node>."
  elseif event == "PLAYER_TARGET_CHANGED" then
    if ns._onTargetChanged then ns._onTargetChanged() end
  elseif event == "NAME_PLATE_UNIT_ADDED" then
    if ns._onNamePlateAdded then ns._onNamePlateAdded(arg1) end   -- arg1 = nameplate unit token

  elseif event == "CHAT_MSG_SYSTEM" then
    onSystemMsg(arg1)
  elseif event == "PLAYER_LOGIN" then
    ns.loginTime = GetTime()
    -- disk-flush tracking: bump the write generation each login (a login only follows a logout/reload,
    -- which WROTE SavedVariables) so any session banked in an earlier gen is provably on disk; and the
    -- live data is clean (== disk) right after a load.
    if HaulData then HaulData._gen = (HaulData._gen or 0) + 1 end
    ns._dirty = false
    -- (No automatic log retention/prune — the saved log grows until you purge it with /haul prune <N>.)
    ns._lastMoney = GetMoney()   -- baseline for looted-gold deltas
    if HaulDB.killsCombatLog and ns.EnableCombatLogKills then ns.EnableCombatLogKills() end   -- opt-in full kill tracking
    ns.SyncXPBaseline()          -- baseline UnitXP so the first PLAYER_XP_UPDATE delta is correct (not a jump)
    HookMailGold()               -- labeled mail-gold capture (TakeInboxMoney + AutoLootMailItem)
    -- One-time: move new users off the vendor default onto the best installed
    -- price source (TSM preferred, then Auctionator), and onto min-buyout.
    if not HaulDB.initialized then
      HaulDB.initialized = true
      if HaulDB.priceSource == "vendor" then
        if ns.PriceSourceAvailable("tsm") then HaulDB.priceSource = "tsm"
        elseif ns.PriceSourceAvailable("auctionator") then HaulDB.priceSource = "auctionator" end
      end
      if HaulDB.tsmPriceStr == "dbmarket" then HaulDB.tsmPriceStr = "dbminbuyout" end
    end
    if ns.BuildUI then ns.BuildUI() end
    if ns.InitFeedConsumer then ns.InitFeedConsumer() end   -- dev-only: consume outside (GEC) feeds
    if ns.InitOptions then ns.InitOptions() end   -- register the AddOns Settings page
    if ns.ApplyKeybinds then ns.ApplyKeybinds() end   -- apply the Keybinds-tab combos
    ns.ApplyFastLoot()                                 -- register/unregister Haul with the shared fast-loot lib + mirror debug
    if ns.StartFlush then ns.StartFlush() end
    ns.Print("loaded v" .. tostring(Haul.BUILD) .. " — source: "
      .. Theme.Accent(HaulDB.priceSource) .. ". /haul for window."
      .. (Haul.IsDev and Haul.IsDev() and " /haul diag to test prices." or ""))   -- diag dispatch is dev-only (stripped in public)
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- arg1 = isInitialLogin, arg2 = isReloadingUi. A TRUE fresh login (not /reload, not zoning)
    -- starts a BRAND-NEW session — /reload still resumes. The resumed previous run is banked to
    -- history first (if it has data) so nothing is lost.
    if arg1 then
      HaulDB._loginUnix = time()
      if ns.SessionHasData and ns.SessionHasData() then ns.BankSession() end
      -- The prior run spanned a logout (a session = login→logout). Close it at its LAST ACTIVITY, not
      -- "now" — else its marker duration swallows the whole offline gap (a run left open overnight would
      -- read ~13h). RepairIfDangling stops at last event/marker ts + freezes; reason "logout" (a clean
      -- session boundary, NOT a crash). Falls back to LogStop only if the controller isn't available.
      if ns.session and ns.session.sid then
        local S = ns.SessionCtrl and ns.SessionCtrl()
        if S and S.RepairIfDangling then
          S:RepairIfDangling((ns.BuildPriceSnapshot and ns.BuildPriceSnapshot(ns.session)) or {}, "logout")
        elseif ns.LogStop then ns.LogStop(ns.session.sid) end
      end
      ns.session = NewSession()
      ns._lastTiers = nil   -- re-baseline the zone tiers after a fresh login
      if ns.RefreshUI then ns.RefreshUI() end
    end
    if not CheckInstanceTransition() then ns.CheckZoneTransition() end
  elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED"
      or event == "ZONE_CHANGED_INDOORS" or event == "SCENARIO_UPDATE" then
    -- delves often enter via a zone change / scenario start, NOT PLAYER_ENTERING_WORLD.
    -- Instance boundaries are handled by the instance trigger; otherwise check zone-tier triggers.
    if not CheckInstanceTransition() then ns.CheckZoneTransition() end
  elseif event == "PLAYER_LOGOUT" then
    -- persist the live session (so /reload & relog resume it) + state mirror
    SaveLive()
    WriteState()
  end
end)

-- Diagnostic: print each source's value for the items in the current session, so
-- you can see what Auctionator/TSM actually return.
function ns.Diag()
  ns.Print(("source=" .. Theme.Accent("%s") .. "  tsm=%s  auctionator=%s  (tsm string: %s)"):format(
    HaulDB.priceSource, tostring(ns.PriceSourceAvailable("tsm")),
    tostring(ns.PriceSourceAvailable("auctionator")), HaulDB.tsmPriceStr or "?"))
  local s, n = ns.session, 0
  if s then
    for _, e in pairs(s.items) do
      n = n + 1
      if n <= 12 then
        local name = GetItemInfo(e.link) or e.link
        ns.Print(("  %s x%d  vendor=%s  auc=%s  tsm=%s"):format(name, e.count,
          ns.Coins(ns.PriceFrom("vendor", e.link) or 0),
          ns.Coins(ns.PriceFrom("auctionator", e.link) or 0),
          ns.Coins(ns.PriceFrom("tsm", e.link) or 0)))
      end
    end
  end
  if n == 0 then ns.Print("  no items yet — loot something first, then /haul diag") end
end


------------------------------------------------------------------ slash cmd --
SLASH_HAUL1 = "/haul"
SlashCmdList.HAUL = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "new" or msg == "reset" then ns.Reset()   -- "new" is the public name; "reset" kept as a quiet alias
  elseif msg == "save" then ns.SaveSession()
  elseif msg == "toggle" then ns.ToggleTracking()
  elseif msg == "flush" then Haul_Flush()
  elseif msg:match("^price ") then
    local s = msg:match("^price%s+(%a+)$")
    if s and ns.PriceSourceAvailable(s) then HaulDB.priceSource = s; ns.RefreshUI(); ns.Print("price source = " .. s)
    else ns.Print("usage: /haul price vendor|tsm|auctionator (must be installed)") end
  elseif msg == "config" or msg == "options" then Haul_Options()
  elseif msg == "export" or msg == "import" or msg == "settings" then
    if ns.ShowPorter then ns.ShowPorter() end
  elseif msg == "show" or msg == "" then Haul_ToggleWindow()
  else
    ns.Print("commands: show, new, save, toggle, flush, price <src>, config, settings")
  end
end
