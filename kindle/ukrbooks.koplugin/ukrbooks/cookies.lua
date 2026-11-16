--[[--
Minimal cookie jar (plain Lua 5.1): enough for one site session.

    local jar = Cookies.new{ _identity = "..." }
    jar:update(set_cookie_header)  -- raw Set-Cookie value(s)
    headers.Cookie = jar:header()
]]

local Cookies = {}
Cookies.__index = Cookies

function Cookies.new(initial)
    local self = setmetatable({ values = {}, order = {} }, Cookies)
    for k, v in pairs(initial or {}) do
        self:set(k, v)
    end
    return self
end

function Cookies:set(name, value)
    if value == nil then
        self.values[name] = nil
        return
    end
    if self.values[name] == nil then
        self.order[#self.order + 1] = name
    end
    self.values[name] = value
end

function Cookies:get(name)
    return self.values[name]
end

--- Splits a Set-Cookie header into single cookies.
-- LuaSocket joins repeated Set-Cookie headers with ", ", and Expires dates
-- contain ", " too ("Wed, 21 Oct 2026 ..."). A new cookie starts after a comma
-- that is followed by "name=" (no spaces in the name).
function Cookies.split(header)
    local list = {}
    if not header or header == "" then return list end
    header = "," .. header
    local starts = {}
    local pos = 1
    while true do
        local s, e = header:find(",%s*[%w!#%$%%&'%*%+%-%.%^_`|~]+=", pos)
        if not s then break end
        starts[#starts + 1] = { s, e }
        pos = e + 1
    end
    for i, st in ipairs(starts) do
        local cookie_start = header:find("[^,%s]", st[1])
        local cookie_end = starts[i + 1] and starts[i + 1][1] - 1 or #header
        list[#list + 1] = header:sub(cookie_start, cookie_end)
    end
    return list
end

--- Applies Set-Cookie header(s). Accepts a string or a list of strings.
function Cookies:update(set_cookie)
    if not set_cookie then return end
    local headers = type(set_cookie) == "table" and set_cookie or { set_cookie }
    for _, h in ipairs(headers) do
        for _, c in ipairs(Cookies.split(h)) do
            local name, value = c:match("^%s*([^=;%s]+)=([^;]*)")
            if name then
                local lower = c:lower()
                local expired = lower:find("max%-age=0[;%s]") or lower:find("max%-age=0$")
                    or value == "deleted"
                if expired then
                    self:set(name, nil)
                else
                    self:set(name, value)
                end
            end
        end
    end
end

--- Value for the Cookie request header.
function Cookies:header()
    local parts = {}
    for _, name in ipairs(self.order) do
        local v = self.values[name]
        if v ~= nil then parts[#parts + 1] = name .. "=" .. v end
    end
    return table.concat(parts, "; ")
end

return Cookies
