-- ImportExport.lua — settings as editable JSON. Copy it out, edit it anywhere
-- (the Helper app, a text editor), paste it back. Addons can't read/write files,
-- so copy/paste (and the SavedVariables mirror) is the channel.
local ADDON, ns = ...
local Theme = LibStub("GECTheme-1.0").ForAddon(function() return (HaulDB and HaulDB.themePreset) or "gruvbox" end)

-- The user-editable settings keys (NOT history/session/dev state — no watchers,
-- wSeq, liveSession, sidelined, history, dev, debug). A complete Haul-config snapshot.
local SETTINGS_KEYS = {
  "priceSource", "tsmPriceStr", "notableQuality", "graysMode", "boundMode",
  "excludedMode", "view", "repView", "sortBy", "headerTemplate", "detailTemplate",
  "flushEnabled", "flushSeconds", "reloadBeforeNewSession",
  "autoStartInstance", "themePreset",
  "newSessionTriggers", "newSessionMapLevel", "newSessionPrompt",
  "countPausedByDefault", "logShow",
  "scale", "headerFontSize", "headerColor", "headerSpacing", "headerPad",
}

------------------------------------------------------------------ JSON enc ----
local function enc(v)
  local t = type(v)
  if t == "string" then
    return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
      local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                  ['\r'] = '\\r', ['\t'] = '\\t' }
      return m[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
  elseif t == "number" then return tostring(v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "table" then
    local parts = {}
    if #v > 0 then
      for _, e in ipairs(v) do parts[#parts + 1] = enc(e) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, val in pairs(v) do parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(val) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

------------------------------------------------------------------ JSON dec ----
local function decode(s)
  local pos = 1
  local function skip() while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end end
  local value
  local function str()
    pos = pos + 1
    local buf = {}
    while pos <= #s do
      local c = s:sub(pos, pos)
      if c == '"' then pos = pos + 1; return table.concat(buf) end
      if c == "\\" then
        pos = pos + 1
        local e = s:sub(pos, pos)
        local m = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', n = '\n', t = '\t',
                    r = '\r', b = '\b', f = '\f' }
        if e == "u" then
          buf[#buf + 1] = string.char((tonumber(s:sub(pos + 1, pos + 4), 16) or 63) % 256)
          pos = pos + 4
        else buf[#buf + 1] = m[e] or e end
        pos = pos + 1
      else buf[#buf + 1] = c; pos = pos + 1 end
    end
    error("unterminated string")
  end
  local function obj()
    pos = pos + 1; local o = {}; skip()
    if s:sub(pos, pos) == "}" then pos = pos + 1; return o end
    while true do
      skip(); local k = str(); skip(); pos = pos + 1  -- ':'
      o[k] = value(); skip()
      local c = s:sub(pos, pos); pos = pos + 1
      if c == "}" then return o elseif c ~= "," then error("bad object") end
    end
  end
  local function arr()
    pos = pos + 1; local a = {}; skip()
    if s:sub(pos, pos) == "]" then pos = pos + 1; return a end
    while true do
      a[#a + 1] = value(); skip()
      local c = s:sub(pos, pos); pos = pos + 1
      if c == "]" then return a elseif c ~= "," then error("bad array") end
    end
  end
  value = function()
    skip()
    local c = s:sub(pos, pos)
    if c == '"' then return str()
    elseif c == "{" then return obj()
    elseif c == "[" then return arr()
    elseif c == "t" then pos = pos + 4; return true
    elseif c == "f" then pos = pos + 5; return false
    elseif c == "n" then pos = pos + 4; return nil
    else
      local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
      if num and num ~= "" then pos = pos + #num; return tonumber(num) end
      error("unexpected char at " .. pos)
    end
  end
  return value()
end

------------------------------------------------------------------ settings ----
-- The header template can hold real newlines (Enter in the multi-line field). Keep
-- the exported JSON portable + readable by storing those as the {br} token, and
-- convert any line-break token back to a real newline on import so the editor
-- shows it as wrapped lines. Both render identically in the bar.
local function nlToBr(s)
  return type(s) == "string" and (s:gsub("\n", "{br}")) or s
end
local function brToNL(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("{(%w+)}", function(tok)
    local t = tok:lower()
    if t == "br" or t == "lb" or t == "lw" or t == "linewrap" or t == "wrap" then
      return "\n"
    end
    return "{" .. tok .. "}"
  end))
end

function ns.ExportTable()
  local out = {}
  for _, k in ipairs(SETTINGS_KEYS) do out[k] = HaulDB[k] end
  out.headerTemplate = nlToBr(out.headerTemplate)   -- newlines -> {br} for clean JSON
  out.detailTemplate = nlToBr(out.detailTemplate)
  local ex = {}  -- excluded ids as an array (numeric keys don't survive JSON)
  for id in pairs(HaulDB.excluded or {}) do ex[#ex + 1] = id end
  table.sort(ex)
  out.excluded = ex
  return out
end

function ns.ExportSettings()
  -- one key per line so it's pleasant to edit
  local out, lines = ns.ExportTable(), {}
  for _, k in ipairs(SETTINGS_KEYS) do
    lines[#lines + 1] = '  ' .. enc(k) .. ': ' .. enc(out[k])
  end
  lines[#lines + 1] = '  "excluded": ' .. enc(out.excluded)
  return "{\n" .. table.concat(lines, ",\n") .. "\n}"
end

function ns.ImportSettings(text)
  local ok, data = pcall(decode, text)
  if not ok or type(data) ~= "table" then
    ns.Print("|cffff6060import failed — not valid JSON|r"); return false
  end
  for _, k in ipairs(SETTINGS_KEYS) do
    if data[k] ~= nil then HaulDB[k] = data[k] end
  end
  HaulDB.headerTemplate = brToNL(HaulDB.headerTemplate)  -- {br} -> newline for editor
  HaulDB.detailTemplate = brToNL(HaulDB.detailTemplate)
  if type(data.excluded) == "table" then
    local ex = {}
    for _, id in ipairs(data.excluded) do ex[tonumber(id) or id] = true end
    HaulDB.excluded = ex
  end
  if ns.StartFlush then ns.StartFlush() end
  if ns.ApplyHeaderStyle then ns.ApplyHeaderStyle() end
  if ns.RefreshUI then ns.RefreshUI() end
  ns.Print("|cff80ff80settings imported|r")
  return true
end

---------------------------------------------------------------------- window --
local frame
function ns.ShowPorter()
  if not frame then
    frame = CreateFrame("Frame", "HaulPorter", UIParent, "BackdropTemplate")
    frame:SetSize(440, 320); frame:SetPoint("CENTER"); frame:SetFrameStrata("DIALOG")
    Theme.Panel(frame)
    frame:EnableMouse(true); frame:SetMovable(true); frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10); title:SetText("Haul — Settings (JSON)")
    Theme.Font(title, "text")
    local porterCloseBtn = Theme.CloseButton(frame, function() frame:Hide() end)
    porterCloseBtn:SetPoint("TOPRIGHT", -6, -6)

    local sf = CreateFrame("ScrollFrame", "HaulPorterScroll", frame, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 12, -40); sf:SetPoint("BOTTOMRIGHT", -30, 44)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true); eb:SetFontObject("ChatFontNormal"); eb:SetWidth(384)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    sf:SetScrollChild(eb)
    frame.eb = eb

    local exp = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    exp:SetSize(110, 22); exp:SetPoint("BOTTOMLEFT", 12, 12); exp:SetText("Export (copy)")
    Theme.Button(exp)
    exp:SetScript("OnClick", function()
      frame.eb:SetText(ns.ExportSettings()); frame.eb:HighlightText(); frame.eb:SetFocus()
    end)
    local imp = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    imp:SetSize(110, 22); imp:SetPoint("LEFT", exp, "RIGHT", 8, 0); imp:SetText("Import (paste)")
    Theme.Button(imp)
    imp:SetScript("OnClick", function() ns.ImportSettings(frame.eb:GetText()) end)
    local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMRIGHT", -12, 18); hint:SetText("Ctrl+A, Ctrl+C to copy / Ctrl+V to paste")
    Theme.Font(hint, "textMuted")
  end
  frame.eb:SetText(ns.ExportSettings())
  frame:Show()
end
