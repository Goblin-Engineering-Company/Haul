-- Token.lua — a thin shim over GECWowToken-1.0, which now OWNS the WoW Token: polling (C_WowTokenPublic,
-- no Auction House), a persisted stock-ticker history, daily rollups, all-time stats, and the REAL windowed
-- trend. Haul registers its persisted slice into the lib's mesh and keeps the same ns.* getters Core /
-- Window / ComputeStats already call, so nothing downstream changes — {token.trend} just becomes windowed.
local ADDON, ns = ...

local WT = LibStub and LibStub:GetLibrary("GECWowToken-1.0", true)
ns.WowToken = WT   -- the lib, for the token tooltip + the high/low/avg tokens (Window.lua)

-- SAVEDVARIABLES BIND — must happen at ADDON_LOADED, never at file scope.
-- WoW executes an addon's Lua BEFORE it restores that addon's SavedVariables. At file scope GECWowTokenDB is
-- therefore ALWAYS nil, so `GECWowTokenDB = GECWowTokenDB or {}` there creates a fresh throwaway table; we
-- hand that table to the lib BY REFERENCE, and the SV loader then rebinds the global to the real saved data.
-- The lib keeps holding the orphan forever: from the second session on, every price the lib records lands in
-- a table nothing persists. The symptom is quiet and plausible — high/low/avg are labelled all-time but only
-- ever cover the current login, and {token.trend} reads flat because the 24h window is never populated.
-- GECWowToken's own header states this rule ("Nothing here touches SavedVariables at FILE scope"), and
-- RegisterStore's contract is a table "already loaded from disk", which at file scope it is not.
-- ADDON_LOADED fires after the restore and before PLAYER_LOGIN (where the lib does its mesh merge), so this
-- is both correct and in time. RegisterStore is documented idempotent, so a late register is safe.
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:SetScript("OnEvent", function(self, _, name)
  if name ~= ADDON then return end
  self:UnregisterEvent("ADDON_LOADED")
  GECWowTokenDB = GECWowTokenDB or {}   -- Haul's persisted mesh slice (declared in the .toc SavedVariables)
  if WT then
    WT.RegisterStore(GECWowTokenDB)                                  -- join the mesh (merged on login)
    if WT.OnChange then WT.OnChange(function() if ns.RefreshUI then ns.RefreshUI() end end) end  -- repaint on a new price
  end
end)

function ns.TokenPrice()        return WT and WT.GetPrice and WT.GetPrice() end
function ns.GetTokenPct(copper) return WT and WT.PercentOf and WT.PercentOf(copper) end
-- TokenTrend is now the REAL windowed-trend direction (24h) — no longer up/down vs the previous reading.
function ns.TokenTrend()
  local tr = WT and WT.GetTrend and WT.GetTrend()
  return (tr and tr.dir) or "flat"
end
