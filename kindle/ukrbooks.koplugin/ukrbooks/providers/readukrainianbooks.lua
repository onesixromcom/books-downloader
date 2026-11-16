--[[--
Provider for https://readukrainianbooks.com (DataLife Engine site).

Pure Lua: network access goes through the injected `http` object
({get=function(url) -> body|nil,err, download=function(url, path) -> ok|nil,err}),
so the module can be tested on a desktop.

Site facts this relies on:
  * listings (home, category, author, search) all use the same card markup:
    <div class="short-item"> ... <a class="short-title" href=URL>Title, Author</a> ...
  * 5 cards per page; category paging: /<slug>/page/N/
  * search: /index.php?do=search&subaction=search&story=Q&search_start=N
  * book page: page list in <select> (page-N-<id>-<slug>.html), text in <div id="texts">
  * some books ("Блог") offer direct FB2/EPUB files in <div class="btns_download">,
    and keep their text in <article itemprop="articleBody">
]]

local Html = require("ukrbooks/html")
local Fb2 = require("ukrbooks/fb2")

local BASE = "https://readukrainianbooks.com/"

local Provider = {
    id = "readukrainianbooks",
    name = "ReadUkrainianBooks",
    site = "readukrainianbooks.com",
    base = BASE,
    page_size = 5,
}
Provider.__index = Provider

function Provider.new(http, opts)
    local self = setmetatable({}, Provider)
    self.http = http
    self.opts = opts or {}
    -- pause between page requests during a book download, in seconds
    self.delay = self.opts.delay or 0.3
    self.sleep = self.opts.sleep -- function(seconds), optional
    return self
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

--- Parses all book cards in a listing page.
function Provider.parseCards(html)
    local items = {}
    local seen = {}
    local pos = 1
    while true do
        local s = html:find('class="short-item"', pos, true)
        if not s then break end
        local next_s = html:find('class="short-item"', s + 1, true)
        local card = html:sub(s, (next_s or #html + 1) - 1)
        pos = s + 1

        local url, raw_title = card:match('class="short%-title[^"]*"%s+href="([^"]+)"[^>]*>(.-)</a>')
        if url and not seen[url] then
            seen[url] = true
            local item = { url = absUrl(url) }
            local title = Html.cleanText(raw_title)
            local author_url, author = card:match('href="([^"]*/xfsearch/author/[^"]*)"[^>]*>(.-)</a>')
            if author then
                item.author = Html.cleanText(author)
                item.author_url = absUrl(author_url)
                -- "Title, Author" -> "Title"
                local suffix = ", " .. item.author
                if #title > #suffix and title:sub(-#suffix) == suffix then
                    title = title:sub(1, -#suffix - 1)
                end
            end
            item.title = title
            item.cover = absUrl(card:match('data%-src="([^"]+)"') or card:match('<img[^>]-src="([^"]+)"'))
            local label = card:match('class="short%-label">(.-)</div>')
            item.genre = label and Html.cleanText(label) or nil
            local views = card:match('fa%-eye"></span>%s*([%d%s\194\160]+)')
            item.views = views and Html.squash(views) or nil
            item.date = card:match('fa%-calendar%-alt"></span>%s*([%d%.]+)')
            items[#items + 1] = item
        end
    end
    return items
end

--- Fetches a listing page and wraps the result.
-- @param has_more_fn function(html) -> boolean
function Provider:fetchListing(url, has_more_fn)
    local html, err = self:fetch(url)
    if not html then return nil, err end
    local items = Provider.parseCards(html)
    return { items = items, has_more = #items > 0 and has_more_fn(html) or false }
end

local function pagedUrl(base_url, page)
    if not page or page <= 1 then return base_url end
    return base_url .. "page/" .. page .. "/"
end

local function hasPageLink(page)
    return function(html)
        return html:find("/page/" .. (page + 1) .. '/"', 1, true) ~= nil
    end
end

--- Latest books (home page). Returns {items=, has_more=} or nil, err.
function Provider:latest(page)
    page = page or 1
    return self:fetchListing(pagedUrl(BASE, page), hasPageLink(page))
end

--- Books of a category (id = slug).
function Provider:category(id, page)
    page = page or 1
    return self:fetchListing(pagedUrl(BASE .. id .. "/", page), hasPageLink(page))
end

--- Books by URL of an author page (from item.author_url).
function Provider:byUrl(url, page)
    page = page or 1
    if url:sub(-1) ~= "/" then url = url .. "/" end
    return self:fetchListing(pagedUrl(url, page), hasPageLink(page))
end

function Provider:search(query, page)
    page = page or 1
    local url = BASE .. "index.php?do=search&subaction=search&full_search=0"
        .. "&story=" .. Html.urlEncode(query)
        .. "&search_start=" .. page
        .. "&result_from=" .. ((page - 1) * Provider.page_size + 1)
    return self:fetchListing(url, function(html)
        return html:find("list_submit(" .. (page + 1) .. ")", 1, true) ~= nil
    end)
end

--- Category list from the site menu. Returns list of {id=, title=}.
function Provider:categories()
    if self._categories then return self._categories end
    local html, err = self:fetch(BASE)
    if not html then return nil, err end
    local cats, seen_id, seen_title = {}, {}, {}
    -- menu entries are marked with blue/yellow hearts: <a href=".../slug/">💙 Name</a>
    for slug, name in html:gmatch('<a href="https://readukrainianbooks%.com/([%w_%-]+)/">\240\159\146[\153\155]%s*([^<]+)</a>') do
        if not seen_id[slug] then
            seen_id[slug] = true
            local title = Html.cleanText(name)
            if seen_title[title] then
                title = title .. " (" .. slug .. ")"
            end
            seen_title[title] = true
            cats[#cats + 1] = { id = slug, title = title }
        end
    end
    if html:find('href="/blog/"', 1, true) or html:find(BASE .. 'blog/"', 1, true) then
        cats[#cats + 1] = { id = "blog", title = "Блог" }
    end
    if #cats == 0 then return nil, "no categories found" end
    self._categories = cats
    return cats
end

-- Book details ---------------------------------------------------------------

local function paragraphs(html)
    local list = {}
    if not html then return list end
    html = html:gsub("<br%s*/?>", "</p><p>")
    for p in (html .. "</p>"):gmatch("(.-)</p>") do
        local t = Html.cleanText(p)
        -- skip the site's self-promotion paragraphs
        if t and t ~= "" and not t:lower():find("readukrainianbooks", 1, true) then
            list[#list + 1] = t
        end
    end
    return list
end

--- Parses a book page.
function Provider.parseBook(html, url)
    local book = { url = url, authors = {}, pages = {}, direct = {} }

    local h1 = html:match('<h1[^>]*class="short%-title[^"]*"[^>]*>(.-)</h1>') or html:match("<h1[^>]*>(.-)</h1>")
    local title = Html.cleanText(h1 or "")
    -- 'Читати книгу - "Title, Author"' / 'Читати статтю - "..."'
    title = title:gsub('^[^"]-%- "', ""):gsub('"$', "")
    book.title = title

    local meta = html:match('<ul class="short%-list">(.-)</ul>') or ""
    for href, name in meta:gmatch('<a href="([^"]*/xfsearch/author/[^"]*)">(.-)</a>') do
        book.authors[#book.authors + 1] = Html.cleanText(name)
        book.author_url = book.author_url or absUrl(href)
    end
    local genres = {}
    local genre_li = meta:match('fa%-book.-</li>') or ""
    for name in genre_li:gmatch("<a[^>]*>(.-)</a>") do
        genres[#genres + 1] = Html.cleanText(name)
    end
    book.genre = table.concat(genres, " / ")
    -- "Title, Author" -> "Title"
    if book.authors[1] then
        local suffix = ", " .. book.authors[1]
        if #book.title > #suffix and book.title:sub(-#suffix) == suffix then
            book.title = book.title:sub(1, -#suffix - 1)
        end
    end

    local fimg = html:match('<div class="fimg[^"]*">%s*(<img[^>]+>)')
    if fimg then
        book.cover = absUrl(Html.attr(fimg, "data-src") or Html.attr(fimg, "src"))
    end

    local annotation = Html.extractInner(html, '<div class="shortstory-text"')
        or html:match('<article itemprop="articleBody">(.-)</article>')
    book.annotation = paragraphs(annotation)

    local downloads = Html.extractInner(html, '<div class="btns_download"') or ""
    for href in downloads:gmatch('href="([^"]+)"') do
        local ext = href:match("%.(%w+)$")
        if ext then book.direct[ext:lower()] = absUrl(href) end
    end

    local seen = {}
    for page_url in html:gmatch('<option[^>]-value="(https?://[^"]-/page%-%d+%-[^"]+)"') do
        if not seen[page_url] then
            seen[page_url] = true
            book.pages[#book.pages + 1] = page_url
        end
    end

    book.has_text = html:find('<div id="texts"', 1, true) ~= nil
        or html:find('itemprop="articleBody"', 1, true) ~= nil
    return book
end

--- Fetches and parses a book page.
-- @param hint optional listing item ({author=}); blog pages have no author link
function Provider:getBook(url, hint)
    local html, err = self:fetch(url)
    if not html then return nil, err end
    local book = Provider.parseBook(html, url)
    if not book.title or book.title == "" then
        return nil, "can't parse book page"
    end
    if #book.authors == 0 and hint and hint.author and hint.author ~= "" then
        book.authors[1] = hint.author
        book.author_url = hint.author_url
        local suffix = ", " .. hint.author
        if #book.title > #suffix and book.title:sub(-#suffix) == suffix then
            book.title = book.title:sub(1, -#suffix - 1)
        end
    end
    book._html = html -- reuse for single-page books
    -- generic fields used by the browser
    book.extra = {}
    if book.direct.fb2 then
        book.extra[1] = "Ready FB2 file available on the site."
    elseif #book.pages > 0 then
        book.extra[1] = "Pages on the site: " .. #book.pages
    end
    book.can_download = (book.direct.fb2 or book.has_text) and true or false
    if not book.can_download then
        book.download_note = "No book text found on this page."
    end
    return book
end

--- Extracts the book text of one page as HTML.
function Provider.pageText(html)
    return Html.extractInner(html, '<div id="texts"')
end

-- Download -------------------------------------------------------------------

--- Builds an ASCII file name from the URL slug ("12854-gajdamaki-taras.html" -> "gajdamaki-taras").
function Provider.fileBase(url)
    local slug = url:match("/([^/]+)%.html") or "book"
    slug = slug:gsub("^page%-%d+%-", ""):gsub("^%d+%-", "")
    slug = slug:gsub("[^%w%-_]", "")
    if slug == "" then slug = "book" end
    return slug:sub(1, 120)
end

--- The site's own FB2 files sometimes have an empty <author>; fill it in.
local function fixDirectFb2Author(path, author)
    if not author or author == "" then return end
    local f = io.open(path, "rb")
    if not f then return end
    local data = f:read("*a")
    f:close()
    local head_end = data:find("</title-info>", 1, true)
    if not head_end then return end
    local head = data:sub(1, head_end)
    local s, e = head:find("<author>%s*<first%-name>%s*</first%-name>%s*<last%-name>%s*</last%-name>%s*</author>")
    if not s then return end
    local first, last = author:match("^(.*)%s+(%S+)$")
    if not first then first, last = "", author end
    local tmp = path .. ".tmp"
    f = io.open(tmp, "wb")
    if not f then return end
    f:write(data:sub(1, s - 1), "<author><first-name>", Fb2.escape(first), "</first-name><last-name>",
        Fb2.escape(last), "</last-name></author>", data:sub(e + 1))
    f:close()
    os.remove(path)
    os.rename(tmp, path)
end

local function sniffImageType(data)
    if not data then return nil end
    if data:sub(1, 3) == "\255\216\255" then return "image/jpeg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png" end
    return nil
end

--[[--
Downloads a book to `dir`. Returns the file path or nil, err.

@param book result of getBook()
@param dir target folder (must exist)
@param progress function(done, total) called before each step; return false to cancel
@param opts {prefer_direct=true}
]]
function Provider:download(book, dir, progress, opts)
    opts = opts or {}
    progress = progress or function() return true end
    local base = dir:gsub("/$", "") .. "/" .. Provider.fileBase(book.url)

    -- 1. The site's own FB2 file, if offered.
    if opts.prefer_direct ~= false and book.direct.fb2 then
        if progress(0, 1) == false then return nil, "cancelled" end
        local path = base .. ".fb2"
        local ok, err = self.http.download(book.direct.fb2, path)
        if ok then
            fixDirectFb2Author(path, book.authors[1])
            return path
        end
        -- fall through to scraping if the file link is broken
        if not book.has_text then return nil, err end
    end

    -- 2. Scrape the pages (or the single article) into a new FB2.
    local cover_data, cover_type
    if book.cover then
        cover_data = self.http.get(book.cover)
        cover_type = sniffImageType(cover_data)
        if not cover_type then cover_data = nil end
    end

    local path = base .. ".fb2"
    local writer, werr = Fb2.Writer(path, {
        title = book.title,
        authors = book.authors,
        genre = "prose",
        annotation = book.annotation,
        lang = "uk",
        source_url = book.url,
        cover_id = cover_data and (cover_type == "image/png" and "cover.png" or "cover.jpg") or nil,
    })
    if not writer then return nil, werr end

    local conv = Fb2.Converter()
    local pages = book.pages
    local total = math.max(#pages, 1)

    if #pages == 0 then
        -- single page book: text is on the book page itself
        local html = book._html
        if not html then
            local err
            html, err = self:fetch(book.url)
            if not html then writer:abort() return nil, err end
        end
        local text = Provider.pageText(html)
            or html:match('<article itemprop="articleBody">(.-)</article>')
        if not text then writer:abort() return nil, "no book text found" end
        if progress(1, 1) == false then writer:abort() return nil, "cancelled" end
        writer:write(conv:feed(text))
    else
        for i, page_url in ipairs(pages) do
            if progress(i - 1, total) == false then
                writer:abort()
                return nil, "cancelled"
            end
            local html, err
            -- retry once, the site sometimes times out
            for _ = 1, 2 do
                html, err = self:fetch(page_url)
                if html then break end
            end
            if not html then
                writer:abort()
                return nil, string.format("page %d/%d: %s", i, total, tostring(err))
            end
            local text = Provider.pageText(html)
            if text then
                writer:write(conv:feed(text))
            end
            if self.sleep and self.delay > 0 and i < total then
                self.sleep(self.delay)
            end
        end
        progress(total, total)
    end
    writer:write(conv:finish())

    local binaries = {}
    if cover_data then
        binaries[1] = {
            id = cover_type == "image/png" and "cover.png" or "cover.jpg",
            content_type = cover_type,
            data = cover_data,
        }
    end
    return writer:close(binaries)
end

return Provider
