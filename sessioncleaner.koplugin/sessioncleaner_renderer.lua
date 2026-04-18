local Menu = require("ui/widget/menu")

local Renderer = {}
Renderer.__index = Renderer

-- Centralized Menu presets keep row density consistent across the plugin.
-- The UI scale setting only swaps between these controlled values.
local SCALE_DEFAULTS = {
    ultra_tiny = {
        books = { items_per_page = 11, items_font_size = 13, items_mandatory_font_size = 10, items_max_lines = 2, multilines_forced = true },
        sessions = { items_per_page = 10, items_font_size = 13, items_mandatory_font_size = 10, items_max_lines = 2, multilines_forced = true },
        details = { items_per_page = 12, items_font_size = 13, items_mandatory_font_size = 10, items_max_lines = 2, multilines_forced = true },
        compact = { items_per_page = 10, items_font_size = 13, items_mandatory_font_size = 10, items_max_lines = 2, multilines_forced = true },
    },
    compact = {
        books = { items_per_page = 10, items_font_size = 14, items_mandatory_font_size = 11, items_max_lines = 2, multilines_forced = true },
        sessions = { items_per_page = 9, items_font_size = 14, items_mandatory_font_size = 11, items_max_lines = 2, multilines_forced = true },
        details = { items_per_page = 11, items_font_size = 13, items_mandatory_font_size = 10, items_max_lines = 2, multilines_forced = true },
        compact = { items_per_page = 10, items_font_size = 14, items_mandatory_font_size = 11, items_max_lines = 2, multilines_forced = true },
    },
    normal = {
        books = { items_per_page = 9, items_font_size = 15, items_mandatory_font_size = 12, items_max_lines = 2, multilines_forced = true },
        sessions = { items_per_page = 8, items_font_size = 15, items_mandatory_font_size = 11, items_max_lines = 2, multilines_forced = true },
        details = { items_per_page = 10, items_font_size = 14, items_mandatory_font_size = 11, items_max_lines = 2, multilines_forced = true },
        compact = { items_per_page = 9, items_font_size = 15, items_mandatory_font_size = 12, items_max_lines = 2, multilines_forced = true },
    },
    large = {
        books = { items_per_page = 8, items_font_size = 17, items_mandatory_font_size = 13, items_max_lines = 2, multilines_forced = true },
        sessions = { items_per_page = 7, items_font_size = 17, items_mandatory_font_size = 12, items_max_lines = 2, multilines_forced = true },
        details = { items_per_page = 9, items_font_size = 15, items_mandatory_font_size = 12, items_max_lines = 2, multilines_forced = true },
        compact = { items_per_page = 8, items_font_size = 16, items_mandatory_font_size = 12, items_max_lines = 2, multilines_forced = true },
    },
}

function Renderer:new()
    return setmetatable({}, self)
end

function Renderer:makeActionRow(text, mandatory, callback, opts)
    opts = opts or {}
    return {
        text = text,
        mandatory = mandatory,
        callback = callback,
        bold = opts.bold,
        dim = opts.dim,
        mandatory_dim = opts.mandatory_dim,
        with_dots = opts.with_dots,
        select_enabled = opts.select_enabled,
    }
end

function Renderer:makeInfoRow(text, mandatory, opts)
    opts = opts or {}
    return {
        text = text,
        mandatory = mandatory,
        bold = opts.bold,
        dim = opts.dim,
        mandatory_dim = opts.mandatory_dim,
        with_dots = opts.with_dots,
        select_enabled = false,
    }
end

function Renderer:makeBookRow(card, callback)
    return {
        text = card.text,
        mandatory = card.mandatory,
        callback = callback,
        bold = card.bold,
        mandatory_dim = card.mandatory_dim,
    }
end

function Renderer:makeSessionRow(card, callback)
    return {
        text = card.text,
        mandatory = card.mandatory,
        callback = callback,
        bold = card.bold,
        mandatory_dim = card.mandatory_dim,
    }
end

function Renderer:_menuDefaults(kind, ui_scale)
    local scale = SCALE_DEFAULTS[ui_scale or "normal"] or SCALE_DEFAULTS.normal
    return scale[kind] or scale.sessions
end

function Renderer:createMenu(spec)
    local defaults = self:_menuDefaults(spec.kind, spec.ui_scale)
    local menu = Menu:new{
        title = spec.title,
        subtitle = spec.subtitle,
        title_multilines = spec.title_multilines,
        title_bar_fm_style = true,
        title_bar_left_icon = spec.left_icon,
        item_table = spec.item_table or {},
        page = spec.page,
        items_per_page = spec.items_per_page or defaults.items_per_page,
        items_font_size = spec.items_font_size or defaults.items_font_size,
        items_mandatory_font_size = spec.items_mandatory_font_size or defaults.items_mandatory_font_size,
        items_max_lines = spec.items_max_lines or defaults.items_max_lines,
        multilines_forced = spec.multilines_forced ~= nil and spec.multilines_forced or defaults.multilines_forced,
    }

    if spec.on_left_button then
        function menu:onLeftButtonTap()
            spec.on_left_button()
        end
    end

    if spec.on_return then
        menu.onReturn = function()
            spec.on_return()
        end
    end

    return menu
end

return Renderer
