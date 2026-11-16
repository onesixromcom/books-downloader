--[[--
Provider for https://booknet.ua (Yii2 site).

Browsing and book pages are public. Reading (even free books) needs a logged-in
session: the `_identity` cookie, read from identity.txt (and optionally the
`_csrf` cookie from csrf.txt), the same files the bash script uses.

Download protocol (same as providers/booknet.ua in the bash version):
  1. GET /reader/<slug> with cookies -> <meta name="csrf-token">, chapter list
  2. POST /reader/get-page  chapterId=..&page=..&_csrf=<token>
     (+ X-CSRF-Token header, cookies) -> JSON { data = "<html>", totalPages = N }
  3. When a response has no text/totalPages the token has expired or the server
     is throttling us. Retrying right away gets the connection blocked, so:
     wait TOKEN_WAIT (2 minutes), reload the reader page for a fresh token and
     cookies, retry the same page ONCE. If it fails again, stop and save what
     was downloaded as "<name>-incomplete.fb2".
  4. Before downloading, the last chapter is requested once: if it's not
     available the book isn't fully readable for this account (paid).
  5. At least BETWEEN_BOOKS seconds between two book downloads.

Pure Lua: network access goes through the injected `http` object
({get=, download=, request=}), time through opts.now / opts.sleep.
]]

local Cookies = require("ukrbooks/cookies")
local Fb2 = require("ukrbooks/fb2")
local Html = require("ukrbooks/html")
local Json = require("ukrbooks/json")

local BASE = "https://booknet.ua/"

local Provider = {
    id = "booknet",
    name = "Booknet",
    site = "booknet.ua",
    base = BASE,
    page_size = 20,
    needs_login = true,

    TOKEN_WAIT = 140,      -- seconds to wait before refreshing an expired token
    BETWEEN_BOOKS = 60,    -- seconds between two book downloads
    REQUEST_DELAY = 1,     -- seconds between get-page requests
}
Provider.__index = Provider

Provider.ERR_NO_IDENTITY = "Booknet allows reading only for logged-in users, even for free books.\n"
    .. "Put identity.txt (value of the _identity cookie from your browser) into the plugin folder."
Provider.ERR_RESTRICTED = "Booknet says access is restricted (\"Доступ обмежено\").\n"
    .. "identity.txt is probably expired: copy a fresh _identity cookie value into it."

-- shared across instances: when the last book download ended (os.time())
local last_download_end = nil

--[[--
@param http {get=, download=, request=}
@param opts {
  identity = "_identity cookie value" (optional),
  csrf = "_csrf cookie value" (optional),
  setting = function(key, default) -> value (optional),
  sleep = function(seconds), now = function() -> seconds,
}
]]
function Provider.new(http, opts)
    local self = setmetatable({}, Provider)
    self.http = http
    opts = opts or {}
    self.identity = opts.identity ~= "" and opts.identity or nil
    self.csrf = opts.csrf ~= "" and opts.csrf or nil
    self.setting = opts.setting or function(_, default) return default end
    self.now = opts.now or os.time
    self.sleep = opts.sleep or function(s) os.execute("sleep " .. tonumber(s)) end
    return self
end

function Provider:hasLogin()
    return self.identity ~= nil
end

local function absUrl(u)
    if not u or u == "" then return nil end
    u = Html.decodeEntities(u)
    if u:match("^https?://") then return u end
    if u:sub(1, 2) == "//" then return "https:" .. u end
    if u:sub(1, 1) == "/" then return BASE .. u:sub(2) end
    return BASE .. u
end

function Provider:fetch(url)
    local body, err = self.http.get(url)
    if not body then return nil, err or "network error" end
    if #body < 200 then return nil, "empty response" end
    return body
end

-- Listings -------------------------------------------------------------------

local function priceInfo(price_text)
    if not price_text or price_text == "" then return nil, nil end
    if price_text:find("Безкоштовно", 1, true) then return "Безкоштовно", true end
    local amount = price_text:match("(%d+%s*грн)")
    return amount or price_text, false
end

-- Splits html into chunks, each starting at a plain-text marker.
local function splitCards(html, marker)
    local cards = {}
    local pos = 1
    while true do
        local s = html:find(marker, pos, true)
        if not s then break end
        local next_s = html:find(marker, s + 1, true)
        cards[#cards + 1] = html:sub(s, (next_s or #html + 1) - 1)
        pos = s + 1
    end
    return cards
end

--- Parses genre listing cards (/top/...) and search result cards (/search?...).
function Provider.parseCards(html)
    local items, seen = {}, {}
    local function add(item)
        if item.url and not seen[item.url] then
            seen[item.url] = true
            items[#items + 1] = item
        end
    end

    -- genre listing: <div class="bn_book-genre__wrapper">
    for _, card in ipairs(splitCards(html, 'class="bn_book-genre__wrapper"')) do
        local url, title = card:match('<a href="(/book/[^"]+)" class="bn_book%-genre__title%-link">(.-)</a>')
        if url then
            local item = { url = absUrl(url), title = Html.cleanText(title) }
            local author = card:match('class="bn_book%-genre__author[^"]*">%s*<a[^>]*>(.-)</a>')
            item.author = author and Html.cleanText(author) or nil
            item.cover = absUrl(card:match('<img src="([^"]+)"'))
            local price = card:match('class="bn_book%-genre__price">(.-)</div>')
            item.price, item.free = priceInfo(price and Html.cleanText(price))
            local status = card:match('class="bn_book%-genre__status%-content">(.-)</div>')
            local pages = card:match('class="bn_book%-genre__status%-pages">(.-)</div>')
            item.status = status and Html.cleanText(status) or nil
            item.pages = pages and Html.cleanText(pages) or nil
            local annotation = card:match('class="bn_book%-genre__annotation[^"]*">(.-)</div>')
            item.annotation = annotation and Html.cleanText(annotation) or nil
            item.badge = item.price
            add(item)
        end
    end

    -- search results: <div class="bn_book-row__vert-item">
    for _, card in ipairs(splitCards(html, 'class="bn_book-row__vert-item"')) do
        local url, title = card:match('class="bn_book%-row__vert%-item%-title[^"]*">%s*<a href="(/book/[^"]+)">(.-)</a>')
        if url then
            local item = { url = absUrl(url), title = Html.cleanText(title) }
            local author = card:match('class="bn_book%-row__vert%-item%-author[^"]*">%s*<a[^>]*>(.-)</a>')
            item.author = author and Html.cleanText(author) or nil
            item.cover = absUrl(card:match('<img src="([^"]+)"'))
            local status = card:match('class="bn_book%-row__vert%-item%-content%-status[^"]*">.-<span>(.-)</span>')
            item.status = status and Html.cleanText(status) or nil
            item.badge = item.status and item.status:match("(%d+ стор%.)") or nil
            add(item)
        end
    end
    return items
end

function Provider:fetchListing(url, page)
    local html, err = self:fetch(url)
    if not html then return nil, err end
    local items = Provider.parseCards(html)
    local has_more = #items > 0 and html:find("page=" .. (page + 1) .. '"', 1, true) ~= nil
    if self.setting("free_only", true) then
        local free = {}
        for _, it in ipairs(items) do
            if it.free ~= false then free[#free + 1] = it end -- unknown price is kept
        end
        items = free
    end
    return { items = items, has_more = has_more }
end

local function topUrl(id, page)
    local url = BASE .. "top/" .. id
    if page and page > 1 then url = url .. "?page=" .. page end
    return url
end

function Provider:latest(page)
    page = page or 1
    return self:fetchListing(topUrl("latest-new", page), page)
end

function Provider:category(id, page)
    page = page or 1
    return self:fetchListing(topUrl(id, page), page)
end

function Provider:search(query, page)
    page = page or 1
    local url = BASE .. "search?q=" .. Html.urlEncode(query) .. "&type=book"
    if page > 1 then url = url .. "&page=" .. page end
    return self:fetchListing(url, page)
end

-- Not supported (author pages have a different layout); the UI hides the button.
function Provider:byUrl()
    return nil, "not supported"
end

--- Genre list from the site menu: {id=, title=}.
function Provider:categories()
    if self._categories then return self._categories end
    local html, err = self:fetch(BASE)
    if not html then return nil, err end
    local cats, seen = {}, { ["latest-new"] = true } -- "Новинки" is the "New books" item
    for slug, name in html:gmatch('<a[^>]-href="/top/([%w_%-]+)"[^>]*>(.-)</a>') do
        local title = Html.cleanText(name)
        if not seen[slug] and title ~= "" then
            seen[slug] = true
            cats[#cats + 1] = { id = slug, title = title }
        end
    end
    if #cats == 0 then return nil, "no categories found" end
    self._categories = cats
    return cats
end

-- Book details ---------------------------------------------------------------

local function bookSlug(url)
    return url:match("booknet%.ua/book/([^/?#]+)") or url:match("booknet%.ua/reader/([^/?#]+)")
end

function Provider.fileBase(url)
    local slug = bookSlug(url) or "book"
    slug = slug:gsub("[^%w%-_]", "")
    if slug == "" then slug = "book" end
    return slug:sub(1, 120)
end

local function paragraphs(html)
    local list = {}
    if not html then return list end
    html = html:gsub("<br%s*/?>", "\n")
    for p in (Html.decodeEntities2(html:gsub("<[^>]*>", "")) .. "\n"):gmatch("(.-)\n") do
        p = Html.squash(Html.stripEmoji(p))
        if p ~= "" then list[#list + 1] = p end
    end
    return list
end

function Provider.parseBook(html, url)
    local slug = bookSlug(url)
    local book = {
        url = BASE .. "book/" .. slug,
        reader_url = BASE .. "reader/" .. slug,
        authors = {}, chapters = {}, annotation = {}, extra = {},
    }
    local h1 = html:match('class="bn_book__header%-title[^"]*">(.-)</h1>')
    if h1 then
        h1 = h1:gsub('<span class="bn_book__header%-adult%-only.-</span>', "")
        book.title = Html.cleanText(h1)
    end
    if not book.title or book.title == "" then
        local og = html:match('<meta property="og:title" content="([^"]*)"')
        book.title = og and Html.cleanText(og) or nil
    end
    book.adult = html:find('class="bn_book__header-adult-only', 1, true) ~= nil

    for name in html:gmatch('class="bn_book__header%-author%-item%-name[^"]*">%s*<a[^>]*>(.-)</a>') do
        book.authors[#book.authors + 1] = Html.cleanText(name)
    end
    local genres = {}
    for name in html:gmatch('class="bn_book__header%-genre%s[^"]*"[^>]*>(.-)</a>') do
        genres[#genres + 1] = Html.cleanText(name)
    end
    book.genre = table.concat(genres, " / ")

    local status = html:match('class="bn_book__header%-status%-value">(.-)</span>')
    local count = html:match('class="bn_book__header%-status%-count">(.-)</span>')
    if status then
        status = Html.cleanText(status):gsub("%s*·%s*$", "")
        book.status = count and (status .. " · " .. Html.cleanText(count)) or status
    end

    book.cover = absUrl(html:match('class="bn_book__header%-image%-src" src="([^"]+)"'))
    book.annotation = paragraphs(html:match('class="bn_book__about%-content[^"]*">(.-)</div>'))

    local buy = html:match('class="bn_buy%-button__text">(.-)</span>%s*</a>')
        or html:match('class="bn_buy%-button__text">(.-)</a>')
    if buy then
        book.price, book.free = priceInfo(Html.cleanText(buy))
    else
        book.price, book.free = "Безкоштовно", true
    end

    for id, rest in html:gmatch('href="/reader/[^"?]+%?c=(%d+)" class="bn_book__chapters%-item%-link"></a>(.-)</span>') do
        local title = rest:match('class="bn_book__chapters%-item%-title[^"]*">(.*)$')
        book.chapters[#book.chapters + 1] = { id = id, title = title and Html.cleanText(title) or "" }
    end
    return book
end

function Provider:getBook(url, hint)
    if not bookSlug(url) then return nil, "not a booknet book URL" end
    local html, err = self:fetch(BASE .. "book/" .. bookSlug(url))
    if not html then return nil, err end
    local book = Provider.parseBook(html, url)
    if not book.title or book.title == "" then
        return nil, "can't parse book page"
    end
    if #book.authors == 0 and hint and hint.author then
        book.authors[1] = hint.author
    end
    if book.status then book.extra[#book.extra + 1] = book.status end
    book.extra[#book.extra + 1] = book.free and "Безкоштовно" or ("Платна: " .. tostring(book.price))
    book.extra[#book.extra + 1] = "Chapters: " .. #book.chapters
    if not self:hasLogin() then
        book.can_download = false
        book.download_note = Provider.ERR_NO_IDENTITY
    elseif #book.chapters == 0 then
        book.can_download = false
        book.download_note = "No chapters found."
    else
        book.can_download = true
        if not book.free then
            book.download_note = "Paid book: only works if you bought it with this account."
        end
    end
    return book
end

-- Reader session -------------------------------------------------------------

function Provider:newSession(reader_url)
    local jar = Cookies.new()
    if self.csrf then jar:set("_csrf", self.csrf) end
    jar:set("_identity", self.identity)
    return { jar = jar, reader_url = reader_url }
end

--- (Re)loads the reader page: fresh CSRF token and cookies.
function Provider:refresh(s)
    local res, err = self.http.request{
        method = "GET",
        url = s.reader_url,
        headers = {
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Cache-Control"] = "no-cache",
            ["Pragma"] = "no-cache",
            ["Cookie"] = s.jar:header(),
        },
    }
    if not res then return nil, err end
    s.jar:update(res.set_cookie)
    if res.status ~= 200 then return nil, "reader page: HTTP " .. tostring(res.status) end
    local html = res.body or ""
    if html:find("<title>%s*Доступ обмежено") then
        return nil, Provider.ERR_RESTRICTED
    end
    local token = html:match('<meta name="csrf%-token" content="([^"]+)"')
    if not token then return nil, "no CSRF token on the reader page" end
    s.token = Html.decodeEntities(token)
    -- chapter list of the reader (authoritative, as in book.sh)
    local select_html = html:match('<select[^>]-js%-chapter%-change[^>]*>(.-)</select>')
    if select_html then
        s.chapters = {}
        for attrs, title in select_html:gmatch("<option([^>]*)>(.-)</option>") do
            local id = attrs:match('value="(%d+)"')
            if id then s.chapters[#s.chapters + 1] = { id = id, title = Html.cleanText(title) } end
        end
    end
    return true
end

--- Requests one page of a chapter. Returns {text=, total=} or nil, reason.
function Provider:getPage(s, chapter_id, page)
    local body = "chapterId=" .. Html.urlEncode(tostring(chapter_id))
        .. "&page=" .. page
        .. "&_csrf=" .. Html.urlEncode(s.token or "")
    local res, err = self.http.request{
        method = "POST",
        url = BASE .. "reader/get-page",
        body = body,
        headers = {
            ["Accept"] = "application/json, text/javascript, */*; q=0.01",
            ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
            ["Cache-Control"] = "no-cache",
            ["Pragma"] = "no-cache",
            ["Origin"] = "https://booknet.ua",
            ["Referer"] = s.reader_url,
            ["X-CSRF-Token"] = s.token,
            ["X-Requested-With"] = "XMLHttpRequest",
            ["Cookie"] = s.jar:header(),
        },
    }
    if not res then return nil, err end
    s.jar:update(res.set_cookie)
    if res.status ~= 200 then return nil, "HTTP " .. tostring(res.status) end
    local data = Json.decode(res.body)
    if type(data) ~= "table" then return nil, "invalid response" end
    local total = tonumber(data.totalPages)
    if data.status == 0 or type(data.data) ~= "string" or (page == 1 and not total) then
        local msg = type(data.data) == "string" and Html.cleanText(data.data) or "no text"
        return nil, msg ~= "" and msg or "no text"
    end
    return { text = data.data, total = total or 1 }
end

-- Download -------------------------------------------------------------------

local function sniffImageType(data)
    if not data then return nil end
    if data:sub(1, 3) == "\255\216\255" then return "image/jpeg", "jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png", "png" end
    if data:sub(1, 4) == "GIF8" then return "image/gif", "gif" end
    return nil
end

--- Waits `seconds` while reporting a countdown. Returns false if cancelled.
function Provider:wait(seconds, progress, done, total, fmt)
    local deadline = self.now() + seconds
    while true do
        local left = deadline - self.now()
        if left <= 0 then return true end
        if progress(done, total, string.format(fmt, math.floor(left / 60), left % 60)) == false then
            return false
        end
        self.sleep(math.min(1, left))
    end
end

function Provider:pause()
    if self.REQUEST_DELAY > 0 then self.sleep(self.REQUEST_DELAY) end
end

--- get-page with the token recovery described at the top of this file.
-- Returns page, or nil, err ("cancelled" if the user cancelled the wait).
function Provider:getPageWithRecovery(s, chapter_id, page, progress, done, total)
    local res, err = self:getPage(s, chapter_id, page)
    if res then return res end
    local ok = self:wait(Provider.TOKEN_WAIT, progress, done, total,
        "The site refused the request (" .. tostring(err):sub(1, 60) .. ").\n"
        .. "Waiting %d:%02d for the token to expire, then retrying once…")
    if not ok then return nil, "cancelled" end
    local rok, rerr = self:refresh(s)
    if not rok then return nil, rerr end
    self:pause()
    res, err = self:getPage(s, chapter_id, page)
    if res then return res end
    return nil, err
end

--[[--
Downloads a book to `dir`.
@param progress function(done, total, text) -> false to cancel
@return path, warning  (warning is set for an incomplete book), or nil, err
]]
function Provider:download(book, dir, progress)
    progress = progress or function() return true end
    if not self:hasLogin() then return nil, Provider.ERR_NO_IDENTITY end

    if last_download_end then
        local left = Provider.BETWEEN_BOOKS - (self.now() - last_download_end)
        if left > 0 and not self:wait(left, progress, 0, 1, "Pause between books: %d:%02d…") then
            return nil, "cancelled"
        end
    end

    local function finished(...)
        last_download_end = self.now()
        return ...
    end

    local s = self:newSession(book.reader_url)
    progress(0, 1, "Opening the reader…")
    local ok, err = self:refresh(s)
    if not ok then return finished(nil, err) end

    local chapters = (s.chapters and #s.chapters > 0) and s.chapters or book.chapters
    if not chapters or #chapters == 0 then return finished(nil, "No chapters found.") end
    local total = #chapters

    -- Is the whole book readable for this account? (as book.sh does)
    progress(0, total, "Checking that all chapters are available…")
    self:pause()
    local check, cerr = self:getPage(s, chapters[total].id, 1)
    if not check then
        return finished(nil, "The last chapter is not available: " .. tostring(cerr)
            .. "\n\nThe book is probably paid (not bought with this account).")
    end

    local base = dir:gsub("/$", "") .. "/" .. Provider.fileBase(book.url)
    local path = base .. ".fb2"

    local cover_data, cover_type, cover_ext
    if book.cover then
        cover_data = self.http.get(book.cover)
        cover_type, cover_ext = sniffImageType(cover_data)
        if not cover_type then cover_data = nil end
    end

    local writer, werr = Fb2.Writer(path, {
        title = book.title,
        authors = book.authors,
        genre = "prose",
        annotation = book.annotation,
        lang = "uk",
        source_url = book.url,
        cover_id = cover_data and ("cover." .. cover_ext) or nil,
    })
    if not writer then return finished(nil, werr) end

    local images = {}
    local image_ids = {}
    local conv = Fb2.Converter{
        headings_as_subtitles = true,
        on_image = function(src)
            local url = absUrl(src)
            if not url or not url:match("^https?://") or url:find("facebook", 1, true) then return nil end
            if not image_ids[url] then
                images[#images + 1] = url
                image_ids[url] = "img" .. #images
            end
            return image_ids[url]
        end,
    }

    local stopped -- reason the download stopped early
    local chapters_done = 0
    for ci, ch in ipairs(chapters) do
        if progress(ci - 1, total, string.format("Chapter %d of %d", ci, total)) == false then
            stopped = "cancelled"
            break
        end
        writer:write(conv:startSection(ch.title))
        local page, pages = 1, 1
        while page <= pages do
            self:pause()
            local res, perr = self:getPageWithRecovery(s, ch.id, page, progress, ci - 1, total)
            if not res then
                stopped = perr
                break
            end
            if page == 1 then pages = math.max(1, res.total) end
            writer:write(conv:feed(res.text))
            page = page + 1
            if page <= pages and progress(ci - 1, total,
                    string.format("Chapter %d of %d, page %d of %d", ci, total, page, pages)) == false then
                stopped = "cancelled"
                break
            end
        end
        if stopped then break end
        chapters_done = ci
    end
    writer:write(conv:finish())

    if stopped and chapters_done == 0 then
        -- nothing useful downloaded: don't leave an empty "incomplete" book
        writer:abort()
        return finished(nil, stopped)
    end
    if stopped then
        writer:write(conv:startSection(""))
        writer:write("<p>[Завантаження перервано: збережено розділів " .. chapters_done
            .. " з " .. total .. ".]</p>")
    end

    -- images: in the order they appeared; stop fetching them if cancelled
    local binaries = {}
    if cover_data then
        binaries[1] = { id = "cover." .. cover_ext, content_type = cover_type, data = cover_data }
    end
    for i, url in ipairs(images) do
        if progress(total, total, string.format("Images %d of %d", i, #images)) == false then break end
        local data = self.http.get(url)
        local ctype = sniffImageType(data)
        if ctype then
            binaries[#binaries + 1] = { id = image_ids[url], content_type = ctype, data = data }
        end
    end

    -- An incomplete book gets its own name, so it never replaces a complete
    -- copy downloaded earlier.
    local final, cerr2 = writer:close(binaries, stopped and (base .. "-incomplete.fb2") or nil)
    if not final then return finished(nil, cerr2) end
    if stopped then
        return finished(final, string.format("Incomplete book: %d of %d chapters (%s).",
            chapters_done, total, tostring(stopped)))
    end
    return finished(final)
end

return Provider
