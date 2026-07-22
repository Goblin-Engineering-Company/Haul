-- GECStore-Session — the session engine MODULE of GECStore-1.0 (spec §5, packaging decided v8).
-- Namespace: GECStore.Session. Sessions are PER-STORE (Haul's live in HaulData, SBF's in SBFData),
-- so the controller binds to a store handle: GECStore.Session.For(handle). The readable spec API
-- (Begin/Close/Pause/Resume/Fold/Current/Sid/IsOpen/ActiveSeconds/Get/OnEvent) hangs off that
-- controller. This file currently implements the PURE CORE (Resolve) first, per build order §1;
-- the live-capture mutators land next.
--
-- Resolve(data) is the reconstruct path — a PURE function of captured data (spec §2.3 invariant):
-- ZERO live API calls. It reduces a store's frozen records + event/marker streams to the ratified
-- resolved.json parity shape (spec §10.6), verified byte-for-byte against testdata/sessions/*.

local lib = LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECStore-1.0")
if not lib then return end
-- Version guard (mirrors LibStub's "higher minor wins" / GECTheme-Box:26): this module re-attaches Session.*
-- onto the shared GECStore-1.0 table, so WITHOUT it an OLDER embed loading after a newer one would clobber the
-- newer Session engine with its older methods (the documented "no change" bug class). Only attach when THIS
-- copy's SESSION_MINOR beats what's stamped, then stamp it — newest wins regardless of addon load order, and
-- an older copy loading later is a no-op. Bump SESSION_MINOR on every Session change that must supersede copies.
local SESSION_MINOR = 1
if lib._sessionMinor and lib._sessionMinor >= SESSION_MINOR then return end
lib._sessionMinor = SESSION_MINOR
lib.Session = lib.Session or {}
local Session = lib.Session

-- Monetary event kinds whose `amount` is a FACT that sums into gold `coin` (§7a.1 coin carve-out).
-- Only LOOTED coin feeds a session's value. mail + vendor are informational (Haul shows them in their own
-- categories): mail gold is AH returns / transfers / self-mail (not fresh income), and vendor sell is
-- converting already-counted loot to gold (counting it too would double it). Buy/repair are spend.
local MONETARY = { coin = true }

-- Sum pause spans [{p,r},…] -> total paused seconds (a dangling span with no r contributes 0).
local function pausedSeconds(pauses)
  local total = 0
  if pauses then
    for _, span in ipairs(pauses) do
      if span.p and span.r then total = total + (span.r - span.p) end
    end
  end
  return total
end

-- Reduce ONE session id to its value segment: items aggregated by id (valued at the record's frozen
-- price snapshot), coin summed from monetary facts, gross/counted split by the record's exclusions,
-- activeSeconds derived from the timing skeleton. Pure — reads only `data` (no live API).
local function reduceSegment(data, sid)
  local rec = data.sessions[sid]
  local events = (data.streams and data.streams.events) or {}

  local byId, coin = {}, 0
  for _, e in ipairs(events) do
    if e.sid == sid then
      if e.k == "loot" and e.from ~= "mail" then   -- mail-collected loot is informational (Haul's Mail category), not haul value
        local price = rec.prices and rec.prices[e.id]
        local it = byId[e.id]
        if not it then
          it = { id = e.id, count = 0, unit = (price and price.unit) or 0, source = (price and price.source) or "?" }
          byId[e.id] = it
        end
        it.count = it.count + (e.count or 0)
      elseif MONETARY[e.k] then
        coin = coin + (e.amount or 0)
      end
    end
  end

  local excluded = {}
  if rec.exclusions then for _, id in ipairs(rec.exclusions) do excluded[id] = true end end

  local items = {}
  for _, it in pairs(byId) do
    it.value = it.count * it.unit
    it.excluded = excluded[it.id] and true or false
    items[#items + 1] = it
  end
  table.sort(items, function(a, b) return a.id < b.id end)

  local itemGross, itemCounted = 0, 0
  for _, it in ipairs(items) do
    itemGross = itemGross + it.value
    if not it.excluded then itemCounted = itemCounted + it.value end
  end

  return {
    sid = sid,
    startedAt = rec.startedAt,
    closedAt = rec.closedAt,
    activeSeconds = (rec.closedAt - rec.startedAt) - pausedSeconds(rec.pauses),
    items = items,
    coin = coin,
    gross = itemGross + coin,
    counted = itemCounted + coin,
  }
end

local function unionInOrder(dst, list, seen)
  if not list then return end
  for _, v in ipairs(list) do
    if not seen[v] then seen[v] = true; dst[#dst + 1] = v end
  end
end

-- Resolve a whole store table (sessions map + streams.events + streams.markers) to the resolved.json
-- shape (spec §10.6): { sessions = [ … ] } sorted by startedAt asc then sid. Only CLOSED sessions
-- (has closedAt — completeness gate §4) are emitted; absorbed fold segments are rolled into their
-- surviving session and not emitted standalone.
function Session.Resolve(data)
  local sessions = data.sessions or {}
  local markers = (data.streams and data.streams.markers) or {}

  -- fold graph + close reasons from the markers stream (audit source; the record carries no fold field)
  local absorbed, foldOf, closeReason = {}, {}, {}
  for _, m in ipairs(markers) do
    if m.k == "fold" then
      foldOf[m.sid] = foldOf[m.sid] or { via = m.via, from = {} }
      foldOf[m.sid].from[#foldOf[m.sid].from + 1] = m.fromsid
      absorbed[m.fromsid] = true
    elseif m.k == "stop" and m.reason then
      closeReason[m.sid] = m.reason
    end
  end

  local out = {}
  for sid, rec in pairs(sessions) do
    if rec.closedAt and not absorbed[sid] then
      local fold = foldOf[sid]
      if fold then
        -- rolled-up view: segments = absorbed (in fold order) then the surviving session
        local segs = {}
        for _, fromsid in ipairs(fold.from) do segs[#segs + 1] = reduceSegment(data, fromsid) end
        segs[#segs + 1] = reduceSegment(data, sid)

        local builds, seen = {}, {}
        local gross, counted, coin, active = 0, 0, 0, 0
        local exclUnion, exclSeen = {}, {}
        local segOut = {}
        for _, s in ipairs(segs) do
          unionInOrder(builds, data.sessions[s.sid].builds, seen)
          unionInOrder(exclUnion, data.sessions[s.sid].exclusions, exclSeen)
          gross, counted, coin, active = gross + s.gross, counted + s.counted, coin + s.coin, active + s.activeSeconds
          segOut[#segOut + 1] = {
            sid = s.sid, startedAt = s.startedAt, closedAt = s.closedAt,
            activeSeconds = s.activeSeconds, gross = s.gross, counted = s.counted, items = s.items,
          }
        end
        table.sort(exclUnion, function(a, b) return a < b end)

        out[#out + 1] = {
          sid = sid, character = rec.character, builds = builds,
          startedAt = rec.startedAt, closedAt = rec.closedAt, activeSeconds = active,
          coin = coin, gross = gross, counted = counted, exclusions = exclUnion,
          via = fold.via, foldedFrom = fold.from, segments = segOut,
          closeReason = closeReason[sid],
        }
      else
        local seg = reduceSegment(data, sid)
        local excl = {}
        if rec.exclusions then for _, id in ipairs(rec.exclusions) do excl[#excl + 1] = id end end
        table.sort(excl, function(a, b) return a < b end)
        out[#out + 1] = {
          sid = sid, character = rec.character, schemaVersion = rec.schemaVersion,
          builds = rec.builds, gameEnv = rec.gameEnv,
          startedAt = rec.startedAt, closedAt = rec.closedAt, activeSeconds = seg.activeSeconds,
          coin = seg.coin, gross = seg.gross, counted = seg.counted, exclusions = excl,
          items = seg.items, closeReason = closeReason[sid],
        }
      end
    end
  end

  table.sort(out, function(a, b)
    if a.startedAt ~= b.startedAt then return a.startedAt < b.startedAt end
    return a.sid < b.sid
  end)
  return { sessions = out }
end

-- ===== close-time derivations (PURE; the capture-side counterparts Resolve reads) =====

-- Derive the timing skeleton for `sid` from the markers stream: startedAt/closedAt/pauses(+closeReason).
-- Pauses pair pause→resume in stream order; an unclosed pause stays open (dangling). Pure (spec §3.3/§4).
function Session._deriveTiming(markers, sid)
  local startedAt, closedAt, closeReason
  local pauses, open = {}, nil
  for _, m in ipairs(markers or {}) do
    if m.sid == sid then
      if m.k == "start" then startedAt = m.t
      elseif m.k == "stop" then closedAt, closeReason = m.t, m.reason
      elseif m.k == "pause" then open = { p = m.t }; pauses[#pauses + 1] = open
      elseif m.k == "resume" then if open then open.r = m.t; open = nil end
      end
    end
  end
  return { startedAt = startedAt, closedAt = closedAt, pauses = pauses, closeReason = closeReason }
end

-- Resolve the excluded item-id set as of `atTime` — the global running-target (spec §3.4):
-- for each item the latest exclude/include marker with t ≤ atTime wins (exclude ⇒ in, include ⇒ out).
-- Scans the WHOLE markers stream (not one sid's group) — that was the retroactive-UI bug. Pure.
function Session._resolveExclusions(markers, atTime)
  local latest = {}
  for _, m in ipairs(markers or {}) do
    if (m.k == "exclude" or m.k == "include") and m.id and m.t and m.t <= atTime then
      local cur = latest[m.id]
      if not cur or m.t >= cur.t then latest[m.id] = { t = m.t, on = (m.k == "exclude") } end
    end
  end
  local out = {}
  for id, v in pairs(latest) do if v.on then out[#out + 1] = id end end
  table.sort(out)
  return out
end

-- ===== live-capture controller: GECStore.Session.For(handle) (spec §5.1) =====
-- Bound to a store handle (sessions are per-store: HaulData vs SBFData). The open session pointer
-- persists on the SV (`_open`) so it survives /reload; markers append to the handle's markers stream;
-- the frozen record lands in the SV's top-level `sessions` map at close.

local CtrlMT = {}
CtrlMT.__index = CtrlMT

local function store(self) return _G[self._sv] end
local function fire(self, evt, sid, reason)
  for fn in pairs(self._subs) do pcall(fn, evt, sid, reason) end
end
local function addonBuild(handle)
  local b = handle and handle._build
  if type(b) == "function" then local ok, v = pcall(b); return ok and v or nil end
  return b
end

-- gameEnv snapshot (injectable for tests). Live: GetBuildInfo (client build + interface) + WOW_PROJECT_ID.
Session._gameEnv = function()
  local clientBuild, interface
  if GetBuildInfo then local v, _, _, iface = GetBuildInfo(); clientBuild, interface = v, iface end
  return { clientBuild = clientBuild, interface = interface, flavor = WOW_PROJECT_ID }
end

-- Deterministic-enough sid: "<now hex>-<random 16-bit hex>" (matches Haul's NewSid format; sorts by time).
function Session._newSid(now)
  return string.format("%x-%04x", now or 0, math.random(0, 0xffff))
end

-- Assemble the frozen §3.3 record from the markers stream + supplied prices + capture metadata.
local function freezeRecord(self, sid, prices, openState)
  local st = store(self)
  local timing = Session._deriveTiming(st.streams and st.streams.markers, sid)
  st.sessions = st.sessions or {}
  st.sessions[sid] = {
    builds        = openState.builds,
    gameEnv       = Session._gameEnv(),
    schemaVersion = openState.schema,
    startedAt     = timing.startedAt,
    closedAt      = timing.closedAt,
    pauses        = timing.pauses,
    character     = openState.character or lib.CharIndex(),   -- the CREATOR (bound at Begin), not the closer
    prices        = prices or {},
    exclusions    = Session._resolveExclusions(st.streams and st.streams.markers, timing.closedAt or lib._now()),
  }
  return st.sessions[sid]
end

function Session.For(handle)
  assert(handle and handle._sv, "GECStore.Session.For needs a store handle")
  return setmetatable({ _sv = handle._sv, _handle = handle, _subs = {} }, CtrlMT)
end

function CtrlMT:OnEvent(fn)
  if type(fn) == "function" then self._subs[fn] = true end
  return function() self._subs[fn] = nil end
end

function CtrlMT:Begin(policyTag)
  local st = store(self)
  local now = lib._now()
  local sid = Session._newSid(now)
  -- character is bound at CREATION (the runner), not at close — sessions persist across relog, so the char
  -- logged in when the session closes may not be who ran it.
  st._open = { sid = sid, builds = { addonBuild(self._handle) }, schema = st.version, policy = policyTag,
               character = lib.CharIndex() }
  local who = (lib._identity and lib._identity().name) or nil
  self._handle:Append("markers", { k = "start", sid = sid, who = who, t = now })
  fire(self, "open", sid)
  return sid
end

-- 0-based build index for the CURRENT build, appending to `builds` on a mid-session addon-version
-- change (§7d.2). The addon calls this when appending an event and stamps `b` when the result > 0.
function CtrlMT:CurrentBuildIndex()
  local open = store(self)._open
  if not open then return 0 end
  local b = addonBuild(self._handle)
  if b and open.builds[#open.builds] ~= b then open.builds[#open.builds + 1] = b end
  for i = 1, #open.builds do if open.builds[i] == b then return i - 1 end end
  return 0
end

function CtrlMT:Pause()
  local open = store(self)._open; if not open then return end
  self._handle:Append("markers", { k = "pause", sid = open.sid, t = lib._now() })
  fire(self, "pause", open.sid)
end

function CtrlMT:Resume()
  local open = store(self)._open; if not open then return end
  self._handle:Append("markers", { k = "resume", sid = open.sid, t = lib._now() })
  fire(self, "resume", open.sid)
end

function CtrlMT:Fold(fromsid, via)
  local open = store(self)._open; if not open then return end
  self._handle:Append("markers", { k = "fold", sid = open.sid, fromsid = fromsid, via = via, t = lib._now() })
end

-- Close the open session: stop marker + freeze the record. `prices` = the addon's frozen snapshot
-- {[itemID]={unit,source}} (GECStore doesn't value items). reason ∈ user/logout/boundary/…
function CtrlMT:Close(reason, prices)
  local st = store(self); local open = st._open
  if not open then return nil end
  self._handle:Append("markers", { k = "stop", sid = open.sid, reason = reason or "user", t = lib._now() })
  freezeRecord(self, open.sid, prices, open)
  st._open = nil
  fire(self, "close", open.sid, reason or "user")
  return open.sid
end

-- Manual "New session" (the one call behind Haul's / SBF's New button): close the open session (if any) at
-- NOW with reason "new", then Begin a fresh one — returning the new sid. Sequencing Close→Begin in ONE
-- synchronous call guarantees the `stop` marker is appended BEFORE the new `start` (they may share a
-- same-second `t`, but append order — and the log viewer's stable sort — keep stop-before-start; Resolve is
-- unaffected since it derives each session's timing from its OWN sid's markers). The addon must NOT
-- hand-sequence Close+Begin itself (that's how the start-before-stop ordering bugs crept in). `prices` freezes
-- the closed session's item values (SBF passes {} until it prices catches); `policyTag` tags the new session.
function CtrlMT:NewSession(prices, policyTag)
  if store(self)._open then self:Close("new", prices) end
  return self:Begin(policyTag or "user")
end

-- Closure safety net (spec §4). If a session was left open with no stop (hard crash → no logout, OR a
-- schemaVersion changed under it), insert the stop at the LAST recorded event/marker ts (not now, so
-- idle crash time isn't counted) and freeze the record. reason = version-change if the store schema
-- moved, else crash-repair. The addon calls this once on init before opening a fresh session.
-- reasonOverride: the caller states WHY it's closing at last-activity. A fresh-login close of a session
-- that spanned a logout passes "logout" (accurate + not a crash); omit it for a true dangling repair
-- (crash / schema change), where the reason is inferred.
function CtrlMT:RepairIfDangling(prices, reasonOverride)
  local st = store(self); local open = st._open
  if not open then return nil end
  local streams = st.streams or {}
  if Session._deriveTiming(streams.markers, open.sid).closedAt then st._open = nil; return nil end
  local lastT = 0
  for _, m in ipairs(streams.markers or {}) do if m.sid == open.sid and (m.t or 0) > lastT then lastT = m.t end end
  for _, e in ipairs(streams.events or {}) do if e.sid == open.sid and (e.t or 0) > lastT then lastT = e.t end end
  if lastT == 0 then lastT = lib._now() end
  local reason = reasonOverride or ((open.schema ~= st.version) and "version-change" or "crash-repair")
  self._handle:Append("markers", { k = "stop", sid = open.sid, reason = reason, t = lastT })
  freezeRecord(self, open.sid, prices, open)
  st._open = nil
  fire(self, "repair", open.sid, reason)
  return open.sid, reason
end

-- Recover ORPHANED events (spec §4, data-loss safety net). A sid that has events in the stream but NO
-- start marker lost its lifecycle — e.g. the markers stream was wiped/corrupted while events remained.
-- Such events are invisible to Resolve (no closedAt) and would be lost. Synthesize a lifecycle at the
-- events' OWN timestamps (append-only, honest): every orphan sid gets a `start` at its first event ts;
-- any orphan that is NOT the current open run also gets a `stop` at its last event ts + a minimal frozen
-- record (reason "recovered"), so Resolve emits it. The current open run (if its start was also lost) is
-- re-anchored with just a start and stays OPEN. `priceFor(id)` is an optional best-effort pricer for the
-- recovered items (the frozen prices are gone with the wipe; nil ⇒ coin + counts recovered, item value 0).
-- Returns # recovered. Call on init, before opening/continuing the live session.
function CtrlMT:RepairOrphans(priceFor)
  local st = store(self)
  local events  = (st.streams and st.streams.events)  or {}
  local markers = (st.streams and st.streams.markers) or {}
  local openSid = (st._open or {}).sid
  local hasStart = {}
  for _, m in ipairs(markers) do if m.k == "start" and m.sid then hasStart[m.sid] = true end end
  local first, last, ids, order = {}, {}, {}, {}
  for _, e in ipairs(events) do
    local sid = e.sid
    if sid and not hasStart[sid] then
      if first[sid] == nil then first[sid] = e.t or 0; last[sid] = e.t or 0; ids[sid] = {}; order[#order + 1] = sid end
      if (e.t or 0) < first[sid] then first[sid] = e.t or 0 end
      if (e.t or 0) > last[sid]  then last[sid]  = e.t or 0 end
      if e.k == "loot" and e.id and e.from ~= "mail" then ids[sid][e.id] = true end
    end
  end
  local n = 0
  for _, sid in ipairs(order) do
    self._handle:Append("markers", { k = "start", sid = sid, t = first[sid], reason = "recovered" })
    if sid == openSid then
      -- the live run lost its start; re-anchor it but keep it OPEN (no stop / no frozen record yet)
      st._open = st._open or { sid = sid, builds = { addonBuild(self._handle) }, schema = st.version, character = lib.CharIndex() }
      fire(self, "recover", sid, "orphan-open")
    else
      self._handle:Append("markers", { k = "stop", sid = sid, t = last[sid], reason = "recovered" })
      local prices = {}
      if priceFor then for id in pairs(ids[sid]) do local p = priceFor(id); if p then prices[id] = p end end end
      st.sessions[sid] = {
        builds = { addonBuild(self._handle) }, schema = st.version,
        startedAt = first[sid], closedAt = last[sid], pauses = {}, character = lib.CharIndex(),
        prices = prices, exclusions = {}, recovered = true,
      }
      fire(self, "recover", sid, "orphan")
    end
    n = n + 1
  end
  return n
end

-- COMBINE N already-closed sessions into ONE new typed session (the user's "combine selected"). Unlike
-- merge/resume (which fold into the LIVE run), combine is a retrospective grouping of SAVED sessions:
-- pause the live run, mint a fresh sid, lay `start` + N × `fold(via="combine")` + `stop` (all at `now`),
-- freeze a minimal record (its value is entirely its folds — its own segment is empty), then resume the
-- live run. The pause/resume bracket keeps the log sequence clean and it never disturbs the open run.
-- Resolve rolls it up (via="combine", per-source segments) — so it's a real session: uploadable, shareable,
-- re-combinable. `prices` is best-effort (the combine has no items of its own). Returns the new sid.
function CtrlMT:Combine(fromsids, prices)
  if not fromsids or #fromsids == 0 then return nil end
  local st = store(self)
  local paused = false
  if st._open then self:Pause(); paused = true end
  local now = lib._now()
  local sid = Session._newSid(now)
  local who = (lib._identity and lib._identity().name) or nil
  self._handle:Append("markers", { k = "start", sid = sid, who = who, t = now })
  for _, fromsid in ipairs(fromsids) do
    self._handle:Append("markers", { k = "fold", sid = sid, fromsid = fromsid, via = "combine", t = now })
  end
  self._handle:Append("markers", { k = "stop", sid = sid, reason = "combine", t = now })
  freezeRecord(self, sid, prices or {},
    { sid = sid, builds = { addonBuild(self._handle) }, schema = st.version, character = lib.CharIndex() })
  if paused then self:Resume() end
  fire(self, "combine", sid)
  return sid
end

-- Numeric-segment CalVer compare (a <= b). Split on non-digits, compare each segment as a NUMBER —
-- "2026.07.18.10" > "2026.07.18.3" (10 > 3), which a plain string compare gets wrong.
local function verLE(a, b)
  local sa, sb = {}, {}
  for n in tostring(a or ""):gmatch("%d+") do sa[#sa + 1] = tonumber(n) end
  for n in tostring(b or ""):gmatch("%d+") do sb[#sb + 1] = tonumber(n) end
  for i = 1, math.max(#sa, #sb) do
    local x, y = sa[i] or 0, sb[i] or 0
    if x ~= y then return x < y end
  end
  return true   -- equal counts as <=
end

-- In-place drop every list entry whose .sid is in `doomed`; returns how many were removed.
local function dropSids(list, doomed)
  if not list then return 0 end
  local removed, w = 0, 0
  for r = 1, #list do
    local e = list[r]
    if e and e.sid and doomed[e.sid] then removed = removed + 1
    else w = w + 1; list[w] = e end
  end
  for i = #list, w + 1, -1 do list[i] = nil end
  return removed
end

-- Purge every FROZEN session whose CREATING build (builds[1]) is <= `version` (CalVer, numeric-segment),
-- along with that session's events + markers. The currently-OPEN session is NEVER purged (it's live). Use
-- to unload stale test data the server now rejects so Uplink stops re-pushing it. Returns
-- { sessions, events, markers } counts. Persists with the SV on the next write (/reload or logout).
function CtrlMT:PurgeThroughBuild(version)
  local st = store(self)
  local sessions = st.sessions or {}
  local openSid = st._open and st._open.sid
  local doomed, nS = {}, 0
  for sid, rec in pairs(sessions) do
    if sid ~= openSid then
      local b = rec.builds and rec.builds[1]
      if b and verLE(b, version) then doomed[sid] = true; nS = nS + 1 end
    end
  end
  for sid in pairs(doomed) do sessions[sid] = nil end
  local streams = st.streams or {}
  local nE = dropSids(streams.events, doomed)
  local nM = dropSids(streams.markers, doomed)
  return { sessions = nS, events = nE, markers = nM }
end

function CtrlMT:Sid()      return (store(self)._open or {}).sid end
function CtrlMT:IsOpen()   return store(self)._open ~= nil end
function CtrlMT:Current()  return store(self)._open end
function CtrlMT:Get(sid)   local s = store(self).sessions; return s and s[sid] end

-- Sideline/Restore: park the current open session so a fresh Begin doesn't clobber it, then bring it
-- back. Haul uses this for instance farming — pause + sideline the open-world run, Begin the instance
-- run, Close it, then Restore + resume the open-world run right where it left off. The parked session
-- stays OPEN (its pause span, laid by the addon, covers the detour); one level of parking (no nesting).
-- `_sidelined` persists on the SV so a /reload mid-instance keeps the parked run.
function CtrlMT:Sideline()
  local st = store(self)
  if st._open and not st._sidelined then
    st._sidelined, st._open = st._open, nil
  end
  return (st._sidelined or {}).sid
end

function CtrlMT:Restore()
  local st = store(self)
  if st._sidelined and not st._open then
    st._open, st._sidelined = st._sidelined, nil
    return st._open.sid
  end
  return nil
end

function CtrlMT:SidelinedSid() return (store(self)._sidelined or {}).sid end
function CtrlMT:IsSidelined()  return store(self)._sidelined ~= nil end

-- Live active seconds for the OPEN session (span-so-far minus pauses, an open pause counted up to now).
function CtrlMT:ActiveSeconds()
  local st = store(self); local open = st._open; if not open then return 0 end
  local now = lib._now()
  local timing = Session._deriveTiming(st.streams and st.streams.markers, open.sid)
  local paused = 0
  for _, p in ipairs(timing.pauses) do paused = paused + ((p.r or now) - p.p) end
  return now - (timing.startedAt or now) - paused
end

return Session
