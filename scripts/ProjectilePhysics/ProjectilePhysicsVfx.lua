local self = require('openmw.self')
local animation = require('openmw.animation')

return {
    eventHandlers = {
        PlayAnimation = function(data)
            if not data or not data.groupName then return end
            local ok, err = pcall(function()
                animation.play(self, data.groupName, data.options or {
                    priority = animation.PRIORITY.Target or 10,
                    blendMask = animation.BLEND_MASK.All,
                    loops = 0 -- Reset loops
                })
            end)
            if not ok then
                print("[LPP-VFX] PlayAnimation failed: " .. tostring(err))
            end
        end
    }
}
