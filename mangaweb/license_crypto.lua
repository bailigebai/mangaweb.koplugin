local Crypto = {}

local function read_file(path, limit)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local value = handle:read(limit + 1)
    handle:close()
    if type(value) ~= "string" or #value > limit then return nil end
    return value
end

function Crypto.sha256(value)
    if type(value) ~= "string" then return nil end
    local success, digest = pcall(function()
        return require("ffi/sha2").sha256(value)
    end)
    if success and type(digest) == "string" and #digest == 64
        and digest:match("^[0-9a-f]+$") then
        return digest
    end
    return nil
end

local function valid_signature(value)
    if type(value) ~= "string" or #value ~= 344 or value:sub(-2) ~= "==" then
        return false
    end
    local encoded = value:sub(1, 342)
    return encoded:match("^[A-Za-z0-9+/]+$") ~= nil
        and encoded:sub(-1):match("^[AQgw]$") ~= nil
end

local ffi
local libcrypto
local backend_checked = false

local function load_backend()
    if backend_checked then return ffi ~= nil and libcrypto ~= nil end
    backend_checked = true

    local success = pcall(function()
        ffi = require("ffi")
        require("ffi/loadlib")
        ffi.cdef[[
            typedef struct bio_st MWL_BIO;
            typedef struct evp_pkey_st MWL_PKEY;
            typedef struct evp_md_st MWL_MD;
            typedef struct evp_md_ctx_st MWL_MD_CTX;
            typedef struct evp_pkey_ctx_st MWL_PKEY_CTX;
            typedef struct rsa_st MWL_RSA;
            MWL_BIO *BIO_new_mem_buf(const void *, int);
            int BIO_free(MWL_BIO *);
            MWL_PKEY *PEM_read_bio_PUBKEY(MWL_BIO *, MWL_PKEY **, void *, void *);
            void EVP_PKEY_free(MWL_PKEY *);
            MWL_RSA *EVP_PKEY_get1_RSA(MWL_PKEY *);
            int RSA_size(const MWL_RSA *);
            void RSA_free(MWL_RSA *);
            MWL_MD_CTX *EVP_MD_CTX_new(void);
            void EVP_MD_CTX_free(MWL_MD_CTX *);
            const MWL_MD *EVP_sha256(void);
            int EVP_DigestVerifyInit(MWL_MD_CTX *, MWL_PKEY_CTX **,
                const MWL_MD *, void *, MWL_PKEY *);
            int EVP_PKEY_CTX_ctrl_str(MWL_PKEY_CTX *, const char *, const char *);
            int EVP_DigestUpdate(MWL_MD_CTX *, const void *, size_t);
            int EVP_DigestVerifyFinal(MWL_MD_CTX *, const unsigned char *, size_t);
            int EVP_DecodeBlock(unsigned char *, const unsigned char *, int);
        ]]
        libcrypto = ffi.loadlib("crypto", "57")
    end)
    if not success then
        ffi, libcrypto = nil, nil
        return false
    end
    return libcrypto ~= nil
end

function Crypto.verify(message, signature, public_pem)
    if type(message) ~= "string" or #message > 256
        or not valid_signature(signature)
        or type(public_pem) ~= "string" or #public_pem == 0 or #public_pem > 8192 then
        return false
    end
    if not load_backend() then return false end

    local bio, public_key, rsa, context
    local success, verified = pcall(function()
        bio = libcrypto.BIO_new_mem_buf(public_pem, #public_pem)
        if bio == nil then return false end
        public_key = libcrypto.PEM_read_bio_PUBKEY(bio, nil, nil, nil)
        if public_key == nil then return false end
        rsa = libcrypto.EVP_PKEY_get1_RSA(public_key)
        if rsa == nil or libcrypto.RSA_size(rsa) ~= 256 then return false end

        local decoded = ffi.new("unsigned char[258]")
        if libcrypto.EVP_DecodeBlock(decoded, signature, #signature) ~= 258 then
            return false
        end

        context = libcrypto.EVP_MD_CTX_new()
        if context == nil then return false end
        local key_context = ffi.new("MWL_PKEY_CTX *[1]")
        return libcrypto.EVP_DigestVerifyInit(
                context, key_context, libcrypto.EVP_sha256(), nil, public_key
            ) == 1
            and key_context[0] ~= nil
            and libcrypto.EVP_PKEY_CTX_ctrl_str(
                key_context[0], "rsa_padding_mode", "pkcs1"
            ) == 1
            and libcrypto.EVP_DigestUpdate(context, message, #message) == 1
            and libcrypto.EVP_DigestVerifyFinal(context, decoded, 256) == 1
    end)

    if context ~= nil then libcrypto.EVP_MD_CTX_free(context) end
    if rsa ~= nil then libcrypto.RSA_free(rsa) end
    if public_key ~= nil then libcrypto.EVP_PKEY_free(public_key) end
    if bio ~= nil then libcrypto.BIO_free(bio) end
    return success and verified == true
end

return Crypto
