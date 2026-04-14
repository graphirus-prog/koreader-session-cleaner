local Settings = {
    key = "sessioncleaner",
    defaults = {
        session_gap_minutes = 30,
        short_session_seconds = 120,
        book_search = "",
        session_filter = "all",
        auto_backup_before_delete = true,
    },
}

function Settings:load()
    local saved = G_reader_settings:readSetting(self.key, self.defaults) or {}
    local merged = {}
    for k, v in pairs(self.defaults) do
        if saved[k] == nil then
            merged[k] = v
        else
            merged[k] = saved[k]
        end
    end
    return merged
end

function Settings:save(values)
    G_reader_settings:saveSetting(self.key, values)
    G_reader_settings:flush()
end

return Settings
