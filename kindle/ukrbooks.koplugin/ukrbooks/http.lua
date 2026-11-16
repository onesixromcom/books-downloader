--[[--
HTTP helper for KOReader (LuaSocket + LuaSec, as bundled with KOReader).

    local Http = require("ukrbooks/http")
    local body, err = Http.get(url)
    local ok, err = Http.download(url, path)
    local res, err = Http.request{ method = "POST", url = ..., headers = {...}, body = "a=1" }
    -- res = { status = 200, body = "...", headers = {...}, set_cookie = "raw Set-Cookie" }

The provider modules only depend on this interface, so the desktop test runner
can use a curl-based replacement instead.
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

local Http = {}

-- Some sites serve reduced pages (or block) unknown clients, so look like a browser.
Http.USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

local MAX_REDIRECTS = 5

local function absolute(base, loc)
    if loc:match("^https?://") then return loc end
    local scheme_host = base:match("^(https?://[^/]+)")
    if loc:sub(1, 1) == "/" then return scheme_host .. loc end
    return (base:gsub("[^/]*$", "")) .. loc
end

local function describe(code, status, block_timeout, total_timeout)
    local msg = socketutil.describe_error -- missing in older KOReader versions
        and socketutil.describe_error(code, block_timeout, total_timeout)
    return msg or tostring(code or status)
end

--[[--
One request without automatic redirects.
@param opts { method=, url=, headers=, body=, sink= }
@return code, headers, status  or nil, error
]]
local function raw_request(opts, block_timeout, total_timeout)
    local headers = { ["User-Agent"] = Http.USER_AGENT, ["Accept-Language"] = "uk,en;q=0.8" }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    if opts.body then
        headers["Content-Length"] = tostring(#opts.body)
    end
    socketutil:set_timeout(block_timeout, total_timeout)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = opts.url,
        method = opts.method or "GET",
        headers = headers,
        source = opts.body and ltn12.source.string(opts.body) or nil,
        sink = opts.sink,
        redirect = false,
    })
    socketutil:reset_timeout()
    if type(code) ~= "number" then
        logger.warn("ukrbooks: request failed", opts.url, code, status)
        return nil, describe(code, status, block_timeout, total_timeout)
    end
    return code, resp_headers or {}, status
end

--[[--
Performs a GET, following redirects manually (LuaSocket won't follow
http -> https redirects by itself).
@param new_sink function(attempt) returning a fresh LTN12 sink for each attempt,
       so a redirect response body never ends up in the result
]]
local function get_following(url, new_sink, block_timeout, total_timeout)
    for attempt = 1, MAX_REDIRECTS do
        local code, headers = raw_request({ url = url, sink = new_sink(attempt) }, block_timeout, total_timeout)
        if not code then return nil, headers end
        if code >= 300 and code < 400 and headers.location then
            url = absolute(url, headers.location)
        elseif code ~= 200 then
            logger.warn("ukrbooks: HTTP", code, url)
            return nil, "HTTP " .. tostring(code)
        else
            return true
        end
    end
    return nil, "Too many redirects"
end

--- Downloads a URL into memory. Returns body or nil, error.
function Http.get(url)
    logger.dbg("ukrbooks: GET", url)
    local chunks
    local ok, err = get_following(url, function()
        chunks = {}
        return socketutil.table_sink(chunks)
    end, socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    if not ok then return nil, err end
    return table.concat(chunks)
end

--- Downloads a URL into a file. Returns true or nil, error.
function Http.download(url, path)
    logger.dbg("ukrbooks: download", url, "->", path)
    local part = path .. ".part"
    local open_err
    local ok, err = get_following(url, function()
        -- file_sink closes the handle at the end of each response
        local f, ferr = io.open(part, "wb")
        open_err = ferr
        return socketutil.file_sink(f, ferr)
    end, socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    if not ok then
        os.remove(part)
        return nil, open_err or err
    end
    os.remove(path)
    local rok, rerr = os.rename(part, path)
    if not rok then return nil, rerr end
    return true
end

--[[--
Generic request (no redirect following), for session-based sites.
@param opts { method=, url=, headers=, body= }
@return { status=, body=, headers=, set_cookie= } or nil, error
]]
function Http.request(opts)
    logger.dbg("ukrbooks:", opts.method or "GET", opts.url)
    local chunks = {}
    local code, headers = raw_request({
        method = opts.method,
        url = opts.url,
        headers = opts.headers,
        body = opts.body,
        sink = socketutil.table_sink(chunks),
    }, socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    if not code then return nil, headers end
    return {
        status = code,
        body = table.concat(chunks),
        headers = headers,
        set_cookie = headers["set-cookie"],
    }
end

return Http
