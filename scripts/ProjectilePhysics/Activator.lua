local self = require("openmw.self")
local animation = require("openmw.animation")

return {
    eventHandlers = {
        PlayAnimation = function(args)
            if animation and animation.playBlended then
                pcall(function()
                    if animation.hasGroup(self, "Idle2") then
                        animation.playBlended(self, "Idle2", args.options)
                    end
                    if animation.hasGroup(self, args.groupName) then
                        animation.playBlended(self, args.groupName, args.options)
                    end
                end)
            end
        end,
    },
}
