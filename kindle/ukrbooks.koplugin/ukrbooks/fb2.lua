--[[--
FB2 building blocks in plain Lua 5.1.

* Fb2.escape(): XML escaping
* Fb2.Converter: turns site HTML (one page after another) into FB2 body markup.
  It keeps its state between pages, because a paragraph or chapter can span
  a page boundary. Blocks whose class contains "title" (or h1-h3) start a new
  <section> with a <title>.
* Fb2.Writer: streams a .fb2 file to disk (header, sections, cover, footer).
  It writes to "<path>.part" and renames it on close, so an aborted download
  never leaves a broken book behind.
]]

local Html = require("ukrbooks/html")

local Fb2 = {}

function Fb2.escape(s)
    if not s then return "" end
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Same as escape(), plus quotes, for attribute values.
function Fb2.escapeAttr(s)
    return (Fb2.escape(s):gsub('"', "&quot;"))
end

local BLOCK_TAGS = {
    p = true, div = true, br = true, li = true, ul = true, ol = true,
    blockquote = true, tr = true, table = true, section = true, article = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    pre = true, hr = true, dd = true, dt = true, center = true,
}
local VOID_TAGS = { br = true, hr = true, img = true, meta = true, input = true, link = true }
local INLINE_MAP = { b = "strong", strong = "strong", i = "emphasis", em = "emphasis" }
local SKIP_CONTENT = { script = true, style = true, noscript = true, iframe = true, svg = true }

local function blockStyle(tag, class)
    if tag == "h1" or tag == "h2" or tag == "h3" then return "title" end
    if tag == "h4" or tag == "h5" or tag == "h6" then return "subtitle" end
    if class then
        class = " " .. class:lower() .. " "
        if class:find("[ %-]title%d* ") then return "title" end
        if class:find(" subtitle ") then return "subtitle" end
        -- No "epigraph" style on purpose: the site never closes those divs,
        -- so the rest of the chapter would end up in italics.
        if class:find(" empty%-line ") then return "empty" end
    end
    return nil
end

local Converter = {}
Converter.__index = Converter

--[[--
Creates a converter.
@param opts optional:
  headings_as_subtitles: h1-h3 / "title" blocks become <subtitle> instead of
                         new sections (when sections come from a chapter list)
  on_image: function(src) -> binary id or nil; <img> becomes <image l:href="#id"/>
]]
function Fb2.Converter(opts)
    local self = setmetatable({}, Converter)
    self.opts = opts or {}
    self.out = {}             -- emitted chunks for the current feed() call
    self.stack = {}           -- open block elements: {tag=, style=}
    self.inline = {}          -- open inline FB2 tags inside current paragraph
    self.para = {}            -- current paragraph pieces
    self.para_has_text = false
    self.title_buf = nil      -- paragraphs of a title being collected
    self.title_depth = nil    -- stack depth where the title block started
    self.section_has_content = false
    self.section_has_title = false
    self.last_empty = true    -- avoid repeated/leading <empty-line/>
    return self
end

function Converter:currentStyle()
    for i = #self.stack, 1, -1 do
        local st = self.stack[i].style
        if st and st ~= "empty" then return st end
    end
    return nil
end

function Converter:emit(s)
    self.out[#self.out + 1] = s
end

function Converter:emitEmptyLine()
    if not self.last_empty and not self.title_buf then
        self:emit("<empty-line/>")
        self.last_empty = true
    end
end

function Converter:flushParagraph()
    -- close any inline tags still open in this paragraph
    local closing = {}
    for i = #self.inline, 1, -1 do
        closing[#closing + 1] = "</" .. self.inline[i] .. ">"
    end
    local text = table.concat(self.para) .. table.concat(closing)
    local had_text = self.para_has_text
    self.para = {}
    self.para_has_text = false
    -- reopen inline tags at the start of the next paragraph
    for _, t in ipairs(self.inline) do
        self.para[#self.para + 1] = "<" .. t .. ">"
    end
    if not had_text then return end

    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- drop inline tags that ended up empty
    text = text:gsub("<(%a+)>%s*</%1>", "")
    if text == "" then return end

    if self.title_buf then
        self.title_buf[#self.title_buf + 1] = "<p>" .. text .. "</p>"
        return
    end
    local style = self:currentStyle()
    if style == "subtitle" or (style == "title" and self.section_has_title) then
        self:emit("<subtitle>" .. text .. "</subtitle>")
    elseif style == "epigraph" then
        self:emit("<p><emphasis>" .. text .. "</emphasis></p>")
    else
        self:emit("<p>" .. text .. "</p>")
    end
    self.section_has_content = true
    self.last_empty = false
end

function Converter:beginTitle()
    self.title_buf = {}
    self.title_depth = #self.stack - 1 -- the title element itself is on top
    self.title_class = nil
end

function Converter:endTitle()
    local buf = self.title_buf
    -- The site doesn't close title divs (they wrap the whole chapter), so
    -- whatever follows inside the element is regular text.
    local el = self.stack[self.title_depth + 1]
    if el and el.style == "title" then el.style = nil end
    self.title_buf, self.title_depth, self.title_class = nil, nil, nil
    if not buf or #buf == 0 then return end
    if self.section_has_title and not self.section_has_content then
        -- A second title right after the first one: use subtitles.
        for _, p in ipairs(buf) do
            self:emit((p:gsub("^<p>", "<subtitle>"):gsub("</p>$", "</subtitle>")))
        end
        return
    end
    if self.section_has_content or self.section_has_title then
        self:emit("</section><section>")
    end
    self:emit("<title>" .. table.concat(buf) .. "</title>")
    self.section_has_title = true
    self.section_has_content = false
    self.last_empty = true
end

function Converter:addText(raw)
    local t = Html.decodeEntities(raw)
    t = t:gsub("\194\160", " "):gsub("[%s]+", " ")
    if t:find("%S") then
        self.para_has_text = true
    elseif #self.para == 0 or not self.para_has_text then
        return -- no leading whitespace
    end
    self.para[#self.para + 1] = Fb2.escape(t)
end

function Converter:openBlock(tag, class)
    self:flushParagraph()
    if VOID_TAGS[tag] then
        if tag == "br" then return end
        if tag == "hr" then self:emitEmptyLine() end
        return
    end
    local style = blockStyle(tag, class)
    if style == "title" and self.opts.headings_as_subtitles then
        style = "subtitle"
    end
    -- A title is the run of paragraphs with the class of its first paragraph,
    -- ended by a different class, a nested block element or a length cap.
    if self.title_buf and #self.stack > self.title_depth then
        if tag == "p" and not style then
            local cls = class or ""
            if not self.title_class then
                self.title_class = cls
            elseif cls ~= self.title_class or #self.title_buf >= 5 then
                self:endTitle()
            end
        elseif tag ~= "p" then
            self:endTitle()
        end
    end
    if style == "empty" then
        self:emitEmptyLine()
    end
    self.stack[#self.stack + 1] = { tag = tag, style = style }
    if style == "title" and not self.title_buf then
        self:beginTitle()
    end
end

function Converter:closeBlock(tag)
    -- an empty <p></p> is used by the site as a separator
    if tag == "p" and not self.para_has_text and #self.stack > 0
        and self.stack[#self.stack].tag == "p" and not self.title_buf then
        self:flushParagraph()
        self:emitEmptyLine()
    else
        self:flushParagraph()
    end
    -- pop up to (and including) the matching element
    for i = #self.stack, 1, -1 do
        if self.stack[i].tag == tag then
            for j = #self.stack, i, -1 do
                self.stack[j] = nil
            end
            break
        end
    end
    if self.title_buf and #self.stack <= self.title_depth then
        self:endTitle()
    end
end

function Converter:openInline(fb2tag)
    self.inline[#self.inline + 1] = fb2tag
    self.para[#self.para + 1] = "<" .. fb2tag .. ">"
end

function Converter:closeInline(fb2tag)
    for i = #self.inline, 1, -1 do
        if self.inline[i] == fb2tag then
            -- close everything opened after it too, then reopen those
            local reopen = {}
            for j = #self.inline, i, -1 do
                self.para[#self.para + 1] = "</" .. self.inline[j] .. ">"
                if j > i then table.insert(reopen, 1, self.inline[j]) end
                self.inline[j] = nil
            end
            for _, t in ipairs(reopen) do self:openInline(t) end
            return
        end
    end
end

--- Feeds an HTML fragment and returns the FB2 markup produced so far.
function Converter:feed(html)
    self.out = {}
    local pos = 1
    local len = #html
    while pos <= len do
        local lt = html:find("<", pos, true)
        if not lt then
            self:addText(html:sub(pos))
            break
        end
        if lt > pos then
            self:addText(html:sub(pos, lt - 1))
        end
        if html:sub(lt, lt + 3) == "<!--" then
            local ce = html:find("-->", lt + 4, true)
            pos = ce and ce + 3 or len + 1
        else
            local gt = html:find(">", lt + 1, true)
            if not gt then break end
            local tag_str = html:sub(lt, gt)
            local closing, name = tag_str:match("^<(/?)([%w]+)")
            pos = gt + 1
            if name then
                name = name:lower()
                if SKIP_CONTENT[name] and closing == "" then
                    local ce = html:find("</" .. name .. "%s*>", pos)
                    if not ce then ce = html:find("</" .. name:upper() .. "%s*>", pos) end
                    if ce then
                        pos = html:find(">", ce, true) + 1
                    else
                        pos = len + 1
                    end
                elseif INLINE_MAP[name] then
                    if closing == "/" then
                        self:closeInline(INLINE_MAP[name])
                    else
                        self:openInline(INLINE_MAP[name])
                    end
                elseif BLOCK_TAGS[name] then
                    if closing == "/" then
                        self:closeBlock(name)
                    else
                        self:openBlock(name, Html.attr(tag_str, "class"))
                        if tag_str:find("/>$") and not VOID_TAGS[name] then
                            self:closeBlock(name)
                        end
                    end
                elseif name == "img" and self.opts.on_image and not self.title_buf then
                    local src = Html.attr(tag_str, "src") or Html.attr(tag_str, "data-src")
                    local id = src and self.opts.on_image(Html.decodeEntities(src))
                    if id then
                        self:flushParagraph()
                        self:emit('<image l:href="#' .. Fb2.escapeAttr(id) .. '"/>')
                        self.section_has_content = true
                        self.last_empty = true -- an image already separates blocks
                    end
                end
                -- other tags (a, span, sup, font...) are dropped, text is kept
            end
        end
    end
    return table.concat(self.out)
end

--- Starts a new <section> with the given title (e.g. a chapter name from the
-- site's chapter list). Returns the FB2 markup produced.
function Converter:startSection(title)
    self.out = {}
    self:flushParagraph()
    if self.title_buf then self:endTitle() end
    self.stack = {}
    if self.section_has_content or self.section_has_title then
        self:emit("</section><section>")
    end
    title = title and title:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if title ~= "" then
        self:emit("<title><p>" .. Fb2.escape(title) .. "</p></title>")
        self.section_has_title = true
    else
        self.section_has_title = false
    end
    self.section_has_content = false
    self.last_empty = true
    return table.concat(self.out)
end

--- Flushes any pending paragraph/title. Returns the remaining FB2 markup.
function Converter:finish()
    self.out = {}
    self:flushParagraph()
    if self.title_buf then self:endTitle() end
    self.stack = {}
    return table.concat(self.out)
end

-- Writer ---------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

--[[--
Opens a new FB2 file.
@param path final file path
@param meta table: title, authors (list of strings), genre, annotation
            (list of paragraphs), lang, source_url, cover_id (optional)
]]
function Fb2.Writer(path, meta)
    local self = setmetatable({ path = path, part = path .. ".part" }, Writer)
    local f, err = io.open(self.part, "wb")
    if not f then return nil, err end
    self.f = f

    local parts = {
        '<?xml version="1.0" encoding="utf-8"?>\n',
        '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" ',
        'xmlns:l="http://www.w3.org/1999/xlink">\n',
        "<description><title-info>",
        "<genre>", Fb2.escape(meta.genre or "prose"), "</genre>",
    }
    local authors = meta.authors or {}
    if #authors == 0 then authors = { "" } end
    for _, a in ipairs(authors) do
        -- FB2 wants first/last name; split on the last space.
        local first, last = a:match("^(.*)%s+(%S+)$")
        if not first then first, last = "", a end
        parts[#parts + 1] = "<author><first-name>" .. Fb2.escape(first)
            .. "</first-name><last-name>" .. Fb2.escape(last) .. "</last-name></author>"
    end
    parts[#parts + 1] = "<book-title>" .. Fb2.escape(meta.title or "Untitled") .. "</book-title>"
    if meta.annotation and #meta.annotation > 0 then
        parts[#parts + 1] = "<annotation>"
        for _, p in ipairs(meta.annotation) do
            parts[#parts + 1] = "<p>" .. Fb2.escape(p) .. "</p>"
        end
        parts[#parts + 1] = "</annotation>"
    end
    if meta.cover_id then
        parts[#parts + 1] = '<coverpage><image l:href="#' .. Fb2.escapeAttr(meta.cover_id) .. '"/></coverpage>'
    end
    parts[#parts + 1] = "<lang>" .. (meta.lang or "uk") .. "</lang>"
    parts[#parts + 1] = "</title-info><document-info>"
    parts[#parts + 1] = "<author><nickname>ukrbooks.koplugin</nickname></author>"
    parts[#parts + 1] = "<program-used>ukrbooks.koplugin</program-used>"
    parts[#parts + 1] = "<date>" .. os.date("%Y-%m-%d") .. "</date>"
    if meta.source_url then
        parts[#parts + 1] = "<src-url>" .. Fb2.escape(meta.source_url) .. "</src-url>"
    end
    parts[#parts + 1] = "<id>ukrbooks-" .. tostring(os.time()) .. "</id><version>1.0</version>"
    parts[#parts + 1] = "</document-info></description>\n<body><section>"
    f:write(table.concat(parts))
    return self
end

function Writer:write(fb2_markup)
    if fb2_markup and fb2_markup ~= "" then
        self.f:write(fb2_markup, "\n")
        self.wrote_text = true
    end
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(data)
    local out = {}
    local line = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        line[#line + 1] = b64chars:sub(c1 + 1, c1 + 1) .. b64chars:sub(c2 + 1, c2 + 1)
            .. (b and b64chars:sub(c3 + 1, c3 + 1) or "=")
            .. (c and b64chars:sub(c4 + 1, c4 + 1) or "=")
        if #line == 19 then -- 76 chars per line
            out[#out + 1] = table.concat(line)
            line = {}
        end
    end
    if #line > 0 then out[#out + 1] = table.concat(line) end
    return table.concat(out, "\n")
end
Fb2.base64 = base64

--- Closes the body and optionally embeds binaries, then finalizes the file.
-- @param binaries list of {id=, content_type=, data=}
-- @param final_path optional: save under this name instead of the one given
--        to Writer() (e.g. "-incomplete"), leaving an existing file untouched
function Writer:close(binaries, final_path)
    if final_path then self.path = final_path end
    if not self.wrote_text then
        -- FB2 sections must not be empty
        self.f:write("<p></p>")
    end
    self.f:write("</section></body>\n")
    for _, bin in ipairs(binaries or {}) do
        if bin.data and #bin.data > 0 then
            self.f:write('<binary id="', Fb2.escapeAttr(bin.id), '" content-type="',
                bin.content_type or "image/jpeg", '">', base64(bin.data), "</binary>\n")
        end
    end
    self.f:write("</FictionBook>\n")
    self.f:close()
    self.f = nil
    os.remove(self.path)
    local ok, err = os.rename(self.part, self.path)
    if not ok then return nil, err end
    return self.path
end

--- Aborts writing and removes the partial file.
function Writer:abort()
    if self.f then self.f:close() self.f = nil end
    os.remove(self.part)
end

return Fb2
