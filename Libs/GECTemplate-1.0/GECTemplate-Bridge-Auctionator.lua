-- GECTemplate-Bridge-Auctionator.lua — GECBridge adapter for Auctionator. Price-only: Auctionator has
-- no cross-character inventory counts (that's TSM's job), so this exposes Auctionator's per-item prices
-- as {auctionator.price[.<source>](itemID)} + {auctionator.age(itemID)}. Auctionator is just another WoW
-- addon (interop, like TSM), so naming it in code is fine. Every getter pcalls the API and returns nil on
-- any failure, so the bridge dispatcher renders "-" instead of throwing.
--
-- Verified against the installed Auctionator (Source/API/v1/):
--   GetAuctionPriceByItemID(callerID, itemID)    → copper (current auction value) | nil
--   GetVendorPriceByItemID(callerID, itemID)     → copper (vendor sell)           | nil
--   GetDisenchantPriceByItemID(callerID, itemID) → copper (disenchant value)      | nil
--   GetAuctionAgeByItemID(callerID, itemID)      → age of the price data (days)   | nil
--   InternalVerifyID only requires a non-empty string callerID (no registration needed).
local Tpl = LibStub and LibStub:GetLibrary("GECTemplate-1.0", true)
if not (Tpl and Tpl.Bridge) then return end

local CALLER = "GEC"   -- any non-empty string; Auctionator uses it only to attribute API calls.

local function apiV1()
  local a = Auctionator
  if a and a.API and a.API.v1 then return a.API.v1 end
  return nil
end

-- generic copper getter for an Auctionator "...ByItemID" API, pcall-guarded → number or nil.
local function priceVia(fnName)
  return function(id)
    local v1 = apiV1(); id = tonumber(id)
    if not (v1 and id and v1[fnName]) then return nil end
    local ok, v = pcall(v1[fnName], CALLER, id)
    if not ok then return nil end
    return v   -- copper (or days for age), or nil when Auctionator has no data
  end
end
local auctionPrice    = priceVia("GetAuctionPriceByItemID")
local vendorPrice     = priceVia("GetVendorPriceByItemID")
local disenchantPrice = priceVia("GetDisenchantPriceByItemID")
local dataAge         = priceVia("GetAuctionAgeByItemID")

-- friendly source name → getter. market/auction/min/buyout all map to Auctionator's primary live value
-- (it has no separate min-buyout vs market split like TSM). An UNKNOWN name falls back to that live value,
-- mirroring TSM's pass-through leniency so a typo'd source still renders something sensible.
local SRC = {
  market = auctionPrice, auction = auctionPrice, ah = auctionPrice,
  min = auctionPrice, minbuyout = auctionPrice, buyout = auctionPrice,
  vendor = vendorPrice, vendorsell = vendorPrice,
  disenchant = disenchantPrice, de = disenchantPrice, destroy = disenchantPrice,
}
local function srcFn(s) return (s and SRC[s:lower()]) or auctionPrice end

-- Dynamic resolver: returns (value, typeName). Grammar (price-only — Auctionator has no quantities, so
-- there is no value.<scope> like TSM):
--   price            → current auction value (money)
--   price.<source>   → that source's unit price (money): vendor / disenchant / market…
--   age              → auction-data age in days (number)
-- typeName nil ⇒ unknown path ⇒ literal; value nil WITH typeName ⇒ known path, no data ⇒ "-".
local function resolve(path, id)
  local kind, rest = path:match("^(%a+)%.?(.*)$")
  if kind == "price" then
    return srcFn(rest ~= "" and rest or nil)(id), "money"
  elseif kind == "age" then
    return dataAge(id), "number"
  end
  return nil, nil   -- unknown kind → literal
end

Tpl.Bridge.Register("auctionator", {
  title = "Auctionator",
  available = function() return apiV1() ~= nil end,
  tokens = {
    ["price"]            = { type = "money",  desc = "current auction value",   get = auctionPrice },
    ["price.auction"]    = { type = "money",  desc = "current auction value",   get = auctionPrice },
    ["price.vendor"]     = { type = "money",  desc = "vendor sell price",       get = vendorPrice },
    ["price.disenchant"] = { type = "money",  desc = "disenchant value",        get = disenchantPrice },
    ["age"]              = { type = "number", desc = "price-data age (days)",   get = dataAge },
    -- other price.<source> aliases (market/min/buyout/de/…) are handled by `resolve` below.
  },
  resolve = resolve,
  -- representative paths for the Feeds browser (the `id` arg is a placeholder there).
  catalog = {
    { path = "price",            desc = "current auction value" },
    { path = "price.vendor",     desc = "vendor sell" },
    { path = "price.disenchant", desc = "disenchant value" },
    { path = "age",              desc = "price-data age (days)" },
  },
})
