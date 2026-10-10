local Auth = require("mangaweb.auth")
local Zero = require("mangaweb.sources.zero")

local values = {}
local settings = {}
function settings:read(key, fallback) return values[key] or fallback end
function settings:write(key, value) values[key] = value; return true end
function settings:flush() return true end
local auth = Auth:new{ settings = settings,
    origins = { zero = "https://www.zerobyw33.com" } }
assert(auth:set_cookie("zero", "session=old"))
assert(auth:headers("zero", "https://www.zerobyw33.com/Android/").Cookie == "session=old")
auth.origins.zero = "https://zero.example.com"
assert(auth:headers("zero", "https://zero.example.com/Android/").Cookie == nil,
    "changing Zero's domain must not send the old site's Cookie to the new host")
local updated_source = Zero:new{ origin = "https://zero.example.com", auth = auth }
updated_source:_merge_set_cookie{ ["set-cookie"] = "new_state=abc" }
assert(auth:cookie("zero") == "new_state=abc",
    "the new host's Set-Cookie must not rebind the previous host's Cookie")
assert(auth:set_cookie("zero", "session=new"))
assert(auth:headers("zero", "https://zero.example.com/Android/").Cookie == "session=new")
assert(auth:headers("zero", "https://other.example.com/").Cookie == nil)

local requested, fallback_url = {}, nil
local source = Zero:new{
    origin = "https://zero.example.com", auth = { clear = function() return true end },
    http = { get = function(_, url, _, callbacks)
        fallback_url = url
        return callbacks.on_error{ code = "network_error" }
    end },
}
source._get = function(_, url, _, callbacks)
    requested[#requested + 1] = url
    return callbacks.on_error{ code = "empty_result" }
end
local outcome
source:login({}, { on_error = function(error) outcome = error end })
assert(#requested == 2 and requested[1]:find("zero.example.com", 1, true)
    and requested[2]:find("zero.example.com", 1, true))
assert(fallback_url == "http://zero.example.com/Android/my/",
    "Zero's anonymous form fallback must follow the edited domain")
assert(outcome.code == "network_error")

print("zero_domain_spec: passed")
