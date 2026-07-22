-- GECLoot-1.0 — shared loot pipeline for GEC addons: a source-classifying OBSERVER + optional fast auto-loot.
--
-- TWO ROLES (independent):
--   1. OBSERVER (MINOR 3+): on every loot window it reads each slot's SOURCE (GetLootSourceInfo) and the recent
--      action context (fishing / pickpocket / opening / gather casts), classifies a `src` descriptor, and fires
--      enriched callbacks — LOOT_ITEM(info)/LOOT_MONEY(info) each carry `info.src`. This is the SINGLE
--      source-classifying capture both Haul and SBF consume (so a record looks identical whichever produced it).
--      Firing is driven off LOOT_SLOT_CLEARED, so it reports what actually ENTERED YOUR BAGS whether fast-loot,
--      Blizzard auto-loot, or a manual click took the slot. Request it with Observe(token)/Unobserve(token).
--   2. FAST AUTO-LOOT (the original role): a C_Timer ticker takes one slot per tick (framerate-independent) and
--      suppresses the loot window, so looting is silent + never drops on low FPS. Request it with
--      Enable(token)/Disable(token). Enable implies Observe.
--
-- SAFETY (auto-loot, always on): the real window is surfaced whenever the user is needed — locked slot, above
-- group-loot quality, bind-on-pickup, or bags full — so nothing is silently lost.
--
-- NO EXTERNAL REFERENCE: our own implementation against the standard WoW loot API; no shipped code/comment/string
-- names any other addon.
--
-- EMBED-SYNC: copied verbatim into addons/_libs/, addons/SBF/Libs/, addons/Haul/Libs/. A lib edit must propagate
-- to ALL copies — bump MINOR so the newest copy wins via LibStub until the others sync.
local MAJOR, MINOR = "GECLoot-1.0", 10  -- 10: fish window is one-per-reel-in — a later instant-open chest in the tail is not fish
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- CallbackHandler gives consumers lib.RegisterCallback / lib.UnregisterCallback and us lib.callbacks:Fire.
lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)

-- Persistent state (kept across a MINOR upgrade so an in-flight reload doesn't lose the requester/observer sets).
lib.requesters = lib.requesters or {}   -- [token] = true   (addons that want FAST AUTO-LOOT)
lib.observers  = lib.observers  or {}   -- [token] = true   (addons that want SOURCE-CLASSIFIED loot events)
lib.debugOf    = lib.debugOf    or {}   -- [token] = true   (requesters/observers that want the chat dump)
lib._active    = lib._active    or false   -- auto-loot on (>= 1 requester)
lib._lastContainer = lib._lastContainer or nil   -- { itemID, link, t } — last bag container the player opened

-- Track the last bag container the player OPENED (right-click / UseContainerItem). Bag containers push their
-- contents to bags with no loot window, so this is the only anchor a consumer has to attribute those pushed
-- items. Hooked ONCE (idempotent across MINOR upgrades). Cheap: just records id+link+time.
if not lib._containerHooked and C_Container and C_Container.UseContainerItem then
  hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
    local id   = C_Container.GetContainerItemID   and C_Container.GetContainerItemID(bag, slot)
    local link = C_Container.GetContainerItemLink and C_Container.GetContainerItemLink(bag, slot)
    if id then lib._lastContainer = { itemID = id, link = link, t = GetTime() } end
  end)
  lib._containerHooked = true
end

-- Time window (seconds) a "what action produced this loot" cast/opening stays valid. Configurable per the
-- everything-configurable rule (a consumer may set lib.CONTEXT_WINDOW before/after load).
lib.CONTEXT_WINDOW = lib.CONTEXT_WINDOW or 5
-- Window (seconds) a "you just opened a bag container" fact stays valid. Bag containers (clams, lockboxes,
-- caches) PUSH their contents straight to bags with NO loot window / GetLootSourceInfo, so slot classification
-- can't see them. LastContainer() exposes the last-opened container so a consumer can attribute a pushed item
-- that arrives right after. Short by design — contents push within the same frame or two.
lib.CONTAINER_WINDOW = lib.CONTAINER_WINDOW or 2

-- Action spell IDs that disambiguate an otherwise-ambiguous source GUID (verified in-game 2026-07-05 — see the
-- loot-source-guid-map). A GameObject GUID alone can't tell fish-bobble from chest from herb node; the last cast
-- does. A Creature GUID is a kill UNLESS the last cast was Pick Pocket (the unit is still alive).
-- Fishing has MULTIPLE spell IDs (verified in-game): 131474 = the base cast, 131476 = the CHANNEL — and pole
-- variants (Underlight Angler, etc.) use others. They're ALL named "Fishing", so we match by known-id fast-path
-- OR by name (locale-proof: compare to the localized name of the base fishing spell). isFishingSpell() gates
-- both the channel tracking and the last-cast fallback.
local FISHING_SPELLS   = { [131474] = true, [131476] = true }
local SPELL_PICKPOCKET = 921
local SPELL_OPENING    = 3365
local function spellName(id) return id and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id) or nil end
local function isFishingSpell(id)
  if not id then return false end
  if FISHING_SPELLS[id] then return true end
  local base = spellName(131474)          -- localized "Fishing" (cached would be nicer, but this is cheap + rare)
  return (base and spellName(id) == base) or false
end

-- One owned event frame, and one owned ALWAYS-HIDDEN host we reparent LootFrame onto to suppress it.
if not lib._frame then lib._frame = CreateFrame("Frame") end
if not lib._hide  then lib._hide  = CreateFrame("Frame"); lib._hide:Hide() end

local TICK   = 0.033   -- ~30/s: one slot per tick, framerate-independent (the whole point)
local PREFIX = "|cff8fd3c4GECLoot|r "   -- brand-neutral teal prefix for debug lines (no external-addon name)
-- Observer needs the loot + context events; UI_ERROR_MESSAGE only matters while auto-looting (gated in-handler).
-- FISHING is a CHANNEL, and the bite can take longer than CONTEXT_WINDOW while other casts (SBF's lure/buff
-- rotation) overwrite the "last cast" — so a last-cast check alone misreads the fish loot as a chest. We track
-- the fishing CHANNEL itself (start → active; stop → a short tail for the loot that follows) which is immune to
-- intervening casts and long waits. FISH_TAIL is the grace after reel-in during which loot is still "fish".
lib.FISH_TAIL = lib.FISH_TAIL or 6
local EVENTS = {
  "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "LOOT_SLOT_CLEARED", "UI_ERROR_MESSAGE",
  "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "CHAT_MSG_OPENING",
}

-- Empty/cleared slot type. We gate the drain on GetLootSlotType ~= None rather than LootSlotHasItem: the latter
-- is FALSE for money slots (coins aren't "items"), so a HasItem gate silently leaves coins unlooted.
local SLOT_NONE  = (Enum and Enum.LootSlotType and Enum.LootSlotType.None)  or LOOT_SLOT_NONE  or 0
-- Money slot type: use the Enum (the deprecated LOOT_SLOT_MONEY global can disagree — e.g. pickpocket coin was
-- mis-flagged as an item and fired LOOT_ITEM instead of LOOT_MONEY). Enum.LootSlotType.Money is authoritative.
local SLOT_MONEY = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or LOOT_SLOT_MONEY or 2

-- Inventory-full error strings → the "bags full" safety surface (locale-correct via the global strings).
local FULL_ERRORS = {}
if ERR_INV_FULL then FULL_ERRORS[ERR_INV_FULL] = true end
if ERR_BAG_FULL then FULL_ERRORS[ERR_BAG_FULL] = true end
-- "You can't carry any more of those" — a UNIQUE / max-count item you're already at the cap for. DISTINCT
-- from bags-full: more space won't help, and the loot slot never clears, so auto-loot would spam-retry it.
-- We must SKIP that specific slot (not the whole window) and name what it was. Locale-correct via globals.
local MAXCOUNT_ERRORS = {}
if ERR_ITEM_MAX_COUNT then MAXCOUNT_ERRORS[ERR_ITEM_MAX_COUNT] = true end
if ERR_ITEM_MAX_COUNT_SOCKETED then MAXCOUNT_ERRORS[ERR_ITEM_MAX_COUNT_SOCKETED] = true end
if ERR_ITEM_MAX_COUNT_EQUIPPED_SOCKETED then MAXCOUNT_ERRORS[ERR_ITEM_MAX_COUNT_EQUIPPED_SOCKETED] = true end

-- ============================ small helpers ============================
local function anyRequester() return next(lib.requesters) ~= nil end
local function observing()    return anyRequester() or next(lib.observers) ~= nil end

-- "in debug" while ANY ACTIVE requester/observer has debug on (a stale flag for a non-consumer has no effect).
local function inDebug()
  for token in pairs(lib.requesters) do if lib.debugOf[token] then return true end end
  for token in pairs(lib.observers)  do if lib.debugOf[token] then return true end end
  return false
end
local function dprint(msg) if inDebug() then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end end

-- itemID from a hyperlink (the canonical key for the LOOT_ITEM payload).
local function ItemIDFromLink(link)
  if not link then return nil end
  if C_Item and C_Item.GetItemInfoInstant then
    local id = C_Item.GetItemInfoInstant(link)
    if id then return id end
  end
  return tonumber(link:match("item:(%d+)"))
end

-- ============================ source classification ============================
-- GUID kind + id (field 6 = npcID for Creature, objID for GameObject, itemID for Item).
local function parseGUID(guid)
  if type(guid) ~= "string" then return nil end
  local kind = strsplit("-", guid)
  local id = tonumber((select(6, strsplit("-", guid))))
  return kind, id
end

local function freshCast(spellID)
  local c = lib._lastCast
  return c and c.spell == spellID and (GetTime() - c.t) < lib.CONTEXT_WINDOW
end
local function freshGather()
  local g = lib._gather
  if g and (GetTime() - g.t) < lib.CONTEXT_WINDOW then return g end
end
-- Are we fishing right now (channel live) or was the fishing channel just running (loot follows reel-in)?
-- Channel-based (immune to intervening lure/buff casts + long bite waits), with the last-cast as a backstop.
local function fishingNow()
  if lib._fishActive then return true end             -- channel live = unambiguously fishing
  -- One reel-in yields exactly ONE fish loot window. Once it has opened+closed (_fishConsumed), we're still
  -- inside the FISH_TAIL but the fish is already taken — so a later INSTANT-open chest (no cast to key on) in
  -- that tail must NOT be called fish. This is the "instant chest right after fishing == caught" fix.
  if lib._fishConsumed then return false end
  return (lib._fishUntil and (GetTime() - lib._fishUntil) < lib.FISH_TAIL)
    or (lib._lastCast and isFishingSpell(lib._lastCast.spell) and (GetTime() - lib._lastCast.t) < lib.CONTEXT_WINDOW)
    or false
end

-- Classify a loot SLOT's source into a `src` descriptor { t, guid, npcID, objID, node } (nil if unattributable).
-- Reads the slot's source GUID + the recent action context. Money slots have no item link but DO carry the
-- corpse GUID, so money-from-a-mob still classifies as t="kill" (etc.).
local function classifyLootSlot(slot)
  local guid = GetLootSourceInfo and (GetLootSourceInfo(slot))
  if not guid then
    if fishingNow() then return { t = "fish" } end   -- fished loot sometimes has no GUID
    return nil
  end
  local kind, id = parseGUID(guid)
  if kind == "Creature" or kind == "Vehicle" then
    if freshCast(SPELL_PICKPOCKET) then return { t = "pickpocket", guid = guid, npcID = id } end
    return { t = "kill", guid = guid, npcID = id }
  elseif kind == "GameObject" then
    -- While the fishing channel is LIVE, GameObject loot is unambiguously the reeled-in fish. Once the
    -- channel stops we're in the FISH_TAIL — a several-second grace where fished loot still arrives, BUT a
    -- chest/node opened in that grace would otherwise be mis-tagged "fish". So in the tail an EXPLICIT open
    -- context (a gather "perform on" line, or an Opening cast) wins over the ambient tail; only with no such
    -- context does the tail fall back to fish. This is the "chest opened right after fishing == fish" fix.
    if lib._fishActive then return { t = "fish", objID = id } end     -- channel live = definitely a fish
    local g = freshGather()
    if g then return { t = g.skill or "gather", objID = id, node = g.node } end
    if freshCast(SPELL_OPENING) then return { t = "chest", objID = id } end   -- explicit Opening cast = a chest
    if fishingNow() then return { t = "fish", objID = id } end        -- otherwise the fishing tail owns it
    return { t = "chest", objID = id }                                -- world object, no cast context
  elseif kind == "Item" then
    return { t = "container", objID = id }                            -- opened lockbox / container item
  end
  return { t = "unknown", guid = guid }
end
lib.ClassifyLootSlot = classifyLootSlot   -- exposed for consumers / tests

-- Build a canonical loot-entry table from a GECLoot `info` record (as returned by the LOOT_ITEM callback).
-- Pure function — no WoW API calls, no side effects, nil-safe. Consumers append `val` themselves after pricing.
-- Fields: id (itemID), name, link, count (quantity), q (quality), src (source descriptor from classifyLootSlot).
function lib.ToEntry(info)
  if not info then return nil end
  return {
    id    = info.itemID,
    name  = info.name,
    link  = info.link,
    count = info.quantity,
    q     = info.quality,
    src   = info.src,
  }
end

-- ============================ loot-window suppression ============================
local function suppressWindow()
  if LootFrame and LootFrame.SetParent and LootFrame:GetParent() ~= lib._hide then
    lib._lootParent = lib._lootParent or LootFrame:GetParent() or UIParent
    LootFrame:SetParent(lib._hide)
  end
end
local function restoreWindow()
  if LootFrame and LootFrame.SetParent then LootFrame:SetParent(lib._lootParent or UIParent) end
end

-- ============================ slot classification (auto-loot decision) ============================
local function aboveThreshold(quality)
  if quality == nil then return false end
  if not IsInGroup() then return false end
  local method = GetLootMethod and GetLootMethod()
  if method ~= "group" and method ~= "master" then return false end
  local thr = (GetLootThreshold and GetLootThreshold()) or 2
  return quality >= thr
end

-- Read a slot into the LOOT_ITEM/LOOT_MONEY payload shape (itemID is the canonical key). `src` is stamped by the
-- observer at LOOT_READY. Coins carry isCoin + their formatted amount in `name` (per-slot copper isn't exposed;
-- a consumer needing the exact value reads CHAT_MSG_MONEY).
local function buildInfo(slot)
  local texture, name, quantity, currencyID, quality, locked, isQuestItem = GetLootSlotInfo(slot)
  local link   = GetLootSlotLink and GetLootSlotLink(slot) or nil
  local isCoin = (GetLootSlotType and GetLootSlotType(slot) == SLOT_MONEY) or false
  return {
    slot        = slot,
    itemID      = (not isCoin) and ItemIDFromLink(link) or nil,
    link        = link,
    name        = name,
    icon        = texture,
    quality     = quality,
    quantity    = quantity or 0,
    isCoin      = isCoin,
    copper      = nil,
    isQuestItem = isQuestItem or false,
    currencyID  = currencyID,
    locked      = locked or false,
    src         = nil,                 -- filled by the observer at LOOT_READY
  }
end

local function classifySlot(slot)
  local info = buildInfo(slot)
  if info.locked then return "locked", info end
  if aboveThreshold(info.quality) then return "above quality threshold", info end
  return "loot", info
end

-- human debug lines
local function itemLine(info)
  local s = info.src and (" ← " .. tostring(info.src.t) .. (info.src.node and (" " .. info.src.node) or
    (info.src.npcID and (" npc:" .. info.src.npcID) or (info.src.objID and (" obj:" .. info.src.objID) or "")))) or ""
  if info.isCoin then return "coin · " .. tostring(info.name or "?") .. s end
  return string.format("%s · %s x%d%s", tostring(info.itemID or "?"), tostring(info.name or "?"), info.quantity or 1, s)
end
local function skipLine(reason, info)
  local id = info and info.itemID and (tostring(info.itemID) .. " ") or ""
  return string.format("skipped slot %d: %s · %s%s", (info and info.slot) or 0, reason, id, (info and info.link) or "")
end

-- ============================ the ticker (auto-loot) ============================
local function stopTicker()
  if lib._ticker then lib._ticker:Cancel(); lib._ticker = nil end
end
local function surface()
  stopTicker(); restoreWindow()
  if LootFrame and LootFrame.Show then LootFrame:Show() end
end

-- One tick = take the highest still-present LOOTABLE slot. Firing of LOOT_ITEM/LOOT_MONEY is NOT done here — it
-- rides LOOT_SLOT_CLEARED (below), so it's one path for auto-loot, Blizzard auto-loot, and manual clicks alike.
local function processTick()
  if not lib._active then stopTicker(); return end
  local num = GetNumLootItems() or 0
  if num == 0 then stopTicker(); return end
  local skip = lib._skipSlots
  local pendings
  for slot = num, 1, -1 do
    local st = GetLootSlotType and GetLootSlotType(slot)
    if st and st ~= SLOT_NONE then
      if skip and skip[slot] then                       -- flagged "can't carry more" — never retry; leave it in the window
        pendings = pendings or {}
        pendings[#pendings + 1] = { reason = "maxcount", info = skip[slot] }
      else
        local action, info = classifySlot(slot)
        if action == "loot" then
          lib._lastTriedSlot = slot                     -- so a "can't carry more" error knows WHICH item balked
          LootSlot(slot)                                -- triggers LOOT_SLOT_CLEARED → fires the callback
          return
        else
          pendings = pendings or {}
          pendings[#pendings + 1] = { reason = action, info = info }
        end
      end
    end
  end
  if pendings then
    for _, p in ipairs(pendings) do
      if p.reason == "maxcount" then dprint("can't carry more — " .. tostring(p.info))
      else dprint(skipLine(p.reason, p.info)) end
    end
    surface()
  end
  stopTicker()
end
local function startTicker()
  stopTicker()
  lib._ticker = C_Timer.NewTicker(TICK, processTick)
end

-- ============================ event flow ============================
-- Cache every slot's source-classified info the moment the window opens (before anything loots), so the
-- LOOT_SLOT_CLEARED that follows can fire the enriched callback for whatever entered the bags.
local function onLootReady()
  local num = GetNumLootItems() or 0
  if num == 0 then return end
  if lib._lastNum == num then return end   -- de-dupe the LOOT_READY / LOOT_OPENED double-fire for one window
  lib._lastNum = num
  lib._slot = {}
  for slot = 1, num do
    local info = buildInfo(slot)
    info.src = classifyLootSlot(slot)
    lib._slot[slot] = info
  end
  lib.callbacks:Fire("LOOT_START", num)
  dprint(string.format("window: %d slot%s%s", num, num == 1 and "" or "s", anyRequester() and " (auto-loot)" or ""))
  if anyRequester() then
    suppressWindow()
    startTicker()
  end
end

-- A slot was looted (by us, Blizzard auto-loot, or a manual click). Fire the enriched callback from the cache.
local function onLootSlotCleared(slot)
  local info = lib._slot and lib._slot[slot]
  if not info or info._fired then return end
  info._fired = true
  if info.isCoin then lib.callbacks:Fire("LOOT_MONEY", info)
  else lib.callbacks:Fire("LOOT_ITEM", info) end
  dprint(itemLine(info))
end

local function onLootClosed()
  -- If a loot window closes while we're inside the fishing tail, that WAS this reel-in's fish window (one per
  -- reel-in). Mark it consumed so a subsequent instant-open chest in the same tail no longer classifies as
  -- fish. Reset only on the next reel-in (CHANNEL_STOP). Harmless if the window was itself a chest.
  if lib._fishActive or (lib._fishUntil and (GetTime() - lib._fishUntil) < lib.FISH_TAIL) then
    lib._fishConsumed = true
  end
  stopTicker()
  lib._lastNum = nil
  lib._slot = nil
  lib._skipSlots = nil      -- per-window: slot indices differ next window, so never carry the skip set over
  lib._lastTriedSlot = nil
  lib.callbacks:Fire("LOOT_END")
  dprint("done")
end

-- "You perform <skill> on <node>." — tag the recent gather node + its skill (herb/mining/gather) for the
-- classifier. English match; other locales just leave node/skill unresolved (graceful — src stays generic).
local function onOpening(msg)
  if type(msg) ~= "string" then return end
  local skillTxt, node = msg:match("[Pp]erform (.-) on (.+)$")
  if not node then return end
  node = node:gsub("%s*%.%s*$", "")
  if node == "" then return end
  local skill = "gather"
  if skillTxt then
    local s = skillTxt:lower()
    if s:find("herb") then skill = "herb" elseif s:find("min") then skill = "mining" end
  end
  lib._gather = { node = node, skill = skill, t = GetTime() }
end

lib._frame:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "LOOT_READY" or event == "LOOT_OPENED" then
    onLootReady()
  elseif event == "LOOT_SLOT_CLEARED" then
    onLootSlotCleared(a1)
  elseif event == "LOOT_CLOSED" then
    onLootClosed()
  elseif event == "UI_ERROR_MESSAGE" then
    local message = a2   -- (errorType, message)
    if lib._ticker and message then
      if FULL_ERRORS[message] then
        dprint("bags full — " .. tostring(message)); surface()
      elseif MAXCOUNT_ERRORS[message] then
        -- a unique / at-cap item the game refuses: its loot slot never clears, so mark THAT slot skip (the
        -- ticker stops retrying it) and name what it was, then keep looting the rest. Answers "what is it?"
        local slot = lib._lastTriedSlot
        if slot then
          local link = (GetLootSlotLink and GetLootSlotLink(slot)) or ("slot " .. slot)
          lib._skipSlots = lib._skipSlots or {}
          lib._skipSlots[slot] = link
          dprint("can't carry any more of " .. tostring(link) .. " — skipping that slot (won't retry)")
        end
      end
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if a1 == "player" then lib._lastCast = { spell = a3, t = GetTime() } end   -- (unit, castGUID, spellID)
  elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
    if a1 == "player" and isFishingSpell(a3) then lib._fishActive = true end   -- fishing channel is live
  elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
    if a1 == "player" and (isFishingSpell(a3) or lib._fishActive) then
      lib._fishActive = false; lib._fishUntil = GetTime()   -- reel-in: the loot that follows (within FISH_TAIL) is fish
      lib._fishConsumed = false                             -- fresh reel-in: this cast's ONE fish window hasn't opened yet
    end
  elseif event == "CHAT_MSG_OPENING" then
    onOpening(a1)
  end
end)

-- ============================ registration sync ============================
-- Register the observer events whenever ANY consumer wants events (requester OR observer). Suppress + auto-loot
-- only when a REQUESTER is present. Turning everything off restores vanilla looting completely.
local function sync()
  local obs = observing()
  if obs and not lib._registered then
    for _, e in ipairs(EVENTS) do lib._frame:RegisterEvent(e) end
    lib._registered = true
  elseif not obs and lib._registered then
    stopTicker()
    for _, e in ipairs(EVENTS) do lib._frame:UnregisterEvent(e) end
    lib._registered = false
    restoreWindow()
    lib._lastNum, lib._slot = nil, nil
  end
  lib._active = anyRequester() and true or false
  if not lib._active then restoreWindow() end   -- observer-only: never suppress the window
end

-- ============================ public API ============================
-- Fast auto-loot (implies Observe). Idempotent per token.
function lib:Enable(token)
  if not token or lib.requesters[token] then return end
  lib.requesters[token] = true
  sync()
end
function lib:Disable(token)
  if not token or not lib.requesters[token] then return end
  lib.requesters[token] = nil
  sync()
end

-- Source-classified loot EVENTS without forcing auto-loot. A consumer that wants to record loot+source but leave
-- looting to the player calls Observe; combine with Enable elsewhere and the window is still auto-looted.
function lib:Observe(token)
  if not token or lib.observers[token] then return end
  lib.observers[token] = true
  sync()
end
function lib:Unobserve(token)
  if not token or not lib.observers[token] then return end
  lib.observers[token] = nil
  sync()
end

function lib:IsActive()    return lib._active and true or false end       -- auto-loot on
function lib:IsObserving() return lib._registered and true or false end   -- classifying + firing events
function lib:IsFishing()   return fishingNow() and true or false end      -- fishing channel live or just reeled in (FISH_TAIL grace)

-- The last bag container the player opened, IF still within CONTAINER_WINDOW — { itemID, link } — else nil.
-- A consumer that captures a pushed item (contents pushed to bags with no loot window) uses this to attribute
-- it to the container it came from (t="container", objID=itemID). nil = no recent container open.
function lib:LastContainer()
  local c = lib._lastContainer
  if c and (GetTime() - c.t) < lib.CONTAINER_WINDOW then return { itemID = c.itemID, link = c.link } end
  return nil
end

function lib:SetDebug(token, on)
  if not token then return end
  lib.debugOf[token] = on and true or nil
end

-- Persisted requesters/observers survive a MINOR upgrade; re-assert registration for the newest code.
sync()
