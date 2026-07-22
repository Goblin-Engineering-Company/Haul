-- GECTemplate-1.0 — live game-state resolvers (zone / player / currency / count).
-- Separate from the pure engine: these call the WoW client at RENDER TIME, so they are
-- verified in-game (parity via /haul tpl), not headless. They only touch the API when invoked.
local Tpl = LibStub and LibStub:GetLibrary("GECTemplate-1.0", true)
if not Tpl then return end

-- Catalog of built-in/ambient tokens for feed browsers (insert text + short description).
Tpl.catalog = {
  { token = "{clock}",            desc = "time of day (HH:MM)" },
  { token = "{clock.12hr}",       desc = "time of day, 12-hour" },
  { token = "{clock.date}",       desc = "date (MM/DD)" },
  { token = "{played}",           desc = "time played this session (1h 15m 25s)" },
  { token = "{played.clock}",     desc = "session time as 1:15:25" },
  { token = "{speed}",            desc = "live speed % (0 at rest; works flying)" },
  { token = "{speed.pct}",        desc = "live speed % (same as {speed})" },
  { token = "{speed.yards}",      desc = "live speed in yd/s" },
  { token = "{speed.raw}",        desc = "live speed number (no unit)" },
  { token = "{zone}",             desc = "current zone" },
  { token = "{zone.full}",        desc = "continent > zone > subzone" },
  { token = "{zone.region}",      desc = "continent" },
  { token = "{subzone}",          desc = "subzone" },
  { token = "{coords}",           desc = "player x.xx, y.yy" },
  { token = "{player.name}",      desc = "your name (class-colored)" },
  { token = "{player.gold}",      desc = "wallet gold (largest unit)" },
  { token = "{player.gold.full}", desc = "wallet g/s/c" },
  { token = "{player.level}",     desc = "your level" },
  { token = "{player.class}",     desc = "your class" },
  { token = "{player.realm}",     desc = "your realm" },
  { token = "{wowtoken}",         desc = "WoW Token price" },
  { token = "{wowtoken.trend}",   desc = "Token price trend (up/down/flat)" },
  { token = "{wowtoken.pct(50000)}", desc = "% of a Token for N copper" },
  { token = "{currency(id)}",       desc = "currency name (by ID or name)" },
  { token = "{currency.icon(id)}",  desc = "currency icon" },
  { token = "{currency.count(id)}", desc = "amount held" },
  { token = "{currency.max(id)}",   desc = "overall cap (blank if uncapped)" },
  { token = "{currency.week(id)}",  desc = "earned this week" },
  { token = "{currency.weekmax(id)}", desc = "weekly cap (blank if not weekly-capped)" },
  { token = "{currency.earned(id)}", desc = "total ever earned" },
  { token = "{currency.iscapped(id)}", desc = "yes/no: has an overall cap" },
  { token = "{currency.week.iscapped(id)}", desc = "yes/no: has a weekly cap" },
  { token = "{count.bags(id)}",   desc = "item count in bags (replace id)" },
  { token = "{count.all(id)}",    desc = "item count bags+bank (replace id)" },
  { token = "{item(id)}",         desc = "item name by ID/link (replace id)" },
  { token = "{item.icon(id)}",    desc = "item icon" },
  { token = "{item.value(id)}",   desc = "item price" },
  { token = "{durability}",        desc = "equipped durability %" },
  { token = "{durability.low}",    desc = "lowest single-piece durability %" },
  { token = "{durability.repair}", desc = "repair-all cost" },
  { token = "{bags}",              desc = "free bag slots" },
  { token = "{bags.total}",        desc = "total bag slots" },
  { token = "{bags.used}",         desc = "used bag slots" },
  { token = "{ilvl}",              desc = "equipped item level" },
  { token = "{xp.pct}",            desc = "XP % to next level" },
  { token = "{xp.cur}",            desc = "current XP" },
  { token = "{xp.max}",            desc = "XP needed for next level" },
  { token = "{xp.togo}",           desc = "XP remaining to next level (max - current)" },
  { token = "{xp.rested}",         desc = "rested XP" },
  { token = "{fps}",               desc = "frames per second" },
  { token = "{latency}",           desc = "world latency (ms)" },
  { token = "{latency.home}",      desc = "home latency (ms)" },
  { token = "{perf}",              desc = "fps + latency combined" },
  { token = "{warband.gold}",      desc = "Warband bank gold (after first open)" },
  { token = "{reset.daily}",       desc = "time until daily reset" },
  { token = "{reset.weekly}",      desc = "time until weekly reset" },
  { token = "{mail}",              desc = "\"Mail\" when unread mail is waiting" },
  { token = "{br}",               desc = "line break" },
}

-- ===================== zone / subzone / coords (ambient, C_Map) =====================

-- zone: current zone name. facet "full" = "Zone > Subzone" when subzone is distinct.
-- subzone: the minor area name (GetSubZoneText).
-- coords: player map position as "xx.x, yy.y" — empty string if position unavailable.

-- The player's full map chain, best→root: { name, mapType } per level. The real C_Map tree
-- nests variably (3, 4, even 5 deep): it can stack TWO continents (outer = classic continent,
-- inner = expansion area), multiple zone levels, then the sub-zone leaf.
local function mapChain()
  local chain = {}
  local mapID, guard = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"), 0
  while mapID and guard < 16 do
    guard = guard + 1
    local info = C_Map.GetMapInfo(mapID)
    if not info then break end
    chain[#chain + 1] = { name = info.name or "", mapType = info.mapType }
    mapID = info.parentMapID
    if not mapID or mapID == 0 then break end
  end
  return chain
end
local function isContinent(t) return Enum and Enum.UIMapType and t == Enum.UIMapType.Continent end

-- zone: bare = current zone (GetZoneText). Facets:
--   full   = the whole location chain, broad→specific, from the INNERMOST continent down to the
--            sub-zone (drops the cosmic/world levels AND any outer continent above the innermost).
--            Variable depth; matches {zone.region} for the continent it starts at.
--   region = the most-specific (innermost) continent — matches Haul ns.ZoneTiers' region.
--   sub    = the sub-zone (GetSubZoneText).
Tpl.RegisterType("zone", function(v, facet, ctx)
  if facet == "region" then
    for _, e in ipairs(mapChain()) do if isContinent(e.mapType) then return e.name, false end end
    return "", false
  end
  if facet == "sub" then return (GetSubZoneText and GetSubZoneText()) or "", false end
  if facet == "full" then
    local chain = mapChain()
    local startIdx = #chain                         -- fall back to the root if no continent found
    -- INNERMOST continent: mapChain() is best→root (chain[1] = most specific), so the FIRST
    -- continent found scanning best→root is the innermost. Drops an outer continent in a
    -- two-continent timeline chain — matching what {zone.region} already returns.
    for i = 1, #chain do if isContinent(chain[i].mapType) then startIdx = i; break end end  -- INNERMOST continent
    local out = {}
    for i = startIdx, 1, -1 do if chain[i].name ~= "" then out[#out + 1] = chain[i].name end end
    local sub = (GetSubZoneText and GetSubZoneText()) or ""
    if sub ~= "" and (#out == 0 or out[#out] ~= sub) then out[#out + 1] = sub end
    return table.concat(out, " > "), false
  end
  if facet == nil or facet == "zone" then
    return (GetZoneText and GetZoneText()) or "", false   -- bare {zone} / {zone.zone}
  end
  return nil   -- unrecognized facet → engine renders the literal (typo aid)
end)

Tpl.RegisterType("subzone", function(v, facet, ctx)
  return (GetSubZoneText and GetSubZoneText()) or "", false
end)

Tpl.RegisterType("coords", function(v, facet, ctx)
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return "", false end
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return "", false end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return "", false end
  local x, y = pos:GetXY()
  if not (x and y) then return "", false end
  return ("%.2f, %.2f"):format(x * 100, y * 100), false
end)

-- clock: the wall clock (time of day). The engine's built-in "time" type formats a unix
-- TIMESTAMP; this no-value type reads the live clock at render time. Not self-colored. Facets:
--   bare / .24hr / .short → date("%H:%M")     (24-hour, e.g. 14:05; bare defaults to 24-hour)
--   .12hr                 → 12-hour + AM/PM    (e.g. "2:05 PM" — leading "0" on the hour stripped)
--   .full                 → date("%H:%M:%S")   (e.g. 14:05:32)
--   .date                 → date("%m/%d")      (e.g. 06/24)
--   any OTHER facet       → nil (engine renders the literal — typo aid)
Tpl.RegisterType("clock", function(v, facet, ctx)
  if facet == nil or facet == "24hr" or facet == "short" then
    return date("%H:%M"), false
  elseif facet == "12hr" then
    return (date("%I:%M %p"):gsub("^0", "")), false   -- "02:05 PM" → "2:05 PM"
  elseif facet == "full" then
    return date("%H:%M:%S"), false
  elseif facet == "date" then
    return date("%m/%d"), false
  end
  return nil   -- unrecognized facet → engine renders the literal (typo aid)
end)

-- played: time in game THIS SESSION — a DURATION (seconds since login). Reload-safe: the host
-- addon captures/persists the login EPOCH (a true fresh login, surviving /reload) and feeds it via
-- Tpl.SetSessionLogin; this resolver just renders elapsed = time() - login. "-" until a login is set.
-- Money-style coloration (SELF-COLORED, like the money type): the NUMBERS are locked white and the
-- unit LETTERS follow the money denominations — hours = GOLD, minutes = SILVER, seconds = COPPER.
-- Self-colored so a template base / :color can't recolor it. Facets:
--   bare / .words → "1h 15m 25s" (all non-zero h/m/s parts, space-joined; 0 → "0s"; colored letters)
--   .clock / .hms → "1:15:25"     (H:MM:SS, or M:SS under an hour; whole string white)
--   .h / .m / .s  → raw component numbers (white)
--   any OTHER facet → nil (engine renders the literal — typo aid)
--   no login set   → "-" (plain, not self-colored)
-- NOTE: the engine's "duration" type truncates to the two most-significant parts (→ "1h 15m"), so
-- {played}/.words builds the full h/m/s word string itself to show all three parts (per the spec
-- example "1h 15m 25s"); the per-component math mirrors the duration type.
function Tpl.SetSessionLogin(unix) Tpl._loginUnix = tonumber(unix) end

-- money-parity coloration: white number + denomination-colored unit letter (gold/silver/copper),
-- mirroring the engine's coin() span format ("|cffffffff"..num.."|r|c"..c..unit.."|r").
local PL_WHITE = "|cffffffff"
local PL_H, PL_M, PL_S = "ffffd700", "ffc7c7cf", "ffeda55f"   -- gold / silver / copper (money parity)
local function plPart(num, unit, c) return PL_WHITE .. num .. "|r|c" .. c .. unit .. "|r" end

Tpl.RegisterType("played", function(v, facet, ctx)
  local base = Tpl._loginUnix
  if not (base and time) then return "-", false end
  local secs = math.max(0, time() - base)
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  local s = secs % 60
  if facet == nil or facet == "words" then
    local parts = {}
    if h > 0 then parts[#parts + 1] = plPart(h, "h", PL_H) end
    if m > 0 then parts[#parts + 1] = plPart(m, "m", PL_M) end
    if s > 0 or #parts == 0 then parts[#parts + 1] = plPart(s, "s", PL_S) end
    return table.concat(parts, " "), true                 -- "1h 15m 25s" (self-colored, money parity)
  elseif facet == "clock" or facet == "hms" then
    -- plain (NOT self-colored) so the template's :color / base color applies — unlike the
    -- word form, the colon format carries no fixed money styling.
    if h > 0 then return ("%d:%02d:%02d"):format(h, m, s), false end
    return ("%d:%02d"):format(m, s), false                  -- M:SS under an hour (colorable)
  elseif facet == "h" then return tostring(h), false        -- raw parts: colorable too
  elseif facet == "m" then return tostring(m), false
  elseif facet == "s" then return tostring(s), false
  end
  return nil                                              -- unknown facet → literal (the standard)
end)

-- speed: the player's LIVE movement velocity — how fast you're actually moving RIGHT NOW, so it's 0 while
-- standing still and ticks up as you move. Reads GetUnitSpeed's current velocity (ground / water / steady
-- flight); in Skyriding / Dragonriding that stays ~0, so we use the live forward glide speed from
-- C_PlayerInfo.GetGlidingInfo instead. base run = 7 yd/s = 100%. Only three facets (kept intentionally small):
--   bare / .pct / .percent → "104%"      (live velocity %; 0 at rest, works flying incl. dragonriding)
--   .yards / .yd           → "9.1 yd/s"  (live velocity in yd/s)
--   .raw                   → "9.1"        (live velocity number, no unit — for composing)
--   any OTHER facet        → nil (engine renders the literal — the standard typo aid)
-- NOTE: this is a time-varying token — the host bar must re-render on a timer (not only on data events) or it
-- freezes at the last render (e.g. keeps showing your last moving speed after you stop). The Gadgets bars tick
-- every second; a Haul watcher/bar needs the same to show live speed.
-- SECRET-VALUE GUARD (WoW 12.0 "Midnight"): GetUnitSpeed / GetGlidingInfo can return SECRET values (e.g. the
-- glide speed while skyriding, to block speed-hacking). Formatting a secret into a string yields a secret
-- string, and the engine's gsub then throws "invalid replacement value (a secret)". So every read is filtered
-- through issecretvalue and dropped to a plain 0 if secret — `current` is ALWAYS a plain number below, so the
-- returned string is never secret. `and`-short-circuit keeps a secret boolean out of the `if` condition.
local SPEED_BASE = BASE_MOVEMENT_SPEED or 7   -- yards/second at 100% run speed
local function safeNum(x)   -- plain number, or nil if secret / not a number
  if issecretvalue and issecretvalue(x) then return nil end
  return type(x) == "number" and x or nil
end
Tpl.RegisterType("speed", function(v, facet, ctx)
  local current = 0
  if GetUnitSpeed then current = safeNum(GetUnitSpeed("player")) or 0 end
  -- Skyriding / Dragonriding: GetUnitSpeed's currentVelocity stays ~0 while gliding, so it reads blank aloft.
  -- C_PlayerInfo.GetGlidingInfo returns the live forward GLIDE speed (yd/s) — the real dragonriding number
  -- (may be secret while gliding; safeNum drops it to nil and we keep the current-velocity fallback).
  if C_PlayerInfo and C_PlayerInfo.GetGlidingInfo then
    local isGliding, _, forwardSpeed = C_PlayerInfo.GetGlidingInfo()
    local secret = issecretvalue and (issecretvalue(isGliding) or issecretvalue(forwardSpeed))
    local fwd = safeNum(forwardSpeed)
    if not secret and isGliding and fwd then current = fwd end
  end
  if facet == nil or facet == "pct" or facet == "percent" then
    return ("%d%%"):format(math.floor(current / SPEED_BASE * 100 + 0.5)), false
  elseif facet == "yards" or facet == "yd" then
    return ("%.1f yd/s"):format(current), false
  elseif facet == "raw" then
    return ("%.1f"):format(current), false
  end
  return nil
end)

-- ===================== player.<facet> (ambient) =====================

-- Facets: name (class-colored, self-colored), realm, class, level, race,
--         faction, guild, gold (wallet — reuses the engine's money type, self-colored).
-- Default facet = name.

local function classColorHex(classFile)
  -- RAID_CLASS_COLORS[classFile].colorStr is "ffRRGGBB"; we want "RRGGBB" for |cff<hex>.
  local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
  if not c then return nil end
  -- colorStr may be "ffRRGGBB" or absent on older builds; fall back to r/g/b floats.
  if c.colorStr then return c.colorStr:sub(3) end
  if c.r and c.g and c.b then
    return ("%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
  end
end

Tpl.RegisterType("player", function(v, facet, ctx)
  facet = facet or "name"

  -- PARITY: cache-backed facets (professions, and future state facets) resolve through the SAME
  -- path as {char(...)} — delegate to the cache instead of reinventing per-token logic.
  -- {player.professions} / {player.professions.fishing} → Store.Display("char", CharIndex(), {facet=...})
  if facet == "professions" or facet:find("^professions%.") then
    local Store = LibStub and LibStub:GetLibrary("GECStore-1.0", true)
    if Store and Store.Display and Store.CharIndex then
      return Store.Display("char", Store.CharIndex(), { facet = facet }), true
    end
    return "", false
  end

  if facet == "name" then
    local _, classFile = UnitClass("player")
    local hex = classFile and classColorHex(classFile)
    local name = UnitName("player") or ""
    if hex then return "|cff" .. hex .. name .. "|r", true end
    return name, false
  elseif facet == "realm" then
    return GetRealmName() or "", false
  elseif facet == "class" then
    return (UnitClass("player")) or "", false     -- returns the localised class name
  elseif facet == "level" then
    return tostring(UnitLevel("player") or 0), false
  elseif facet == "race" then
    return (UnitRace("player")) or "", false      -- localised race name
  elseif facet == "faction" then
    return (UnitFactionGroup("player")) or "", false
  elseif facet == "guild" then
    return (GetGuildInfo("player")) or "", false  -- first return = guild name
  elseif facet == "gold" then
    -- wallet money as MoneyShort = the LARGEST denomination only ("1,234g" for anyone with gold),
    -- self-colored. Matches the money type's bare=short convention. Use {player.gold.full} for g/s/c.
    return Tpl.types.money(GetMoney and GetMoney() or 0, "short", ctx)
  elseif facet == "gold.full" then
    return Tpl.types.money(GetMoney and GetMoney() or 0, "full", ctx)   -- full g/s/c breakdown
  end
  return "", false
end)

-- ===================== currency (keyed by currencyID OR name via data/arg) =====================

-- value = currencyID (number) OR currency name (string), so {currency(2245)} and
-- {currency(Valorstones)} both work. Facets:
--   name (default), icon (16px texture, self-colored),
--   count (quantity held), max (overall cap), earned (total ever earned),
--   week (earned this week), weekmax (weekly cap),
--   iscapped / week.iscapped ("yes"/"no": does it have an overall / weekly cap).
-- Blizzard reports an uncapped currency as cap 0; max/weekmax render BLANK (not "0") in that
-- case so an uncapped currency self-hides instead of showing a misleading "0". Falls back to the
-- raw value string if the currency can't be resolved (unknown id, or a name not yet in the list).

-- Lazy name→id index for the name form. Built on first name lookup by scanning the player's
-- currency list (only currencies the player has discovered are resolvable by name); invalidated
-- on CURRENCY_DISPLAY_UPDATE so newly-earned currencies become resolvable. One frame on the
-- lib singleton (the wowtokenState pattern).
local function currencyNameToID(name)
  local st = Tpl._currencyIndex
  if not st then
    st = {}
    Tpl._currencyIndex = st
    if CreateFrame then
      local f = CreateFrame("Frame")
      f:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
      f:SetScript("OnEvent", function() st.map = nil end)   -- invalidate; rebuilt on next lookup
      st.frame = f
    end
  end
  if not st.map then
    local map = {}
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
      for i = 1, (C_CurrencyInfo.GetCurrencyListSize() or 0) do
        local info = C_CurrencyInfo.GetCurrencyListInfo and C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader and info.name then
          local link = C_CurrencyInfo.GetCurrencyListLink and C_CurrencyInfo.GetCurrencyListLink(i)
          local id = link and tonumber(link:match("currency:(%d+)"))
          if id then map[info.name:lower()] = id end
        end
      end
    end
    st.map = map
  end
  return st.map[name:lower()]
end

Tpl.RegisterType("currency", function(v, facet, ctx)
  local id = tonumber(v)
  if not id and type(v) == "string" and v ~= "" then
    id = currencyNameToID(v)                               -- name form: {currency(Valorstones)}
  end
  if not (id and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then
    return tostring(v), false
  end
  local info = C_CurrencyInfo.GetCurrencyInfo(id)
  if not info then return tostring(v), false end
  facet = facet or "name"
  if facet == "name" then
    return info.name or tostring(v), false
  elseif facet == "icon" then
    if info.iconFileID then return "|T" .. info.iconFileID .. ":16|t", true end
    return "", true
  elseif facet == "count" then
    return Tpl.types.number(info.quantity or 0, nil, ctx)
  elseif facet == "max" then
    local cap = info.maxQuantity or 0
    if cap == 0 then return "", false end                 -- uncapped → blank (0 reads as misleading)
    return Tpl.types.number(cap, nil, ctx)
  elseif facet == "earned" then
    return Tpl.types.number(info.totalEarned or 0, nil, ctx)
  elseif facet == "week" then
    return Tpl.types.number(info.quantityEarnedThisWeek or 0, nil, ctx)
  elseif facet == "weekmax" then
    local cap = info.maxWeeklyQuantity or 0
    if cap == 0 then return "", false end                 -- not weekly-capped → blank
    return Tpl.types.number(cap, nil, ctx)
  elseif facet == "iscapped" then
    return ((info.maxQuantity or 0) > 0) and "yes" or "no", false
  elseif facet == "week.iscapped" then
    return ((info.maxWeeklyQuantity or 0) > 0) and "yes" or "no", false
  end
  return nil                                               -- unknown facet → literal (typo aid)
end)

-- Discovery helper for the {currency(id)} token: print the player's currencies as "ID  Name",
-- optionally filtered by a case-insensitive name SUBSTRING (so "void" matches "Nebulous Void Core"
-- — partial or full both work). Sorted by name. Returns the number printed. Addons wire this to a
-- slash command so users can look up the numeric ID when a currency isn't resolvable by name yet.
function Tpl.DumpCurrencies(filter)
  filter = (filter and filter ~= "") and filter:lower() or nil
  if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize) then
    print("|cffffd200Currencies|r: currency API unavailable")
    return 0
  end
  local rows = {}
  for i = 1, (C_CurrencyInfo.GetCurrencyListSize() or 0) do
    local info = C_CurrencyInfo.GetCurrencyListInfo and C_CurrencyInfo.GetCurrencyListInfo(i)
    if info and not info.isHeader and info.name then
      if (not filter) or info.name:lower():find(filter, 1, true) then
        local link = C_CurrencyInfo.GetCurrencyListLink and C_CurrencyInfo.GetCurrencyListLink(i)
        local id = link and tonumber(link:match("currency:(%d+)"))
        if id then rows[#rows + 1] = { id = id, name = info.name } end
      end
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  print(("|cffffd200Currencies%s:|r %d"):format(filter and (" matching '" .. filter .. "'") or "", #rows))
  for _, r in ipairs(rows) do
    print(("  |cff00ff00%d|r  %s"):format(r.id, r.name))
  end
  return #rows
end

-- ===================== count (keyed by itemID — current character, pure C_Item) =====================

-- value = itemID (from the data table, e.g. data.count = 12345).
-- Facets (all live, THIS character, via C_Item.GetItemCount):
--   "bags"          (default) — carried bags only
--   "all" / "total"           — bags + bank
--   "bank"                    — bank only (all minus bags)
--   "warband"                 — Warband bank only (warband minus bags)
-- CROSS-CHARACTER / external-addon totals (account/guild, TSM-backed) live in the GECBridge `tsm`
-- namespace ({tsm.count.account(id)} / {tsm.count.guild(id)} — see GECTemplate-Bridge-TSM.lua), NOT
-- here: `count` stays a pure, dependency-free C_Item resolver.
-- Note: bank/warband locations return 0 until the player opens them in the current session.

local function itemCount(id, includeBank, includeWarband)
  if not (C_Item and C_Item.GetItemCount) then return 0 end
  return C_Item.GetItemCount(id, includeBank or false, false, includeWarband or false) or 0
end

Tpl.RegisterType("count", function(v, facet, ctx)
  -- C_Item.GetItemCount accepts an itemID, an item NAME, or an item link — pass the value
  -- through (numeric if it parses, else the raw name/link) so {count.bags(Hearthstone)} works.
  local id = tonumber(v) or v
  if id == nil or id == "" then return "0", false end
  facet = facet or "bags"
  local n
  if facet == "all" or facet == "total" then
    n = itemCount(id, true, false)
  elseif facet == "bank" then
    -- bank only: (bags + bank) minus bags
    n = itemCount(id, true, false) - itemCount(id, false, false)
  elseif facet == "warband" then
    -- warband only: (bags + warband) minus bags
    n = itemCount(id, false, true) - itemCount(id, false, false)
  else -- "bags"
    n = itemCount(id, false, false)
  end
  return tostring(math.max(0, n or 0)), false
end)

-- ===================== wowtoken (WoW Token price, direct C_WowTokenPublic) =====================
-- Bare {wowtoken} / {wowtoken.price} = current market price as money (self-colored), "-" until known.
-- {wowtoken.trend} = "up" / "down" / "flat" vs the previous reading.
-- {wowtoken.pct(<copper>)} = what % of a Token <copper> buys, e.g. {wowtoken.pct(500000)} → "12.3%".
-- The price isn't instantly available: the API needs UpdateMarketPrice() + the TOKEN_MARKET_PRICE_UPDATED
-- event before GetCurrentMarketPrice() returns. We do that handshake from ONE lazily-created frame (guarded
-- on the lib singleton so multiple embedders share it); consumers pick up the cached value on their next
-- render tick. Lifted from Haul/Token.lua so it's reusable by any addon (watcher, demo, Haul itself).
local function wowtokenState()
  if not Tpl._wowtoken then
    local st = { price = nil, trend = "flat" }
    Tpl._wowtoken = st
    if CreateFrame then
      local f = CreateFrame("Frame")
      f:RegisterEvent("PLAYER_LOGIN")
      f:RegisterEvent("TOKEN_MARKET_PRICE_UPDATED")
      f:SetScript("OnEvent", function(_, event)
        if not C_WowTokenPublic then return end
        if event == "PLAYER_LOGIN" then pcall(C_WowTokenPublic.UpdateMarketPrice) end
        local ok, price = pcall(C_WowTokenPublic.GetCurrentMarketPrice)
        if ok and price and price > 0 then
          if st.price == nil then st.trend = "flat"
          elseif price > st.price then st.trend = "up"
          elseif price < st.price then st.trend = "down"
          else st.trend = "flat" end
          st.price = price
        end
      end)
      st._frame = f
      -- kick an initial fetch in case PLAYER_LOGIN already fired before this token was first rendered
      if C_WowTokenPublic then
        pcall(C_WowTokenPublic.UpdateMarketPrice)
        local ok, price = pcall(C_WowTokenPublic.GetCurrentMarketPrice)
        if ok and price and price > 0 then st.price = price end
      end
      if C_Timer then
        st._ticker = C_Timer.NewTicker(600, function()
          if C_WowTokenPublic then pcall(C_WowTokenPublic.UpdateMarketPrice) end
        end)
      end
    end
  end
  return Tpl._wowtoken
end

-- Trend display — tinted texture arrows + a colored word, self-colored so a template's base
-- color can't recolor them. Byte-identical to Haul/Window.lua's TREND_DISPLAY (and Megaphone's):
-- the default font has no ▲/▼ glyph, so we use the Blizzard arrow textures. yOffset is negative=down
-- (per CreateTextureMarkup). The two textures are NOT symmetric: Arrow-Down-Up's chevron sits higher in
-- its 32×32 canvas than Arrow-Up-Up's, so at the same offset the DOWN arrow rides up off a thin bar — it
-- needs an extra drop. 12px (not 14) so it fits a short gadget bar without poking out the top.
-- NOTE: these offsets are eyeball-tuned; nudge yOffset (5th field) if a bar font makes them sit off-center.
local TR_UP   = "|TInterface\\Buttons\\Arrow-Up-Up:12:12:0:-2:32:32:0:32:0:32:30:255:0|t"
local TR_DOWN = "|TInterface\\Buttons\\Arrow-Down-Up:12:12:0:-6:32:32:0:32:0:32:255:96:96|t"
local TREND_DISPLAY = {
  up   = TR_UP   .. " |cff1eff00up|r",
  down = TR_DOWN .. " |cffff6060down|r",
  flat = "|cff808080flat|r",
}

-- {wowtoken} / {wowtoken.price} / {wowtoken.value} / {wowtoken.short} = price, money SHORT (largest unit)
-- {wowtoken.full}  = price, money FULL (g/s/c)
-- {wowtoken.trend} = arrow + colored word (up/down/flat) vs the previous reading
-- {wowtoken.pct(<copper>)} = what % of a Token <copper> buys
-- {wowtoken.percent} = the % of a Token earned this SESSION — needs session gold (Haul/SBF inject
--                      it later via a feed); standalone has no basis, so it returns "-" for now.
Tpl.RegisterType("wowtoken", function(v, facet, ctx)
  local st = wowtokenState()
  facet = facet or "price"
  if facet == "trend" then
    return TREND_DISPLAY[st.trend or "flat"] or "-", true        -- self-colored (arrows + words)
  elseif facet == "percent" then
    return "-", false                                            -- session %: injected later
  elseif facet == "pct" then
    local copper = tonumber(v)
    if not (st.price and st.price > 0 and copper) then return "-", false end
    return ("%.1f%%"):format(copper / st.price * 100), false
  elseif facet == "price" or facet == "value" or facet == "short" or facet == "full" then
    -- price family: price / value / short → money SHORT; full → money FULL. "-" until known.
    if not (st.price and st.price > 0) then return "-", false end
    return Tpl.types.money(st.price, (facet == "full") and "full" or "short", ctx)
  end
  return nil   -- unrecognized facet → engine renders the literal (typo aid)
end)

-- ===================== price adapters =====================
-- Registered here (not the engine) because they call WoW APIs.

-- vendor: GetItemInfo return 11 = sellPrice (copper). Returns 0 if uncached.
Tpl.RegisterPrice("vendor", function(itemID)
  return (select(11, GetItemInfo(itemID))) or 0
end)

-- tsm: dbmarket via TSM_API. Returns nil if TSM is absent.
Tpl.RegisterPrice("tsm", function(itemID)
  if not TSM_API then return nil end
  local s = TSM_API.ToItemString("i:" .. itemID)
  if not s then return nil end
  local ok, v = pcall(TSM_API.GetCustomPriceValue, "dbmarket", s)
  return ok and v or nil
end)

-- auctionator: commodity-friendly (ID lookup first). Returns nil if absent.
Tpl.RegisterPrice("auctionator", function(itemID)
  if not (Auctionator and Auctionator.API and Auctionator.API.v1) then return nil end
  local ok, v = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "GECTemplate", itemID)
  return ok and v or nil
end)

-- ===================== item (keyed by itemID or item link) =====================
-- value = itemID number/string, or a full item link (GetItemInfo accepts both).
-- Facets: name (default, rarity-colored self), icon, value (price chain, money self),
--         ilvl, link, quality (numeric), type (item type string).
-- Async-safe: returns "[id]" placeholder when the client hasn't cached the item yet.
-- The consumer's frame refresh / ITEM_DATA_LOAD_RESULT will re-trigger rendering.

-- Wrap a name in rarity color using ITEM_QUALITY_COLORS, mirroring Haul/Core.lua:
--   .color:WrapTextInColorCode (ColorMixin, retail 10.x+) takes precedence;
--   .hex is "ffRRGGBB" (alpha+rgb), so use "|c" not "|cff".
local function rarityWrap(name, quality)
  local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
  if not q then return name, false end
  if q.color and q.color.WrapTextInColorCode then
    return q.color:WrapTextInColorCode(name), true
  end
  if q.hex then
    return "|c" .. q.hex .. name .. "|r", true
  end
  return name, false
end

-- Default price chain: renderer's priceFn → TSM → Auctionator → vendor.
local function itemPrice(itemID, ctx)
  if ctx and ctx.priceFn then
    local v = ctx.priceFn(itemID)
    if v and v > 0 then return v end
  end
  for _, src in ipairs({ "tsm", "auctionator", "vendor" }) do
    local fn = Tpl.prices[src]
    if fn then
      local v = fn(itemID)
      if v and v > 0 then return v end
    end
  end
  return 0
end

Tpl.RegisterType("item", function(v, facet, ctx)
  -- GetItemInfo accepts an itemID (number or numeric string) or an item link.
  local name, link, quality, level, _, itemType, _, _, _, icon, _ = GetItemInfo(v)
  if not name then
    -- Item not yet cached by the client — return a placeholder; the consumer re-renders on
    -- ITEM_DATA_LOAD_RESULT or its next refresh cycle.
    return "[" .. tostring(v) .. "]", false
  end
  facet = facet or "name"
  if facet == "name" then
    return rarityWrap(name, quality)
  elseif facet == "icon" then
    return icon and ("|T" .. icon .. ":16|t") or "", true
  elseif facet == "link" then
    return link or name, true
  elseif facet == "type" then
    return itemType or "", false
  elseif facet == "ilvl" then
    return tostring(level or 0), false
  elseif facet == "quality" then
    return tostring(quality or 0), false
  elseif facet == "value" then
    local id = tonumber(v) or v      -- keep as-is for GetItemInfo; price adapters want an ID
    return Tpl.types.money(itemPrice(id, ctx), "full", ctx)
  end
  -- unknown facet → fall back to name
  return rarityWrap(name, quality)
end)

-- ===================== Tier 1 character-status tokens (ambient, poll-class) =====================
-- All read the live client at render time. Gadget bars re-render on a ticker, so these need no
-- event wiring — they read fresh each tick. Reuse percent/number/money; unknown facet → nil (literal).

-- durability: bare = overall equipped %, .low = lowest single piece %, .repair = repair-all cost.
Tpl.RegisterType("durability", function(v, facet, ctx)
  if facet == "repair" then
    -- GetRepairAllCost() → (cost, canRepair). Cache-free; refreshes when a merchant is open.
    local cost = (GetRepairAllCost and GetRepairAllCost()) or 0
    return Tpl.types.money(cost, "short", ctx)
  end
  if facet ~= nil and facet ~= "low" then return nil end   -- unknown facet → literal
  local curTotal, maxTotal, lowest = 0, 0, nil
  for slot = (INVSLOT_FIRST_EQUIPPED or 1), (INVSLOT_LAST_EQUIPPED or 19) do
    local cur, max = GetInventoryItemDurability(slot)
    if cur and max and max > 0 then
      curTotal = curTotal + cur
      maxTotal = maxTotal + max
      local p = cur / max
      if not lowest or p < lowest then lowest = p end
    end
  end
  if maxTotal == 0 then return "-", false end              -- nothing with durability equipped
  if facet == "low" then
    return Tpl.types.percent(lowest or 1, nil, ctx)
  end
  return Tpl.types.percent(curTotal / maxTotal, nil, ctx)  -- bare = overall
end)

-- bags: bare/.free = free slots, .total = all slots, .used = total - free.
Tpl.RegisterType("bags", function(v, facet, ctx)
  facet = facet or "free"
  if facet ~= "free" and facet ~= "total" and facet ~= "used" then return nil end
  local free, total = 0, 0
  for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
    if C_Container then
      total = total + (C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag) or 0)
      free  = free  + (C_Container.GetContainerNumFreeSlots and C_Container.GetContainerNumFreeSlots(bag) or 0)
    end
  end
  if facet == "free"  then return Tpl.types.number(free, nil, ctx) end
  if facet == "total" then return Tpl.types.number(total, nil, ctx) end
  return Tpl.types.number(total - free, nil, ctx)           -- used
end)

-- ilvl: equipped item level (GetAverageItemLevel's 2nd return). Bare only.
Tpl.RegisterType("ilvl", function(v, facet, ctx)
  if facet ~= nil then return nil end
  local _, equipped = GetAverageItemLevel()
  return ("%.1f"):format(equipped or 0), false
end)

-- xp: bare/.pct = % to next level (empty at max level so the watcher hides), .cur/.max raw, .rested.
Tpl.RegisterType("xp", function(v, facet, ctx)
  local cur, max = UnitXP("player"), UnitXPMax("player")
  facet = facet or "pct"
  if facet == "pct" then
    if not max or max == 0 then return "", false end        -- max level → contextually empty
    return Tpl.types.percent(cur / max, nil, ctx)
  elseif facet == "cur" then
    return Tpl.types.number(cur, nil, ctx)
  elseif facet == "max" then
    return Tpl.types.number(max, nil, ctx)
  elseif facet == "togo" then
    if not max or max == 0 then return "", false end        -- max level → contextually empty
    return Tpl.types.number(math.max(0, max - (cur or 0)), nil, ctx)
  elseif facet == "rested" then
    local r = GetXPExhaustion()
    if r then return Tpl.types.number(r, nil, ctx) end
    return "", false
  end
  return nil
end)

-- fps: frames per second (bare only).
Tpl.RegisterType("fps", function(v, facet, ctx)
  if facet ~= nil then return nil end
  return ("%d"):format(math.floor((GetFramerate and GetFramerate()) or 0)), false
end)

-- latency: bare/.world = world ms, .home = home ms. GetNetStats() → (in, out, home, world).
Tpl.RegisterType("latency", function(v, facet, ctx)
  facet = facet or "world"
  if facet ~= "world" and facet ~= "home" then return nil end
  local _, _, home, world = GetNetStats()
  return ("%dms"):format((facet == "world") and (world or 0) or (home or 0)), false
end)

-- perf: combined performance readout. Bare = "60 fps · 40 ms" (fps + world latency);
-- .fps = framerate, .latency/.world = world ms, .home = home ms. Wraps the same reads as
-- {fps}/{latency} so a bar can show one tidy "perf" field instead of two tokens.
Tpl.RegisterType("perf", function(v, facet, ctx)
  local fps = math.floor((GetFramerate and GetFramerate()) or 0)
  local _, _, home, world = GetNetStats()
  if facet == nil then
    return ("%d fps · %d ms"):format(fps, world or 0), false
  elseif facet == "fps" then
    return ("%d"):format(fps), false
  elseif facet == "latency" or facet == "world" then
    return ("%dms"):format(world or 0), false
  elseif facet == "home" then
    return ("%dms"):format(home or 0), false
  end
  return nil
end)

-- warband: account-wide (Warband) bank data. .gold (default) = deposited gold, self-colored money.
-- Reads 0 until the player opens the Warband bank in-session. Namespace left open so future
-- Warband data (slots, currencies) can hang off {warband.*} as those APIs are wired in.
Tpl.RegisterType("warband", function(v, facet, ctx)
  facet = facet or "gold"
  if facet == "gold" then
    local money = 0
    if C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType then
      money = C_Bank.FetchDepositedMoney(Enum.BankType.Account) or 0
    end
    return Tpl.types.money(money, "short", ctx)
  end
  return nil
end)

-- reset: countdown to the next game reset. .daily (default) / .weekly, rendered as a duration.
Tpl.RegisterType("reset", function(v, facet, ctx)
  facet = facet or "daily"
  if not C_DateAndTime then return "-", false end
  local secs
  if facet == "daily" then
    secs = C_DateAndTime.GetSecondsUntilDailyReset and C_DateAndTime.GetSecondsUntilDailyReset()
  elseif facet == "weekly" then
    secs = C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()
  else
    return nil
  end
  if not secs then return "-", false end
  return Tpl.types.duration(secs, nil, ctx)
end)

-- mail: "Mail" when unread mail is waiting (the same flag the default UI envelope reads — no
-- mailbox needed), else "" so the watcher hides. Bare only.
Tpl.RegisterType("mail", function(v, facet, ctx)
  if facet ~= nil then return nil end
  return (HasNewMail and HasNewMail()) and "Mail" or "", false
end)

-- {megaphone} = the Megaphone addon's latest emitted message ("" when none / addon absent). The
-- resolver lives HERE in the library — front-ends (a Haul header bar, a Gadgets watcher) just put
-- {megaphone} in a template and let it hide when empty; they never reach into the Megaphone addon.
-- Lazy global read so it declines gracefully to "" when Megaphone isn't installed.
Tpl.RegisterType("megaphone", function(v, facet, ctx)
  if facet ~= nil then return nil end
  return (Megaphone and Megaphone.Last and Megaphone.Last()) or "", false
end)

-- ===================== entity tokens (registry-backed, delegate to GECStore.Display) =====================
-- {char(ref)} {spell(id)} {faction(id)} {place(idx).facet} — one render primitive so an entity looks
-- identical in a bar and a log row. ref = interned index (char/place) or id (simple) or GUID/name key (char).
-- place facet = granularity (full=continent->leaf, detail=leaf, zone, continent, continent_zone).
-- Lazy GECStore handle; declines (nil) when the store is absent so the token stays literal, never errors.
-- NOTE: item + currency entity tokens deferred — those names collide with the existing ambient {item}/
-- {currency} resolvers above; reconcile later (a bar shows the rich ambient token, a log shows Display
-- directly). {zone}/{player} are likewise ambient live resolvers and intentionally left alone.
local function entityResolver(kind)
  return function(v, facet, _ctx)
    local Store = LibStub and LibStub:GetLibrary("GECStore-1.0", true)
    if not (Store and Store.Display) then return nil end
    local ref = tonumber(v) or v
    -- char: a non-numeric, non-GUID arg is a NAME -> resolve to the interned index (most-recently-seen)
    if kind == "char" and type(ref) == "string" and not ref:find("^Player%-") and Store.CharByName then
      ref = Store.CharByName(ref) or ref
    end
    -- place facet -> granularity; char facet -> the state facet; others take no opts
    local opts
    if kind == "place" and facet then opts = { granularity = facet }
    elseif kind == "char" and facet then opts = { facet = facet } end
    return Store.Display(kind, ref, opts), true   -- selfColored: Display already colored it
  end
end
for _, k in ipairs({ "char", "spell", "faction", "place" }) do
  Tpl.RegisterType(k, entityResolver(k))
end
