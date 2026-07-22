-- GECTheme-1.0 — shared look-and-feel for Goblin Engineering Company WoW addons.
-- Two layers, decoupled: a semantic PALETTE (the only place raw colors live) and structure-only
-- FIXTURES that read colors from the palette by name. Drop in a different palette -> same layouts,
-- new colors.
local MAJOR, MINOR = "GECTheme-1.0", 15
local Theme = LibStub:NewLibrary(MAJOR, MINOR)
if not Theme then return end   -- a newer copy is already loaded

-- ============================ palette (semantic tokens) ============================
Theme.colors = {
  panelBg        = { 0.05, 0.055, 0.07, 1 },
  panelBorder    = { 0.24, 0.26, 0.32, 1 },
  headerBg       = { 0.12, 0.12, 0.14, 1 },
  bodyBg         = { 0.07, 0.075, 0.09, 1 },
  pausedHeaderBg = { 0.26, 0.06, 0.06, 1 },
  pausedBodyBg   = { 0.18, 0.05, 0.05, 1 },
  slotFill           = { 0, 0, 0, 0.6 },
  slotBorder         = { 0.38, 0.41, 0.49, 1 },
  slotFillSelected   = { 0.16, 0.13, 0, 0.7 },
  slotBorderSelected = { 1, 0.82, 0, 1 },
  tabAccent     = { 1, 0.82, 0, 1 },
  tabTextActive = { 1, 0.93, 0.74 },
  tabTextIdle   = { 0.58, 0.58, 0.58 },
  tabActiveBg   = { 1, 1, 1, 0.07 },
  tabHoverBg    = { 1, 1, 1, 0.05 },
  tabSep        = { 1, 1, 1, 0.10 },
  divider       = { 1, 1, 1, 0.08 },
  headerBand    = { 1, 1, 1, 0.04 },

  -- accordion group-header tokens (collapsible bucket bars in a list). Alpha-white overlays so they read
  -- as a raised clickable bar on ANY preset's body bg without needing per-preset tuning; a preset can
  -- still override them for a custom tone. accordionHeader = resting fill, accordionHeaderHover = hover.
  accordionHeader      = { 1, 1, 1, 0.06 },
  accordionHeaderHover = { 1, 1, 1, 0.11 },

  -- row-highlight tokens for the virtualized flat list (search/match highlighting is a Phase-2 consumer;
  -- the renderer just honors entry.highlight). rowHighlight = a matched row's soft tint;
  -- rowHighlightActive = the current/active match (stronger). Absent entry.highlight = no tint.
  rowHighlight       = { 1, 0.82, 0, 0.14 },
  rowHighlightActive = { 1, 0.82, 0, 0.32 },

  -- button widget tokens
  buttonBg       = { 0.10, 0.11, 0.14, 1 },
  buttonBorder   = { 0.30, 0.33, 0.40, 1 },
  buttonText     = { 0.86, 0.87, 0.92, 1 },
  buttonHover    = { 0.16, 0.18, 0.23, 1 },
  buttonPressed  = { 0.04, 0.05, 0.07, 1 },
  buttonDisabled = { 0.45, 0.45, 0.50, 1 },
  buttonHighlight = { 1, 1, 1, 0.08 },           -- hover overlay (use a DARK one for light themes)

  -- dropdown widget tokens
  dropdownBg     = { 0.10, 0.11, 0.14, 1 },
  dropdownBorder = { 0.30, 0.33, 0.40, 1 },
  dropdownText   = { 0.86, 0.87, 0.92, 1 },
  dropdownArrow  = { 0.66, 0.70, 0.80, 1 },

  -- checkbox widget tokens
  checkboxBg     = { 0.04, 0.05, 0.07, 1 },
  checkboxBorder = { 0.30, 0.33, 0.40, 1 },
  checkboxCheck  = { 1, 0.82, 0, 1 },

  -- editbox widget tokens
  editboxBg      = { 0, 0, 0, 0.5 },
  editboxBorder  = { 0.30, 0.33, 0.40, 1 },
  editboxText    = { 1, 1, 1, 1 },

  -- close-X + arrow tokens
  closeColor     = { 0.66, 0.70, 0.80, 1 },
  closeHover     = { 0.96, 0.97, 1, 1 },   -- bright white-grey on hover (not the gold accent)
  arrowTint      = { 0.66, 0.70, 0.80, 1 },

  -- label text tokens (apply to fontstrings via Theme.Font(fs, role)) — light on dark presets;
  -- light presets override these to dark so labels stay readable.
  text     = { 0.86, 0.88, 0.93, 1 },   -- primary labels / body
  textDim  = { 0.62, 0.65, 0.72, 1 },   -- secondary / small captions
  textMuted= { 0.46, 0.48, 0.55, 1 },   -- hints / disabled

  -- content/list panel: for INTENTIONAL scrollable lists & inset boxes (item list, JSON box, …) so they
  -- read as their own element, separate from the page bg. (Page/overflow scrolls don't use this.)
  contentBg     = { 0, 0, 0, 0.25 },    -- own fill (set per-preset; e.g. WoW can go solid black)
  contentBorder = { 0.42, 0.42, 0.45, 1 },
}
Theme.accentHex = "ffd100"

-- Standard spacing — every fixture + Theme.Columns reads these so whitespace is consistent and tunable
-- from one place.
Theme.metrics = {
  pad        = 14,   -- content inset from the window's inner edge
  rowH       = 22,   -- nominal row / control height (checkbox, dropdown, button)
  rowGap     = 8,    -- vertical gap between rows
  labelGap   = 8,    -- gap between a label and its control
  colGap     = 14,   -- gap between columns
  sectionTop = 16,   -- space above a section header
  sectionBot = 8,    -- space below a section header (to first row)
  indent     = 10,   -- how far section CONTENT is indented under its (left-edge) header
}
Theme.metrics.rowPitch    = Theme.metrics.rowH + Theme.metrics.rowGap   -- 30: row baseline-to-baseline
-- Box layout engine tokens (GECTheme-Box.lua). All spacing the engine reads lives here so nothing is
-- hardcoded: sectionHeaderH = reserved height of a section's title-line + underline block; wrapGap =
-- vertical gap between wrapped rows in a `wrap` row; align/justify = the flexbox defaults a box inherits.
Theme.metrics.sectionHeaderH = 16
Theme.metrics.wrapGap        = Theme.metrics.rowGap
Theme.metrics.noteMaxW       = 320  -- default max wrap width for a `note` paragraph (unless it sets maxWidth):
                                    -- caps a note to a readable column in wide/unbounded contexts so it wraps
                                    -- + reserves height instead of overrunning / inflating the window.
Theme.metrics.align          = "stretch"
Theme.metrics.justify        = "start"
Theme.SLIDER_TOP_PAD = 12   -- MinimalSliderWithSteppers: visible track sits ~12px below the frame top

Theme.FONT   = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
Theme.STRATA = { "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
Theme.PANEL_BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 },
}
Theme.SLOT_BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 2, insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

-- ============================ named colors + utilities ============================
Theme.NAMED_COLORS = {
  white = "ffffff", red = "ff6060", green = "1eff00", blue = "66ccff",
  gold = "ffd100", yellow = "ffd100", purple = "a335ee", gray = "808080",
  grey = "808080", orange = "eda55f", teal = "45c4a0",
}
function Theme.ColorToHex(input)
  if type(input) ~= "string" then return nil end
  local s = input:lower():gsub("%s", "")
  return Theme.NAMED_COLORS[s] or (s:match("^%x%x%x%x%x%x$") and s) or nil
end
local HEX_TO_NAME = {}
for nm, hx in pairs(Theme.NAMED_COLORS) do HEX_TO_NAME[hx] = HEX_TO_NAME[hx] or nm end
HEX_TO_NAME["ffffff"] = "white"; HEX_TO_NAME["808080"] = "gray"; HEX_TO_NAME["ffd100"] = "gold"
function Theme.ColorName(hex)
  hex = tostring(hex or "ffffff"):lower()
  return HEX_TO_NAME[hex] or hex
end
function Theme.HexToRGB(hex)
  hex = tostring(hex or "ffffff"):gsub("^|cff", ""):gsub("|r", "")
  local r = tonumber(hex:sub(1, 2), 16) or 255
  local g = tonumber(hex:sub(3, 4), 16) or 255
  local b = tonumber(hex:sub(5, 6), 16) or 255
  return r / 255, g / 255, b / 255
end

-- ============================ scrollbar fixture ============================
function Theme.AttachScrollBar(sf, barParent)
  sf:EnableMouseWheel(true)
  sf:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 40)))
  end)
  local bar = CreateFrame("EventFrame", nil, barParent or sf:GetParent(), "MinimalScrollBar")
  bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 4, -2); bar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 4, 2)
  if bar.SetHideIfUnscrollable then bar:SetHideIfUnscrollable(true) end
  local function refresh()
    local range = sf:GetVerticalScrollRange() or 0
    local vis = sf:GetHeight() or 1
    local total = vis + range
    if bar.SetVisibleExtentPercentage then bar:SetVisibleExtentPercentage(total > 0 and vis / total or 1) end
    if bar.SetScrollPercentage then bar:SetScrollPercentage(range > 0 and (sf:GetVerticalScroll() / range) or 0) end
    if bar.Update then bar:Update() end
    -- explicit auto-hide: the bar is parented to the scrollframe's PARENT (to dodge ScrollFrame
    -- clipping), so it must be hidden by hand when the frame is hidden (a collapsed/empty list) or
    -- the content fits (range ~0) — SetHideIfUnscrollable alone leaves a stranded bar otherwise.
    bar:SetShown(sf:IsShown() and range > 1)
  end
  if bar.RegisterCallback then
    bar:RegisterCallback("OnScroll", function(_, pct)
      sf:SetVerticalScroll((pct or 0) * (sf:GetVerticalScrollRange() or 0))
    end, sf)
  end
  sf:HookScript("OnVerticalScroll", refresh); sf:HookScript("OnScrollRangeChanged", refresh)
  sf:HookScript("OnShow", refresh); sf:HookScript("OnHide", function() bar:Hide() end)
  sf.RefreshScrollBar = refresh; sf.modernBar = bar
  return bar
end

-- ============================ tab strip fixture ============================
function Theme.TabStrip(parent, x, y, defs, onSelect)
  local c = Theme.colors
  -- Capture at build so a later paint()/hover can't read ANOTHER addon's active palette. Theme.colors
  -- is one shared table whose fields SetTokens reassigns on each per-addon preset activation, so a
  -- deferred read of c.tabTextActive would return whichever addon last touched its theme handle (the
  -- "Haul tabs randomly turn Gadgets-purple" bug). Same technique as Theme.Slot above.
  local cTextActive, cTextIdle = c.tabTextActive, c.tabTextIdle
  local cActiveBgA, cHoverBgA  = c.tabActiveBg[4], c.tabHoverBg[4]
  local TAB_H, TAB_GAP, TAB_PADX = 30, 2, 18
  local tabs, current = {}, nil
  local sep = parent:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(unpack(c.tabSep)); sep:SetHeight(1)
  local function paint()
    for _, t in ipairs(tabs) do
      local on = (t.key == current)
      if on then t.txt:SetTextColor(unpack(cTextActive)) else t.txt:SetTextColor(unpack(cTextIdle)) end
      t.under:SetShown(on)
      t.bg:SetAlpha(on and cActiveBgA or 0)
    end
  end
  local function setActive(key) current = key; paint() end
  local prev
  for _, d in ipairs(defs) do
    local b = CreateFrame("Button", nil, parent)
    b.key = d.key
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints()
    b.bg:SetColorTexture(c.tabActiveBg[1], c.tabActiveBg[2], c.tabActiveBg[3], 1); b.bg:SetAlpha(0)
    b.txt = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.txt:SetPoint("CENTER", 0, 1); b.txt:SetText(d.label)
    b.under = b:CreateTexture(nil, "OVERLAY"); b.under:SetColorTexture(unpack(c.tabAccent))
    b.under:SetPoint("BOTTOMLEFT", 5, 0); b.under:SetPoint("BOTTOMRIGHT", -5, 0); b.under:SetHeight(2); b.under:Hide()
    b:SetSize(math.max(64, b.txt:GetStringWidth() + TAB_PADX * 2), TAB_H)
    if prev then b:SetPoint("LEFT", prev, "RIGHT", TAB_GAP, 0) else b:SetPoint("TOPLEFT", x, y) end
    b:SetScript("OnClick", function() if onSelect then onSelect(d.key) end end)
    b:SetScript("OnEnter", function(self) if self.key ~= current then self.bg:SetAlpha(cHoverBgA) end end)
    b:SetScript("OnLeave", paint)
    tabs[#tabs + 1] = b; prev = b
  end
  sep:SetPoint("TOPLEFT", tabs[1], "BOTTOMLEFT", 0, 0)
  sep:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -12, 0)
  paint()
  return setActive
end

-- ============================ panel + header fixtures ============================
local function resolveColor(v, fallback)
  if type(v) == "table" then return v end
  if type(v) == "string" and Theme.colors[v] then return Theme.colors[v] end
  return fallback
end
function Theme.Panel(frame, opts)
  opts = opts or {}
  frame:SetBackdrop(Theme.PANEL_BACKDROP)
  local bg = resolveColor(opts.bg, Theme.colors.panelBg)
  local bd = resolveColor(opts.border, Theme.colors.panelBorder)
  local a = opts.alpha or bg[4] or 1
  local ba = opts.borderAlpha or bd[4] or 1
  frame:SetBackdropColor(bg[1], bg[2], bg[3], a)
  frame:SetBackdropBorderColor(bd[1], bd[2], bd[3], ba)
  return frame
end
-- Theme.ContentPanel(frame, opts) — give an INTENTIONAL list / inset box (a scroll list, JSON box, …)
-- its own contentBg + contentBorder, drawn as a backdrop sibling just behind `frame` so it works even
-- on a bare ScrollFrame. opts.bg/opts.border override the tokens (table or token name). Idempotent;
-- returns the backdrop frame (its color follows the palette at build, so it re-themes on /reload).
function Theme.ContentPanel(frame, opts)
  opts = opts or {}
  local fill = resolveColor(opts.bg, Theme.colors.contentBg)
  local bd   = resolveColor(opts.border, Theme.colors.contentBorder)
  -- If the frame is a BackdropTemplate, paint it DIRECTLY so the fill sits behind its own (scrolled)
  -- content and can't be covered by a parent's fill. Otherwise drop a backdrop sibling just behind it.
  if frame.SetBackdrop then
    frame:SetBackdrop(Theme.PANEL_BACKDROP)
    frame:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
    frame:SetBackdropBorderColor(bd[1], bd[2], bd[3], bd[4] or 1)
    return frame
  end
  if frame._jgcontent then return frame._jgcontent end
  local bg = CreateFrame("Frame", nil, frame:GetParent() or frame, "BackdropTemplate")
  bg:SetPoint("TOPLEFT", frame, "TOPLEFT", -2, 2)
  bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -2)
  bg:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
  bg:SetBackdrop(Theme.PANEL_BACKDROP)
  bg:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
  bg:SetBackdropBorderColor(bd[1], bd[2], bd[3], bd[4] or 1)
  frame._jgcontent = bg
  return bg
end

-- Theme.SectionHeader(parent, x, y, text, opts) — a standalone section header (accent title + underline)
-- for layouts NOT on Theme.Columns. opts: desc (trailing plain text), lineW (underline width, default 180).
-- Returns the header fontstring + the underline texture.
function Theme.SectionHeader(parent, x, y, text, opts)
  opts = opts or {}
  local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  fs:SetPoint("TOPLEFT", x, y); fs:SetJustifyH("LEFT"); fs:SetText(Theme.Accent(text) .. (opts.desc or ""))
  Theme.Font(fs, "text")
  local line = parent:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 1, 1, 0.12); line:SetHeight(1)
  line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3); line:SetWidth(opts.lineW or 180)
  return fs, line
end

-- ============================ responsive column layout ============================
-- Theme.Columns(page, opts) — a 2-column layout bound to `page` (a scroll child / content frame).
-- Registers content into a left/right column, reflows to a split fraction on the page's OnSizeChanged
-- (capping each label to its column so long labels WRAP instead of bleeding), and derives the window's
-- min width from the widest real labels so it shrinks to fit but never stomps text. opts: split(0.5),
-- labelCap(210), floorW(560), leftX/colGap/labelGap/rightMargin (default from Theme.metrics), cbW(24).
--
function Theme.Columns(page, opts)
  opts = opts or {}
  local M = Theme.metrics
  local split       = opts.split or 0.5
  local labelCap    = opts.labelCap or 210
  local floorW      = opts.floorW or 560
  local leftX       = opts.leftX or M.pad
  local colGap      = opts.colGap or M.colGap
  local labelGap    = opts.labelGap or M.labelGap
  local rightMargin = opts.rightMargin or M.pad
  local cbW         = opts.cbW or 24
  local rightWidth  = opts.rightWidth   -- if set, RIGHT-anchor the right column (fixed px width) instead of
                                        -- a percentage split, so it stays glued to the right edge on resize

  local mgr = { page = page }
  local items, coupled = {}, {}       -- items: {control,label,lz,side,y,isCheck}; coupled: {frame,y}
  local widestLeft, widestRight = 0, 0

  local function reflow()
    local pw = page:GetWidth(); if not pw or pw <= 0 then return end
    -- rightWidth set => right column right-anchored (pw - margin - width); else percentage split
    local rightX = rightWidth and math.floor(pw - rightMargin - rightWidth) or math.floor(pw * split)
    for _, it in ipairs(items) do
      local colX = (it.side == "right") and rightX or leftX
      local x = (it.header and (colX - M.indent) or colX) + (it.xoff or 0)   -- xoff = extra indent (sub-rows)
      it.control:ClearAllPoints(); it.control:SetPoint("TOPLEFT", x, it.y)
      local limit = (it.side == "right") and (pw - rightMargin) or (rightX - colGap)
      if it.header and it.line then
        it.line:ClearAllPoints(); it.line:SetPoint("TOPLEFT", it.control, "BOTTOMLEFT", 0, -3)
        it.line:SetWidth(math.max(40, it.lineW or (limit - x)))
      end
      if it.label then
        local lblLeft = x + (it.isCheck and (cbW + 2) or 0)
        local w = math.max(60, limit - lblLeft - labelGap)
        it.label:SetWidth(w); it.label:SetJustifyH("LEFT")   -- capped labels stay LEFT (else they centre)
        if it.lz then it.lz:SetWidth(w) end
      end
    end
    for _, c in ipairs(coupled) do
      c.frame:ClearAllPoints(); c.frame:SetPoint("TOPLEFT", rightX, c.y)
    end
  end
  mgr.Reflow = reflow

  local function track(side, label)
    if not label or not label.GetStringWidth then return end
    local sw = math.min(labelCap, label:GetStringWidth() or 0)
    if side == "right" then widestRight = math.max(widestRight, sw)
    else widestLeft = math.max(widestLeft, sw) end
  end
  local function asSide(side)
    if type(side) == "number" then return (side >= 200) and "right" or "left" end
    return side or "left"
  end

  -- a checkbox + wrapping label, vertically centred on the label text (LEFT->RIGHT anchoring). Returns
  -- the checkbox, the label fontstring, and a mouse "label zone" (so a tooltip can cover the whole row).
  function mgr:Check(side, y, label, get, set, xoff)
    side = asSide(side)
    local cb = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    cb:SetSize(cbW, cbW); cb:SetChecked(get and get() or false)
    if set then cb:SetScript("OnClick", function(s) set(s:GetChecked() and true or false) end) end
    Theme.Checkbox(cb)
    local f = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f:SetPoint("LEFT", cb, "RIGHT", 2, 0); f:SetJustifyH("LEFT"); f:SetText(label or "")
    Theme.Font(f, "text")
    local lz = CreateFrame("Frame", nil, page); lz:EnableMouse(true)
    lz:SetPoint("LEFT", cb, "RIGHT", 2, 0); lz:SetHeight(cbW)
    items[#items + 1] = { control = cb, label = f, lz = lz, side = side, y = y, isCheck = true, xoff = xoff }
    track(side, f); reflow()
    return cb, f, lz
  end

  -- a SECTION HEADER (accent text + underline) at the column's LEFT edge. Content placed via Place/Check
  -- sits indented (Theme.metrics.indent) under it. Returns the header fontstring. opts.lineW overrides the
  -- underline width (default = the column's room).
  function mgr:Header(side, text, y, ho)
    ho = ho or {}
    side = asSide(side)
    local fs = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetJustifyH("LEFT"); fs:SetText(Theme.Accent(text) .. (ho.desc or ""))
    Theme.Font(fs, "text")   -- base colour for any trailing plain description (accent part keeps its code)
    local line = page:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.12); line:SetHeight(1)
    items[#items + 1] = { control = fs, side = side, y = y, header = true, line = line, lineW = ho.lineW }
    reflow()
    return fs
  end

  -- a tightly-coupled group (a label+control that belong together); its LEFT edge tracks the split.
  function mgr:Couple(frame, y) coupled[#coupled + 1] = { frame = frame, y = y }; reflow(); return frame end

  -- any frame + its (optional) label dropped into a column — the disassociated-columns case. If `frame`
  -- itself is a fontstring it is both the control and the (width-capped) label.
  -- Place a frame at a column's x (TOPLEFT, y). Pass `labelFS` ONLY to width-cap a wrapping text block to
  -- the column (it then word-wraps); omit it for short labels/headers and for any label that has a control
  -- anchored to its RIGHT (capping would stretch that edge to the column's far side). labelFS also feeds
  -- the min-width.
  function mgr:Place(side, frame, y, labelFS, xoff)
    side = asSide(side)
    items[#items + 1] = { control = frame, label = labelFS, side = side, y = y, isCheck = false, xoff = xoff }
    if labelFS then track(side, labelFS) end
    reflow()
    return frame
  end

  -- derive window:SetResizeBounds from the content: WIDTH from the widest real labels per column, HEIGHT
  -- from the lowest registered item + chrome — so the window shrinks to fit but never clips text in
  -- either axis. mo: chromeH (header+tabs+padding above/below the page, default 0), contentBottom
  -- (override the auto bottom), lastRowH (allowance for the lowest item's height, default rowH),
  -- floorH (min height floor), panelVsPage (width insets+scrollbar, default 42). Widens/heightens the
  -- window if it's currently smaller than the derived minimum so nothing clips.
  function mgr:ApplyMinSize(window, mo)
    mo = mo or {}
    local needLeft  = 2 * (leftX + cbW + 2 + labelGap + widestLeft + colGap)
    local needRight = 2 * (cbW + 2 + labelGap + widestRight + rightMargin)
    local panelMin = math.ceil(math.max(floorW, math.max(needLeft, needRight) + (mo.panelVsPage or 42)))
    local lowest = 0
    for _, it in ipairs(items) do if it.y < lowest then lowest = it.y end end
    for _, c in ipairs(coupled) do if c.y < lowest then lowest = c.y end end
    local contentBottom = mo.contentBottom or (-lowest + (mo.lastRowH or M.rowH) + M.pad)
    local hMin = math.ceil(math.max(mo.floorH or 0, contentBottom + (mo.chromeH or 0)))
    if window.SetResizeBounds then window:SetResizeBounds(panelMin, hMin)
    elseif window.SetMinResize then window:SetMinResize(panelMin, hMin) end
    if (window:GetWidth() or 0) < panelMin then window:SetWidth(panelMin) end
    if (window:GetHeight() or 0) < hMin then window:SetHeight(hMin) end
    mgr._panelMin, mgr._panelMinH = panelMin, hMin
    return panelMin, hMin
  end
  mgr.ApplyMinWidth = mgr.ApplyMinSize   -- back-compat alias (now derives height too)

  page:HookScript("OnSizeChanged", reflow)
  if C_Timer and C_Timer.After then C_Timer.After(0, reflow) end
  return mgr
end

function Theme.Header(frame, height)
  local band = frame:CreateTexture(nil, "ARTWORK")
  band:SetPoint("TOPLEFT", 1, -1); band:SetPoint("TOPRIGHT", -1, -1); band:SetHeight(height or 34)
  band:SetColorTexture(unpack(Theme.colors.headerBand))
  return band
end

-- Theme.CloseButton(parent, onClick) -> a themed close button: a navy square (like the buttons) with a
-- centered × glyph and a white-brighten hover. Caller positions it with :SetPoint.
function Theme.CloseButton(parent, onClick)
  local col = Theme.colors
  -- capture colors at build (correct addon palette active) so hover handlers can't read another addon's
  local closeC, hoverC, bgC, bhoverC, borderC = col.closeColor, col.closeHover, col.buttonBg, col.buttonHover, col.buttonBorder
  local btn = CreateFrame("Button", nil, parent)
  btn:SetSize(20, 20)
  local cbg = CreateFrame("Frame", nil, btn, "BackdropTemplate")
  cbg:SetAllPoints(); cbg:SetFrameLevel(math.max(0, btn:GetFrameLevel() - 1))
  cbg:SetBackdrop(Theme.PANEL_BACKDROP)
  cbg:SetBackdropColor(unpack(bgC))
  cbg:SetBackdropBorderColor(unpack(borderC))
  local fs = btn:CreateFontString(nil, "OVERLAY")
  fs:SetFont(Theme.FONT, 20, "")
  fs:SetPoint("CENTER", -1, -1)   -- the × glyph renders up-right of the anchor; pull it to center
  fs:SetText("×")
  pcall(function() fs:SetTextColor(unpack(closeC)) end)
  if onClick then btn:SetScript("OnClick", onClick) end
  btn:SetScript("OnEnter", function()
    pcall(function() fs:SetTextColor(unpack(hoverC)) end)
    pcall(function() cbg:SetBackdropColor(unpack(bhoverC)) end)
  end)
  btn:SetScript("OnLeave", function()
    pcall(function() fs:SetTextColor(unpack(closeC)) end)
    pcall(function() cbg:SetBackdropColor(unpack(bgC)) end)
  end)
  return btn
end

-- ============================ window fixture (the standard window) ============================
-- A complete movable window: navy panel skin + header band/title + close button, drag-move, optional
-- resize (grip), optional collapse (title-click), an optional close-veto guard, and pos/size/collapsed
-- persistence. The consumer fills `content` (everything that should hide on collapse parents to it).
--   opts: name, title, width, height, minWidth, minHeight,
--         resizable=true, collapsible=true, specialFrame=false, strata="MEDIUM",
--         savedKey=<table>, alpha=<number>, borderAlpha=<number>, closeGuard=function()->bool, onResize=function(window)
-- Returns: window, content.  Methods: window:SetCollapsed(b)/RequestClose()/ForceClose()/ApplyAlpha(a)/ApplyBorderAlpha(a).
function Theme.Window(opts)
  opts = opts or {}
  local saved = opts.savedKey or {}
  local HEADER_H = 34
  local f = CreateFrame("Frame", opts.name, UIParent, "BackdropTemplate")
  f:SetFrameStrata(opts.strata or "MEDIUM")
  f:SetToplevel(true)
  f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
  Theme.Panel(f, { alpha = opts.alpha or saved.bgAlpha, borderAlpha = opts.borderAlpha or saved.borderAlpha })
  Theme.Header(f, HEADER_H)

  if opts.title then
    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("LEFT", 14, 0); title:SetPoint("TOP", 0, -8); title:SetText(opts.title)
    pcall(function() title:SetTextColor(Theme.HexToRGB(Theme.accentHex)) end)   -- title follows the accent
    f.titleFS = title
  end

  -- content child: everything the consumer adds parents here (so collapse hides it as a unit)
  local content = CreateFrame("Frame", nil, f)
  content:SetPoint("TOPLEFT", 1, -HEADER_H)
  content:SetPoint("BOTTOMRIGHT", -1, 1)
  f.content = content

  -- restore the saved size, but never below the resize floor (a previously-saved too-small size,
  -- or a raised minWidth/minHeight, snaps up so fixed-layout content can't overflow on load).
  f:SetSize(math.max((saved.winSize and saved.winSize.w) or opts.width or 560, opts.minWidth or 0),
            math.max((saved.winSize and saved.winSize.h) or opts.height or 480, opts.minHeight or 0))

  -- Persist by the TOP-LEFT corner (the standard for movable windows) — store the frame's left/top in
  -- UIParent space and re-anchor TOPLEFT → UIParent BOTTOMLEFT. Robust across whatever anchor GetPoint
  -- hands back after a drag; the old {point,rel,x,y} form could restore to the wrong spot on /reload.
  local function savePos()
    local l, t = f:GetLeft(), f:GetTop()
    if l and t then saved.winPos = { left = l, top = t } end
  end
  local function applyPos()
    f:ClearAllPoints()
    local wp = saved.winPos
    if wp and wp.left and wp.top then
      f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", wp.left, wp.top)
    elseif wp and wp.point then                       -- migrate the old {point,rel,x,y} form
      f:SetPoint(wp.point, UIParent, wp.rel or wp.point, wp.x or 0, wp.y or 0)
    else
      f:SetPoint("CENTER")
    end
  end
  applyPos()

  -- header band drag-to-move (leaves room for the close button on the right)
  local hdr = CreateFrame("Button", nil, f)
  hdr:SetPoint("TOPLEFT", 2, -2); hdr:SetPoint("TOPRIGHT", -28, -2); hdr:SetHeight(HEADER_H - 4)
  hdr:RegisterForDrag("LeftButton")
  hdr:SetScript("OnDragStart", function() f:StartMoving() end)
  hdr:SetScript("OnDragStop", function() f:StopMovingOrSizing(); savePos() end)

  -- close button + veto interface
  f._forceHide = false
  function f:RequestClose()
    if opts.closeGuard and not opts.closeGuard() then return end
    self:ForceClose()
  end
  function f:ForceClose() self._forceHide = true; self:Hide(); self._forceHide = false end
  f:SetScript("OnHide", function(self)
    if opts.closeGuard and not self._forceHide and not opts.closeGuard() then self:Show() end
  end)

  -- Themed close button (navy square + centered × glyph), centered in the header band.
  local closeBtn = Theme.CloseButton(f, function() f:RequestClose() end)
  closeBtn:SetPoint("TOPRIGHT", -6, -6)
  f.closeBtn = closeBtn

  -- resize grip (bottom-right)
  local grip
  if opts.resizable ~= false then
    f:SetResizable(true)
    local minW, minH = opts.minWidth or 320, opts.minHeight or 200
    if f.SetResizeBounds then f:SetResizeBounds(minW, minH)
    elseif f.SetMinResize then f:SetMinResize(minW, minH) end
    grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
      f:StopMovingOrSizing()
      if not saved.collapsed then saved.winSize = { w = f:GetWidth(), h = f:GetHeight() } end
      savePos()
      if opts.onResize then opts.onResize(f) end
    end)
    f.grip = grip
  end
  if opts.onResize then f:SetScript("OnSizeChanged", function() opts.onResize(f) end) end

  -- collapse / expand (click the header band)
  if opts.collapsible ~= false then
    function f:SetCollapsed(v)
      v = v and true or false
      -- COMBAT SAFETY (opt-in via opts.deferCollapseInCombat): this toggles content:SetShown, and when the
      -- window HOSTS SECURE frames (e.g. a SecureActionButton in the content), showing/hiding an ancestor of a
      -- protected frame is BLOCKED in combat — it aborts this method after ClearAllPoints ran, leaving a
      -- broken half-drawn window that persists. So a window that declares it hosts secure content defers the
      -- whole toggle to the instant combat ends (applies the LAST requested state). See the GEC secure-action
      -- doctrine: never drive a protected-affecting op in combat.
      if opts.deferCollapseInCombat and InCombatLockdown() then
        f._pendingCollapsed = v
        if not f._collapseWaiter then
          f._collapseWaiter = CreateFrame("Frame")
          f._collapseWaiter:SetScript("OnEvent", function(wf)
            wf:UnregisterEvent("PLAYER_REGEN_ENABLED"); f._collapseWaiter = nil
            if f._pendingCollapsed ~= nil then local pv = f._pendingCollapsed; f._pendingCollapsed = nil; f:SetCollapsed(pv) end
          end)
        end
        f._collapseWaiter:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
      end
      local l, t = f:GetLeft(), f:GetTop()
      if l and t then f:ClearAllPoints(); f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t) end
      content:SetShown(not v)
      if grip then grip:SetShown(not v) end
      if v then
        if not saved.collapsed then saved.winSize = { w = f:GetWidth(), h = f:GetHeight() } end
        f:SetResizable(false); f:SetHeight(HEADER_H)
      else
        f:SetResizable(opts.resizable ~= false)
        f:SetHeight((saved.winSize and saved.winSize.h) or opts.height or 480)
      end
      saved.collapsed = v
      savePos()
    end
    hdr:SetScript("OnClick", function() f:SetCollapsed(not saved.collapsed) end)
    hdr:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Click to collapse / expand"); GameTooltip:Show()
    end)
    hdr:SetScript("OnLeave", GameTooltip_Hide)
  end

  if opts.specialFrame and opts.name then tinsert(UISpecialFrames, opts.name) end

  -- Optional open/closed persistence (opts.persistShown). Remembers whether the window was
  -- shown across /reload and full relogs by stashing a `shown` flag in the saved table, so a
  -- window the user left open returns to that state instead of vanishing. Opt-in so the many
  -- transient Theme.Window users (popups, feed browsers) are unaffected.
  --   f.wantShown       — the state captured at build time (what to restore to)
  --   f:RestoreShown()  — call once after the consumer finishes building: applies wantShown
  --                       and arms the OnShow/OnHide tracking. SetShown() runs BEFORE tracking
  --                       is armed so the restore itself can't clobber the saved value.
  if opts.persistShown then
    f.wantShown = saved.shown and true or false
    f._trackShown = false
    function f:RestoreShown()
      self:SetShown(self.wantShown)
      self._trackShown = true
    end
    f:HookScript("OnShow", function(self) if self._trackShown then saved.shown = true end end)
    f:HookScript("OnHide", function(self) if self._trackShown then saved.shown = false end end)
  end

  function f:ApplyAlpha(a)
    if a ~= nil then saved.bgAlpha = a end
    Theme.Panel(f, { alpha = saved.bgAlpha, borderAlpha = saved.borderAlpha })
  end
  function f:ApplyBorderAlpha(a)
    if a ~= nil then saved.borderAlpha = a end
    Theme.Panel(f, { alpha = saved.bgAlpha, borderAlpha = saved.borderAlpha })
  end

  f:HookScript("OnShow", function(self) self:Raise() end)
  return f, content
end

-- ============================ slot + button fixtures ============================
function Theme.Slot(b)
  local c = Theme.colors
  -- capture at build so a later SetSelected can't read another addon's active palette
  local fillSel, borderSel, fill, border = c.slotFillSelected, c.slotBorderSelected, c.slotFill, c.slotBorder
  b:SetBackdrop(Theme.SLOT_BACKDROP)
  local function apply(on)
    if on then
      b:SetBackdropColor(unpack(fillSel))
      b:SetBackdropBorderColor(unpack(borderSel))
    else
      b:SetBackdropColor(unpack(fill))
      b:SetBackdropBorderColor(unpack(border))
    end
  end
  apply(false)
  b.SetSelected = function(_, on) apply(on) end
  return b
end

-- Theme.Button(b) — full flat-skin for any button (UIPanelButtonTemplate or bare).
-- Strips Blizzard textures, draws a navy backdrop child, hooks hover/press/disable states.
-- Idempotent: re-calling on the same button is a no-op.
function Theme.Button(b)
  if b._jgbg then return b end   -- already skinned

  -- Strip all Blizzard default button regions (pcall so a missing region can't break anything)
  pcall(function()
    local regions = {
      b.Left, b.Middle, b.Right, b.Center,
      b.LeftSeparator, b.RightSeparator,
    }
    for _, r in ipairs(regions) do
      if r and r.SetAlpha then r:SetAlpha(0) end
    end
  end)
  pcall(function()
    local nt = b:GetNormalTexture()
    if nt then nt:SetAlpha(0) end
  end)
  pcall(function()
    local pt = b:GetPushedTexture()
    if pt then pt:SetAlpha(0) end
  end)
  pcall(function()
    local ht = b:GetHighlightTexture()
    if ht then ht:SetAlpha(0) end
  end)
  pcall(function()
    local dt = b:GetDisabledTexture()
    if dt then dt:SetAlpha(0) end
  end)

  -- Navy backdrop child (drawn just below the button label layer)
  local bg = CreateFrame("Frame", nil, b, "BackdropTemplate")
  bg:SetAllPoints()
  bg:SetFrameLevel(math.max(0, b:GetFrameLevel() - 1))
  bg:SetBackdrop(Theme.PANEL_BACKDROP)
  b._jgbg = bg

  local c = Theme.colors
  bg:SetBackdropColor(unpack(c.buttonBg))
  bg:SetBackdropBorderColor(unpack(c.buttonBorder))
  -- Capture deferred-paint colors at build (correct addon palette active) so the OnEnable/OnDisable
  -- repaint below can't read ANOTHER addon's active palette — the shared-Theme.colors cross-addon bug
  -- (same reason Theme.Slot / TabStrip / the dropdown capture at build).
  local bBg, bBorder, bText, bDisabled = c.buttonBg, c.buttonBorder, c.buttonText, c.buttonDisabled

  -- Hover via a NATIVE highlight texture, NOT OnEnter/OnMouseDown HookScripts. CRITICAL for taint:
  -- hook handlers run DURING the click, tainting it — so a button that triggers a protected action
  -- (e.g. Haul's Options button -> Settings.OpenToCategory) would fail with "interface action failed
  -- because of an add-on". A highlight texture is Blizzard-native and taint-free.
  pcall(function()
    b:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
    local hl = b:GetHighlightTexture()
    if hl then hl:SetVertexColor(unpack(Theme.colors.buttonHighlight)) end
  end)

  -- Pin the font across states. UIPanelButtonTemplate carries SEPARATE normal/highlight/disabled font
  -- objects and re-applies the matching one on hover/enable/disable — which silently swaps the glyph SIZE
  -- away from whatever the caller set on the fontstring (so hovered buttons grow, un-hovered stay small,
  -- looking random). Force highlight + disabled to equal the NORMAL font object so the label size never
  -- changes on state. Callers that want a smaller label set it via b:SetNormalFontObject(...) BEFORE this.
  pcall(function()
    local nfo = b.GetNormalFontObject and b:GetNormalFontObject()
    if nfo then
      if b.SetHighlightFontObject then b:SetHighlightFontObject(nfo) end
      if b.SetDisabledFontObject then b:SetDisabledFontObject(nfo) end
    end
  end)

  -- Enabled/disabled paint. A disabled button clearly recedes: the WHOLE button (backdrop, border, label)
  -- fades to 40% opacity and the label greys to `buttonDisabled`, so :Disable()/:SetEnabled(false) reads as
  -- unmistakably inactive (e.g. a Save button with nothing to save). The opacity fade is the dominant cue —
  -- a subtle backdrop-only tint was invisible on dark presets. Colors are captured at build (above) so a
  -- deferred repaint uses THIS addon's palette, not whichever addon last activated its theme. The
  -- OnEnable/OnDisable hooks fire from SetEnabled, NOT during click dispatch, so they're taint-safe
  -- (unlike the OnEnter/OnMouseDown hooks the highlight texture above deliberately avoids).
  local function labelFS()
    local fs = b.GetFontString and b:GetFontString()
    return fs or b.text
  end
  b._jgPaint = function()
    local enabled = (b.IsEnabled == nil) or b:IsEnabled()
    bg:SetBackdropColor(unpack(bBg))
    bg:SetBackdropBorderColor(unpack(bBorder))
    b:SetAlpha(enabled and 1 or 0.4)   -- whole-button fade: the unmistakable "inactive" cue
    pcall(function()
      local fs = labelFS()
      if fs then fs:SetTextColor(unpack(enabled and bText or bDisabled)) end
    end)
  end
  b:HookScript("OnEnable", b._jgPaint)
  b:HookScript("OnDisable", b._jgPaint)
  b._jgPaint()   -- initial paint matches the button's current enabled state

  return b
end

-- Theme.MakeButton(parent, width, text, onClick) -> a flat navy button (no Blizzard template).
function Theme.MakeButton(parent, width, text, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width or 80, 22)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.text:SetPoint("CENTER")
  b.text:SetText(text or "")
  b.GetFontString = function(self) return self.text end
  if onClick then b:SetScript("OnClick", onClick) end
  Theme.Button(b)
  return b
end

-- ============================ checkbox fixture ============================
-- Theme.Checkbox(c) — skin a UICheckButtonTemplate checkbox to flat navy.
-- Keeps the check glyph but recolors it gold; hides the default box textures.
-- Idempotent, pcall-guarded. Returns c.
function Theme.Checkbox(c)
  if c._jgcb then return c end   -- already skinned
  c._jgcb = true

  local col = Theme.colors

  -- Hide the default box textures (the square that Blizzard draws)
  pcall(function()
    local nt = c:GetNormalTexture()
    if nt then nt:SetAlpha(0) end
  end)
  pcall(function()
    local pt = c:GetPushedTexture()
    if pt then pt:SetAlpha(0) end
  end)
  pcall(function()
    local ht = c:GetHighlightTexture()
    if ht then ht:SetAlpha(0) end
  end)
  -- Named region variants (some templates expose these directly)
  pcall(function()
    local regions = { c.Background, c.CheckedTexture }
    for _, r in ipairs(regions) do
      if r and r ~= c:GetCheckedTexture() and r.SetAlpha then r:SetAlpha(0) end
    end
  end)

  -- Flat navy box — a bit SMALLER than the hit area (Blizzard's box read smaller too), vertically
  -- centered via the LEFT anchor.
  local bg = CreateFrame("Frame", nil, c, "BackdropTemplate")
  local sz = 16
  bg:SetSize(sz, sz)
  bg:SetPoint("LEFT", c, "LEFT", 2, 0)
  bg:SetFrameLevel(math.max(0, c:GetFrameLevel() - 1))
  bg:SetBackdrop(Theme.PANEL_BACKDROP)
  bg:SetBackdropColor(col.checkboxBg[1], col.checkboxBg[2], col.checkboxBg[3], col.checkboxBg[4] or 1)
  bg:SetBackdropBorderColor(col.checkboxBorder[1], col.checkboxBorder[2], col.checkboxBorder[3], col.checkboxBorder[4] or 1)
  c._jgcbbg = bg

  -- Tint the check glyph gold + size it onto the smaller box.
  pcall(function()
    local ct = c:GetCheckedTexture()
    if ct then
      ct:SetVertexColor(unpack(col.checkboxCheck))
      ct:ClearAllPoints(); ct:SetPoint("CENTER", bg, "CENTER", 0, 0); ct:SetSize(sz + 4, sz + 4)
    end
  end)

  return c
end

-- ============================ editbox fixture ============================
-- Theme.EditBox(e) — skin an editbox to flat navy.
-- Hides default border regions, adds a backdrop child.
-- Idempotent, pcall-guarded. Returns e.
function Theme.EditBox(e)
  if e._jgeb then return e end   -- already skinned
  e._jgeb = true

  local col = Theme.colors

  -- Hide default border/bg region textures (InputBoxTemplate exposes Left/Middle/Right)
  pcall(function()
    local regions = { e.Left, e.Middle, e.Right, e.Background }
    for _, r in ipairs(regions) do
      if r and r.SetAlpha then r:SetAlpha(0) end
    end
  end)
  -- Also try _G-name lookups for older templates that use global names
  pcall(function()
    local n = e:GetName()
    if n then
      local candidates = { n.."Left", n.."Middle", n.."Right", n.."Background" }
      for _, gn in ipairs(candidates) do
        local r = _G[gn]
        if r and r.SetAlpha then r:SetAlpha(0) end
      end
    end
  end)

  -- Flat navy backdrop child
  local bg = CreateFrame("Frame", nil, e, "BackdropTemplate")
  bg:SetPoint("TOPLEFT", e, "TOPLEFT", -2, 0)
  bg:SetPoint("BOTTOMRIGHT", e, "BOTTOMRIGHT", 2, 0)
  bg:SetFrameLevel(math.max(0, e:GetFrameLevel() - 1))
  bg:SetBackdrop(Theme.PANEL_BACKDROP)
  bg:SetBackdropColor(col.editboxBg[1], col.editboxBg[2], col.editboxBg[3], col.editboxBg[4] or 0.5)
  bg:SetBackdropBorderColor(col.editboxBorder[1], col.editboxBorder[2], col.editboxBorder[3], col.editboxBorder[4] or 1)
  e._jgebg = bg

  -- Text color
  pcall(function() e:SetTextColor(unpack(col.editboxText)) end)

  return e
end

-- Theme.MultilineEditBox(parent, opts) -> scrollFrame, editBox
-- The ONE scrollable multiline copy/output/template box for all our addons, built on WoW's native
-- InputScrollFrameTemplate. This is the fix for the long-standing "click won't position the cursor /
-- focus is gained but no cursor shows and the arrows are dead" bug: our old hand-rolled ScrollFrame +
-- content-sized editbox entered a dead focus state whenever a visible row had no text (empty rows, or the
-- space below short content) — on the desktop AND scaled clients (Steam Deck). The native widget doesn't.
-- Caller anchors the returned scrollFrame (and sets its height, or anchors its BOTTOM). opts (all optional):
--   onChanged(editbox, userInput) — OnTextChanged hook (hooked, so the template's own sizing still runs)
--   font       — font object name (default "ChatFontNormal")
--   insets     — text insets px (default 4)
--   maxLetters — default 0 (unlimited)
--   panel      — themed ContentPanel border/bg behind it (default true; pass false for bare native)
--   rightPad   — px kept clear on the right (scrollbar) when matching the editbox width (default 8)
--   name       — optional frame name
-- Caller sets the box height (or anchors its BOTTOM); for a capped box use a fixed N-line height and the
-- native widget scrolls once content overflows.
function Theme.MultilineEditBox(parent, opts)
  opts = opts or {}
  local sf = CreateFrame("ScrollFrame", opts.name, parent, "InputScrollFrameTemplate")
  local eb = sf.EditBox
  eb:SetFontObject(opts.font or "ChatFontNormal")
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(opts.maxLetters or 0)
  local ins = opts.insets or 4
  eb:SetTextInsets(ins, ins, ins, ins)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  if sf.CharCount then sf.CharCount:Hide() end
  pcall(function() if eb.Instructions then eb.Instructions:Hide() end end)
  pcall(function() eb:SetTextColor(unpack(Theme.colors.editboxText)) end)
  if opts.onChanged then
    eb:HookScript("OnTextChanged", function(self, userInput) opts.onChanged(self, userInput) end)
  end
  -- keep the editbox width matched to the scroll frame so text wraps + hit-tests across the full width
  local pad = opts.rightPad or 8
  local function fit() local w = sf:GetWidth() or 0; if w > 0 then eb:SetWidth(math.max(10, w - pad)) end end
  sf:HookScript("OnSizeChanged", fit); sf:HookScript("OnShow", fit); fit()
  if opts.panel ~= false and Theme.ContentPanel then Theme.ContentPanel(sf) end
  return sf, eb
end

-- ============================ dropdown fixture ============================
-- Theme.Dropdown(parent, opts) — create and skin a modern WowStyle1 dropdown.
-- opts: { width, options, get, set }
--   options = array of { value, label } or { value, text }
--   get() -> current value; set(value) -> called on selection.
-- Returns the DropdownButton frame (position it with :SetPoint).
-- NOTE: WowStyle1DropdownTemplate field names (Arrow/Text/Background) are guessed from
-- inspection of retail frame XML; they are pcall-guarded so a wrong name can't error.
-- Theme.SkinDropdown(dd) — apply ONLY the navy skin to an existing WowStyle1Dropdown (no menu setup),
-- so addons that build their own menu (with MarkDirty etc.) still get the look. pcall-guarded.
function Theme.SkinDropdown(dd)
  if not dd then return dd end
  -- navy wrapper: a backdrop CHILD (a DropdownButton isn't a BackdropTemplate frame, so SetBackdrop on
  -- it silently no-ops) — gives the visible box + border so it reads as a control, like the buttons.
  if not dd._jgdd then
    local bg = CreateFrame("Frame", nil, dd, "BackdropTemplate")
    bg:SetAllPoints()
    bg:SetFrameLevel(math.max(0, dd:GetFrameLevel() - 1))
    bg:SetBackdrop(Theme.PANEL_BACKDROP)
    bg:SetBackdropColor(unpack(Theme.colors.dropdownBg))
    bg:SetBackdropBorderColor(unpack(Theme.colors.dropdownBorder))
    dd._jgdd = bg
  end
  -- Re-apply on a hook + next frame: the template re-colors its Arrow/Text during setup/show. The arrow
  -- is a gold atlas (square + chevron), desaturate then tint it with dropdownArrow. Capture colors NOW
  -- (build time, correct addon palette active) so a deferred OnShow can't read another addon's palette.
  local arrowCol, textCol = Theme.colors.dropdownArrow, Theme.colors.dropdownText
  local function reskin()
    pcall(function()
      if dd.Arrow then dd.Arrow:SetDesaturated(true); dd.Arrow:SetVertexColor(unpack(arrowCol)) end
      if dd.Background then dd.Background:SetAlpha(0) end
      if dd.Text then dd.Text:SetTextColor(unpack(textCol)) end
    end)
  end
  reskin()
  if not dd._jgddhook then
    dd._jgddhook = true
    dd:HookScript("OnShow", reskin)
    if C_Timer and C_Timer.After then C_Timer.After(0, reskin) end
  end
  return dd
end

function Theme.Dropdown(parent, opts)
  opts = opts or {}
  local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  dd:SetWidth(opts.width or 160)
  Theme.SkinDropdown(dd)

  -- Build the menu
  dd:SetupMenu(function(_, root)
    for _, o in ipairs(opts.options or {}) do
      local label = o.label or o.text or tostring(o.value)
      root:CreateRadio(label,
        function() return opts.get and opts.get() == o.value end,
        function() if opts.set then opts.set(o.value) end end)
    end
  end)

  -- Refresh helper: regenerates the menu (useful after opts.options changes)
  dd.Refresh = function()
    if dd.GenerateMenu then
      pcall(function() dd:GenerateMenu() end)
    end
  end

  return dd
end

-- ============================ theme selector (drop-in palette picker) ============================
-- A ready-made dropdown that lists every palette (Theme.PresetList) and, on pick, persists the choice
-- via setPreset() and ReloadUI()s to apply it. Skinned like the rest of the kit. Position the returned
-- dropdown with :SetPoint. opts: { width=200, label=nil } (if label is given, a header is anchored above).
-- Most callers use the bound form from a ForAddon handle: Theme.ThemeSelector(parent, { label = "Theme" }).
function Theme.ThemeSelector(parent, getPreset, setPreset, opts)
  opts = opts or {}
  local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  dd:SetSize(opts.width or 200, 22)
  dd:SetupMenu(function(_, root)
    for _, p in ipairs(Theme.PresetList) do
      root:CreateRadio(p.label,
        function() return ((getPreset and getPreset()) or "default") == p.key end,
        function() if setPreset then setPreset(p.key) end; if ReloadUI then ReloadUI() end end)
    end
  end)
  Theme.SkinDropdown(dd)
  if opts.label then
    local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    lbl:SetText(Theme.Accent(opts.label))
    lbl:SetPoint("BOTTOMLEFT", dd, "TOPLEFT", 0, 3)
    dd.label = lbl
  end
  return dd
end

-- ============================ arrow tint helper ============================
-- Recolor a gold/Blizzard arrow (or any texture) to the theme's arrowTint. pcall-safe.
function Theme.TintArrow(tex)
  if tex and tex.SetVertexColor then
    pcall(function() tex:SetVertexColor(unpack(Theme.colors.arrowTint)) end)
  end
  return tex
end

-- Theme.SkinSlider(s) — desaturate + tint the gold thumb and the </> steppers of an existing
-- MinimalSliderWithSteppersTemplate (re-applied on show + next frame, since the template re-colors).
function Theme.SkinSlider(s)
  if not s then return s end
  local tintCol = Theme.colors.sliderTint or Theme.colors.dropdownArrow   -- capture at build (own token, falls back to the dropdown arrow)
  local function reskin()
    pcall(function()
      local sl = s.Slider or s
      local thumb = sl.GetThumbTexture and sl:GetThumbTexture()
      if thumb then thumb:SetDesaturated(true); thumb:SetVertexColor(unpack(tintCol)) end
      for _, b in ipairs({ s.Back, s.Forward }) do
        if b and b.GetRegions then
          for _, rg in ipairs({ b:GetRegions() }) do
            if rg.SetDesaturated then rg:SetDesaturated(true) end
            if rg.SetVertexColor then rg:SetVertexColor(unpack(tintCol)) end
          end
        end
      end
    end)
  end
  reskin()
  if not s._jgskhook then
    s._jgskhook = true
    s:HookScript("OnShow", reskin)
    if C_Timer and C_Timer.After then C_Timer.After(0, reskin) end
  end
  return s
end

-- ============================ slider fixture ============================
-- Modern stepper slider (MinimalSliderWithSteppersTemplate). The label + value readout stay with the
-- caller (their placement varies per layout). opts: name, width, min, max, steps, value, onChange(v).
-- Returns the slider frame (position it with :SetPoint). Guarded so an API mismatch can't break a page.
function Theme.Slider(parent, opts)
  opts = opts or {}
  local s = CreateFrame("Frame", opts.name, parent, "MinimalSliderWithSteppersTemplate")
  s:SetWidth(opts.width or 190)
  pcall(function()
    s:Init(opts.value or 0, opts.min or 0, opts.max or 1, opts.steps or 20, {})
    s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, v)
      if opts.onChange then opts.onChange(v) end
    end, s)
  end)

  Theme.SkinSlider(s)
  return s
end

-- ============================ palette presets (theme swap) ============================
-- The palette is the single config surface: change the active preset (load-time) and EVERY fixture
-- in EVERY addon re-skins on the next /reload. Our original navy is snapshotted as "default" so it's
-- never lost. SetTokens reassigns token fields (Theme.colors itself is never replaced, so held refs
-- stay valid). Source for the alternate scheme: Gruvbox — github.com/morhetz/gruvbox.
Theme.presets = { default = { accentHex = Theme.accentHex } }
for k, v in pairs(Theme.colors) do Theme.presets.default[k] = v end

-- SetTokens applies overrides; the special "accentHex" key (the gold for titles/highlights) sets
-- Theme.accentHex so the accent swaps with the rest of the palette.
function Theme.SetTokens(overrides)
  for k, v in pairs(overrides or {}) do
    if k == "accentHex" then Theme.accentHex = v else Theme.colors[k] = v end
  end
end

function Theme.UsePreset(name)
  name = name or "default"
  local p = Theme.presets[name]; if not p then return end
  Theme.SetTokens(Theme.presets.default)   -- reset every token (incl. accentHex) to default
  Theme.SetTokens(p)                        -- then apply this preset's overrides
  Theme._active = name
end

-- Per-addon palette. The shared Theme.colors is one table, so to give each addon an INDEPENDENT
-- palette we wrap the lib: every access through the returned handle first activates that addon's
-- preset (cheap; skipped if already active), so whenever an addon builds a frame it uses ITS palette.
-- Usage in each addon file: local Theme = LibStub("GECTheme-1.0").ForAddon(function() return MyDB.themePreset end)
function Theme.ForAddon(presetGetter, presetSetter)
  local function activate()
    local want = (presetGetter and presetGetter()) or "default"
    if Theme._active ~= want then Theme.UsePreset(want) end
  end
  return setmetatable({}, { __index = function(_, k)
    if k == "ThemeSelector" then
      -- a fully self-contained palette selector bound to THIS addon's get/set: drop it in any UI
      -- with Theme.ThemeSelector(parent, opts) and position the returned dropdown with :SetPoint.
      return function(parent, o) activate(); return Theme.ThemeSelector(parent, presetGetter, presetSetter, o) end
    end
    activate()
    local v = Theme[k]
    if type(v) == "function" then
      return function(...) activate(); return v(...) end   -- re-activate at call time too
    end
    return v
  end })
end

-- Wrap text in the configurable accent color (gold by default) so titles/highlights follow the theme.
-- Addons should use this (or "|cff"..Theme.accentHex) instead of a hardcoded "|cffffd100".
function Theme.Accent(text) return "|cff" .. (Theme.accentHex or "ffd100") .. tostring(text) .. "|r" end

-- Theme.Font(fs, role) — color a fontstring from the palette so plain labels follow the theme (esp.
-- needed for light presets, where Blizzard's white/yellow fonts are unreadable). role: "text" (default,
-- primary labels), "textDim" (small/secondary), "textMuted" (hints). Returns fs. Leave SEMANTIC text
-- (item-quality names, money g/s/c, accent headers via Theme.Accent) alone — those carry meaning.
function Theme.Font(fs, role)
  if not fs or not fs.SetTextColor then return fs end
  local col = Theme.colors[role or "text"] or Theme.colors.text
  pcall(function() fs:SetTextColor(unpack(col)) end)
  return fs
end

-- Gruvbox (retro warm) — a deliberately different scheme to prove the swap.
Theme.presets.gruvbox = {
  accentHex = "fabd2f",                          -- yellow (titles/highlights)
  panelBg        = { 0.157, 0.157, 0.157, 1 },   -- bg0  #282828
  panelBorder    = { 0.400, 0.361, 0.329, 1 },   -- bg3  #665c54
  headerBg       = { 0.114, 0.125, 0.129, 1 },   -- bg0_h #1d2021
  bodyBg         = { 0.235, 0.220, 0.212, 1 },   -- bg1  #3c3836
  pausedHeaderBg = { 0.27, 0.09, 0.07, 1 },      -- red-tinted
  pausedBodyBg   = { 0.18, 0.06, 0.05, 1 },
  slotFill           = { 0, 0, 0, 0.5 },
  slotBorder         = { 0.400, 0.361, 0.329, 1 },
  slotFillSelected   = { 0.20, 0.15, 0.03, 0.7 },
  slotBorderSelected = { 0.980, 0.741, 0.184, 1 },  -- yellow #fabd2f
  tabAccent     = { 0.980, 0.741, 0.184, 1 },       -- yellow #fabd2f
  tabTextActive = { 0.984, 0.945, 0.780, 1 },       -- fg0 #fbf1c7
  tabTextIdle   = { 0.659, 0.600, 0.518, 1 },       -- fg4 #a89984
  buttonBg       = { 0.235, 0.220, 0.212, 1 },
  buttonBorder   = { 0.400, 0.361, 0.329, 1 },
  buttonText     = { 0.922, 0.859, 0.698, 1 },      -- fg1 #ebdbb2
  buttonHover    = { 0.314, 0.286, 0.271, 1 },      -- bg2 #504945
  buttonPressed  = { 0.114, 0.125, 0.129, 1 },
  buttonDisabled = { 0.659, 0.600, 0.518, 1 },
  dropdownBg     = { 0.235, 0.220, 0.212, 1 },
  dropdownBorder = { 0.400, 0.361, 0.329, 1 },
  dropdownText   = { 0.922, 0.859, 0.698, 1 },
  dropdownArrow  = { 0.741, 0.682, 0.576, 1 },      -- fg3 #bdae93
  checkboxBg     = { 0.114, 0.125, 0.129, 1 },
  checkboxBorder = { 0.400, 0.361, 0.329, 1 },
  checkboxCheck  = { 0.980, 0.741, 0.184, 1 },
  editboxBg      = { 0, 0, 0, 0.4 },
  editboxBorder  = { 0.400, 0.361, 0.329, 1 },
  editboxText    = { 0.984, 0.945, 0.780, 1 },
  closeColor     = { 0.741, 0.682, 0.576, 1 },
  closeHover     = { 0.984, 0.945, 0.780, 1 },
  arrowTint      = { 0.741, 0.682, 0.576, 1 },
  contentBg = { 0.114, 0.125, 0.129, 1 }, contentBorder = { 0.40, 0.36, 0.33, 1 },   -- list/inset = bg0_h (darker), warm frame
}

-- ---- Solarized Dark — ethanschoonover.com/solarized ----
Theme.presets["solarized-dark"] = {
  accentHex = "b58900",                          -- solarized yellow
  panelBg        = { 0.000, 0.169, 0.212, 1 },   -- base03 #002b36
  panelBorder    = { 0.15, 0.34, 0.40, 1 },
  headerBg       = { 0.027, 0.212, 0.259, 1 },   -- base02 #073642
  bodyBg         = { 0.015, 0.190, 0.235, 1 },
  pausedHeaderBg = { 0.30, 0.10, 0.09, 1 },
  pausedBodyBg   = { 0.22, 0.07, 0.06, 1 },
  slotFill           = { 0, 0, 0, 0.4 },
  slotBorder         = { 0.15, 0.34, 0.40, 1 },
  slotFillSelected   = { 0.20, 0.15, 0.00, 0.6 },
  slotBorderSelected = { 0.710, 0.537, 0.000, 1 },   -- yellow #b58900
  tabAccent     = { 0.710, 0.537, 0.000, 1 },
  tabTextActive = { 0.933, 0.910, 0.835, 1 },        -- base2 #eee8d5
  tabTextIdle   = { 0.345, 0.431, 0.459, 1 },        -- base01 #586e75
  buttonBg       = { 0.027, 0.212, 0.259, 1 },
  buttonBorder   = { 0.15, 0.34, 0.40, 1 },
  buttonText     = { 0.576, 0.631, 0.631, 1 },       -- base1 #93a1a1
  buttonHover    = { 0.05, 0.27, 0.32, 1 },
  buttonPressed  = { 0.000, 0.169, 0.212, 1 },
  buttonDisabled = { 0.345, 0.431, 0.459, 1 },
  buttonHighlight = { 1, 1, 1, 0.07 },
  dropdownBg     = { 0.027, 0.212, 0.259, 1 },
  dropdownBorder = { 0.15, 0.34, 0.40, 1 },
  dropdownText   = { 0.576, 0.631, 0.631, 1 },
  dropdownArrow  = { 0.514, 0.580, 0.588, 1 },       -- base0 #839496
  checkboxBg     = { 0.000, 0.169, 0.212, 1 },
  checkboxBorder = { 0.15, 0.34, 0.40, 1 },
  checkboxCheck  = { 0.710, 0.537, 0.000, 1 },
  editboxBg      = { 0, 0, 0, 0.3 },
  editboxBorder  = { 0.15, 0.34, 0.40, 1 },
  editboxText    = { 0.576, 0.631, 0.631, 1 },
  closeColor     = { 0.514, 0.580, 0.588, 1 },
  closeHover     = { 0.933, 0.910, 0.835, 1 },
  arrowTint      = { 0.514, 0.580, 0.588, 1 },
}

-- ---- Solarized Light — ethanschoonover.com/solarized. A true LIGHT theme: the white-alpha overlays
-- flip to DARK and widget text goes dark. NOTE: general Blizzard label fonts (GameFontHighlight=white,
-- GameFontNormal=yellow) are NOT palette-controlled yet, so some plain labels read low-contrast on the
-- light panels until text tokens are added. ----
Theme.presets["solarized-light"] = {
  accentHex = "268bd2",                              -- solarized BLUE (the signature accent)
  text      = { 0.345, 0.431, 0.459, 1 },            -- base01 (dark labels, readable on cream)
  textDim   = { 0.396, 0.482, 0.514, 1 },            -- base00
  textMuted = { 0.514, 0.580, 0.588, 1 },            -- base0
  panelBg        = { 0.992, 0.965, 0.890, 1 },       -- base3  #fdf6e3
  panelBorder    = { 0.514, 0.580, 0.588, 1 },       -- base0  #839496
  headerBg       = { 0.933, 0.910, 0.835, 1 },       -- base2  #eee8d5
  bodyBg         = { 0.972, 0.949, 0.871, 1 },        -- between base3/base2
  pausedHeaderBg = { 0.863, 0.196, 0.184, 1 },        -- red    #dc322f
  pausedBodyBg   = { 0.760, 0.180, 0.165, 1 },
  slotFill           = { 0, 0, 0, 0.05 },
  slotBorder         = { 0.576, 0.631, 0.631, 1 },    -- base1  #93a1a1
  slotFillSelected   = { 0.149, 0.545, 0.824, 0.18 }, -- blue wash
  slotBorderSelected = { 0.149, 0.545, 0.824, 1 },    -- blue   #268bd2
  tabAccent     = { 0.149, 0.545, 0.824, 1 },         -- blue
  tabTextActive = { 0.027, 0.212, 0.259, 1 },         -- base02 #073642 (strong dark)
  tabTextIdle   = { 0.345, 0.431, 0.459, 1 },         -- base01 #586e75
  tabActiveBg   = { 0, 0, 0, 0.05 },                  -- DARK overlays for a light bg
  tabHoverBg    = { 0, 0, 0, 0.03 },
  tabSep        = { 0, 0, 0, 0.12 },
  divider       = { 0, 0, 0, 0.10 },
  headerBand    = { 0, 0, 0, 0.03 },
  buttonBg       = { 0.933, 0.910, 0.835, 1 },        -- base2
  buttonBorder   = { 0.514, 0.580, 0.588, 1 },        -- base0
  buttonText     = { 0.027, 0.212, 0.259, 1 },        -- base02 (strong dark text)
  buttonHover    = { 0.882, 0.851, 0.760, 1 },
  buttonPressed  = { 0.835, 0.800, 0.706, 1 },
  buttonDisabled = { 0.576, 0.631, 0.631, 1 },
  buttonHighlight = { 0, 0, 0, 0.07 },                -- DARK hover on light buttons
  dropdownBg     = { 0.933, 0.910, 0.835, 1 },
  dropdownBorder = { 0.514, 0.580, 0.588, 1 },
  dropdownText   = { 0.027, 0.212, 0.259, 1 },        -- base02
  dropdownArrow  = { 0.149, 0.545, 0.824, 1 },        -- blue arrow
  checkboxBg     = { 0.992, 0.965, 0.890, 1 },
  checkboxBorder = { 0.514, 0.580, 0.588, 1 },
  checkboxCheck  = { 0.149, 0.545, 0.824, 1 },        -- blue check
  editboxBg      = { 1, 1, 1, 0.55 },
  editboxBorder  = { 0.514, 0.580, 0.588, 1 },
  editboxText    = { 0.027, 0.212, 0.259, 1 },        -- base02 dark text
  closeColor     = { 0.396, 0.482, 0.514, 1 },        -- base00
  closeHover     = { 0.149, 0.545, 0.824, 1 },        -- blue
  arrowTint      = { 0.149, 0.545, 0.824, 1 },
}

-- ---- WoW Default — dark + gold/tan, so the addon blends with Blizzard's own UI / options screen ----
-- WoW Default: BLACK panels/widgets with GRAY box borders + gold text/arrows/accents. The accent RED
-- is reserved for the buttons. The outer window frame stays gold; widget boxes (dropdowns/checks/edit/
-- slots) are gray-edged; dropdown down-arrow + checkmarks are gold; slider arrows are gray.
Theme.presets.wow = {
  accentHex = "ffd100",                                 -- Blizzard gold (titles/highlights)
  panelBg = { 0.045, 0.045, 0.052, 1 }, panelBorder = { 1, 0.82, 0, 1 },   -- outer frame stays gold
  headerBg = { 0.075, 0.072, 0.075, 1 }, bodyBg = { 0.055, 0.052, 0.056, 1 },
  pausedHeaderBg = { 0.34, 0.05, 0.05, 1 }, pausedBodyBg = { 0.24, 0.04, 0.04, 1 },
  slotFill = { 0, 0, 0, 0.5 }, slotBorder = { 0.52, 0.52, 0.55, 1 },        -- gray box wrap
  slotFillSelected = { 0.45, 0.08, 0.08, 0.8 }, slotBorderSelected = { 1, 0.82, 0, 1 },
  tabAccent = { 1, 0.82, 0, 1 }, tabTextActive = { 1, 0.82, 0, 1 }, tabTextIdle = { 0.62, 0.62, 0.66, 1 },  -- gray idle tabs
  buttonBg = { 0.42, 0.07, 0.07, 1 }, buttonBorder = { 0.52, 0.52, 0.55, 1 }, buttonText = { 1, 0.82, 0, 1 },
  buttonHover = { 0.58, 0.11, 0.11, 1 }, buttonPressed = { 0.30, 0.05, 0.05, 1 }, buttonDisabled = { 0.55, 0.42, 0.42, 1 },
  buttonHighlight = { 1, 0.82, 0, 0.15 },
  dropdownBg = { 0.060, 0.060, 0.070, 1 }, dropdownBorder = { 0.52, 0.52, 0.55, 1 },   -- gray box wrap
  dropdownText = { 1, 0.82, 0, 1 }, dropdownArrow = { 1, 0.82, 0, 1 },                 -- arrow = gold
  sliderTint = { 0.62, 0.62, 0.65, 1 },                                               -- slider arrows = gray
  checkboxBg = { 0.045, 0.045, 0.052, 1 }, checkboxBorder = { 0.52, 0.52, 0.55, 1 }, checkboxCheck = { 1, 0.82, 0, 1 },
  editboxBg = { 0, 0, 0, 0.6 }, editboxBorder = { 0.52, 0.52, 0.55, 1 }, editboxText = { 1, 1, 1, 1 },   -- bright white input
  closeColor = { 1, 0.82, 0, 1 }, closeHover = { 1, 1, 1, 1 }, arrowTint = { 1, 0.82, 0, 1 },
  text = { 1, 0.86, 0.45, 1 }, textDim = { 0.85, 0.70, 0.40, 1 }, textMuted = { 0.62, 0.52, 0.34, 1 },
  contentBg = { 0, 0, 0, 1 }, contentBorder = { 0.52, 0.52, 0.55, 1 },   -- list/inset = solid black, gray frame
}

-- ---- Nord (cool blue-grey) — nordtheme.com ----
Theme.presets.nord = {
  accentHex = "88c0d0",
  panelBg = { 0.180, 0.204, 0.251, 1 }, panelBorder = { 0.298, 0.337, 0.416, 1 },
  headerBg = { 0.231, 0.259, 0.322, 1 }, bodyBg = { 0.208, 0.231, 0.286, 1 },
  pausedHeaderBg = { 0.31, 0.13, 0.15, 1 }, pausedBodyBg = { 0.24, 0.10, 0.12, 1 },
  slotFill = { 0, 0, 0, 0.35 }, slotBorder = { 0.298, 0.337, 0.416, 1 },
  slotFillSelected = { 0.20, 0.30, 0.34, 0.6 }, slotBorderSelected = { 0.533, 0.753, 0.816, 1 },
  tabAccent = { 0.533, 0.753, 0.816, 1 }, tabTextActive = { 0.925, 0.937, 0.957, 1 }, tabTextIdle = { 0.42, 0.46, 0.55, 1 },
  buttonBg = { 0.231, 0.259, 0.322, 1 }, buttonBorder = { 0.298, 0.337, 0.416, 1 }, buttonText = { 0.847, 0.871, 0.914, 1 },
  buttonHover = { 0.263, 0.298, 0.369, 1 }, buttonPressed = { 0.180, 0.204, 0.251, 1 }, buttonDisabled = { 0.42, 0.46, 0.55, 1 },
  buttonHighlight = { 1, 1, 1, 0.07 },
  dropdownBg = { 0.231, 0.259, 0.322, 1 }, dropdownBorder = { 0.298, 0.337, 0.416, 1 },
  dropdownText = { 0.847, 0.871, 0.914, 1 }, dropdownArrow = { 0.506, 0.631, 0.757, 1 },
  checkboxBg = { 0.180, 0.204, 0.251, 1 }, checkboxBorder = { 0.298, 0.337, 0.416, 1 }, checkboxCheck = { 0.533, 0.753, 0.816, 1 },
  editboxBg = { 0, 0, 0, 0.3 }, editboxBorder = { 0.298, 0.337, 0.416, 1 }, editboxText = { 0.925, 0.937, 0.957, 1 },
  closeColor = { 0.506, 0.631, 0.757, 1 }, closeHover = { 0.925, 0.937, 0.957, 1 }, arrowTint = { 0.506, 0.631, 0.757, 1 },
}

-- ---- Dracula (dark purple/pink) — draculatheme.com ----
Theme.presets.dracula = {
  accentHex = "bd93f9",
  panelBg = { 0.157, 0.165, 0.212, 1 }, panelBorder = { 0.267, 0.278, 0.353, 1 },
  headerBg = { 0.129, 0.133, 0.173, 1 }, bodyBg = { 0.165, 0.173, 0.220, 1 },
  pausedHeaderBg = { 0.33, 0.12, 0.14, 1 }, pausedBodyBg = { 0.24, 0.09, 0.11, 1 },
  slotFill = { 0, 0, 0, 0.35 }, slotBorder = { 0.267, 0.278, 0.353, 1 },
  slotFillSelected = { 0.25, 0.18, 0.35, 0.6 }, slotBorderSelected = { 0.741, 0.576, 0.976, 1 },
  tabAccent = { 0.741, 0.576, 0.976, 1 }, tabTextActive = { 0.973, 0.973, 0.949, 1 }, tabTextIdle = { 0.384, 0.447, 0.643, 1 },
  buttonBg = { 0.267, 0.278, 0.353, 1 }, buttonBorder = { 0.384, 0.447, 0.643, 1 }, buttonText = { 0.973, 0.973, 0.949, 1 },
  buttonHover = { 0.31, 0.32, 0.42, 1 }, buttonPressed = { 0.129, 0.133, 0.173, 1 }, buttonDisabled = { 0.384, 0.447, 0.643, 1 },
  buttonHighlight = { 1, 1, 1, 0.07 },
  dropdownBg = { 0.267, 0.278, 0.353, 1 }, dropdownBorder = { 0.384, 0.447, 0.643, 1 },
  dropdownText = { 0.973, 0.973, 0.949, 1 }, dropdownArrow = { 0.384, 0.447, 0.643, 1 },
  checkboxBg = { 0.129, 0.133, 0.173, 1 }, checkboxBorder = { 0.384, 0.447, 0.643, 1 }, checkboxCheck = { 0.741, 0.576, 0.976, 1 },
  editboxBg = { 0, 0, 0, 0.3 }, editboxBorder = { 0.384, 0.447, 0.643, 1 }, editboxText = { 0.973, 0.973, 0.949, 1 },
  closeColor = { 0.741, 0.576, 0.976, 1 }, closeHover = { 0.973, 0.973, 0.949, 1 }, arrowTint = { 0.384, 0.447, 0.643, 1 },
}

-- ---- Tokyo Night (dark blue/purple) — terminalcolors.com ----
Theme.presets.tokyonight = {
  accentHex = "7aa2f7",
  panelBg = { 0.102, 0.106, 0.149, 1 }, panelBorder = { 0.231, 0.259, 0.380, 1 },
  headerBg = { 0.086, 0.086, 0.118, 1 }, bodyBg = { 0.122, 0.137, 0.208, 1 },
  pausedHeaderBg = { 0.31, 0.11, 0.16, 1 }, pausedBodyBg = { 0.23, 0.08, 0.12, 1 },
  slotFill = { 0, 0, 0, 0.35 }, slotBorder = { 0.231, 0.259, 0.380, 1 },
  slotFillSelected = { 0.18, 0.24, 0.40, 0.6 }, slotBorderSelected = { 0.478, 0.635, 0.969, 1 },
  tabAccent = { 0.478, 0.635, 0.969, 1 }, tabTextActive = { 0.753, 0.792, 0.961, 1 }, tabTextIdle = { 0.337, 0.373, 0.537, 1 },
  buttonBg = { 0.161, 0.180, 0.259, 1 }, buttonBorder = { 0.231, 0.259, 0.380, 1 }, buttonText = { 0.753, 0.792, 0.961, 1 },
  buttonHover = { 0.204, 0.227, 0.322, 1 }, buttonPressed = { 0.086, 0.086, 0.118, 1 }, buttonDisabled = { 0.337, 0.373, 0.537, 1 },
  buttonHighlight = { 1, 1, 1, 0.07 },
  dropdownBg = { 0.161, 0.180, 0.259, 1 }, dropdownBorder = { 0.231, 0.259, 0.380, 1 },
  dropdownText = { 0.753, 0.792, 0.961, 1 }, dropdownArrow = { 0.478, 0.635, 0.969, 1 },
  checkboxBg = { 0.086, 0.086, 0.118, 1 }, checkboxBorder = { 0.231, 0.259, 0.380, 1 }, checkboxCheck = { 0.478, 0.635, 0.969, 1 },
  editboxBg = { 0, 0, 0, 0.3 }, editboxBorder = { 0.231, 0.259, 0.380, 1 }, editboxText = { 0.753, 0.792, 0.961, 1 },
  closeColor = { 0.478, 0.635, 0.969, 1 }, closeHover = { 0.753, 0.792, 0.961, 1 }, arrowTint = { 0.337, 0.373, 0.537, 1 },
}

-- ---- Rosé Pine (muted rose-gold) — terminalcolors.com ----
Theme.presets.rosepine = {
  accentHex = "f6c177",
  panelBg = { 0.098, 0.090, 0.141, 1 }, panelBorder = { 0.251, 0.239, 0.322, 1 },
  headerBg = { 0.122, 0.114, 0.180, 1 }, bodyBg = { 0.129, 0.125, 0.180, 1 },
  pausedHeaderBg = { 0.33, 0.13, 0.18, 1 }, pausedBodyBg = { 0.24, 0.09, 0.13, 1 },
  slotFill = { 0, 0, 0, 0.35 }, slotBorder = { 0.251, 0.239, 0.322, 1 },
  slotFillSelected = { 0.30, 0.22, 0.14, 0.6 }, slotBorderSelected = { 0.965, 0.757, 0.467, 1 },
  tabAccent = { 0.965, 0.757, 0.467, 1 }, tabTextActive = { 0.878, 0.871, 0.957, 1 }, tabTextIdle = { 0.431, 0.416, 0.525, 1 },
  buttonBg = { 0.149, 0.137, 0.227, 1 }, buttonBorder = { 0.251, 0.239, 0.322, 1 }, buttonText = { 0.878, 0.871, 0.957, 1 },
  buttonHover = { 0.180, 0.165, 0.267, 1 }, buttonPressed = { 0.098, 0.090, 0.141, 1 }, buttonDisabled = { 0.431, 0.416, 0.525, 1 },
  buttonHighlight = { 1, 1, 1, 0.07 },
  dropdownBg = { 0.149, 0.137, 0.227, 1 }, dropdownBorder = { 0.251, 0.239, 0.322, 1 },
  dropdownText = { 0.878, 0.871, 0.957, 1 }, dropdownArrow = { 0.565, 0.549, 0.667, 1 },
  checkboxBg = { 0.098, 0.090, 0.141, 1 }, checkboxBorder = { 0.251, 0.239, 0.322, 1 }, checkboxCheck = { 0.965, 0.757, 0.467, 1 },
  editboxBg = { 0, 0, 0, 0.3 }, editboxBorder = { 0.251, 0.239, 0.322, 1 }, editboxText = { 0.878, 0.871, 0.957, 1 },
  closeColor = { 0.565, 0.549, 0.667, 1 }, closeHover = { 0.878, 0.871, 0.957, 1 }, arrowTint = { 0.565, 0.549, 0.667, 1 },
}

-- ---- Everforest (dark green) — terminalcolors.com ----
Theme.presets.everforest = {
  accentHex = "a7c080",
  panelBg = { 0.176, 0.208, 0.231, 1 }, panelBorder = { 0.310, 0.345, 0.369, 1 },
  headerBg = { 0.137, 0.165, 0.180, 1 }, bodyBg = { 0.165, 0.196, 0.216, 1 },
  pausedHeaderBg = { 0.30, 0.13, 0.13, 1 }, pausedBodyBg = { 0.23, 0.10, 0.10, 1 },
  slotFill = { 0, 0, 0, 0.3 }, slotBorder = { 0.310, 0.345, 0.369, 1 },
  slotFillSelected = { 0.22, 0.28, 0.16, 0.6 }, slotBorderSelected = { 0.655, 0.753, 0.502, 1 },
  tabAccent = { 0.655, 0.753, 0.502, 1 }, tabTextActive = { 0.827, 0.776, 0.667, 1 }, tabTextIdle = { 0.522, 0.573, 0.537, 1 },
  buttonBg = { 0.239, 0.282, 0.302, 1 }, buttonBorder = { 0.310, 0.345, 0.369, 1 }, buttonText = { 0.827, 0.776, 0.667, 1 },
  buttonHover = { 0.278, 0.322, 0.345, 1 }, buttonPressed = { 0.137, 0.165, 0.180, 1 }, buttonDisabled = { 0.522, 0.573, 0.537, 1 },
  buttonHighlight = { 1, 1, 1, 0.07 },
  dropdownBg = { 0.239, 0.282, 0.302, 1 }, dropdownBorder = { 0.310, 0.345, 0.369, 1 },
  dropdownText = { 0.827, 0.776, 0.667, 1 }, dropdownArrow = { 0.522, 0.573, 0.537, 1 },
  checkboxBg = { 0.137, 0.165, 0.180, 1 }, checkboxBorder = { 0.310, 0.345, 0.369, 1 }, checkboxCheck = { 0.655, 0.753, 0.502, 1 },
  editboxBg = { 0, 0, 0, 0.3 }, editboxBorder = { 0.310, 0.345, 0.369, 1 }, editboxText = { 0.827, 0.776, 0.667, 1 },
  closeColor = { 0.522, 0.573, 0.537, 1 }, closeHover = { 0.827, 0.776, 0.667, 1 }, arrowTint = { 0.522, 0.573, 0.537, 1 },
}

-- ---- One Dark (Atom grey-blue) — terminalcolors.com ----
Theme.presets.onedark = {
  accentHex = "61afef",
  panelBg = { 0.157, 0.173, 0.204, 1 }, panelBorder = { 0.294, 0.322, 0.388, 1 },
  headerBg = { 0.129, 0.145, 0.169, 1 }, bodyBg = { 0.173, 0.192, 0.227, 1 },
  pausedHeaderBg = { 0.30, 0.13, 0.14, 1 }, pausedBodyBg = { 0.23, 0.10, 0.11, 1 },
  slotFill = { 0, 0, 0, 0.35 }, slotBorder = { 0.294, 0.322, 0.388, 1 },
  slotFillSelected = { 0.16, 0.26, 0.36, 0.6 }, slotBorderSelected = { 0.380, 0.686, 0.937, 1 },
  tabAccent = { 0.380, 0.686, 0.937, 1 }, tabTextActive = { 0.671, 0.698, 0.749, 1 }, tabTextIdle = { 0.361, 0.388, 0.439, 1 },
  buttonBg = { 0.243, 0.267, 0.318, 1 }, buttonBorder = { 0.294, 0.322, 0.388, 1 }, buttonText = { 0.671, 0.698, 0.749, 1 },
  buttonHover = { 0.271, 0.298, 0.353, 1 }, buttonPressed = { 0.129, 0.145, 0.169, 1 }, buttonDisabled = { 0.361, 0.388, 0.439, 1 },
  buttonHighlight = { 1, 1, 1, 0.07 },
  dropdownBg = { 0.243, 0.267, 0.318, 1 }, dropdownBorder = { 0.294, 0.322, 0.388, 1 },
  dropdownText = { 0.671, 0.698, 0.749, 1 }, dropdownArrow = { 0.510, 0.537, 0.592, 1 },
  checkboxBg = { 0.129, 0.145, 0.169, 1 }, checkboxBorder = { 0.294, 0.322, 0.388, 1 }, checkboxCheck = { 0.380, 0.686, 0.937, 1 },
  editboxBg = { 0, 0, 0, 0.3 }, editboxBorder = { 0.294, 0.322, 0.388, 1 }, editboxText = { 0.671, 0.698, 0.749, 1 },
  closeColor = { 0.510, 0.537, 0.592, 1 }, closeHover = { 0.671, 0.698, 0.749, 1 }, arrowTint = { 0.510, 0.537, 0.592, 1 },
}

-- An ordered list for a config "theme" dropdown (key -> label). Mostly dark; a couple light.
Theme.PresetList = {
  { key = "default",         label = "JG Navy (default)" },
  { key = "wow",             label = "WoW Default" },
  { key = "gruvbox",         label = "Gruvbox" },
  { key = "nord",            label = "Nord" },
  { key = "dracula",         label = "Dracula" },
  { key = "tokyonight",      label = "Tokyo Night" },
  { key = "rosepine",        label = "Rosé Pine" },
  { key = "everforest",      label = "Everforest" },
  { key = "onedark",         label = "One Dark" },
  { key = "solarized-dark",  label = "Solarized Dark" },
  { key = "solarized-light", label = "Solarized Light" },
}

-- Active palette fallback (the config switcher / saved choice overrides this at addon load).
Theme.UsePreset("default")

-- ============================================================================
-- Theme.AccordionList(scrollChild, opts) — generic data-in list with collapsible, arbitrarily-NESTED
-- groups and configurable right-aligned columns. PURE RENDERER: open/closed state lives with the
-- CONSUMER (pass `open` per group + an `onToggle(key)` that flips its own state and re-renders).
--
--   local list = Theme.AccordionList(scrollChild, {
--     theme   = Theme,                       -- ForAddon handle for colors (defaults to this lib)
--     rowH = 18, indent = 14,
--     columns = { { key="value", max=130 }, { key="pct", max=56, optional=true } },  -- RIGHT->LEFT order
--       -- per-column opts: max, min, optional (hide when empty), flex (name column), icon, align, gap
--       -- (px to the column's LEFT; default 8 — set small for a tight icon column that shouldn't reserve a word-gap)
--     groupGlyph = false | true | { open=tex, closed=tex } | function(glyphTexture, isOpen) ... end,
--   })
--   list:SetEntries(entries)                 -- re-pool + lay out; sets scrollChild height. Each refresh.
--
-- entries: ordered array of nodes, depth-first. Item: { icon, name, link, onClick/onEnter/onLeave,
--   cols={value=..,pct=..} (or legacy value=/pct=) }. Group: { kind="group", key, label, count, icon,
--   open, onToggle, children={...nodes...}, cols=.. }. Groups nest to ANY depth (depth-indented).
local AL_ICON  = 134400
local AL_PLUS  = "Interface\\Buttons\\UI-PlusButton-Up"
local AL_MINUS = "Interface\\Buttons\\UI-MinusButton-Up"
local AccordionList = {}
AccordionList.__index = AccordionList

local function alColText(e, key)   -- per-entry column value: e.cols[key], else legacy e.value / e.pct
  if e.cols and e.cols[key] ~= nil then return e.cols[key] end
  if key == "value" then return e.value elseif key == "pct" then return e.pct end
  return nil
end

-- Windowed (virtualized) range for the flat list. Given the total entry count, row height, the current
-- vertical scroll offset (px from top) and the viewport height, return the 1-based FIRST index to render
-- and the COUNT of rows in the window (the visible span padded by `overscan` rows each side). Pure math so
-- it's unit-testable headless (total N, rowH, offset, viewportH, overscan -> first, count) and so the live
-- row-frame count stays BOUNDED (window ~ visible rows + 2*overscan) no matter how large N is.
local function alWindowRange(total, rowH, scrollOffset, viewportH, overscan)
  if not total or total <= 0 or not rowH or rowH <= 0 then return 1, 0 end
  overscan = overscan or 0
  scrollOffset = math.max(0, scrollOffset or 0)
  viewportH    = math.max(0, viewportH or 0)
  local firstVis = math.floor(scrollOffset / rowH) + 1
  local lastVis  = math.ceil((scrollOffset + viewportH) / rowH)
  local first = math.max(1, firstVis - overscan)
  local last  = math.min(total, lastVis + overscan)
  if last < first then return first, 0 end
  return first, last - first + 1
end

-- Fixed column widths for the flat list, measured ONCE across the FULL entries array (not just the
-- rendered window) so columns do NOT jitter while scrolling. `measure(text)` returns a string's pixel
-- width (in game: a scratch/offscreen FontString's GetStringWidth; in tests: an injected stub — measuring
-- text width needs no visible frame). Mirrors the legacy per-row sizing exactly: widest cell capped by
-- `max`, floored by `min`, `optional` empty columns collapse to 0, the icon column reserves an icon slot,
-- and the (first) flex column is left at 0 here (its width is filled from the viewport at layout time).
-- Returns fixedW (array by column index), sumFixed, nVis, flexCi, iconCi.
local function alMeasureFlat(entries, columns, rowH, measure)
  entries = entries or {}
  local ICON = rowH - 2
  local flexCi, iconCi
  for ci, c in ipairs(columns) do
    if c.flex and not flexCi then flexCi = ci end
    if c.icon and not iconCi then iconCi = ci end
  end
  local fixedW, sumFixed, nVis = {}, 0, 0
  for ci, c in ipairs(columns) do
    if c.flex then fixedW[ci] = 0
    else
      local w = 0
      for i = 1, #entries do
        local cell = entries[i].cols and entries[i].cols[c.key]
        if cell and cell ~= "" then local cw = measure(cell) or 0; if cw > w then w = cw end end
      end
      if c.optional and w <= 0 then fixedW[ci] = 0
      else
        w = math.ceil(w) + 2
        if c.max then w = math.min(w, c.max) end
        if c.min then w = math.max(w, c.min) end
        if ci == iconCi then w = w + ICON + 4 end
        fixedW[ci] = w
      end
    end
    if c.flex or fixedW[ci] > 0 then nVis = nVis + 1 end
    if not c.flex then sumFixed = sumFixed + fixedW[ci] end
  end
  return fixedW, sumFixed, nVis, flexCi, iconCi
end

function AccordionList:_row(i)
  local r = self.rows[i]
  if r then return r end
  local rowH = self.rowH
  r = CreateFrame("Button", nil, self.scrollChild)
  r:SetHeight(rowH); r:RegisterForClicks("AnyUp")
  r.fill  = r:CreateTexture(nil, "BACKGROUND"); r.fill:SetAllPoints(); r.fill:Hide()
  r.hover = r:CreateTexture(nil, "BORDER");     r.hover:SetAllPoints(); r.hover:Hide()
  r.glyph = r:CreateTexture(nil, "ARTWORK");    r.glyph:SetSize(rowH - 6, rowH - 6); r.glyph:Hide()
  r.icon  = r:CreateTexture(nil, "ARTWORK");    r.icon:SetSize(rowH - 2, rowH - 2)
  r.cols = {}                                   -- one FontString per configured column (placed in SetEntries)
  for _, cdef in ipairs(self.columns) do
    local fs = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetJustifyH(cdef.align or "RIGHT"); r.cols[cdef.key] = fs
  end
  r.name = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
  r:SetScript("OnEnter", function(row)
    if row._hover and row.hover then row.hover:Show() end
    if row._onEnter then row._onEnter(row) return end
    if not row._link then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(row._link); GameTooltip:Show()
  end)
  r:SetScript("OnLeave", function(row)
    if row.hover then row.hover:Hide() end
    if row._onLeave then row._onLeave(row) return end
    GameTooltip_Hide()
  end)
  r:SetScript("OnClick", function(row, button)
    -- item rows: a modified click (shift = link to chat, ctrl = dressup, …) goes to the item link first;
    -- HandleModifiedItemClick returns true when it consumed the click. Non-item rows (_link nil, e.g. a
    -- grouped-mode header) skip straight to the row's own onClick, so this is inert for the legacy path.
    if row._link and HandleModifiedItemClick and HandleModifiedItemClick(row._link) then return end
    if row._onClick then row._onClick(row, button) end
  end)
  self.rows[i] = r
  return r
end

function AccordionList:_drawGlyph(r, isOpen)   -- configurable twirl-down: false / true / {open,closed} / fn
  local g = self.groupGlyph
  if not g then r.glyph:Hide(); return end
  if type(g) == "function" then r.glyph:Show(); g(r.glyph, isOpen and true or false)
  elseif type(g) == "table" then r.glyph:SetTexture(isOpen and g.open or g.closed); r.glyph:Show()
  else r.glyph:SetTexture(isOpen and AL_MINUS or AL_PLUS); r.glyph:Show() end
end

function AccordionList:_layout(r, e, depth, isGroup)
  local base = 2 + depth * self.indent
  local glyphSlot = (self.groupGlyph and self.rowH) or 0   -- reserved for ALL rows at a depth (alignment)
  r.icon:ClearAllPoints(); r.icon:SetPoint("LEFT", base + glyphSlot, 0)
  r.icon:SetTexture(e.icon or AL_ICON)
  for _, cdef in ipairs(self.columns) do r.cols[cdef.key]:SetText(alColText(e, cdef.key) or "") end
  if isGroup then
    local c = (self.theme and self.theme.colors) or {}
    r.fill:SetColorTexture(unpack(c.accordionHeader or { 1, 1, 1, 0.06 })); r.fill:Show()
    r.hover:SetColorTexture(unpack(c.accordionHeaderHover or { 1, 1, 1, 0.11 })); r.hover:Hide()
    r._hover = true
    if self.groupGlyph then
      self:_drawGlyph(r, e.open); r.glyph:ClearAllPoints(); r.glyph:SetPoint("LEFT", base, 0)
    else r.glyph:Hide() end
    local cnt = (e.count and e.count > 0) and ("  x" .. e.count) or ""
    r.name:SetText((e.label or "") .. cnt)
    -- group headers still get their entry's hover callbacks (e.g. a dev metadata tooltip); _link stays nil
    -- so the row isn't treated as an item, and the click toggles the group.
    r._link, r._onEnter, r._onLeave = nil, e.onEnter, e.onLeave
    local key, onToggle = e.key, e.onToggle
    r._onClick = function() if onToggle then onToggle(key) end end
  else
    r.fill:Hide(); r.hover:Hide(); r.glyph:Hide(); r._hover = false
    r.name:SetText(e.name or "")
    r._link, r._onClick, r._onEnter, r._onLeave = e.link, e.onClick, e.onEnter, e.onLeave
  end
end

function AccordionList:SetEntries(entries)
  if self.declarative then return self:_setEntriesFlat(entries) end
  entries = entries or {}
  local rowH, shown = self.rowH, 0
  local function place(e, depth, isGroup)
    shown = shown + 1
    local r = self:_row(shown)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 0, -(shown - 1) * rowH)
    r:SetPoint("RIGHT", self.scrollChild, "RIGHT", 0, 0)
    self:_layout(r, e, depth, isGroup); r:Show()
  end
  local function walk(list, depth)             -- depth-first; groups nest to any depth
    for _, e in ipairs(list or {}) do
      if e.kind == "group" then
        place(e, depth, true)
        if e.open and e.children then walk(e.children, depth + 1) end
      else
        place(e, depth, false)
      end
    end
  end
  walk(entries, 0)
  -- auto-width columns: measure widest per column (capped), lay out RIGHT->LEFT ([1]=rightmost), anchor
  -- the flex name to the leftmost visible column. `optional` columns with no content hide entirely.
  local GAP, EDGE = 8, 4
  local widths = {}
  for _, cdef in ipairs(self.columns) do
    local w = 0
    for i = 1, shown do w = math.max(w, self.rows[i].cols[cdef.key]:GetStringWidth() or 0) end
    widths[cdef.key] = (cdef.optional and w <= 0) and 0 or math.min(math.ceil(w) + 1, cdef.max or 130)
  end
  -- per-column `gap` overrides the default GAP for the space to that column's LEFT (its neighbour toward
  -- the name). Lets a tight icon column (e.g. a source glyph) hug the column to its right instead of
  -- reserving a full word-gap of padding on both sides.
  for i = 1, shown do
    local r = self.rows[i]
    local prevFS, leftmost, leftGap = nil, nil, GAP
    for ci = 1, #self.columns do               -- [1] is the rightmost column
      local cdef = self.columns[ci]
      local fs, w = r.cols[cdef.key], widths[cdef.key]
      fs:ClearAllPoints()
      if w > 0 then
        if prevFS then fs:SetPoint("RIGHT", prevFS, "LEFT", -(cdef.gap or GAP), 0) else fs:SetPoint("RIGHT", -EDGE, 0) end
        fs:SetWidth(w); fs:Show(); prevFS, leftmost, leftGap = fs, fs, (cdef.gap or GAP)
      else fs:Hide() end
    end
    r.name:ClearAllPoints(); r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
    if leftmost then r.name:SetPoint("RIGHT", leftmost, "LEFT", -leftGap, 0) else r.name:SetPoint("RIGHT", -EDGE, 0) end
  end
  for i = shown + 1, #self.rows do self.rows[i]:Hide() end
  self.scrollChild:SetHeight(math.max(shown * rowH, 1))
end

-- Declarative FLAT columnar layout (no groups), VIRTUALIZED. Each column: { key, align, flex=true (ONE
-- column absorbs the slack), icon=true (reserve an icon slot at its left), max, min, optional, color }.
-- entries: flat array of rows { cols = { key = text, ... }, icon, link, onClick, onEnter, onLeave, highlight }.
-- Only a viewport-sized WINDOW of row frames is ever live (visible rows + overscan); the scroll child spans
-- the FULL entry count so the scrollbar represents the whole list. Column widths are measured ONCE across
-- ALL entries (offscreen scratch FontString) so they stay fixed while scrolling. This is the path
-- GECStoreView uses for the log; legacy grouped mode (SetEntries) is untouched.

-- Offscreen scratch FontString for width measurement (no visible frame needed to measure text width).
function AccordionList:_measureText(text)
  local fs = self._measureFS
  if not fs then
    fs = self.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:Hide()
    self._measureFS = fs
  end
  fs:SetText(text or "")
  return fs:GetStringWidth() or 0
end

-- Hook the parent ScrollFrame ONCE so scrolling / resizing re-windows the visible rows. Uses HookScript so
-- it composes with Theme.AttachScrollBar's own OnVerticalScroll hook (and never clobbers it).
function AccordionList:_installScrollHandlers()
  if self._scrollHooked then return end
  local sf = self.scrollChild:GetParent()
  if not (sf and sf.GetVerticalScroll and sf.HookScript) then return end   -- no ScrollFrame -> static fallback
  self.scrollFrame = sf
  sf:HookScript("OnVerticalScroll", function() self:_relayoutFlat() end)
  sf:HookScript("OnSizeChanged",    function() self:_relayoutFlat() end)
  self._scrollHooked = true
end

-- Scroll so entry `idx` (1-based, newest-first) sits at the top of the viewport. Phase-2 (search) uses this
-- to jump to a match. Clamped to the scroll range; re-windows immediately.
function AccordionList:ScrollToIndex(idx)
  local sf = self.scrollFrame
  if not sf then return end
  local total = (self._entries and #self._entries) or 0
  idx = math.max(1, math.min(idx or 1, math.max(1, total)))
  local target = (idx - 1) * self.rowH
  local range = sf:GetVerticalScrollRange() or 0
  sf:SetVerticalScroll(math.max(0, math.min(range, target)))
  self:_relayoutFlat()
end

function AccordionList:_setEntriesFlat(entries)
  entries = entries or {}
  self._entries = entries
  -- measure the fixed column widths ONCE across the FULL data so they don't shift while scrolling
  self._fixedW, self._sumFixed, self._nVis, self._flexCi, self._iconCi =
    alMeasureFlat(entries, self.columns, self.rowH, function(t) return self:_measureText(t) end)
  -- the scroll child spans every entry so the scrollbar covers the whole log
  self.scrollChild:SetHeight(math.max(#entries * self.rowH, 1))
  self:_installScrollHandlers()
  self:_relayoutFlat()
  -- widths/heights can be stale for one frame right after a build/resize; re-window once when laid out
  if C_Timer and C_Timer.After then C_Timer.After(0, function() self:_relayoutFlat() end) end
end

-- Bind the pooled row frames to the current window and place their cells. Called on SetEntries and on every
-- scroll/resize. Bounded work: only `count` (~viewport + overscan) rows are ever touched.
function AccordionList:_relayoutFlat()
  local entries = self._entries or {}
  local total, rowH, cols = #entries, self.rowH, self.columns
  local fixedW = self._fixedW or {}
  local sf = self.scrollFrame
  local W = self.scrollChild:GetWidth() or 0
  local viewportH, scrollOffset, first, count
  if sf then
    local sw = sf:GetWidth() or 0
    if sw > 10 then W = sw; self.scrollChild:SetWidth(sw) end
    viewportH    = sf:GetHeight() or 0
    scrollOffset = sf:GetVerticalScroll() or 0
    first, count = alWindowRange(total, rowH, scrollOffset, viewportH, self.overscan)
  else
    first, count = 1, total                     -- static fallback (no ScrollFrame): render everything
  end
  if W < 10 then W = self._lastW or 320 end
  self._lastW = W
  -- the flex column soaks up the leftover viewport width (kept out of the measured fixed widths)
  local GAP, EDGE, ICON = self.colGap or 8, 4, rowH - 2
  local gaps = math.max(0, (self._nVis or 0) - 1) * GAP
  if self._flexCi then fixedW[self._flexCi] = math.max(48, W - 2 * EDGE - (self._sumFixed or 0) - gaps) end
  local themeColors = (self.theme and self.theme.colors) or {}
  for p = 1, count do
    local idx = first + p - 1
    local e, r = entries[idx], self:_row(p)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 0, -(idx - 1) * rowH); r:SetPoint("RIGHT", self.scrollChild, "RIGHT", 0, 0)
    -- highlight primitive (Phase-2 hook): entry.highlight tints the whole row from the theme.
    -- "active"/"current" -> stronger tint; any other truthy value -> the match tint; absent -> no tint.
    local hl = e.highlight
    if hl then
      local col = (hl == "active" or hl == "current") and (themeColors.rowHighlightActive or { 1, 0.82, 0, 0.32 })
                  or (themeColors.rowHighlight or { 1, 0.82, 0, 0.14 })
      r.fill:SetColorTexture(unpack(col)); r.fill:Show()
    else r.fill:Hide() end
    r.glyph:Hide(); r.hover:Hide(); r._hover = false
    for _, c in ipairs(cols) do
      local fs = r.cols[c.key]
      fs:SetText((e.cols and e.cols[c.key]) or "")
      fs:SetTextColor(Theme.HexToRGB(c.color or "ffffff"))   -- per-column base color; inline |cff in the text still wins
    end
    r._link, r._onClick, r._onEnter, r._onLeave, r._eicon = e.link, e.onClick, e.onEnter, e.onLeave, e.icon
    if e.icon then r.icon:SetTexture(e.icon); r.icon:Show() else r.icon:Hide() end
    -- place cells left -> right with the fixed widths; the icon (if any) anchors at its column's left
    local x = EDGE
    for ci, c in ipairs(cols) do
      local fs, w = r.cols[c.key], fixedW[ci]
      if w and w > 0 then
        local tx, tw = x, w
        if ci == self._iconCi then
          if e.icon then r.icon:ClearAllPoints(); r.icon:SetSize(ICON, ICON); r.icon:SetPoint("LEFT", r, "LEFT", x, 0) end
          tx, tw = x + ICON + 4, w - ICON - 4
        end
        fs:ClearAllPoints(); fs:SetPoint("LEFT", r, "LEFT", tx, 0)
        fs:SetWidth(math.max(1, tw)); fs:SetJustifyH(c.align or "LEFT"); fs:Show()
        x = x + w + GAP
      else fs:Hide() end
    end
    r:Show()
  end
  for p = count + 1, #self.rows do self.rows[p]:Hide() end
  self.scrollChild:SetHeight(math.max(total * rowH, 1))
end

function Theme.AccordionList(scrollChild, opts)
  opts = opts or {}
  local self = setmetatable({}, AccordionList)
  self.scrollChild = scrollChild
  self.theme   = opts.theme or Theme
  self.rowH    = opts.rowH or 18
  self.indent  = opts.indent or 14
  self.groupGlyph = opts.groupGlyph or false
  self.columns = opts.columns or { { key = "value", max = 130 }, { key = "pct", max = 56, optional = true } }
  self.declarative = opts.declarative and true or false   -- flat per-column layout (align + flex) vs legacy groups
  self.colGap  = opts.colGap or 8
  self.overscan = opts.overscan or 6                       -- extra windowed rows above+below the viewport
  self.rows    = {}
  return self
end

-- pure helpers exposed for headless unit tests (windowing index math + column-width-from-full-data)
Theme._WindowRange = alWindowRange
Theme._MeasureFlatColumns = alMeasureFlat
