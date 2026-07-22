-- GECBind-1.0 — shared keybinding helper for GEC addons.
--
-- WoW's NATIVE bindings are the single source of truth: whatever an addon binds here shows up in the game's
-- own Key Bindings menu (and ConsolePort), and reading it back means the addon's UI can never disagree with
-- the game. This lib centralizes everything keybind-related so every addon (now and future) behaves the same:
--   * native-key inspection (which key, of which kind, is on a command),
--   * conflict detection + a game-style "already bound — reassign?" confirmation (one key maps to only one
--     action in WoW, so SetBinding silently STEALS it otherwise),
--   * a reusable capture-cell widget (click to bind, right-click to clear, Esc to cancel),
--   * a one-time migration helper for addons moving off their own stored combos.
local MAJOR, MINOR = "GECBind-1.0", 4
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-------------------------------------------------------------------- key inspection --
-- a binding token is a CONTROLLER button when it contains PAD (PADA, PADDUP, SHIFT-PADA, ...).
function lib.IsPadToken(key) return type(key) == "string" and key:find("PAD") ~= nil end

-- every key currently bound to a native command (WoW returns up to two: primary + secondary).
function lib.Keys(command)
  local out = {}
  if not (command and GetBindingKey) then return out end
  local k1, k2 = GetBindingKey(command)
  if k1 and k1 ~= "" then out[#out + 1] = k1 end
  if k2 and k2 ~= "" then out[#out + 1] = k2 end
  return out
end

-- the bound key of one kind: kind "pad" -> the controller key, anything else -> the keyboard key. Lets a
-- Keyboard cell and a Controller cell each own one of a command's two native key slots.
function lib.KeyOfKind(command, kind)
  for _, k in ipairs(lib.Keys(command)) do
    if (kind == "pad") == lib.IsPadToken(k) then return k end
  end
end

-------------------------------------------------------------------- combo + labels --
-- modifier keys: held to build a combo, never recorded as a bind on their own.
lib.IGNORE = {
  LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
  LMETA = true, RMETA = true, LWIN = true, RWIN = true, UNKNOWN = true,
}
-- canonical WoW modifier order: ALT-CTRL-SHIFT-<KEY>.
function lib.ComboString(key)
  local m = ""
  if IsAltKeyDown() then m = m .. "ALT-" end
  if IsControlKeyDown() then m = m .. "CTRL-" end
  if IsShiftKeyDown() then m = m .. "SHIFT-" end
  return m .. key
end
-- friendly label for a key token (uses WoW's own prettifier when present); "Set key" when unbound.
function lib.Pretty(key)
  if not key or key == "" then return "Set key" end
  if GetBindingText then local t = GetBindingText(key); if t and t ~= "" then return t end end
  return key
end
-- friendly NAME of a bound action ("Interact With Target", "Action / Cast", ...); falls back to the raw id.
function lib.BindingName(action)
  if not action or action == "" then return action end
  local n = GetBindingName and GetBindingName(action)
  if n and n ~= "" then return n end
  return action
end

-------------------------------------------------------------------- conflict + write --
-- What ELSE `combo` is already claimed by (nil if free or it already maps to `command`). One key maps to only
-- one action in WoW, so binding it elsewhere STEALS it — callers should confirm before reassigning.
-- Checks, in order:
--   (a) an optional consumer `extra` map { [combo] = label } — lets an addon fold in its OWN non-native binds
--       (e.g. per-slot override keys that never touch the native binding set) so those collisions are caught
--       too, not just game bindings;
--   (b) WoW's bindings, OVERRIDE-AWARE (GetBindingAction(...,true)) so an active override binding is seen, not
--       only the base binding.
-- Returns (label, rawAction): `label` is a friendly display string; `rawAction` is the native binding id when
-- the hit came from WoW (nil when it came from `extra`) — so the caller can distinguish an addon-owned conflict
-- from a plain game binding and pick prompt-vs-warn accordingly.
function lib.Conflict(combo, command, extra)
  if not (combo and combo ~= "") then return nil end
  if extra and extra[combo] and extra[combo] ~= command then return extra[combo], nil end
  if not GetBindingAction then return nil end
  local action = GetBindingAction(combo, true)   -- true = include override bindings
  if action and action ~= "" and action ~= command then return lib.BindingName(action), action end
  return nil
end

local function save()
  if SaveBindings and GetCurrentBindingSet then pcall(SaveBindings, GetCurrentBindingSet()) end
end
-- clear the key of `kind` currently on `command`, then persist.
function lib.Clear(command, kind)
  local k = lib.KeyOfKind(command, kind)
  if k and SetBinding then SetBinding(k) end
  save()
end
-- bind `combo` to `command`, first clearing this kind's existing key (so a keyboard rebind doesn't wipe the
-- controller slot and vice-versa), then persist. Does NOT check conflicts — use lib.Conflict first.
function lib.Set(combo, command, kind)
  if not SetBinding then return end
  lib.Clear(command, kind)
  SetBinding(combo, command)
  save()
end

-- one-time migration: lift an addon's legacy stored combos into native bindings. `map` is { [command]=combo }.
-- Only seeds a command that has no native key yet (idempotent); returns true if anything changed (so the
-- addon can drop its old store). Out of combat only — SetBinding/SaveBindings can't run in combat.
function lib.Migrate(map)
  if InCombatLockdown() or not SetBinding then return false end
  local changed = false
  for command, combo in pairs(map or {}) do
    if type(combo) == "string" and combo ~= "" and not GetBindingKey(command) then
      SetBinding(combo, command); changed = true
    end
  end
  if changed then save() end
  return changed
end

-------------------------------------------------------------------- confirm popup --
StaticPopupDialogs["GECBIND_REBIND_CONFLICT"] = {
  text = "|cffffd100%s|r is already bound to |cffffffff%s|r.\n\nReassign that key here? "
    .. "The other binding will be cleared.",
  button1 = YES, button2 = CANCEL,
  OnAccept = function(self) local d = self.data; if d and d.accept then d.accept() end end,
  OnCancel = function(self) local d = self.data; if d and d.cancel then d.cancel() end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
-- Confirm reassigning `combo` (currently bound to `otherAction`). accept()/cancel() callbacks. If the popup
-- can't show (rare — too many already up), proceed (the user initiated it).
function lib.ConfirmRebind(combo, otherAction, accept, cancel)
  local dlg = StaticPopup_Show("GECBIND_REBIND_CONFLICT", lib.Pretty(combo), lib.BindingName(otherAction),
    { accept = accept, cancel = cancel })
  if not dlg and accept then accept() end
end

-------------------------------------------------------------------- capture widget --
-- CreateButton(parent, opts) -> a button that binds opts.command natively, with the game-style conflict
-- prompt. opts:
--   command (required)  the native binding command (e.g. "CLICK SBFBtn_fishing:LeftButton", "HAUL_WINDOW")
--   kind                "key" (keyboard, default) or "pad" (controller) — each owns one of the two key slots
--   width               button width (default 130)
--   after               called after any change (set/clear) — e.g. to recompute an auto-enable toggle
--   skin                optional fn(button) to theme it (pass your Theme.Button)
-- The returned button gains :Reload() to re-read its label. Right-click clears; Esc cancels/clears capture.
function lib.CreateButton(parent, opts)
  opts = opts or {}
  local command, kind, width, after = opts.command, opts.kind or "key", opts.width or 130, opts.after
  local function cur() return lib.Pretty(lib.KeyOfKind(command, kind)) end
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(width, 20); btn:SetText(cur())
  btn:SetNormalFontObject("GameFontNormalSmall")   -- pin on the button so a state change can't grow the label
  function btn:Reload() self:SetText(cur()) end
  local function changed() btn:SetText(cur()); if after then after() end end
  local function stop(s)
    s:EnableKeyboard(false); s:SetPropagateKeyboardInput(true)
    s:SetScript("OnKeyDown", nil); s:SetScript("OnGamePadButtonDown", nil)
    pcall(function() if s.EnableGamePadButton then s:EnableGamePadButton(false) end end)
  end
  local function commit(s, token, isPad)
    stop(s)
    if token == "ESCAPE" then lib.Clear(command, kind); changed(); return end
    local combo = isPad and token or lib.ComboString(token)
    local function apply() lib.Set(combo, command, kind); changed() end
    local other = lib.Conflict(combo, command)
    if other then lib.ConfirmRebind(combo, other, apply, function() btn:SetText(cur()) end)
    else apply() end
  end
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:SetScript("OnClick", function(self, click)
    if InCombatLockdown() then return end   -- bindings can't change in combat
    if click == "RightButton" then lib.Clear(command, kind); changed(); return end
    self:SetText(kind == "pad" and "press a controller button..." or "press key...")
    if kind ~= "pad" then   -- keyboard cell: keys only (don't grab a controller button into this slot)
      self:EnableKeyboard(true); self:SetPropagateKeyboardInput(false)
      self:SetScript("OnKeyDown", function(s, keyName)
        if not lib.IGNORE[keyName] then commit(s, keyName, false) end
      end)
    else                    -- controller cell: gamepad buttons; Esc (keyboard) still cancels/clears
      pcall(function() if self.EnableGamePadButton then self:EnableGamePadButton(true) end end)
      self:SetScript("OnGamePadButtonDown", function(s, button)
        if button and button ~= "" then commit(s, button, true) end
      end)
      self:EnableKeyboard(true); self:SetPropagateKeyboardInput(false)
      self:SetScript("OnKeyDown", function(s, keyName)
        if keyName == "ESCAPE" then commit(s, "ESCAPE", false) end
      end)
    end
  end)
  if opts.skin then opts.skin(btn) end
  -- track for the shared UPDATE_BINDINGS auto-refresh (MINOR 3) so the shown key never goes stale after a
  -- reload / a change made in WoW's own Key Bindings menu / ConsolePort / a binding-set switch.
  lib._bindBtns = lib._bindBtns or setmetatable({}, { __mode = "k" })
  lib._bindBtns[btn] = true
  return btn
end

-- NOTE: there is intentionally NO "draggable bar macro" helper here. A bar macro's /click cannot carry the
-- protected cast for an addon's INSECURE smart button (only an override-click from a real key/PAD token can),
-- so such a macro would be a silent no-op. Bind via key/controller (CreateButton) instead.

------------------------------------------------------------ secure-button click edge (MINOR 2) --
-- A SecureActionButton fires its protected action on key-DOWN or key-UP depending on the
-- ActionButtonUseKeyDown CVar. A button registered for a FIXED "AnyUp" silently DROPS the action on a client
-- that casts on key-down (the CVar was never set to 0) — PostClick still fires, but the cast never runs. This
-- cost a multi-hour "won't cast on the new account" hunt in SBF. So EVERY GEC addon's keybind-triggered secure
-- button MUST go through here and never hardcode an edge:
--   * ClickEdge()              -> the "AnyDown"/"AnyUp" matching the current CVar.
--   * RegisterSecureClicks(b)  -> registers that edge for b AND keeps b re-synced on CVAR_UPDATE forever.
-- Call RegisterSecureClicks(b) once when you create the secure button; the lib handles the rest.
function lib.ClickEdge()
  return (GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")) and "AnyDown" or "AnyUp"
end

lib._secureBtns = lib._secureBtns or {}   -- tracked buttons (persists across a MINOR upgrade)
function lib.RegisterSecureClicks(button)
  if not (button and button.RegisterForClicks) then return button end
  lib._secureBtns[button] = true
  button:RegisterForClicks(lib.ClickEdge())
  return button
end

if not lib._edgeFrame then                -- ONE shared watcher re-registers every tracked button on CVar change
  lib._edgeFrame = CreateFrame("Frame")
  lib._edgeFrame:RegisterEvent("CVAR_UPDATE")
  lib._edgeFrame:SetScript("OnEvent", function(_, _, cvar)
    if cvar ~= "ActionButtonUseKeyDown" then return end
    if InCombatLockdown() then return end          -- RegisterForClicks is restricted in combat
    local edge = lib.ClickEdge()
    for b in pairs(lib._secureBtns) do
      if b.RegisterForClicks then b:RegisterForClicks(edge) end
    end
  end)
end

------------------------------------------------------- bind-cell auto-refresh (MINOR 3) --
-- A bind cell reads its key ONCE at creation; without this it goes stale after a /reload (cells built before
-- the bindings finished loading), after a change made in WoW's own Key Bindings menu / ConsolePort, or after a
-- binding-set switch. WoW fires UPDATE_BINDINGS whenever any of those happen, so ONE shared watcher re-reads
-- every tracked cell (via its :Reload()) and the shown key can never disagree with the game again.
lib._bindBtns = lib._bindBtns or setmetatable({}, { __mode = "k" })
if not lib._bindFrame then
  lib._bindFrame = CreateFrame("Frame")
  lib._bindFrame:RegisterEvent("UPDATE_BINDINGS")
  lib._bindFrame:SetScript("OnEvent", function()
    for b in pairs(lib._bindBtns) do
      if b.Reload then pcall(function() b:Reload() end) end
    end
  end)
end
