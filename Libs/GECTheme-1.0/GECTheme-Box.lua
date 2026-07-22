-- GECTheme-Box — one recursive flexbox primitive for every GEC addon UI.
--
-- A page is a box, a section is a box, a row is a box, a column is a box; they differ only by
-- PROPERTIES, never by type. Each box measures its own width AND height and reports both upward, so
-- nesting is unlimited and no caller ever writes a y-offset or a section height again. The property set
-- is a deliberate subset of CSS flexbox (dir/gap/pad/grow/basis/align/justify/wrap) so the mental model
-- is one people already know. Spec: docs/superpowers/specs/2026-07-05-gectheme-flow-layout-system-design.md
--
-- The engine attaches its API onto the SAME Theme table LibStub returned for GECTheme-1.0 (loaded just
-- before this file). It is split out only so the engine is reviewable in isolation.
--
-- Design — a PURE core under a thin frame layer. The whole three-pass algorithm (resolve widths ->
-- measure heights -> place) is expressed as file-local functions over "layout nodes": plain tables that
-- know their flexbox props and, for a leaf, three closures (mh/nw/lw = measure-height / natural-width /
-- min-width). Those functions never touch a WoW Frame, so they are unit-testable headless. The frame
-- layer (Theme.Box / Theme.Layout) builds the real frames + leaf controls, hangs the same closures off
-- each leaf, runs the pure core, then copies the computed geometry onto the frames.
--
-- Coordinate convention: a box's frame is TOPLEFT-anchored inside its PARENT box's frame; a box's
-- children parent to ITS frame, so every :Place(x, y, w, h) is in the parent's local space with y
-- growing NEGATIVE downward (WoW's convention). Recursion is uniform: column vs row differ only in
-- which axis is "main".
local Theme = LibStub and LibStub:GetLibrary("GECTheme-1.0", true)
if not Theme then return end          -- GECTheme-1.0 not loaded (or a newer copy already owns the table)

-- Version guard (mirrors LibStub's "higher minor wins"): the Box engine re-attaches its API onto the
-- shared Theme table, so WITHOUT this an OLDER embed loading after a newer one would clobber the Box API
-- (the earlier "no change" bug). Only attach when THIS copy's BOX_MINOR is greater than what's already
-- stamped, then stamp it — so the newest copy wins regardless of addon load order and an older embed
-- loading later is a no-op. Bump BOX_MINOR on every Box-engine change that must supersede deployed copies.
local BOX_MINOR = 6
if Theme._boxMinor and Theme._boxMinor >= BOX_MINOR then return end
Theme._boxMinor = BOX_MINOR

local M = Theme.metrics

-- ============================ property resolution (pure) ============================
-- The keys that make a child table a LEAF (it measures + places its own control instead of nesting).
local LEAF_KEYS = { "check", "slider", "dropdown", "edit", "button", "buttons", "note", "frame" }

-- Theme._boxLeafType(spec) -> the leaf key present on the spec (e.g. "check"), or nil for a container.
local function leafType(spec)
  if type(spec) ~= "table" then return nil end
  for _, k in ipairs(LEAF_KEYS) do
    if spec[k] ~= nil then return k end
  end
  return nil
end

-- Resolve a `gap`/named-gap to a pixel number against the metrics. A number passes through; the named
-- forms map to the standard tokens; nil falls back to the axis default ("row" gap stacking a column,
-- "col" gap splitting a row).
local function resolveGap(gap, dir)
  if type(gap) == "number" then return gap end
  if gap == "row"     then return M.rowGap end
  if gap == "col"     then return M.colGap end
  if gap == "section" then return M.sectionTop end
  return (dir == "row") and M.colGap or M.rowGap
end

-- Resolve `pad` (a number = uniform inset, or a {t,r,b,l} table) to a full {t,r,b,l}. nil -> zeros.
local function resolvePad(pad)
  if type(pad) == "number" then return { t = pad, r = pad, b = pad, l = pad } end
  if type(pad) == "table" then
    return { t = pad.t or pad[1] or 0, r = pad.r or pad[2] or 0,
             b = pad.b or pad[3] or 0, l = pad.l or pad[4] or 0 }
  end
  return { t = 0, r = 0, b = 0, l = 0 }
end

-- Theme._boxProps(spec) -> the resolved, defaulted flexbox properties of a box spec (no frames touched).
-- This is the single place spec keys become engine fields, so metrics resolution + defaults are testable.
local function boxProps(spec)
  spec = spec or {}
  local dir = (spec.dir == "row") and "row" or "column"
  return {
    dir     = dir,
    gap     = resolveGap(spec.gap, dir),
    pad     = resolvePad(spec.pad),
    grow    = spec.grow or 0,
    basis   = spec.basis,   -- preferred MAIN-axis size; honored on a ROW (width) only, not a column (height)
    align   = spec.align or M.align,
    justify = spec.justify or M.justify,
    wrap    = spec.wrap and true or false,
    section = spec.section,
    desc    = spec.desc,
    lineW   = spec.lineW,
    bg      = spec.bg,
    hidden  = spec.hidden and true or false,
    id      = spec.id,
    minW    = spec.minWidth,
    maxW    = spec.maxWidth,
  }
end

-- Theme._boxCollectIds(tree) -> a sorted array of every `id` in the tree (pure; for headless ref checks).
local function collectIds(spec, out)
  out = out or {}
  if type(spec) ~= "table" then return out end
  if spec.id then out[#out + 1] = spec.id end
  if not leafType(spec) then
    for _, child in ipairs(spec) do collectIds(child, out) end
  end
  return out
end

-- A bare layout node (no frame) carrying the resolved props. Shared by the frame builder and the
-- frameless test/measure constructor so both feed the exact same pure core.
local function nodeFromProps(p)
  return {
    dir = p.dir, gap = p.gap, pad = p.pad, grow = p.grow, basis = p.basis,
    align = p.align, justify = p.justify, wrap = p.wrap, section = p.section,
    desc = p.desc, lineW = p.lineW, bg = p.bg, hidden = p.hidden,
    minW = p.minW, maxW = p.maxW, id = p.id, secInsT = 0, secInsL = 0, children = {},
  }
end

-- A `section` box reserves top space for its header block (space-above + title line + underline +
-- space-below) and indents its content, all from metrics. The pure passes read these as plain insets;
-- the header fontstring/underline are DRAWN by the frame layer's decor closure.
local function applySectionInsets(node)
  if node.section then
    node.secInsT = M.sectionTop + M.sectionHeaderH + M.sectionBot
    node.secInsL = M.indent
  end
end

-- ============================ three-pass layout core (pure) ============================
local naturalWidth, minWidth, resolveWidths, measure, place   -- mutually recursive; forward-declared
local measureWrap, wrapLines, placeColumn, placeRow, placeWrap

-- Visible children only: a `hidden` child (display:none) contributes zero size and zero gap.
local function kidsOf(node)
  local out = {}
  for _, c in ipairs(node.children) do
    if not c.hidden then out[#out + 1] = c end
  end
  return out
end

-- Effective insets = pad plus any section reservation. Returned as top, right, bottom, left.
local function insets(node)
  local p = node.pad
  return p.t + (node.secInsT or 0), p.r, p.b, p.l + (node.secInsL or 0)
end

local function clampW(node, w)
  if node.maxW then w = math.min(w, node.maxW) end
  if node.minW then w = math.max(w, node.minW) end
  return w
end

-- Natural (preferred, unwrapped) width: a leaf's is nw(); a row's is Σ children + gaps; a column's is the
-- widest child. A WRAP row also returns the widest child (min-content: it can fold to a single column),
-- NOT the summed line width — no audited case depends on a wrap row's natural width. All plus own insets, clamped.
function naturalWidth(node)
  if node.leaf then return clampW(node, node.nw()) end
  local _, ir, _, il = insets(node)
  local kids = kidsOf(node)
  local m = 0
  if node.dir == "row" and not node.wrap then
    for i, c in ipairs(kids) do m = m + naturalWidth(c) + (i > 1 and node.gap or 0) end
  else
    for _, c in ipairs(kids) do local w = naturalWidth(c); if w > m then m = w end end
  end
  return clampW(node, m + il + ir)
end

-- Intrinsic MINIMUM width (for window SetResizeBounds so labels never clip): a leaf's smallest
-- unwrappable content; a row's is Σ children mins + gaps; a column's (or a wrap row's) is the widest
-- child min. Plus insets; floored by an explicit minWidth.
function minWidth(node)
  if node.leaf then return math.max(node.lw(), node.minW or 0) end
  local _, ir, _, il = insets(node)
  local kids = kidsOf(node)
  local m = 0
  if node.dir == "row" and not node.wrap then
    for i, c in ipairs(kids) do m = m + minWidth(c) + (i > 1 and node.gap or 0) end
  else
    for _, c in ipairs(kids) do local w = minWidth(c); if w > m then m = w end end
  end
  return math.max(m + il + ir, node.minW or 0)
end

-- Pass 1 — resolve widths, top-down. Fix this box's outer width, then hand each child its width: a
-- COLUMN stretches children to its content width (align:stretch) or shrinks them to intrinsic; a ROW
-- gives each child its flex-basis then shares leftover width across `grow` children by weight — exactly
-- flexbox. A wrap row resolves each child at its own (capped) natural width.
function resolveWidths(node, outerW)
  node._w = clampW(node, outerW)
  if node.leaf then return end
  local _, ir, _, il = insets(node)
  local cw = node._w - il - ir
  local kids = kidsOf(node)
  if node.dir == "row" and not node.wrap then
    local n = #kids
    local avail = cw - math.max(0, n - 1) * node.gap
    local totalBasis, totalGrow = 0, 0
    for _, c in ipairs(kids) do
      -- flex-basis: an explicit basis wins; a GROW child bases at its MIN width (real flex-grow items
      -- base LOW and grow to fill), so two grow columns SHARE the bounded row width instead of each
      -- claiming its full natural width — which, for a column of wide notes, is the whole unwrapped
      -- string and would overflow off-screen. Non-grow children keep their natural (preferred) width.
      if c.basis then c._basis = c.basis
      elseif (c.grow or 0) > 0 then c._basis = minWidth(c)
      else c._basis = naturalWidth(c) end
      totalBasis = totalBasis + c._basis
      totalGrow = totalGrow + (c.grow or 0)
    end
    -- By design there is NO flex-shrink: a negative leftover (children's bases exceed the row) is not
    -- redistributed — children keep their basis and may overflow; the window min-width (MinWidth bubbling)
    -- is what keeps a real layout from ever getting that narrow.
    local leftover = avail - totalBasis
    for _, c in ipairs(kids) do
      local w = c._basis
      if leftover > 0 and totalGrow > 0 then w = w + leftover * (c.grow or 0) / totalGrow end
      resolveWidths(c, w)
    end
  elseif node.dir == "row" and node.wrap then
    for _, c in ipairs(kids) do resolveWidths(c, math.min(naturalWidth(c), cw)) end
  else
    for _, c in ipairs(kids) do
      local w = (node.align == "stretch") and cw or math.min(naturalWidth(c), cw)
      resolveWidths(c, w)
    end
  end
end

-- Greedy line-break for a wrap row: pack children left->right at their resolved widths, breaking to a
-- new line when the next child would overflow the content width. Returns an array of lines (each an
-- array of child nodes).
function wrapLines(node, kids, cw)
  local gap = node.gap
  local lines = { {} }
  local x = 0
  for _, c in ipairs(kids) do
    local w = c._w or naturalWidth(c)
    local cur = lines[#lines]
    if #cur > 0 and (x + gap + w) > cw then
      lines[#lines + 1] = {}; cur = lines[#lines]; x = 0
    end
    if #cur > 0 then x = x + gap end
    cur[#cur + 1] = c; x = x + w
  end
  return lines
end

-- Height of a wrap row = Σ line heights (each = tallest child in the line) + a wrapGap between lines.
function measureWrap(node, kids, cw)
  local lines = wrapLines(node, kids, cw)
  local total = 0
  for li, line in ipairs(lines) do
    local lh = 0
    for _, c in ipairs(line) do local hh = measure(c, c._w); if hh > lh then lh = hh end end
    line._h = lh
    total = total + lh + (li > 1 and M.wrapGap or 0)
  end
  node._lines = lines
  return total
end

-- Pass 2 — measure heights, bottom-up. Each leaf measures at its now-known content width (wrapping text
-- included). A COLUMN's height = Σ children + gaps; a ROW's = max(children); a WRAP row's = its packed
-- lines. Plus insets. The natural height is cached (_natH) so pass 3's fill can grow from it.
function measure(node, outerW)
  outerW = outerW or node._w
  local it, ir, ib, il = insets(node)
  if node.leaf then
    node._h = node.mh(outerW - il - ir) + it + ib
    node._natH = node._h
    return node._h
  end
  local kids = kidsOf(node)
  local contentH
  if node.dir == "row" and not node.wrap then
    local maxh = 0
    for _, c in ipairs(kids) do local hh = measure(c, c._w); if hh > maxh then maxh = hh end end
    contentH = maxh
  elseif node.dir == "row" and node.wrap then
    contentH = measureWrap(node, kids, outerW - il - ir)
  else
    local sum, n = 0, #kids
    for _, c in ipairs(kids) do sum = sum + measure(c, c._w) end
    contentH = sum + math.max(0, n - 1) * node.gap
  end
  node._h = it + ib + contentH
  node._natH = node._h
  return node._h
end

-- Column placement: stack children on the vertical MAIN axis. Vertical `grow` fills leftover height
-- (the "fill" case). `justify` distributes free space when nothing grew (start/center/end/between);
-- `align` sets each child's cross-axis (horizontal) x.
function placeColumn(node, kids, cx, cyTop, cw, ch)
  local n, gap = #kids, node.gap
  local natTotal, totalGrow = math.max(0, n - 1) * gap, 0
  for _, c in ipairs(kids) do
    natTotal = natTotal + (c._natH or c._h or 0)
    totalGrow = totalGrow + (c.grow or 0)
  end
  local leftover = ch - natTotal
  for _, c in ipairs(kids) do
    local hh = c._natH or c._h or 0
    if leftover > 0 and totalGrow > 0 then hh = hh + leftover * (c.grow or 0) / totalGrow end
    c._alloc = hh
  end
  local used = math.max(0, n - 1) * gap
  for _, c in ipairs(kids) do used = used + c._alloc end
  local free = ch - used
  local startY, extraGap = 0, gap
  if totalGrow <= 0 and free > 0 then
    if node.justify == "center" then startY = free / 2
    elseif node.justify == "end" then startY = free
    elseif node.justify == "between" and n > 1 then extraGap = gap + free / (n - 1) end
  end
  local yy = cyTop - startY
  for _, c in ipairs(kids) do
    local xx = cx
    if node.align == "center" then xx = cx + (cw - c._w) / 2
    elseif node.align == "end" then xx = cx + (cw - c._w) end
    place(c, xx, yy, c._w, c._alloc)
    yy = yy - c._alloc - extraGap
  end
end

-- Row placement: lay children along the horizontal MAIN axis. Widths were fixed in pass 1 (grow already
-- shared), so `justify` only positions any leftover; `align` sets each child's cross-axis (vertical) y
-- and, for stretch, its height to the row height.
function placeRow(node, kids, cx, cyTop, cw, ch)
  local n, gap = #kids, node.gap
  local sumW = 0
  for _, c in ipairs(kids) do sumW = sumW + c._w end
  local free = cw - (sumW + math.max(0, n - 1) * gap)
  local startX, extraGap = 0, gap
  if free > 0 then
    if node.justify == "center" then startX = free / 2
    elseif node.justify == "end" then startX = free
    elseif node.justify == "between" and n > 1 then extraGap = gap + free / (n - 1) end
  end
  local xx = cx + startX
  for _, c in ipairs(kids) do
    local hh, yy = (c._natH or c._h or 0), cyTop
    if node.align == "stretch" then hh = ch
    elseif node.align == "center" then yy = cyTop - (ch - hh) / 2
    elseif node.align == "end" then yy = cyTop - (ch - hh) end
    place(c, xx, yy, c._w, hh)
    xx = xx + c._w + extraGap
  end
end

-- Wrap-row placement: place each packed line as a start-justified row; lines stack downward with wrapGap.
function placeWrap(node, kids, cx, cyTop, cw)
  local lines = node._lines or wrapLines(node, kids, cw)
  local gap, yy = node.gap, cyTop
  for li, line in ipairs(lines) do
    if li > 1 then yy = yy - M.wrapGap end
    local lh = line._h or 0
    if not line._h then
      for _, c in ipairs(line) do local hh = measure(c, c._w); if hh > lh then lh = hh end end
    end
    local xx = cx
    for _, c in ipairs(line) do
      place(c, xx, yy, c._w, c._natH or c._h or lh)
      xx = xx + c._w + gap
    end
    yy = yy - lh
  end
end

-- Pass 3 — place, top-down. Fix this box's rectangle, then position children within the content region
-- per `dir`. Leaves just record their rectangle (the frame layer stamps the control in applyGeom).
function place(node, x, y, w, h)
  node._x, node._y, node._w, node._h = x, y, w, h
  if node.leaf then return end
  local it, ir, ib, il = insets(node)
  local cw, ch = w - il - ir, h - it - ib
  local cx, cyTop = il, -it
  local kids = kidsOf(node)
  if node.dir == "row" and not node.wrap then placeRow(node, kids, cx, cyTop, cw, ch)
  elseif node.dir == "row" and node.wrap then placeWrap(node, kids, cx, cyTop, cw)
  else placeColumn(node, kids, cx, cyTop, cw, ch) end
end

-- ============================ frame layer — tree builder ============================
local buildNode   -- forward (recursion)
local wrapBox     -- forward (defined with the Box wrapper below)

local function stubLeaf(node)
  -- Placeholder sizing until the real leaf builders land (Task 5). A nominal one-row control.
  node.mh = function() return M.rowH end
  node.nw = function() return M.rowH * 4 end
  node.lw = function() return M.rowH * 2 end
  node._applyLeaf = function() end
end

-- Reposition a section's header/underline within the box, and (bg is anchored to the frame corners at
-- build so it needs no repositioning). The header sits at the box's pad inset + sectionTop; the section
-- reservation (secInsT/secInsL) already carved out the space in the pure passes, so this only paints it.
local function decorPlace(node)
  local fs, line = node._headerFS, node._headerLine
  if not fs then return end
  local px, py = node.pad.l, node.pad.t + M.sectionTop
  fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", node._frame, "TOPLEFT", px, -py)
  if line then
    local cw = (node._w or 0) - node.pad.l - node.pad.r
    line:ClearAllPoints(); line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3)
    line:SetWidth(node.lineW or math.max(40, cw))
  end
end

-- Build a container box's decoration: a `section` gets an accent title (+ optional trailing `desc`) and
-- an underline; `bg` paints a ContentPanel behind the whole box. The header widgets are created here and
-- placed each layout by decorPlace (hung on node._decor); the bg panel anchors to the frame so it tracks.
local function buildDecor(node, frame)
  if node.section then
    -- Reuse the shared fixture (accent title + underline + desc/lineW) instead of re-rolling it; the
    -- initial x/y is provisional — decorPlace re-anchors both each layout as the box width settles.
    local fs, line = Theme.SectionHeader(frame, node.pad.l, -(node.pad.t + M.sectionTop),
      node.section, { desc = node.desc, lineW = node.lineW })
    node._headerFS, node._headerLine = fs, line
    node._decor = decorPlace
  end
  if node.bg then
    Theme.ContentPanel(frame, type(node.bg) == "table" and node.bg or nil)
  end
end

-- ============================ leaf builders ============================
-- Each leaf builder creates its control(s) parented to the leaf's frame, then hangs the pure-core
-- closures on the node: mh(contentWidth) -> height, nw() -> natural width, lw() -> min width, and
-- _applyLeaf(node) which positions the control(s) inside the placed rectangle. node._widget is the
-- primary control (returned via refs / onBuild). Help hover-zones and slider top-pad are baked in so a
-- caller can't wire them wrong.
local CB_HIT = 24   -- checkbox hit area (the visible box is smaller; matches Theme.Checkbox / Columns:Check)

-- A tooltip hover-zone covering the whole row (box + label, per [[tooltips-cover-whole-row]]). `help` is:
--   * a string -> shown as a plain wrapped block; OR
--   * a function fn(owner) -> a RENDER FUNCTION that draws its own tooltip (SetOwner/SetText/AddLine/Show,
--     e.g. an accent title + body) and returns nothing; if it instead returns a string, that string is
--     rendered as the plain block (so an older text-returning fn still works). Backward-compatible.
local function attachHelp(zone, help)
  if not help then return end
  zone:EnableMouse(true)
  zone:SetScript("OnEnter", function(self)
    local text = help
    if type(help) == "function" then
      text = help(self)          -- render fn draws its own tooltip; may return a plain string instead
      if text == nil then return end
    end
    if type(text) ~= "string" or text == "" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  zone:SetScript("OnLeave", GameTooltip_Hide)
end

-- checkbox + wrapping label + a help hover-zone covering both. `indent` (in metrics.indent units) shifts
-- the whole control right for a sub-row conditioned on a parent toggle.
local function leafCheck(node, spec, frame)
  local d = spec.check
  local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  cb:SetSize(CB_HIT, CB_HIT)
  cb:SetChecked(d.get and d.get() or false)
  if d.set then cb:SetScript("OnClick", function(s) d.set(s:GetChecked() and true or false) end) end
  Theme.Checkbox(cb)
  local lbl = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  lbl:SetJustifyH("LEFT"); lbl:SetText(d.label or ""); Theme.Font(lbl, "text")
  local zone = CreateFrame("Frame", nil, frame)
  attachHelp(zone, d.help)
  node._indent = (d.indent or 0) * M.indent
  local textX = function() return node._indent + CB_HIT + 2 end
  node.mh = function(cw)
    local th = Theme.MeasureWrappedHeight(d.label or "", math.max(10, cw - textX()), "GameFontHighlight")
    return math.max(CB_HIT, th)
  end
  node.nw = function() return textX() + math.ceil((lbl:GetStringWidth() or 0)) + 4 end
  node.lw = function() return textX() + math.min(math.ceil((lbl:GetStringWidth() or 0)), 80) end
  node._applyLeaf = function(n)
    local x = node._indent
    cb:ClearAllPoints(); cb:SetPoint("TOPLEFT", frame, "TOPLEFT", x, 0)
    local lw = math.max(10, (n._w or 0) - textX())
    -- vertically CENTER the label on the checkbox (LEFT->RIGHT anchor, pillar-2: never TOP/baseline) so a
    -- one-line label lines up with the 24px box instead of riding high; a wrapping label centers its block.
    lbl:ClearAllPoints(); lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0); lbl:SetWidth(lw)
    zone:ClearAllPoints(); zone:SetPoint("TOPLEFT", frame, "TOPLEFT", x, 0)
    zone:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", textX() + lw, -(n._h or M.rowH))
  end
  node._widget = cb
end

-- a dim, word-wrapping note/help paragraph. note = "text" | { text, color=<palette role> }.
-- A note's space is ALWAYS protected: it word-wraps to the width it's given and reserves the full wrapped
-- height (measure and place use the same resolved width, so nothing ever overlaps it). And unless the spec
-- pins an explicit maxWidth, a note is capped at metrics.noteMaxW (~320) — so in a wide/unbounded context
-- it folds to a readable paragraph instead of demanding its entire one-line string width (which would
-- overrun horizontally AND inflate the parent, pushing the window off-screen).
local function leafNote(node, spec, frame)
  local d = spec.note
  local text = (type(d) == "table") and d.text or d
  local role = (type(d) == "table" and d.color and Theme.colors[d.color]) and d.color or "textDim"
  local fs = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT"); fs:SetWordWrap(true); fs:SetText(text or ""); Theme.Font(fs, role)
  if not node.maxW then node.maxW = M.noteMaxW end   -- default paragraph cap (explicit maxWidth wins)
  node.mh = function(cw) return Theme.MeasureWrappedHeight(text or "", math.max(10, cw), "GameFontHighlightSmall") end
  node.nw = function() return math.ceil((fs:GetStringWidth() or 0)) end
  node.lw = function() return 60 end
  node._applyLeaf = function(n)
    fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0); fs:SetWidth(math.max(10, n._w or 0))
  end
  node._widget = fs
end

-- a single button. button = { text, onClick, width } or a pre-built control frame.
local function leafButton(node, spec, frame)
  local d = spec.button
  local btn
  if type(d) == "table" and d.GetObjectType then
    btn = d; btn:SetParent(frame)
  else
    d = (type(d) == "table") and d or {}
    btn = Theme.MakeButton(frame, d.width or 90, d.text or "", d.onClick)
  end
  local bw = btn:GetWidth() or 90
  node.mh = function() return math.max(M.rowH, btn:GetHeight() or M.rowH) end
  node.nw = function() return bw end
  node.lw = function() return bw end
  node._applyLeaf = function() btn:ClearAllPoints(); btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0) end
  node._widget = btn
end

-- a horizontal group of buttons. buttons = { { text, onClick, width }, ... }.
local function leafButtons(node, spec, frame)
  local list = spec.buttons or {}
  local gap, btns, total = 6, {}, 0
  for i, b in ipairs(list) do
    local w = b.width or 90
    btns[i] = Theme.MakeButton(frame, w, b.text or "", b.onClick)
    total = total + w + (i > 1 and gap or 0)
  end
  node.mh = function() return M.rowH end
  node.nw = function() return total end
  node.lw = function() return total end
  node._applyLeaf = function()
    local x = 0
    for _, btn in ipairs(btns) do
      btn:ClearAllPoints(); btn:SetPoint("TOPLEFT", frame, "TOPLEFT", x, 0)
      x = x + (btn:GetWidth() or 90) + gap
    end
  end
  node._widget = btns
end

-- label above + a stepper slider below, with the live value right-aligned. Reserves the label line then
-- the slider, compensating SLIDER_TOP_PAD (the visible track sits ~12px below the slider frame's top).
local function leafSlider(node, spec, frame)
  local d = spec.slider
  local lbl = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  lbl:SetJustifyH("LEFT"); lbl:SetText(d.label or ""); Theme.Font(lbl, "text")
  local val = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  val:SetJustifyH("RIGHT"); Theme.Font(val, "textDim")
  local function fmt(v) return d.format and d.format(v) or tostring(v) end
  local minv, maxv, step = d.min or 0, d.max or 1, d.step or 1
  local steps = (step > 0) and math.floor((maxv - minv) / step + 0.5) or 20
  local cur = (d.get and d.get()) or minv
  local s = Theme.Slider(frame, {
    width = d.width or 190, min = minv, max = maxv, steps = steps, value = cur,
    onChange = function(v) if d.set then d.set(v) end; val:SetText(fmt(v)) end,
  })
  val:SetText(fmt(cur))
  local TOP = Theme.SLIDER_TOP_PAD or 12
  local sh = (s.GetHeight and s:GetHeight()) or 32
  node.mh = function() return M.rowH + sh - TOP end
  node.nw = function() return d.width or 190 end
  node.lw = function() return math.min(d.width or 190, 160) end
  node._applyLeaf = function(n)
    lbl:ClearAllPoints(); lbl:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    val:ClearAllPoints(); val:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    s:ClearAllPoints(); s:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(M.rowH) + TOP)
    if s.SetWidth then s:SetWidth(math.max(60, n._w or 190)) end
  end
  node._widget = s
end

-- label + a skinned dropdown pinned to the box's right edge. dropdown = { label, control } where control
-- is a pre-built skinned dropdown or a build function(parent)->dropdown; { options, get, set } also works.
local function leafDropdown(node, spec, frame)
  local d = spec.dropdown
  local lbl
  if d.label then
    lbl = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lbl:SetJustifyH("LEFT"); lbl:SetText(d.label); Theme.Font(lbl, "text")
  end
  local dd
  if type(d.control) == "function" then dd = d.control(frame)
  elseif d.control then dd = d.control; dd:SetParent(frame)
  elseif d.options then dd = Theme.Dropdown(frame, d) end
  if dd then Theme.SkinDropdown(dd) end
  local ddW = (dd and dd.GetWidth and dd:GetWidth()) or 160
  node.mh = function() return M.rowH end
  node.nw = function() return (lbl and (math.ceil((lbl:GetStringWidth() or 0)) + M.labelGap) or 0) + ddW end
  node.lw = function() return ddW end
  node._applyLeaf = function()
    if lbl then lbl:ClearAllPoints(); lbl:SetPoint("LEFT", frame, "LEFT", 0, 0) end
    if dd then dd:ClearAllPoints(); dd:SetPoint("RIGHT", frame, "RIGHT", 0, 0) end
  end
  node._widget = dd
end

-- label + editbox (+ optional trailing suffix). grow => the editbox stretches to the box's right edge;
-- multiline => a scrolling MultilineEditBox reserving `lines` rows.
local function leafEdit(node, spec, frame)
  local d = spec.edit
  local lbl
  if d.label then
    lbl = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lbl:SetJustifyH("LEFT"); lbl:SetText(d.label); Theme.Font(lbl, "text")
  end
  local suffixFS
  if d.suffix then
    suffixFS = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    suffixFS:SetText(d.suffix); Theme.Font(suffixFS, "textDim")
  end
  local isMulti, eb, ctrl = d.multiline and true or false
  if isMulti then
    local sf, e = Theme.MultilineEditBox(frame, {
      onChanged = function(self, user) if user and d.set then d.set(self:GetText()) end end,
    })
    ctrl, eb = sf, e
  else
    eb = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    eb:SetAutoFocus(false); eb:SetHeight(20); Theme.EditBox(eb)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    if d.set then eb:SetScript("OnEnterPressed", function(s) d.set(s:GetText()); s:ClearFocus() end) end
    ctrl = eb
  end
  if d.get then eb:SetText(d.get() or "") end
  local fixedW, lines = d.width or 120, d.lines or 4
  local labelH = lbl and M.rowH or 0
  local suffixW = function() return suffixFS and (math.ceil((suffixFS:GetStringWidth() or 0)) + 6) or 0 end
  node.mh = function() return isMulti and (labelH + lines * 16 + 8) or M.rowH end
  node.nw = function()
    return (lbl and (math.ceil((lbl:GetStringWidth() or 0)) + M.labelGap) or 0) + fixedW + suffixW()
  end
  node.lw = function() return 100 end
  node._applyLeaf = function(n)
    local x = 0
    if lbl then lbl:ClearAllPoints(); lbl:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -2); x = math.ceil((lbl:GetStringWidth() or 0)) + M.labelGap end
    ctrl:ClearAllPoints()
    if isMulti then
      ctrl:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -labelH)
      ctrl:SetPoint("RIGHT", frame, "RIGHT", -2, 0); ctrl:SetHeight(lines * 16)
    else
      ctrl:SetPoint("TOPLEFT", frame, "TOPLEFT", x, 0); ctrl:SetHeight(20)
      if d.grow then ctrl:SetPoint("RIGHT", frame, "RIGHT", -suffixW(), 0) else ctrl:SetWidth(fixedW) end
      if suffixFS then suffixFS:ClearAllPoints(); suffixFS:SetPoint("LEFT", ctrl, "RIGHT", 4, 0) end
    end
  end
  node._widget = eb
end

-- Height of a hosted widget, per the escape-hatch contract: an explicit height option wins, else the
-- widget's own GetContentHeight() (its intrinsic content size), else its GetHeight(). Pure so the
-- precedence is unit-testable with a stub widget.
local function hostHeight(widget, heightOpt)
  if heightOpt then return heightOpt end
  if widget and widget.GetContentHeight then
    local ch = widget:GetContentHeight()
    if ch and ch > 0 then return ch end
  end
  if widget and widget.GetHeight then return widget:GetHeight() or 0 end
  return 0
end

-- ESCAPE HATCH: host a bespoke widget (a tree, pooled list, pixel grid, …) by placing it and owning the
-- whitespace around it; its internals are untouched. frame = widget, or { widget = w, height = n }. The
-- box reports the widget's height (hostHeight), stretches its width on align="stretch", fills it when
-- `grow` is set, and wires widget.Invalidate so a rebuild that changes size triggers ONE root relayout
-- (coalesced by Box:Invalidate) that re-stacks everything below.
local function leafFrame(node, spec, frame)
  local widget, heightOpt = spec.frame, spec.height
  if type(widget) == "table" and not widget.GetObjectType then
    heightOpt = widget.height or heightOpt
    widget = widget.widget or widget[1]
  end
  if widget and widget.SetParent then widget:SetParent(frame) end
  node._hosted = widget
  node.mh = function() return math.max(0, hostHeight(widget, heightOpt)) end
  node.nw = function() return (widget and widget.GetWidth and widget:GetWidth()) or 0 end
  node.lw = function() return 0 end
  node._applyLeaf = function(n)
    if not widget then return end
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    if node.align == "stretch" and widget.SetWidth then widget:SetWidth(math.max(1, n._w or 1)) end
    if (node.grow or 0) > 0 and widget.SetHeight then widget:SetHeight(math.max(1, n._h or 1)) end
  end
  if widget then
    local prev = widget.Invalidate
    widget.Invalidate = function(...)
      if prev then prev(...) end
      local rn = node._root or node
      if rn._box then rn._box:Invalidate() end   -- coalesced -> one root relayout, re-stacking below
    end
  end
  node._widget = widget
end

local LEAF_BUILDERS = {
  check = leafCheck, note = leafNote, button = leafButton, buttons = leafButtons,
  slider = leafSlider, dropdown = leafDropdown, edit = leafEdit, frame = leafFrame,
}
local function buildLeaf(node, spec, frame)
  local builder = LEAF_BUILDERS[node.leafType]
  if not builder then return false end
  builder(node, spec, frame)
  return true
end

function buildNode(parentFrame, spec, root, refs, depth)
  local node = nodeFromProps(boxProps(spec))
  node.depth = depth or 0
  applySectionInsets(node)
  local frame = CreateFrame("Frame", nil, parentFrame)
  node._frame = frame
  node._parentFrame = parentFrame
  node._root = root   -- nil for the root; threaded down so any descendant can request a relayout

  local lt = leafType(spec)
  if lt then
    node.leaf = true
    node.leafType = lt
    node.leafSpec = spec[lt]
    node.spec = spec
    if not buildLeaf(node, spec, frame) then stubLeaf(node) end   -- stubLeaf: defensive fallback for an unknown leaf key
    local d = spec[lt]
    if type(d) == "table" and d.onBuild then d.onBuild(node._widget) end
    if node.id then refs[node.id] = node._widget or frame end   -- leaf id -> its built control
  else
    buildDecor(node, frame)   -- section header/underline + bg panel (positioned in applyGeom's decor)
    for _, childSpec in ipairs(spec) do
      node.children[#node.children + 1] = buildNode(frame, childSpec, root or node, refs, node.depth + 1)
    end
    if node.id then refs[node.id] = wrapBox(node) end   -- container id -> its Box handle
  end
  return node
end

-- Copy computed geometry onto the real frames, recursively. Hidden children are shown/hidden here so a
-- toggled `hidden` re-stacks cleanly on the next Layout.
local function applyGeom(node)
  local f = node._frame
  if f then
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", node._parentFrame, "TOPLEFT", node._x or 0, node._y or 0)
    f:SetSize(math.max(1, node._w or 1), math.max(1, node._h or 1))
  end
  if node.leaf then
    if node._applyLeaf then node._applyLeaf(node) end
    return
  end
  if node._decor then node._decor(node) end
  for _, c in ipairs(node.children) do
    if c._frame then c._frame:SetShown(not c.hidden) end
    if not c.hidden then applyGeom(c) end
  end
end

-- Detach every child of a node: hide its frame (which hides its whole subtree, since children parent to
-- it) and drop it from node.children. Guarded on _frame so frameless test nodes work. WoW frames can't be
-- destroyed, so a hidden orphan is the correct "release"; a rebuild via :Add re-fills the tree.
local function clearChildren(node)
  for _, c in ipairs(node.children) do
    if c._frame then c._frame:Hide(); c._frame:ClearAllPoints() end
  end
  node.children = {}
end

-- ============================ Box wrapper (public handle) ============================
local Box = {}
Box.__index = Box

-- Attach a Box handle to a node (cheap; created for the root + any id'd container so refs can hand it back).
function wrapBox(node)
  if node._box then return node._box end
  local b = setmetatable({ node = node }, Box)
  node._box = b
  return b
end

local function rootNode(node) return node._root or node end

function Box:GetFrame()  return self.node._frame end
function Box:GetHeight() return self.node._h or 0 end
function Box:GetWidth()  return self.node._w or 0 end
function Box:MinWidth()  return minWidth(self.node) end
-- Natural (preferred, unwrapped) width of the whole subtree — the width at which nothing wraps, honoring
-- each node's maxW cap (so a long note folds to its noteMaxW rather than demanding its full string). A
-- shrink-to-fit popup sizes its content host to this so it's exactly as wide as its widest row.
function Box:NaturalWidth() return naturalWidth(self.node) end

function Box:ResolveWidth(w) resolveWidths(self.node, w); return self end
function Box:Measure(w)      return measure(self.node, w or self.node._w) end
function Box:Place(x, y, w, h) place(self.node, x, y, w, h); applyGeom(self.node); return self end

-- Deferred settle: WoW font/width metrics settle a frame a beat late, so re-run the layout on the
-- owning frame's OnShow and OnSizeChanged (a wrapping label only reports its true height once the frame
-- has a real width). Hooked once. A pure height change is ignored (we DRIVE the height, so reacting to
-- it would ping-pong) — only a WIDTH change or a show re-lays out.
function Box:_installSettle()
  if self._settleHooked then return end
  local settle = self._settleFrame or self.node._parentFrame
  if not (settle and settle.HookScript) then return end
  self._settleHooked = true
  settle:HookScript("OnShow", function() self:Invalidate() end)
  settle:HookScript("OnSizeChanged", function(_, w)
    if w and self._lastW and math.abs(w - self._lastW) < 0.5 then return end   -- height-only: skip
    self:Invalidate()
  end)
end

-- Run the full three-pass layout from the root's parent width and stamp the frames. Fill mode: if the
-- root contains a vertical-`grow` child and its parent is taller than the natural content, the root
-- fills the parent's height (tab-content "a few rows + one region that fills the rest"). Otherwise the
-- root is content-height, and (opt-in) drives a scroll child's height so the scrollbar tracks it.
function Box:Layout()
  local node = self.node
  if node._root then return rootNode(node)._box:Layout() end   -- always lay out from the true root
  if self._laying then return self end                          -- re-entrancy guard (Invalidate storms)
  self:_installSettle()   -- arm OnShow/OnSizeChanged FIRST, so a not-yet-sized parent still re-lays on show
  local parent = node._parentFrame
  local availW = (parent and parent.GetWidth and parent:GetWidth()) or 0
  if not availW or availW <= 0 then availW = self._lastW or 0 end
  if availW <= 0 then return self end   -- parent has no width yet (hidden tab); the settle pass re-runs when it does
  self._laying = true
  self._lastW = availW
  resolveWidths(node, availW)
  local natH = measure(node, node._w)
  local outerH, hasGrow = natH, false
  for _, c in ipairs(kidsOf(node)) do   -- VISIBLE children only: a hidden grow child mustn't reserve fill space
    if (c.grow or 0) > 0 then hasGrow = true; break end
  end
  local ph = (parent and parent.GetHeight and parent:GetHeight()) or 0
  if hasGrow and ph and ph > natH then outerH = ph end
  place(node, 0, 0, node._w, outerH)
  applyGeom(node)
  if self._setParentHeight and parent and parent.SetHeight then parent:SetHeight(outerH) end
  self._laying = false
  return self
end

-- Live relayout after content changed size. Coalesced to one root pass on the next frame so a storm of
-- Invalidate() calls (e.g. several hosted widgets rebuilding at once) collapses into a single layout.
function Box:Invalidate()
  local root = rootNode(self.node)._box
  if root._invalidatePending then return self end
  root._invalidatePending = true
  local run = function() root._invalidatePending = false; root:Layout() end
  if C_Timer and C_Timer.After then C_Timer.After(0, run) else run() end
  return self
end

-- Derive the window's minimum (width, height) from the content so labels never clip. Width bubbles from
-- MinWidth(); height is MEASURED AT THAT MIN WIDTH (the narrowest layout wraps the most, so it's the
-- tallest — measuring here is what guarantees nothing clips when the user shrinks the window). Pure, so
-- the derivation is unit-testable; the frame-level SetResizeBounds lives in Box:ApplyMinSize.
local function minSize(node, o)
  o = o or {}
  local minW = math.ceil(math.max(o.floorW or 0, minWidth(node) + (o.chromeW or 0)))
  resolveWidths(node, minW)
  local h = measure(node, node._w)
  local minH = math.ceil(math.max(o.floorH or 0, h + (o.chromeH or 0)))
  return minW, minH
end

-- Layout:ApplyMinSize(window, { chromeH, chromeW, floorH, floorW }) -> minW, minH. Sets the window's
-- SetResizeBounds from the derived content minimum, grows the window if it is currently below that, then
-- re-lays out so the (temporarily min-width) node geometry is restored to the real available width.
function Box:ApplyMinSize(window, o)
  local minW, minH = minSize(self.node, o)
  if window.SetResizeBounds then window:SetResizeBounds(minW, minH)
  elseif window.SetMinResize then window:SetMinResize(minW, minH) end
  if (window:GetWidth() or 0) < minW then window:SetWidth(minW) end
  if (window:GetHeight() or 0) < minH then window:SetHeight(minH) end
  self._minW, self._minH = minW, minH
  self:Layout()
  return minW, minH
end

-- Imperative escape for dynamically built content. Add(spec) builds a child via the same tree-builder
-- path (so leaves/sections/ids all work), appends it, and relayouts; ids land in the ROOT box's refs.
-- Returns the built child's widget (leaf) or Box handle (container). Clear() detaches all children and
-- relayouts (the page re-stacks around the now-empty box).
function Box:Add(spec)
  local node = self.node
  local rn = rootNode(node)
  local refs = rn._box.refs or {}
  rn._box.refs = refs
  local child = buildNode(node._frame, spec, rn, refs, (node.depth or 0) + 1)
  node.children[#node.children + 1] = child
  self:Invalidate()
  return child.leaf and child._widget or wrapBox(child)
end

function Box:Clear()
  clearChildren(self.node)
  self:Invalidate()
  return self
end

-- ============================ public entry points ============================
-- Theme.Box(parent, spec) -> a box handle around a freshly built (frame) subtree. The imperative escape
-- for dynamically built content; :Add/:Clear rebuild it and re-stack the page.
function Theme.Box(parent, spec)
  local refs = {}
  local box = wrapBox(buildNode(parent, spec or {}, nil, refs))
  box.refs = refs
  return box
end

-- Theme.Layout(parent, tree, opts) -> (rootBox, refs). The declarative surface: `tree` is a box spec
-- whose array entries are children and named keys are properties. Every id in the tree is collected into
-- refs (id -> the built Box for a container, or the widget/frame for a leaf). opts.setParentHeight
-- (default true) drives the parent's height from the measured content — right for a scroll child.
-- opts.settle overrides the frame whose OnShow/OnSizeChanged re-runs layout (default: the parent frame).
-- The initial :Layout() runs here and ARMS the deferred settle automatically, so a caller never has to
-- remember to call :Layout() or pass a settle frame — a page built while its parent is still 0-width
-- (a hidden tab) lays out correctly the moment it's shown at its real width.
function Theme.Layout(parent, tree, opts)
  opts = opts or {}
  local refs = {}
  local root = wrapBox(buildNode(parent, tree or {}, nil, refs))
  root.refs = refs                  -- also stashed on the root so :Add can register new ids into it
  root._setParentHeight = (opts.setParentHeight ~= false)
  root._settleFrame = opts.settle   -- OnShow/OnSizeChanged source (default: the parent) for the settle pass
  root:Layout()                     -- initial pass + arms the auto settle (re-runs on the parent's OnShow/resize)
  return root, refs
end

-- Theme.MeasureWrappedHeight(text, width, fontObj) -> the pixel height `text` occupies word-wrapped to
-- `width`. Uses a single hidden scratch fontstring (no visible frame needed to measure text). This is
-- what wrapping leaves (note/check labels) call so their height is correct at any column width.
local scratchFS
function Theme.MeasureWrappedHeight(text, width, fontObj)
  if not scratchFS then
    scratchFS = UIParent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    scratchFS:Hide()
  end
  scratchFS:SetFontObject(fontObj or "GameFontHighlight")
  if width and width > 0 then scratchFS:SetWidth(width) end
  scratchFS:SetWordWrap(true)
  scratchFS:SetText(text or "")
  return math.ceil((scratchFS:GetStringHeight() or 0) + 0.5)
end

-- ============================ pure helpers exposed for headless unit tests ============================
Theme._boxLeafType   = leafType
Theme._boxResolveGap = resolveGap
Theme._boxResolvePad = resolvePad
Theme._boxProps      = boxProps
Theme._boxCollectIds = collectIds

-- Frameless node constructors for headless layout tests: build a pure node from a spec + child nodes,
-- and a fixed-size leaf (mh/nw/lw closures). The pure passes are exposed so a test can drive all three.
function Theme._boxNode(spec, children, leaf)
  local node = nodeFromProps(boxProps(spec))
  node.children = children or {}
  applySectionInsets(node)
  if leaf then node.leaf = true; node.mh = leaf.mh; node.nw = leaf.nw; node.lw = leaf.lw end
  return node
end
function Theme._boxLeaf(height, natW, minWpx)
  return Theme._boxNode({}, nil, {
    mh = function() return height end,
    nw = function() return natW or height end,
    lw = function() return minWpx or natW or height end,
  })
end
Theme._boxResolveWidths = resolveWidths
Theme._boxMeasure       = measure
Theme._boxPlace         = place
Theme._boxMinWidth      = minWidth
Theme._boxNaturalWidth  = naturalWidth
Theme._boxMinSize       = minSize
Theme._boxHostHeight    = hostHeight
Theme._boxClearChildren = clearChildren
