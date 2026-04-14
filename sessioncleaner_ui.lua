local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local _ = require("gettext")

local UI = {}

function UI:showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function UI:showNotification(text)
    UIManager:show(Notification:new{
        text = text,
    })
end

function UI:showConfirm(spec)
    UIManager:show(ConfirmBox:new{
        text = spec.text,
        ok_text = spec.ok_text or _("OK"),
        ok_callback = spec.ok_callback,
        cancel_text = spec.cancel_text or _("Cancel"),
        cancel_callback = spec.cancel_callback,
    })
end

function UI:showInput(spec)
    local dialog
    dialog = InputDialog:new{
        title = spec.title or _("Input"),
        input = spec.input or "",
        input_hint = spec.input_hint or "",
        description = spec.description,
        buttons = {
            {
                {
                    text = spec.clear_text or _("Clear"),
                    callback = function()
                        if spec.clear_callback then
                            spec.clear_callback(dialog)
                        else
                            UIManager:close(dialog)
                        end
                    end,
                },
                {
                    text = spec.cancel_text or _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        if spec.cancel_callback then
                            spec.cancel_callback()
                        end
                    end,
                },
                {
                    text = spec.ok_text or _("Apply"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputValue()
                        UIManager:close(dialog)
                        if spec.ok_callback then
                            spec.ok_callback(value)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

return UI
