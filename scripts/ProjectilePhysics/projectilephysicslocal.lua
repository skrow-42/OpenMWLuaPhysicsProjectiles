-- ProjectilePhysicsLocal.lua
-- Local script for projectiles - Wraps LuaPhysics and adds Combat API support.

local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local util = require('openmw.util')
local animation = require('openmw.animation')
local storage = require('openmw.storage')

-- Settings
local debugSettings = storage.globalSection('SettingsProjectilePhysics')

local function debugLog(message)
    if debugSettings:get('debugMode') then
        print('[ProjectilePhysics Local] ' .. message)
    end
end

-- Optional: use MaxYari slerp if present (nice but not required)

-- ============================================================================
-- CONFIG: MODEL AXES (THIS IS THE USUAL CAUSE OF “TAIL LEADS / TIP LAGS”)
-- ============================================================================
-- Most projectile meshes in OpenMW/Morrowind conventions face +Y.
-- If yours is backwards, change to util.vector3(0, -1, 0).
local MODEL_FORWARD = util.vector3(0, 1, 0)

-- Up axis used to keep roll stable (optional but helps visuals)
local MODEL_UP = util.vector3(0, 0, 1)

-- If you want PERFECT ballistic tangent alignment, keep this very high or snap.
-- Set to 0 to snap instantly (no smoothing).
local ALIGN_SMOOTH_RATE = 0 -- Higher = snappier response to arc changes, 0 = snap

local MIN_ALIGN_SPEED = 1.0

-- Gravity constant matching MaxYari LuaPhysics (PhysicsObject.lua line 17)
-- Used for look-ahead prediction so rotation anticipates the arc, not lags behind it
local GRAVITY = util.vector3(0, 0, -9.8 * 69.99)

-- ============================================================================
-- FOLLOWER / TRAIL (FPS-Based Particle System)
-- ============================================================================

local TRAIL_TIERS = {
    { r=5,   id='vfx_arrow_trail_5' },
    { r=21,  id='vfx_arrow_trail_21' },
    { r=37,  id='vfx_arrow_trail_37' },
    { r=38,  id='vfx_arrow_trail_38' },
    { r=54,  id='vfx_arrow_trail_54' },
    { r=70,  id='vfx_arrow_trail_70' },
    { r=86,  id='vfx_arrow_trail_86' },
    { r=87,  id='vfx_arrow_trail_87' },
    { r=103, id='vfx_arrow_trail_103' },
    { r=119, id='vfx_arrow_trail_119' },
    { r=120, id='vfx_arrow_trail_120' },
    { r=135, id='vfx_arrow_trail_135' },
    { r=136, id='vfx_arrow_trail_136' },
    { r=152, id='vfx_arrow_trail_152' },
    { r=168, id='vfx_arrow_trail_168' },
    { r=169, id='vfx_arrow_trail_169' },
    { r=185, id='vfx_arrow_trail_185' },
    { r=201, id='vfx_arrow_trail_201' },
    { r=217, id='vfx_arrow_trail_217' },
    { r=218, id='vfx_arrow_trail_218' },
    { r=234, id='vfx_arrow_trail_234' },
    { r=250, id='vfx_arrow_trail_250' }
}

local projectileData = {}
local hasHit = false
local currentTrailRotation = nil

local fpsTracker = {
    history = {},
    maxSamples = 30,
    avgFps = 60
}

local pollStanceTimer = 0
local pollFpsTimer = 0
local isReadyCached = false
local launchTime = 0 -- Track time for initial collision avoidance

-- 2 Water physics state
local hasEnteredWater  = false
local isFloating       = false
local FLOAT_SPEED_THRESHOLD = 500   -- units/s; below this -> decide float/sink
local FLOAT_RISE_SPEED      = 30    -- units/s upward when floating
local WATER_DRAG_FACTOR     = 18.0  -- multiplier on physObj.drag when entering water

-- Projectile record IDs (lowercase) that should SINK rather than float
-- (fully metal projectiles with no wood/feather component)
local WATER_SINKERS = {
    ['iron arrow']    = true, ['steel arrow']   = true,
    ['iron bolt']     = true, ['steel bolt']    = true,
    ['silver bolt']   = true, ['iron shuriken'] = true,
    ['steel shuriken']= true,
}
local function isSinker(recordId)
    if not recordId then return false end
    return WATER_SINKERS[recordId:lower()] == true
end



local followerItem = {
    active = false,
    recordId = nil,
    offset = 0.0,
    updateInterval = 1.0,
    timeSinceLastUpdate = 0,
    currentSpeed = 0,
    currentFollower = nil, -- [NEW] Store specific object
    generation = 1,
    fading = false
}
local currentFollowerGen = 1

local function behindPosition(pos, rot, offset)
    local backVector = rot:apply(util.vector3(0, -1, 0))
    return pos + (backVector * offset)
end

local function updateFpsTracker(dt)
    -- dt is simulation time, use RealFrameDuration for FPS
    local realDt = core.getRealFrameDuration()
    if realDt <= 0 then return end
    
    table.insert(fpsTracker.history, realDt)
    if #fpsTracker.history > fpsTracker.maxSamples then
        table.remove(fpsTracker.history, 1)
    end
    
    local sum = 0
    for _, v in ipairs(fpsTracker.history) do sum = sum + v end
    if sum > 0 then
        -- Average frametime -> FPS
        fpsTracker.avgFps = math.max(10, #fpsTracker.history / sum)
    end
end

local function pickTrailRecord(speed)
    if not speed then return 'vfx_arrow_trail_250' end
    
    local ratio = speed / fpsTracker.avgFps
    local bestIndex = #TRAIL_TIERS
    local minDiff = 999999
    
    for i, tier in ipairs(TRAIL_TIERS) do
        local diff = math.abs(tier.r - ratio)
        if diff < minDiff then
            minDiff = diff
            bestIndex = i
        end
    end
    
    -- User request: "always assign a version that is +X amount higher than the calculated one"
    local targetIndex = math.min(#TRAIL_TIERS, bestIndex + 1)
    
     --debugLog(string.format("[FPS-Trail] Speed: %.1f, FPS: %.1f, Ratio: %.1f -> Index %d -> %d (%s)", speed, fpsTracker.avgFps, ratio, bestIndex, targetIndex, TRAIL_TIERS[targetIndex].id))
    
    return TRAIL_TIERS[targetIndex].id
end

local function startFollower(speed, offset)
    if not speed then return end
    
    local recordId = pickTrailRecord(speed)
    
    followerItem.recordId = recordId
    followerItem.offset = offset or 0.0
    followerItem.currentSpeed = speed
    followerItem.generation = currentFollowerGen
    followerItem.active = true
    followerItem.currentFollower = nil

    -- Spawn at remote location (-30000) to ensure NO collision until exception is added
    local safeStartPos = util.vector3(0, 0, -30000)
    core.sendGlobalEvent('LuaProjectilePhysics_SpawnFollower', {
        projectile = self,
        recordId   = recordId,
        startPos   = safeStartPos,
        startRot   = self.rotation
    })
end

local function stopFollower(shouldFade)
    if not followerItem.active then return end

    if shouldFade then
        followerItem.fading = true
        local duration = 1.2
        
        -- [DIRECT METHOD] Send directly to follower if we have the reference
        local follower = followerItem.currentFollower
        if follower and follower:isValid() then
            pcall(function()
                follower:sendEvent("PlayAnimation", { 
                    groupName = "Idle2",
                    options = { autoDisable = false }
                })
            end)
        end

        core.sendGlobalEvent('LuaProjectilePhysics_FadeFollower', { 
            projectile = self,
            duration = duration
        })
        -- Prepare for next generation (the bounce trail)
        if followerItem.generation == 1 then
            currentFollowerGen = 2
        end
    else
        -- Hard remove
        core.sendGlobalEvent('LuaProjectilePhysics_RemoveFollower', { 
            projectile = self 
        })
    end
    
    followerItem.active = false
end

-- [behindPosition moved up]

local function updateFollowerPosition(dt, rotToUse)
    if not (followerItem.active or followerItem.fading) then return end
    -- Wait until we have the follower object to move it (avoids early collision)
    if not followerItem.currentFollower then return end
    
    if not self or not self:isValid() then return end
    if not rotToUse then rotToUse = self.rotation end

    local backVector = rotToUse:apply(util.vector3(0, -1, 0))
    local targetPos = self.position + (backVector * followerItem.offset)

    core.sendGlobalEvent('LuaProjectilePhysics_UpdateFollower', {
        projectile = self,
        position = targetPos,
        rotation = rotToUse
    })
end

-- [Legacy trail pool code removed]

-- ============================================================================
-- LOAD LUA PHYSICS ENGINE
-- ============================================================================

local physicsSuccess, physics = pcall(require, 'scripts.MaxYari.LuaPhysics.PhysicsEngineLocal')
if not physicsSuccess then
    debugLog("[PP-LOCAL] Warning: PhysicsEngineLocal not found!")
    return {}
end

local physObj = physics.interface.physicsObject

-- ============================================================================
-- BALLISTIC “LOOK ROTATION” (Transform), not Euler vector3
-- ============================================================================

local function clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

local function reject(v, n)
    -- remove component along n
    return v - n * (v:dot(n))
end

local function rotBetween(a, b)
    local an, alen = a:normalize()
    local bn, blen = b:normalize()
    if not an or not bn or alen < 1e-6 or blen < 1e-6 then
        return util.transform.identity
    end

    local dot = clamp(an:dot(bn), -1.0, 1.0)
    if dot > 0.999999 then
        return util.transform.identity
    end

    if dot < -0.999999 then
        -- 180-degree flip: choose any axis perpendicular to a
        local axis = an:cross(util.vector3(1, 0, 0))
        if axis:length() < 1e-6 then
            axis = an:cross(util.vector3(0, 0, 1))
        end
        local axn = axis:normalize()
        return util.transform.rotate(math.pi, axn)
    end

    local axis = an:cross(bn)
    local axn, axlen = axis:normalize()
    if not axn or axlen < 1e-6 then
        return util.transform.identity
    end

    local angle = math.acos(dot)
    return util.transform.rotate(angle, axn)
end


local function applyBallisticFacing(dt)
    -- [MIGRATED] authoritative orientation is now handled globally.
    -- We keep this function as a stub for potential future local VFX needs.
end

-- ============================================================================

-- authoritative collision handler
local function onProjectileCollision(hitResult)
    if not hitResult then return end
    if hasHit then return end

    local target = hitResult.hitObject
    
    -- [LOGGING]
    debugLog('[COLLISION] Hit: ' .. tostring(target and target.id or 'Terrain') .. ' | Speed: ' .. tostring(physObj.velocity:length()))

    -- 1. Actor Hit Logic (Highest priority)
    local isActor = target and (target.type == types.NPC or target.type == types.Creature or target.type == types.Player)
    if isActor then
        -- Don't hit attacker immediately
        if target.id == projectileData.attackerId or target == projectileData.attacker then
            if launchTime < 0.2 then return end
        end

        -- [FIX] Removing hasHit = true here to match the world hit logic
        -- stopFollower(true) will set fading = true, and we let the loop run
        stopFollower(true) -- True = Fade out

        local impactVelocity = hitResult.velocity or physObj.velocity or util.vector3(0, 0, 0)

        pcall(function()
            physObj.velocity = util.vector3(0, 0, 0)
            physObj.angularVelocity = util.vector3(0, 0, 0)
            physObj.disabled = true
            physObj:sleep()
        end)

        core.sendGlobalEvent('LuaProjectilePhysics_ProjectileHit', {
            projectile = self,
            sourceItem = projectileData.projectile,
            hitObject = target,
            hitPos = hitResult.hitPos,
            hitNormal = hitResult.hitNormal,
            velocity = impactVelocity,
            waterDamageMult = projectileData.waterDamageMult
        })
        stopFollower(true) -- True = Fade out
        hasHit = true -- [STILL NEED FOR ENGINE HANDLER STOP]
        return false -- Stop engine from bouncing off the body
    end

    -- 2. Scenery/Environment Logic (World, Terrain, Static Objects)
    if not isActor then
        -- Ignore trail particles
        if target and target.recordId and string.find(string.lower(target.recordId), "vfx_arrow_trail") then
            return
        end

        -- Ignore vanilla projectiles (Double Projectile issue)
        if target and target.type == types.Projectile then
            core.sendGlobalEvent('ProjectilePhysics_RemoveObject', target)
            return
        end

        -- [NEW] Report World Hit to Global (For AoE Detonation on walls/ground)
        -- We only do this if hasHit is false (first impact)
        if not hasHit then
            debugLog('[COLLISION] World Hit reported for AoE/Logic check.')
            core.sendGlobalEvent('LuaProjectilePhysics_ProjectileHit', {
                projectile = self,
                sourceItem = projectileData.projectile,
                hitObject = target,
                hitPos = hitResult.hitPos,
                hitNormal = hitResult.hitNormal,
                velocity = physObj.velocity or util.vector3(0, 0, 0),
                waterDamageMult = projectileData.waterDamageMult
            })
        end
        -- [FIX] Ensure the trail fades out on world impact instead of vanishing
        stopFollower(true) 
    end

    -- 3. Standard Bounce Logic (Fallback)
    debugLog('[COLLISION] Material not sticky. Bouncing.')
    stopFollower(true)

    -- -- PhysicsObject reflects velocity *internally* after this handler returning true or nil.
    -- -- We can manually trigger a follower for the bounce next frame.
    -- local incomingV = physObj.velocity
    -- local incomingNormal = hitResult.hitNormal
    -- if incomingNormal and incomingNormal:length() > 0.1 then
    --     local bounceReduction = (physObj.bounce or 0.3)
    --     local reflected = -(incomingNormal * incomingNormal:dot(incomingV) * 2 - incomingV) * bounceReduction
    --     local newSpeed = reflected:length()
        
    --     if newSpeed > MIN_ALIGN_SPEED then
    --          startFollower(newSpeed, 0.0)
    --     end
    -- end
end

physObj.onCollision:addEventHandler(onProjectileCollision)


-- ============================================================================
-- WRAP ENGINE HANDLERS
-- ============================================================================
local engineHandlers = {}
for k, v in pairs(physics.engineHandlers) do engineHandlers[k] = v end

local baseUpdate = engineHandlers.onUpdate
engineHandlers.onUpdate = function(dt)
    -- Hard early return only when fully done with an actor hit or fade.
    if hasHit and not followerItem.fading then return end
    
    -- [SLEEPING/LOW-SPEED CHECK] 
    -- Fires if engine settles (isSleeping) OR if speed drops below 100 units/sec (fast cleanup).
    local currentSpeed = physObj and physObj.velocity and physObj.velocity:length() or 0
    local isLowSpeed = currentSpeed < 100 and launchTime > 0.5
    
    if physObj and (physObj.isSleeping or isLowSpeed) then
        if followerItem.active or followerItem.fading then
            local follower = followerItem.currentFollower
            if follower and follower:isValid() then
                -- [DIRECT] Fire idle2 on the follower object this frame — no round-trip delay
                pcall(function()
                    follower:sendEvent("PlayAnimation", {
                        groupName = "Idle2",
                        options   = { autoDisable = false }
                    })
                end)
                -- Schedule hard removal after the idle2 animation plays (~0.25s)
                core.sendGlobalEvent('LuaProjectilePhysics_FadeFollower', {
                    projectile = self,
                    duration   = 1.2
                })
            else
                -- No follower reference — fall back to hard remove
                core.sendGlobalEvent('LuaProjectilePhysics_RemoveFollower', { projectile = self })
            end
            -- Clear flags immediately so this block doesn't re-fire
            followerItem.active = false
            followerItem.fading = false
        end
        return
    end
    
    launchTime = launchTime + dt

    -- IMPORTANT: set rotation BEFORE baseUpdate so LuaPhysics sends it in UpdateVisPos this frame
    -- This is only invoked when the projectile is actually flying (not hit or sleeping).
    applyBallisticFacing(dt)
    
    -- [USER REQUEST] Track FPS only when the player or attacker has a readied marksman stance.
    -- [OPTIMIZATION] Poll stance/weapon state every 0.15s and cache it to avoid senseless constant scanning.
    pollStanceTimer = pollStanceTimer + dt
    if pollStanceTimer >= 0.75 then
        pollStanceTimer = 0
        local actorToCheck = projectileData.attacker or self
        isReadyCached = false

        if actorToCheck and actorToCheck:isValid() and types.Actor.getStance(actorToCheck) == 1 then
            local equip = types.Actor.getEquipment(actorToCheck)
            local wpn = equip[types.Actor.EQUIPMENT_SLOT.CarriedRight]
            if wpn then
                local wType = types.Weapon.record(wpn).type
                if wType == types.Weapon.TYPE.MarksmanBow or 
                   wType == types.Weapon.TYPE.MarksmanCrossbow or 
                   wType == types.Weapon.TYPE.MarksmanThrown then
                    isReadyCached = true
                end
            end
        end
    end

    if isReadyCached then
        -- [USER REQUEST] Throttle FPS tracking to once per 0.75 seconds.
        pollFpsTimer = pollFpsTimer + dt
        if pollFpsTimer >= 1.5 then
            pollFpsTimer = 0
            updateFpsTracker(dt) -- [NEW] Track FPS for trail selection
        end
    end
    
    -- [TASK 4] Water detection and float/sink physics
    if not hasHit and not hasEnteredWater then
        local cell = self and self.cell
        local waterLevel = cell and cell.waterLevel
        if waterLevel and self.position.z < waterLevel then
            hasEnteredWater = true
            -- [FIX] Do NOT stop the trail on water entry — let it show until the projectile slows down.
            -- The existing low-speed/sleep check handles cleanup when speed drops below threshold.
            
            -- Water Resistance (Speed & Damage)
            local mult = (projectileData.type == 'bolt') and 0.2 or 0.1
            projectileData.waterDamageMult = mult
            if physObj and physObj.velocity then
                physObj.velocity = physObj.velocity * mult
            end
            if physObj then
                physObj.drag = (physObj.drag or 0.02) * WATER_DRAG_FACTOR
            end
            
            core.sendGlobalEvent('ProjectilePhysics_EnteredWater', {
                projectile = self, position = self.position,
                ammoRecordId = projectileData.ammoRecordId,
            })
        end
    end
    -- Water physics natively handled by LuaPhysics drag applied on entry

    if baseUpdate then baseUpdate(dt) end

    -- [WABA v10] Redundant local updates disabled.
    -- Global script now handles ballistic trail orientation via UpdateVisPos.
end

-- [FIX 1] Always clean up the trail when the projectile object is deactivated or removed.
-- This fires when the object leaves processing range OR is explicitly removed (lifetime expiry, cleanup, etc.)
engineHandlers.onInactive = function()
    if followerItem.active or followerItem.fading then
        stopFollower(true) -- graceful fade-out
    end
end

local baseLoad = engineHandlers.onLoad
engineHandlers.onLoad = function(data)
    if data then
        projectileData = data.projectileData or {}
        hasHit = data.hasHit or false
        hasEnteredWater = data.hasEnteredWater or false
        isFloating      = data.isFloating or false

        if data.followerItem then
            followerItem.active = data.followerItem.active or false
            followerItem.recordId = data.followerItem.recordId
            followerItem.offset = data.followerItem.offset or followerItem.offset
            followerItem.currentSpeed = data.followerItem.currentSpeed or 0
            followerItem.fading = data.followerItem.fading or false
            
            followerItem.lastProjectilePos = self and self:isValid() and self.position or nil
        end
    end
    if baseLoad then baseLoad(data) end
end

local baseSave = engineHandlers.onSave
engineHandlers.onSave = function()
    local data = baseSave and baseSave() or {}
    data.projectileData  = projectileData
    data.hasHit          = hasHit
    data.hasEnteredWater = hasEnteredWater
    data.isFloating      = isFloating
    data.followerItem    = followerItem
    return data
end

-- ============================================================================
-- EVENTS
-- ============================================================================
local finalEventHandlers = {}
for k, v in pairs(physics.eventHandlers) do finalEventHandlers[k] = v end

finalEventHandlers.ProjectilePhysics_SetData = function(data)
    projectileData = data or {}

    -- [REVISION 43] Self-Collision Prevention (LPP-Only)
    -- Ignore collisions with the attacker/launcher to prevent self-impact while moving.
    -- [REFINEMENT] Re-enable collision after 0.75 seconds of flight (to allow for self-damage from falling proj).
    physObj.collisionFilter = function(hitResult)
        if not hitResult or not hitResult.hitObject then return true end
        if projectileData.attacker and hitResult.hitObject == projectileData.attacker then
            if launchTime < 0.75 then
                return false -- Ignore the shooter initially
            end
        end
        return true
    end

    -- ballistic-facing mode
    physObj.lockRotation = true
    physObj.angularVelocity = util.vector3(0, 0, 0)
    physObj.angularDrag = 50.0

    if data and data.vfxSpeed then
        startFollower(data.vfxSpeed, data.vfxOffset)
    end

    -- [REVISION 42] Store Attacker ID for faster/safer comparisons
    if data and data.attacker then
        projectileData.attackerId = data.attacker.id
        projectileData.attacker = data.attacker
        if physObj.addCollisionException then
            physObj:addCollisionException(data.attacker)
        end
    end
end

finalEventHandlers.ProjectilePhysics_FollowerSpawned = function(data)
    if not data or not data.follower then return end
    
    followerItem.currentFollower = data.follower
    
    -- [FIX] Race condition: if stopFollower() was called while the spawn was in-flight
    -- (e.g. projectile entered water before the global reply arrived), immediately
    -- remove the follower that just got created so it doesn't ghost permanently.
    if not followerItem.active and not followerItem.fading then
        core.sendGlobalEvent('LuaProjectilePhysics_RemoveFollower', { projectile = self })
        followerItem.currentFollower = nil
        return
    end
    
    -- Attempt to ignore collision with the follower object
    -- Supports various MaxYari API versions/naming conventions
    if physObj then
        pcall(function() 
            if physObj.addCollisionException then physObj:addCollisionException(data.follower) end 
        end)
        pcall(function() 
            if physObj.addIgnoreObject then physObj:addIgnoreObject(data.follower) end 
        end)
        pcall(function() 
            if physObj.ignoreObject then physObj:ignoreObject(data.follower) end 
        end)
    end
end

finalEventHandlers.ProjectilePhysics_PlayTrailFade = function(data)
    if not data or not data.follower or not data.follower:isValid() then return end
    
    -- [REVISION 40] Generic Activator Pattern
    -- We send the standardized 'PlayAnimation' event to the follower.
    -- The VFX records must have 'Activator.lua' attached as an ACTIVATOR script.
    data.follower:sendEvent("PlayAnimation", {
        groupName = "Idle2",
        options = {
           autoDisable = false
        },
    })
end

finalEventHandlers.ProjectilePhysics_RemoveVfx = function()
    stopFollower(false) -- Instant force-remove
end

return {
    engineHandlers = engineHandlers,
    eventHandlers = finalEventHandlers,
    interfaceName = "ProjectilePhysicsLocal",
    interface = {
        projectileData = function() return projectileData end
    }
}