local BookCards = {}
BookCards.__index = BookCards

--[[
Session Cleaner book row builder

Version history:
- v1.9.3
  * Changed the book identity separator from em dash to pipe ("|").
  * Relaxed truncation budgets so more title/author and metadata survive
    before ellipsis on the stable native-Menu branch.
  * Kept the row strategy conservative to avoid destabilizing KOReader
    Menu pagination and fullscreen behavior.

Developer note:
KOReader's Menu widget is our stable shell. These row builders intentionally
return one safe browse string plus the right-side mandatory date. The string is
allowed to wrap naturally within Menu's own layout limits, but we do not force
custom card widgets here in the stable branch.
]]

local LIMITS = {
    ultra_tiny = { line = 126 },
    compact = { line = 118 },
    normal = { line = 110 },
    large = { line = 98 },
}

local function ellipsize(text, max_chars)
    text = tostring(text or "")
    if max_chars and #text > max_chars and max_chars > 1 then
        return text:sub(1, max_chars - 1) .. "…"
    end
    return text
end

function BookCards:new()
    return setmetatable({}, self)
end

function BookCards:build(book_spec, ui_scale)
    local limits = LIMITS[ui_scale or "normal"] or LIMITS.normal

    -- Prefer a cleaner book identity line first: Title | Author. Metadata stays
    -- attached after that so short/medium entries can still show sessions and
    -- suspect counts without introducing a risky custom row renderer.
    local main_text = string.format("%s%s%s",
        book_spec.title or "",
        (book_spec.author and book_spec.author ~= "") and (" | " .. book_spec.author) or "",
        (book_spec.metadata and book_spec.metadata ~= "") and (" · " .. book_spec.metadata) or ""
    )

    return {
        kind = "book",
        text = ellipsize(main_text, limits.line),
        mandatory = book_spec.date_text,
        bold = false,
        mandatory_dim = false,
    }
end

return BookCards
