--[[--
Minimal JSON decoder (plain Lua 5.1), so the providers don't depend on
KOReader's JSON module and can be tested on a desktop.
Returns nil, error on invalid input. JSON null becomes nil.
]]

local Html = require("ukrbooks/html")

local Json = {}

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local decode_value

local function skip(s, i)
    return s:find("[^ \t\r\n]", i) or #s + 1
end

local function decode_string(s, i)
    -- s:sub(i, i) == '"'
    local out = {}
    local pos = i + 1
    while true do
        local q = s:find('["\\]', pos)
        if not q then error("unterminated string") end
        out[#out + 1] = s:sub(pos, q - 1)
        if s:sub(q, q) == '"' then
            return table.concat(out), q + 1
        end
        local c = s:sub(q + 1, q + 1)
        if c == "u" then
            local cp = tonumber(s:sub(q + 2, q + 5), 16)
            if not cp then error("bad \\u escape") end
            local next_pos = q + 6
            -- surrogate pair
            if cp >= 0xD800 and cp <= 0xDBFF and s:sub(next_pos, next_pos + 1) == "\\u" then
                local lo = tonumber(s:sub(next_pos + 2, next_pos + 5), 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    next_pos = next_pos + 6
                end
            end
            out[#out + 1] = Html.utf8char(cp)
            pos = next_pos
        else
            local e = escapes[c]
            if not e then error("bad escape") end
            out[#out + 1] = e
            pos = q + 2
        end
    end
end

local function decode_array(s, i)
    local arr = {}
    local pos = skip(s, i + 1)
    if s:sub(pos, pos) == "]" then return arr, pos + 1 end
    while true do
        local v
        v, pos = decode_value(s, pos)
        arr[#arr + 1] = v
        pos = skip(s, pos)
        local c = s:sub(pos, pos)
        if c == "]" then return arr, pos + 1 end
        if c ~= "," then error("expected , or ]") end
        pos = skip(s, pos + 1)
    end
end

local function decode_object(s, i)
    local obj = {}
    local pos = skip(s, i + 1)
    if s:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
        if s:sub(pos, pos) ~= '"' then error("expected key") end
        local key
        key, pos = decode_string(s, pos)
        pos = skip(s, pos)
        if s:sub(pos, pos) ~= ":" then error("expected :") end
        local v
        v, pos = decode_value(s, skip(s, pos + 1))
        obj[key] = v
        pos = skip(s, pos)
        local c = s:sub(pos, pos)
        if c == "}" then return obj, pos + 1 end
        if c ~= "," then error("expected , or }") end
        pos = skip(s, pos + 1)
    end
end

decode_value = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then return decode_object(s, i) end
    if c == "[" then return decode_array(s, i) end
    if c == '"' then return decode_string(s, i) end
    if s:sub(i, i + 3) == "true" then return true, i + 4 end
    if s:sub(i, i + 4) == "false" then return false, i + 5 end
    if s:sub(i, i + 3) == "null" then return nil, i + 4 end
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if num and num ~= "" then return tonumber(num), i + #num end
    error("unexpected character at " .. i)
end

function Json.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local ok, res = pcall(decode_value, s, 1)
    if not ok then return nil, res end
    return res
end

return Json
