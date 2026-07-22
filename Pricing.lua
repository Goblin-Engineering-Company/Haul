-- Pricing.lua — per-unit item value from the chosen source, vendor as the floor.
local ADDON, ns = ...

-- Value (copper) of `itemLink` from ONE named source, or nil if that source has no value for it.
local function computePriceFrom(src, itemLink)
  if src == "vendor" then
    return (select(11, GetItemInfo(itemLink)))

  elseif src == "tsm" then
    if not TSM_API then return nil end
    local ok, val = pcall(function()
      local itemString = TSM_API.ToItemString(itemLink)
      if not itemString then return nil end
      return (TSM_API.GetCustomPriceValue(HaulDB.tsmPriceStr or "dbmarket", itemString))
    end)
    return ok and val or nil

  elseif src == "auctionator" then
    if not (Auctionator and Auctionator.API and Auctionator.API.v1) then return nil end
    -- itemID lookup hits commodity prices (most fishing loot); the link lookup
    -- builds a level-aware key that misses commodities, so try ID first.
    local id = GetItemInfoInstant(itemLink)
    if id then
      local ok, v = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "Haul", id)
      if ok and v and v > 0 then return v end
    end
    local ok, v = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, "Haul", itemLink)
    return ok and v or nil
  end
  return nil
end

-- Memoize per (source[+TSM metric], itemLink) with a short TTL. ComputeStats runs a few times a second over
-- every captured item, and an uncached TSM GetCustomPriceValue per item was hundreds of calls/sec; prices
-- don't move on a sub-minute scale, so a short cache is safe (and self-heals when it expires). TTL is
-- configurable via HaulDB.priceCacheTTL (seconds); 0 disables the cache entirely. Used by GetUnitValue and
-- the /haul diag command.
local priceCache = {}
function ns.PriceFrom(src, itemLink)
  if not itemLink then return nil end
  local ttl = (HaulDB and HaulDB.priceCacheTTL) or 45
  if ttl <= 0 then return computePriceFrom(src, itemLink) end
  local key = (src == "tsm")
    and ("tsm\1" .. tostring(HaulDB and HaulDB.tsmPriceStr or "dbmarket") .. "\1" .. itemLink)
    or (src .. "\1" .. itemLink)
  local now = GetTime()
  local c = priceCache[key]
  if c and (now - c.t) < ttl then return c.v end
  local v = computePriceFrom(src, itemLink)
  priceCache[key] = { v = v, t = now }
  return v
end

-- itemLink -> (per-unit value in copper, SOURCE actually used). Tries the configured source; falls back to
-- vendor when that source has no value (e.g. gray junk has no AH price), so the returned source is ACCURATE
-- per item — "vendor" for a fallback, the configured label otherwise. `vendorHint` = GetItemInfo sellPrice.
function ns.GetUnitValue(itemLink, vendorHint)
  if not itemLink then return 0, "vendor" end
  local v = ns.PriceFrom(HaulDB and HaulDB.priceSource or "vendor", itemLink)
  if v and v > 0 then return v, ns.PriceSourceLabel() end   -- the configured source returned a real value
  if vendorHint and vendorHint > 0 then return vendorHint, "vendor" end   -- fell back to vendor (grays, no-AH items)
  return (ns.PriceFrom("vendor", itemLink) or 0), "vendor"
end

-- True when the named price addon is actually usable (matches what GetUnitValue
-- requires, so Options never offers a source that won't work).
function ns.PriceSourceAvailable(src)
  if src == "vendor" then return true end
  if src == "tsm" then return TSM_API ~= nil end
  if src == "auctionator" then
    return Auctionator ~= nil and Auctionator.API ~= nil and Auctionator.API.v1 ~= nil
  end
  return false
end

-- "tsm:dbminbuyout" / "auctionator" / "vendor" — the price source + metric in effect right now.
-- Embedded on item log events (ns.AddLoot) so a reconstructed session reflects what was actually
-- used to value items at capture time, even after the live setting or market prices change.
function ns.PriceSourceLabel()
  local src = (HaulDB and HaulDB.priceSource) or "vendor"
  if src == "tsm" then return "tsm:" .. ((HaulDB and HaulDB.tsmPriceStr) or "dbminbuyout") end
  return src
end
