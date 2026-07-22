-- GECTemplate-1.0 — shared {token} text-render engine for Goblin Engineering Company WoW addons.
-- Lifted from Haul ns.RenderTemplate; standalone LibStub library with no WoW-API dependency.
-- Grammar: {token}  {token.facet}  {token:color}  {token(arg)}  {"literal"}  {br}
local MAJOR, MINOR = "GECTemplate-1.0", 7
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end   -- a newer copy is already loaded

-- {br} and its aliases all produce a newline.
local LINEBREAKS = { br = true, lb = true, lw = true, linewrap = true, wrap = true }

-- parse the inside of {...} into (name, arg, colraw). Mirrors Haul ns.RenderTemplate grammar.
-- Handles: {token}  {token:color}  {token|color}  {token(arg)}  {token(arg):color}
local function parseToken(inside)
  local name, arg, colraw
  local pn, pa, prest = inside:match("^([%w%.]+)%((.-)%)(.*)$")  -- {token(arg)} / {token(arg):color}
  if pn then
    name, arg = pn, pa
    colraw = prest:match("^[:|](%w+)$")
  else
    name, colraw = inside:match("^([%w%.]+)[:|](%w+)$")          -- {token:color} / {token|color}
    if not name then name = inside end
  end
  return name, arg, colraw
end

-- ===================== named color palette =====================
-- Aligned with GECTheme-1.0 NAMED_COLORS so consumers share one vocabulary.
lib.NAMED_COLORS = {
  white  = "ffffff", red    = "ff6060", green  = "1eff00", blue   = "66ccff",
  gold   = "ffd100", yellow = "ffd100", purple = "a335ee", gray   = "808080",
  grey   = "808080", orange = "eda55f", teal   = "45c4a0",
}

-- Resolve a color keyword or raw 6-hex string to a 6-hex value, or nil.
local function resolveColor(colraw, NAMED)
  if not colraw then return nil end
  local lo = colraw:lower()
  return NAMED[lo] or (lo:match("^%x%x%x%x%x%x$") and lo) or nil
end

-- Forward declaration so Renderer:Render can call it before the fallback chain is defined below.
local runResolvers

-- ===================== renderer =====================
local Renderer = {}
Renderer.__index = Renderer

-- Tpl.New(opts) → renderer
-- opts.tokens  : map of token-name → type-string | { type=, color= }
-- opts.base    : default line color (6-hex); baked into the whole rendered string
-- opts.price   : a function(itemID)→copper, or a string naming a registered price provider
function lib.New(opts)
  opts = opts or {}
  local p = opts.price
  return setmetatable({
    tokens   = opts.tokens or {},
    base     = opts.base,
    -- resolve the price option at construction time; nil means use the default chain.
    priceFn  = (type(p) == "function" and p)
               or (type(p) == "string" and lib.prices[p])
               or nil,
    -- per-consumer config carried onto the renderer so it reaches resolvers via ctx (self IS ctx).
    -- tsmPrice = the TSM custom-price string for {tsm.value.*}; may also be set live at runtime
    -- (renderer.tsmPrice = "dbminbuyout") and is read each render.
    tsmPrice = opts.tsmPrice,
  }, Renderer)
end

-- renderer:Render(template, data [, base]) → string
-- base overrides self.base for this call.
function Renderer:Render(template, data, base)
  data = data or {}
  local NAMED = lib.NAMED_COLORS
  local spec  = self.tokens

  -- Per-token resolution (one innermost {…} → its value). Body is unchanged; it's hoisted into a
  -- named function so the render can run it as a CAPPED LOOP for NESTED tokens: the {([^{}]+)}
  -- pattern only matches the INNERMOST braces (no braces inside), so re-running gsub resolves one
  -- layer per pass — inner first. e.g. {count.account({haul.items.last.id})} → pass 1 resolves the
  -- inner {haul.items.last.id} → "6948", pass 2 sees {count.account(6948)} and resolves it.
  local resolve = function(inside)
    -- 1. quoted literal: {"anything here"} → anything here
    local lit = inside:match('^"(.*)"$')
    if lit then return lit end

    local name, arg, colraw = parseToken(inside)
    -- An ARGUMENT is a raw VALUE, not display text. A nested token's output can carry display
    -- formatting (color codes, a feed's |Hgecdata:…|h click hot-span, textures) — strip it so
    -- {outer({inner})} passes a clean value (e.g. an item id), not "|Hgecdata:haul|h6948|h".
    if arg ~= nil and arg ~= "" then
      arg = arg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
               :gsub("|H.-|h", ""):gsub("|h", ""):gsub("|T.-|t", "")
    end

    -- 2. line-break aliases
    if LINEBREAKS[name] then return "\n" end

    -- 3-5. Resolve value + type, FULL DOTTED NAME FIRST, then a base.facet split.
    --   (A) FULL NAME — the whole dotted token is a data field / spec entry / registered type.
    --       Consumers (e.g. Haul) key their fields by the COMPLETE dotted token ("time.current",
    --       "items.value", "haul.full"), so this path must win — otherwise {time.current} would
    --       wrongly grab data["time"].
    --   (B) BASE.FACET — only if (A) yielded nothing: split "base.facet" and use the base's type
    --       with the facet (the type model: {item.name(id)}, {money.full}).
    -- The registered-type-by-name fallback only fires when there is NO data (ambient) or an (arg)
    -- is present, so a plain data field that shares a type's name is never hijacked.
    local v, entry, facet, typeName
    if arg ~= nil then
      v = arg
      entry = spec[name]
      typeName = (type(entry) == "table" and entry.type) or (type(entry) == "string" and entry)
                 or (lib.types[name] and name) or nil
      if not typeName then
        local bn, fc = name:match("^([^%.]+)%.(.+)$")
        if bn then
          facet, entry = fc, spec[bn]
          typeName = (type(entry) == "table" and entry.type) or (type(entry) == "string" and entry)
                     or (lib.types[bn] and bn) or nil
        end
      end
    else
      v = data[name]
      entry = spec[name]
      typeName = (type(entry) == "table" and entry.type) or (type(entry) == "string" and entry) or nil
      if not typeName and v == nil and lib.types[name] then typeName = name end
      if v == nil and not typeName then
        local bn, fc = name:match("^([^%.]+)%.(.+)$")
        if bn then
          facet, v, entry = fc, data[bn], spec[bn]
          typeName = (type(entry) == "table" and entry.type) or (type(entry) == "string" and entry) or nil
          if not typeName and v == nil and lib.types[bn] then typeName = bn end
        end
      end
    end
    local resolver = typeName and lib.types[typeName]

    -- 6. no resolver AND (parameterized OR no data) → consult the fallback chain, else leave literal.
    --    Parameterized (arg) tokens are never routed through the fallback chain — they go literal.
    if not resolver and (arg ~= nil or v == nil) then
      if arg == nil then
        local rtext, rself = runResolvers(name)
        if rtext ~= nil then
          if rself then return rtext end
          -- colorable: apply explicit :color or token default color, then return
          local defColor = type(entry) == "table" and entry.color or nil
          local hex = resolveColor(colraw, NAMED)
                      or (defColor and (NAMED[defColor:lower()] or resolveColor(defColor, NAMED)))
          if hex then return "|cff" .. hex .. rtext .. "|r" end
          return rtext
        end
      end
      return "{" .. inside .. "}"
    end

    -- 7. run the resolver (self-colored types ignore :color); else stringify the data value
    if resolver then
      local text, selfColored = resolver(v, facet, self)
      -- Midnight secret-value guard: a resolver that formats a SECRET WoW value (e.g. GetUnitSpeed while
      -- skyriding) yields a secret string; gsub'ing that below throws "invalid replacement value (a secret)"
      -- and crashes the whole render. Coerce any secret to "" so ONE bad token can't take down the bar.
      if issecretvalue and issecretvalue(text) then text = "" end
      -- resolver returned nil → it DECLINED this token (e.g. an unrecognized facet). Render the
      -- literal as a typo aid (and to avoid a nil concat if a :color is present). A KNOWN-but-empty
      -- facet returns "" (not nil), so it still renders blank rather than literal.
      if text == nil then return "{" .. inside .. "}" end
      if selfColored then return text end
      v = text
    else
      v = tostring(v)
    end

    -- 8. color precedence: explicit :color > token default color
    local defColor = type(entry) == "table" and entry.color or nil
    local hex = resolveColor(colraw, NAMED)
                or (defColor and (NAMED[defColor:lower()] or resolveColor(defColor, NAMED)))
    if hex then return "|cff" .. hex .. v .. "|r" end
    return v
  end

  -- NESTED resolution: loop the innermost-only gsub until the string stabilizes (a depth cap guards
  -- against a token that keeps yielding another token). Each pass resolves the current innermost
  -- layer; an UNKNOWN token resolves to its own literal {x} (no net change), so a stable string
  -- (only unresolved/literal tokens left) breaks the loop. Non-nested templates cost 2 passes
  -- (pass 1 resolves, pass 2 confirms stable). The base-color baking below runs ONCE, after the loop.
  local out = template
  for _ = 1, 6 do
    local before = out
    out = out:gsub("{([^{}]+)}", resolve)
    if out == before then break end
  end

  -- 7. bake the base line color into the whole output so it's portable:
  --    prefix with |cff<base>, re-open base after every |r so colored tokens
  --    don't bleed into following text, then close with a final |r.
  local b = base or self.base
  if b then
    out = "|cff" .. b .. out:gsub("|r", "|r|cff" .. b) .. "|r"
  end
  return out
end

-- ===================== type registry =====================
-- lib.types[name] = function(value, facet, ctx) → text, selfColored
-- `or {}` so a MINOR-upgrade re-run (a higher embed copy loading after a lower one) PRESERVES
-- externally-registered entries instead of wiping them — see the resolvers note below.
lib.types = lib.types or {}
function lib.RegisterType(name, resolver)
  lib.types[name] = resolver
end

-- ===================== price-provider registry =====================
-- lib.prices[name] = function(itemID) → copper (number) | nil
-- The vendor adapter is registered in GECTemplate-Resolvers.lua (needs GetItemInfo).
-- Third-party addons and the TSM/Auctionator adapters register here too.
lib.prices = lib.prices or {}   -- preserve across a MINOR-upgrade re-run (see resolvers note below)
function lib.RegisterPrice(name, fn)
  lib.prices[name] = fn
end

-- built-in: text (plain passthrough; obeys :color and base)
lib.RegisterType("text", function(v, facet, ctx)
  return tostring(v), false
end)

-- built-in: raw (verbatim self-colored passthrough — for already-formatted strings such as
-- money spans and quality-colored item names that carry their own color escapes and must
-- NOT be recolored by :color modifiers or a renderer base color).
lib.RegisterType("raw", function(v, facet, ctx)
  return tostring(v), true
end)

-- ===================== fallback resolver chain =====================
-- An ordered list of resolver functions consulted for a token that has NO data value in the
-- fields table and NO registered type entry, before the token is left literal. Each resolver
-- receives the full token name (dotted; e.g. "feedslug.value") and returns:
--   text[, selfColored]   — non-nil text wins; selfColored follows the usual convention
--   nil                   — pass to the next resolver in the chain
-- Parameterized {token(arg)} tokens are never routed through this chain (they go literal when
-- there is no resolver, matching the engine's existing (arg) semantics). Data values and
-- registered types always take precedence over this chain.
-- `or {}` is LOAD-BEARING: when two addons embed DIFFERENT MINOR copies, LibStub upgrades the
-- singleton by RE-RUNNING the higher copy's file. A bare `= {}` there would wipe the fallback
-- resolver another addon already registered (e.g. Gadgets' GECData consumer), and GECData's
-- one-shot `_Tpl` guard then never re-adds it → every {slug.token} silently goes literal. Only
-- GECData.RegisterConsumer appends here (once, guarded), so preserving the list can't duplicate.
lib.resolvers = lib.resolvers or {}

function lib.RegisterResolver(fn)
  if type(fn) == "function" then lib.resolvers[#lib.resolvers + 1] = fn end
end

runResolvers = function(name)
  for i = 1, #lib.resolvers do
    local text, selfColored = lib.resolvers[i](name)
    if text ~= nil then return text, selfColored end
  end
end

-- ===================== shared number grouping =====================
-- Comma-group an integer: 1234567 → "1,234,567". Shared by money + number.
local function groupThousands(n)
  local s = tostring(math.floor(math.abs(n)))
  local out, len = "", #s
  for i = 1, len do
    out = out .. s:sub(i, i)
    local remaining = len - i
    if remaining > 0 and remaining % 3 == 0 then out = out .. "," end
  end
  return out
end

-- ===================== money formatters (port of Haul ns.Money / ns.MoneyShort) =====================
-- In-game style: the NUMBER is forced white (|cffffffff) so a base/line color can't recolor it;
-- only the g/s/c LETTER carries the coin color. Colors match the game exactly.
local GOLD_C, SILVER_C, COPPER_C = "ffffd700", "ffc7c7cf", "ffeda55f"   -- full |c codes (alpha+rgb)
local function coin(numStr, unit, c)
  return "|cffffffff" .. numStr .. "|r|c" .. c .. unit .. "|r"
end

-- MoneyFull = all NON-ZERO denominations (zeros omitted), space-separated. (= Haul ns.Money)
function lib.MoneyFull(copper)
  copper = math.max(0, math.floor(tonumber(copper) or 0))
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local out = {}
  if g > 0 then out[#out + 1] = coin(groupThousands(g), "g", GOLD_C) end
  if s > 0 then out[#out + 1] = coin(s, "s", SILVER_C) end
  if c > 0 or #out == 0 then out[#out + 1] = coin(c, "c", COPPER_C) end
  return table.concat(out, " ")
end

-- MoneyShort = the LARGEST non-zero denomination only (3g / 40s / 75c). (= Haul ns.MoneyShort)
function lib.MoneyShort(copper)
  copper = math.max(0, math.floor(tonumber(copper) or 0))
  if copper >= 10000 then return coin(groupThousands(math.floor(copper / 10000)), "g", GOLD_C) end
  if copper >= 100   then return coin(math.floor(copper / 100), "s", SILVER_C) end
  return coin(copper, "c", COPPER_C)
end

-- ===================== number formatter =====================
-- Default: comma-grouped integer (1234567 → "1,234,567") via the shared groupThousands above.
-- Facet "abbrev": one decimal with M/k suffix; below 1000 unchanged.
-- Not self-colored — obeys :color and base.
local function abbrevNumber(n)
  local a = math.abs(n)
  if a >= 1e6 then return ("%.1fM"):format(n / 1e6) end
  if a >= 1e3 then return ("%.1fk"):format(n / 1e3) end
  return tostring(math.floor(n))
end

lib.RegisterType("number", function(v, facet, ctx)
  v = tonumber(v) or 0
  if facet == "abbrev" then return abbrevNumber(v), false end
  return groupThousands(v), false
end)

-- built-in: money (self-colored; .full facet → MoneyFull, default → MoneyShort)
lib.RegisterType("money", function(v, facet, ctx)
  if facet == "full" then
    return lib.MoneyFull(v), true
  end
  return lib.MoneyShort(v), true
end)

-- ===================== misc resolvers =====================

-- percent: fraction (<=1) → multiply by 100; whole number → pass through.
-- Rounds to nearest integer. Not self-colored.
lib.RegisterType("percent", function(v, facet, ctx)
  v = tonumber(v) or 0
  if v > 0 and v <= 1 then v = v * 100 end
  return ("%d%%"):format(math.floor(v + 0.5)), false
end)

-- duration: seconds → up to two most-significant non-zero parts
-- (e.g. 83 → "1m 23s", 3600 → "1h", 90061 → "1d 1h"). 0 → "0s".
lib.RegisterType("duration", function(v, facet, ctx)
  local s = math.max(0, math.floor(tonumber(v) or 0))
  local d  = math.floor(s / 86400); s = s % 86400
  local hr = math.floor(s / 3600);  s = s % 3600
  local mn = math.floor(s / 60);    local sc = s % 60
  local parts = {}
  if d  > 0 then parts[#parts + 1] = d  .. "d" end
  if hr > 0 then parts[#parts + 1] = hr .. "h" end
  if mn > 0 then parts[#parts + 1] = mn .. "m" end
  if sc > 0 then parts[#parts + 1] = sc .. "s" end
  if #parts == 0 then parts[1] = "0s" end
  -- return only the two most-significant parts
  if parts[2] then
    return parts[1] .. " " .. parts[2], false
  end
  return parts[1], false
end)

-- time: unix timestamp → "HH:MM" (UTC for determinism when ts passed).
-- nil/missing → local wall clock via date("%H:%M").
-- `date` is the WoW global (mocked to os.date in tests).
lib.RegisterType("time", function(v, facet, ctx)
  local ts = tonumber(v)
  if ts then
    return date("!%H:%M", ts), false   -- UTC for a passed timestamp (deterministic in tests)
  end
  return date("%H:%M"), false          -- local time when nil
end)

-- icon: texture path → |T<path>:<size>|t. Facet = size (default 16). Self-colored/verbatim.
lib.RegisterType("icon", function(v, facet, ctx)
  local size = tonumber(facet) or 16
  return "|T" .. tostring(v) .. ":" .. size .. "|t", true
end)
