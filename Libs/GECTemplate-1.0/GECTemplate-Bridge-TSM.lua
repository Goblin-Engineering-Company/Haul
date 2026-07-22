-- GECTemplate-Bridge-TSM.lua — the first GECBridge adapter: TradeSkillMaster (TSM).
-- Exposes TSM's cross-character / warbank / guild snapshot store as {tsm.<path>(itemID)} tokens.
-- TSM is just another WoW addon (like the existing tsm price adapter in GECTemplate-Resolvers.lua),
-- so naming it in code is fine. All token getters pcall TSM_API and return nil on any failure, so the
-- bridge dispatcher renders "-" rather than throwing.
--
-- Verified against the installed TSM (Core/API.lua):
--   GetPlayerTotals(is)   → numPlayer, numAlts, numAuctions, numAltAuctions
--   GetWarbankQuantity(is)→ number
--   GetGuildTotal(is)     → number
--   GetCustomPriceValue("dbmarket", is) → copper
local Tpl = LibStub and LibStub:GetLibrary("GECTemplate-1.0", true)
if not (Tpl and Tpl.Bridge) then return end

-- TSM itemString for a numeric id (mirrors the tsm price adapter's ToItemString("i:"..id)).
local function itemString(id)
  id = tonumber(id)
  if not (TSM_API and id) then return nil end
  local ok, s = pcall(TSM_API.ToItemString, "i:" .. id)
  return ok and s or nil
end

-- "account" = everything the account OWNS in storage: all characters' bags/bank/mail (GetPlayerTotals'
-- numPlayer+numAlts) PLUS the Warband bank — TSM tracks the warbank in a separate module and does NOT
-- fold it into GetPlayerTotals. Auctions (escrow) and guild banks (not yours) are deliberately excluded;
-- they remain their own scopes. Void storage isn't tracked by TSM at all, so no scope can see it.
local function accountQty(id)
  local is = itemString(id)
  if not (is and TSM_API.GetPlayerTotals) then return nil end
  local ok, numPlayer, numAlts = pcall(TSM_API.GetPlayerTotals, is)
  if not ok then return nil end
  local total = (numPlayer or 0) + (numAlts or 0)
  if TSM_API.GetWarbankQuantity then
    local okW, w = pcall(TSM_API.GetWarbankQuantity, is)
    if okW then total = total + (w or 0) end
  end
  return total
end

-- numPlayer ALONE = THIS character's holdings (bags + bank + mail) — GetPlayerTotals' first return.
local function characterQty(id)
  local is = itemString(id)
  if not (is and TSM_API.GetPlayerTotals) then return nil end
  local ok, numPlayer = pcall(TSM_API.GetPlayerTotals, is)
  if not ok then return nil end
  return numPlayer or 0
end

local function warbandQty(id)
  local is = itemString(id)
  if not (is and TSM_API.GetWarbankQuantity) then return nil end
  local ok, w = pcall(TSM_API.GetWarbankQuantity, is)
  if not ok then return nil end
  return w or 0
end

local function guildQty(id)
  local is = itemString(id)
  if not (is and TSM_API.GetGuildTotal) then return nil end
  local ok, g = pcall(TSM_API.GetGuildTotal, is)
  if not ok then return nil end
  return g or 0
end

-- generic single-return TSM quantity getter — the current character, drilled down per LOCATION.
-- (character = bags+bank+mail summed; these are each location on its own. bank/mail/auctions are
-- TSM's PERSISTENT snapshots — visible even when that location is closed, which C_Item can't do.)
local function qtyVia(fnName)
  return function(id)
    local is = itemString(id)
    if not (is and TSM_API[fnName]) then return nil end
    local ok, n = pcall(TSM_API[fnName], is)
    if not ok then return nil end
    return n or 0
  end
end
local bagsQty     = qtyVia("GetBagQuantity")
local bankQty     = qtyVia("GetBankQuantity")
local mailQty     = qtyVia("GetMailQuantity")
local auctionsQty = qtyVia("GetAuctionQuantity")

-- unit price (copper) for an id via a TSM custom-price string (default "dbmarket"), or nil.
local function marketPrice(id, source)
  local is = itemString(id)
  if not (is and TSM_API.GetCustomPriceValue) then return nil end
  local ok, v = pcall(TSM_API.GetCustomPriceValue, source or "dbmarket", is)
  return ok and v or nil
end

-- friendly source name → TSM custom-price key. An UNKNOWN name passes through verbatim, so any raw
-- TSM key / custom price still works (e.g. {tsm.price.dbregionsoldperday(id)}). Verified against the
-- installed TSM: disenchant = TSM's "Destroy Value" source, key "destroy" (TradeSkillMaster.lua:269,
-- RegisterSource("Crafting","Destroy",…) = max of disenchant/mill/prospect per destroyValueSource).
local SRC = {
  market = "dbmarket", min = "dbminbuyout", minbuyout = "dbminbuyout", buyout = "dbminbuyout",
  historical = "dbhistorical", regionmarket = "dbregionmarketavg", region = "dbregionmarketavg",
  regionminbuyout = "dbregionminbuyoutavg", saleavg = "dbregionsaleavg", regionsale = "dbregionsaleavg",
  salerate = "dbregionsalerate", soldperday = "dbregionsoldperday", vendor = "vendorsell",
  vendorsell = "vendorsell", vendorbuy = "vendorbuy", crafting = "crafting", craft = "crafting",
  disenchant = "destroy", de = "destroy", destroy = "destroy",
}
local function mapSource(s) return s and (SRC[s:lower()] or s) or "dbmarket" end

-- scope → the qty getter that scope counts.
local SCOPE_QTY = {
  character = characterQty, bags = bagsQty, bank = bankQty, mail = mailQty, auctions = auctionsQty,
  account = accountQty, warband = warbandQty, guild = guildQty,
}

-- Dynamic open-ended resolver: returns (value, typeName). Grammar (SCOPE-FIRST, source optional last):
--   price.<source>             → unit price from a TSM source (money)
--   value.<scope>              → scope qty × the DEFAULT source (ctx.tsmPrice, from Settings)
--   value.<scope>.<source>     → scope qty × that specific source
-- typeName nil ⇒ unknown path ⇒ literal; value nil WITH typeName ⇒ known path, no data ⇒ "-".
local function resolve(path, id, ctx)
  local kind, rest = path:match("^(%a+)%.(.+)$")
  if kind == "price" then
    return marketPrice(id, mapSource(rest)), "money"            -- unit price @ source
  elseif kind == "value" then
    local scope, source = rest:match("^(%a+)%.(.+)$")
    if not scope then scope = rest end                          -- value.<scope> (no source)
    local qfn = SCOPE_QTY[scope]
    if not qfn then return nil, nil end                         -- unknown scope → literal
    local qty = qfn(id)
    local price = marketPrice(id, source and mapSource(source) or (ctx and ctx.tsmPrice) or "dbmarket")
    if qty == nil or price == nil then return nil, "money" end  -- known path, no data → "-"
    return math.floor(qty * price), "money"
  end
  return nil, nil                                               -- unknown kind → literal
end

Tpl.Bridge.Register("tsm", {
  title = "TSM",
  available = function() return TSM_API ~= nil end,
  tokens = {
    ["count.character"] = { type = "number", desc = "owned on THIS character (bags+bank+mail)", get = characterQty },
    ["count.bags"]     = { type = "number", desc = "this character's bags only",        get = bagsQty },
    ["count.bank"]     = { type = "number", desc = "this character's bank (persistent)", get = bankQty },
    ["count.mail"]     = { type = "number", desc = "this character's mail",              get = mailQty },
    ["count.auctions"] = { type = "number", desc = "this character's active auctions",   get = auctionsQty },
    ["count.account"] = { type = "number", desc = "owned account-wide (all characters + Warband bank)", get = accountQty },
    ["count.warband"] = { type = "number", desc = "quantity in the Warband bank",      get = warbandQty },
    ["count.guild"]   = { type = "number", desc = "quantity in tracked guild banks",    get = guildQty },
    -- value.* are now handled by `resolve` below (so a source can be specified per token).
  },
  resolve = resolve,
  -- representative dynamic paths for the Feeds browser (the `id` arg is a placeholder there).
  catalog = {
    { path = "value.account",            desc = "account value (default source)" },
    { path = "value.account.minbuyout",  desc = "account value @ min buyout" },
    { path = "value.warband",            desc = "Warband-bank value (default source)" },
    { path = "value.guild",              desc = "guild-bank value (default source)" },
    { path = "price.market",             desc = "market unit price" },
    { path = "price.minbuyout",          desc = "min buyout" },
    { path = "price.vendorsell",         desc = "vendor sell" },
    { path = "price.disenchant",         desc = "disenchant value" },
  },
})
