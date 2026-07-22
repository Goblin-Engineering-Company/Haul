-- Vault.lua — Great Vault (C_WeeklyRewards) progress exposed as template tokens:
--   {vault.delve.slots}  {vault.dungeon.ilvl}  {vault.raid.tier}  {vault.ready}
--   {vault.delve}  (bare = smart summary, e.g. "1/3 t13 642")
-- Cached and only recomputed on WEEKLY_REWARDS_UPDATE / entering world, so the
-- per-frame header render stays cheap.
local ADDON, ns = ...
local Theme = LibStub("GECTheme-1.0").ForAddon(function() return (HaulDB and HaulDB.themePreset) or "gruvbox" end)

local CACHE = {}
ns.vaultCache = CACHE

-- our friendly track key -> Enum.WeeklyRewardChestThresholdType field name
local TRACKS = {
  raid    = "Raid",
  dungeon = "Activities",   -- Mythic+ dungeons
  delve   = "World",        -- world / delve row
}
local TRACK_ORDER = { "raid", "dungeon", "delve" }

local function enumFor(key)
  local E = Enum and Enum.WeeklyRewardChestThresholdType
  return E and E[TRACKS[key]] or nil
end

-- best-effort reward item level for a slot (needs Blizzard_WeeklyRewards loaded)
local function slotIlvl(activity)
  if not activity or not activity.id then return nil end
  if not (C_WeeklyRewards and C_WeeklyRewards.GetExampleRewardItemHyperlinks) then return nil end
  local ok, link = pcall(C_WeeklyRewards.GetExampleRewardItemHyperlinks, activity.id)
  if not ok or not link or link == "" then return nil end
  if C_Item and C_Item.GetDetailedItemLevelInfo then
    local ok2, ilvl = pcall(C_Item.GetDetailedItemLevelInfo, link)
    if ok2 and ilvl and ilvl > 0 then return ilvl end
  end
  return nil
end

local function unlocked(a)
  return (a.threshold or 0) > 0 and (a.progress or 0) >= a.threshold
end

local function computeTrack(key)
  local t = enumFor(key)
  if not (t and C_WeeklyRewards and C_WeeklyRewards.GetActivities) then return end
  local raw = C_WeeklyRewards.GetActivities(t) or {}
  local acts = {}
  for _, a in ipairs(raw) do
    if (not t) or a.type == t then acts[#acts + 1] = a end   -- filter defensively
  end
  if #acts == 0 then return end
  table.sort(acts, function(a, b) return (a.index or 0) < (b.index or 0) end)

  local done, slots, nextNeed = acts[1].progress or 0, 0, 0
  for _, a in ipairs(acts) do
    if unlocked(a) then slots = slots + 1
    elseif nextNeed == 0 then nextNeed = (a.threshold or 0) - (a.progress or 0) end
  end

  local bestTier, bestIlvl
  for _, a in ipairs(acts) do
    if unlocked(a) then bestTier = a.level; bestIlvl = slotIlvl(a) or bestIlvl end
  end

  local pre = "vault." .. key .. "."
  CACHE[pre .. "done"]  = tostring(done)
  CACHE[pre .. "slots"] = slots .. "/" .. #acts
  CACHE[pre .. "next"]  = nextNeed > 0 and tostring(nextNeed) or "-"
  CACHE[pre .. "tier"]  = bestTier and ("t" .. bestTier) or "-"
  CACHE[pre .. "ilvl"]  = bestIlvl and tostring(bestIlvl) or "-"
  for i, a in ipairs(acts) do
    local parts = {}
    if a.level and a.level > 0 then parts[#parts + 1] = "t" .. a.level end
    local il = slotIlvl(a)
    if il then parts[#parts + 1] = tostring(il) end
    if #parts == 0 then
      parts[1] = unlocked(a) and "done" or ((a.progress or 0) .. "/" .. (a.threshold or 0))
    end
    CACHE[pre .. "s" .. i] = table.concat(parts, " ")
  end
  -- bare summary: "1/3 t13 642"
  local sum = { CACHE[pre .. "slots"] }
  if bestTier then sum[#sum + 1] = "t" .. bestTier end
  if bestIlvl then sum[#sum + 1] = tostring(bestIlvl) end
  CACHE["vault." .. key] = table.concat(sum, " ")
end

function ns.RecomputeVault()
  wipe(CACHE)
  if not C_WeeklyRewards then return end
  -- DO NOT LoadAddOn("Blizzard_WeeklyRewards") here. Loading a Blizzard module from this
  -- (addon-initiated, on PLAYER_ENTERING_WORLD) path TAINTS it, and the taint spreads to shared
  -- UI globals (AuctionHouseFrame, StaticPopup, keybindings) — which then BLOCKS protected actions
  -- like using an item from your bags. The C_WeeklyRewards API below works without the UI loaded;
  -- ilvl previews simply fill in once you open the Great Vault yourself.
  for _, key in ipairs(TRACK_ORDER) do
    local ok = pcall(computeTrack, key)
    if not ok then end   -- never let a bad track break the rest
  end
  -- defaults so tokens never render as raw "{vault...}" once we've queried once
  for _, key in ipairs(TRACK_ORDER) do
    local pre = "vault." .. key .. "."
    CACHE[pre .. "done"]  = CACHE[pre .. "done"]  or "0"
    CACHE[pre .. "slots"] = CACHE[pre .. "slots"] or "0/3"
    CACHE[pre .. "next"]  = CACHE[pre .. "next"]  or "-"
    CACHE[pre .. "tier"]  = CACHE[pre .. "tier"]  or "-"
    CACHE[pre .. "ilvl"]  = CACHE[pre .. "ilvl"]  or "-"
    CACHE[pre .. "s1"]    = CACHE[pre .. "s1"]    or "-"
    CACHE[pre .. "s2"]    = CACHE[pre .. "s2"]    or "-"
    CACHE[pre .. "s3"]    = CACHE[pre .. "s3"]    or "-"
    CACHE["vault." .. key] = CACHE["vault." .. key] or CACHE[pre .. "slots"]
  end
  local ready = C_WeeklyRewards.HasAvailableRewards and C_WeeklyRewards.HasAvailableRewards()
  CACHE["vault.ready"] = ready and "Vault ready!" or ""
end

function ns.VaultFields()
  return CACHE
end

-- The static list of vault token NAMES (independent of whether the CACHE has been computed yet), so
-- the GECData feed (ns.OutputTokens) can list them in tokenTypes even before the first query;
-- BuildFields merges the live CACHE values at render time.
local VAULT_FIELDS = { "done", "slots", "next", "tier", "ilvl", "s1", "s2", "s3" }
function ns.VaultTokens()
  local out = {}
  for _, key in ipairs(TRACK_ORDER) do
    out[#out + 1] = "vault." .. key                    -- bare summary
    for _, fld in ipairs(VAULT_FIELDS) do out[#out + 1] = "vault." .. key .. "." .. fld end
  end
  out[#out + 1] = "vault.ready"
  return out
end


local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("WEEKLY_REWARDS_UPDATE")
f:SetScript("OnEvent", function()
  ns.RecomputeVault()
  if ns.RefreshUI then ns.RefreshUI() end
end)
