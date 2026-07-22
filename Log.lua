-- Log.lua — Haul's continuous, append-only event log (the data foundation).
-- See docs/superpowers/specs/2026-06-11-haul-event-log-data-model-design.md
--
-- The log is ALWAYS-ON: it records every income event (item / coin / quest / rep)
-- the moment it happens, regardless of pause/stop state, with full map cascade +
-- position + heading. Session lifecycle is recorded as markers (start/stop/pause/
-- resume), each carrying a unique session id (sid). ns.session still drives the
-- live bar/stats; this engine runs underneath it (Spec 1, additive hybrid).
local ADDON, ns = ...

local DATA_VERSION = 6   -- v6 = session-model rework (spec 2026-07-16): lifecycle+exclusion MARKERS move to
                         -- streams.markers; the per-session record fattens to the frozen §3.3 shape written at
                         -- CLOSE via GECStore.Session; income facts stay in streams.events. v5 = dropped loot `v`.
                         -- v4 = journal relocated to HaulData.streams.events. v3 = collapsed k+src schema.
                         -- Crossing it AUTO-WIPES the old-format log/sessions + old-format saved snapshots
                         -- (pre-release, no migration). The old bespoke HaulData.log array is dumped for good.

------------------------------------------------------------------- store ------
-- HaulData: separate versioned store (config stays in HaulDB). Account-wide;
-- each entry tags its character (ch) and place (p).
local GECStore = LibStub("GECStore-1.0")
-- Lazy GECReader handle (the one live-getter layer; silent=true -> nil if absent, never errors).
local function reader()
  return (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECReader-1.0", true)) or nil
end
-- The Haul store: schemaVersion tracks DATA_VERSION; NO `src` tag (the loot-source `src` is set per-entry;
-- the export envelope's `producer` already identifies the addon, so GECStore's Stamp must not re-add one).
local haulStoreHandle
local function haulStore()
  haulStoreHandle = haulStoreHandle or GECStore.RegisterStore({ sv = "HaulData", schemaVersion = DATA_VERSION,
    build = function() return Haul and Haul.BUILD end })
  return haulStoreHandle
end

-- The session controller (GECStore.Session bound to Haul's store): it owns the lifecycle — mints the sid,
-- lays start/stop/pause/resume/fold MARKERS on streams.markers, and freezes the §3.3 record into
-- HaulData.sessions[sid] at close. Lazy (the Session module attaches after GECStore-1.0 loads).
local sessionCtrl
local function Session()
  if not sessionCtrl then
    local S = GECStore.Session
    if S and S.For then sessionCtrl = S.For(haulStore()) end
  end
  return sessionCtrl
end
ns.SessionCtrl = Session   -- Core uses this for Fold / Sideline / Restore / RepairIfDangling / OnEvent
if Haul then Haul.SessionCtrl = Session end   -- global entry point (GEC-Console purge / diagnostics)

-- Append an exclusion toggle to the MARKERS stream (spec §3.4). on=true → "exclude" (item now excluded),
-- on=false → "include" (re-included). The controller resolves the running-target into the record at close.
function ns.LogExclude(id, on)
  if not (HaulData and id) then return end
  -- `t` is REQUIRED: Session._resolveExclusions matches exclude/include markers by `t <= atTime`, so a
  -- marker with no timestamp is silently dropped (exclusions never resolve, in-game record AND server).
  haulStore():Append("markers", { k = on and "exclude" or "include", id = id, t = time() })
end

local function InitData()
  HaulData = HaulData or {}
  local d = HaulData
  -- Clean-start migration to the shared GECStore registry: a v1 store interned chars/places locally
  -- (HaulData.chars / HaulData.places). v2 delegates both to GECStore, so the old log + interning are
  -- abandoned and rebuilt fresh. HaulDB.history snapshots (separate SV) are untouched.
  if d.version and d.version < DATA_VERSION then
    -- Clean-start: dump the legacy bespoke array + its bookkeeping. v4 keeps the journal in the exported
    -- GECStore stream HaulData.streams.events instead (created lazily by the first Append).
    d.log, d.sessions, d.nextSid, d.chars, d.places = nil, nil, nil, nil, nil
    d.streams = nil   -- v4: also drop any old-format stream so events restart clean (pre-release, no migration)
    d._open, d._sidelined = nil, nil   -- v6: drop the controller's open/parked pointers (they point at wiped sessions)
    -- v6: the restored live session references wiped sessions/markers, so clear it + any set-aside run so a
    -- clean new session starts after the crossing (the DATA_VERSION bump IS the supported wipe path).
    if HaulDB then HaulDB.liveSession = nil; HaulDB.sidelined = nil end
    -- v3: the saved-session snapshots (HaulDB.history, a separate SV) hold OLD-format drops the collapsed
    -- Replay can't read, so clear them once too (pre-release, no migration).
    if d.version < 3 and HaulDB and HaulDB.history then HaulDB.history = {} end
  end
  d.version  = DATA_VERSION
  d.sessions = d.sessions or {}   -- [sid] = the frozen §3.3 record (builds/gameEnv/timing/prices/exclusions), written at close
  d.ah       = d.ah       or {}   -- auction-house sales (STUB)
  -- The event journal now lives in HaulData.streams.events (append-only, created lazily by haulStore():Append).
  -- Ensure the store is registered so its stream table + snapshot embed exist.
  haulStore()
  -- NOTE: chars/places are no longer stored here — ns.CharIndex/ns.PlaceIndex delegate to GECStore.
end
ns.InitLog = InitData

-- Embed a copy of the shared GECStore registry into HaulData on logout, so an exported Haul file
-- resolves its ch/p indices without the live GECStoreDB. The journal itself lives in the exported
-- stream HaulData.streams.events, and Snapshot() records the per-stream schema in the embed header.
local gecLogoutFrame = CreateFrame("Frame")
gecLogoutFrame:RegisterEvent("PLAYER_LOGOUT")
gecLogoutFrame:SetScript("OnEvent", function() haulStore():Snapshot() end)

------------------------------------------------------------- session ids ------
-- Collision-proof, time-ordered string sid: "<server-seconds hex>-<random 16-bit hex>". No longer depends on
-- HaulData.nextSid (dumped at v4). Sorts chronologically by the leading timestamp; the random tail avoids
-- same-second collisions across chars sharing the account-wide stream.
function ns.NewSid()
  return string.format("%x-%04x", GetServerTime(), math.random(0, 0xffff))
end

----------------------------------------------------- interned characters ------
-- Delegate to the shared GECStore registry so `ch` indexes GECStoreDB.characters (same space as SBF).
function ns.CharIndex()
  return GECStore.CharIndex()
end

--------------------------------------------------------- location cascade -----
-- Full variable-depth cascade, broad -> specific, delegated to GECReader.Current.location() — the ONE
-- location cascade shared with SBF (it owns the C_Map walk / continent detection / subzone leaf). Each
-- level: { mapID, name, mapType, kind = "continent"|"zone"|"area" } (the area leaf has no mapID). The
-- mapID per level is what makes Haul's interned places timeline-stable and share SBF's registry keys.
-- Returns {} when the Reader is absent (never errors).
function ns.LocationCascade()
  local R = reader()
  local loc = R and R.Current and R.Current.location and R.Current.location()
  return loc or {}
end

------------------------------------------------------ deduped place dict ------
-- Delegate to the shared GECStore registry so `p` indexes GECStoreDB.places (same space as SBF).
-- GECStore dedups on the cascade; the cascade's leaf already carries the sub-zone (the "area" level).
function ns.PlaceIndex()
  return GECStore.PlaceIndex(ns.LocationCascade())
end

------------------------------------------------- current position + heading ---
-- Coords + heading from the getter layer (x/y 0-100 2-decimal, heading whole degrees 0-359). Current.position()
-- is now combat-safe (a secret coord comes back as no-position, a secret facing as no-heading), so this is a
-- clean swap for the old local C_Map/GetPlayerFacing walk. A field just stays nil when absent (no error).
local function curPos()
  local R = reader()
  local pos = R and R.Current and R.Current.position and R.Current.position()
  if not pos then return nil, nil, nil end
  return pos.x, pos.y, pos.heading
end

----------------------------------------------- the single append choke point --
-- payload may carry `sid` (markers); otherwise the active session's sid is used.
function ns.LogEvent(kind, payload)
  if not HaulData then return end
  local e = { t = time(), k = kind }   -- no envelope src tag; a per-entry loot-source `src` may arrive via payload
  local s = ns.session
  if s and s.sid then e.sid = s.sid end
  e.ch = ns.CharIndex()
  e.p  = ns.PlaceIndex()
  local x, y, h = curPos()
  if x then e.x = x end
  if y then e.y = y end
  if h then e.h = h end
  if payload then for k, v in pairs(payload) do e[k] = v end end   -- payload.sid (markers) overrides
  haulStore():Append("events", e)   -- append-only, oldest-first, into the exported HaulData.streams.events
  ns._dirty = true   -- live data now differs from disk until the next reload/logout write
  return e
end

------------------------------------------------- sessions: begin + markers ----
-- Lifecycle is owned by GECStore.Session (the controller): Begin mints the sid + lays the `start`
-- MARKER on streams.markers; Close freezes the §3.3 record (incl. Core's price snapshot) + lays `stop`;
-- Pause/Resume lay their markers. These ns.* names stay thin wrappers so every Core call site is unchanged.
function ns.BeginSession(s)
  local S = Session(); if not (HaulData and S) then return end
  -- INVARIANT: at most ONE open session. If one is already open here (a begin path that forgot to
  -- LogStop, or a crash/relog that left it dangling), CLOSE it FIRST — RepairIfDangling lays its `stop`
  -- at the last recorded activity + freezes the §3.3 record. Otherwise Begin clobbers the open pointer
  -- and orphans a `start` with no `stop` (the "lots of starts, few stops" bug). No-op if already closed.
  -- Safe for sidelining: Sideline() has already parked _open (IsOpen == false), so this won't fire there.
  if S:IsOpen() then
    S:RepairIfDangling((ns.session and ns.BuildPriceSnapshot and ns.BuildPriceSnapshot(ns.session)) or {})
  end
  s.sid = S:Begin("user")
end

-- Folded into Begin (which lays the start marker) — a no-op so a stray caller doesn't lay a duplicate.
function ns.LogStart(_sid) end   -- luacheck: ignore _sid

-- Close the current session. `prices` = the frozen snapshot Core builds (defaults to a snapshot of the
-- live session); the controller resolves exclusions from the marker history and writes the record at close.
function ns.LogStop(sid, prices)
  local S = Session(); if not (sid and S and S:IsOpen()) then return end
  return S:Close("user", prices or (ns.BuildPriceSnapshot and ns.BuildPriceSnapshot(ns.session)) or {})
end

function ns.LogPause(sid)  local S = Session(); if sid and S then S:Pause() end end
function ns.LogResume(sid) local S = Session(); if sid and S then S:Resume() end end

--------------------------------------------------------------- retention ------
-- NO-OP as of v4. The journal is now HaulData.streams.events — an APPEND-ONLY GECStore stream, and shortening
-- it would break the sync cursor and silently halt syncing. So prune must never trim the stream. Retention of
-- synced data is a server-side concern now; this is kept only so /haul prune <N> doesn't error. Returns 0.
function ns.PruneLog(_keepN)   -- luacheck: ignore _keepN
  return 0
end

-- DEV: purge the EVENT LOG — clears the append-only journal (HaulData.streams.events) AND the session
-- index (HaulData.sessions), since orphaned index rows are useless without their events. This is what the
-- "Purge log" dev button has always PROMISED; previously it cleared only the index, so the stream never
-- emptied (the bug: "sessions cleared, logs wouldn't"). Manual/pre-release only — the caller reloads after,
-- and a consuming reader (Uplink) re-syncs from an empty stream. Saved Sessions (HaulDB.history, a separate
-- SV) are UNTOUCHED. Returns the number of event entries removed. (Post-release, clearing an append-only
-- stream mid-life would break a live sync cursor — the DATA_VERSION clean-start is the supported wipe path.)
function ns.PurgeLog()
  if not HaulData then return 0 end
  local n = (HaulData.streams and HaulData.streams.events and #HaulData.streams.events) or 0
  if HaulData.streams then
    if HaulData.streams.events  then wipe(HaulData.streams.events)  end
    if HaulData.streams.markers then wipe(HaulData.streams.markers) end   -- markers are part of the RECORD too;
  end                                                                     -- leaving them orphans start/stop/fold rows
  HaulData.sessions = {}
  -- drop every pointer INTO the wiped record so nothing dangles onto gone markers/events. The caller
  -- reloads after; RestoreOrNew then starts a clean fresh session on the now-empty streams.
  HaulData._open, HaulData._sidelined = nil, nil
  if HaulDB then HaulDB.liveSession, HaulDB.sidelined = nil, nil end
  ns._dirty = true
  return n
end

-- DEV: purge all SAVED SESSIONS (HaulDB.history — the banked/reconstructed runs shown on the Data tab). The
-- event log (HaulData.log) is untouched. Returns the number of saved sessions removed.
function ns.PurgeSessions()
  local n = (HaulDB and HaulDB.history and #HaulDB.history) or 0
  if HaulDB then HaulDB.history = {} end
  return n
end

---------------------------------------------------- stream / diag --
-- The event journal, as its append-only GECStore stream table (oldest-first). Readers follow this.
function ns.LogStream()
  return (HaulData and HaulData.streams and HaulData.streams.events) or {}
end

