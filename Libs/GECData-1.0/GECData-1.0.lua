-- GECData-1.0 — the token data-provider standard: consume LDB feeds (passthrough + protocol +
-- the typed-token convention) and produce them. Renders typed values through GECTemplate.
local MAJOR, MINOR = "GECData-1.0", 2
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end
local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)

-------------------------------------------------------------------- slug index --
-- slug = feed name lowercased with every non-alphanumeric stripped. First-come wins;
-- a later name that derives the same slug is a collision (recorded, not remapped).
local function Slugify(name) return (tostring(name):lower():gsub("[^%a%d]", "")) end

local slugToName = {}     -- slug  -> feed name (the owner; first-come wins)
-- (Broker.lua also kept a name->slug reverse map for its interactivity/browser layer; that
--  layer is deferred to a later phase, and phase-1 resolution needs only slugToName, so the
--  reverse map is omitted here — re-add it when the dispatch/browser code lifts over.)
lib.collisions  = {}      -- list of { slug=, name=, owner= } (was Broker's print-based log)
local seenName  = {}      -- name  -> true once handled (indexed OR recorded as a collision)
local dirtyIndex = true    -- true ⇒ a full rebuild is pending (initial build / unknown-slug miss)

-- adapter registry (framework only — ships ZERO adapters; see lib.RegisterAdapter, later task)
local adaptersByName  = {}   -- exact feed name -> spec
local adaptersByMatch = {}   -- list of specs carrying a .match pattern

local function AdapterFor(feedName)
  local a = adaptersByName[feedName]
  if a then return a end
  for i = 1, #adaptersByMatch do
    local spec = adaptersByMatch[i]
    if feedName:match(spec.match) then return spec end
  end
end

-- an adapter may declare an explicit namespace that overrides the derived slug
local function SlugFor(feedName)
  local a = AdapterFor(feedName)
  if a and a.namespace then return tostring(a.namespace):lower() end
  return Slugify(feedName)
end

local function IndexFeed(name)
  if not name or seenName[name] then return end
  local slug = SlugFor(name)
  if slug == "" then return end
  local owner = slugToName[slug]
  if owner and owner ~= name then
    seenName[name] = true                                   -- record once, never remap (first-come wins)
    local c = { slug = slug, name = name, owner = owner }
    lib.collisions[#lib.collisions + 1] = c
    if lib.onCollision then lib.onCollision(c) end          -- optional hook (no WoW print at lib scope)
    return
  end
  slugToName[slug], seenName[name] = name, true
end

local function RebuildIndex()
  if not LDB then return end
  for name in LDB:DataObjectIterator() do IndexFeed(name) end
end

-- build once on demand (dirty), then rely on the DataObjectCreated callback to stay current,
-- so a typo'd/absent slug doesn't trigger a full registry scan every render tick.
local function EnsureIndex()
  if dirtyIndex then RebuildIndex(); dirtyIndex = false end
end

function lib.FeedBySlug(slug)
  if not LDB then return nil end
  slug = tostring(slug):lower()
  local name = slugToName[slug]
  if not name then EnsureIndex(); name = slugToName[slug] end   -- lazy: catch feeds loaded before us
  if not name then return nil end
  return LDB:GetDataObjectByName(name), name
end

-- Stay current as new feeds register — but only where CallbackHandler exists (absent in the
-- headless mock, so this is a no-op there).
if LDB and LDB.RegisterCallback then
  LDB.RegisterCallback(lib, "LibDataBroker_DataObjectCreated", function(_, name)
    IndexFeed(name)
  end)
end

----------------------------------------------------------------- interactivity --
-- Slug-wide hot-span wrapper. Ported from Broker.lua's Wrap. KEPT: the empty-string
-- short-circuit and the nested-|H guard (WoW hyperlinks cannot nest, so content that
-- already carries its own |H link — e.g. a passthrough item link — is left intact).
-- When the feed for `slug` defines OnClick OR OnTooltipShow, the content is wrapped in a
-- "|Hgecdata:<slug>|h…|h" hyperlink hot-span so a consumer's OnHyperlink* scripts can route a
-- click/hover to the feed's handlers (see Gadgets.lua). Feeds with NO handlers stay UNWRAPPED
-- (plain — no noise / no inert links).
function lib.Wrap(slug, content)
  if content == "" then return "" end                      -- blank: nothing to host
  if content:find("|H", 1, true) then return content end   -- nested-link guard
  local feed = lib.FeedBySlug(slug)
  if feed and (type(feed.OnClick) == "function" or type(feed.OnTooltipShow) == "function") then
    return "|Hgecdata:" .. slug .. "|h" .. content .. "|h"
  end
  return content                                           -- no handlers → no hot-span
end

----------------------------------------------------------------- consumption ----
-- The fallback resolver GECData registers into a GECTemplate engine. name = the dotted token
-- (e.g. "brokergold.earned"). Returns (text, selfColored) | nil (→ next resolver / literal).
function lib.RegisterConsumer(Tpl)
  if not (Tpl and Tpl.RegisterResolver) then return end
  if lib._Tpl == Tpl then return end   -- idempotent: don't stack a 2nd resolver on re-init / shared renderer
  lib._Tpl = Tpl
  Tpl.RegisterResolver(function(name)
    local slug, sub = name:match("^([%a%d]+)%.(.+)$")
    if not slug then slug = name end
    local feed = lib.FeedBySlug(slug)
    if not feed then return nil end
    -- typed-token convention: declared type + value (GetToken → static tokens)
    if sub then
      -- token-name lookups stay CASE-SENSITIVE (a feed owns its own token keys); only the
      -- protocol-field comparison below is case-insensitive (parity with Broker.lua:111).
      local lsub = sub:lower()
      local typ = feed.tokenTypes and feed.tokenTypes[sub]
      if typ and Tpl.types[typ] then
        local val
        -- foreign callback: pcall so a misbehaving feed can't throw out of Render() (parity: Broker.lua:132).
        if feed.GetToken then
          local ok, v = pcall(feed.GetToken, sub)
          if ok then val = v end
        end
        if val == nil and feed.tokens then val = feed.tokens[sub] end
        if val ~= nil then
          -- typed render → (text, selfColored); wrap the text in the feed's hot-span (if it has
          -- handlers) so {slug.token} is clickable too, preserving the selfColored flag.
          local text, selfColored = Tpl.types[typ](val, nil, lib)
          return lib.Wrap(slug, text), selfColored
        end
      end
      -- protocol fields (plain LDB) — known field with a nil value ⇒ "" (parity: Broker.lua:126), not literal.
      if lsub == "value" or lsub == "suffix" or lsub == "label" then
        return lib.Wrap(slug, tostring(feed[lsub] or "")), false
      elseif lsub == "icon" then
        -- NOTE (facet phase / M6): hardcodes |T...:0|t; later route through the engine's `icon`
        -- type so a size facet ({slug.icon.24}) works.
        return feed.icon and ("|T" .. tostring(feed.icon) .. ":0|t") or "", true
      elseif lsub == "text" then
        return lib.Wrap(slug, tostring(feed.text or "")), true
      end
      return nil   -- unknown sub-token ⇒ literal
    end
    -- bare {slug} = passthrough text (escapes intact, nested-|H guarded)
    return lib.Wrap(slug, tostring(feed.text or "")), true
  end)
end

-------------------------------------------------------------- adapter framework --
-- lib.RegisterAdapter(feedName, spec) — spec = { namespace?, match?, parse, tokens? }.
-- namespace overrides the derived slug; match handles feeds whose registered name varies;
-- parse(feedObj) -> table of named fields. Lifted from Broker.lua: registry/storage ONLY —
-- phase 1 ships ZERO adapters. (AdapterFor above already reads this table via SlugFor, so the
-- framework is luacheck-clean even with no adapters registered.)
function lib.RegisterAdapter(feedName, spec)
  if type(spec) ~= "table" or type(spec.parse) ~= "function" then return end
  if feedName then adaptersByName[feedName] = spec end
  if spec.match then adaptersByMatch[#adaptersByMatch + 1] = spec end
  -- a namespace override re-slugs feeds; force a full rebuild on next lookup.
  dirtyIndex = true
  slugToName, seenName = {}, {}
end

------------------------------------------------------------------ producer ------
-- lib.Provide(name, spec) — register an LDB data object carrying the typed-token convention
-- (spec.tokenTypes / spec.tokens). Wraps LDB:NewDataObject so the create-callback fires and the
-- feed is indexed like any other. Returns a handle with :Set(token, value) that writes the
-- static token store. If LibDataBroker isn't present (no LDB in-game), fail gracefully → nil.
function lib.Provide(name, spec)
  if not LDB then return nil end
  spec = spec or {}
  local obj = LDB:NewDataObject(name, spec)
  if not obj then return nil end
  obj._gec = true   -- mark as OURS (a GEC-produced feed) — foundation for trusted/subscription filtering
  return {
    object = obj,
    Set = function(_, token, value)
      obj.tokens = obj.tokens or {}
      obj.tokens[token] = value
    end,
  }
end

------------------------------------------------------------- WoW Token price ----
-- lib.TokenPrice() → the current WoW Token market price in COPPER (a number), or nil until a
-- price is known. Reusable numeric accessor for any addon that needs the raw price to do
-- arithmetic (e.g. Coffer's gold→USD→credit) WITHOUT touching C_WowTokenPublic itself.
--
-- C_WowTokenPublic.GetCurrentMarketPrice() is itself the client-side cache and returns nil
-- until the first market update. We lazily request an update ONCE (the client caches the
-- result and fires TOKEN_MARKET_PRICE_UPDATED on its own thereafter) so the value populates;
-- no standing event handler is added here (the {wowtoken} resolver already keeps a live
-- display copy). The first call typically returns nil — call again after a market tick.
--
-- Every C_WowTokenPublic call is existence-guarded + pcall'd (the API is absent on some
-- clients), so this is pure and nil-safe when the API is unavailable.
local tokenPriceRequested = false
function lib.TokenPrice()
  if type(C_WowTokenPublic) ~= "table" then return nil end
  if not tokenPriceRequested then
    tokenPriceRequested = true
    if type(C_WowTokenPublic.UpdateMarketPrice) == "function" then
      pcall(C_WowTokenPublic.UpdateMarketPrice)
    end
  end
  if type(C_WowTokenPublic.GetCurrentMarketPrice) ~= "function" then return nil end
  local ok, price = pcall(C_WowTokenPublic.GetCurrentMarketPrice)
  if ok and type(price) == "number" and price > 0 then return price end
  return nil
end

------------------------------------------------------------------ enumeration ---
-- Reflection API for feed browsers (e.g. the Gadgets "Feeds…" picker): list every registered
-- feed and a feed's declared typed tokens. Both are nil-safe when LibDataBroker is absent.

-- GECData.Feeds([opts]) → array of { name = <LDB name>, slug = <slug>, object = <LDB data object> },
-- sorted by name. Reflects every registered LDB feed (plain LDB feeds AND typed-token feeds).
-- opts.oursOnly = true → return only feeds WE produced (object._gec, set by Provide) — the trusted
-- set; default / no opts = ALL feeds (unchanged).
-- FORCE a fresh scan of the live LDB registry every call (NOT the lazy EnsureIndex): a feed that
-- registered before our index first built — or whose DataObjectCreated callback we missed — would
-- otherwise be absent and the browser shows blank. RebuildIndex() re-enumerates DataObjectIterator
-- and indexes any not-yet-seen feed, so the list always reflects what's actually registered.
function lib.Feeds(opts)
  if not LDB then return {} end
  local oursOnly = opts and opts.oursOnly
  RebuildIndex(); dirtyIndex = false
  local out = {}
  for slug, name in pairs(slugToName) do
    local obj = LDB:GetDataObjectByName(name)
    if obj and (not oursOnly or obj._gec) then
      out[#out + 1] = { name = name, slug = slug, object = obj }
    end
  end
  table.sort(out, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
  return out
end

-- GECData.FeedTokens(slugOrObject) → array of { token = <sub-name>, type = <typeName> } for a feed's
-- DECLARED typed tokens (from its tokenTypes), sorted by token. Empty if the feed declares none
-- (a plain LDB feed). Accepts a slug string, a Provide handle ({object=...}), or a raw LDB object.
function lib.FeedTokens(feed)
  local obj
  if type(feed) == "table" then
    obj = feed.object or feed            -- a Provide handle (has .object) or a raw LDB object
  elseif feed ~= nil then
    obj = lib.FeedBySlug(feed)           -- a slug string → resolve to the LDB object
  end
  local out = {}
  if obj and type(obj.tokenTypes) == "table" then
    for tok, typ in pairs(obj.tokenTypes) do out[#out + 1] = { token = tok, type = typ } end
    table.sort(out, function(a, b) return a.token < b.token end)
  end
  return out
end

return lib
