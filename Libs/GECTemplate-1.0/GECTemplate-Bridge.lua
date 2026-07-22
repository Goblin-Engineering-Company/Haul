-- GECTemplate-Bridge.lua — GECBridge: a named adapter interface for reading EXTERNAL addons' APIs
-- through GECTemplate tokens. Each adapter registers a NAMESPACE (e.g. "tsm") and a set of arg-style
-- tokens organized by capability path (e.g. "count.account", "value.account"). It renders via the
-- engine's EXISTING facet+arg model with NO engine change:
--
--   {tsm.count.account(6948)}  → parseToken: name="tsm.count.account", arg="6948"
--     → engine arg-branch: lib.types["tsm.count.account"]? no → split base="tsm" (a registered type),
--       facet="count.account", v=arg="6948" → calls our type fn(v="6948", facet="count.account").
--
-- So registering the namespace as a GECTemplate TYPE whose FACET is the token path is all it takes.
-- Adapters live in their own files (e.g. GECTemplate-Bridge-TSM.lua) and call Tpl.Bridge.Register.
local Tpl = LibStub and LibStub:GetLibrary("GECTemplate-1.0", true)
if not Tpl then return end

Tpl.Bridge = Tpl.Bridge or { adapters = {} }

-- Register an adapter under `namespace`. spec = {
--   title     = "TSM",
--   available = function() return <addon loaded?> end,
--   tokens    = { ["count.account"] = { desc=, type="number"|"money"|"text", get=function(itemID, ctx)->value }, ... },
--   resolve   = function(path, arg, ctx) -> value, typeName    -- OPTIONAL: open-ended dynamic paths
--   catalog   = { { path="value.account", desc=… }, … }       -- OPTIONAL: example paths for browsers
-- }
--
-- Dispatch order for {ns.<facet>(arg)}: STATIC tokens (spec.tokens[facet]) → dynamic spec.resolve →
-- literal. resolve(path, arg, ctx) returns (value, typeName): typeName==nil ⇒ unknown path ⇒ literal
-- (typo aid); value==nil WITH a typeName ⇒ known path but no data ⇒ "-".
function Tpl.Bridge.Register(namespace, spec)
  Tpl.Bridge.adapters[namespace] = spec
  Tpl.RegisterType(namespace, function(v, facet, ctx)
    if not (spec.available and spec.available()) then return "-", false end
    -- 1) STATIC tokens (declared get) take precedence.
    local tok = facet and spec.tokens and spec.tokens[facet]
    if tok and tok.get then
      local ok, val = pcall(tok.get, v, ctx)               -- v = the itemID arg, ctx = renderer (per-consumer config); pcall so a bad adapter can't throw
      if not ok or val == nil then return "-", false end
      local rt = tok.type and Tpl.types[tok.type]
      if rt then return rt(val, nil, ctx) end              -- render via the declared type
      return tostring(val), false
    end
    -- 2) DYNAMIC open-ended paths via spec.resolve(path, arg, ctx) -> value, typeName.
    if facet and spec.resolve then
      local ok, val, typ = pcall(spec.resolve, facet, v, ctx)
      if not ok or not typ then return nil end             -- error OR no typeName → unknown path → literal
      if val == nil then return "-", false end             -- known path, no data → "-"
      local rt = Tpl.types[typ]
      if rt then return rt(val, nil, ctx) end
      return tostring(val), false
    end
    return nil                                             -- unknown path → engine renders literal
  end)
end
