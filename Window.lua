-- Window.lua — the collapsible Haul bar.
--   Collapsed: a thin bar showing the timer + counted gold (+ token%), with a
--              sync nudge and expand arrow.
--   Expanded:  running-stats panel + a collapsible, scrollable item list +
--              bottom buttons (Reset / Start-Stop / Save / Options).
local ADDON, ns = ...
local Theme = LibStub("GECTheme-1.0").ForAddon(function() return (HaulDB and HaulDB.themePreset) or "gruvbox" end)

local WIDTH       = 300
local BAR_H       = 26
local STATS_H     = 110
local LIST_H      = 168
local BTN_H       = 30
local ROW_H       = 18

-- Header template colors come from GECTheme so every addon shares one palette.
ns.ColorToHex = Theme.ColorToHex
ns.ColorName  = Theme.ColorName
-- "source" is backed by Theme.accentHex so a palette swap picks it up at render time.
local TOKEN_DEFAULT_COLOR = setmetatable({
  time = "eda55f", ["time.timer"] = "eda55f", ["time.current"] = "eda55f",
  ["time.current.ampm"] = "eda55f",
  ["time.ig"] = "eda55f", token = "66ccff", ["token.percent"] = "66ccff",
  ["token.trend"] = "ffffff",
  items = "ffffff", ["items.count"] = "ffffff", ["items.last.count"] = "ffffff",
  -- notable / items.notable are now self-colored (the count is wrapped in the notable-quality color
  -- in BuildFields, see notableCount), so they live in MONEY_TOKENS below — not here.
  rep = "1eff00", ["rep.amount"] = "1eff00", ["rep.faction"] = "ffffff",
  zone = "ffffff", ["zone.full"] = "ffffff", ["zone.region"] = "ffffff",
  ["zone.zone"] = "ffffff", ["zone.sub"] = "ffffff",
}, { __index = function(_, k) if k == "source" then return Theme.accentHex end end })
-- price-trend display. Texture arrows (tinted) — the default WoW font has no ▲/▼
-- glyph, so Unicode triangles render as a box. Self-colored so the token's base
-- color can't recolor them. Kept identical to Megaphone's TrendText.
-- the :0:-3 is offsetX:offsetY — the negative Y drops the arrow down so it centers
-- on the text line instead of floating up at the baseline top.
local TR_UP   = "|TInterface\\Buttons\\Arrow-Up-Up:14:14:0:-3:32:32:0:32:0:32:30:255:0|t"
local TR_DOWN = "|TInterface\\Buttons\\Arrow-Down-Up:14:14:0:-3:32:32:0:32:0:32:255:96:96|t"
local TREND_DISPLAY = {
  up   = TR_UP   .. " |cff1eff00up|r",
  down = TR_DOWN .. " |cffff6060down|r",
  flat = "|cff808080flat|r",
}
-- self-colored tokens: money values + quality-colored item names. RenderTemplate
-- returns these verbatim so the template's base/`:color` can't recolor them. Every
-- money base also implies <base>.short (largest unit) and <base>.full (g/s/c).
local MONEY_TOKENS = {}
for _, n in ipairs({
  "haul", "total", "loot", "gross", "gross.perhour", "perhour", "cash",
  "token.price", "tokenprice", "token.value",
  "items.value", "items.price", "items.last.value", "items.last.price",
}) do
  MONEY_TOKENS[n], MONEY_TOKENS[n .. ".short"], MONEY_TOKENS[n .. ".full"] = true, true, true
end
-- quality-colored item names / composites (also returned verbatim)
for _, n in ipairs({ "items.last", "items.last.short", "items.last.full", "items.last.name",
                     "notable", "items.notable", "items.notable.label",
                     "rep.top", "rep.detail", "flushed" }) do
  MONEY_TOKENS[n] = true
end
-- notable threshold name + color, by quality (drives the "Uncommon+: N" label)
local QUALITY_INFO = {
  [1] = { name = "Common",    hex = "ffffff" },
  [2] = { name = "Uncommon",  hex = "1eff00" },
  [3] = { name = "Rare",      hex = "0070dd" },
  [4] = { name = "Epic",      hex = "a335ee" },
  [5] = { name = "Legendary", hex = "ff8000" },
}

local win

------------------------------------------------------------------ geometry --
local BTN_PAD     = 14    -- gaps + padding around the bottom buttons

local function Heights()
  local w = HaulDB.window
  local bh = win.barH or BAR_H
  if not w.expanded then return bh end
  local h = bh + (win.statsH or STATS_H) + BTN_H + BTN_PAD   -- stats panel grows to fit the detail template
  if w.listShown then h = h + (w.listH or LIST_H) end   -- user-resizable scrollable list height
  return h
end

local function Relayout()
  local w = HaulDB.window
  win:SetHeight(Heights())
  win.body:SetShown(w.expanded)
  win.list:SetShown(w.expanded and w.listShown)
  if win.UpdateCollapseSquare then win.UpdateCollapseSquare() end   -- +/- glyph follows listShown
  -- buttons are statically pinned to the body bottom (see BuildUI); the list
  -- flexes to fill the space above them, so nothing overflows.
end

-- Grow the bar to fit a multi-line header ({linewrap} / wrapping), then re-anchor
-- the body below it and resize the window.
local function UpdateBarHeight()
  local th = (win.barText:GetStringHeight() or 0)
  local pad = HaulDB.headerPad or 4
  local bh = math.max(BAR_H, math.ceil(th) + 2 * pad + 4)
  if bh ~= (win.barH or BAR_H) then
    win.barH = bh
    win.bar:SetHeight(bh)
    win.body:ClearAllPoints()
    win.body:SetPoint("TOPLEFT", 4, -bh)
    win.body:SetPoint("TOPRIGHT", -4, -bh)
    win.body:SetPoint("BOTTOM", win, "BOTTOM", 0, 4)
    Relayout()
  end
end

-- Bottom-row-only height when the detail text is hidden (list toggle + category + last-item line).
local STATS_COMPACT_H = 24

-- Grow the stats panel to fit the (variable-length) detail template, so the bottom row
-- (the list toggle + last-item line, pinned to win.stats's bottom) can't be overlapped.
-- When the detail panel is turned off (HaulDB.window.showDetail == false) we hide the detail
-- text and shrink the stats panel to just the bottom row, so the window compacts down to
-- bar + loot list — handy on small screens. The bottom row (list +/- toggle, category, last
-- item) stays visible so you can still drive the log.
local function UpdateStatsHeight()
  if not win or not win.statText then return end
  local show = HaulDB.window.showDetail ~= false   -- default on
  win.statText:SetShown(show)
  local needed
  if show then
    local th = math.ceil(win.statText:GetStringHeight() or 0)
    needed = math.max(STATS_H, 8 + th + 6 + 20)   -- top inset + text + gap + bottom row
  else
    needed = STATS_COMPACT_H
  end
  if needed ~= (win.statsH or STATS_H) then
    win.statsH = needed
    win.stats:SetHeight(needed)
    Relayout()
  end
end
ns.UpdateStatsHeight = UpdateStatsHeight   -- so the Options checkbox can re-apply on toggle

-- Position helpers that survive scale changes. We store the window's TOP-LEFT in
-- absolute SCREEN PIXELS; the SetPoint offset is in the frame's own scaled space,
-- so dividing pixels by the effective scale keeps the top-left pinned (the window
-- then grows down-and-right as you scale up, instead of drifting).
function ns.SaveWindowPos()
  if not win then return end
  local es = win:GetEffectiveScale()
  local l, t = win:GetLeft(), win:GetTop()
  if l and t and es and es > 0 then
    HaulDB.window.left, HaulDB.window.top = l * es, t * es
    HaulDB.window._px = true
  end
end

function ns.ApplyWindowPos()
  if not win then return end
  local w = HaulDB.window
  win:ClearAllPoints()
  if w.left and w.top then
    local es = win:GetEffectiveScale()
    local f = (w._px and es and es > 0) and (1 / es) or 1   -- _px = stored in pixels
    win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", w.left * f, w.top * f)
  else
    win:SetPoint("TOP", UIParent, "TOP", 0, -240)
  end
end

-- Apply the display settings (scale, font size/color, line spacing, padding).
-- The paused/active background tint (header + body), driven by IsTracking(). Kept SEPARATE from the
-- heavy ApplyHeaderStyle and called from RefreshUI every refresh, so the tint ALWAYS tracks the running
-- state — not only when SetTracking runs. Without this, a running change through a non-SetTracking path
-- (NewSession on reset/zone/login/instance, or the instance-leave restore) updates the buttons via
-- RefreshUI but leaves the tint stale, and SetTracking's early-return then can't recover it.
function ns.ApplyTrackingTint()
  if not win then return end
  local a = HaulDB.bgAlpha or 0.88
  local hb = HaulDB.headerBg or Theme.colors.headerBg
  local bb = HaulDB.bodyBg   or Theme.colors.bodyBg
  if not (ns.IsTracking and ns.IsTracking()) then        -- PAUSED: obvious red tint at a glance
    hb = HaulDB.pausedHeaderBg or Theme.colors.pausedHeaderBg
    bb = HaulDB.pausedBodyBg   or Theme.colors.pausedBodyBg
  end
  win:SetBackdropColor(hb[1], hb[2], hb[3], a)
  if win.body and win.body.SetBackdropColor then win.body:SetBackdropColor(bb[1], bb[2], bb[3], a) end
end

function ns.ApplyHeaderStyle()
  if not win then return end
  win:SetScale(HaulDB.scale or 1.0)
  ns.ApplyTrackingTint()   -- header/body paused-vs-active tint (also re-applied on every RefreshUI)
  ns.ApplyWindowPos()   -- re-pin top-left after the scale change
  local pad = HaulDB.headerPad or 4
  local size = HaulDB.headerFontSize or 12
  local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
  local path, _, flags = win.barText:GetFont()
  win.barText:SetFont(path or FONT, size, flags or "")
  win.barText:SetSpacing(HaulDB.headerSpacing or 2)
  win.barText:SetTextColor(ns.HexToRGB(HaulDB.headerColor or "ffffff"))
  local bpath, _, bflags = win.brand:GetFont()
  win.brand:SetFont(bpath or FONT, size, bflags or "")
  win.brand:ClearAllPoints(); win.brand:SetPoint("TOPLEFT", pad + 4, -(pad + 1))
  win.barText:ClearAllPoints()
  win.barText:SetPoint("TOPLEFT", win.brand, "TOPRIGHT", 6, 0)
  win.barText:SetPoint("RIGHT", win.bar, "RIGHT", -(pad + 18), 0)
  if ns.RefreshUI then ns.RefreshUI() end
end

local function SetExpanded(v) HaulDB.window.expanded = v and true or false; Relayout() end
local function SetListShown(v) HaulDB.window.listShown = v and true or false; Relayout() end
function ns.ToggleWindow()
  if not win then return end
  if win:IsShown() then win:Hide() else win:Show(); ns.RefreshUI() end
end

---------------------------------------------------------------- entries ------
-- The window's item list is now an ns.AccordionList over win.scrollChild (built in BuildUI). These
-- builders turn Haul's live data into the component's ordered descriptor array — one builder per
-- (category, view). See spec §4. The component is a pure renderer; open/closed state lives here in
-- HaulDB.window.groupOpen (seeded from each bucket's Options mode, then remembered per click).

-- bucket descriptors: the source + "can only vendor / excluded" accordions, in render order.
--   cat      = ComputeStats row marker ("bound"/"gray") or nil
--   excluded = true for the excluded bucket (matched on row.excluded instead of cat)
--   from     = acquisition source ("mail"/"craft") for the source buckets (matched on row.from; wins over cat)
--   mode     = the Options DB field whose value seeds the default open state (source buckets default closed)
-- All buckets render BELOW the regular counted loot, in THIS order: Soulbound, then the mail/craft
-- source buckets, then Vendor trash, then Excluded last.
local BUCKETS = {
  { key = "bound",    cat = "bound", label = "Soulbound",    color = "ffffff",
    icon = "Interface\\Icons\\INV_Misc_Key_03",         modeKey = "boundMode" },
  -- (mail moved out of Loot into its own Mail category, 2026-07-18 — see BuildMailCollectionEntries)
  -- (craft bucket removed 2026-07-21 — too buggy; a future crafting library will own it as its own tab)
  { key = "gray",     cat = "gray",  label = "Vendor trash", color = "9d9d9d",
    icon = 133784,                                       modeKey = "graysMode" },
  { key = "excluded", excluded = true, label = "Excluded",   color = "808080",
    icon = "Interface\\Buttons\\UI-GroupLoot-Pass-Up",  modeKey = "excludedMode" },
}

-- the click behavior every item row shares: shift/ctrl modified-click links/previews; a plain
-- click toggles inclusion. For loot that's the persistent exclude-from-gold state; for a mail/craft
-- row (data.from set) it's the one-off per-entry `keep` flag (keyed by the composite s.items key).
local function ItemClick(data)
  local link, id, from = data.link, data.id, data.from
  if IsModifiedClick and IsModifiedClick() then
    HandleModifiedItemClick(link)                       -- shift=link, ctrl=preview
  elseif from then
    Haul.ToggleEntryKeep(data.key)                       -- mail/craft: one-off include this captured stack
  elseif id then
    Haul.SetExcluded(id, not Haul.IsExcluded(id))        -- toggle exclude (click an excluded item to include it again)
  end
end

-- build an item descriptor for one loot row. `gray` renders the whole row dimmed (excluded items).
-- "% of drops" value for the percentage COLUMN when the Columns dropdown enables it. Only area drops
-- carry a pct (mail/craft are nil), so it shows only where it makes sense. Returns nil when off/absent.
-- render context: the builders + item helpers read these so the SAME code renders the LIVE session OR a
-- saved-session snapshot. The caller sets it before building (BuildEntries for live; BuildSessionEntries
-- for a snapshot). Builds are synchronous, so there's no re-entrancy.
local RCTX = {}
local function PctCol(pct)
  if RCTX.colPct and pct then return "|cff808080" .. string.format("%.1f%%", pct) .. "|r" end
  return nil
end

-- Loot-SOURCE icons for the opt-in "Source" column (Columns dropdown). `src` is the GECLoot classifier's
-- loot-source type stamped onto the item at capture (fish/kill/pickpocket/herb/mining/gather/chest/container).
-- Rendered as a small inline texture escape so the AccordionList's plain FontString column shows an ICON,
-- not a word (per the user's ask). Only present where we KNOW the source; nil collapses the (optional) column.
local SRC_ICONS = {
  fish       = "Interface\\Icons\\Trade_Fishing",
  kill       = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",   -- skull marker = mob kill
  pickpocket = "Interface\\Icons\\Ability_Rogue_PickPocket",
  herb       = "Interface\\Icons\\Trade_Herbalism",
  mining     = "Interface\\Icons\\Trade_Mining",
  gather     = "Interface\\Icons\\INV_Misc_Bag_08",                   -- generic "Opening"/gather
  chest      = "Interface\\Icons\\INV_Box_01",
  container  = "Interface\\Icons\\INV_Misc_Bag_10",
}
local function SrcCol(src)
  if not (RCTX.colSrc and src) then return nil end
  local tex = SRC_ICONS[src]
  if not tex then return nil end
  return "|T" .. tex .. ":13:13:0:0|t"
end

-- DEV tooltip: append Haul's internal metadata for a hovered item to the standard item tooltip, so the whole
-- captured data set (src / from / keep / pct / seq / key / value math …) is inspectable without a log dump.
-- Gated at build time via RCTX.devMeta (Haul.IsDev() + HaulDB.devTooltip); when off, entries carry no onEnter
-- and the AccordionList's default plain-hyperlink tooltip is used.
local function ItemMetaTip(row, data)
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if data.link then GameTooltip:SetHyperlink(data.link) else GameTooltip:SetText(data.name or "?") end
  local function ln(k, v) GameTooltip:AddDoubleLine(k, (v == nil) and "-" or tostring(v), 0.6, 0.6, 0.6, 1, 1, 1) end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("|cff66ccffHaul metadata|r")
  ln("id", data.id)
  ln("quality", data.quality)
  -- FULL precision (ns.Money, not MoneyShort) — this is a raw-metadata tooltip, so it must not drop
  -- sub-gold denominations (MoneyShort showed only the top unit → "4 x 1g = 5g" for a 1g45s item).
  GameTooltip:AddDoubleLine("count x unit = total", string.format("%s x %s = %s",
    tostring(data.count or "?"), data.unit and ns.Money(data.unit) or "?",
    data.total and ns.Money(data.total) or "?"), 0.6, 0.6, 0.6, 1, 1, 1)
  ln("unit (copper)", data.unit)   -- the exact stored integer the server sees (truest raw value)
  ln("loot src", data.src)
  if data.from then ln("acquire", data.from) end   -- only crafted/mailed items have an acquire source; hidden for normal loot
  ln("keep", data.keep and "yes" or "no")
  ln("excluded", data.excluded and "yes" or "no")
  if data.cat then ln("cat", data.cat) end
  if data.merged then ln("merged", data.merged) end
  if data.pct then ln("pct", string.format("%.1f%%", data.pct)) end
  ln("seq", data.seq)
  ln("key", data.key)
  GameTooltip:Show()
end

-- Generic metadata dump for NON-item rows (kills / XP mobs / currency / rep / skills). Shows every scalar
-- field of the row's underlying data table so a dev can see "our data" on any row, not just loot. Nested
-- tables (e.g. a kill's loot map) are summarized by count. Gated by RCTX.devMeta like ItemMetaTip.
local function MetaTip(row, data)
  if type(data) ~= "table" then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine("|cff66ccffHaul metadata|r")
  local keys = {}
  for k, v in pairs(data) do if type(v) ~= "table" then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    GameTooltip:AddDoubleLine(tostring(k), tostring(data[k]), 0.6, 0.6, 0.6, 1, 1, 1)
  end
  for k, v in pairs(data) do
    if type(v) == "table" then local n = 0; for _ in pairs(v) do n = n + 1 end
      GameTooltip:AddDoubleLine(tostring(k), n .. " entr" .. (n == 1 and "y" or "ies"), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8) end
  end
  GameTooltip:Show()
end

local function LootItemEntry(data, gray)
  local icon = select(5, GetItemInfoInstant(data.link))
  local cnt = (data.count and data.count > 1) and ("  x" .. data.count) or ""
  local name, value
  if gray then
    name  = "|cff808080[" .. (data.name or "?") .. "]" .. cnt .. "  (excl)|r"
    value = "|cff808080" .. ns.MoneyShort(data.total) .. "|r"
  else
    name  = ns.QualityName(data.name, data.quality) .. cnt   -- quality-colored (captured link color is unreliable)
    value = ns.MoneyShort(data.total)
  end
  return {
    kind = "item", icon = icon or 134400, name = name, value = value, pct = PctCol(data.pct), link = data.link,
    cols = { src = SrcCol(data.src) },   -- opt-in Source column (icon; loot-source type); collapses when off/unknown
    onClick = RCTX.itemClick and function() RCTX.itemClick(data) end or nil,   -- nil = not clickable (snapshot)
    onEnter = RCTX.devMeta and function(row) ItemMetaTip(row, data) end or nil,   -- dev: append metadata
  }
end

-- build an item descriptor for one mail/craft row. Not counted by default → dimmed with "(excl)";
-- once you click to include it (entry.keep), it reads normally with an "(included)" tag, mirroring the
-- excluded-row affordance inverted.
local function SourceItemEntry(data)
  local icon = select(5, GetItemInfoInstant(data.link))
  local cnt = (data.count and data.count > 1) and ("  x" .. data.count) or ""
  local name, value
  if data.keep then
    name  = ns.QualityName(data.name, data.quality) .. cnt .. "  |cff80ff80(included)|r"
    value = ns.MoneyShort(data.total)
  else
    name  = "|cff808080[" .. (data.name or "?") .. "]" .. cnt .. "  (excl)|r"
    value = "|cff808080" .. ns.MoneyShort(data.total) .. "|r"
  end
  return {
    kind = "item", icon = icon or 134400, name = name, value = value, link = data.link,
    onClick = RCTX.itemClick and function() RCTX.itemClick(data) end or nil,
    onEnter = RCTX.devMeta and function(row) ItemMetaTip(row, data) end or nil,   -- dev: append metadata
  }
end

local function ToggleGroup(key)
  local go = HaulDB.window.groupOpen
  go[key] = not go[key]
  if ns.RefreshUI then ns.RefreshUI() end
end

-- Loot · Collection: normal rows flat at the top, then the three buckets as accordion groups.
-- A bucket's default open state seeds from its mode (Expanded -> open, Collapsed -> closed); Hidden
-- omits it entirely (those rows are already dropped by ComputeStats' "ignore" handling).
local function BuildLootCollectionEntries()
  local st = RCTX.stats or ns.ComputeStats()
  local rows = st.rows
  local entries = {}
  local bucketRows = { bound = {}, gray = {}, excluded = {} }
  for _, data in ipairs(rows) do
    if data.from == "mail" then
      -- mail-arrived loot belongs to the Mail category, not Loot — skip it here
    elseif data.from == "craft" then
      -- craft tracking removed (too buggy). New captures never tag craft; legacy from="craft" rows are
      -- hidden here (kept in the log, just out of Loot) until the future crafting library owns them.
    elseif data.excluded then
      bucketRows.excluded[#bucketRows.excluded + 1] = data
    elseif data.cat == "bound" or data.cat == "gray" then
      bucketRows[data.cat][#bucketRows[data.cat] + 1] = data
    else
      entries[#entries + 1] = LootItemEntry(data, false)   -- normal item, flat at top
    end
  end
  local go = RCTX.go or HaulDB.window.groupOpen
  local onToggle = RCTX.onToggle or ToggleGroup
  for _, B in ipairs(BUCKETS) do
    local list = bucketRows[B.key]
    if B.modeKey and HaulDB[B.modeKey] == "ignore" then list = {} end   -- Hidden: omit the whole bucket
    local children, count, total = {}, 0, 0
    for _, data in ipairs(list) do
      count = count + (data.count or 0); total = total + (data.total or 0)
      if B.from then children[#children + 1] = SourceItemEntry(data)
      else children[#children + 1] = LootItemEntry(data, B.excluded and true or false) end
    end
    if #children > 0 then
      -- seed open state the first time: source buckets default closed; quality/excluded buckets
      -- seed from their Options mode (Expanded=show -> open, else closed)
      if go[B.key] == nil then
        if B.modeKey then go[B.key] = (HaulDB[B.modeKey] == "show") else go[B.key] = B.defaultOpen and true or false end
      end
      -- group % of drops on the Soulbound / Vendor-trash / Excluded headers — all three are area drops
      -- counted in dropBase, so the header % = the sum of its rows' %s. Mail/craft get no % (they're
      -- not area drops, so they're out of the base entirely).
      local groupPct
      if (B.key == "bound" or B.key == "gray" or B.key == "excluded") and st.dropBase and st.dropBase > 0 then
        groupPct = PctCol(count / st.dropBase * 100)
      end
      entries[#entries + 1] = {
        kind = "group", key = B.key, icon = B.icon,
        label = "|cff" .. B.color .. B.label .. "|r", count = count,
        value = "|cff" .. B.color .. ns.MoneyShort(total) .. "|r", pct = groupPct,
        open = go[B.key] and true or false, onToggle = onToggle, children = children,
      }
    end
  end
  -- Cash: the looted-coin total (the same value as the {cash} token), pinned at the bottom so it's visible
  -- straight in the list even when the detail/template area isn't shown. Not a group — just a rollup line.
  if (st.coin or 0) > 0 then
    entries[#entries + 1] = { kind = "item", icon = "Interface\\Icons\\INV_Misc_Coin_01",
      name = "|cffffd700Cash|r", value = "|cffffd700" .. ns.MoneyShort(st.coin) .. "|r" }
  end
  return entries
end

-- Mail category: the display split of what used to be the Loot "Mailbox" bucket — two accordions, Items
-- (loot that arrived via mail, from="mail") and Gold (mail-gold pickups, each with what it was for). BOTH are
-- INFORMATIONAL — never in counted/gross/coin (mail = AH returns / transfers / self-mail / missed-pickup). No
-- category total line; each group carries its own summed header (gold in Gold, item value in Items).
local function BuildMailCollectionEntries()
  local st = RCTX.stats or ns.ComputeStats()
  local go = RCTX.go or HaulDB.window.groupOpen
  local onToggle = RCTX.onToggle or ToggleGroup
  local entries = {}
  -- Items: every from="mail" row (rendered as normal item rows — value/pct/source, not the grayed "excl" style
  -- from when mail lived under Loot; in its own category the items simply are what they are).
  local itemChildren, itemCount, itemTotal = {}, 0, 0
  for _, data in ipairs(st.rows or {}) do
    if data.from == "mail" then
      itemChildren[#itemChildren + 1] = LootItemEntry(data, false)
      itemCount = itemCount + (data.count or 0); itemTotal = itemTotal + (data.total or 0)
    end
  end
  if #itemChildren > 0 then
    if go.mail_items == nil then go.mail_items = true end
    entries[#entries + 1] = {
      kind = "group", key = "mail_items", icon = "Interface\\Icons\\INV_Letter_15",
      label = "|cffffd98aItems|r", count = itemCount,
      value = "|cffffd98a" .. ns.MoneyShort(itemTotal) .. "|r",
      open = go.mail_items and true or false, onToggle = onToggle, children = itemChildren,
    }
  end
  -- Gold: one line per mail-gold pickup (label = what it was for), summed in the group header. Not clickable —
  -- the keep flag is moot now that mail never counts; promote-to-loot is a separate deferred flow.
  local goldChildren, goldTotal = {}, 0
  for _, mr in ipairs(st.mailGoldRows or {}) do
    goldChildren[#goldChildren + 1] = {
      kind = "item", icon = "Interface\\Icons\\INV_Misc_Coin_01",
      name = "|cffffd700" .. (mr.label or "Mail gold") .. "|r",
      value = "|cffffd700" .. ns.MoneyShort(mr.amount or 0) .. "|r",
    }
    goldTotal = goldTotal + (mr.amount or 0)
  end
  if #goldChildren > 0 then
    if go.mail_gold == nil then go.mail_gold = true end
    entries[#entries + 1] = {
      kind = "group", key = "mail_gold", icon = "Interface\\Icons\\INV_Misc_Coin_01",
      label = "|cffffd700Gold|r", count = #goldChildren,
      value = "|cffffd700" .. ns.MoneyShort(goldTotal) .. "|r",
      open = go.mail_gold and true or false, onToggle = onToggle, children = goldChildren,
    }
  end
  if #entries == 0 then
    entries[1] = { kind = "item", icon = "Interface\\Icons\\INV_Letter_15",
      name = "|cff808080No mail this session|r", value = "" }
  end
  return entries
end

-- Vendor category: a self-contained ledger — Sold (+), Bought (−), Repairs (−), and a Net total
-- (sell − buy − repair, green when ahead / red when behind). NONE of it feeds counted/gross/coin: vendor SELL
-- is already-tracked loot converted to gold (counting it would double-count), and buy/repair are spending.
-- Replay's buckets are positive magnitudes; buy/repair display as negatives.
local function BuildVendorCollectionEntries()
  local st = RCTX.stats or ns.ComputeStats()
  local v = RCTX.vendor or st.vendor or { sell = 0, buy = 0, repair = 0 }
  local sell, buy, repair = v.sell or 0, v.buy or 0, v.repair or 0
  if sell == 0 and buy == 0 and repair == 0 then
    return { { kind = "item", icon = "Interface\\Icons\\INV_Misc_Coin_02",
      name = "|cff808080No vendor activity this session|r", value = "" } }
  end
  -- a signed value string; a ZERO shows a plain gray "0" (no +/- dash — only real spend/gain is signed).
  local function val(amount, positive)
    if (amount or 0) == 0 then return "|cff8080800|r" end
    return "|cff" .. (positive and "80ff80" or "ff8080") .. (positive and "+" or "-") .. ns.MoneyShort(amount) .. "|r"
  end
  local net = sell - buy - repair
  local netStr = (net == 0) and "|cff8080800|r"
    or ("|cff" .. (net > 0 and "80ff80" or "ff8080") .. (net > 0 and "+" or "-") .. ns.MoneyShort(math.abs(net)) .. "|r")
  -- Net headline FIRST (the number that matters), then the three lines it's made of. (Sold/Bought will become
  -- twirl-downs of the individual items once per-item vendor capture lands — today only the totals exist.)
  return {
    { kind = "item", icon = "Interface\\Icons\\INV_Misc_Coin_02", name = "|cffffffffNet|r",     value = netStr },
    { kind = "item", icon = "Interface\\Icons\\INV_Misc_Coin_01", name = "|cffffffffSold|r",    value = val(sell, true) },
    { kind = "item", icon = "Interface\\Icons\\INV_Misc_Bag_08",  name = "|cffffffffBought|r",  value = val(buy, false) },
    { kind = "item", icon = "Interface\\Icons\\Ability_Repair",   name = "|cffffffffRepairs|r", value = val(repair, false) },
  }
end

-- money rows in the List view carry a coin icon, the formatted amount, and a small source tag. Collapsed:
-- kind is `coin` (with src.t=quest for quest turn-ins) or `mail`; from="container" for bag-opened gold.
local function moneyTag(data)
  if data.from == "container" then return "container" end
  if data.kind == "mail" then return "mail" end
  if data.src and data.src.t == "quest" then return "quest" end
  return "looted"   -- plain coin total
end
local function MoneyListEntry(data)
  local tag = moneyTag(data)
  return {
    kind = "item", icon = "Interface\\Icons\\INV_Misc_Coin_01",
    name = "|cffffd700" .. tag .. "|r", value = ns.MoneyShort(data.amount or 0),
  }
end

-- Loot · List: the chronological loot log, flat (no groups). Excluded items stay shown inline, dimmed.
-- Mixed rows: money rows (looted/quest/mail) interleave with item drops, newest first.
local function BuildLootListEntries()
  local entries = {}
  for _, data in ipairs(ns.LogRows()) do
    if data.money then entries[#entries + 1] = MoneyListEntry(data)
    else entries[#entries + 1] = LootItemEntry(data, data.excluded) end
  end
  return entries
end

local REP_ICON = "Interface\\Icons\\Achievement_Reputation_01"

-- Reputation · Collection: one row per faction, +amount (green), sorted by amount desc.
-- Signed rep amount: green +N for gains, red −N for losses (amt already carries the minus), gray 0.
local function RepValue(amt)
  amt = amt or 0
  if amt > 0 then return "|cff1eff00+" .. amt .. "|r" end
  if amt < 0 then return "|cffff6060" .. amt .. "|r" end
  return "|cff8080800|r"
end
ns.RepValue = RepValue

local function BuildRepCollectionEntries()
  local rep = RCTX.rep or (ns.session and ns.session.rep) or {}
  local list = {}
  for fac, amt in pairs(rep) do list[#list + 1] = { fac = fac, amt = amt } end
  table.sort(list, function(a, b) return a.amt > b.amt end)
  if #list == 0 then
    return { { kind = "item", icon = REP_ICON,
      name = "|cff808080no reputation this session|r", value = "" } }
  end
  local entries = {}
  for _, e in ipairs(list) do
    entries[#entries + 1] = { kind = "item", icon = REP_ICON,
      name = (ns.RepName and ns.RepName(e.fac)) or e.fac, value = RepValue(e.amt),   -- rep is id-keyed: resolve to the name
      onEnter = RCTX.devMeta and function(row) MetaTip(row, e) end or nil }
  end
  return entries
end

-- Reputation · List: the chronological rep-gain stream, newest first.
local function BuildRepListEntries()
  local log = (ns.session and ns.session.repLog) or {}
  if #log == 0 then
    return { { kind = "item", icon = REP_ICON,
      name = "|cff808080no reputation this session|r", value = "" } }
  end
  local entries = {}
  for i = #log, 1, -1 do
    local e = log[i]
    entries[#entries + 1] = { kind = "item", icon = REP_ICON,
      name = e.faction, value = RepValue(e.amount),
      onEnter = RCTX.devMeta and function(row) MetaTip(row, e) end or nil }
  end
  return entries
end

-- Currency: keyed by currencyType ID; name/icon resolve live (offline rebuilds keep the totals).
local CURRENCY_ICON = "Interface\\Icons\\INV_Misc_Coin_02"
-- wrap a currency name in its quality color (crests etc. carry a quality, like items) — same coloring
-- path ns.QualityName uses, but no brackets (currencies aren't item links).
local function colorByQuality(name, quality)
  local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
  if q then
    if q.color and q.color.WrapTextInColorCode then return q.color:WrapTextInColorCode(name)
    elseif q.hex then return "|c" .. q.hex .. name .. "|r" end
  end
  return name
end
local function CurrencyInfo(id)
  local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(id)
  local name = (info and info.name) or ("currency " .. tostring(id))
  return colorByQuality(name, info and info.quality), (info and info.iconFileID) or CURRENCY_ICON
end
ns.CurrencyName = function(id) return (CurrencyInfo(id)) end   -- quality-colored name only (Data tab reuse)
-- gains are plain counts (not money): green +N with thousands separators where available.
local function CurrencyValue(amt)
  amt = amt or 0
  local n = (BreakUpLargeNumbers and BreakUpLargeNumbers(amt)) or amt
  if amt > 0 then return "|cff1eff00+" .. n .. "|r" end
  return "|cff808080" .. n .. "|r"
end
ns.CurrencyValue = CurrencyValue

-- Currency · Collection: one row per currency, +amount, sorted by amount desc.
local function BuildCurrencyCollectionEntries()
  local cur = RCTX.currency or (ns.session and ns.session.currency) or {}
  local list = {}
  for id, amt in pairs(cur) do list[#list + 1] = { id = id, amt = amt } end
  table.sort(list, function(a, b) return a.amt > b.amt end)
  if #list == 0 then
    return { { kind = "item", icon = CURRENCY_ICON,
      name = "|cff808080no currency this session|r", value = "" } }
  end
  local entries = {}
  for _, e in ipairs(list) do
    local name, icon = CurrencyInfo(e.id)
    entries[#entries + 1] = { kind = "item", icon = icon, name = name, value = CurrencyValue(e.amt),
      onEnter = RCTX.devMeta and function(row) MetaTip(row, e) end or nil }
  end
  return entries
end

-- Currency · List: the chronological currency-gain stream, newest first.
local function BuildCurrencyListEntries()
  local log = (ns.session and ns.session.currencyLog) or {}
  if #log == 0 then
    return { { kind = "item", icon = CURRENCY_ICON,
      name = "|cff808080no currency this session|r", value = "" } }
  end
  local entries = {}
  for i = #log, 1, -1 do
    local e = log[i]
    local name, icon = CurrencyInfo(e.id)
    entries[#entries + 1] = { kind = "item", icon = icon, name = name, value = CurrencyValue(e.amount),
      onEnter = RCTX.devMeta and function(row) MetaTip(row, e) end or nil }
  end
  return entries
end

-- Professions / skills: keyed by lineID (the expansion-qualified tier, e.g. "Classic Fishing"); the
-- name resolves via GECStore.ProfessionCatalog (static per build), the session totals rebuild offline.
local PROF_ICON = "Interface\\Icons\\INV_Scroll_08"
local function ProfLineName(id, fallback)
  local Store = LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECStore-1.0", true)
  local cat = Store and Store.ProfessionCatalog and Store.ProfessionCatalog()
  local e = cat and cat[id]
  return "|cffd0a0ff" .. ((e and e.name) or fallback or ("skill " .. tostring(id))) .. "|r"
end
ns.ProfLineName = function(id, fb) return ProfLineName(id, fb) end   -- Data-tab reuse
-- skill-ups are plain counts (not money): green +N.
local function ProfValue(amt)
  amt = amt or 0
  if amt > 0 then return "|cff1eff00+" .. amt .. "|r" end
  return "|cff808080" .. amt .. "|r"
end
ns.ProfValue = ProfValue

-- Skills · Collection: one row per profession tier, +N skill points, sorted by amount desc.
local function BuildProfCollectionEntries()
  local prof = RCTX.professions or (ns.session and ns.session.professions) or {}
  local list = {}
  for id, amt in pairs(prof) do list[#list + 1] = { id = id, amt = amt } end
  table.sort(list, function(a, b) return a.amt > b.amt end)
  if #list == 0 then
    return { { kind = "item", icon = PROF_ICON,
      name = "|cff808080no skill-ups this session|r", value = "" } }
  end
  local entries = {}
  for _, e in ipairs(list) do
    entries[#entries + 1] = { kind = "item", icon = PROF_ICON, name = ProfLineName(e.id), value = ProfValue(e.amt),
      onEnter = RCTX.devMeta and function(row) MetaTip(row, e) end or nil }
  end
  return entries
end

-- Skills · List: the chronological skill-up stream, newest first (uses the name captured at event time).
local function BuildProfListEntries()
  local log = (ns.session and ns.session.professionsLog) or {}
  if #log == 0 then
    return { { kind = "item", icon = PROF_ICON,
      name = "|cff808080no skill-ups this session|r", value = "" } }
  end
  local entries = {}
  for i = #log, 1, -1 do
    local e = log[i]
    entries[#entries + 1] = { kind = "item", icon = PROF_ICON, name = ProfLineName(e.id, e.name), value = ProfValue(e.amount),
      onEnter = RCTX.devMeta and function(row) MetaTip(row, e) end or nil }
  end
  return entries
end

-- Experience: a scalar total (from PLAYER_XP_UPDATE) plus a DISCOVERY subset broken out per zone (from the
-- ERR_ZONE_EXPLORED_XP chat line). Collection = the total + one row per discovered zone; List = the
-- chronological discovery stream. Green +N, thousands-separated.
local XP_ICON = "Interface\\Icons\\XPBonus_Icon"
local XP_ZONE_ICON = "Interface\\Icons\\INV_Misc_Map_01"
local function XPValue(amt)
  amt = amt or 0
  local n = (BreakUpLargeNumbers and BreakUpLargeNumbers(amt)) or amt
  if amt > 0 then return "|cff1eff00+" .. n .. "|r" end
  return "|cff808080" .. n .. "|r"
end
ns.XPValue = XPValue

local XP_QUEST_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local XP_KILL_ICON = "Interface\\Icons\\Ability_DualWield"
local XP_GATHER_ICON = "Interface\\Icons\\Trade_Herbalism"
local XP_OTHER_ICON = "Interface\\Icons\\Ability_Hunter_SniperShot"
-- helper: timestamped gain rows, newest first (used ONLY for unidentifiable XP — the Other group).
local function xpTimeRows(stream)
  local rows = {}
  for i = #stream, 1, -1 do
    local e = stream[i]
    local when = e.t and date("%H:%M:%S", e.t) or ""
    rows[#rows + 1] = { kind = "item", icon = XP_OTHER_ICON, name = "|cffcfcfcf" .. when .. "|r", value = XPValue(e.amount) }
  end
  return rows
end
-- helper: quest rows BY NAME (detailed), newest first; falls back to a timestamp only when the title is unknown.
local function xpQuestRows(stream)
  local rows = {}
  for i = #stream, 1, -1 do
    local e = stream[i]
    local label
    if e.title and e.title ~= "" then label = "|cffffe08a" .. e.title .. "|r"
    else label = "|cff808080" .. (e.t and date("%H:%M:%S", e.t) or "quest") .. "|r" end
    rows[#rows + 1] = { kind = "item", icon = XP_QUEST_ICON, name = label, value = XPValue(e.amount) }
  end
  return rows
end

-- XP · Collection: Total at the top (a plain header — the grand total), then the source breakdown as
-- TOP-LEVEL sibling accordion groups, each expanding to DETAIL (what the XP was), not timestamps:
--   Kills      -> per mob (kill count + XP)      Quests    -> per quest (by name)
--   Gathering  -> per node (gather count + XP)   Discovery -> per zone
--   Other      -> the ONLY time-based group: unidentifiable gains, each with a timestamp to review later.
-- Live reads the session's own tables; a saved session reads the Replay-reconstructed tables via RCTX.
local function BuildXPCollectionEntries()
  local s = ns.session
  local total  = RCTX.xp or (s and s.xp) or 0
  local disc   = RCTX.xpDiscovery or (s and s.xpDiscovery) or 0
  local quest  = RCTX.xpQuest or (s and s.xpQuest) or 0
  local kill   = RCTX.xpKill or (s and s.xpKill) or 0
  local mobs   = RCTX.xpMobs or (s and s.xpMobs) or {}
  local gather = RCTX.xpGather or (s and s.xpGather) or 0
  local nodes  = RCTX.xpNodes or (s and s.xpNodes) or {}
  local zones  = RCTX.xpZones or (s and s.xpZones) or {}
  local qstream = RCTX.xpQuestStream or (s and s.xpQuestLog) or {}
  local ostream = RCTX.xpOtherStream or (s and s.xpOtherLog) or {}
  local other = total - disc - quest - kill - gather
  if other < 0 then other = 0 end   -- rested doubling can push a subset over the delta; keep the residual sane
  if (total or 0) <= 0 then
    return { { kind = "item", icon = XP_ICON, name = "|cff808080no experience this session|r", value = "" } }
  end
  local go = RCTX.go or HaulDB.window.groupOpen
  local onToggle = RCTX.onToggle or ToggleGroup
  -- Source groups are TOP-LEVEL siblings, each a one-line header showing its subtotal; they default COLLAPSED
  -- so the breakdown reads as a clean flat list (expand a group to drill into its detail).
  local function grp(key, icon, label, value, children)
    if go[key] == nil then go[key] = false end
    return { kind = "group", key = key, icon = icon, label = label, count = #children,
             value = value, open = go[key] and true or false, onToggle = onToggle, children = children }
  end
  local entries = {}
  -- Total XP: a plain (non-expandable) header row — the grand total
  entries[#entries + 1] = { kind = "item", icon = XP_ICON, name = "|cffffffffTotal XP|r", value = XPValue(total) }
  -- Kills: one row per mob (kill count + XP), largest XP first
  if kill > 0 then
    local mlist = {}
    for mob, m in pairs(mobs) do mlist[#mlist + 1] = { mob = mob, xp = m.xp or 0, kills = m.kills or 0 } end
    table.sort(mlist, function(a, b) return a.xp > b.xp end)
    local mchildren = {}
    for _, e in ipairs(mlist) do
      local cnt = (e.kills > 1) and ("  |cff808080x" .. e.kills .. "|r") or ""
      mchildren[#mchildren + 1] = { kind = "item", icon = XP_KILL_ICON, name = tostring(e.mob) .. cnt, value = XPValue(e.xp),
        onEnter = RCTX.devMeta and function(row) MetaTip(row, e) end or nil }
    end
    entries[#entries + 1] = grp("xp_kill", XP_KILL_ICON, "|cffff8080Kills|r", XPValue(kill), mchildren)
  end
  -- Gathering: one row per node (gather count + XP), largest XP first
  if gather > 0 then
    local nlist = {}
    for node, n in pairs(nodes) do nlist[#nlist + 1] = { node = node, xp = n.xp or 0, count = n.count or 0 } end
    table.sort(nlist, function(a, b) return a.xp > b.xp end)
    local nchildren = {}
    for _, e in ipairs(nlist) do
      local cnt = (e.count > 1) and ("  |cff808080x" .. e.count .. "|r") or ""
      nchildren[#nchildren + 1] = { kind = "item", icon = XP_GATHER_ICON, name = tostring(e.node) .. cnt, value = XPValue(e.xp),
        onEnter = RCTX.devMeta and function(row) MetaTip(row, e) end or nil }
    end
    entries[#entries + 1] = grp("xp_gather", XP_GATHER_ICON, "|cff80ff80Gathering|r", XPValue(gather), nchildren)
  end
  -- Quests: one row per turn-in, BY NAME (detailed)
  if quest > 0 then
    entries[#entries + 1] = grp("xp_quest", XP_QUEST_ICON, "|cffffd100Quests|r", XPValue(quest), xpQuestRows(qstream))
  end
  -- Discovery: each discovered zone, largest first
  if disc > 0 then
    local zlist = {}
    for z, amt in pairs(zones) do zlist[#zlist + 1] = { zone = z, amt = amt } end
    table.sort(zlist, function(a, b) return a.amt > b.amt end)
    local zchildren = {}
    for _, e in ipairs(zlist) do
      zchildren[#zchildren + 1] = { kind = "item", icon = XP_ZONE_ICON, name = tostring(e.zone), value = XPValue(e.amt) }
    end
    entries[#entries + 1] = grp("xp_disc", XP_ZONE_ICON, "|cffa0d0ffDiscovery|r", XPValue(disc), zchildren)
  end
  -- Other: the ONLY time-based group — unidentifiable gains, each timestamped so you can review what you were
  -- doing. Any leftover (embedded rested bonus, which has no separate gain to timestamp) is one summary row.
  if other > 0 then
    local ochildren = xpTimeRows(ostream)
    local tracked = 0
    for _, e in ipairs(ostream) do tracked = tracked + (e.amount or 0) end
    local remainder = other - tracked
    if remainder > 0 then
      ochildren[#ochildren + 1] = { kind = "item", icon = XP_OTHER_ICON,
        name = "|cff808080rested bonus / unattributed|r", value = XPValue(remainder) }
    end
    entries[#entries + 1] = grp("xp_other", XP_OTHER_ICON, "|cffcfcfcfOther|r", XPValue(other), ochildren)
  end
  return entries
end

-- XP · List: the chronological stream of identified XP gains (newest first), each shown as WHAT it was —
-- the mob / node / quest / zone — not a bare timestamp. Only unidentified ("other") gains fall back to a
-- time. Walks the session log's XP-source events (the raw total "xp" rows are skipped; they'd double-list).
local function BuildXPListEntries()
  local log = (ns.session and ns.session.log) or {}
  local entries = {}
  for i = #log, 1, -1 do
    local e = log[i]
    -- collapsed: XP subset rows are kind="xp" with a `src` descriptor (kill/gather/quest/disc/other). The raw
    -- total rows are kind="xp" with NO src — skipped here (they'd double-list).
    local lt = (e.kind == "xp" and e.src) and e.src.t or nil
    local name, icon
    if lt == "kill" then name = "|cffff8080" .. tostring((e.src.name or e.src.mob) or "?") .. "|r"; icon = XP_KILL_ICON
    elseif lt == "gather" then name = "|cff80ff80" .. tostring(e.src.node or "?") .. "|r"; icon = XP_GATHER_ICON
    elseif lt == "quest" then name = "|cffffd100" .. tostring(e.src.title or "quest") .. "|r"; icon = XP_QUEST_ICON
    elseif lt == "disc" then name = "|cffa0d0ffDiscovered: " .. tostring(e.src.zone or "?") .. "|r"; icon = XP_ZONE_ICON
    elseif lt == "other" then
      name = "|cffcccccc" .. (e.t and date("%H:%M:%S", e.t) or "") .. "  unidentified|r"; icon = XP_OTHER_ICON
    end
    if name then entries[#entries + 1] = { kind = "item", icon = icon, name = name, value = XPValue(e.amount) } end
  end
  if #entries == 0 then
    return { { kind = "item", icon = XP_ICON, name = "|cff808080no experience this session|r", value = "" } }
  end
  return entries
end

-- Kills: mobs you killed this session (killing blow by you/your pet). Keyed by npcID; name resolves from
-- the captured display name. Collection = one row per mob (kill count), most first; List = the chronological
-- kill stream, newest first.
local KILL_ICON = "Interface\\Icons\\Ability_Rogue_Eviscerate"
local function KillCountValue(n)
  n = n or 0
  if n > 0 then return "|cffff8080x" .. n .. "|r" end
  return "|cff8080800|r"
end
-- one accordion group per mob: header = name + kill count (value); expand to see its XP, its drops, and — if
-- some corpses weren't looted — an "unlooted" line. Everything for one mob is unified here (GUID-keyed capture).
local function BuildKillCollectionEntries()
  local kills = RCTX.kills or (ns.session and ns.session.kills) or {}
  -- MERGE same-named mobs for display: WoW maps one creature NAME to several npcIDs (e.g. Springpaw Lynx =
  -- 250033 + 253939), so keying by npcID correctly stores them apart but would show duplicate rows. Aggregate
  -- count/xp/cash/loot/looted across ids sharing a name into ONE row; the per-npcID data stays intact underneath
  -- (the registry / aggregator keep the granularity). Unnamed ("npc <id>") kills can't merge → keyed by id.
  local byKey, order = {}, {}
  for id, k in pairs(kills) do
    local named = k.name and k.name ~= ""
    local nm = named and k.name or ("npc " .. tostring(id))
    local key = named and ("name:" .. nm) or ("id:" .. tostring(id))
    local g = byKey[key]
    if not g then g = { key = key, name = nm, count = 0, xp = 0, cash = 0, looted = 0, loot = {} }; byKey[key] = g; order[#order + 1] = key end
    g.count = g.count + (k.count or 0); g.xp = g.xp + (k.xp or 0)
    g.cash = g.cash + (k.cash or 0); g.looted = g.looted + (k.looted or 0)
    if k.loot then for lk, it in pairs(k.loot) do
      local li = g.loot[lk]; if not li then li = { link = it.link, count = 0 }; g.loot[lk] = li end
      li.count = li.count + (it.count or 0)
    end end
  end
  local list = {}
  for _, key in ipairs(order) do list[#list + 1] = byKey[key] end
  table.sort(list, function(a, b) return a.count > b.count end)
  if #list == 0 then
    return { { kind = "item", icon = KILL_ICON, name = "|cff808080no kills this session|r", value = "" } }
  end
  local go = RCTX.go or HaulDB.window.groupOpen
  local onToggle = RCTX.onToggle or ToggleGroup
  local entries = {}
  for _, e in ipairs(list) do
    local children = {}
    -- XP earned from this mob
    if e.xp and e.xp > 0 then
      local nxp = (BreakUpLargeNumbers and BreakUpLargeNumbers(e.xp)) or e.xp
      children[#children + 1] = { kind = "item", icon = XP_ICON, name = "|cff1eff00XP|r", value = "|cff1eff00" .. nxp .. "|r" }
    end
    -- cash looted from this mob (rollup; matches what feeds your top-line cash)
    if e.cash and e.cash > 0 then
      children[#children + 1] = { kind = "item", icon = "Interface\\Icons\\INV_Misc_Coin_01",
        name = "|cffffd700Cash|r", value = ns.MoneyShort and ns.MoneyShort(e.cash) or tostring(e.cash) }
    end
    -- drops (quality-colored item name + xCount)
    if e.loot then
      local llist = {}
      for _, it in pairs(e.loot) do llist[#llist + 1] = it end
      table.sort(llist, function(a, b) return (a.count or 0) > (b.count or 0) end)
      for _, it in ipairs(llist) do
        local icon = select(5, GetItemInfoInstant(it.link)) or 134400
        local nm = (it.link and it.link:match("%[(.-)%]")) or "item"
        local cnt = (it.count and it.count > 1) and ("  x" .. it.count) or ""
        children[#children + 1] = { kind = "item", icon = icon, name = ns.QualityName and ns.QualityName(nm) or nm,
          value = cnt ~= "" and ("|cff808080" .. cnt .. "|r") or "", link = it.link }
      end
    end
    -- Effective kill count: a looted corpse IS a kill you were there for, so when NO kill EVENT was logged
    -- (12.0 makes combat names/GUIDs secret + loot-classification gaps leave count=0), fall back to the
    -- looted-corpse count so the mob doesn't misleadingly read "0 kills". [[wow12-secret-combat-names]]
    local kc = math.max(e.count or 0, e.looted or 0)
    local unlooted = kc - (e.looted or 0)   -- kills we counted but didn't loot
    if unlooted > 0 then
      children[#children + 1] = { kind = "item", icon = KILL_ICON,
        name = "|cff808080" .. unlooted .. " unlooted|r", value = "" }
    end
    local meta = RCTX.devMeta and function(row) MetaTip(row, e) end or nil   -- dev: dump the kill record
    if #children > 0 then
      local key = "kill_" .. tostring(e.key)   -- name-based key (same-named npcIDs already merged into e)
      if go[key] == nil then go[key] = false end
      entries[#entries + 1] = { kind = "group", key = key, icon = KILL_ICON, label = tostring(e.name),
        count = kc, value = KillCountValue(kc), open = go[key] and true or false,
        onToggle = onToggle, children = children, onEnter = meta }
    else
      entries[#entries + 1] = { kind = "item", icon = KILL_ICON, name = tostring(e.name),
        value = KillCountValue(kc), onEnter = meta }
    end
  end
  return entries
end
local function BuildKillListEntries()
  local log = (ns.session and ns.session.killLog) or {}
  if #log == 0 then
    return { { kind = "item", icon = KILL_ICON, name = "|cff808080no kills this session|r", value = "" } }
  end
  local entries = {}
  for i = #log, 1, -1 do
    local e = log[i]
    local when = e.t and date("%H:%M:%S", e.t) or ""
    entries[#entries + 1] = { kind = "item", icon = KILL_ICON,
      name = "|cffff8080" .. tostring(e.name or "?") .. "|r  |cff808080" .. when .. "|r", value = "" }
  end
  return entries
end
ns.KillCount = function() return (ns.session and ns.session.killCount) or 0 end   -- for tokens later

-- "All" view: every category as a top-level collapsible section in ONE list. Each section's children come
-- straight from that category's own Collection builder — no special-casing, so it renders identically to the
-- category's own view (its inner groups just nest one level deeper). Group-open state is shared with the
-- per-category views (same HaulDB.window.groupOpen keys where they overlap).
local ALL_SECTIONS = {
  { key = "all_loot",     label = "Loot",       icon = "Interface\\Icons\\INV_Misc_Bag_08", build = BuildLootCollectionEntries },
  { key = "all_kill",     label = "Kills",      icon = KILL_ICON,     build = BuildKillCollectionEntries },
  { key = "all_rep",      label = "Reputation", icon = REP_ICON,      build = BuildRepCollectionEntries },
  { key = "all_currency", label = "Currency",   icon = CURRENCY_ICON, build = BuildCurrencyCollectionEntries },
  { key = "all_xp",       label = "XP",         icon = XP_ICON,       build = BuildXPCollectionEntries },
  { key = "all_prof",     label = "Skills",     icon = PROF_ICON,     build = BuildProfCollectionEntries },
}
local function BuildAllEntries()
  local go = RCTX.go or HaulDB.window.groupOpen
  local onToggle = RCTX.onToggle or ToggleGroup
  local entries = {}
  for _, sec in ipairs(ALL_SECTIONS) do
    local children = sec.build() or {}
    if go[sec.key] == nil then go[sec.key] = false end
    entries[#entries + 1] = { kind = "group", key = sec.key, icon = sec.icon,
      label = "|cffffffff" .. sec.label .. "|r",
      open = go[sec.key] and true or false, onToggle = onToggle, children = children }
  end
  return entries
end

-- dispatch (category, view) -> the right builder. Loot uses HaulDB.view; Rep uses HaulDB.repView;
-- Currency uses HaulDB.currencyView; Skills uses HaulDB.profView; XP uses HaulDB.xpView; Kills uses HaulDB.killView.
local function BuildEntries()
  -- LIVE render context: clickable items mutate the live session; live group-open + columns.
  RCTX = { colPct = HaulDB.window.colPct, colSrc = HaulDB.window.colSrc, itemClick = ItemClick,
           devMeta = (Haul.IsDev() and HaulDB.devTooltip) and true or false,
           go = HaulDB.window.groupOpen, onToggle = ToggleGroup }
  local cat = HaulDB.window.category or "loot"
  if cat == "all" then return BuildAllEntries() end
  if cat == "mail" then return BuildMailCollectionEntries() end
  if cat == "vendor" then return BuildVendorCollectionEntries() end
  if cat == "rep" then
    if (HaulDB.repView or "collection") == "list" then return BuildRepListEntries() end
    return BuildRepCollectionEntries()
  end
  if cat == "currency" then
    if (HaulDB.currencyView or "collection") == "list" then return BuildCurrencyListEntries() end
    return BuildCurrencyCollectionEntries()
  end
  if cat == "prof" then
    if (HaulDB.profView or "collection") == "list" then return BuildProfListEntries() end
    return BuildProfCollectionEntries()
  end
  if cat == "xp" then
    if (HaulDB.xpView or "collection") == "list" then return BuildXPListEntries() end
    return BuildXPCollectionEntries()
  end
  if cat == "kill" then
    if (HaulDB.killView or "collection") == "list" then return BuildKillListEntries() end
    return BuildKillCollectionEntries()
  end
  if (HaulDB.view or "collection") == "list" then return BuildLootListEntries() end
  return BuildLootCollectionEntries()
end

-- Render a SAVED session `h`'s category EXACTLY like the live window (the Data-tab overhaul). Snapshot
-- render context: items aren't clickable (no live session to mutate); group-open state + columns are the
-- caller's (per-session). Returns the AccordionList entries for the given category ("loot"/"rep"/"currency").
function ns.BuildSessionEntries(h, category, groupOpen, onToggle, colPct)
  local reb = (ns.Replay and ns.Replay.Rebuild(h.drops or {}, { markers = ns.SidMarkers and h.sid and ns.SidMarkers(h.sid) })) or {}
  RCTX = {
    colPct = colPct, colSrc = HaulDB.window.colSrc, itemClick = nil, go = groupOpen or {}, onToggle = onToggle,
    devMeta = (Haul.IsDev() and HaulDB.devTooltip) and true or false,
    stats = ns.SnapshotStats and ns.SnapshotStats(h) or nil,
    rep = reb.rep or {}, currency = reb.currency or {}, professions = reb.professions or {},
    xp = reb.xp or 0, xpDiscovery = reb.xpDiscovery or 0, xpQuest = reb.xpQuest or 0, xpKill = reb.xpKill or 0,
    xpGather = reb.xpGather or 0, xpOther = reb.xpOther or 0,
    xpMobs = reb.xpMobs or {}, xpNodes = reb.xpNodes or {}, xpZones = reb.xpZones or {},
    xpQuestStream = reb.xpQuestStream or {}, xpOtherStream = reb.xpOtherStream or {},
    kills = reb.kills or {}, gather = reb.gather or {},
    vendor = reb.vendor or { sell = 0, buy = 0, repair = 0 },   -- Vendor category ledger (snapshot)
  }
  if category == "all" then return BuildAllEntries() end
  if category == "mail" then return BuildMailCollectionEntries() end
  if category == "vendor" then return BuildVendorCollectionEntries() end
  if category == "rep" then return BuildRepCollectionEntries() end
  if category == "currency" then return BuildCurrencyCollectionEntries() end
  if category == "prof" then return BuildProfCollectionEntries() end
  if category == "xp" then return BuildXPCollectionEntries() end
  if category == "kill" then return BuildKillCollectionEntries() end
  return BuildLootCollectionEntries()
end

-------------------------------------------------------------- template render --
-- Build the token table once per refresh; shared by the main bar AND watchers.
function ns.BuildFields()
  local st = ns.ComputeStats()
  local src = ns.SourceLabel and ns.SourceLabel() or HaulDB.priceSource
  local tp = ns.TokenPrice and ns.TokenPrice()
  local clock = SecondsToClock or function(s) return string.format("%d:%02d", math.floor(s / 60), s % 60) end
  local timer = clock(math.floor(st.elapsed))
  -- previous (most recent) drop, from the chronological loot log. The name is the
  -- item link (quality-colored, and hoverable where the bar enables hyperlinks).
  -- GetItemInfo's link (2nd return) is reliably colored; fall back to the chat link.
  local lastName, lastCount, lastVal, lastId = "-", 0, nil, ""
  do
    local s = ns.session
    local log = s and s.log
    -- s.log now holds mixed item + money rows; {items.last} means the last ITEM drop,
    -- so scan back past any money rows (which have no .link / carry .kind).
    local last
    if log then
      for i = #log, 1, -1 do
        if log[i].id and log[i].link then last = log[i]; break end
      end
    end
    if last then
      local _, glink, _, _, _, _, _, _, _, _, sell = GetItemInfo(last.link)
      lastName = glink or last.link or "-"
      lastCount = last.count or 1
      lastVal = (ns.GetUnitValue(last.link, sell) or 0) * lastCount
      -- numeric itemID of the last drop, PLAIN, so it can be a nested arg:
      -- {count.account({haul.items.last.id})}. "" when there's no id.
      lastId = (last.link and tostring(last.link):match("item:(%d+)")) or ""
    end
  end
  -- money in two flavors: .short = largest non-zero unit (40s, 3g); .full = g/s/c
  local valShort, valFull = ns.MoneyShort(st.loot), ns.Money(st.loot)
  local lastValShort = (lastVal and ns.MoneyShort(lastVal)) or "-"
  local lastValFull  = (lastVal and ns.Money(lastVal)) or "-"
  -- composite "name xCount value"; the value flavor (short/full) is the only diff
  local function lastComposite(valStr)
    if lastCount <= 0 then return "-" end
    return lastName .. "  x" .. lastCount .. "   " .. valStr   -- always show count, even x1
  end
  local lastWhole, lastWholeFull = lastComposite(lastValShort), lastComposite(lastValFull)
  -- zone tiers: region > zone > sub (empty tiers dropped); plus the explicit {zone.*}
  local zRegion, zZone, zSub = ns.ZoneTiers()
  local ZSEP = " > "
  local zoneFull = (zZone ~= "" and zZone) or "?"
  if zRegion ~= "" and zRegion ~= zZone then zoneFull = zRegion .. ZSEP .. zoneFull end
  if zSub ~= "" then zoneFull = zoneFull .. ZSEP .. zSub end
  -- notable threshold label (e.g. "Uncommon+"), self-colored by the quality
  local nqi = QUALITY_INFO[HaulDB.notableQuality or 2] or QUALITY_INFO[2]
  local noteLabel = "|cff" .. (nqi.hex or "1eff00") .. (nqi.name or "Uncommon") .. "+|r"
  -- the notable COUNT, self-colored by the SAME quality color as the label, so the count's color
  -- alone signals the threshold (even without showing the label). Raw token → carries through the feed.
  local notableCount = "|cff" .. (nqi.hex or "1eff00") .. tostring(st.notable) .. "|r"
  -- reputation gained this session, per faction
  local rep = (ns.session and ns.session.rep) or {}
  local repTotal, repTop, repTopAmt, repParts = 0, nil, 0, {}
  for fac, amt in pairs(rep) do
    local facName = (ns.RepName and ns.RepName(fac)) or fac   -- rep is id-keyed: resolve to the display name
    repTotal = repTotal + amt
    if repTop == nil or amt > repTopAmt then repTop, repTopAmt = facName, amt end   -- highest, even if all losses
    repParts[#repParts + 1] = facName .. " " .. RepValue(amt)
  end
  table.sort(repParts)
  local fields = {
    time = timer, ["time.timer"] = timer,
    ["time.current"] = date and date("%H:%M") or "",                          -- 24-hour wall clock
    ["time.current.ampm"] = date and (date("%I:%M %p"):gsub("^0", "")) or "",  -- 12-hour wall clock ("2:30 PM")
    ["time.ig"] = clock(math.floor(ns.IGSeconds and ns.IGSeconds() or 0)),
    -- haul/total/loot/gross/perhour/cash populated below (bare/.short/.full)
    items = tostring(st.itemCount),               -- alias of items.count
    ["items.count"] = tostring(st.itemCount),
    -- total item value. bare = short (largest unit); .short/.full are explicit
    ["items.value"] = valShort, ["items.value.short"] = valShort, ["items.value.full"] = valFull,
    ["items.price"] = valShort, ["items.price.short"] = valShort, ["items.price.full"] = valFull,
    notable = notableCount,                        -- alias of items.notable (quality-colored count)
    ["items.notable"] = notableCount,
    ["items.last"] = lastWhole,                    -- name + xCount + value short
    ["items.last.short"] = lastWhole,
    ["items.last.full"] = lastWholeFull,           -- same, value in full g/s/c
    ["items.last.name"] = lastName,                -- just the quality-colored item name
    ["items.last.id"] = lastId,                    -- numeric itemID (PLAIN) → nestable as an arg
    ["items.last.count"] = tostring(lastCount),
    -- previous drop's value. bare = short; .short/.full explicit
    ["items.last.value"] = lastValShort,
    ["items.last.value.short"] = lastValShort, ["items.last.value.full"] = lastValFull,
    ["items.last.price"] = lastValShort,
    ["items.last.price.short"] = lastValShort, ["items.last.price.full"] = lastValFull,
    token = st.tokenPct and string.format("%.4f%%", st.tokenPct) or "-",
    ["token.percent"] = st.tokenPct and string.format("%.4f%%", st.tokenPct) or "-",
    -- token.price / tokenprice / token.value populated below (money, guarded by tp)
    ["token.trend"] = TREND_DISPLAY[(ns.TokenTrend and ns.TokenTrend()) or "flat"] or "-",
    rep = repTotal ~= 0 and tostring(repTotal) or "",
    ["rep.amount"] = repTotal ~= 0 and tostring(repTotal) or "",
    ["rep.faction"] = repTop or "",
    ["rep.top"] = repTop and (repTop .. " " .. RepValue(repTopAmt)) or "",
    ["rep.detail"] = (#repParts > 0 and table.concat(repParts, "   ")) or "",
    zone = zoneFull, ["zone.full"] = zoneFull,
    ["zone.region"] = (zRegion ~= "" and zRegion) or "?",
    ["zone.zone"] = (zZone ~= "" and zZone) or "?",
    ["zone.sub"] = zSub,
    ["items.notable.label"] = noteLabel,
    source = src,
  }
  -- money tokens: bare = short (largest unit), plus explicit .short / .full (g/s/c)
  local moneyCopper = {
    haul = st.counted, total = st.counted,
    loot = st.loot or (st.counted - st.coin),
    gross = st.gross, ["gross.perhour"] = st.grossPerHour,
    perhour = st.goldPerHour, cash = st.coin,
  }
  for name, copper in pairs(moneyCopper) do
    local short = ns.MoneyShort(copper)
    fields[name], fields[name .. ".short"], fields[name .. ".full"] = short, short, ns.Money(copper)
    fields[name .. ".copper"] = math.floor(copper or 0)   -- raw copper integer (consumer formats it)
  end
  -- raw-copper for the item-value tokens too (same copper that valShort/valFull formatted above)
  fields["items.value.copper"] = math.floor(st.loot or 0)
  fields["items.price.copper"] = math.floor(st.loot or 0)
  fields["items.last.value.copper"] = math.floor(lastVal or 0)
  fields["items.last.price.copper"] = math.floor(lastVal or 0)
  -- WoW Token price (canonical token.price + aliases); "-" until a price is known
  local tpShort = (tp and tp > 0 and ns.MoneyShort(tp)) or "-"
  local tpFull  = (tp and tp > 0 and ns.Money(tp)) or "-"
  local tpCopper = (tp and tp > 0 and math.floor(tp)) or 0
  for _, name in ipairs({ "token.price", "tokenprice", "token.value" }) do
    fields[name], fields[name .. ".short"], fields[name .. ".full"] = tpShort, tpShort, tpFull
    fields[name .. ".copper"] = tpCopper
  end
  if ns.VaultFields then for k, v in pairs(ns.VaultFields()) do fields[k] = v end end
  -- cross-addon: SBF (Single-Button Fishing) exposes its state + skill readout as {sbf.*} tokens.
  if SBF then
    if SBF.GetNext then fields["sbf.next"] = SBF.GetNext() end
    if SBF.GetState then fields["sbf.state"] = SBF.GetState() end
    if SBF.GetProfile then fields["sbf.profile"] = SBF.GetProfile() end
    if SBF.GetPerception then fields["sbf.perception"] = SBF.GetPerception() end
    -- fishing skill: {sbf.skill} = the full "109/300 (+116)" readout; the pieces split out for custom layouts.
    if SBF.GetFishing then fields["sbf.skill"] = SBF.GetFishing() end
    if SBF.FishingSkill then
      local lvl, mx, mod = SBF.FishingSkill()
      if lvl then
        fields["sbf.skill.level"] = tostring(lvl)
        fields["sbf.skill.max"]   = tostring(mx or lvl)
        fields["sbf.skill.bonus"] = (mod and mod > 0) and ("|cff33ff33+" .. mod .. "|r") or ""
      end
    end
  end
  -- disk-flush state of the live session: on disk (clean since the last write) vs unsaved changes.
  -- Self-colored (in MONEY_TOKENS) so the template can't recolor it.
  fields.flushed = ns._dirty and "|cffff6060unsaved|r" or "|cff45c4a0on disk|r"
  return fields, st, tp, src
end

-- ===================== GECTemplate renderer (new) =====================
-- Build a static token spec from Haul's existing color/verbatim tables so output is
-- identical to the old renderer. Done once at load time:
--   MONEY_TOKENS entries        → "raw" (verbatim self-colored; ignores :color / base)
--   TOKEN_DEFAULT_COLOR entries → { type="text", color=<hex> } (raw wins when both apply)
--   rep                         → { type="rep", color="1eff00" } (unified resolver for bare
--                                  + parameterized {rep(Faction)} forms; overrides the text entry)
--   source                      → "source" type (reads Theme.accentHex dynamically at render time)
local function buildTokenSpec()
  local spec = {}
  for name in pairs(MONEY_TOKENS) do spec[name] = "raw" end
  for name, hex in pairs(TOKEN_DEFAULT_COLOR) do
    -- pairs() does NOT walk the metatable, so "source" (metatable-provided) is skipped here.
    if not spec[name] then spec[name] = { type = "text", color = hex } end
  end
  -- rep: needs a unified type so {rep} (bare) AND {rep(Faction)} (parameterized) both work
  -- correctly. A plain "text" entry would render the faction name instead of the lookup for
  -- {rep(Faction)}, so we use a dedicated "rep" type that handles both forms.
  spec["rep"] = { type = "rep", color = "1eff00" }
  -- source: accent color must be read at render time (Theme.accentHex changes with palette
  -- swaps), so we register a "source" type below and use it here.
  spec["source"] = "source"
  return spec
end

-- ns.IsRawToken(name) — true when this token's BuildFields VALUE carries baked, meaningful color
-- that must NOT be recolored: the MONEY_TOKENS set (white-number + gold/silver/copper money strings,
-- and the quality-colored item-name / notable-label / rep.top composites) PLUS token.trend (a colored
-- arrow+word). Everything else stores a PLAIN value, so a consumer can color it. Single source of
-- truth: the same MONEY_TOKENS table buildTokenSpec() uses.
function ns.IsRawToken(name)
  if MONEY_TOKENS[name] then return true end
  if name == "token.trend" then return true end   -- TREND_DISPLAY = arrow texture + colored word
  return false
end

-- Haul's output VOCABULARY, exposed as an array of { name, type } so Feed.lua can publish the same
-- set as a GECData feed without duplicating the list. type = "raw" for IsRawToken (baked color kept
-- verbatim) else "text" (plain → consumer-colorable). Also emits the per-money .copper NUMBER tokens
-- (raw copper integers added to BuildFields above) so a gadget can format/color money itself.
-- Single source of truth: derives from the same tables buildTokenSpec() uses.
function ns.OutputTokens()
  local seen, out = {}, {}
  local function add(n, typ)
    if n and not seen[n] then seen[n] = true; out[#out + 1] = { name = n, type = typ or (ns.IsRawToken(n) and "raw" or "text") } end
  end
  for n in pairs(MONEY_TOKENS) do add(n) end
  for n in pairs(TOKEN_DEFAULT_COLOR) do add(n) end   -- pairs() skips the metatable "source"
  add("rep"); add("source")                            -- the two buildTokenSpec adds explicitly
  add("items.last.id", "text")                         -- numeric itemID, plain → nestable as an arg
  -- Great Vault tokens (vault.<track>.<field> + bare + vault.ready), sourced statically from Vault.lua
  -- so the feed lists them even before the first vault query; BuildFields merges the live values.
  if ns.VaultTokens then for _, n in ipairs(ns.VaultTokens()) do add(n, "text") end end
  -- .copper number tokens for every money base + flavor (haul/loot/cash/perhour/… incl .short/.full).
  -- These mirror the copper fields BuildFields now stores; a number type so it's colorable/formattable.
  for _, base in ipairs({ "haul", "total", "loot", "gross", "gross.perhour", "perhour", "cash",
                          "token.price", "tokenprice", "token.value",
                          "items.value", "items.price", "items.last.value", "items.last.price" }) do
    add(base .. ".copper", "number")
  end
  return out
end

local Tpl = LibStub and LibStub("GECTemplate-1.0", true)

-- Read OTHER addons' feeds via the shared standard (replaces the bespoke Broker.lua resolver):
-- wiring GECData's consumer into Haul's engine makes {sbf.*}, {haul.*} and any LDB feed's {slug}/
-- {slug.token} resolve in Haul's bar/detail templates. Idempotent (safe on /reload). {tsm.*} bridge
-- tokens already resolve because Haul loads the Bridge files.
--
-- DEV-ONLY: consuming outside (cross-addon GEC) feeds is gated behind Haul.IsDev(). Run from
-- PLAYER_LOGIN (Core) — after SavedVariables load — so the runtime `/haul dev` toggle (HaulDB.dev)
-- governs it; at file-load time HaulDB isn't loaded yet, so IsDev() couldn't see the saved flag.
-- Haul's native pricing/token/vault feeds are untouched (always on).
function ns.InitFeedConsumer()
  if not (Haul and Haul.IsDev and Haul.IsDev()) then return end
  local GECData = LibStub and LibStub("GECData-1.0", true)
  if Tpl and GECData and GECData.RegisterConsumer then GECData.RegisterConsumer(Tpl) end
end

if Tpl then
  -- "rep" type: handles bare {rep} (v = BuildFields fields.rep = tostring(total) or "")
  -- and parameterized {rep(Faction)} (v = arg = faction name). Both return self-colored.
  -- The resolver distinguishes the two cases: a numeric string is the bare total; anything
  -- else is treated as a faction name for the per-faction lookup.
  Tpl.RegisterType("rep", function(v, facet, ctx)
    local n = tonumber(v)
    if n ~= nil then
      -- bare {rep}: v is the formatted session total ("1500" / "-150"); color by sign, value verbatim
      return "|cff" .. (n < 0 and "ff6060" or "1eff00") .. v .. "|r", true
    elseif v == "" then
      return "", true   -- zero / no rep this session
    else
      -- {rep(Faction)}: v is the faction name (the arg). rep is keyed by factionID now, so resolve the
      -- typed name -> id first, falling back to the raw name key (for an unresolved / name-fallback entry).
      local key = (ns.ResolveFactionID and ns.ResolveFactionID(v)) or v
      local amt = (ns.session and ns.session.rep and (ns.session.rep[key] or ns.session.rep[v])) or 0
      return amt ~= 0 and RepValue(amt) or "", true
    end
  end)

  -- "source" type: renders the price-source label with the theme's current accent color.
  -- Reading Theme.accentHex at render time so palette swaps are reflected immediately.
  Tpl.RegisterType("source", function(v, facet, ctx)
    local hex = Theme.accentHex
    return "|cff" .. hex .. tostring(v) .. "|r", true
  end)
end

-- Renderer instance: no `base` so plain text keeps the fontstring's own color (no baked wrap).
local templateRenderer = Tpl and Tpl.New({ tokens = buildTokenSpec() })
ns.templateRenderer = templateRenderer   -- exposed for the GECFeedBrowser (live token preview + feed resolution)

-- Public render API for all call sites (header, detail): delegates to the shared GECTemplate engine.
-- buildTokenSpec reproduces Haul's verbatim/default-color behavior and BuildFields is unchanged, so
-- output is identical to the former local renderer.
function ns.RenderTemplate(template, fields)
  if templateRenderer then return templateRenderer:Render(template or "", fields or {}) end
  return template or ""   -- degraded fallback if the shared lib somehow didn't load
end

------------------------------------------------------------------ refresh ----
function ns.RefreshUI()
  if not win or not win:IsShown() then return end   -- hidden window: skip the whole (expensive) BuildFields/ComputeStats pass
  local fields = ns.BuildFields()
  win.barText:SetText(ns.RenderTemplate(
    HaulDB.headerTemplate or "{time}   {haul}   {perhour}/hr", fields))
  UpdateBarHeight()   -- grow the bar for multi-line headers

  -- running stats panel — rendered through the engine from the user-editable Detail layout template
  win.statText:SetText(ns.RenderTemplate(HaulDB.detailTemplate or "{haul.full}", fields))
  UpdateStatsHeight()   -- protect the bottom row from a tall/wrapping detail template

  -- notification line: a transient message (last looted item / saved / reset).
  local note = ""
  if ns._notifyMsg and GetTime() < (ns._notifyUntil or 0) then
    note = ns._notifyMsg
  end
  win.notify:SetText(note)
  -- track button label + bar pause/play icon + paused/active tint — ALL read IsTracking() here, so the
  -- background can never desync from the buttons (this is the single per-refresh UI sync every path hits).
  if ns.ApplyTrackingTint then ns.ApplyTrackingTint() end
  win.btnTrack:SetText(ns.IsTracking() and "Pause" or "Resume")
  if ns.UpdatePlayButton then ns.UpdatePlayButton() end
  if win.list:IsShown() and win.accordion then
    win.accordion:SetEntries(BuildEntries())   -- builds for the active (category, view)
  end
end

-------------------------------------------------------------------- build ----
function ns.BuildUI()
  if win then return end
  win = CreateFrame("Frame", "HaulFrame", UIParent, "BackdropTemplate")
  ns.win = win
  win:SetSize(WIDTH, BAR_H)
  win:SetScale(HaulDB.scale or 1.0)
  local w = HaulDB.window
  -- migrate any pre-pixel saved position to screen pixels (preserves its current
  -- on-screen spot) so scaling no longer drifts it
  if w.left and w.top and not w._px then
    local es = win:GetEffectiveScale()
    if es and es > 0 then w.left, w.top, w._px = w.left * es, w.top * es, true end
  end
  ns.ApplyWindowPos()
  Theme.Panel(win, { bg = "headerBg", alpha = HaulDB.bgAlpha or 0.88 })
  win:SetMovable(true); win:SetClampedToScreen(true)
  -- ---- resizable WIDTH (drag the right edge); height stays content-driven ----
  win:SetResizable(true)
  -- min width = bottom button row (+ margins + the corner grip's room) so the buttons can't run off;
  -- min height = bar + stats + buttons + a couple list rows.
  local btnRowW = 56 + 4 + 56 + 4 + 56 + 4 + 64 + (Haul.IsDev() and (4 + 22) or 0)   -- Reset/Resume/Save/Options [+R]
  local MINW = btnRowW + 26
  local MINH = BAR_H + STATS_H + BTN_H + 48
  if win.SetResizeBounds then win:SetResizeBounds(MINW, MINH) end
  win:SetWidth(math.max(MINW, HaulDB.window.width or WIDTH))
  -- bottom-right CORNER grip: resizes WIDTH + HEIGHT; the extra height grows the scrollable list.
  local grip = CreateFrame("Frame", nil, win)
  grip:SetPoint("BOTTOMRIGHT", 0, 0); grip:SetSize(16, 16); grip:EnableMouse(true)
  grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    win:StopMovingOrSizing()
    HaulDB.window.width = win:GetWidth()
    if win.list and win.list:IsShown() then HaulDB.window.listH = math.floor(win.list:GetHeight() + 0.5) end
    if ns.SaveWindowPos then ns.SaveWindowPos() end
  end)
  local gt = grip:CreateTexture(nil, "OVERLAY")
  gt:SetPoint("BOTTOMRIGHT", -1, 1); gt:SetSize(12, 12)
  gt:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  gt:SetVertexColor(unpack(Theme.colors.dropdownArrow))

  -- ---- bar (always visible) ----
  local bar = CreateFrame("Button", nil, win)
  win.bar = bar
  bar:SetPoint("TOPLEFT", 0, 0); bar:SetPoint("TOPRIGHT", 0, 0); bar:SetHeight(BAR_H)
  bar:RegisterForDrag("LeftButton")
  bar:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  bar:SetScript("OnDragStart", function() win:StartMoving() end)
  bar:SetScript("OnDragStop", function()
    win:StopMovingOrSizing()
    ns.SaveWindowPos()    -- store top-left in screen pixels, then re-pin
    ns.ApplyWindowPos()
  end)
  -- a plain click (left or right, not a drag) toggles collapse — no arrow needed
  bar:SetScript("OnClick", function() SetExpanded(not HaulDB.window.expanded) end)

  -- far-left brand label (top-aligned so a multi-line header flows below it)
  win.brand = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  win.brand:SetPoint("TOPLEFT", 8, -5); win.brand:SetText("|cff45c4a0Haul|r")

  -- GameFontHighlight = white so un-colored coin numbers render white. Top-
  -- anchored with word-wrap ON so {linewrap} / long content flows onto more
  -- lines (the bar grows to fit, see UpdateBarHeight).
  win.barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  win.barText:SetPoint("TOPLEFT", win.brand, "TOPRIGHT", 8, 0)
  win.barText:SetPoint("RIGHT", bar, "RIGHT", -26, 0)
  win.barText:SetJustifyH("LEFT"); win.barText:SetJustifyV("TOP")
  win.barText:SetWordWrap(true)

  -- item links in the header ({items.last} / {items.last.name}) get a hover tooltip
  bar:SetHyperlinksEnabled(true)
  bar:SetScript("OnHyperlinkEnter", function(self, link)
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
  end)
  bar:SetScript("OnHyperlinkLeave", GameTooltip_Hide)

  -- pause/play toggle, right in the bar so you can pause without expanding. Shows
  -- two bars (pause) while running, a forward arrow (play) while paused.
  local pp = CreateFrame("Button", nil, bar)
  pp:SetSize(16, 16); pp:SetPoint("TOPRIGHT", -4, -4)
  pp:SetFrameLevel(bar:GetFrameLevel() + 4)   -- above the bar's collapse-click area
  pp:RegisterForClicks("LeftButtonUp")
  pp.arrow = pp:CreateTexture(nil, "ARTWORK")             -- play (paused state)
  pp.arrow:SetAllPoints()
  pp.arrow:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
  pp.bar1 = pp:CreateTexture(nil, "ARTWORK")              -- pause (running state)
  pp.bar1:SetColorTexture(0.92, 0.92, 0.92, 0.95)
  pp.bar1:SetSize(4, 12); pp.bar1:SetPoint("CENTER", -3, 0)
  pp.bar2 = pp:CreateTexture(nil, "ARTWORK")
  pp.bar2:SetColorTexture(0.92, 0.92, 0.92, 0.95)
  pp.bar2:SetSize(4, 12); pp.bar2:SetPoint("CENTER", 3, 0)
  pp:SetScript("OnClick", function() ns.ToggleTracking() end)
  pp:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(ns.IsTracking() and "Pause tracking" or "Resume tracking")
    GameTooltip:Show()
  end)
  pp:SetScript("OnLeave", GameTooltip_Hide)
  win.playBtn = pp

  function ns.UpdatePlayButton()
    if not win or not win.playBtn then return end
    local running = ns.IsTracking()
    win.playBtn.bar1:SetShown(running)
    win.playBtn.bar2:SetShown(running)
    win.playBtn.arrow:SetShown(not running)
  end

  -- ---- body ----
  local body = CreateFrame("Frame", nil, win, "BackdropTemplate")
  win.body = body
  body:SetPoint("TOPLEFT", 4, -BAR_H); body:SetPoint("TOPRIGHT", -4, -BAR_H)
  body:SetPoint("BOTTOM", win, "BOTTOM", 0, 4)
  body:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })   -- own fill so it colours independently of the header
  -- body colour is applied (separately from the header) in ApplyHeaderStyle

  win.stats = CreateFrame("Frame", nil, body)
  win.stats:SetPoint("TOPLEFT", 0, 0); win.stats:SetPoint("TOPRIGHT", 0, 0)
  win.stats:SetHeight(STATS_H)
  win.statText = win.stats:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  win.statText:SetPoint("TOPLEFT", 4, -4)
  win.statText:SetPoint("TOPRIGHT", -4, -4)   -- bound width so long lines wrap (not off-side)
  win.statText:SetJustifyH("LEFT")
  win.statText:SetSpacing(3)

  -- ---- control row (bottom of the stats area): [+/-] collapse button + [Loot] category button ----
  -- Collapse button: one of our themed buttons; shows/hides the whole list panel ("-" shown / "+" hidden).
  win.listToggle = CreateFrame("Button", nil, win.stats, "UIPanelButtonTemplate")
  win.listToggle:SetSize(22, 18); win.listToggle:SetPoint("BOTTOMLEFT", 0, 2)
  Theme.Button(win.listToggle)
  function win.UpdateCollapseSquare()
    win.listToggle:SetText(HaulDB.window.listShown and "-" or "+")   -- "-" = click to collapse, "+" = expand
  end
  win.UpdateCollapseSquare()
  win.listToggle:SetScript("OnClick", function() SetListShown(not HaulDB.window.listShown) end)
  win.listToggle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(HaulDB.window.listShown and "Hide the list" or "Show the list"); GameTooltip:Show()
  end)
  win.listToggle:SetScript("OnLeave", GameTooltip_Hide)

  -- Category button: rotates Loot -> Rep -> Currency -> Skills -> XP -> Loot, persisting HaulDB.window.category.
  -- Fixed width = the widest category label (measured below) so rotating never resizes it.
  -- "all" is intentionally NOT in the cycle for now (the all-view isn't ready — see BuildAllEntries, kept
  -- dormant). CAT_LABEL keeps "all" so the dormant path still labels correctly when it's re-enabled.
  local CATS = { "loot", "mail", "vendor", "rep", "currency", "prof", "xp", "kill" }
  local CAT_LABEL = { all = "All", loot = "Loot", mail = "Mail", vendor = "Vendor", rep = "Rep", currency = "Currency", prof = "Skills", xp = "XP", kill = "Kills" }
  local function nextCat(c)
    for i, k in ipairs(CATS) do if k == c then return CATS[(i % #CATS) + 1] end end
    return CATS[1]
  end
  win.catBtn = CreateFrame("Button", nil, win.stats, "UIPanelButtonTemplate")
  win.catBtn:SetHeight(18); win.catBtn:SetPoint("LEFT", win.listToggle, "RIGHT", 4, 0)
  Theme.Button(win.catBtn)
  -- fixed width = the widest category label + room for the dropdown arrow, so switching never resizes it
  do
    local m = win.catBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local widest = 0
    for _, c in ipairs(CATS) do
      m:SetText(CAT_LABEL[c]); widest = math.max(widest, m:GetStringWidth() or 0)
    end
    m:Hide()
    win.catBtn:SetWidth(math.max(56, math.ceil(widest) + 38))   -- label + arrow clearance (no overlap on "Currency")
  end
  do   -- down-arrow so it reads as a dropdown (matches the Columns dropdown)
    local a = win.catBtn:CreateTexture(nil, "OVERLAY")
    a:SetTexture("Interface\\Buttons\\Arrow-Down-Up"); a:SetSize(12, 12); a:SetPoint("RIGHT", -3, -1)
  end
  do   -- left-align the label so the arrow never sits over the last letter (e.g. the "y" in Currency)
    local fs = win.catBtn:GetFontString()
    if fs then fs:ClearAllPoints(); fs:SetPoint("LEFT", 6, 0); fs:SetJustifyH("LEFT") end
  end
  function win.UpdateCategoryButton()
    win.catBtn:SetText(CAT_LABEL[HaulDB.window.category or "loot"] or "Loot")
  end
  win.UpdateCategoryButton()
  -- Category is now a DROPDOWN (too many categories to cycle through). A radio menu lists every category;
  -- falls back to cycling only if the modern MenuUtil API is missing.
  win.catBtn:SetScript("OnClick", function(self)
    if not MenuUtil then
      HaulDB.window.category = nextCat(HaulDB.window.category or "loot")
      win.UpdateCategoryButton(); if ns.RefreshUI then ns.RefreshUI() end
      return
    end
    MenuUtil.CreateContextMenu(self, function(_, root)
      root:CreateTitle("Category")
      for _, k in ipairs(CATS) do
        root:CreateRadio(CAT_LABEL[k], function() return (HaulDB.window.category or "loot") == k end, function()
          HaulDB.window.category = k
          win.UpdateCategoryButton()
          if ns.RefreshUI then ns.RefreshUI() end
        end)
      end
    end)
  end)
  win.catBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("List category")
    GameTooltip:AddLine("Choose Loot / Mail / Vendor / Rep / Currency / Skills / XP / Kills", 0.9, 0.9, 0.9, true)
    GameTooltip:Show()
  end)
  win.catBtn:SetScript("OnLeave", GameTooltip_Hide)

  -- Columns dropdown (bottom-RIGHT of the loot row): multi-select which item columns show. Value is
  -- always on; Percentage adds the "% of drops" column in the Collection view. Same 18px row height.
  win.colBtn = CreateFrame("Button", nil, win.stats, "UIPanelButtonTemplate")
  -- right edge inset to match the list's viewing area (the list insets -16 for its scrollbar), so the
  -- dropdown lines up with the content column, not the panel/scrollbar edge.
  win.colBtn:SetSize(24, 18); win.colBtn:SetPoint("BOTTOMRIGHT", -16, 2)
  Theme.Button(win.colBtn)
  do
    local a = win.colBtn:CreateTexture(nil, "OVERLAY")
    a:SetTexture("Interface\\Buttons\\Arrow-Down-Up"); a:SetSize(12, 12); a:SetPoint("CENTER", 0, -1)
  end
  win.colBtn:SetScript("OnClick", function(self)
    if not MenuUtil then return end   -- modern retail menu API
    MenuUtil.CreateContextMenu(self, function(_, root)
      root:CreateTitle("Columns")
      local v = root:CreateCheckbox("Value", function() return true end,
        function() return MenuResponse and MenuResponse.Refresh end)   -- always on (no-op toggle)
      if v.SetEnabled then v:SetEnabled(false) end
      root:CreateCheckbox("Percentage", function() return HaulDB.window.colPct end, function()
        HaulDB.window.colPct = not HaulDB.window.colPct
        if ns.RefreshUI then ns.RefreshUI() end
        return MenuResponse and MenuResponse.Refresh   -- keep the menu open for multi-select
      end)
      root:CreateCheckbox("Source", function() return HaulDB.window.colSrc end, function()
        HaulDB.window.colSrc = not HaulDB.window.colSrc   -- opt-in loot-source icon column
        if ns.RefreshUI then ns.RefreshUI() end
        return MenuResponse and MenuResponse.Refresh
      end)
    end)
  end)
  win.colBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Columns"); GameTooltip:AddLine("Item columns: Value, % of drops, Source icon", 0.9, 0.9, 0.9)
    GameTooltip:Show()
  end)
  win.colBtn:SetScript("OnLeave", GameTooltip_Hide)

  -- notification line: between the category button and the Columns dropdown.
  -- Shows transient messages (last item / saved / reset). Clipped.
  win.notify = win.stats:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  win.notify:SetPoint("LEFT", win.catBtn, "RIGHT", 6, 0)
  win.notify:SetPoint("RIGHT", win.colBtn, "LEFT", -4, 0)
  win.notify:SetJustifyH("LEFT"); win.notify:SetWordWrap(false)

  -- bottom buttons, pinned to the bottom of the body with padding
  win.buttons = CreateFrame("Frame", nil, body)
  win.buttons:SetHeight(BTN_H)
  win.buttons:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 4, 6)
  win.buttons:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -4, 6)
  local function mk(label, onClick, wdt)
    local b = CreateFrame("Button", nil, win.buttons, "UIPanelButtonTemplate")
    b:SetSize(wdt or 64, 22); b:SetText(label); b:SetScript("OnClick", onClick)
    Theme.Button(b)
    return b
  end
  local bReset = mk("New", function() ns.Reset() end, 56)   -- "New" = start a fresh session (banks the current run first)
  bReset:SetPoint("LEFT", 0, 0)
  win.btnTrack = mk("Resume", function() ns.ToggleTracking() end, 56)
  win.btnTrack:SetPoint("LEFT", bReset, "RIGHT", 4, 0)
  local bSave = mk("Save", function() ns.SaveSession() end, 56)
  bSave:SetPoint("LEFT", win.btnTrack, "RIGHT", 4, 0)
  local bOpt = mk("Options", function() ns.ToggleOptions() end, 64)
  bOpt:SetPoint("LEFT", bSave, "RIGHT", 4, 0)

  -- scrollable list fills the space between the stats and the buttons
  win.list = CreateFrame("ScrollFrame", "HaulListScroll", body, "BackdropTemplate")   -- own backdrop (ContentPanel paints it); modern MinimalScrollBar attached below
  win.list:SetPoint("TOPLEFT", win.stats, "BOTTOMLEFT", 0, -2)
  win.list:SetPoint("TOPRIGHT", win.stats, "BOTTOMRIGHT", -16, -2)
  win.list:SetPoint("BOTTOM", win.buttons, "TOP", 0, 4)
  win.scrollChild = CreateFrame("Frame", nil, win.list)
  win.scrollChild:SetSize(WIDTH - 30, 1)
  win.list:SetScrollChild(win.scrollChild)
  Theme.ContentPanel(win.list)   -- the item list is an intentional list → its own contentBg/border
  ns.AttachScrollBar(win.list)
  win.list:HookScript("OnSizeChanged", function(self) win.scrollChild:SetWidth(math.max(1, self:GetWidth())) end)

  -- the generic accordion renderer over the scroll child; entry builders feed it each refresh
  -- columns render RIGHT->LEFT: value (always), then pct, then the opt-in source icon to pct's LEFT
  -- ("in front of the percentages"). pct/src are optional → collapse to 0 width when off/empty.
  win.accordion = Theme.AccordionList(win.scrollChild, { theme = Theme, rowH = ROW_H, indent = 14,
    columns = { { key = "value", max = 130 }, { key = "pct", max = 56, optional = true },
                { key = "src", max = 16, optional = true, gap = 3 } } })

  ns.ApplyHeaderStyle()   -- scale / font size / color / spacing / padding
  Relayout()
  win:Show()

  -- live ticker: keep the timer / g-hr moving while shown
  C_Timer.NewTicker(1, function() ns.RefreshUI() end)
  ns.RefreshUI()
end
