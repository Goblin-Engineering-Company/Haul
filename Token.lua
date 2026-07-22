-- Token.lua — WoW Token price, the "% of a Token" stat, and a price trend.
-- Haul only READS the price (for {token.percent} / {token.value} / {token.trend});
-- monitoring + buy/sell alerting lives in Megaphone now.
-- NOTE: verify C_WowTokenPublic against the live build; the names below are the
-- long-standing retail ones but Blizzard occasionally shuffles this namespace.
local ADDON, ns = ...

local tokenPrice          -- copper, nil until fetched
local tokenTrend = "flat" -- "up" / "down" / "flat" vs the previous reading

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("TOKEN_MARKET_PRICE_UPDATED")
f:SetScript("OnEvent", function(_, event)
  if not C_WowTokenPublic then return end
  if event == "PLAYER_LOGIN" then pcall(C_WowTokenPublic.UpdateMarketPrice) end
  local ok, price = pcall(C_WowTokenPublic.GetCurrentMarketPrice)
  if ok and price and price > 0 then
    -- trend vs the last reading: up / down / flat (flat = exact same number)
    if tokenPrice == nil then tokenTrend = "flat"
    elseif price > tokenPrice then tokenTrend = "up"
    elseif price < tokenPrice then tokenTrend = "down"
    else tokenTrend = "flat" end
    tokenPrice = price
    if ns.RefreshUI then ns.RefreshUI() end            -- repaint so {token.*} update
  end
end)

-- periodic refresh (token price moves slowly; every 10 min is plenty)
if C_Timer then
  C_Timer.NewTicker(600, function()
    if C_WowTokenPublic then pcall(C_WowTokenPublic.UpdateMarketPrice) end
  end)
end

-- returns percent (0-100+) of a token earned for `copper`, or nil if no price
function ns.GetTokenPct(copper)
  if not tokenPrice or tokenPrice <= 0 then return nil end
  return (tonumber(copper) or 0) / tokenPrice * 100
end

function ns.TokenPrice() return tokenPrice end
function ns.TokenTrend() return tokenTrend end
