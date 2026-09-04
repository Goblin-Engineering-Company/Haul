-- Report.lua — the in-game BUG REPORT blob (Haul's mirror of SBF/Report.lua).
--
-- This SHIPS (it is not dev-only): a public user hits a problem, clicks one button on the About tab (or types
-- /haul bug), and pastes a block of text that tells us enough to reproduce it. Every Haul bug so far — the
-- session that silently crossed characters, the zone prompt that never showed, the 0g cold-cache values, the
-- double-counted coin — came down to a handful of facts (which build, which price source, what the triggers
-- were set to, where the player actually was) that took a round trip each to extract. This hands them over
-- in one paste.
--
-- ⚠️ PRIVACY IS THE HARD CONSTRAINT. NOTHING here may identify the player. Explicitly EXCLUDED, and no
-- future field may reintroduce them: character name, realm, guild, account/BattleTag, GUIDs, friends,
-- group members, coordinates, mail senders/subjects, any chat text, any item you looted, gold amounts.
-- We ship CONFIGURATION and STATE (counts, flags, versions), never identity and never the haul itself.
-- Zone NAMES are included because the zone-change triggers are the thing most reports are about and a zone
-- is not identifying on its own (thousands of players stand in it). Class and level gate nothing here but
-- are cheap context and equally anonymous. When in doubt, leave it out — a missing field costs one round
-- trip, a leaked one costs trust.
--
-- Shape is deliberately plain text, not JSON: it has to survive being pasted into Discord, a forum, or an
-- email without anyone installing anything.
local _, ns = ...
Haul = Haul or {}

local function ver(addon)
  local g = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ok, v = pcall(g, addon, "Version")
  return (ok and v) or "?"
end

-- every GEC addon that's loaded, with its version — "which builds were in play" is the first question we
-- ask on any report, and a mismatched pair (Haul new, a shared lib old) is a real failure mode. The two
-- price addons are listed too: they are OptionalDeps and their absence explains most "0g" reports.
local GEC_ADDONS = { "Haul", "SBF", "Megaphone", "Gadgets", "Coffer", "GEC-Console", "GECStore-session" }
local PRICE_ADDONS = { "TradeSkillMaster", "Auctionator" }
local LIBS = { "GECBind-1.0", "GECLoot-1.0", "GECTheme-1.0", "GECStore-1.0", "GECData-1.0", "GECReader-1.0",
               "GECMap-1.0", "GECStoreView-1.0", "GECQuest-1.0", "GECTemplate-1.0", "GECWowToken-1.0",
               "GECFeedBrowser-1.0" }

local function loadedAddons(out)
  local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  local function list(names)
    local parts = {}
    for _, a in ipairs(names) do
      local ok, l = pcall(isLoaded, a)
      if ok and l then parts[#parts + 1] = ("%s %s"):format(a, ver(a)) end
    end
    return parts
  end
  local gec = list(GEC_ADDONS)
  out[#out + 1] = "addons : " .. (#gec > 0 and table.concat(gec, ", ") or "none")
  local price = list(PRICE_ADDONS)
  out[#out + 1] = "pricing addons: " .. (#price > 0 and table.concat(price, ", ") or "none (vendor prices only)")
  local lv = {}
  for _, l in ipairs(LIBS) do
    local lib, minor
    if LibStub then lib, minor = LibStub(l, true) end   -- `x and f()` would collapse the second return value
    if lib then lv[#lv + 1] = ("%s.%s"):format((l:gsub("%-1%.0$", "")), tostring(minor or "?")) end
  end
  if #lv > 0 then out[#out + 1] = "libs   : " .. table.concat(lv, ", ") end
end

-- tostring() on a table prints an ADDRESS, which is noise in a report and differs every session. Render
-- something a human can read (one level deep; nested tables collapse to {...}).
local function fmtValue(v)
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k2, v2 in pairs(v) do
    if type(v2) ~= "table" then keys[#keys + 1] = ("%s=%s"):format(tostring(k2), tostring(v2)) end
  end
  table.sort(keys)
  return #keys > 0 and ("{" .. table.concat(keys, ",") .. "}") or "{...}"
end

-- Settings that change BEHAVIOUR. Window positions, colours, font sizes, templates and view prefs are left
-- out on purpose: they never explain a bug and the templates can carry user-typed text.
local BEHAVIOUR_KEYS = {
  "priceSource", "tsmPriceStr", "priceCacheTTL", "notableQuality",
  "graysMode", "boundMode", "excludedMode", "mailMode",
  "fastLoot", "flushEnabled", "flushSeconds", "reloadBeforeNewSession",
  "newSessionTriggers", "newSessionMapLevel", "newSessionPrompt",
  "countPausedByDefault", "batchGap", "refreshThrottle", "sessionsMineOnly", "zeroValueRepair",
}

local function settingLines(out)
  local parts = {}
  for _, k in ipairs(BEHAVIOUR_KEYS) do
    local v = HaulDB and HaulDB[k]
    if v ~= nil then parts[#parts + 1] = ("%s=%s"):format(k, fmtValue(v)) end
  end
  out[#out + 1] = "settings: " .. table.concat(parts, " ")
  -- Call out anything deviating from the shipped defaults (read from Core's own table, so this can't drift).
  -- A wall of key=value hides the two that matter.
  local D = ns.Defaults or {}
  local off = {}
  for _, k in ipairs(BEHAVIOUR_KEYS) do
    local cur, def = HaulDB and HaulDB[k], D[k]
    if cur ~= nil and def ~= nil and type(cur) ~= "table" and cur ~= def then
      off[#off + 1] = ("%s=%s (default %s)"):format(k, tostring(cur), tostring(def))
    elseif type(cur) == "table" and type(def) == "table" then
      for k2, dv in pairs(def) do
        if type(dv) ~= "table" and cur[k2] ~= nil and cur[k2] ~= dv then
          off[#off + 1] = ("%s.%s=%s (default %s)"):format(k, tostring(k2), tostring(cur[k2]), tostring(dv))
        end
      end
    end
  end
  table.sort(off)
  if #off > 0 then out[#out + 1] = "CHANGED : " .. table.concat(off, "  ") end
  -- which price sources this client can actually serve, vs the one selected: the whole "0g / wrong value"
  -- class of report is answered by this line.
  local avail = {}
  for _, s in ipairs({ "vendor", "auctionator", "tsm" }) do
    if ns.PriceSourceAvailable and ns.PriceSourceAvailable(s) then avail[#avail + 1] = s end
  end
  out[#out + 1] = ("pricing : selected=%s  available=%s"):format(
    tostring(HaulDB and HaulDB.priceSource or "?"), #avail > 0 and table.concat(avail, ",") or "none")
  -- keybinds are combos, not identity; a report about "the key does nothing" needs them.
  local kb = {}
  for cmd, combo in pairs((HaulDB and HaulDB.keybinds) or {}) do kb[#kb + 1] = ("%s=%s"):format(tostring(cmd), tostring(combo)) end
  table.sort(kb)
  if #kb > 0 then out[#out + 1] = "keys    : " .. table.concat(kb, " ") end
  local dbg = {}
  for _, k in ipairs({ "debug", "xpTrace", "dev" }) do
    if HaulDB and HaulDB[k] then dbg[#dbg + 1] = k end
  end
  if #dbg > 0 then out[#out + 1] = "debugOn : " .. table.concat(dbg, ", ") end
end

local function count(t)
  local n = 0
  if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
  return n
end

-- The live session as COUNTS and FLAGS only — never the loot, never the gold. "Is it running, how long, how
-- much has it captured, does it belong to this character, is there one set aside" is what every "it stopped
-- tracking / it lost my run" report needs.
local function sessionLines(out)
  local s = ns.session
  out[#out + 1] = "-- session --"
  if not s then out[#out + 1] = "  NO LIVE SESSION (tracking is dead - this is the bug)"; return end
  local elapsed = (s.accum or 0) + ((s.running and s.t0) and (GetTime() - s.t0) or 0)
  local cur = ns.CharName and ns.CharName() or nil
  local mine = (s.character == nil or s.character == "?" or s.character == cur) and "yes" or "NO (created by another character)"
  out[#out + 1] = ("  running=%s  elapsed=%.1fmin  sid=%s  thisCharacter=%s"):format(
    tostring(s.running and true or false), elapsed / 60, tostring(s.sid or "-"), mine)
  out[#out + 1] = ("  captured: items=%d lootEvents=%d rep=%d currency=%d professions=%d kills=%d xpEvents=%d mailGold=%d"):format(
    count(s.items), #(s.log or {}), count(s.rep), count(s.currency), count(s.professions), count(s.kills),
    #(s.xpLog or {}), #(s.mailGoldLog or {}))
  local side = ns.sidelined
  out[#out + 1] = ("  setAside=%s  savedSessions=%d  liveSessionOnDisk=%s  syncPending=%s"):format(
    side and ("yes (sid " .. tostring(side.sid or "-") .. ", " .. count(side.items) .. " items)") or "no",
    #((HaulDB and HaulDB.history) or {}), tostring(HaulDB and HaulDB.liveSession ~= nil),
    tostring(ns._syncPending and true or false))
end

-- WHERE the player is, as the triggers see it. The zone/instance triggers are the most-reported feature and
-- every one of those reports needs the same four facts: the current tiers, the baseline they are compared
-- against, whether the client thinks this is an instance, and what the trigger settings would do with that.
-- Read from the SAME functions the triggers use (ns.ZoneTiers / ns.InInstanceNow) so this cannot disagree
-- with the behaviour it describes.
local function locationLines(out)
  out[#out + 1] = "-- location (as the new-session triggers see it) --"
  local region, zone, sub = "?", "?", "?"
  if ns.ZoneTiers then
    local ok, r, z, sb = pcall(ns.ZoneTiers)
    if ok then region, zone, sub = r, z, sb end
  end
  out[#out + 1] = ("  now     : region=\"%s\"  zone=\"%s\"  subzone=\"%s\""):format(tostring(region), tostring(zone), tostring(sub))
  local last = ns._lastTiers
  if last then
    out[#out + 1] = ("  baseline: region=\"%s\"  zone=\"%s\"  subzone=\"%s\""):format(
      tostring(last.region), tostring(last.zone), tostring(last.sub))
  else
    out[#out + 1] = "  baseline: none yet (no zone event since login - the first one only sets the baseline)"
  end
  -- the map chain behind "region": a zone whose parent chain never reaches a Continent map reports region=""
  -- and a hearth inside it can never count as a region change. Show the chain so that is visible.
  if C_Map and C_Map.GetBestMapForUnit then
    local okM, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    local chain, guard = {}, 0
    while okM and mapID and guard < 12 do
      guard = guard + 1
      local info = C_Map.GetMapInfo(mapID)
      if not info then break end
      chain[#chain + 1] = ("%s(%s:t%s)"):format(tostring(info.name), tostring(mapID), tostring(info.mapType))
      mapID = info.parentMapID
      if not mapID or mapID == 0 then break end
    end
    if #chain > 0 then out[#out + 1] = "  mapChain: " .. table.concat(chain, " > ") .. "   (t3=Continent)" end
  end
  local inInst, instType = false, "?"
  if ns.InInstanceNow then
    local ok, a, b = pcall(ns.InInstanceNow)
    if ok then inInst, instType = a, b end
  end
  local rawIn, rawType = IsInInstance()
  local garrison = C_Garrison and C_Garrison.IsOnGarrisonMap and C_Garrison.IsOnGarrisonMap() or false
  local scenario = false
  if C_ScenarioInfo and C_ScenarioInfo.GetScenarioInfo then
    local ok, info = pcall(C_ScenarioInfo.GetScenarioInfo); scenario = ok and info ~= nil
  end
  out[#out + 1] = ("  instance: haulSays=%s(%s)  client=%s(%s)  garrison=%s  scenarioActive=%s  wasInInstance=%s  init=%s"):format(
    tostring(inInst), tostring(instType), tostring(rawIn), tostring(rawType), tostring(garrison), tostring(scenario),
    tostring(ns.wasInInstance), tostring(ns.peInit and true or false))
  -- and what the map trigger would DO right now, spelled out - the answer to "why didn't it ask me"
  local t = (HaulDB and HaulDB.newSessionTriggers) or {}
  local level = (HaulDB and HaulDB.newSessionMapLevel) or "region"
  local verdict
  if not t.map then verdict = "map trigger is OFF - it never asks"
  elseif inInst and t.instance then verdict = "in an instance and the instance trigger owns it - the map trigger stays quiet"
  elseif not last then verdict = "no baseline yet - the next zone event sets it, the one after can fire"
  else
    local changed
    if level == "region" then changed = (region ~= last.region)
    elseif level == "subzone" then changed = (sub ~= last.sub)
    else changed = (zone ~= last.zone) end
    verdict = ("level=%s  changed-vs-baseline=%s  %s"):format(level, tostring(changed),
      t.map and (HaulDB.newSessionPrompt and "-> would ASK" or "-> would switch automatically") or "")
    if level == "region" and (region == "" or region == nil) then
      verdict = verdict .. "  <<< region is EMPTY here: no Continent map in the chain, region-level can never fire from this spot"
    end
  end
  out[#out + 1] = ("  triggers: instance=%s scenario=%s map=%s level=%s ask=%s"):format(
    tostring(t.instance), tostring(t.scenario), tostring(t.map), tostring(level), tostring(HaulDB and HaulDB.newSessionPrompt))
  out[#out + 1] = "  verdict : " .. verdict
end

-- The data layer: the append-only streams Haul's views are rebuilt from. A hole in the sequence, a version
-- crossing, or a dangling open pointer explains every "my session vanished / the numbers don't match" report.
local function dataLines(out)
  out[#out + 1] = "-- data --"
  local d = HaulData
  if type(d) ~= "table" then out[#out + 1] = "  HaulData missing"; return end
  local meta = d._streamMeta or {}
  local GS = LibStub and LibStub:GetLibrary("GECStore-1.0", true)
  local parts = {}
  for _, name in ipairs({ "events", "markers" }) do
    local m = meta[name] or {}
    local line = ("%s seq=%s base=%s"):format(name, tostring(m.seq or 0), tostring(m.base or 1))
    if GS and GS.StreamGaps then
      local ok, r = pcall(GS.StreamGaps, { _sv = "HaulData" }, name)
      if ok and type(r) == "table" then
        line = line .. ((r.ok and " ok") or (" HOLES=" .. tostring(#(r.holes or {}))))
      end
    end
    parts[#parts + 1] = line
  end
  out[#out + 1] = ("  version=%s  sessions=%d  open=%s  parked=%s"):format(
    tostring(d.version), count(d.sessions), tostring(d._open or "-"), tostring(d._sidelined or "-"))
  out[#out + 1] = "  streams: " .. table.concat(parts, "  |  ")
end

-- The whole report as one pasteable string. `note` is the reporter's own description, included verbatim.
function Haul.BugReport(note)
  local out = {}
  out[#out + 1] = "=== Haul bug report ==="
  out[#out + 1] = ("when   : %s (client uptime %.1fh)"):format(date("%Y-%m-%d %H:%M"), (GetTime() or 0) / 3600)
  -- RETAIL OR CLASSIC, stated rather than inferred (same table as SBF's report; read from the client's own
  -- WOW_PROJECT_* globals so a flavor Blizzard adds later reports its id instead of reading as the wrong game).
  local FLAVORS = {
    [_G.WOW_PROJECT_MAINLINE or -1]                 = "Retail",
    [_G.WOW_PROJECT_CLASSIC or -2]                  = "Classic Era",
    [_G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC or -3]  = "Burning Crusade Classic",
    [_G.WOW_PROJECT_WRATH_CLASSIC or -4]            = "Wrath Classic",
    [_G.WOW_PROJECT_CATACLYSM_CLASSIC or -5]        = "Cataclysm Classic",
    [_G.WOW_PROJECT_MISTS_CLASSIC or -6]            = "Mists Classic",
  }
  local proj = _G.WOW_PROJECT_ID
  local flavor = (proj and FLAVORS[proj]) or (proj and ("unknown flavor id " .. tostring(proj))) or "unknown"
  local gameVer, build, _, iface = GetBuildInfo()
  out[#out + 1] = ("wow    : %s %s (build %s)  interface %s  locale %s"):format(
    flavor, tostring(gameVer), tostring(build), tostring(iface), tostring(GetLocale and GetLocale() or "?"))
  -- class + level only. NO name/realm/guild.
  local class = select(2, UnitClass("player"))
  out[#out + 1] = ("player : %s lvl %s  (no name/realm/guild collected)"):format(
    tostring(class), tostring(UnitLevel and UnitLevel("player") or "?"))
  out[#out + 1] = ("build  : %s%s  dev=%s"):format(tostring(Haul.BUILD or ver("Haul")),
    tostring(Haul.ChannelBadge and Haul.ChannelBadge() or ""), tostring(Haul.IsDev and Haul.IsDev() or false))
  loadedAddons(out)
  settingLines(out)
  out[#out + 1] = ""
  sessionLines(out)
  out[#out + 1] = ""
  locationLines(out)
  out[#out + 1] = ""
  dataLines(out)
  if note and note ~= "" then
    out[#out + 1] = ""
    out[#out + 1] = "-- what happened (reporter) --"
    out[#out + 1] = "  " .. tostring(note)
  end
  out[#out + 1] = "=== end report ==="
  return table.concat(out, "\n")
end

-- ALWAYS opens its own copy window, for everyone. It must never depend on the dev console: a public user
-- doesn't have GEC-Console installed, and the report is worth exactly nothing if they can't select and copy
-- it. Self-contained, closes on Escape, pre-selects the text so it's Ctrl+C and done. Same frame as SBF's.
function Haul.ShowBugReport(note)
  local text = Haul.BugReport(note)
  local f = Haul._reportFrame
  if not f then
    f = CreateFrame("Frame", "HaulBugReport", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(700, 500); f:SetPoint("CENTER")
    f:SetMovable(true); f:SetResizable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    if f.SetResizeBounds then f:SetResizeBounds(420, 280) end

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -6)
    f.title:SetText("Haul bug report")

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 14, -28)
    hint:SetText("Already selected - press Ctrl+C to copy, then paste it into your report. No character name, realm, guild or loot is included.")
    hint:SetWidth(660); hint:SetJustifyH("LEFT")

    local sf = CreateFrame("ScrollFrame", "HaulBugReportScroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 12, -58); sf:SetPoint("BOTTOMRIGHT", -32, 40)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true); eb:SetFontObject(ChatFontNormal)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    -- read-only in practice: any edit just restores the report, so a stray keypress can't corrupt what
    -- gets pasted back to us. Guarded via OnTextChanged (user-gated), NOT OnChar: Backspace/Delete never
    -- fire OnChar, so with the whole blob pre-selected the most natural key there is silently WIPED it.
    eb:SetScript("OnTextChanged", function(self, user)
      if user and self:GetText() ~= (f._text or "") then self:SetText(f._text or ""); self:HighlightText() end
    end)
    sf:SetScrollChild(eb); f.eb, f.sf = eb, sf

    local sel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sel:SetSize(110, 22); sel:SetPoint("BOTTOMLEFT", 14, 12); sel:SetText("Select all")
    sel:SetScript("OnClick", function() eb:SetFocus(); eb:HighlightText() end)

    local rebuild = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    rebuild:SetSize(110, 22); rebuild:SetPoint("LEFT", sel, "RIGHT", 8, 0); rebuild:SetText("Refresh")
    rebuild:SetScript("OnClick", function() Haul.ShowBugReport(f._note) end)

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing(); f._fit() end)

    f._fit = function() eb:SetWidth(math.max(200, sf:GetWidth() - 8)) end
    f:SetScript("OnSizeChanged", function() f._fit() end)

    tinsert(UISpecialFrames, "HaulBugReport")     -- Escape closes it
    Haul._reportFrame = f
  end
  f._text, f._note = text, note
  f:Show()
  f._fit()
  f.eb:SetText(text)
  f.eb:SetCursorPosition(0)
  f.eb:SetFocus(); f.eb:HighlightText()
  return text
end
