local _ = require("gettext")
local ffiUtil = require("ffi/util")

local T = ffiUtil.template

local Presenter = {}
Presenter.__index = Presenter

Presenter.FILTER_ORDER = {
    "all",
    "no_advance",
    "short",
    "no_advance_or_short",
}

Presenter.FILTER_LABELS = {
    all = _("All sessions"),
    no_advance = _("No page advance"),
    short = _("Short sessions"),
    no_advance_or_short = _("No advance OR short"),
}

-- UI scale presets are shared by the settings screen and the renderer.
-- Keeping the labels here lets the rest of the plugin stay presentation-focused.
Presenter.UI_SCALE_ORDER = {
    "ultra_tiny",
    "compact",
    "normal",
    "large",
}

Presenter.UI_SCALE_LABELS = {
    ultra_tiny = _("Ultra Tiny"),
    compact = _("Compact"),
    normal = _("Normal"),
    large = _("Large"),
}

function Presenter:new(util)
    return setmetatable({ Util = util }, self)
end

function Presenter:formatBooks(count)
    if count == 1 then
        return _("1 book with statistics")
    end
    return T(_("%1 books with statistics"), tostring(count))
end

function Presenter:formatRows(count)
    count = tonumber(count) or 0
    if count == 1 then
        return _("1 row")
    end
    return T(_("%1 rows"), tostring(count))
end

function Presenter:formatSessions(count)
    count = tonumber(count) or 0
    if count == 1 then
        return _("1 session")
    end
    return T(_("%1 sessions"), tostring(count))
end

function Presenter:formatFlagged(count)
    count = tonumber(count) or 0
    if count == 1 then
        return _("1 flagged")
    end
    return T(_("%1 flagged"), tostring(count))
end

function Presenter:formatGapLabel(minutes)
    minutes = tonumber(minutes) or 30
    if minutes == 1 then
        return _("1 minute")
    end
    return T(_("%1 minutes"), tostring(minutes))
end

function Presenter:formatShortLabel(seconds)
    seconds = tonumber(seconds) or 120
    if seconds == 1 then
        return _("1 second")
    end
    return T(_("%1 seconds"), tostring(seconds))
end

function Presenter:formatAutoBackupLabel(enabled)
    return enabled and _("On") or _("Off")
end

function Presenter:formatUIScaleLabel(scale_name)
    return self.UI_SCALE_LABELS[scale_name or "normal"] or self.UI_SCALE_LABELS.normal
end

function Presenter:formatSearchValue(query)
    query = self.Util.trim(query or "")
    if query == "" then
        return _("All books")
    end
    return query
end

function Presenter:filterBooks(books, query)
    query = self.Util.trim(query or "")
    if query == "" then
        return books
    end

    local filtered = {}
    for _, book in ipairs(books or {}) do
        if self.Util.containsInsensitive(book.title, query) or self.Util.containsInsensitive(book.authors, query) then
            filtered[#filtered + 1] = book
        end
    end
    return filtered
end

function Presenter:countSuspectSessions(sessions)
    local count = 0
    for _, session in ipairs(sessions or {}) do
        if session.no_page_advance or session.is_short then
            count = count + 1
        end
    end
    return count
end

function Presenter:makeBookMetadata(book)
    -- Avoid repeating "0 flagged" on every row. When there are no suspect
    -- sessions, the browse list stays calmer and lets the actual book identity
    -- do the work. We still surface flagged counts when they matter.
    local suspect_count = tonumber(book.suspect_count) or 0
    local parts = { self:formatSessions(book.session_count or 0) }
    if suspect_count > 0 then
        parts[#parts + 1] = self:formatFlagged(suspect_count)
    end
    return table.concat(parts, " · ")
end

function Presenter:makeBookSpec(book)
    local author = self.Util.trim(book.authors or "")
    if author == "" or author == "N/A" then
        author = _("Unknown author")
    end

    return {
        id_book = book.id_book,
        title = tostring(book.title or _("Untitled")),
        author = author,
        metadata = self:makeBookMetadata(book),
        date_text = self.Util.formatDate(book.last_activity),
    }
end

function Presenter:formatSessionSummary(book, all_sessions, visible_sessions, selected_count)
    -- The summary line keeps the most useful counts visible, but it also avoids
    -- adding a noisy "0 flagged" when there are no suspect sessions in the book.
    local parts = {
        self:formatRows(book.raw_rows or 0),
        self:formatSessions(#(all_sessions or {})),
    }

    local suspect_count = tonumber(book.suspect_count) or 0
    if suspect_count > 0 then
        parts[#parts + 1] = self:formatFlagged(suspect_count)
    end

    if #(visible_sessions or {}) ~= #(all_sessions or {}) then
        parts[#parts + 1] = T(_("showing %1"), tostring(#(visible_sessions or {})))
    end

    if (selected_count or 0) > 0 then
        if selected_count == 1 then
            parts[#parts + 1] = _("1 selected")
        else
            parts[#parts + 1] = T(_("%1 selected"), tostring(selected_count))
        end
    end

    return table.concat(parts, " · ")
end

function Presenter:formatSessionMetrics(session)
    return string.format("p%s→%s · Δ%s · %s",
        tostring(session.first_page or "-"),
        tostring(session.last_page or "-"),
        self.Util.formatSignedInt(session.progress_delta or 0),
        self.Util.formatDurationCompact(session.active_duration or 0)
    )
end

function Presenter:formatSessionFlagsCompact(session)
    local parts = {}
    if session.no_page_advance then
        parts[#parts + 1] = _("No adv.")
    end
    if session.is_short then
        parts[#parts + 1] = _("Short")
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " · ")
end

function Presenter:makeSessionSpec(index, session)
    -- Session rows are intentionally compact. The main browse line carries the
    -- index and time range; the secondary segment carries pages, delta, and
    -- duration, with short inline flags appended only when needed.
    local line2 = self:formatSessionMetrics(session)
    local flags = self:formatSessionFlagsCompact(session)
    if flags then
        line2 = line2 .. " · " .. flags
    end

    return {
        index = index,
        line1 = string.format("#%d  %s–%s", index, self.Util.formatClock(session.start_time), self.Util.formatClock(session.end_time)),
        line2 = line2,
        date_text = self.Util.formatDate(session.start_time),
        no_page_advance = session.no_page_advance,
        is_short = session.is_short,
    }
end

function Presenter:detailSubtitle(session)
    return string.format("%s · %s–%s",
        self.Util.formatDate(session.start_time),
        self.Util.formatClock(session.start_time),
        self.Util.formatClock(session.end_time)
    )
end

function Presenter:formatPageRange(session)
    local total_pages = nil
    if session.rows and #session.rows > 0 then
        total_pages = tonumber(session.rows[#session.rows].total_pages)
    end
    if total_pages and total_pages > 0 then
        return T(_("%1–%2 / %3"), tostring(session.first_page or "-"), tostring(session.last_page or "-"), tostring(total_pages))
    end
    return T(_("%1–%2"), tostring(session.first_page or "-"), tostring(session.last_page or "-"))
end

function Presenter:makeSessionDetailRows(book, session)
    return {
        {
            label = _("Book"),
            value = tostring(book.title or _("Untitled")),
            multiline = true,
        },
        {
            label = _("Date / time"),
            value = string.format("%s · %s–%s",
                self.Util.formatDate(session.start_time),
                self.Util.formatClock(session.start_time),
                self.Util.formatClock(session.end_time)
            ),
        },
        {
            label = _("Pages"),
            value = string.format("%s → %s · Δ%s · %s",
                tostring(session.first_page or "-"),
                tostring(session.last_page or "-"),
                self.Util.formatSignedInt(session.progress_delta or 0),
                self.Util.formatDuration(session.active_duration or 0)
            ),
        },
        {
            label = _("Rows / unique"),
            value = string.format("%s · %s",
                self:formatRows(session.row_count or 0),
                T(_("%1 unique pages"), tostring(session.unique_pages or 0))
            ),
        },
        {
            label = _("Full page range"),
            value = self:formatPageRange(session),
        },
    }
end

function Presenter:makeRawRowSpec(index, row)
    local page_text = tostring(row.page or "-")
    local total_pages = tonumber(row.total_pages)
    if total_pages and total_pages > 0 then
        page_text = string.format("p%s/%s", page_text, tostring(total_pages))
    else
        page_text = string.format("p%s", page_text)
    end

    return {
        text = string.format("#%d  %s · %s · %s",
            index,
            self.Util.formatDateTime(row.start_time),
            page_text,
            self.Util.formatDuration(row.duration)
        ),
        mandatory = string.format("rowid %s", tostring(row.rowid or "-")),
    }
end

return Presenter
