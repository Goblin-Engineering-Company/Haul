-- GECStoreView-1.0 — shared log-viewer widget for GEC addons. Renders a GECStore stream into one
-- standardized line format + a per-kind show/hide filter, so SBF and Haul share one log look.
local MAJOR, MINOR = "GECStoreView-1.0", 9
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end
GECStoreView = lib

local Store = LibStub("GECStore-1.0")
local DIRS = { "N", "NW", "W", "SW", "S", "SE", "E", "NE" }   -- WoW facing is CCW from north

-- (Color provider removed: GECStore-1.0 now installs a guarded default in-game provider for Display, so the
-- data core self-colors class names / item quality everywhere. This viewer no longer installs its own.)

-- Render one record into the standardized line. opts.kinds[k] = {label,color}; opts.formatDetail(rec)
-- returns the per-kind body. The widget owns time/char/location/coords/heading; the addon owns the body.
-- Wrap an item link in its quality color. WoW 12.0 changed loot-link colors to the |cn (color-by-name)
-- format, which capture patterns miss → bare links render white. Strip any color wrapper and re-color
-- from the item's actual quality (mirrors Haul's QualityName). Quality is cache-dependent: a just-looted
-- item is cached (colored); an uncached one stays clickable-but-uncolored until the game caches it.
function lib.ColorItemLink(link)
  if type(link) ~= "string" then return link end
  local bare = link:match("|Hitem:.-|h.-|h")
  if not bare then return link end                       -- not an item link; leave untouched
  local quality = GetItemInfo and select(3, GetItemInfo(link))
  local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
  if q then
    if q.color and q.color.WrapTextInColorCode then return q.color:WrapTextInColorCode(bare) end
    if q.hex then return "|c" .. q.hex .. bare .. "|r" end
  end
  return bare
end

function lib.FormatLine(rec, opts)
  opts = opts or {}
  local kinds = opts.kinds or {}
  local s = "|cff808080" .. (date and date("%m/%d %H:%M:%S", rec.t or 0) or tostring(rec.t or 0)) .. "|r"
  if rec.ch and Store.Display then
    local who = Store.Display("char", rec.ch)          -- single render path (class-colored, GUID-disambiguated)
    if who and who ~= "" then s = s .. "  " .. who end
  end
  local kd = kinds[rec.k]
  local label = kd and kd.label
  if label and label ~= "" then
    s = s .. "  |cff" .. ((kd and kd.color) or "ffffff") .. label .. "|r"
  end
  local detail = opts.formatDetail and opts.formatDetail(rec)
  if detail and detail ~= "" then s = s .. "  " .. detail end
  if rec.p and Store.Display then
    local loc = Store.Display("place", rec.p, { granularity = "detail" })   -- most-specific location, uniform path
    if loc and loc ~= "" then s = s .. "  |cff66ccff" .. loc .. "|r" end
  end
  if rec.x and rec.y then s = s .. " |cff808080(" .. rec.x .. ", " .. rec.y .. ")|r" end
  if rec.h then s = s .. " |cff888888" .. DIRS[(math.floor((rec.h + 22.5) / 45) % 8) + 1] .. " " .. rec.h .. "\194\176|r" end
  return s
end

-- Build the display text (newest-first, kind-filtered, capped) from an oldest-first stream.
-- Returns the joined text and the count of all VISIBLE (post-filter) records.
-- A record is hidden if ANY active filter field's hidden-set contains the record's value for that field.
-- `hidden` is keyed BY FIELD: { k = { <kind>=true }, ch = { <charIdx>=true }, … }. This generalizes the
-- filter bar — each labeled dropdown (Kind, Character, …) owns one field's hidden-set.
local function recHidden(rec, hidden)
  for field, set in pairs(hidden) do
    if set[rec[field]] then return true end
  end
  return false
end

function lib.RenderLines(stream, opts)
  opts = opts or {}
  local hidden = opts.hidden or {}
  local maxLines = opts.maxLines or 500
  local lines, shown = {}, 0
  for i = #stream, 1, -1 do
    local rec = stream[i]
    if not recHidden(rec, hidden) then
      shown = shown + 1
      if shown <= maxLines then lines[#lines + 1] = lib.FormatLine(rec, opts) end
    end
  end
  return table.concat(lines, "\n"), shown
end

-- Expand a stream (oldest-first) into display rows, NEWEST-FIRST, applying the per-field hidden filters and
-- an optional case-insensitive substring SEARCH over o.searchText(rec). This runs over the FULL stream, so
-- search inherently covers the whole log (not just on-screen rows). Returns:
--   rows    — the flat row array (each matched row carries .highlight = true)
--   matches — the row indices (into `rows`) that matched, in display order (for highlight next/prev + count)
-- Modes: "filter" drops non-matching records when a query is active; "highlight" (default) keeps every row
-- and only tags matches. Pure (no frames) so the whole-log search is unit-testable headless.
function lib.BuildRows(stream, o)
  o = o or {}
  local hidden = o.hidden or {}
  local q = (o.query or "")
  local ql = q:lower()
  local cap = o.cap or 200000
  local mode = o.mode or "highlight"
  local filtering = (mode == "filter") and q ~= ""
  local rows, matches = {}, {}
  for i = #stream, 1, -1 do
    local rec = stream[i]
    if not recHidden(rec, hidden) then
      local isMatch = false
      if q ~= "" and o.searchText then
        local txt = o.searchText(rec)
        isMatch = (type(txt) == "string" and txt:lower():find(ql, 1, true)) and true or false
      end
      if not (filtering and not isMatch) then
        local rs = (o.toRows and o.toRows(rec)) or (o.toRow and { o.toRow(rec) }) or nil
        if rs then
          for j = 1, #rs do
            rows[#rows + 1] = rs[j]
            if isMatch then rs[j].highlight = true; matches[#matches + 1] = #rows end
            if #rows >= cap then break end
          end
        end
        if #rows >= cap then break end
      end
    end
  end
  return rows, matches
end

-- ============================ View:Create widget ============================
-- Guard GECTheme so the harness (no CreateFrame/LibStub for GECTheme) doesn't error at load.
local Theme = LibStub and LibStub("GECTheme-1.0", true)

-- Create a log-viewer widget under `parent`. Caller anchors view.frame and calls view:Refresh().
-- opts = { stream=fn, kinds, formatDetail, hidden=table|fn, onToggleKind=fn(k, isHidden), maxLines? }
-- view.frame  — the root Frame to anchor
-- view:Refresh() — re-pulls the stream, re-renders, updates view:Count()
-- view:Count()   — last rendered visible-record count
function lib.Create(parent, opts)
  local view = { opts = opts, _count = 0, _hidden = { k = {}, ch = {} } }

  -- seed the KIND hidden-set from opts.hidden (table or getter) — e.g. SBF's "show actions" -> action kind
  local h0 = type(opts.hidden) == "function" and opts.hidden() or opts.hidden or {}
  for k, v in pairs(h0) do view._hidden.k[k] = v and true or nil end

  local root = CreateFrame("Frame", nil, parent)
  view.frame = root

  -- filter bar — a row of labeled multi-select dropdowns, one per filter FIELD (Character, Kind, …).
  -- Each dropdown owns view._hidden[field]; a record shows only if no field hides its value. New filters
  -- slot in by calling addFilter() with another field + options source — they all work the same way.
  local filterBar = CreateFrame("Frame", nil, root)
  filterBar:SetPoint("TOPLEFT", 0, 0)
  filterBar:SetPoint("TOPRIGHT", 0, 0)
  filterBar:SetHeight(26)   -- room for the WowStyle1 dropdowns so they don't crowd the summary/body below
  view._ddTexts = {}        -- field -> function that refreshes that dropdown's button summary
  local lastAnchor          -- previous dropdown, so the next filter's label anchors to its right

  -- Build one labeled multi-select dropdown for `field`. optionsFn() -> ordered { value, text } list.
  -- Each menu has Select all / Select none, then a checkbox per option (checked = shown).
  local function addFilter(field, label, optionsFn, onToggle)
    view._hidden[field] = view._hidden[field] or {}
    local set = view._hidden[field]
    local lbl = filterBar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    lbl:SetText(label)
    if Theme and Theme.Font then Theme.Font(lbl, "textDim") end
    if lastAnchor then lbl:SetPoint("LEFT", lastAnchor, "RIGHT", 16, 0) else lbl:SetPoint("LEFT", 0, 0) end

    local dd = CreateFrame("DropdownButton", nil, filterBar, "WowStyle1DropdownTemplate")
    if Theme and Theme.SkinDropdown then Theme.SkinDropdown(dd) end
    dd:SetSize(140, 22)
    dd:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    lastAnchor = dd

    local function ddText()
      local o, shown = optionsFn(), 0
      for _, it in ipairs(o) do if not set[it.value] then shown = shown + 1 end end
      return (shown == #o) and "all" or (shown .. " of " .. #o)
    end
    view._ddTexts[field] = function() dd:SetDefaultText(ddText()) end
    dd:SetDefaultText(ddText())

    dd:SetupMenu(function(_dd, menu)
      local o = optionsFn()
      menu:CreateButton("Select all", function()
        for _, it in ipairs(o) do set[it.value] = nil end
        dd:SetDefaultText(ddText()); view:Refresh(); dd:GenerateMenu()
        return MenuResponse and MenuResponse.Refresh
      end)
      menu:CreateButton("Select none", function()
        for _, it in ipairs(o) do set[it.value] = true end
        dd:SetDefaultText(ddText()); view:Refresh(); dd:GenerateMenu()
        return MenuResponse and MenuResponse.Refresh
      end)
      menu:CreateDivider()
      for _, it in ipairs(o) do
        local v = it.value
        menu:CreateCheckbox(it.text,
          function() return not set[v] end,                   -- checked = shown
          function()
            local nowHidden = not set[v]                      -- toggle: shown -> hidden, hidden -> shown
            set[v] = nowHidden or nil
            if onToggle then onToggle(v, nowHidden) end
            dd:SetDefaultText(ddText()); view:Refresh(); dd:GenerateMenu()
          end)
      end
    end)
  end

  -- Character filter (LEFTMOST): characters present in the stream, the CURRENT character pinned topmost.
  -- Store is the module-level GECStore handle (used by FormatLine too).
  local function charOptions()
    local stream = (opts.stream and opts.stream()) or {}
    local present = {}
    for i = 1, #stream do local ch = stream[i].ch; if ch then present[ch] = true end end
    local cur = (Store and Store.CharIndex and Store.CharIndex()) or nil
    local order = {}
    if cur then order[#order + 1] = cur; present[cur] = nil end   -- current character first
    local rest = {}
    for ch in pairs(present) do rest[#rest + 1] = ch end
    table.sort(rest)
    for _, ch in ipairs(rest) do order[#order + 1] = ch end
    local out = {}
    for _, ch in ipairs(order) do
      local info = Store and Store.CharInfo and Store.CharInfo(ch)
      local name = (info and info.name) or ("char " .. ch)
      local cc = info and info.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[info.class]
      out[#out + 1] = { value = ch, text = "|c" .. ((cc and cc.colorStr) or "ffcccccc") .. name .. "|r" }
    end
    return out
  end
  addFilter("ch", "Character", charOptions)

  -- Kind filter: the addon's kinds (badge label, or the kind key when the badge is blank).
  -- opts.kindVisible(k) — optional predicate to hide some kinds from the DROPDOWN itself (not just the log),
  -- so a viewer can collapse a long kind list to its primary set and expand it on demand (evaluated each open).
  local function kindOptions()
    local out = {}
    local vis = opts.kindVisible
    for k, kd in pairs(opts.kinds or {}) do
      if not vis or vis(k) then
        local kindText = (kd.label and kd.label ~= "" and kd.label) or k
        out[#out + 1] = { value = k, text = "|cff" .. (kd.color or "ffffff") .. kindText .. "|r" }
      end
    end
    return out
  end
  addFilter("k", "Kind", kindOptions, opts.onToggleKind)

  -- Search bar (its OWN row below the dropdowns, so it never crowds them). Enabled when the addon supplies
  -- opts.searchText(rec) -> a plain searchable string. A mode toggle picks Highlight (keep all rows, tint +
  -- next/prev jump the matches) vs Filter (show only matches). Search composes (AND) with Kind/Character.
  -- The chosen mode persists via opts.searchMode()/opts.onSearchMode(m) (the addon owns the SavedVariable).
  local searchRowH = 0
  if opts.searchText then
    searchRowH = 26
    view._mode = (opts.searchMode and opts.searchMode()) or "highlight"
    view._query, view._matches, view._active = "", {}, 0

    local sBar = CreateFrame("Frame", nil, root)
    sBar:SetPoint("TOPLEFT", 0, -28); sBar:SetPoint("TOPRIGHT", 0, -28); sBar:SetHeight(24)
    local sLbl = sBar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sLbl:SetPoint("LEFT", 0, 0); sLbl:SetText("Search")
    if Theme and Theme.Font then Theme.Font(sLbl, "textDim") end

    local eb = CreateFrame("EditBox", nil, sBar, "InputBoxTemplate")
    eb:SetAutoFocus(false); eb:SetSize(180, 20)
    eb:SetPoint("LEFT", sLbl, "RIGHT", 10, 0)
    if Theme and Theme.EditBox then Theme.EditBox(eb) end

    local function mkBtn(w, txt) return (Theme and Theme.MakeButton) and Theme.MakeButton(sBar, w, txt) or CreateFrame("Button", nil, sBar) end
    local modeBtn = mkBtn(80, (view._mode == "filter") and "Filter" or "Highlight")
    modeBtn:SetPoint("LEFT", eb, "RIGHT", 10, 0)
    local prevBtn = mkBtn(24, "<"); prevBtn:SetPoint("LEFT", modeBtn, "RIGHT", 10, 0)
    local nextBtn = mkBtn(24, ">"); nextBtn:SetPoint("LEFT", prevBtn, "RIGHT", 3, 0)
    local countLbl = sBar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    countLbl:SetPoint("LEFT", nextBtn, "RIGHT", 10, 0)
    if Theme and Theme.Font then Theme.Font(countLbl, "textDim") end
    prevBtn:Hide(); nextBtn:Hide(); countLbl:Hide()   -- nav appears only in highlight mode with a live query

    view._searchEb, view._modeBtn = eb, modeBtn
    view._prevBtn, view._nextBtn, view._countLbl = prevBtn, nextBtn, countLbl

    -- debounce keystrokes so a big log isn't re-scanned on every character
    local seq = 0
    local function applyQuery(q)
      view._query = q; view._active = q ~= "" and 1 or 0
      view._scrollOnRefresh = (q ~= "")          -- jump to the first match once (highlight mode)
      view:Refresh()
    end
    eb:SetScript("OnTextChanged", function(box, userInput)
      if not userInput then return end
      seq = seq + 1; local my = seq
      local q = (box:GetText() or ""):lower()
      if C_Timer and C_Timer.After then
        C_Timer.After(0.25, function() if my == seq then applyQuery(q) end end)
      else applyQuery(q) end
    end)
    eb:SetScript("OnEscapePressed", function(box) box:SetText(""); box:ClearFocus(); applyQuery("") end)
    eb:SetScript("OnEnterPressed", function() if view._mode == "highlight" then view:SearchNext() end end)

    modeBtn:SetScript("OnClick", function()
      view._mode = (view._mode == "highlight") and "filter" or "highlight"
      if opts.onSearchMode then opts.onSearchMode(view._mode) end
      if modeBtn.text then modeBtn.text:SetText(view._mode == "filter" and "Filter" or "Highlight") end
      view:Refresh()
    end)
    prevBtn:SetScript("OnClick", function() view:SearchPrev() end)
    nextBtn:SetScript("OnClick", function() view:SearchNext() end)
  end

  -- optional summary line (addon-provided text) below the chip row, in the standard dim style.
  -- The addon supplies opts.summary (a function returning the line text); the widget owns placement
  -- so SBF and Haul summaries are styled identically. All offsets shift down by the search row (if present).
  local summaryFS
  local sumY = -(34 + searchRowH)
  local bodyTop = -(34 + searchRowH)   -- clear the taller filter-bar dropdowns (+ the search row when shown)
  if opts.summary then
    summaryFS = root:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    summaryFS:SetPoint("TOPLEFT", 2, sumY)
    summaryFS:SetPoint("TOPRIGHT", -2, sumY)
    summaryFS:SetJustifyH("LEFT")
    if Theme and Theme.Font then Theme.Font(summaryFS, "textDim") end
    bodyTop = -(52 + searchRowH)
  end
  view._summary = summaryFS

  -- scrolling text body below the chip row (and summary, if present)
  local body = CreateFrame("Frame", nil, root)
  body:SetPoint("TOPLEFT", 0, bodyTop)
  body:SetPoint("BOTTOMRIGHT", 0, 0)
  -- BARE ScrollFrame (NO UIPanelScrollFrameTemplate) — the template ships the default arrow+slider
  -- scrollbar, which would double up with the themed one. Theme.AttachScrollBar provides the only
  -- scrollbar (the modern arrow-less MinimalScrollBar), matching SBF's attachPageScroll pattern.
  local sf = CreateFrame("ScrollFrame", nil, body)
  sf:SetPoint("TOPLEFT", 0, 0)
  sf:SetPoint("BOTTOMRIGHT", -18, 0)   -- leave room for the themed bar (anchored at sf TOPRIGHT +4)
  local child = CreateFrame("Frame", nil, sf)
  child:SetSize(1, 1)
  sf:SetScrollChild(child)
  if Theme and Theme.AttachScrollBar then Theme.AttachScrollBar(sf, body) end
  local text = child:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  text:SetPoint("TOPLEFT", 4, -2)
  text:SetJustifyH("LEFT")
  text:SetSpacing(3)
  view._text  = text
  view._child = child
  view._sf    = sf

  -- Columnar mode: when opts.columns is given, render rows through Theme.AccordionList (declarative
  -- per-column layout) instead of the single text body. opts.toRows(rec) -> array of row tables
  -- { cols={key=text,...}, icon, link, onClick } — a record may expand to SEVERAL rows (e.g. a multi-item
  -- catch). opts.toRow(rec) is the single-row shorthand. Filter chips / summary / char filter are unchanged
  -- (they live in the bar above). The AccordionList is VIRTUALIZED: it renders only a viewport-sized window
  -- of row frames and OWNS the ScrollFrame's scroll/size handlers (so we don't install a competing
  -- OnSizeChanged here) — the full filtered log is scrollable without a per-row frame explosion.
  if opts.columns and Theme and Theme.AccordionList then
    text:Hide()
    view._acc = Theme.AccordionList(child, {
      theme = opts.theme or Theme, rowH = opts.rowH or 18, declarative = true, columns = opts.columns,
      overscan = opts.overscan,
    })
    child:SetHyperlinksEnabled(false)
  end

  -- item links in the log get a hover tooltip; the quality color is already carried in the link itself.
  -- Any |Hitem:…|h…|h the addon's formatDetail emits is interactive (hover = tooltip, shift-click = chat).
  child:SetHyperlinksEnabled(true)
  child:SetScript("OnHyperlinkEnter", function(self, link)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
  end)
  child:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
  child:SetScript("OnHyperlinkClick", function(_self, link, linkText, button)
    if SetItemRef then SetItemRef(link, linkText, button) end
  end)

  function view:Count()
    return self._count
  end

  -- Scroll the (virtualized) columnar log so ROW index n is at the top of the viewport. Phase-2 (search)
  -- jumps to a match with this. No-op in text mode or before the list is built.
  function view:ScrollToIndex(n)
    if self._acc and self._acc.ScrollToIndex then self._acc:ScrollToIndex(n) end
  end

  -- refresh the search widgets (mode label + "N of M" counter + next/prev visibility). Counter and nav
  -- show only in HIGHLIGHT mode with a live query (in filter mode the visible rows ARE the matches).
  function view:_syncSearchUI()
    if not self._searchEb then return end
    local hasQuery = self._query and self._query ~= ""
    local nav = (self._mode == "highlight") and hasQuery
    if self._countLbl then
      if nav then
        local n = self._matches and #self._matches or 0
        self._countLbl:SetText((n > 0 and self._active or 0) .. " of " .. n)
        self._countLbl:Show()
      else self._countLbl:Hide() end
    end
    if self._prevBtn then self._prevBtn:SetShown(nav) end
    if self._nextBtn then self._nextBtn:SetShown(nav) end
  end

  -- Highlight-mode next/prev: move the active match, re-tag its tint ("active") and demote the previous one,
  -- then jump-scroll to it. Lighter than a full Refresh — it only re-tags the retained entry tables and
  -- re-windows via ScrollToIndex (no re-scan / re-measure), so it stays snappy on a huge log.
  function view:_gotoMatch(delta)
    local m = self._matches
    if not m or #m == 0 then return end
    local ent = self._acc and self._acc._entries
    if not ent then return end
    local old = m[self._active]
    if old and ent[old] then ent[old].highlight = true end            -- demote previous active to normal tint
    self._active = ((self._active - 1 + delta) % #m) + 1
    local ridx = m[self._active]
    if ent[ridx] then ent[ridx].highlight = "active" end
    self._acc:ScrollToIndex(ridx)                                     -- re-windows, re-reads highlight
    self:_syncSearchUI()
  end
  function view:SearchNext() self:_gotoMatch(1) end
  function view:SearchPrev() self:_gotoMatch(-1) end

  function view:Refresh()
    local stream = (opts.stream and opts.stream()) or {}
    if self._acc then
      -- columnar (VIRTUALIZED): expand every visible record into one or more rows; the list windows its row
      -- frames so the whole set is scrollable. BuildRows also applies the whole-log SEARCH (filter/highlight)
      -- and returns the matched row indices.
      -- Cap: honor the addon's DISPLAY cap (opts.maxLines) when there's NO active search, so "show N" limits
      -- the list to the newest N rows (still virtualized/scrollable). During a search we scan the FULL log
      -- (safety cap only) so whole-log search reaches matches older than the display cap.
      local hasQuery = self._query and self._query ~= ""
      local safety = opts.safetyCap or 200000
      local cap = (not hasQuery and opts.maxLines) and math.min(opts.maxLines, safety) or safety
      local rows, matches = lib.BuildRows(stream, {
        hidden = self._hidden, cap = cap,
        query = self._query, mode = self._mode, searchText = opts.searchText,
        toRows = opts.toRows, toRow = opts.toRow,
      })
      -- mark the currently-focused match with the stronger "active" tint (highlight-mode next/prev target)
      self._matches = matches
      if #matches > 0 then
        self._active = math.max(1, math.min(self._active or 1, #matches))
        if rows[matches[self._active]] then rows[matches[self._active]].highlight = "active" end
      else
        self._active = 0
      end
      self._count = #rows
      self._child:SetWidth(self._sf:GetWidth())
      self._acc:SetEntries(rows)
      if self._ddTexts then for _, fn in pairs(self._ddTexts) do fn() end end
      if self._summary then self._summary:SetText((opts.summary and opts.summary()) or "") end
      self:_syncSearchUI()
      -- on a fresh query (highlight mode), jump to the first match once the scroll range is current
      if self._scrollOnRefresh and self._mode == "highlight" and #matches > 0 then
        self._scrollOnRefresh = false
        local target = matches[self._active]
        if C_Timer and C_Timer.After then C_Timer.After(0, function() self:ScrollToIndex(target) end)
        else self:ScrollToIndex(target) end
      end
      return
    end
    local bodyText, shown = lib.RenderLines(stream, {
      kinds        = opts.kinds,
      formatDetail = opts.formatDetail,
      hidden       = self._hidden,
      maxLines     = opts.maxLines,
    })
    self._count = shown
    if self._ddTexts then for _, fn in pairs(self._ddTexts) do fn() end end
    if self._summary then self._summary:SetText((opts.summary and opts.summary()) or "") end
    self._text:SetWidth(math.max(1, self._sf:GetWidth() - 8))
    self._text:SetText(bodyText ~= "" and bodyText or "|cff808080(no entries)|r")
    -- Size the scroll child to the text. GetStringHeight can be STALE right after SetText (WoW lays the
    -- fontstring out at render), which left the LAST line clipped/unscrollable — so set the height now AND
    -- once more next frame when it's current. Extra bottom pad (16) gives the final line breathing room.
    local function fit() self._child:SetHeight(math.max(10, math.ceil(self._text:GetStringHeight() or 10) + 16)) end
    fit()
    if C_Timer then C_Timer.After(0, fit) end
  end

  return view
end

return lib
