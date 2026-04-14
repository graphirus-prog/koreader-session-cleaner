--[[
Session Cleaner
Standalone KOReader plugin for browsing books with reading statistics,
reconstructing sessions from raw page_stat_data rows, creating backups,
and deleting unwanted sessions safely from statistics.sqlite3.
--]]

local Dispatcher = require("dispatcher")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")

local DB = require("sessioncleaner_db")
local Sessions = require("sessioncleaner_sessions")
local SettingsStore = require("sessioncleaner_settings")
local UI = require("sessioncleaner_ui")
local Util = require("sessioncleaner_util")

local T = ffiUtil.template

local FILTER_ORDER = {
    "all",
    "no_advance",
    "short",
    "no_advance_or_short",
}

local FILTER_LABELS = {
    all = _("All sessions"),
    no_advance = _("No page advance"),
    short = _("Short sessions"),
    no_advance_or_short = _("No advance OR short"),
}

local SessionCleaner = WidgetContainer:extend{
    name = "sessioncleaner",
    is_doc_only = false,
}

function SessionCleaner:init()
    self.settings = SettingsStore:load()
    self.current_widget = nil
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

function SessionCleaner:saveSettings()
    SettingsStore:save(self.settings)
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

function SessionCleaner:createBackupNow(after_callback)
    local ok, backup_or_err = DB:createBackup()
    if ok then
        UI:showNotification(T(_("Backup created:\n%1"), tostring(backup_or_err)))
        if after_callback then
            after_callback(true, backup_or_err)
        end
    else
        UI:showInfo(T(_("Backup failed:\n%1"), tostring(backup_or_err)))
        if after_callback then
            after_callback(false, backup_or_err)
        end
    end
end

function SessionCleaner:promptBookSearch(reopen_callback)
    UI:showInput{
        title = _("Search books"),
        description = _("Filter the book list by title or author. Leave empty to show every book with statistics."),
        input = self.settings.book_search or "",
        input_hint = _("Type part of a title or author"),
        ok_text = _("Apply"),
        clear_text = _("Show all"),
        clear_callback = function(dialog)
            UIManager:close(dialog)
            self.settings.book_search = ""
            self:saveSettings()
            reopen_callback()
        end,
        ok_callback = function(value)
            self.settings.book_search = Util.trim(value)
            self:saveSettings()
            reopen_callback()
        end,
    }
end

function SessionCleaner:promptSessionGap(reopen_callback)
    UI:showInput{
        title = _("Session gap"),
        description = _("If the pause between one raw row and the next is greater than this many minutes, Session Cleaner starts a new reconstructed session."),
        input = tostring(self.settings.session_gap_minutes or 30),
        input_hint = _("Minutes"),
        ok_text = _("Save"),
        clear_text = _("Default"),
        clear_callback = function(dialog)
            UIManager:close(dialog)
            self.settings.session_gap_minutes = 30
            self:saveSettings()
            reopen_callback()
        end,
        ok_callback = function(value)
            local minutes = tonumber(value)
            if not minutes or minutes < 1 then
                UI:showInfo(_("Please enter a number of minutes greater than zero."))
                reopen_callback()
                return
            end
            self.settings.session_gap_minutes = math.floor(minutes)
            self:saveSettings()
            reopen_callback()
        end,
    }
end

function SessionCleaner:promptShortThreshold(reopen_callback)
    UI:showInput{
        title = _("Short threshold"),
        description = _("Sessions at or below this many seconds are considered short. This only affects filtering and cleanup decisions. It does not delete anything by itself."),
        input = tostring(self.settings.short_session_seconds or 120),
        input_hint = _("Seconds"),
        ok_text = _("Save"),
        clear_text = _("Default"),
        clear_callback = function(dialog)
            UIManager:close(dialog)
            self.settings.short_session_seconds = 120
            self:saveSettings()
            reopen_callback()
        end,
        ok_callback = function(value)
            local seconds = tonumber(value)
            if not seconds or seconds < 0 then
                UI:showInfo(_("Please enter zero or a positive number of seconds."))
                reopen_callback()
                return
            end
            self.settings.short_session_seconds = math.floor(seconds)
            self:saveSettings()
            reopen_callback()
        end,
    }
end

function SessionCleaner:toggleAutomaticBackup(reopen_callback)
    self.settings.auto_backup_before_delete = not self.settings.auto_backup_before_delete
    self:saveSettings()
    if reopen_callback then
        reopen_callback()
    end
end

function SessionCleaner:formatSearchValue()
    if Util.isEmpty(self.settings.book_search) then
        return _("All books")
    end
    return self.settings.book_search
end

function SessionCleaner:formatGapValueLong()
    local minutes = tonumber(self.settings.session_gap_minutes or 30) or 30
    if minutes == 1 then
        return _("1 minute")
    end
    return T(_("%1 minutes"), tostring(minutes))
end

function SessionCleaner:formatShortValueLong()
    local seconds = tonumber(self.settings.short_session_seconds or 120) or 120
    if seconds == 1 then
        return _("1 second")
    end
    return T(_("%1 seconds"), tostring(seconds))
end

function SessionCleaner:formatAutoBackupValue()
    return self.settings.auto_backup_before_delete and _("On") or _("Off")
end

function SessionCleaner:formatRowWord(count)
    count = tonumber(count) or 0
    if count == 1 then
        return _("1 row")
    end
    return T(_("%1 rows"), tostring(count))
end

function SessionCleaner:formatBookSubtitle(book)
    local parts = {}
    if not Util.isEmpty(book.authors) and book.authors ~= "N/A" then
        parts[#parts + 1] = tostring(book.authors)
    else
        parts[#parts + 1] = _("Unknown author")
    end
    parts[#parts + 1] = self:formatRowWord(book.raw_rows or 0)
    if (book.suspect_count or 0) > 0 then
        if (book.suspect_count or 0) == 1 then
            parts[#parts + 1] = _("1 suspect")
        else
            parts[#parts + 1] = T(_("%1 suspect"), tostring(book.suspect_count))
        end
    end
    return table.concat(parts, " · ")
end

function SessionCleaner:formatSessionSummary(book, all_sessions, visible_sessions)
    local parts = {
        self:formatRowWord(book.raw_rows or 0),
    }
    if #all_sessions == 1 then
        parts[#parts + 1] = _("1 session")
    else
        parts[#parts + 1] = T(_("%1 sessions"), tostring(#all_sessions))
    end
    if (book.suspect_count or 0) == 1 then
        parts[#parts + 1] = _("1 suspect")
    elseif (book.suspect_count or 0) > 1 then
        parts[#parts + 1] = T(_("%1 suspect"), tostring(book.suspect_count))
    end
    if #visible_sessions ~= #all_sessions then
        parts[#parts + 1] = T(_("showing %1"), tostring(#visible_sessions))
    end
    return table.concat(parts, " · ")
end

function SessionCleaner:countSuspectSessions(sessions)
    local count = 0
    for _, session in ipairs(sessions or {}) do
        if session.no_page_advance or session.is_short then
            count = count + 1
        end
    end
    return count
end

function SessionCleaner:getFilteredBooks(books)
    local query = Util.trim(self.settings.book_search or "")
    if query == "" then
        return books
    end

    local filtered = {}
    for _, book in ipairs(books or {}) do
        if Util.containsInsensitive(book.title, query) or Util.containsInsensitive(book.authors, query) then
            filtered[#filtered + 1] = book
        end
    end
    return filtered
end

function SessionCleaner:enrichBooksWithSuspects(books)
    for _, book in ipairs(books or {}) do
        local rows = DB:listRawRowsForBook(book.id_book)
        if rows then
            local sessions = Sessions:reconstruct(rows, {
                session_gap_minutes = self.settings.session_gap_minutes,
                short_session_seconds = self.settings.short_session_seconds,
            })
            book.suspect_count = self:countSuspectSessions(sessions)
        else
            book.suspect_count = 0
        end
    end
end

function SessionCleaner:loadSessionsForBook(id_book)
    local book, book_err = DB:getBook(id_book)
    if not book then
        return nil, nil, nil, book_err
    end

    local rows, rows_err = DB:listRawRowsForBook(id_book)
    if not rows then
        return nil, nil, nil, rows_err
    end

    local sessions = Sessions:reconstruct(rows, {
        session_gap_minutes = self.settings.session_gap_minutes,
        short_session_seconds = self.settings.short_session_seconds,
    })
    local filtered = Sessions:filter(sessions, self.settings.session_filter)
    book.suspect_count = self:countSuspectSessions(sessions)

    return book, sessions, filtered, nil
end

function SessionCleaner:makeSection(text)
    return {
        text = text,
        bold = true,
        select_enabled = false,
    }
end

function SessionCleaner:makeInfo(text)
    return {
        text = text,
        select_enabled = false,
    }
end

function SessionCleaner:makeAction(text, mandatory, callback, opts)
    opts = opts or {}
    return {
        text = text,
        mandatory = mandatory,
        callback = callback,
        bold = opts.bold,
        select_enabled = opts.select_enabled,
    }
end

function SessionCleaner:showSettingExplanation(topic)
    local texts = {
        session_gap = T(_([[Session gap controls how raw rows are grouped into reconstructed sessions.

Current gap: %1

If the pause between one raw row and the next is greater than this value, Session Cleaner starts a new session.

Smaller values split activity into more sessions.
Larger values merge nearby activity into fewer sessions.

Changing this setting never edits the database. It only changes reconstruction in the interface.]]), self:formatGapValueLong()),
        short_threshold = T(_([[Short threshold controls which sessions count as short.

Current threshold: %1

This is a secondary cleanup heuristic. It helps surface tiny accidental sessions.
It never deletes anything by itself.]]), self:formatShortValueLong()),
        filter = T(_([[Filter changes which reconstructed sessions are visible.

Current filter: %1

All sessions shows everything.
No page advance shows sessions where first and last page are the same.
Short sessions shows sessions at or below the short threshold.
No advance OR short is the broadest suspect view.

Changing the filter never edits the database.]]), FILTER_LABELS[self.settings.session_filter or "all"] or FILTER_LABELS.all),
        auto_backup = T(_([[Automatic backup creates a fresh copy of statistics.sqlite3 before a deletion runs.

Current state: %1

When this is on, deletion is slower but safer.
If backup creation fails, the deletion is cancelled.]]), self:formatAutoBackupValue()),
        backup_now = T(_([[Create backup now writes a manual safety copy of statistics.sqlite3.

Backups are stored in:
%1

Use this before your first cleanup pass or before aggressive experiments with session reconstruction.]]), tostring(DB.backup_dir or "")),
        deleting = _([[Tap a session to review it and confirm deletion.

Deletion removes the real raw rows from page_stat_data using the exact SQLite rowids tracked for that reconstructed session.

This is permanent unless you restore from backup.]]),
    }
    UI:showInfo(texts[topic] or _("No explanation available."))
end

function SessionCleaner:openHelpMenu(return_callback)
    local menu = Menu:new{
        title = _("Help"),
        subtitle = _("What each control does"),
        title_bar_fm_style = true,
        title_bar_left_icon = "back.top",
        item_table = {
            self:makeAction(_("Session gap"), nil, function() self:showSettingExplanation("session_gap") end),
            self:makeAction(_("Short threshold"), nil, function() self:showSettingExplanation("short_threshold") end),
            self:makeAction(_("Filter"), nil, function() self:showSettingExplanation("filter") end),
            self:makeAction(_("Automatic backup"), nil, function() self:showSettingExplanation("auto_backup") end),
            self:makeAction(_("Create backup now"), nil, function() self:showSettingExplanation("backup_now") end),
            self:makeAction(_("Deleting sessions"), nil, function() self:showSettingExplanation("deleting") end),
        },
        items_per_page = 8,
        items_font_size = 17,
        items_mandatory_font_size = 14,
        items_max_lines = 2,
        multilines_forced = true,
    }
    function menu:onLeftButtonTap()
        return_callback()
    end
    menu.onReturn = function()
        return_callback()
    end
    self:showWidget(menu)
end

function SessionCleaner:openSettingsMenu(return_callback)
    local menu = Menu:new{
        title = _("Settings"),
        subtitle = _("How sessions are reconstructed and cleaned"),
        title_bar_fm_style = true,
        title_bar_left_icon = "back.top",
        item_table = {
            self:makeAction(_("Session gap"), self:formatGapValueLong(), function()
                self:promptSessionGap(function() self:openSettingsMenu(return_callback) end)
            end),
            self:makeAction(_("Short threshold"), self:formatShortValueLong(), function()
                self:promptShortThreshold(function() self:openSettingsMenu(return_callback) end)
            end),
            self:makeAction(_("Automatic backup"), self:formatAutoBackupValue(), function()
                self:toggleAutomaticBackup(function() self:openSettingsMenu(return_callback) end)
            end),
            self:makeAction(_("Create backup now"), _("Run"), function()
                self:createBackupNow(function() self:openSettingsMenu(return_callback) end)
            end),
            self:makeAction(_("Help"), nil, function()
                self:openHelpMenu(function() self:openSettingsMenu(return_callback) end)
            end),
        },
        items_per_page = 8,
        items_font_size = 17,
        items_mandatory_font_size = 14,
        items_max_lines = 2,
        multilines_forced = true,
    }
    function menu:onLeftButtonTap()
        return_callback()
    end
    menu.onReturn = function()
        return_callback()
    end
    self:showWidget(menu)
end

function SessionCleaner:openFilterPicker(id_book)
    local items = {}
    for _, name in ipairs(FILTER_ORDER) do
        local prefix = (self.settings.session_filter or "all") == name and "✓ " or ""
        items[#items + 1] = self:makeAction(prefix .. (FILTER_LABELS[name] or name), nil, function()
            self.settings.session_filter = name
            self:saveSettings()
            self:openSessionBrowser(id_book)
        end)
    end

    local menu = Menu:new{
        title = _("Filter"),
        subtitle = _("Choose which sessions to show"),
        title_bar_fm_style = true,
        title_bar_left_icon = "back.top",
        item_table = items,
        items_per_page = 8,
        items_font_size = 17,
        items_mandatory_font_size = 14,
        items_max_lines = 2,
        multilines_forced = true,
    }
    local plugin = self
    function menu:onLeftButtonTap()
        plugin:openSessionBrowser(id_book)
    end
    menu.onReturn = function()
        plugin:openSessionBrowser(id_book)
    end
    self:showWidget(menu)
end

function SessionCleaner:buildBookItems(books)
    local items = {
        self:makeAction(_("Search books"), self:formatSearchValue(), function()
            self:promptBookSearch(function() self:openBookBrowser() end)
        end),
        self:makeAction(_("Settings"), nil, function()
            self:openSettingsMenu(function() self:openBookBrowser() end)
        end),
        self:makeAction(_("Create backup now"), _("Run"), function()
            self:createBackupNow(function() self:openBookBrowser() end)
        end),
    }

    if #books == 0 then
        items[#items + 1] = self:makeInfo(
            Util.isEmpty(self.settings.book_search) and _("No books with statistics were found.") or _("Nothing matches the current search.")
        )
        return items
    end

    for _, book in ipairs(books) do
        local title = tostring(book.title or _("Untitled"))
        local subtitle = self:formatBookSubtitle(book)
        local text = title .. "\n" .. subtitle
        local mandatory = book.last_activity and Util.formatDate(book.last_activity) or nil
        items[#items + 1] = self:makeAction(text, mandatory, function()
            self:openSessionBrowser(book.id_book)
        end, { bold = false })
    end

    return items
end

function SessionCleaner:openBookBrowser()
    local ok = self:validateDatabaseOrExplain()
    if not ok then
        return
    end

    local books, err = DB:listBooks()
    if not books then
        UI:showInfo(T(_("Could not read books from statistics database.\n\n%1"), tostring(err)))
        return
    end

    books = self:getFilteredBooks(books)
    self:enrichBooksWithSuspects(books)

    local subtitle
    if #books == 1 then
        subtitle = _("1 book with statistics")
    else
        subtitle = T(_("%1 books with statistics"), tostring(#books))
    end

    local menu = Menu:new{
        title = _("Session Cleaner"),
        subtitle = subtitle,
        title_bar_fm_style = true,
        item_table = self:buildBookItems(books),
        items_per_page = 8,
        items_font_size = 17,
        items_mandatory_font_size = 14,
        items_max_lines = 2,
        multilines_forced = true,
    }
    self:showWidget(menu)
end

function SessionCleaner:formatSessionLine3(session)
    local parts = {
        string.format("p%s→%s", tostring(session.first_page or "-"), tostring(session.last_page or "-")),
        string.format("Δ%s", Util.formatSignedInt(session.progress_delta or 0)),
        Util.formatDuration(session.active_duration),
        self:formatRowWord(session.row_count or 0),
        T(_("uniq %1"), tostring(session.unique_pages or 0)),
    }
    return table.concat(parts, "   ")
end

function SessionCleaner:formatSessionLine4(session)
    local parts = {}
    if session.no_page_advance then
        parts[#parts + 1] = _("no advance")
    end
    if session.is_short then
        parts[#parts + 1] = _("short")
    end
    parts[#parts + 1] = self:formatSessionRange(session)
    return table.concat(parts, " · ")
end

function SessionCleaner:formatSessionRange(session)
    local total_pages = nil
    if session.rows and #session.rows > 0 then
        local last_row = session.rows[#session.rows]
        total_pages = tonumber(last_row.total_pages)
    end
    local first_page = tostring(session.first_page or "-")
    local last_page = tostring(session.last_page or "-")
    if total_pages and total_pages > 0 then
        return T(_("pp %1–%2 / %3"), first_page, last_page, tostring(total_pages))
    end
    return T(_("pp %1–%2"), first_page, last_page)
end

function SessionCleaner:formatSessionCard(index, session)
    local line1 = string.format("#%d   %s–%s", index, Util.formatClock(session.start_time), Util.formatClock(session.end_time))
    local line2 = self:formatSessionLine3(session)
    local line3 = self:formatSessionLine4(session)
    return table.concat({ line1, line2, line3 }, "\n")
end
function SessionCleaner:confirmDeleteSession(book, session, refresh_callback)
    local confirm_text = T(_([[This action is destructive.

Book: %1

Session: %2 → %3
Pages: %4 → %5
Unique pages: %6
Progress delta: %7
Raw database rows to delete: %8

Delete this session from statistics.sqlite3 now?]]),
        tostring(book.title),
        Util.formatDateTime(session.start_time),
        Util.formatDateTime(session.end_time),
        tostring(session.first_page or "-"),
        tostring(session.last_page or "-"),
        tostring(session.unique_pages or 0),
        Util.formatSignedInt(session.progress_delta or 0),
        tostring(session.row_count or 0)
    )

    UI:showConfirm{
        text = confirm_text,
        ok_text = _("Delete session"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local function proceedWithDelete()
                local deleted_count, delete_err = DB:deleteSessionRows(book.id_book, session.rowids)
                if not deleted_count then
                    UI:showInfo(T(_("Delete failed:\n%1"), tostring(delete_err)))
                    return
                end
                UI:showNotification(T(_("Deleted %1 raw rows."), tostring(deleted_count)))
                refresh_callback()
            end

            if self.settings.auto_backup_before_delete then
                local backup_ok, backup_or_err = DB:createBackup()
                if not backup_ok then
                    UI:showInfo(T(_("Delete cancelled because backup failed.\n\n%1"), tostring(backup_or_err)))
                    return
                end
                logger.dbg("SessionCleaner backup created:", backup_or_err)
            end

            proceedWithDelete()
        end,
    }
end

function SessionCleaner:buildSessionItems(book, all_sessions, visible_sessions, id_book)
    local items = {
        self:makeInfo(self:formatSessionSummary(book, all_sessions, visible_sessions)),
        self:makeAction(_("Filter"), FILTER_LABELS[self.settings.session_filter or "all"] or FILTER_LABELS.all, function()
            self:openFilterPicker(id_book)
        end),
        self:makeAction(_("Settings"), nil, function()
            self:openSettingsMenu(function() self:openSessionBrowser(id_book) end)
        end),
    }

    if #visible_sessions == 0 then
        items[#items + 1] = self:makeInfo(_("No reconstructed sessions match the current filter."))
        return items
    end

    for index, session in ipairs(visible_sessions) do
        local mandatory = Util.formatDate(session.start_time)
        items[#items + 1] = self:makeAction(self:formatSessionCard(index, session), mandatory, function()
            self:confirmDeleteSession(book, session, function()
                self:openSessionBrowser(id_book)
            end)
        end)
    end

    return items
end

function SessionCleaner:openSessionBrowser(id_book)
    local ok = self:validateDatabaseOrExplain()
    if not ok then
        return
    end

    local book, all_sessions, visible_sessions, err = self:loadSessionsForBook(id_book)
    if not book then
        UI:showInfo(T(_("Could not load sessions.\n\n%1"), tostring(err)))
        return
    end

    local subtitle
    if Util.isEmpty(book.authors) or book.authors == "N/A" then
        subtitle = tostring(book.title or _("Untitled"))
    else
        subtitle = tostring(book.title or _("Untitled")) .. " · " .. tostring(book.authors)
    end

    local menu = Menu:new{
        title = _("Sessions"),
        subtitle = subtitle,
        title_bar_fm_style = true,
        title_multilines = true,
        title_bar_left_icon = "back.top",
        item_table = self:buildSessionItems(book, all_sessions, visible_sessions, id_book),
        items_per_page = 6,
        items_font_size = 17,
        items_mandatory_font_size = 14,
        items_max_lines = 3,
        multilines_forced = true,
    }
    local plugin = self
    function menu:onLeftButtonTap()
        plugin:openBookBrowser()
    end
    menu.onReturn = function()
        plugin:openBookBrowser()
    end
    self:showWidget(menu)
end

return SessionCleaner
