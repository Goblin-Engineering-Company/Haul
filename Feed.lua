-- Feed.lua — publish Haul's session outputs as a GECData feed (the typed-token convention), so any
-- GECData consumer (e.g. the Gadgets addon) can render {haul.<token>} live. SHIPPING file.
--
-- The feed name "Haul" slugs to "haul", so {haul.perhour}, {haul.cash}, {haul.token.percent}, etc.
-- resolve on the consumer side, and bare {haul} = the feed's passthrough text. The token vocabulary
-- (and per-token TYPE) comes from ns.OutputTokens() (Window.lua) — the same tables buildTokenSpec()
-- uses — so coverage and coloring match Haul's own templates.
--
-- Token TYPING (the point of this file): Haul's BuildFields stores MOST values PLAIN (zone, counts,
-- token.percent, …) and only bakes color into the money strings + a few quality/colored labels. So:
--   "raw"  → tokens whose value carries baked, meaningful color (money + quality labels + token.trend):
--            kept verbatim, NOT recolorable (ns.IsRawToken).
--   "text" → everything else: plain values, so a gadget template can color them ({haul.zone:teal}).
--   "number" → the .copper raw-integer money tokens (consumer formats/colors them).
--
-- Producer-only: needs LibStub + CallbackHandler + LDB + GECData (the typed rendering happens
-- consumer-side, no GECTemplate here). Haul's own Broker.lua is a separate CONSUMER, untouched.
local ADDON, ns = ...

local Data = LibStub and LibStub:GetLibrary("GECData-1.0", true)
if not Data or not Data.Provide then return end

-- per-token type, sourced from ns.OutputTokens() (each entry { name, type }) so the feed stays in
-- lock-step with Haul's vocabulary + classification (no duplicated name list / guessing here).
-- tokenColors[name] = the token's DEFAULT color hex (text tokens only). Handed to consumers so a
-- {haul.<token>} shows its category color automatically in a Gadgets bar, while {haul.<token>:color}
-- still overrides it (GECData passes it as GECTemplate's 3rd resolver return; explicit :color wins).
local tokenTypes, tokenColors = {}, {}
for _, t in ipairs((ns.OutputTokens and ns.OutputTokens()) or {}) do
  tokenTypes[t.name] = t.type or "raw"
  if t.color then tokenColors[t.name] = t.color end
end

-- Field cache with REUSE + demand-gating. BuildFields() is expensive (full log replay + sort + alloc), so:
--   1) if Window just built this tick (it stamps ns._fieldsSnap, 1/sec while shown), REUSE that — no
--      second pass; and
--   2) we only build ourselves when a consumer is actively reading (a GetToken call in the last few
--      seconds — e.g. a Gadgets bar) and Window isn't already doing it. When the window is closed AND
--      nothing reads the feed, no pass runs at all (the hidden-window skip the feed used to bypass).
local cache, cacheAt, lastRead = {}, 0, 0
local function nowT() return (GetTime and GetTime()) or 0 end
local function ensureFresh()
  local now = nowT()
  local snap = ns._fieldsSnap
  if snap and snap.fields and (now - (snap.t or 0)) < 1.2 then cache, cacheAt = snap.fields, now; return end
  if (now - cacheAt) < 1 then return end                 -- our own cache still fresh (<1s)
  cache = (ns.BuildFields and ns.BuildFields()) or cache
  cacheAt = now
end

-- belt-and-suspenders: for a "text"-typed token, strip any stray color escapes from the cached value
-- so it's reliably colorable even if a value sneaks in baked color. Keep textures (|T..|t) and links
-- (|H..|h) intact. "raw"/"number" tokens are returned untouched.
local function stripColor(v)
  return (tostring(v):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local feed = Data.Provide("Haul", {
  type = "data source",
  text = "Haul",
  icon = "Interface\\Icons\\inv_misc_coin_01",
  tokenTypes = tokenTypes,
  tokenColors = tokenColors,   -- overridable default colors for the consumer (see above)
  GetToken = function(name)
    lastRead = nowT(); ensureFresh()   -- a consumer is reading → keep fresh (reuses Window's build if any)
    local v = cache[name]
    if v == nil then return nil end
    if tokenTypes[name] == "text" then return stripColor(v) end   -- ensure plain → colorable
    return v                                                       -- raw / number: verbatim
  end,
  -- interactivity (LDB convention; routed by a GECData consumer's hot-span, e.g. a Gadgets bar):
  -- left-click a {haul.*} span → toggle Haul's main window (what /haul opens).
  OnClick = function(_, button)
    if button == "LeftButton" and ns.ToggleWindow then ns.ToggleWindow() end
  end,
  -- short session summary from the same cached fields the tokens read (haul/per-hour/item count).
  OnTooltipShow = function(tt)
    tt:AddLine("Haul")
    tt:AddLine("Session: " .. (cache.haul or "-"))
    tt:AddLine("Per hour: " .. (cache.perhour or "-"))
    tt:AddLine("Items: " .. (cache["items.count"] or "0"))
    -- WoW Token history block (price/trend, today + all-time stats, last N reads) — only once the lib
    -- has a price. The lib owns the whole section; we just add a spacer and hand it the tooltip.
    local wt = ns.WowToken
    if wt and wt.BuildTooltip and wt.GetPrice and wt.GetPrice() then
      tt:AddLine(" ")
      wt.BuildTooltip(tt)
    end
  end,
})

-- Refresh the cache (and the live LDB display text) once a second. GECData.Provide returns a HANDLE
-- { object = <LDB obj>, Set }, NOT the LDB object — so the live text goes on feed.object.text.
-- Live text = session haul + per-hour (a compact "what am I making" line for any LDB display).
if feed and feed.object and C_Timer then
  C_Timer.NewTicker(1, function()
    -- Only refresh the LDB line when something actually consumes the feed: a token read in the last ~5s
    -- (a Gadgets bar — self-sustaining, since setting .text drives its re-render → next GetToken), or the
    -- window is up (its snapshot is fresh). Nothing reading + window closed → skip the whole pass.
    local now = nowT()
    local snap = ns._fieldsSnap
    local windowUp = snap and (now - (snap.t or 0)) < 1.2
    if (now - lastRead) > 5 and not windowUp then return end
    ensureFresh()
    feed.object.text = "Haul " .. (cache.haul or "-") .. "   " .. (cache.perhour or "-") .. "/hr"
  end)
end
