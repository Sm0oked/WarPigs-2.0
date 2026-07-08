local settings = require 'core.settings'

local external = {
    enable  = function() settings.set_main_toggle(true) end,
    disable = function() settings.set_main_toggle(false) end,
    status  = function()
        settings:update_settings()
        local st = require('core.state_tracker').get_snapshot()
        return {
            name    = settings.plugin_label,
            version = settings.plugin_version,
            enabled = settings.is_active(),
            phase   = st.phase,
            detail  = st.phase_detail,
        }
    end,
}

return external
