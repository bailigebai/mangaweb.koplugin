local Crypto = require("mangaweb.license_crypto")
local Device = require("mangaweb.license_device")
local Protocol = require("mangaweb.license_protocol")
local Store = require("mangaweb.license_store")
local Transport = require("mangaweb.license_transport")

local License = {}
License.__index = License

local module_directory = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or ""
local DEFAULT_PUBLIC_KEY = module_directory .. "resources/mangaweb_license_public_key.pem"

local SERVER_ERRORS = {
    invalid_key = true,
    key_bound_to_other_device = true,
    rate_limited = true,
    service_unavailable = true,
}
local TRANSPORT_ERRORS = {
    http_unavailable = true,
    proxy_not_supported = true,
    tls_unavailable = true,
    dns_error = true,
    server_unreachable = true,
    tls_error = true,
    timeout = true,
    response_too_large = true,
    redirect_refused = true,
    server_error = true,
    invalid_response = true,
    network_error = true,
    service_unavailable = true,
    rate_limited = true,
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function read_file(path, limit)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local value = handle:read(limit + 1)
    handle:close()
    if type(value) ~= "string" or #value == 0 or #value > limit then return nil end
    return value
end

local function store_error(code)
    if code == "invalid_json" then return "invalid_local_license" end
    if code == "not_found" then return "not_activated" end
    return "storage_unavailable"
end

local function identity_equal(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    return left.schema_version == right.schema_version
        and left.identity_source == right.identity_source
        and left.fallback_installation_id == right.fallback_installation_id
end

function License:new(dependencies)
    dependencies = dependencies or {}
    local store = dependencies.store or Store:new(dependencies.store_options)
    local device = dependencies.device or Device:new(dependencies.device_options)
    local transport = dependencies.transport or Transport:new(dependencies.transport_options)
    return setmetatable({
        store = store,
        device = device,
        crypto = dependencies.crypto or Crypto,
        protocol = dependencies.protocol or Protocol,
        transport = transport,
        public_key = dependencies.public_key,
        public_key_path = dependencies.public_key_path or DEFAULT_PUBLIC_KEY,
        read_file = dependencies.read_file or read_file,
        generation = 0,
    }, self)
end

function License:_get_public_key()
    if type(self.public_key) == "string" and self.public_key ~= "" then
        return self.public_key
    end
    local success, value = pcall(self.read_file, self.public_key_path, 8192)
    if success and type(value) == "string" and #value > 0 and #value <= 8192 then
        return value
    end
    return nil
end

function License:_resolve_record(record)
    local success, device_id, resolved, code = pcall(self.device.resolve, self.device, record)
    if not success then return nil, nil, "device_unavailable" end
    if not device_id then
        if code == "invalid_identity" then code = "invalid_local_license" end
        return nil, nil, code or "device_unavailable"
    end
    return device_id, resolved
end

function License:_load_record()
    local success, record, code = pcall(self.store.load, self.store)
    if not success then return nil, "storage_unavailable" end
    if not record then return nil, store_error(code) end
    return record
end

function License:_save_record(record)
    local success, saved = pcall(self.store.save, self.store, record)
    if not success or saved ~= true then return nil, "save_failed" end
    return true
end

function License:_verify_record(record)
    local device_id, _, device_code = self:_resolve_record(record)
    if not device_id then return false, device_code end
    if record.receipt == nil then return false, "not_activated" end
    local message, code = self.protocol.validate_receipt(record.receipt, device_id)
    if not message then return false, code end
    local public_key = self:_get_public_key()
    if not public_key then return false, "public_key_unavailable" end
    local success, valid = pcall(
        self.crypto.verify, message, record.receipt.signature, public_key
    )
    if not success or valid ~= true then return false, "invalid_signature" end
    return true, "authorized"
end

function License:is_authorized()
    local record, code = self:_load_record()
    if not record then return false, code end
    return self:_verify_record(record)
end

function License:status()
    local authorized, code = self:is_authorized()
    if authorized then return "authorized", code end
    if code == "not_activated" then return "not_activated", code end
    return "invalid", code
end

function License:_ensure_identity()
    local record, code = self:_load_record()
    if record then
        local device_id, _, device_code = self:_resolve_record(record)
        return device_id, record, device_code
    end
    if code ~= "not_activated" then return nil, nil, code end

    local device_id, new_record, device_code = self:_resolve_record(nil)
    if not device_id then return nil, nil, device_code end
    local saved, save_code = self:_save_record(new_record)
    if not saved then return nil, nil, save_code or "save_failed" end

    local persisted, load_code = self:_load_record()
    if not persisted then return nil, nil, load_code end
    local persisted_id, _, persisted_code = self:_resolve_record(persisted)
    if not persisted_id or persisted_id ~= device_id then
        return nil, nil, persisted_code or "save_failed"
    end
    return persisted_id, persisted
end

local function inert_handle()
    return { cancel = function() end }
end

function License:activate(raw_key, callbacks)
    callbacks = callbacks or {}
    local canonical = self.protocol.normalize_key(raw_key)
    if not canonical then
        if type(callbacks.on_error) == "function" then
            pcall(callbacks.on_error, "invalid_key_format")
        end
        return inert_handle()
    end
    if self.activation ~= nil then
        if type(callbacks.on_error) == "function" then pcall(callbacks.on_error, "activation_busy") end
        return inert_handle()
    end

    self.generation = self.generation + 1
    local state = {
        generation = self.generation,
        canceled = false,
        settled = false,
    }
    self.activation = state

    local external = {}
    local function active()
        return not state.canceled and not state.settled and self.activation == state
    end
    local function cancel_child()
        if state.child and type(state.child.cancel) == "function" then
            pcall(state.child.cancel, state.child)
        end
    end
    local owner = self
    function external:cancel()
        if state.canceled or state.settled then return end
        state.canceled = true
        if owner.activation == state then owner.activation = nil end
        cancel_child()
    end
    state.external = external

    local function finish_error(code)
        if not active() then return end
        state.settled = true
        self.activation = nil
        cancel_child()
        if type(callbacks.on_error) == "function" then pcall(callbacks.on_error, code) end
    end
    local function finish_success()
        if not active() then return end
        state.settled = true
        self.activation = nil
        if type(callbacks.on_success) == "function" then pcall(callbacks.on_success) end
    end

    local device_id, record, identity_code = self:_ensure_identity()
    if not device_id then
        finish_error(identity_code == "save_failed" and "save_failed" or identity_code)
        return external
    end
    local snapshot = copy(record)

    local function restore_and_fail()
        self:_save_record(snapshot)
        finish_error("save_failed")
    end

    local function on_response(response)
        if not active() then return end
        if type(response) ~= "table" then return finish_error("activation_rejected") end
        if response.ok ~= true then
            local code = type(response.error) == "string" and response.error or nil
            return finish_error(SERVER_ERRORS[code] and code or "activation_rejected")
        end

        local message, validation_code = self.protocol.validate_receipt(
            response.receipt, device_id
        )
        if not message then return finish_error(validation_code) end
        local public_key = self:_get_public_key()
        if not public_key then return finish_error("public_key_unavailable") end
        local verified, valid = pcall(
            self.crypto.verify, message, response.receipt.signature, public_key
        )
        if not verified or valid ~= true then return finish_error("invalid_signature") end

        local updated = copy(record)
        updated.receipt = copy(response.receipt)
        local saved, save_code = self:_save_record(updated)
        if not saved then return finish_error(save_code or "save_failed") end

        local authorized = self:is_authorized()
        if authorized ~= true then return restore_and_fail() end
        finish_success()
    end

    local function on_transport_error(code)
        if not active() then return end
        finish_error(TRANSPORT_ERRORS[code] and code or "network_error")
    end

    local requested, child = pcall(
        self.transport.request,
        self.transport,
        { product = self.protocol.PRODUCT_ID, key = canonical, device_id = device_id },
        { on_success = on_response, on_error = on_transport_error }
    )
    if not requested then
        finish_error("network_error")
    elseif type(child) ~= "table" or type(child.cancel) ~= "function" then
        finish_error("http_unavailable")
    elseif state.settled or state.canceled then
        pcall(child.cancel, child)
    else
        state.child = child
    end
    return external
end

function License:cancel()
    local state = self.activation
    if state and state.external then state.external:cancel() end
end

function License:remove_local()
    self:cancel()
    local before, code = self:_load_record()
    if not before then return nil, code end
    local identity_before = {
        schema_version = before.schema_version,
        identity_source = before.identity_source,
        fallback_installation_id = before.fallback_installation_id,
    }
    local clear_ok, cleared, clear_code = pcall(self.store.clear_receipt, self.store)
    if not clear_ok then return nil, "save_failed" end
    if not cleared then return nil, clear_code or "save_failed" end
    local after, load_code = self:_load_record()
    if not after or after.receipt ~= nil or not identity_equal(identity_before, after) then
        return nil, load_code or "save_failed"
    end
    local authorized, status_code = self:is_authorized()
    if authorized or status_code ~= "not_activated" then return nil, "save_failed" end
    return true
end

return License
