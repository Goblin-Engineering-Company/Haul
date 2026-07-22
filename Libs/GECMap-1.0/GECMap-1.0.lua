-- GECMap-1.0 — canonical, content-addressed place registry (spec 2026-07-17-gecmap-...).
-- The PURE CORE: the pinned place cascade hash (SHA-256 → first 8 bytes → mod 36^10 → base-36, 10
-- chars) and the composite key builder. Content-addressed ⇒ Lua, Rust and TS compute the SAME id
-- independently. The hash vectors are pinned in website/tests/places.hash.test.ts and this lib's tests.
--
-- Bundles a pure-Lua SHA-256 (LuaJIT `bit`; WoW exposes the same `bit` global). Runs once per
-- newly-seen cascade, so its cost is irrelevant. The sync/registry/reconciliation layer (server round
-- trip, sub-area aliasing) is NOT here — this file is the deterministic, headless-testable core.

local MAJOR, MINOR = "GECMap-1.0", 2   -- 2: WoW bit-subset polyfill (ror/tobit/variadic bxor)
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end
GECMap = lib

local bit = rawget(_G, "bit") or (require and require("bit"))
local band, bor, bnot = bit.band, bit.bor, bit.bnot
local rshift, lshift = bit.rshift, bit.lshift
-- WoW's bit library is a LuaBitOp SUBSET: it lacks ror + tobit, and its band/bor/bxor are 2-ARG (luajit's
-- are variadic + provide ror/tobit). Polyfill from the basics so this SHA-256 is byte-identical in-game and
-- headless. (GECMap was only ever exercised under luajit until it was wired in-game — hence this surfaced now.)
local _bxor = bit.bxor
local function bxor(...)                                    -- 3-arg-safe: reduce via 2-arg xor (associative)
  local r = ...
  for i = 2, select("#", ...) do r = _bxor(r, (select(i, ...))) end
  return r
end
local ror = bit.ror or function(x, n) return band(bor(rshift(x, n), lshift(x, 32 - n)), 0xffffffff) end
local tobit = bit.tobit or function(x) return x % 0x100000000 end

-- ===== SHA-256 (pure Lua, 32-bit via `bit`) =====
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function add32(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + select(i, ...) end
  return tobit(s)            -- wraparound mod 2^32 (bit pattern is what matters downstream)
end

-- Return the SHA-256 digest of `msg` as a table of 32 byte values (0-255), big-endian per word.
function lib.Sha256Bytes(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  local len = #msg
  local withOne = msg .. "\128"
  local padZeros = (56 - (#withOne % 64)) % 64
  local bitLen = len * 8
  local hi = math.floor(bitLen / 0x100000000)
  local lo = bitLen % 0x100000000
  local tail = string.char(
    band(rshift(hi, 24), 0xff), band(rshift(hi, 16), 0xff), band(rshift(hi, 8), 0xff), band(hi, 0xff),
    band(rshift(lo, 24), 0xff), band(rshift(lo, 16), 0xff), band(rshift(lo, 8), 0xff), band(lo, 0xff))
  local data = withOne .. string.rep("\0", padZeros) .. tail

  local w = {}
  for chunk = 1, #data, 64 do
    for i = 0, 15 do
      local p = chunk + i * 4
      w[i + 1] = bxor(lshift(data:byte(p), 24), lshift(data:byte(p + 1), 16),
                      lshift(data:byte(p + 2), 8), data:byte(p + 3))
    end
    for i = 17, 64 do
      local a, b = w[i - 15], w[i - 2]
      local s0 = bxor(ror(a, 7), ror(a, 18), rshift(a, 3))
      local s1 = bxor(ror(b, 17), ror(b, 19), rshift(b, 10))
      w[i] = add32(w[i - 16], s0, w[i - 7], s1)
    end

    local a, b, c, d = h0, h1, h2, h3
    local e, f, g, h = h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = add32(h, S1, ch, K[i], w[i])
      local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = add32(S0, maj)
      h, g, f, e = g, f, e, add32(d, t1)
      d, c, b, a = c, b, a, add32(t1, t2)
    end

    h0, h1, h2, h3 = add32(h0, a), add32(h1, b), add32(h2, c), add32(h3, d)
    h4, h5, h6, h7 = add32(h4, e), add32(h5, f), add32(h6, g), add32(h7, h)
  end

  local out, n = {}, 0
  for _, hv in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
    out[n + 1] = band(rshift(hv, 24), 0xff)
    out[n + 2] = band(rshift(hv, 16), 0xff)
    out[n + 3] = band(rshift(hv, 8), 0xff)
    out[n + 4] = band(hv, 0xff)
    n = n + 4
  end
  return out
end

function lib.Sha256Hex(msg)
  local b = lib.Sha256Bytes(msg)
  local t = {}
  for i = 1, #b do t[i] = string.format("%02x", b[i]) end
  return table.concat(t)
end

-- ===== the pinned id(): first 8 digest bytes (big-endian) mod 36^10 → 10 base-36 chars =====
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
-- Reduce the 8-byte big-endian head mod 36^10 WITHOUT a 64-bit int: long-divide the byte array by 36,
-- collecting base-36 remainders LSD-first; the low 10 are (value mod 36^10). Each carry < 256·36 < 2^13.
function lib.Id(s)
  local d = lib.Sha256Bytes(s)
  local work = { d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8] }
  local digits = {}
  local nonzero = true
  while nonzero do
    local rem = 0
    nonzero = false
    for i = 1, 8 do
      local cur = rem * 256 + work[i]
      work[i] = math.floor(cur / 36)
      rem = cur % 36
      if work[i] ~= 0 then nonzero = true end
    end
    digits[#digits + 1] = rem
  end
  local out = {}
  for p = 1, 10 do
    local dv = digits[11 - p] or 0     -- MSD-first, low 10 digits, zero-padded
    out[p] = B36:sub(dv + 1, dv + 1)
  end
  return table.concat(out)
end

-- ===== cascade → composite key =====
-- The front chain: base-10 mapID of every level that HAS a mapID, root→leaf, joined by ">".
function lib.CascadeChain(cascade)
  local parts = {}
  for i = 1, #cascade do
    local lv = cascade[i]
    if lv.mapID then parts[#parts + 1] = tostring(lv.mapID) end
  end
  return table.concat(parts, ">")
end

function lib.CascadeHash(cascade)
  return lib.Id(lib.CascadeChain(cascade))
end

-- The localized area leaf (deepest level with NO mapID), if any → its provisional subAreaRef.
local function areaLeaf(cascade)
  local leaf = cascade[#cascade]
  if leaf and not leaf.mapID then return leaf end
  return nil
end

-- Resolve a cascade to the composite event key "<cascadeHash>-<subAreaRef>" (spec §4). No area leaf ⇒
-- empty back ("<cascadeHash>-"). Pure — a cascade seen for the first time already carries its final key.
-- The back hashes the leaf in the `n:<name>` SENTINEL form (the same representation the mapID-less level
-- takes in GECStore.cascadeKey), which is the pinned cross-language contract (website places.hash vectors).
function lib.Resolve(cascade)
  if not cascade or #cascade == 0 then return nil end
  local front = lib.CascadeHash(cascade)
  local leaf = areaLeaf(cascade)
  local back = (leaf and leaf.name and leaf.name ~= "") and lib.Id("n:" .. leaf.name) or ""
  return front .. "-" .. back
end

return lib
