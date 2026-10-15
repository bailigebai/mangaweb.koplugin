-- Run with KOReader's actual LuaJIT/ffi/sha2 available, passing the source root.
local root = assert(arg[1], 'pass MangaWeb source root')
package.path = root .. '/?.lua;' .. package.path
local fixture = dofile(root .. '/spec/fixtures/license_rsa_vectors.lua')
local crypto = require('mangaweb.license_crypto')
local portable = require('mangaweb.license_rsa_portable')
local checks = 0
for _, vector in ipairs(fixture.vectors) do
    assert(crypto.verify(vector.message, vector.signature, fixture.public_pem) == vector.valid, vector.name)
    assert(portable.verify(vector.message, vector.signature, fixture.public_pem, crypto.sha256) == vector.valid, vector.name)
    assert(portable.verify(vector.message, vector.signature, fixture.wrong_public_pem, crypto.sha256) == false, vector.name)
    checks = checks + 3
end

-- Match Android monolibtic: a library can load without exporting RSA symbols.
local ffi = require('ffi')
local loadlib = ffi.loadlib
ffi.loadlib = function(name, ...)
    if name == 'crypto' then
        return setmetatable({}, { __index = function() error('symbol not exported') end })
    end
    return loadlib(name, ...)
end
package.loaded['mangaweb.license_crypto'] = nil
local android = require('mangaweb.license_crypto')
for _, vector in ipairs(fixture.vectors) do
    assert(android.verify(vector.message, vector.signature, fixture.public_pem) == vector.valid, vector.name)
    checks = checks + 1
end
ffi.loadlib = loadlib
print('Real SHA256 / automatic / portable / hidden native export checks passed: ' .. checks)
