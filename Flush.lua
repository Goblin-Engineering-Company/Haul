-- Flush.lua — reload-to-sync. The addon can ReloadUI() itself (not a protected
-- action), so it flushes SavedVariables to disk without logging out. Auto-timer is
-- OFF by default; the primary UX is the "press Save/Flush to sync" nudge in the bar.
local ADDON, ns = ...

local reloadQueued = false

-- Don't yank the player out of a cast / loot / combat; defer to the next safe moment.
local function SafeNow()
  if InCombatLockdown() then return false end
  if UnitChannelInfo and UnitChannelInfo("player") then return false end
  if UnitCastingInfo and UnitCastingInfo("player") then return false end
  if LootFrame and LootFrame:IsShown() then return false end
  return true
end

-- Request a reload. force=true still respects the safety guard (queues if unsafe).
-- Returns true if it reloaded RIGHT NOW, false if it queued (unsafe) — callers that
-- must sequence work around the reload (e.g. Reset's stop -> reload -> start) use this.
function ns.RequestReload(_force)
  ns.WriteState()           -- make sure the saved-state mirror is current first
  if SafeNow() then
    C_UI.Reload()
    return true
  end
  reloadQueued = true
  ns.Print("sync queued — will reload when safe")
  return false
end

local g = CreateFrame("Frame")
g:RegisterEvent("PLAYER_REGEN_ENABLED")
g:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
g:RegisterEvent("UNIT_SPELLCAST_STOP")
g:RegisterEvent("LOOT_CLOSED")
g:SetScript("OnEvent", function()
  if reloadQueued and SafeNow() then
    reloadQueued = false
    C_UI.Reload()
  end
end)

-- Optional auto-flush timer (off unless enabled in Options).
local ticker
function ns.StartFlush()
  if ticker then ticker:Cancel(); ticker = nil end
  if HaulDB.flushEnabled and (HaulDB.flushSeconds or 0) > 0 then
    ticker = C_Timer.NewTicker(HaulDB.flushSeconds, function()
      ns.RequestReload()
    end)
  end
end
