local lfs = require("libs/libkoreader-lfs")

local Util = {}

function Util.safeNumber(value, default)
    local n = tonumber(value)
    if n == nil then
        return default or 0
    end
    return n
end

function Util.trim(text)
    if text == nil then
        return ""
    end
    return tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
end

function Util.isEmpty(text)
    return Util.trim(text) == ""
end

function Util.casefold(text)
    return tostring(text or ""):lower()
end

function Util.containsInsensitive(haystack, needle)
    haystack = Util.casefold(haystack)
    needle = Util.casefold(needle)
    if needle == "" then
        return true
    end
    return haystack:find(needle, 1, true) ~= nil
end

function Util.ensureDir(path)
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end
    local ok, err = lfs.mkdir(path)
    if ok then
        return true
    end
    return false, err or "mkdir failed"
end

function Util.fileExists(path)
    return lfs.attributes(path, "mode") == "file"
end

function Util.copyFile(src, dst)
    local in_f, err = io.open(src, "rb")
    if not in_f then
        return false, err or "cannot open source file"
    end

    local out_f, out_err = io.open(dst, "wb")
    if not out_f then
        in_f:close()
        return false, out_err or "cannot open destination file"
    end

    while true do
        local chunk = in_f:read(65536)
        if not chunk then
            break
        end
        local ok, write_err = out_f:write(chunk)
        if not ok then
            in_f:close()
            out_f:close()
            return false, write_err or "cannot write destination file"
        end
    end

    in_f:close()
    out_f:close()
    return true
end

function Util.arrayContains(arr, value)
    for _, item in ipairs(arr or {}) do
        if item == value then
            return true
        end
    end
    return false
end

function Util.shallowCopy(tbl)
    local out = {}
    for k, v in pairs(tbl or {}) do
        out[k] = v
    end
    return out
end

function Util.joinNumericList(numbers)
    local parts = {}
    for _, n in ipairs(numbers or {}) do
        local num = tonumber(n)
        if num then
            parts[#parts + 1] = tostring(math.floor(num))
        end
    end
    return table.concat(parts, ",")
end

function Util.sortByStartTimeThenRowid(rows)
    table.sort(rows, function(a, b)
        if a.start_time == b.start_time then
            return (a.rowid or 0) < (b.rowid or 0)
        end
        return (a.start_time or 0) < (b.start_time or 0)
    end)
    return rows
end

function Util.formatDate(ts)
    ts = Util.safeNumber(ts, 0)
    if ts <= 0 then
        return "----.--.--"
    end
    return os.date("%Y-%m-%d", ts)
end

function Util.formatClock(ts)
    ts = Util.safeNumber(ts, 0)
    if ts <= 0 then
        return "--:--"
    end
    return os.date("%H:%M", ts)
end

function Util.formatDateTime(ts)
    ts = Util.safeNumber(ts, 0)
    if ts <= 0 then
        return "----.--.-- --:--"
    end
    return os.date("%Y-%m-%d %H:%M", ts)
end

function Util.formatDuration(seconds)
    seconds = math.max(0, Util.safeNumber(seconds, 0))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format("%dh %02dm", h, m)
    elseif m > 0 then
        return string.format("%dm %02ds", m, s)
    else
        return string.format("%ds", s)
    end
end


function Util.formatDurationCompact(seconds)
    seconds = math.max(0, Util.safeNumber(seconds, 0))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        if m > 0 then
            return string.format("%dh %dm", h, m)
        end
        return string.format("%dh", h)
    elseif m > 0 then
        return string.format("%dm", m)
    end
    return string.format("%ds", s)
end

function Util.formatSignedInt(n)
    n = Util.safeNumber(n, 0)
    if n > 0 then
        return "+" .. tostring(n)
    end
    return tostring(n)
end

return Util
