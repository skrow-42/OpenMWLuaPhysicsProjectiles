-- ProjectilePhysicsPlayer.lua
-- Player-side projectile detection using ArrowStick-inspired approach
-- Monitors weapon use and raycasts to find collision point

local core = require('openmw.core')
local types = require('openmw.types')
local self = require('openmw.self')
local ui = require('openmw.ui')
local nearby = require('openmw.nearby')
local camera = require('openmw.camera')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local ambient = require('openmw.ambient')
local anim = require('openmw.animation')
local debug = require('openmw.debug')
local input = require('openmw.input')
local storage = require('openmw.storage')
local async = require('openmw.async')
local poseTransforms = require('scripts/projectilephysics/poseTransforms')
local AnimController = I.AnimationController

local lastGodModeState = nil
local lastSneakState = false
local lastActivateState = false

-- Load settings
local storage = require('openmw.storage')
local async = require('openmw.async')
local settings = {
    general = storage.playerSection('SettingsProjectilePhysics'),
    advanced = storage.playerSection('SettingsProjectilePhysicsAdvanced'),
    velocity = storage.playerSection('SettingsProjectilePhysicsVelocity')
}

-- Sync settings to global
local function syncSettingsToGlobal()
    local data = {
        enableProjectilePhysics = settings.general:get('enableProjectilePhysics'),
        enableBounceDamage = settings.general:get('enableBounceDamage'),
        enableProjectileSticking = settings.general:get('enableProjectileSticking'),
        projectileLifetime = settings.general:get('projectileLifetime'),
        breakChance = settings.general:get('breakChance'),
        bounceDamageMultiplier = settings.general:get('bounceDamageMultiplier'),
        hitDetectionMode = settings.advanced:get('hitDetectionMode'),
        pickupMode = settings.advanced:get('pickupMode'),
        enableLiveInventorySync = settings.advanced:get('enableLiveInventorySync'),
        enableSkillBasedRecoil = settings.general:get('enableSkillBasedRecoil'),
        enableNPCSupport = settings.general:get('enableNPCSupport'),
        maxRecoil = settings.general:get('maxRecoil'),
        enableProjectileBlocking = settings.general:get('enableProjectileBlocking'),
        debugMode = settings.general:get('debugMode'),
        rangedOnUseToOnStrike = settings.advanced:get('rangedOnUseToOnStrike'),
    }
    core.sendGlobalEvent('ProjectilePhysics_SyncSettings', data)
end

-- Subscribe to changes
settings.general:subscribe(async:callback(syncSettingsToGlobal))
settings.advanced:subscribe(async:callback(syncSettingsToGlobal))

local ARROW_OFFSET = 8.0

-- Initial sync
async:newUnsavableSimulationTimer(0.1, function()
    syncSettingsToGlobal()
end)

-- State tracking (Text Key System)
local passiveAttackActive = false
local passiveAttackStartTime = nil
local passiveWeaponType = nil
local passiveWeaponItem = nil
local passiveAmmoItem = nil -- For arrows/bolts OR thrown
local passiveIsThrown = false
local passiveAmmoHidden = false
local savedAmmoSlot = nil
local passiveDidFire = {} -- Track shots handled by Early handler
local passiveGeneration = 0 -- To track shot cycles for cleanup safety
local scanLeaksTimer = 0     -- For proximity cleanup of vanilla bolts
local passiveHoldActive = false -- For infinite crossbow charge hold
local passiveWasReleased = false -- For tap detection during spam
local passiveProcessedMinHit = {} -- For blending safety
local passiveShootSoundPlayed = {}
local passivePullSoundPlayed = {}
local passiveIsReadying = false
local holdReleaseBuffer = 0     -- For sticky hold release
local lastLaunchTime = 0
local passiveAnimReady = true   -- [COOLDOWN] False while animation is playing, true when ready
local passiveIsUnequipping = false -- [FIX 3] Guard against unequip animation triggering a shot

local lastInteractionTime = 0
local weaponReadyTime = 0 -- Time when weapon will be ready after re-equip animation

local lastWpnType = nil
local ammoTypeToWeaponType = {
    [types.Weapon.TYPE.Arrow] = types.Weapon.TYPE.MarksmanBow,
    [types.Weapon.TYPE.MarksmanBow] = types.Weapon.TYPE.Arrow,
    [types.Weapon.TYPE.Bolt] = types.Weapon.TYPE.MarksmanCrossbow,
    [types.Weapon.TYPE.MarksmanCrossbow] = types.Weapon.TYPE.Bolt,
    [types.Weapon.TYPE.MarksmanThrown] = types.Weapon.TYPE.MarksmanThrown
}

-- [SMART AMMO STATE]
local lastAmmoSlotItem = nil
local currentAmmoSlotItem = nil
local preferredAmmoMap = {}


-- Debug logging
local function debugLog(message)
    if settings.general:get('debugMode') then
        print('[ProjectilePhysics Player] ' .. message)
    end
end


-- [USER CONFIG] Projectile Launch Offsets -- negative = up/left
local WEAPON_TIMINGS = {
    arrow  = { minAttackTime = 0.95,  maxAttackTime = 1.5,  releaseTime = 0.05, vanillaReleaseTime = 0.75 },
    bolt   = { minAttackTime = 0.0,  maxAttackTime = 0.0,  releaseTime = 0.05, vanillaReleaseTime = 1.20 },
    thrown = { minAttackTime = 0.119,  maxAttackTime = 0.6, releaseTime = 0.05, vanillaReleaseTime = 0.95 }
}

local OFFSET_PROFILES = {
    vanilla = {
        arrow =  { right = -12.0, down = 0.0 },
        bolt =   { right = 20.0, down = 22.0 },
        thrown = { right = 27.0, down = 17.0 }
    },
    reanimation = {
        arrow =  { right = -4.0, down = -3.0 },
        bolt =   { right = 0.0, down = 15.0 },
        thrown = { right = 27.0, down = 19.0 }
    }
}

-- Helper: Hide ammo/weapon to suppress vanilla projectile
local function hideAmmoForSuppression()
    if passiveAmmoHidden then return end
    local equipment = types.Actor.getEquipment(self)
    local SLOT = types.Actor.EQUIPMENT_SLOT
    if passiveIsThrown then
        local item = equipment[SLOT.CarriedRight]
        if item then
            savedAmmoSlot = item.recordId -- Store Record ID instead of reference
            equipment[SLOT.CarriedRight] = nil
            types.Actor.setEquipment(self, equipment)
            passiveAmmoHidden = true
            debugLog('Suppression: Thrown weapon hidden (' .. savedAmmoSlot .. ')')
        end
    else
        local item = equipment[SLOT.Ammunition]
        if item then
            savedAmmoSlot = item.recordId -- Store Record ID instead of reference
            equipment[SLOT.Ammunition] = nil
            types.Actor.setEquipment(self, equipment)
            passiveAmmoHidden = true
            debugLog('Suppression: Ammunition hidden (' .. savedAmmoSlot .. ')')
        end
    end
end

-- Helper: Restore ammo after shot
local function restoreAmmoAfterShot()
    if not passiveAmmoHidden then return end
    if savedAmmoSlot then
        local equipment = types.Actor.getEquipment(self)
        local SLOT = types.Actor.EQUIPMENT_SLOT
        local inv = types.Actor.inventory(self)
        
        -- Find a valid item reference for the stored record ID
        local itemToRestore = inv:find(savedAmmoSlot)
        
        if itemToRestore then
            if passiveIsThrown then
                equipment[SLOT.CarriedRight] = itemToRestore
            else
                equipment[SLOT.Ammunition] = itemToRestore
            end
            types.Actor.setEquipment(self, equipment)
            debugLog('Suppression: Restored ' .. savedAmmoSlot)
        else
            debugLog('Suppression: Restore failed - out of ammo for ' .. tostring(savedAmmoSlot))
        end
    end
    passiveAmmoHidden = false
    savedAmmoSlot = nil
end




-- Play crossbowshoot once per firing cycle.
-- crossbowpull is fired natively by the follow-through animation (fakerelease playBlended).
local function playCrossbowSounds()
    local gen = passiveGeneration
    if not passiveShootSoundPlayed[gen] then
        core.sound.playSound3d('crossbowshoot', self)
        passiveShootSoundPlayed[gen] = true
    end
end
local function anglesToVector(pitch, yaw)
    local xzLen = math.cos(pitch)
    return util.vector3(
        xzLen * math.sin(yaw),
        xzLen * math.cos(yaw),
        math.sin(pitch)
    )
end

-- Calculate precision based on Marksman skill
-- 0 skill = 0.2 (20%), 100 skill = 0.95 (95%), 120 skill = 1.0 (100%)
local function getMarksmanPrecision()
    local marksman = 0
    pcall(function()
        marksman = types.NPC.stats.skills.marksman(self).modified
    end)
    
    -- Normalized precision: 
    -- 0 skill = 0.0 accuracy
    -- 100 skill = 0.95 accuracy
    -- 120 skill = 1.0 accuracy
    local precision = 0
    if marksman <= 100 then
        precision = (marksman / 100) * 0.95
    else
        -- Scale from 0.95 to 1.0 between level 100 and 120
        local overLevel = math.min(20, marksman - 100)
        precision = 0.95 + (overLevel / 20) * 0.05
    end
    
    return precision
end


-- Get camera direction
local function getCameraDirection()
    local pitch = -(camera.getPitch() + camera.getExtraPitch())
    local yaw = (camera.getYaw() + camera.getExtraYaw())
    return anglesToVector(pitch, yaw)
end

-- Raycast to find where projectile would hit
local function raycastProjectilePath(maxDistance)
    -- Offset startPos to match vanilla firing (30 units down, 5 units right)
    local yaw = (camera.getYaw() + camera.getExtraYaw())
    local rightDir = util.vector3(math.cos(yaw), -math.sin(yaw), 0)
    
    -- [3RD PERSON FIX]
    -- camera.getPosition() is the orbiting camera's location in 3rd person.
    -- We must use the actor's physical position to avoid spawning behind the player.
    local basePos = camera.getPosition()
    local direction = getCameraDirection()
    
    if camera.getMode() ~= 0 then 
        -- [FIX] Issue 5: 3rd Person Direction Lock
        -- Use Actor Body Yaw + Camera Pitch
        -- This ensures the projectile flies where the character is facing, not where the camera is looking (if mismatched).
        local camPitch = -(camera.getPitch() + camera.getExtraPitch())
        local bodyDir = self.rotation * util.vector3(0,1,0)
        local bodyYaw = math.atan2(bodyDir.x, bodyDir.y)
        
        direction = anglesToVector(camPitch, bodyYaw)

        -- Approximate eye level 110 units above self.position
        -- Forward offset: Move starting point 10 units in front of player
        local forwardDir = util.vector3(direction.x, direction.y, 0):normalize()
        basePos = self.position + util.vector3(0, 0, 110) + (forwardDir * 10)
    end


    -- Determine Offset based on weapon type & Profile
    local wType = passiveWeaponType or 'arrow' -- Default to arrow if nil
    
    local offsetMode = settings.general:get('projectileLaunchOffsetMode')
    -- Default to reanimation if setting is missing/invalid
    local profile = OFFSET_PROFILES[offsetMode] or OFFSET_PROFILES.reanimation
    local offsets = profile[wType] or profile.arrow
    
    local rightVal = offsets.right
    local downVal = offsets.down
    
    -- Apply Offset: Right * RightVal, Down is negative Z
    local startOffset = (rightDir * rightVal) - util.vector3(0, 0, downVal)
    local startPos = basePos + startOffset

    -- APPLY SKILL-BASED RECOIL (SPREAD)
    local enableRecoil = settings.general:get('enableSkillBasedRecoil')
    if enableRecoil == nil then enableRecoil = true end -- Default to ON
    
    if enableRecoil then
        local precision = getMarksmanPrecision()
        -- spreadMult: 1.0 at 0 precision, 0.0 at 1.0 precision
        local spreadMult = math.max(0, 1.0 - precision)
        
        -- Maximum angle of shot deviation (recoil) - now configurable
        local maxSpreadRadius = settings.general:get('maxRecoil') or 0.25
        local spreadAmount = maxSpreadRadius * spreadMult
        
        if spreadAmount > 0 then
            -- Use polar coordinates for uniform disk distribution (reaching any point of the cone)
            local angle = math.random() * 2 * math.pi
            -- sqrt(random) ensures uniform distribution over the area of the disk
            local radius = math.sqrt(math.random()) * spreadAmount
            
            -- Construct orthonormal basis relative to direction
            local up = (math.abs(direction.z) < 0.999) and util.vector3(0,0,1) or util.vector3(1,0,0)
            local right = direction:cross(up):normalize()
            local realUp = right:cross(direction):normalize()
            
            -- Apply spread
            direction = (direction + (right * math.cos(angle) * radius) + (realUp * math.sin(angle) * radius)):normalize()
        end
    end

    local endPos = startPos + direction * maxDistance
    
    -- Cast both rendering and physics rays
    local renderHit = nearby.castRenderingRay(startPos, endPos, { ignore = self })
    local physicsHit = nearby.castRay(startPos, endPos, { 
        ignore = self,
        collisionType = 63
    })

    -- [DEAD ACTOR "GHOST" FILTER]
    -- If we hit a dead NPC's upright collision capsule in the air, ignore it and continue.
    -- This prevents projectiles from "bouncing off air" where a dead body used to stand.
    if physicsHit.hit and physicsHit.hitObject and (physicsHit.hitObject.type == types.NPC or physicsHit.hitObject.type == types.Creature) then
        local healthStat = physicsHit.hitObject.type.stats.dynamic.health(physicsHit.hitObject)
        if healthStat and healthStat.current <= 0 then
            local relZ = physicsHit.hitPos.z - physicsHit.hitObject.position.z
            if relZ > 20 then
                 -- Hit air above dead body. Recast from slightly past the hit.
                 local newStart = physicsHit.hitPos + direction * 10
                 physicsHit = nearby.castRay(newStart, endPos, { 
                    ignore = self,
                    collisionType = 63
                 })
                 debugLog('  Ghost hit ignored in raycast (relZ: ' .. math.floor(relZ) .. ')')
            end
        end
    end
    
    return startPos, renderHit, physicsHit, direction
end

-- Check if weapon fires projectiles
local function isProjectileWeapon(weapon)
    if not weapon then return false, nil end
    
    local weaponRecord = types.Weapon.record(weapon)
    if not weaponRecord then return false, nil end
    
    local weaponType = weaponRecord.type
    
    if weaponType == types.Weapon.TYPE.MarksmanBow then
        return true, 'arrow', weaponRecord
    elseif weaponType == types.Weapon.TYPE.MarksmanCrossbow then
        return true, 'bolt', weaponRecord
    elseif weaponType == types.Weapon.TYPE.MarksmanThrown then
        return true, 'thrown', weaponRecord
    end
    
    return false, nil, nil
end


-- Get equipment
local function getEquipment()
    return types.Actor.getEquipment(self)
end

-- [SMART AMMO HELPERS]
local function getAmmoForWeapon(kind)
    local inv = types.Actor.inventory(self)
    -- Use TIER 1/2 approach for version safety
    local Amm = types.Ammunition
    if Amm and Amm.TYPE then
        for _, item in ipairs(inv:getAll(Amm)) do
            local record = Amm.record(item)
            if (kind == types.Weapon.TYPE.MarksmanBow and record.type == Amm.TYPE.Arrow) or
               (kind == types.Weapon.TYPE.MarksmanCrossbow and record.type == Amm.TYPE.Bolt) then
                return item
            end
        end
    end
    
    -- Fallback to Weapon type check (Legacy/Thrown)
    for _, item in ipairs(inv:getAll(types.Weapon)) do
        local record = types.Weapon.record(item)
        if record and record.type then
            if (kind == types.Weapon.TYPE.MarksmanBow and record.type == types.Weapon.TYPE.Arrow) or
               (kind == types.Weapon.TYPE.MarksmanCrossbow and record.type == types.Weapon.TYPE.Bolt) then
                return item
            end
        end
    end
    return nil
end

local function checkAmmoMatch(wpn, ammo)
    if not wpn or not ammo then return false end
    local wpnRecord = types.Weapon.record(wpn)
    if not wpnRecord then return false end
    
    local ammoType = nil
    -- Version-safe ammo type detection
    local Amm = types.Ammunition
    if Amm and Amm.object(ammo) then
        local rec = Amm.record(ammo)
        if rec.type == Amm.TYPE.Arrow then ammoType = types.Weapon.TYPE.Arrow
        elseif rec.type == Amm.TYPE.Bolt then ammoType = types.Weapon.TYPE.Bolt end
    else
        local ammoWepRec = types.Weapon.record(ammo)
        if ammoWepRec then ammoType = ammoWepRec.type end
    end

    if wpnRecord.type == types.Weapon.TYPE.MarksmanBow and ammoType == types.Weapon.TYPE.Arrow then
        return true
    elseif wpnRecord.type == types.Weapon.TYPE.MarksmanCrossbow and ammoType == types.Weapon.TYPE.Bolt then
        return true
    end
    return false
end

local function smartAmmoEquip(slot, item)
    local currentEquip = types.Actor.getEquipment(self)
    currentEquip[slot] = item
    types.Actor.setEquipment(self, currentEquip)
end

local function setPreferredAmmo(ammo)
    local ammoRec = nil
    if types.Ammunition and types.Ammunition.object(ammo) then
        ammoRec = types.Ammunition.record(ammo)
    else
        ammoRec = types.Weapon.record(ammo)
    end
    if not ammoRec then return end
    
    local ammoType = ammoRec.mwType == types.Ammunition and ((ammoRec.type == types.Ammunition.TYPE.Arrow) and types.Weapon.TYPE.Arrow or types.Weapon.TYPE.Bolt) or ammoRec.type
    local kind = ammoTypeToWeaponType[ammoType]
    
    if preferredAmmoMap[kind] == ammo then return end

    if (kind == types.Weapon.TYPE.MarksmanBow and ammoType == types.Weapon.TYPE.Arrow) or
       (kind == types.Weapon.TYPE.MarksmanCrossbow and ammoType == types.Weapon.TYPE.Bolt) then
        preferredAmmoMap[kind] = ammo
    end
end

local function smartAmmoUpdate()
    -- [USER REQUEST] Do not unequip the ammo if the weapon is chosen (stays equipped until run out/change).
    -- Also, skip if we are currently suppressing vanilla fire (hiding ammo).
    if passiveAmmoHidden then return end

    -- Early return if weapon is not drawn (stance ~= 1) or no weapon equipped.
    if types.Actor.getStance(self) ~= 1 then return end

    local equipment = types.Actor.getEquipment(self)
    local wpnItem = equipment[types.Actor.EQUIPMENT_SLOT.CarriedRight]
    local isProj, pType, wpnRec = isProjectileWeapon(wpnItem)
    
    -- No bow/crossbow/thrown? Return immediately.
    if not isProj then return end

    local ammoItem = equipment[types.Actor.EQUIPMENT_SLOT.Ammunition]
    local currentWpnType = wpnRec and wpnRec.type or nil
    
    if currentWpnType == types.Weapon.TYPE.MarksmanThrown then 
        lastWpnType = currentWpnType
        return 
    end

    -- [USER REQUEST] OPTIMIZATION: Only scan inventory when ammo is low (0 or 1)
    -- This avoids constant inventory loops during gameplay.
    if ammoItem and ammoItem:isValid() then
        -- Note: If ammo doesn't match the current weapon, we MUST proceed to scan/swap.
        if checkAmmoMatch(wpnItem, ammoItem) and ammoItem.count > 1 then
            lastWpnType = currentWpnType
            return
        end
    end

    -- If we reach here, we are either out of ammo (0), on the last arrow (1), or have a mismatch.
    -- We perform the "check" (scan inventory for next best).
    local wantAmmo = preferredAmmoMap[currentWpnType]
    local toUse = (wantAmmo and wantAmmo:isValid() and wantAmmo.count > 0) and wantAmmo or getAmmoForWeapon(currentWpnType)

    if toUse then
        -- [USER REQUEST] EQUIP logic: Only equip when 0 or mismatch.
        -- This allows the player to use their very last arrow before switching stacks.
        local isMismatch = not ammoItem or not checkAmmoMatch(wpnItem, ammoItem)
        
        if isMismatch then
            -- Empty hand or wrong ammo type: EQUIP NOW.
            smartAmmoEquip(types.Actor.EQUIPMENT_SLOT.Ammunition, toUse)
            debugLog('[SMART-AMMO] Equipped ' .. tostring(toUse.recordId) .. ' (count was 0 or mismatch)')
        elseif ammoItem.count == 1 and toUse ~= ammoItem then
            -- On the last arrow, and a DIFFERENT replacement is ready.
            -- We wait until count hits 0 before swapping stacks.
            debugLog('[SMART-AMMO] On last arrow. Replacement ready: ' .. tostring(toUse.recordId))
        end
    end

    lastWpnType = currentWpnType
end


-- [Projectile Physics Player Logic Block] --

-- Weapon Timing Configurations (Synced with Actor script + Player Tweak)
-- Weapon Timing Configurations (Synced with Actor script + Player Tweak)
-- Differences: Player has 0.0s minAttackTime for instant charge start (responsiveness)
local function firePhysicsProjectile(chargeRatio, sound, forcedAmmo)
    local wRec = types.Weapon.record(passiveWeaponItem)
    local aRec = nil
    
    local ammoItem = forcedAmmo or passiveAmmoItem
    
    if ammoItem then
        if passiveIsThrown then
            aRec = types.Weapon.record(ammoItem)
        else
            if types.Ammunition then
                aRec = types.Ammunition.record(ammoItem)
            end
            if not aRec then aRec = types.Weapon.record(ammoItem) end
        end
    end
    
    if not wRec or (not aRec and not passiveIsThrown) then 
        debugLog('Fire aborted: Missing records.')
        return 
    end
    
    local pType = passiveWeaponType
    
    -- Calculate Damage
    local wMin, wMax = wRec.chopMinDamage or 0, wRec.chopMaxDamage or 0
    if pType == 'arrow' or pType == 'bolt' then
         -- Use Chop for generic damage range if available, else Fallback
         if wMax == 0 then wMin, wMax = wRec.thrustMinDamage or 0, wRec.thrustMaxDamage or 0 end
    end
    
    -- Charge Logic
    -- Determine actual power based on charge ratio
    local damage = 0
    local speed = 0
    
    -- [USER REQUEST] Deterministic Charge Formula: Min + (Max - Min) * Charge
    -- Ammo damage is added AFTER
    local wDmg = wMin + ((wMax - wMin) * chargeRatio)
    
    local aDmg = 0
    if aRec then
        local aMin, aMax = aRec.chopMinDamage or 0, aRec.chopMaxDamage or 0 -- Ammunition damage
        if aMax == 0 then aMin, aMax = aRec.thrustMinDamage or 0, aRec.thrustMaxDamage or 0 end
        aDmg = (aMin + aMax) * 0.5 -- Average ammo damage (since ammo doesn't scale with draw)
    end
    
    damage = wDmg + aDmg
    
    -- Speed Calculation
    local boltMax   = settings.velocity:get('boltSpeed') or 4000
    local arrowMax  = settings.velocity:get('arrowSpeed') or 3500
    local thrownMax = settings.velocity:get('thrownSpeed') or 2000

    -- [USER REQUEST] Charge % affects speed for bow/thrown. Crossbow fixed.
    if pType == 'bolt' then
        speed = boltMax -- Fixed high speed
        chargeRatio = 1.0 -- Force full power for bolts
    elseif pType == 'arrow' then
        local minArrow = arrowMax * (1000 / 3500)
        speed = minArrow + ((arrowMax - minArrow) * chargeRatio)
    elseif pType == 'thrown' then
        local minThrown = thrownMax * (500 / 2000)
        speed = minThrown + ((thrownMax - minThrown) * chargeRatio)
    else
        speed = (arrowMax + thrownMax) / 2
    end
    
    -- Use cached aim data (updated every frame in onFrame)
    -- castRenderingRay is forbidden in animation callbacks, so we must use pre-cached values
    local startPos = cachedStartPos
    local direction = cachedDirection
    local physicsHit = cachedPhysicsHit
    
    if not startPos or not direction then
        -- Fallback: compute direction from camera angles (no raycast needed)
        direction = getCameraDirection()
        
    -- APPLY RECOIL TO FALLBACK
    local enableRecoil = settings.general:get('enableSkillBasedRecoil', true)
    
    if enableRecoil then
        local precision = getMarksmanPrecision()
        local spreadMult = math.max(0, 1.0 - precision)
        local maxSpreadRadius = settings.general:get('maxRecoil', 0.18)
        local spreadAmount = maxSpreadRadius * spreadMult
        if spreadAmount > 0 then
            local angle = math.random() * 2 * math.pi
            local radius = math.sqrt(math.random()) * spreadAmount
            local up = (math.abs(direction.z) < 0.999) and util.vector3(0,0,1) or util.vector3(1,0,0)
            local right = direction:cross(up):normalize()
            local realUp = right:cross(direction):normalize()
            direction = (direction + (right * math.cos(angle) * radius) + (realUp * math.sin(angle) * radius)):normalize()
        end
    end
        
        physicsHit = { hit = false }
        
        -- Recalculate Start Pos with Offsets (duplicate logic from raycastProjectilePath)
        -- This ensures we don't spawn from center even if cache misses
        local offsetMode = settings.general:get('projectileLaunchOffsetMode')
        local profile = OFFSET_PROFILES[offsetMode] or OFFSET_PROFILES.reanimation
        local offs = profile[pType] or profile.arrow
        
        local yaw = (camera.getYaw() + camera.getExtraYaw())
        local rightDir = util.vector3(math.cos(yaw), -math.sin(yaw), 0)
        
        local basePos = camera.getPosition()
        if camera.getMode() ~= 0 then
             local forwardDir = util.vector3(direction.x, direction.y, 0):normalize()
             basePos = self.position + util.vector3(0, 0, 110) + (forwardDir * 10)
        end
        
        startPos = basePos + (rightDir * offs.right) - util.vector3(0, 0, offs.down)
        debugLog(string.format("[PP-PLAYER] Cache Miss - Fired via fallback (Recoil enabled: %s)", tostring(settings.general:get('enableSkillBasedRecoil'))))
    end
    
    -- Spawn Visuals / Projectile via Global
    -- We tell global to spawn at launcher, so it flies physically from the bow
    core.sendGlobalEvent('ProjectilePhysics_PlaceProjectile', {
        projectileType = pType,
        recordId = aRec.id,
        weaponRecordId = wRec.id,
        attacker = self,
        attackerVelocity = self.velocity, -- [NEW] Pass velocity from local
        launcher = passiveWeaponItem,
        position = physicsHit.hitPos or (startPos + direction * 10000), -- Target context
        startPos = startPos,
        direction = direction,
        speed = speed,
        damage = damage,
        chargeRatio = chargeRatio,
        flightTime = 0, -- 0 means spawn immediately at launcher
        spawnAtLauncher = true, -- Force physical flight
        isMiss = not physicsHit.hit,
        isDirectHit = false -- Global handles hit detection
    })
    
    -- [FIX] Issue 2: Consume Ammo
    -- Engine does not consume ammo because we hid it. We must manually remove 1 count.
    local function consumeAmmo()
        local inv = types.Actor.inventory(self)
        local itemToConsume = nil
        
        if passiveIsThrown then
             itemToConsume = passiveAmmoItem
        else
             itemToConsume = passiveAmmoItem or savedAmmoSlot
        end
        
        if itemToConsume and itemToConsume:isValid() then
            -- Find the item in the inventory to ensure we have a valid, mutable handle
            -- (passiveAmmoItem/savedAmmoSlot might be read-only refs from Equipment)
            local realItem = inv:find(itemToConsume.recordId)
            
            if realItem then
                -- STRATEGY: Global Authority
                -- Local script cannot modify item.count (read-only) or remove items (no API).
                -- We send the item handle to Global, which has permission.
                core.sendGlobalEvent('ProjectilePhysics_ConsumeAmmo', {
                    item = realItem,
                    count = 1,
                    actor = self
                })
            else
                debugLog('[AMMO] Could not find ammo item in inventory: ' .. tostring(itemToConsume.recordId))
            end
        end
    end
    -- [FIX 2] Ammo is now restored exclusively by the caller (or delayed for thrown weapons)
    -- to structurally prevent vanilla engine evaluation bypasses.
    consumeAmmo()
    
    -- Reset state
    passiveAttackActive = false
    
    -- [DEBUG]
    -- debugLog(string.format("Fired %s: Charge %.2f, Dmg %.1f, Speed %.0f", pType, chargeRatio, damage, speed))
end

-- Helper to safely clear all attack states and restore animation
local function resetAttackState()
    if passiveHoldActive then
        anim.setSpeed(self, 'crossbow', 1)
        anim.setSpeed(self, 'throwweapon', 1)
        passiveHoldActive = false
    end
    if passiveAmmoHidden then
        restoreAmmoAfterShot()
    end
    passiveIsUnequipping = false
    passiveIsReadying = false
    passiveAttackActive = false
    passiveHoldActive = false
end

-- Handles the conflict between other mods (needing ammo) and the engine (needing none)
-- ============================================================================
-- Registration

-- MAIN TEXT KEY HANDLER (Unified)
-- Registration is delayed to ensure we run AFTER other mods like Combat API.
local function onTextKey(group, key)
    if not key then return end
    local lKey = key:lower()
    local lGroup = group and group:lower() or ''
    if lGroup ~= 'bowandarrow' and lGroup ~= 'crossbow' and lGroup ~= 'throwweapon' then return end

    if lKey == 'fakerelease' or lKey == 'shoot fakerelease' then
        if passiveIsReadying then return end
        debugLog('PLAYER FAKERELEASE TRIGGERED. Group: ' .. tostring(lGroup))
        
        -- Play correct sound based on weapon type
        if lGroup == 'bowandarrow' then
            core.sound.playSound3d('bowshoot', self)
        elseif lGroup == 'crossbow' then
            -- Sounds are emitted by the fire path (onFrame/min hit), not fakerelease
        end
        
        if anim and anim.cancel then
            anim.cancel(self, group)
            debugLog('PLAYER FAKERELEASE - anim.cancel() executed')
            debugLog('Fake release intercepted. Animation canceled for ' .. lGroup)
        end

        if passiveAttackActive and not passiveDidFire[passiveGeneration] then
             -- [SUPPRESSION] Proactive unequip MUST run BEFORE playBlended
             -- Otherwise playBlended instantly evaluates native `fakerelease` 
             -- while the weapon is still equipped in C++, spawning the vanilla drop!
             local wasHidden = false
             if not passiveAmmoHidden then
                 hideAmmoForSuppression()
                 wasHidden = true
             end
             
             -- [ANIMATION BLENDING] Play the follow-through sequence so the arm/bow lowers naturally
             if anim and anim.playBlended then
                 pcall(function()
                     anim.playBlended(self, group, {
                         startKey = 'shoot follow start',
                         stopKey  = 'shoot follow stop',
                         priority = anim.PRIORITY.Default,
                         loops    = 1,
                         autoblend = true,
                     })
                 end)
                 debugLog('Release follow-through blended for ' .. lGroup)
             end
             -- [REVISION 28] Bolt Hold Filter
             if passiveWeaponType == 'bolt' and input.isActionPressed(input.ACTION.Use) and camera.getMode() ~= 0 then
                 anim.setSpeed(self, 'crossbow', 0)
                 passiveHoldActive = true
                 debugLog('Crossbow: Release key hit while holding - blocking fire.')
                 return
             end

             -- Calculate Charge
             local now = core.getRealTime()
             local elapsed = now - (passiveAttackStartTime or now)
             local timings = WEAPON_TIMINGS[passiveWeaponType] or WEAPON_TIMINGS.arrow
             local chargeWindow = timings.maxAttackTime - timings.minAttackTime
             local chargeRatio = math.max(0.1, math.min(1.0, chargeWindow > 0 and (elapsed - timings.minAttackTime) / chargeWindow or 1.0))

             -- Authoritative Fire
             firePhysicsProjectile(chargeRatio, true, passiveAmmoItem)
             passiveDidFire[passiveGeneration] = true
             lastLaunchTime = now
             scanLeaksTimer = 1.0
             
             -- [CAUTION] Restore immediately to avoid breaking subsequent shots or other mods
             if wasHidden then
                 restoreAmmoAfterShot()
             end
             debugLog(passiveWeaponType .. ': Physic fire complete (Suppressed & Restored)')
        end
        return
    end

    if lKey == 'shoot start' then
        if passiveIsReadying then return end
        -- [FIX 3] Block shot if we are in the middle of an unequip animation
        if passiveIsUnequipping then
            debugLog('Shoot start suppressed: unequip animation in progress.')
            return
        end
        -- [DYNAMIC COOLDOWN] Block new shots until the previous animation is fully done.
        if not passiveAnimReady then
            debugLog('Shoot start blocked: previous animation not finished.')
            return
        end

        -- [REVISION 30] Absolute Shield: crossbow hold blocks new starts
        if passiveHoldActive then
            return
        end

        -- [LEGACY FALLBACK] Hard cooldown (catches edge cases where stop key was missed)
        if core.getRealTime() - (lastLaunchTime or 0) < 0.4 then
            return
        end
        
        passiveAnimReady = false  -- Lock until shoot follow stop / unequip stop
        
        -- [CRITICAL] Update generation to invalidate old cleanup timers
        passiveGeneration = passiveGeneration + 1
        local myGen = passiveGeneration
        passiveDidFire[myGen] = false
        passiveProcessedMinHit[myGen] = false
        passiveShootSoundPlayed[myGen] = false
        passivePullSoundPlayed[myGen] = false
        
        -- [CRITICAL] Reset old state before starting new attack
        resetAttackState()
        
        local weapon = types.Actor.getEquipment(self)[types.Actor.EQUIPMENT_SLOT.CarriedRight]
        if isProjectileWeapon(weapon) then
            passiveAttackActive = true
            passiveWasReleased = false
            passiveAttackStartTime = core.getRealTime()
            passiveWeaponItem = weapon
            local wRec = types.Weapon.record(weapon)
            if wRec.type == types.Weapon.TYPE.MarksmanThrown then
                passiveWeaponType = 'thrown'
                passiveIsThrown = true
                passiveAmmoItem = weapon
            else
                passiveWeaponType = (wRec.type == types.Weapon.TYPE.MarksmanCrossbow) and 'bolt' or 'arrow'
                passiveIsThrown = false
                passiveAmmoItem = types.Actor.getEquipment(self)[types.Actor.EQUIPMENT_SLOT.Ammunition]
            end

            if not passiveAmmoItem then
                debugLog('Attack aborted: No ammo in slot at Shoot Start.')
                passiveAttackActive = false
                return
            end
            
            debugLog('Attack initialized (Gen ' .. myGen .. '): ' .. tostring(passiveWeaponType))
        end
        
    elseif lKey == 'shoot min hit' then
        if passiveAttackActive then
             if passiveWeaponType == 'thrown' then
                 -- By pausing the animation here if the user is holding their throw,
                 -- we actively prevent the openMW C++ engine from advancing to native release frames
                 -- organically, which structurally bans the double-projectile.
                 local isIntentionalHold = input.isActionPressed(input.ACTION.Use) and not passiveWasReleased
                 if isIntentionalHold and not passiveHoldActive then
                     anim.setSpeed(self, 'throwweapon', 0)
                     passiveHoldActive = true
                     debugLog('Thrown: Held at Min Hit - Frozen locally to trap hardcoded drop.')
                 end
             elseif passiveWeaponType == 'bolt' then
                  -- [REVISION 32] Intentional Hold Check
                  local isIntentionalHold = input.isActionPressed(input.ACTION.Use) and not passiveWasReleased
                  local canHold = (camera.getMode() ~= 0)
                  
                  if passiveWeaponType == 'bolt' and isIntentionalHold and not passiveHoldActive and canHold then
                      anim.setSpeed(self, 'crossbow', 0)
                      passiveHoldActive = true
                      debugLog('Crossbow: Held at Min Hit (3rd Person) - Frozen.')
                  elseif not passiveHoldActive then
                      -- [REVISION 33] Authoritative Tap-Fire at Min Hit
                      if passiveProcessedMinHit[passiveGeneration] then return end
                      passiveProcessedMinHit[passiveGeneration] = true

                      -- Taps/Spam: Fire if we haven't already.
                      if not passiveDidFire[passiveGeneration] then
                          -- [SUPPRESSION] Proactive unequip for tap-fire.
                          local wasHidden = false
                          if not passiveAmmoHidden then
                               hideAmmoForSuppression()
                               wasHidden = true
                          end

                          -- Fire authoritative projectile
                          firePhysicsProjectile(1.0, true, passiveAmmoItem)
                          passiveDidFire[passiveGeneration] = true
                          lastLaunchTime = core.getRealTime()
                          scanLeaksTimer = 1.0
                          
                          -- Cancel vanilla animation to prevent double-projectile
                          if anim and anim.cancel then 
                              anim.cancel(self, 'crossbow') 
                          end

                          -- [FIX] Synchronized manual sounds
                          playCrossbowSounds()

                          -- Immediate restore so subsequent handlers don't see nil
                          if wasHidden then restoreAmmoAfterShot() end
                          
                          debugLog(tostring(passiveWeaponType) .. ': Rapid-fire (Tap) launch at Min Hit.')
                      end
                  end
             end
        end
    elseif lKey == 'shoot release' then
        debugLog('PLAYER SHOOT RELEASE TRIGGERED. Active: ' .. tostring(passiveAttackActive) .. ', Fired: ' .. tostring(passiveDidFire[passiveGeneration]))
        if passiveAttackActive and not passiveDidFire[passiveGeneration] then
             -- [USER REQUEST] For thrown weapons, we ONLY fire on fakerelease key.
             -- Bows and Crossbows still use shoot release as a fallback/forward.
             if passiveWeaponType ~= 'thrown' then
                 -- [USER REQUEST] Cancel vanilla animation to prevent double-projectile from base engine
                 if anim and anim.cancel then
                     anim.cancel(self, group)
                     debugLog('PLAYER SHOOT RELEASE - anim.cancel() executed to act as fakerelease')
                 end
     
                 debugLog('PLAYER SHOOT RELEASE - Forwarding to fakerelease logic')
                 onTextKey(group, 'fakerelease')
             else
                 debugLog('PLAYER SHOOT RELEASE - Ignored for Thrown (Waiting for fakerelease key)')
             end
        end
        
    elseif lKey == 'unequip start' or lKey == 'equip start' then
        -- [CLEANUP] If we unequip or ready at any point, immediately reset attack state 
        -- so it doesn't linger until the next readying.
        resetAttackState()
        if lKey == 'equip start' then passiveIsReadying = true end
        debugLog(lKey .. ' — attack state reset.')
    elseif lKey == 'shoot follow stop' or lKey == 'unequip stop' or lKey == 'equip stop' then
        passiveIsUnequipping = false
        passiveIsReadying = false
        if passiveAttackActive or passiveHoldActive or passiveAmmoHidden then
             -- [REVISION 27] Natural Recovery
             -- Restore ammo and clear flags ONLY after animation is fully finished.
             resetAttackState()
             passiveIsThrown = false
             debugLog('Cleanup complete (follow stop)')
        end
        -- [DYNAMIC COOLDOWN] Animation is done; allow new attacks.
        passiveAnimReady = true
        debugLog('Animation ready flag reset.')
    end
end

if I.AnimationController then
    -- Use single authoritative handler - Register late to run after Combat API
    async:newUnsavableSimulationTimer(0.5, function()
        I.AnimationController.addTextKeyHandler(nil, onTextKey)
        debugLog('Actor-Aligned Suppression System active.')
    end)
end

-- Main frame handler (Simplified)
local frameCount = 0
local lastActivateState = false
local lastTogglePOVState = false
local lastGodModeState = false

-- [TASK 6] Inventory Loot Detection
local preLootSnapshot  = {}   -- { [recordId] = count } before looting
local lootTargetActor  = nil  -- the actor we are looting from
local lootCheckPending = false
local LOOT_CHECK_DELAY = 0.7  -- Increased to ensure we catch gains after menu closure.
local lootCheckTimer   = 0

-- [CACHED AIM] Updated every frame while drawing. Used by firePhysicsProjectile
-- since castRenderingRay is forbidden inside animation callbacks.
local cachedStartPos = nil
local cachedDirection = nil
local cachedPhysicsHit = nil

local function onFrame(dt)
    frameCount = frameCount + 1
    


    -- [REVISION 34] Real-time Unequip Detection
    -- If the weapon is no longer equipped while we are in an attack state,
    -- clean up immediately to prevent ghost-firing or stuck states.
    if passiveAttackActive and not passiveIsUnequipping then
        local equip = types.Actor.getEquipment(self)
        local wpn = equip[types.Actor.EQUIPMENT_SLOT.CarriedRight]
        if not wpn or wpn.recordId ~= (passiveWeaponItem and passiveWeaponItem.recordId) then
             debugLog('Mid-attack unequip detected — cleaning up.')
             passiveIsUnequipping = false  -- [CORRECT] Must be false for the next attack to start
             resetAttackState()
             passiveAnimReady = true
        end
    end

    -- [REVISION 32] Crossbow Hold Release + Bow Early Intercept
    -- Responding faster (0.1s buffer) and tracking release state for spam-bypass.
    if passiveAttackActive and not passiveIsReadying and not input.isActionPressed(input.ACTION.Use) then
        if not passiveWasReleased then
            passiveWasReleased = true
            
            -- [USER REQUEST] Thrown weapons ONLY fire via fakerelease key.
            -- Scheduling is disabled for thrown to ensure frame-perfect sync with anim.
            if passiveWeaponType == 'arrow' then
                local currentGen = passiveGeneration
                local wpnGroup = 'bowandarrow'
                
                local now = core.getRealTime()
                local elapsed = now - (passiveAttackStartTime or now)
                local timings = WEAPON_TIMINGS.arrow
                local remaining = timings.minAttackTime - elapsed
                
                if remaining <= 0 then
                    -- Synchronously trigger our fakerelease to cleanly and instantly cut the 
                    -- native animation chain the identical frame the mouse unclicks.
                    if passiveAttackActive and not passiveDidFire[currentGen] then
                        onTextKey(wpnGroup, 'fakerelease')
                    end
                else
                    -- Released too early — let the animation continue, fire when minimum draw is reached
                    debugLog(('PLAYER onFrame early release - scheduling fakerelease in %.3fs'):format(remaining))
                    async:newUnsavableSimulationTimer(remaining, function()
                        if passiveAttackActive and not passiveDidFire[currentGen] then
                            onTextKey(wpnGroup, 'fakerelease')
                        end
                    end)
                end
            elseif passiveWeaponType == 'thrown' then
                debugLog('PLAYER onFrame early release - Thrown weapon waiting for native fakerelease key')
            end
        end
    end

    if passiveHoldActive then
        if not input.isActionPressed(input.ACTION.Use) then
            holdReleaseBuffer = holdReleaseBuffer + dt
            
            -- Shorter buffer for thrown
            local bufferMax = (passiveWeaponType == 'thrown') and 0.01 or 0.1
            
            if holdReleaseBuffer > bufferMax then
                 if not passiveDidFire[passiveGeneration] then
                     if passiveWeaponType == 'thrown' then
                         -- Manually force our logical fakerelease chain which
                         -- evaluates physics, runs anim.cancel, and plays the
                         -- visual follow-through so it organically releases.
                         onTextKey('throwweapon', 'fakerelease')
                     else
                         -- [SUPPRESSION] Late Suppression for Crossbow Release
                         local wasHidden = false
                         if not passiveAmmoHidden then
                             hideAmmoForSuppression()
                             wasHidden = true
                         end
    
                         firePhysicsProjectile(1.0, true, passiveAmmoItem)
                         passiveDidFire[passiveGeneration] = true
                         lastLaunchTime = core.getRealTime()
                         scanLeaksTimer = 1.0
                         
                         if anim and anim.cancel then
                             anim.cancel(self, 'crossbow')
                         end
    
                         -- [FIX] Synchronized sounds for held shots
                         playCrossbowSounds()
                         
                         if wasHidden then restoreAmmoAfterShot() end
                         debugLog('Crossbow: Release fire (onFrame)')
                     end
                 end
                 
                 local groupToReset = (passiveWeaponType == 'thrown') and 'throwweapon' or 'crossbow'
                 anim.setSpeed(self, groupToReset, 1)
                 passiveHoldActive = false
                 holdReleaseBuffer = 0
             end
        else
            holdReleaseBuffer = 0
        end
    end

    -- [CACHED AIM] While drawing, update the cached aim every frame
    -- This is the ONLY place where castRenderingRay is allowed (input event context)
    if passiveAttackActive then
        local ok, s, r, p, d = pcall(raycastProjectilePath, 10000)
        if ok then
            cachedStartPos = s
            cachedDirection = d
            cachedPhysicsHit = p
        end
    end
    
    -- [VFX REFRESH] User-requested strict input trigger (TogglePOV)
    local input = require('openmw.input')
    local isTogglePressed = input.isActionPressed(input.ACTION.TogglePOV)
    
    if isTogglePressed and not lastTogglePOVState then
         async:newUnsavableSimulationTimer(0.1, function()
             core.sendGlobalEvent('ProjectilePhysics_RequestVfxRefresh', { actor = self })
         end)
    end
    -- [TASK 6] Loot Check Ticker
    if lootCheckPending then
        lootCheckTimer = lootCheckTimer + dt
        if lootCheckTimer >= LOOT_CHECK_DELAY then
            lootCheckPending = false
            debugLog('[LOOT-PLAYER] Performing post-loot diff check...')
            -- Diff current vs snapshot
            local playerInv = types.Actor.inventory(self)
            local currentCounts = {}
            for _, item in ipairs(playerInv:getAll(types.Ammunition)) do
                currentCounts[item.recordId:lower()] = (currentCounts[item.recordId:lower()] or 0) + item.count
            end
            for _, item in ipairs(playerInv:getAll(types.Weapon)) do
                local rec; pcall(function() rec = types.Weapon.record(item) end)
                if rec and (rec.type == types.Weapon.TYPE.MarksmanThrown) then
                    currentCounts[item.recordId:lower()] = (currentCounts[item.recordId:lower()] or 0) + item.count
                end
            end
            
            local diffDetected = false
            for recordId, preCount in pairs(preLootSnapshot) do
                local postCount = currentCounts[recordId] or 0
                local gained = postCount - preCount
                if gained > 0 then
                    debugLog(string.format('[LOOT-PLAYER] Detected gain: %s x %d', recordId, gained))
                    core.sendGlobalEvent('ProjectilePhysics_OnLootedFromInventory', {
                        recordId = recordId,
                        count    = gained,
                        actor    = lootTargetActor,
                        player   = self, -- Pass player reference
                    })
                    diffDetected = true
                end
            end
            -- Check for items NOT in snapshot (newly gained)
            for recordId, postCount in pairs(currentCounts) do
                if preLootSnapshot[recordId] == nil then
                    debugLog(string.format('[LOOT-PLAYER] Detected new item gain: %s x %d', recordId, postCount))
                    core.sendGlobalEvent('ProjectilePhysics_OnLootedFromInventory', {
                        recordId = recordId,
                        count    = postCount,
                        actor    = lootTargetActor,
                        player   = self, -- Pass player reference
                    })
                    diffDetected = true
                end
            end
            
            if diffDetected then
                -- [RE-ARM] Refresh snapshot and reset timer to catch next bunch of loot
                preLootSnapshot = currentCounts
                lootCheckTimer = 0
            elseif lootCheckTimer > 8.0 then
                -- [END SESSION] No activity for 8 seconds
                lootCheckPending = false
                preLootSnapshot  = {}
                lootTargetActor  = nil
                debugLog('[LOOT-PLAYER] Monitoring session ended.')
            end
        end
    end

    lastTogglePOVState = isTogglePressed

    -- God Mode Sync
    local isGodMode = debug.isGodMode()
    if isGodMode ~= lastGodModeState then
        lastGodModeState = isGodMode
        core.sendGlobalEvent('ProjectilePhysics_UpdateGodMode', isGodMode)
    end
    
    -- Smart Ammo Logic (Only if not attacking)
    if not passiveAttackActive then
        local now = core.getRealTime()
        -- [USER REQUEST] Throttle smartAmmoUpdate to once per 0.25 seconds.
        if now - (lastInteractionTime or 0) > 0.5 then
            lastInteractionTime = now
            smartAmmoUpdate()
        end
    else
        -- [REVISION 30] Safety Timeout (30s)
        local elapsed = core.getRealTime() - (passiveAttackStartTime or 0)
        if passiveAttackActive and elapsed > 30.0 then
             resetAttackState()
             debugLog('Safety timeout triggered (30s).')
        end
    end
    
    -- Stuck Arrow Pickup (Activate Key)
    -- [USER REQUEST] Sync Sneak State via Global Script (Avoid illegal storage write)
    if input.isActionPressed(input.ACTION.Sneak) ~= lastSneakState then
        core.sendGlobalEvent('ProjectilePhysics_SyncSneakState', { sneaking = input.isActionPressed(input.ACTION.Sneak), player = self })
        lastSneakState = input.isActionPressed(input.ACTION.Sneak)
    end

    local isActivatePressed = input.isActionPressed(input.ACTION.Activate)
    if isActivatePressed and not lastActivateState then
        local isActuallySneaking = input.isActionPressed(input.ACTION.Sneak)
        local pickupMode = settings.advanced:get('pickupMode')
        
        -- EXCLUSIVE CHECK: If looking directly at a physics activator/item, prioritize single pickup
        local from = camera.getPosition()
        local dir = getCameraDirection()
        local to = from + (dir * 300)
        local ray = nearby.castRay(from, to, { ignore = self, collisionType = 63 })
        local directLook = ray.hitObject
        
        local isLookingAtStuck = false
        if directLook and directLook.recordId then
            local rId = directLook.recordId:lower()
            if rId:find("^pp_act_") or rId:find("^pp_s_") or rId:find("^pp_vfx_") then
                 isLookingAtStuck = true
            end
        end

        -- Path 1: Direct Single Pickup (Exclusive)
        if isLookingAtStuck then
            -- Global Script's onActivate handles this! 
            -- By exiting here, we ensure "Mass Salvage" is NOT triggered even if sneaking.
            lastActivateState = isActivatePressed
            return
        end

        -- Path 2: Special Activation Logic (Sneak/Harvest)
        -- [EXCLUSIVE] Only available if NOT in inventory pickup mode
        if isActuallySneaking then 
             -- 1. Check for self-harvest (Looking down)
             if camera.getPitch() > 1.2 then
                 core.sendGlobalEvent('ProjectilePhysics_RemoveOneVfxFromTarget', { target = self, player = self })
                 lastActivateState = isActivatePressed
                 return
             end
             
             -- 2. Check for Mass Salvage (Virtual Raycast to Body)
             local from = camera.getPosition()
             local dir = getCameraDirection()
             local to = from + (dir * 400)
             core.sendGlobalEvent('ProjectilePhysics_VirtualTryCollectFromActor', { 
                 player = self,
                 rayFrom = from,
                 rayTo = to
             })
        end

         -- [TASK 6] Path 3: Inventory Loot Detection
         -- [REVISION] ONLY do this if pickupMode is 'inventory'. For mass_harvest or activation, VFX are handled differently.
         -- If we are just activating a dead body (not sneaking), snapshot inventory to detect loots
         if not isLookingAtStuck and not isActuallySneaking and pickupMode == 'inventory' then
              local fromLook = camera.getPosition()
              local dirLook = getCameraDirection()
              local toLook = fromLook + (dirLook * 300)
              local rayLook = nearby.castRay(fromLook, toLook, { ignore = self, collisionType = 63 })
              local targetLook = rayLook.hitObject
              if targetLook and (targetLook.type == types.NPC or targetLook.type == types.Creature) then
                  local hp = types.Actor.stats.dynamic.health(targetLook).current
                  if hp <= 0 then
                      -- Snapshot current player ammo counts
                      preLootSnapshot = {}
                      local playerInv = types.Actor.inventory(self)
                      for _, item in ipairs(playerInv:getAll(types.Ammunition)) do
                          preLootSnapshot[item.recordId:lower()] = (preLootSnapshot[item.recordId:lower()] or 0) + item.count
                      end
                      for _, item in ipairs(playerInv:getAll(types.Weapon)) do
                          local rec; pcall(function() rec = types.Weapon.record(item) end)
                          if rec and (rec.type == types.Weapon.TYPE.MarksmanThrown) then
                              preLootSnapshot[item.recordId:lower()] = (preLootSnapshot[item.recordId:lower()] or 0) + item.count
                          end
                      end
                      lootTargetActor  = targetLook
                      lootCheckPending = true
                      lootCheckTimer   = 0
                      
                      local preCount = 0
                      for _ in pairs(preLootSnapshot) do preCount = preCount + 1 end
                      debugLog(string.format('[LOOT-PLAYER] Snapshotted %d items from body: %s', preCount, targetLook.id))
                  end
              end
         end
    end
    lastActivateState = isActivatePressed
    
end
return {
    engineHandlers = {
        onFrame = onFrame,
        onSave = function()
            -- Safety: If saving while mid-shot, restore equipment so save file is clean.
            -- This prevents "lost ammo" bugs if game is reloaded.
            if passiveAmmoHidden then
                restoreAmmoAfterShot()
            end
            return {
                preferredAmmoMap = preferredAmmoMap
            }
        end,
        onLoad = function(data)
            if data and data.preferredAmmoMap then
                preferredAmmoMap = data.preferredAmmoMap
            end
        end,
    },
    eventHandlers = {

        -- ProjectilePhysics_ApplyDamage is now handled by ProjectilePhysicsActor.lua for the player too
        -- to ensure consistent regional damage and armor logic.
        -- Marksman XP is handled by engine via successful=true
        
        ProjectilePhysics_AwardMarksmanXP = function(data)
            local I = require('openmw.interfaces')
            if I.SkillProgression then
                local useType = (types.Actor.SKILL_USE_TYPE and types.Actor.SKILL_USE_TYPE.Hit) or 1 
                I.SkillProgression.skillUsed('marksman', { useType = useType })
                -- debugLog('[XP] Awarded Marksman XP via SkillProgression')
            end
        end,

        ProjectilePhysics_ShowMessage = function(data) 
            if data.msg then 
                debugLog("ShowMessage Received: " .. data.msg)
                ui.showMessage(data.msg) 
            end 
        end,
        -- [BLOCK FEEDBACK] Play animation and sound when global confirms a block
        -- Generic "launch from camera" entry point for external mods.
        -- Caller provides projectileType, recordId, weaponRecordId.
        -- This handler resolves the correct startPos and direction based on
        -- current camera mode (1st vs 3rd person) and fires the global event.
        ProjectilePhysics_LaunchFromCamera = function(data)
            if not data or not data.recordId then return end

            local pitch = -(camera.getPitch() + camera.getExtraPitch())
            local yaw   =  (camera.getYaw()   + camera.getExtraYaw())

            local direction, startPos
            if camera.getMode() ~= 0 then
                -- 3rd person: derive yaw from actor body, pitch from camera
                local bodyDir = self.rotation * util.vector3(0, 1, 0)
                local bodyYaw = math.atan2(bodyDir.x, bodyDir.y)
                local xzLen = math.cos(pitch)
                direction = util.vector3(xzLen * math.sin(bodyYaw), xzLen * math.cos(bodyYaw), math.sin(pitch))
                local forwardDir = util.vector3(direction.x, direction.y, 0):normalize()
                startPos = self.position + util.vector3(0, 0, 110) + (forwardDir * 10)
            else
                local xzLen = math.cos(pitch)
                direction = util.vector3(xzLen * math.sin(yaw), xzLen * math.cos(yaw), math.sin(pitch))
                startPos  = camera.getPosition()
            end

            core.sendGlobalEvent('ProjectilePhysics_PlaceProjectile', {
                projectileType   = data.projectileType or 'thrown',
                recordId         = data.recordId,
                weaponRecordId   = data.weaponRecordId or data.recordId,
                attacker         = self,
                attackerVelocity = self.velocity or util.vector3(0, 0, 0),
                startPos         = startPos,
                direction        = direction,
                spawnAtLauncher  = true,
                flightTime       = 0,
                isMiss           = false,
                isDirectHit      = false,
            })
        end,

        ProjectilePhysics_BlockFeedback = function(data)
            debugLog('BLOCK-FEEDBACK EVENT RECEIVED - Playing animation and sound')
            -- Play shield raise animation using standard API
            local animOk, animErr = pcall(function()
                 -- Player might not have 'shieldraise' (especially in 1st person), so check generic groups too
                 local candidates = {"shieldraise", "shield", "Shield", "block", "Block"}
                 local validGroup = nil
                 
                 for _, g in ipairs(candidates) do
                     if anim.hasGroup(self, g) then
                         validGroup = g
                         break
                     end
                 end
                 
                 if validGroup then
                     debugLog('Playing animation group: ' .. validGroup)
                     
                     local opts = {
                         priority = anim.PRIORITY.Scripted + 1000, 
                         blendMask = 8, 
                         loops = 1,
                         autoblend = false
                     }
                     if validGroup == "shieldraise" or validGroup == "Shieldraise" then
                         opts.startKey = "start"
                         opts.stopKey = "stop"
                     end
                     
                     anim.playBlended(self, validGroup, opts)
                     anim.setSpeed(self, validGroup, 1.6) -- [USER REQUEST] Fast raise
                     
                     -- Transition to fast drop/stop (Approximate midpoint)
                     async:newUnsavableSimulationTimer(0.17, function()
                         -- Ensure we only apply if the block sequence hasn't naturally ended
                         pcall(function() anim.setSpeed(self, validGroup, 0.5) end)
                     end)
                     
                     core.sound.playSound3d("Heavy Armor Hit", self, {volume=1.0, pitch=0.8+math.random()*0.4})
                 else
                     debugLog('Warning: No suitable block animation group found (checked: shieldraise, shield, block, etc.)')
                 end
            end)
            if not animOk then debugLog('playBlended failed: ' .. tostring(animErr)) end
            end,
    },
}
