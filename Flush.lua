-- Flush.lua — reload-to-sync. Reloading is a PROTECTED action in current clients: C_UI.Reload()
-- only succeeds when it runs from a HARDWARE event (your click / keypress). A reload DEFERRED to an
-- event or timer handler runs with no hardware event and is taint-blocked ("Interface action failed
-- because of an add-on"). The old code queued the reload for "when safe" and fired it from an event
-- handler — that is exactly the blocked path, and for anyone fishing (never "safe" at Save-press) it
-- blocked every time.
--
-- New rule: NEVER defer. Reload runs synchronously from the hardware Save/Flush action, and only when
-- SafeNow() (not mid-cast/channel/loot/combat, so it can't yank you out of anything). The Save button
-- is DISABLED while unsafe (see ns.UpdateSaveEnabled in Window.lua) and enables the instant you're
-- clear, so every click that reaches RequestReload is the known-good hardware+safe path.
local ADDON, ns = ...

-- Safe to reload right now? (Also the Save button's enabled predicate.) Don't interrupt a cast/channel
-- (a fishing channel included), an open loot window, or combat.
function ns.SafeNow()
  if InCombatLockdown() then return false end
  if UnitChannelInfo and UnitChannelInfo("player") then return false end
  if UnitCastingInfo and UnitCastingInfo("player") then return false end
  if LootFrame and LootFrame:IsShown() then return false end
  return true
end

-- Reload NOW if safe, from the CALLER'S hardware context (a button OnClick / keybind press). Returns
-- true if it reloaded, false if it couldn't (unsafe). NEVER defers — a deferred reload is taint-blocked
-- — so when unsafe it just no-ops and lets the UX (the disabled Save button, or this nudge) handle it.
-- Callers that sequence around a reload (New-session) use the return value.
function ns.RequestReload(_force)
  ns.WriteState()                     -- keep the saved-state mirror current first
  if ns.SafeNow() then
    C_UI.Reload()
    return true
  end
  ns.Print("can't sync yet: finish the cast, close the loot window, or leave combat, then press Save")
  return false
end

-- Watch every edge that flips SafeNow() and refresh the Save button's enabled state, so it grays out
-- while unsafe and lights up the moment you're clear. NO reload happens here — a reload from an event
-- handler is precisely the taint-blocked path we're removing.
local g = CreateFrame("Frame")
g:RegisterEvent("PLAYER_REGEN_DISABLED")
g:RegisterEvent("PLAYER_REGEN_ENABLED")
g:RegisterEvent("LOOT_OPENED")
g:RegisterEvent("LOOT_CLOSED")
g:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
g:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
g:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
g:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
g:SetScript("OnEvent", function()
  if ns.UpdateSaveEnabled then ns.UpdateSaveEnabled() end
end)

-- Optional auto-flush timer (off unless enabled in Options). A timer has NO hardware event, so it can
-- NOT reload (that would be taint-blocked). Repurposed to a NUDGE: it flags a pending sync and refreshes
-- the Save button; you click Save to actually flush. Printed once per pending window so it can't spam.
local ticker
function ns.StartFlush()
  if ticker then ticker:Cancel(); ticker = nil end
  if HaulDB.flushEnabled and (HaulDB.flushSeconds or 0) > 0 then
    ticker = C_Timer.NewTicker(HaulDB.flushSeconds, function()
      if not ns._syncPending then
        ns._syncPending = true
        ns.Print("sync due: press Save when you get a moment")
      end
      if ns.UpdateSaveEnabled then ns.UpdateSaveEnabled() end
    end)
  end
end
