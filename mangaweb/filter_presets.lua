-- Shared preset data; pixel processing remains in the two filter modules.
local Presets = {}
local BUILTINS = {
    gray = {
        {id="original",name="原图",black=0,white=255,gamma=1,builtin=true},
        {id="clear",name="清晰",black=40,white=238,gamma=1.20,builtin=true},
        {id="strong",name="强力",black=55,white=228,gamma=1.30,builtin=true},
    },
    tone = {
        {id="original",name="原图",brightness=0,contrast=100,builtin=true},
        {id="clear",name="清晰",brightness=0,contrast=120,builtin=true},
        {id="strong",name="强力",brightness=0,contrast=140,builtin=true},
    },
}
function Presets.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Presets.copy(item) end
    return result
end
local function number(value, low, high, integer)
    value = tonumber(value)
    if not value or value ~= value or value < low or value > high
        or (integer and value ~= math.floor(value)) then return nil end
    return value
end
function Presets.normalize(kind, raw, id)
    if type(raw) ~= "table" or not BUILTINS[kind] then return nil, "invalid_filter_preset" end
    id = raw.id or id
    local name = tostring(raw.name or ""):match("^%s*(.-)%s*$")
    if type(id) ~= "string" or not id:match("^custom%-%d+$")
        or name == "" or #name > 40 or name:find("[%c]") then return nil, "invalid_filter_name" end
    local value = {id=id,name=name,builtin=false}
    if kind == "gray" then
        value.black = number(raw.black,0,254,true)
        value.white = number(raw.white,1,255,true)
        value.gamma = number(raw.gamma,0.1,5,false)
        if not value.black or not value.white or not value.gamma or value.black >= value.white then
            return nil, "invalid_gray_preset"
        end
        value.gamma = math.floor(value.gamma * 100 + 0.5) / 100
    else
        value.brightness = number(raw.brightness,-100,100,true)
        value.contrast = number(raw.contrast,0,200,true)
        if value.brightness == nil or value.contrast == nil then return nil, "invalid_tone_preset" end
    end
    return value
end
function Presets.sanitize(kind, values)
    local result, used = {}, {}
    if type(values) ~= "table" then return result end
    for _, raw in ipairs(values) do
        local value = Presets.normalize(kind,raw)
        if value and not used[value.id] then result[#result+1]=value; used[value.id]=true end
    end
    return result
end
function Presets.valid_list(kind, values)
    if type(values) ~= "table" then return false end
    local used, count = {},0
    for index, raw in pairs(values) do
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #values then return false end
        local value = Presets.normalize(kind,raw)
        if not value or used[value.id] then return false end
        used[value.id]=true; count=count+1
    end
    return count == #values
end
function Presets.all(kind, custom)
    local result = Presets.copy(BUILTINS[kind] or {})
    for _, value in ipairs(Presets.sanitize(kind,custom)) do result[#result+1]=value end
    return result
end
function Presets.find(kind, id, custom)
    for _, value in ipairs(Presets.all(kind,custom)) do if value.id == id then return value end end
end
function Presets.next_id(custom)
    local used = {}
    for _, value in ipairs(custom or {}) do used[value.id]=true end
    local index = 1
    while used["custom-"..index] do index=index+1 end
    return "custom-"..index
end
return Presets
