-- GECFeedBrowser-1.0 — a shared, parameterized "Data feeds" browser. Lists the GECTemplate built-in
-- token catalog, registered GECData feeds (+ their tokens), and GECBridge adapter namespaces (+ their
-- catalog), as a collapsible accordion. LEFT-click a header expands it; RIGHT-click a header or token
-- INSERTS the token ({slug} / {slug.token} / a bridge path) at a target editbox's cursor, or — with no
-- target — into an always-populated copy field to Ctrl-C. Lifted verbatim from Gadgets/Feeds.lua and
-- parameterized so any addon can host its own browser bound to its theme, renderer, SV, and subscription.
--
--   local FB = LibStub("GECFeedBrowser-1.0")
--   local browser = FB.New({
--     theme    = <a GECTheme ForAddon handle>,   -- Theme.Window/Font/EditBox/ContentPanel/AttachScrollBar
--     renderer = <a GECTemplate renderer>,        -- for live token preview values (tokenValue)
--     savedKey = <a table in the addon's SV>,     -- window position persistence (Theme.Window savedKey)
--     oursOnly = <bool>,                          -- subscription: true → only _gec GECData feeds
--     title    = "Data feeds",                    -- window title (default "Data feeds")
--     name     = "MyFeedsBrowser",                -- UNIQUE global frame name (for UISpecialFrames / Esc)
--   })
--   browser:Open(targetEditbox)   browser:Toggle(targetEditbox)   -- nil target → copy-field path
local MAJOR, MINOR = "GECFeedBrowser-1.0", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

local Data = LibStub and LibStub:GetLibrary("GECData-1.0", true)
local Tpl  = LibStub and LibStub:GetLibrary("GECTemplate-1.0", true)

local FEED_H, TOKEN_H, INDENT, MAX_PREVIEW = 30, 18, 16, 48
local nameSeq = 0   -- fallback unique-name counter when opts.name is omitted

-- truncate + strip color/link escapes for a one-line preview of a feed's live text.
local function clean(t)
  t = tostring(t or "")
  t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
  t = t:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #t > MAX_PREVIEW then t = t:sub(1, MAX_PREVIEW) .. "…" end
  return t
end

-- Render a token to its CURRENT value for the browser preview (cleaned/plain). Returns "" if it
-- doesn't resolve (e.g. a placeholder like {currency(id)} that renders back to the literal token).
local function tokenValue(renderer, tokenStr)
  if not (renderer and tokenStr) then return "" end
  local ok, rendered = pcall(renderer.Render, renderer, tokenStr)
  if not ok or type(rendered) ~= "string" or rendered == tokenStr then return "" end
  return clean(rendered)
end

-- Insert a token at the target editbox cursor, or (no target) into the copyable field.
local function Insert(self, token)
  local f = self._frame
  if not f then return end
  if f.copyEB then                 -- ALWAYS populate the copy field, so it's never empty ("just in case")
    f.copyEB:SetText(token); f.copyEB:HighlightText()
  end
  if f.target and f.target.Insert then
    f.target:Insert(token); f.target:SetFocus()   -- also drop it at the template box cursor
  elseif f.copyEB then
    f.copyEB:SetFocus()            -- no target → focus the copy field so Ctrl-C grabs it
  end
end

-- one reusable button row (header or indented token), parented to the scroll child.
local function getRow(f, i)
  local r = f.rows[i]
  if not r then
    r = CreateFrame("Button", nil, f.child)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, 0.08)
    r.lbl = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    r.lbl:SetPoint("LEFT", 4, 0); r.lbl:SetJustifyH("LEFT")
    f.rows[i] = r
  end
  return r
end

local function Build(self)
  local opts = self._opts
  local Theme = opts.theme
  local content
  self._frame, content = Theme.Window({
    name = opts.name, title = opts.title or "Data feeds",
    width = 360, height = 440, minWidth = 300, minHeight = 240,
    resizable = true, collapsible = false, specialFrame = true,
    strata = "DIALOG",
    savedKey = opts.savedKey,
  })
  local f = self._frame

  local hint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", 12, -8); hint:SetPoint("TOPRIGHT", -12, -8)
  -- two explicit lines + word-wrap so the hint never clips/truncates at narrow widths.
  hint:SetJustifyH("LEFT"); hint:SetWordWrap(true)
  hint:SetText("Left-click a header to expand.\nRight-click a header or token to insert it.")
  Theme.Font(hint, "textDim")

  -- copyable field (no-target path): a read-only-ish editbox the user can Ctrl-C from.
  local copyLbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  copyLbl:SetPoint("BOTTOMLEFT", 12, 14); copyLbl:SetText("Copy:")
  Theme.Font(copyLbl, "textDim")
  f.copyEB = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
  f.copyEB:SetSize(220, 18); f.copyEB:SetPoint("LEFT", copyLbl, "RIGHT", 10, 0); f.copyEB:SetAutoFocus(false)
  Theme.EditBox(f.copyEB)
  f.copyEB:SetScript("OnEscapePressed", function(self2) self2:ClearFocus() end)
  -- effectively read-only: re-highlight on any edit attempt so it stays a copy source, not an input.
  f.copyEB:SetScript("OnEnterPressed", function(self2) self2:HighlightText(); self2:ClearFocus() end)

  f.scroll = CreateFrame("ScrollFrame", nil, content)
  -- anchor the list below the (now 2-line) hint so it always has room and never overlaps.
  f.scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6); f.scroll:SetPoint("BOTTOMRIGHT", -28, 36)
  Theme.ContentPanel(f.scroll)
  f.child = CreateFrame("Frame", nil, f.scroll); f.child:SetSize(300, 1)
  f.scroll:SetScrollChild(f.child)
  f.scroll:HookScript("OnSizeChanged", function(self2)
    f.child:SetWidth(math.max(1, self2:GetWidth())); if f.scroll.RefreshScrollBar then f.scroll.RefreshScrollBar() end
  end)
  Theme.AttachScrollBar(f.scroll, content)

  f.empty = f.child:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  f.empty:SetPoint("TOPLEFT", 8, -8); f.empty:SetText("No data feeds registered."); f.empty:Hide()
  Theme.Font(f.empty, "textMuted")
  f.rows = {}        -- reusable row buttons (entry headers + token sub-rows, mixed)
  -- accordion expand state, keyed by entry key ("gectemplate" or a feed slug). Lives on the frame
  -- (built ONCE here, never in Refresh) so it SURVIVES the 0.5s refresh ticker. Default: all collapsed.
  f.expanded = {}
  return f
end

local function Refresh(self)
  local f = self._frame
  if not f or not f:IsShown() then return end
  local opts = self._opts
  local renderer = opts.renderer

  -- Build the unified entry list: the GECTemplate built-in catalog FIRST, then every GECData feed.
  -- Each entry is { key, title, sub, preview, expanded, tokens = { {label, insert}, ... } }.
  local entries = {}

  -- 1) GECTemplate built-in tokens (always shown — ours)
  do
    local toks = {}
    local open = f.expanded["gectemplate"]   -- only render live values when this entry is expanded
    for _, c in ipairs((Tpl and Tpl.catalog) or {}) do
      local vp = ""
      if open then local val = tokenValue(renderer, c.token); if val ~= "" then vp = ("  |cffffffff%s|r"):format(val) end end
      toks[#toks + 1] = { label = ("|cffd0d0d0%s|r  |cff707070%s|r%s"):format(c.token, c.desc or "", vp), insert = c.token }
    end
    entries[#entries + 1] = {
      key = "gectemplate", title = "GECTemplate", sub = "built-in tokens", preview = "",
      tokens = toks, header = nil,   -- header click toggles only (no insert)
    }
  end

  -- 2) each GECData feed — SKIP launchers / data-less objects: some third-party LDB objects register
  -- type="launcher" (icon + OnClick, no text, no tokens), so there's nothing to insert → pointless here.
  -- SUBSCRIPTION: oursOnly → only our (_gec) feeds; otherwise all feeds.
  local feeds = (Data and Data.Feeds and Data.Feeds(opts.oursOnly and { oursOnly = true } or nil)) or {}
  for _, info in ipairs(feeds) do
    local obj = info.object
    local hasTokens = obj and type(obj.tokenTypes) == "table" and next(obj.tokenTypes) ~= nil
    local hasText   = obj and ((obj.text and obj.text ~= "") or (obj.value and obj.value ~= ""))
    if obj and obj.type ~= "launcher" and (hasTokens or hasText) then
    local slug = info.slug
    local toks = {}
    local open = f.expanded[slug]   -- only render live values when this feed is expanded
    for _, tok in ipairs((Data and Data.FeedTokens and Data.FeedTokens(info.object or info.slug)) or {}) do
      local full = "{" .. slug .. "." .. tok.token .. "}"
      local vp = ""
      if open then local val = tokenValue(renderer, full); if val ~= "" then vp = ("  |cffffffff%s|r"):format(val) end end
      toks[#toks + 1] = { label = ("|cffd0d0d0%s|r  |cff707070%s|r%s"):format(full, tok.type or "?", vp), insert = full }
    end
    entries[#entries + 1] = {
      key = slug, title = info.name, sub = ("{%s}"):format(slug), preview = clean(info.object and info.object.text),
      tokens = toks, header = "{" .. slug .. "}",   -- header click inserts the passthrough {slug}
    }
    end   -- has-data filter (skip launchers)
  end

  -- 3) GECBridge adapters (external-addon namespaces, e.g. TSM) whose available() is true. Their
  -- tokens take an itemID ARG, so there's no concrete value to preview — we list the token with a
  -- literal "id" placeholder ({tsm.count.account(id)}) + its desc; clicking inserts that string.
  -- Bridges are OURS, so they show regardless of oursOnly.
  local bridge = (Tpl and Tpl.Bridge and Tpl.Bridge.adapters) or {}
  -- stable order: namespace keys sorted.
  local nsKeys = {}
  for nsName, spec in pairs(bridge) do
    if spec.available and spec.available() then nsKeys[#nsKeys + 1] = nsName end
  end
  table.sort(nsKeys)
  for _, nsName in ipairs(nsKeys) do
    local spec = bridge[nsName]
    -- collect STATIC token paths (spec.tokens) AND representative dynamic paths (spec.catalog),
    -- deduped by path and sorted, so the browser shows both fixed and example open-ended tokens.
    local descByPath, paths, seen = {}, {}, {}
    local function add(path, desc)
      if path and not seen[path] then seen[path] = true; paths[#paths + 1] = path end
      if desc and desc ~= "" then descByPath[path] = descByPath[path] or desc end
    end
    for path, t in pairs(spec.tokens or {}) do add(path, t.desc or t.type) end
    for _, c in ipairs(spec.catalog or {}) do add(c.path, c.desc) end
    table.sort(paths)
    local toks = {}
    for _, path in ipairs(paths) do
      local full = ("{%s.%s(id)}"):format(nsName, path)   -- literal "id" placeholder (needs an itemID)
      toks[#toks + 1] = { label = ("|cffd0d0d0%s|r  |cff707070%s|r"):format(full, descByPath[path] or ""), insert = full }
    end
    entries[#entries + 1] = {
      key = nsName, title = spec.title or nsName, sub = ("{%s}"):format(nsName), preview = "",
      tokens = toks, header = nil,   -- a namespace alone isn't a usable token → toggle only
    }
  end

  -- "empty" = no GECData feeds (GECTemplate + bridges are always present, so never truly empty).
  f.empty:SetShown(#feeds == 0)

  for _, r in ipairs(f.rows) do r:Hide(); r:SetScript("OnClick", nil) end

  local i, y, maxw = 0, -4, 180
  for _, e in ipairs(entries) do
    local open = f.expanded[e.key] and true or false
    -- ----- entry header row: caret + title + dimmed sub + (feed) live preview -----
    i = i + 1
    local r = getRow(f, i); r:SetHeight(FEED_H)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 4, y); r:SetPoint("TOPRIGHT", -4, y)
    local caret = open and "v" or ">"
    local pv = (e.preview ~= "") and ("  |cff707070" .. e.preview .. "|r") or ""
    r.lbl:SetText(("|cff888888%s|r |cffffffff%s|r  |cff888888%s|r%s"):format(caret, e.title, e.sub, pv))
    local key, insertHeader = e.key, e.header
    r:SetScript("OnClick", function(_, button)
      if button == "RightButton" and insertHeader then
        Insert(self, insertHeader)   -- right-click a feed header inserts its passthrough {slug}
      else
        f.expanded[key] = not f.expanded[key]   -- left-click toggles expand
        Refresh(self)
      end
    end)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:Show()   -- rows are Hide()'d at the top each Refresh; re-show the active ones (else the 0.5s
               -- ticker's re-Refresh left them hidden and the list "disappeared" after first open)
    maxw = math.max(maxw, (r.lbl:GetStringWidth() or 0) + 10)
    y = y - FEED_H

    -- ----- token sub-rows: ONLY when this entry is expanded -----
    if open then
      for _, tok in ipairs(e.tokens) do
        i = i + 1
        local tr = getRow(f, i); tr:SetHeight(TOKEN_H)
        tr:ClearAllPoints()
        tr:SetPoint("TOPLEFT", INDENT, y); tr:SetPoint("TOPRIGHT", -4, y)
        tr.lbl:SetText(tok.label)
        local insertText = tok.insert
        -- RIGHT-click inserts (consistent with the header rows); left-click does nothing.
        tr:SetScript("OnClick", function(_, button) if button == "RightButton" then Insert(self, insertText) end end)
        tr:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        tr:Show()
        maxw = math.max(maxw, INDENT + (tr.lbl:GetStringWidth() or 0) + 10)
        y = y - TOKEN_H
      end
    end
  end

  f.child:SetHeight(math.max(1, -y + 8))
  if f.scroll.RefreshScrollBar then f.scroll.RefreshScrollBar() end
end

-- ===================== browser instance API =====================
local Browser = {}
Browser.__index = Browser

-- Open the browser targeting `editbox` (insert at its cursor), or nil → copyable-field path.
function Browser:Open(editbox)
  if not self._frame then Build(self) end
  self._frame.target = editbox
  if self._frame.copyEB then self._frame.copyEB:SetText("") end
  self._frame:Show(); self._frame:Raise()
  Refresh(self)
end

-- Toggle — if shown, hide; otherwise open (with the given target).
function Browser:Toggle(editbox)
  if self._frame and self._frame:IsShown() then self._frame:Hide() else self:Open(editbox) end
end

function lib.New(opts)
  opts = opts or {}
  if not opts.name then
    nameSeq = nameSeq + 1
    opts.name = "GECFeedBrowser" .. nameSeq   -- unique global frame name (UISpecialFrames / Esc)
  end
  local self = setmetatable({ _opts = opts }, Browser)
  -- keep previews/token values live while THIS browser is open (throttled; harmless when hidden).
  if C_Timer then
    self._ticker = C_Timer.NewTicker(0.5, function()
      if self._frame and self._frame:IsShown() then Refresh(self) end
    end)
  end
  return self
end
