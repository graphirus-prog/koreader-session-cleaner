local DataStorage = require("datastorage")
local Device = require("device")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Util = require("sessioncleaner_util")

local DB = {
    db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3",
    backup_dir = DataStorage:getSettingsDir() .. "/statistics_backups",
}

local function withConnection(fn)
    local ok, result_a, result_b = pcall(function()
        local conn = SQ3.open(DB.db_path)
        if not conn then
            return nil, "cannot open statistics database"
        end
        local a, b = fn(conn)
        conn:close()
        return a, b
    end)
    if not ok then
        logger.err("SessionCleaner DB error:", result_a)
        return nil, result_a
    end
    return result_a, result_b
end

function DB:getPath()
    return self.db_path
end

function DB:exists()
    return Util.fileExists(self.db_path)
end

function DB:introspectSchema()
    return withConnection(function(conn)
        local tables = conn:exec([[
            SELECT name, type
            FROM sqlite_master
            WHERE type IN ('table', 'view')
            ORDER BY type, name;
        ]])
        local page_stat_info = conn:exec("PRAGMA table_info('page_stat_data');")
        local book_info = conn:exec("PRAGMA table_info('book');")
        local user_version = conn:rowexec("PRAGMA user_version;")
        return {
            tables = tables,
            page_stat_info = page_stat_info,
            book_info = book_info,
            user_version = tonumber(user_version) or 0,
        }
    end)
end

function DB:validateSchema()
    local schema, err = self:introspectSchema()
    if not schema then
        return false, err
    end

    local has_page_stat_data = false
    local has_book = false
    if schema.tables and schema.tables.name then
        for i = 1, #(schema.tables.name) do
            local name = schema.tables.name[i]
            if name == "page_stat_data" then
                has_page_stat_data = true
            elseif name == "book" then
                has_book = true
            end
        end
    end

    if not has_page_stat_data then
        return false, "missing table: page_stat_data"
    end

    local required = {
        id_book = false,
        page = false,
        start_time = false,
        duration = false,
    }
    if schema.page_stat_info and schema.page_stat_info.name then
        for i = 1, #(schema.page_stat_info.name) do
            local name = schema.page_stat_info.name[i]
            if required[name] ~= nil then
                required[name] = true
            end
        end
    end

    for column, present in pairs(required) do
        if not present then
            return false, "missing column in page_stat_data: " .. column
        end
    end

    return true, {
        has_book = has_book,
        user_version = schema.user_version,
    }
end

function DB:listBooks()
    return withConnection(function(conn)
        local sql = [[
            SELECT
                psd.id_book AS id_book,
                COALESCE(NULLIF(b.title, ''), '[Book #' || psd.id_book || ']') AS title,
                COALESCE(NULLIF(b.authors, ''), 'N/A') AS authors,
                COUNT(psd.rowid) AS raw_rows,
                MAX(psd.start_time) AS last_activity,
                COALESCE(b.total_read_pages, 0) AS total_read_pages,
                COALESCE(b.total_read_time, 0) AS total_read_time
            FROM page_stat_data psd
            LEFT JOIN book b ON b.id = psd.id_book
            GROUP BY psd.id_book
            ORDER BY last_activity DESC, title COLLATE NOCASE ASC;
        ]]
        local result = conn:exec(sql)
        local books = {}
        if result == nil or result.id_book == nil then
            return books
        end
        for i = 1, #(result.id_book) do
            books[#books + 1] = {
                id_book = Util.safeNumber(result.id_book[i]),
                title = tostring(result.title[i] or ("Book #" .. tostring(result.id_book[i]))),
                authors = tostring(result.authors[i] or "N/A"),
                raw_rows = Util.safeNumber(result.raw_rows[i]),
                last_activity = Util.safeNumber(result.last_activity[i]),
                total_read_pages = Util.safeNumber(result.total_read_pages[i]),
                total_read_time = Util.safeNumber(result.total_read_time[i]),
            }
        end
        return books
    end)
end

function DB:getBook(id_book)
    return withConnection(function(conn)
        local sql = string.format([[
            SELECT
                psd.id_book AS id_book,
                COALESCE(NULLIF(b.title, ''), '[Book #%d]') AS title,
                COALESCE(NULLIF(b.authors, ''), 'N/A') AS authors,
                COUNT(psd.rowid) AS raw_rows,
                MAX(psd.start_time) AS last_activity,
                COALESCE(b.total_read_pages, 0) AS total_read_pages,
                COALESCE(b.total_read_time, 0) AS total_read_time
            FROM page_stat_data psd
            LEFT JOIN book b ON b.id = psd.id_book
            WHERE psd.id_book = %d
            GROUP BY psd.id_book;
        ]], tonumber(id_book) or 0, tonumber(id_book) or 0)
        local result = conn:exec(sql)
        if result == nil or result.id_book == nil or #(result.id_book) == 0 then
            return nil, "book not found"
        end
        return {
            id_book = Util.safeNumber(result.id_book[1]),
            title = tostring(result.title[1] or ("Book #" .. tostring(id_book))),
            authors = tostring(result.authors[1] or "N/A"),
            raw_rows = Util.safeNumber(result.raw_rows[1]),
            last_activity = Util.safeNumber(result.last_activity[1]),
            total_read_pages = Util.safeNumber(result.total_read_pages[1]),
            total_read_time = Util.safeNumber(result.total_read_time[1]),
        }
    end)
end

function DB:listRawRowsForBook(id_book)
    return withConnection(function(conn)
        local sql = string.format([[
            SELECT
                rowid AS rowid,
                id_book,
                page,
                start_time,
                duration,
                total_pages
            FROM page_stat_data
            WHERE id_book = %d
            ORDER BY start_time ASC, rowid ASC;
        ]], tonumber(id_book) or 0)
        local result = conn:exec(sql)
        local rows = {}
        if result == nil or result.rowid == nil then
            return rows
        end
        for i = 1, #(result.rowid) do
            rows[#rows + 1] = {
                rowid = Util.safeNumber(result.rowid[i]),
                id_book = Util.safeNumber(result.id_book[i]),
                page = Util.safeNumber(result.page[i]),
                start_time = Util.safeNumber(result.start_time[i]),
                duration = Util.safeNumber(result.duration[i]),
                total_pages = Util.safeNumber(result.total_pages[i]),
            }
        end
        return rows
    end)
end

function DB:checkpoint()
    return withConnection(function(conn)
        conn:exec("PRAGMA wal_checkpoint(TRUNCATE);")
        return true
    end)
end

function DB:createBackup()
    local ok, err = Util.ensureDir(self.backup_dir)
    if not ok then
        return false, err
    end

    local checkpoint_ok, checkpoint_err = self:checkpoint()
    if not checkpoint_ok then
        return false, checkpoint_err
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local backup_path = string.format("%s/statistics-%s.sqlite3", self.backup_dir, timestamp)

    local copied, copy_err = Util.copyFile(self.db_path, backup_path)
    if not copied then
        return false, copy_err
    end

    return true, backup_path
end

function DB:recomputeBookTotals(conn, id_book)
    local id = tonumber(id_book) or 0
    local read_pages, read_time = conn:rowexec(string.format([[
        SELECT count(DISTINCT page), COALESCE(sum(duration), 0)
        FROM page_stat
        WHERE id_book = %d;
    ]], id))
    read_pages = Util.safeNumber(read_pages)
    read_time = Util.safeNumber(read_time)

    local last_open = conn:rowexec(string.format([[
        SELECT COALESCE(MAX(start_time + duration), 0)
        FROM page_stat_data
        WHERE id_book = %d;
    ]], id))
    last_open = Util.safeNumber(last_open)

    conn:exec(string.format([[
        UPDATE book
        SET total_read_pages = %d,
            total_read_time = %d,
            last_open = %d
        WHERE id = %d;
    ]], read_pages, read_time, last_open, id))
end

function DB:deleteSessionRows(id_book, rowids)
    local numeric_rowids = {}
    for _, rowid in ipairs(rowids or {}) do
        local n = tonumber(rowid)
        if n then
            numeric_rowids[#numeric_rowids + 1] = math.floor(n)
        end
    end
    if #numeric_rowids == 0 then
        return false, "no valid rowids to delete"
    end

    return withConnection(function(conn)
        conn:exec("BEGIN IMMEDIATE;")
        local ok, result_or_err = pcall(function()
            local rowid_list = Util.joinNumericList(numeric_rowids)
            conn:exec("DELETE FROM page_stat_data WHERE rowid IN (" .. rowid_list .. ");")
            local deleted_count = conn:rowexec("SELECT changes();")
            deleted_count = Util.safeNumber(deleted_count)
            if deleted_count ~= #numeric_rowids then
                error(string.format("expected to delete %d rows, deleted %d", #numeric_rowids, deleted_count))
            end
            self:recomputeBookTotals(conn, id_book)
            conn:exec("COMMIT;")
            return deleted_count
        end)

        if not ok then
            conn:exec("ROLLBACK;")
            return nil, result_or_err
        end

        return result_or_err
    end)
end

return DB
