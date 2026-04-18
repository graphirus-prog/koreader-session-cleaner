local Util = require("sessioncleaner_util")

local Sessions = {}

local function newSession(id_book)
    return {
        id_book = id_book,
        rows = {},
        rowids = {},
        pages_seen = {},
        unique_pages = 0,
        row_count = 0,
        first_page = nil,
        last_page = nil,
        start_time = nil,
        end_time = nil,
        active_duration = 0,
        progress_delta = 0,
        no_page_advance = false,
        is_short = false,
    }
end

local function finalizeSession(session, short_threshold_seconds)
    if not session then
        return nil
    end

    session.progress_delta = (session.last_page or 0) - (session.first_page or 0)
    session.no_page_advance = (session.first_page or 0) == (session.last_page or 0)
    session.is_short = (session.active_duration or 0) <= (tonumber(short_threshold_seconds) or 0)

    return session
end

function Sessions:reconstruct(rows, opts)
    opts = opts or {}
    local session_gap_minutes = tonumber(opts.session_gap_minutes) or 30
    local short_session_seconds = tonumber(opts.short_session_seconds) or 120
    local gap_seconds = math.max(60, math.floor(session_gap_minutes * 60))

    rows = Util.sortByStartTimeThenRowid(rows or {})

    local sessions = {}
    local current = nil
    local prev_row = nil

    for _, row in ipairs(rows) do
        local row_start = Util.safeNumber(row.start_time)
        local row_duration = math.max(0, Util.safeNumber(row.duration))
        local row_end = row_start + row_duration

        local must_start_new = false
        if current == nil then
            must_start_new = true
        elseif prev_row ~= nil then
            local prev_end = Util.safeNumber(prev_row.start_time) + math.max(0, Util.safeNumber(prev_row.duration))
            local gap = row_start - prev_end
            if gap > gap_seconds then
                must_start_new = true
            end
        end

        if must_start_new then
            if current ~= nil then
                sessions[#sessions + 1] = finalizeSession(current, short_session_seconds)
            end
            current = newSession(row.id_book)
        end

        current.rows[#current.rows + 1] = row
        current.rowids[#current.rowids + 1] = row.rowid
        current.row_count = current.row_count + 1
        current.active_duration = current.active_duration + row_duration

        if current.start_time == nil or row_start < current.start_time then
            current.start_time = row_start
        end
        if current.end_time == nil or row_end > current.end_time then
            current.end_time = row_end
        end

        if current.first_page == nil then
            current.first_page = Util.safeNumber(row.page)
        end
        current.last_page = Util.safeNumber(row.page)

        if not current.pages_seen[row.page] then
            current.pages_seen[row.page] = true
            current.unique_pages = current.unique_pages + 1
        end

        prev_row = row
    end

    if current ~= nil then
        sessions[#sessions + 1] = finalizeSession(current, short_session_seconds)
    end

    return sessions
end

function Sessions:filter(sessions, filter_name)
    filter_name = filter_name or "all"
    local filtered = {}

    for _, session in ipairs(sessions or {}) do
        local keep = false
        if filter_name == "all" then
            keep = true
        elseif filter_name == "no_advance" then
            keep = session.no_page_advance
        elseif filter_name == "short" then
            keep = session.is_short
        elseif filter_name == "no_advance_or_short" then
            keep = session.no_page_advance or session.is_short
        else
            keep = true
        end

        if keep then
            filtered[#filtered + 1] = session
        end
    end

    return filtered
end

return Sessions
