local SessionCards = {}
SessionCards.__index = SessionCards

--[[
Session Cleaner session row builder

Version history:
- v1.9.3
  * Relaxed truncation budgets so session rows reveal more factual detail
    before ellipsis on the stable native-Menu branch.
  * Preserved the compact single-row strategy to avoid breaking the current
    fullscreen layout, pagination, and selection mode.

Developer note:
The session browser needs to stay information-dense, especially when users are
looking for multiple bad sessions to delete. We therefore let the compact fact
string run longer before ellipsis, trusting Menu's own wrapping limits.
]]

local LIMITS = {
    ultra_tiny = { line = 132 },
    compact = { line = 122 },
    normal = { line = 114 },
    large = { line = 102 },
}

local function ellipsize(text, max_chars)
    text = tostring(text or "")
    if max_chars and #text > max_chars and max_chars > 1 then
        return text:sub(1, max_chars - 1) .. "…"
    end
    return text
end

function SessionCards:new()
    return setmetatable({}, self)
end

function SessionCards:build(session_spec, ui_scale)
    local limits = LIMITS[ui_scale or "normal"] or LIMITS.normal
    local main_text = string.format("%s · %s", session_spec.line1 or "", session_spec.line2 or "")

    if session_spec.selection_marker and session_spec.selection_marker ~= "" then
        main_text = session_spec.selection_marker .. " " .. main_text
    end

    return {
        kind = "session",
        text = ellipsize(main_text, limits.line),
        mandatory = session_spec.date_text,
        bold = false,
        mandatory_dim = false,
    }
end

return SessionCards
