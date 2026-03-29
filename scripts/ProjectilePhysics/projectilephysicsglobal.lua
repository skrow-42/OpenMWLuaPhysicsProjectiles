-- ProjectilePhysicsGlobal.lua
-- Global-side projectile placement using ArrowStick-inspired approach
-- Places projectiles at raycast hit positions with timer delay

local core = require('openmw.core')
local world = require('openmw.world')
local types = require('openmw.types')
local util = require('openmw.util')
local async = require('openmw.async')
local storage = require('openmw.storage')
local I = require('openmw.interfaces')

-- Load settings
local settingsGeneral = storage.globalSection('settingsprojectilephysics')
local settingsAdvanced = storage.globalSection('settingsprojectilephysicsadvanced')
local settingsGravity = storage.globalSection('settingsprojectilephysicsgravity')
local poseTransforms = require('scripts/projectilephysics/poseTransforms')
local D = nil
pcall(function() D = require('scripts/MaxYari/LuaPhysics/scripts/physics_defs') end)
-- ============================================================================
-- STATE TRACKING
-- ============================================================================
local settingsCache = {} -- [FIX] Early initialization for getSetting
local staggeredBatches = {}
local nextProcessTime = 0
local boneSyncRegistry = {} 
local placedProjectiles = {} 
local lastAssaultBountyTime = {} 
local projectileBountyActive = {} 
local isGodModeActive = false
local playersSneaking = {}
local lastEnchantDrainPoll = 0 -- [FIX] For throttled drain
local lastCleanupTime = 0 

-- Safe settings getter
local function getSetting(section, key, default)
    if not section then return default end
    if settingsCache[key] ~= nil then return settingsCache[key] end
    -- Try direct case first
    local value = section:get(key)
    -- Fallback to lowercase (often used by storage API for keys)
    if value == nil then value = section:get(key:lower()) end
    return (value ~= nil) and value or default
end

local function debugLog(message)
    if getSetting(settingsGeneral, 'debugMode', false) then
        print('[ProjectilePhysics Global] ' .. message)
    end
end

-- ============================================================================
-- RANGED ON-USE TO ON-STRIKE CONVERSION SYSTEM
-- Forces "Cast on Use" bow charges to 0 and applies them on hit instead
-- ============================================================================
local virtualEnchantRegistry = {}
--[[
  virtualEnchantRegistry[actorId] = {
      items = {
          [itemId] = {
              enchantId     = string,
              virtualCharge = number,
              costPerUse    = number,
              maxCharge     = number,
              recordId      = string
          },
          ...
      },
      notifiedNoCharge = { [enchantId] = boolean }
  }
]]

local function fetchEnch(enchantId)
    if not enchantId or enchantId == "" then return nil end
    local e = nil
    if core.magic and core.magic.enchantments then
        e = (core.magic.enchantments.records
                and core.magic.enchantments.records[enchantId])
    end
    return e
end

local function isAoeEnchantment(enchantId)
    local ench = fetchEnch(enchantId)
    if not ench or not ench.effects then 
        debugLog('  [AOE-CHECK] No record or effects for ' .. tostring(enchantId))
        return false 
    end
    
    -- Check all effects for area (OpenMW API uses 'area' for radius)
    -- Robust loop for both 0-indexed vectors and 1-indexed tables
    for i = 0, 10 do
        local effect = ench.effects[i]
        if effect then
            local r = effect.area or 0
            if r > 0 then 
                debugLog(string.format('  [AOE-CHECK]nonlegacy %s IS AOE (Effect[%d] area: %d)', enchantId, i, r))
                return true 
            end
        else
            if i > 0 then break end -- Stop if no effect at i > 0
        end
    end
    debugLog('  [AOE-CHECK] ' .. enchantId .. ' is NOT AoE (no area/radius found)')
    return false
end

local function getEffectiveCost(baseCost, actor)
    local skill = 0
    pcall(function()
        if actor and (actor.type == types.NPC or actor.type == types.Player) then
            local skills = (actor.type == types.Player) and types.Player.stats.skills or types.NPC.stats.skills
            skill = skills.enchant(actor).modified
        end
    end)
    return math.max(1, math.floor(0.01 * (110 - skill) * baseCost))
end

-- [CORE] Global Magic Visuals (Entirely in Global - no actor delegation)
local function playMagicVfxGlobal(target, enchantId, isAoe)
    if not target or not target:isValid() then return end
    local enchant = fetchEnch(enchantId)
    if not enchant or not enchant.effects then 
        debugLog('  [GLOBAL-VFX] No enchant record for VFX: ' .. tostring(enchantId))
        return 
    end
    
    local foundAny = false
    for i = 0, 10 do
        local effect = enchant.effects[i]
        if effect then
            -- effect.effect is already the MagicEffect record object in OpenMW
            local mgef = effect.effect
            if type(mgef) == 'string' then
                local strId = mgef
                mgef = core.magic.effects.records[strId] or core.magic.effects[strId]
            elseif not mgef and effect.id then
                local strId = effect.id
                mgef = core.magic.effects.records[strId] or core.magic.effects[strId]
            end
            
            if mgef then
                -- Visuals
                -- Only use the hitStatic on the individual victim so we don't duplicate the massive area explosion on their feet
                local vfxId = mgef.hitStatic
                local particleOverlay = mgef.particle or ""
                local mgid = mgef.id or ""
                
                if vfxId and vfxId ~= '' then
                        if target.type == types.NPC or target.type == types.Creature or target.type == types.Player then
                            local staticRec = types.Static.records[vfxId]
                            if staticRec and staticRec.model then
                                target:sendEvent('AddVfx', {
                                    model = staticRec.model,
                                    options = { 
                                        loop = false,
                                        particleTextureOverride = particleOverlay,
                                        mwMagicVfx = true,
                                        vfxId = mgid
                                    }
                                })
                                foundAny = true
                            end
                        end
                    end
                    -- Sounds
                    local soundId = isAoe and mgef.areaSound
                    local school = mgef.school
                    
                    if not soundId or soundId == '' then
                        if school and school ~= '' then
                            soundId = school .. " area" -- generic fallback
                        end
                    end
                    if soundId and soundId ~= '' then
                        target:sendEvent('PlaySound3d', { sound = soundId })
                        foundAny = true
                    end
                end
        else
            if i > 0 then break end
        end
    end
    if foundAny then
        debugLog(string.format('  [GLOBAL-VFX] Played effects for %s on %s', enchantId, tostring(target.recordId or target.id)))
    end
end

-- Enchantment ID Lookup
local function getProjectileEnchantId(projData)
    if not projData then return nil end
    local enchantId = nil
    local sourceType = nil
    
    local pType = projData.type or projData.projectileType
    local isThrown = (pType == 'thrown')
    
    -- Ammo record enchantment (e.g. Firestorm Arrow)
    if projData.ammoRecordId then
        local rec = nil
        if types.Ammunition then 
            rec = types.Ammunition.records[projData.ammoRecordId] 
        end
        if not rec and types.Weapon then
            rec = types.Weapon.records[projData.ammoRecordId] 
        end
        
        if rec and rec.enchant and rec.enchant ~= '' then
            enchantId = rec.enchant
            sourceType = 'ammo'
            debugLog(string.format('  [GET-ENCH] P1 Ammo/Thrown Enchant: %s (from %s)', enchantId, projData.ammoRecordId))
        end
    end

    -- Launcher Registry & Record (Skip for thrown weapons)
    if not isThrown and not enchantId and projData.attacker and projData.attacker:isValid() and projData.launcher then
        local attacker = projData.attacker
        local launcher = projData.launcher
        local isPlayer = (attacker.type == types.Player)
        
        -- Path A: Virtual registry (NPCs / Drained weapons)
        local reg = virtualEnchantRegistry[attacker.id]
        if reg and reg.items then
            local itemData = reg.items[launcher.id]
            if itemData and itemData.enchantId then
                if not isAoeEnchantment(itemData.enchantId) then
                    enchantId = itemData.enchantId
                    sourceType = 'virtual'
                    debugLog(string.format('  [GET-ENCH] P2 Virtual Wrapper (Weapon: %s): %s', launcher.recordId, enchantId))
                else
                    debugLog(string.format('  [GET-ENCH] P2 Virtual REJECTED (Is AoE): %s', itemData.enchantId))
                end
            end
        end

        -- Path B: Native Launcher (Player-only / Un-drained)
        if not enchantId and isPlayer then
            local rec = nil
            pcall(function() rec = types.Weapon.records[launcher.recordId] end)
            if rec and rec.enchant and rec.enchant ~= "" then
                -- Even if it's Cast on Use, we treat it as a Strike enchantment for our projectiles
                if not isAoeEnchantment(rec.enchant) then
                    enchantId = rec.enchant
                    sourceType = 'weapon'
                    debugLog(string.format('  [GET-ENCH] P2 Native Launcher (Player): %s', enchantId))
                end
            end
        end
    end
    if not enchantId then
        debugLog(string.format('  [GET-ENCH] No valid enchantment found. ammoId=%s, weaponId=%s, isThrown=%s', 
            tostring(projData.ammoRecordId), tostring(projData.weaponRecordId), tostring(isThrown)))
    end
    
    return enchantId, sourceType
end

-- Helper for school-specific failure sound
local function playEnchantFailureSound(actor, enchantId)
    local schoolName = "destruction" -- Default fallback
    local ench = fetchEnch(enchantId)
    if ench and ench.effects and ench.effects[0] then
        local mgef = core.magic.effects.records[ench.effects[0].id]
        if mgef and mgef.school then schoolName = mgef.school:lower() end
    end
    actor:sendEvent("PlaySound3d", { Sound = "spell failure " .. schoolName })
end

-- [CORE] Unified Enchantment Charge Check
local function checkPayForMagic(projData, enchantId, sourceType)
    if not enchantId then return false end
    if sourceType == 'ammo' or sourceType == 'instance' then return true end
    
    local attacker = projData.attacker
    if not attacker or not attacker:isValid() then return false end
    local isPlayer = (attacker.type == types.Player)

    if sourceType == 'virtual' and projData.launcher then
        local reg = virtualEnchantRegistry[attacker.id]
        if reg and reg.items then
            local itemData = reg.items[projData.launcher.id]
            if itemData and itemData.enchantId == enchantId then
                if itemData.virtualCharge >= itemData.costPerUse then
                    itemData.virtualCharge = itemData.virtualCharge - itemData.costPerUse
                    debugLog(string.format('[RANGED-CONV] Applied %s via Weapon %s Pool | Remaining: %d', enchantId, projData.launcher.recordId, itemData.virtualCharge))
                    return true
                else
                    if isPlayer and not (reg.notifiedNoCharge and reg.notifiedNoCharge[enchantId]) then
                        if not reg.notifiedNoCharge then reg.notifiedNoCharge = {} end
                        reg.notifiedNoCharge[enchantId] = true
                        playEnchantFailureSound(attacker, enchantId)
                        attacker:sendEvent('ProjectilePhysics_ShowMessage', { msg = "Item does not have enough charge." })
                        debugLog('[RANGED-CONV] Virtual Pool out of charge for ' .. enchantId)
                    end
                    return false
                end
            end
        end
     elseif sourceType == 'weapon' and projData.launcher and projData.launcher:isValid() then
        local ench = fetchEnch(enchantId)
        local cost = getEffectiveCost(ench and ench.cost or 1, attacker)
        local data = types.Item.itemData(projData.launcher)
        local current = (data and data.enchantmentCharge)
        
        -- If missing dynamic data, fallback to record max (implies it hasn't been used yet)
        if not current then
             local rec = types.Weapon.record(projData.launcher)
             current = (rec and ench) and ench.charge or 0
        end

        if current >= cost then
            core.sendGlobalEvent('ProjectilePhysics_DeductCharge', {
                item = projData.launcher,
                cost = cost,
                enchantId = enchantId
            })
            return true
         else
            if isPlayer then
                playEnchantFailureSound(attacker, enchantId)
                attacker:sendEvent('ProjectilePhysics_ShowMessage', { msg = "Item does not have enough charge." })
                debugLog('[GET-ENCH] Weapon out of charge. Notified player.')
            end
            return false
        end
    end
    return false
end

-- [CORE] Global Enchantment Application
-- Per KI: id = Item Record ID, effects = 0-based index list
local function applyEnchantmentGlobal(enchantId, caster, target, hitPos, isAoe, projData)
    if not enchantId or not target or not target:isValid() then return end
    if target.type ~= types.NPC and target.type ~= types.Creature and target.type ~= types.Player then return end

    -- Resolve the item record ID (for activeSpells:add, id = item recordId per KI)
    local itemRecordId = (projData and projData.ammoRecordId) or (projData and projData.weaponRecordId)
    if not itemRecordId then
        debugLog('  [GLOBAL-MAGIC] No item record ID available, using enchantId as fallback')
        itemRecordId = enchantId
    end

    -- Build 0-based effect index list from enchantment
    local enchant = fetchEnch(enchantId)
    local effectIndexes = {}
    if enchant and enchant.effects then
        for i, eff in ipairs(enchant.effects) do
            table.insert(effectIndexes, i - 1)
        end
    end
    if #effectIndexes == 0 then effectIndexes = {0} end -- fallback failsafe

    local ok, err = pcall(function()
        local activeSpells = types.Actor.activeSpells(target)
        if activeSpells then
            local params = {
                id = itemRecordId,
                stackable = false,
                effects = effectIndexes
            }
            if caster and caster:isValid() then params.caster = caster end
            
            -- Only pass projectile item if it's still a valid world object (not yet removed)
            if projData and projData.projectile and not isAoe then
                pcall(function()
                    if projData.projectile:isValid() then
                        params.item = projData.projectile
                    end
                end)
            end
            
            activeSpells:add(params)
            debugLog(string.format('  [GLOBAL-MAGIC] Applied %s (item=%s) to %s (AoE: %s)', 
                enchantId, itemRecordId, target.recordId or target.id, tostring(isAoe)))
        end
    end)
    
    if not ok then
        debugLog('  [GLOBAL-MAGIC-FAIL] ' .. tostring(err))
    end
    
    -- VFX and Sounds (always attempt even if spell application failed)
    playMagicVfxGlobal(target, enchantId, isAoe)
end

local function detonateEnchantmentAtPos(enchantId, caster, pos, sourceData, excludeActor)
    local enchant = fetchEnch(enchantId)
    if not enchant or not enchant.effects then 
        debugLog("  [AOE-FAIL] No enchantment record or effects for " .. tostring(enchantId))
        return 
    end
    
    local maxRadius = 0
    local RADIUS_MULT = 21.33 -- 1 foot = 21.33 units
    
    -- Radius Calculation (OpenMW API uses 'area')
    for i = 0, 10 do
        local effect = enchant.effects[i]
        if effect then
            local r = effect.area or 0
            if r > maxRadius then maxRadius = r end
        else
            if i > 0 then break end
        end
    end
    if maxRadius == 0 then
        for _, effect in ipairs(enchant.effects) do
            if effect then
                local r = effect.area or effect.radius or 0
                if r > maxRadius then maxRadius = r end
            end
        end
    end
    
    if maxRadius <= 0 then 
        debugLog("  [AOE-SKIP] Area (radius) is 0 for " .. tostring(enchantId))
        return 
    end
    local finalRadius = maxRadius * RADIUS_MULT
    debugLog(string.format('  [AOE-DETONATE] Calculating Pulse: Area=%d -> finalRadius=%.1f', maxRadius, finalRadius))
    
    local explosionSound = nil
    local areaStaticId = nil
    local areaParticleId = ""
    local visualScale = 1.0
    
    -- Find the primary effect to use for the visual "Orb" and "Boom"
    -- Based on engine logic: every effect spawns an orb, but we'll find the most prominent one
    for i = 0, 10 do
        local effect = enchant.effects[i]
        if effect then
            local mgef = effect.effect -- Already userdata
            if mgef then
                -- Determine visual shell scale per engine: area * 2
                local areaVal = effect.area or 0
                local currentScale = (areaVal > 0) and (areaVal * 2) or 1.0
                
                -- Determine Static Mesh and Sound
                local aSnd = mgef.areaSound
                local school = mgef.school
                local aStat = mgef.areaStatic
                
                -- Collect Sound: Priority = Current effect areaSound > Current effect school sound
                if not explosionSound and aSnd and aSnd ~= "" then
                    explosionSound = aSnd
                elseif not explosionSound and school and school ~= "" then
                    explosionSound = school .. " area"
                end
                
                -- Collect Visual: Use mArea if exists, otherwise VFX_DefaultArea fallback
                if not areaStaticId then
                    if aStat and aStat ~= "" then
                        areaStaticId = aStat
                    else
                        -- Engine Fallback
                        areaStaticId = "VFX_DefaultArea"
                    end
                    areaParticleId = mgef.particle or ""
                    visualScale = currentScale
                end
            end
        else
            if i > 0 then break end
        end
    end


    -- [WORLD IMPACT VFX] Resolve Static model path and spawn at position
    if areaStaticId then
        local staticRec = types.Static.records[areaStaticId]
        if staticRec and staticRec.model then
            -- Use world.vfx.spawn for world-position effects
            if world.vfx and world.vfx.spawn then
                world.vfx.spawn(staticRec.model, pos, { 
                    particleTextureOverride = areaParticleId,
                    mwMagicVfx = true,
                    scale = visualScale
                })
                debugLog(string.format('  [AOE-VFX] Spawned world VFX: %s at %s (Scale: %.2f)', staticRec.model, tostring(pos), visualScale))
            else
                debugLog('  [AOE-VFX] world.vfx.spawn not available')
            end
        else
            debugLog('  [AOE-VFX] Static record not found for: ' .. tostring(areaStaticId))
        end
    end

    if explosionSound then
        -- Find the nearest actor to the detonation point for accurate 3D audio panning
        local nearestAnchor = nil
        local minDist = math.huge
        for _, actor in ipairs(world.activeActors) do
            if actor:isValid() then
                local dist = (actor.position - pos):length()
                if dist < minDist then
                    minDist = dist
                    nearestAnchor = actor
                end
            end
        end
        
        local anchor = nearestAnchor or caster or world.players[1]
        if anchor and anchor:isValid() then
            if anchor.type == types.NPC or anchor.type == types.Creature or anchor.type == types.Player then
                anchor:sendEvent('PlaySound3d', { sound = explosionSound })
            else
                core.sound.playSound3d(explosionSound, anchor, { volume = 1.0 })
            end
        end
    end

    -- Apply effects to all actors in range (DIRECTLY from Global)
    local affectedCount = 0
    for _, actor in ipairs(world.activeActors) do
        -- excludeActor is now a hash table {[actor.id] = true} for multiple exclusions
        local isExcluded = type(excludeActor) == 'table' and excludeActor[actor.id]
                        or (excludeActor == actor) -- backwards compat with single object
        if not isExcluded and actor:isValid() then
            local dist = (actor.position - pos):length()
            if dist <= finalRadius then
                -- [GLOBAL-MAGIC] Apply the enchantment spell directly
                applyEnchantmentGlobal(enchantId, caster, actor, pos, true, sourceData)
                
                -- Still send a notification event for blood/reaction/UI, but damage is 0
                actor:sendEvent('ProjectilePhysics_ApplyDamage', {
                    damage = 0, 
                    hitPos = pos,
                    attacker = caster,
                    launcher = sourceData.launcher,
                    ammoRecordId = sourceData.ammoRecordId,
                    projectile = sourceData.ammoRecordId or sourceData.weaponRecordId,
                    chargeRatio = 1.0,
                    weaponRecordId = sourceData.weaponRecordId,
                    skipEnchants = true, -- Handled by global now
                    isAoe = true
                })
                affectedCount = affectedCount + 1
            end
        end
    end
    debugLog(string.format('[AOE-DETONATE] %s detonated. Final Radius: %.1f. Affected: %d', enchantId, finalRadius, affectedCount))
end

-- [UTILITIES MOVED TO TOP]
local function restoreRangedEnchantCharges(actor)
    if not actor then return end
    local aId = actor.id
    local reg = virtualEnchantRegistry[aId]
    if not reg or not reg.items then
        virtualEnchantRegistry[aId] = nil
        return
    end

    local restored = 0
    for itemId, itemData in pairs(reg.items) do
        -- Find the actual item object in inventory if we can (though we store the ref, it might be stale)
        -- In OpenMW, we can often still use the reference if it hasn't been removed/respawned
        -- But first we check if we actually have the item object stored
        for _, item in ipairs(types.Actor.inventory(actor):getAll()) do
            if item.id == itemId then
                local data = types.Item.itemData(item)
                if data then
                    data.enchantmentCharge = itemData.virtualCharge
                    restored = restored + 1
                    debugLog(string.format('[RANGED-CONV] Restored %d to %s on %s', itemData.virtualCharge, itemData.recordId, tostring(aId)))
                end
                break
            end
        end
    end
    virtualEnchantRegistry[aId] = nil
end

local function enforceRangedEnchantDrain(actor)
    if not actor or not actor:isValid() then return end
    
    local settingOn = getSetting(settingsAdvanced, 'rangedOnUseToOnStrike', true)
    if not settingOn then
        if virtualEnchantRegistry[actor.id] then restoreRangedEnchantCharges(actor) end
        return
    end

    -- Skip dead actors or NPCs out of combat
    local hp = types.Actor.stats.dynamic.health(actor)
    local stance = types.Actor.getStance(actor)
    local isNpcOrCreature = (actor.type == types.NPC or actor.type == types.Creature)

    if (hp and hp.current <= 0) or (isNpcOrCreature and stance == 0) then
        if virtualEnchantRegistry[actor.id] then restoreRangedEnchantCharges(actor) end
        return
    end

    local id = actor.id
    local isPlayer = (actor.type == types.Player)
    
    -- [USER REQUEST] Player keeps charges visible/native.
    -- We only drain NPCs/Biped because engine handling of their items is different.
    if isPlayer then 
        if virtualEnchantRegistry[id] then restoreRangedEnchantCharges(actor) end
        return 
    end

    local inventory = types.Actor.inventory(actor)
    if not inventory then return end

    local reg = virtualEnchantRegistry[id]
    if not reg then
        reg = { items = {}, notifiedNoCharge = {} }
        virtualEnchantRegistry[id] = reg
    elseif not reg.items then
        -- Legacy data from older version of mod
        reg.items = {}
        reg.notifiedNoCharge = {}
    end

    local foundAnyOnUse = false
    local CAST_ON_USE = (core.magic and core.magic.ENCHANTMENT_TYPE) and core.magic.ENCHANTMENT_TYPE.CastOnUse or 2

    local equipment = types.Actor.getEquipment(actor)
    local item = equipment[types.Actor.EQUIPMENT_SLOT.CarriedRight]
    
    if item and item.type == types.Weapon then
        local rec = nil
        pcall(function() rec = types.Weapon.record(item) end)

        if rec and (rec.type == types.Weapon.TYPE.MarksmanBow or rec.type == types.Weapon.TYPE.MarksmanCrossbow) then
            if rec.enchant and rec.enchant ~= "" then
                local ench = fetchEnch(rec.enchant)
                if ench and ench.type == CAST_ON_USE then
                    foundAnyOnUse = true
                    local data = types.Item.itemData(item)
                    if data then
                        local current = data.enchantmentCharge or ench.charge or 0
                        local itemId = item.id
                        
                        if current > 0 then
                            local existing = reg.items[itemId]
                            if existing then
                                -- Item already tracked, just update its pool if charge somehow increased
                                existing.virtualCharge = math.min(existing.maxCharge, existing.virtualCharge + current)
                            else
                                -- New item to drain
                                reg.items[itemId] = {
                                    enchantId = rec.enchant,
                                    virtualCharge = current,
                                    costPerUse = getEffectiveCost(ench.cost or 1, actor),
                                    maxCharge = ench.charge or 1000,
                                    recordId = item.recordId
                                }
                                debugLog(string.format('[RANGED-CONV] Drained equipped %s (%s) on %s | charge=%d', item.recordId, itemId, tostring(id), current))
                                if actor.type == types.Player then
                                    actor:sendEvent('ProjectilePhysics_ShowMessage', { msg = string.format("%s charge converted to Strike Pool.", rec.name) })
                                end
                            end
                            data.enchantmentCharge = 0
                        end
                    end
                end
            end
        end
    end

    -- Clean up untracked items if no longer in inventory or relevant?
    -- Actually, keep them as long as we have virtual charge to restore later.
    
    local hasAnyCharge = false
    if reg.items then
        for _, itemData in pairs(reg.items) do
            if itemData.virtualCharge > 0 then hasAnyCharge = true break end
        end
    end

    if not foundAnyOnUse and not hasAnyCharge then
        virtualEnchantRegistry[id] = nil
    end
end
-- ACTIVATOR-BASED STUCK PROJECTILE SYSTEM
local stuckActivatorCache = {} 
local stuckProjectileRegistry = {} 
local processedDeaths = {} 

-- VFX-INVENTORY SYNC SYSTEM
local actorVfxRegistry = {} 
local actorAmmoCounts = {} 
local lastPollTime = 0 

-- FOLLOWER TRAIL SYSTEM
local activeFollowers = {} -- { [projId] = followerObj }
local fadingFollowers = {} -- { [uniqueId key] = followerObj }
        local ARROW_SCALE = 0.53
local ARROW_OFFSET = 8.0

local UNIT_Y = util.vector3(0, 1, 0)
local MODEL_FORWARD = util.vector3(0, 1, 0)
local MODEL_UP = util.vector3(0, 0, 1)

-- WABA v5 Constants
local WABA_LIMIT = math.rad(90) -- 10% of 90 degrees
local WABA_RAMP_DURATION = 2.1 -- Time to reach 100% trajectory influence

local function reject(v, onto)
    if onto:length() < 1e-6 then return v end
    local ontoN = onto:normalize()
    return v - ontoN * v:dot(ontoN)
end

local function rotBetween(a, b)
    local an = a:normalize()
    local bn = b:normalize()
    local dot = an:dot(bn)
    if dot > 0.999999 then return util.transform.identity end
    if dot < -0.999999 then
        local axis = util.vector3(1, 0, 0):cross(an)
        if axis:length() < 1e-6 then axis = util.vector3(0, 1, 0):cross(an) end
        return util.transform.rotate(math.pi, axis:normalize())
    end
    local axis = an:cross(bn):normalize()
    return util.transform.rotate(math.acos(dot), axis)
end

local function getGlobalWabaRotation(projectile, data, currentPos, velocity, isTrail)
    if not velocity or velocity:length() < 10 then return nil end
    
    local flightTime = data.launchSimulationTime and (core.getSimulationTime() - data.launchSimulationTime) or 0
    
    -- WABA v10: Ballistic Trail Synthesis
    -- 1. BASE TRAJECTORY (Physical Direction)
    local useFwd = (flightTime < 0.1) and data.direction or velocity:normalize()
    local yaw = math.atan2(useFwd.x, useFwd.y)
    local trajPitch = math.asin(useFwd.z) 

    if isTrail then
        -- TRAILS ARE PHYSICS-PURE:
        -- They must follow the ballistic arc exactly to look "natural".
        local cosTP = math.cos(trajPitch)
        local trailDir = util.vector3(math.sin(yaw) * cosTP, math.cos(yaw) * cosTP, math.sin(trajPitch))
        local rT = rotBetween(MODEL_FORWARD, trailDir)
        -- Roll Stability (Same as projectile)
        local upT = rT:apply(MODEL_UP)
        local uppT = reject(util.vector3(0, 0, 1), trailDir)
        if upT:length() > 1e-6 and uppT:length() > 1e-6 then
             rT = util.transform.rotate(math.atan2((upT:cross(uppT:normalize())):dot(trailDir), upT:dot(uppT:normalize())), trailDir) * rT
        end
        if data.type == 'thrown' then rT = rT * util.transform.rotateZ(math.pi) end
        return rT
    end

    -- 2. STEEPNESS FADE-OUT (Pole Protection)
    local cosP = math.cos(trajPitch)
    local steepnessFactor = cosP * cosP * cosP * cosP 
    local blendFactor = math.min(1.0, flightTime * (1.0 / WABA_RAMP_DURATION)) * steepnessFactor
    
    -- 3. MOMENTUM-SENSITIVE DIVE BIAS
    local momentumFactor = math.max(0, math.cos(trajPitch)) 
    local zFactor = math.abs(currentPos.z) / 1000
    local diveBias = -0.1 * (1 + zFactor) * momentumFactor
    
    -- 4. AUTONOMOUS TARGET (10% Mirroring + Bias)
    local rawTarget = (trajPitch * 0.1) + diveBias
    local targetPitch = math.max(-WABA_LIMIT, math.min(WABA_LIMIT, rawTarget))
    
    -- 5. NON-LIFTING GUARD (For downward shots)
    if trajPitch < -WABA_LIMIT then
        targetPitch = math.min(targetPitch, trajPitch) 
    end
    
    -- 6. DYNAMIC BLEND
    local visualPitch = trajPitch * (1.0 - blendFactor) + (targetPitch * blendFactor)
    
    -- Construct Visual Direction Vector
    local cosVP = math.cos(visualPitch)
    local visualDir = util.vector3(
        math.sin(yaw) * cosVP,
        math.cos(yaw) * cosVP,
        math.sin(visualPitch)
    )
    
    -- Construct Matrix
    local r1 = rotBetween(MODEL_FORWARD, visualDir)
    
    -- Roll Stability
    local up1 = r1:apply(MODEL_UP)
    local worldUp = util.vector3(0, 0, 1)
    local up1p = reject(up1, visualDir)
    local upp = reject(worldUp, visualDir)
    if up1p:length() > 1e-6 and upp:length() > 1e-6 then
        local u1n = up1p:normalize()
        local uwn = upp:normalize()
        local sinTerm = (u1n:cross(uwn)):dot(visualDir)
        local cosTerm = u1n:dot(uwn)
        r1 = util.transform.rotate(math.atan2(sinTerm, cosTerm), visualDir) * r1
    end
    
    if data.type == 'thrown' then
        r1 = r1 * util.transform.rotateZ(math.pi)
    end
    
    return r1
end

local function removeFollowerById(projId)
    local follower = activeFollowers[projId]
    if follower and follower:isValid() then
        pcall(function() follower:remove() end)
    end
    activeFollowers[projId] = nil
end

-- [REPLACED BY TOP-LEVEL DEFINITION]

-- ============================================================================
-- MODEL CLONING (Mesh Banning Bypass)
-- ============================================================================
local function getClonedModelPath(modelPath)
    if not modelPath then return nil end
    -- If already cloned, don't double-replace
    if modelPath:find("meshes/luameshes/") then return modelPath end
    
    -- Robust replacement
    local cloned = modelPath:gsub("^[mM][eE][sS][hH][eE][sS][/\\]", "meshes/luameshes/")
    
    -- If no "meshes/" prefix was found, it might be a raw path
    if cloned == modelPath then
        cloned = "meshes/luameshes/" .. modelPath:gsub("^[/\\]", "")
    end
    
    -- Ensure formatting is clean
    cloned = cloned:gsub("//", "/")
    
    return cloned
end

-- ============================================================================
-- FOLLOWER ITEM LOGIC (VFX Trails) - [NEW SECTION]
-- ============================================================================

-- [TASK 1] Trail record pre-registration
-- world.createObject() requires the record to be known to the engine.
-- We register each trail ID as an Activator record pointing to the .nif at load time.
local trailRecordCache = {}        -- { [recordId] = true } once registered
local trailRecordsInitialized = false

local TRAIL_RECORD_MODELS = {
    ['vfx_arrow_trail_5']   = 'meshes/g7/t/vfx_arrow_trail_5.nif',
    ['vfx_arrow_trail_21']  = 'meshes/g7/t/vfx_arrow_trail_21.nif',
    ['vfx_arrow_trail_37']  = 'meshes/g7/t/vfx_arrow_trail_37.nif',
    ['vfx_arrow_trail_38']  = 'meshes/g7/t/vfx_arrow_trail_38.nif',
    ['vfx_arrow_trail_54']  = 'meshes/g7/t/vfx_arrow_trail_54.nif',
    ['vfx_arrow_trail_70']  = 'meshes/g7/t/vfx_arrow_trail_70.nif',
    ['vfx_arrow_trail_86']  = 'meshes/g7/t/vfx_arrow_trail_86.nif',
    ['vfx_arrow_trail_87']  = 'meshes/g7/t/vfx_arrow_trail_87.nif',
    ['vfx_arrow_trail_103'] = 'meshes/g7/t/vfx_arrow_trail_103.nif',
    ['vfx_arrow_trail_119'] = 'meshes/g7/t/vfx_arrow_trail_119.nif',
    ['vfx_arrow_trail_120'] = 'meshes/g7/t/vfx_arrow_trail_120.nif',
    ['vfx_arrow_trail_135'] = 'meshes/g7/t/vfx_arrow_trail_135.nif',
    ['vfx_arrow_trail_136'] = 'meshes/g7/t/vfx_arrow_trail_136.nif',
    ['vfx_arrow_trail_152'] = 'meshes/g7/t/vfx_arrow_trail_152.nif',
    ['vfx_arrow_trail_168'] = 'meshes/g7/t/vfx_arrow_trail_168.nif',
    ['vfx_arrow_trail_169'] = 'meshes/g7/t/vfx_arrow_trail_169.nif',
    ['vfx_arrow_trail_185'] = 'meshes/g7/t/vfx_arrow_trail_185.nif',
    ['vfx_arrow_trail_201'] = 'meshes/g7/t/vfx_arrow_trail_201.nif',
    ['vfx_arrow_trail_217'] = 'meshes/g7/t/vfx_arrow_trail_217.nif',
    ['vfx_arrow_trail_218'] = 'meshes/g7/t/vfx_arrow_trail_218.nif',
    ['vfx_arrow_trail_234'] = 'meshes/g7/t/vfx_arrow_trail_234.nif',
    ['vfx_arrow_trail_250'] = 'meshes/g7/t/vfx_arrow_trail_250.nif',
}

local function ensureTrailRecords()
    if trailRecordsInitialized then return end
    trailRecordsInitialized = true

    if not types.Activator or not types.Activator.createRecordDraft then
        debugLog('[TRAIL] createRecordDraft not available — skipping trail pre-registration')
        return
    end

    local registered = 0
    for recordId, modelPath in pairs(TRAIL_RECORD_MODELS) do
        if not trailRecordCache[recordId] then
            -- Check if already registered (e.g. from a previous session)
            local existing = nil
            pcall(function() existing = types.Activator.record(recordId) end)
            if existing then
                trailRecordCache[recordId] = true
            else
                local ok, err = pcall(function()
                    local draft = types.Activator.createRecordDraft({
                        id    = recordId,
                        model = modelPath,
                        name  = 'Arrow Trail',
                        scripts = {'scripts/ProjectilePhysics/Activator.lua'}
                    })
                    world.createRecord(draft)
                    trailRecordCache[recordId] = true
                    registered = registered + 1
                end)
                if not ok then
                    debugLog('[TRAIL] Failed to register ' .. recordId .. ': ' .. tostring(err))
                end
            end
        end
    end
    debugLog('[TRAIL] Trail records initialized (' .. registered .. ' newly registered)')
end

local function spawnFollower(data)
    -- data: { projectile, recordId, startPos, startRot }
    if not data.projectile or not data.recordId then return end
    
    local pid = data.projectile.id

    -- [FIX] Only block duplicate spawns if the ACTIVE (non-fading) follower exists
    if activeFollowers[pid] then return end

    -- [TASK 1] Ensure trail records are registered before first spawn
    ensureTrailRecords()

    local ok, follower = pcall(function()
        return world.createObject(data.recordId)
    end)

    if ok and follower then
        follower:teleport(data.projectile.cell, data.startPos, data.startRot)
        activeFollowers[pid] = follower
        
        -- Send the follower object back to local script so it can ignore collision
        if data.projectile and data.projectile:isValid() then
            data.projectile:sendEvent('ProjectilePhysics_FollowerSpawned', {
                follower = follower
            })
        end
     else
        debugLog('Failed to spawn follower: ' .. tostring(data.recordId) .. ". Check if Record ID is valid!")
    end
end

local function updateFollower(data)
    -- data: { projectile, position, rotation }
    if not data.projectile then return end
    
    local pid = data.projectile.id
    local follower = activeFollowers[pid]
    
    -- [REVISION 37] Follow while Fading
    -- If not in active (it's already fading), check the fading registry
    if not follower then
        local prefix = tostring(pid) .. '_'
        for key, f in pairs(fadingFollowers) do
            if key:sub(1, #prefix) == prefix then
                follower = f
                break
            end
        end
    end
    
    if follower and follower:isValid() then
        -- Wrap teleport in pcall to prevent crashes if the object is busy
        pcall(function()
            follower:teleport(data.projectile.cell, data.position, data.rotation)
        end)
    else
        -- Cleanup if follower became invalid
        if activeFollowers[pid] == follower then
            activeFollowers[pid] = nil
        end
    end
end

local function removeFollower(data)
    -- data: { projectile }
    if not data.projectile then return end
    removeFollowerById(data.projectile.id)
end

local function fadeFollower(data)
    -- data: { projectile, duration }
    if not data.projectile then return end
    
    local pid = data.projectile.id
    local follower = activeFollowers[pid]
    
    if follower and follower:isValid() then
        -- Move to fading registry to prevent further updates
        local key = tostring(pid) .. '_' .. tostring(core.getRealTime())
        fadingFollowers[key] = follower
        activeFollowers[pid] = nil
        
        -- 1. Tell Follower Activator directly to play fade-out animation
        -- Sending to the projectile's local script fails if the projectile was just killed or tp'd away.
        follower:sendEvent("PlayAnimation", {
            groupName = "Idle2",
            options = { autoDisable = false },
        })
        
        -- 2. Schedule removal after specific duration (increased to 1.2s for smoothness)
        local duration = data.duration or 1.2
        async:newUnsavableSimulationTimer(duration, function()
            if follower and follower:isValid() then
                follower:remove()
            end
            fadingFollowers[key] = nil
        end)
    end
end

-- [Legacy ring buffer code removed]
-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

local function checkBypass(weaponId, ammoId)
    local isBypass = false
    local function isSpecial(id)
        if not id then return false end
        local rec = nil
        pcall(function() rec = types.Ammunition.records[id] or types.Weapon.records[id] end)
        if not rec then return false end

        local idL = tostring(rec.id):lower()
        local nameL = rec.name:lower()
        
        if rec.enchant and rec.enchant ~= "" then return true end
        if idL:find("silver") or nameL:find("silver") then return true end
        if idL:find("daedric") or nameL:find("daedric") then return true end
        if rec.isMagical or rec.magical or (rec.flags and (rec.flags % 2 == 1)) then return true end
        return false
    end

    local weaponRec = nil
    pcall(function() weaponRec = types.Weapon.records[weaponId] end)
    local isLauncher = weaponRec and (weaponRec.type == types.Weapon.TYPE.MarksmanBow or weaponRec.type == types.Weapon.TYPE.MarksmanCrossbow)
    
    if isLauncher then isBypass = isSpecial(ammoId)
    else isBypass = isSpecial(weaponId) end
    
    if isBypass then debugLog(string.format("[BYPASS-CHECK] Bypass detected: Weapon=%s, Ammo=%s", tostring(weaponId), tostring(ammoId))) end
    return isBypass
end

local actorAmmoCounts = {}

local function applyLauncherDurability(launcher, damage, isActorHit)
    if not launcher or not launcher:isValid() then return end
    local record = types.Weapon.record(launcher)
    if not record then return end
    if record.type ~= types.Weapon.TYPE.MarksmanBow and record.type ~= types.Weapon.TYPE.MarksmanCrossbow then return end

    local loss = 1
    if isActorHit then
        local fWeaponDamageMult = core.getGMST('fWeaponDamageMult') or 0.1
        loss = math.max(1, math.floor(damage * fWeaponDamageMult))
    end
    
    local itemData = types.Item.itemData(launcher)
    if not itemData then return end
    if itemData.condition > 0 then
        itemData.condition = math.max(0, itemData.condition - loss)
    end
end

local function getSkillModifiedActor(actor, skillId)
    if not actor or not actor:isValid() then return 0 end
    if actor.type == types.Player then
        local fn = types.Player.stats.skills and types.Player.stats.skills[skillId]
        return fn and fn(actor).modified or 0
    end
    if actor.type == types.NPC then
        local fn = types.NPC.stats.skills and types.NPC.stats.skills[skillId]
        return fn and fn(actor).modified or 0
    end
    if actor.type == types.Creature then
        -- [REFINEMENT] Fallback logic for creatures
        -- Most creatures don't have skills, so we scale with level and agility
        local level = types.Actor.stats.level(actor).current
        local agi = types.Actor.stats.attributes.agility(actor).modified
        return 20 + (level * 0.5) + (agi / 10)
    end
    return 30
end

local function getVectorRotation(dir, currentZ, startZ)
    if not dir or dir:length() < 0.001 then return util.transform.identity end
    local fwd = dir:normalize()
    local yaw = math.atan2(fwd.x, fwd.y)
    local pitch = math.asin(fwd.z)

    -- [USER REQUEST] Standardized Pitch
    -- Use the raw trajectory pitch directly. The local script handles visual WABA scaling/biasing.
    local usePitch = pitch
    
    return util.transform.rotateZ(yaw) * util.transform.rotateX(usePitch)
end

local function hashString(str)
    local hash = 5381
    for i = 1, #str do hash = ((hash * 33) + string.byte(str, i)) % 4294967296 end
    return string.format("%08x", hash)
end

local function getOrCreateStuckActivatorRecord(modelPath, useLPPPath, asActivator, ammoRecordId)
    if useLPPPath == nil then useLPPPath = true end
    local stuckModel = modelPath
    if asActivator then stuckModel = modelPath:gsub("^LPP/", "")
    elseif useLPPPath then stuckModel = modelPath:gsub("^[mM][eE][sS][hH][eE][sS][/\\]", "meshes/luameshes/") end
    
    local uniqueId = 'pp_act_' .. hashString(stuckModel)
    if ammoRecordId then uniqueId = uniqueId .. '_' .. ammoRecordId end
    
    if stuckActivatorCache[uniqueId] then return stuckActivatorCache[uniqueId] end
    if types.Activator.record then
        local found = nil
        pcall(function() found = types.Activator.record(uniqueId) end)
        if found then stuckActivatorCache[uniqueId] = uniqueId; return uniqueId end
    end
    if not types.Activator or not types.Activator.createRecordDraft then return nil end
    
    local finalId = nil
    local ok, _ = pcall(function()
        local draft = types.Activator.createRecordDraft({ id = uniqueId, model = stuckModel, name = 'Recoverable Projectile' })
        local newRec = world.createRecord(draft)
        finalId = newRec.id
    end)
    if ok and finalId then stuckActivatorCache[uniqueId] = finalId; return finalId end
    return nil
end

local function getUniqueVfxHandle(prefix)
    return prefix .. '_' .. tostring(math.floor(core.getRealTime() * 100)) .. '_' .. tostring(math.random(1000))
end

local function removeStuckProjectile(activatorId)
    local data = stuckProjectileRegistry[activatorId]
    if not data then return end
    
    -- Cleanup actorVfxRegistry if applicable
    if data.target and data.target:isValid() and data.ammoRecordId then
        local actorId = data.target.id
        local recId = data.ammoRecordId:lower()
        if actorVfxRegistry[actorId] and actorVfxRegistry[actorId][recId] then
            local list = actorVfxRegistry[actorId][recId]
            for i = #list, 1, -1 do
                if list[i] == activatorId then
                    table.remove(list, i)
                end
            end
        end
    end

    if data.type == 'vfx' then
        if data.target and data.target:isValid() then
            -- [BYPASS GUARD] Pass explicit flag so the actor script knows this is an intentional, authorized removal
            data.target:sendEvent('ProjectilePhysics_RemoveVfx', { vfxId = activatorId, isGlobalCleanup = true })
        end
    else
        if data.activator and data.activator:isValid() then
            if data.activator.cell then 
                if data.type == 'item' then
                    -- [AnimatedPickup Compatibility]
                    local itemToKill = data.activator
                    async:newUnsavableSimulationTimer(0.1, function()
                        if itemToKill and itemToKill:isValid() then
                            pcall(function() itemToKill:remove() end)
                        end
                    end)
                else
                    pcall(function() data.activator:remove() end) 
                end
            end
        end
    end
    
    -- [USER REQUEST] SYNC INVENTORY ON REMOVAL
    -- If this was a synced projectile (Live Sync), ensure its item is removed from inventory when the visual is gone.
    -- This prevents arrows "reappearing" in loot if they time out or break.
    if data.syncedToInventory and data.target and data.target:isValid() and data.ammoRecordId then
        local pMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory')
        if pMode == 'activation' or pMode == 'mass_harvest' then
            local inv = types.Actor.inventory(data.target)
            local item = inv:find(data.ammoRecordId)
            if item then
                item:remove(1)
                debugLog(string.format('  [SYNC-CLEANUP] Removed 1x %s from %s (Projectile gone)', data.ammoRecordId, data.target.recordId))
            end
        end
    end
    
    stuckProjectileRegistry[activatorId] = nil
end

local function calculateMarksmanHitChance(attacker, defender)
    -- Simplified calculation
    local marksman = getSkillModifiedActor(attacker, 'marksman')
    local agi = types.Actor.stats.attributes.agility(attacker).modified
    local luck = types.Actor.stats.attributes.luck(attacker).modified
    local hitRate = marksman + agi / 5 + luck / 10
    
    local dAgility = types.Actor.stats.attributes.agility(defender).modified
    local dLuck = types.Actor.stats.attributes.luck(defender).modified
    local evasion = dAgility / 5 + dLuck / 10
    
    return hitRate - evasion
end

-- ============================================================================
-- PROJECTILE PLACEMENT
-- ============================================================================
local physicsAvailable = false
local D = nil
pcall(function() 
    local pd = require('scripts/MaxYari/LuaPhysics/scripts/physics_defs')
    if pd then D = pd; physicsAvailable = true end
end)

local function onPlaceProjectile(data)
    debugLog('========== PLACEMENT REQUEST: ' .. data.projectileType .. ' ==========')

    async:newUnsavableSimulationTimer(data.flightTime or 0, function()
        if not data.attacker or not data.attacker:isValid() then return end
        
        local projectile = nil
        local ok, _ = pcall(function() projectile = world.createObject(data.recordId, 1) end)
        if not ok or not projectile then return end

        -- Consume Ammo AFTER creating the projectile object (so the record stays valid)
        if data.consumeRecord and data.attacker and data.attacker:isValid() then
            pcall(function()
                local inv = types.Actor.inventory(data.attacker)
                local item = inv:find(data.consumeRecord)
                if item then item:remove(1) end
            end)
        end

        local incomingDir = data.direction:normalize()
        local speed = data.speed or 7000
        local spawnPos
        local finalImpulse
        
        -- Spawn Position Logic
        if data.spawnAtLauncher then
             -- Dynamic Clear Distance: Base + (Velocity in direction of aim)
             -- This ensures the projectile "ejects" cleanly even if the launcher is running forward.
             local baseClear = 100
             local actorVel = data.attackerVelocity or util.vector3(0,0,0)
             local fwdSpeed = math.max(0, actorVel:dot(incomingDir))
             local clearDist = baseClear + (fwdSpeed * 20) -- Add margin based on fwd speed
             
             spawnPos = data.startPos + (incomingDir * clearDist) 
             finalImpulse = incomingDir * speed
        elseif data.isMiss then
             local startPos = data.startPos or (data.attacker.position + util.vector3(0,0,130))
             spawnPos = startPos + (incomingDir * 200)
             finalImpulse = incomingDir * speed
        elseif data.isDirectHit then
             spawnPos = data.position - (incomingDir * 10)
             finalImpulse = incomingDir * speed
        elseif data.projectileType == 'arrow' then
             local distToTarget = (data.position - data.startPos):length()
             spawnPos = data.position - (incomingDir * math.min(100, distToTarget * 0.3))
             finalImpulse = incomingDir * speed
        else
             spawnPos = data.position - (incomingDir * 10)
             finalImpulse = incomingDir * speed
        end
        
        -- REGISTER PROJECTILE (Do this BEFORE rotation calculation)
        local initialBounce = (not data.isMiss and not data.isDirectHit)
        if data.spawnAtLauncher then initialBounce = false end

        local projData = {
            projectile = projectile,
            type = data.projectileType,
            spawnTime = core.getRealTime(),
            launchSimulationTime = core.getSimulationTime(),
            attacker = data.attacker,
            direction = incomingDir,
            damage = data.damage or 10,
            hasBounced = initialBounce,
            launcher = data.launcher,
            originalItem = data.projectile,
            ammoRecordId = data.recordId,
            weaponRecordId = data.weaponRecordId,
            chargeRatio = data.chargeRatio or 1.0,
            durabilityApplied = false,
            bypassesNormalResistance = checkBypass(data.weaponRecordId, data.recordId),
            startPos = spawnPos,
            startZ = spawnPos.z
        }
        placedProjectiles[projectile.id] = projData

        -- Authoritative Rotation: Use WABA v7 logic immediately to prevent flicker
        -- Note: At flightTime=0, this returns the trajectory-aligned rotation.
        local finalRotation = getGlobalWabaRotation(projectile, projData, spawnPos, finalImpulse)
        if not finalRotation then
            -- Extreme fallback using standard axis orientation
            finalRotation = util.transform.rotateZ(math.atan2(incomingDir.x, incomingDir.y)) * util.transform.rotateX(math.asin(incomingDir.z))
            if data.projectileType == 'thrown' then finalRotation = finalRotation * util.transform.rotateZ(math.pi) end
        end

        -- [FIX] Standardize on 3-argument teleport (cell, pos, rotation) 
        projectile:teleport(data.attacker.cell, spawnPos, finalRotation)
        
        -- SETUP PHYSICS
        if physicsAvailable and D then
            local radius = 6.0
            
            -- [USER REQUEST] Custom gravity per projectile type
            local gravMult = 1.0
            local pType = data.projectileType
            if pType == 'arrow' then gravMult = getSetting(settingsGravity, 'arrowGravity', 1.0)
            elseif pType == 'bolt' then gravMult = getSetting(settingsGravity, 'boltGravity', 1.0)
            elseif pType == 'thrown' then gravMult = getSetting(settingsGravity, 'thrownGravity', 1.0) end
            
            -- Standard 9.8m/s down converted to Game Units (72 units per meter)
            local customGravity = util.vector3(0, 0, -9.8 * 72.0 * gravMult)

            projectile:sendEvent(D.e.WhatIsMyPhysicsData, { object = projectile })
            projectile:sendEvent(D.e.SetPhysicsProperties, {
                drag = 0.02, bounce = 0.034, angularDrag = 50.0, weight = (data.weight or 0.5), 
                useInternalCollision = true, culprit = data.attacker, isSleeping = false, 
                collisionMode = 'sphere', radius = radius,
                lockRotation = true,
                gravity = customGravity
            })
            projectile:sendEvent(D.e.ApplyImpulse, { impulse = finalImpulse, culprit = data.attacker })
        end

        -- SEND DATA TO LOCAL SCRIPT
        projectile:sendEvent('ProjectilePhysics_SetData', {
            attacker = data.attacker,
            projectileType = data.projectileType,
            launcher = data.launcher,
            damage = data.damage or 10,
            chargeRatio = data.chargeRatio or 1.0,
            launchTime = core.getSimulationTime(),
            startDir = incomingDir, 
            bypassesNormalResistance = checkBypass(data.weaponRecordId, data.recordId),
            weaponRecordId = data.weaponRecordId,
            ammoRecordId = data.recordId,
            startPos = spawnPos, 
            vfxSpeed = speed, 
            vfxRecordId = nil, 
            vfxOffset = 0.0
        })
    end)
end



-- Cleanup old projectiles
local function cleanupOldProjectiles()
    local lifetime = getSetting(settingsGeneral, 'projectileLifetime', 99990)
    local now = core.getRealTime()
    
    for id, data in pairs(placedProjectiles) do
        local age = now - data.spawnTime
        
        if age > lifetime then
            debugLog('Removing old projectile: ' .. id)
            
            -- [[ ADD THIS BLOCK ]] --
            if activeFollowers[id] and activeFollowers[id]:isValid() then
                activeFollowers[id]:remove()
                activeFollowers[id] = nil
            end
            -- [[ END BLOCK ]] --

            if data.projectile and data.projectile.count and data.projectile.count > 0 then
                data.projectile:remove()
            end
            
            placedProjectiles[id] = nil
        end
    end
end

-- Main update loop
-- [CONSOLIDATED Master Update Logic]
local function onNpcDeath(actor, attacker)
    if not actor or not actor:isValid() then return end
    debugLog('[NPC-DEATH] Triggering conversion for ' .. (actor.recordId or "Actor"))
    
    local pickupMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory')
    
    if pickupMode == 'inventory' then
        -- Ensure all stuck projectiles are in the inventory so they can be looted
        local inv = types.Actor.inventory(actor)
        if inv then
            for objId, sData in pairs(stuckProjectileRegistry) do
                if sData.target == actor and sData.ammoRecordId and not sData.syncedToInventory then
                    local ok, err = pcall(function()
                        -- Double-check current count to avoid duplicates
                        local currentCount = 0
                        local ok, allItems = pcall(function() return inv:getAll() end)
                        if ok and allItems then
                            local targetRid = sData.ammoRecordId:lower()
                            for _, it in ipairs(allItems) do
                                if it.recordId:lower() == targetRid then
                                    currentCount = currentCount + it.count
                                end
                            end
                        end
                        
                        -- Add only if not already there (safety)
                        local newItem = world.createObject(sData.ammoRecordId, 1)
                        if newItem then
                            newItem:moveInto(inv)
                            sData.syncedToInventory = true
                            debugLog('  [DEATH-SYNC] Added missing ' .. sData.ammoRecordId .. ' to ' .. actor.id)
                            
                            -- Update cache immediately to prevent fake consumption pulse
                            if not actorAmmoCounts[actor.id] then actorAmmoCounts[actor.id] = {} end
                            actorAmmoCounts[actor.id][sData.ammoRecordId:lower()] = currentCount + 1
                        end
                    end)
                end
            end
        end
    elseif pickupMode == 'activation' then
        -- Request the Actor script to convert its current VFXes to static activators
        actor:sendEvent('ProjectilePhysics_TriggerConversion', { attacker = attacker })
        -- Proactively strip inventory items that correspond to VFX
        core.sendGlobalEvent('ProjectilePhysics_StripInventoryOnDeath', {actor = actor})
    elseif pickupMode == 'mass_harvest' then
        -- [mass_harvest] ONLY strip inventory items, DO NOT trigger conversion (VFX stay on body)
        core.sendGlobalEvent('ProjectilePhysics_StripInventoryOnDeath', {actor = actor})
    end
end

local function masterUpdate(dt)
    local now = core.getRealTime()

    -- 1. MUTUAL RANGED ENCHANTMENT DRAIN (THROTTLED 0.5s)
    if (now - lastEnchantDrainPoll) > 0.5 then
        lastEnchantDrainPoll = now
        for _, actor in ipairs(world.activeActors) do
            if actor:isValid() then
                enforceRangedEnchantDrain(actor)
            end
        end
    end

    -- 2. HARVESTING STAGGERED BATCHES
    if now >= nextProcessTime and #staggeredBatches > 0 then
        local batch = staggeredBatches[1]
        local target = batch.target
        local player = batch.player
        
        if not target or not target:isValid() or not player or not player:isValid() then
            table.remove(staggeredBatches, 1)
        else
            if batch.mode == 'precision' then
                local items = batch.items
                local index = batch.currentIndex
                local itemData = items[index]
                local ok, err = pcall(function()
                    local newItem = world.createObject(itemData.ammoRecordId, 1)
                    if newItem then
                        local finalPos
                        if itemData.positionIsWorldFinal then
                            finalPos = itemData.pos
                        else
                            local OFFSETS = { arrow = { offset = 8.0, scale = 0.53 }, bolt = { offset = 4.0, scale = 1.1 }, thrown = { offset = 4.0, scale = 1.0 } }
                            local pType = itemData.projectileType or 'arrow'
                            local profile = OFFSETS[pType] or OFFSETS.arrow
                            local offsetVec = util.vector3(0, -profile.offset, 0)
                            finalPos = itemData.pos + (itemData.rot * offsetVec)
                        end
                        -- [USER REQUEST] Ensure harvested items spawn near the ground (z=10 relative to actor)
                        -- Prevents them from floating at eye level before being added to inventory.
                        finalPos = util.vector3(finalPos.x, finalPos.y, target.position.z - 30)
                        
                        newItem:teleport(target.cell, finalPos, { rotation = itemData.rot })
                        newItem:setScale((itemData.projectileType == 'bolt' and 1.1) or (itemData.projectileType == 'thrown' and 1.0) or 0.53)
                        newItem:activateBy(player)
                        batch.recoveredCount = (batch.recoveredCount or 0) + 1
                    end
                    removeStuckProjectile(itemData.vfxId)
                end)
                batch.currentIndex = index + 1
                if batch.currentIndex > #items then
                    if batch.recoveredCount and batch.recoveredCount > 0 then
                        player:sendEvent('ProjectilePhysics_ShowMessage', { msg = string.format("Harvested %d projectiles.", batch.recoveredCount) })
                    end
                    table.remove(staggeredBatches, 1)
                end
            elseif batch.mode == 'normal' then
                local toHarvest = batch.toHarvest
                local index = batch.currentIndex
                local objId = toHarvest[index]
                local sData = stuckProjectileRegistry[objId]
                if sData then
                    local ammoId = sData.ammoRecordId
                    if sData.isRecoverable and ammoId then
                        if math.random(100) <= batch.successChance then
                            local newItem = world.createObject(ammoId, 1)
                            if newItem then
                                local harvestPos = target.position
                                if sData.relativePos then harvestPos = target.position + (target.rotation * sData.relativePos) end
                                -- [USER REQUEST] Ensure harvested items spawn near the ground (z=10 relative to actor)
                                harvestPos = util.vector3(harvestPos.x, harvestPos.y, target.position.z - 30)
                                
                                newItem:teleport(target.cell, harvestPos)
                                newItem:activateBy(player)
                                batch.recoveredCounts[ammoId] = (batch.recoveredCounts[ammoId] or 0) + 1
                                batch.totalRecovered = (batch.totalRecovered or 0) + 1
                            end
                        end
                    end
                    removeStuckProjectile(objId)
                end
                batch.currentIndex = index + 1
                if batch.currentIndex > #toHarvest then
                    if batch.totalRecovered and batch.totalRecovered > 0 then
                        local msgs = {}
                        for aid, count in pairs(batch.recoveredCounts) do
                            local name = aid
                            pcall(function()
                                if aid and #aid > 1 then
                                    local rec = nil
                                    if types.Ammunition then pcall(function() rec = types.Ammunition.records[aid] end) end
                                    if not rec and types.Weapon then pcall(function() rec = types.Weapon.records[aid] end) end
                                    if rec then name = rec.name end
                                end
                            end)
                            -- [USER REQUEST] Adjust spawn height to z=10
                            local harvestPos = util.vector3(target.position.x, target.position.y, target.position.z + 10)
                            local player = batch.player
                            
                            local finalPos = (batch.mode == 'precision') and (batch.hitPos) or harvestPos
                            if batch.mode == 'precision' then 
                                finalPos = util.vector3(finalPos.x, finalPos.y, finalPos.z + 10) -- Also nudge precision
                            end
                            
                            local items = world.createObject(aid, count)
                            items:teleport(target.cell, finalPos)
                            items:moveInto(types.Actor.inventory(player))
                            table.insert(msgs, string.format("%dx %s", count, name))

                        end
                        player:sendEvent('ProjectilePhysics_ShowMessage', { msg = "Harvested: " .. table.concat(msgs, ", ") })
                    else
                        player:sendEvent('ProjectilePhysics_ShowMessage', { msg = "All projectiles broke." })
                    end
                    table.remove(staggeredBatches, 1)
                end
            end
            nextProcessTime = now + 0.01
        end
    end

    -- 3. PROJECTILE DYNAMICS & CLEANUP
    for id, data in pairs(placedProjectiles) do
        local isInvalid = not data.projectile or not data.projectile:isValid()
        if isInvalid then
            placedProjectiles[id] = nil
        end
    end

    -- 4. INVENTORY SYNC (0.15s POLLING)
    if (now - lastPollTime) > 0.15 then
        lastPollTime = now
        for _, actor in ipairs(world.activeActors) do
            if actor:isValid() then
                local aId = actor.id
                local vfxGroup = actorVfxRegistry[aId]
                if vfxGroup then
                    local inv = types.Actor.inventory(actor)
                    if inv then
                        if not actorAmmoCounts[aId] then actorAmmoCounts[aId] = {} end
                        local currentCounts = {}
                        local ok, allItems = pcall(function() return inv:getAll() end)
                        if ok and allItems then
                            for _, item in ipairs(allItems) do
                                local rid = item.recordId:lower()
                                if vfxGroup[rid] then currentCounts[rid] = (currentCounts[rid] or 0) + item.count end
                            end
                        end
                        for ammoId, vfxList in pairs(vfxGroup) do
                            local currentCount = currentCounts[ammoId] or 0
                            local lastCount = actorAmmoCounts[aId][ammoId] or currentCount
                            if currentCount < lastCount then
                                local consumed = lastCount - currentCount
                                local hp = types.Actor.stats.dynamic.health(actor)
                                local isDead = (hp and hp.current <= 0)
                                local pMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory')
                                
                                -- [FIX] If dead and in mass_harvest mode, do NOT remove VFX when inventory is stripped.
                                -- The user wants VFX to persist on the body for "Mass Scavenging".
                                if not (isDead and pMode == 'mass_harvest') then
                                    for i = 1, math.min(consumed, #vfxList) do
                                         local vfxId = vfxList[1]
                                         if vfxId then removeStuckProjectile(vfxId) end
                                    end
                                else
                                    debugLog('[SYNC-SKIP] Actor ' .. tostring(aId) .. ' is dead (mass_harvest). Preserving VFX despite inventory strip.')
                                end
                            end
                            actorAmmoCounts[aId][ammoId] = currentCount
                        end
                    end
                end
            end
        end
    end

    -- 5. BONE SYNC & DEATH PROCESSING
    for activatorId, data in pairs(stuckProjectileRegistry) do
        if not data.target or not data.target:isValid() then
            removeStuckProjectile(activatorId)
        else
            local health = types.Actor.stats.dynamic.health(data.target)
            if health and health.current <= 0 and not data.deathProcessed then
                data.deathProcessed = true
                if not processedDeaths[data.target.id] then
                    processedDeaths[data.target.id] = true
                    onNpcDeath(data.target, data.attacker)
                end
            end
            if (data.type == 'activator' or data.type == 'item') and data.activator and data.activator:isValid() then
                if (core.getRealTime() - data.spawnTime) >= 2.0 then
                    if (not data.activator.cell) or (not data.target.cell) or (data.activator.cell ~= data.target.cell) then
                        removeStuckProjectile(activatorId)
                    else
                        pcall(function() data.activator:teleport(data.target.cell, data.activator.position, { rotation = data.activator.rotation }) end)
                    end
                end
            end
        end
    end

    -- 6. PERIODIC TASKS
    if now - lastCleanupTime >= 1.0 then 
        for _, player in ipairs(world.players) do
            if types.Player.getCrimeLevel(player) == 0 then projectileBountyActive[player.id] = false end
        end
    end
    if now - lastCleanupTime >= 5.0 then
        cleanupOldProjectiles()
        lastCleanupTime = now
    end
end

debugLog('========================================')
debugLog('GLOBAL SCRIPT LOADED (ArrowStick approach)')
debugLog('Event handler: ProjectilePhysics_PlaceProjectile')
debugLog('========================================')

-- [REVISION 46] Restored Crime Logic Constants
local GUARD_CLASSES = {
    ['guard'] = true,
    ['imperial guard'] = true,
    ['ordinator'] = true,
    ['buoyant armiger'] = true,
    ['high ordinator'] = true,
    ['royal guard'] = true,
    ['nord_guard'] = true,
    ['ordinator_high_fane'] = true,
    ['ordinator_stationary'] = true,
    ['ordinator_wander'] = true,
    ['ordinator_office'] = true,
}


local function onReportAssault(data)
    local victim = data.victim
    local attacker = data.attacker
    if victim.type ~= types.NPC or attacker.type ~= types.Player then return end
    
    -- [USER REQUEST] Do not invoke bounty when hitting creatures
    --if victim.type ~= types.NPC then return end

    -- [FIX] Do not apply bounty or voice if victim is already dead
    local victimHp = types.Actor.stats.dynamic.health(victim)
    if victimHp and victimHp.current <= 0 then
        debugLog('REPORTING SKIPPED: Victim is dead.')
        return
    end

    -- [USER REQUEST] Do not add bounty or trigger alarm if victim has Fight > 70
    local isAggressive = false
    if victim.type == types.NPC or victim.type == types.Creature then
        local fightStat = types.Actor.stats.ai.fight(victim)
        if fightStat and fightStat.modified > 70 then
            isAggressive = true
            debugLog('  [ASSAULT] Victim is aggressive. Bounty/Murder-Report will be skipped, but combat-refresh/alarm will still trigger.')
        end
    end

    debugLog('REPORTING ASSAULT: Player hit ' .. tostring(victim.recordId or victim.id))

    -- 2. Trigger Alarm (Alert nearby Guards with LoS)
    local alarmRadius = 2000
    for _, actor in ipairs(world.activeActors) do
        if actor ~= attacker and actor ~= victim and actor.type == types.NPC then
            -- Only alert specific guard classes (requested by user)
            local npcRecord = types.NPC.record(actor)
            local npcClass = (npcRecord and npcRecord.class or ""):lower()
            
            -- [USER REMINDER] Pursue ONLY works for Guards.
            if GUARD_CLASSES[npcClass] then
                local dist = (actor.position - victim.position):length()
                if dist < alarmRadius then
                    -- Check Line of Sight
                    local hasLoS = true
                    if world.castRay then
                        local hit = world.castRay(actor.position + util.vector3(0,0,120), victim.position + util.vector3(0,0,120), {ignore = actor})
                        if hit.hitObject and hit.hitObject ~= victim then
                            hasLoS = false
                        end
                    else
                        -- Fallback: If no castRay, assume restricted LoS (e.g. only within 1000 units)
                        if dist > 1000 then hasLoS = false end
                    end
                    
                    if hasLoS then
                        debugLog('  Witness ' .. tostring(actor.recordId) .. ' (Class: ' .. npcClass .. ') alerted at distance ' .. math.floor(dist))
                        -- Start Pursue (ONLY FOR GUARDS)
                        actor:sendEvent('StartAIPackage', {
                            type = 'Pursue',
                            target = attacker
                        })
                    end
                end
            end
        end
    end

    -- 1. Apply Bounty (40 Gold) - Only if victim was NOT aggressive
    if not isAggressive then
        local now = core.getRealTime()
        local victimId = victim.id
        local lastAssault = lastAssaultBountyTime[victimId] or 0
        
        -- ONE-TIME BOUNTY LOGIC:
        -- Only apply if we haven't already flagged this player for a projectile assault
        -- Reset occurs when crime level drops to 0 (monitored in onUpdate)
        local attackerId = attacker.id
        if projectileBountyActive[attackerId] then
            debugLog('  Bounty skipped: Player already has an active projectile assault bounty.')
            -- We still trigger alarm/pursuit above, but no new gold added
        else
            local currentBounty = 0
            if types.Player.getCrimeLevel then
                currentBounty = types.Player.getCrimeLevel(attacker)
            end
            
            local newBounty = currentBounty + 40 -- Standard assault bounty
            if types.Player.setCrimeLevel then
                types.Player.setCrimeLevel(attacker, newBounty)
                debugLog('  Applied 40 Gold Bounty. Total: ' .. newBounty)
                projectileBountyActive[attackerId] = true
                lastAssaultBountyTime[victimId] = now
            end
        end
    end
end

local function handleMurderReport(data)
    local victim = data.victim
    local attacker = data.attacker
    if victim.type ~= types.NPC or attacker.type ~= types.Player then return end
    
    -- [USER REQUEST] Do not invoke bounty when hitting creatures
   -- if victim.type ~= types.NPC then return end
    
    -- [AUTHORITATIVE I.CRIMES CHECK] (0.49+)
    if I.Crimes and victim.type == types.NPC then
        local ok = pcall(function()
            I.Crimes.commitCrime(attacker, {
                type = I.Crimes.TYPE.Murder,
                victim = victim
            })
        end)
        if ok then
            debugLog("[PP-GLOBAL] Reported murder via I.Crimes")
            return
        end
    end

    -- [FALLBACK] Trigger Alarm (Alert nearby Guards with LoS)
    local alarmRadius = 3000
    for _, actor in ipairs(world.activeActors) do
        if actor ~= attacker and actor ~= victim and actor.type == types.NPC then
            local npcRecord = types.NPC.record(actor)
            local npcClass = (npcRecord and npcRecord.class or ""):lower()
            
            if GUARD_CLASSES[npcClass] then
                local dist = (actor.position - victim.position):length()
                if dist < alarmRadius then
                    actor:sendEvent('StartAIPackage', {
                        type = 'Pursue',
                        target = attacker
                    })
                end
            end
        end
    end

    -- [FALLBACK] Apply Manual Bounty (1000 Gold)
    if attacker and attacker.type == types.Player then
        if types.Player.setCrimeLevel then
            local current = types.Player.getCrimeLevel(attacker) or 0
            types.Player.setCrimeLevel(attacker, current + 1000)
        end
    end
end

-- Helper: Attempt to stick a projectile (visual only or physics) into a target
local function tryStickProjectile(data)
    local target = data.target
    local impactPos = data.hitPos
    local model = data.model
    local projectile = data.projectile
    local projectileId = data.projectileId
    
    -- [ROBUST REMOVAL] Kill the physical object immediately
    if projectile and projectile:isValid() then
        pcall(function() 
            -- Aggressive Hiding
            projectile:setScale(0.001)
            if projectile.cell then
                projectile:teleport(projectile.cell, util.vector3(0, 0, -10000))
            end
            projectile.velocity = util.vector3(0,0,0)
            projectile:remove() 
        end)
        debugLog('  [REMOVE] Removed flying projectile object.')
    end
    
    -- If we have an ID, clear from tracking
    if projectileId then
        placedProjectiles[projectileId] = nil
    else
        -- Fallback: If no ID provided (e.g. from DirectHit), try to find a projectile 
        -- near the hit point that belongs to the same attacker/target to clean it up.
        for pid, pdata in pairs(placedProjectiles) do
            if pdata.projectile and pdata.projectile:isValid() and pdata.attacker == data.attacker then
                local dist = (pdata.projectile.position - impactPos):length()
                if dist < 100 then
                    pcall(function() pdata.projectile:remove() end)
                    placedProjectiles[pid] = nil
                    debugLog('  [REMOVE-EXT] Cleaned up nearby untracked projectile ' .. pid)
                end
            end
        end
    end

    -- [USER REQUEST] Support Ground Impacts (nil target) for AoE triggers
    if not target and not impactPos then 
        debugLog('  [STICK-FAIL] No target or position.')
        return false 
    end
    if not model then 
        debugLog('  [STICK-FAIL] No model data provided.')
        return false 
    end

    local rotation = data.rotation or (projectile and projectile.rotation) or util.transform.identity
    local fwd = rotation * util.vector3(0,1,0)
    
    -- Check Sticking Enabled
    local enableSticking = getSetting(settingsGeneral, 'enableProjectileSticking', true)
    
    local isActor = target and (target.type == types.NPC or target.type == types.Creature or target.type == types.Player)
    local isWorldObject = (not target) or (target.type == types.Door or target.type == types.Activator or target.type == types.Static)
    
    local canStickToTarget = isActor or isWorldObject
    if target and target.type == types.Player then
        local playerBehavior = getSetting(settingsGeneral, 'playerHitBehavior', 'stick')
        if playerBehavior == 'break' then
            canStickToTarget = false
        end
    end
    
    if not canStickToTarget or not enableSticking then return false end

    debugLog('  [STICK-ATTEMPT] Target: ' .. tostring(target and target.recordId or "Ground/Terrain"))

    if not target then
        -- Handle ground impact: Detonate AoE if necessary, then exit
        local enchantId = getProjectileEnchantId(data)
        if enchantId and isAoeEnchantment(enchantId) then
            detonateEnchantmentAtPos(enchantId, data.attacker, impactPos, data, {})
        end
        return false -- We can't stick to terrain, but we handled the impact.
    end

    -- RAW SURFACE REFERENCE (For Bone Selection and Placement)
    local invRot = target.rotation:inverse()
    local meshImpactPosLocal = invRot * (impactPos - target.position)
    
    -- [LOGICAL INVERSION]: Rig forward is Y-. Internally we flip Y to use "+Y = Front" logic.
    local logicSurfacePos = util.vector3(meshImpactPosLocal.x, -meshImpactPosLocal.y, meshImpactPosLocal.z)

    -- Trust the physics hit pinpoint directly. 
    -- Removing nudge/magnetism as it often causes floating or misalignment on complex meshes.
    local magnetizedPos = impactPos

    -- Calculate Visual Depth (Bolts and Thrown weapons bury deeper)
    local buryDepth = 0
    if model:find('bolt') then buryDepth = 8 end
    if data and data.projectileType == 'thrown' then buryDepth = 6 end
    -- Standard ARROWS use 0 bury depth for 1:1 pinpoint surface fidelity
    
    -- GEOMETRIC BURIAL CLAMP (Physical Bleed-Through Prevention)
    -- Logic is now standard: +Y is Front, -Y is Back (based on logicSurfacePos)
    local localHitVisual = logicSurfacePos
    
    if isActor then
        -- Logical Forward for the rig (Y-)
        local actorFwd = target.rotation * util.vector3(0, -1, 0) 
        local dot = (data.flightDir or fwd):dot(actorFwd)
        
        local rawLocalProjFwd = invRot * fwd
        local localProjFwd = util.vector3(rawLocalProjFwd.x, -rawLocalProjFwd.y, rawLocalProjFwd.z)
        
        -- Logic is now standard: +Y is Front, -Y is Back
        if dot < -0.15 then -- Coming FROM Front
            if localHitVisual.y > 0 then
                local distToBarrier = localHitVisual.y - 2
                if localProjFwd.y < -0.01 then
                    local maxBury = math.abs(distToBarrier / localProjFwd.y)
                    buryDepth = math.min(buryDepth, math.max(0, maxBury))
                end
            end
        elseif dot > 0.15 then -- Coming FROM Back
            if localHitVisual.y < 0 then
                local distToBarrier = math.abs(localHitVisual.y) - 2
                if localProjFwd.y > 0.01 then
                    local maxBury = math.abs(distToBarrier / localProjFwd.y)
                    buryDepth = math.min(buryDepth, math.max(0, maxBury))
                end
            end
        end
    end

    local stuckPos = magnetizedPos + (fwd * buryDepth)
    
    local lifetime = getSetting(settingsGeneral, 'projectileLifetime', 300)
    -- local pickupChance = getSetting(settingsAdvanced, 'projectilePickupChance', 50)
    local isRecoverable = true -- Marksman Skill Logic handles chance at recovery time, so we track everything.

    if isActor then
        -- VFX PATH (Direction Faithful & Compatible)
        -- Use robust cloning to bypass engine mesh banning
        local stuckModel = getClonedModelPath(model)
        local vfxInstanceId = getUniqueVfxHandle('pp_v_vfx')
        
        local invRot = target.rotation:inverse()
        local relativePos = invRot * (stuckPos - target.position)
        local relativeRot = invRot * rotation
        
        target:sendEvent('ProjectilePhysics_AttachVfxArrow', {
            model = stuckModel,
            relativePos = relativePos, -- Buried visual position
            surfaceRelativePosRaw = meshImpactPosLocal, -- RAW PINPOINTED SURFACE (For visual alignment)
            logicSurfacePos = logicSurfacePos, -- Y-INVERTED SURFACE (For bone selection)
            relativeRot = relativeRot,
            vfxId = vfxInstanceId,
            lifetime = lifetime,
            useAmbientLight = false,
            attacker = data.attacker,
            flightDir = data.flightDir,
            ammoRecordId = data.ammoRecordId, -- For auto-conversion on death
            pickupMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory'),
            projectileType = data.projectileType or data.type
        })
        
        stuckProjectileRegistry[vfxInstanceId] = {
            type = 'vfx',
            vfxId = vfxInstanceId,
            target = target,
            ammoRecordId = data.ammoRecordId,
            relativePos = relativePos, -- Store for death conversion
            relativeRot = relativeRot, -- Store for death conversion
            spawnTime = core.getRealTime(),
            isRecoverable = isRecoverable,
            lifetime = lifetime,
            model = stuckModel, -- [CRITICAL] Store the CLONED path for refresh compatibility
            attacker = data.attacker, -- Track attacker for marksman skill
            projectileType = data.projectileType or data.type
        }
        
        -- Register in actor VFX registry for type-specific removal
        if data.ammoRecordId then
            local lowAmmoId = data.ammoRecordId:lower()
            local tId = target.id
            
            if not actorVfxRegistry[tId] then actorVfxRegistry[tId] = {} end
            if not actorVfxRegistry[tId][lowAmmoId] then actorVfxRegistry[tId][lowAmmoId] = {} end
            table.insert(actorVfxRegistry[tId][lowAmmoId], vfxInstanceId)
            
            -- Initialize ammo count cache (Important for tracking looting even without Live Sync)
            if not actorAmmoCounts[tId] then actorAmmoCounts[tId] = {} end
            if not actorAmmoCounts[tId][lowAmmoId] then
                local currentTotal = 0
                local inv = types.Actor.inventory(target)
                local ok, allItems = pcall(function() return inv:getAll() end)
                if ok and allItems then
                    for _, item in ipairs(allItems) do
                        if item.recordId:lower() == lowAmmoId then
                            currentTotal = currentTotal + item.count
                        end
                    end
                end
                actorAmmoCounts[tId][lowAmmoId] = currentTotal
            end
            
            debugLog(string.format('[VFX-TRACK] Registered %s on %s (Total: %d, InitialCount: %d)', 
                lowAmmoId, target.recordId or "Actor", #actorVfxRegistry[tId][lowAmmoId], actorAmmoCounts[tId][lowAmmoId]))
        end
        
        -- [SYNC INVENTORY]
        -- Delay addition slightly to prevent animation glitches on the shooter
        local enableLiveSync = getSetting(settingsAdvanced, 'enableLiveInventorySync', true)
        if enableLiveSync and data.ammoRecordId then
            local recordId = data.ammoRecordId
            local targetId = target.id
            async:newUnsavableSimulationTimer(0.05, function()
                if recordId and target and target:isValid() then
                    -- [FIX] Race condition for mass_harvest/activation mode
                    -- If the actor died before the timer hit, and we aren't in standard inventory mode, don't add!
                    local hp = types.Actor.stats.dynamic.health(target)
                    local isDead = (hp and hp.current <= 0)
                    local pMode = settingsCache['pickupMode'] or getSetting(settingsAdvanced, 'pickupMode', 'inventory')
                    if isDead and (pMode == 'mass_harvest' or pMode == 'activation') then
                        debugLog('  [SYNC-SKIP] Target died during delay (' .. pMode .. '). Not adding item.')
                        return
                    end

                    local inv = types.Actor.inventory(target)
                    if inv then
                        local obj = world.createObject(recordId, 1)
                        obj:moveInto(inv)
                        debugLog('  [SYNC-DELAYED] Added ' .. recordId .. ' to ' .. target.recordId .. ' inventory.')
                        
                        -- Update cache immediately
                        if not actorAmmoCounts[targetId] then actorAmmoCounts[targetId] = {} end
                        
                        local currentCount = 0
                        local ok, allItems = pcall(function() return inv:getAll() end)
                        if ok and allItems then
                            local lowRecId = recordId:lower()
                            for _, item in ipairs(allItems) do
                                if item.recordId:lower() == lowRecId then
                                    currentCount = currentCount + item.count
                                end
                            end
                        end
                        actorAmmoCounts[targetId][recordId:lower()] = currentCount
                        
                        -- Flag as synced
                        local sData = stuckProjectileRegistry[vfxInstanceId]
                        if sData then sData.syncedToInventory = true end
                    end
                end
            end)
        end

        return true
    else
        -- ACTIVATOR PATH (World Objects)
        local pickupMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory')
        if pickupMode ~= 'activation' then
             debugLog('  [STICK-SKIP] Activators disabled (inventory mode)')
             return false 
        end
        
        local activatorRecordId = getOrCreateStuckActivatorRecord(model)
        if not activatorRecordId then 
            -- Fallback: If record creation failed, we can't stick to world, but at least we don't crash
            return false 
        end
        
        async:newUnsavableSimulationTimer(0.01, function()
            if not target or not target:isValid() then return end

            local stuckActivator = nil
            local ok, err = pcall(function()
                stuckActivator = world.createObject(activatorRecordId, 1)
                stuckActivator:teleport(target.cell, stuckPos, { rotation = rotation })
            end)
            
            if not ok or not stuckActivator then
                debugLog('  [STICK-FAIL] Spawning (Async) failed: ' .. tostring(err))
                return 
            end
            
            -- Calculate relative coordinates for high-precision follow
            local invRot = target.rotation:inverse()
            local relativePos = invRot * (stuckPos - target.position)
            local relativeRot = invRot * rotation
            
            stuckProjectileRegistry[stuckActivator.id] = {
                type = 'activator',
                activator = stuckActivator,
                target = target,
                ammoRecordId = data.ammoRecordId,
                relativePos = relativePos,
                relativeRot = relativeRot,
                spawnTime = core.getRealTime(),
                isRecoverable = isRecoverable,
                lifetime = lifetime
            }
            
            debugLog('[STICK-SUCCESS] Activator Spawned: ' .. stuckActivator.id)
            
            if lifetime > 0 then
                async:newUnsavableSimulationTimer(lifetime, function()
                    if stuckProjectileRegistry[stuckActivator.id] then removeStuckProjectile(stuckActivator.id) end
                end)
            end
        end)
    end
    return true
end

-- MAIN PHYSICS HIT HANDLER
local function onPhysicsHit(data)
    debugLog('Received LuaProjectilePhysics_ProjectileHit (or Alias)')
    -- Immediate cleanup of follower trail on impact
    if data.projectile then
        local fid = data.projectile.id
        if activeFollowers[fid] then
            if activeFollowers[fid]:isValid() then 
                fadeFollower({ projectile = data.projectile })
            end
            activeFollowers[fid] = nil
        end
    end
    local id = data.projectile.id
    local projData = placedProjectiles[id]
    
    if not projData then 
        return 
    end
    
    -- [BACKUP FADE] Ensure trail fades out gracefully even if local script is removed
    fadeFollower({ projectile = projData.projectile, duration = 1.2 })

    local target = data.hitObject
    local now = core.getRealTime()
    local isActor = target and (target.type == types.NPC or target.type == types.Creature or target.type == types.Player)
    
    -- [CRITICAL] Impact Position (Define early for all paths)
    local impactPos = data.hitPos or (projData.projectile and projData.projectile.position) or util.vector3(0,0,0)
    
    -- [CRITICAL] Priority AoE Detonation Check
    local enchantIdRaw, source = getProjectileEnchantId(projData)
    local enchantId = nil
    
    -- PAY TO PLAY: Verify charges before deciding to detonate or apply hit magic
    if enchantIdRaw and checkPayForMagic(projData, enchantIdRaw, source) then
        enchantId = enchantIdRaw
    end
    local isAoe = enchantId and isAoeEnchantment(enchantId)
    local wasAlreadyBounced = projData.hasBounced
    local wasAlreadyHit = projData.hasHitActor 

    -- [REFINEMENT] AoE detonation for actors is moved down to the block/hit decision point
    -- to ensure the direct target receives AoE damage if the physical hit is blocked.
    -- (The enchantId and isAoe variables defined above are still used below).
    
    debugLog('HIT EVENT: Target=' .. tostring(target and target.recordId or "World") .. ', Bounced=' .. tostring(wasAlreadyBounced))
    
    -- [DEAD ACTOR HEIGHT CONSTRAINT]
    if isActor then
        local health = types.Actor.stats.dynamic.health(target).current
        if health <= 0 then
            local relZ = data.hitPos.z - target.position.z
            if relZ > 20 then
                debugLog('  [STICK-SKIP] Ignoring dead actor hit: Z height ' .. math.floor(relZ) .. ' > 20. Force-Removing.')
                if data.projectile and data.projectile:isValid() then 
                    pcall(function() data.projectile:teleport(data.projectile.cell, util.vector3(data.hitPos.x, data.hitPos.y, -10000)) end)
                    pcall(function() data.projectile:remove() end)
                end
                placedProjectiles[id] = nil
                return
            end
        end
    end
    
    -- [WORLD IMPACT HANDLING]
    if not isActor then
        local timeSinceSpawn = now - projData.spawnTime
        -- Only apply grace period for launcher-spawned shots to prevent self-deletion
        if projData.spawnAtLauncher and timeSinceSpawn < 0.01 then return end
        
        -- SUPER AGGRESSIVE DIAGNOSTICS
        if not projData.hasBounced then
             pcall(function()
                 local sTable = settingsGeneral:asTable()
                 debugLog('  [FULL-STORAGE-DUMP] Total keys found: ' .. tostring(#sTable or "N/A"))
                 for k, v in pairs(sTable) do
                      debugLog(string.format('  [FULL-STORAGE-DUMP] Key: "%s" = %s', tostring(k), tostring(v)))
                 end
             end)

            local breakRate = 100 -- Default for AoE
            if isAoe then
                breakRate = tonumber(getSetting(settingsGeneral, 'aoeBreakRate', 100)) or 100
            else
                breakRate = tonumber(getSetting(settingsGeneral, 'breakChance', 25)) or 25
            end

            local roll = math.random(100)
            debugLog(string.format('  [WORLD-HIT] First Impact Roll: %d vs BreakRate: %s', roll, tostring(breakRate)))
            
            if roll <= tonumber(breakRate) then
                local pId = data.projectile and data.projectile.id or id
                debugLog(string.format('  [BREAK] Projectile %s (Valid: %s) broke on world impact', tostring(pId), tostring(data.projectile:isValid())))
                
                -- If AoE breaks on world, it detonates
                if isAoe then
                    debugLog('  [AOE-DETONATE] Detonating on world break')
                    detonateEnchantmentAtPos(enchantId, projData.attacker, impactPos, projData, {})
                end

                if data.projectile and data.projectile:isValid() then 
                    -- Force-Remove: Hide immediately
                    pcall(function() data.projectile:teleport(data.projectile.cell, util.vector3(impactPos.x, impactPos.y, -10000)) end)
                    -- Delayed removal to avoid physics script lock during collision
                    async:newUnsavableSimulationTimer(0, function()
                        if data.projectile and data.projectile:isValid() then 
                             pcall(function() data.projectile:remove() end)
                        end
                    end)
                end
                placedProjectiles[id] = nil
                return -- Exit as projectile is destroyed
            end
        end
    end

    -- BOUNCE DETECTION
    if not projData.hasBounced then
        if not isActor then
            local timeSinceSpawn = now - projData.spawnTime
            if timeSinceSpawn < 0.01 then -- Reduced grace period for point-blank hits
                debugLog('  Ignoring point-blank spawn-time wall effects, but marking as bounced.')
                projData.hasBounced = true
                return
            end
        end
        
        projData.hasBounced = true
    end

    -- [DURABILITY]
    if not projData.durabilityApplied then
        if not isActor then
            applyLauncherDurability(projData.launcher, 0, false)
            projData.durabilityApplied = true
        end
    end

    -- Only proceed if hitting actor
    if not isActor then return end


    -- SELF-HIT PREVENTION
    local timeSinceSpawn = now - projData.spawnTime
    if target == projData.attacker and timeSinceSpawn < 0.55 then
         return
    end
    
    -- [BLOCKING LOGIC] Checks before Damage/VFX to prevent blood/sticking
    local isBlocked = false
    if isActor and getSetting(settingsGeneral, 'enableProjectileBlocking', true) then
        local stance = types.Actor.getStance(target)
        if stance == types.Actor.STANCE.Weapon then
            local equip = types.Actor.getEquipment(target)
            local shieldItem = equip[types.Actor.EQUIPMENT_SLOT.CarriedLeft]
            local hasShield = false
            
            if shieldItem then
                -- Verify it is a shield
                if types.Armor then
                    local rec = types.Armor.record(shieldItem)
                    if rec and rec.type == types.Armor.TYPE.Shield then hasShield = true end
                end
                -- Basic fallback if types.Armor unavailable (unlikely)
                if not hasShield and types.Weapon and types.Weapon.record(shieldItem) then
                    -- Maybe a weapon (dual wield block?), user spec said Shield.
                end
            end
            
            if hasShield then
                -- Directional Check (160 deg Arc, skewed 7 deg Left)
                local invRot = target.rotation:inverse()
                local relPos = invRot * (projData.attacker.position - target.position)
                
                -- 1. Apply 7 deg Left Skew to find "Skewed Forward" component
                local skewY = (0.993 * relPos.y) - (0.122 * relPos.x)
                
                -- 2. Check 80 degree half-angle (cos(80) ~ 0.174)
                -- Condition: dot / mag > cos(theta)  =>  dot^2 > cos^2 * mag^2
                local distSq = relPos.x*relPos.x + relPos.y*relPos.y
                local isFrontHit = (skewY > 0) and (skewY * skewY > (0.030 * distSq))
                
                if isFrontHit then
                    -- Calc Chance
                    local blockSkill = getSkillModifiedActor(target, 'block')
                    local agility = types.Actor.stats.attributes.agility(target).modified
                    local luck = types.Actor.stats.attributes.luck(target).modified
                    
                    local attackerMarksman = 30
                    local attackerAgility = 50
                    local attackerLuck = 50
                    if projData.attacker then
                        attackerMarksman = getSkillModifiedActor(projData.attacker, 'marksman')
                        attackerAgility = types.Actor.stats.attributes.agility(projData.attacker).modified
                        attackerLuck = types.Actor.stats.attributes.luck(projData.attacker).modified
                    end
                    
                    local blockChance = (0.25 * blockSkill) + (luck / 10.0) + (agility / 5.0)
                    local attackBonus = attackerMarksman + (attackerAgility / 5.0) + (attackerLuck / 10.0)
                    local finalChance = blockChance - attackBonus + 10 -- Base 10 modifier
                    
                    if math.random(100) <= finalChance then
                        isBlocked = true                        
                        debugLog('[BLOCK] Blocked by Global! (Chance: ' .. finalChance .. ')')
                        target:sendEvent('ProjectilePhysics_BlockFeedback', {})

                        -- [USER REQUEST] For AoE projectiles, if blocked, trigger detonation INCLUDING the target
                        if isAoe then
                            debugLog('  [AOE-DETONATE] Detonating on blocked target (including target in AoE)')
                            -- Only exclude the attacker to avoid self-harm
                            local exclusions = {}
                            if projData.attacker and projData.attacker:isValid() then exclusions[projData.attacker.id] = true end
                            detonateEnchantmentAtPos(enchantId, projData.attacker, impactPos, projData, exclusions)
                        end
                        
                        -- [REFINEMENT] Implement Physical Bounce (Fixing Lua Error)
                        if projData.projectile and projData.projectile:isValid() then 
                            local projectile = projData.projectile
                            -- The physics engine passes velocity in the data table
                            local currentVelocity = data.velocity or (projData.direction * (projData.speed or 5000))
                            local incoming = projData.direction or currentVelocity:normalize()
                            
                            -- Use vector from attacker to target as normal proxy for the shield surface
                            local normal = (target.position - projData.attacker.position):normalize()
                            local dot = incoming:dot(normal)
                            local reflected = (incoming - normal * (2 * dot)):normalize()
                            
                            -- Add randomness for physical "clatter" effect
                            reflected = (reflected + util.vector3(math.random()-0.5, math.random()-0.5, math.random()-0.5) * 0.4):normalize()
                            
                             local oldSpeed = currentVelocity:length()
                             local newSpeed = math.min(800, math.max(200, oldSpeed * 0.25)) -- 75% reduction, clamped [200, 800]
                             
                             -- Authoritative Velocity Set (Fixes "Impulse + Mass" speed doubling)
                             projectile:sendEvent(D.e.SetPhysicsProperties, { 
                                 velocity = reflected * newSpeed,
                                 isSleeping = false 
                             })
                            
                            -- Track state to prevent re-hitting the same block frame
                            projData.hasBounced = true
                            projData.lastHitObject = target.id
                            projData.lastHitTime = core.getRealTime()
                        end
                        
                        -- [CRITICAL] Return early to skip Damage, Sticking, and VFX
                        return 
                    end
                end
            end
        end
    end
    -- HIT CHANCE / DAMAGE 
    local hitMode = getSetting(settingsAdvanced, 'hitDetectionMode', 'vanilla') -- Use settingsAdvanced!
    -- local skipRoll ... (unused now)
    
    local isVanillaMiss = false
    
    if hitMode == 'vanilla' and projData.attacker and target then
        local hitChance = calculateMarksmanHitChance(projData.attacker, target)
        local roll = math.random(100)
        
        debugLog(string.format('  [VANILLA-ROLL] Chance: %d vs Roll: %d (Actor: %s)', hitChance, roll, tostring(target.recordId)))
        
        if roll > hitChance then
            debugLog('  [MISS] Vanilla Dice Roll failed. Nullifying damage but maintaining collision event.')
            isVanillaMiss = true
            -- Do NOT return. Proceed to trigger event (0 damage) so actor reacts.
        end
    end
    
    -- Debounce
    if projData.lastHitObject == target.id and (now - (projData.lastHitTime or 0) < 0.5) then
         return
    end

    -- [REVISION 45] Robust Record Lookup
    -- Prefer resolving from ammoRecordId/weaponRecordId strings directly
    local model = nil
    local sourceRecord = nil
    
    local lookupId = projData.ammoRecordId or projData.weaponRecordId
    if lookupId then
        local rec = nil
        pcall(function() rec = types.Ammunition.records[lookupId] or types.Weapon.records[lookupId] end)
        
        if rec then
            sourceRecord = rec
            model = rec.model
            debugLog('  [RECORD-FOUND] Resolved model ' .. model .. ' from ID ' .. lookupId)
        end
    end

    -- Fallback to instance (only if ID lookup failed)
    if not model and projData.projectile and projData.projectile:isValid() then
         local rec = nil
         pcall(function() rec = types.Ammunition.record(projData.projectile) end)
         if not rec then pcall(function() rec = types.Weapon.record(projData.projectile) end) end
         if rec then 
             model = rec.model 
             sourceRecord = rec
         end
    end

    local baseDamage = projData.damage or 5
    if data.waterDamageMult then
        baseDamage = baseDamage * data.waterDamageMult
        debugLog('  [WATER] Applying water damage multiplier: ' .. tostring(data.waterDamageMult))
    end
    local damage = isVanillaMiss and 0 or baseDamage
    if wasAlreadyBounced then
         local bounceMultValue = getSetting(settingsGeneral, 'bounceDamageMultiplier', 33)
         local bounceMult = bounceMultValue / 100
         damage = baseDamage * bounceMult
         debugLog(string.format('  [BOUNCE-DMG] Multiplier Applied: %d%% | %d -> %d', bounceMultValue, baseDamage, damage))
    end
    
    -- [DELEGATE TO LOCAL SCRIPT]
    -- Combat API (I.Combat) is only available in LOCAL scripts, not Global.
    -- So we always send the event, and the Actor script handles I.Combat.onHit.
    local fwd = projData.direction or util.vector3(0,1,0)

    debugLog(string.format('[PP-GLOBAL] Sending Hit Event to Actor | Target=%s | Dmg=%.1f | Bypass=%s', 
        target.recordId, damage, tostring(projData.bypassesNormalResistance)))
         
    local reg = virtualEnchantRegistry[projData.attacker.id]
    local skipLauncherEnchant = (reg ~= nil)
    -- [GLOBAL MAGIC] Apply enchantments directly (AoE is handled at top for pulse, handles direct hit here)
    if enchantId then
        -- [USER REQUEST] For AoE projectiles, trigger detonation EXCLUDING the target 
        -- (standard behavior because they are about to receive direct hit enchantment)
        if isAoe then
            debugLog('  [AOE-DETONATE] Detonating on hit target (excluding target to avoid double damage)')
            local exclusions = {}
            if target then exclusions[target.id] = true end
            if projData.attacker and projData.attacker:isValid() then exclusions[projData.attacker.id] = true end
            detonateEnchantmentAtPos(enchantId, projData.attacker, impactPos, projData, exclusions)
        end
        
        applyEnchantmentGlobal(enchantId, projData.attacker, target, impactPos, isAoe, projData)
    end

    target:sendEvent('ProjectilePhysics_ApplyDamage', {
         damage = damage,
         hitPos = impactPos,
         attacker = projData.attacker,
         launcher = projData.launcher,
         ammoRecordId = projData.ammoRecordId,
         projectile = projData.originalItem or projData.projectile, -- PREFER ORIGINAL ITEM/RECORD
         originalProjectile = projData.originalItem, -- EXPLICIT ORIGINAL
         flightDir = data.flightDir or fwd,
         chargeRatio = projData.chargeRatio,
         bypassesNormalResistance = projData.bypassesNormalResistance,
         weaponRecordId = projData.weaponRecordId,
         skipEnchants = true, -- CRITICAL: Handled by global now
         isAoe = isAoe,
         boneName = data.boneName -- [NEW] Pass boneName for locational damage
    })

    -- Bounty (XP is now handled by Combat.onHit in actor script via successful=true)
    local isPlayerAttacker = projData.attacker and (projData.attacker.type == types.Player or projData.attacker == world.players[1])
    if not wasAlreadyBounced and isPlayerAttacker and target.id ~= projData.attacker.id then
         -- Skill XP is now handled by Combat.onHit - removed manual XP call
         onReportAssault({ victim = target, attacker = projData.attacker })
    end
    
    -- Apply Durability
    if not projData.durabilityApplied then
        applyLauncherDurability(projData.launcher, damage, true)
        projData.durabilityApplied = true
    end

    -- STICK TO BODY (Using Helper)
    -- STABILIZE ROTATION: If velocity has bounced/flipped on impact, use flight intent
    local stickDir = projData.direction
    
    -- [REVISION 43] Prioritize REAL velocity passed from local script
    local curVel = data.velocity or (projData.projectile and projData.projectile:isValid() and projData.projectile.velocity)
    
    if curVel and curVel:length() > 10 then
        local normVel = curVel:normalize()
        -- If velocity is still mostly aligned with launch intent, use it (accounts for gravity arc)
        if normVel:dot(projData.direction) > 0.1 then
            stickDir = normVel
        end
    end
    
    local stuckData = {
        target = target,
        hitPos = data.hitPos or projData.projectile.position,
        model = model,
        sourceRecord = sourceRecord,
        projectile = projData.projectile,
        projectileId = id,
        rotation = getVectorRotation(stickDir, (data.hitPos or projData.projectile.position).z, (projData.startPos and projData.startPos.z) or (data.hitPos or projData.projectile.position).z),
        flightDir = projData.direction,
        projectileType = projData.type,
        ammoRecordId = projData.ammoRecordId,
        attacker = projData.attacker -- INCLUDE ATTACKER
    }
    
    local stuck = false
    -- [REVISION 43] Relax sticking restriction: Allow sticking even after bounce for better reliability
    -- [USER REQUEST] Allow sticking for ALL projectiles, including enchanted/AoE (matching unenchanted behavior)
    if isActor and not wasAlreadyHit then
        stuck = tryStickProjectile(stuckData)
    else
        debugLog('  [STICK-SKIP] Skipping sticking (Already hit, or not hitting actor).')
    end
    
    if stuck then
         projData.hasHitActor = true
         projData.lastHitObject = target.id
         projData.lastHitTime = now
         return -- Stuck and removed
    end

    -- Hit but failed stick (bounce or disabled)
    debugLog('  Hit actor but sticking failed/disabled. Removing projectile.')
    if projData.projectile and projData.projectile:isValid() and projData.projectile.count > 0 then 
        -- STOP & REMOVE: Kill velocity immediately to prevent visual bounce
        pcall(function() 
            projData.projectile.velocity = util.vector3(0,0,0)
            projData.projectile:remove() 
        end)
    end
    placedProjectiles[id] = nil
    
    projData.lastHitObject = target.id
    projData.lastHitTime = now
end

local function onDirectHit(data)
    local target = data.target
    local damage = data.damage or 1
    
    local waterLevel = target and target.cell and target.cell.waterLevel
    local waterMult = nil
    if waterLevel and ((data.hitPos and data.hitPos.z < waterLevel) or (data.startPos and data.startPos.z < waterLevel) or (data.attacker and data.attacker.position.z < waterLevel)) then
        waterMult = (data.projectileType == 'bolt') and 0.2 or 0.1
        damage = damage * waterMult
        debugLog('  [WATER] Direct Hit water damage multiplier applied: ' .. tostring(waterMult))
    end
    
    debugLog('Direct Hit (Raycast): Dealing ' .. damage .. ' damage to ' .. tostring(target.recordId or target.id))
    
    target:sendEvent('ProjectilePhysics_ApplyDamage', {
        damage = damage,
        attacker = data.player or data.attacker,
        hitPos = data.hitPos,
        projectileId = data.projectileId,
        isGodMode = (target.type == types.Player) and isGodModeActive,
        -- Combat API AttackInfo fields
        ammoRecordId = data.ammo and data.ammo.recordId, -- Assuming ammo is the item object
        weaponRecordId = data.launcher and data.launcher.recordId,
        chargeRatio = data.chargeRatio or 1.0,
        bypassesNormalResistance = checkBypass(data.launcher and data.launcher.recordId, data.ammo and data.ammo.recordId), -- Immunity Check
        waterDamageMult = waterMult
    })
    
    local attacker = data.player or data.attacker
    if attacker and target and target ~= attacker then
        onReportAssault({ victim = target, attacker = attacker })
    end

    -- [DEAD ACTOR HEIGHT CONSTRAINT]
    if target and (target.type == types.NPC or target.type == types.Creature) then
        local health = types.Actor.stats.dynamic.health(target).current
        if health <= 0 then
            local hitPos = data.hitPos or target.position
            local relZ = hitPos.z - target.position.z
            if relZ > 20 then
                 debugLog('  [DIRECT-SKIP] Ignoring dead actor hit: Z height ' .. math.floor(relZ) .. ' > 20')
                 return
            end
        end
    end
    
    if data.launcher then
        applyLauncherDurability(data.launcher, damage, true)
    end
    
    -- Try to stick for Raycast hits too
    local model = nil
    if data and data.ammo then
        local ammoRec = nil
        pcall(function() ammoRec = types.Ammunition.records[data.ammo] end)
        if ammoRec then
            model = ammoRec.model
        end
    end
    
    if model then
        tryStickProjectile({
            target = target,
            hitPos = data.hitPos,
            model = model,
            sourceRecord = ammoRec,
            projectile = nil,
            projectileId = nil,
            rotation = getVectorRotation(data.direction, data.hitPos.z, (data.startPos and data.startPos.z) or (data.attacker and data.attacker.position.z) or data.hitPos.z),
            flightDir = data.direction,
            projectileType = data.projectileType,
            ammoRecordId = ammoRec and ammoRec.id,
            attacker = data.player or data.attacker -- INCLUDE ATTACKER
        })
    end
end

-- [CLEANUP] Redundant block removed.


-- [FIX] Stub for missing onProjectileFired function
local function onProjectileFired(data)
    -- This function can be expanded later if needed for global-side projectile firing logic
    debugLog("Projectile fired: " .. (data.recordId or "unknown"))
end

return {
    engineHandlers = {
        onUpdate = masterUpdate,
        onSave = function() 
            return { 
                stuckProjectileRegistry = stuckProjectileRegistry,
                actorVfxRegistry = actorVfxRegistry,
                virtualEnchantRegistry = virtualEnchantRegistry,
                boneSyncRegistry = boneSyncRegistry,
                playersSneaking = playersSneaking
            } 
        end,
        onLoad = function(data)
            -- [TASK 1] Re-register trail records after load (runtime records don't persist through saves)
            trailRecordsInitialized = false
            ensureTrailRecords()
            processedDeaths = {}
            if data then
                stuckProjectileRegistry = data.stuckProjectileRegistry or {}
                actorVfxRegistry = data.actorVfxRegistry or {}
                virtualEnchantRegistry = data.virtualEnchantRegistry or {}
                boneSyncRegistry = data.boneSyncRegistry or {}
                playersSneaking = data.playersSneaking or {}
            end
        end,
        onActivate = function(obj, actor)
            if not obj or not actor then return end
            local sData = stuckProjectileRegistry[obj.id]
            if sData and (sData.type == 'item' or sData.type == 'activator') then
                local distOk = true
                if sData.target and sData.target:isValid() then
                    local dist = (actor.position - sData.target.position):length()
                    if dist > 350 then distOk = false end
                end
                if distOk then
                    core.sendGlobalEvent('ProjectilePhysics_Interact', { object = obj, actor = actor })
                end
                return true
            end
            if core.isGamePaused and core.isGamePaused() then return end
            local pMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory')
            if actor.type == types.Player and (pMode == 'activation' or pMode == 'mass_harvest') then
                local isSneaking = playersSneaking[actor.id]
                if isSneaking == nil then
                    isSneaking = (types.Actor.getStance(actor) == 2 or (types.Actor.isSneaking and types.Actor.isSneaking(actor)))
                end
                if isSneaking and (obj.type == types.NPC or obj.type == types.Creature) then
                     local hp = types.Actor.stats.dynamic.health(obj)
                     local dist = (actor.position - obj.position):length()
                     if hp and hp.current <= 0 and dist <= 250 then
                          obj:sendEvent('ProjectilePhysics_RecallPrecisionCoords', { player = actor })
                          return true
                     end
                end
            end
        end,
    },
    eventHandlers = {
        ProjectilePhysics_SyncSneakState = function(data)
            if data and data.sneaking ~= nil and data.player then
                playersSneaking[data.player.id] = data.sneaking
            end
        end,
        ProjectilePhysics_UpdateGodMode = function(active) isGodModeActive = active end,
        ProjectilePhysics_TriggerNpcShot = onPlaceProjectile,
        ProjectilePhysics_PlaceProjectile = onPlaceProjectile,
        ProjectilePhysics_TryPlaceProjectile = onPlaceProjectile, -- ALIAS (Restored)
        LuaProjectilePhysics_StickProjectile = tryStickProjectile, -- [NEW] Restores world-sticking support
        ProjectilePhysics_StickProjectile = tryStickProjectile,    -- ALIAS
        LuaProjectilePhysics_SpawnFollower = spawnFollower,
        LuaProjectilePhysics_UpdateFollower = updateFollower,
        LuaProjectilePhysics_RemoveFollower = removeFollower,
        LuaProjectilePhysics_FadeFollower = fadeFollower, -- [NEW]
        ProjectilePhysics_SetFloating = function(data)
            if data and data.projectile then
                local projData = placedProjectiles[data.projectile.id]
                if projData then projData.isFloating = true end
            end
        end,
        -- LuaProjectilePhysics_SpawnTrailParticlesBatch = spawnTrailParticlesBatch, -- REMOVED
        -- LuaProjectilePhysics_RemoveTrailParticles = removeTrailParticles, -- REMOVED
        ProjectilePhysics_DirectHit = onDirectHit,

        -- [TASK 4] Water physics splash
        ProjectilePhysics_EnteredWater = function(data)
            local pos = data.position
            if not pos then return end
            -- Play splash sound at impact point
            pcall(function()
                core.sound.playSound3d('Water Large', data.projectile or world.players[1], {
                    volume = 0.8, pitch = 0.9 + math.random() * 0.2
                })
            end)
            debugLog('[WATER] Projectile entered water at z=' .. tostring(pos.z))
        end,

        ProjectilePhysics_DeductCharges = function(data) -- ALIAS (Restored)
            -- Call the singular version since that has the actual logic
            -- Need to copy code since we can't self-reference the table during construction
            local item = data.item
            local cost = data.cost
            if item and item:isValid() then
                local itemData = types.Item.itemData(item)
                if itemData then
                    local current = itemData.enchantmentCharge
                    if not current then
                        local rec = nil
                        if item.type == types.Weapon then rec = types.Weapon.record(item)
                        elseif item.type == types.Ammunition then rec = types.Ammunition.record(item) end
                        if rec and rec.enchant and rec.enchant ~= "" then
                            local ench = core.magic.enchantments.records[rec.enchant] or core.magic.enchantments[rec.enchant]
                            current = (ench and ench.charge) or 0
                        end
                    end
                    current = current or 0
                    itemData.enchantmentCharge = math.max(0, current - cost)
                end
            end
        end,
        
        LuaProjectilePhysics_ProjectileHit = onPhysicsHit,
        LuaPhysics_ProjectileHit = onPhysicsHit, -- ALIAS
        ProjectilePhysics_Hit = onPhysicsHit,    -- ALIAS
        
        ProjectilePhysics_ReportAssault = onReportAssault,
        ProjectilePhysics_ReportMurder = handleMurderReport,
        -- LuaProjectilePhysics_SpawnTrailParticlesBatch = spawnTrailParticlesBatch, -- REMOVED
        -- LuaProjectilePhysics_RemoveTrailParticles = removeTrailParticles, -- REMOVED
        ProjectilePhysics_DeductCharge = function(data)
            local item = data.item
            local cost = data.cost
            if item and item:isValid() then
                local itemData = types.Item.itemData(item)
                if itemData then
                    local current = itemData.enchantmentCharge
                    if not current then
                        -- Resolve max charge from record if not previously modified
                        local rec = nil
                        if item.type == types.Weapon then rec = types.Weapon.record(item)
                        elseif item.type == types.Ammunition then rec = types.Ammunition.record(item) end
                        if rec and rec.enchant and rec.enchant ~= "" then
                            local ench = core.magic.enchantments.records[rec.enchant] or core.magic.enchantments[rec.enchant]
                            current = (ench and ench.charge) or 0
                        end
                    end
                    current = current or 0
                    itemData.enchantmentCharge = math.max(0, current - cost)
                    -- Global debugLog
                    debugLog(string.format("[ProjectilePhysics Global] Deducted %d charge (Effective Cost) from %s for %s (Remaining: %d)", 
                        cost, item.recordId, data.enchantId or "Enchantment", itemData.enchantmentCharge))
                end
            end
        end,
        
        ProjectilePhysics_UpdateBoneSync = function(data)
            if not data.targetId then return end
            boneSyncRegistry[data.targetId] = {
                bones = data.bones,
                time = core.getRealTime()
            }
        end,
        
        ProjectilePhysics_InitialBoneResponse = function(data)
            local projData = placedProjectiles[data.projectileId]
            debugLog('  [BRIDGE-RESPONSE] NPC reported BoneFit: ' .. tostring(data.boneName))
            
            if projData and projData.attachedTo and data.boneName then
                projData.boneName = data.boneName
                local invAnchorRot = data.boneRot:inverse()
                projData.relativePos = invAnchorRot * (projData.projectile.position - data.bonePos)
                projData.relativeRot = invAnchorRot * projData.projectile.rotation
                debugLog('  [BRIDGE] Bone-Link finalized for Proj ' .. tostring(data.projectileId) .. ' (' .. tostring(data.boneName) .. ')')
            end
        end,
        
        ProjectilePhysics_ActivateStuckArrow = function(data)
            local activatorId = data.activatorId
            local player = data.player
            local stuckData = stuckProjectileRegistry[activatorId]
            
            if not stuckData then return end
            
            local targetHealth = stuckData.target and types.Actor.stats.dynamic.health(stuckData.target)
            local isDead = not stuckData.target or not stuckData.target:isValid() or (targetHealth and targetHealth.current <= 0)
            
            if not isDead then
                debugLog('[PICKUP] Cannot pick up arrow from living NPC')
                return
            end
            
            local pickupMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory')
            if pickupMode ~= 'activation' then return end
            
            if not stuckData.isRecoverable then
                debugLog('[PICKUP] Arrow was destroyed on impact')
                async:newUnsavableSimulationTimer(0.1, function()
                    removeStuckProjectile(activatorId)
                end)
                return
            end
            
            -- Get player's marksman skill for success chance
            local marksmanSkill = 0
            if player and player:isValid() then
                pcall(function()
                    local skillStat = types.Player.stats.skills.marksman(player)
                    marksmanSkill = skillStat and skillStat.modified or 0
                end)
            end
            local successChance = math.min(marksmanSkill, 100)
            
            -- Roll for success
            local roll = math.random(100)
            local success = (roll <= successChance)
            
            if success and stuckData.ammoRecordId and player then
                -- [REFACTORED PICKUP LOGIC]
                local ammoId = stuckData.ammoRecordId
                
                -- Determine if it's a real world item (Weapon/Ammo) or a custom activator/VFX
                local isRealItem = false
                local activator = stuckData.activator
                
                if activator and activator:isValid() then
                    isRealItem = (activator.type == types.Ammunition or activator.type == types.Weapon)
                end
                
                local itemName = ammoId
                
                -- 2. Handle Item Creation / Transfer
                if isRealItem then
                     -- Engine interactions handle real items usually.
                     -- We define name just for message.
                     local rec = nil
                     if types.Ammunition then rec = types.Ammunition.record(ammoId) end
                     if not rec and types.Weapon then rec = types.Weapon.record(ammoId) end
                     if rec then itemName = rec.name end
                else
                     -- 3. Validate Ammo Record
                     local rec = nil
                     if types.Ammunition then rec = types.Ammunition.record(ammoId) end
                     if not rec and types.Weapon then rec = types.Weapon.record(ammoId) end
                     
                     if not rec then
                         -- [FALLBACK]
                         debugLog('[PICKUP-WARN] Record lookup failed used ID: ' .. tostring(ammoId))
                     else
                         itemName = rec.name
                     end
                     
                     -- 4. Create Object
                     local newItem = world.createObject(ammoId, 1)
                     if not newItem then
                         debugLog('[PICKUP-FAIL] world.createObject failed for: ' .. tostring(ammoId))
                         player:sendEvent('ProjectilePhysics_ShowMessage', { msg = 'Projectile broke.' })
                         async:newUnsavableSimulationTimer(0.1, function()
                             removeStuckProjectile(activatorId)
                         end)
                         return
                     end
                     
                     -- 5. Transfer to Inventory
                     local playerInv = types.Actor.inventory(player)
                     if not playerInv then
                          debugLog('[PICKUP-FAIL] Player inventory not found!')
                          newItem:remove()
                          return
                     end
                     
                     newItem:moveInto(playerInv)
                end
                
                player:sendEvent('ProjectilePhysics_ShowMessage', { msg = 'Recovered ' .. itemName })
                debugLog(string.format('[PICKUP] Arrow recovered: %s (Roll: %d/%d)', ammoId, roll, successChance))
            else
                player:sendEvent('ProjectilePhysics_ShowMessage', { msg = 'Projectile broke.' })
                debugLog(string.format('[PICKUP] Failed to recover %s (Roll: %d/%d)', stuckData.ammoRecordId or 'unknown', roll, successChance))
            end
            
            -- Remove activator regardless of success (attempted pickup)
            async:newUnsavableSimulationTimer(0.1, function()
                    removeStuckProjectile(activatorId)
                end)
        end,
        
        ProjectilePhysics_ProcessPrecisionHarvest = function(data)
            if not data.target or not data.player or not data.items or #data.items == 0 then return end
            table.insert(staggeredBatches, {
                mode = 'precision',
                target = data.target,
                player = data.player,
                items = data.items,
                currentIndex = 1,
                recoveredCount = 0
            })
        end,
        
        ProjectilePhysics_TryCollectFromActor = function(data)
            local target = data.target
            local player = data.player
            if not target or not player then return end
            
            local toHarvest = {}
            for objId, sData in pairs(stuckProjectileRegistry) do
                if sData.target and sData.target.id == target.id then
                    table.insert(toHarvest, objId)
                end
            end
            
            if #toHarvest == 0 then return end
            
            local marksmanSkill = 0
            pcall(function()
                local skillStat = types.Player.stats.skills.marksman(player)
                marksmanSkill = skillStat and skillStat.modified or 0
            end)
            
            table.insert(staggeredBatches, {
                mode = 'normal',
                target = target,
                player = player,
                toHarvest = toHarvest,
                currentIndex = 1,
                recoveredCounts = {},
                totalRecovered = 0,
                successChance = math.min(marksmanSkill, 100)
            })
        end,
        
        ProjectilePhysics_SpawnActivatorAtPos = function(data)
            local recordId = data.ammoRecordId
            if not recordId then return end
            
            debugLog('[SPAWN-DEBUG] Received request for ' .. tostring(data.model))
            
            local ok, err = pcall(function()
                -- Get/Create activator using the EXACT model path (true = Use LPP path logic)
                -- data.model comes from Actor script which got it from Item record
                -- true = Create as TYPES.ACTIVATOR (Interactable)
                -- This will result in path: LPP/meshes/luaactmeshes/...
                local actRecord = getOrCreateStuckActivatorRecord(data.model, true, true, recordId)
                if not actRecord then
                     -- FALLBACK: If record creation failed, use the ORIGINAL ITEM record.
                     -- We still treat it as an activator so it follows the corpse!
                     actRecord = recordId
                     debugLog('[SPAWN-FALLBACK] Record creation unsupported. Using original item: ' .. recordId)
                end

                local cell = nil
                if data.actor and data.actor:isValid() then cell = data.actor.cell end
                if not cell then cell = world.players[1].cell end
                
                local activator = nil
                if not data.isMassHarvestAction then
                    debugLog('[SPAWN-DEBUG] Creating object with ID: ' .. tostring(actRecord))
                    activator = world.createObject(actRecord)
                    
                    -- [STATIC PLACEMENT] Use the animated world position/rotation from Actor script
                    activator:teleport(cell, data.pos, {rotation = data.rot})
                    if data.scale then activator:setScale(data.scale) end
                    
                    -- Register for interaction tracking (Static - no bone-sync needed)
                    stuckProjectileRegistry[activator.id] = {
                        type = 'activator',
                        activator = activator,
                        target = data.actor,
                        ammoRecordId = recordId,
                        spawnTime = core.getRealTime(),
                        isRecoverable = true
                    }
                    debugLog('[SPAWN-SUCCESS] Spawned static activator: ' .. tostring(actRecord))
                else
                    debugLog('[SPAWN-STRIP] Skipping activator spawn for mass_harvest (Inventory Strip Only).')
                end
                
                -- [SYNC INVENTORY]
                -- Remove from NPC inventory during conversion to prevent double-looting
                local pMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory')
                if data.actor and data.actor:isValid() and (pMode == 'activation' or pMode == 'mass_harvest') then
                    local inv = types.Actor.inventory(data.actor)
                    if inv then
                        local item = inv:find(recordId)
                        if item then
                            item:remove(1)
                            debugLog('  [SYNC] Cleaned up ' .. recordId .. ' from ' .. data.actor.recordId .. ' inventory for activator replacement.')
                        end
                    end
                end
            end)
            
            if not ok then
                debugLog('[SPAWN-ERROR] ' .. tostring(err))
            end
        end,
        
        ProjectilePhysics_VirtualInteract = function(data)
            local target = data.target
            local from = data.rayFrom
            local to = data.rayTo
            local actor = data.player -- Player who clicked
            
            if not target or not from or not to or not actor then return end
            
            local pickupMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory')
            if pickupMode ~= 'activation' then 
                debugLog('[VIRTUAL-PICKUP] Skipped: Not in activation mode.')
                return 
            end
            
            -- Direction vector of the ray
            local rayDir = (to - from):normalize()
            local bestDist = 44.0 -- [ENLARGED] Increased tolerance (35 * 1.25 = 43.75) to make picking up easier.
            local bestActivatorId = nil
            
            -- Iterate all stuck projectiles
            for actId, sData in pairs(stuckProjectileRegistry) do
                -- Only check projectiles attached to this NPC
                if sData.target and sData.target == target and sData.activator and sData.activator:isValid() then
                    local pos = sData.activator.position
                    
                    -- Calculate perpendicular distance from Point (pos) to Line (from, rayDir)
                    -- Dist = |(pos - from) X rayDir|  (assuming rayDir is normalized)
                    local vec = pos - from
                    local crossP = vec:cross(rayDir)
                    local dist = crossP:length()
                    
                    if dist < bestDist then
                        bestDist = dist
                        bestActivatorId = actId
                    end
                end
            end
            
            if bestActivatorId and stuckProjectileRegistry[bestActivatorId] then
                debugLog('[ProjectilePhysics-DEBUG] Virtual Raycast Hit! Dist: ' .. tostring(bestDist) .. ' ID: ' .. tostring(bestActivatorId))
                
                -- Delegate to the main Interact handler using the REAL object (safe for serialization)
                local realActivator = stuckProjectileRegistry[bestActivatorId].activator
                if realActivator and realActivator:isValid() then
                    core.sendGlobalEvent('ProjectilePhysics_Interact', { object = realActivator, actor = actor })
                else
                    debugLog('[ProjectilePhysics-DEBUG] Virtual Hit found invalid activator object.')
                end
            end
        end,
        
        ProjectilePhysics_Interact = function(data)
            local activatorId = (data.object and data.object.id) or data.projectileId
            local player = data.actor
            
            -- [USER REQUEST] FEEDBACK FOR BLOCKS
            if data.isBlock and activatorId then
                debugLog('[BLOCK] Processing blocked projectile: ' .. tostring(activatorId))
                
                -- Send event to actor to play animation and sound (can't do it from global)
                if data.actor and data.actor:isValid() then
                    debugLog('[BLOCK] Sending BlockFeedback event to actor: ' .. tostring(data.actor.recordId or data.actor.id))
                    data.actor:sendEvent('ProjectilePhysics_BlockFeedback', {})
                else
                    debugLog('[BLOCK] ERROR: Actor is nil or invalid, cannot send feedback event!')
                end
                
                async:newUnsavableSimulationTimer(0.1, function()
                    removeStuckProjectile(activatorId)
                end)
                return
            end
            
            debugLog('[ProjectilePhysics-DEBUG] Interact Called for: ' .. tostring(activatorId))
            
            local stuckData = stuckProjectileRegistry[activatorId]
            
            -- FALLBACK: If registry is missing (e.g. after load), try to parse the Record ID
            if not stuckData and data.object.recordId then
                 local rId = data.object.recordId
                 if rId:find("^pp_act_") or rId:find("^pp_s_") then
                     local _, _, extracted = rId:find("_[^_]+_(.+)")
                     if extracted then
                         debugLog('[ProjectilePhysics-DEBUG] Registry missing, parsing ID: ' .. extracted)
                         stuckData = {
                             target = nil, -- Lost reference to target on load, but we can still pickup
                             ammoRecordId = extracted,
                             isRecoverable = true
                         }
                     end
                 end
            end
            
            if not stuckData then 
                -- Silently return if no registry data found
                debugLog('[ProjectilePhysics-DEBUG] No registry data found for ' .. tostring(activatorId))
                return 
            end
            
            local targetHealth = stuckData.target and types.Actor.stats.dynamic.health(stuckData.target)
            local isDead = not stuckData.target or not stuckData.target:isValid() or (targetHealth and targetHealth.current <= 0)
            
            if not isDead then
                debugLog('[PICKUP] Cannot pick up arrow from living NPC')
                return
            end
            
            local pickupMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory')
            if pickupMode ~= 'activation' then 
                debugLog('[PICKUP] Interaction blocked: Not in activation mode.')
                return 
            end
            
            if not stuckData.isRecoverable then
                debugLog('[PICKUP] Arrow was destroyed on impact')
                async:newUnsavableSimulationTimer(0.1, function()
                    removeStuckProjectile(activatorId)
                end)
                return
            end
            
            -- Get player's marksman skill for success chance
            local marksmanSkill = 0
            if player and player:isValid() then
                pcall(function()
                    local skillStat = types.Player.stats.skills.marksman(player)
                    marksmanSkill = skillStat and skillStat.modified or 0
                end)
            end
            local successChance = math.min(marksmanSkill, 100)
            
            -- Roll for success
            local roll = math.random(100)
            local success = (roll <= successChance)
            
            if success and stuckData.ammoRecordId and player then
                 -- [REFACTORED PICKUP LOGIC]
                 local ammoId = stuckData.ammoRecordId
                 
                 -- Determine if it's a real world item (Weapon/Ammo) or a custom activator/VFX
                 local isRealItem = false
                 local activator = stuckData.activator
                 
                 if activator and activator:isValid() then
                     isRealItem = (activator.type == types.Ammunition or activator.type == types.Weapon)
                 end
                 
                 local itemName = ammoId
                 
                  -- 2. Handle Item Creation / Transfer
                  if isRealItem then
                       -- [ANIMATED PICKUP FIX] Manually transfer to inventory after a short delay
                       -- This allows AnimatedPickup to finish its animation while blocking engine pickup
                       local itemToMove = activator
                       async:newUnsavableSimulationTimer(0.1, function()
                           if itemToMove and itemToMove:isValid() and player and player:isValid() then
                               itemToMove:moveInto(types.Actor.inventory(player))
                           end
                       end)

                      -- Engine interactions handle real items usually.
                      -- We define name just for message.
                      local rec = types.Ammunition.records[ammoId] or types.Weapon.records[ammoId]
                      if rec then itemName = rec.name end
                 else
                      -- 3. Validate Ammo Record
                      local rec = types.Ammunition.records[ammoId] or types.Weapon.records[ammoId]
                      
                      if not rec then
                           -- [FALLBACK] If record lookup failed (e.g. types.Ammunition missing), 
                           -- we rely on createObject to fail if ID is truly invalid.
                           -- We keep itemName as ammoId.
                           debugLog('[PICKUP-WARN] Record lookup failed for ' .. tostring(ammoId) .. '. Proceeding with creation attempt.')
                       else
                           itemName = rec.name
                       end

                      
                      -- 4. Create Object
                      local newItem = world.createObject(ammoId, 1)
                      if not newItem then
                          debugLog('[PICKUP-FAIL] world.createObject failed for: ' .. tostring(ammoId))
                          player:sendEvent('ProjectilePhysics_ShowMessage', { msg = 'Projectile broke.' })
                          async:newUnsavableSimulationTimer(0.1, function()
                              removeStuckProjectile(activatorId)
                          end)
                          return
                      end
                      
                      -- 5. Transfer to Inventory
                      local playerInv = types.Actor.inventory(player)
                      if not playerInv then
                           debugLog('[PICKUP-FAIL] Player inventory not found!')
                           newItem:remove()
                           return
                      end
                      
                      newItem:moveInto(playerInv)
                 end
                 
                 player:sendEvent('ProjectilePhysics_ShowMessage', { msg = 'Recovered ' .. itemName })
                 debugLog(string.format('[PICKUP] Arrow recovered: %s (Roll: %d/%d)', ammoId, roll, successChance))
            else
                player:sendEvent('ProjectilePhysics_ShowMessage', { msg = 'Projectile broke.' })
                debugLog(string.format('[PICKUP] Failed to recover %s (Roll: %d/%d)', stuckData.ammoRecordId or 'unknown', roll, successChance))
            end
            
            -- Remove activator regardless of success (attempted pickup)
            async:newUnsavableSimulationTimer(0.1, function()
                removeStuckProjectile(activatorId)
            end)
        end,
        
        ProjectilePhysics_SyncSettings = function(data)
             -- Sync settings from Player script (MCM)
             for k,v in pairs(data) do settingsCache[k] = v end
             debugLog('Settings Synced from Player script')
             
             -- [NEW] Write to Global Storage so new Actors can read them immediately
             local syncStore = storage.globalSection('ProjectilePhysics_Sync')
             for k,v in pairs(data) do
                 syncStore:set(k, v)
             end
             
             -- Broadcast to all active actors so their local scripts can honor settings
             for _, actor in ipairs(world.activeActors) do
                 actor:sendEvent('ProjectilePhysics_SyncSettings', data)
             end
        end,
        
        ProjectilePhysics_RequestSettingsSync = function(data)
            local actorId = data.actorId
            local actor = nil
            for _, a in ipairs(world.activeActors) do
                if a.id == actorId then actor = a break end
            end
            if not actor then
                for _, p in ipairs(world.players) do
                    if p.id == actorId then actor = p break end
                end
            end
            
            if actor then
                actor:sendEvent('ProjectilePhysics_SyncSettings', settingsCache)
            end
        end,
        
        ProjectilePhysics_RequestVfxRefresh = function(data)
            local actor = data.actor
            if not actor then return end
            
            debugLog('[VFX-REFRESH] Refreshing VFX for ' .. tostring(actor.recordId))
            
            -- Find all VFX belonging to this actor in registry
            local foundCount = 0
            local actorObjId = actor.id
            for vfxId, regData in pairs(stuckProjectileRegistry) do
                if regData.type == 'vfx' and regData.target and regData.target.id == actorObjId then
                    -- Trigger Attachment Event Again
                    -- PRESERVE ID so we don't duplicate logic, just visual refresh
                    actor:sendEvent('ProjectilePhysics_AttachVfxArrow', {
                        model = regData.model,
                        relativePos = regData.relativePos,
                        relativeRot = regData.relativeRot,
                        -- Note: logicSurfacePos and surfaceRelativePosRaw missing from registry,
                        -- but AttachVfxArrow handler reconstructs them from relativePos if missing.
                        vfxId = vfxId,
                        lifetime = regData.lifetime,
                        useAmbientLight = false,
                        attacker = regData.attacker,
                        ammoRecordId = regData.ammoRecordId,
                        pickupMode = getSetting(settingsAdvanced, 'pickupMode', 'inventory'),
                        isRefresh = true -- IMPORANT: Flag to prevent new blood/sounds
                    })
                    foundCount = foundCount + 1
                end
            end
            debugLog('  Refreshed ' .. foundCount .. ' VFX items.')
        end,
        
        ProjectilePhysics_RemoveOneVfxByType = function(data)
            local actorId = data.actorId
            local recordId = data.recordId
            if not actorId or not recordId then return end
            
            local vfxData = actorVfxRegistry[actorId]
            if not vfxData then return end
            
            local recordIdLower = recordId:lower()
            local foundAmmoKey = nil
            for regId, _ in pairs(vfxData) do
                if regId:lower() == recordIdLower then
                    foundAmmoKey = regId
                    break
                end
            end
            
            if foundAmmoKey then
                local list = vfxData[foundAmmoKey]
                if #list > 0 then
                    local vfxId = list[1]
                    debugLog(string.format('[SYNC-REMOVE] Removing visual %s for actor %s', tostring(vfxId), tostring(actorId)))
                    removeStuckProjectile(vfxId)
                end
            end
        end,
        
        -- [SELF REMOVAL / ONE-BY-ONE]
        ProjectilePhysics_RemoveOneVfxFromTarget = function(data)
            local target = data.target
            local player = data.player
            if not target then return end
            
            debugLog('[REMOVE-SINGLE] Checking VFX for ' .. tostring(target.id))
            
            local vfxData = actorVfxRegistry[target.id]
            if not vfxData then
                debugLog('[REMOVE-SINGLE] No VFX data found in registry for ' .. tostring(target.id))
                -- [OPTIMIZATION] Filter tracking log to show only valid entries
                local keys = {}
                for k, v in pairs(actorVfxRegistry) do 
                    local hasVfx = false
                    for _, l in pairs(v) do if #l > 0 then hasVfx = true; break end end
                    if hasVfx then table.insert(keys, tostring(k)) end
                end
                debugLog('[REMOVE-SINGLE] Currently tracking actors with VFX: ' .. table.concat(keys, ', '))
            end
            
            if vfxData then
                -- Find first available VFX type that has entries
                for ammoId, list in pairs(vfxData) do
                    if #list > 0 then
                        local vfxId = list[1]
                        debugLog('[REMOVE-SINGLE] Removing one VFX: ' .. tostring(vfxId) .. ' from ' .. tostring(target.id))
                        removeStuckProjectile(vfxId)
                        if player == target then
                            player:sendEvent('ProjectilePhysics_ShowMessage', { msg = "Removed one projectile." })
                        end
                        return -- Only remove one per activation
                    end
                end
            end
            
            if player == target then
                player:sendEvent('ProjectilePhysics_ShowMessage', { msg = "No more projectiles to remove." })
            end
        end,
        
        -- [VIRTUAL HARVEST ALL]
        ProjectilePhysics_VirtualTryCollectFromActor = function(data)
            local from = data.rayFrom
            local to = data.rayTo
            local player = data.player
            if not from or not to or not player then return end
            
            local rayDir = (to - from):normalize()
            local bestDist = 120.0 -- [USER REQUEST] Forgiving detection radius (~50-80 units radius)
            local bestActor = nil
            
            -- Find nearest dead NPC/Creature to the ray
            for _, actor in ipairs(world.activeActors) do
                if actor ~= player then
                    local targetHealth = types.Actor.stats.dynamic.health(actor)
                    if targetHealth and targetHealth.current <= 0 then
                        local vec = actor.position - from
                        local projDist = vec:dot(rayDir)
                        
                        -- Check if in front and within reasonable distance
                        if projDist > 0 and projDist < 400 then
                            local perpDist = vec:cross(rayDir):length()
                            if perpDist < bestDist then
                                bestDist = perpDist
                                bestActor = actor
                            end
                        end
                    end
                end
            end
            
            if bestActor then
                debugLog('[VIRTUAL-HARVEST] Triggering harvest for nearby body: ' .. bestActor.recordId)
                core.sendGlobalEvent('ProjectilePhysics_TryCollectFromActor', { target = bestActor, player = player })
            end
        end,
        
        -- Handler for when local script processes hit via I.Combat.onHit
        ProjectilePhysics_LocalHitProcessed = function(data)
            debugLog('[PP-GLOBAL] Local Hit Processed - handling VFX/sticking')
            -- The damage was already applied by local script via I.Combat.onHit
            -- We just need to handle VFX attachment and projectile cleanup
            local target = data.target
            local projectile = data.projectile
            local hitPos = data.hitPos
            local velocity = data.velocity
            
            if not target or not projectile then return end
            
            -- Handle VFX sticking (reuse existing logic)
            local projData = placedProjectiles[projectile.id]
            if projData then
                -- Trigger VFX attachment via existing pathway
                target:sendEvent('ProjectilePhysics_AttachVfxArrow', {
                    recordId = projData.ammoRecordId,
                    hitPos = hitPos,
                    direction = (velocity and velocity:length() > 0) and velocity:normalize() or util.vector3(0, 1, 0),
                    attacker = data.attacker,
                    projectileType = projData.type
                })
                
                -- Mark as hit/processed and REMOVE physical object
                projData.hasHitActor = true
                
                -- NOTIFY ACTOR: Even if Combat API handled it, we send the event
                -- so the Actor script can run its manual enchantment fallbacks.
                -- We set combatHandled=true so it doesn't apply damage twice.
                target:sendEvent('ProjectilePhysics_ApplyDamage', {
                     damage = projData.damage or 0,
                     hitPos = hitPos,
                     attacker = data.attacker,
                     launcher = data.launcher,
                     ammoRecordId = projData.ammoRecordId,
                     projectile = projectile,
                     flightDir = velocity and velocity:length() > 0 and velocity:normalize() or util.vector3(0,1,0),
                     combatHandled = data.combatHandled, -- PROPAGATE FLAG
                     chargeRatio = projData.chargeRatio,
                     weaponRecordId = projData.weaponRecordId
                })

                if projectile:isValid() then
                    pcall(function() projectile:remove() end)
                end
                placedProjectiles[projectile.id] = nil
            end
        end,
        [D and D.e.UpdateVisPos or 'LuaPhysics_UpdateVisPos'] = function(pObjData)
            if not pObjData or not pObjData.object then return end
            
            local data = placedProjectiles[pObjData.object.id]
            if data and data.projectile and data.projectile:isValid() then
                -- Authoritative WABA v10 Orientation
                local newRot = getGlobalWabaRotation(data.projectile, data, pObjData.position, pObjData.velocity, false)
                local trailRot = getGlobalWabaRotation(data.projectile, data, pObjData.position, pObjData.velocity, true)
                
                if newRot then
                    -- AUTHORITATIVE OVERRIDE:
                    data.projectile:sendEvent(D.e.SetPhysicsProperties, { rotation = newRot })
                end
                
                -- Update active followers (VFX trails) with BALLISTIC rotation
                local pid = data.projectile.id
                local follower = activeFollowers[pid]
                if follower and follower:isValid() then
                    local cell = data.projectile.cell
                    local pos = pObjData.position
                    local rot = trailRot or newRot or data.projectile.rotation
                    async:newUnsavableSimulationTimer(0, function()
                         if follower:isValid() then
                             pcall(function() follower:teleport(cell, pos, rot) end)
                         end
                    end)
                end
            end
        end,

        -- Global fallback for enchantment casting (if local actor script lacks APIs)
        ProjectilePhysics_GlobalCastEnchant = function(data)
             local enchantId = data.enchantId
             local caster = data.caster
             local target = data.target
             if not enchantId or not target then return end
             
             debugLog("[PP-GLOBAL] Attempting global enchant cast: " .. enchantId)
             
             -- Note: core.magic is also limited in global scripts, but we might have 
             -- different permissions or future engine expansions here.
             if core.magic and core.magic.cast then
                  core.magic.cast(enchantId, caster, target)
                  debugLog("[PP-GLOBAL] Global core.magic.cast successful")
             end
        end,

        ProjectilePhysics_ConsumeAmmo = function(data)
             local item = data.item
             local count = data.count or 1
             local actor = data.actor
             
             if not item then return end
             
             if item:isValid() then
                 local success = false
                 local recordId = item.recordId
                 
                 local function triggerVfxSync()
                     if actor and actor:isValid() then
                         core.sendGlobalEvent('ProjectilePhysics_RemoveOneVfxByType', { actorId = actor.id, recordId = recordId })
                     end
                 end

                 -- STRATEGY 1: object:remove(count) (if supported)
                 pcall(function() 
                     item:remove(count) 
                     success = true 
                 end)
                 if success then 
                     triggerVfxSync()
                     return 
                 end
                 
                 -- STRATEGY 2: inventory:remove(item, count) (if actor provided)
                 if actor and actor:isValid() then
                     pcall(function()
                         local inv = types.Actor.inventory(actor)
                         inv:remove(item, count)
                         success = true
                     end)
                     if success then 
                         triggerVfxSync()
                         return 
                     end
                 end
                 
                 -- STRATEGY 3: Verify count, Remove Stack, Re-add (The Nuclear Option)
                 local ok, err = pcall(function()
                     local currentCount = item.count
                     local newCount = currentCount - count
                     
                     item:remove()
                     if newCount > 0 and actor and actor:isValid() then
                         local inv = types.Actor.inventory(actor)
                         inv:add(recordId, newCount)
                     end
                     success = true
                 end)
                 
                 if success then
                     triggerVfxSync()
                 else
                     debugLog('[PP-GLOBAL] ALL consumption strategies failed: ' .. tostring(err))
                 end
             end
        end,

        ProjectilePhysics_RemoveObject = function(obj)
             if obj and obj:isValid() then
                 -- Clean way to remove vanilla projectile upon collision
                 -- debugLog('[PP-GLOBAL] Removing vanilla projectile via collision request.')
                 pcall(function() obj:remove() end)
             end
        end,

        ProjectilePhysics_StripInventoryOnDeath = function(data)
            local actor = data.actor
            if not actor or not actor:isValid() then return end
            
            -- [REVISION 63] Use cache first, fallback to storage
            local pMode = settingsCache['pickupMode'] or getSetting(settingsAdvanced, 'pickupMode', 'inventory')
            if pMode ~= 'mass_harvest' and pMode ~= 'activation' then return end
            
            debugLog('[STRIP-DEATH] Stripping projectiles from ' .. tostring(actor.recordId) .. ' based on VFX registry.')
            
            local inv = types.Actor.inventory(actor)
            if not inv then return end
            
            -- Count how many of each ammoId we have stuck as VFX
            local vfxCounts = {}
            for vfxId, entry in pairs(stuckProjectileRegistry) do
                if entry.type == 'vfx' and entry.target and entry.target.id == actor.id then
                    local rid = (entry.ammoRecordId or ""):lower()
                    if rid ~= "" then
                        vfxCounts[rid] = (vfxCounts[rid] or 0) + 1
                    end
                end
            end
            
            -- Strip exactly that many from inventory to ensure parity with visual state
            for rid, count in pairs(vfxCounts) do
                local toRemove = count
                -- Iterate ALL items to handle split stacks
                for _, item in ipairs(inv:getAll()) do
                    if item.recordId:lower() == rid then
                        local amount = math.min(item.count, toRemove)
                        item:remove(amount)
                        toRemove = toRemove - amount
                        debugLog('  [STRIP] Removed ' .. amount .. 'x ' .. rid .. ' (VFX parity)')
                    end
                    if toRemove <= 0 then break end
                end
            end
        end,
        
        ProjectilePhysics_OnLootedFromInventory = function(data)
            
            local player = data.player -- Passed from actor or player script
            local searchId = (data.recordId or ""):lower()
            local count = data.count or 1
            local targetActor = data.actor
            
            if not player or searchId == "" or not targetActor or not targetActor:isValid() then return end
            
            -- Perform success roll using Marksman skill
            local marksmanSkill = 0
            pcall(function()
                local skillStat = types.Player.stats.skills.marksman(player)
                marksmanSkill = skillStat and skillStat.modified or 0
            end)
            
            local successChance = math.min(95, 20 + (marksmanSkill * 0.75))
            local vfxData = actorVfxRegistry[targetActor.id]
            local vfxList = (vfxData and vfxData[searchId]) or {}
            local vfxAvailable = #vfxList
            
            -- Only roll for items that were actually represented by VFX on the body
            local rollCount = math.min(count, vfxAvailable)
            if rollCount <= 0 then 
                debugLog('[LOOT-ROLL] Skipped: No VFX matching record ' .. searchId .. ' on actor.')
                return 
            end

            local brokenCount = 0
            local successCount = 0
            local isEnchanted = false
            local recoveryOn = getSetting(settingsGeneral, 'allowEnchantedRecovery', true)
            
            -- Check if the item is enchanted
            local rec = types.Ammunition.record(searchId) or types.Weapon.record(searchId)
            if rec and rec.enchant and rec.enchant ~= "" then
                isEnchanted = true
            end

            for i = 1, rollCount do
                -- [FORCED BREAK LOGIC]
                local forcedBreak = (isEnchanted and not recoveryOn)
                
                if forcedBreak then
                    brokenCount = brokenCount + 1
                    debugLog('  [LOOT-FORCED-BREAK] Enchanted item forced to break (Recovery Off)')
                elseif math.random(100) > successChance then
                    brokenCount = brokenCount + 1
                else
                    successCount = successCount + 1
                end
            end
            
            -- 1. If failed: remove the broken items from player's inventory
            if brokenCount > 0 then
                local inv = types.Actor.inventory(player)
                local actuallyRemoved = 0
                
                -- Attempt splitter-assisted removal for stacks
                for _, item in ipairs(inv:getAll()) do
                    if item.recordId:lower() == searchId then
                        local toRemove = math.min(item.count, brokenCount)
                        local splitItem = item:split(toRemove)
                        if splitItem then
                            splitItem:remove()
                            actuallyRemoved = actuallyRemoved + toRemove
                            brokenCount = brokenCount - toRemove
                        end
                        if brokenCount <= 0 then break end
                    end
                end

                if actuallyRemoved > 0 then
                    debugLog(string.format('[LOOT-BREAK] Successfully removed %d x %s from player inventory stack.', actuallyRemoved, searchId))
                    player:sendEvent('ProjectilePhysics_ShowMessage', { msg = string.format("Accidentally broke %d items.", actuallyRemoved) })
                    core.sound.playSound3d("Item Misc Up", player, {pitch=0.6, volume=0.8})
                else
                    debugLog('[LOOT-BREAK] WARNING: Roll failed but failed to find or split item %s in player inventory!', searchId)
                end
            end
            -- 2. Remove corresponding VFX from the actor
            if targetActor and targetActor:isValid() then

                local removedVfx = 0
                -- We remove the full number of items rolled for, since they are all removed from the body
                -- This happens for BOTH successful and failed (broken) items.
                for i = 1, rollCount do
                    local found = false
                    -- Re-fetch lists as removeStuckProjectile mutates them
                    local latestVfxData = actorVfxRegistry[targetActor.id]
                    if latestVfxData then
                        -- Check for exact match (ammoId)
                        if latestVfxData[searchId] and #latestVfxData[searchId] > 0 then
                            local vfxId = latestVfxData[searchId][1]
                            removeStuckProjectile(vfxId)
                            found = true
                        end
                        
                        -- Fallback to ANY VFX on that actor if exact match is empty/absent
                        if not found then
                            for ammoId, list in pairs(latestVfxData) do
                                if #list > 0 then
                                    local vfxId = list[1]
                                    removeStuckProjectile(vfxId)
                                    found = true
                                    break
                                end
                            end
                        end
                    end
                    if found then removedVfx = removedVfx + 1 else break end
                end
                
                if removedVfx > 0 then
                     debugLog(string.format('[LOOT-ROLL] Removed %d VFX from %s due to inventory looting roll (%d success, %d broken)', 
                        removedVfx, targetActor.recordId or "Actor", successCount, actuallyRemoved))
                     
                     -- Unified message for salvage status
                     local msg = string.format("Salvaged %d items.", successCount)
                     if actuallyRemoved > 0 then
                         msg = string.format("Salvaged %d items (%d broke).", successCount, actuallyRemoved)
                     end
                     player:sendEvent('ProjectilePhysics_ShowMessage', { msg = msg })
                end
            end
        end,
    },
}
