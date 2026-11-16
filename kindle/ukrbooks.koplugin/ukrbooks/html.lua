--[[--
Small HTML helpers in plain Lua 5.1 (no KOReader dependencies, so they can
be tested on a desktop). Good enough for the regular markup of the sites we
scrape. This is not a general HTML parser.
]]

local Html = {}

local named_entities = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = "\194\160", laquo = "«", raquo = "»", bdquo = "„",
    ldquo = "“", rdquo = "”", lsquo = "‘", rsquo = "’", sbquo = "‚",
    mdash = "—", ndash = "–", hellip = "…", minus = "−",
    copy = "©", reg = "®", trade = "™", deg = "°", middot = "·",
    bull = "•", times = "×", shy = "", zwnj = "", zwj = "",
    prime = "′", Prime = "″", sect = "§", para = "¶", euro = "€",
}

--- Encodes a Unicode code point as UTF-8.
function Html.utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(0xF0 + math.floor(cp / 0x40000),
                           0x80 + math.floor(cp / 0x1000) % 0x40,
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    end
    return ""
end

local function decode_numeric(cp)
    -- Drop control characters, which are invalid in XML.
    if not cp or (cp < 32 and cp ~= 9 and cp ~= 10 and cp ~= 13) then
        return ""
    end
    return Html.utf8char(cp)
end

--- Decodes HTML entities once.
function Html.decodeEntities(s)
    if not s or not s:find("&", 1, true) then return s end
    return (s:gsub("&(#?[xX]?)([%w]+);", function(prefix, body)
        if prefix == "#" then
            return decode_numeric(tonumber(body, 10))
        elseif prefix == "#x" or prefix == "#X" then
            return decode_numeric(tonumber(body, 16))
        elseif prefix == "" then
            local v = named_entities[body]
            if v then return v end
        end
        return "&" .. prefix .. body .. ";"
    end))
end

--- Decodes entities twice. Some titles on the site are double-encoded
-- (e.g. "п&amp;#039;яти").
function Html.decodeEntities2(s)
    return Html.decodeEntities(Html.decodeEntities(s))
end

--- Removes emoji (4-byte UTF-8 sequences plus some common 3-byte symbols).
-- The e-ink UI fonts usually can't draw them, so they would show as boxes.
function Html.stripEmoji(s)
    if not s then return s end
    s = s:gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", "")
    -- variation selectors, zero-width joiner, misc symbols (U+2600-U+27BF)
    s = s:gsub("\239\184[\128-\143]", "")
    s = s:gsub("\226\128\141", "")
    s = s:gsub("\226[\152-\158][\128-\191]", "")
    return s
end

--- Collapses whitespace (including NBSP) and trims.
function Html.squash(s)
    if not s then return s end
    s = s:gsub("\194\160", " ")
    s = s:gsub("%s+", " ")
    return (s:gsub("^ ", ""):gsub(" $", ""))
end

--- Removes tags, decodes entities, collapses whitespace.
function Html.text(s)
    if not s then return nil end
    s = s:gsub("<[^>]*>", " ")
    return Html.squash(Html.decodeEntities2(s))
end

--- Same as Html.text(), but without emoji.
function Html.cleanText(s)
    return Html.squash(Html.stripEmoji(Html.text(s)))
end

--- Returns the full outer HTML of the element starting at the first plain-text
-- match of `start_marker` (e.g. '<div id="texts"'), balancing nested tags with
-- the same name. Returns nil if the marker is not found.
function Html.extractElement(html, start_marker, tag)
    tag = tag or "div"
    local start = html:find(start_marker, 1, true)
    if not start then return nil end
    local depth = 0
    local pos = start
    local open_pat = "<(/?)" .. tag .. "[%s>/]"
    while true do
        local s, e, closing = html:find(open_pat, pos)
        if not s then
            return html:sub(start) -- unbalanced, return the rest
        end
        if closing == "/" then
            depth = depth - 1
            if depth == 0 then
                local close_end = html:find(">", e, true) or e
                return html:sub(start, close_end)
            end
        else
            depth = depth + 1
        end
        pos = e + 1
    end
end

--- Like extractElement(), but returns only the inner HTML.
function Html.extractInner(html, start_marker, tag)
    local el = Html.extractElement(html, start_marker, tag)
    if not el then return nil end
    local open_end = el:find(">", 1, true)
    local inner = el:sub(open_end + 1)
    return (inner:gsub("</" .. (tag or "div") .. "%s*>%s*$", ""))
end

--- Reads an attribute value from a tag string.
function Html.attr(tag_str, name)
    name = name:gsub("%p", "%%%0") -- "data-src": '-' is a pattern quantifier
    return tag_str:match("%s" .. name .. '%s*=%s*"([^"]*)"')
        or tag_str:match("%s" .. name .. "%s*=%s*'([^']*)'")
end

--- Percent-encodes a string for use in URL query parameters.
function Html.urlEncode(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

return Html
