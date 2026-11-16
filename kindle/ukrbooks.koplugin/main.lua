--[[--
Ukrainian books: browse, search and download books from Ukrainian sites
straight into KOReader.

@module koplugin.ukrbooks
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local UkrBooks = WidgetContainer:extend{
    name = "ukrbooks",
    is_doc_only = false,
}

local MAX_HISTORY = 200

-- Folder of this plugin (pluginloader sets self.path; fall back to this file's location).
local function pluginDir(self)
    if self.path then return self.path end
    local src = debug.getinfo(1, "S").source or ""
    return src:match("^@(.*)/[^/]*$") or "."
end

-- Reads a one-line secret file, trimmed. Returns nil if missing or empty.
local function readValue(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*a") or ""
    f:close()
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then return nil end
    return v
end

function UkrBooks:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/ukrbooks.lua")
    self.path = pluginDir(self)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function UkrBooks:onDispatcherRegisterActions()
    Dispatcher:registerAction("ukrbooks_show", {
        category = "none", event = "ShowUkrBooks", title = _("Ukrainian books"), general = true,
    })
end

function UkrBooks:addToMainMenu(menu_items)
    menu_items.ukrbooks = {
        text = _("Ukrainian books"),
        sorting_hint = "search",
        callback = function()
            self:onShowUkrBooks()
        end,
    }
end

local function sleep(seconds)
    local ffiutil = require("ffi/util")
    if ffiutil.usleep then
        ffiutil.usleep(math.floor(seconds * 1000000))
    else
        ffiutil.sleep(math.ceil(seconds))
    end
end

function UkrBooks:createProviders()
    local Http = require("ukrbooks/http")
    local Rub = require("ukrbooks/providers/readukrainianbooks")
    local Booknet = require("ukrbooks/providers/booknet")

    -- Booknet login cookies: same files as the bash scripts use, in the plugin folder.
    local identity = readValue(self.path .. "/identity.txt")
    local csrf = readValue(self.path .. "/csrf.txt")
    logger.info("ukrbooks: booknet identity.txt", identity and "found" or "not found", "in", self.path)

    local booknet
    booknet = Booknet.new(Http, {
        identity = identity,
        csrf = csrf,
        sleep = sleep,
        setting = function(key, default)
            return self:getProviderSetting(booknet, key, default)
        end,
    })
    return {
        Rub.new(Http, { sleep = sleep }),
        booknet,
    }
end

function UkrBooks:onShowUkrBooks()
    local Browser = require("ukrbooks/browser")
    self.browser = Browser:new{
        plugin = self,
        providers = self:createProviders(),
        close_callback = function()
            self.browser = nil
        end,
    }
    UIManager:show(self.browser)
    return true
end

-- Settings -------------------------------------------------------------------

function UkrBooks:getDownloadDir()
    local dir = self.settings:readSetting("download_dir")
    if dir then return dir end
    if Device:isKindle() then
        return "/mnt/us/books"
    end
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
    return home .. "/books"
end

function UkrBooks:setDownloadDir(dir)
    self.settings:saveSetting("download_dir", dir)
    self.settings:flush()
end

function UkrBooks:getSetting(key, default)
    local v = self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

function UkrBooks:saveSetting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function UkrBooks:getProviderSetting(provider, key, default)
    return self:getSetting(provider.id .. "_" .. key, default)
end

function UkrBooks:saveProviderSetting(provider, key, value)
    self:saveSetting(provider.id .. "_" .. key, value)
end

function UkrBooks:getHistory()
    return self.settings:readSetting("history") or {}
end

function UkrBooks:addHistory(entry)
    local history = self:getHistory()
    for i = #history, 1, -1 do
        if history[i].path == entry.path then table.remove(history, i) end
    end
    entry.time = os.time()
    table.insert(history, 1, entry)
    while #history > MAX_HISTORY do table.remove(history) end
    self:saveSetting("history", history)
end

function UkrBooks:removeHistory(path)
    local history = self:getHistory()
    for i = #history, 1, -1 do
        if history[i].path == path then table.remove(history, i) end
    end
    self:saveSetting("history", history)
end

-- Opening books --------------------------------------------------------------

function UkrBooks:openFile(path)
    if self.browser then
        UIManager:close(self.browser)
        self.browser = nil
    end
    if self.ui.document and self.ui.switchDocument then
        self.ui:switchDocument(path)
    else
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end
end

return UkrBooks
