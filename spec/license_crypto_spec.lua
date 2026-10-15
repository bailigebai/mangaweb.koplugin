local fixture = dofile('spec/fixtures/license_rsa_vectors.lua')
local digests = {}
for _, vector in ipairs(fixture.vectors) do digests[vector.message] = vector.digest end

-- Android monolibtic loads successfully but does not export these RSA APIs.
package.preload['ffi'] = function()
    return {
        cdef = function() end,
        loadlib = function()
            return setmetatable({}, { __index = function() error('symbol not exported') end })
        end,
    }
end
package.preload['ffi/loadlib'] = function() return true end
package.preload['ffi/sha2'] = function()
    return { sha256 = function(message) return assert(digests[message]) end }
end
local Crypto = require('mangaweb.license_crypto')
for _, vector in ipairs(fixture.vectors) do
    local verified = Crypto.verify(vector.message, vector.signature, fixture.public_pem)
    assert(verified == vector.valid,
        'RSA verification with missing native exports: ' .. vector.name)
    assert(Crypto.verify(vector.message, vector.signature, fixture.wrong_public_pem) == false)
end

local first = fixture.vectors[1]
assert(Crypto.verify(first.message, first.signature:sub(2), fixture.public_pem) == false)
assert(Crypto.verify(first.message, first.signature .. '\n', fixture.public_pem) == false)
assert(Crypto.verify(first.message, first.signature, fixture.public_pem .. 'extra') == false)
assert(Crypto.verify(first.message, first.signature, 'not a public key') == false)
assert(Crypto.verify(string.rep('x', 257), first.signature, fixture.public_pem) == false)

-- Every missing export must be detected before any native allocation; an
-- incomplete API must not prevent the real portable verifier from running.
local required = {
    'BIO_new_mem_buf', 'BIO_free', 'PEM_read_bio_PUBKEY', 'EVP_PKEY_free',
    'EVP_PKEY_get1_RSA', 'RSA_size', 'RSA_free', 'EVP_MD_CTX_new',
    'EVP_MD_CTX_free', 'EVP_sha256', 'EVP_DigestVerifyInit',
    'EVP_PKEY_CTX_ctrl_str', 'EVP_DigestUpdate', 'EVP_DigestVerifyFinal', 'EVP_DecodeBlock',
}
local ffi = require('ffi')
for _, missing in ipairs(required) do
    local library, allocations = {}, 0
    for _, name in ipairs(required) do
        if name ~= missing then library[name] = function()
            allocations = allocations + 1
            error('incomplete native API must not be called')
        end end
    end
    ffi.loadlib = function() return library end
    package.loaded['mangaweb.license_crypto'] = nil
    local candidate = require('mangaweb.license_crypto')
    assert(candidate.verify(first.message, first.signature, fixture.public_pem) == true, missing)
    assert(allocations == 0, 'native objects allocated with missing ' .. missing)
end

-- A usable native backend refusing a receipt must not trigger another path.
local library, allocations = {}, 0
for _, name in ipairs(required) do library[name] = function() error('unexpected native call') end end
library.BIO_new_mem_buf = function() allocations = allocations + 1; return nil end
ffi.loadlib = function() return library end
package.loaded['mangaweb.license_crypto'] = nil
assert(require('mangaweb.license_crypto').verify(first.message, first.signature, fixture.public_pem) == false)
assert(allocations == 1)

-- Missing SHA256 must never turn an unverifiable receipt into an authorization.
package.loaded['ffi/sha2'].sha256 = function() return nil end
assert(Crypto.verify(first.message, first.signature, fixture.public_pem) == false)
