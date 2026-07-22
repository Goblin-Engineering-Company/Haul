-- GECReader-1.0 — the single getter layer for GEC addons: the ONLY code that touches Blizzard APIs.
-- Current.* = live/transient reads; Resolve.* = stable id-keyed reads. The raw WoW calls live in the
-- injectable _adapter (mocked in tests); the facade below does the assembly + profiling + secret handling.
local MAJOR, MINOR = "GECReader-1.0", 11
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end
GECReader = lib

-- Distinguishes "present but secret right now" from "absent" (nil). Callers compare against this.
lib.SECRET = lib.SECRET or setmetatable({}, { __tostring = function() return "<secret>" end })

-- The adapter: raw WoW-API wrappers. Empty here; the WoW adapter (below) populates it in-game, tests mock it.
lib._adapter = lib._adapter or {}

-- Secret detection seam (WoW: issecretvalue). Overridable in tests.
lib._isSecret = lib._isSecret or function(v) return issecretvalue and issecretvalue(v) or false end

-- Profiling seam (off by default): counts calls per method so we can measure hot getters (e.g. buffs).
lib._profile = false
lib._counts = {}
local function prof(name) if lib._profile then lib._counts[name] = (lib._counts[name] or 0) + 1 end end
function lib.SetProfiling(on) lib._profile = on and true or false; if not lib._profile then lib._counts = {} end end
function lib.ProfileCounts() return lib._counts end

lib.Resolve = lib.Resolve or {}
lib.Current = lib.Current or {}

-- expose the prof helper to the rest of the file
lib._prof = prof

-- Resolve-by-ID: stable, cacheable entity attrs. Delegates to the adapter's normalized getter; returns
-- its record, nil (absent), or lib.SECRET (present-but-secret) unchanged.
local function makeResolve(kind)
  return function(id)
    lib._prof("resolve." .. kind)
    local fn = lib._adapter[kind]
    return fn and fn(id) or nil
  end
end
lib.Resolve.spell    = makeResolve("spell")
lib.Resolve.item     = makeResolve("item")
lib.Resolve.currency = makeResolve("currency")
lib.Resolve.faction  = makeResolve("faction")

-- Numeric map type for a continent (== Enum.UIMapType.Continent). Hardcoded because this facade is shared
-- with the headless test suite, which has no Enum; the value is stable across the client.
local MAPTYPE_CONTINENT = 2

-- The complete location cascade, continent->leaf: the most-specific continent as head (cosmic/world levels
-- above it are dropped), every map below it as zone levels, then the sub-zone TEXT as the area leaf. Each
-- level carries mapID (registry key) + numeric mapType (Display granularity) + kind. The one
-- LocationCascade — replaces SBF's and Haul's copies.
function lib.Current.location()
  lib._prof("current.location")
  local chain = (lib._adapter.mapChain and lib._adapter.mapChain()) or {}
  -- most-specific continent = lowest-index continent-type map in the best->root walk
  local contIdx
  for i = 1, #chain do if chain[i].mapType == MAPTYPE_CONTINENT then contIdx = i; break end end
  local out = {}
  local function push(lv, kind) out[#out + 1] = { mapID = lv.mapID, name = lv.name, mapType = lv.mapType, kind = kind } end
  if contIdx then
    push(chain[contIdx], "continent")
    for i = contIdx - 1, 1, -1 do push(chain[i], "zone") end
  else
    for i = #chain, 1, -1 do push(chain[i], "zone") end   -- rare: no continent in the chain
  end
  local sub = (lib._adapter.subzone and lib._adapter.subzone()) or ""
  if sub ~= "" and (#out == 0 or out[#out].name ~= sub) then
    out[#out + 1] = { name = sub, kind = "area" }   -- area leaf: sub-zone TEXT has no mapID
  end
  return out
end

-- Thin pass-through getters (no assembly), all profiled. nil-graceful when the adapter is empty.
function lib.Current.identity()
  lib._prof("current.identity")
  return lib._adapter.identity and lib._adapter.identity() or nil
end
function lib.Current.position()
  lib._prof("current.position")
  return lib._adapter.position and lib._adapter.position() or nil
end
function lib.build()
  return (lib._adapter.build and lib._adapter.build()) or "?"
end
function lib.factionStanding(id)
  lib._prof("factionStanding")
  return lib._adapter.factionStanding and lib._adapter.factionStanding(id) or nil
end

-- The player's faction list as { { factionID, name }, ... } (headers filtered out by the adapter). Lets a
-- consumer build a name->factionID reverse map (chat only gives the name). Profiled; nil-graceful -> {}.
function lib.Current.factionList()
  lib._prof("current.factionList")
  return (lib._adapter.factionList and lib._adapter.factionList()) or {}
end

-- The RAW best->root map ancestry as { { mapID, name, mapType }, ... } (unprocessed — location() is the
-- assembled cascade built ON this). For consumers that must check EVERY ancestor mapID (a continent->skill
-- lookup, a "which maps am I in now" set), not just the processed cascade. Profiled; nil-graceful -> {}.
function lib.Current.mapChain()
  lib._prof("current.mapChain")
  return (lib._adapter.mapChain and lib._adapter.mapChain()) or {}
end

-- Per-character live state getters (for the state cache). Pass-throughs over their adapter; nil-graceful.
-- 0-SAFE: `X and X()` (no `or nil`) returns the adapter's value verbatim, so an exact 0 (broke char / no
-- M+ rating) is cached as 0, not dropped. When the adapter fn is absent, the `and` yields nil.
function lib.Current.gold()
  lib._prof("current.gold")
  return lib._adapter.gold and lib._adapter.gold()
end
function lib.Current.ilvl()
  lib._prof("current.ilvl")
  return lib._adapter.ilvl and lib._adapter.ilvl()
end
function lib.Current.level()
  lib._prof("current.level")
  return lib._adapter.level and lib._adapter.level()
end
function lib.Current.bags()
  lib._prof("current.bags")
  return lib._adapter.bags and lib._adapter.bags()
end
function lib.Current.vault()
  lib._prof("current.vault")
  return lib._adapter.vault and lib._adapter.vault()
end
function lib.Current.mythicRating()
  lib._prof("current.mythicRating")
  return lib._adapter.mythicRating and lib._adapter.mythicRating()
end
function lib.Current.professionRoster()
  lib._prof("professionRoster")
  return lib._adapter.professionRoster and lib._adapter.professionRoster()
end

-- Build the profession roster from the WoW slot API. GetProfessions() returns prof1, prof2, archaeology,
-- fishing, cooking — WITH NIL HOLES (e.g. a char with no archaeology has a nil at slot 3). Packing into a
-- table and ipairs()'ing it truncates at the first nil and silently drops fishing/cooking; walk the varargs
-- instead so a hole can't stop iteration. Pure + injectable so it's headless-testable (the live adapter passes
-- the real WoW GetProfessions/GetProfessionInfo globals).
function lib._buildRoster(getProfessions, getProfessionInfo)
  local out
  local function scan(...)
    for i = 1, select("#", ...) do
      local idx = select(i, ...)
      if idx then
        local name, _, rank, maxRank, _, _, line, mod = getProfessionInfo(idx)
        if name and line then
          out = out or {}
          out[line] = { name = name, rank = rank, max = maxRank, mod = mod or 0 }
        end
      end
    end
  end
  scan(getProfessions())
  return out
end
function lib.Current.professionLines(ids) lib._prof("professionLines")
  if not lib._adapter.lineInfo then return nil end
  local out
  for _, id in ipairs(ids) do
    local info = lib._adapter.lineInfo(id)
    if info and (info.maxSkillLevel or 0) > 0 then  -- skip-unwarmed: max>0 is the warmth signal
      out = out or {}
      out[id] = { name = info.professionName, level = info.skillLevel or 0, max = info.maxSkillLevel }
    end
  end
  return out
end

-- Returns the full primary-profession catalog: { {id, name}, ... } for every skill line the client
-- reports. Delegates to adapter.allTradeSkillLines (id list) + adapter.lineInfo (per-id info record).
-- nil-graceful when either adapter fn is absent (headless / data not loaded yet).
function lib.ProfessionCatalogRaw()
  lib._prof("ProfessionCatalogRaw")
  local ids = lib._adapter.allTradeSkillLines and lib._adapter.allTradeSkillLines()
  if not ids then return nil end
  local out = {}
  for _, id in ipairs(ids) do
    local info = lib._adapter.lineInfo and lib._adapter.lineInfo(id)
    if info and info.professionName then
      out[#out + 1] = { id = id, name = info.professionName }
    end
  end
  return out
end

-- Reads a caller-supplied list of skill line IDs and returns {id,name,level,max} for each that has
-- data. Useful for targeted probes (e.g. fishing expansion lines) without enumerating all professions.
-- nil-graceful when adapter.lineInfo is absent.
function lib.ScanSkillLines(ids)
  lib._prof("ScanSkillLines")
  if not lib._adapter.lineInfo then return nil end
  local out = {}
  for _, id in ipairs(ids) do
    local info = lib._adapter.lineInfo(id)
    if info and info.professionName then
      out[#out + 1] = { id = id, name = info.professionName,
                        level = info.skillLevel or 0, max = info.maxSkillLevel or 0 }
    end
  end
  return out
end

-- Pure parser for the localized "Your skill in X has increased to N" chat message.
-- `lib._skillUpFormat` is the test seam (tests set it directly); live code sets it from ERR_SKILL_UP_SI.
-- Returns { skillName, newLevel } on match, nil otherwise.
lib._skillUpFormat = nil  -- test seam; live code sets it from ERR_SKILL_UP_SI
function lib.ParseSkillIncrease(msg)
  if type(msg) ~= "string" then return nil end
  local fmt = lib._skillUpFormat or ERR_SKILL_UP_SI  -- luacheck: globals ERR_SKILL_UP_SI
  if not fmt then return nil end
  -- escape magic chars, then restore the %s / %d capture groups
  local pat = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  pat = pat:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
  local name, num = msg:match(pat)
  if not (name and num) then return nil end
  return { skillName = name, newLevel = tonumber(num) }
end

-- One snapshot of HELPFUL auras. Normal auras key byName + bySpell. A secret-named aura is NOT dropped:
-- it's flagged { secret = true } and keyed bySpell when the spellId is readable (its name can't be a key).
-- PER-FRAME MEMO (MINOR 11): the snapshot is cached keyed on GetTime(), which is FROZEN for the whole frame
-- (WoW processes aura events between frames, never mid-frame) — so every caller in a frame shares one build
-- instead of re-walking the aura list 15-25x/tick. Zero staleness: a new frame = a new GetTime() = a rebuild.
-- Headless tests have no GetTime (now == nil) → never cached, so specs still see a fresh read each call.
local _buffsSnap, _buffsAt
function lib.Current.buffs()
  local now = GetTime and GetTime()
  if now and _buffsAt == now and _buffsSnap then return _buffsSnap end
  lib._prof("current.buffs")
  local byName, bySpell, ordered = {}, {}, {}
  local raw = (lib._adapter.auras and lib._adapter.auras()) or {}
  for _, a in ipairs(raw) do
    local nameSecret = lib._isSecret(a.name)
    local exp = a.expirationTime
    if exp and lib._isSecret(exp) then exp = nil end       -- a secret expiry would poison timer math
    local secondsLeft = (not exp or exp == 0) and math.huge or (exp - (GetTime and GetTime() or 0))
    local d = {
      name = (not nameSecret) and a.name or nil, spellId = a.spellId, icon = a.icon,
      duration = a.duration, expirationTime = exp, count = a.applications or 1,
      secondsLeft = secondsLeft, secret = nameSecret or nil,
    }
    ordered[#ordered + 1] = d
    if not nameSecret and a.name then byName[a.name] = d end
    if a.spellId and not lib._isSecret(a.spellId) then bySpell[a.spellId] = d end
  end
  local snap = { byName = byName, bySpell = bySpell, ordered = ordered }
  if now then _buffsSnap, _buffsAt = snap, now end   -- cache only in-game (GetTime present); tests stay fresh
  return snap
end

-- ===== live WoW adapter (in-game only; headless leaves _adapter empty so specs inject their own) =====
if C_Map or C_UnitAuras or GetBuildInfo then
  local a = lib._adapter
  function a.spell(id)
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
    if info then return { name = info.name, icon = info.iconID } end
    if GetSpellInfo then local name, _, icon = GetSpellInfo(id); return name and { name = name, icon = icon } or nil end
    return nil
  end
  function a.item(id)
    if not GetItemInfo then return nil end
    local name, _, quality, _, _, _, _, _, _, icon, sell = GetItemInfo(id)
    return name and { name = name, quality = quality, icon = icon, sellPrice = sell } or nil
  end
  function a.currency(id)
    local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(id)
    return info and { name = info.name, icon = info.iconFileID } or nil
  end
  function a.faction(id)
    local d = C_Reputation and C_Reputation.GetFactionDataByID and C_Reputation.GetFactionDataByID(id)
    return d and { name = d.name } or nil
  end
  function a.factionStanding(id)
    if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
      local mf = C_MajorFactions.GetMajorFactionData(id); if mf then return "Renown " .. tostring(mf.renownLevel) end
    end
    local fr = C_GossipInfo and C_GossipInfo.GetFriendshipReputation and C_GossipInfo.GetFriendshipReputation(id)
    if fr and fr.friendshipFactionID and fr.friendshipFactionID ~= 0 then return fr.reaction end
    local d = C_Reputation and C_Reputation.GetFactionDataByID and C_Reputation.GetFactionDataByID(id)
    if d and d.reaction then return _G["FACTION_STANDING_LABEL" .. d.reaction] end
    return nil
  end
  function a.identity()
    local name  = UnitName and UnitName("player") or "?"
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()) or "?"
    -- NOTE: plan had `local _, class = UnitClass and UnitClass("player")` — the `and` truncates the RHS
    -- to a single value, so class (2nd return) was ALWAYS nil in-game. select(2,...) captures it correctly.
    local class = UnitClass and select(2, UnitClass("player")) or nil
    return { guid = UnitGUID and UnitGUID("player"), name = name, realm = realm, class = class,
             faction = UnitFactionGroup and UnitFactionGroup("player"), region = GetCurrentRegion and GetCurrentRegion() }
  end
  function a.mapChain()
    local chain, mapID, guard = {}, C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"), 0
    while mapID and guard < 16 do
      guard = guard + 1
      local info = C_Map.GetMapInfo(mapID); if not info then break end
      chain[#chain + 1] = { mapID = mapID, name = info.name or "", mapType = info.mapType }
      mapID = info.parentMapID; if not mapID or mapID == 0 then break end
    end
    return chain
  end
  function a.subzone() return (GetSubZoneText and GetSubZoneText()) or "" end
  -- The player's faction list, headers dropped (a header/category row has factionID 0/nil). Modern
  -- C_Reputation path first; legacy GetFactionInfoByIndex fallback.
  function a.factionList()
    local out = {}
    if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
      for i = 1, (C_Reputation.GetNumFactions() or 0) do
        local d = C_Reputation.GetFactionDataByIndex(i)
        if d and d.factionID and d.factionID ~= 0 and d.name and d.name ~= "" then
          out[#out + 1] = { factionID = d.factionID, name = d.name }
        end
      end
    elseif GetNumFactions and GetFactionInfoByIndex then
      for i = 1, (GetNumFactions() or 0) do
        local name, _, _, _, _, _, _, _, isHeader, _, _, _, _, factionID = GetFactionInfoByIndex(i)
        if name and name ~= "" and not isHeader and factionID and factionID ~= 0 then
          out[#out + 1] = { factionID = factionID, name = name }
        end
      end
    end
    return out
  end
  -- HELPFUL aura scan. Raw fields passed through (name may be a secret value in-game); the facade
  -- (Current.buffs) flags/keys it. NOTE: this method is absent from the plan's Task 6 block; added
  -- because Current.buffs() (Task 5) requires it or buffs are always empty in-game.
  function a.auras()
    local list = {}
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
      for i = 1, 60 do
        local d = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
        if not d then break end
        list[#list + 1] = { name = d.name, spellId = d.spellId, icon = d.icon,
                            duration = d.duration, expirationTime = d.expirationTime, applications = d.applications }
      end
    end
    return list
  end
  function a.position()
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
    local px, py = pos and pos.x, pos and pos.y
    -- 12.0 secret values: a coord/facing can be SECRET in combat — doing math on it errors/taints. Treat a
    -- secret x/y as no-position and a secret facing as no-heading (issecretvalue is nil pre-12.0 -> skipped).
    if px ~= nil and py ~= nil and issecretvalue and (issecretvalue(px) or issecretvalue(py)) then return nil end
    local x = px and math.floor(px * 10000) / 100
    local y = py and math.floor(py * 10000) / 100
    local h = GetPlayerFacing and GetPlayerFacing()
    if h and issecretvalue and issecretvalue(h) then h = nil end
    h = h and math.floor(math.deg(h) + 0.5) % 360 or nil
    return (x and y) and { x = x, y = y, heading = h } or nil
  end
  function a.build() return (select(2, GetBuildInfo())) end
  function a.gold() return GetMoney and GetMoney() or nil end
  function a.ilvl()
    if not GetAverageItemLevel then return nil end
    local overall, equipped = GetAverageItemLevel()
    return { overall = overall, equipped = equipped }
  end
  function a.level() return UnitLevel and UnitLevel("player") or nil end
  function a.bags()
    if not (C_Container and C_Container.GetContainerNumFreeSlots and C_Container.GetContainerNumSlots) then return nil end
    local free, total = 0, 0
    for bag = 0, (NUM_BAG_SLOTS or 4) do
      total = total + (C_Container.GetContainerNumSlots(bag) or 0)
      free  = free  + (C_Container.GetContainerNumFreeSlots(bag) or 0)
    end
    return { free = free, total = total }
  end
  function a.vault()
    if not (C_WeeklyRewards and C_WeeklyRewards.GetActivities) then return nil end
    local tiers, anyReady = {}, false
    -- Enum.WeeklyRewardChestThresholdType: 1=Activities(M+/dungeon), 3=Raid, 6=World/Delve (values stable)
    local NAME = { [1] = "dungeon", [3] = "raid", [6] = "delve" }
    for _, act in ipairs(C_WeeklyRewards.GetActivities()) do
      local key = NAME[act.type] or ("t" .. tostring(act.type))
      local t = tiers[key] or { slots = 0, filled = 0 }
      t.slots = t.slots + 1
      if (act.progress or 0) >= (act.threshold or 0) then t.filled = t.filled + 1; anyReady = true end
      if act.level and act.level > (t.level or 0) then t.level = act.level end
      tiers[key] = t
    end
    return { ready = anyReady, tiers = tiers }
  end
  function a.mythicRating()
    if not (C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore) then return nil end
    return C_ChallengeMode.GetOverallDungeonScore()
  end
  function a.allTradeSkillLines()
    if not (C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines) then return nil end
    return C_TradeSkillUI.GetAllProfessionTradeSkillLines()
  end
  function a.lineInfo(id)
    if not (C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID) then return nil end
    return C_TradeSkillUI.GetProfessionInfoBySkillLineID(id)
  end
  if ERR_SKILL_UP_SI then lib._skillUpFormat = ERR_SKILL_UP_SI end
  function a.professionRoster()
    if not GetProfessions then return nil end
    -- delegate to the pure varargs-walking builder (handles the nil archaeology slot without truncating).
    -- newest-tier detail (current.*) stays nil at this layer; the Store fills it from the line scan.
    return lib._buildRoster(GetProfessions, GetProfessionInfo)
  end
end

return lib
