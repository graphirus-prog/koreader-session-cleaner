--[[
Session Cleaner
Native-Menu rewrite around the preserved database/session engine.
The screen shell is KOReader's Menu widget; book/session presentation stays
separated in presenter and card modules for easier typography control.
--
Version history:
- v1.10.1
  * Added post-delete in-memory cache updates so the UI can return to the
    session list and book list without immediately re-reading the edited book
    from SQLite.
  * Narrow invalidation is preserved as a fallback, but successful deletions
    now patch the current book/session view state in memory first.
  * If the last remaining session of a book is deleted, the plugin now returns
    directly to the book browser instead of trying to reopen a vanished book.
- v1.10.0
  * Added conservative in-memory view caches for the book browser and per-book
    session reconstructions.
  * Returning from inspect/delete flows now reuses cached view data whenever
    possible instead of rebuilding the whole books page from the database.
  * Cache invalidation stays narrow: reconstruction-setting changes flush all
    computed data, search flushes only the books cache, and deletions refresh
    only the affected book.
- v1.9.3
  * Safe readability pass on the stable native-Menu branch.
  * Keep the working layout intact while loosening row truncation.
  * Book rows now prefer "Title | Author" presentation.
]]

local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local _ = require("gettext")

local T = ffiUtil.template

local function getPluginRoot()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*[/\\])main%.lua$") or "./"
end

local PLUGIN_ROOT = getPluginRoot()

local function loadModuleFromPath(module_name, relative_path)
    if package.loaded[module_name] ~= nil then
        return package.loaded[module_name]
    end

    local chunk, load_err = loadfile(PLUGIN_ROOT .. relative_path)
    if not chunk then
        return nil, load_err
    end

    local ok, result = pcall(chunk)
    if not ok then
        return nil, result
    end

    if result == nil then
        result = true
    end

    package.loaded[module_name] = result
    return result
end

local function dedupeNumericRowids(rowids)
    local out = {}
    local seen = {}
    for _, rowid in ipairs(rowids or {}) do
        local n = tonumber(rowid)
        if n then
            n = math.floor(n)
            if not seen[n] then
                seen[n] = true
                out[#out + 1] = n
            end
        end
    end
    table.sort(out)
    return out
end

local SessionCleaner = WidgetContainer:extend{
    name = "sessioncleaner",
    is_doc_only = false,
    version = "1.10.1",
}

function SessionCleaner:init()
    self.runtime = nil
    self.settings = nil
    self.current_widget = nil
    self.book_menu_page = 1
    self.session_menu_pages = {}
    self.session_selection = nil
    -- Runtime-only caches keep navigation snappy without introducing a second
    -- source of truth. The database remains authoritative; cached entries are
    -- disposable views derived from it.
    self.view_cache = {
        books = nil,
        sessions = {},
    }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function SessionCleaner:onDispatcherRegisterActions()
    Dispatcher:registerAction("session_cleaner", {
        category = "none",
        event = "OpenSessionCleaner",
        title = _("Session Cleaner"),
        general = true,
    })
end

function SessionCleaner:onOpenSessionCleaner()
    self:openBookBrowser()
end

function SessionCleaner:addToMainMenu(menu_items)
    menu_items.session_cleaner = {
        text = _("Session Cleaner"),
        sorting_hint = "more_tools",
        callback = function()
            self:openBookBrowser()
        end,
    }
end

function SessionCleaner:_loadRuntime()
    if self.runtime then
        return true
    end

    local Util, err0 = loadModuleFromPath("sessioncleaner_util", "core/sessioncleaner_util.lua")
    if not Util then return nil, err0 end

    local DB, err1 = loadModuleFromPath("sessioncleaner_db", "core/sessioncleaner_db.lua")
    if not DB then return nil, err1 end

    local Sessions, err2 = loadModuleFromPath("sessioncleaner_sessions", "core/sessioncleaner_sessions.lua")
    if not Sessions then return nil, err2 end

    local SettingsStore, err3 = loadModuleFromPath("sessioncleaner_settings", "core/sessioncleaner_settings.lua")
    if not SettingsStore then return nil, err3 end

    local UI, err4 = loadModuleFromPath("sessioncleaner_ui", "sessioncleaner_ui.lua")
    if not UI then return nil, err4 end

    local PresenterModule, err5 = loadModuleFromPath("sessioncleaner_presenter", "sessioncleaner_presenter.lua")
    if not PresenterModule then return nil, err5 end

    local BookCardsModule, err6 = loadModuleFromPath("sessioncleaner_bookcards", "sessioncleaner_bookcards.lua")
    if not BookCardsModule then return nil, err6 end

    local SessionCardsModule, err7 = loadModuleFromPath("sessioncleaner_sessioncards", "sessioncleaner_sessioncards.lua")
    if not SessionCardsModule then return nil, err7 end

    local RendererModule, err8 = loadModuleFromPath("sessioncleaner_renderer", "sessioncleaner_renderer.lua")
    if not RendererModule then return nil, err8 end

    self.runtime = {
        Util = Util,
        DB = DB,
        Sessions = Sessions,
        SettingsStore = SettingsStore,
        UI = UI,
        Presenter = PresenterModule:new(Util),
        BookCards = BookCardsModule:new(),
        SessionCards = SessionCardsModule:new(),
        Renderer = RendererModule:new(),
    }

    self.settings = SettingsStore:load()
    self:normalizeSettings()
    return true
end

function SessionCleaner:_ensureRuntimeReady()
    local ok, err = self:_loadRuntime()
    if not ok then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("Session Cleaner failed to load: ") .. tostring(err),
        })
        return false
    end
    return true
end

function SessionCleaner:normalizeSettings()
    -- Guard old saved settings and unexpected manual edits.
    local Presenter = self.runtime and self.runtime.Presenter
    local valid_scale = false
    for _, name in ipairs((Presenter and Presenter.UI_SCALE_ORDER) or {}) do
        if self.settings.ui_scale == name then
            valid_scale = true
            break
        end
    end
    if not valid_scale then
        self.settings.ui_scale = "normal"
    end
end

function SessionCleaner:saveSettings()
    self:normalizeSettings()
    self.runtime.SettingsStore:save(self.settings)
end

-- Cache keys are tied only to data-shaping settings. Pure presentation settings
-- like UI scale do not invalidate these caches because the renderer can safely
-- rebuild rows from cached data.
function SessionCleaner:_sessionOptsKey()
    return table.concat({
        tostring(math.floor(tonumber(self.settings.session_gap_minutes) or 30)),
        tostring(math.floor(tonumber(self.settings.short_session_seconds) or 120)),
    }, ":")
end

function SessionCleaner:_bookCacheKey()
    return table.concat({
        self:_sessionOptsKey(),
        tostring(self.runtime and self.runtime.Util.trim(self.settings.book_search or "") or ""),
    }, "|")
end

function SessionCleaner:_invalidateBooksCache()
    self.view_cache.books = nil
end

function SessionCleaner:_invalidateSessionCache(id_book)
    if id_book == nil then
        self.view_cache.sessions = {}
        return
    end
    self.view_cache.sessions[id_book] = nil
end

function SessionCleaner:_removeCachedBookEntry(id_book)
    local books_cache = self.view_cache.books
    if not books_cache or not books_cache.books then
        return
    end
    for index = #books_cache.books, 1, -1 do
        if books_cache.books[index].id_book == id_book then
            table.remove(books_cache.books, index)
            break
        end
    end
end

local function shallowCopyTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

function SessionCleaner:_buildBookSnapshotFromSessions(book, all_sessions)
    local updated_book = shallowCopyTable(book)
    local raw_rows = 0
    local last_activity = 0

    for _, session in ipairs(all_sessions or {}) do
        raw_rows = raw_rows + (tonumber(session.row_count) or #(session.rowids or {}))
        for _, row in ipairs(session.rows or {}) do
            local row_start = tonumber(row.start_time) or 0
            if row_start > last_activity then
                last_activity = row_start
            end
        end
    end

    updated_book.raw_rows = raw_rows
    updated_book.last_activity = last_activity
    updated_book.session_count = #(all_sessions or {})
    updated_book.suspect_count = self.runtime.Presenter:countSuspectSessions(all_sessions)
    return updated_book
end

-- Apply destructive edits to the current in-memory view model first. This is
-- the cache path that improves perceived responsiveness: once SQLite confirms
-- the delete, the UI no longer needs to re-read the same book immediately just
-- to rediscover state it already had loaded.
function SessionCleaner:_applyDeletedSessionsToCache(book, all_sessions, deleted_sessions)
    local deleted_lookup = {}
    for _, session in ipairs(deleted_sessions or {}) do
        deleted_lookup[self:_sessionKey(session)] = true
    end

    local remaining_sessions = {}
    for _, session in ipairs(all_sessions or {}) do
        if not deleted_lookup[self:_sessionKey(session)] then
            remaining_sessions[#remaining_sessions + 1] = session
        end
    end

    if #remaining_sessions == 0 then
        self:_invalidateSessionCache(book.id_book)
        self:_removeCachedBookEntry(book.id_book)
        return nil, nil, nil
    end

    local updated_book = self:_buildBookSnapshotFromSessions(book, remaining_sessions)
    local session_entry = self:_storeSessionCache(book.id_book, updated_book, remaining_sessions)
    self:_updateCachedBookEntry(updated_book, remaining_sessions)
    return updated_book, remaining_sessions, self:_getCachedFilteredSessions(session_entry)
end

function SessionCleaner:invalidateAllDataCaches()
    self:_invalidateBooksCache()
    self:_invalidateSessionCache()
end

function SessionCleaner:_storeSessionCache(id_book, book, all_sessions)
    local cache_entry = {
        opts_key = self:_sessionOptsKey(),
        book = book,
        all_sessions = all_sessions,
        filtered_by_filter = {},
    }
    self.view_cache.sessions[id_book] = cache_entry
    return cache_entry
end

function SessionCleaner:_getCachedFilteredSessions(session_entry)
    local filter_name = self.settings.session_filter or "all"
    local filtered = session_entry.filtered_by_filter[filter_name]
    if not filtered then
        filtered = self.runtime.Sessions:filter(session_entry.all_sessions, filter_name)
        session_entry.filtered_by_filter[filter_name] = filtered
    end
    return filtered
end

function SessionCleaner:_updateCachedBookEntry(book, all_sessions)
    local books_cache = self.view_cache.books
    if not books_cache or not books_cache.books then
        return
    end

    local filtered_books = self.runtime.Presenter:filterBooks({ book }, self.settings.book_search)
    local index_to_replace = nil
    for index, cached_book in ipairs(books_cache.books) do
        if cached_book.id_book == book.id_book then
            index_to_replace = index
            break
        end
    end

    if #filtered_books == 0 then
        if index_to_replace then
            table.remove(books_cache.books, index_to_replace)
        end
        return
    end

    local updated_book = filtered_books[1]
    updated_book.session_count = #all_sessions
    updated_book.suspect_count = self.runtime.Presenter:countSuspectSessions(all_sessions)

    if index_to_replace then
        books_cache.books[index_to_replace] = updated_book
    else
        books_cache.books[#books_cache.books + 1] = updated_book
    end

    -- Keep the cached browse order aligned with DB:listBooks(): newest activity
    -- first, then title for ties. This prevents "go back to books" from
    -- feeling instant but visually wrong after a deletion changes last_activity.
    table.sort(books_cache.books, function(a, b)
        local a_time = tonumber(a.last_activity) or 0
        local b_time = tonumber(b.last_activity) or 0
        if a_time ~= b_time then
            return a_time > b_time
        end
        return string.lower(tostring(a.title or "")) < string.lower(tostring(b.title or ""))
    end)
end

-- Rebuild just one book after a destructive edit. This is the key cache win:
-- returning to the books page no longer forces a full-library recount.
function SessionCleaner:refreshBookAndSessionCache(id_book)
    local book, book_err = self.runtime.DB:getBook(id_book)
    if not book then
        self:_invalidateSessionCache(id_book)
        self:_invalidateBooksCache()
        return nil, nil, nil, book_err
    end

    local rows, rows_err = self.runtime.DB:listRawRowsForBook(id_book)
    if not rows then
        self:_invalidateSessionCache(id_book)
        self:_invalidateBooksCache()
        return nil, nil, nil, rows_err
    end

    local all_sessions = self.runtime.Sessions:reconstruct(rows, self:_sessionOpts())
    book.session_count = #all_sessions
    book.suspect_count = self.runtime.Presenter:countSuspectSessions(all_sessions)

    local session_entry = self:_storeSessionCache(id_book, book, all_sessions)
    self:_updateCachedBookEntry(book, all_sessions)

    return book, all_sessions, self:_getCachedFilteredSessions(session_entry), nil
end

function SessionCleaner:showWidget(widget)
    if self.current_widget and self.current_widget ~= widget then
        pcall(function()
            UIManager:close(self.current_widget)
        end)
    end
    self.current_widget = widget
    UIManager:show(widget)
end

function SessionCleaner:validateDatabaseOrExplain()
    if not self:_ensureRuntimeReady() then
        return false
    end

    local DB = self.runtime.DB
    local UI = self.runtime.UI

    if not DB:exists() then
        UI:showInfo(T(_("Statistics database not found:\n%1"), DB:getPath()))
        return false
    end

    local ok, info_or_err = DB:validateSchema()
    if not ok then
        UI:showInfo(T(_("Unsupported or incomplete statistics schema.\n\n%1"), tostring(info_or_err)))
        return false
    end

    return true, info_or_err
end

function SessionCleaner:_rememberCurrentBookPage()
    if self.current_widget and self.current_widget.page then
        self.book_menu_page = self.current_widget.page
    end
end

function SessionCleaner:_rememberCurrentSessionPage(id_book)
    if self.current_widget and self.current_widget.page then
        self.session_menu_pages[id_book] = self.current_widget.page
    end
end

function SessionCleaner:createBackupNow(after_callback)
    local ok, backup_or_err = self.runtime.DB:createBackup()
    if ok then
        self.runtime.UI:showNotification(T(_("Backup created:\n%1"), tostring(backup_or_err)))
        if after_callback then
            after_callback(true, backup_or_err)
        end
    else
        self.runtime.UI:showInfo(T(_("Backup failed:\n%1"), tostring(backup_or_err)))
        if after_callback then
            after_callback(false, backup_or_err)
        end
    end
end

function SessionCleaner:promptBookSearch(reopen_callback)
    self.runtime.UI:showInput{
        title = _("Search books"),
        description = _("Filter the book list by title or author. Leave empty to show every book with statistics."),
        input = self.settings.book_search or "",
        input_hint = _("Type part of a title or author"),
        ok_text = _("Apply"),
        clear_text = _("Show all"),
        clear_callback = function(dialog)
            UIManager:close(dialog)
            self.settings.book_search = ""
            self.book_menu_page = 1
            self:_invalidateBooksCache()
            self:saveSettings()
            reopen_callback()
        end,
        ok_callback = function(value)
            self.settings.book_search = self.runtime.Util.trim(value)
            self.book_menu_page = 1
            self:_invalidateBooksCache()
            self:saveSettings()
            reopen_callback()
        end,
    }
end

function SessionCleaner:promptSessionGap(reopen_callback)
    self.runtime.UI:showInput{
        title = _("Session gap"),
        description = _("If the pause between one raw row and the next is greater than this many minutes, Session Cleaner starts a new reconstructed session."),
        input = tostring(self.settings.session_gap_minutes or 30),
        input_hint = _("Minutes"),
        ok_text = _("Save"),
        clear_text = _("Default"),
        clear_callback = function(dialog)
            UIManager:close(dialog)
            self.settings.session_gap_minutes = 30
            self:invalidateAllDataCaches()
            self:saveSettings()
            reopen_callback()
        end,
        ok_callback = function(value)
            local minutes = tonumber(value)
            if not minutes or minutes < 1 then
                self.runtime.UI:showInfo(_("Please enter a number of minutes greater than zero."))
                reopen_callback()
                return
            end
            self.settings.session_gap_minutes = math.floor(minutes)
            self:invalidateAllDataCaches()
            self:saveSettings()
            reopen_callback()
        end,
    }
end

function SessionCleaner:promptShortThreshold(reopen_callback)
    self.runtime.UI:showInput{
        title = _("Short threshold"),
        description = _("Sessions at or below this many seconds are considered short. This only affects filtering and cleanup decisions. It does not delete anything by itself."),
        input = tostring(self.settings.short_session_seconds or 120),
        input_hint = _("Seconds"),
        ok_text = _("Save"),
        clear_text = _("Default"),
        clear_callback = function(dialog)
            UIManager:close(dialog)
            self.settings.short_session_seconds = 120
            self:invalidateAllDataCaches()
            self:saveSettings()
            reopen_callback()
        end,
        ok_callback = function(value)
            local seconds = tonumber(value)
            if not seconds or seconds < 0 then
                self.runtime.UI:showInfo(_("Please enter zero or a positive number of seconds."))
                reopen_callback()
                return
            end
            self.settings.short_session_seconds = math.floor(seconds)
            self:invalidateAllDataCaches()
            self:saveSettings()
            reopen_callback()
        end,
    }
end

function SessionCleaner:toggleAutomaticBackup(reopen_callback)
    self.settings.auto_backup_before_delete = not self.settings.auto_backup_before_delete
    self:saveSettings()
    reopen_callback()
end

function SessionCleaner:showSettingExplanation(topic)
    local Presenter = self.runtime.Presenter
    local texts = {
        session_gap = T(_([[Session gap controls how raw rows are grouped into reconstructed sessions.

Current gap: %1

If the pause between one raw row and the next is greater than this value, Session Cleaner starts a new session.

Smaller values split activity into more sessions.
Larger values merge nearby activity into fewer sessions.

Changing this setting never edits the database. It only changes reconstruction in the interface.]]), Presenter:formatGapLabel(self.settings.session_gap_minutes)),
        short_threshold = T(_([[Short threshold controls which sessions count as short.

Current threshold: %1

This is a secondary cleanup heuristic. It helps surface tiny accidental sessions.
It never deletes anything by itself.]]), Presenter:formatShortLabel(self.settings.short_session_seconds)),
        filter = T(_([[Filter changes which reconstructed sessions are visible.

Current filter: %1

All sessions shows everything.
No page advance shows sessions where first and last page are the same.
Short sessions shows sessions at or below the short threshold.
No advance OR short is the broadest suspect view.

Changing the filter never edits the database.]]), Presenter.FILTER_LABELS[self.settings.session_filter or "all"] or Presenter.FILTER_LABELS.all),
        auto_backup = T(_([[Automatic backup creates a fresh copy of statistics.sqlite3 before a deletion runs.

Current state: %1

When this is on, deletion is slower but safer.
If backup creation fails, the deletion is cancelled.]]), Presenter:formatAutoBackupLabel(self.settings.auto_backup_before_delete)),
        ui_scale = T(_([[UI scale changes the Menu font sizes and row density across the plugin.

Current preset: %1

Ultra Tiny fits the most information on screen.
Compact is slightly denser than Normal.
Large improves readability at the cost of fewer rows per page.

This changes presentation only. It never edits the database.]]), Presenter:formatUIScaleLabel(self.settings.ui_scale)),
        backup_now = T(_([[Create backup now writes a manual safety copy of statistics.sqlite3.

Backups are stored in:
%1

Use this before your first cleanup pass or before aggressive experiments with session reconstruction.]]), tostring(self.runtime.DB.backup_dir or "")),
        deleting = _([[Tap a session to inspect it before deletion.

Selection mode lets you mark several sessions and delete them together.
Deletion removes the real raw rows from page_stat_data using the exact SQLite rowids tracked for those reconstructed sessions.

This is permanent unless you restore from backup.]]),
    }
    self.runtime.UI:showInfo(texts[topic] or _("No explanation available."))
end

function SessionCleaner:openHelpMenu(return_callback)
    local Renderer = self.runtime.Renderer
    local items = {
        Renderer:makeActionRow(_("Session gap"), nil, function() self:showSettingExplanation("session_gap") end),
        Renderer:makeActionRow(_("Short threshold"), nil, function() self:showSettingExplanation("short_threshold") end),
        Renderer:makeActionRow(_("Filter"), nil, function() self:showSettingExplanation("filter") end),
        Renderer:makeActionRow(_("Automatic backup"), nil, function() self:showSettingExplanation("auto_backup") end),
        Renderer:makeActionRow(_("UI scale"), nil, function() self:showSettingExplanation("ui_scale") end),
        Renderer:makeActionRow(_("Create backup now"), nil, function() self:showSettingExplanation("backup_now") end),
        Renderer:makeActionRow(_("Deleting sessions"), nil, function() self:showSettingExplanation("deleting") end),
    }
    local menu = self.runtime.Renderer:createMenu{
        kind = "compact",
        ui_scale = self.settings.ui_scale,
        title = _("Help"),
        subtitle = _("What each control does"),
        left_icon = "back.top",
        item_table = items,
        on_left_button = return_callback,
        on_return = return_callback,
    }
    self:showWidget(menu)
end

function SessionCleaner:openSettingsMenu(return_callback)
    local Renderer = self.runtime.Renderer
    local Presenter = self.runtime.Presenter

    local items = {
        Renderer:makeActionRow(_("Session gap"), Presenter:formatGapLabel(self.settings.session_gap_minutes), function()
            self:promptSessionGap(function() self:openSettingsMenu(return_callback) end)
        end, { with_dots = true }),
        Renderer:makeActionRow(_("Short threshold"), Presenter:formatShortLabel(self.settings.short_session_seconds), function()
            self:promptShortThreshold(function() self:openSettingsMenu(return_callback) end)
        end, { with_dots = true }),
        Renderer:makeActionRow(_("Automatic backup"), Presenter:formatAutoBackupLabel(self.settings.auto_backup_before_delete), function()
            self:toggleAutomaticBackup(function() self:openSettingsMenu(return_callback) end)
        end, { with_dots = true }),
        Renderer:makeActionRow(_("UI scale"), Presenter:formatUIScaleLabel(self.settings.ui_scale), function()
            self:openUIScalePicker(function() self:openSettingsMenu(return_callback) end)
        end, { with_dots = true }),
        Renderer:makeActionRow(_("Create backup now"), _("Run"), function()
            self:createBackupNow(function() self:openSettingsMenu(return_callback) end)
        end, { with_dots = true }),
        Renderer:makeActionRow(_("Help"), nil, function()
            self:openHelpMenu(function() self:openSettingsMenu(return_callback) end)
        end),
    }

    local menu = Renderer:createMenu{
        kind = "compact",
        ui_scale = self.settings.ui_scale,
        title = _("Settings"),
        subtitle = _("Reconstruction and safety"),
        left_icon = "back.top",
        item_table = items,
        on_left_button = return_callback,
        on_return = return_callback,
    }
    self:showWidget(menu)
end

function SessionCleaner:openFilterPicker(id_book)
    local Renderer = self.runtime.Renderer
    local Presenter = self.runtime.Presenter
    local items = {}
    for _, name in ipairs(Presenter.FILTER_ORDER) do
        local prefix = (self.settings.session_filter or "all") == name and "✓ " or ""
        items[#items + 1] = Renderer:makeActionRow(prefix .. (Presenter.FILTER_LABELS[name] or name), nil, function()
            self.settings.session_filter = name
            self:saveSettings()
            self.session_menu_pages[id_book] = 1
            self:openSessionBrowser(id_book)
        end)
    end

    local menu = Renderer:createMenu{
        kind = "compact",
        ui_scale = self.settings.ui_scale,
        title = _("Filter"),
        subtitle = _("Choose which sessions to show"),
        left_icon = "back.top",
        item_table = items,
        on_left_button = function() self:openSessionBrowser(id_book) end,
        on_return = function() self:openSessionBrowser(id_book) end,
    }
    self:showWidget(menu)
end

function SessionCleaner:openUIScalePicker(return_callback)
    local Renderer = self.runtime.Renderer
    local Presenter = self.runtime.Presenter
    local items = {}

    for _, name in ipairs(Presenter.UI_SCALE_ORDER) do
        local prefix = (self.settings.ui_scale or "normal") == name and "✓ " or ""
        items[#items + 1] = Renderer:makeActionRow(prefix .. Presenter:formatUIScaleLabel(name), nil, function()
            self.settings.ui_scale = name
            self:saveSettings()
            return_callback()
        end)
    end

    local menu = Renderer:createMenu{
        kind = "compact",
        ui_scale = self.settings.ui_scale,
        title = _("UI scale"),
        subtitle = _("Choose interface size"),
        left_icon = "back.top",
        item_table = items,
        on_left_button = return_callback,
        on_return = return_callback,
    }
    self:showWidget(menu)
end

function SessionCleaner:_sessionOpts()
    return {
        session_gap_minutes = self.settings.session_gap_minutes,
        short_session_seconds = self.settings.short_session_seconds,
    }
end

function SessionCleaner:_sessionKey(session)
    return self.runtime.Util.joinNumericList(session and session.rowids or {})
end

function SessionCleaner:_selectionState(id_book, create_if_missing)
    if self.session_selection and self.session_selection.book_id == id_book then
        return self.session_selection
    end
    if create_if_missing then
        self.session_selection = {
            book_id = id_book,
            keys = {},
        }
        return self.session_selection
    end
    return nil
end

function SessionCleaner:isSelectionMode(id_book)
    local selection = self:_selectionState(id_book, false)
    return selection ~= nil
end

function SessionCleaner:clearSessionSelection(id_book)
    if not id_book or (self.session_selection and self.session_selection.book_id == id_book) then
        self.session_selection = nil
    end
end

function SessionCleaner:startSessionSelection(id_book)
    self:_selectionState(id_book, true)
end

function SessionCleaner:toggleSessionSelection(id_book, session)
    local selection = self:_selectionState(id_book, true)
    local key = self:_sessionKey(session)
    if key == "" then
        return
    end
    selection.keys[key] = not selection.keys[key] or nil
    if next(selection.keys) == nil then
        self.session_selection = nil
    end
end

function SessionCleaner:isSessionSelected(id_book, session)
    local selection = self:_selectionState(id_book, false)
    if not selection then
        return false
    end
    return selection.keys[self:_sessionKey(session)] and true or false
end

function SessionCleaner:countSelectedSessions(id_book, all_sessions)
    local selection = self:_selectionState(id_book, false)
    if not selection then
        return 0
    end
    local count = 0
    for _, session in ipairs(all_sessions or {}) do
        if selection.keys[self:_sessionKey(session)] then
            count = count + 1
        end
    end
    return count
end

function SessionCleaner:selectAllVisibleSessions(id_book, visible_sessions)
    local selection = self:_selectionState(id_book, true)
    for _, session in ipairs(visible_sessions or {}) do
        local key = self:_sessionKey(session)
        if key ~= "" then
            selection.keys[key] = true
        end
    end
end

function SessionCleaner:collectSelectedRowids(id_book, all_sessions)
    local selection = self:_selectionState(id_book, false)
    if not selection then
        return {}, 0
    end

    local rowids = {}
    local session_count = 0
    for _, session in ipairs(all_sessions or {}) do
        if selection.keys[self:_sessionKey(session)] then
            session_count = session_count + 1
            for _, rowid in ipairs(session.rowids or {}) do
                rowids[#rowids + 1] = rowid
            end
        end
    end

    return dedupeNumericRowids(rowids), session_count
end

-- Recompute session counts from the preserved engine so the book browser always
-- reflects the current reconstruction settings without duplicating DB logic.
-- The expensive full-library recount is cached until a search or reconstruction
-- setting changes.
function SessionCleaner:loadBooksWithCounts()
    local cache_key = self:_bookCacheKey()
    local books_cache = self.view_cache.books
    if books_cache and books_cache.key == cache_key and books_cache.books then
        return books_cache.books
    end

    local books, err = self.runtime.DB:listBooks()
    if not books then
        return nil, err
    end

    books = self.runtime.Presenter:filterBooks(books, self.settings.book_search)

    for _, book in ipairs(books) do
        local session_cache = self.view_cache.sessions[book.id_book]
        if session_cache and session_cache.opts_key == self:_sessionOptsKey() and session_cache.all_sessions then
            book.session_count = #session_cache.all_sessions
            book.suspect_count = self.runtime.Presenter:countSuspectSessions(session_cache.all_sessions)
        else
            local rows = self.runtime.DB:listRawRowsForBook(book.id_book)
            if rows then
                local sessions = self.runtime.Sessions:reconstruct(rows, self:_sessionOpts())
                book.session_count = #sessions
                book.suspect_count = self.runtime.Presenter:countSuspectSessions(sessions)
            else
                book.session_count = 0
                book.suspect_count = 0
            end
        end
    end

    self.view_cache.books = {
        key = cache_key,
        books = books,
    }
    return books
end

function SessionCleaner:loadSessionsForBook(id_book)
    local session_entry = self.view_cache.sessions[id_book]
    if session_entry and session_entry.opts_key == self:_sessionOptsKey() and session_entry.book and session_entry.all_sessions then
        return session_entry.book, session_entry.all_sessions, self:_getCachedFilteredSessions(session_entry), nil
    end

    local book, book_err = self.runtime.DB:getBook(id_book)
    if not book then
        return nil, nil, nil, book_err
    end

    local rows, rows_err = self.runtime.DB:listRawRowsForBook(id_book)
    if not rows then
        return nil, nil, nil, rows_err
    end

    local sessions = self.runtime.Sessions:reconstruct(rows, self:_sessionOpts())
    book.session_count = #sessions
    book.suspect_count = self.runtime.Presenter:countSuspectSessions(sessions)

    session_entry = self:_storeSessionCache(id_book, book, sessions)
    return book, sessions, self:_getCachedFilteredSessions(session_entry), nil
end

-- Native Menu shell for the book browser. The card module controls row text,
-- while Menu handles fullscreen behavior and pagination.
function SessionCleaner:openBookBrowser()
    local ok = self:validateDatabaseOrExplain()
    if not ok then
        return
    end

    self:clearSessionSelection()

    local books, err = self:loadBooksWithCounts()
    if not books then
        self.runtime.UI:showInfo(T(_("Could not read books from statistics database.\n\n%1"), tostring(err)))
        return
    end

    local Presenter = self.runtime.Presenter
    local BookCards = self.runtime.BookCards
    local Renderer = self.runtime.Renderer

    local items = {
        Renderer:makeActionRow(_("Search books"), Presenter:formatSearchValue(self.settings.book_search), function()
            self:promptBookSearch(function() self:openBookBrowser() end)
        end, { with_dots = true }),
        Renderer:makeActionRow(_("Settings"), nil, function()
            self:openSettingsMenu(function() self:openBookBrowser() end)
        end),
        Renderer:makeActionRow(_("Create backup now"), _("Run"), function()
            self:createBackupNow(function() self:openBookBrowser() end)
        end, { with_dots = true }),
    }

    if #books == 0 then
        items[#items + 1] = Renderer:makeInfoRow(
            self.runtime.Util.isEmpty(self.settings.book_search) and _("No books with statistics were found.") or _("Nothing matches the current search."),
            nil,
            { dim = false }
        )
    else
        for _, book in ipairs(books) do
            local card = BookCards:build(Presenter:makeBookSpec(book), self.settings.ui_scale)
            items[#items + 1] = Renderer:makeBookRow(card, function()
                self:_rememberCurrentBookPage()
                self:openSessionBrowser(book.id_book)
            end)
        end
    end

    local menu = Renderer:createMenu{
        kind = "books",
        ui_scale = self.settings.ui_scale,
        title = _("Session Cleaner"),
        subtitle = Presenter:formatBooks(#books),
        item_table = items,
        page = self.book_menu_page or 1,
    }
    self:showWidget(menu)
end

function SessionCleaner:confirmDeleteSession(book, session, all_sessions, on_done)
    local confirm_text = T(_([[This action is destructive.

Book: %1

Session: %2 → %3
Pages: %4 → %5
Progress delta: %6
Raw database rows to delete: %7

Delete this session from statistics.sqlite3 now?]]),
        tostring(book.title),
        self.runtime.Util.formatDateTime(session.start_time),
        self.runtime.Util.formatDateTime(session.end_time),
        tostring(session.first_page or "-"),
        tostring(session.last_page or "-"),
        self.runtime.Util.formatSignedInt(session.progress_delta or 0),
        tostring(session.row_count or 0)
    )

    self.runtime.UI:showConfirm{
        text = confirm_text,
        ok_text = _("Delete session"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local function proceed()
                local deleted_count, delete_err = self.runtime.DB:deleteSessionRows(book.id_book, session.rowids)
                if not deleted_count then
                    self.runtime.UI:showInfo(T(_([[Delete failed:
%1]]), tostring(delete_err)))
                    return
                end

                local updated_book = nil
                if all_sessions and #all_sessions > 0 then
                    updated_book = self:_applyDeletedSessionsToCache(book, all_sessions, { session })
                else
                    local refreshed_book, _, _, refresh_err = self:refreshBookAndSessionCache(book.id_book)
                    if refresh_err then
                        self:_invalidateSessionCache(book.id_book)
                        self:_invalidateBooksCache()
                    end
                    updated_book = refreshed_book
                end

                self.runtime.UI:showNotification(T(_("Deleted %1 raw rows."), tostring(deleted_count)))
                self.session_menu_pages[book.id_book] = 1
                on_done(updated_book)
            end

            if self.settings.auto_backup_before_delete then
                local backup_ok, backup_or_err = self.runtime.DB:createBackup()
                if not backup_ok then
                    self.runtime.UI:showInfo(T(_([[Delete cancelled because backup failed.

%1]]), tostring(backup_or_err)))
                    return
                end
            end

            proceed()
        end,
    }
end

function SessionCleaner:confirmDeleteSelectedSessions(book, all_sessions, on_done)
    local rowids, selected_count = self:collectSelectedRowids(book.id_book, all_sessions)
    if selected_count == 0 or #rowids == 0 then
        self.runtime.UI:showInfo(_("No sessions are selected."))
        return
    end

    local confirm_text = T(_([[This action is destructive.

Book: %1
Selected sessions: %2
Raw database rows to delete: %3

Delete the selected sessions from statistics.sqlite3 now?]]),
        tostring(book.title),
        tostring(selected_count),
        tostring(#rowids)
    )

    self.runtime.UI:showConfirm{
        text = confirm_text,
        ok_text = _("Delete selected"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local function proceed()
                local deleted_count, delete_err = self.runtime.DB:deleteSessionRows(book.id_book, rowids)
                if not deleted_count then
                    self.runtime.UI:showInfo(T(_([[Delete failed:
%1]]), tostring(delete_err)))
                    return
                end

                local selected_lookup = {}
                for _, session in ipairs(all_sessions or {}) do
                    if self:isSessionSelected(book.id_book, session) then
                        selected_lookup[self:_sessionKey(session)] = true
                    end
                end

                local deleted_sessions = {}
                for _, session in ipairs(all_sessions or {}) do
                    if selected_lookup[self:_sessionKey(session)] then
                        deleted_sessions[#deleted_sessions + 1] = session
                    end
                end

                local updated_book = nil
                if #deleted_sessions > 0 then
                    updated_book = self:_applyDeletedSessionsToCache(book, all_sessions, deleted_sessions)
                else
                    local refreshed_book, _, _, refresh_err = self:refreshBookAndSessionCache(book.id_book)
                    if refresh_err then
                        self:_invalidateSessionCache(book.id_book)
                        self:_invalidateBooksCache()
                    end
                    updated_book = refreshed_book
                end

                self:clearSessionSelection(book.id_book)
                self.session_menu_pages[book.id_book] = 1
                self.runtime.UI:showNotification(T(_("Deleted %1 raw rows from %2 sessions."), tostring(deleted_count), tostring(selected_count)))
                on_done(updated_book)
            end

            if self.settings.auto_backup_before_delete then
                local backup_ok, backup_or_err = self.runtime.DB:createBackup()
                if not backup_ok then
                    self.runtime.UI:showInfo(T(_([[Delete cancelled because backup failed.

%1]]), tostring(backup_or_err)))
                    return
                end
            end

            proceed()
        end,
    }
end

-- The session browser keeps the same shell strategy as the book browser, but
-- adds optional selection mode for batch deletion.
function SessionCleaner:openSessionBrowser(id_book)
    local ok = self:validateDatabaseOrExplain()
    if not ok then
        return
    end

    local book, all_sessions, visible_sessions, err = self:loadSessionsForBook(id_book)
    if not book then
        self.runtime.UI:showInfo(T(_("Could not load sessions.\n\n%1"), tostring(err)))
        return
    end

    local Presenter = self.runtime.Presenter
    local Renderer = self.runtime.Renderer
    local SessionCards = self.runtime.SessionCards
    local selection_mode = self:isSelectionMode(id_book)
    local selected_count = self:countSelectedSessions(id_book, all_sessions)

    local subtitle
    if self.runtime.Util.isEmpty(book.authors) or book.authors == "N/A" then
        subtitle = tostring(book.title or _("Untitled"))
    else
        subtitle = tostring(book.title or _("Untitled")) .. " · " .. tostring(book.authors)
    end

    local items = {
        Renderer:makeInfoRow(Presenter:formatSessionSummary(book, all_sessions, visible_sessions, selected_count), nil),
        Renderer:makeActionRow(_("Filter"), Presenter.FILTER_LABELS[self.settings.session_filter or "all"] or Presenter.FILTER_LABELS.all, function()
            self:_rememberCurrentSessionPage(id_book)
            self:openFilterPicker(id_book)
        end, { with_dots = true }),
    }

    if selection_mode then
        items[#items + 1] = Renderer:makeActionRow(_("Delete selected"), tostring(selected_count), function()
            self:confirmDeleteSelectedSessions(book, all_sessions, function(updated_book)
                if updated_book then
                    self:openSessionBrowser(id_book)
                else
                    self:openBookBrowser()
                end
            end)
        end, { with_dots = true })
        items[#items + 1] = Renderer:makeActionRow(_("Select all shown"), tostring(#visible_sessions), function()
            self:selectAllVisibleSessions(id_book, visible_sessions)
            self:_rememberCurrentSessionPage(id_book)
            self:openSessionBrowser(id_book)
        end)
        items[#items + 1] = Renderer:makeActionRow(_("Cancel selection"), nil, function()
            self:clearSessionSelection(id_book)
            self:_rememberCurrentSessionPage(id_book)
            self:openSessionBrowser(id_book)
        end)
    else
        items[#items + 1] = Renderer:makeActionRow(_("Select sessions"), nil, function()
            self:startSessionSelection(id_book)
            self:_rememberCurrentSessionPage(id_book)
            self:openSessionBrowser(id_book)
        end)
    end

    items[#items + 1] = Renderer:makeActionRow(_("Settings"), nil, function()
        self:_rememberCurrentSessionPage(id_book)
        self:openSettingsMenu(function() self:openSessionBrowser(id_book) end)
    end)

    if #visible_sessions == 0 then
        items[#items + 1] = Renderer:makeInfoRow(_("No reconstructed sessions match the current filter."))
    else
        for index, session in ipairs(visible_sessions) do
            local spec = Presenter:makeSessionSpec(index, session)
            if selection_mode then
                spec.selection_marker = self:isSessionSelected(id_book, session) and "[x]" or "[ ]"
            end
            local card = SessionCards:build(spec, self.settings.ui_scale)
            items[#items + 1] = Renderer:makeSessionRow(card, function()
                self:_rememberCurrentSessionPage(id_book)
                if selection_mode then
                    self:toggleSessionSelection(id_book, session)
                    self:openSessionBrowser(id_book)
                else
                    self:openSessionDetail(book, session, index, all_sessions)
                end
            end)
        end
    end

    local menu = Renderer:createMenu{
        kind = "sessions",
        ui_scale = self.settings.ui_scale,
        title = _("Sessions"),
        subtitle = subtitle,
        left_icon = "back.top",
        item_table = items,
        page = self.session_menu_pages[id_book] or 1,
        on_left_button = function()
            self:clearSessionSelection(id_book)
            self:openBookBrowser()
        end,
        on_return = function()
            self:clearSessionSelection(id_book)
            self:openBookBrowser()
        end,
    }
    self:showWidget(menu)
end

-- Inspect view intentionally stays simple and readable. It is backed by the
-- exact rowids captured in the reconstructed session so deletion stays precise.
function SessionCleaner:openSessionDetail(book, session, visible_index, all_sessions)
    local Renderer = self.runtime.Renderer
    local Presenter = self.runtime.Presenter
    local items = {
        Renderer:makeActionRow(_("Delete this session"), Presenter:formatRows(session.row_count or 0), function()
            self:confirmDeleteSession(book, session, all_sessions, function(updated_book)
                if updated_book then
                    self:openSessionBrowser(book.id_book)
                else
                    self:openBookBrowser()
                end
            end)
        end, { with_dots = true }),
        Renderer:makeActionRow(_("Create backup now"), _("Run"), function()
            self:createBackupNow(function() self:openSessionDetail(book, session, visible_index, all_sessions) end)
        end, { with_dots = true }),
    }

    for _, row in ipairs(Presenter:makeSessionDetailRows(book, session)) do
        if row.multiline then
            items[#items + 1] = Renderer:makeInfoRow(row.label .. "\n" .. row.value)
        else
            items[#items + 1] = Renderer:makeInfoRow(row.label, row.value, { with_dots = true })
        end
    end

    items[#items + 1] = Renderer:makeInfoRow(_("Raw rows to delete"), nil, { bold = true })

    for index, row in ipairs(session.rows or {}) do
        local raw = Presenter:makeRawRowSpec(index, row)
        items[#items + 1] = Renderer:makeInfoRow(raw.text, raw.mandatory)
    end

    local menu = Renderer:createMenu{
        kind = "details",
        ui_scale = self.settings.ui_scale,
        title = _("Inspect session"),
        subtitle = Presenter:detailSubtitle(session),
        left_icon = "back.top",
        item_table = items,
        on_left_button = function() self:openSessionBrowser(book.id_book) end,
        on_return = function() self:openSessionBrowser(book.id_book) end,
    }
    self:showWidget(menu)
end

return SessionCleaner
