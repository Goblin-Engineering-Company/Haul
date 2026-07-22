-- GECStore-1.0 — shared persistent journal/event store + character/place identity registry
-- for Goblin Engineering Company WoW addons. Pure logic is headless-testable (luajit); all live-WoW
-- reads (identity, build stamp, entity resolve, faction standing) are delegated to GECReader-1.0.
local MAJOR, MINOR = "GECStore-1.0", 23   -- 23: + "quest" registry type (GECQuest atlas). 22: PurgeThroughBuild (unload sessions/events/markers at-or-before a build). 21: NewSession (atomic Close→Begin for the "New" button). 20: Combine (retrospective typed combine session). 19: PlaceIndex uses GECMap for the place id. 18: RepairOrphans (encapsulate events whose markers were lost). 17: RepairIfDangling reasonOverride. 16: mail+vendor excluded from value. 15: character bound at Begin. 14: Sideline/Restore. 13: + Session module.
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end   -- a newer copy is already loaded

-- expose the table as a convenience global too (matches GECTemplate usage)
GECStore = lib

-- GECReader handle, looked up LAZILY at every call (never cached at load): the Reader may load after us
-- in-game, and the headless suite injects a mock into LibStub AFTER GECStore has loaded. A load-time
-- capture would be nil forever and never see the injected/late Reader.
local function reader()
  return (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECReader-1.0")) or nil
end

-- injectable clock: WoW provides time(); tests override lib._now for determinism.
lib._now = function() return time() end

-- deep copy of plain-data tables (no metatables / cycles in our registry)
local function deepCopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepCopy(v) end
  return out
end

-- entity types and how each is keyed. composite = interned to an integer index (heavy/multi-part
-- ids: char GUID, place mapID-cascade); simple = keyed by its own raw id (spell/faction/currency/item).
-- ONE global format version for the whole GEC exported-data format (see the unified-schema spec §9). Stamped
-- into every store's export envelope at Snapshot so the aggregator/server can migrate. Monotonic int: bump on
-- any cross-cutting/breaking change to the emitted shape (the kind-collapse is the first — it becomes 2).
-- Per-stream `schema` sub-versions (below) evolve independently for changes confined to one stream.
lib.FORMAT_VERSION = lib.FORMAT_VERSION or 1

local TYPES = {
  char     = { composite = true },
  place    = { composite = true },
  spell    = { simple = true },
  faction  = { simple = true },
  currency = { simple = true },
  item     = { simple = true },
  npc      = { simple = true },   -- creature: npcID -> {name}; name is CALLER-supplied (no npcID->name API)
  object   = { simple = true },   -- game object / gather node / fishing pool: objID -> {name}; caller-supplied
  quest    = { simple = true },   -- quest atlas (GECQuest-1.0): questID -> {name, giver/ender, location, rewards}
}

-- Fishing and cooking skill-line IDs across all expansions. Used by ProfessionCatalog to supplement
-- the primary profession catalog (these lines don't appear in C_Professions.GetProfessions).
local FISHING_COOKING_IDS = {
  356, 2585, 2586, 2587, 2588, 2589, 2590, 2591, 2592, 2754, 2826, 2876, 2911,   -- fishing
  185, 2541, 2542, 2543, 2544, 2545, 2546, 2547, 2548, 2752, 2824, 2873, 2908,   -- cooking
}

-- Extract the last whitespace-delimited word of a name: "Khaz Algar Herbalism" -> "Herbalism".
local function professionOfName(name)
  local last = name and name:match("(%S+)%s*$")
  return last
end

-- Return the active Reader: honors a test-injected override so headless specs can fake catalog responses.
local function activeReader() return lib._readerOverride or reader() end

-- injectable client build stamp (tests override). Delegates to the Reader in-game; headless (no Reader)
-- falls back to GetBuildInfo, then "?" when even that is absent.
lib._build = function()
  local R = reader()
  if R and R.build then return R.build() end
  return (GetBuildInfo and (select(2, GetBuildInfo()))) or "?"
end

-- Compose / split the canonical character key "Account.Realm.Name". account defaults to "Default"
-- (WoW exposes no account name in-game; the aggregator stamps the real one at ingest).
function lib.MakeKey(account, realm, name)
  return ("%s.%s.%s"):format(account or "Default", realm or "?", name or "?")
end

function lib.SplitKey(key)
  return key:match("^(.-)%.(.-)%.(.+)$")
end

-- Ensure the canonical SavedVariable shape exists. SavedVariables are restored before any consumer
-- runs; this fills a fresh one on first touch. _gen drives the persist indicator (bumped per login).
function lib.EnsureDB()
  GECStoreDB = GECStoreDB or {}
  local db = GECStoreDB
  db.version  = 2
  db._gen     = db._gen or 0
  db.registry = db.registry or {}
  db.enabledFields = db.enabledFields or {}   -- [fieldKey] = true; optional fields opt in here (base is always on)
  for t in pairs(TYPES) do
    db.registry[t] = db.registry[t] or { items = {}, _byKey = {} }
    local r = db.registry[t]
    if not next(r._byKey) and #r.items > 0 then        -- rebuild the key map after a fresh load
      for i = 1, #r.items do r._byKey[r.items[i].key] = i end
    end
  end
  return db
end

-- Upsert a registry row keyed by `key`; refresh attrs + build + lastSeen. Returns the interned index.
local function upsert(typ, id, key, attrs)
  local db = lib.EnsureDB()
  local reg = db.registry[typ]
  assert(reg, "unknown registry type: " .. tostring(typ))
  local now = lib._now()
  local idx = reg._byKey[key]
  if not idx then
    idx = #reg.items + 1
    local row = { id = id, key = key, build = lib._build(), firstSeen = now, lastSeen = now }
    if attrs then for k, v in pairs(attrs) do row[k] = v end end
    reg.items[idx] = row
    reg._byKey[key] = idx
  else
    local row = reg.items[idx]
    row.lastSeen = now
    row.build = lib._build()
    if id ~= nil and row.id == nil then row.id = id end   -- backfill a content-hash id computed after the row first existed
    if attrs then for k, v in pairs(attrs) do if v ~= nil then row[k] = v end end end
  end
  return idx
end

-- Public intern. Composite types return the interned index; simple types return their id.
function lib.Intern(typ, id, key, attrs)
  local idx = upsert(typ, id, key, attrs)
  return TYPES[typ] and TYPES[typ].simple and id or idx
end

-- Read by interned index (composite types).
function lib.Info(typ, idx)
  if type(idx) ~= "number" then return nil end
  local reg = lib.EnsureDB().registry[typ]
  return reg and reg.items[idx] or nil
end

-- Read by stable key (simple types: key == id; composite: key == GUID / cascade string).
function lib.Resolve(typ, key)
  local reg = lib.EnsureDB().registry[typ]
  if not reg then return nil end
  local idx = reg._byKey[key]
  return idx and reg.items[idx] or nil
end

-- Snapshot a simple-type entity into the registry from the Reader. Re-pulls only when the row is missing
-- or was captured under an older client build (self-healing after a patch). Returns the id. GECStore no
-- longer touches WoW APIs itself: entity attrs come from GECReader.Resolve[typ](id).
function lib.Note(typ, id)
  if id == nil then return nil end
  local existing = lib.Resolve(typ, id)
  if existing and existing.build == lib._build() then return id end   -- fresh enough
  local R = reader()
  local attrs = (R and R.Resolve and R.Resolve[typ] and R.Resolve[typ](id)) or nil
  if R and R.SECRET and attrs == R.SECRET then attrs = nil end   -- don't cache a secret snapshot
  lib.Intern(typ, id, id, attrs)
  return id
end

-- Upsert a simple entity whose NAME the caller supplies (npc/object — there's no id->name WoW API for these,
-- so a consumer that learns the name, e.g. from a nameplate or a "You perform X on <node>" line, records it
-- here so it persists account-wide and resolves later even with no live source). Idempotent: only rewrites when
-- the name actually changed. Returns the id.
-- `extra` (optional) merges additional STATIC attrs onto the entity (e.g. an npc's creatureType /
-- classification / family, learned from a live unit). Idempotent: re-interns only when the name OR any
-- provided extra attr actually changed (or the client build rolled).
function lib.NoteNamed(typ, id, name, extra)
  if id == nil or not (name and name ~= "") then return id end
  local existing = lib.Resolve(typ, id)
  if existing and existing.name == name and existing.build == lib._build() then
    if not extra then return id end
    local same = true
    for k, v in pairs(extra) do if existing[k] ~= v then same = false; break end end
    if same then return id end
  end
  local attrs = { name = name }
  if extra then for k, v in pairs(extra) do if v ~= nil then attrs[k] = v end end end
  lib.Intern(typ, id, id, attrs)
  return id
end

-- Upsert the current character into the registry; return its stable integer index. Keyed by GUID
-- (the stable identity) so a delete+recreate of a same-name character never collides; before
-- PLAYER_LOGIN a GUID may be absent, so fall back to the name key until one is available.
function lib.UpsertChar(identity)
  local key = identity.guid or lib.MakeKey(identity.account, identity.realm, identity.name)
  return lib.Intern("char", identity.guid, key, {
    account = identity.account or "Default", realm = identity.realm or "?", name = identity.name or "?",
    region = identity.region, guid = identity.guid, class = identity.class, faction = identity.faction,
  })
end

-- Serialize a cascade to its stable key: the mapID at each level, root->leaf. A level with no mapID
-- falls back to a name sentinel so it still dedups deterministically without colliding with real IDs.
local function cascadeKey(cascade)
  local parts = {}
  for i = 1, #cascade do
    local lv = cascade[i]
    parts[i] = lv.mapID and tostring(lv.mapID) or ("n:" .. (lv.name or ""))
  end
  return table.concat(parts, ">")
end

-- Intern a complete location cascade (root->leaf, each level { mapID, name, mapType }). Returns the
-- interned place index, or nil for an empty/nil cascade.
function lib.PlaceIndex(cascade)
  if not cascade or #cascade == 0 then return nil end
  -- canonical content-addressed place id = the cascadeHash (GECMap-1.0, spec §4 — the `places` registry is
  -- keyed by cascadeHash). Computed at CAPTURE so it's identical on every client and the server verifies it
  -- against its pinned vectors. Falls back to nil if GECMap isn't loaded (the interned index still dedups).
  local GECMap = LibStub and LibStub:GetLibrary("GECMap-1.0", true)
  local id = (GECMap and GECMap.CascadeHash) and GECMap.CascadeHash(cascade) or nil
  return lib.Intern("place", id, cascadeKey(cascade), { cascade = deepCopy(cascade) })
end

-- Resolve an interned place index back to its complete cascade (read side for viewers). nil/unknown -> nil.
function lib.PlaceInfo(idx)
  local row = lib.Info("place", idx)
  return row and row.cascade or nil
end

-- Look up a character by interned index (number) or by GUID/key string.
function lib.CharInfo(idxOrKey)
  if type(idxOrKey) == "number" then return lib.Info("char", idxOrKey) end
  return lib.Resolve("char", idxOrKey)
end

-- Most-recently-seen char interned index whose display name matches, or nil. (Realm-qualified names later.)
function lib.CharByName(name)
  local items = lib.EnsureDB().registry.char.items
  local best, bestSeen
  for i = 1, #items do
    if items[i].name == name and (not bestSeen or (items[i].lastSeen or 0) > bestSeen) then
      best, bestSeen = i, items[i].lastSeen or 0
    end
  end
  return best
end

-- Bump the write generation. Called once per login (Task 7). Records written this session carry
-- the new _gen; after the next flush + reload they read as 'persisted' (gen < the newer _gen).
function lib.BumpGen()
  local db = lib.EnsureDB()
  db._gen = (db._gen or 0) + 1
  return db._gen
end

local StoreMT = {}
StoreMT.__index = StoreMT

function StoreMT:Stream(name)
  local sv = _G[self._sv]
  sv.streams[name] = sv.streams[name] or {}
  return sv.streams[name]
end

function StoreMT:Stamp(rec)
  rec.t = rec.t or lib._now()
  rec.gen = lib.EnsureDB()._gen
  if self._src then rec.src = rec.src or self._src end   -- source addon, configured at RegisterStore
  return rec
end

-- The source tag configured for this store (e.g. "SBF"/"Haul"). Lets a consumer that appends
-- directly (not via Append) stamp the same configured source onto its records.
function StoreMT:Src() return self._src end

function StoreMT:Append(name, rec)
  self:Stamp(rec)
  local s = self:Stream(name)
  s[#s + 1] = rec               -- append-only, oldest first
  return rec
end

function StoreMT:IsPersisted(rec)
  return (rec.gen or 0) < lib.EnsureDB()._gen
end

function StoreMT:PendingCount(name)
  local gen = lib.EnsureDB()._gen
  local sv, total = _G[self._sv], 0
  local function countStream(s) for i = 1, #s do if (s[i].gen or 0) >= gen then total = total + 1 end end end
  if name then countStream(self:Stream(name))
  else for _, s in pairs(sv.streams) do countStream(s) end end
  return total
end

-- Register (and shape-init) a per-addon store living in the SavedVariable named opts.sv.
-- opts: sv (SavedVariable name), src (source/producer tag on records), schemaVersion (this store's shape,
-- default 1), build (the producer addon's BUILD stamp — string or a function returning it; stamped into the
-- export envelope so the server can special-case a specific buggy build), streamSchemas ({ [stream]=N } for
-- per-stream sub-versions; defaults to the store schemaVersion).
function lib.RegisterStore(opts)
  assert(type(opts) == "table" and type(opts.sv) == "string", "RegisterStore needs opts.sv")
  lib.EnsureDB()
  _G[opts.sv] = _G[opts.sv] or {}
  local sv = _G[opts.sv]
  sv.version = opts.schemaVersion or sv.version or 1
  sv.streams = sv.streams or {}
  sv._gen    = sv._gen    or 0
  return setmetatable({ _sv = opts.sv, _src = opts.src, _build = opts.build, _streamSchemas = opts.streamSchemas },
    StoreMT)
end

-- Resolve the producer build stamp (string or function) to a plain value for the envelope.
local function resolveBuild(b)
  if type(b) == "function" then local ok, v = pcall(b); return ok and v or nil end
  return b
end

-- The versioned EXPORT ENVELOPE for this store's SavedVariable (unified-schema spec §9). Stamped at Snapshot
-- so the file the aggregator reads is always self-describing: the global format version, who produced it +
-- their build, the registry shape, and per-stream schema sub-versions.
function StoreMT:_stampEnvelope()
  local db = lib.EnsureDB()
  local sv = _G[self._sv]
  local streams = {}
  for name in pairs(sv.streams or {}) do
    local s = self._streamSchemas and self._streamSchemas[name]
    streams[name] = { schema = s or sv.version or 1 }
  end
  sv._format = {
    formatVersion   = lib.FORMAT_VERSION,
    producer        = self._src,
    producerBuild   = resolveBuild(self._build),
    registryVersion = db.version,
    schemaVersion   = sv.version,
    streams         = streams,
    generatedAt     = (time and time()) or nil,
  }
  return sv._format
end

-- Embed a copy of the canonical registry into this store's SV so an exported file is self-contained
-- (resolves ch/p without the live GECStoreDB) AND stamp the versioned envelope. Call at export time (logout).
function StoreMT:Snapshot()
  local db = lib.EnsureDB()
  _G[self._sv]._registry = deepCopy(db.registry)
  self:_stampEnvelope()
  return _G[self._sv]._registry
end

-- ===== display layer (single render path; color injected so the data core stays pure) =====
lib._color = nil
function lib.SetColorProvider(fn) lib._color = fn end
local function colored(role, text)
  if lib._color and role then return lib._color(role, text) end
  return text
end

-- Default in-game color provider (class-colored names, quality-colored items) from WoW's globals. GUARDED
-- so a headless run installs nothing (data core stays plain-text; the suite is unaffected). SetColorProvider
-- still overrides. Roles emitted by Display: "class:<FILE>" and "quality:<n>".
if RAID_CLASS_COLORS or ITEM_QUALITY_COLORS then
  lib._color = lib._color or function(role, text)
    local kind, key = role:match("^(%a+):(.+)$")
    if kind == "class" then
      local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[key]
      return "|c" .. ((c and c.colorStr) or "ffcccccc") .. text .. "|r"
    elseif kind == "quality" then
      local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[tonumber(key) or 1]
      return (q and q.hex or "|cffffffff") .. text .. "|r"
    end
    return text
  end
end

-- Format a cached state value for display by its descriptor fmt. Minimal for v1 (refine the fmt set later).
function lib._fmtState(fmt, v)
  if fmt == "money" and type(v) == "number" then return math.floor(v / 10000) .. "g" end
  if fmt == "place" then local c = lib.PlaceInfo(v); return c and lib.RenderCascade(c, "zone") or "" end
  if fmt == "vault" and type(v) == "table" then return v.ready and "ready" or "-" end
  if fmt == "professions" and type(v) == "table" then
    local n = 0; if v.roster then for _ in pairs(v.roster) do n = n + 1 end end
    return n .. " profession" .. (n == 1 and "" or "s")
  end
  return tostring(v)
end

-- Render a stored cascade at a named granularity. mapType convention: 2=continent, 3=zone, others=area.
-- Levels are root->leaf; we pick by mapType, falling back to position so it works even if types are sparse.
local function levelByType(cascade, mapType)
  for i = #cascade, 1, -1 do if cascade[i].mapType == mapType then return cascade[i] end end
  return nil
end
function lib.RenderCascade(cascade, granularity)
  if not cascade or #cascade == 0 then return "" end
  granularity = granularity or "full"
  local cont = levelByType(cascade, 2)
  local zone = levelByType(cascade, 3)
  local leaf = cascade[#cascade]
  if granularity == "detail"    then return leaf.name end   -- most specific level (map-zone / subzone)
  if granularity == "continent" then return (cont and cont.name) or leaf.name end
  if granularity == "zone"      then return (zone and zone.name) or leaf.name end
  if granularity == "continent_zone" then
    local a = cont and cont.name; local b = (zone and zone.name) or leaf.name
    return a and (a .. " › " .. b) or b
  end
  -- "full": every level from the continent down to the leaf, skipping the cosmic/world root(s) (mapType<2)
  local names = {}
  for i = 1, #cascade do
    local lv = cascade[i]
    if (lv.mapType == nil or lv.mapType >= 2) and lv.name and lv.name ~= "" then names[#names + 1] = lv.name end
  end
  return table.concat(names, " › ")
end

-- True if another char row shares this row's display name (then we disambiguate with a GUID fragment).
local function charNameClashes(row)
  local items = lib.EnsureDB().registry.char.items
  for i = 1, #items do
    if items[i] ~= row and items[i].name == row.name then return true end
  end
  return false
end
local function guidFragment(guid)
  if not guid then return "" end
  return "·" .. guid:sub(-4)          -- last 4 of the GUID, enough to disambiguate visually
end

-- Render a professions state value for a given facet string.
-- bare "professions"       -> "N profession(s)"
-- "professions.<name>"     -> skill rank for that profession (by roster name, case-insensitive)
-- anything unmatched       -> ""
function lib._displayProfessions(prof, facet)
  if type(prof) ~= "table" then return "" end
  if facet == "professions" then
    local n = 0; if prof.roster then for _ in pairs(prof.roster) do n = n + 1 end end
    return n .. " profession" .. (n == 1 and "" or "s")
  end
  local sub = facet:match("^professions%.(.+)$")
  if sub and prof.roster then
    local want = sub:lower()
    for _, p in pairs(prof.roster) do
      if p.name and p.name:lower() == want then
        local lvl = p.rank or (p.current and p.current.level)
        return lvl and tostring(lvl) or ""   -- never a placeholder "0" (consumer contract)
      end
    end
  end
  return ""   -- known-but-missing -> blank (not the literal token)
end

-- The single formatter. `ref` is an interned index for char/place, a raw id for simple types.
function lib.Display(typ, ref, opts)
  opts = opts or {}
  local row = (typ == "char" or typ == "place") and lib.Info(typ, ref) or lib.Resolve(typ, ref)
  if not row then return typ .. "#" .. tostring(ref) end
  if typ == "char" then
    if opts.facet then
      if opts.facet == "professions" or opts.facet:match("^professions%.") then
        local out = lib._displayProfessions(row.state and row.state.professions, opts.facet)
        return out
      end
      local d = lib._fields and lib._fields[opts.facet]
      local v
      if d and d.scope == "warbound" then
        local w = lib.EnsureDB().warband
        v = w and w.state and w.state[opts.facet]
      else
        v = row.state and row.state[opts.facet]
      end
      if v == nil then return "" end
      return lib._fmtState((d and d.fmt) or "number", v)
    end
    local name = row.name or "?"
    if opts.disambiguate or charNameClashes(row) then name = name .. guidFragment(row.guid) end
    return colored(row.class and ("class:" .. row.class) or nil, name)
  elseif typ == "place" then
    return lib.RenderCascade(row.cascade, opts.granularity)
  elseif typ == "item" then
    return colored("quality:" .. tostring(row.quality or 1), "[" .. (row.name or "?") .. "]")
  elseif typ == "faction" then
    local R = reader()
    local standing = R and R.factionStanding and R.factionStanding(ref) or nil
    local name = row.name or ("faction#" .. tostring(ref))
    return standing and (name .. " (" .. standing .. ")") or name
  end
  return row.name or (typ .. "#" .. tostring(ref))   -- spell / currency
end

-- ===== identity seam (delegates to GECReader; NOT headless-tested; verified in-game) =====
-- Resolve the current character's identity via the Reader (GECStore no longer calls WoW APIs). Overridable
-- for tests. Headless (no Reader) yields a neutral fallback so CurrentKey/UpsertChar stay well-defined.
function lib._identity()
  local R = reader()
  if R and R.Current and R.Current.identity then
    return R.Current.identity() or { account = "Default", realm = "?", name = "?" }
  end
  return { account = "Default", realm = "?", name = "?" }   -- headless fallback
end

function lib.CurrentKey()
  local id = lib._identity()
  return lib.MakeKey(id.account, id.realm, id.name)
end

function lib.CharIndex()
  return lib.UpsertChar(lib._identity())
end

-- ===== per-character state cache: field descriptors + snapshot engine =====
-- A descriptor: { key, scope="character"|"warbound", tier="base"|"optional", events={...}, get=fn, fmt }.
-- Snapshot writes each base field's live value (via its get) onto the current char's row.state (or the
-- account-wide warband slot for scope="warbound"). Extensible: adding a field = one RegisterField call.
lib._fields = lib._fields or {}
function lib.RegisterField(desc)
  if type(desc) == "table" and desc.key then lib._fields[desc.key] = desc end
end
function lib.Fields() return lib._fields end

-- Optional fields snapshot only when enabled here (base fields are always snapshotted). Persisted account-wide.
function lib.IsFieldEnabled(key) return lib.EnsureDB().enabledFields[key] == true end
function lib.SetFieldEnabled(key, on)
  lib.EnsureDB().enabledFields[key] = on and true or nil
  if on then lib.SnapshotState() end   -- turning it on populates the current char immediately
end

function lib.SnapshotState()
  local idx = lib.CharIndex()                 -- ensures the current char's row exists; returns its index
  local row = lib.Info("char", idx); if not row then return end
  row.state = row.state or {}
  for key, d in pairs(lib._fields) do
    if (d.tier == "base" or lib.IsFieldEnabled(key)) and type(d.get) == "function" then
      local ok, v = pcall(d.get)
      if ok and v ~= nil then
        -- merge: shallow-accumulate a table result into the existing map (keys survive across snapshots);
        -- a nil result never reaches here (guarded above), so it preserves whatever was merged.
        if type(d.apply) == "function" then
          d.apply(row, v)               -- custom write hook (character-scoped in v1)
        elseif d.scope == "warbound" then
          local db = lib.EnsureDB(); db.warband = db.warband or {}; db.warband.state = db.warband.state or {}
          if d.merge and type(v) == "table" then
            db.warband.state[key] = db.warband.state[key] or {}
            for mk, mv in pairs(v) do db.warband.state[key][mk] = mv end
          else
            db.warband.state[key] = v
          end
        else
          if d.merge and type(v) == "table" then
            row.state[key] = row.state[key] or {}
            for mk, mv in pairs(v) do row.state[key][mk] = mv end
          else
            row.state[key] = v
          end
        end
      end
    end
  end
  row.stateAt = lib._now()
end

-- Debounce a burst of snapshot requests: in live WoW, coalesces via C_Timer (one snapshot ~0.2s after the
-- last request). Under the _debounceSync test seam the first call snapshots once and latches _pending so
-- subsequent calls in the same burst are no-ops (deterministic, no timer needed in headless tests).
function lib.RequestSnapshot()
  if lib._debounceSync then
    if lib._pending then return end
    lib._pending = true
    lib.SnapshotState()
    return
  end
  lib._snapGen = (lib._snapGen or 0) + 1
  local gen = lib._snapGen
  if C_Timer and C_Timer.After then
    C_Timer.After(0.2, function() if gen == lib._snapGen then lib.SnapshotState() end end)
  else
    lib.SnapshotState()
  end
end

-- v1 base field descriptors (lazy Reader getters). location stores the interned place index.
do
  local function R() return reader() end
  lib.RegisterField({ key = "gold",     scope = "character", tier = "base", events = { "PLAYER_MONEY" },
                      get = function() return R() and R().Current.gold() end, fmt = "money" })
  lib.RegisterField({ key = "ilvl",     scope = "character", tier = "base",
                      get = function() local i = R() and R().Current.ilvl(); return i and i.overall end, fmt = "number" })
  lib.RegisterField({ key = "level",    scope = "character", tier = "base",
                      get = function() return R() and R().Current.level() end, fmt = "number" })
  lib.RegisterField({ key = "bags",     scope = "character", tier = "base", events = { "BAG_UPDATE_DELAYED" },
                      get = function() local b = R() and R().Current.bags(); return b and b.free end, fmt = "number" })
  lib.RegisterField({ key = "location", scope = "character", tier = "base", events = { "ZONE_CHANGED_NEW_AREA" },
                      get = function() local c = R() and R().Current.location(); return c and lib.PlaceIndex(c) end, fmt = "place" })
  lib.RegisterField({ key = "vault",    scope = "character", tier = "base", events = { "WEEKLY_REWARDS_UPDATE" },
                      get = function() return R() and R().Current.vault() end, fmt = "vault" })
  lib.RegisterField({ key = "mythic",   scope = "character", tier = "base", events = { "CHALLENGE_MODE_COMPLETED" },
                      get = function() return R() and R().Current.mythicRating() end, fmt = "number" })
  -- professions: OPTIONAL (opt-in) — dual-source (roster + lines) with custom apply that replaces the
  -- roster authoritatively, accumulates warmed lines, and reconcile-purges lines for dropped professions.
  lib.RegisterField({
    key = "professions", scope = "character", tier = "optional",
    events = { "SKILL_LINES_CHANGED", "TRADE_SKILL_LIST_UPDATE" },
    facet = "professions", fmt = "professions",
    get = function()
      local Rd = activeReader(); if not Rd then return nil end
      local cat = lib.ProfessionCatalog() or {}
      local ids = {}; for id in pairs(cat) do ids[#ids + 1] = id end
      return {
        roster = Rd.Current and Rd.Current.professionRoster and Rd.Current.professionRoster(),
        lines  = Rd.Current and Rd.Current.professionLines and Rd.Current.professionLines(ids),
      }
    end,
    apply = function(row, v)
      row.state.professions = row.state.professions or { roster = {}, lines = {} }
      local st = row.state.professions
      if v.roster then st.roster = v.roster end                 -- roster: authoritative replace
      st.lines = st.lines or {}
      if v.lines then for id, l in pairs(v.lines) do st.lines[id] = l end end   -- lines: accumulate (already max>0)
      -- reconcile-purge: drop lines whose profession is not in the current roster
      local cat = lib.ProfessionCatalog() or {}
      local have = {}
      if st.roster then for _, p in pairs(st.roster) do if p.name then have[p.name] = true end end end
      for id in pairs(st.lines) do
        local prof = cat[id] and cat[id].profession
        if prof and not have[prof] then st.lines[id] = nil end
      end
    end,
  })
end
-- Professions warmth = "are the per-expansion skill lines READABLE from the LIVE game API right now?",
-- NOT "did I observe TRADE_SKILL_LIST_UPDATE this UI-session". Those two differ across a /reload: the client
-- keeps serving live per-expansion data (levels AND the +modifier) after a reload with no journal open, but
-- the UI-session flag is wiped by the Lua teardown — so the old flag falsely read "cold" after every reload
-- (indicator went gray though the data was live). Evidence: the warm-after-reload console probe, 2026-07-09.
-- So warmth SELF-HEALS: the flag is the fast path (a journal open marks it), and when the flag is false
-- ProfessionsWarmed() probes the live API and latches true if the data is genuinely there. Not persisted.
lib._warm = lib._warm or false
-- Live probe: does the game currently serve per-expansion data for any of THIS character's cached lines?
-- Cold (fresh login, journal never opened) -> maxSkillLevel 0 -> false. Warm (opened once this game-login,
-- survives reloads) -> maxSkillLevel > 0 -> true. The cache is used only to know WHICH lines to ask about.
function lib._liveProbe()
  local G = C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID
  if not G then return false end
  local idx = lib.CharIndex and lib.CharIndex()
  local ci = idx and lib.CharInfo and lib.CharInfo(idx)
  local lines = ci and ci.state and ci.state.professions and ci.state.professions.lines
  if not lines then return false end
  for lineID in pairs(lines) do
    local p = G(lineID)
    if p and (p.maxSkillLevel or 0) > 0 then return true end
  end
  return false
end
function lib.ProfessionsWarmed()
  if lib._warm then return true end
  local now = GetTime and GetTime() or 0
  if lib._lastProbe and now > 0 and (now - lib._lastProbe) < 1 then return false end  -- throttle cold re-probes
  lib._lastProbe = now
  if lib._liveProbe() then lib._warm = true; return true end
  return false
end
function lib._markWarm() lib._warm = true end
function lib._resetWarm() lib._warm = false; lib._lastProbe = nil end

-- Live snapshot triggers: entering world + logout + the union of every descriptor's events.
if CreateFrame then
  local sf = CreateFrame("Frame")
  local ev = { PLAYER_ENTERING_WORLD = true, PLAYER_LOGOUT = true }
  for _, d in pairs(lib._fields) do if d.events then for _, e in ipairs(d.events) do ev[e] = true end end end
  for e in pairs(ev) do sf:RegisterEvent(e) end
  sf:SetScript("OnEvent", function(_, event)
    if event == "TRADE_SKILL_LIST_UPDATE" then lib._markWarm() end
    -- Deliberately NO reset on PLAYER_ENTERING_WORLD: a /reload or zone-in does not close the live
    -- trade-skill data, so forcing cold here is what caused the gray-after-reload bug. On a /reload the
    -- Lua teardown already re-inits _warm=false, and ProfessionsWarmed() re-derives it from the live API;
    -- on a zone change warmth legitimately persists. (Was: if PEW then lib._resetWarm().)
    lib.RequestSnapshot()
  end)
end

-- One-time login wiring: bump the write generation (so this session's records read as "pending" until
-- the next flush) and register the current character. Guarded so multiple embedding addons run it once.
do
  local f = CreateFrame and CreateFrame("Frame")
  if f and not lib._loginHooked then
    lib._loginHooked = true
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function()
      lib.BumpGen()
      lib.CharIndex()
    end)
  end
end

-- Build and persist a lineID -> { name, profession } catalog. Primaries come from
-- Reader.ProfessionCatalogRaw(); fishing/cooking base lines from Reader.ScanSkillLines(FISHING_COOKING_IDS).
-- The crafting-order line "Tuskarr Fishing Gear" (name ends in "Gear") is excluded.
-- The result is cached in GECStoreDB.professionCatalog and invalidated per client build stamp.
function lib.ProfessionCatalog()
  local db = lib.EnsureDB()
  local build = lib._build()
  if db.professionCatalog and db.professionCatalogBuild == build then return db.professionCatalog end
  local R = activeReader()
  if not R then return db.professionCatalog end   -- keep any prior cache if reader absent
  local cat = {}
  local primaries = R.ProfessionCatalogRaw and R.ProfessionCatalogRaw()
  if primaries then
    for _, e in ipairs(primaries) do
      if not (e.name and e.name:match("Gear%s*$")) then   -- drop crafting-order "... Gear" lines
        cat[e.id] = { name = e.name, profession = professionOfName(e.name) }
      end
    end
  end
  local fc = R.ScanSkillLines and R.ScanSkillLines(FISHING_COOKING_IDS)
  if fc then
    for _, e in ipairs(fc) do cat[e.id] = { name = e.name, profession = professionOfName(e.name) } end
  end
  db.professionCatalog = cat
  db.professionCatalogBuild = build
  return cat
end

-- ===== subscribable skill-increase event =====
-- Session-only (not persisted). OnSkillIncrease(fn) -> unsubscribe fn. FireSkillIncrease(payload) dispatches.
lib._skillSubs = lib._skillSubs or {}
function lib.OnSkillIncrease(fn)
  if type(fn) ~= "function" then return function() end end
  lib._skillSubs[fn] = true
  return function() lib._skillSubs[fn] = nil end
end
function lib.FireSkillIncrease(payload)
  for fn in pairs(lib._skillSubs) do pcall(fn, payload) end
end

-- Reverse-lookup: find the lineID (and profession) for a given skill name via the catalog.
function lib._lineIdByName(name)
  local cat = lib.ProfessionCatalog() or {}
  for id, e in pairs(cat) do if e.name == name then return id, e.profession end end
  return nil
end

-- Parse a CHAT_MSG_SKILL message, resolve the skill name to a catalog lineID, patch the current
-- char's cached line, and fire OnSkillIncrease. Returns the payload on success, nil if the message
-- is not a skill-increase message or the skill name is unrecognised. Chat-scrape does NOT set the
-- warmth flag — only a journal open (TRADE_SKILL_LIST_UPDATE) does that.
function lib.HandleSkillMessage(msg)
  local R = activeReader(); if not R or not R.ParseSkillIncrease then return nil end
  local p = R.ParseSkillIncrease(msg); if not p then return nil end
  local lineID, profession = lib._lineIdByName(p.skillName)
  if not lineID then return nil end
  -- patch the current char's cached line + compute delta (skip gracefully if no current char, e.g. headless)
  local idx = lib.CharIndex and lib.CharIndex()
  local row = idx and lib.CharInfo and lib.CharInfo(idx)
  local prevLevel, maxv
  if row then
    row.state = row.state or {}
    row.state.professions = row.state.professions or { roster = {}, lines = {} }
    row.state.professions.lines = row.state.professions.lines or {}
    local cur = row.state.professions.lines[lineID]
    prevLevel = cur and cur.level
    maxv = cur and cur.max
    row.state.professions.lines[lineID] = { name = p.skillName, level = p.newLevel, max = maxv or 0 }
  end
  local payload = {
    lineID = lineID, profession = profession, skillName = p.skillName,
    newLevel = p.newLevel, prevLevel = prevLevel,
    delta = prevLevel and (p.newLevel - prevLevel) or nil,
    max = maxv, isFishing = (profession == "Fishing"), ts = lib._now(),
  }
  lib.FireSkillIncrease(payload)
  return payload
end

-- Live frame: dispatch CHAT_MSG_SKILL into HandleSkillMessage.
if CreateFrame then
  local cf = CreateFrame("Frame")
  cf:RegisterEvent("CHAT_MSG_SKILL")
  cf:SetScript("OnEvent", function(_, _, msg) lib.HandleSkillMessage(msg) end)
end

return lib
