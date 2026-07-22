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
local tokenTypes = {}
for _, t in ipairs((ns.OutputTokens and ns.OutputTokens()) or {}) do
  tokenTypes[t.name] = t.type or "raw"
end

-- Cached field table: BuildFields() builds the WHOLE token table, so we compute it ONCE per second
-- (below) and have GetToken read from the cache — not a fresh BuildFields() per token per render.
local cache = {}

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
  GetToken = function(name)
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
  end,
})

-- Refresh the cache (and the live LDB display text) once a second. GECData.Provide returns a HANDLE
-- { object = <LDB obj>, Set }, NOT the LDB object — so the live text goes on feed.object.text.
-- Live text = session haul + per-hour (a compact "what am I making" line for any LDB display).
if feed and feed.object and C_Timer then
  C_Timer.NewTicker(1, function()
    cache = (ns.BuildFields and ns.BuildFields()) or cache
    local haul = cache.haul or "-"
    local per  = cache.perhour or "-"
    feed.object.text = "Haul " .. haul .. "   " .. per .. "/hr"
  end)
end
