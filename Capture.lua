-- Capture.lua — turn loot chat messages into session items. Coin is tracked as a
-- net GetMoney() delta in Core (locale-independent), so we only parse items here.
local ADDON, ns = ...

local GECLoot = LibStub and LibStub:GetLibrary("GECLoot-1.0", true)   -- last-opened-container fact (container attribution)

-- Localized "you receive" prefixes so we count OUR loot, not group members'.
-- Derived from Blizzard's format strings (work in any locale).
-- Classify a self-loot line by HOW the item arrived: "loot" (mob/world), "pushed" (sent to bags), or
-- "created" ("You create: X" — crafted/COMBINED). Created items are SKIPPED — crafting isn't tracked yet
-- (a future crafting library will own it); this reliable "You create:" signal is what we use to drop them.
local LOOT_PREFIXES, PUSH_PREFIXES, CREATE_PREFIXES = {}, {}, {}
local function addP(t, fmt)
  local p = fmt and fmt:match("^(.-)%%s")          -- text before the item placeholder
  if p and p ~= "" then t[#t + 1] = p end
end
addP(LOOT_PREFIXES, LOOT_ITEM_SELF); addP(LOOT_PREFIXES, LOOT_ITEM_SELF_MULTIPLE)               -- "You receive loot: %s."
addP(PUSH_PREFIXES, LOOT_ITEM_PUSHED_SELF); addP(PUSH_PREFIXES, LOOT_ITEM_PUSHED_SELF_MULTIPLE) -- "You receive item: %s."
addP(CREATE_PREFIXES, LOOT_ITEM_CREATED_SELF); addP(CREATE_PREFIXES, LOOT_ITEM_CREATED_SELF_MULTIPLE) -- "You create: %s."
if #LOOT_PREFIXES == 0 then LOOT_PREFIXES = { "You receive" } end

local function matchesAny(msg, prefixes)
  for _, p in ipairs(prefixes) do if msg:find(p, 1, true) then return true end end
  return false
end
-- created wins over pushed wins over loot (created/pushed prefixes are the more specific match)
local function LootKind(msg)
  if matchesAny(msg, CREATE_PREFIXES) then return "created" end
  if matchesAny(msg, PUSH_PREFIXES) then return "pushed" end
  if matchesAny(msg, LOOT_PREFIXES) then return "loot" end
  return nil
end

-- Pull the item link and quantity out of a self-loot message.
local function ParseLoot(msg)
  local link = msg:match("(|c%x+|Hitem:.-|h.-|h|r)") or msg:match("(|Hitem:.-|h.-|h)")
  if not link then return end
  local count = tonumber(msg:match("[xX\195\151]%s*(%d+)%s*%.?%s*$")) or 1  -- "x3" / "×3"
  return link, count
end

-- Acquisition source, decided from "what window is open RIGHT NOW" via ns.MailboxOpen/MerchantOpen
-- (live frame/interaction checks in Core) — NOT a sticky flag, so a missed mailbox-close event can't
-- make us tag world loot as mail. Mail wins if both are somehow open. nil = normal loot.
local function CurrentSource()
  if ns.MailboxOpen and ns.MailboxOpen() then return "mail" end
  if ns.MerchantOpen and ns.MerchantOpen() then return "vendor" end
  return nil
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_LOOT")
f:SetScript("OnEvent", function(_, event, a1)
  if event ~= "CHAT_MSG_LOOT" then return end
  local kind = a1 and LootKind(a1)
  if not kind then return end
  -- Crafting is NOT tracked yet (a future crafting library will own consumption + output as its own tab).
  -- "You create: X" is the reliable crafted/combined signal, so we simply SKIP those items — they never
  -- enter Loot. The old cast-bar "combine" heuristic was removed entirely: it false-positived constantly,
  -- wrongly pulling real farmed loot out of the counted haul into a "Crafted" bucket.
  if kind == "created" then return end
  local link, count = ParseLoot(a1)
  if not link then return end
  local src = CurrentSource()
  -- Bag containers (clams, lockboxes, caches) PUSH their contents to bags with NO loot window, so GECLoot's
  -- slot classifier never sees them (both `ls` and `src` come up nil). Correlate a "pushed" item with the
  -- container we just opened: stamp ls=container (objID = that container) into the shared _lootSrc stash AddLoot reads.
  if kind == "pushed" and GECLoot and GECLoot.LastContainer then
    local c = GECLoot:LastContainer()
    if c then
      local id = tonumber(link:match("item:(%-?%d+)"))
      local existing = id and ns._lootSrc and ns._lootSrc[id]
      if id and not (existing and (GetTime() - existing.at) < 3) then
        ns._lootSrc = ns._lootSrc or {}
        ns._lootSrc[id] = { t = "container", objID = c.itemID, at = GetTime() }
      end
    end
  end
  ns.AddLoot(link, count, src)
end)
