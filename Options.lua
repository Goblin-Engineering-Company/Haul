-- Options.lua — configuration page. Everything is configurable here.
local ADDON, ns = ...
local Theme = LibStub("GECTheme-1.0").ForAddon(
  function() return (HaulDB and HaulDB.themePreset) or "gruvbox" end,
  function(v) HaulDB.themePreset = v end)

-- Shared keybinding lib: the native-binding capture cell + the "already bound, reassign?" conflict prompt.
local GECBind = LibStub:GetLibrary("GECBind-1.0")

local panel  -- lazily built

-- notable threshold choices, each labeled in its in-game item-quality color
local NOTE_LEVELS = {
  { q = 1, label = "|cffffffffCommon|r+" },
  { q = 2, label = "|cff1eff00Uncommon|r+" },
  { q = 3, label = "|cff0070ddRare|r+" },
  { q = 4, label = "|cffa335eeEpic|r+" },
  { q = 5, label = "|cffff8000Legendary|r+" },
}
-- One consolidated price-source list: source + (for TSM) the metric. Vendor is
-- a single entry (TSM's vendorsell pulls the same value, so it's omitted).
local SOURCE_OPTIONS = {
  { label = "TSM: Minimum Buyout",    source = "tsm", tsm = "dbminbuyout" },
  { label = "TSM: Market Value",      source = "tsm", tsm = "dbmarket" },
  { label = "TSM: Region Market Avg", source = "tsm", tsm = "dbregionmarketavg" },
  { label = "TSM: Region Min Buyout", source = "tsm", tsm = "dbregionminbuyoutavg" },
  { label = "TSM: Historical",        source = "tsm", tsm = "dbhistorical" },
  { label = "Auctionator",            source = "auctionator" },
  { label = "Vendor",                 source = "vendor" },
}

-- (MakeCheck removed — all option checkboxes are now GECTheme `check` leaves in the box trees.)

-- (MakeSlider removed — the Header tab's display sliders are now built by the box-tree-local sliderRow
--  helper, which keeps the same custom Init/silentSet and hosts the slider via { frame } in the tree.)

-- accordion default-state choices for the "can only vendor / excluded" buckets. The DB values are
-- unchanged (show/merge/ignore) but reinterpreted (Spec 2 §6): the bucket is ALWAYS an accordion group
-- when not Hidden — the mode only sets the group's DEFAULT open state, which window.groupOpen then
-- remembers per click. show -> Expanded (open), merge -> Collapsed (closed), ignore -> Hidden (omit).
local MODE_OPTS = {
  { v = "show",   label = "Expanded" },
  { v = "merge",  label = "Collapsed" },
  { v = "ignore", label = "Hidden" },
}
local VIEW_OPTS = {
  { v = "collection", label = "Collection" }, { v = "list", label = "List" },
}
local SORT_OPTS = {
  { v = "value", label = "Value" }, { v = "name", label = "Name" },
  { v = "count", label = "Count" }, { v = "time", label = "Time" },
}
-- global money format: Short = largest unit only (3g); Long = full g/s/c (3g 47s 21c). Affects EVERY value.
local VALUE_FMT_OPTS = {
  { v = "short", label = "Short (3g)" }, { v = "long", label = "Long (3g 47s 21c)" },
}
-- a small radio dropdown bound to a getter/setter over an {v,label} option list
local function MakeChoiceDD(parent, x, y, w, opts, getter, setter)
  local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  dd:SetSize(w or 150, 22); dd:SetPoint("TOPLEFT", x, y)
  dd:SetupMenu(function(_dd, root)
    for _, o in ipairs(opts) do
      root:CreateRadio(o.label, function() return getter() == o.v end,
        function() setter(o.v); if ns.RefreshUI then ns.RefreshUI() end end)
    end
  end)
  Theme.SkinDropdown(dd)
  return dd
end

local function AttachTip(frame, title, body)
  frame:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    if body then GameTooltip:AddLine(body, 0.9, 0.9, 0.9, true) end
    GameTooltip:Show()
  end)
  frame:HookScript("OnLeave", GameTooltip_Hide)
end

local PRICE_HELP = "Where item values come from:\n"
  .. Theme.Accent("vendor") .. " = sell-to-vendor price (always available)\n"
  .. Theme.Accent("auctionator") .. " = Auctionator's last-scanned auction price\n"
  .. Theme.Accent("tsm") .. " = TradeSkillMaster (uses the price string below)\n"
  .. "Auction sources need the addon installed AND a recent AH scan."

local HEADER_HELP =
    "Type any text for the top bar and drop in {tokens}.\n\n"
  .. Theme.Accent("Tokens") .. "\n"
  .. "{time}  {time.current}  {time.current.ampm}  {time.ig}\n"
  .. "{haul}=total  {total}  {loot}  {cash}  {gross}  {perhour}  {gross.perhour}\n"
  .. "{items.count}  {items.value}  {items.notable}\n"
  .. "{items.last}  {items.last.name}  {items.last.count}  {items.last.value}\n"
  .. "{token.percent}  {token.price}  {token.trend}  {zone}  {source}  {flushed}\n"
  .. "any money token takes .short (top unit, 40s) or .full (g s c); bare = short\n"
  .. "(items.last = previous drop, name shown in its item-quality\n"
  .. " color; time.ig = since login)\n\n"
  .. Theme.Accent("Great Vault") .. "\n"
  .. "{vault.delve.slots}  {vault.delve.tier}  {vault.delve.ilvl}\n"
  .. "(also .done .next .s1 .s2 .s3; tracks: raid, dungeon, delve)\n"
  .. "{vault.delve}  = summary,  {vault.ready} = claim alert\n\n"
  .. Theme.Accent("Color a token") .. "\n"
  .. "{token:color}  —  color is a name (blue, green,\n"
  .. "gold, white, red, purple, orange) or hex like 66ccff.\n"
  .. "Money tokens keep their own g/s/c colors.\n\n"
  .. Theme.Accent("New line") .. "\n"
  .. "{br}  jumps to the next line; the bar grows to fit.\n"
  .. "(also {lb}, {lw}, {linewrap})\n\n"
  .. Theme.Accent("Example") .. "\n"
  .. "{time}{br}Haul {haul}   {token:blue}"

-- ----- keybind capture (assign a key combo to a named Haul binding) -----
-- The capture cell + the game-style "already bound, reassign?" conflict prompt come from the shared GECBind
-- lib, so every native binding (here, the HAUL_* actions declared in Bindings.xml) reads/writes WoW's own
-- Key Bindings — this tab and the game's Key Bindings menu can never disagree.
local function MakeKeybindRow(parent, y, entry)
  local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  lbl:SetPoint("TOPLEFT", 4, y); lbl:SetWidth(190); lbl:SetJustifyH("LEFT")
  lbl:SetText(entry.label)
  Theme.Font(lbl, "text")
  local btn = GECBind.CreateButton(parent, { command = entry.name, kind = "key", width = 150, skin = Theme.Button })
  btn:SetPoint("TOPLEFT", 200, y + 3)
  local clr = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  clr:SetSize(50, 22); clr:SetPoint("LEFT", btn, "RIGHT", 4, 0); clr:SetText("Clear")
  Theme.Button(clr)
  clr:SetScript("OnClick", function()
    if InCombatLockdown() then return end
    GECBind.Clear(entry.name, "key"); btn:Reload()
  end)
end

local function Build()
  -- Standalone floating window (GECTheme fixture) — NOT a Blizzard Settings canvas,
  -- so it floats over the game at MEDIUM strata and never traps clicks/casts the way
  -- the protected Settings panel does. Matches Megaphone / SBF.
  HaulDB.optionsWin = HaulDB.optionsWin or {}
  local winContent
  panel, winContent = Theme.Window({
    name = "HaulOptionsFrame", title = "Haul",
    -- One window size that fits the tallest fixed-content tab (Header, ~594px scroll
    -- child) without scrolling, and wide enough that the General left column fits its
    -- label + the 210px price-source dropdown. Header band 34 + tab strip/top inset ≈
    -- 56 → window height ≈ pageHeight + 90 (594 → ~684, rounded up to 700).
    width = 640, height = 700, minWidth = 560, minHeight = 600,   -- base floor; the real min-width is derived from the General box tree (genRoot:ApplyMinSize) and supersedes this
    -- specialFrame=false so Escape (and CloseSpecialWindows on the Blizzard Settings panel)
    -- never closes it. persistShown=false so it always starts CLOSED on login/reload (opened on demand
    -- via the Options button) — the config must never pop open on load.
    resizable = true, collapsible = true, specialFrame = false, persistShown = false,
    savedKey = HaulDB.optionsWin,
  })


  -- reserve a bottom band for the dev Reload-UI/console bar (built above) so tab pages stop ABOVE it
  -- instead of overrunning it. Public builds have no bar, so they keep the tight 12px inset.
  local PAGE_BOTTOM = Haul.IsDev() and 40 or 12
  local function MakePage()
    local p = CreateFrame("Frame", nil, winContent)
    p:SetPoint("TOPLEFT", 10, -44)                                  -- below the tab strip
    p:SetPoint("BOTTOMRIGHT", winContent, "BOTTOMRIGHT", -10, PAGE_BOTTOM)
    p:Hide()
    return p
  end
  -- Header + Watchers can overflow the visible area, so wrap each in a scroll child +
  -- an auto-hiding MinimalScrollBar. Returns (rawPage, child): the tab shows/hides
  -- `raw`; page content parents to `child`.
  local function MakeScrollPage(childH)
    local raw = MakePage()
    local sf = CreateFrame("ScrollFrame", nil, raw)
    sf:SetPoint("TOPLEFT", 0, 0); sf:SetPoint("BOTTOMRIGHT", -16, 0)
    local child = CreateFrame("Frame", nil, sf); child:SetSize(480, childH); sf:SetScrollChild(child)
    if ns.AttachScrollBar then ns.AttachScrollBar(sf, raw) end
    local function fitChild()
      child:SetWidth(math.max(1, sf:GetWidth())); if sf.RefreshScrollBar then sf.RefreshScrollBar() end
    end
    sf:SetScript("OnSizeChanged", fitChild)
    -- OnSizeChanged doesn't fire when the size was already set (e.g. tab shown without a resize), so also
    -- fit on show and once next frame, so the content always fills the page width.
    raw:HookScript("OnShow", function() fitChild() end)
    if C_Timer and C_Timer.After then C_Timer.After(0, fitChild) end
    return raw, child
  end
  local pData, pKeybinds, pLog = MakePage(), MakePage(), MakePage()
  local pDebug   -- dev-only Debug tab; its page frame is created in the dev block below, so no dead frame ships
  local pGeneral = MakePage()   -- non-scroll: its content fits the fixed window, so no scrollbar reserve eats width
  local rawHeader, pHeader = MakeScrollPage(594)   -- +54 for the taller header-layout box
  local rawAbout, pAbout = MakeScrollPage(460)     -- scrollable About page (banner can push content below the fold)
  for _, p in ipairs({ pData, pKeybinds, pLog, pGeneral, rawHeader, rawAbout }) do
    p:SetFrameLevel(winContent:GetFrameLevel() + 2)   -- controls above the window bg
  end
  local TABS = {
    { key = "general",  label = "General",  page = pGeneral },
    { key = "header",   label = "Header",   page = rawHeader },
  }
  -- (Watcher bars extracted to the standalone Gadgets addon — no Watchers tab here anymore.)
  TABS[#TABS + 1] = { key = "data",     label = "Data",     page = pData }
  TABS[#TABS + 1] = { key = "keybinds", label = "Keybinds", page = pKeybinds }
  TABS[#TABS + 1] = { key = "about",    label = "About",    page = rawAbout }
  -- Log tab SHIPS active — the raw event-log viewer is a user-facing feature (see exactly what Haul captured).
  TABS[#TABS + 1] = { key = "log", label = "Log", page = pLog }
  local ShowTab   -- forward decl (init calls it)
  local tabSetActive = Theme.TabStrip(winContent, 8, -8, TABS, function(key) ShowTab(key) end)
  function ShowTab(key)
    local found
    for _, t in ipairs(TABS) do if t.key == key then found = true end end
    if not found then key = TABS[1].key end   -- e.g. "watchers" when the dev tab is hidden
    for _, t in ipairs(TABS) do t.page:SetShown(t.key == key) end
    tabSetActive(key)
    panel.currentTab = key
  end
  panel.ShowTab = ShowTab   -- exposed for ToggleOptions / OpenToSessions (outside Build)

  -- ===== PAGE: About (banner / name / version / tagline / website / license) — mirrors SBF's About tab.
  -- Brand + name + version (with channel badge), a copyable Website link, and the license notice. The
  -- donate/vote ASK stays on the WEBSITE (Blizzard policy) — the addon only ever links out, never asks.
  -- (No "Show welcome screen" button yet — Haul has no welcome screen; add both together later.)
  do
    local ABOUT_URL = "https://goblineng.co"
    local ver = Haul.BUILD or "?"
    local BANNER_ASPECT = 512 / 279   -- the cropped band's aspect (~1.835:1) — width / this = height
    local BANNER_MAX_W = 512          -- native band width; never upscale past it
    local BANNER_TOP = 8

    -- Goblin Engineering Company banner (goblin + brand). 512x512 TGA (WoW can't load PNG); SetTexCoord crops to the band.
    local banner = pAbout:CreateTexture(nil, "ARTWORK")
    banner:SetPoint("TOP", pAbout, "TOP", 0, -BANNER_TOP)
    banner:SetTexture("Interface\\AddOns\\Haul\\art\\goblin.tga")
    banner:SetTexCoord(0, 1, 0.2266, 0.7715)

    local title = pAbout:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", banner, "BOTTOM", 0, -10); title:SetText(Theme.Accent("Haul"))

    local verFS = pAbout:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    verFS:SetPoint("TOP", title, "BOTTOM", 0, -4)
    verFS:SetText("Version " .. tostring(ver) .. (Haul.ChannelBadge and Haul.ChannelBadge() or ""))   -- badge dev/prerelease/local
    Theme.Font(verFS, "textDim")

    -- tagline — brand-gold (e8c679), matching SBF's About/welcome styling.
    local tag = pAbout:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    tag:SetPoint("TOP", verFS, "BOTTOM", 0, -14)
    tag:SetText("|cffe8c679Know exactly what every session is worth.|r")

    -- the "does it all" one-liner: what Haul tracks and shows for you.
    local desc = pAbout:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOP", tag, "BOTTOM", 0, -8); desc:SetWidth(440); desc:SetJustifyH("CENTER")
    desc:SetText("Tracks everything you pick up — loot, coin, reputation, currency, kills, and XP — values it "
      .. "against vendor or auction prices, and shows your gold-per-hour in a movable bar, with saved sessions "
      .. "you can merge and compare.")
    Theme.Font(desc, "textDim")

    local div = pAbout:CreateTexture(nil, "ARTWORK")
    div:SetPoint("TOP", desc, "BOTTOM", 0, -14); div:SetSize(430, 1); div:SetColorTexture(unpack(Theme.colors.divider))

    -- Website invite (no copy-hint — the field auto-selects on click): point people at the brand site for the
    -- other add-ons + the roadmap they can vote on. The vote/donate ASK itself stays on the site (Blizzard).
    local wlbl = pAbout:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    wlbl:SetPoint("TOP", div, "BOTTOM", 0, -12); wlbl:SetWidth(440); wlbl:SetJustifyH("CENTER")
    wlbl:SetText("Check out our other add-ons, and vote on what we build next:")
    Theme.Font(wlbl, "text")

    local urlEb = CreateFrame("EditBox", nil, pAbout, "InputBoxTemplate")
    urlEb:SetSize(300, 22); urlEb:SetPoint("TOP", wlbl, "BOTTOM", 0, -6)
    urlEb:SetAutoFocus(false); urlEb:SetFontObject("ChatFontNormal"); Theme.EditBox(urlEb)
    urlEb:SetText(ABOUT_URL); urlEb:SetCursorPosition(0)
    urlEb:SetScript("OnEditFocusGained", function(s) s:HighlightText() end)
    urlEb:SetScript("OnTextChanged", function(s, user) if user then s:SetText(ABOUT_URL); s:HighlightText() end end)  -- read-only: snap back on any edit
    urlEb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    urlEb:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)

    -- Licensing — the short version of LICENSE.txt (proprietary Goblin Engineering Company license; the embedded
    -- Libs/ are separately MIT). Just the notice + a pointer to the file for the full terms — no external ask.
    local licDiv = pAbout:CreateTexture(nil, "ARTWORK")
    licDiv:SetPoint("TOP", urlEb, "BOTTOM", 0, -18); licDiv:SetSize(430, 1); licDiv:SetColorTexture(unpack(Theme.colors.divider))

    local licHdr = pAbout:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    licHdr:SetPoint("TOP", licDiv, "BOTTOM", 0, -10); licHdr:SetText(Theme.Accent("License"))

    local licCopy = pAbout:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    licCopy:SetPoint("TOP", licHdr, "BOTTOM", 0, -6); licCopy:SetWidth(440); licCopy:SetJustifyH("CENTER")
    licCopy:SetText("© 2026 Goblin Engineering Company. All rights reserved.")
    Theme.Font(licCopy, "text")

    local licBody = pAbout:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    licBody:SetPoint("TOP", licCopy, "BOTTOM", 0, -6); licBody:SetWidth(440); licBody:SetJustifyH("CENTER")
    licBody:SetText("Free to install, use, and read the source. You may not redistribute, re-host, publish "
      .. "modified or derivative versions, or use this code commercially without written permission. Embedded "
      .. "libraries under Libs\\ are separately MIT-licensed under their own terms. See LICENSE.txt for full terms.")
    Theme.Font(licBody, "textDim")

    -- keep the banner edge-to-edge + aspect-correct on resize, widen the dividers to match, and grow the scroll
    -- child so the content below the (possibly tall) banner scrolls into reach. ~360px = the fixed stack below.
    local function layoutAbout()
      local sf = pAbout:GetParent()
      local sw = (sf and sf:GetWidth()) or 0
      if sw <= 1 then return end
      pAbout:SetWidth(sw)                                      -- child fills the scroll frame so TOP-anchored content centres
      local bw = math.min(BANNER_MAX_W, sw - 24)              -- cap at native width; only shrinks on a narrow window
      banner:SetSize(bw, bw / BANNER_ASPECT)
      local dw = math.min(BANNER_MAX_W, sw - 60)
      div:SetWidth(dw); licDiv:SetWidth(dw)                    -- both dividers track the window width
      pAbout:SetHeight(BANNER_TOP + banner:GetHeight() + 360)  -- fixed stack below (desc + invite + url + license)
      if sf.RefreshScrollBar then sf.RefreshScrollBar() end
    end
    pAbout:HookScript("OnSizeChanged", layoutAbout)
    rawAbout:HookScript("OnShow", function() C_Timer.After(0, layoutAbout) end)
    layoutAbout()
  end

  -- section divider line (matches SBF's sectionHeader); under a gold |cffffd100…|r header
  local function sectionLine(parent, x, y, w)
    local ln = parent:CreateTexture(nil, "ARTWORK")
    ln:SetPoint("TOPLEFT", x, y); ln:SetHeight(1); ln:SetColorTexture(1, 1, 1, 0.10)
    if w then ln:SetWidth(w) else ln:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, 0) end
  end

  -- ===================== GENERAL: tracking, pricing, reload — ONE box tree =====================
  -- Two INDEPENDENT columns as a {dir="row"} of two column boxes (the box model's core case): LEFT grows,
  -- RIGHT is a fixed 246 (label 78 + gap 8 + 150 dropdown + the section's 10px content indent). Each
  -- section auto-stacks; no gcols, no hand y-offsets. Dropdown rows share a `basis` label column so every
  -- selector lines up; checkboxes are check leaves (AttachTip title/body carried via the render-fn help);
  -- the bespoke dropdowns keep their exact SetupMenu logic, HOSTED via { frame = w }.
  local LEFT_LBL_W, RIGHT_LBL_W = 92, 78

  -- AttachTip as a check-leaf render fn (title white + body gray, matching AttachTip exactly)
  local function tipFn(title, body)
    return function(owner)
      GameTooltip:SetOwner(owner, "ANCHOR_RIGHT"); GameTooltip:SetText(title, 1, 1, 1)
      if body then GameTooltip:AddLine(body, 0.9, 0.9, 0.9, true) end
      GameTooltip:Show()
    end
  end
  -- onBuild for a note label: hover-zone over the label text carrying the same AttachTip (whole-row help)
  local function labelTip(title, body)
    return function(fs)
      local z = CreateFrame("Frame", nil, fs:GetParent()); z:EnableMouse(true)
      z:SetPoint("TOPLEFT", fs, "TOPLEFT", -2, 2); z:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 2, -2)
      AttachTip(z, title, body)
    end
  end
  -- a [label(basis) , hosted dropdown] row; attaches the tooltip to the dropdown AND the label
  local function ddRow(labelText, dd, basisW, title, body)
    if title then AttachTip(dd, title, body) end
    return { dir = "row", align = "center", gap = 8,
      { note = { text = labelText, color = "text", onBuild = title and labelTip(title, body) or nil }, basis = basisW },
      { frame = dd } }
  end
  -- a check leaf bound to get/set with AttachTip help + optional indent (sub-row)
  local function chk(label, get, set, title, body, id, indent)
    return { id = id, check = { label = label, get = get, set = set,
      help = title and tipFn(title, body) or nil, indent = indent } }
  end

  -- ----- LEFT column widgets: price + notable dropdowns (bespoke SetupMenu, hosted) -----
  panel.sourceDD = CreateFrame("DropdownButton", nil, pGeneral, "WowStyle1DropdownTemplate")
  panel.sourceDD:SetSize(210, 22); panel.sourceDD:SetDefaultText("Pick a price source")
  panel.sourceDD:SetupMenu(function(_dd, root)
    for _, opt in ipairs(SOURCE_OPTIONS) do
      local avail = (opt.source == "vendor")
        or (opt.source == "tsm" and ns.PriceSourceAvailable("tsm"))
        or (opt.source == "auctionator" and ns.PriceSourceAvailable("auctionator"))
      if avail then
        root:CreateRadio(opt.label,
          function(o)
            if o.source == "tsm" then return HaulDB.priceSource == "tsm" and HaulDB.tsmPriceStr == o.tsm end
            return HaulDB.priceSource == o.source
          end,
          function(o) HaulDB.priceSource = o.source; if o.tsm then HaulDB.tsmPriceStr = o.tsm end
            if ns.RefreshUI then ns.RefreshUI() end end,
          opt)
      end
    end
  end)
  Theme.SkinDropdown(panel.sourceDD)
  panel.noteDD = CreateFrame("DropdownButton", nil, pGeneral, "WowStyle1DropdownTemplate")
  panel.noteDD:SetSize(160, 22); panel.noteDD:SetDefaultText("Quality")
  panel.noteDD:SetupMenu(function(_dd, root)
    for _, lvl in ipairs(NOTE_LEVELS) do
      root:CreateRadio(lvl.label,
        function() return HaulDB.notableQuality == lvl.q end,
        function() HaulDB.notableQuality = lvl.q; if ns.RefreshUI then ns.RefreshUI() end end)
    end
  end)
  Theme.SkinDropdown(panel.noteDD)

  -- ----- RIGHT column widgets: view / sort / grouping-mode dropdowns (MakeChoiceDD, hosted) -----
  panel.viewDD = MakeChoiceDD(pGeneral, 0, 0, 150, VIEW_OPTS, function() return HaulDB.view end,
    function(v) HaulDB.view = v; panel.Refresh() end)
  panel.repViewDD = MakeChoiceDD(pGeneral, 0, 0, 150, VIEW_OPTS, function() return HaulDB.repView end,
    function(v) HaulDB.repView = v; panel.Refresh() end)
  panel.currencyViewDD = MakeChoiceDD(pGeneral, 0, 0, 150, VIEW_OPTS, function() return HaulDB.currencyView end,
    function(v) HaulDB.currencyView = v; panel.Refresh() end)
  panel.profViewDD = MakeChoiceDD(pGeneral, 0, 0, 150, VIEW_OPTS, function() return HaulDB.profView end,
    function(v) HaulDB.profView = v; panel.Refresh() end)
  panel.xpViewDD = MakeChoiceDD(pGeneral, 0, 0, 150, VIEW_OPTS, function() return HaulDB.xpView end,
    function(v) HaulDB.xpView = v; panel.Refresh() end)
  panel.killViewDD = MakeChoiceDD(pGeneral, 0, 0, 150, VIEW_OPTS, function() return HaulDB.killView end,
    function(v) HaulDB.killView = v; panel.Refresh() end)
  panel.sortDD = MakeChoiceDD(pGeneral, 0, 0, 150, SORT_OPTS, function() return HaulDB.sortBy end,
    function(v) HaulDB.sortBy = v end)
  panel.valueFmtDD = MakeChoiceDD(pGeneral, 0, 0, 150, VALUE_FMT_OPTS, function() return HaulDB.valueFormat or "short" end,
    function(v) HaulDB.valueFormat = v; if ns.RefreshUI then ns.RefreshUI() end end)
  panel.boundDD = MakeChoiceDD(pGeneral, 0, 0, 150, MODE_OPTS, function() return HaulDB.boundMode end,
    function(v) HaulDB.boundMode = v end)
  panel.graysDD = MakeChoiceDD(pGeneral, 0, 0, 150, MODE_OPTS, function() return HaulDB.graysMode end,
    function(v) HaulDB.graysMode = v end)
  panel.excludedDD = MakeChoiceDD(pGeneral, 0, 0, 150, MODE_OPTS, function() return HaulDB.excludedMode end,
    function(v) HaulDB.excludedMode = v end)
  panel.mailDD = MakeChoiceDD(pGeneral, 0, 0, 150, MODE_OPTS, function() return HaulDB.mailMode end,
    function(v) HaulDB.mailMode = v end)

  -- inline flush interval editbox (sits on the "Auto reload every:" check row) + map-level dropdown
  panel.flushBox = CreateFrame("EditBox", nil, pGeneral, "InputBoxTemplate")
  panel.flushBox:SetSize(56, 20); panel.flushBox:SetAutoFocus(false); Theme.EditBox(panel.flushBox)
  panel.flushBox:SetScript("OnEnterPressed", function(self)
    HaulDB.flushSeconds = ns.Duration.ParseSeconds(self:GetText(), HaulDB.flushSeconds)
    self:SetText(ns.Duration.Format(HaulDB.flushSeconds)); self:ClearFocus(); ns.StartFlush()
  end)
  AttachTip(panel.flushBox, "Auto-reload interval",
    "How often to auto-reload. Enter a number with a unit: " .. Theme.Accent("10s") .. " (seconds), "
    .. Theme.Accent("10m") .. " (minutes), " .. Theme.Accent("1h") .. " (hours).")
  local MAP_LEVEL_OPTS = {
    { label = "Region / continent", v = "region" }, { label = "Zone", v = "zone" }, { label = "Sub-zone", v = "subzone" },
  }
  panel.mapLevelDD = MakeChoiceDD(pGeneral, 0, 0, 150, MAP_LEVEL_OPTS,
    function() return HaulDB.newSessionMapLevel or "region" end, function(v) HaulDB.newSessionMapLevel = v end)
  local mlTip = "How coarse a move counts: Region (continent only), Zone, or Sub-zone (every named area). "
    .. "A finer level ALSO fires on coarser moves — pick Zone and crossing a region counts too. Applies "
    .. "whether you Ask or switch automatically."
  AttachTip(panel.mapLevelDD, "Map level", mlTip)

  -- compose the two columns as locals so the dev Theme section can be appended under strip sentinels
  -- explicit column min-widths so the tree's MinWidth() reflects the real content: a hosted-dropdown
  -- frame leaf reports lw()=0, so without these the derived window min would ignore the dropdowns.
  -- LEFT = label 92 + gap 8 + price dropdown 210 + section indent 10; RIGHT = 78 + 8 + 150 + 10.
  local leftCol = { grow = 1, minWidth = 320,
    { section = "Loot value",
      ddRow("Price source:", panel.sourceDD, LEFT_LBL_W, "Price source", PRICE_HELP),
      ddRow("Notable:", panel.noteDD, LEFT_LBL_W, "Notable quality",
        "The {notable} counter and item highlighting count items at this quality and above. Colors match "
        .. 'in-game item quality, so you can eyeball "blues and up" at a glance.'),
    },
    { section = "Session & reload",
      chk("Reload before new session", function() return HaulDB.reloadBeforeNewSession end,
        function(v) HaulDB.reloadBeforeNewSession = v end, "Reload before new session",
        "Reload the UI right before a new session starts (the New button, and automatic new sessions on a map "
        .. "change), flushing your data to disk at each session boundary. Optional; off by default. "
        .. "(Your run is always banked to Saved Sessions on New regardless — this only controls the reload.)", "cbReset"),
      chk("New session on instances  (set aside + resume)",
        function() return HaulDB.newSessionTriggers and HaulDB.newSessionTriggers.instance end,
        function(v) HaulDB.newSessionTriggers = HaulDB.newSessionTriggers or {}; HaulDB.newSessionTriggers.instance = v end,
        "New session on instances",
        "Zoning into a dungeon/raid/delve sets the current run aside (paused) and tracks the instance fresh; leaving banks the instance run and resumes your previous session right where it left off.", "cbInstance"),
      chk("Also treat world quests / scenarios as instances",
        function() return HaulDB.newSessionTriggers and HaulDB.newSessionTriggers.scenario end,
        function(v) HaulDB.newSessionTriggers = HaulDB.newSessionTriggers or {}; HaulDB.newSessionTriggers.scenario = v end,
        "Treat scenarios as instances",
        "Scenario-system content (world quests, open-world events, delves) runs on the SAME system dungeons do, so WoW flags it as an instance. OFF by default: 9/10 a 'scenario' is an open-world area you fly THROUGH on a farm run — you don't want it setting your session aside. Turn ON only to track scenarios/delves as their own run.", "cbScenario", 1),
      chk("New session on map change",
        function() return HaulDB.newSessionTriggers and HaulDB.newSessionTriggers.map end,
        function(v) HaulDB.newSessionTriggers = HaulDB.newSessionTriggers or {}; HaulDB.newSessionTriggers.map = v end,
        "New session on map change",
        "Start a fresh run when your location changes. The two rows below set HOW (ask first, or switch automatically) and at WHAT level a move counts.", "cbMap"),
      chk("Ask first  (off = switch automatically)", function() return HaulDB.newSessionPrompt end,
        function(v) HaulDB.newSessionPrompt = v end, "Ask first",
        "On a qualifying map change, ASK before starting the new session (New session / Keep current). Off = it just switches automatically.", "cbPrompt", 1),
      { dir = "row", align = "center", gap = 8, pad = { l = 16 },
        { note = { text = "at level:", color = "text", onBuild = labelTip("Map level", mlTip) } },
        { frame = panel.mapLevelDD } },
      { dir = "row", align = "center", gap = 8,
        chk("Auto reload every:", function() return HaulDB.flushEnabled end,
          function(v) HaulDB.flushEnabled = v; ns.StartFlush() end, "Auto reload",
          "Reload the UI automatically on the interval to the right, so your session data is written to disk regularly. Off = data is written only when you Save / Flush.", "cbFlush"),
        { frame = panel.flushBox } },
    },
    { section = "Looting",
      chk("Ultra fast loot  (grab everything instantly, no loot window)", function() return HaulDB.fastLoot end,
        function(v) HaulDB.fastLoot = v and true or false; if ns.ApplyFastLoot then ns.ApplyFastLoot() end end,
        "Ultra fast loot",
        "Replaces the game's built-in auto-loot with a fast, silent looter: everything is grabbed off a corpse/node "
        .. "with no loot window popping up, and it keeps up even at low framerate (the built-in auto-loot can drop "
        .. "items when your FPS dips). The normal loot window still appears on its own when it needs you \226\128\148 "
        .. "a locked slot, an item above your group's loot-quality threshold, a bind-on-pickup confirm, or full bags "
        .. "\226\128\148 so nothing is ever silently lost.", "cbFastLoot"),
      -- (Full kill tracking moved to the dev-only Debug tab.)
    },
  }

  local rightCol = { basis = 246, minWidth = 246,   -- label 78 + gap 8 + dropdown 150 + section indent 10
    { section = "Item display",
      ddRow("Loot view:", panel.viewDD, RIGHT_LBL_W, "Loot view",
        "Loot category — Collection = each item once with a running count (x45). List = every loot event on its own line, newest first."),
      ddRow("Rep view:", panel.repViewDD, RIGHT_LBL_W, "Reputation view",
        "Reputation category — Collection = per-faction session totals. List = the chronological +rep stream, newest first (see which sources pay)."),
      ddRow("Curr view:", panel.currencyViewDD, RIGHT_LBL_W, "Currency view",
        "Currency category — Collection = per-currency session totals (gains only). List = the chronological +currency stream, newest first. Spending is logged but not shown here."),
      ddRow("Skills view:", panel.profViewDD, RIGHT_LBL_W, "Skills view",
        "Skills category — Collection = per-profession skill-ups gained this session. List = the chronological skill-up stream, newest first."),
      ddRow("XP view:", panel.xpViewDD, RIGHT_LBL_W, "XP view",
        "XP category — Collection = total experience this session + a per-zone discovery breakdown. List = the chronological zone-discovery stream, newest first."),
      ddRow("Kills view:", panel.killViewDD, RIGHT_LBL_W, "Kills view",
        "Kills category — Collection = per-mob kill counts this session. List = the chronological kill stream, newest first."),
      ddRow("Sort:", panel.sortDD, RIGHT_LBL_W, "Sort (Collection)",
        "How the Collection view orders items: by Value (highest first), Name (alphabetical), Count (most copies first), or Time (order first looted). List view is always newest-first."),
      ddRow("Value:", panel.valueFmtDD, RIGHT_LBL_W, "Value format",
        "How EVERY money value shows across Haul: Short = just the largest unit (3g — compact, rounds off silver/copper), Long = the full amount (3g 47s 21c). Applies to the window, buckets, and header tokens."),
    },
    { section = "Grouping",
      ddRow("Soulbound:", panel.boundDD, RIGHT_LBL_W, "Bind-on-pickup items",
        "Soulbound (bind-on-pickup) loot can't be auctioned, so it's valued at vendor "
        .. "price. In Collection view it's a collapsible \"Soulbound\" group: Expanded (open), "
        .. "Collapsed (closed, click to expand), or Hidden. Sets the group's default — it remembers your clicks."),
      ddRow("Grays:", panel.graysDD, RIGHT_LBL_W, "Gray items",
        "Gray (Poor) loot, always valued at vendor price. In Collection view it's a "
        .. "collapsible \"Vendor trash\" group: Expanded (open), Collapsed (closed, click to expand), "
        .. "or Hidden (dropped from the list and totals). Sets the group's default — it remembers your clicks."),
      ddRow("Excluded:", panel.excludedDD, RIGHT_LBL_W, "Excluded items",
        "Items you've excluded from your haul (click an item to toggle). They never count "
        .. "toward your total either way. In Collection view it's a collapsible \"Excluded\" group: "
        .. "Expanded (open), Collapsed (closed, click to expand), or Hidden (dropped from the list and the "
        .. "gross total too). Sets the group's default — it remembers your clicks."),
      ddRow("Mailbox:", panel.mailDD, RIGHT_LBL_W, "Mailbox items",
        "Items pulled from the mailbox aren't farm loot, so they never count toward your haul "
        .. "total. In Collection view they're a collapsible \"Mailbox\" group (with mail gold nested inside): "
        .. "Expanded (open), Collapsed (closed, click to expand), or Hidden (dropped from the list). Click any "
        .. "mail item to include it in your haul one-off. Sets the group's default — it remembers your clicks."),
    },
  }


  local genRoot, refs = Theme.Layout(pGeneral,
    { dir = "row", align = "start", gap = 12, pad = { t = 6, r = 8, b = 8, l = 8 }, leftCol, rightCol },
    { setParentHeight = false })
  -- General is the widest tab, so it drives the window's resize floor: derive the min-WIDTH from the tree
  -- (MinWidth() = 320 + gap 12 + 246 + pad 16 = 594) + the window<->pGeneral horizontal chrome (~46, so the
  -- right column clears the edge with margin), MAX'd with the 600 min-height. Replaces the removed
  -- gcols:ApplyMinSize + the hardcoded 624 guess, and widens the window if it's currently narrower.
  genRoot:ApplyMinSize(panel, { chromeW = 46, chromeH = 100, floorH = 600 })

  panel.cbReset = refs.cbReset   -- "Reload before new session" toggle
  panel.cbInstance, panel.cbScenario, panel.cbMap, panel.cbPrompt = refs.cbInstance, refs.cbScenario, refs.cbMap, refs.cbPrompt
  panel.cbFlush, panel.cbFastLoot = refs.cbFlush, refs.cbFastLoot   -- cbCLK (kill tracking) moved to the Debug tab
  -- ===================== HEADER: template + display styling — box tree =====================
  local TEMPLATE_BOX_H = 108
  local function MakeFixedTemplateEditor(parent, height, onChanged)
    local box, eb = Theme.MultilineEditBox(parent, { onChanged = onChanged })
    box:SetHeight(height)
    return box, eb
  end
  -- a 1px section divider hosted as a frame leaf (stretches to the box width)
  local function hdivider()
    local f = CreateFrame("Frame", nil, pHeader); f:SetHeight(1)
    local t = f:CreateTexture(nil, "ARTWORK"); t:SetAllPoints(); t:SetColorTexture(1, 1, 1, 0.10)
    return { frame = f }
  end
  -- a hosted display slider (custom Init/silentSet kept for panel.Refresh) + its label as a basis note row
  local SLIDER_LBL_W = 80
  local function sliderRow(name, label, minv, maxv, step, get, set, fmt)
    local function show(v) return fmt and fmt(v) or tostring(v) end
    local s = CreateFrame("Frame", name, pHeader, "MinimalSliderWithSteppersTemplate")
    s:SetHeight(24); s:SetWidth(180)
    local val = s:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    val:SetPoint("LEFT", s, "RIGHT", 8, 0); Theme.Font(val, "textDim")
    local steps = math.max(1, math.floor((maxv - minv) / step + 0.5))
    local suppress
    pcall(function()
      s:Init(get(), minv, maxv, steps, {})
      s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, v)
        if suppress then return end
        set(v); val:SetText(show(v)); if ns.ApplyHeaderStyle then ns.ApplyHeaderStyle() end
      end, s)
    end)
    s.silentSet = function(v) suppress = true; pcall(function() s:Init(v, minv, maxv, steps, {}) end); suppress = false; val:SetText(show(v)) end
    val:SetText(show(get()))
    Theme.SkinSlider(s)
    return s, { dir = "row", align = "center", gap = 8,
      { note = { text = label, color = "textDim" }, basis = SLIDER_LBL_W }, { frame = s } }
  end

  -- header template editor (host) + Data feeds button (host)
  local hsf, heb = MakeFixedTemplateEditor(pHeader, TEMPLATE_BOX_H, function(self, userInput)
    if userInput then HaulDB.headerTemplate = self:GetText(); if ns.RefreshUI then ns.RefreshUI() end end
  end)
  panel.headerBox = heb
  local feedsBtn = Theme.MakeButton(pHeader, 96, "Data feeds", function()
    local FB = LibStub and LibStub("GECFeedBrowser-1.0", true)
    if not (FB and ns.templateRenderer) then return end
    if not panel._feedBrowser then
      HaulDB.feedsWin = HaulDB.feedsWin or {}
      panel._feedBrowser = FB.New({
        name = "HaulFeedsBrowser", title = "Data feeds", theme = Theme,
        renderer = ns.templateRenderer, savedKey = HaulDB.feedsWin, oursOnly = true,
      })
    end
    panel._feedBrowser:Toggle(panel.headerBox)   -- insert at the HEADER template cursor
  end)
  local sampleText = "|cff808080Sample:|r   |cffeda55f12:34|r   "
    .. ns.MoneyShort(12500000) .. "   " .. ns.MoneyShort(34000000) .. "/hr"

  -- detail template editor (host)
  local dsf, deb = MakeFixedTemplateEditor(pHeader, TEMPLATE_BOX_H, function(self, userInput)
    if userInput then HaulDB.detailTemplate = self:GetText(); if ns.RefreshUI then ns.RefreshUI() end end
  end)
  panel.detailBox = deb

  -- text color box (host) — aligns to the shared slider label column (no GetLeft track hack)
  panel.colorBox = CreateFrame("EditBox", nil, pHeader, "InputBoxTemplate")
  panel.colorBox:SetSize(80, 20); panel.colorBox:SetAutoFocus(false); Theme.EditBox(panel.colorBox)
  panel.colorBox:SetScript("OnEditFocusLost", function(self)
    local hex = ns.ColorToHex and ns.ColorToHex(self:GetText())
    if hex then HaulDB.headerColor = hex end
    if ns.ApplyHeaderStyle then ns.ApplyHeaderStyle() end
    panel.Refresh()
  end)
  panel.colorBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  panel.colorBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  -- the display sliders (custom silentSet kept; panel.*Slider set for panel.Refresh)
  local scaleRow, fontRow, padRow, spaceRow, bgRow
  panel.scaleSlider, scaleRow = sliderRow("HaulDispScale", "Scale", 0.3, 3, 0.05,
    function() return HaulDB.scale or 1 end, function(v) HaulDB.scale = v end, function(v) return string.format("%.2f", v) end)
  panel.fontSlider, fontRow = sliderRow("HaulDispFont", "Font size", 6, 40, 1,
    function() return HaulDB.headerFontSize or 12 end, function(v) HaulDB.headerFontSize = math.floor(v + 0.5) end)
  panel.padSlider, padRow = sliderRow("HaulDispPad", "Padding", 0, 30, 1,
    function() return HaulDB.headerPad or 4 end, function(v) HaulDB.headerPad = math.floor(v + 0.5) end)
  panel.spaceSlider, spaceRow = sliderRow("HaulDispSpace", "Line spacing", 0, 20, 1,
    function() return HaulDB.headerSpacing or 2 end, function(v) HaulDB.headerSpacing = math.floor(v + 0.5) end)
  panel.bgSlider, bgRow = sliderRow("HaulDispBg", "Background", 0, 1, 0.05,
    function() return HaulDB.bgAlpha or 0.88 end, function(v) HaulDB.bgAlpha = v end,
    function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end)

  -- a proper SECTION TITLE (accent + GameFontNormal, matching every other section header) that also
  -- carries the whole-title help hover-zone. Notes default to GameFontHighlightSmall, so bump the font.
  local function hdrTitle(title, body)
    return function(fs) fs:SetFontObject("GameFontNormal"); labelTip(title, body)(fs) end
  end

  local _, hrefs = Theme.Layout(pHeader, {
    gap = "row", pad = { t = 8, r = 8, b = 12, l = 6 },
    -- Header layout: title + right-pinned Data feeds button
    { dir = "row", justify = "between", align = "center",
      { note = { text = Theme.Accent("Header layout"), color = "text", onBuild = hdrTitle("Header layout", HEADER_HELP) } },
      { frame = feedsBtn } },
    hdivider(),
    { frame = hsf },
    { note = { text = sampleText, color = "textMuted" } },
    -- Detail layout: title + right-pinned Show-in-window check
    { dir = "row", justify = "between", align = "center",
      { note = { text = Theme.Accent("Detail layout"), color = "text", onBuild = hdrTitle("Detail layout",
          "The body/stats area under the header, rendered through the same {token} engine. Same tokens as the header — e.g. {haul.full}, {zone}, {items.notable.label}.") } },
      { id = "showDetail", check = { label = "Show in window",
          get = function() return HaulDB.window and HaulDB.window.showDetail ~= false end,
          set = function(v) HaulDB.window.showDetail = v and true or false; if ns.RefreshUI then ns.RefreshUI() end end,
          help = tipFn("Show detail panel", "When off, the detail/stats block is hidden and the window compacts to just the header bar + loot list. The list toggle and last-item line stay. Put whatever you need in the Header layout instead.") } } },
    hdivider(),
    { frame = dsf },
    -- Display: sliders + text color, all sharing the slider label basis column
    { note = { text = Theme.Accent("Display"), color = "text", onBuild = hdrTitle("Display",
        "Style this header. Drag the sliders for size/spacing; they apply live. Text color takes a hex code (ffffff) or a name (blue, green, gold, white, red, purple, orange, teal, gray).") } },
    hdivider(),
    scaleRow, fontRow, padRow, spaceRow, bgRow,
    { dir = "row", align = "center", gap = 8,
      { note = { text = "Text color:", color = "textDim", onBuild = labelTip("Text color",
          "Default header text color — a name (white, blue, green, gold, red, purple, orange, teal, gray) or a hex code like ffffff.") }, basis = SLIDER_LBL_W },
      { frame = panel.colorBox } },
  }, { setParentHeight = true, settle = rawHeader })
  panel.showDetailCb = hrefs.showDetail

  -- ===================== DATA: sessions + JSON import/export ====================
  local dtip = pData:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  dtip:SetPoint("TOPLEFT", 0, -14); dtip:SetWidth(560); dtip:SetJustifyH("LEFT")
  dtip:SetText("Data is written to disk on " .. Theme.Accent("Save") .. " / Flush — do that at the end of a run.")
  Theme.Font(dtip, "textDim")

  -- Saved Sessions — INLINE collapsible section (was a floating popup). The toggle
  -- reveals the embedded session list (built by ns.EmbedSessions into sessHost).
  local sessBtn = CreateFrame("Button", nil, pData, "UIPanelButtonTemplate")   -- collapsed; click to reveal the list
  sessBtn:SetPoint("TOPLEFT", 0, -40); sessBtn:SetSize(150, 22)
  Theme.Button(sessBtn)
  -- dress the toggle as an accordion HEADER (+/- glyph, left-aligned label) so it reads as an
  -- expandable section, not an action button (the +/- state is set in applyAccordion).
  sessBtn.glyph = sessBtn:CreateTexture(nil, "OVERLAY"); sessBtn.glyph:SetSize(14, 14); sessBtn.glyph:SetPoint("LEFT", 5, 0)
  do local fs = sessBtn:GetFontString(); if fs then fs:ClearAllPoints(); fs:SetPoint("LEFT", sessBtn.glyph, "RIGHT", 5, 0); fs:SetJustifyH("LEFT") end end
  AttachTip(sessBtn, "Saved sessions",
    "View past saved sessions and Resume one — it reloads the data and keeps the "
    .. "clock and totals rolling from where it left off. Sessions are account-wide; "
    .. "each is tagged with the character that ran it.")
  local sessHost = CreateFrame("Frame", nil, pData)
  sessHost:SetFrameLevel(pData:GetFrameLevel() + 2)   -- accordion sets its anchors (fills available height)
  if ns.EmbedSessions then ns.EmbedSessions(sessHost) end

  -- Settings (JSON) — INLINE (was a floating popup): copy the JSON out, edit, paste back to import.
  local jBtn = CreateFrame("Button", nil, pData, "UIPanelButtonTemplate")   -- collapsed; click to reveal the editor
  jBtn:SetSize(150, 22)
  Theme.Button(jBtn)
  jBtn.glyph = jBtn:CreateTexture(nil, "OVERLAY"); jBtn.glyph:SetSize(14, 14); jBtn.glyph:SetPoint("LEFT", 5, 0)
  do local fs = jBtn:GetFontString(); if fs then fs:ClearAllPoints(); fs:SetPoint("LEFT", jBtn.glyph, "RIGHT", 5, 0); fs:SetJustifyH("LEFT") end end
  local jbox = CreateFrame("Frame", nil, pData, "BackdropTemplate")
  jbox:SetPoint("BOTTOMRIGHT", pData, "BOTTOMRIGHT", -2, 40)
  jbox:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
  jbox:SetBackdropColor(unpack(Theme.colors.contentBg)); jbox:SetBackdropBorderColor(unpack(Theme.colors.contentBorder))
  local jsf = CreateFrame("ScrollFrame", "HaulPorterInlineScroll", jbox, "InputScrollFrameTemplate")
  jsf:SetPoint("TOPLEFT", 6, -6); jsf:SetPoint("BOTTOMRIGHT", -10, 6)
  local jeb = jsf.EditBox
  jeb:SetFontObject("ChatFontNormal"); jeb:SetAutoFocus(false); jeb:SetMaxLetters(0)
  jeb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  if jsf.CharCount then jsf.CharCount:Hide() end
  if ns.ExportSettings then jeb:SetText(ns.ExportSettings()) end
  local jexp = CreateFrame("Button", nil, pData, "UIPanelButtonTemplate")
  jexp:SetSize(110, 22); jexp:SetPoint("TOPLEFT", jbox, "BOTTOMLEFT", 0, -8); jexp:SetText("Export (copy)")
  Theme.Button(jexp)
  jexp:SetScript("OnClick", function()
    if ns.ExportSettings then jeb:SetText(ns.ExportSettings()); jeb:HighlightText(); jeb:SetFocus() end
  end)
  local jimp = CreateFrame("Button", nil, pData, "UIPanelButtonTemplate")
  jimp:SetSize(110, 22); jimp:SetPoint("LEFT", jexp, "RIGHT", 8, 0); jimp:SetText("Import (paste)")
  Theme.Button(jimp)
  jimp:SetScript("OnClick", function() if ns.ImportSettings then ns.ImportSettings(jeb:GetText()) end end)
  local jhint = pData:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  jhint:SetPoint("LEFT", jimp, "RIGHT", 10, 0); jhint:SetText("Ctrl+A, Ctrl+C to copy  ·  Ctrl+V to paste")
  Theme.Font(jhint, "textMuted")

  -- ACCORDION: exactly one of {Saved Sessions, Settings JSON} is open and FILLS the available
  -- height (stretches with the window); the other collapses to a header. Opening one closes the other.
  -- clicking a header opens that section (and closes the other); clicking the OPEN one closes it (both
  -- collapse to headers). The open section FILLS the available height. 3-state: "sess" | "json" | nil.
  local openSection = "sess"
  local H_PLUS, H_MINUS = "Interface\\Buttons\\UI-PlusButton-Up", "Interface\\Buttons\\UI-MinusButton-Up"
  local function applyAccordion()
    sessBtn:ClearAllPoints(); sessBtn:SetPoint("TOPLEFT", 0, -40); sessBtn:SetPoint("RIGHT", pData, "RIGHT", -2, 0)
    sessBtn:SetText("Saved Sessions"); sessBtn.glyph:SetTexture(openSection == "sess" and H_MINUS or H_PLUS)
    jBtn:SetText("Settings (JSON)"); jBtn.glyph:SetTexture(openSection == "json" and H_MINUS or H_PLUS)
    sessHost:Hide(); jbox:Hide(); jexp:Hide(); jimp:Hide(); jhint:Hide()   -- hide all; the open branch re-shows
    if openSection == "sess" then
      -- sessions fills from under its header down to the JSON header, which is pinned to the bottom
      jBtn:ClearAllPoints(); jBtn:SetPoint("BOTTOMLEFT", pData, "BOTTOMLEFT", 0, 12); jBtn:SetPoint("RIGHT", pData, "RIGHT", -2, 0)
      sessHost:ClearAllPoints()
      sessHost:SetPoint("TOPLEFT", sessBtn, "BOTTOMLEFT", 0, -8)
      sessHost:SetPoint("RIGHT", pData, "RIGHT", -2, 0)
      sessHost:SetPoint("BOTTOM", jBtn, "TOP", 0, 8)
      sessHost:Show()
      if ns.RefreshSessions then ns.RefreshSessions() end
    elseif openSection == "json" then
      -- JSON header tucks under the sessions header; the JSON box fills down to the export/import row
      jBtn:ClearAllPoints(); jBtn:SetPoint("TOPLEFT", sessBtn, "BOTTOMLEFT", 0, -8); jBtn:SetPoint("RIGHT", pData, "RIGHT", -2, 0)
      jbox:ClearAllPoints()
      jbox:SetPoint("TOPLEFT", jBtn, "BOTTOMLEFT", 0, -8)
      jbox:SetPoint("BOTTOMRIGHT", pData, "BOTTOMRIGHT", -2, 40)
      jbox:Show(); jexp:Show(); jimp:Show(); jhint:Show()
      if ns.ExportSettings then jeb:SetText(ns.ExportSettings()) end
    else
      -- both collapsed: just the two headers stacked at the top
      jBtn:ClearAllPoints(); jBtn:SetPoint("TOPLEFT", sessBtn, "BOTTOMLEFT", 0, -8); jBtn:SetPoint("RIGHT", pData, "RIGHT", -2, 0)
    end
  end
  -- explicit if/else (NOT `cond and nil or X` — that idiom can't yield nil, so it never closed)
  sessBtn:SetScript("OnClick", function()
    if openSection == "sess" then openSection = nil else openSection = "sess" end; applyAccordion()
  end)
  jBtn:SetScript("OnClick", function()
    if openSection == "json" then openSection = nil else openSection = "json" end; applyAccordion()
  end)
  applyAccordion()   -- sessions open by default, filling the space
  -- expose for OpenToSessions: open the window to Data with sessions revealed
  panel.ExpandSessions = function() openSection = "sess"; applyAccordion() end
  -- repopulate the open section each time the Data tab is shown (history may have changed)
  pData:HookScript("OnShow", function() if openSection == "sess" and ns.RefreshSessions then ns.RefreshSessions() end end)


  function panel.Refresh()
    -- the dropdowns (price/notable/view/grays/soulbound) show their own text live
    panel.flushBox:SetText(ns.Duration.Format(HaulDB.flushSeconds))
    panel.headerBox:SetText(HaulDB.headerTemplate or "")
    if panel.detailBox then panel.detailBox:SetText(HaulDB.detailTemplate or "") end
    if panel.showDetailCb then panel.showDetailCb:SetChecked(HaulDB.window and HaulDB.window.showDetail ~= false) end
    if panel.cbReset then panel.cbReset:SetChecked(HaulDB.reloadBeforeNewSession) end
    panel.cbFlush:SetChecked(HaulDB.flushEnabled)
    if panel.cbFastLoot then panel.cbFastLoot:SetChecked(HaulDB.fastLoot and true or false) end
    if panel.cbInstance then panel.cbInstance:SetChecked(HaulDB.newSessionTriggers and HaulDB.newSessionTriggers.instance) end
    if panel.cbScenario then panel.cbScenario:SetChecked(HaulDB.newSessionTriggers and HaulDB.newSessionTriggers.scenario) end
    if panel.cbMap then panel.cbMap:SetChecked(HaulDB.newSessionTriggers and HaulDB.newSessionTriggers.map) end
    if panel.cbPrompt then panel.cbPrompt:SetChecked(HaulDB.newSessionPrompt) end
    panel.scaleSlider.silentSet(HaulDB.scale or 1)
    panel.fontSlider.silentSet(HaulDB.headerFontSize or 12)
    panel.padSlider.silentSet(HaulDB.headerPad or 4)
    panel.spaceSlider.silentSet(HaulDB.headerSpacing or 2)
    panel.bgSlider.silentSet(HaulDB.bgAlpha or 0.88)
    panel.colorBox:SetText(ns.ColorName and ns.ColorName(HaulDB.headerColor)
      or (HaulDB.headerColor or "white"))
    -- (the color box now aligns to the shared slider label basis column via the box tree — the old
    --  GetLeft track-measure re-anchor is gone.)
  end

  -- ===================== KEYBINDS: assign keys to Haul actions ==================
  -- (no explainer — the "Set key" rows are self-evident)
  local ky = -12
  for _, e in ipairs(ns.KEYBINDS or {}) do
    MakeKeybindRow(pKeybinds, ky, e); ky = ky - 28
  end


  -- ===================== LOG (ships): raw event-log viewer ======================
  local lHead = pLog:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  lHead:SetPoint("TOPLEFT", 0, -10); lHead:SetText(Theme.Accent("Haul log"))
  Theme.Font(lHead, "text")
  -- "show" = DISPLAY cap only (how many recent lines to RENDER); the saved log is NOT trimmed by this field
  -- (mirrors SBF). The TOTAL saved-entry count sits to its right as "N logged".
  local logCountLbl = pLog:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  logCountLbl:SetPoint("TOPRIGHT", -14, -8); logCountLbl:SetJustifyH("RIGHT"); Theme.Font(logCountLbl, "textDim")
  logCountLbl:SetText(#ns.LogStream() .. " logged")
  local lMaxEb = CreateFrame("EditBox", nil, pLog, "InputBoxTemplate")
  lMaxEb:SetSize(64, 18); lMaxEb:SetAutoFocus(false); lMaxEb:SetNumeric(true); Theme.EditBox(lMaxEb)
  lMaxEb:SetPoint("RIGHT", logCountLbl, "LEFT", -8, 0); lMaxEb:SetText(tostring(HaulDB.logShow or 150))
  local lMaxLbl = pLog:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  lMaxLbl:SetPoint("RIGHT", lMaxEb, "LEFT", -4, 0); lMaxLbl:SetText("show"); Theme.Font(lMaxLbl, "textDim")
  AttachTip(lMaxEb, "Lines to show", "How many of the most recent log lines to DISPLAY. The full log is always kept — this never trims saved data.")
  sectionLine(pLog, 0, -30)
  local GSV = LibStub("GECStoreView-1.0")
  -- collapsed schema (2026-07-09): 9 primary kinds + markers. Attribution rides on `ls`, not separate kinds.
  local HAUL_KINDS = {
    loot     = { label = "loot",   color = "ffffff" },
    coin     = { label = "coin",   color = "ffd100" },
    mail     = { label = "mail $", color = "ffd100" },
    vendor   = { label = "vendor", color = "ff9933" },
    rep      = { label = "rep",    color = "66ccff" },
    currency = { label = "curr",   color = "66ddff" },
    skill    = { label = "skill",  color = "d0a0ff" },
    xp       = { label = "xp",     color = "1eff00" },
    kill     = { label = "kill",   color = "ff8080" },
    include  = { label = "incl",   color = "808080" },
    exclude  = { label = "excl",   color = "a0a0a0" },
    fold     = { label = "fold",   color = "c080ff" },
    start    = { label = "start",  color = "45c4a0" },
    stop     = { label = "stop",   color = "ff6060" },
    pause    = { label = "pause",  color = "ffaa44" },
    resume   = { label = "resume", color = "45c4a0" },
  }
  -- source-type label for the `src` attribution descriptor (shown inline on loot/coin/xp rows).
  local LS_LABEL = { fish = "fish", kill = "kill", pickpocket = "pickpocket", herb = "herb", mining = "mining",
    gather = "gather", chest = "chest", container = "container", quest = "quest", disc = "discovery", other = "other" }
  local function lsTag(e) return (e.src and e.src.t and LS_LABEL[e.src.t]) and ("  |cff808080<" .. LS_LABEL[e.src.t] .. ">|r") or "" end
  local function fromTag(e) return e.from and ("  |cff808080(" .. e.from .. ")|r") or "" end
  local function money(e) return (ns.Money and ns.Money(e.amount or 0)) or tostring(e.amount) end
  local function haulDetail(e)
    local sid = "|cff606060[s" .. tostring(e.sid or "-") .. "]|r  "
    if e.k == "loot"  then return sid .. tostring((e.link and GSV.ColorItemLink(e.link)) or e.id or "?") .. "  x" .. tostring(e.count or 1) .. fromTag(e) .. lsTag(e) end
    if e.k == "coin"  then return sid .. money(e) .. fromTag(e) .. lsTag(e) end
    if e.k == "mail"  then return sid .. (e.label or "mail gold") .. "  " .. money(e) end
    if e.k == "vendor" then return sid .. tostring(e.vt or "vendor") .. "  " .. money(e) end
    if e.k == "rep"   then return sid .. tostring(e.f or "?") .. ("  %+d"):format(e.amount or 0) end
    if e.k == "currency" then
      local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(e.cid or e.id)
      return sid .. ((info and info.name) or ("currency " .. tostring(e.cid or e.id or "?"))) .. ("  %+d"):format(e.amount or 0)
    end
    if e.k == "skill" then
      local name = e.name or ("skill " .. tostring(e.pid or e.id or "?"))
      return sid .. name .. ("  +%d"):format(e.amount or 0) .. (e.lvl and ("  |cff808080-> " .. e.lvl .. "|r") or "")
    end
    if e.k == "xp" then
      -- total (no src) or a labeled subset (src.t=kill/gather/disc/quest/other, with its name)
      local who = e.src and (e.src.name or e.src.mob or e.src.node or e.src.zone or e.src.title)
      return sid .. ("+%d xp"):format(e.amount or 0) .. lsTag(e) .. (who and ("  |cff808080" .. tostring(who) .. "|r") or "")
    end
    if e.k == "kill" then return sid .. "killed " .. tostring(e.name or e.id or "?") end
    if e.k == "exclude" or e.k == "include" then
      -- exclusion toggle on the MARKERS stream (ns.LogExclude): `k` IS the direction — "exclude" = now
      -- out of the gold count, "include" = back in — and `id` is the item. (Old code read e.on/e.ref,
      -- which these markers never carry, so it showed "+re-included item ?" / "-excluded nil".)
      local itemId = e.id or e.ref
      local link = itemId and select(2, GetItemInfo(itemId))
      local what = (link and GSV.ColorItemLink(link)) or ("item " .. tostring(itemId or "?"))
      local dir = (e.k == "exclude") and "|cffff8080-excluded|r " or "|cff80ff80+re-included|r "
      return sid .. dir .. what
    end
    if e.k == "fold" then   -- merge/resume marker: this session absorbed another (fromsid) via resume/carryover
      return sid .. "folded in |cffffd100s" .. tostring(e.fromsid or "?") .. "|r"
        .. (e.via and ("  |cff808080(" .. e.via .. ")|r") or "")
    end
    if e.k == "start"  then return sid .. "started run" .. (e.who and ("  |cff808080" .. tostring(e.who) .. "|r") or "") end
    if e.k == "stop"   then return sid .. "stopped run" end
    if e.k == "pause"  then return sid .. "paused" end
    if e.k == "resume" then return sid .. "resumed" end
    return sid .. (e.who or "")
  end
  local function haulSummary()
    local nsess = 0
    if HaulData and HaulData.sessions then for _ in pairs(HaulData.sessions) do nsess = nsess + 1 end end
    return string.format("|cffffffff%d|r entries · |cffffffff%d|r sessions · |cffffffff%d|r places",
      #ns.LogStream(), nsess,
      ((GECStoreDB and GECStoreDB.places) and #GECStoreDB.places) or 0)
  end
  -- ===== Columnar log: same standard component/columns as SBF (consistent data display across addons) =====
  -- Columns: Time · Character · Kind · Session · Item · Count · Sub-zone · Location. The character/kind/item
  -- cells carry inline |cff (class / per-kind / item-quality), which wins over the column base color below.
  local HaulStoreLib = LibStub("GECStore-1.0")
  local HAUL_LOG_COLUMNS = {
    { key = "time",    align = "LEFT",  max = 64,  color = "808080" },
    { key = "char",    align = "LEFT",  max = 96 },                            -- class-colored inline
    { key = "kind",    align = "LEFT",  max = 70 },                            -- per-kind color inline
    { key = "session", align = "LEFT",  max = 48,  color = "808080", optional = true },
    { key = "item",    align = "LEFT",  max = 260 },                           -- item link / money / rep / currency / marker
    { key = "count",   align = "RIGHT", max = 48,  color = "ffd97f", optional = true },
    { key = "subzone", align = "LEFT",  max = 130, color = "66ccff", optional = true },
    { key = "loc",     align = "RIGHT", max = 130, color = "808080", optional = true },
  }
  local function hCharCell(e)
    local info = e.ch and HaulStoreLib.CharInfo and HaulStoreLib.CharInfo(e.ch)
    if not info then return (e.ch and ("char " .. e.ch)) or "" end
    local cc = RAID_CLASS_COLORS and info.class and RAID_CLASS_COLORS[info.class]
    return "|c" .. ((cc and cc.colorStr) or "ffcccccc") .. (info.name or "?") .. "|r"
  end
  local function hKindCell(e)
    local kd = HAUL_KINDS[e.k]
    return "|cff" .. ((kd and kd.color) or "ffffff") .. ((kd and kd.label) or e.k or "") .. "|r"
  end
  local function hSubzoneCell(e)
    local casc = e.p and HaulStoreLib.PlaceInfo and HaulStoreLib.PlaceInfo(e.p)
    return (casc and #casc > 0 and casc[#casc].name) or ""
  end
  local function hLocCell(e)
    local s = (e.x and e.y) and string.format("%.1f, %.1f", e.x, e.y) or ""
    if e.h then s = (s ~= "" and (s .. " \194\183 ") or "") .. e.h .. "\194\176" end
    return s
  end
  -- DEV row tooltip: the FULL raw data set of a log event, so any two rows can be correlated by their shared
  -- metadata (e.g. a kill and its loot share src.guid / src.npcID). Dumps every field (nested tables like `src`
  -- and `loc` expanded). If the row is a loot item, the item tooltip shows first, then the data set below it.
  local function tipDump(tbl, indent)
    local keys = {}
    for kk in pairs(tbl) do keys[#keys + 1] = kk end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, kk in ipairs(keys) do
      local v = tbl[kk]
      if type(v) == "table" then
        GameTooltip:AddLine(indent .. tostring(kk) .. ":", 0.55, 0.75, 1)
        tipDump(v, indent .. "   ")
      else
        GameTooltip:AddDoubleLine(indent .. tostring(kk), tostring(v), 0.6, 0.6, 0.6, 1, 1, 1)
      end
    end
  end
  local function logRowTip(row, e)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if e.link then GameTooltip:SetHyperlink(e.link) else GameTooltip:SetText("|cff66ccffevent: " .. tostring(e.k or "?") .. "|r") end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff66ccfffull data set|r")
    tipDump(e, "")
    GameTooltip:Show()
  end
  local function haulRows(e)
    local base = {
      time = e.t and date("%H:%M:%S", e.t) or "", char = hCharCell(e), kind = hKindCell(e),
      session = e.sid and ("s" .. e.sid) or "", subzone = hSubzoneCell(e), loc = hLocCell(e), count = "",
    }
    local k = e.k
    if k == "loot" then
      base.item  = ((e.link and GSV.ColorItemLink(e.link)) or ("|cffffffff" .. tostring(e.id or "?") .. "|r")) .. lsTag(e)
      base.count = (e.count and e.count > 0) and ("x" .. e.count) or ""
    elseif k == "coin" then
      base.item = "|cffffd100" .. money(e) .. "|r" .. fromTag(e) .. lsTag(e)
    elseif k == "vendor" then
      base.item = "|cffff9933" .. tostring(e.vt or "vendor") .. "  " .. money(e) .. "|r"
    elseif k == "mail" then
      base.item = "|cffffd100" .. (e.label or "mail gold") .. "  " .. money(e) .. "|r"
    elseif k == "rep" then
      base.item = "|cff66ccff" .. tostring(e.f or "?") .. ("  %+d"):format(e.amount or 0) .. "|r"
    elseif k == "currency" then
      local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(e.cid or e.id)
      base.item = "|cff66ddff" .. ((info and info.name) or ("currency " .. tostring(e.cid or e.id or "?"))) .. ("  %+d"):format(e.amount or 0) .. "|r"
    elseif k == "skill" then
      base.item  = "|cffd0a0ff" .. (e.name or ("skill " .. tostring(e.pid or e.id or "?"))) .. ("  +%d"):format(e.amount or 0) .. "|r"
      base.count = e.lvl and tostring(e.lvl) or ""
    elseif k == "xp" then
      local who = e.src and (e.src.name or e.src.mob or e.src.node or e.src.zone or e.src.title)
      base.item  = "|cff1eff00+" .. (e.amount or 0) .. " xp|r" .. lsTag(e) .. (who and ("  |cff808080" .. tostring(who) .. "|r") or "")
    elseif k == "kill" then
      base.item  = "|cffff8080killed " .. tostring(e.name or e.id or "?") .. "|r"
    else
      -- markers (start/stop/pause/resume/fold/include/exclude): reuse the detail text minus its [sNN] prefix
      base.item = (haulDetail(e):gsub("^|cff%x+%[s.-%]|r%s*", ""))
    end
    return { { cols = base, link = (k == "loot") and e.link or nil, onEnter = function(row) logRowTip(row, e) end } }
  end
  -- Plain-text haystack for the whole-log search (mirrors haulRows' content, minus color codes): kind label +
  -- item/faction/currency/skill/xp-source/kill names + sub-zone + session. So typing an item name, a faction,
  -- a mob, a zone, or "s4" all match. The lib scans the FULL stream, so search covers the whole log.
  local function haulSearchText(e)
    local parts = {}
    local kd = HAUL_KINDS[e.k]
    parts[#parts + 1] = (kd and kd.label) or e.k or ""
    local k = e.k
    if k == "loot" then
      parts[#parts + 1] = (e.link and e.link:match("%[(.-)%]")) or ("item " .. tostring(e.id or "?"))
    elseif k == "mail" then parts[#parts + 1] = e.label or "mail gold"
    elseif k == "vendor" then parts[#parts + 1] = tostring(e.vt or "vendor")
    elseif k == "rep" then parts[#parts + 1] = tostring(e.f or "")
    elseif k == "currency" then
      local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(e.cid or e.id)
      parts[#parts + 1] = (info and info.name) or ("currency " .. tostring(e.cid or e.id or ""))
    elseif k == "skill" then
      parts[#parts + 1] = e.name or ""
      if e.lvl then parts[#parts + 1] = tostring(e.lvl) end
    elseif k == "xp" then
      if e.src then parts[#parts + 1] = tostring(e.src.name or e.src.mob or e.src.node or e.src.zone or e.src.title or e.src.t or "") end
    elseif k == "kill" then parts[#parts + 1] = tostring(e.name or e.id or "")
    elseif k == "exclude" or k == "include" then
      local itemId = e.id or e.ref
      parts[#parts + 1] = (itemId and GetItemInfo(itemId)) or ("item " .. tostring(itemId or ""))
    end
    if e.src and e.src.t then parts[#parts + 1] = e.src.t end
    local sz = hSubzoneCell(e); if sz ~= "" then parts[#parts + 1] = sz end
    if e.sid then parts[#parts + 1] = "s" .. e.sid end
    return table.concat(parts, " ")
  end
  -- NAMED opts table so the "show" field can update maxLines live (lib reads opts.maxLines each Refresh).
  -- Reconstruction / attribution DETAIL kinds: these duplicate the primary item/coin/kill/xp rows (a mob's
  -- loot, its cash, the looted flag, gathered items, and the xp SOURCE subsets). They're essential for
  -- rebuild/export but pure noise in the chronological log — e.g. one coin loot shows coin + mobcash. Default
  -- them HIDDEN so the log reads as one row per real event; the "Kind" dropdown toggles any back on (persisted).
  -- Collapsed schema: the old attribution/subset KINDS (mobloot/xpkill/…) are gone — the remaining "detail"
  -- rows are xp/coin rows that carry a `src` (an xp SUBSET paired with its total, or mob-cash coin attribution
  -- paired with the net-delta total). They can't be kind-filtered (same kind as their totals), so they're
  -- hidden at the STREAM level below. No kind is default-hidden now (all 9 are primary).
  local HAUL_LOG_DETAIL = {}
  -- for xp, the raw no-`src` TOTAL rows (a PLAYER_XP delta) are the "detail" we hide by default — the ATTRIBUTED
  -- rows (src=kill/gather/quest/disc/other) are more useful to see. Show-hidden reveals the totals. Coin is one
  -- event per gain (mob coin carries src=kill but IS the real coin), so it is never hidden.
  local function isDetailRow(e)
    return e.k == "xp" and e.src == nil
  end
  local logViewOpts = {
    -- default view = one row per real event: hide the paired xp-subset / mob-cash-attribution rows unless
    -- "Show hidden" is on (then the full stream, incl. attribution, is shown).
    stream        = function()
      -- Merge income events (streams.events) with the lifecycle MARKERS stream (streams.markers) into
      -- ONE chronological list, so the log shows session start/stop/pause/resume/fold/exclude inline with
      -- loot/coin/xp/… — both streams carry `t`. Markers are never "detail" rows, so the hidden-filter
      -- (which only trims paired xp-subset rows) skips them. Sorted oldest-first, like the raw stream.
      local ev = ns.LogStream()
      local mk = (HaulData and HaulData.streams and HaulData.streams.markers) or {}
      local out = {}
      for i = 1, #ev do
        if HaulDB.logShowHidden or not isDetailRow(ev[i]) then out[#out + 1] = ev[i] end
      end
      for i = 1, #mk do out[#out + 1] = mk[i] end
      -- STABLE sort by t: time() is 1-second resolution, so a session's `stop` and the next session's
      -- `start` (RepairIfDangling → Begin) routinely share a timestamp. The markers stream is appended in
      -- TRUE chronological order (stop before start), so same-second entries MUST keep insertion order —
      -- an unstable table.sort was scrambling them (start-before-stop, a stop before its own start). Sort
      -- an index array (stable by the `ia < ib` tiebreak) so shared stream objects aren't mutated. The
      -- RECORD + server are unaffected — Resolve reads markers in stream order, never a t-sort; display-only.
      local ord = {}
      for i = 1, #out do ord[i] = i end
      table.sort(ord, function(ia, ib)
        local ta, tb = out[ia].t or 0, out[ib].t or 0
        if ta ~= tb then return ta < tb end
        return ia < ib
      end)
      local sorted = {}
      for i = 1, #ord do sorted[i] = out[ord[i]] end
      return sorted
    end,
    kinds         = HAUL_KINDS,
    columns       = HAUL_LOG_COLUMNS,
    toRows        = haulRows,
    theme         = Theme,
    formatDetail  = haulDetail,   -- (text-mode fallback; unused while columns are set)
    summary       = haulSummary,
    maxLines      = tonumber(HaulDB.logShow) or 150,   -- DISPLAY cap only; the saved log is never trimmed by it
    searchText    = haulSearchText,                    -- enables the Log-tab search bar (whole-log)
    searchMode    = function() return HaulDB.logSearchMode or "highlight" end,
    onSearchMode  = function(m) HaulDB.logSearchMode = m end,
    hidden        = function()
      if HaulDB.logHidden == nil then                  -- first open: seed the default-hidden detail kinds
        HaulDB.logHidden = {}
        for dk in pairs(HAUL_LOG_DETAIL) do HaulDB.logHidden[dk] = true end
      end
      if HaulDB.logShowHidden then return {} end        -- "Show hidden": reveal everything (correct INITIAL seed)
      return HaulDB.logHidden
    end,
    kindVisible   = function(k)                       -- collapse the Kind dropdown to primary kinds; full list only when Show hidden
      return HaulDB.logShowHidden or not HAUL_LOG_DETAIL[k]
    end,
    onToggleKind  = function(k, isHidden)              -- persist the user's Kind-filter choices
      HaulDB.logHidden = HaulDB.logHidden or {}
      HaulDB.logHidden[k] = isHidden or nil
    end,
  }
  local logView = LibStub("GECStoreView-1.0").Create(pLog, logViewOpts)   -- dot-call: Create is a plain function
  logView.frame:SetPoint("TOPLEFT", 4, -40); logView.frame:SetPoint("BOTTOMRIGHT", -10, 8)
  local function refreshHaulLog()
    logViewOpts.maxLines = tonumber(HaulDB.logShow) or 150   -- re-read the display cap each refresh
    logView:Refresh()
    if logCountLbl then logCountLbl:SetText(#ns.LogStream() .. " logged") end   -- total saved (never trimmed)
  end
  ns.RefreshLogView = refreshHaulLog   -- exposed so /haul prune can refresh the open log + count
  -- "Show hidden" toggle: reveal the reconstruction/attribution detail kinds hidden by default (mob loot /
  -- cash, looted, gathered, the xp source subsets). Flips the live Kind filter (view._hidden.k) directly and
  -- persists in HaulDB.logShowHidden.
  local function applyShowHidden()
    local set = logView._hidden and logView._hidden.k
    if not set then return end
    for kk in pairs(set) do set[kk] = nil end                          -- clear the live kind filter
    if not HaulDB.logShowHidden then                                    -- OFF: restore the persisted hidden set
      for kk, v in pairs(HaulDB.logHidden or {}) do set[kk] = v and true or nil end
    end
    refreshHaulLog()
  end
  local lShowHidden = CreateFrame("CheckButton", nil, pLog, "UICheckButtonTemplate")
  lShowHidden:SetSize(20, 20); lShowHidden:SetPoint("LEFT", lHead, "RIGHT", 14, 0)
  lShowHidden:SetChecked(HaulDB.logShowHidden and true or false)
  local lShowHiddenLbl = pLog:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  lShowHiddenLbl:SetPoint("LEFT", lShowHidden, "RIGHT", 0, 0); lShowHiddenLbl:SetText("Show hidden"); Theme.Font(lShowHiddenLbl, "textDim")
  lShowHidden:SetScript("OnClick", function(self)
    HaulDB.logShowHidden = self:GetChecked() and true or nil
    applyShowHidden()
  end)
  AttachTip(lShowHidden, "Show hidden kinds", "Reveal the reconstruction/attribution detail rows hidden by default: mob loot, mob cash, looted, gathered, and the xp source subsets.")
  -- NOTE: no build-time applyShowHidden() call here — the initial hidden state comes from the `hidden` getter
  -- (which honors logShowHidden). A build-time logView:Refresh() before the page is shown could throw and skip
  -- the OnShow/OnUpdate wiring below, freezing the log. applyShowHidden only runs from the checkbox click.
  local function commitMax(self)
    local v = tonumber(self:GetText())
    if v and v >= 1 then HaulDB.logShow = math.floor(v) end   -- DISPLAY cap only; never prunes the saved log
    self:SetText(tostring(HaulDB.logShow or 150))
    refreshHaulLog()
  end
  lMaxEb:SetScript("OnEnterPressed", function(s) commitMax(s); s:ClearFocus() end)
  lMaxEb:SetScript("OnEditFocusLost", commitMax)
  lMaxEb:SetScript("OnEscapePressed", function(s) commitMax(s); s:ClearFocus() end)
  -- Live update: refresh on show, then poll ~1s while the page is VISIBLE (OnUpdate only fires while shown) so
  -- new events appear as they land — but only re-render when the log actually GREW, so idle/scrolling isn't
  -- disturbed and there's no cost when nothing's happening.
  pLog:SetScript("OnShow", function(self) self._logAccum = 0; self._logN = nil; refreshHaulLog() end)
  pLog:SetScript("OnUpdate", function(self, elapsed)
    self._logAccum = (self._logAccum or 0) + elapsed
    if self._logAccum < 1 then return end
    self._logAccum = 0
    local n = #((ns.LogStream and ns.LogStream()) or {})
    if n ~= self._logN then self._logN = n; refreshHaulLog() end
  end)

  -- refresh the controls each time the window is shown (HookScript: Theme.Window
  -- already hooked OnShow → Raise; don't clobber it)
  panel:HookScript("OnShow", function() if panel.Refresh then panel.Refresh() end end)

  -- open the window straight to the Data tab with the Saved Sessions section expanded
  -- (used by /haul sessions and the ShowSessions back-compat alias)
  function ns.OpenToSessions()
    if not panel:IsShown() then if panel.Refresh then panel.Refresh() end; panel:Show() end
    ShowTab("data")
    if panel.ExpandSessions then panel.ExpandSessions() end
  end

  ShowTab("general")
  panel:Hide()   -- built hidden; shown ONLY on demand via ToggleOptions (starts closed every login/reload)
end

-- Build the standalone window (hidden). Called once at PLAYER_LOGIN (HaulDB ready)
-- and lazily by ToggleOptions. No Blizzard Settings registration — the window is
-- fully standalone so it floats over the game and never traps clicks/casts.
function ns.InitOptions()
  if not panel then Build() end
end

-- The Options button OPENS the window (twirls it down): not shown → show expanded; shown-but-COLLAPSED →
-- expand it (open the accordion) instead of hiding; only fully-open → hide. So a collapsed window opens on
-- click rather than needing you to click the title bar, and a hidden one comes up expanded.
function ns.ToggleOptions()
  ns.InitOptions()
  local collapsed = HaulDB.optionsWin and HaulDB.optionsWin.collapsed
  if not panel:IsShown() then
    if panel.Refresh then panel.Refresh() end
    panel:Show()
    if collapsed and panel.SetCollapsed then panel:SetCollapsed(false) end   -- come up expanded, never collapsed
    if panel.ShowTab then panel.ShowTab(panel.currentTab or "general") end
  elseif collapsed and panel.SetCollapsed then
    panel:SetCollapsed(false)   -- shown but collapsed → twirl it open (don't hide)
  else
    panel:Hide()
  end
end
