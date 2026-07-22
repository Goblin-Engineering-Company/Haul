-- Durations.lua — human time entry (10s / 10m / 1h). A bare number = seconds.
local ADDON, ns = ...
ns.Duration = {}

local UNITS = { ms = 0.001, s = 1, m = 60, h = 3600 }

-- Parse "10", "10s", "10m", "1h", "500ms" -> seconds (number). Returns `default`
-- on blank/garbage. A bare number defaults to seconds.
function ns.Duration.ParseSeconds(text, default)
  if type(text) == "number" then return text end
  text = tostring(text or ""):gsub("%s+", ""):lower()
  if text == "" then return default end
  local num, unit = text:match("^(%d+%.?%d*)(%a*)$")
  num = num and tonumber(num)
  if not num then return default end
  unit = (unit == "" and "s") or unit
  local mult = UNITS[unit]
  if not mult then return default end
  return num * mult
end

-- Render seconds with the cleanest unit suffix (0 -> "off").
function ns.Duration.Format(sec)
  sec = tonumber(sec) or 0
  if sec <= 0 then return "off" end
  if sec % 3600 == 0 then return (sec / 3600) .. "h" end
  if sec % 60 == 0 then return (sec / 60) .. "m" end
  return sec .. "s"
end
