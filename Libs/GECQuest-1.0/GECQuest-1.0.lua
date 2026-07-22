-- GECQuest-1.0 — the shared QUEST domain library for GEC addons.
--
-- One job: whenever a quest is touched, collect everything the client will tell us and correlate it, keyed by
-- the numeric quest ID. WoW hands quest data out across several events and a live NPC unit; this library is the
-- single place that stitches them together so every consumer gets an ID-anchored record (never a bare title).
--
-- DOCTRINE — capture EVERYTHING, on dialog OPEN. Two principles this library embodies (true of every GEC domain
-- library): (1) the library collects the MAXIMUM the API exposes about its domain; a consumer (Haul, etc.) reads
-- only the slice it wants. Capturing it all lets us later bind this real in-game data against external API/DB2
-- data and validate it. (2) capture the moment a dialog OPENS, before any accept/turn-in — so just *opening* a
-- giver's window (then closing it) harvests the quest, giver, location, "go here" text, and reward preview.
--
-- WHAT IT COLLECTS
--   On the OFFER dialog (QUEST_DETAIL) — fires GECQUEST_OFFERED(info), no accept required:
--     id (GetQuestID), title, level, faction; GIVER npc (name + npcID from GUID); location (uiMapID+x/y+zone);
--     offer + objective text; tag/type, daily/weekly, suggested group; and the full reward PREVIEW —
--     money, xp, honor, artifact power, guaranteed + choice items (ID-anchored), currencies, reward spells.
--   On the TURN-IN dialogs — captured AND fired/streamed on open (GECQUEST_TURNIN_OPENED), no completion required:
--     QUEST_PROGRESS: ENDER npc, location, progress text, required turn-in items + money.
--     QUEST_COMPLETE: ENDER npc, location, completion text, and the full reward preview again.
--   On QUEST_GREETING (multi-quest gossip giver): the interacting NPC (no single quest id is exposed).
--   On QUEST_ACCEPTED(questID): confirms the accept (data already captured at offer), stamps faction; fires
--     GECQUEST_ACCEPTED(info).
--   On QUEST_POI_UPDATE: for any in-log quest — the DESTINATION waypoint (the "go here" pin: uiMapID + x/y + zone
--     + text) AND the objective POI pins ("blobs") the client currently draws. Only in-log quests have these (a
--     viewed offer does not); objectives revealed one-at-a-time appear only as reached, so a fresh quest often
--     shows just the first pin. We keep the richest pin set seen over the quest's life.
--   On QUEST_TURNED_IN(questID, xp, money): stamps the ACTUAL XP + money; fires GECQUEST_TURNED_IN(info).
--   On QUEST_REMOVED(questID): fires GECQUEST_REMOVED(id) (abandoned or completed-and-cleared).
--
-- WHAT IT EXPOSES
--   lib.RegisterCallback(token, "GECQUEST_OFFERED"|"GECQUEST_ACCEPTED"|"GECQUEST_TURNIN_OPENED"|
--                               "GECQUEST_TURNED_IN"|"GECQUEST_REMOVED", fn)
--   lib.Get(questID)   -> the correlated record we know (accept + turn-in merged), or nil
--   lib.Current()      -> the last quest NPC we saw interacting (id, name, t)
--
-- PERSISTENCE: every record is upserted into the GECStore registry as type "quest" (NoteNamed) when GECStore is
-- present, so it survives account-wide and rides the normal sync up to the server — the self-filling quest atlas.
-- The library keeps no SavedVariable of its own (libraries can't own one); GECStore owns the durable store.
--
-- NO EXTERNAL REFERENCE: pure implementation against the standard WoW quest API; no shipped code/comment/string
-- names any other addon.
--
-- EMBED-SYNC: copied verbatim into each addon's Libs/ (Haul/Libs, SBF/Libs, _libs). A lib edit must propagate to
-- ALL copies — bump MINOR so the newest copy wins via LibStub until the others sync.
local MAJOR, MINOR = "GECQuest-1.0", 13  -- 13: +questline/campaign, structured objectives, quest type/elite, timed/repeatable/warband/failed, reward title; TomTom coords (space, no comma). 12: POI blobs
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end
GECQuest = lib   -- global handle, so console /run GECQuest.Dump() works without a GetLibrary dance

-- CallbackHandler gives consumers lib.RegisterCallback / lib.UnregisterCallback and us lib.callbacks:Fire.
lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)

-- Persistent state (kept across a MINOR upgrade so an in-flight reload keeps its correlation table).
lib._quests = lib._quests or {}   -- [questID] = correlated record (accept + turn-in merged)
lib._npc    = lib._npc    or nil   -- { id, name, t = GetTime() } — the last quest-dialog NPC we saw
lib.NPC_WINDOW = lib.NPC_WINDOW or 8   -- seconds a seen quest-NPC stays valid for accept/turn-in attribution
lib._streamSig = lib._streamSig or {}   -- [heading:id] = last streamed body signature; suppresses identical reprints
lib.WRAP_WIDTH = lib.WRAP_WIDTH or 74   -- chars per line when word-wrapping quest offer / objective text (configurable)

local function store()
  return LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECStore-1.0", true) or nil
end

-- ---- helpers ---------------------------------------------------------------

-- The npc unit that opened a quest dialog IS the giver/ender. Read its name + numeric id (from the GUID: the
-- 6th "-"-delimited field on Creature / Vehicle / GameObject GUIDs). Returns nil when no unit is present.
local function unitNpc(unit)
  if not (UnitExists and UnitExists(unit)) then return nil end
  local name = UnitName and UnitName(unit)
  local id
  local guid = UnitGUID and UnitGUID(unit)
  if guid and strsplit then
    local kind, _, _, _, _, npcid = strsplit("-", guid)
    if npcid and (kind == "Creature" or kind == "Vehicle" or kind == "GameObject") then id = tonumber(npcid) end
  end
  if not name and not id then return nil end
  return { id = id, name = name }
end

-- The recent quest-dialog NPC, if still within the attribution window (else nil — don't guess a stale giver).
local function recentNpc()
  local n = lib._npc
  if n and (not GetTime or (GetTime() - (n.t or 0) <= lib.NPC_WINDOW)) then return n end
  return nil
end

-- Player's current spot: uiMapID + x/y (0-100, 1 decimal) + zone name. nil when the map isn't readable
-- (instances / loading). This is the "where you accepted / turned in" anchor.
local function here()
  local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if not m then return nil end
  local x, y
  local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(m, "player")
  if pos and pos.GetXY then x, y = pos:GetXY() end
  local info = C_Map.GetMapInfo and C_Map.GetMapInfo(m)
  local round = function(v) return v and math.floor(v * 1000 + 0.5) / 10 or nil end
  return { map = m, x = round(x), y = round(y), zone = info and info.name }
end

local function titleFor(id)
  return id and C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id) or nil
end
local function levelFor(id)
  return id and C_QuestLog and C_QuestLog.GetQuestDifficultyLevel and C_QuestLog.GetQuestDifficultyLevel(id) or nil
end

-- ---- rich capture: read EVERYTHING the open quest dialog exposes ------------
-- Library doctrine: the domain library collects the MAXIMUM the API offers about a quest; consumers (Haul, etc.)
-- read only the slice they want. Capturing everything lets us later bind this real in-game data against external
-- API/DB2 data and validate it. Every call below is defensively guarded (pcall / `and`-chains) so a missing or
-- renamed API on any client just yields nil — the library never errors on data it can't get.

-- A non-empty trimmed string from a getter, else nil (guarded — some text getters error off-dialog).
local function txt(fn)
  if type(fn) ~= "function" then return nil end
  local ok, s = pcall(fn)
  s = ok and s or nil
  return (type(s) == "string" and s ~= "") and s or nil
end

-- A reward/requirement item list off the OPEN dialog. kind="reward"|"choice"|"required"; countFn = its counter.
-- Each entry is ID-anchored { id, name, count, quality } (itemID from GetQuestItemInfo, else parsed from the link).
local function itemsOf(kind, countFn)
  if not (GetQuestItemInfo and type(countFn) == "function") then return nil end
  local ok, n = pcall(countFn); if not ok then return nil end
  n = tonumber(n) or 0; if n <= 0 then return nil end
  local out = {}
  for i = 1, n do
    local name, _, count, quality, _, itemID = GetQuestItemInfo(kind, i)
    if not itemID and GetQuestItemLink then
      local link = GetQuestItemLink(kind, i)
      if link then itemID = tonumber(link:match("item:(%d+)")) end
    end
    if name or itemID then out[#out + 1] = { id = itemID, name = name, count = count, quality = quality } end
  end
  return out[1] and out or nil
end

-- Reward spells for a quest id — ID-first via C_QuestInfoSystem (doesn't need the dialog open). e.g. a quest that
-- teaches you a spell/recipe. { id = spellID, name }.
local function rewardSpellsOf(id)
  local sys = C_QuestInfoSystem
  if not (sys and sys.GetQuestRewardSpells) then return nil end
  local ok, ids = pcall(sys.GetQuestRewardSpells, id)
  if not ok or not (ids and ids[1]) then return nil end
  local out = {}
  for _, sid in ipairs(ids) do
    local info = sys.GetQuestRewardSpellInfo and sys.GetQuestRewardSpellInfo(id, sid)
    out[#out + 1] = { id = sid, name = info and info.name }
  end
  return out[1] and out or nil
end

-- Reward currencies off the OPEN dialog. { id = currencyID, name, amount, quality }.
local function rewardCurrencies()
  local n = GetNumRewardCurrencies and GetNumRewardCurrencies() or 0
  if not n or n <= 0 then return nil end
  local out = {}
  for i = 1, n do
    local name, amount, quality, _
    if GetQuestCurrencyInfo then name, _, amount, quality = GetQuestCurrencyInfo("reward", i) end
    local cid = GetQuestCurrencyID and GetQuestCurrencyID("reward", i)
    if name or cid then out[#out + 1] = { id = cid, name = name, amount = amount, quality = quality } end
  end
  return out[1] and out or nil
end

-- The reward preview shared by the offer (QUEST_DETAIL) and completion (QUEST_COMPLETE) dialogs: money, xp,
-- honor, artifact power, guaranteed + choice items, currencies, and reward spells. Zeros are dropped.
local function rewardPreview(id)
  local f = {}
  f.money        = GetRewardMoney and GetRewardMoney() or nil
  f.xp           = GetRewardXP and GetRewardXP() or nil
  f.honor        = GetRewardHonor and GetRewardHonor() or nil
  f.artifactXP   = GetRewardArtifactXP and GetRewardArtifactXP() or nil
  f.rewardItems  = itemsOf("reward", GetNumQuestRewards)
  f.choiceItems  = itemsOf("choice", GetNumQuestChoices)
  f.currencies   = rewardCurrencies()
  f.rewardSpells = rewardSpellsOf(id)
  local rt = (GetRewardTitle and GetRewardTitle()) or (GetQuestLogRewardTitle and GetQuestLogRewardTitle(id))
  if type(rt) == "string" and rt ~= "" then f.rewardTitle = rt end
  for _, k in ipairs({ "money", "xp", "honor", "artifactXP" }) do if f[k] == 0 then f[k] = nil end end
  return f
end

-- Quest metadata keyed by id (not tied to an open dialog): tag/type, world-quest flag, quest type, elite.
local function questMeta(id)
  local f = {}
  local ql = C_QuestLog
  local tag = ql and ql.GetQuestTagInfo and ql.GetQuestTagInfo(id)
  if tag then
    f.tagId = tag.tagID; f.tagName = tag.tagName
    if tag.isElite then f.elite = 1 end
  end
  if ql and ql.IsWorldQuest and ql.IsWorldQuest(id) then f.worldQuest = 1 end
  local qt = ql and ql.GetQuestType and ql.GetQuestType(id)
  if qt and qt > 0 then f.questType = qt end
  return f
end

-- Questline + campaign the quest belongs to (the "chain" / storyline it's part of) — ID-anchored. Best-effort:
-- GetQuestLineInfo needs a map and the quest to be known; campaign is 0 when the quest isn't in one.
local function questChain(id)
  local f = {}
  local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local qln = C_QuestLine
  if qln and qln.GetQuestLineInfo and map then
    local ok, info = pcall(qln.GetQuestLineInfo, id, map)
    if ok and info then f.questLineId = info.questLineID; f.questLineName = info.questLineName end
  end
  local ci = C_CampaignInfo
  if ci and ci.GetCampaignID then
    local ok, cid = pcall(ci.GetCampaignID, id)
    if ok and cid and cid > 0 then
      f.campaignId = cid
      local cinfo = ci.GetCampaignInfo and ci.GetCampaignInfo(cid)
      f.campaignName = cinfo and cinfo.name
    end
  end
  return f
end

-- Structured objectives (in-log): each { text, type, need = numRequired }. The prose objectiveText is the summary;
-- this is the machine-readable per-step breakdown (kill 8 X, collect 5 Y). Empty until the quest is in the log.
local function questObjectives(id)
  local ql = C_QuestLog
  if not (ql and ql.GetQuestObjectives) then return nil end
  local ok, list = pcall(ql.GetQuestObjectives, id)
  if not ok or type(list) ~= "table" or not list[1] then return nil end
  local out = {}
  for _, o in ipairs(list) do
    out[#out + 1] = { text = (type(o.text) == "string" and o.text ~= "") and o.text or nil, type = o.type, need = o.numRequired }
  end
  return out[1] and out or nil
end

-- Time limit in seconds for a timed quest (in-log), else nil.
local function timeLimitOf(id)
  local ql = C_QuestLog
  if not (ql and ql.GetTimeAllowed) then return nil end
  local ok, total = pcall(ql.GetTimeAllowed, id)
  return (ok and total and total > 0) and total or nil
end

-- The quest's destination MARKER — the waypoint the game draws on world map / minimap / world for an IN-LOG
-- quest (the "go here" pin). Returns { map, x, y (0-100), zone, text } or nil. Only in-log quests have one; a
-- merely-viewed offer does not (the client computes it from log data). Also nil until POI data loads post-accept.
local function destWaypoint(id)
  local ql = C_QuestLog
  if not (ql and ql.GetNextWaypoint) then return nil end
  local map, x, y = ql.GetNextWaypoint(id)
  if not map then return nil end
  local round = function(v) return v and math.floor(v * 1000 + 0.5) / 10 or nil end
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
  local text = ql.GetNextWaypointText and ql.GetNextWaypointText(id)
  return { map = map, x = round(x), y = round(y), zone = info and info.name,
           text = (type(text) == "string" and text ~= "") and text or nil }
end

-- All objective POI pins ("blobs") the client currently knows for an in-log quest, gathered from the map POI
-- data across candidate maps (the player's current zone + the dest-waypoint map). Each { map, x, y (0-100), zone }.
-- May be one (a single objective area) or several (distinct objective pins). Deduped. nil if none / not in log.
-- CAVEAT: the client only knows the pins it would currently draw — objectives revealed one-at-a-time as you
-- progress appear only once reached, so a fresh quest often exposes just the first. Simultaneous objectives all show.
local function questPois(id)
  local ql = C_QuestLog
  if not (ql and ql.GetQuestsOnMap) then return nil end
  local maps, seenMap = {}, {}
  local cur = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if cur then maps[#maps + 1] = cur; seenMap[cur] = true end
  local rec = lib._quests[id]
  local dmap = rec and rec.dest and rec.dest.map
  if dmap and not seenMap[dmap] then maps[#maps + 1] = dmap end
  local round = function(v) return v and math.floor(v * 1000 + 0.5) / 10 or nil end
  local out, seen = {}, {}
  for _, m in ipairs(maps) do
    local ok, list = pcall(ql.GetQuestsOnMap, m)
    if ok and type(list) == "table" then
      local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
      for _, e in ipairs(list) do
        if e.questID == id and e.x and e.y then
          local x, y = round(e.x), round(e.y)
          local key = m .. ":" .. tostring(x) .. ":" .. tostring(y)
          if not seen[key] then
            seen[key] = true
            out[#out + 1] = { map = m, x = x, y = y, zone = info and info.name }
          end
        end
      end
    end
  end
  return out[1] and out or nil
end

-- Push the correlated record into the GECStore registry (type "quest") so it persists account-wide + uploads.
-- Attrs are stored verbatim as row columns — scalars flat, lists as nested arrays (reward/choice/required items,
-- reward spells, currencies). nils are dropped by NoteNamed. Only called once we have a title (the display name).
local function persist(r)
  local S = store()
  if not (S and S.NoteNamed and r and r.id and r.title) then return end
  S.NoteNamed("quest", r.id, r.title, {
    level = r.level, faction = r.faction, daily = r.daily, weekly = r.weekly,
    offered = r.offered, accepted = r.accepted, autoAccept = r.autoAccept,   -- provenance: viewed vs taken vs auto
    tagId = r.tagId, tagName = r.tagName, worldQuest = r.worldQuest, suggestedGroup = r.suggestedGroup,
    questType = r.questType, elite = r.elite, repeatable = r.repeatable, accountQuest = r.accountQuest,
    failed = r.failed, timeLimit = r.timeLimit,
    questLineId = r.questLineId, questLineName = r.questLineName, campaignId = r.campaignId, campaignName = r.campaignName,
    objectives = r.objectives, rewardTitle = r.rewardTitle,
    giverId = r.giver and r.giver.id, giverName = r.giver and r.giver.name,
    enderId = r.ender and r.ender.id, enderName = r.ender and r.ender.name,
    acceptMap = r.acceptAt and r.acceptAt.map, acceptX = r.acceptAt and r.acceptAt.x, acceptY = r.acceptAt and r.acceptAt.y,
    acceptZone = r.acceptAt and r.acceptAt.zone,
    turninMap = r.turninAt and r.turninAt.map, turninX = r.turninAt and r.turninAt.x, turninY = r.turninAt and r.turninAt.y,
    turninZone = r.turninAt and r.turninAt.zone,
    destMap = r.dest and r.dest.map, destX = r.dest and r.dest.x, destY = r.dest and r.dest.y,
    destZone = r.dest and r.dest.zone, destText = r.dest and r.dest.text,
    pois = r.pois,   -- objective POI pins (nested array of {map,x,y,zone})
    xp = r.xp, money = r.money, honor = r.honor, artifactXP = r.artifactXP, moneyToGet = r.moneyToGet,
    offerText = r.offerText, objectiveText = r.objectiveText, progressText = r.progressText, completeText = r.completeText,
    rewardItems = r.rewardItems, choiceItems = r.choiceItems, requiredItems = r.requiredItems,
    rewardSpells = r.rewardSpells, currencies = r.currencies,
  })
end

-- Merge new fields into the correlated record for a quest id (create on first touch), then persist + return it.
local function record(id, fields)
  local r = lib._quests[id]
  if not r then r = { id = id }; lib._quests[id] = r end
  for k, v in pairs(fields) do if v ~= nil then r[k] = v end end
  r.title = r.title or titleFor(id)
  if r.level == nil then r.level = levelFor(id) end
  persist(r)
  return r
end

-- Rebuild the in-memory record shape from a flat GECStore registry row (the inverse of persist()). Nested lists
-- (reward/choice/required items, spells, currencies) were stored verbatim, so they come back as-is.
local function fromRow(row)
  local r = {
    id = tonumber(row.id or row.key), title = row.name,
    level = row.level, faction = row.faction, daily = row.daily, weekly = row.weekly,
    offered = row.offered, accepted = row.accepted, autoAccept = row.autoAccept,
    tagId = row.tagId, tagName = row.tagName, worldQuest = row.worldQuest, suggestedGroup = row.suggestedGroup,
    questType = row.questType, elite = row.elite, repeatable = row.repeatable, accountQuest = row.accountQuest,
    failed = row.failed, timeLimit = row.timeLimit,
    questLineId = row.questLineId, questLineName = row.questLineName, campaignId = row.campaignId, campaignName = row.campaignName,
    objectives = row.objectives, rewardTitle = row.rewardTitle,
    xp = row.xp, money = row.money, honor = row.honor, artifactXP = row.artifactXP, moneyToGet = row.moneyToGet,
    offerText = row.offerText, objectiveText = row.objectiveText, progressText = row.progressText, completeText = row.completeText,
    rewardItems = row.rewardItems, choiceItems = row.choiceItems, requiredItems = row.requiredItems,
    rewardSpells = row.rewardSpells, currencies = row.currencies,
  }
  if row.giverId or row.giverName then r.giver = { id = row.giverId, name = row.giverName } end
  if row.enderId or row.enderName then r.ender = { id = row.enderId, name = row.enderName } end
  if row.acceptMap then r.acceptAt = { map = row.acceptMap, x = row.acceptX, y = row.acceptY, zone = row.acceptZone } end
  if row.turninMap then r.turninAt = { map = row.turninMap, x = row.turninX, y = row.turninY, zone = row.turninZone } end
  if row.destMap then r.dest = { map = row.destMap, x = row.destX, y = row.destY, zone = row.destZone, text = row.destText } end
  r.pois = row.pois
  return r
end

-- Seed the session table from the persisted GECStore "quest" registry so a /reload or relog keeps the whole
-- atlas visible (the in-memory table is torn down each reload; the registry survives in GECStoreDB). Runs once,
-- lazily, as soon as GECStore's DB is available; never clobbers a live session record.
local function hydrate()
  if lib._hydrated then return end
  local S = store()
  local db = S and S.EnsureDB and S.EnsureDB()
  local reg = db and db.registry and db.registry.quest
  if not reg then return end   -- GECStore/its SavedVariable not ready yet; retry on the next call
  lib._hydrated = true
  for _, row in ipairs(reg.items or {}) do
    local id = tonumber(row.id or row.key)
    if id and not lib._quests[id] then lib._quests[id] = fromRow(row) end
  end
end

-- When live-streaming is on, push a titled, formatted block to the GEC-Console Feed page. Dedup: skip a reprint
-- when this quest+phase's rendered block is byte-identical to the last one we streamed (re-viewing / re-accepting
-- an already-known quest is quiet), but a block that gained new info (offer→turn-in, new rewards) still streams.
local function streamPush(heading, r)
  if not (lib._stream and GECConsole and GECConsole.Feed) then return end
  local lines = lib.Format(r)
  local sig = table.concat(lines, "\n")
  local key = heading .. ":" .. tostring(r and r.id)
  if lib._streamSig[key] == sig then return end
  lib._streamSig[key] = sig
  GECConsole.Feed("|cffe8c679" .. heading .. "|r")
  for _, line in ipairs(lines) do GECConsole.Feed(line) end
end

-- ---- event handling --------------------------------------------------------

local f = lib._frame or CreateFrame("Frame")
lib._frame = f
f:UnregisterAllEvents()
f:RegisterEvent("PLAYER_LOGIN")      -- seed the session table from the persisted registry (survives reloads)
f:RegisterEvent("QUEST_DETAIL")      -- offer dialog
f:RegisterEvent("QUEST_PROGRESS")    -- turn-in requirements dialog
f:RegisterEvent("QUEST_COMPLETE")    -- reward dialog
f:RegisterEvent("QUEST_GREETING")    -- multi-quest gossip giver
f:RegisterEvent("QUEST_ACCEPTED")
f:RegisterEvent("QUEST_TURNED_IN")
f:RegisterEvent("QUEST_REMOVED")
f:RegisterEvent("QUEST_POI_UPDATE")  -- destination-waypoint data loaded; backfill dest markers for in-log quests

-- The quest id the currently-open offer/turn-in dialog is about (GetQuestID is valid during those dialogs; it
-- returns 0 at a multi-quest greeting and between dialogs). nil when there's no single quest in focus.
local function dialogId()
  local id = GetQuestID and GetQuestID()
  id = tonumber(id)
  return (id and id > 0) and id or nil
end

f:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "PLAYER_LOGIN" then
    hydrate()

  elseif event == "QUEST_DETAIL" then
    -- Offer dialog opened. Note the giver, then harvest EVERYTHING the offer exposes NOW (no accept needed):
    -- id, title, level, faction, giver, location, offer + objective text, tag/frequency/group, and the full
    -- reward preview (money/xp/honor/items/choices/currencies/spells). This is what makes "open→look→close"
    -- fully populate the atlas — invaluable when you can't or won't accept the quest.
    local n = unitNpc("npc")
    if n then n.t = GetTime and GetTime() or 0; lib._npc = n end
    local id = dialogId()
    if id then
      local fields = {
        offered = 1,   -- provenance: a player at least SAW this offer (vs. actually accepting it)
        title = txt(GetTitleText),   -- the offered quest's title (GetTitleForQuestID is nil for a not-in-log quest)
        giver = n or recentNpc(), acceptAt = here(),
        faction = UnitFactionGroup and UnitFactionGroup("player"),
        offerText = txt(GetQuestText), objectiveText = txt(GetObjectiveText),
        -- auto-accept quests (escorts / area-trigger / phased starts) are accepted by the game the instant this
        -- dialog opens — there's no Accept button; QUEST_ACCEPTED fires on its own. Record that so it's not a mystery.
        autoAccept = (QuestGetAutoAccept and QuestGetAutoAccept()) and 1 or nil,
      }
      for k, v in pairs(rewardPreview(id)) do fields[k] = v end
      for k, v in pairs(questMeta(id)) do fields[k] = v end
      for k, v in pairs(questChain(id)) do fields[k] = v end   -- questline/campaign (best-effort; may be empty pre-accept)
      if QuestIsDaily and QuestIsDaily() then fields.daily = 1 end
      if QuestIsWeekly and QuestIsWeekly() then fields.weekly = 1 end
      local grp = GetSuggestedGroupNum and GetSuggestedGroupNum()
      if grp and grp > 0 then fields.suggestedGroup = grp end
      local r = record(id, fields)
      lib.callbacks:Fire("GECQUEST_OFFERED", r)
      streamPush(">> OFFERED", r)
    end

  elseif event == "QUEST_PROGRESS" then
    -- Turn-in requirements dialog opened. Harvest the ender + location + progress text + required items/money,
    -- and stream/fire on OPEN (no completion needed) — symmetric with the offer dialog.
    local n = unitNpc("npc")
    if n then n.t = GetTime and GetTime() or 0; lib._npc = n end
    local id = dialogId()
    if id then
      local toGet = GetQuestMoneyToGet and GetQuestMoneyToGet() or 0
      local r = record(id, {
        title = txt(GetTitleText),
        ender = n or recentNpc(), turninAt = here(),
        progressText = txt(GetProgressText),
        requiredItems = itemsOf("required", GetNumQuestItems),
        moneyToGet = (toGet and toGet > 0) and toGet or nil,
      })
      lib.callbacks:Fire("GECQUEST_TURNIN_OPENED", r)
      streamPush("<< TURN-IN (requirements)", r)
    end

  elseif event == "QUEST_COMPLETE" then
    -- Reward dialog opened. Harvest the ender + location + completion text + the full reward preview, and
    -- stream/fire on OPEN (no completion needed) — this is what you see when you open a turn-in and look.
    local n = unitNpc("npc")
    if n then n.t = GetTime and GetTime() or 0; lib._npc = n end
    local id = dialogId()
    if id then
      local fields = { title = txt(GetTitleText), ender = n or recentNpc(), turninAt = here(), completeText = txt(GetRewardText) }
      for k, v in pairs(rewardPreview(id)) do fields[k] = v end
      local r = record(id, fields)
      lib.callbacks:Fire("GECQUEST_TURNIN_OPENED", r)
      streamPush("<< TURN-IN (rewards)", r)
    end

  elseif event == "QUEST_GREETING" then
    -- Multi-quest gossip giver: no single quest id is exposed; just remember the NPC for attribution.
    local n = unitNpc("npc")
    if n then n.t = GetTime and GetTime() or 0; lib._npc = n end

  elseif event == "QUEST_ACCEPTED" then
    -- retail passes (questID); older clients pass (questLogIndex, questID). Take whichever resolves to a title.
    -- The giver/location were already captured at QUEST_DETAIL; here we confirm the accept + stamp faction.
    local id = a2 or a1
    if not titleFor(id) and titleFor(a1) then id = a1 end
    id = tonumber(id); if not id then return end
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    local existing = lib._quests[id]
    local fields = { accepted = 1, faction = faction }
    if not (existing and existing.giver) then fields.giver = recentNpc() end
    if not (existing and existing.acceptAt) then fields.acceptAt = here() end
    local d = destWaypoint(id)   -- usually nil this early (POI loads on the following QUEST_POI_UPDATE); backfilled there
    if d then fields.dest = d end
    local r = record(id, fields)
    lib.callbacks:Fire("GECQUEST_ACCEPTED", r)
    streamPush(r.autoAccept and ">> ACCEPTED (auto)" or ">> ACCEPTED", r)

  elseif event == "QUEST_POI_UPDATE" then
    -- POI data just loaded. For each currently-in-log quest we know, fill the "go here" waypoint if missing and
    -- refresh the objective pins, keeping the RICHEST pin set seen (as objectives reveal, more pins appear).
    -- Restricted to in-log quests so we don't churn over the whole hydrated atlas.
    local ql = C_QuestLog
    if ql and ql.IsOnQuest then
      for id, r in pairs(lib._quests) do
        if ql.IsOnQuest(id) then
          local add = {}
          if not r.dest then local d = destWaypoint(id); if d then add.dest = d end end
          local p = questPois(id); if p and (not r.pois or #p > #r.pois) then add.pois = p end
          if not r.objectives then local o = questObjectives(id); if o then add.objectives = o end end
          if not r.questLineId and not r.campaignId then for k, v in pairs(questChain(id)) do add[k] = v end end
          if not r.questType then for k, v in pairs(questMeta(id)) do if r[k] == nil then add[k] = v end end end
          if r.timeLimit == nil then local tl = timeLimitOf(id); if tl then add.timeLimit = tl end end
          if r.repeatable == nil and ql.IsRepeatableQuest and ql.IsRepeatableQuest(id) then add.repeatable = 1 end
          if r.accountQuest == nil and ql.IsAccountQuest and ql.IsAccountQuest(id) then add.accountQuest = 1 end
          if ql.IsFailed and ql.IsFailed(id) then add.failed = 1 end
          if next(add) then record(id, add) end
        end
      end
    end

  elseif event == "QUEST_TURNED_IN" then
    local id = tonumber(a1); if not id then return end
    local r = record(id, {
      ender = recentNpc(), turninAt = here(),
      xp = tonumber(a2) or nil, money = tonumber(a3) or nil,
    })
    lib.callbacks:Fire("GECQUEST_TURNED_IN", r)
    streamPush("<< TURNED IN", r)

  elseif event == "QUEST_REMOVED" then
    local id = tonumber(a1)
    if id then lib.callbacks:Fire("GECQUEST_REMOVED", id) end
  end
end)

-- ---- public API ------------------------------------------------------------

-- The correlated record for a quest id (accept + turn-in merged), or nil if we've never seen it.
function lib.Get(id) hydrate(); return id and lib._quests[tonumber(id) or id] or nil end
-- The last quest-dialog NPC we saw (id, name, t), or nil if none is recent.
function lib.Current() return recentNpc() end

-- ---- diagnostics: pretty console output (GEC-Console) ----------------------

local G = "|cffe8c679"   -- brass  (labels)
local W = "|cffede6d6"   -- ink    (values)
local D = "|cff6f6a5e"   -- faint  (chrome)
local R = "|r"
local function money(c)
  c = tonumber(c) or 0
  local g, s = math.floor(c / 10000), math.floor((c % 10000) / 100)
  if g > 0 then return g .. "g " .. s .. "s" end
  if s > 0 then return s .. "s " .. (c % 100) .. "c" end
  return (c % 100) .. "c"
end
local function npcStr(n) return n and ((n.name or "?") .. (n.id and (" " .. D .. "#" .. n.id .. R) or "")) or (D .. "unknown" .. R) end
-- Location string. Coords are SPACE-separated (no comma) so "45.0 14.8" can be pasted straight into TomTom's
-- /way command; the uiMapID is shown faintly after (TomTom's /way #mapID x y form).
local function whereStr(w)
  if not w then return D .. "unknown" .. R end
  local co = (w.x and w.y) and string.format("  %s%.1f %.1f%s", W, w.x, w.y, R) or ""
  local mp = w.map and ("  " .. D .. "map " .. w.map .. R) or ""
  return W .. (w.zone or ("map " .. (w.map or "?"))) .. R .. co .. mp
end
-- "Name #id, Name #id" for an ID-anchored list ({id,name,count}); count shown as xN when > 1.
local function listStr(items)
  local parts = {}
  for _, it in ipairs(items or {}) do
    local s = (it.name or "?") .. (it.id and (" " .. D .. "#" .. it.id .. R) or "")
    if it.count and it.count > 1 then s = s .. " " .. D .. "x" .. it.count .. R end
    if it.amount and it.amount > 1 then s = s .. " " .. D .. "x" .. it.amount .. R end
    parts[#parts + 1] = W .. s .. R
  end
  return table.concat(parts, D .. ", " .. R)
end
-- Greedy word-wrap raw text (no color codes) into lines of at most `width` visible chars, breaking on spaces.
local function wrapLines(text, width)
  text = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return {} end
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    if line == "" then line = word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else out[#out + 1] = line; line = word end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end

-- A quest record as pretty lines. ASCII only — WoW's default fonts have no glyphs for box-drawing / geometric
-- symbols (they render as tofu boxes), so we use a plain "|" left rail. Returns an array of strings.
function lib.Format(r)
  if not r then return { D .. "no record" .. R } end
  local L = {}
  -- The left rail is a LITERAL pipe. In WoW text "|" is the escape char, so a lone "|" must be doubled ("||")
  -- or it swallows the following color/reset code (e.g. "||r" from a colored rail rendered as literal "|r").
  local function row(fmt, ...) L[#L + 1] = string.format("||  " .. fmt, ...) end
  -- A labeled multi-line block: full text (never truncated), word-wrapped, with wrapped lines hanging-indented
  -- to sit under the text (past the label) rather than restarting at the label.
  local function textBlock(label, text)
    local indent = string.rep(" ", #label + 1)
    local segs = wrapLines(text, lib.WRAP_WIDTH)
    for i, seg in ipairs(segs) do
      if i == 1 then L[#L + 1] = string.format("||  %s%s%s %s%s%s", G, label, R, W, seg, R)
      else L[#L + 1] = string.format("||  %s%s%s%s", indent, W, seg, R) end
    end
  end
  L[#L+1] = string.format("%s#%s%s  %s%s%s", G, r.id, R, W, r.title or "?", R)
  do
    local bits = {}
    if r.level and r.level > 0 then bits[#bits+1] = G .. "level" .. R .. " " .. W .. r.level .. R end
    if r.faction then bits[#bits+1] = G .. "faction" .. R .. " " .. W .. r.faction .. R end
    local tags = {}
    if r.daily then tags[#tags+1] = "daily" elseif r.weekly then tags[#tags+1] = "weekly" end
    if r.repeatable then tags[#tags+1] = "repeatable" end
    if r.worldQuest then tags[#tags+1] = "world quest" end
    if r.elite then tags[#tags+1] = "elite" end
    if r.accountQuest then tags[#tags+1] = "warband" end
    if r.autoAccept then tags[#tags+1] = "auto-accept" end
    if r.failed then tags[#tags+1] = "FAILED" end
    if r.timeLimit and r.timeLimit > 0 then tags[#tags+1] = "timed " .. math.floor(r.timeLimit / 60) .. "m" end
    if r.tagName then tags[#tags+1] = r.tagName end
    if r.suggestedGroup and r.suggestedGroup > 0 then tags[#tags+1] = "group " .. r.suggestedGroup end
    if tags[1] then bits[#bits+1] = D .. table.concat(tags, " - ") .. R end
    if bits[1] then row("%s", table.concat(bits, "   ")) end
  end
  if r.questLineName then row("%squestline%s %s%s%s%s", G, R, W, r.questLineName, R, r.questLineId and (" " .. D .. "#" .. r.questLineId .. R) or "") end
  if r.campaignName then row("%scampaign%s %s%s%s", G, R, W, r.campaignName, R) end
  if r.giver then row("%sgiver%s %s", G, R, npcStr(r.giver)) end
  if r.acceptAt then row("%saccept @%s %s", G, R, whereStr(r.acceptAt)) end
  if r.dest then row("%sdest @%s %s%s", G, R, whereStr(r.dest), r.dest.text and ("  " .. W .. r.dest.text .. R) or "") end
  if r.pois then
    row("%sobjective pins%s %s%d spot%s%s", G, R, D, #r.pois, #r.pois == 1 and "" or "s", R)
    for _, p in ipairs(r.pois) do L[#L + 1] = string.format("||      %s", whereStr(p)) end
  end
  if r.objectives then
    for _, o in ipairs(r.objectives) do
      local need = (o.need and o.need > 1) and (D .. "x" .. o.need .. R .. " ") or ""
      row("%sstep%s %s%s%s%s", G, R, need, W, o.text or "?", R)
    end
  elseif r.objectiveText then textBlock("objective", r.objectiveText) end
  if r.offerText then textBlock("offer", r.offerText) end
  if r.ender then row("%sturn-in%s %s", G, R, npcStr(r.ender)) end
  if r.turninAt then row("%sturned @%s %s", G, R, whereStr(r.turninAt)) end
  if r.requiredItems then row("%srequires%s %s", G, R, listStr(r.requiredItems)) end
  if r.rewardItems then row("%sreward items%s %s", G, R, listStr(r.rewardItems)) end
  if r.choiceItems then row("%schoose one%s %s", G, R, listStr(r.choiceItems)) end
  if r.rewardSpells then row("%sreward spell%s %s", G, R, listStr(r.rewardSpells)) end
  if r.currencies then row("%scurrency%s %s", G, R, listStr(r.currencies)) end
  if r.rewardTitle then row("%sreward title%s %s%s%s", G, R, W, r.rewardTitle, R) end
  do
    local parts = {}
    if r.xp and r.xp > 0 then parts[#parts+1] = W .. tostring(r.xp) .. R .. " XP" end
    if r.money and r.money > 0 then parts[#parts+1] = W .. money(r.money) .. R end
    if r.honor and r.honor > 0 then parts[#parts+1] = W .. r.honor .. R .. " honor" end
    if #parts > 0 then row("%sreward%s %s", G, R, table.concat(parts, D .. "  -  " .. R)) end
  end
  return L
end

-- Print the full record for one quest id (or a not-found note) to the chat frame — captured by the console.
function lib.Print(id)
  local r = lib.Get(id)
  if not r then print(string.format("%sGECQuest%s no record for #%s (not in the atlas yet)", G, R, tostring(id))); return end
  for _, line in ipairs(lib.Format(r)) do print(line) end
end

-- Dump every known quest as a one-line summary (id / title / giver / zone). Includes quests persisted from
-- earlier sessions (the registry is rehydrated), not just ones touched since the last reload.
function lib.Dump()
  hydrate()
  local ids = {}
  for id in pairs(lib._quests) do ids[#ids+1] = id end
  table.sort(ids)
  print(string.format("%sGECQuest%s - %d quest%s in the atlas", G, R, #ids, #ids == 1 and "" or "s"))
  for _, id in ipairs(ids) do
    local r = lib._quests[id]
    local giver = r.giver and r.giver.name or (r.ender and r.ender.name) or "?"
    local zone = (r.acceptAt and r.acceptAt.zone) or (r.turninAt and r.turninAt.zone) or "?"
    print(string.format("  %s#%-6s%s %s%-34s%s %sgiver%s %s  %s%s%s", G, id, R, W, (r.title or "?"):sub(1, 34), R, D, R, giver, D, zone, R))
  end
  if #ids == 0 then print(D .. "  (accept or turn in a quest to populate)" .. R) end
end

-- Live-stream: push each accept/turn-in as a formatted block to the GEC-Console Feed page. Toggle with no
-- arg, or force with true/false. Soft dependency on GECConsole (does nothing if the console isn't loaded).
function lib.Stream(on)
  if on == nil then on = not lib._stream end
  lib._stream = on and true or false
  print(string.format("%sGECQuest%s live-stream to console: %s", G, R, lib._stream and (W .. "ON" .. R) or (D .. "off" .. R)))
  return lib._stream
end

-- /gquest            -> dump all known quests (ids + summary)
-- /gquest <id>       -> full record for that quest
-- /gquest stream     -> toggle the live-stream to the console Feed page
-- Registered once (guarded across MINOR upgrades + multiple embedding addons).
if not lib._slash then
  lib._slash = true
  _G.SLASH_GECQUEST1 = "/gquest"
  SlashCmdList = SlashCmdList or {}
  SlashCmdList["GECQUEST"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then lib.Dump()
    elseif msg == "stream" then lib.Stream()
    else lib.Print(tonumber(msg) or msg) end
  end
end
