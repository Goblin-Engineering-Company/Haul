-- GECWowToken-1.0 — the WoW Token domain: price, "% of a token", and a price trend, PLUS the one shared
-- trend DISPLAY so Haul, Gadgets and Megaphone render it identically.
--
-- This lib now OWNS the token end-to-end (Phase 1 of the service spec:
-- docs/superpowers/specs/2026-07-30-gecwowtoken-service-design.md): it polls C_WowTokenPublic (NO Auction
-- House, no AH addon), keeps a persisted stock-ticker price history, rolls that up per day, tracks all-time
-- stats, computes a REAL windowed trend (current vs the reading ~window-ago, not "delta since last read"),
-- builds a tooltip, and serves the token API. It does NOT graph history yet — that's a later phase.
--
-- MESH (why an embedded lib can own region-wide data): embedded-lib SavedVariables are per HOST addon, so
-- Haul, Gadgets and Megaphone each get their OWN saved copy. To avoid three divergent histories, every host
-- hands us its persistent table via lib.RegisterStore(tbl); on PLAYER_LOGIN (after all SVs have loaded) we
-- MERGE every registered store into ONE canonical in-memory model and then point EVERY store's region slot
-- at that single model — so all hosts share it live and each persists the full history (redundant + any host
-- loading alone still has everything). LibStub guarantees ONE lib instance, so exactly one poller runs.
local MAJOR, MINOR = "GECWowToken-1.0", 11   -- 11: BuildTooltip history rows date-stamp anything not from today (%m/%d %H:%M); readings are kept 7 days, so a time-only stamp was ambiguous across days.
local lib = LibStub and LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end   -- an equal-or-newer copy already loaded (embed-sync: bump MINOR on any change)

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────
-- TUNABLES (everything-configurable) — the only magic numbers; change here, no rebuild of logic needed.
local DEFAULT_WINDOW             = 86400              -- trend window in seconds (24h) — GetTrend default
local FLAT_PCT                   = 0.5                -- |pct change| below this reads "flat"
local POLL_INTERVAL              = 600                -- seconds between UpdateMarketPrice polls (~10 min)
local READINGS_RETENTION_SECONDS = 7 * 24 * 60 * 60  -- drop readings older than this (~7 days)
local READINGS_MAX               = 2000              -- hard cap on stored readings (whichever bound hits first)
local DAILY_MAX                  = 365               -- keep ~1 year of daily rollups
local DEFAULT_TIP_DEPTH          = 15                -- readings shown by BuildTooltip
local SCHEMA                     = 1                 -- persisted model schema version (meta.v)
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────

-- Trend display: just the colored WORD — green "up", red "down", grey "flat". NO arrow graphic. A word is text,
-- so it aligns and scales with whatever font renders it, in every renderer, for free. (Texture/glyph arrows were
-- tried and dropped: a texture can't be centred+sized consistently across Haul's and Gadgets' different fonts,
-- and the ▲/▼ glyph draws as a box in the header/bar fonts. Not worth it for a two-letter indicator.)
local TREND_WORD = {
  up   = "|cff1eff00up|r",
  down = "|cffff6060down|r",
  flat = "|cff808080flat|r",
}
lib.TREND_DISPLAY = TREND_WORD   -- back-compat for consumers reading lib.TREND_DISPLAY[dir]

-- TrendDisplay(trend) — the colored word for "up"/"down"/"flat". The single source of the visual.
function lib.TrendDisplay(trend)
  return TREND_WORD[trend or "flat"] or TREND_WORD.flat
end

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────
-- Model helpers. A model = { readings, daily, stats, meta } for ONE region. Prices are copper. Money is never
-- formatted here — GetPrice returns raw copper and the HOST formats it (BuildTooltip is the one place we
-- render, via GECTemplate's standard money text).

local function regionKey()
  local r
  if GetCurrentRegion then
    local ok, v = pcall(GetCurrentRegion)
    if ok then r = v end
  end
  return "region:" .. tostring(r or "?")   -- stable per-region key; token price is region-wide
end

local function newModel()
  return {
    readings = {},                                     -- array of { t, price }, ascending by t
    daily    = {},                                     -- map dayKey -> rollup
    stats    = { high = nil, low = nil, sum = 0, count = 0 },
    meta     = { region = regionKey(), v = SCHEMA, lastFetch = nil },
  }
end

-- all-time extreme, tracked with the timestamp so the tooltip can show when it happened
local function statExtreme(stats, which, price, t)
  local cur = stats[which]
  if which == "high" then
    if not cur or price > cur.price then stats[which] = { price = price, t = t } end
  else
    if not cur or price < cur.price then stats[which] = { price = price, t = t } end
  end
end

local function foldIntoStats(stats, t, price)
  statExtreme(stats, "high", price, t)
  statExtreme(stats, "low",  price, t)
  stats.sum   = (stats.sum   or 0) + price
  stats.count = (stats.count or 0) + 1
end

-- fold ONE reading into its daily rollup. Called in ascending-t order (live: newest last; rebuild: sorted),
-- so `open` is the first price of the day and `close` the last. highT/lowT record when each extreme landed.
local function foldIntoDaily(daily, dk, t, price)
  local d = daily[dk]
  if not d then
    daily[dk] = { day = dk, open = price, high = price, low = price, close = price,
                  sum = price, count = 1, avg = price, highT = t, lowT = t }
    return
  end
  d.close = price
  if price > d.high then d.high = price; d.highT = t end
  if price < d.low  then d.low  = price; d.lowT  = t end
  d.sum   = d.sum + price
  d.count = d.count + 1
  d.avg   = d.sum / d.count
end

-- Trim readings by BOTH bounds (configurable): drop anything older than the retention window, then cap the
-- count. Mutates in place so the shared canonical array keeps its identity across all registered stores.
local function trimReadings(readings)
  local cutoff = time() - READINGS_RETENTION_SECONDS
  while readings[1] and readings[1].t and readings[1].t < cutoff do table.remove(readings, 1) end
  while #readings > READINGS_MAX do table.remove(readings, 1) end
end

-- Keep only the newest DAILY_MAX day rows (dayKey "%Y-%m-%d" sorts lexicographically == chronologically).
local function trimDaily(daily)
  local keys = {}
  for k in pairs(daily) do keys[#keys + 1] = k end
  if #keys <= DAILY_MAX then return end
  table.sort(keys)                                   -- ascending (oldest first)
  for i = 1, #keys - DAILY_MAX do daily[keys[i]] = nil end
end

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────
-- Canonical model + change callbacks.
local M                                              -- the one canonical in-memory model (current region)
local stores = {}                                    -- registered host SavedVariable tables
local merged = false                                 -- has the login merge run yet?
local callbacks = {}                                 -- OnChange listeners

local function ensureModel()
  if not M then M = newModel() end                   -- in-memory-only fallback if no store ever registered
  return M
end

local function fireChange(price)
  for _, fn in ipairs(callbacks) do pcall(fn, price) end
end

-- Reconcile the merge: rebuild the canonical model from EVERY registered store, then mirror it back into all.
-- Idempotent by design (safe to re-run on late RegisterStore even after we've mirrored to all stores):
--   * readings are UNION-ed by timestamp (deduped) — re-merging identical mirrors changes nothing.
--   * daily/stats for days covered by the surviving readings are REBUILT from those readings (deduped once).
--   * daily rows OLDER than the readings window ("archived" days) are reconciled across stores with
--     max(count)/max(sum) + extreme high/low — max, not sum, so re-merging convergent mirrors never
--     double-counts; when one store genuinely has a richer old day, max keeps the richer copy.
local function rebuildCanonical()
  local key = regionKey()
  local nm  = newModel()

  -- 1. union readings by timestamp
  local seen = {}
  for _, store in ipairs(stores) do
    local rg = store and store.regions and store.regions[key]
    if rg and rg.readings then
      for _, r in ipairs(rg.readings) do
        if r and r.t and r.price and not seen[r.t] then
          seen[r.t] = true
          nm.readings[#nm.readings + 1] = { t = r.t, price = r.price }
        end
      end
    end
  end
  table.sort(nm.readings, function(a, b) return a.t < b.t end)

  -- days that surviving readings cover (rebuilt from readings, not carried from stored daily)
  local covered = {}
  for _, r in ipairs(nm.readings) do covered[date("%Y-%m-%d", r.t)] = true end

  -- 2. fold the union readings into daily + stats (ascending -> open/close correct, counted exactly once)
  for _, r in ipairs(nm.readings) do
    foldIntoDaily(nm.daily, date("%Y-%m-%d", r.t), r.t, r.price)
    foldIntoStats(nm.stats, r.t, r.price)
  end

  -- 3a. reconcile archived (non-covered) days across stores into a temp map (idempotent: max count/sum)
  local archived = {}
  for _, store in ipairs(stores) do
    local rg = store and store.regions and store.regions[key]
    if rg and rg.daily then
      for dk, d in pairs(rg.daily) do
        if not covered[dk] and type(d) == "table" then
          local a = archived[dk]
          if not a then
            archived[dk] = { day = dk, open = d.open, high = d.high, low = d.low, close = d.close,
                             sum = d.sum or 0, count = d.count or 0, avg = d.avg,
                             highT = d.highT, lowT = d.lowT }
          else
            if d.high and (not a.high or d.high > a.high) then a.high = d.high; a.highT = d.highT end
            if d.low  and (not a.low  or d.low  < a.low ) then a.low  = d.low;  a.lowT  = d.lowT  end
            if (d.count or 0) > (a.count or 0) then
              a.count = d.count or 0; a.sum = d.sum or 0; a.open = d.open; a.close = d.close
            end
          end
        end
      end
    end
  end

  -- 3b. commit reconciled archived days into daily and fold each into stats ONCE
  for dk, a in pairs(archived) do
    a.avg = (a.count and a.count > 0) and (a.sum / a.count) or a.avg
    nm.daily[dk] = a
    if a.high then statExtreme(nm.stats, "high", a.high, a.highT) end
    if a.low  then statExtreme(nm.stats, "low",  a.low,  a.lowT)  end
    nm.stats.sum   = nm.stats.sum   + (a.sum   or 0)
    nm.stats.count = nm.stats.count + (a.count or 0)
  end

  -- 4. bound
  trimReadings(nm.readings)
  trimDaily(nm.daily)

  -- 5. MIRROR: make nm canonical and point every store's region slot at it (one shared live table; each host
  --    serializes its own on-disk copy). Live folds mutate nm and are therefore reflected in every store.
  M = nm
  for _, store in ipairs(stores) do
    store.regions = store.regions or {}
    store.regions[key] = M
  end
  return M
end

-- Live: record a fetched price. Appends only when the value CHANGED vs the last reading (spec: readings hold
-- changes only), folds into daily + stats, and fires OnChange listeners. Mutates the shared canonical model,
-- so every registered store sees it.
local function recordReading(price)
  local m = ensureModel()
  local last = m.readings[#m.readings]
  if last and last.price == price then
    m.meta.lastFetch = time()
    return false                                     -- unchanged: not a new reading
  end
  local now = time()
  m.readings[#m.readings + 1] = { t = now, price = price }
  trimReadings(m.readings)
  foldIntoDaily(m.daily, date("%Y-%m-%d", now), now, price)
  trimDaily(m.daily)
  foldIntoStats(m.stats, now, price)
  m.meta.lastFetch = now
  fireChange(price)
  return true
end

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────
-- Public API.

-- RegisterStore(tbl) — a host hands us its persistent SavedVariable subtable (already loaded from disk). We
-- own its shape (tbl.regions[regionKey] = model). Idempotent; safe from any host in any order. If the login
-- merge has already run, fold this late store in immediately.
function lib.RegisterStore(tbl)
  if type(tbl) ~= "table" then return end
  for _, s in ipairs(stores) do if s == tbl then return end end
  stores[#stores + 1] = tbl
  if merged then rebuildCanonical() end
end

-- GetPrice() -> copper, or nil if not fetched yet. Raw copper; the HOST formats it.
function lib.GetPrice()
  local m = ensureModel()
  local r = m.readings[#m.readings]
  return r and r.price or nil
end

-- PercentOf(copper) -> % of a token that `copper` buys, or nil if no price yet.
function lib.PercentOf(copper)
  local p = lib.GetPrice()
  if not p or p <= 0 then return nil end
  return (tonumber(copper) or 0) / p * 100
end

-- GetTrend(window) -> { dir = "up"|"down"|"flat", pct = <signed %> }. The REAL windowed trend: compares the
-- current price to the reading closest to `window` seconds ago — walk readings back to the NEWEST one whose
-- t <= (now - window); if history is shorter than the window, use the OLDEST reading. Flat when |pct| < FLAT_PCT.
function lib.GetTrend(window)
  window = tonumber(window) or DEFAULT_WINDOW
  local m = ensureModel()
  local readings = m.readings
  local n = #readings
  if n == 0 then return { dir = "flat", pct = 0 } end

  local cur    = readings[n].price
  local target = time() - window
  local base   = readings[1]                          -- fallback: oldest (history shorter than window)
  for i = n, 1, -1 do
    if readings[i].t <= target then base = readings[i]; break end
  end

  local basePrice = base.price
  if not basePrice or basePrice == 0 then return { dir = "flat", pct = 0 } end
  local pct = (cur - basePrice) / basePrice * 100
  local dir
  if math.abs(pct) < FLAT_PCT then dir = "flat"
  elseif pct > 0                then dir = "up"
  else                               dir = "down" end
  return { dir = dir, pct = pct }
end

-- GetHistory(n) -> last n readings, NEWEST first (copies).
function lib.GetHistory(n)
  local m = ensureModel()
  local readings = m.readings
  local total = #readings
  n = tonumber(n) or total
  local out = {}
  local stop = math.max(1, total - n + 1)
  for i = total, stop, -1 do
    if readings[i] then out[#out + 1] = { t = readings[i].t, price = readings[i].price } end
  end
  return out
end

-- GetDaily(n) -> last n daily rollups, NEWEST first (copies).
function lib.GetDaily(n)
  local m = ensureModel()
  local keys = {}
  for k in pairs(m.daily) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return a > b end)   -- descending (newest first)
  n = tonumber(n) or #keys
  local out = {}
  for i = 1, math.min(n, #keys) do
    local d = m.daily[keys[i]]
    out[#out + 1] = { day = d.day, open = d.open, high = d.high, low = d.low,
                      close = d.close, avg = d.avg, sum = d.sum, count = d.count }
  end
  return out
end

-- GetStats() -> { high = {price,t}, low = {price,t}, avg }. avg derived from the running sum/count.
function lib.GetStats()
  local m = ensureModel()
  local s = m.stats
  local avg = (s.count and s.count > 0) and (s.sum / s.count) or nil
  return {
    high = s.high and { price = s.high.price, t = s.high.t } or nil,
    low  = s.low  and { price = s.low.price,  t = s.low.t  } or nil,
    avg  = avg,
  }
end

-- OnChange(fn) — register a callback fired (price) when a NEW reading lands (host can RefreshUI).
function lib.OnChange(fn)
  if type(fn) == "function" then callbacks[#callbacks + 1] = fn end
end

-- copper -> display string. Uses GECTemplate's standard money TEXT (white number + colored g/s/c letter, the
-- same format the {token.price} etc. tokens render) — NOT coin icons — so the tooltip matches the rest of the
-- addons and stays compact. GECTemplate loads after us, so fetch it lazily at call time. Falls back to coin
-- icons, then a plain number, if GECTemplate isn't embedded.
local function money(c)
  local Tpl = LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECTemplate-1.0", true)
  if Tpl and Tpl.MoneyShort then return Tpl.MoneyShort(c) end
  if GetCoinTextureString then
    local ok, s = pcall(GetCoinTextureString, c)
    if ok and s then return s end
  end
  return tostring(c or 0)
end

-- compact colored move marker for a per-row up/down move (green +, red -); "" when equal/unknown.
local function rowArrow(newer, older)
  if not older then return "" end
  if newer > older then return "|cff1eff00+|r"
  elseif newer < older then return "|cffff6060-|r" end
  return ""
end

-- BuildTooltip(tt, n) — add lines to a GameTooltip `tt`. Caller owns tt:Show(). All strings ASCII (no dashes).
function lib.BuildTooltip(tt, n)
  if not tt or not tt.AddLine then return end
  n = tonumber(n) or DEFAULT_TIP_DEPTH

  tt:AddLine("WoW Token")

  local price = lib.GetPrice()
  if not price then
    tt:AddLine("fetching...")                          -- nil/0 = not fetched yet, never "no token"
    return
  end

  local trend = lib.GetTrend()
  if tt.AddDoubleLine then
    tt:AddDoubleLine("Price", money(price) .. " " .. lib.TrendDisplay(trend.dir))
  else
    tt:AddLine("Price " .. money(price) .. " " .. lib.TrendDisplay(trend.dir))
  end

  local m = ensureModel()
  local today = m.daily[date("%Y-%m-%d")]
  if today and tt.AddDoubleLine then
    tt:AddDoubleLine("Today high/low", money(today.high) .. " / " .. money(today.low))
    tt:AddDoubleLine("Today avg", money(math.floor((today.avg or 0) + 0.5)))
  end

  local st = lib.GetStats()
  if tt.AddDoubleLine then
    if st.high then tt:AddDoubleLine("All time high", money(st.high.price)) end
    if st.low  then tt:AddDoubleLine("All time low",  money(st.low.price))  end
  end

  local hist = lib.GetHistory(n)
  if #hist > 0 then
    tt:AddLine(" ")
    -- Readings are kept for READINGS_RETENTION_SECONDS (7 days), so a time-only stamp is ambiguous the
    -- moment there is more than one day of history: "09:14" could be any of seven mornings. Stamp TODAY's
    -- readings with the time alone (the common case, and it keeps the list compact) and prefix anything
    -- older with its date. Numeric %m/%d rather than %b so the stamp stays ASCII in every client locale
    -- (this tooltip is documented ASCII-only).
    local todayKey = date("%Y-%m-%d")
    for i, r in ipairs(hist) do
      local older = hist[i + 1]                        -- next in list is the OLDER reading
      local arrow = older and rowArrow(r.price, older.price) or ""
      local stamp = (date("%Y-%m-%d", r.t) == todayKey) and date("%H:%M", r.t)
                    or date("%m/%d %H:%M", r.t)
      if tt.AddDoubleLine then
        tt:AddDoubleLine(stamp, money(r.price) .. " " .. arrow)
      else
        tt:AddLine(stamp .. "  " .. money(r.price) .. " " .. arrow)
      end
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────
-- Polling (AH-free) + the login-driven merge. Nothing here touches SavedVariables at FILE scope — the frame
-- just registers events; the merge + poll only run on PLAYER_LOGIN (after all SVs have loaded).

local function poll()
  if not C_WowTokenPublic or not C_WowTokenPublic.UpdateMarketPrice then return end
  pcall(C_WowTokenPublic.UpdateMarketPrice)
end

local function readCurrent()
  if not C_WowTokenPublic or not C_WowTokenPublic.GetCurrentMarketPrice then return end
  local ok, price = pcall(C_WowTokenPublic.GetCurrentMarketPrice)
  if ok and price and price > 0 then recordReading(price) end
end

local tickerStarted = false
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("TOKEN_MARKET_PRICE_UPDATED")
frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    rebuildCanonical()                                 -- merge all registered stores (SVs loaded) + mirror
    merged = true
    poll()                                             -- kick the first fetch
    if not tickerStarted and C_Timer and C_Timer.NewTicker then
      C_Timer.NewTicker(POLL_INTERVAL, poll)           -- repeating AH-free refresh
      tickerStarted = true
    end
  elseif event == "TOKEN_MARKET_PRICE_UPDATED" then
    readCurrent()
  end
end)
