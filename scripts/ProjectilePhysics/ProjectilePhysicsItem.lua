local self = require('openmw.self')
local animation = require('openmw.animation')
local storage = require('openmw.storage')

-- Settings
local debugSettings = storage.globalSection('SettingsProjectilePhysics')

-- Debug helper
local function debugLog(msg)
    if debugSettings:get('debugMode') then
        print('[ProjectilePhysics-Item] ' .. tostring(self.object.recordId) .. ': ' .. msg)
    end
end

return {
    eventHandlers = {
        ProjectilePhysics_AttachTrail = function(data)
            debugLog('AttachTrail event received! Type: ' .. tostring(data.projectileType))
            
            if hasTrail then 
                debugLog('Already has trail, skipping')
                return 
            end
            
            -- Check if object is valid
            if not self.object or not self.object:isValid() then
                debugLog('ERROR: self.object is invalid!')
                return
            end
            
            -- Choose trail based on type
            local trailModel = 'meshes/vfx/vfx_speedln.nif' -- Default
            
            if data.projectileType == 'bolt' then
                trailModel = 'meshes/vfx/vfx_spark_hit.nif'
            elseif data.projectileType == 'thrown' then
                trailModel = 'meshes/vfx/vfx_speedln.nif'
            end
            
            debugLog('Attempting to attach VFX: ' .. trailModel)
            
            -- Try without pcall first to see errors
            local ok, err = pcall(function()
                trailVfxKey = animation.addVfx(self.object, trailModel, {
                    loop = true,
                    bonename = ''
                })
            end)
            
            if ok then
                hasTrail = true
                debugLog('SUCCESS! Trail attached, key: ' .. tostring(trailVfxKey))
            else
                debugLog('FAILED! Error: ' .. tostring(err))
            end
        end,
        
        ProjectilePhysics_RemoveTrail = function()
            debugLog('RemoveTrail event received')
            if trailVfxKey then
                pcall(function() 
                    animation.removeVfx(self.object, trailVfxKey) 
                end)
                trailVfxKey = nil
                hasTrail = false
                debugLog('Trail removed')
            end
        end,
        
        ProjectilePhysics_SetData = function(data)
            -- Store data locally (don't forward event to self)
            debugLog('SetData received - Damage: ' .. tostring(data.damage))
            -- You can store these as local variables if needed:
            -- localAttacker = data.attacker
            -- localDamage = data.damage
            -- etc.
        end
    },
    
    engineHandlers = {
        onActive = function()
            debugLog('Item script activated!')
        end
    }
}