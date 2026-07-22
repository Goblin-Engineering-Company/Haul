-- Replay.lua — reconstruct a session's aggregated "data layout" (the Data-tab snapshot view)
-- from a chronological event list (the log). PURE Lua: no WoW APIs, so it runs offline in luajit
-- for testing AND in-game for a real rebuild.
--
-- CANONICAL SCHEMA (2026-07-14): the exported stream (HaulData.streams.events) carries ~9 primary kinds +
-- markers with a CANONICAL field vocabulary (count/amount/val/name/src). ATTRIBUTION rides on the `src`
-- DESCRIPTOR `{ t, npcID, guid, node, name, mob, zone, title }` on the primary event — not as separate
-- mobloot/mobcash/xpkill/gatherloot events. One `loot` event feeds BOTH the flat item list AND the per-mob/
-- per-node breakdown; one `coin`/`xp` event feeds the total AND the breakdown by `src.t`. Totals stay
-- authoritative (net-delta on the primary event); attribution never re-adds to a total. This reader is
-- CANONICAL-ONLY: the exported stream AND the live session drop log (ns.session.log) share one field
-- vocabulary (count/amount/val/name/src), so no legacy short-name fallbacks remain.
--   loot   { id, name, link, count, val, q, src, ...(b/ps/from/v ride in extra) }  -- item into bags
--          (rebuilt DISPLAY item mirrors the stream: `src` = loot-source TYPE, `from` = acquire source)
--   coin   { amount, src, from }                        -- money delta (src.t=kill attributes to a mob; signed)
--   xp     { amount, src }                              -- experience (src.t=kill/gather/disc/quest/other subset)
--   mail   { amount, label, sender, subject, seq }      -- mail gold (own category, opt-in via include marker)
--   vendor { amount, vt }                               -- vendor txn (vt=sell/buy/repair; signed; never counted)
--   currency { cid, id, amount }   rep { f, fid, amount }   skill { id, amount, name, prof, lvl }   kill { id, name, guid }
--   markers: start/stop/pause/resume/fold/include/exclude (unchanged)
-- `looted` (corpses looted) is DERIVED from distinct corpse GUIDs seen in kill-attributed loot/coin events
-- (edge: a looted-but-empty corpse produces no event, so it reads as unlooted — acceptable per owner).
local ADDON, ns = ...
ns = ns or {}
local Replay = {}

-- classify an event into a kind string. New logs carry `k`; the per-session drop log carries `kind` for
-- money rows and a bare `id` for loot drops.
local function kindOf(e)
  if e.k then return e.k end
  if e.kind then return e.kind end
  if e.id then return "loot" end            -- bare drop = looted item
  return nil
end

-- bucket key keys off the ACQUIRE source (`from` = nil loot / mail / craft) so mail/craft copies of an
-- item bucket separately from normal loot. The `@`-suffix value is the acquire source, unchanged.
local function itemKey(id, from) return (from and from ~= "") and (tostring(id) .. "@" .. from) or id end

-- the only real acquisition sources an item carries; used to tell them apart from the always-on log's
-- store tag (e.src = "Haul"), which must NOT be read as an acquisition source.
local ACQ_SRC = { mail = true, craft = true, vendor = true }

-- Rebuild from an ordered event list. Returns a table mirroring the snapshot's reconstructable fields.
-- `opts.priceSource` (optional) labels the rebuild; per-item value comes from embedded `v`/`q` only.
function Replay.Rebuild(events, opts)
  opts = opts or {}
  local items, order = {}, {}
  local coin, itemCount = 0, 0
  local mailGoldLog, mailBySeq = {}, {}
  local rep = {}
  local currency = {}
  local professions = {}
  local xp, xpDiscovery, xpQuest, xpKill, xpGather, xpOther = 0, 0, 0, 0, 0, 0
  local xpZones, xpMobs, xpNodes = {}, {}, {}
  local xpStream, xpQuestStream, xpOtherStream = {}, {}, {}   -- detail for accordion children on saved sessions
  local kills, killCount, gather = {}, 0, {}
  local startT, stopT, character = nil, nil, nil
  local pauses = {}
  local allValued, anyItem = true, false
  local vendor = { sell = 0, buy = 0, repair = 0 }
  local excluded, psSeen = {}, {}

  -- attribution helpers: derive the per-mob / per-node breakdown from the SAME loot/coin/xp events.
  local function ensureKill(id, name)
    id = tonumber(id) or id   -- normalize npcID to number so string/number keys merge the same mob
    local kk = kills[id]
    if not kk then kk = { name = name, count = 0, xp = 0, cash = 0, loot = {}, looted = 0, _corpses = {} }; kills[id] = kk end
    if name and name ~= "" then kk.name = name end
    return kk
  end
  local function ensureGather(node)
    local g = gather[node]; if not g then g = { name = node, loot = {} }; gather[node] = g end
    return g
  end
  -- mark a corpse GUID looted for a kill (derives `looted` = distinct looted corpses).
  local function markCorpse(kk, guid)
    if not (kk and guid) then return end
    if not kk._corpses[guid] then kk._corpses[guid] = true; kk.looted = (kk.looted or 0) + 1 end
  end
  local function addAttrLoot(bucketLoot, link, n)
    local key = link and (link:match("item:(%-?%d+)") or link)
    if not key then return end
    local li = bucketLoot[key]; if not li then li = { link = link, count = 0 }; bucketLoot[key] = li end
    li.count = li.count + n
  end

  for _, e in ipairs(events or {}) do
    local k = kindOf(e)
    -- CANONICAL attribution descriptor is `src` — on BOTH the exported stream and the live session drop
    -- log (they share one vocabulary now). (The store tag "Haul" is no longer set as top-level src, so
    -- `e.src` on a non-loot kind is the attribution descriptor.)
    local ls = e.src                         -- attribution descriptor { t, npcID, guid, node, name, mob, zone, title } or nil
    local lt = ls and ls.t
    -- ACQUISITION source: prefer `from`; fall back to `src` ONLY when it's a real acquisition value.
    -- (In the always-on log e.src is the STORE tag "Haul" — never an acquisition source.)
    local from = e.from or (ACQ_SRC[e.src] and e.src) or nil
    if k == "loot" then
      if from == "vendor" then
        -- purchased item: log-only, never part of the session aggregate (matches AddLoot early-return)
      else
        anyItem = true
        local n = e.count or 1
        local s = (from ~= "" and from) or nil
        local key = itemKey(e.id, s)
        local it = items[key]
        if not it then
          it = { id = e.id, link = e.link, count = 0, from = s, key = key, seq = #order + 1 }
          items[key] = it; order[#order + 1] = key
        end
        if lt and not it.src then it.src = lt end   -- loot-source TYPE string (fish/kill/gather/container/…)
        it.count = it.count + n
        itemCount = itemCount + n
        -- CANONICAL: `val` is the TOTAL stack value for this loot line. Accumulate the line total; derive
        -- the unit value for display from the total ÷ count.
        local lineTotal = e.val
        if lineTotal then
          it.total = (it.total or 0) + lineTotal
          it.unit = (n > 0 and (lineTotal / n)) or it.unit
        else allValued = false end
        if e.q then it.quality = e.q end
        if e.b then it.b = true end
        if e.ps then psSeen[e.ps] = (psSeen[e.ps] or 0) + 1 end
        -- attribution: the SAME event feeds the kill / gather breakdown
        if (lt == "kill" or lt == "pickpocket") and ls.npcID then
          local kk = ensureKill(ls.npcID, ls.name); addAttrLoot(kk.loot, e.link, n); markCorpse(kk, ls.guid)
        elseif (lt == "gather" or lt == "herb" or lt == "mining") and ls.node then
          addAttrLoot(ensureGather(ls.node).loot, e.link, n)
        end
      end
    elseif k == "coin" then
      -- EVERY coin event counts toward the total (each gold gain is now ONE coin event). `ls` just adds the
      -- breakdown: ls.t=kill also attributes to the mob's cash — like a loot event feeds both the flat list
      -- and the mob breakdown. (The old double-event model — a total + a separate kill-attribution — is gone.)
      local camt = e.amount or 0   -- CANONICAL amount (signed)
      coin = coin + camt
      if lt == "kill" and ls.npcID then
        local kk = ensureKill(ls.npcID, ls.name); kk.cash = (kk.cash or 0) + camt; markCorpse(kk, ls.guid)
      end
    elseif k == "mail" then
      local amt = e.amount or 0
      local entry = { amount = amt, label = e.label, sender = e.sender, subject = e.subject, seq = e.seq }
      mailGoldLog[#mailGoldLog + 1] = entry
      if e.seq then mailBySeq[e.seq] = entry end
    elseif k == "rep" then
      if e.f then rep[e.f] = (rep[e.f] or 0) + (e.amount or 0) end
    elseif k == "currency" then
      local cid = e.cid or e.id   -- CANONICAL: currency keyed by cid (id kept as fallback)
      local camt = e.amount or 0
      if cid and camt > 0 then currency[cid] = (currency[cid] or 0) + camt end   -- gains only (spends are log-only)
    elseif k == "skill" then
      local pid = e.pid or e.id   -- s.log uses pid; the exported log uses id
      local samt = e.amount or 0
      if pid and samt > 0 then professions[pid] = (professions[pid] or 0) + samt end   -- skill-ups only go up
    elseif k == "xp" then
      -- collapsed/merged model: EVERY xp event is an attributed gain (kill/gather/disc/quest/other), and the
      -- capture-side reconcile guarantees they SUM to the true PLAYER_XP total (rested/unattributed remainder is
      -- booked as an `other` event). So each counts toward the total AND its breakdown. (A no-`ls` event, only
      -- from legacy/edge data, falls through to `other`.)
      local a = e.amount or 0
      xp = xp + a
      if a > 0 then xpStream[#xpStream + 1] = { amount = a, t = e.t } end
      if lt == "kill" then
        xpKill = xpKill + a
        local mob = ls and (ls.name or ls.mob)
        if mob and a > 0 then local m = xpMobs[mob]; if not m then m = { xp = 0, kills = 0 }; xpMobs[mob] = m end; m.xp = m.xp + a; m.kills = m.kills + 1 end
        if ls and ls.npcID and a > 0 then local kk = ensureKill(ls.npcID, ls.name or mob); kk.xp = (kk.xp or 0) + a end
      elseif lt == "gather" or lt == "herb" or lt == "mining" then
        xpGather = xpGather + a
        local node = ls and ls.node
        if node and a > 0 then local nn = xpNodes[node]; if not nn then nn = { xp = 0, count = 0 }; xpNodes[node] = nn end; nn.xp = nn.xp + a; nn.count = nn.count + 1 end
      elseif lt == "disc" then
        xpDiscovery = xpDiscovery + a
        local zone = ls and ls.zone
        if zone then xpZones[zone] = (xpZones[zone] or 0) + a end
      elseif lt == "quest" then
        xpQuest = xpQuest + a
        if a > 0 then xpQuestStream[#xpQuestStream + 1] = { amount = a, title = ls and ls.title, t = e.t } end
      else
        xpOther = xpOther + a
        if a > 0 then xpOtherStream[#xpOtherStream + 1] = { amount = a, t = e.t } end
      end
    elseif k == "kill" then
      local id = tonumber(e.id) or e.id
      if id then local kk = ensureKill(id, e.name); kk.count = kk.count + 1; killCount = killCount + 1 end
    elseif k == "vendor" then
      local vt = e.vt or lt   -- subtype: sell / buy / repair
      -- CANONICAL amount is signed (buy/repair negative from the exported stream); the buckets track
      -- MAGNITUDE (the display/hasContent gate wants positive totals), so take abs.
      local vamt = math.abs(e.amount or 0)
      if vt == "sell" then vendor.sell = vendor.sell + vamt
      elseif vt == "buy" then vendor.buy = vendor.buy + vamt
      elseif vt == "repair" then vendor.repair = vendor.repair + vamt end
    elseif k == "start" then startT = startT or e.t; if e.who then character = e.who end
    elseif k == "stop" then stopT = e.t
    elseif k == "pause" then pauses[#pauses + 1] = { p = e.t }
    elseif k == "resume" then local last = pauses[#pauses]; if last and not last.r then last.r = e.t end
    elseif k == "include" then
      -- append-only one-off include marker: latest wins
      if e.cat == "mailgold" and e.ref and mailBySeq[e.ref] then
        mailBySeq[e.ref].keep = e.on and true or nil
      elseif e.cat == "item" and e.ref and items[e.ref] then
        items[e.ref].keep = e.on and true or nil
      end
    elseif k == "exclude" then
      if e.ref ~= nil then excluded[e.ref] = e.on and true or nil end   -- per-item-ID, latest wins
    end
  end

  for _, kk in pairs(kills) do kk._corpses = nil end   -- strip the internal corpse-dedup set from the output

  local itemList = {}
  for _, key in ipairs(order) do itemList[#itemList + 1] = items[key] end

  -- enrich each item to the snapshot's shape (name from link, gray/bound category, excluded flag)
  -- and tally notable / gross / counted. Mail/craft count only when individually kept; loot counts
  -- unless on the excluded list. (Mirrors ComputeStats.)
  local thr = opts.notableQuality or 2
  local notable, grossItem, countedItem = 0, 0, 0
  for _, it in ipairs(itemList) do
    it.name = (it.link and it.link:match("%[(.-)%]")) or it.name
    if it.quality == 0 then it.cat = "gray" elseif it.b then it.cat = "bound" end
    -- NOTE: value is NOT recomputed here — Replay must be a PURE function of the captured events so the
    -- server's reconstruction (no vendor/AH pricing available) is byte-for-byte identical to the client's.
    -- Correctness lives at CAPTURE (AddLoot freezes the right value; gray/bound forced to vendor there).
    it.excluded = excluded[it.id] and true or false
    if it.quality and it.quality >= thr then notable = notable + it.count end
    -- mail-collected loot is informational (Haul's Mail category), NEVER part of the haul value — out of
    -- BOTH gross and counted. It stays in itemList so the Mail category can still show it. Matches Resolve
    -- (MONETARY/reduceSegment exclude mail), so the live window == the reconstruct == the server.
    if it.from ~= "mail" then
      grossItem = grossItem + (it.total or 0)
      local inHaul
      if it.from == "craft" then inHaul = it.keep and true or false
      else inHaul = not it.excluded end
      if inHaul then countedItem = countedItem + (it.total or 0) end
    end
    it.b = nil   -- internal only, not a snapshot field
  end

  -- Lifecycle markers (start/stop/pause/resume + `who`) now live in a SEPARATE stream (session refactor),
  -- not inline in `events` — so timing + character come from opts.markers when provided. The in-events
  -- branches above stay for pre-refactor logs. opts.markers should be THIS session's markers (sid-filtered).
  for _, m in ipairs(opts.markers or {}) do
    local mk = m.k
    if mk == "start" then startT = startT or m.t; if m.who then character = m.who end
    elseif mk == "stop" then stopT = m.t
    elseif mk == "pause" then pauses[#pauses + 1] = { p = m.t }
    elseif mk == "resume" then local last = pauses[#pauses]; if last and not last.r then last.r = m.t end
    end
  end

  local durationSec
  if startT and stopT then
    durationSec = stopT - startT
    for _, p in ipairs(pauses) do if p.p and p.r then durationSec = durationSec - (p.r - p.p) end end
    if durationSec < 0 then durationSec = nil end
  end

  -- mail gold is informational (Haul's Mail category) — NO longer folded into coin/counted. mailGoldLog is
  -- still returned for the Mail category display. Matches Resolve (MONETARY excludes mail), so the value is
  -- looted coin only. (vendor sell/buy/repair were never in Replay's coin — they ride the `vendor` buckets.)
  local coinTotal = coin

  -- Coin ALWAYS counts — it's a fact on the event, so a coin-only run (quest gold, vendor proceeds, mail)
  -- must still total its coin. Item value adds in on top; the `valued` flag (below) says whether every item
  -- was priced (item values aren't embedded in the log anymore, so an uncached item can't be valued here and
  -- the item portion is understated — but the coin is never lost). This was the "coin not added to haul" bug.
  local countedValue = countedItem + coinTotal
  local grossValue = grossItem + coinTotal
  local goldPerHour
  if durationSec and durationSec > 0 then goldPerHour = math.floor(countedValue / (durationSec / 3600)) end

  -- dominant price source seen across the items (the snapshot stores a single label)
  local priceSource, psMax = opts.priceSource, -1
  for label, n in pairs(psSeen) do if n > psMax then priceSource, psMax = label, n end end

  return {
    items = itemList, itemCount = itemCount, coin = coinTotal, notable = notable,
    mailGoldLog = mailGoldLog, rep = rep, currency = currency, professions = professions,
    xp = xp, xpDiscovery = xpDiscovery, xpQuest = xpQuest, xpKill = xpKill, xpGather = xpGather, xpOther = xpOther,
    xpZones = xpZones, xpMobs = xpMobs, xpNodes = xpNodes,
    xpStream = xpStream, xpQuestStream = xpQuestStream, xpOtherStream = xpOtherStream,
    kills = kills, killCount = killCount, gather = gather, vendor = vendor,
    startedAt = startT, durationSec = durationSec, character = character,
    valued = (not anyItem) or allValued,   -- true if no items to price (coin-only) OR every item was priced
    countedValue = countedValue, grossValue = grossValue, goldPerHour = goldPerHour,
    priceSource = priceSource,
  }
end

-- Mail-gold reconciliation (pure, so it's unit-tested offline). The per-mail hooks record + accumulate
-- `pending` for each labeled mail; a PLAYER_MONEY `delta` should CONSUME that pending, not reset it.
-- Returns (newPending, leftover) where leftover is gold beyond what the hooks already saw (recorded as
-- an unlabeled entry). Resetting pending to 0 on every delta was the duplicate bug: a second per-mail
-- delta for already-labeled gold then looked like fresh money and produced a phantom "Mail gold" line.
function Replay.ReconcileMailDelta(pending, delta)
  pending = pending or 0
  if delta <= pending then return pending - delta, 0 end
  return 0, delta - pending
end

ns.Replay = Replay
return Replay
