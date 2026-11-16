--[[--
Menu-based browser:
  root -> site -> search / new books / categories
       -> downloaded
       -> download folder

Listings load lazily: one screen is filled from several site pages, and more
are fetched when you turn to a page that isn't full yet.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local MIN_QUERY_LENGTH = 2
-- Max site requests for one "fill the screen" step (with filters most cards
-- of a page can be skipped, don't keep loading forever).
local MAX_REQUESTS_PER_FILL = 6

local Browser = Menu:extend{
    title = _("Ukrainian books"),
    is_popout = false,
    is_borderless = true,
    covers_fullscreen = true,
    title_bar_fm_style = true,
    title_shrink_font_to_fit = true,

    plugin = nil,    -- main.lua instance
    providers = nil, -- list of provider instances
    provider = nil,  -- provider of the current view
    state = nil,     -- lazy listing state of the current view, if any
}

function Browser:init()
    self.item_table = self:genRootItems()
    self.current_title = self.title
    Menu.init(self)
end

-- Helpers --------------------------------------------------------------------

local function showError(text, err)
    UIManager:show(InfoMessage:new{
        text = err and T("%1\n\n%2", text, tostring(err)) or text,
    })
end

-- Runs fn() while showing a "Loading…" message. Returns fn's results, or nil, error.
function Browser:loading(fn, text)
    local info = InfoMessage:new{ text = text or _("Loading…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok, res, err = pcall(fn)
    UIManager:close(info)
    if not ok then
        logger.warn("ukrbooks: error", res)
        return nil, tostring(res)
    end
    return res, err
end

function Browser:withNetwork(fn)
    NetworkMgr:runWhenOnline(fn)
end

function Browser:pushView(title, item_table, state, provider)
    table.insert(self.paths, {
        title = self.current_title,
        item_table = self.item_table,
        page = self.page,
        state = self.state,
        provider = self.provider,
        regen = self.regen,
    })
    self.state = state
    self.provider = provider or self.provider
    self.regen = nil
    self.current_title = title
    self:switchItemTable(title, item_table)
end

function Browser:onReturn()
    local prev = table.remove(self.paths)
    if not prev then return true end
    self.state = prev.state
    self.provider = prev.provider
    self.regen = prev.regen
    self.current_title = prev.title
    local item_table = prev.item_table
    if self.regen then
        item_table = self.regen() -- menus with dynamic text (settings)
    elseif #self.paths == 0 then
        item_table = self:genRootItems()
    end
    self:switchItemTable(prev.title, item_table, ((prev.page or 1) - 1) * self.perpage + 1)
    return true
end

function Browser:onHoldReturn()
    while #self.paths > 1 do table.remove(self.paths) end
    return self:onReturn()
end

function Browser:onMenuSelect(item)
    if item.callback then item.callback() end
    return true
end

function Browser:onMenuHold(item)
    if item.hold_callback then item.hold_callback() end
    return true
end

-- Root -----------------------------------------------------------------------

function Browser:genRootItems()
    local items = {}
    for __, provider in ipairs(self.providers) do
        items[#items + 1] = {
            text = T("%1 (%2)", provider.name, provider.site),
            callback = function() self:showProvider(provider) end,
        }
    end
    items[#items + 1] = {
        text = _("Downloaded"),
        callback = function() self:showHistory() end,
    }
    items[#items + 1] = {
        text = T(_("Download folder: %1"), self.plugin:getDownloadDir()),
        callback = function() self:chooseDownloadDir() end,
    }
    return items
end

function Browser:genProviderItems(provider)
    local items = {
        {
            text = _("Search…"),
            callback = function() self:showSearch() end,
        },
        {
            text = _("New books"),
            callback = function()
                self:openListing(_("New books"), function(page)
                    return self.provider:latest(page)
                end)
            end,
        },
        {
            text = _("Categories"),
            callback = function() self:showCategories() end,
        },
    }
    if provider.id == "booknet" then
        local free_only = self.plugin:getProviderSetting(provider, "free_only", true)
        items[#items + 1] = {
            text = free_only and _("Listings: free books only (tap to show all)")
                or _("Listings: all books (tap to show free only)"),
            callback = function()
                self.plugin:saveProviderSetting(provider, "free_only", not free_only)
                self:switchItemTable(nil, self:genProviderItems(provider), 1)
            end,
        }
    end
    if provider.needs_login then
        items[#items + 1] = {
            text = provider:hasLogin() and _("Login: identity.txt found")
                or _("Login: identity.txt not found (downloads disabled)"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("Downloading from %1 needs your browser login cookie.\n\n"
                        .. "Put identity.txt (value of the _identity cookie) and optionally csrf.txt "
                        .. "(value of the _csrf cookie) into the plugin folder:\n%2\n\n"
                        .. "Then reopen this window."), provider.site, self.plugin.path or "ukrbooks.koplugin"),
                })
            end,
        }
    end
    return items
end

function Browser:showProvider(provider)
    self:pushView(provider.name, self:genProviderItems(provider), nil, provider)
    self.regen = function() return self:genProviderItems(provider) end
end

function Browser:showSearch()
    local provider = self.provider
    local dialog
    dialog = InputDialog:new{
        title = T(_("Search on %1"), provider.site),
        input = self.plugin:getProviderSetting(provider, "last_query", ""),
        input_hint = _("Title or author"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = util.trim(dialog:getInputText() or "")
                        if #query < MIN_QUERY_LENGTH then
                            return
                        end
                        UIManager:close(dialog)
                        self.plugin:saveProviderSetting(provider, "last_query", query)
                        self:openListing(T(_("Search: %1"), query), function(page)
                            return provider:search(query, page)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:showCategories()
    local provider = self.provider
    self:withNetwork(function()
        local cats, err = self:loading(function()
            return provider:categories()
        end)
        if not cats then
            showError(_("Could not load categories."), err)
            return
        end
        local items = {}
        for __, cat in ipairs(cats) do
            items[#items + 1] = {
                text = cat.title,
                callback = function()
                    self:openListing(cat.title, function(page)
                        return provider:category(cat.id, page)
                    end)
                end,
            }
        end
        self:pushView(_("Categories"), items)
    end)
end

function Browser:showHistory()
    local items = {}
    for __, entry in ipairs(self.plugin:getHistory()) do
        local exists = util.fileExists(entry.path)
        items[#items + 1] = {
            text = entry.author and entry.author ~= "" and (entry.title .. " — " .. entry.author) or entry.title,
            mandatory = entry.incomplete and _("incomplete") or nil,
            dim = not exists,
            callback = function()
                if util.fileExists(entry.path) then
                    self.plugin:openFile(entry.path)
                else
                    showError(T(_("File not found:\n%1"), entry.path))
                end
            end,
            hold_callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove from this list?\n\n%1\n\n(The file itself is not deleted.)"), entry.title),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        self.plugin:removeHistory(entry.path)
                        self:onReturn()
                        self:showHistory()
                    end,
                })
            end,
        }
    end
    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No downloaded books yet.") })
        return
    end
    self:pushView(_("Downloaded"), items)
end

function Browser:chooseDownloadDir()
    local current = self.plugin:getDownloadDir()
    local start = util.pathExists(current) and current or "/mnt/us"
    if not util.pathExists(start) then start = "/" end
    local chooser = PathChooser:new{
        title = _("Choose download folder (long-press to select)"),
        select_file = false,
        show_files = false,
        path = start,
        onConfirm = function(path)
            self.plugin:setDownloadDir(path)
            self:switchItemTable(nil, self:genRootItems())
        end,
    }
    UIManager:show(chooser)
end

-- Listings -------------------------------------------------------------------

local function bookItemText(book)
    if book.author and book.author ~= "" then
        return book.title .. " — " .. book.author
    end
    return book.title
end

-- Fetches site pages until `want` new items were added, there are no more,
-- or MAX_REQUESTS_PER_FILL requests were made. Returns true, or nil, err.
function Browser:fetchMore(state, items, want)
    local added, requests = 0, 0
    while state.has_more and added < want and requests < MAX_REQUESTS_PER_FILL do
        requests = requests + 1
        local res, err = state.loader(state.next_page)
        if not res then
            if added > 0 then return true end
            return nil, err
        end
        state.next_page = state.next_page + 1
        state.has_more = res.has_more and true or false
        for __, book in ipairs(res.items) do
            -- skip books shifted from the previous page by new uploads
            if not state.seen[book.url] then
                state.seen[book.url] = true
                added = added + 1
                items[#items + 1] = {
                    text = bookItemText(book),
                    mandatory = book.date or book.badge,
                    callback = function() self:showBook(book) end,
                }
            end
        end
    end
    return true
end

function Browser:openListing(title, loader)
    self:withNetwork(function()
        local state = { loader = loader, next_page = 1, has_more = true, seen = {} }
        local items = {}
        local ok, err = self:loading(function()
            return self:fetchMore(state, items, self.perpage)
        end)
        if not ok then
            showError(_("Could not load the list."), err)
            return
        end
        if #items == 0 then
            UIManager:show(InfoMessage:new{
                text = state.has_more and _("No matching books on the first pages.") or _("Nothing found."),
            })
            return
        end
        self:pushView(title, items, state)
    end)
end

-- Before turning to the next page, make sure it's full (load more site pages if needed).
function Browser:onNextPage()
    local state = self.state
    local next_first = self.page * self.perpage + 1 -- first item of the next page
    local missing = (self.page + 1) * self.perpage - #self.item_table
    if state and state.has_more and missing > 0 then
        self:withNetwork(function()
            local ok, err = self:loading(function()
                return self:fetchMore(state, self.item_table, missing)
            end)
            if not ok then
                showError(_("Could not load more books."), err)
            end
            if #self.item_table >= next_first then
                self:switchItemTable(nil, self.item_table, next_first)
            end
        end)
        return true
    end
    return Menu.onNextPage(self)
end

-- Book -----------------------------------------------------------------------

function Browser:targetPath(provider, book)
    return self.plugin:getDownloadDir() .. "/" .. provider.fileBase(book.url) .. ".fb2"
end

function Browser:showBook(item)
    local provider = self.provider
    self:withNetwork(function()
        local book, err = self:loading(function()
            return provider:getBook(item.url, item)
        end)
        if not book then
            showError(_("Could not load the book page."), err)
            return
        end

        local lines = {}
        if #book.authors > 0 then
            lines[#lines + 1] = T(_("Author: %1"), table.concat(book.authors, ", "))
        end
        if book.genre and book.genre ~= "" then
            lines[#lines + 1] = T(_("Genre: %1"), book.genre)
        end
        for __, line in ipairs(book.extra or {}) do
            lines[#lines + 1] = line
        end
        local target = self:targetPath(provider, book)
        -- util.fileExists returns nil (not false) for a missing file, and a Button
        -- with enabled=nil falls back to its default (enabled), so make it a boolean.
        local downloaded = util.fileExists(target) == true
        if downloaded then
            lines[#lines + 1] = _("Already downloaded.")
        end
        if book.download_note then
            lines[#lines + 1] = ""
            lines[#lines + 1] = book.download_note
        end
        if #book.annotation > 0 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = table.concat(book.annotation, "\n\n")
        end

        local viewer
        local buttons = {
            {
                {
                    text = _("By this author"),
                    enabled = book.author_url ~= nil,
                    callback = function()
                        UIManager:close(viewer)
                        self:openListing(book.authors[1] or _("Author"), function(page)
                            return provider:byUrl(book.author_url, page)
                        end)
                    end,
                },
                {
                    text = downloaded and _("Download again") or _("Download"),
                    enabled = book.can_download and true or false,
                    callback = function()
                        UIManager:close(viewer)
                        self:download(provider, book)
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
                {
                    text = _("Read"),
                    enabled = downloaded,
                    callback = function()
                        if not util.fileExists(target) then
                            showError(T(_("File not found:\n%1"), target))
                            return
                        end
                        UIManager:close(viewer)
                        self.plugin:openFile(target)
                    end,
                },
            },
        }
        viewer = TextViewer:new{
            title = book.title,
            text = table.concat(lines, "\n"),
            text_type = "book_info",
            buttons_table = buttons,
        }
        UIManager:show(viewer)
    end)
end

function Browser:download(provider, book)
    local dir = self.plugin:getDownloadDir()
    if not util.pathExists(dir) then
        util.makePath(dir)
    end
    if not util.pathExists(dir) then
        showError(T(_("Can't create the download folder:\n%1"), dir))
        return
    end
    self:withNetwork(function()
        Trapper:wrap(function()
            Trapper:info(T(_("Downloading:\n%1"), book.title))
            local progress = function(done, total, text)
                if not text then
                    text = total > 1 and T(_("Page %1 of %2"), done, total) or ""
                end
                return Trapper:info(T(_("Downloading:\n%1\n\n%2\n\nTap to cancel."), book.title, text))
            end
            local ok, path, warning = pcall(provider.download, provider, book, dir, progress)
            Trapper:clear()
            if not ok then
                logger.warn("ukrbooks: download error", path)
                warning, path = path, nil
            end
            if not path then
                if warning ~= "cancelled" then
                    showError(_("Download failed."), warning)
                end
                return
            end
            self.plugin:addHistory{
                title = book.title,
                author = book.authors[1],
                path = path,
                url = book.url,
                incomplete = warning and true or nil,
            }
            local text = warning
                and T(_("%1\n\nSaved to:\n%2\n\nRead it now?"), warning, path)
                or T(_("Saved to:\n%1\n\nRead it now?"), path)
            UIManager:show(ConfirmBox:new{
                text = text,
                ok_text = _("Read now"),
                ok_callback = function()
                    self.plugin:openFile(path)
                end,
            })
        end)
    end)
end

return Browser
