-- Sessions.lua — view saved sessions and Resume one (loads it back into the live
-- session so the clock + totals keep rolling from where it left off). Click a row
-- to expand an inline snapshot: zones, the stats, and the full item list.
local ADDON, ns = ...
local Theme = LibStub("GECTheme-1.0").ForAddon(function() return (HaulDB and HaulDB.themePreset) or "gruvbox" end)

local frame, rows
local expanded = {}   -- [history index] = true when its detail is open
local selected = {}   -- [history index] = true when ticked for Combine

local DETAIL_W = 372

local function FmtDur(sec)
  sec = math.floor(tonumber(sec) or 0)
  local m = math.floor(sec / 60)
  if m >= 60 then return string.format("%dh %02dm", math.floor(m / 60), m % 60) end
  return string.format("%dm %02ds", m, sec % 60)
end

-- Dominant zones for a session, from its loot waypoints: "Zone (n), Zone2 (n)". Group by the most-specific
-- segment (the part after the last ">") and display the LONGEST form, so a session that mixes short
-- ("Slayer's Rise") and full-path ("... > Slayer's Rise") waypoints — e.g. spanning the full-path capture
-- change — collapses to one entry showing the full path.
local function ZoneSummary(h)
  -- unique zone strings with counts
  local raw, list = {}, {}
  for _, w in ipairs(h.waypoints or {}) do
    local z = w.zone or "?"
    if not raw[z] then raw[z] = 0; list[#list + 1] = z end
    raw[z] = raw[z] + (w.count or 1)
  end
  if #list == 0 then return "Unknown" end
  -- fold a shorter zone into the longest zone that CONTAINS it (the full-path form of the same place),
  -- so a session mixing "Slayer's Rise" (old short capture) and "... > Slayer's Rise" (full path) shows
  -- one entry. Process longest-first so the full paths become the groups.
  table.sort(list, function(a, b) return #a > #b end)
  local groups, order = {}, {}
  for _, z in ipairs(list) do
    local into
    for _, g in ipairs(order) do if g:find(z, 1, true) then into = g; break end end
    if into then groups[into] = groups[into] + raw[z]
    else groups[z] = raw[z]; order[#order + 1] = z end
  end
  table.sort(order, function(a, b) return groups[a] > groups[b] end)
  local parts = {}
  for i = 1, math.min(#order, 4) do
    parts[i] = string.format("%s |cff808080(%d)|r", order[i], groups[order[i]])
  end
  if #order > 4 then parts[#parts + 1] = "..." end
  return table.concat(parts, ",  ")
end

-- The one-line session summary used by BOTH the Data-tab row header AND each merge line, so a folded
-- run renders identically to its own row (same class color, date/time, duration, gold) — plus a stable
-- 6-digit #id so you can immediately match the merge reference to a session. `h` needs: character,
-- class, startedAt, durationSec, countedValue, uid (the per-snapshot unique id).
local SEP = "  |cff66ccff::|r  "
local function SessionLine(h, showHash)
  if showHash == nil then showHash = true end   -- default on; main rows pass false unless the sid repeats
  local who = (h.character and h.character:match("^[^-]+")) or "?"
  local classFile = h.class
  if not classFile and h.character == ns.CharName() then
    classFile = ns.CharClass and ns.CharClass() or nil
  end
  local cc = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
  local nameCol = (cc and cc.colorStr and ("|c" .. cc.colorStr)) or "|cff66ccff"
  local started = h.startedAt or 0
  local clock = date("%I:%M %p", started):gsub("^0", "")   -- 12-hour, drop the leading zero
  return nameCol .. who .. "|r"
    .. SEP .. Theme.Accent(date("%m/%d", started)) .. " |cff45c4a0" .. clock .. "|r"
    .. SEP .. "|cffeda55f" .. FmtDur(h.durationSec) .. "|r"
    .. SEP .. ns.MoneyShort(h.countedValue or 0)
    -- s<sid> = the log session number (cross-ref to the event log). The #<hash> (unique per SAVE) is shown
    -- ONLY when needed to disambiguate — a sid is 1:1 with a row UNLESS it was saved more than once / spans
    -- a merge — so the common case shows just s<sid> and saves space (showHash decides).
    .. "  |cff606060" .. ((h.sid and ("s" .. h.sid)) or "")
    .. ((showHash or not h.sid) and (((h.sid and " ") or "") .. "#" .. ns.SessionUID(h.uid)) or "") .. "|r"
end

-- The general session summary (haul/loot/coin, items, char/token/source, zone, merge provenance) — shown
-- ABOVE the category switcher regardless of which category (Loot / Rep / Currency) is selected.
local function DetailSummary(h)
  local lines = {}
  local counted = h.countedValue or 0
  local coin = h.coin or 0
  local loot = math.max(0, counted - coin)   -- item-only value (haul minus gold)
  lines[#lines + 1] = Theme.Accent("haul") .. " " .. ns.MoneyShort(counted)
    .. "    " .. Theme.Accent("loot") .. " " .. ns.MoneyShort(loot)
    .. "    " .. Theme.Accent("coin") .. " " .. ns.MoneyShort(coin)
    .. "    " .. Theme.Accent("g/hr") .. " " .. ns.MoneyShort(h.goldPerHour or 0)
    .. "  |cff808080(gross " .. ns.MoneyShort(h.grossValue or 0) .. ")|r"
  lines[#lines + 1] = Theme.Accent("items") .. " " .. tostring(h.itemCount or 0)
    .. "   " .. Theme.Accent("notable") .. " " .. tostring(h.notable or 0)
  local extra = {}
  if h.character then extra[#extra + 1] = Theme.Accent("char") .. " |cff66ccff" .. h.character .. "|r" end
  if h.tokenPct then extra[#extra + 1] = Theme.Accent("token") .. string.format(" %.4f%%", h.tokenPct) end
  if h.priceSource then extra[#extra + 1] = Theme.Accent("source") .. " " .. tostring(h.priceSource) end
  if #extra > 0 then lines[#lines + 1] = table.concat(extra, "    ") end
  lines[#lines + 1] = Theme.Accent("zone") .. " " .. ZoneSummary(h)
  -- merge provenance: this run's true creation time + each fold-in, so a merged run
  -- (relabeled to its earliest start) can be pieced back together.
  if h.establishedAt and h.establishedAt ~= h.startedAt then
    lines[#lines + 1] = Theme.Accent("established") .. " " .. date("%m/%d %H:%M", h.establishedAt)
  end
  for _, m in ipairs(h.merges or {}) do
    local f = m.from or {}
    -- the folded run rendered EXACTLY like its own Data-tab row (+ its #id) so it's instantly
    -- matchable, prefixed with a "merged <-" / "resumed <-" marker (whichever produced the fold).
    local verb = (m.via == "resume") and "resumed" or "merged"
    lines[#lines + 1] = "|cff45c4a0" .. verb .. "|r |cff808080<-|r  " .. SessionLine({
      character = f.character, class = f.class, startedAt = f.startedAt,
      durationSec = f.durationSec, countedValue = f.counted, uid = f.uid, sid = f.sid })
  end
  return table.concat(lines, "\n")
end

-- the Data-tab detail category switcher (parallels the live window's Loot/Rep/Currency button)
-- "all" retired from the switcher for now (all-view not ready); DATA_CAT_LABEL still maps it for the dormant path.
local DATA_CATS = { { k = "loot", t = "Loot" }, { k = "mail", t = "Mail" }, { k = "vendor", t = "Vendor" },
                    { k = "rep", t = "Rep" }, { k = "currency", t = "Currency" },
                    { k = "prof", t = "Skills" }, { k = "xp", t = "XP" }, { k = "kill", t = "Kills" } }
local DATA_CAT_LABEL = {}
for _, c in ipairs(DATA_CATS) do DATA_CAT_LABEL[c.k] = c.t end
local function NextDataCat(cur)   -- cycle Loot -> Rep -> Currency -> Skills -> XP -> Kills -> ...
  for i, c in ipairs(DATA_CATS) do if c.k == cur then return DATA_CATS[(i % #DATA_CATS) + 1].k end end
  return DATA_CATS[1].k
end

local function Layout()
  local y = 0
  for _, r in ipairs(rows) do
    if r:IsShown() then
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", 0, -y)
      r:SetPoint("RIGHT", frame.child, "RIGHT", 0, 0)   -- fill the panel width; buttons pinned to this edge
      y = y + r.rowH + 2
    end
  end
  frame.child:SetHeight(math.max(y, 1))
end

local function Refresh()
  if not frame then return end
  rows = rows or {}
  local hist = HaulDB.history or {}
  local sidCount = {}   -- how many rows share each sid (decides whether a row needs the #hash to disambiguate)
  for _, hh in ipairs(hist) do if hh.sid then sidCount[hh.sid] = (sidCount[hh.sid] or 0) + 1 end end
  local me = ns.CharName()
  local order = {}
  for i = 1, #hist do
    if (not HaulDB.sessionsMineOnly) or hist[i].character == me then
      order[#order + 1] = i
    end
  end
  table.sort(order, function(a, b)
    -- soft-deleted AND absorbed (folded into a survivor) sessions sink to the bottom — kept visible for
    -- Undelete / un-absorb / reconstruction, but out of the way of the live runs.
    local da, db = (hist[a].deleted or hist[a].absorbed) and 1 or 0, (hist[b].deleted or hist[b].absorbed) and 1 or 0
    if da ~= db then return da < db end
    -- "By date" order: newest SESSION first by startedAt (so reconstructed runs land in their real
    -- chronological place instead of clustering at the top by recent-rebuild save-order). uid tiebreaks.
    if HaulDB.dataSessionSort == "date" then
      local sa, sb = hist[a].startedAt or 0, hist[b].startedAt or 0
      if sa ~= sb then return sa > sb end
    end
    -- Newest SAVE first, by the per-snapshot uid (a unique, monotonic save counter). Unique => the
    -- sort is stable (no reorder-on-refresh), and the most recently saved run is always on top — incl.
    -- resumed/merged runs (which kept an OLD establishedAt and used to sink to the bottom).
    local ua, ub = hist[a].uid or -1, hist[b].uid or -1
    if ua ~= ub then return ua > ub end
    local ea = hist[a].establishedAt or hist[a].startedAt or 0   -- fallback for any pre-uid entry
    local eb = hist[b].establishedAt or hist[b].startedAt or 0
    return ea > eb
  end)

  for _, r in ipairs(rows) do r:Hide() end
  for n, idx in ipairs(order) do
    local h = hist[idx]
    local r = rows[n]
    if not r then
      r = CreateFrame("Frame", nil, frame.child)   -- width comes from the Layout anchors (fills frame.child)
      -- select checkbox (left) — ticks this session for Combine
      r.pick = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
      r.pick:SetSize(20, 20); r.pick:SetPoint("TOPLEFT", 0, -1)
      Theme.Checkbox(r.pick)
      -- clickable header that toggles the detail: fills from the checkbox to just left of the buttons
      r.head = CreateFrame("Button", nil, r)
      r.head:SetPoint("TOPLEFT", 20, 0); r.head:SetPoint("RIGHT", r, "RIGHT", -176, 0); r.head:SetHeight(22)
      r.head:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      r.head:SetScript("OnEnter", function(self)   -- explain the disk indicator (r._onDisk set per refresh)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(r._onDisk and "On disk" or "In memory only")
        GameTooltip:AddLine(r._onDisk
          and "Written to SavedVariables — safe across a crash."
          or "Not yet written. Reload or log out to flush it to disk (Save reloads by default).",
          0.9, 0.9, 0.9, true)
        GameTooltip:Show()
      end)
      r.head:SetScript("OnLeave", GameTooltip_Hide)
      r.head.text = r.head:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      r.head.text:SetPoint("LEFT", 2, 0); r.head.text:SetPoint("RIGHT", -4, 0)
      r.head.text:SetJustifyH("LEFT"); r.head.text:SetWordWrap(false)   -- one flowing line (clips at the buttons if very long)
      -- detail snapshot (hidden until expanded); width set per-refresh to the panel width
      r.detail = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      r.detail:SetPoint("TOPLEFT", 26, -24)
      r.detail:SetJustifyH("LEFT"); r.detail:SetSpacing(2)
      -- ONE category DROPDOWN (mirrors the live window), + a 2nd FontString for the selected category's
      -- content. Choosing a category sets the shared HaulDB.dataCategory (all expanded rows follow it).
      r.catBtn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
      r.catBtn:SetSize(96, 18); Theme.Button(r.catBtn)
      r.catBtn:SetFrameLevel(r.head:GetFrameLevel() + 2)
      do   -- down-arrow so it reads as a dropdown
        local a = r.catBtn:CreateTexture(nil, "OVERLAY")
        a:SetTexture("Interface\\Buttons\\Arrow-Down-Up"); a:SetSize(12, 12); a:SetPoint("RIGHT", -3, -1)
      end
      do   -- left-align the label so the arrow never sits over the last letter
        local fs = r.catBtn:GetFontString()
        if fs then fs:ClearAllPoints(); fs:SetPoint("LEFT", 6, 0); fs:SetJustifyH("LEFT") end
      end
      r.catBtn:SetScript("OnClick", function(self)
        if not MenuUtil then   -- fallback: cycle when the modern menu API is missing
          HaulDB.dataCategory = NextDataCat(HaulDB.dataCategory or "loot"); Refresh(); return
        end
        MenuUtil.CreateContextMenu(self, function(_, root)
          root:CreateTitle("Category")
          for _, c in ipairs(DATA_CATS) do
            root:CreateRadio(c.t, function() return (HaulDB.dataCategory or "loot") == c.k end, function()
              HaulDB.dataCategory = c.k; Refresh()
            end)
          end
        end)
      end)
      r.catBtn:Hide()
      -- per-session AccordionList content frame (replaces the old text block) — the SAME component the
      -- live window uses, so a saved session gets identical expandable groups + value/% columns.
      r.accFrame = CreateFrame("Frame", nil, r)
      r.acc = Theme.AccordionList(r.accFrame, { theme = Theme, rowH = 18, indent = 14 })
      r.resume = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
      r.resume:SetSize(52, 20); r.resume:SetPoint("TOPRIGHT", -118, -1); r.resume:SetText("Resume")
      Theme.Button(r.resume)
      r.merge = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
      r.merge:SetSize(52, 20); r.merge:SetPoint("TOPRIGHT", -62, -1); r.merge:SetText("Merge")
      Theme.Button(r.merge)
      r.del = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
      r.del:SetSize(56, 20); r.del:SetPoint("TOPRIGHT", -2, -1); r.del:SetText("Delete")
      Theme.Button(r.del)
      -- Undelete (shown only on soft-deleted rows, in the Merge slot; Resume/Merge hide there)
      r.undel = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
      r.undel:SetSize(62, 20); r.undel:SetPoint("TOPRIGHT", -60, -1); r.undel:SetText("Undelete")
      Theme.Button(r.undel); r.undel:Hide()
      -- keep the action buttons above the full-width clickable header
      r.resume:SetFrameLevel(r.head:GetFrameLevel() + 2)
      r.merge:SetFrameLevel(r.head:GetFrameLevel() + 2)
      r.del:SetFrameLevel(r.head:GetFrameLevel() + 2)
      r.undel:SetFrameLevel(r.head:GetFrameLevel() + 2)
      rows[n] = r
    end
    r.idx = idx
    r.pick:SetChecked(selected[idx] and true or false)
    r.pick:SetScript("OnClick", function(self)
      selected[r.idx] = self:GetChecked() and true or nil
      if frame.updateCombine then frame.updateCombine() end
    end)
    r.merge:SetScript("OnClick", function() ns.MergeFromHistory(r.idx); Refresh() end)
    local isOpen = expanded[idx] and true or false
    -- +/- textures render in every font (Unicode triangles show as tofu boxes)
    local arrow = isOpen and "|TInterface\\Buttons\\UI-MinusButton-Up:14:14:0:0|t "
                          or "|TInterface\\Buttons\\UI-PlusButton-Up:14:14:0:0|t "
    local isDeleted = h.deleted and true or false
    local isAbsorbed = h.absorbed and true or false
    local tag = ""
    if h.merged then tag = "  |cff45c4a0" .. (type(h.merged) == "string" and h.merged or "merged") .. "|r"
    elseif h.combined then tag = "  |cff45c4a0combined|r"
    elseif h.reconstructed then tag = "  |cff8888ff(from log)|r" end
    -- a folded-in source: rolled into its survivor's total, kept here (faded) so it never looks lost
    if isAbsorbed then tag = tag .. "  |cffa0a0a0(absorbed into s" .. tostring(h.absorbedInto or "?"):sub(-4) .. ")|r" end
    if isDeleted then tag = tag .. "  |cffd06060(deleted)|r" end
    -- disk-flush indicator: on disk once a later write-generation has loaded (see SnapshotSession.gen)
    r._onDisk = (h.gen or 0) < (HaulData and HaulData._gen or 1)
    local disk = r._onDisk
      and "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12:0:-1|t "      -- green check = written to disk
      or  "|TInterface\\RaidFrame\\ReadyCheck-Waiting:12:12:0:-1|t "    -- yellow = in memory, not yet flushed
    -- [disk] [+/-] then the SHARED one-line summary (name :: date/time :: playtime :: gold :: #id), + tag
    -- show the #hash only when this sid appears on more than one row (or has no sid); else just s<sid>
    r.head.text:SetText(disk .. arrow .. SessionLine(h, (not h.sid) or (sidCount[h.sid] or 0) > 1) .. tag)

    -- soft-delete state: deleted rows hide Resume/Merge + the Combine tick, and Delete becomes a
    -- deliberate permanent Purge; Undelete restores. A normal Delete just sinks the run to the bottom.
    -- both deleted and absorbed rows are faded and hide Resume/Merge/Combine (you don't operate on a
    -- folded-in source directly; un-absorb is the future reverse). Delete still soft-deletes the view row.
    local faded = isDeleted or isAbsorbed
    r.undel:SetShown(isDeleted)
    r.resume:SetShown(not faded)
    r.merge:SetShown(not faded)
    r.pick:SetShown(not faded)
    r.del:SetText(isDeleted and "Purge" or "Delete")
    r.head.text:SetAlpha(faded and 0.5 or 1)   -- fade the deleted/absorbed row's header (buttons stay crisp)

    if isOpen then
      local cw = frame.child:GetWidth()                        -- flow the detail to the panel width
      local dw = (cw and cw > 80) and (cw - 32) or DETAIL_W
      r.detail:SetWidth(dw); r.detail:SetText(DetailSummary(h)); r.detail:Show()
      -- cycling category button, just below the summary
      local cat = HaulDB.dataCategory or "loot"
      r.catBtn:SetText(DATA_CAT_LABEL[cat] or "Loot")
      r.catBtn:ClearAllPoints()
      r.catBtn:SetPoint("TOPLEFT", r.detail, "BOTTOMLEFT", 0, -4)
      r.catBtn:Show()
      -- the selected category's AccordionList, below the button. Per-session group-open state so
      -- expanding "Vendor trash" on one saved row doesn't toggle it on every row.
      HaulDB.dataGroupOpen = HaulDB.dataGroupOpen or {}
      local go = HaulDB.dataGroupOpen[h.uid] or {}
      HaulDB.dataGroupOpen[h.uid] = go
      local onToggle = function(key) go[key] = not go[key]; Refresh() end
      r.accFrame:ClearAllPoints()
      r.accFrame:SetPoint("TOPLEFT", r.catBtn, "BOTTOMLEFT", 0, -6)
      r.accFrame:SetWidth(dw); r.accFrame:Show()
      r.acc:SetEntries(ns.BuildSessionEntries(h, cat, go, onToggle, HaulDB.dataColPct))   -- sets accFrame height
      r.rowH = 24 + r.detail:GetStringHeight() + 4 + 18 + 6 + (r.accFrame:GetHeight() or 0) + 6
    else
      r.detail:Hide(); r.catBtn:Hide(); if r.accFrame then r.accFrame:Hide() end
      r.rowH = 24
    end
    r:SetHeight(r.rowH)

    r.head:SetScript("OnClick", function()
      expanded[r.idx] = not expanded[r.idx]
      Refresh()
    end)
    r.resume:SetScript("OnClick", function() ns.ResumeFromHistory(r.idx); Refresh() end)
    r.undel:SetScript("OnClick", function() ns.SetHistoryDeleted(r.idx, false); Refresh() end)
    if isDeleted then
      r.del:SetScript("OnClick", function() StaticPopup_Show("HAUL_PURGE_SESSION", nil, nil, r.idx) end)
    else
      r.del:SetScript("OnClick", function()
        selected[r.idx] = nil                 -- a soft-deleted run can't stay ticked for Combine
        ns.SetHistoryDeleted(r.idx, true)
        if frame.updateCombine then frame.updateCombine() end
        Refresh()
      end)
    end
    r:Show()
  end
  Layout()
  frame.empty:SetShown(#order == 0)
  if frame.updateCombine then frame.updateCombine() end
end

-- "are you sure" gate for the permanent Purge (only reachable from an already soft-deleted row)
StaticPopupDialogs["HAUL_PURGE_SESSION"] = {
  text = "Permanently delete this saved session?\nThis can't be undone here (it may still be reconstructed from its log later).",
  button1 = YES, button2 = NO,
  OnAccept = function(_, idx)
    expanded[idx] = nil; wipe(selected)   -- history indices shift on a permanent delete
    ns.DeleteHistory(idx); Refresh()
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

-- Build the saved-sessions UI into a caller-provided host frame (the Data tab's
-- inline section). All the per-session row builders, Refresh()/Layout(), the
-- mine-only filter, and Combine point at `frame` (= host), so they work unchanged.
function ns.EmbedSessions(host)
  if frame == host and host.haulSessionsBuilt then ns.RefreshSessions(); return end
  frame = host
  host.haulSessionsBuilt = true
  -- "this character only" filter (persisted)
  local mine = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  mine:SetSize(22, 22); mine:SetPoint("TOPLEFT", 0, -2)
  mine:SetChecked(HaulDB.sessionsMineOnly)
  Theme.Checkbox(mine)
  mine:SetScript("OnClick", function(self)
    HaulDB.sessionsMineOnly = self:GetChecked() and true or false; Refresh()
  end)
  local ml = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ml:SetPoint("LEFT", mine, "RIGHT", 2, 0); ml:SetText("This character only")
  Theme.Font(ml, "textDim")
  -- Columns dropdown (Value always on + Percentage toggle) — mirrors the main window's Columns control
  local colsBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  colsBtn:SetSize(74, 22); colsBtn:SetPoint("LEFT", ml, "RIGHT", 12, 0); colsBtn:SetText("Columns")
  Theme.Button(colsBtn)
  colsBtn:SetScript("OnClick", function(self)
    if not MenuUtil then return end
    MenuUtil.CreateContextMenu(self, function(_, root)
      root:CreateCheckbox("Percentage", function() return HaulDB.dataColPct end, function()
        HaulDB.dataColPct = not HaulDB.dataColPct; Refresh()
      end)
    end)
  end)
  -- Sort dropdown (order of ITEMS within each expanded session's loot detail)
  local SORTS = { { v = "value", t = "Value" }, { v = "name", t = "Name" }, { v = "count", t = "Count" } }
  local sortBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  sortBtn:SetSize(60, 22); sortBtn:SetPoint("LEFT", colsBtn, "RIGHT", 6, 0); sortBtn:SetText("Sort")
  Theme.Button(sortBtn)
  sortBtn:SetScript("OnClick", function(self)
    if not MenuUtil then return end
    MenuUtil.CreateContextMenu(self, function(_, root)
      root:CreateTitle("Items")   -- order of items within an expanded session's loot
      for _, s in ipairs(SORTS) do
        root:CreateRadio(s.t, function() return (HaulDB.dataSortBy or "value") == s.v end, function()
          HaulDB.dataSortBy = s.v; Refresh()
        end)
      end
      root:CreateTitle("Sessions")   -- order of the session list itself
      root:CreateRadio("Recent (saved)", function() return (HaulDB.dataSessionSort or "recent") == "recent" end,
        function() HaulDB.dataSessionSort = "recent"; Refresh() end)
      root:CreateRadio("By date", function() return HaulDB.dataSessionSort == "date" end,
        function() HaulDB.dataSessionSort = "date"; Refresh() end)
    end)
  end)
  -- Combine: fuse the ticked sessions into one new saved entry (originals kept)
  local combine = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  combine:SetSize(150, 22); combine:SetPoint("TOPRIGHT", -2, 0)
  combine:SetText("Combine selected")
  Theme.Button(combine)
  combine:SetScript("OnClick", function()
    local idx = {}
    for i in pairs(selected) do idx[#idx + 1] = i end
    if ns.CombineHistory(idx) then
      wipe(selected); Refresh()
    end
  end)
  frame.combineBtn = combine
  function frame.updateCombine()
    local n = 0
    for _ in pairs(selected) do n = n + 1 end
    combine:SetText(n >= 2 and ("Combine " .. n) or "Combine selected")
    combine:SetEnabled(n >= 2)
  end
  local sf = CreateFrame("ScrollFrame", "HaulSessionsScroll", frame)   -- bare: modern MinimalScrollBar
  sf:SetPoint("TOPLEFT", 0, -28); sf:SetPoint("BOTTOMRIGHT", -16, 4)
  frame.child = CreateFrame("Frame", nil, sf); frame.child:SetSize(384, 1)
  sf:SetScrollChild(frame.child)
  ns.AttachScrollBar(sf)
  -- keep the scroll child as wide as the scroll frame so the rows fill the panel width
  local function fitChild() frame.child:SetWidth(math.max(1, sf:GetWidth())) end
  sf:SetScript("OnSizeChanged", fitChild)
  sf:HookScript("OnShow", fitChild)
  if C_Timer and C_Timer.After then C_Timer.After(0, fitChild) end
  frame.empty = frame:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  frame.empty:SetPoint("CENTER", 0, 0)
  frame.empty:SetText("No saved sessions yet — hit Save during a run.")
  Theme.Font(frame.empty, "textMuted")
  rows = nil   -- rows pool is parented to frame.child; rebuild for this host
  Refresh()
end

-- Repopulate the embedded list (Data tab calls this when the section is shown).
function ns.RefreshSessions()
  Refresh()
end

-- Back-compat alias: /haul sessions and any old caller open the options Data tab
-- with the sessions section expanded (the standalone popup is gone).
function ns.ShowSessions()
  if ns.InitOptions then ns.InitOptions() end
  if ns.OpenToSessions then ns.OpenToSessions() end
end
