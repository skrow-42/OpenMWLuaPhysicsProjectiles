-- ProjectilePhysicsActor.lua
-- NPC-side script to handle bone tracking and damage
local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local anim = require('openmw.animation')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local async = require('openmw.async')
local nearby = require('openmw.nearby')
local storage = require('openmw.storage')
local AnimController = require('openmw.interfaces').AnimationController


-- Pre-calculated bone transforms for each death animation (Death1-5)
local poseTransforms = require('scripts.ProjectilePhysics.poseTransforms')

-- Forward declarations for script-wide visibility
local getBoneWorldPos
local getBoneAnimatedPos
local getBoneAnimatedRot
local getActorRaceScales
local getDeathAnimationType

-- Forward declarations for data tables
local BONE_CATEGORIES = {
    ["Bip01 Arrow Bone 086"] = "Head",
    ["Bip01 Arrow Bone 090"] = "Head",
    ["Bip01 Arrow Bone 092"] = "Head",
    ["Bip01 Arrow Bone 084"] = "Head",
    ["Bip01 Arrow Bone 091"] = "Head",
    ["Bip01 Arrow Bone 087"] = "Head",
    ["Bip01 Arrow Bone 085"] = "Head",
    ["Bip01 Arrow Bone 089"] = "BackHead",
    ["Bip01 Arrow Bone 083"] = "Head",
    ["Bip01 Arrow Bone 073"] = "Head",
    ["Bip01 Arrow Bone 080"] = "Head",
    ["Bip01 Arrow Bone 072"] = "Head",
    ["Bip01 Arrow Bone 088"] = "Head",
    ["Bip01 Arrow Bone 079"] = "Head",
    ["Bip01 Arrow Bone 071"] = "Head",
    ["Bip01 Arrow Bone 082"] = "Head",
    ["Bip01 Arrow Bone 074"] = "Head",
    ["Bip01 Arrow Bone 070"] = "Head",
    ["Bip01 Arrow Bone 069"] = "Head",
    ["Bip01 Arrow Bone 076"] = "Head",
    ["Bip01 Arrow Bone 081"] = "Head",
    ["Bip01 Arrow Bone 077"] = "Head",
    ["Bip01 Arrow Bone 075"] = "Head",
    ["Bip01 Arrow Bone 068"] = "BackHead",
    ["Bip01 Arrow Bone 062"] = "Head",
    ["Bip01 Arrow Bone 064"] = "Head",
    ["Bip01 Arrow Bone 078"] = "BackHead",
    ["Bip01 Arrow Bone 061"] = "Head",
    ["Bip01 Arrow Bone 066"] = "BackHead",
    ["Bip01 Arrow Bone 065"] = "BackHead",
    ["Bip01 Arrow Bone 054"] = "BackHead",
    ["Bip01 Arrow Bone 060"] = "Head",
    ["Bip01 Arrow Bone 052"] = "BackHead",
    ["Bip01 Arrow Bone 059"] = "Head",
    ["Bip01 Arrow Bone 058"] = "Head",
    ["Bip01 Arrow Bone 051"] = "Back",
    ["Bip01 Arrow Bone 057"] = "Torso",
    ["Bip01 Arrow Bone 067"] = "Back",
    ["Bip01 Arrow Bone 197"] = "LArm",
    ["Bip01 Arrow Bone 063"] = "Torso",
    ["Bip01 Arrow Bone 056"] = "Torso",
    ["Bip01 Arrow Bone 053"] = "Back",
    ["Bip01 Arrow Bone 031"] = "Back",
    ["Bip01 Arrow Bone 055"] = "Back",
    ["Bip01 Arrow Bone 189"] = "RArm",
    ["Bip01 Arrow Bone 036"] = "Back",
    ["Bip01 Arrow Bone 032"] = "Back",
    ["Bip01 Arrow Bone 041"] = "Back",
    ["Bip01 Arrow Bone 202"] = "LArm",
    ["Bip01 Arrow Bone 011"] = "Torso",
    ["Bip01 Arrow Bone 040"] = "Back",
    ["Bip01 Arrow Bone 050"] = "Torso",
    ["Bip01 Arrow Bone 006"] = "Torso",
    ["Bip01 Arrow Bone 018"] = "Torso",
    ["Bip01 Arrow Bone 010"] = "Torso",
    ["Bip01 Arrow Bone 034"] = "Back",
    ["Bip01 Arrow Bone 190"] = "RArm",
    ["Bip01 Arrow Bone 005"] = "Torso",
    ["Bip01 Arrow Bone 198"] = "LArm",
    ["Bip01 Arrow Bone 030"] = "Back",
    ["Bip01 Arrow Bone 042"] = "Back",
    ["Bip01 Arrow Bone 049"] = "RArm",
    ["Bip01 Arrow Bone 027"] = "Back",
    ["Bip01 Arrow Bone 012"] = "Torso",
    ["Bip01 Arrow Bone 026"] = "Torso",
    ["Bip01 Arrow Bone 048"] = "Torso",
    ["Bip01 Arrow Bone 004"] = "Torso",
    ["Bip01 Arrow Bone 203"] = "LArm",
    ["Bip01 Arrow Bone 002"] = "Torso",
    ["Bip01 Arrow Bone 039"] = "Back",
    ["Bip01 Arrow Bone 025"] = "Back",
    ["Bip01 Arrow Bone 007"] = "Torso",
    ["Bip01 Arrow Bone 017"] = "Torso",
    ["Bip01 Arrow Bone 199"] = "LArm",
    ["Bip01 Arrow Bone 028"] = "Back",
    ["Bip01 Arrow Bone 022"] = "Torso",
    ["Bip01 Arrow Bone 019"] = "Torso",
    ["Bip01 Arrow Bone 035"] = "Back",
    ["Bip01 Arrow Bone 191"] = "RArm",
    ["Bip01 Arrow Bone 194"] = "RArm",
    ["Bip01 Arrow Bone 047"] = "Torso",
    ["Bip01 Arrow Bone 043"] = "Back",
    ["Bip01 Arrow Bone 008"] = "Torso",
    ["Bip01 Arrow Bone 001"] = "Torso",
    ["Bip01 Arrow Bone 038"] = "Back",
    ["Bip01 Arrow Bone 200"] = "LArm",
    ["Bip01 Arrow Bone 033"] = "Back",
    ["Bip01 Arrow Bone 016"] = "Torso",
    ["Bip01 Arrow Bone 024"] = "Back",
    ["Bip01 Arrow Bone 204"] = "LArm",
    ["Bip01 Arrow Bone 045"] = "Torso",
    ["Bip01 Arrow Bone 013"] = "Torso",
    ["Bip01 Arrow Bone 000"] = "Torso",
    ["Bip01 Arrow Bone 037"] = "Back",
    ["Bip01 Arrow Bone 029"] = "Back",
    ["Bip01 Arrow Bone 021"] = "Torso",
    ["Bip01 Arrow Bone 009"] = "Torso",
    ["Bip01 Arrow Bone 020"] = "Torso",
    ["Bip01 Arrow Bone 046"] = "Torso",
    ["Bip01 Arrow Bone 074"] = "Torso",
}

local BONES
local BONE_GROUPS
local boneOccupancy

-- Combat API wrapper with hit-position-based armor durability
local CombatAPI = require('scripts.ProjectilePhysics.combat_api_wrapper')

local Actor = types.Actor
local NPC   = types.NPC
local Armor = types.Armor
local Item  = types.Item
local SLOT = Actor.EQUIPMENT_SLOT

-- Optimized constants
-- Cached health stat accessor (call only once per actor lifetime)
local LPP_STATE = {
    isRangedCombatActive = false,
    activityCheckTime = 0,
    trackedProjectileCount = 0,
    stuckVfxCount = 0,
    scriptActive = false,
    nextActivityCheck = 0,
    hasRangedWeaponInInventory = nil,
    isCreatureNonBiped = nil,
    inventoryCheckDone = false,
    neverUsesRanged = nil,
    vfxConvertedOnDeath = false,
    murderReported = false,
    cachedIsDead = false,
    hasSpawnedOnDeath = false,
    hasLoggedDeath = false,
    settingsInitialized = false,
    zeroHealthStartTime = nil,
    deathBoneCaptureScheduled = false,
    lastAttacker = nil,
    lastAttackerTime = 0,
    IDLE_CHECK_INTERVAL = 2.0,
    ACTIVE_CHECK_INTERVAL = 0.25,
    getHealth = self.type.stats.dynamic.health,
    lastInvSyncTime = 0,
    lastHealthCheck = 0,
    cachedAmmoCounts = {},
}

-- [CORE TRACKING TABLES]
local trackedProjectiles = {}
local stuckVfxRegistry = {}
local boneOccupancy = {}
local stateCache = { deathAnim = nil, heightFactor = nil, lastHeightUpdate = 0 }

-- [DEATH ANIM DURATIONS] Known animation lengths for precise bone capture timing
local DEATH_ANIM_DURATIONS = {
    Death1 = 2.666,
    Death2 = 2.400,
    Death3 = 3.199,
    Death4 = 2.666,
    Death5 = 2.533,
}
local weaponRecordCache = {}
local raceScaleCache = {}

-- Debug logging
local settingsCache = {}

local function debugLog(message)
    if settingsCache.debugMode then
        print('[ProjectilePhysics Actor] ' .. message)
    end
end

-- ═══════════════════════════════════════════════════════════════════
-- [PHASE 3] Comprehensive State Logging
-- ═══════════════════════════════════════════════════════════════════
local function debugTransformState(label, targetBone)
    if not settingsCache or not settingsCache.debugMode then return end
    
    debugLog("════════════════════════════ [PP-DEBUG-TRANSFORM] ════════════════════════════")
    debugLog(string.format("[%s] Actor: %s (%s)", label, tostring(self.recordId), tostring(self.id)))
    debugLog(string.format("[%s] Position: %s | Rotation: %s | Scale: %.2f", 
        label, tostring(self.position), tostring(self.rotation), self.scale or 1.0))
    
    local deathAnim = getDeathAnimationType()
    debugLog(string.format("[%s] Death Anim: %s", label, tostring(deathAnim)))
    
end
-- ============================================================================
-- HELPER FUNCTIONS FOR TRACKING WITH COUNTS
-- ============================================================================

local function addTrackedProjectile(projectileId, data)
    if not trackedProjectiles[projectileId] then
        LPP_STATE.trackedProjectileCount = LPP_STATE.trackedProjectileCount + 1
    end
    trackedProjectiles[projectileId] = data
    LPP_STATE.scriptActive = true
end

local function removeTrackedProjectile(projectileId)
    if trackedProjectiles[projectileId] then
        trackedProjectiles[projectileId] = nil
        LPP_STATE.trackedProjectileCount = math.max(0, LPP_STATE.trackedProjectileCount - 1)
    end
end

local function addStuckVfx(vfxId, data)
    if not stuckVfxRegistry[vfxId] then
        LPP_STATE.stuckVfxCount = LPP_STATE.stuckVfxCount + 1
    end
    stuckVfxRegistry[vfxId] = data
    LPP_STATE.scriptActive = true
end

local function removeStuckVfx(vfxId)
    if stuckVfxRegistry[vfxId] then
        local entry = stuckVfxRegistry[vfxId]
        if entry.boneName and boneOccupancy[entry.boneName] then
            boneOccupancy[entry.boneName] = math.max(0, boneOccupancy[entry.boneName] - 1)
        end
        stuckVfxRegistry[vfxId] = nil
        LPP_STATE.stuckVfxCount = math.max(0, LPP_STATE.stuckVfxCount - 1)
    end
end

-- ============================================================================
-- [OPTIMIZATION] ONE-TIME INVENTORY CHECK FOR RANGED WEAPONS
-- ============================================================================

local function checkInventoryForRangedWeapons()
    if LPP_STATE.inventoryCheckDone then
        return LPP_STATE.hasRangedWeaponInInventory
    end
    
    LPP_STATE.inventoryCheckDone = true
    LPP_STATE.hasRangedWeaponInInventory = false
    
    -- Get actor's inventory
    local inv = Actor.inventory(self)
    if not inv then return false end
    
    -- Check for Bows/Crossbows/Thrown weapons
    local found = false
    local rangedTypes = { 
        [types.Weapon.TYPE.MarksmanBow] = true, 
        [types.Weapon.TYPE.MarksmanCrossbow] = true, 
        [types.Weapon.TYPE.MarksmanThrown] = true 
    }
    
    local weapons = inv:getAll(types.Weapon)
    for _, w in ipairs(weapons) do
        local rec = types.Weapon.record(w)
        if rec and rangedTypes[rec.type] then
            found = true
            break
        end
    end
    
    if found then
        LPP_STATE.hasRangedWeaponInInventory = true
    end
    
    if LPP_STATE.hasRangedWeaponInInventory then
        debugLog('[PP-ACTOR] Inventory check: FOUND ranged weapon for ' .. tostring(self.recordId))
    else
        debugLog('[PP-ACTOR] Inventory check: NO ranged weapons for ' .. tostring(self.recordId))
    end
    
    return LPP_STATE.hasRangedWeaponInInventory
end

-- Force re-check inventory (called when VFX is attached)
local function forceInventoryRecheck()
    LPP_STATE.inventoryCheckDone = false
    LPP_STATE.hasRangedWeaponInInventory = nil
    checkInventoryForRangedWeapons()
end

-- ============================================================================
-- [OPTIMIZATION] CHECK IF CREATURE CAN EVER USE RANGED (BIPED CHECK)
-- ============================================================================

local function checkIfCreatureCannotUseRanged()
    if LPP_STATE.isCreatureNonBiped ~= nil then
        return LPP_STATE.isCreatureNonBiped
    end
    
    if self.type ~= types.Creature then
        LPP_STATE.isCreatureNonBiped = false
        return false
    end
    
    local ok, record = pcall(function() return types.Creature.record(self) end)
    if ok and record and record.type then
        -- types.Creature.TYPE: 0=Creatures, 1=Daedra, 2=Undead, 3=Humanoid
        -- Non-bipedal creatures (type > 2) cannot use ranged weapons
        if record.type > 2 then
            LPP_STATE.isCreatureNonBiped = true
            debugLog('[PP-ACTOR] Creature type ' .. record.type .. ' cannot use ranged: ' .. tostring(self.recordId))
            return true
        end
    end
    
    isCreatureNonBiped = false
    return false
end

-- ============================================================================
-- [OPTIMIZATION] MASTER ELIGIBILITY CHECK
-- Combines biped check + inventory check for one-time determination
-- ============================================================================

local function isActorEligibleForRangedProcessing()
    -- Creatures that physically can't use ranged weapons
    if checkIfCreatureCannotUseRanged() then
        return false
    end
    
    -- Actors without any ranged weapons in inventory
    if not checkInventoryForRangedWeapons() then
        return false
    end
    
    return true
end

-- ========================================
-- KNOCKDOWN CONFIGURATION
-- ========================================
local KNOCKDOWN_CONFIG = {
    -- Formula tuning (based on community research)
    -- Knockdown chance = (FinalDamage * DamageMultiplier + StrengthBonus - AgilityReduction) / Divisor
    damageMultiplier = 1.0,           -- How much damage affects chance
    strengthFactor = 0.5,             -- How much attacker strength adds
    agilityFactor = 1.0,              -- How much defender agility reduces chance
    divisor = 40,                     -- Overall scaling divisor (higher = less knockdowns)
    
    -- Immunity threshold
    immunityAgility = 100,            -- 100 Agility = immune to knockdown
    
    -- Knockdown effects
    damageMultiplierWhileDown = 1.5,  -- 50% more physical damage while knocked down
    evasionWhileDown = 0,             -- Evasion set to 0 while down
    
    -- Animations
    knockdownAnim = 'knockdown',
    knockoutAnim = 'knockout',
    
    -- Default knockdown duration (if can't read from animation)
    defaultDuration = 2.5,
}

-- ========================================
-- KNOCKDOWN STATE TRACKING
-- ========================================
local isKnockedDown = false
local knockdownEndTime = 0
local pendingSuppressEnchantId = nil
local pendingSuppressExpiry    = 0
-- ============================================================================
-- RACE SCALING SYSTEM (Height & Weight)
-- ============================================================================

-- Cache for race scales to avoid repeated record lookups
local raceScaleCache = {}
local weaponRecordCache = {} -- [CRITICAL] Instance-local cache to prevent cross-NPC contamination

-- Exact racial scaling factors from provided OAAB/Vanilla data image
-- Format: mh/mw (Male Height/Weight), fh/fw (Female Height/Weight)
local REFERENCE_RACE_STATS = {
    ["t_els_dagi-raht"]      = { mh = 0.89, mw = 0.89, fh = 0.86, fw = 0.88 },
    ["t els ohmes"]          = { mh = 0.92, mw = 0.95, fh = 0.90, fw = 0.90 },
    ["t_els_suthay"]         = { mh = 0.93, mw = 0.95, fh = 0.90, fw = 0.90 },
    ["breton"]               = { mh = 1.00, mw = 1.00, fh = 0.95, fw = 0.90 },
    ["khajiit"]              = { mh = 1.00, mw = 1.00, fh = 0.95, fw = 0.95 },
    ["t_els_ohmes-raht"]     = { mh = 1.00, mw = 1.00, fh = 0.95, fw = 0.95 },
    ["ynesai"]               = { mh = 1.00, mw = 1.00, fh = 0.95, fw = 0.90 },
    ["t_cnq_keptu"]          = { mh = 1.00, mw = 1.15, fh = 0.98, fw = 1.02 },
    ["wood elf"]             = { mh = 0.90, mw = 0.95, fh = 1.00, fw = 0.90 },
    ["dark elf"]             = { mh = 1.00, mw = 1.00, fh = 1.00, fw = 0.90 },
    ["imperial"]             = { mh = 1.00, mw = 1.25, fh = 1.00, fw = 0.95 },
    ["redguard"]             = { mh = 1.02, mw = 1.10, fh = 1.00, fw = 1.00 },
    ["argonian"]             = { mh = 1.03, mw = 1.10, fh = 1.00, fw = 1.00 },
    ["t_sky_reachman"]       = { mh = 1.04, mw = 1.15, fh = 1.02, fw = 1.00 },
    ["t_hr_riverfolk"]       = { mh = 1.03, mw = 1.03, fh = 1.03, fw = 1.00 },
    ["orc"]                  = { mh = 1.05, mw = 1.35, fh = 1.05, fw = 1.10 },
    ["t_cnq_chimeriquey"]    = { mh = 1.05, mw = 1.05, fh = 1.05, fw = 1.00 },
    ["t_pya_seaelf"]         = { mh = 1.05, mw = 1.00, fh = 1.05, fw = 1.00 },
    ["nord"]                 = { mh = 1.06, mw = 1.25, fh = 1.06, fw = 1.00 },
    ["t_els_cathay"]         = { mh = 1.10, mw = 1.15, fh = 1.06, fw = 1.10 },
    ["high elf"]             = { mh = 1.10, mw = 1.00, fh = 1.10, fw = 1.00 },
    ["t_val_imga"]           = { mh = 1.10, mw = 1.20, fh = 1.10, fw = 1.17 },
    ["t_mw_malahk_orc"]      = { mh = 1.12, mw = 1.80, fh = 1.12, fw = 1.70 },
    ["t_els_cathay-raht"]    = { mh = 1.20, mw = 1.40, fh = 1.15, fw = 1.25 },
    ["t_sky_hill_giant"]     = { mh = 1.86, mw = 2.00, fh = 1.84, fw = 1.95 },
}

getActorRaceScales = function(actor)
    if not actor then return { height = 1.0, weight = 1.0 } end
    
    local instanceScale = actor.scale or 1.0
    if actor.type ~= types.NPC and actor.type ~= types.Player then
        -- Creatures or others use default instance scale
        return { height = instanceScale, weight = instanceScale }
    end

    local id = actor.id
    if raceScaleCache[id] then 
        local cached = raceScaleCache[id]
        return { height = cached.height * instanceScale, weight = cached.weight * instanceScale }
    end

    local finalRaceScales = { height = 1.0, weight = 1.0 }
    local scaleSource = "default"
    
    local ok = pcall(function()
        local record = types.NPC.record(actor)
        if not record or not record.race then return end
        
        local raceId = record.race:lower()
        local isMale = record.isMale
        if isMale == nil then isMale = true end
        
        -- 1. Try dynamic API (types.NPC.races)
        local races = types.NPC.races
        if races then
            local raceRecord = races.record(raceId)
            if raceRecord then
                local h, w = nil, nil
                if isMale then
                    h = raceRecord.height and raceRecord.height.male
                    w = raceRecord.weight and raceRecord.weight.male
                else
                    h = raceRecord.height and raceRecord.height.female
                    w = raceRecord.weight and raceRecord.weight.female
                end
                if h then finalRaceScales.height = h end
                if w then finalRaceScales.weight = w end
                if h or w then scaleSource = "API" end
            end
        end
        
        -- 2. Fallback: hardcoded table (only if API returned nothing)
        if scaleSource == "default" then
            local ref = REFERENCE_RACE_STATS[raceId]
            if ref then
                finalRaceScales.height = isMale and ref.mh or ref.fh
                finalRaceScales.weight = isMale and ref.mw or ref.fw
                scaleSource = "table"
            end
        end
    end)
    
    debugLog(string.format("[RACE-SCALE] %s -> H=%.3f W=%.3f (src=%s, instScale=%.2f)",
        tostring(actor.recordId), finalRaceScales.height, finalRaceScales.weight, scaleSource, instanceScale))
    
    raceScaleCache[id] = { height = finalRaceScales.height, weight = finalRaceScales.weight }
    
    return { 
        height = finalRaceScales.height * instanceScale, 
        weight = finalRaceScales.weight * instanceScale 
    }
end



-- ============================================================================
-- NPC SUPPRESSION SYSTEM (FIXED - Robust Double Projectile Prevention)
-- ============================================================================
local lastShotTriggerTime = 0

-- [DYNAMIC SETTINGS] Pull settings from Global Storage (populated by Global script from Player MCM)
local function getSection(name)
    local s = storage.globalSection(name)
    -- Check for a known key to see if this section is actually populated
    -- We prefer CamelCase as it matches registration and player script
    if s and (s:get('enableProjectilePhysics') ~= nil or s:get('pickupMode') ~= nil) then
        return s
    end
    -- Fallback to lowercase (what global uses)
    local sLow = storage.globalSection(name:lower())
    if sLow and (sLow:get('enableProjectilePhysics') ~= nil or sLow:get('pickupMode') ~= nil) then
        return sLow
    end
    return s -- Fallback to original if neither have data yet
end

local settingsGeneral = getSection('SettingsProjectilePhysics')
local settingsAdvanced = getSection('SettingsProjectilePhysicsAdvanced')
local settingsVelocity = getSection('SettingsProjectilePhysicsVelocity')

local function getSyncSetting(section, key, default)
    if not section then return default end
    local val = section:get(key)
    if val == nil then val = section:get(key:lower()) end
    return val == nil and default or val
end

local settingsCache = {
    enableNPCSupport = getSyncSetting(settingsGeneral, 'enableNPCSupport', true),
    enableProjectilePhysics = getSyncSetting(settingsGeneral, 'enableProjectilePhysics', true),
    enableProjectileSticking = getSyncSetting(settingsGeneral, 'enableProjectileSticking', true),
    enableBounceDamage = getSyncSetting(settingsGeneral, 'enableBounceDamage', true),
    hitDetectionMode = getSyncSetting(settingsAdvanced, 'hitDetectionMode', 'vanilla'),
    debugMode = getSyncSetting(settingsGeneral, 'debugMode', false),
    pickupMode = getSyncSetting(settingsAdvanced, 'pickupMode', 'inventory'),
    enableProjectileBlocking = getSyncSetting(settingsGeneral, 'enableProjectileBlocking', true),
    projectileLifetime = getSyncSetting(settingsGeneral, 'projectileLifetime', 300),
    breakChance = getSyncSetting(settingsGeneral, 'breakChance', 25),
    bounceDamageMultiplier = getSyncSetting(settingsGeneral, 'bounceDamageMultiplier', 10),
    playerHitBehavior = getSyncSetting(settingsGeneral, 'playerHitBehavior', 'stick'),
    enableSkillBasedRecoil = getSyncSetting(settingsGeneral, 'enableSkillBasedRecoil', false),
    maxRecoil = getSyncSetting(settingsGeneral, 'maxRecoil', 0.18),
    rangedOnUseToOnStrike = getSyncSetting(settingsAdvanced, 'rangedOnUseToOnStrike', true),
}
local lastSettingsRefreshTime = 0
local function refreshSettingsCache()
    -- Re-acquire sections with robust casing check
    settingsGeneral = getSection('SettingsProjectilePhysics')
    settingsAdvanced = getSection('SettingsProjectilePhysicsAdvanced')

    settingsCache.enableNPCSupport = getSyncSetting(settingsGeneral, 'enableNPCSupport', true)
    settingsCache.enableProjectilePhysics = getSyncSetting(settingsGeneral, 'enableProjectilePhysics', true)
    settingsCache.enableProjectileSticking = getSyncSetting(settingsGeneral, 'enableProjectileSticking', true)
    settingsCache.enableBounceDamage = getSyncSetting(settingsGeneral, 'enableBounceDamage', true)
    settingsCache.hitDetectionMode = getSyncSetting(settingsAdvanced, 'hitDetectionMode', 'vanilla')
    settingsCache.debugMode = getSyncSetting(settingsGeneral, 'debugMode', false)
    settingsCache.pickupMode = getSyncSetting(settingsAdvanced, 'pickupMode', 'inventory')
    settingsCache.enableProjectileBlocking = getSyncSetting(settingsGeneral, 'enableProjectileBlocking', true)
    settingsCache.projectileLifetime = getSyncSetting(settingsGeneral, 'projectileLifetime', 300)
    settingsCache.breakChance = getSyncSetting(settingsGeneral, 'breakChance', 25)
    settingsCache.bounceDamageMultiplier = getSyncSetting(settingsGeneral, 'bounceDamageMultiplier', 10)
    settingsCache.playerHitBehavior = getSyncSetting(settingsGeneral, 'playerHitBehavior', 'stick')
    settingsCache.enableSkillBasedRecoil = getSyncSetting(settingsGeneral, 'enableSkillBasedRecoil', false)
    settingsCache.maxRecoil = getSyncSetting(settingsGeneral, 'maxRecoil', 0.18)
    settingsCache.rangedOnUseToOnStrike = getSyncSetting(settingsAdvanced, 'rangedOnUseToOnStrike', true)
    settingsCache.enableLocationalDamage = getSyncSetting(settingsGeneral, 'enableLocationalDamage', true)
    settingsCache.arrowSpeed = getSyncSetting(settingsVelocity, 'arrowSpeed', 3500)
    settingsCache.boltSpeed = getSyncSetting(settingsVelocity, 'boltSpeed', 4000)
    settingsCache.thrownSpeed = getSyncSetting(settingsVelocity, 'thrownSpeed', 2000)
    
    if not settingsInitialized and settingsCache.debugMode then
        print(string.format("[ProjectilePhysics Actor] Settings Initialized. Sections: General=%s, Advanced=%s | pickupMode=%s", 
            tostring(settingsGeneral ~= nil), tostring(settingsAdvanced ~= nil), tostring(settingsCache.pickupMode)))
    end
end
local settingsInitialized = false

-- Track the NPC's attack state via self.controls
local selfModule = require('openmw.self')

-- [CRITICAL FIX]: Use continuous onFrame suppression, not just text key
local attackStartTime = nil -- When the NPC started charging the attack
local lastNpcFireTime = 0 -- [USER REQUEST] Per-NPC shot cooldown
local creatureAttackStage = nil -- [NEW] Track animation keys for types.Creature
local suppressedPType = nil -- [NEW] Track if current suppression is arrow/bolt/thrown
local npcAnimReleaseTrigger = false -- [NEW] Catch release frames for better timing

-- [USER CONFIG] Weapon Timing Configurations
-- Based on animation keyframes (relative to Shoot Start = 0.00):
-- Bow: Min Attack @ 0.93s, Max Attack @ 1.33s, Vanilla Release @ 1.47s
local NPC_WEAPON_TIMINGS = {
    arrow = {
        minAttackTime = 0.00,
        maxAttackTime = 1.33,
        vanillaReleaseTime = 1.47, -- Vanilla event time
        releaseMinTime = 0.00,
        releaseMaxTime = 1.46,    -- [FIX] Was 1.40, widened to prevent 0.1s early cancellation
        
        -- Logic Timers
        minHoldTime = 0.96, --0.88
        manualMinTime = 0.96, --0.90
        
        shotLockout = 1.45,       -- [FIX] Was 1.2, matched to new releaseMaxTime
        recoveryDelay = 0.10
    },
    bolt = {
        minAttackTime = 0.00,
        maxAttackTime = 1.00,
        vanillaReleaseTime = 1.20,
        releaseMinTime = 0.00,
        releaseMaxTime = 1.10,
        minHoldTime = 0.00, -- Zeroed for NPCs to ensure firing
        manualMinTime = 0.00,
        shotLockout = 1.5,
        recoveryDelay = 0.50
    },
    thrown = {
        minAttackTime = 0.00,
        maxAttackTime = 0.60,
        vanillaReleaseTime = 0.80,
        releaseMinTime = 0.00,
        releaseMaxTime = 0.70,
        minHoldTime = 0.30,
        manualMinTime = 0.30,
        shotLockout = 0.8,
        recoveryDelay = 0.30
    }
}


-- Per-NPC randomized target release time (set when attack starts)
local targetReleaseTime = nil


getBoneWorldPos = function(actor, boneName)

    -- 2. Fallback: Use the reference coordinate from the BONES table
    local rigLocalCoord = BONES[boneName]
    if rigLocalCoord then
        return actor.position + (actor.rotation * rigLocalCoord)
    end
    
    -- 3. Ultimate Fallback (Legacy)
    local h = 100
    if boneName:find("Head") then h = 120
    elseif boneName:find("Spine") then h = 65
    elseif boneName:find("Pelvis") then h = 50 
    end
    return actor.position + util.vector3(0, 0, h)
end

getBoneAnimatedPos = function(actor, boneName)

    -- [DEAD ACTOR OVERRIDE]: OpenMW's live bone tracking is visually inaccurate for dead corpses.
    if actor.type.stats.dynamic.health(actor).current <= 0 then
        local deathAnim = getDeathAnimationType()
        if deathAnim and poseTransforms[deathAnim] and poseTransforms[deathAnim][boneName] then
            return actor.rotation * poseTransforms[deathAnim][boneName].position + actor.position, true
        end
     end

    return getBoneWorldPos(actor, boneName), false
end

getBoneAnimatedRot = function(actor, boneName)

    -- [DEAD ACTOR OVERRIDE]: Prioritize poseTransforms rotations for ragdolls
    if actor.type.stats.dynamic.health(actor).current <= 0 then
        local deathAnim = getDeathAnimationType()
        if deathAnim and poseTransforms[deathAnim] and poseTransforms[deathAnim][boneName] then
            return actor.rotation * poseTransforms[deathAnim][boneName].rotation, true
        end
     end

    return actor.rotation, false
end

local function verifyBone(actor, boneName)

    local actorPos = actor.position
    local distToRoot = (pos - actorPos):length()
    if distToRoot < 0.01 then
        return false
    end
    
end

local function superCast(enchantId, caster, target, itemObj, hitPosition, isAoe)
    if not enchantId or enchantId == "" then 
        return false 
    end
    
    if not target or not types.Actor.activeSpells then
        return false
    end
    
    local activeSpells = types.Actor.activeSpells(target)
    if not activeSpells or not activeSpells.add then 
        return false 
    end

    -- 1. Get the enchantment record
    local enchant = nil
    if core.magic and core.magic.enchantments then
        if core.magic.enchantments.records then
            enchant = core.magic.enchantments.records[enchantId]
        else
            enchant = core.magic.enchantments[enchantId]
        end
    end
    
    if not enchant then
        return false
    end

    -- 2. Build effect indexes (0-based)
    local effectIndexes = {}
    if enchant.effects then
        for i = 0, #enchant.effects - 1 do
            table.insert(effectIndexes, i)
        end
    else
        effectIndexes = {0}
    end
    
    -- 3. Determine the Record ID to use
    local sourceRecordId = nil
    if itemObj and itemObj.recordId then
        sourceRecordId = itemObj.recordId
    elseif enchant.id then
        sourceRecordId = enchant.id
    else
        sourceRecordId = enchantId
    end

    -- 4. Apply via activeSpells:add
    local params = {
        id = sourceRecordId,
        effects = effectIndexes,
        caster = caster,
        item = itemObj,
        stackable = false
    }

    local ok, err = pcall(function() activeSpells:add(params) end)
    if ok then 
        -- VFX AND SOUNDS
        if enchant.effects then
            for i = 0, #enchant.effects - 1 do
                local effectData = enchant.effects[i]
                if effectData then
                    local effectId = effectData.effect or effectData.id
                    if effectId then
                        local mgef = (core.magic.effects.records and core.magic.effects.records[effectId]) or core.magic.effects[effectId]
                        if mgef then
                            local soundId = isAoe and (mgef.areaSound or mgef.hitSound) or (mgef.hitSound or mgef.castSound)
                            if soundId and soundId ~= "" then
                                pcall(function() core.sound.playSound3d(soundId, target) end)
                            end

                            local vfxStaticId = isAoe and mgef.areaStatic or mgef.hitStatic
                            if not vfxStaticId or vfxStaticId == "" then
                                vfxStaticId = mgef.hitStatic or mgef.castStatic
                            end
                            
                            if vfxStaticId and vfxStaticId ~= "" then
                                local staticRecord = (types.Static.records and types.Static.records[vfxStaticId]) or (types.Static and types.Static[vfxStaticId])
                                if staticRecord and staticRecord.model then
                                    pcall(function()
                                        target:sendEvent('AddVfx', {
                                            model = staticRecord.model,
                                            options = {
                                                particleTextureOverride = mgef.particle or "",
                                                loop = false,
                                                vfxId = "enchant_hit_" .. tostring(enchantId) .. "_" .. tostring(i),
                                            }
                                        })
                                    end)
                                end
                            end
                        end
                    end
                end
            end
        end
        return true 
    end

    return false
end


local function isProjectileWeapon(weapon)
    if not weapon then return false, nil end
    
    local id = weapon.id
    if weaponRecordCache[id] then 
        return unpack(weaponRecordCache[id])
    end

    local weaponRecord = nil
    pcall(function() weaponRecord = types.Weapon.record(weapon) end)
    
    -- [CRITICAL] Do not cache if the record lookup failed (engine not ready)
    if not weaponRecord then
        return false, nil, nil
    end

    local res = {false, nil, nil}
    local weaponType = weaponRecord.type
    if weaponType == types.Weapon.TYPE.MarksmanBow then
        res = {true, 'arrow', weaponRecord}
    elseif weaponType == types.Weapon.TYPE.MarksmanCrossbow then
        res = {true, 'bolt', weaponRecord}
    elseif weaponType == types.Weapon.TYPE.MarksmanThrown then
        res = {true, 'thrown', weaponRecord}
    end
    
    weaponRecordCache[id] = res
    return unpack(res)
end

-- [NEW] Get the current combat target of this actor
local function getNpcTarget()
    -- 0.49+ I.AI target detection
    if I.AI and I.AI.getTarget then
        local ok, target = pcall(I.AI.getTarget, self)
        if ok and target then return target end
    end
    
    -- Fallback: If no AI target, find the player nearby to ensure we aim at them
    if nearby and nearby.actors then
        for _, actor in ipairs(nearby.actors) do
            if actor.type == types.Player then
                return actor
            end
        end
    end
    
    return nil
end

local function getMarksmanPrecision()
    local marksman = 30 -- Default NPC marksman skill
    local stats = types.Actor.stats
    if stats and stats.skills and stats.skills.marksman then
        marksman = stats.skills.marksman(self).modified
    end
    
    -- Normalized precision: 
    -- 0 skill = 0.0 accuracy
    -- 100 skill = 0.95 accuracy
    -- 120 skill = 1.0 accuracy
    local precision = 0
    if marksman <= 100 then
        precision = (marksman / 100) * 0.95
    else
        local overLevel = math.min(20, marksman - 100)
        precision = 0.95 + (overLevel / 20) * 0.05
    end
    
    return precision
end

-- [NEW] Target bone categories for randomized aiming
local AIM_GROUPS = {
    head = { "Bip01 Head", "Bip01 Neck", "Bip01 L Clavicle", "Bip01 R Clavicle" },
    torso = { "Bip01 Spine", "Bip01 Spine1", "Bip01 Spine2", "Bip01 Pelvis" },
    arms = { "Bip01 L Upper Arm", "Bip01 R Upper Arm", "Bip01 L Forearm", "Bip01 R Forearm" },
    legs = { "Bip01 L Thigh", "Bip01 R Thigh", "Bip01 L Calf", "Bip01 R Calf", "Bip01 L Foot", "Bip01 R Foot" }
}

local function chooseTargetBoneId()
    local roll = math.random(100)
    local choices = nil
    
    if roll <= 25 then
        -- Head & Shoulders (25%)
        choices = AIM_GROUPS.head
    elseif roll <= 99 then
        -- Chest & Waist (60% -> 25 to 85)
        choices = AIM_GROUPS.torso
    else
        -- Legs (15%)
        choices = AIM_GROUPS.legs
    end
    
    return choices[math.random(#choices)]
end

-- [NEW] Calculate final aim vector towards a specific bone of the target
local function calculateAimDirection(target, spawnPos, extraOffset)
    if not target then return self.rotation * util.vector3(0, 1, 0) end
    
    local targetBone = chooseTargetBoneId()
    local targetPos, ok = getBoneAnimatedPos(target, targetBone)
    
    if not ok or not targetPos then
        -- Fallback to center mass (-5 units: was 80)
        targetPos = target.position + util.vector3(0, 0, 75)
    end
    
    -- Target center of the chosen bone directly (precision fix)
    -- No random jitter here; any spread should be handled by the skill-based recoil toggle.
    
    -- Apply additional logic offset (like arc compensation)
    if extraOffset then
        targetPos = targetPos + extraOffset
    end
    
    local dir = (targetPos - spawnPos):normalize()
    return dir
end

-- [NEW] Check if NPC is actively trying to attack via AI controls

-- [NEW] Force-cancel the attack by resetting controls
local function cancelNpcAttack()
    if selfModule and selfModule.controls then
        selfModule.controls.use = 0
    end
end

-- ============================================================================
-- PASSIVE TEXT KEY INTERCEPTION SYSTEM
-- Lets vanilla animation play, fires physics projectile at exact text key moments
-- ============================================================================

-- State tracking for passive interception
local passiveAttackActive = false
local passiveAttackStartTime = nil
local passiveWeaponType = nil
local passiveWeaponItem = nil
local passiveAmmoItem = nil
local passiveAmmoHidden = false
local savedAmmoSlot = nil
local passiveIsThrown = false  -- Track if this is a thrown weapon attack
local isTextKeyRegistered = false -- Dynamic registration tracking
local cachedIsDead = false -- Cached death state to avoid per-frame API calls
local stateCache = {
    deathAnim = nil,
    heightFactor = 1.0,
    lastHeightUpdate = 0
}

local function firePhysicsProjectile()
    if not passiveWeaponItem then return end
    
    local now = core.getRealTime()
    local elapsed = now - (passiveAttackStartTime or now)
    local timings = NPC_WEAPON_TIMINGS[passiveWeaponType] or NPC_WEAPON_TIMINGS.arrow
    
    -- 1. Calculate Charge Ratio
    local chargeRatio = 0.0
    if passiveWeaponType == 'bolt' then
        chargeRatio = 1.0
    else
        local attackWindow = timings.maxAttackTime - timings.minAttackTime
        if attackWindow > 0 then
            chargeRatio = (elapsed - timings.minAttackTime) / attackWindow
            -- Clamp: Min 10% power, Max 100%
            chargeRatio = math.max(0.1, math.min(1.0, chargeRatio))
        else
            chargeRatio = 0.5
        end
    end
    
    -- 2. Get Records
    local wRec = types.Weapon.record(passiveWeaponItem)
    local aRec = nil
    if passiveWeaponType == 'thrown' then
        -- For thrown, the weapon IS the ammo
        aRec = wRec
    elseif passiveAmmoItem then
         -- Try Ammo record first (if API exists), fallback to Weapon record
         if types.Ammunition then
             aRec = types.Ammunition.record(passiveAmmoItem)
         end
         if not aRec then aRec = types.Weapon.record(passiveAmmoItem) end
    end
    
    if not wRec or not aRec then return end

    -- 3. Calculate Damage (Formula: (Min + (Max-Min)*Charge) + Ammo)
    local wMin = wRec.chopMinDamage or wRec.slashMinDamage or wRec.thrustMinDamage or 1
    local wMax = wRec.chopMaxDamage or wRec.slashMaxDamage or wRec.thrustMaxDamage or 5
    local wDmg = wMin + (wMax - wMin) * chargeRatio
    
    -- Ammo damage usually in chopMaxDamage for arrows/bolts
    local aDmg = aRec.chopMaxDamage or aRec.slashMaxDamage or aRec.thrustMaxDamage or 0
    
    local damage = wDmg + aDmg
    
    -- 4. Calculate Speed
    local boltMax   = settingsCache.boltSpeed or 4000
    local arrowMax  = settingsCache.arrowSpeed or 3500
    local thrownMax = settingsCache.thrownSpeed or 2000
    
    local speed = 2000 -- Default Fallback
    
    if passiveWeaponType == 'arrow' then
        local minArrow = arrowMax * (1000 / 3500)
        speed = minArrow + ((arrowMax - minArrow) * chargeRatio)
    elseif passiveWeaponType == 'thrown' then
        local minThrown = thrownMax * (500 / 2000)
        speed = minThrown + ((thrownMax - minThrown) * chargeRatio)
    elseif passiveWeaponType == 'bolt' then
        speed = boltMax -- Constant fast
    end

    -- 5. Spawn Position & Direction
    local spawnPos = getBoneAnimatedPos(self, 'Weapon Bone')
    if not spawnPos then spawnPos = getBoneAnimatedPos(self, 'Bip01 R Hand') end
    if not spawnPos then spawnPos = self.position + util.vector3(0,0,100) end -- Fallback
    
    -- [REFINED TARGETING] Explicitly calculate direction vector to target bones
    -- instead of just using the NPC rotation (which is often too low or horizontal)
    local target = getNpcTarget()
    
    -- [ARC COMPENSATION] Aim higher than the chosen bone to compensate for gravity upon launch.
    local aimTargetOffset = util.vector3(0, 0, 0)
    if target then
        local dist = (target.position - self.position):length()
        if passiveWeaponType == 'thrown' then
            -- [CRITICAL] Increased bias to ensure shots don't land at feet
            local verticalBias = 5 + (dist * 0.20) 
            aimTargetOffset = util.vector3(0, 0, verticalBias)
        elseif passiveWeaponType == 'arrow' then
            -- [USER REQUEST] Standard bias for reliability
            local verticalBias = 20 + (dist * 0.05) 
            aimTargetOffset = util.vector3(0, 0, verticalBias)
        elseif passiveWeaponType == 'bolt' then
            -- [NEW] Subtle bias for bolts
            local verticalBias = 15 + (dist * 0.045)
            aimTargetOffset = util.vector3(0, 0, verticalBias)
        end
    end
    
    local direction = calculateAimDirection(target, spawnPos, aimTargetOffset)
    
    -- [LAUNCH TILT] Always add a significant upward lob for thrown weapons
    -- This ensures they always clear the ground and head towards the target in an arc.
    if passiveWeaponType == 'thrown' then
        direction = (direction + util.vector3(0, 0, 0.01)):normalize()
    elseif passiveWeaponType == 'arrow' then
        direction = (direction + util.vector3(0, 0, 0.01)):normalize()
    end
    
    -- [NPC SKILL-BASED RECOIL]
    -- [USER REQUEST] Applied AFTER all arc compensations.
    local enableRecoil = false
    if settingsCache and settingsCache.enableSkillBasedRecoil ~= nil then
        enableRecoil = settingsCache.enableSkillBasedRecoil
    end
    
    if enableRecoil then
        local precision = getMarksmanPrecision()
        local spreadMult = math.max(0, 1.0 - precision)
        local maxSpreadRadius = 0.18
        if settingsCache and settingsCache.maxRecoil then
            maxSpreadRadius = settingsCache.maxRecoil
        end
        local spreadAmount = maxSpreadRadius * spreadMult
        
        if spreadAmount > 0 then
            local angle = math.random() * 2 * math.pi
            local radius = math.sqrt(math.random()) * spreadAmount
            
            -- Basis based on final adjusted trajectory
            local up = (math.abs(direction.z) < 0.999) and util.vector3(0,0,1) or util.vector3(1,0,0)
            local right = direction:cross(up):normalize()
            local realUp = right:cross(direction):normalize()
            
            direction = (direction + (right * math.cos(angle) * radius) + (realUp * math.sin(angle) * radius)):normalize()
        end
    end
    
    
    -- [FIX B] Mark shot as fired so safety loop knows not to cancel it prematurely
    lastShotTriggerTime = core.getRealTime()
    
    -- 6. Send Full Payload (Aligned with onPlaceProjectile)
    core.sendGlobalEvent('ProjectilePhysics_TriggerNpcShot', {
        projectileType = passiveWeaponType,
        recordId = aRec.id,
        consumeRecord = aRec.id, -- Ensure ammo consumption
        weaponRecordId = wRec.id,
        attacker = self,
        attackerVelocity = self.velocity, -- [NEW] Pass velocity from local
        launcher = passiveWeaponItem,
        position = spawnPos,     -- Actual spawn point
        startPos = spawnPos,     -- Origin
        direction = direction,
        speed = speed,
        damage = damage,
        chargeRatio = chargeRatio,
        flightTime = 0,
        spawnAtLauncher = true,  -- Spawn in front and fly physically
        isMiss = false,
        isDirectHit = false
    })
    
    -- [FIX] Issue 2: Consume NPC Ammo
    -- Manually remove 1 count from the tracked ammo item
    local inv = types.Actor.inventory(self)
    local itemToConsume = passiveAmmoItem
    
    if itemToConsume and itemToConsume:isValid() then
        -- Find mutable handle in inventory
        local realItem = inv:find(itemToConsume.recordId)
        
        if realItem then
             -- STRATEGY: Global Authority
             core.sendGlobalEvent('ProjectilePhysics_ConsumeAmmo', {
                 item = realItem,
                 count = 1,
                 actor = self
             })
        else
             debugLog('[PP-ACTOR] Could not find ammo ' .. tostring(itemToConsume.recordId) .. ' in inventory.')
        end
    end
    
    debugLog(string.format('[PASSIVE] NPC Fired %s | Charge: %.2f | Dmg: %.1f | Spd: %.1f', 
        passiveWeaponType, chargeRatio, damage, speed))
end

-- Play crossbowshoot once per firing cycle.
-- crossbowpull is fired natively by the follow-through animation (fakerelease playBlended).
local function playCrossbowSounds()
    if passiveWeaponType ~= 'bolt' then return end
    local now = core.getRealTime()
    if not lastShootSoundTime or (now - lastShootSoundTime > 0.5) then
        core.sound.playSound3d('crossbowshoot', self)
        lastShootSoundTime = now
    end
end


-- Helper: Hide ammo/weapon to suppress vanilla projectile
local function hideAmmoForSuppression()
    if passiveAmmoHidden then return end
    local equipment = Actor.getEquipment(self)
    if passiveIsThrown then
        savedAmmoSlot = equipment[SLOT.CarriedRight]
        if savedAmmoSlot then
            equipment[SLOT.CarriedRight] = nil
            Actor.setEquipment(self, equipment)
            passiveAmmoHidden = true
            debugLog('[PASSIVE] Thrown weapon hidden to suppress vanilla throw')
        end
    else
        savedAmmoSlot = equipment[SLOT.Ammunition]
        if savedAmmoSlot then
            equipment[SLOT.Ammunition] = nil
            Actor.setEquipment(self, equipment)
            passiveAmmoHidden = true
            debugLog('[PASSIVE] Ammo hidden to suppress vanilla arrow/bolt')
        end
    end
end

-- Helper: Restore ammo after shot
local function restoreAmmoAfterShot()
    if not passiveAmmoHidden then return end
    if savedAmmoSlot then
        local equipment = Actor.getEquipment(self)
        if passiveIsThrown then
            equipment[SLOT.CarriedRight] = savedAmmoSlot
            debugLog('[PASSIVE] Thrown weapon restored')
        else
            equipment[SLOT.Ammunition] = savedAmmoSlot
            debugLog('[PASSIVE] Ammo restored')
        end
        Actor.setEquipment(self, equipment)
    end
    passiveAmmoHidden = false
    savedAmmoSlot = nil
    lastShotTriggerTime = 0
end

-- MAIN TEXT KEY HANDLER (Passive Interception)
local function onTextKey(group, key)
    -- Only run for NPCs and Creatures. 
    -- Running for the Player causes double projectiles and animation resets.
    if self.type == types.Player then return end
    
    if settingsCache.enableNPCSupport == false then return end
    if not key then return end
    --TEST ANIM KEYS TRIGGERING - UNCOMMENT THE LINE BELOW TO LOG THE ANIM KEYS LIVE
    --debugLog(string.format('onTextKey called. Arg1: "%s" | Arg2: "%s"', tostring(group), tostring(key)))

    -- Process bowandarrow, crossbow, AND throwweapon groups
    local groupL = group and group:lower() or ''
    if groupL ~= 'bowandarrow' and groupL ~= 'crossbow' and groupL ~= 'throwweapon' then 
        -- Handle creature attacks and other edge cases
        if self.type == types.Creature then
            local keyL = key:lower()
            if keyL:find('ready') or keyL:find('start') or keyL:find('draw') then
                creatureAttackStage = 'ready'
            elseif keyL:find('release') or keyL:find('fire') or keyL:find('shoot') or keyL:find('hit') then
                creatureAttackStage = 'release'
            end
        end
        return 
    end

    local keyL = key:lower()
    
    if keyL == 'fakerelease' or keyL == 'shoot fakerelease' then
        debugLog('ACTOR FAKERELEASE TRIGGERED. Group: ' .. tostring(groupL) .. ' | Actor: ' .. tostring(self.recordId))
        
        -- Play correct sound based on weapon type
        if groupL == 'bowandarrow' then
            core.sound.playSound3d('bowshoot', self)
        elseif groupL == 'crossbow' then
            -- Sounds emitted only when attack is confirmed active (below)
        end
        
        if anim and anim.cancel then
            -- [FIX] Do NOT cancel thrown weapons early, or the animation might freeze
            if groupL ~= 'throwweapon' then
                anim.cancel(self, group)
                debugLog('ACTOR FAKERELEASE - anim.cancel() executed')
                debugLog('Fake release intercepted. Animation canceled for ' .. groupL)
            end
        end
        
        if passiveAttackActive then
            -- Ensure ammo is hidden before firing to suppress vanilla projectile
            hideAmmoForSuppression()
            -- Fire our physics projectile
            firePhysicsProjectile()
            
            -- [FIX] Manual sounds for fakerelease
            playCrossbowSounds()
        end
        return
    end

    -- ========================================
    -- SHOOT START: Initialize attack tracking
    -- ========================================
    if keyL == 'shoot start' then
        local weapon = Actor.getEquipment(self)[SLOT.CarriedRight]
        local isProj, pType = isProjectileWeapon(weapon)
        
        if isProj then
            passiveAttackActive = true
            passiveAttackStartTime = core.getRealTime()
            passiveWeaponType = pType
            passiveWeaponItem = weapon
            passiveAmmoHidden = false
            passiveIsThrown = (pType == 'thrown')
            
            -- [FIX] Track ammunition item for Bows/Crossbows
            if passiveIsThrown then
                passiveAmmoItem = weapon
            else
                passiveAmmoItem = Actor.getEquipment(self)[SLOT.Ammunition]
            end
            
            lastShotTriggerTime = 0 -- Reset at start of new attack
            lastShootSoundTime = 0 -- Reset sound throttle
            
            debugLog('[PASSIVE] Attack started: ' .. pType .. (passiveIsThrown and ' (thrown)' or '') .. 
                ' | Ammo: ' .. tostring(passiveAmmoItem and passiveAmmoItem.recordId or 'None'))
        end
    end
    
    -- ========================================
    -- SHOOT MIN HIT: Hide ammo/weapon to prevent vanilla projectile
    -- ========================================
    if keyL == 'shoot min hit' then
        if passiveAttackActive then
             if passiveWeaponType == 'bolt' then
                 -- [REVISION 34] Authoritative Firing at Min Hit for NPCs
                 hideAmmoForSuppression() -- Safety re-check
                 firePhysicsProjectile()
                 
                 if anim and anim.cancel then
                     anim.cancel(self, 'crossbow')
                 end
                 -- Note: sounds are played at fakerelease, not here
                 restoreAmmoAfterShot()
                 debugLog('[PASSIVE] Crossbow launched, canceled, and restored at min hit')
             else
                 hideAmmoForSuppression()
                 debugLog('[PASSIVE] Shoot min hit - ammo hidden')
             end
        end
    end
    
    -- ========================================
    -- SHOOT RELEASE: Fire physics projectile
    -- ========================================
    if keyL == 'shoot release' then
        debugLog('ACTOR SHOOT RELEASE TRIGGERED. Active: ' .. tostring(passiveAttackActive) .. ' | Actor: ' .. tostring(self.recordId))
        
        -- [FIX A] Re-arm if shoot start was missed
        if not passiveAttackActive then
            local weapon = Actor.getEquipment(self)[SLOT.CarriedRight]
            local isProj, pType = isProjectileWeapon(weapon)
            if isProj then
                passiveAttackActive = true
                passiveAttackStartTime = core.getRealTime() - 1.0  -- treat as logically drawn long enough
                passiveWeaponType = pType
                passiveWeaponItem = weapon
                passiveAmmoItem = Actor.getEquipment(self)[SLOT.Ammunition]
                passiveAmmoHidden = false
                passiveIsThrown = (pType == 'thrown')
                if passiveIsThrown then passiveAmmoItem = weapon end
                debugLog('[PASSIVE] shoot release re-armed (missed start)')
            end
        end
        
        if passiveAttackActive then
             local now = core.getRealTime()
             local elapsed = now - (passiveAttackStartTime or now)
             local timings = NPC_WEAPON_TIMINGS[passiveWeaponType] or NPC_WEAPON_TIMINGS.arrow
             
             -- [FIX C] 20% tolerance on minAttackTime
             local effectiveMin = (timings.minAttackTime or 0) * 0.8
             
             if elapsed >= effectiveMin then
                 if not passiveAmmoHidden then
                     hideAmmoForSuppression()
                 end
                 if anim and anim.cancel then
                     anim.cancel(self, group)
                     debugLog('ACTOR SHOOT RELEASE - anim.cancel() executed to act as fakerelease')
                 end
                 debugLog('ACTOR SHOOT RELEASE - Forwarding to fakerelease logic')
                 onTextKey(group, 'fakerelease')
             else
                 debugLog('ACTOR SHOOT RELEASE IGNORED - Bow not drawn long enough')
             end
        end
    end
    
    -- ========================================
    -- SHOOT FOLLOW STOP: Reset state, restore ammo (Bows/XBow)
    -- ========================================
    if keyL == 'shoot follow stop' then
        if passiveAttackActive then
            if not passiveIsThrown then
                async:newUnsavableSimulationTimer(0.1, function()
                    restoreAmmoAfterShot()
                end)
                passiveAttackActive = false
                passiveAttackStartTime = nil
                passiveWeaponType = nil
                passiveWeaponItem = nil
                passiveAmmoItem = nil
                debugLog('[PASSIVE] Attack complete (Bow/XBow), state reset')
            else
                passiveAttackActive = false
                passiveAttackStartTime = nil
                debugLog('[PASSIVE] Attack complete (Throw), waiting for unequip stop')
            end
        end
    end
    
    -- ========================================
    -- UNEQUIP STOP: Cleanup thrown state + restore
    -- ========================================
    if keyL == 'unequip stop' then
        if passiveIsThrown then
            async:newUnsavableSimulationTimer(0.05, function()
                restoreAmmoAfterShot()
            end)
            passiveAttackActive = false
            passiveIsThrown = false
            passiveWeaponType = nil
            passiveWeaponItem = nil
            passiveAmmoItem = nil
            debugLog('[PASSIVE] Thrown weapon state cleared at unequip stop')
        end
    end
end

-- Only register text key handler for NPCs and Creatures.
-- The Player has their own dedicated handler in ProjectilePhysicsPlayer.lua.
-- Registering here for the player causes double projectiles and animation interference.
-- [REGISTRATION] Ensure the text key handler is active for all NPCs/Creatures.
-- Internal filters in onTextKey will prevent processing for non-ranged actors.
if AnimController and self.type ~= types.Player then
    AnimController.addTextKeyHandler(nil, onTextKey)
    debugLog('Registered passive TextKey handler for actor')
end

-- LOGIC UPDATE LOOP (Fallback/Safety)
-- Handles edge cases where text keys might be missed
local function updateCustomAttack(dt)
    if not passiveAttackActive then return end
    
    local now = core.getRealTime()
    local elapsed = now - (passiveAttackStartTime or 0)
    local timings = NPC_WEAPON_TIMINGS[passiveWeaponType] or NPC_WEAPON_TIMINGS.arrow
    
    if timings and timings.releaseMaxTime and elapsed > timings.releaseMaxTime then
        -- Only cancel/cleanup if we actually fired OR timed out beyond hard limit
        local hardTimeout = timings.releaseMaxTime + 0.3
        if lastShotTriggerTime > 0 or elapsed > hardTimeout then
            cancelNpcAttack()
            restoreAmmoAfterShot()
            passiveAttackActive = false
            passiveAttackStartTime = nil
            passiveWeaponType = nil
            passiveWeaponItem = nil
            passiveAmmoItem = nil
            debugLog('[PASSIVE] Bow cancel triggered/Cleaned up (timeout)')
        end
    end
end


-- ============================================================================
-- ALTERNATIVE METHOD: onFrame Control Interception (Most Reliable)
-- ============================================================================

-- This approach intercepts the AI's attack command BEFORE it reaches the engine


-- ============================================================================
-- VFX STICKING SYSTEM: Precise Coordinate-Based Selection (Data & Helpers)
-- ============================================================================

BONES = {

	-- Head
	['Bip01 Arrow Bone 086'] = util.vector3(-0.147, 6.197, 131.964),
	['Bip01 Arrow Bone 090'] = util.vector3(-2.441, 2.992, 131.754),
	['Bip01 Arrow Bone 092'] = util.vector3(4.132, 3.092, 130.092),
	['Bip01 Arrow Bone 084'] = util.vector3(1.688, 8.970, 129.887),
	['Bip01 Arrow Bone 091'] = util.vector3(-1.331, 0.018, 129.690),
	['Bip01 Arrow Bone 087'] = util.vector3(-5.111, 3.101, 128.458),
	['Bip01 Arrow Bone 085'] = util.vector3(-2.786, 10.142, 127.807),

	-- BackHead
	['Bip01 Arrow Bone 089'] = util.vector3(0.822, -0.753, 127.443),

	-- Head
	['Bip01 Arrow Bone 083'] = util.vector3(4.455, 8.458, 127.268),
	['Bip01 Arrow Bone 073'] = util.vector3(-4.444, 7.860, 127.121),
	['Bip01 Arrow Bone 080'] = util.vector3(4.901, 4.743, 127.029),
	['Bip01 Arrow Bone 072'] = util.vector3(0.204, 11.074, 126.160),
	['Bip01 Arrow Bone 088'] = util.vector3(-2.507, 0.472, 125.202),
	['Bip01 Arrow Bone 079'] = util.vector3(2.411, 0.320, 124.480),
	['Bip01 Arrow Bone 071'] = util.vector3(3.059, 10.252, 123.030),
	['Bip01 Arrow Bone 082'] = util.vector3(4.007, 8.789, 122.532),
	['Bip01 Arrow Bone 074'] = util.vector3(-3.667, 4.082, 122.466),
	['Bip01 Arrow Bone 070'] = util.vector3(-2.635, 10.189, 121.555),
	['Bip01 Arrow Bone 069'] = util.vector3(2.496, 10.091, 120.326),
	['Bip01 Arrow Bone 076'] = util.vector3(-0.621, 0.596, 119.570),
	['Bip01 Arrow Bone 081'] = util.vector3(3.125, 2.800, 119.557),
	['Bip01 Arrow Bone 077'] = util.vector3(2.457, 1.067, 118.873),
	['Bip01 Arrow Bone 075'] = util.vector3(-3.226, 3.117, 118.482),

	-- BackHead
	['Bip01 Arrow Bone 068'] = util.vector3(0.503, -1.768, 116.114),

	-- Head
	['Bip01 Arrow Bone 062'] = util.vector3(7.409, 2.267, 113.879),
	['Bip01 Arrow Bone 064'] = util.vector3(-7.267, 4.196, 113.023),

	-- BackHead
	['Bip01 Arrow Bone 078'] = util.vector3(8.272, -1.135, 112.819),

	-- Head
	['Bip01 Arrow Bone 061'] = util.vector3(5.701, 5.317, 112.383),

	-- BackHead
	['Bip01 Arrow Bone 066'] = util.vector3(6.717, -2.786, 112.297),
	['Bip01 Arrow Bone 065'] = util.vector3(-6.246, -2.870, 111.829),
	['Bip01 Arrow Bone 054'] = util.vector3(-1.335, -2.793, 111.819),

	-- Head
	['Bip01 Arrow Bone 060'] = util.vector3(0.065, 6.697, 111.681),

	-- BackHead
	['Bip01 Arrow Bone 052'] = util.vector3(3.498, -3.372, 110.688),

	-- Head
	['Bip01 Arrow Bone 059'] = util.vector3(-4.320, 7.679, 110.624),
	['Bip01 Arrow Bone 058'] = util.vector3(3.887, 7.974, 110.540),

	-- Back
	['Bip01 Arrow Bone 051'] = util.vector3(-4.432, -1.762, 109.199),

	-- Torso
	['Bip01 Arrow Bone 057'] = util.vector3(-2.283, 10.169, 108.676),

	-- Back
	['Bip01 Arrow Bone 067'] = util.vector3(7.095, -3.691, 108.152),

	-- LArm
	['Bip01 Arrow Bone 197'] = util.vector3(-15.601, 3.483, 107.538),

	-- Torso
	['Bip01 Arrow Bone 063'] = util.vector3(-6.754, 8.003, 107.485),
	['Bip01 Arrow Bone 056'] = util.vector3(4.528, 10.902, 107.485),

	-- Back
	['Bip01 Arrow Bone 053'] = util.vector3(3.462, -4.222, 107.148),
	['Bip01 Arrow Bone 031'] = util.vector3(-7.512, -3.100, 106.987),
	['Bip01 Arrow Bone 055'] = util.vector3(8.844, -2.712, 106.605),

	-- RArm
	['Bip01 Arrow Bone 189'] = util.vector3(14.341, 4.931, 106.149),

	-- Back
	['Bip01 Arrow Bone 036'] = util.vector3(-1.088, -4.190, 106.033),
	['Bip01 Arrow Bone 032'] = util.vector3(-5.472, -4.007, 105.779),
	['Bip01 Arrow Bone 041'] = util.vector3(6.180, -3.867, 105.651),

	-- LArm
	['Bip01 Arrow Bone 202'] = util.vector3(-15.367, 0.545, 105.364),

	-- Torso
	['Bip01 Arrow Bone 011'] = util.vector3(-4.967, 11.399, 105.225),

	-- Back
	['Bip01 Arrow Bone 040'] = util.vector3(2.157, -4.462, 103.625),

	-- Torso
	['Bip01 Arrow Bone 050'] = util.vector3(8.309, 0.327, 103.207),
	['Bip01 Arrow Bone 006'] = util.vector3(2.382, 11.183, 103.175),
	['Bip01 Arrow Bone 018'] = util.vector3(6.652, 8.348, 103.136),
	['Bip01 Arrow Bone 010'] = util.vector3(5.698, 11.074, 102.990),

	-- Back
	['Bip01 Arrow Bone 034'] = util.vector3(-2.794, -4.257, 102.754),

	-- RArm
	['Bip01 Arrow Bone 190'] = util.vector3(15.637, 1.533, 102.409),

	-- Torso
	['Bip01 Arrow Bone 005'] = util.vector3(-7.464, 10.597, 102.262),

	-- LArm
	['Bip01 Arrow Bone 198'] = util.vector3(-12.845, 5.621, 102.080),

	-- Back
	['Bip01 Arrow Bone 030'] = util.vector3(-6.281, -1.466, 101.849),
	['Bip01 Arrow Bone 042'] = util.vector3(8.495, -1.896, 101.747),

	-- RArm
	['Bip01 Arrow Bone 049'] = util.vector3(10.432, 2.807, 101.383),

	-- Back
	['Bip01 Arrow Bone 027'] = util.vector3(-6.253, -3.414, 101.329),

	-- Torso
	['Bip01 Arrow Bone 012'] = util.vector3(-9.772, 6.066, 100.875),
	['Bip01 Arrow Bone 026'] = util.vector3(-7.456, 0.801, 100.704),
	['Bip01 Arrow Bone 048'] = util.vector3(9.799, 1.198, 99.209),
	['Bip01 Arrow Bone 004'] = util.vector3(5.380, 10.373, 99.163),

	-- LArm
	['Bip01 Arrow Bone 203'] = util.vector3(-15.550, 0.252, 99.153),

	-- Torso
	['Bip01 Arrow Bone 002'] = util.vector3(-4.042, 10.679, 99.126),

	-- Back
	['Bip01 Arrow Bone 039'] = util.vector3(4.299, -3.545, 99.081),
	['Bip01 Arrow Bone 025'] = util.vector3(-8.408, -0.255, 98.538),

	-- Torso
	['Bip01 Arrow Bone 007'] = util.vector3(-0.350, 10.870, 98.371),
	['Bip01 Arrow Bone 017'] = util.vector3(7.186, 9.236, 98.316),

	-- LArm
	['Bip01 Arrow Bone 199'] = util.vector3(-14.692, 3.312, 97.908),

	-- Back
	['Bip01 Arrow Bone 028'] = util.vector3(-3.970, -3.024, 97.684),

	-- Torso
	['Bip01 Arrow Bone 022'] = util.vector3(-9.099, 2.752, 97.615),
	['Bip01 Arrow Bone 019'] = util.vector3(9.024, 4.861, 97.594),

	-- Back
	['Bip01 Arrow Bone 035'] = util.vector3(-0.573, -4.008, 97.587),

	-- RArm
	['Bip01 Arrow Bone 191'] = util.vector3(14.335, 3.374, 96.328),
	['Bip01 Arrow Bone 194'] = util.vector3(16.044, 0.416, 95.830),

	-- Torso
	['Bip01 Arrow Bone 047'] = util.vector3(8.260, 1.742, 95.829),

	-- Back
	['Bip01 Arrow Bone 043'] = util.vector3(6.717, -0.331, 94.700),

	-- Torso
	['Bip01 Arrow Bone 008'] = util.vector3(-6.344, 6.751, 94.436),
	['Bip01 Arrow Bone 001'] = util.vector3(3.393, 9.827, 93.399),

	-- Back
	['Bip01 Arrow Bone 038'] = util.vector3(2.555, -2.535, 93.319),

	-- LArm
	['Bip01 Arrow Bone 200'] = util.vector3(-15.616, 2.022, 93.132),

	-- Back
	['Bip01 Arrow Bone 033'] = util.vector3(-1.919, -2.763, 93.080),

	-- Torso
	['Bip01 Arrow Bone 016'] = util.vector3(5.881, 7.088, 92.842),

	-- Back
	['Bip01 Arrow Bone 024'] = util.vector3(-5.646, -0.606, 92.800),

	-- LArm
	['Bip01 Arrow Bone 204'] = util.vector3(-15.733, -1.273, 92.474),

	-- Torso
	['Bip01 Arrow Bone 045'] = util.vector3(7.356, 2.773, 92.118),
	['Bip01 Arrow Bone 013'] = util.vector3(-7.024, 4.003, 92.032),
	['Bip01 Arrow Bone 000'] = util.vector3(-3.464, 9.275, 89.889),

	-- Back
	['Bip01 Arrow Bone 037'] = util.vector3(3.675, -1.828, 89.494),
	['Bip01 Arrow Bone 029'] = util.vector3(-1.791, -2.656, 89.236),

	-- Torso
	['Bip01 Arrow Bone 021'] = util.vector3(-7.797, 2.256, 89.188),
	['Bip01 Arrow Bone 009'] = util.vector3(-6.741, 5.873, 89.168),
	['Bip01 Arrow Bone 020'] = util.vector3(6.966, 5.558, 88.940),
	['Bip01 Arrow Bone 046'] = util.vector3(7.620, 2.864, 88.917),
	['Bip01 Arrow Bone 074'] = util.vector3(-3.667, 4.082, 122.466),
	['Bip01 Arrow Bone 075'] = util.vector3(-3.226, 3.117, 118.482),
	['Bip01 Arrow Bone 076'] = util.vector3(-0.621, 0.596, 119.570),
	['Bip01 Arrow Bone 077'] = util.vector3(2.457, 1.067, 118.873),
	['Bip01 Arrow Bone 078'] = util.vector3(8.272, -1.135, 112.819),
	['Bip01 Arrow Bone 079'] = util.vector3(2.411, 0.320, 124.480),
	['Bip01 Arrow Bone 080'] = util.vector3(4.901, 4.743, 127.029),
	['Bip01 Arrow Bone 081'] = util.vector3(3.125, 2.800, 119.557),
	['Bip01 Arrow Bone 082'] = util.vector3(4.007, 8.789, 122.532),
	['Bip01 Arrow Bone 083'] = util.vector3(4.455, 8.458, 127.268),
	['Bip01 Arrow Bone 084'] = util.vector3(1.688, 8.970, 129.887),
	['Bip01 Arrow Bone 085'] = util.vector3(-2.786, 10.142, 127.807),
	['Bip01 Arrow Bone 086'] = util.vector3(-0.147, 6.197, 131.964),
	['Bip01 Arrow Bone 087'] = util.vector3(-5.111, 3.101, 128.458),
	['Bip01 Arrow Bone 088'] = util.vector3(-2.507, 0.472, 125.202),
	['Bip01 Arrow Bone 089'] = util.vector3(0.822, -0.753, 127.443),
	['Bip01 Arrow Bone 090'] = util.vector3(-2.441, 2.992, 131.754),
	['Bip01 Arrow Bone 091'] = util.vector3(-1.331, 0.018, 129.690),
	['Bip01 Arrow Bone 092'] = util.vector3(4.132, 3.092, 130.092),
	['Bip01 Arrow Bone 093'] = util.vector3(7.438, 7.069, 83.059),
	['Bip01 Arrow Bone 094'] = util.vector3(9.733, 2.948, 81.785),
	['Bip01 Arrow Bone 095'] = util.vector3(7.325, -3.314, 81.525),
	['Bip01 Arrow Bone 096'] = util.vector3(0.573, -4.682, 82.200),
	['Bip01 Arrow Bone 097'] = util.vector3(-2.847, -3.428, 84.605),
	['Bip01 Arrow Bone 098'] = util.vector3(-4.655, -5.535, 77.855),
	['Bip01 Arrow Bone 099'] = util.vector3(-7.942, -0.549, 83.358),
	['Bip01 Arrow Bone 100'] = util.vector3(-9.329, 2.686, 82.001),
	['Bip01 Arrow Bone 101'] = util.vector3(-8.162, -1.184, 76.512),
	['Bip01 Arrow Bone 102'] = util.vector3(-8.202, 6.043, 80.731),
	['Bip01 Arrow Bone 103'] = util.vector3(-11.071, 2.439, 72.708),
	['Bip01 Arrow Bone 104'] = util.vector3(-8.977, 6.578, 73.453),
	['Bip01 Arrow Bone 105'] = util.vector3(-3.621, 9.099, 79.899),
	['Bip01 Arrow Bone 106'] = util.vector3(-0.023, 9.851, 77.524),
	['Bip01 Arrow Bone 107'] = util.vector3(8.022, 6.433, 75.369),
	['Bip01 Arrow Bone 108'] = util.vector3(10.353, 4.594, 72.995),
	['Bip01 Arrow Bone 109'] = util.vector3(6.079, -4.758, 72.291),
	['Bip01 Arrow Bone 110'] = util.vector3(9.423, 0.193, 72.186),
	['Bip01 Arrow Bone 111'] = util.vector3(0.052, -5.897, 76.304),
	['Bip01 Arrow Bone 112'] = util.vector3(4.005, -6.141, 74.587),
	['Bip01 Arrow Bone 113'] = util.vector3(-7.044, -2.070, 69.762),
	['Bip01 Arrow Bone 114'] = util.vector3(-9.946, 0.032, 66.620),
	['Bip01 Arrow Bone 115'] = util.vector3(-10.312, 5.026, 64.273),
	['Bip01 Arrow Bone 116'] = util.vector3(-10.466, 4.747, 70.067),
	['Bip01 Arrow Bone 117'] = util.vector3(-7.619, 7.794, 68.578),
	['Bip01 Arrow Bone 118'] = util.vector3(9.252, 7.611, 71.595),
	['Bip01 Arrow Bone 119'] = util.vector3(7.575, 9.680, 69.819),
	['Bip01 Arrow Bone 120'] = util.vector3(8.828, 9.733, 67.410),
	['Bip01 Arrow Bone 121'] = util.vector3(11.339, 6.659, 68.758),
	['Bip01 Arrow Bone 122'] = util.vector3(11.553, 2.219, 66.159),
	['Bip01 Arrow Bone 123'] = util.vector3(12.143, 6.609, 63.181),
	['Bip01 Arrow Bone 124'] = util.vector3(13.002, 4.407, 58.593),
	['Bip01 Arrow Bone 125'] = util.vector3(9.656, 1.262, 59.893),
	['Bip01 Arrow Bone 126'] = util.vector3(8.041, -0.052, 63.440),
	['Bip01 Arrow Bone 127'] = util.vector3(-8.315, -1.736, 63.668),
	['Bip01 Arrow Bone 128'] = util.vector3(-4.608, -2.505, 59.593),
	['Bip01 Arrow Bone 129'] = util.vector3(9.264, 1.332, 57.042),
	['Bip01 Arrow Bone 130'] = util.vector3(4.403, 0.843, 60.844),
	['Bip01 Arrow Bone 131'] = util.vector3(-6.946, -2.256, 59.377),
	['Bip01 Arrow Bone 132'] = util.vector3(-10.737, 4.206, 59.050),
	['Bip01 Arrow Bone 133'] = util.vector3(10.821, 10.306, 57.503),
	['Bip01 Arrow Bone 134'] = util.vector3(12.441, 8.912, 52.812),
	['Bip01 Arrow Bone 135'] = util.vector3(-8.334, 6.157, 51.928),
	['Bip01 Arrow Bone 136'] = util.vector3(8.285, 10.976, 62.508),
	['Bip01 Arrow Bone 137'] = util.vector3(7.803, 12.352, 54.756),
	['Bip01 Arrow Bone 138'] = util.vector3(-6.038, 8.419, 65.217),
	['Bip01 Arrow Bone 139'] = util.vector3(-7.625, 7.403, 57.335),
	['Bip01 Arrow Bone 140'] = util.vector3(-4.067, 7.772, 59.643),
	['Bip01 Arrow Bone 141'] = util.vector3(-3.398, 6.649, 48.407),
	['Bip01 Arrow Bone 142'] = util.vector3(-7.815, 5.341, 47.866),
	['Bip01 Arrow Bone 143'] = util.vector3(-11.134, 1.941, 54.493),
	['Bip01 Arrow Bone 144'] = util.vector3(-9.478, 0.819, 47.320),
	['Bip01 Arrow Bone 145'] = util.vector3(-7.965, -1.897, 55.488),
	['Bip01 Arrow Bone 146'] = util.vector3(-7.412, -1.692, 50.616),
	['Bip01 Arrow Bone 147'] = util.vector3(-7.826, 2.336, 41.937),
	['Bip01 Arrow Bone 148'] = util.vector3(-6.955, 3.868, 38.408),
	['Bip01 Arrow Bone 149'] = util.vector3(11.047, 10.073, 47.472),
	['Bip01 Arrow Bone 150'] = util.vector3(10.064, 10.885, 38.384),
	['Bip01 Arrow Bone 151'] = util.vector3(10.862, 8.748, 40.462),
	['Bip01 Arrow Bone 152'] = util.vector3(12.798, 6.803, 48.204),
	['Bip01 Arrow Bone 153'] = util.vector3(11.744, 7.114, 37.834),
	['Bip01 Arrow Bone 154'] = util.vector3(11.293, 4.235, 34.941),
	['Bip01 Arrow Bone 155'] = util.vector3(10.533, 5.492, 41.757),
	['Bip01 Arrow Bone 156'] = util.vector3(9.814, 3.159, 50.594),
	['Bip01 Arrow Bone 157'] = util.vector3(7.682, 2.244, 52.805),
	['Bip01 Arrow Bone 158'] = util.vector3(9.180, 1.990, 36.094),
	['Bip01 Arrow Bone 159'] = util.vector3(-2.522, -0.155, 39.192),
	['Bip01 Arrow Bone 160'] = util.vector3(-6.714, -3.087, 35.521),
	['Bip01 Arrow Bone 161'] = util.vector3(-3.162, -3.570, 33.688),
	['Bip01 Arrow Bone 162'] = util.vector3(-8.024, -1.370, 34.016),
	['Bip01 Arrow Bone 163'] = util.vector3(-4.513, -2.410, 40.197),
	['Bip01 Arrow Bone 164'] = util.vector3(-4.490, -2.025, 52.024),
	['Bip01 Arrow Bone 165'] = util.vector3(-3.766, -1.662, 45.026),
	['Bip01 Arrow Bone 166'] = util.vector3(-9.186, 0.865, 35.031),
	['Bip01 Arrow Bone 167'] = util.vector3(-9.308, 0.944, 28.241),
	['Bip01 Arrow Bone 168'] = util.vector3(-7.028, -3.433, 29.878),
	['Bip01 Arrow Bone 169'] = util.vector3(-6.051, -2.996, 21.706),
	['Bip01 Arrow Bone 170'] = util.vector3(-8.485, 0.508, 20.775),
	['Bip01 Arrow Bone 171'] = util.vector3(-7.021, 3.636, 24.673),
	['Bip01 Arrow Bone 172'] = util.vector3(-6.712, 4.619, 32.323),
	['Bip01 Arrow Bone 173'] = util.vector3(9.901, 10.828, 33.079),
	['Bip01 Arrow Bone 174'] = util.vector3(6.310, 9.152, 39.053),
	['Bip01 Arrow Bone 175'] = util.vector3(-4.364, 5.240, 31.009),
	['Bip01 Arrow Bone 176'] = util.vector3(8.967, 10.444, 26.186),
	['Bip01 Arrow Bone 177'] = util.vector3(11.974, 8.016, 31.302),
	['Bip01 Arrow Bone 178'] = util.vector3(10.283, 9.935, 23.510),
	['Bip01 Arrow Bone 179'] = util.vector3(12.711, 6.414, 25.422),
	['Bip01 Arrow Bone 180'] = util.vector3(12.495, 4.831, 31.308),
	['Bip01 Arrow Bone 181'] = util.vector3(12.521, 5.708, 17.264),
	['Bip01 Arrow Bone 182'] = util.vector3(11.191, 8.361, 10.794),
	['Bip01 Arrow Bone 183'] = util.vector3(-5.389, 4.175, 12.298),
	['Bip01 Arrow Bone 184'] = util.vector3(7.928, 2.661, 20.815),
	['Bip01 Arrow Bone 185'] = util.vector3(10.554, 2.338, 28.259),
	['Bip01 Arrow Bone 186'] = util.vector3(11.362, 4.047, 16.860),
	['Bip01 Arrow Bone 187'] = util.vector3(-3.591, -3.953, 27.643),
	['Bip01 Arrow Bone 188'] = util.vector3(-4.052, -1.155, 14.796),
	['Bip01 Arrow Bone 189'] = util.vector3(14.341, 4.931, 106.149),
	['Bip01 Arrow Bone 190'] = util.vector3(15.637, 1.533, 102.409),
	['Bip01 Arrow Bone 191'] = util.vector3(14.335, 3.374, 96.328),
	['Bip01 Arrow Bone 192'] = util.vector3(14.982, 3.207, 87.533),
	['Bip01 Arrow Bone 193'] = util.vector3(15.331, 3.322, 79.049),
	['Bip01 Arrow Bone 194'] = util.vector3(16.044, 0.416, 95.830),
	['Bip01 Arrow Bone 195'] = util.vector3(16.704, 0.053, 84.079),
	['Bip01 Arrow Bone 196'] = util.vector3(16.826, 0.319, 78.107),
	['Bip01 Arrow Bone 197'] = util.vector3(-15.601, 3.483, 107.538),
	['Bip01 Arrow Bone 198'] = util.vector3(-12.845, 5.621, 102.080),
	['Bip01 Arrow Bone 199'] = util.vector3(-14.692, 3.312, 97.908),
	['Bip01 Arrow Bone 200'] = util.vector3(-15.616, 2.022, 93.132),
	['Bip01 Arrow Bone 201'] = util.vector3(-14.934, 2.734, 85.731),
	['Bip01 Arrow Bone 202'] = util.vector3(-15.367, 0.545, 105.364),
	['Bip01 Arrow Bone 203'] = util.vector3(-15.550, 0.252, 99.153),
	['Bip01 Arrow Bone 204'] = util.vector3(-15.733, -1.273, 92.474),
	['Bip01 Arrow Bone 205'] = util.vector3(-15.585, -0.843, 84.466),
	['Bip01 Arrow Bone 206'] = util.vector3(-15.560, 3.007, 80.290),
}

-- [INTERNAL INVERSION]: The character rig is rotated 180 degrees.
-- We invert the Y coordinate of all bone data at load to restore "Logical Front = Positive Y" internally.
for name, coord in pairs(BONES) do
    BONES[name] = util.vector3(coord.x, -coord.y, coord.z)
end

local function getCategoryForCoordinate(coord)
    local x, y, z = coord.x, coord.y, coord.z
    local isFront = y > 0 -- Standard logic: +Y is Front (applied to inverted coordinates)

    -- HEAD (Z > 110)
    if z > 110 then return isFront and "Head" or "BackHead" end

    -- LEGS (Z < 55)
    if z < 55 then
        local side = (x < 0) and "L" or "R"
        if z < 35 then return side .. "LowerLeg" end
        return side .. "UpperLeg"
    end

    -- ARMS (55 <= Z <= 110 AND |X| > 10)
    if math.abs(x) > 10 and z >= 55 and z <= 110 then
        local side = (x < 0) and "L" or "R"
        return side .. "Arm"
    end

    -- TORSO / BACK (Everything else in 55-110 range)
    return isFront and "Torso" or "Back"
end

-- PRE-CALCULATED CATEGORIES: Assigns every bone (000-207) to a region based on its coordinate
BONE_CATEGORIES = {}
for name, coord in pairs(BONES) do
    BONE_CATEGORIES[name] = getCategoryForCoordinate(coord)
end
boneOccupancy = {} -- [boneName] = count (Active projectiles on this bone)


-- HELPER: Find the specific bone nearest to a given actor-local coordinate
-- Now considers occupancy: if a bone is already taken, redirect to 2nd or 3rd closest.
local function findNearestBoneCoordinate(relativePos, isFrontHit, scales)
    scales = scales or { height = 1.0, weight = 1.0 }
    
    -- [RACE SCALING]: Inverse scale the search position to match base bone coordinates
    -- If actor is 1.1x height, their hit at Z=132 corresponds to base bone at Z=120.
    -- More weight = wider actor = hit at X=11 maps to base bone at X=10 if weight scale is 1.1.
    local scaledSearchPos = util.vector3(
        relativePos.x / (scales.weight or 1.0),
        relativePos.y / (scales.weight or 1.0),
        relativePos.z / (scales.height or 1.0)
    )

    local minScore = 1e9
    local bestBone = "Bip01 Arrow Bone 000"
    
    for boneName, coord in pairs(BONES) do
        local dist = (scaledSearchPos - coord):length()
        
        -- STRICT SIDE PENALTY: High penalty (100 units) to prevent selecting bones on the opposite side
        -- Bone side is determined by the pre-inverted BONES data (Logical Front = +Y)
        local boneIsFront = coord.y > 0
        
        -- OCCUPANCY PENALTY: Add 15 units of "virtual distance" per arrow already on this bone
        -- This naturally pushes the selection to the 2nd or 3rd closest bone if the 1st is full.
        local occupancy = boneOccupancy[boneName] or 0
        local score = dist + (occupancy * 15)
        
        if boneIsFront ~= isFrontHit then
            score = score + 100 
        end
        
        if score < minScore then
            minScore = score
            bestBone = boneName
        end
    end
    
    return bestBone, BONE_CATEGORIES[bestBone]
end

-- REGIONAL DAMAGE MULTIPLIERS: High detail anatomical impact effects
local CATEGORY_DAMAGE_MULT = {
    Head      = 2.0,
    BackHead  = 2.25,
    Torso     = 1.0,
    Back      = 1.25,
    LArm      = 0.7,
    RArm      = 0.7,
    RLowerLeg = 0.5,
    LLowerLeg = 0.5,
    RUpperLeg = 0.75,
    LUpperLeg = 0.75,
}

-- [COMPATIBILITY]: Mapping of LPP categories to standard vanilla bones
-- Used when a mesh (like the player's or a modded creature's) lacks custom "Arrow Bones".
local SAFE_BONE_FALLBACKS = {
    Head      = "Bip01 Head",
    BackHead  = "Bip01 Head",
    Torso     = "Bip01 Spine1",
    Back      = "Bip01 Spine",
    LArm      = "Bip01 L UpperArm",
    RArm      = "Bip01 R UpperArm",
    LLowerLeg = "Bip01 L Calf",
    RLowerLeg = "Bip01 R Calf",
    LUpperLeg = "Bip01 L Thigh",
    RUpperLeg = "Bip01 R Thigh"
}



-- Vanilla weight factors (UESP):
local SLOT_WEIGHTS = {
  [SLOT.Cuirass]       = 0.30,
  [SLOT.Helmet]        = 0.10,
  [SLOT.Greaves]       = 0.10,
  [SLOT.Boots]         = 0.10,
  [SLOT.RightPauldron] = 0.10,
  [SLOT.LeftPauldron]  = 0.10,
  [SLOT.RightGauntlet] = 0.05,
  [SLOT.LeftGauntlet]  = 0.05,
  [SLOT.CarriedLeft]   = 0.10,
}

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- Helper: Align a transform with a direction vector (Full 3D)

-- Get an NPC/Player skill's modified value safely.
local function getSkillModified(actor, skillId)
  local function tryLookup(root)
    if not root then return nil end
    local skillTable = root.skills
    if not skillTable then return nil end
    local fn = skillTable[skillId]
    if not fn then return nil end
    local stat = fn(actor)
    return stat and stat.modified
  end

  -- Try various API paths for cross-version compatibility
  local val = tryLookup(types.Actor.stats)
  if val == nil then val = tryLookup(types.NPC.stats) end
  if val == nil and actor.type == types.Player then val = tryLookup(types.Player.stats) end
  
  return val or 0
end

-- Vanilla unarmored AR per *slot*:
local function computeUnarmoredSlotAR(actor)
  local u = getSkillModified(actor, 'unarmored')
  return (u * u) * 0.0065
end

-- Best classification: ask OpenMW which armor skill governs this armor item.
local function getArmorSkillIdForItem(item)
  if Combat and Combat.getArmorSkill then
    local id = Combat.getArmorSkill(item)
    if id == nil then return 'unarmored' end
    return id
  end
  
  local rec = Armor.record(item)
  if not rec then return 'unarmored' end
  
  -- Fallback logic: check weight/type (Simplified)
  if rec.weight == nil then return 'unarmored' end
  if rec.weight > 30 then return 'heavyarmor' end
  if rec.weight > 10 then return 'mediumarmor' end
  return 'lightarmor'
end

-- Per-piece AR (vanilla core):
local function computeEquippedArmorPieceAR(item, actor)
  if (not item) or (not Armor.objectIsInstance(item)) then
    return nil -- caller decides unarmored
  end

  local rec = Armor.record(item)
  if not rec then return nil end

  local baseAR = rec.baseArmor or 0
  local skillId = getArmorSkillIdForItem(item)
  if skillId == 'unarmored' then return nil end

  local armorSkill = getSkillModified(actor, skillId)
  local skillMult = armorSkill / 30

  -- Condition ratio: current / max (max is ArmorRecord.health)
  local maxCond = rec.health or 0
  local curCond = nil
  local data = Item.itemData(item)
  if data then curCond = data.condition end

  if maxCond > 0 then
    if curCond == nil then curCond = maxCond end
    curCond = clamp(curCond, 0, maxCond)
  else
    maxCond = 1
    curCond = 1
  end

  local condMult = curCond / maxCond
  local raw = baseAR * skillMult * condMult

  local pieceFinal = math.floor(raw + 1e-9)
  -- debugLog(string.format('    Piece AR: Skill=%s(%d), Base=%d, Final=%d', skillId, armorSkill, baseAR, pieceFinal))
  
  return pieceFinal
end

local function isEquippedShield(item)
  if not item then return false end
  if not Armor.objectIsInstance(item) then return false end
  local rec = Armor.record(item)
  if not rec then return false end
  return rec.type == Armor.TYPE.Shield
end

-- Direct AR bonus from magic (Shield Effect).
local function computeDirectMagicArmorBonus(actor)
  local maybeEffects = Actor.activeEffects(actor)
  if not maybeEffects then return 0 end

  if maybeEffects.getEffect then
     local shieldEffect = maybeEffects:getEffect(core.magic.EFFECT_TYPE.Shield)
     return (shieldEffect and shieldEffect.magnitude) or 0
  end

  local total = 0
  for _, effect in ipairs(maybeEffects) do
    if effect.id == core.magic.EFFECT_TYPE.Shield then
      total = total + (effect.magnitude or 0)
    end
  end
  return total
end

-- Main computation.
local function computeVanillaArmorRating(actor, options)
  options = options or {}
  if options.includeMagicShield == nil then options.includeMagicShield = true end

  local eq = Actor.getEquipment(actor) or {}
  local unarmoredSlotAR = computeUnarmoredSlotAR(actor)

  local equipmentWeightedAR = 0
  local breakdown = {}
  local anyArmorEquipped = false

  for slot, weight in pairs(SLOT_WEIGHTS) do
    local item = eq[slot]

    if slot == SLOT.CarriedLeft and item and (not isEquippedShield(item)) then
      item = nil
    end

    local slotAR = nil
    if item then
      local pieceAR = computeEquippedArmorPieceAR(item, actor)
      if pieceAR ~= nil then
        slotAR = pieceAR
        anyArmorEquipped = true
      end
    end

    if slotAR == nil then
      slotAR = unarmoredSlotAR
    end

    local contrib = slotAR * weight
    equipmentWeightedAR = equipmentWeightedAR + contrib

    breakdown[slot] = {
      weight = weight,
      slotAR = slotAR,
      contribution = contrib,
      item = item,
    }
  end

  if options.vanillaUnarmoredBug and (not anyArmorEquipped) then
    equipmentWeightedAR = 0
  end

  local magicAR = 0
  if options.includeMagicShield then
    magicAR = computeDirectMagicArmorBonus(actor)
  end

  local totalAR = equipmentWeightedAR + magicAR

  return {
    armorRating = totalAR,
    armorRatingInt = math.floor(totalAR + 1e-9),
    anyArmorEquipped = anyArmorEquipped,
  }
end

-- ============================================================================
-- ACTOR SCRIPT LOGIC
-- ============================================================================

local trackedProjectiles = {}
local boneGroupAnchors = {}
BONE_GROUPS = {
    LowerBody = (anim.BONE_GROUP and anim.BONE_GROUP.LowerBody) or 1,
    Torso = (anim.BONE_GROUP and anim.BONE_GROUP.Torso) or 2,
    LeftArm = (anim.BONE_GROUP and anim.BONE_GROUP.LeftArm) or 3,
    RightArm = (anim.BONE_GROUP and anim.BONE_GROUP.RightArm) or 4
}

-- Effect ID for Resist Normal Weapons (typically 60 in Morrowind)
local EFFECT_ResistNormalWeapons = 60
pcall(function()
    if core.magic and core.magic.EFFECT_TYPE and core.magic.EFFECT_TYPE.ResistNormalWeapons then
        EFFECT_ResistNormalWeapons = core.magic.EFFECT_TYPE.ResistNormalWeapons
    end
end)

local bitOk, bit = pcall(require, 'bit')
if not bitOk or not bit then
    bit = {
        band = function(a, b)
            if b == 8 then return (math.floor(a / 8) % 2 == 1) and 8 or 0 end
            return 0
        end
    }
end

local function debugCreatureInfo(actor)
    debugLog("=== DEBUG CREATURE INFO ===")
    debugLog("Actor: " .. tostring(actor))
    
    local isCreature = types.Creature.objectIsInstance(actor)
    debugLog("Is Creature: " .. tostring(isCreature))
    
    if isCreature then
        local rec = types.Creature.record(actor)
        if rec then
            debugLog("Record ID: " .. tostring(rec.id))
            debugLog("Name: " .. tostring(rec.name))
            
            -- Print all available fields
            pcall(function()
                for k, v in pairs(rec) do
                    debugLog("  " .. tostring(k) .. " = " .. tostring(v))
                end
            end)
        end
    end
    
    -- List active spells
    debugLog("Active Spells:")
    local activeSpells = types.Actor.activeSpells(actor)
    if activeSpells then
        for _, spell in pairs(activeSpells) do
            debugLog("  Spell: " .. tostring(spell.id) .. " / " .. tostring(spell.name))
            if spell.effects then
                for j, eff in pairs(spell.effects) do
                    debugLog("    Effect " .. j .. ": id=" .. tostring(eff.id) .. 
                          ", mag=" .. tostring(eff.magnitude))
                end
            end
        end
    end
    debugLog("=== END DEBUG ===")
end

-- DAMAGE HANDLER (Full Combat API Integration)
-- ========================================
-- KNOCKDOWN HELPER FUNCTIONS
-- ========================================

-- SOUND GENERATION
local function playSoundGen(actor, soundGenType)
    if not actor or not soundGenType then return false end
    
    local soundGenKey = string.lower(soundGenType)
    
    -- Method 1: Via animation system (uses creature/NPC defined sounds)
    if anim.addSoundGen then
        local ok = pcall(function()
            anim.addSoundGen(actor, soundGenKey)
        end)
        if ok then
            -- debugLog("[KNOCKDOWN] Played SoundGen: " .. soundGenKey)
            return true
        end
    end
    
    -- Method 2: Via event to actor
    local ok = pcall(function()
        actor:sendEvent('PlaySoundGen', {soundGen = soundGenKey})
    end)
    if ok then
        -- debugLog("[KNOCKDOWN] Sent PlaySoundGen event: " .. soundGenKey)
        return true
    end
    
    -- Method 3: Fallback to generic sound
    local fallbackSounds = {
        land = "Hand To Hand Hit",
        moan = "Health Damage",
        roar = "Health Damage",
        scream = "Health Damage",
    }
    
    local fallbackSound = fallbackSounds[soundGenKey]
    if fallbackSound then
        pcall(function()
            core.sound.playSound3d(fallbackSound, actor, {volume = 0.8})
        end)
        -- debugLog("[KNOCKDOWN] Played fallback sound: " .. fallbackSound)
        return true
    end
    
    return false
end

-- ATTRIBUTE HELPERS
local function getActorAgility(actor)
    if not actor or not types.Actor.stats then return 50 end
    
    local ok, agility = pcall(function()
        return types.Actor.stats.attributes.agility(actor)
    end)
    
    if ok and agility then
        return agility.modified or agility.base or 50
    end
    return 50
end

local function getActorStrength(actor)
    if not actor or not types.Actor.stats then return 50 end
    
    local ok, strength = pcall(function()
        return types.Actor.stats.attributes.strength(actor)
    end)
    
    if ok and strength then
        return strength.modified or strength.base or 50
    end
    return 50
end

-- KNOCKDOWN CHANCE CALCULATION
-- Based on vanilla Morrowind mechanics:
-- - Final damage output matters (strength + weapon damage + swing)
-- - Defender's Agility reduces chance
-- - 100 Agility = immune
-- - Fatigue does NOT matter
-- - Attacker's Agility does NOT matter
-- - Weapon weight does NOT matter
local function calculateKnockdownChance(target, damage, attacker)
    if not target then return 0 end
    
    -- Get defender's Agility
    local targetAgility = getActorAgility(target)
    
    -- 100 Agility = complete immunity to knockdown
    if targetAgility >= KNOCKDOWN_CONFIG.immunityAgility then
        -- debugLog(string.format("[KNOCKDOWN] Target Agility %d >= %d - IMMUNE", targetAgility, KNOCKDOWN_CONFIG.immunityAgility))
        return 0
    end
    
    -- Get attacker's Strength (affects final damage output)
    local attackerStrength = attacker and getActorStrength(attacker) or 50
    
    -- ========================================
    -- KNOCKDOWN FORMULA (Community Research)
    -- Only final damage output matters:
    -- - High strength helps
    -- - High weapon damage helps
    -- - High swing power helps (already factored into damage)
    -- ========================================
    
    -- Damage contribution (main factor)
    local damageFactor = (damage or 0) * KNOCKDOWN_CONFIG.damageMultiplier
    
    -- Attacker strength bonus (strength above 50 adds, below 50 subtracts)
    local strengthBonus = (attackerStrength - 50) * KNOCKDOWN_CONFIG.strengthFactor
    
    -- Defender agility reduction
    local agilityReduction = targetAgility * KNOCKDOWN_CONFIG.agilityFactor
    
    -- Calculate final knockdown chance
    local knockdownChance = (damageFactor + strengthBonus - agilityReduction) / KNOCKDOWN_CONFIG.divisor
    
    -- Clamp between 0% and 100%
    knockdownChance = math.max(0, math.min(100, knockdownChance))
    
    debugLog(string.format(
        "[KNOCKDOWN] Calc: Damage=%.1f, AtkStr=%d, DefAgi=%d | DmgFactor=%.1f + StrBonus=%.1f - AgiReduce=%.1f = %.1f%%",
        damage or 0, attackerStrength, targetAgility,
        damageFactor, strengthBonus, agilityReduction, knockdownChance
    ))
    
    return knockdownChance
end

-- KNOCKDOWN ROLL
local function rollKnockdown(target, damage, attacker)
    local chance = calculateKnockdownChance(target, damage, attacker)
    
    if chance <= 0 then
        return false
    end
    
    local roll = math.random(100)
    local success = roll <= chance
    
    debugLog(string.format("[KNOCKDOWN] Roll: %d vs Chance: %.1f%% = %s",
        roll, chance, success and "KNOCKDOWN!" or "No knockdown"))
    
    return success
end

-- KNOCKDOWN STATE QUERIES

-- Check if actor is currently knocked down
local function isActorKnockedDown()
    if not isKnockedDown then
        return false
    end
    
    -- Check if knockdown duration has expired
    if core.getSimulationTime() >= knockdownEndTime then
        isKnockedDown = false
        debugLog("[KNOCKDOWN] Recovered from knockdown")
        return false
    end
    
    return true
end

-- Get damage multiplier (50% more damage while knocked down)
local function getKnockdownDamageMultiplier()
    if isActorKnockedDown() then
        return KNOCKDOWN_CONFIG.damageMultiplierWhileDown
    end
    return 1.0
end

-- Get evasion modifier (0 while knocked down)
local function getKnockdownEvasion()
    if isActorKnockedDown() then
        return KNOCKDOWN_CONFIG.evasionWhileDown
    end
    return nil  -- Return nil to indicate no override
end

-- Get remaining knockdown time
local function getKnockdownTimeRemaining()
    if not isActorKnockedDown() then
        return 0
    end
    return math.max(0, knockdownEndTime - core.getSimulationTime())
end

-- PLAY KNOCKDOWN ANIMATION
local function playKnockdownAnimation()
    -- Determine which animation to use
    local knockAnim = nil
    
    -- Try 'knockdown' first
    if anim.hasGroup(self, KNOCKDOWN_CONFIG.knockdownAnim) then
        knockAnim = KNOCKDOWN_CONFIG.knockdownAnim
    -- Fallback to 'knockout'
    elseif anim.hasGroup(self, KNOCKDOWN_CONFIG.knockoutAnim) then
        knockAnim = KNOCKDOWN_CONFIG.knockoutAnim
    end
    
    if not knockAnim then
        debugLog("[KNOCKDOWN] No knockdown/knockout animation available for this actor")
        -- Still apply knockdown state even without animation
        isKnockedDown = true
        knockdownEndTime = core.getSimulationTime() + KNOCKDOWN_CONFIG.defaultDuration
        return false
    end
    
    -- Play the knockdown animation
    local animPlayed = false
    
    -- Try playBlended (preferred)
    if anim.playBlended then
        local ok, err = pcall(function()
            anim.playBlended(self, knockAnim, {
                loops = 0,
                priority = anim.PRIORITY.Knockdown or (anim.PRIORITY.Hit and anim.PRIORITY.Hit + 1) or 100,
                blendMask = anim.BLEND_MASK.All,
            })
        end)
        if ok then
            animPlayed = true
        else
            debugLog("[KNOCKDOWN] playBlended failed: " .. tostring(err))
        end
    end
    
    -- Fallback to playQueued
    if not animPlayed and anim.playQueued then
        local ok, err = pcall(function()
            anim.playQueued(self, knockAnim, {
                loops = 0,
                priority = anim.PRIORITY.Knockdown or (anim.PRIORITY.Hit and anim.PRIORITY.Hit + 1) or 100,
            })
        end)
        if ok then
            animPlayed = true
        else
            debugLog("[KNOCKDOWN] playQueued failed: " .. tostring(err))
        end
    end
    
    if animPlayed then
        debugLog("[KNOCKDOWN] Playing animation: " .. knockAnim)
        
        -- Play 'land' SoundGen (knockout animation has it built-in, but we trigger manually for knockdown)
        playSoundGen(self, 'land')
        
        -- Set knockdown state
        isKnockedDown = true
        
        -- Get animation duration
        local animDuration = KNOCKDOWN_CONFIG.defaultDuration
        if anim.getGroupInfo then
            local ok, info = pcall(function()
                return anim.getGroupInfo(self, knockAnim)
            end)
            if ok and info and info.duration then
                animDuration = info.duration
            end
        end
        
        knockdownEndTime = core.getSimulationTime() + animDuration
        debugLog("[KNOCKDOWN] Duration: " .. animDuration .. "s")
        
        return true
    end
    
    -- Animation failed but still apply state
    debugLog("[KNOCKDOWN] Animation failed, applying state only")
    isKnockedDown = true
    knockdownEndTime = core.getSimulationTime() + KNOCKDOWN_CONFIG.defaultDuration
    return false
end

-- MAIN KNOCKDOWN PROCESSING
local function processKnockdown(damage, attacker)
    -- Already knocked down - don't process again
    if isActorKnockedDown() then
        -- debugLog("[KNOCKDOWN] Already knocked down, skipping")
        return false
    end
    
    -- Roll for knockdown
    if rollKnockdown(self, damage, attacker) then
        playKnockdownAnimation()
        return true
    end
    
    return false
end

-- CHECK IF WEAPON CAN BYPASS IMMUNITY
-- Factors: Enchantment, Silver, or Daedric materials
local function canWeaponBypassImmunity(weaponOrAmmo)
    if not weaponOrAmmo then return false end
    
    local recordId = nil
    local record = nil
    
    -- Handle both objects and strings
    if type(weaponOrAmmo) == "string" then
        recordId = weaponOrAmmo
    elseif weaponOrAmmo.recordId then
        recordId = weaponOrAmmo.recordId
    elseif type(weaponOrAmmo) == "table" and weaponOrAmmo.id then
        -- Some objects might be handled as tables with .id
        recordId = weaponOrAmmo.id
    end
    
    if not recordId then return false end
    
    -- Try to get record safely
    local ok, rec = pcall(function() return types.Weapon.record(recordId) end)
    if ok and rec then
        record = rec
    else
        ok, rec = pcall(function() return types.Ammunition.record(recordId) end)
        if ok and rec then record = rec end
    end
    
    if not record then return false end
    
    -- 1. Check if enchanted (Standard bypass)
    if record.enchant and record.enchant ~= "" then
        return true
    end
    
    -- 2. Check if silver or daedric (Material bypass)
    local idLower = string.lower(recordId)
    local nameLower = string.lower(record.name or "")
    
    if string.find(idLower, "silver") or string.find(nameLower, "silver") then
        return true
    end
    
    if string.find(idLower, "daedric") or string.find(nameLower, "daedric") then
        return true
    end
    
    return false
end

-- Helper to sum magnitude of a specific effect type on an actor
local function getTotalEffectMagnitude(actor, effectId)
    local total = 0
    local activeEffects = types.Actor.activeEffects(actor)
    if activeEffects then
        -- Use numeric loop (safest for OpenMW userdata lists)
        for i = 1, 256 do
            local effect = activeEffects[i]
            if not effect then break end
            if effect.id == effectId then
                total = total + (effect.magnitude or effect.magnitudeMin or 0)
            end
        end
    end
    return total
end

-- Helper to get multiplier for a specific damage type including Magicka resistance/weakness
local function getResistanceMultiplier(actor, damageType)
    local resType = nil
    local weakType = nil
    
    local dt = damageType:lower()
    if dt:find("fire") then
        resType = core.magic.EFFECT_TYPE.ResistFire
        weakType = core.magic.EFFECT_TYPE.WeaknessToFire
    elseif dt:find("frost") then
        resType = core.magic.EFFECT_TYPE.ResistFrost
        weakType = core.magic.EFFECT_TYPE.WeaknessToFrost
    elseif dt:find("shock") then
        resType = core.magic.EFFECT_TYPE.ResistShock
        weakType = core.magic.EFFECT_TYPE.WeaknessToShock
    elseif dt:find("poison") then
        resType = core.magic.EFFECT_TYPE.ResistPoison
        weakType = core.magic.EFFECT_TYPE.WeaknessToPoison
    end
    
    -- Magnitudes of primary resistance/weakness
    local primaryRes = resType and getTotalEffectMagnitude(actor, resType) or 0
    local primaryWeak = weakType and getTotalEffectMagnitude(actor, weakType) or 0
    
    -- Magnitudes of Magicka resistance/weakness
    local magRes = getTotalEffectMagnitude(actor, core.magic.EFFECT_TYPE.ResistMagicka)
    local magWeak = getTotalEffectMagnitude(actor, core.magic.EFFECT_TYPE.WeaknessToMagicka)
    
    -- Combine according to user logic (1 magnitude = 1%)
    local totalRes = primaryRes + magRes
    local totalWeak = primaryWeak + magWeak
    
    local multiplier = 1 + (totalWeak - totalRes) / 100
    return math.max(0, multiplier)
end

-- SHARED HIT PROCESSING LOGIC (Used by both API handler and Fallback Event)
local function isImmuneToNormalWeapons(actor)
    if not actor then return false, 0 end
    
    local isCreature = types.Creature.objectIsInstance(actor)
    local isNPC = types.NPC.objectIsInstance(actor)
    
    if not isCreature and not isNPC then
        return false, 0
    end

    -- ========================================
    -- METHOD 1: Check Actor's Spell List (KNOWNS & ACTIVES)
    -- ========================================
    local function checkSpellList(list, label)
        if not list then return false end
        for i = 1, 256 do
            local spell = list[i]
            if not spell then break end
            if spell.id then
                local lowerId = string.lower(spell.id)
                debugLog(string.format("  Scanning %s: %s", label, lowerId))
                if lowerId == "immune to normal weapons" then
                    return true
                end
            end
        end
        return false
    end

    if checkSpellList(types.Actor.spells(actor), "Known Ability") or 
       checkSpellList(types.Actor.activeSpells(actor), "Active Spell") then
        debugLog("Found ABILITY: immune to normal weapons")
        return true, 100
    end

    local totalResistance = 0

    -- ========================================
    -- METHOD 2: Check Active Effects (MOST RELIABLE)
    -- ========================================
    local activeEffects = types.Actor.activeEffects(actor)
    if activeEffects then
        -- Use numeric loop (safest)
        for i = 1, 256 do
            local effect = activeEffects[i]
            if not effect then break end
            
            if effect.id == core.magic.EFFECT_TYPE.ResistNormalWeapons then
                local mag = effect.magnitude or effect.magnitudeMin or 0
                totalResistance = totalResistance + mag
                debugLog(string.format("Found Resist Normal Weapons: %d%% (%s)", mag, effect.name or "Effect"))
            end
        end
    end
    
    -- If we got 100% resistance, it's immune
    if totalResistance >= 100 then
        -- debugLog("Target is 100%+ resistant to normal weapons.")
        return true, totalResistance
    end

    -- ========================================
    -- METHOD 3: Check Creature Record Flag
    -- ========================================
    if isCreature then
        local ok, creatureRecord = pcall(function() return types.Creature.record(actor) end)
        if ok and creatureRecord then
            if creatureRecord.isImmuneToNormalWeapons then
                debugLog("Inherent Immunity (Record Property) detected")
                return true, 100
            end
        end
    end

    local isImmune = (totalResistance >= 100)
    return isImmune, totalResistance
end

local pendingAttackContext = nil

local function processHit(attack)
    -- [COMBAT-API FIX] OpenMW's Combat API drops custom fields (like boneName and sourceType) 
    -- when routing the attackInfo event to handlers. We retrieve them from our bridge variable.
    if pendingAttackContext then
        attack.sourceType = attack.sourceType or pendingAttackContext.sourceType
        attack.boneName = attack.boneName or pendingAttackContext.boneName
        attack.waterDamageMult = pendingAttackContext.waterDamageMult
    end
    pendingAttackContext = nil -- Consume immediately
    
    debugLog(string.format("[PP-ACTOR-TRACE] processHit called. Source=%s | Bone=%s | LocDmgEnabled=%s", 
        tostring(attack.sourceType), tostring(attack.boneName), tostring(settingsCache.enableLocationalDamage)))
        
    -- [USER FEEDBACK] This script must ONLY process Ranged attacks (Bows, Crossbows, Thrown).
    -- Intercepting Melee or Magic will break Hand-to-Hand damage and other vanilla behaviors.
    if attack.sourceType ~= CombatAPI.ATTACK_SOURCE_TYPES.Ranged and attack.sourceType ~= 'Ranged' then
        return true -- PASS: Let engine and other scripts handle it.
    end

    local healthDmg = (attack.damage and attack.damage.health) or 0
    local fatigueDmg = (attack.damage and attack.damage.fatigue) or 0
    
    -- If no damage is being dealt at all, let other handlers decide.
    if healthDmg <= 0 and fatigueDmg <= 0 then 
        return true 
    end
    
    local damage = healthDmg -- Preserve internal variable name

    -- [LOCATIONAL DAMAGE]
    if attack.boneName and settingsCache.enableLocationalDamage then
        local cat = BONE_CATEGORIES[attack.boneName]
        local mult = cat and CATEGORY_DAMAGE_MULT[cat]
        if mult then
            local oldDmg = damage
            damage = damage * mult
            attack.damage.health = damage
            debugLog(string.format("[PP-ACTOR] Locational Damage: Bone='%s' | Category='%s' | Multiplier=x%.1f | Dmg: %.1f -> %.1f", 
                tostring(attack.boneName), tostring(cat or "Unknown"), mult, oldDmg, damage))
        else
            debugLog(string.format("[PP-ACTOR] Locational Damage: Bone='%s' hit, but no multiplier found for category '%s'", 
                tostring(attack.boneName), tostring(cat or "None")))
        end
    end
    
    -- [WATER DAMAGE]
    if attack.waterDamageMult then
        local oldDmg = damage
        damage = damage * attack.waterDamageMult
        attack.damage.health = damage
        debugLog(string.format("[PP-ACTOR] Water Damage Final Mult: %.1f -> %.1f", oldDmg, damage))
    end

    -- [KNOCKDOWN DAMAGE BONUS]
    -- 50% more physical damage while knocked down
    if isActorKnockedDown() then
        local multiplier = getKnockdownDamageMultiplier()
        damage = damage * multiplier
        attack.damage.health = damage
        debugLog("[PP-ACTOR] Knockdown damage bonus applied: " .. damage)
    end
    
    -- [SHIELD BLOCK CHECK]
    local isBlocked = false
    local eq = types.Actor.getEquipment(self)
    local stance = types.Actor.getStance(self) 
    local shield = eq[types.Actor.EQUIPMENT_SLOT.CarriedLeft]
    
    if shield and stance == types.Actor.STANCE.Weapon and shield.type == types.Armor.TYPE.Shield then
         local attackerPos = attack.hitPos or (attack.attacker and attack.attacker.position)
         if attackerPos then
             local incomeDir = (self.position - attackerPos):normalize()
             local localDir = self.rotation:inverse() * (incomeDir * -1)
             local angle = math.deg(math.atan2(localDir.x, localDir.y))
             
             -- GMST-like Block Angles (Left 90, Right 30?) - Simplified to +/- 45
             if angle >= -45 and angle <= 45 then
                  -- Block Chance logic
                  local blockSkill = types.Actor.stats.skills.block(self).modified
                  local agility = types.Actor.stats.attributes.agility(self).modified
                  local luck = types.Actor.stats.attributes.luck(self).modified
                  local fatigue = types.Actor.stats.dynamic.fatigue(self)
                  local fatigueTerm = (fatigue.current > 0) and (fatigue.current/fatigue.base) or 0
                  local chance = (blockSkill + 0.2*agility + 0.1*luck) * fatigueTerm
                  
                   if math.random(100) < chance then
                        isBlocked = true
                       attack.damage.health = 0 -- Nullify damage
                        
                        debugLog("[PP-ACTOR] Shield Block Successful!")
                       
                       if self.type == types.Player then
                           core.sound.playSound3d("Heavy Armor Hit", self)
                       end
                       
                       return true -- Blocked (Handled)
                  end
             end
         end
    end
    
    -- [IMMUNITY CHECK] (Only if flag is provided, e.g. Fallback Mode)
    -- Engine handles this automatically in API mode, so we only enforce it 
    -- if we are manually applying damage via the Fallback event.
    local canBypass = false
    local weaponRecord = nil
    pcall(function() weaponRecord = types.Weapon.record(attack.weapon) end)
    
    local isLauncher = weaponRecord and (weaponRecord.type == types.Weapon.TYPE.MarksmanBow or weaponRecord.type == types.Weapon.TYPE.MarksmanCrossbow)
    
    if isLauncher then
        canBypass = canWeaponBypassImmunity(attack.ammunition)
    else
        canBypass = canWeaponBypassImmunity(attack.weapon)
    end
    
    if attack.bypassesNormalResistance ~= nil and not attack.bypassesNormalResistance and not canBypass then
         -- Unified check for Spell ID, Creature Flag, and Magic Effect
         local isImmune, resistPercent = isImmuneToNormalWeapons(self)
         if isImmune then
              isBlocked = true
              attack.damage.health = 0
              if attack.attacker and attack.attacker.type == types.Player then
                   attack.attacker:sendEvent('ProjectilePhysics_ShowMessage', {msg = "Your weapon has no effect."})
              end
              debugLog("[PP-ACTOR] Attack Nullified (Target is Immune to Normal Weapons)")
              return true
         elseif resistPercent > 0 then
              local mult = 1 - math.min(1.0, resistPercent / 100)
              attack.damage.health = attack.damage.health * mult
              debugLog(string.format("[PP-ACTOR] Damage Reduced by Resistance: %d%% (New Dmg: %.1f)", resistPercent, attack.damage.health))
         end
    end

    -- [ELEMENTAL DAMAGE] (If not blocked/immune)
    if not isBlocked and (attack.ammunition or attack.weapon) then
         local enchantId = nil
         
         -- Robust ID extraction from either GameObject or String
         local function getEnchantFromItem(item)
             if not item then return nil end
             if type(item) == "string" then
                 -- Try as Weapon ID
                 local ok, rec = pcall(function() return types.Weapon.record(item) end)
                 if ok and rec and rec.enchant ~= "" then return rec.enchant end
                 -- Try as Ammunition ID
                 ok, rec = pcall(function() return types.Ammunition.record(item) end)
                 if ok and rec and rec.enchant ~= "" then return rec.enchant end
             elseif item.recordId then
                 -- GameObject
                 local ok, rec = pcall(function()
                     if item.type == types.Weapon then return types.Weapon.record(item)
                     elseif item.type == types.Ammunition then return types.Ammunition.record(item) end
                 end)
                 if ok and rec and rec.enchant ~= "" then return rec.enchant end
             end
             return nil
         end

         enchantId = getEnchantFromItem(attack.ammunition) or getEnchantFromItem(attack.weapon)
         
         if enchantId and enchantId ~= "" then
              -- Robust Enchantment Record Lookup (mimicking superCast)
              local rec = nil
              if core.magic and core.magic.enchantments then
                  if core.magic.enchantments.records then
                      rec = core.magic.enchantments.records[enchantId]
                  else
                      rec = core.magic.enchantments[enchantId]
                  end
              end

              if rec and rec.effects then
                  local totalElemDmg = 0
                  for i = 1, #rec.effects do
                       local effect = rec.effects[i]
                       if not effect then break end
                       local id = (effect.id or effect.effect or ""):lower()
                       if id ~= "" and (id:find("damage") or id:find("prox") or id:find("abs")) then
                           local min = effect.magnitudeMin or 1
                           local max = effect.magnitudeMax or 1
                           local baseDmg = math.random(min, max)
                           
                           -- Apply Resistances/Weaknesses (User Request)
                           local mult = getResistanceMultiplier(self, id)
                           local finalDmg = baseDmg * mult
                           
                           totalElemDmg = totalElemDmg + finalDmg
                           
                           if mult ~= 1.0 then
                               debugLog(string.format("[PP-ACTOR]   Element %s: %d -> %.1f (Mult: %.2f)", 
                                   id, baseDmg, finalDmg, mult))
                           end
                       end
                  end
                  
                  if totalElemDmg > 0 then
                      attack.damage.health = (attack.damage.health or 0) + totalElemDmg
                      debugLog(string.format("[PP-ACTOR] Added Total Elemental Damage: %.1f from %s", totalElemDmg, enchantId))
                  end
              end
         end
    end
    
    -- [KNOCKDOWN CHECK]
    -- Only on physical hits, not blocked, and damage > 0
    if not isBlocked and damage > 0 then
        local attacker = attack.attacker
        processKnockdown(damage, attacker)
    end
    
    return true -- Continue
end

-- [COMBAT API HANDLER REGISTRATION]
if CombatAPI.addOnHitHandler(processHit) then
    debugLog("[PP-ACTOR] Combat.addOnHitHandler Registered Successfully")
end


local function superCast(enchantId, caster, target, itemObj, hitPosition, isAoe)
    if not enchantId or enchantId == "" then 
        -- debugLog("No enchantId provided")
        return false 
    end
    
    if not target or not types.Actor.activeSpells then
        debugLog("Invalid target or no activeSpells API")
        return false
    end
    
    local activeSpells = types.Actor.activeSpells(target)
    if not activeSpells or not activeSpells.add then 
        debugLog("Cannot get activeSpells for target")
        return false 
    end

    -- 1. Get the enchantment record
    local enchant = nil
    if core.magic and core.magic.enchantments then
        if core.magic.enchantments.records then
            enchant = core.magic.enchantments.records[enchantId]
        else
            enchant = core.magic.enchantments[enchantId]
        end
    end
    
    if not enchant then
        -- debugLog("Could not find enchantment record: " .. tostring(enchantId))
        return false
    end

    -- 2. Build effect indexes (0-based per research)
    local effectIndexes = {}
    if enchant.effects then
        -- OpenMW effects vector index starts at 0
        for i = 0, #enchant.effects - 1 do
            table.insert(effectIndexes, i)
        end
    else
        effectIndexes = {0}
    end
    
    -- 3. Determine the Record ID to use for the activeSpell entry
    -- For item-based enchants, we MUST use the item's record ID
    local sourceRecordId = nil
    if itemObj and itemObj.recordId then
        sourceRecordId = itemObj.recordId
    elseif enchant.id then
        sourceRecordId = enchant.id
    else
        sourceRecordId = enchantId
    end

    -- 4. Apply via activeSpells:add
    local params = {
        id = sourceRecordId,
        effects = effectIndexes,
        caster = caster,
        item = itemObj,
        stackable = false
    }

    local ok, err = pcall(function() activeSpells:add(params) end)
    if ok then 
        debugLog(string.format("SUCCESS applying %s via activeSpells:add", sourceRecordId))
        
        -- ===== PLAY VFX AND SOUNDS FOR EACH EFFECT =====
        if enchant.effects then
            for i = 0, #enchant.effects - 1 do
                local effectData = enchant.effects[i]
                if effectData then
                    -- Get the MagicEffect ID from effect data
                    local effectId = effectData.effect or effectData.id
                    if effectId then
                        -- Get the MagicEffect record (Fire Damage, Frost Damage, etc.)
                        local mgef = (core.magic.effects.records and core.magic.effects.records[effectId]) or core.magic.effects[effectId]
                        
                        if mgef then
                            -- ===== PLAY HIT/AREA SOUND =====
                            local soundId = isAoe and (mgef.areaSound or mgef.hitSound) or (mgef.hitSound or mgef.castSound)
                            if soundId and soundId ~= "" then
                                pcall(function() core.sound.playSound3d(soundId, target) end)
                            end

                            -- ===== PLAY HIT/AREA VFX =====
                            local vfxStaticId = isAoe and mgef.areaStatic or mgef.hitStatic
                            if not vfxStaticId or vfxStaticId == "" then
                                vfxStaticId = mgef.hitStatic or mgef.castStatic
                            end
                            
                            if vfxStaticId and vfxStaticId ~= "" then
                                -- Get the Static record for the model path
                                local staticRecord = (types.Static.records and types.Static.records[vfxStaticId]) or (types.Static and types.Static[vfxStaticId])
                                
                                if staticRecord and staticRecord.model then
                                    local vfxOk = pcall(function()
                                        target:sendEvent('AddVfx', {
                                            model = staticRecord.model,
                                            options = {
                                                particleTextureOverride = mgef.particle or "",
                                                loop = false,  -- Hit effects should not loop
                                                vfxId = "enchant_hit_" .. tostring(enchantId) .. "_" .. tostring(i),
                                            }
                                        })
                                    end)
                                    if vfxOk then
                                        debugLog("  Played VFX: " .. tostring(staticRecord.model))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        -- ===== END VFX AND SOUNDS =====
        
        return true 
    else
        -- 5. Fallback: Try core.magic.cast
        if core.magic.cast then
            local ok2 = pcall(function() core.magic.cast(caster, target, enchant) end)
            if ok2 then 
                debugLog("SUCCESS applying via core.magic.cast: " .. enchantId)
                return true
            end
        end
        debugLog("FAILED enchantment application: " .. tostring(err))
    end

    return false
end

local function onApplyDamage(data)
    debugLog("[PP-ACTOR-TRACE] onApplyDamage entry. Bone: " .. tostring(data and data.boneName))
    if not data then return end
    local isAoe = data.isAoe or false
    
    -- [NPC-ONUSE-BOW] Suppress flag — set by ProjectilePhysics_SuppressNpcOnUseEnchant
    -- before onApplyDamage fires so tryApply can read it.
    local suppressNpcOnUseEnchantId = nil
    if data.suppressNpcOnUseEnchantId then
        suppressNpcOnUseEnchantId = data.suppressNpcOnUseEnchantId
    end
    -- [FIX REFINED] Allow hits on dead bodies (for blood/sticking) but suppress reactions
    -- We check health state before impact
    local hpBuffer = LPP_STATE.getHealth(self)
    local wasAlive = (hpBuffer and hpBuffer.current > 0)
    
    -- [CRITICAL] Cache attacker for murder reporting in onUpdate
    if data.attacker and data.attacker ~= self then
        lastAttacker = data.attacker
        lastAttackerTime = core.getRealTime()
        debugLog("[PP-ACTOR] Cached lastAttacker: " .. tostring(lastAttacker.id))
    end

    -- [COMBAT-API] Check if already processed locally by a script that called onHit directly
    if data.combatHandled then 
        debugLog("[PP-ACTOR] Hit already handled by Combat API. Skipping damage.")
        return 
    end

    debugLog(string.format("onApplyDamage Received | Dmg=%.1f | CombatAPI=%s", 
        data.damage or 0, tostring(CombatAPI.hasCombatAPI)))

    -- Prepare AttackInfo for Combat API
    -- Prepare AttackInfo for Combat API
    local projObj = data.originalProjectile or data.projectile
    local projId = tostring(projObj and (projObj.recordId or projObj.id) or data.ammoRecordId or "Unknown")

    debugLog(string.format("onApplyDamage Received | Dmg=%.1f | Item=%s | CombatAPI=%s", 
        data.damage or 0, projId, tostring(CombatAPI.hasCombatAPI)))

    -- Use recordId strings for weapon/ammunition to avoid handling issues in standard handlers
    local weaponRef = data.launcher or data.weaponRecordId or (projObj and projObj.recordId) or projId
    local ammoRef = projObj or data.ammoRecordId or (data.launcher and projId)

    -- [IMMUNITY CHECK] (Pre-check to nullify before API trigger)
    local canBypass = false
    local weaponRecord = nil
    pcall(function() weaponRecord = types.Weapon.record(weaponRef) end)
    
    local isLauncher = weaponRecord and (weaponRecord.type == types.Weapon.TYPE.MarksmanBow or weaponRecord.type == types.Weapon.TYPE.MarksmanCrossbow)
    
    if isLauncher then
        -- Bows and Crossbows: Only the ammo counts for bypass
        canBypass = canWeaponBypassImmunity(ammoRef)
    else
        -- Thrown weapons (weaponRef is already the projectile)
        canBypass = canWeaponBypassImmunity(weaponRef)
    end
    
    debugLog(string.format("Checking Immunity for hit from %s (Bypass=%s | Manual=%s)", 
        projId, tostring(data.bypassesNormalResistance), tostring(canBypass)))
        
    if data.bypassesNormalResistance == false and not canBypass then
        local isImmune, resistPercent = isImmuneToNormalWeapons(self)
        debugLog(string.format("Immunity Result: Immune=%s, ResistPercent=%d", tostring(isImmune), resistPercent))
        
        if isImmune then
            data.damage = 0
            if data.attacker and data.attacker.type == types.Player then
                data.attacker:sendEvent('ProjectilePhysics_ShowMessage', {msg = "Your weapon has no effect."})
            end
            debugLog(string.format("IMMUNITY BLOCK: Weapon is NOT effective against %s", tostring(self.recordId)))
            -- Output detailed info for debugging
            debugCreatureInfo(self)
        elseif resistPercent > 0 then
            local mult = 1 - math.min(1.0, resistPercent / 100)
            data.damage = data.damage * mult
            debugLog(string.format("RESISTANCE REDUCTION: %d%% (New Dmg: %.1f)", resistPercent, data.damage))
        end
    end

    local attackInfo = {
        target = self,
        attacker = data.attacker,
        damage = { health = data.damage or 0 },
        hitPos = data.hitPos,
        flightDir = data.flightDir,
        sourceType = CombatAPI.ATTACK_SOURCE_TYPES.Ranged,
        weapon = weaponRef,
        ammunition = ammoRef,
        strength = math.min(1.0, data.chargeRatio or 1.0),
        successful = true,
        bypassesNormalResistance = data.bypassesNormalResistance,
        boneName = data.boneName
    }
    
    -- [FIX] Calculate Locational Damage Bone if not provided
    if not attackInfo.boneName and settingsCache.enableLocationalDamage and data.hitPos then
        local invRot = self.rotation:inverse()
        local relativePos = invRot * (data.hitPos - self.position)
        local selectionPos = util.vector3(relativePos.x, -relativePos.y, relativePos.z)
        local isFrontHit = (selectionPos.y > 0)
        attackInfo.boneName, _ = findNearestBoneCoordinate(selectionPos, isFrontHit)
    end
    
    pendingAttackContext = {
        sourceType = attackInfo.sourceType,
        boneName = attackInfo.boneName,
        waterDamageMult = data.waterDamageMult
    } -- Bridge these values over CombatAPI

    -- 1. Try Modern Path: Combat API (Handles damage, sounds, armor, and most enchantments)
    if CombatAPI.onHit(self, attackInfo) then
        -- [XP HOOK] Award Marksman XP on successful hit (if damage > 0 AND was alive)
        if wasAlive and data.attacker and data.attacker.type == types.Player and (data.damage or 0) > 0 then
            data.attacker:sendEvent('ProjectilePhysics_AwardMarksmanXP', {})
        end

        -- [COMBAT-FIX] authoritatively initiate/refresh combat target
        -- If attacker is valid and we are alive, ensure we target them.
        -- This prevents AI dropout for physics-only hits.
        if wasAlive and data.attacker and data.attacker:isValid() and data.attacker ~= self then
            pcall(function()
                if I.Combat and I.Combat.addTarget then
                    -- auth register target in engine
                    I.Combat.addTarget(data.attacker)
                    debugLog("[PP-ACTOR] Refreshed combat target: " .. tostring(data.attacker.id))
                elseif I.AI and I.AI.startPackage then
                    -- Fallback for non-guards/standard NPCs
                    I.AI.startPackage({type='Combat', target=data.attacker})
                    debugLog("[PP-ACTOR] Started Combat package via AI fallback.")
                end
            end)
        end

        -- [ENCHANTMENT FALLBACK] 
        -- Standard OpenMW event-based hits sometimes skip on-strike enchantments for projectiles.
        -- We pro-actively trigger them if we detect an enchantment on the equipment.
        if data.attacker and data.attacker:isValid() then
            -- Use a table to prevent double-activation of the same enchantment (common for thrown weapons)
            local appliedEnchanId = {}
            
            local function tryApply(sourceName, obj, recId)
                
                -- [NPC-ONUSE-BOW] Skip superCast if this enchantment was flagged
                -- as already handled by the engine via the virtual-charge system.
                local now = core.getRealTime()
                if pendingSuppressEnchantId and now < pendingSuppressExpiry then
                    local checkRec = nil
                    local lookupId = (type(recId) == "string") and recId
                                  or (obj and obj.recordId)
                    pcall(function()
                        checkRec = types.Weapon.record(lookupId)
                                or types.Ammunition.record(lookupId)
                    end)
                    if checkRec and checkRec.enchant == pendingSuppressEnchantId then
                        debugLog('[NPC-ONUSE-BOW] superCast suppressed for enchant '
                            .. tostring(pendingSuppressEnchantId))
                        return
                    end
                end
                local rec = nil
                
                -- Try to get record from object first (preserves instance data)
                if obj and obj:isValid() then
                    local ok, err = pcall(function()
                        if obj.type == types.Weapon then rec = types.Weapon.record(obj)
                        elseif obj.type == types.Ammunition then rec = types.Ammunition.record(obj) end
                    end)
                    if ok and rec then 
                        -- debugLog(string.format("  Found record via object: %s", rec.id))
                    end
                end
                
                -- Fallback to static record if object failed or missing
                if not rec and recId then
                    local ok, err = pcall(function()
                        rec = types.Weapon.record(recId) or types.Ammunition.record(recId)
                    end)
                    if ok and rec then 
                        -- debugLog(string.format("  Found record via fallback ID: %s", rec.id))
                    end
                end
                
                if rec and rec.enchant and rec.enchant ~= "" then
                    -- PREVENT DOUBLE-ACTIVATION (e.g. Thrown weapons being both Launcher and Ammo)
                    if appliedEnchanId[rec.enchant] then 
                        -- debugLog("[PP-ACTOR] skipping duplicate enchantment: " .. rec.enchant)
                        return 
                    end
                    
                    if superCast(rec.enchant, data.attacker, self, obj, data.hitPos, isAoe) then
                        appliedEnchanId[rec.enchant] = true
                        -- debugLog("  SUCCESS: Applied enchantment " .. rec.enchant)
                    end
                end
            end
            
            -- Apply for Launcher (Bows/Crossbows)
            if (data.launcher or data.weaponRecordId) and not data.skipLauncherEnchant and not data.skipEnchants then 
                tryApply("Launcher", data.launcher, data.weaponRecordId) 
            end
            
            -- Apply for Ammunition/Projectile (Arrows/Bolts/Thrown)
            if (projObj or data.ammoRecordId) and not data.skipEnchants then 
                tryApply("Projectile", projObj, data.ammoRecordId) 
            end
        end
        return
    end

    -- 2. Fallback Manual Logic (If API missing)
    -- Wrapper to convert event data to AttackInfo format for processHit
    local attack = {
        damage = { health = attackInfo.damage.health },
        hitPos = data.hitPos,
        attacker = data.attacker,
        weapon = data.launcher,
        ammunition = data.ammoRecordId,
        sourceType = 'Ranged',
        bypassesNormalResistance = data.bypassesNormalResistance,
        boneName = attackInfo.boneName
    }
    
    processHit(attack)
    
    -- APPLY DAMAGE MANUALLY
    local dmg = attack.damage.health
    if dmg > 0 then
        local health = LPP_STATE.getHealth(self)
        if health then
            health.current = math.max(0, health.current - dmg)
            debugLog(string.format("[PP-ACTOR] Fallback Damage Applied: %.1f", dmg))
        end
        
        -- Apply Fatigue Damage
        local fatDmg = attack.damage.fatigue
        if fatDmg and fatDmg > 0 then
             local fatigue = types.Actor.stats.dynamic.fatigue(self)
             if fatigue then
                 fatigue.current = math.max(0, fatigue.current - fatDmg)
             end
        end
        
        -- Fallback Death/Murder checks
        if health and health.current <= 0 then
             local attacker = data.attacker
             if self.type ~= types.Player and attacker and attacker:isValid() and attacker ~= self then
                 if attacker.type == types.Player then
                     if core.sendGlobalEvent then core.sendGlobalEvent('ProjectilePhysics_ReportMurder', {victim = self, attacker = attacker}) end
                 end
             end
        end
        
        -- AI Reaction Fallback
        if data.attacker and data.attacker ~= self then
             if types.Actor.startCombat then pcall(function() types.Actor.startCombat(self, data.attacker) end) end
        end
    end

     -- [ENCHANTMENT APPLICATION] (Skip if handled by global)
     if not data.skipEnchants and data.attacker and data.attacker:isValid() and data.attacker ~= self then
          -- Apply Weapon Enchantment
          if data.launcher and data.launcher:isValid() then
               local weaponRec = types.Weapon.record(data.launcher)
               if weaponRec and weaponRec.enchant and weaponRec.enchant ~= "" then
                    superCast(weaponRec.enchant, data.attacker, self, data.launcher, data.hitPos, isAoe)
               end
          end
          
          -- Apply Ammunition/Projectile Enchantment 
          local ammoEnchant = nil
          if data.ammoRecordId then
               local ammoRec = nil
               pcall(function() 
                    ammoRec = types.Ammunition.record(data.ammoRecordId) or types.Weapon.record(data.ammoRecordId)
               end)
               if ammoRec and ammoRec.enchant and ammoRec.enchant ~= "" then
                    ammoEnchant = ammoRec.enchant
               end
          end
          
          if ammoEnchant then
               superCast(ammoEnchant, data.attacker, self, nil, data.hitPos, isAoe)
          end
     end
end

-- DEATH ANIMATION DETECTION - Returns key for poseTransforms lookup (Death1-Death5)
local deathAnimLogged = false -- Only debugLog once per actor death

getDeathAnimationType = function(forceLog)
    if stateCache.deathAnim and not forceLog then return stateCache.deathAnim end

    -- [FIX] Only check Torso group - the engine plays death anims on ALL groups
    -- simultaneously, so checking multiple groups just returns duplicates and adds noise.
    local torsoGroup = BONE_GROUPS.Torso
    local torsoAnim = (anim.getActiveGroup(self, torsoGroup) or ""):lower()
    
    local result = nil
    local source = "unknown"
    
    -- Match death1 through death5
    if torsoAnim:find("death5") then result = "Death5"; source = "torso-group"
    elseif torsoAnim:find("death4") then result = "Death4"; source = "torso-group"
    elseif torsoAnim:find("death3") then result = "Death3"; source = "torso-group"
    elseif torsoAnim:find("death2") then result = "Death2"; source = "torso-group"
    elseif torsoAnim:find("death1") then result = "Death1"; source = "torso-group"
    end

    -- [RECOVERY] If group name didn't specify index (or nil), check completion
    if not result then
        local maxComp = 0
        local bestIdx = 1
        for i = 1, 5 do
            local comp = anim.getCompletion(self, 'death' .. i)
            if comp and comp > maxComp then
                maxComp = comp
                bestIdx = i
            end
        end
        if maxComp > 0 then
            result = 'Death' .. bestIdx
            source = 'completion-check(max=' .. string.format("%.2f", maxComp) .. ')'
        end
    end
    
    -- Fallback
    if not result and torsoAnim:find("death") then 
        result = "Death1"
        source = "generic-death-fallback"
    end
    
    if not result then
        local health = types.Actor.stats.dynamic.health(self)
        if health and health.current <= 0 then
            result = "Death1"
            source = "dead-health-fallback"
        end
    end
    
    -- LOGGING: Force log if requested OR if first time
    if result and (forceLog or not deathAnimLogged) then
        local logMsg = string.format('[PP-ACTOR] DEATH ANIM DETECTION | Result: %s | Source: %s | TorsoGroup: [%s:%s] | Actor: %s',
            tostring(result), source, tostring(torsoGroup), torsoAnim, tostring(self.recordId or self.id))
        
        -- Use print to ensure it definitely hits the console/log
        debugLog(logMsg)
        deathAnimLogged = true
    end
    
    if result then stateCache.deathAnim = result end
    return result
end

-- POSTURE FACTOR
local function getMeshHeightFactor()
    -- Death state always overrides static posture logic
    if cachedIsDead then return 0.15 end

    -- [OPTIMIZATION] Static caching: Posture factor is calculated once and reused.
    -- Dynamic changes (crouch/fall) are ignored to save performance.
    if stateCache.heightFactor then
        return stateCache.heightFactor
    end

    local gTorso = BONE_GROUPS.Torso
    local gLower = BONE_GROUPS.LowerBody
    local t = (anim.getActiveGroup(self, gTorso) or ""):lower()
    local l = (anim.getActiveGroup(self, gLower) or ""):lower()
    
    local result = 1.0
    if l:find("knock") or t:find("knock") or l:find("fall") then result = 0.25
    elseif t:find("hit") or t:find("stagger") then result = 0.80
    elseif types.Actor.getStance(self) == 2 then result = 0.65
    end
    
    stateCache.heightFactor = result
    return result
end

local function getBoneGroupForImpact(impactPos)
    local scales = getActorRaceScales(self)
    local relativePos = self.rotation:inverse() * (impactPos - self.position)
    -- [LOGICAL INVERSION]: Rig forward is Y-. Flip for selection logic (+Y = Front).
    local logicPos = util.vector3(relativePos.x, -relativePos.y, relativePos.z)
    
    local isFrontHit = logicPos.y > 0
    local boneName, cat = findNearestBoneCoordinate(logicPos, isFrontHit, scales)
    
    -- MAP HIGH-PRECISION CATS TO ENGINE GROUPS
    local engineGroup = "Torso"
    if cat:find("Leg") or cat:find("Foot") then engineGroup = "LowerBody"
    elseif cat:find("LArm") then engineGroup = "LeftArm"
    elseif cat:find("RArm") then engineGroup = "RightArm"
    end

    local groupId = BONE_GROUPS[engineGroup] or BONE_GROUPS.Torso
    
    return engineGroup, groupId, boneName
end

-- ============================================================================
-- VFX STICKING SYSTEM (Coordinate Precision System Active)
-- ============================================================================


-- Registry of stuck VFX: { [vfxId] = { boneName = string } }
local vfxSettings = { lifetime = 120, useAmbientLight = false }

local function onRemoveVfx(data)
    local vfxId = data.vfxId
    local entry = stuckVfxRegistry[vfxId]
    
    debugLog(string.format('onRemoveVfx called for actor %s with vfxId: %s (Found in Local Registry: %s)', 
        tostring(self.recordId or self.id), tostring(vfxId), tostring(entry ~= nil)))

    -- [IRONCLAD MASS-HARVEST GUARD]
    -- If the body is dead, or actively dying, and we are in mass_harvest mode, ABSOLUTELY DO NOT allow VFX deletion.
    -- (unless the global script explicitly requested it as an authorized cleanup, e.g. mass-harvest scavenging)
    local pMode = vfxSettings.pickupMode or settingsCache.pickupMode or 'inventory'
    if pMode == 'mass_harvest' and LPP_STATE.isAtZeroHealth and not data.isGlobalCleanup then
        debugLog(string.format('[PP-ACTOR] IRONCLAD BLOCK: Refusing to remove VFX %s because mass_harvest preserves it on dead bodies!', tostring(vfxId)))
        return
    end
    
    if vfxId and entry then
        debugLog(string.format('Removing VFX %s from bone %s (Record: %s)', 
            tostring(vfxId), tostring(entry.boneName), tostring(entry.ammoRecordId)))
        
        local ok, err = pcall(function() anim.removeVfx(self, vfxId) end)
        if not ok then
            debugLog('anim.removeVfx FAILED: ' .. tostring(err))
        else
            debugLog('anim.removeVfx SUCCECCEEDED for ' .. tostring(vfxId))
        end
        
        removeStuckVfx(vfxId)
    else
        -- If it wasn't in our registry, maybe the engine still has it?
        -- Attempt a blind removal just in case of refresh desync
        debugLog('vfxId not found in local registry. Attempting blind removal...')
        pcall(function() anim.removeVfx(self, vfxId) end)
    end
end

local function removeAllStuckVfx()
    local ids = {}
    for id, _ in pairs(stuckVfxRegistry) do table.insert(ids, id) end
    for _, id in ipairs(ids) do
        removeStuckVfx(id)
        pcall(function() anim.removeVfx(self, id) end)
    end
    stuckVfxCount = 0
    boneOccupancy = {}
end

-- HELPER: Find the specific bone nearest to a world position for individual sticking


local function onAttachVfxArrow(data)
    if not data.model or data.model == '' then return end
    
    if data.pickupMode then vfxSettings.pickupMode = data.pickupMode end
    
    local flightDir = data.flightDir or (self.rotation * util.vector3(0, -1, 0))

    local selectionPos = data.logicSurfacePos
    if not selectionPos then
        local raw = data.relativePos
        selectionPos = util.vector3(raw.x, -raw.y, raw.z)
    end

    local isFrontHit = (selectionPos.y > 0)
    local boneName = data.boneName
    local cat = "unknown"
    
    if not boneName then
        boneName, cat = findNearestBoneCoordinate(selectionPos, isFrontHit)
    end

    local vfxId = data.vfxId or ('pp_stuck_' .. tostring(core.getRealTime()) .. '_' .. tostring(math.random(1000)))

    -- ═══════════════════════════════════════════════════════════════════
    -- MATCH FRIEND EXACTLY: No offset, no rotation override
    -- ═══════════════════════════════════════════════════════════════════
    local ok, err = pcall(function()
        anim.addVfx(self, data.model, {
            loop     = true,
            boneName = boneName,
            vfxId    = vfxId,
            -- NO offset
            -- NO rotation
        })
    end)

    if ok then
        -- ═══════════════════════════════════════════════════════════════════
        -- Store actor transform NOW for consistent item spawn later
        -- ═══════════════════════════════════════════════════════════════════
        addStuckVfx(vfxId, {
            boneName         = boneName,
            ammoRecordId     = data.ammoRecordId,
            projectileType   = data.projectileType or 'arrow',
            actorPosAtAttach = self.position,
            actorRotAtAttach = self.rotation,
            actorScaleAtAttach = self.scale or 1.0,
        })
        
        -- Sync inventory cache immediately on attach to track future looting
        if data.ammoRecordId then
            local lowAmmoId = data.ammoRecordId:lower()
            local inv = Actor.inventory(self)
            local currentTotal = 0
            local ok, allItems = pcall(function() return inv:getAll() end)
            if ok and allItems then
                for _, item in ipairs(allItems) do
                    if item.recordId:lower() == lowAmmoId then
                        currentTotal = currentTotal + item.count
                    end
                end
            end
            LPP_STATE.cachedAmmoCounts[lowAmmoId] = currentTotal
        end
        boneOccupancy[boneName] = (boneOccupancy[boneName] or 0) + 1
        
        debugLog(string.format("[VFX-ATTACH] Bone:%s Pos:%s Rot:%s", 
            boneName, tostring(self.position), tostring(self.rotation)))
        debugTransformState("VFX_ATTACH", boneName)
    else
        debugLog('[PP-ACTOR] VFX Attach FAILED: ' .. tostring(err))
    end
end

-- [RAGDOLL ANCHORS] Standard Bip01 bones for ragdoll mapping
-- Defined in Logic Space (Y+ Front) to match processed BONES
local PHYSICAL_ANCHORS = {
    ['Bip01 Head'] = util.vector3(0, 4, 126),
    ['Bip01 Spine2'] = util.vector3(0, 0, 95),
    ['Bip01 Spine1'] = util.vector3(0, -2, 75),
    ['Bip01 Pelvis'] = util.vector3(0, -2, 45),
    ['Bip01 L UpperArm'] = util.vector3(-14, 2, 105),
    ['Bip01 L Forearm'] = util.vector3(-16, 2, 80),
    ['Bip01 L Hand'] = util.vector3(-16, 2, 55),
    ['Bip01 R UpperArm'] = util.vector3(14, 2, 105),
    ['Bip01 R Forearm'] = util.vector3(16, 2, 80),
    ['Bip01 R Hand'] = util.vector3(16, 2, 55),
    ['Bip01 L Thigh'] = util.vector3(-8, 0, 45),
    ['Bip01 L Calf'] = util.vector3(-8, 0, 23),
    ['Bip01 L Foot'] = util.vector3(-8, 2, 4),
    ['Bip01 R Thigh'] = util.vector3(8, 0, 45),
    ['Bip01 R Calf'] = util.vector3(8, 0, 23),
    ['Bip01 R Foot'] = util.vector3(8, 2, 4),
}


local function onConvertVfxToActivator(data)
    -- [FIX] Force fresh settings read - this event fires from global BEFORE onUpdate's refreshSettingsCache()
    refreshSettingsCache()
    
    local vfxId = data.vfxId
    local entry = stuckVfxRegistry[vfxId]
    local pMode = vfxSettings.pickupMode or settingsCache.pickupMode or 'inventory'
    
    if not entry or not entry.boneName then
        debugLog('[PP-ACTOR] ERROR: No VFX entry for ' .. tostring(vfxId))
        return
    end
    
    -- =========================================================================
    -- POSETRANSFORMS HARDCODED SOLUTION
    -- Use pre-calculated bone positions/rotations for death animations.
    -- Pattern: worldPos = rotation * localPos + position
    --          worldRot = rotation * localRot
    -- =========================================================================
    
    -- The VFX was stuck at this bone (e.g., "Bip01 Arrow Bone 042")
    local boneName = entry.boneName
    
    -- 1. Get the dead NPC's base position and rotation
    local position = self.position
    local rotation = self.rotation
    
    -- 2. Detect which death animation is playing (Death1 through Death5)
    local deathAnim = getDeathAnimationType()
    if not deathAnim then
        deathAnim = "Death1" -- Fallback
    end
    
    debugLog(string.format('[PP-ACTOR] VFX->Activator | VFX: %s | Bone: %s | DeathAnim: %s | ActorPos: %s', 
        vfxId, boneName, deathAnim, tostring(position)))
    
    -- 3. Get the pre-calculated bone transform from poseTransforms
    local poseData = poseTransforms[deathAnim]
    if not poseData then
        debugLog('[PP-ACTOR] ERROR: No poseTransforms data for ' .. deathAnim)
        return
    end
    
    local boneData = poseData[boneName]
    if not boneData then
        debugLog(string.format('[PP-ACTOR] WARNING: Bone %s not in poseTransforms[%s]', boneName, deathAnim))
        return
    end
    
    -- 4. Extract the local position and rotation from poseTransforms
    local localPos = boneData.position
    local localRot = boneData.rotation
    
    local scales = getActorRaceScales(self)
    
    -- 5. Transform to world space (Applying race scales to pre-calculated pose):
    local scaledLocalPos = util.vector3(
        localPos.x * (scales.weight or 1.0),
        localPos.y * (scales.weight or 1.0),
        localPos.z * (scales.height or 1.0)
    )
    local worldPos = rotation * scaledLocalPos + position
    local worldRot = rotation * localRot
    
    debugLog(string.format('[PP-ACTOR] PoseTransform (Sync): LocalPos=%s -> WorldPos=%s | DeathAnim: %s', 
        tostring(localPos), tostring(worldPos), deathAnim))
    
    -- 6. Get the activator mesh path
    local itemRec = nil
    if types.Ammunition then itemRec = types.Ammunition.record(data.ammoRecordId) end
    if not itemRec and types.Weapon then itemRec = types.Weapon.record(data.ammoRecordId) end
    
    if not itemRec or not itemRec.model then
        debugLog('[PP-ACTOR] ERROR: No model for ' .. tostring(data.ammoRecordId))
        return
    end
    
    local modelPath = itemRec.model:gsub("^[mM][eE][sS][hH][eE][sS][/\\]", "LPP/meshes/luaactmeshes/")
    
    -- 7. Spawn the activator at poseTransforms position
    -- [REVISION 61] If mass_harvest or inventory, we DO NOT spawn an activator or remove VFX
    local skipActivatorSpawn = (pMode ~= 'activation')
    
    core.sendGlobalEvent('ProjectilePhysics_SpawnActivatorAtPos', {
        ammoRecordId = data.ammoRecordId,
        model = modelPath,
        pos = worldPos,
        rot = worldRot,
        boneName = boneName,
        actor = self,
        scale = self.scale or 1.0,
        isMassHarvestAction = skipActivatorSpawn -- Flag for global script to only strip inventory
    })
    
    if not skipActivatorSpawn then
        debugLog('[PP-ACTOR] SUCCESS: Replaced VFX ' .. vfxId .. ' with Activator')
        
        -- 8. Remove the VFX
        pcall(function() anim.removeVfx(self, vfxId) end)
        
        -- 9. Release bone occupancy & cleanup
        removeStuckVfx(vfxId)
    else
        -- [MASS-HARVEST] Just preservation
        -- We keep it in stuckVfxRegistry so the specialized harvest action can find it later.
        debugLog('[PP-ACTOR] [MASS-HARVEST] Sent strip-request for VFX ' .. vfxId .. '. PRESERVING VFX IN REGISTRY.')
    end
end

local function onSyncVfxSettings(data)
    if data.lifetime then vfxSettings.lifetime = data.lifetime end
end

local function onRequestBoneFit(data)
    local impactPos = data.impactPos
    local groupName, groupId, boneName = getBoneGroupForImpact(impactPos)
    
    -- Use the specific coordinate-fit bone for the physics proxy
    addTrackedProjectile(data.projectileId, {groupName = groupName, groupId = groupId, boneName = boneName})
    
    core.sendGlobalEvent('ProjectilePhysics_InitialBoneResponse', {
        projectileId = data.projectileId, 
        boneName = boneName, -- SEND THE REAL BONE, NOT THE GROUP NAME
        bonePos = self.position, 
        boneRot = self.rotation
    })
end





local function onUpdate(dt)
    -- [USER REQUEST] EXCLUDE PLAYER from actor script processing
    -- Running NPC logic on the player causes control/animation interference.
    if self.type == types.Player then return end

    -- =========================================================================
    
    -- 1. [DISTANCE SKIP] If actor is outside processing range, stop immediately.
    -- This is the cheapest possible check.
    if types.Actor.isInActorsProcessingRange and not types.Actor.isInActorsProcessingRange(self) then
        return
    end

    local now = core.getRealTime()
    local hasProjectiles = (LPP_STATE.trackedProjectileCount or 0) > 0
    local hasVfx = (LPP_STATE.stuckVfxCount or 0) > 0

    -- 1a. [SETTINGS REFRESH] (Check every 5s)
    if now - lastSettingsRefreshTime > 5.0 then
        refreshSettingsCache()
        lastSettingsRefreshTime = now
    end


    -- 2. [STATE-BASED GUARD] Nothing active, no combat
    if not hasProjectiles and not hasVfx then
        if now < (LPP_STATE.nextActivityCheck or 0) then
            -- [OPTIMIZATION] If we aren't at zero health, OR we are already fully dead/processed, exit here safely.
            if not LPP_STATE.isAtZeroHealth or LPP_STATE.cachedIsDead then return end
        end
    end

    -- 3. [HARD RETURN] Dead and Processed
    -- If actor is dead and we've already handled their physics/VFX conversion, stop everything.
    if LPP_STATE.cachedIsDead and not hasVfx and not hasProjectiles then
        -- [USER REQUEST] Hibernate briefly until activated or re-scanned.
        LPP_STATE.nextActivityCheck = now + 10.0 -- 10s hibernation
        return
    end

    -- 4. [THROTTLED COMBAT/ACTIVITY SCAN]
    -- Only scan stance and equipment every 0.15s if nothing is happening.
    if not hasProjectiles and not hasVfx and now >= (LPP_STATE.nextActivityCheck or 0) then
        -- ONE-TIME ELIGIBILITY CHECK: Can this actor ever use ranged?
        if not isActorEligibleForRangedProcessing() then
            LPP_STATE.nextActivityCheck = now + 60.0 -- Check very rarely
            LPP_STATE.scriptActive = false
            LPP_STATE.isRangedCombatActive = false
            return
        end
        
        local stance = types.Actor.getStance(self)
        local isMagicStance = (stance == types.Actor.STANCE.Spell)

        if stance ~= types.Actor.STANCE.Weapon and not isMagicStance then
            LPP_STATE.scriptActive = false
            LPP_STATE.isRangedCombatActive = false
            LPP_STATE.nextActivityCheck = now + 0.5
            return
        end
        
        local equipment = Actor.getEquipment(self)
        local weapon = equipment[SLOT.CarriedRight]
        local isRanged, _, weaponRecord = isProjectileWeapon(weapon)

        if not weapon or not isRanged then
            LPP_STATE.scriptActive = false
            LPP_STATE.isRangedCombatActive = false
            LPP_STATE.nextActivityCheck = now + 0.5
            return
        end

        -- NPC Proactive Divert (Weapon is Bow/XBow, stance is Spell)
        if isMagicStance and self.type ~= types.Player and settingsCache.rangedOnUseToOnStrike and weaponRecord and weaponRecord.enchant ~= "" then
            local enchant = core.magic.enchantments and core.magic.enchantments.records and core.magic.enchantments.records[weaponRecord.enchant] or core.magic.enchantments and core.magic.enchantments[weaponRecord.enchant]
            if enchant and enchant.type == core.magic.ENCHANTMENT_TYPE.CastOnUse then
                pcall(function() types.Actor.setStance(self, types.Actor.STANCE.Weapon) end)
                debugLog("[PP-ACTOR] Proactively Diverted NPC Bow Cast (" .. tostring(self.recordId) .. ")")
            end
        end

        LPP_STATE.scriptActive = true
        LPP_STATE.isRangedCombatActive = true
        LPP_STATE.nextActivityCheck = now + 0.15
    end

    -- 5. [THROTTLED DEATH DETECTION] (Check every 0.25s)
    if not LPP_STATE.lastHealthCheck or (now - LPP_STATE.lastHealthCheck > (LPP_STATE.ACTIVE_CHECK_INTERVAL or 0.25)) then
        LPP_STATE.lastHealthCheck = now
        
        local startedAtZero = (LPP_STATE.isAtZeroHealth == true)
        LPP_STATE.isAtZeroHealth = false
        local okDead, resDead = pcall(function() return types.Actor.isDead(self) end)
        if okDead then LPP_STATE.isAtZeroHealth = resDead
        else
            local health = LPP_STATE.getHealth(self)
            LPP_STATE.isAtZeroHealth = health and health.current <= 0
        end

        if LPP_STATE.isAtZeroHealth then
            if not LPP_STATE.zeroHealthStartTime then 
                LPP_STATE.zeroHealthStartTime = now 
                
                -- [REVISION 62] Immediate settings refresh to ensure correct mode during death transition
                refreshSettingsCache()
                
                -- [REVISION 62] Trigger inventory strip for stuck projectiles only
                if settingsCache.pickupMode == 'mass_harvest' or settingsCache.pickupMode == 'activation' then
                    core.sendGlobalEvent('ProjectilePhysics_StripInventoryOnDeath', {actor = self})
                end
            end
        else
            LPP_STATE.zeroHealthStartTime = nil
        end

        local isDeathDone = false
        local okFinished, resFinished = pcall(function() return types.Actor.isDeathFinished(self) end)
        if okFinished then isDeathDone = resFinished
        else isDeathDone = LPP_STATE.isAtZeroHealth and (now - (LPP_STATE.zeroHealthStartTime or now) > 3.0) end

        if isDeathDone and not LPP_STATE.hasLoggedDeath then
            debugTransformState("DEATH_DONE")
            LPP_STATE.hasLoggedDeath = true
        end

        if LPP_STATE.isAtZeroHealth and not isDeathDone and (now - (LPP_STATE.zeroHealthStartTime or now) > 4.0) then
            isDeathDone = true
        end
        LPP_STATE.cachedIsDead = isDeathDone
    end

    -- [SETTINGS SYNC] Hard Return if nothing else matters
    if not LPP_STATE.settingsInitialized then
        core.sendGlobalEvent('ProjectilePhysics_RequestSettingsSync', {actorId = self.id})
        LPP_STATE.settingsInitialized = true
    end

    -- [KNOCKDOWN TRACKING]
    -- [USER REQUEST] Simplified for local actor context (avoids illegal nearby access)
    if isKnockedDown then
        if core.getRealTime() > (knockdownEndTime or 0) then
            isKnockedDown = false
            debugLog("[KNOCKDOWN] Knockdown state ended via timer")
        end
    end

    -- [FINAL LOGIC] Only run updates if active
    if LPP_STATE.isRangedCombatActive and not LPP_STATE.cachedIsDead then
        updateCustomAttack(dt)
    end

    -- [MURDER REPORTING]
    if LPP_STATE.isAtZeroHealth and not LPP_STATE.murderReported and lastAttacker and lastAttacker:isValid() then
        local timeSinceHit = now - lastAttackerTime
        if lastAttacker.type == types.Player and timeSinceHit < 5.0 then
            -- [USER REQUEST] Aggressor check (Fight > 70 = No Murder)
            local skipReport = false
            local fightStat = types.Actor.stats.ai.fight(self)
            if fightStat and fightStat.modified > 70 then
                debugLog('[PP-ACTOR] Murder report skipped: Victim was aggressive (Fight: ' .. tostring(fightStat.modified) .. ')')
                skipReport = true
            end

            if not skipReport then
                LPP_STATE.murderReported = true
                core.sendGlobalEvent('ProjectilePhysics_ReportMurder', {victim = self, attacker = lastAttacker})
                debugLog('[PP-ACTOR] Murder reported for ' .. tostring(self.recordId))
            end
        end
    end

    -- [OPTIMIZATION] Lazy Physics Calculation
    if hasProjectiles then
        local results = {}
        local any = false
        local scales = getActorRaceScales(self)
        for projId, trackData in pairs(trackedProjectiles) do
            local bonePos = getBoneWorldPos(self, trackData.boneName or "Bip01 Arrow Bone 000")
            results[projId] = { 
                pos = self.position, 
                rot = self.rotation, 
                bonePos = bonePos,
                boneName = trackData.boneName, 
                isProxy = true, 
                isDead = LPP_STATE.isAtZeroHealth, 
                heightFactor = getMeshHeightFactor(), 
                boneGroup = trackData.groupName, 
                deathAnimType = LPP_STATE.isAtZeroHealth and getDeathAnimationType() or nil,
                scales = scales
            }
            any = true
        end
        if any then core.sendGlobalEvent('ProjectilePhysics_UpdateBoneSync', {targetId = self.id, bones = results}) end
    end

    -- Reset flags if actor comes back to life (resurrection)
    if not LPP_STATE.isAtZeroHealth then
        LPP_STATE.vfxConvertedOnDeath = false
        LPP_STATE.deathBoneCaptureScheduled = false
        LPP_STATE.murderReported = false
        stateCache.deathAnim = nil
    end

    -- =========================================================================
    -- [USER REQUEST] RETURN EARLY if no VFX
    -- This skips the expensive inventory sync and death conversion logic.
    -- =========================================================================
    if not hasVfx then return end

    -- =========================================================================
    -- VFX DEATH CONVERSION (ONLY if we have stuck VFX)
    -- =========================================================================
    if hasVfx then
        -- 1. Inventory Sync (Looting & Consumption Detector)
        local nowSim = core.getSimulationTime()
        if (nowSim - LPP_STATE.lastInvSyncTime) > 0.4 then
            LPP_STATE.lastInvSyncTime = nowSim
            local inv = Actor.inventory(self)
            if inv then
                -- Group VFX by ammoId
                local vfxGrouped = {}
                for vfxId, entry in pairs(stuckVfxRegistry) do
                    local ammoId = (entry.ammoRecordId or "unknown"):lower()
                    if not vfxGrouped[ammoId] then vfxGrouped[ammoId] = {} end
                    table.insert(vfxGrouped[ammoId], vfxId)
                end
                
                -- Get current counts
                local currentCounts = {}
                local ok, allItems = pcall(function() return inv:getAll() end)
                if ok and allItems then
                    for _, item in ipairs(allItems) do
                        local rid = item.recordId:lower()
                        if vfxGrouped[rid] then
                            currentCounts[rid] = (currentCounts[rid] or 0) + item.count
                        end
                    end
                end
                
                -- [REFINEMENT] Handle loot breakage for 'inventory' mode
                -- If items are removed from dead NPC while in inventory mode, apply success roll.
                local pMode = vfxSettings.pickupMode or settingsCache.pickupMode or 'inventory'
                local player = nearby.players[1]
                
                for ammoId, vfxList in pairs(vfxGrouped) do
                    local current = currentCounts[ammoId] or 0
                    local last = LPP_STATE.cachedAmmoCounts[ammoId] or current
                    
                    if current < last then
                        local consumed = last - current
                        
                        -- [REFINEMENT] Handle inventory count drops
                        -- Determine if VFX should be removed based on actor state and pickup mode:
                        -- 1. Actor ALIVE (combat): NPC used ammo → remove VFX (they pulled the arrow out)
                        -- 2. Actor DEAD + inventory mode: player looted → remove VFX + breakage roll
                        -- 3. Actor DEAD + mass_harvest/activation: StripInventoryOnDeath fired → KEEP VFX
                        -- [RACE CONDITION FIX] Evaluate health NOW rather than relying on the 0.25s throttled cache
                        local isActuallyDead = false
                        local okDead, resDead = pcall(function() return types.Actor.isDead(self) end)
                        if okDead then 
                            isActuallyDead = resDead 
                        else
                            local hp = LPP_STATE.getHealth(self)
                            isActuallyDead = hp and hp.current <= 0
                        end
                        
                        if not isActuallyDead then
                            -- Living NPC used ammo in combat
                            debugLog("[SYNC-ACTOR] " .. consumed .. " x " .. ammoId .. " consumed by living NPC. Removing VFX.")
                            for i = 1, math.min(consumed, #vfxList) do
                                onRemoveVfx({ vfxId = vfxList[i] })
                            end
                        elseif pMode == 'inventory' then
                            -- Dead NPC, inventory mode: player looted from corpse
                            debugLog("[SYNC-ACTOR] " .. consumed .. " x " .. ammoId .. " looted from corpse (inventory mode). Removing VFX.")
                            for i = 1, math.min(consumed, #vfxList) do
                                onRemoveVfx({ vfxId = vfxList[i] })
                            end
                            
                            -- Inform Global for breakage roll
                            core.sendGlobalEvent('ProjectilePhysics_OnLootedFromInventory', {
                                player = player,
                                recordId = ammoId,
                                count = consumed,
                                actor = self
                            })
                        else
                            -- Dead NPC, mass_harvest/activation: StripInventoryOnDeath stripped items
                            -- DO NOT remove VFX — they stay on the body for manual harvest
                            debugLog("[SYNC-ACTOR] " .. consumed .. " x " .. ammoId .. " stripped from corpse (" .. pMode .. "). PRESERVING VFX.")
                        end
                    end
                    LPP_STATE.cachedAmmoCounts[ammoId] = current
                end
            end
        end

        local pickupModeVal = (vfxSettings.pickupMode == 'activation') or 
                              (settingsCache.pickupMode == 'activation')
        
        -- Master trigger: Health is 0 OR engine says dead
        local startedDying = LPP_STATE.isAtZeroHealth
        
        -- Periodic diagnostic heartbeat (every 2s while dying)
        -- Only log if we are actually WAITING for a conversion (mass_harvest or activation)
        if startedDying and not LPP_STATE.vfxConvertedOnDeath and pickupModeVal and (math.floor(now) % 2 == 0) then
            debugLog(string.format("[PP-ACTOR-CONV] Waiting for conversion on %s: isDead=%s, isDeathDone=%s, pickupMode=%s, VfxCount=%d, TimeAtZero=%.1f", 
                tostring(self.recordId), tostring(LPP_STATE.isAtZeroHealth), tostring(LPP_STATE.cachedIsDead), tostring(settingsCache.pickupMode), LPP_STATE.stuckVfxCount, now - (LPP_STATE.zeroHealthStartTime or now)))
        end

        -- Trigger conversion ONLY after death animation is fully finished.
        -- Fallback: isDeathDone is forced true after 4s at zero health (see above),
        -- so this will not block permanently on older builds.
        local readyToConvert = LPP_STATE.cachedIsDead
    end
    if startedDying and not LPP_STATE.vfxConvertedOnDeath and pickupModeVal and readyToConvert then
    LPP_STATE.vfxConvertedOnDeath = true
    
    -- ═══════════════════════════════════════════════════════════════════
    -- GUARANTEED 3 SECOND DELAY after death is detected
    -- (Bone capture will have already completed by this point)
    -- ═══════════════════════════════════════════════════════════════════
    local DEATH_SETTLE_DELAY = 3.0
    
    async:newUnsavableSimulationTimer(DEATH_SETTLE_DELAY, function()
        local vfxToConvert = {}
        for vfxId, entry in pairs(stuckVfxRegistry) do
            if entry.boneName then
                table.insert(vfxToConvert, {
                    vfxId          = vfxId,
                    ammoRecordId   = entry.ammoRecordId or "chitin arrow",
                    projectileType = entry.projectileType or 'arrow'
                })
            end
        end

        debugLog(string.format("[DEATH-CONVERT] Converting %d VFX after %.1fs delay", 
            #vfxToConvert, DEATH_SETTLE_DELAY))

        for _, convData in ipairs(vfxToConvert) do
            onConvertVfxToActivator(convData)
        end
    end)
    end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,

        onSave = function()
            return {
                stuckVfxRegistry = stuckVfxRegistry,
                boneOccupancy = boneOccupancy,
                cachedAmmoCounts = LPP_STATE.cachedAmmoCounts
            }
        end,
        onLoad = function(data)
            -- [CACHE & STATE RESET] Ensure a clean baseline when loading a save
            stateCache = { deathAnim = nil, heightFactor = nil, lastHeightUpdate = 0 }
            weaponRecordCache = {}
            raceScaleCache = {} -- [CRITICAL] Clear race scales to prevent stale/nil records on load
            
            -- [RESTORE SAVED DATA]
            if data then
                stuckVfxRegistry = data.stuckVfxRegistry or {}
                boneOccupancy = data.boneOccupancy or {}
                LPP_STATE.cachedAmmoCounts = data.cachedAmmoCounts or {}
                local count = 0
                for _ in pairs(stuckVfxRegistry) do count = count + 1 end
                LPP_STATE.stuckVfxCount = count
                debugLog('[PP-ACTOR] Restored ' .. tostring(LPP_STATE.stuckVfxCount) .. ' stuck projectiles.')
            else
                trackedProjectiles = {}
                stuckVfxRegistry = {}
                LPP_STATE.stuckVfxCount = 0
                LPP_STATE.cachedAmmoCounts = {}
            end
            
            -- Request fresh settings
            settingsInitialized = false
            trackedProjectileCount = 0
            nextActivityCheck = 0
            inventoryCheckDone = false
            hasRangedWeaponInInventory = nil
            isCreatureNonBiped = nil
            
            debugLog('[PP-ACTOR] Script state reset/loaded')
        end,
    },
    eventHandlers = {
        ProjectilePhysics_ApplyDamage = onApplyDamage,
        ProjectilePhysics_RequestBoneFit = onRequestBoneFit,
        ProjectilePhysics_TrackBone = function(data) addTrackedProjectile(data.projectileId, {groupName = "Torso", groupId = BONE_GROUPS.Torso}) end,
        ProjectilePhysics_UntrackBone = function(data) removeTrackedProjectile(data.projectileId) end,
        ProjectilePhysics_AttachVfxArrow = onAttachVfxArrow,
        ProjectilePhysics_TriggerConversion = onConvertVfxToActivator,
        ProjectilePhysics_ConvertVfxToActivator = onConvertVfxToActivator,
        ProjectilePhysics_RemoveVfx = onRemoveVfx,
        ProjectilePhysics_SyncVfxSettings = onSyncVfxSettings,
        ProjectilePhysics_RemoveAllStuckVfx = removeAllStuckVfx,
                -- Suppress superCast for one incoming hit (NPC onUse bow system)
        ProjectilePhysics_SuppressNpcOnUseEnchant = function(data)
            if not data or not data.enchantId then return end
            pendingSuppressEnchantId = data.enchantId
            -- Give a 0.5s window — plenty for onApplyDamage which fires in the same frame
            pendingSuppressExpiry    = core.getRealTime() + 0.5
            debugLog('[NPC-ONUSE-BOW] Suppress flag set for enchant '
                .. tostring(data.enchantId))
        end,
        ProjectilePhysics_ApplyEnchantAsOnStrike = function(data)
            if not data or not data.enchantId then return end
            superCast(
                data.enchantId,
                data.caster,
                self,
                data.weapon,
                data.hitPos,
                data.isAoe)
        end,
        -- Post-hoc cancel of a native engine onUse cast (no virtual charges left)
        ProjectilePhysics_CancelNpcOnUseEffect = function(data)
            if not data or not data.enchantId then return end
            local enchantId = data.enchantId

            local activeSpells = types.Actor.activeSpells(self)
            if not activeSpells then return end

            -- Find and remove every active spell instance sourced from this enchantment
            local toRemove = {}
            local ok, err = pcall(function()
                for i = 1, 256 do
                    local spell = activeSpells[i]
                    if not spell then break end
                    -- The spell id for an item enchantment cast is the enchantment id itself
                    -- or the item record id depending on OpenMW version; check both
                    local sid = (spell.id or ""):lower()
                    local eid = enchantId:lower()
                    if sid == eid then
                        table.insert(toRemove, spell)
                    end
                end
            end)

            if ok then
                for _, spell in ipairs(toRemove) do
                    pcall(function() activeSpells:remove(spell) end)
                    debugLog('[NPC-ONUSE-BOW] Removed active spell instance: '
                        .. tostring(spell.id))
                end
                if #toRemove == 0 then
                    debugLog('[NPC-ONUSE-BOW] CancelNpcOnUseEffect: no matching active spell found for '
                        .. tostring(enchantId))
                end
            else
                debugLog('[NPC-ONUSE-BOW] activeSpells iteration failed: ' .. tostring(err))
            end
        end,
        ProjectilePhysics_SyncSettings = function(data)
             -- Sync settings from Player script (MCM)
             for k,v in pairs(data) do settingsCache[k] = v end
        end,
        -- [BLOCK FEEDBACK] Play animation and sound when global confirms a block
        ProjectilePhysics_BlockFeedback = function(data)
            debugLog('BLOCK-FEEDBACK EVENT RECEIVED - Playing animation and sound')
            -- Play shield raise animation using standard API
            local animOk, animErr = pcall(function()
                 -- Try to find a valid group
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
                         blendMask = 14, 
                         loops = 1,
                         autoblend = false
                     }
                     if validGroup == "shieldraise" or validGroup == "Shieldraise" then
                         opts.startKey = "start"
                         opts.stopKey = "stop"
                     end
                     
                     anim.playBlended(self, validGroup, opts)
                     anim.setSpeed(self, validGroup, 0.8) -- [USER REQUEST] Fast raise
                     
                     -- Transition to fast drop/stop (Approximate midpoint)
                     async:newUnsavableSimulationTimer(0.1, function()
                         -- Ensure we only apply if the block sequence hasn't naturally ended
                         pcall(function() anim.setSpeed(self, validGroup, 0.3) end)
                     end)
                     
                     core.sound.playSound3d("Heavy Armor Hit", self, {volume=1.0, pitch=0.8+math.random()*0.4})
                 else
                     debugLog('Warning: No suitable block animation group found (checked: shieldraise, shield, block, etc.)')
                 end
            end)
            if not animOk then 
                debugLog('playBlended failed: ' .. tostring(animErr))
            end
            end,
        AddVfx = function(data)
            local model = data.model
            local options = data.options
            
            pcall(function()
                anim.addVfx(self, model, options)
            end)
        end,
        PlaySound3d = function(data)
            local sound = data.sound
            local options = data.options
            
            pcall(function()
                if options then
                    core.sound.playSound3d(sound, self, options)
                else
                    core.sound.playSound3d(sound, self)
                end
            end)
        end,
        ProjectilePhysics_DebugSpells = function()
            if listActiveSpells then
                listActiveSpells(self)
            else
                debugLog("listActiveSpells function not found!")
            end
        end,
        ProjectilePhysics_DebugCreature = function()
            if debugCreatureInfo then
                debugCreatureInfo(self)
            end
        end,
        KnockdownRequest = function(data)
            local damage = data.damage or 0
            local attacker = data.attacker
            local forceKnockdown = data.forceKnockdown or false
            
            -- Force knockdown (scripted events, special attacks)
            if forceKnockdown then
                debugLog("[KNOCKDOWN] Forced knockdown triggered")
                playKnockdownAnimation()
                return
            end
            
            -- Normal knockdown processing
            processKnockdown(damage, attacker)
        end,
        KnockdownQuery = function(data)
            if data.callback then
                data.callback({
                    isKnockedDown = isActorKnockedDown(),
                    damageMultiplier = getKnockdownDamageMultiplier(),
                    evasion = getKnockdownEvasion(),
                    timeRemaining = getKnockdownTimeRemaining(),
                })
            end
        end,
        
        ProjectilePhysics_RecallPrecisionCoords = function(data)
            local player = data.player
            if not player then return end
            
            local items = {}
            local scales = getActorRaceScales(self)
            
            for vfxId, vData in pairs(stuckVfxRegistry) do
                local ok, err = pcall(function()
                    -- LIVE ENGINE TRACKING (same as onConvertVfxToItem)
                    local boneWorldPos, isAnimatedPos = getBoneAnimatedPos(self, vData.boneName)
                    local boneWorldRot, isAnimatedRot = getBoneAnimatedRot(self, vData.boneName)
                    
                    -- Step 2: Apply VFX offset
                    local worldPos = boneWorldPos
                    if vData.offset then
                        local scaledOffset = util.vector3(
                            vData.offset.x * (scales.weight or 1.0),
                            vData.offset.y * (scales.weight or 1.0),
                            vData.offset.z * (scales.height or 1.0)
                        )
                        
                        worldPos = boneWorldPos + (boneWorldRot * scaledOffset)
                    end
                    
                    -- Step 3: Rotation
                    local worldRot = boneWorldRot
                    if vData.rotation then
                        worldRot = boneWorldRot * vData.rotation
                    end
                    -- [FINETUNE] Extra rotation offset to align item visually with VFX.
                    -- Adjust the angle (in degrees) to match the VFX orientation.
                    local FINETUNE_ROT_DEG = 45
                    worldRot = worldRot * util.transform.rotateX(math.rad(FINETUNE_ROT_DEG))
                    
                    --[HEIGHT CORRECTION 2]
                    table.insert(items, {
                        vfxId = vfxId,
                        ammoRecordId = vData.ammoRecordId,
                        pos = worldPos,
                        rot = worldRot
                    })
                end)
                if not ok then debugLog('[PP-ACTOR] Precision Coord recall failed: ' .. tostring(err)) end
            end
            
            if #items > 0 then
                core.sendGlobalEvent('ProjectilePhysics_ProcessPrecisionHarvest', {
                    target = self,
                    player = player,
                    items = items
                })
            end
        end,

        ProjectilePhysics_PlayMagicVfx = function(data)
            local enchantId = data.enchantId
            local isAoe = data.isAoe
            
            -- Get the enchantment record
            local enchant = nil
            if core.magic and core.magic.enchantments then
                if core.magic.enchantments.records then
                    enchant = core.magic.enchantments.records[enchantId]
                else
                    enchant = core.magic.enchantments[enchantId]
                end
            end
            
            if not enchant or not enchant.effects then return end
            
            for i = 0, #enchant.effects - 1 do
                local effect = enchant.effects[i]
                if effect then
                    local mgefId = effect.effect or effect.id
                    local mgef = (core.magic.effects.records and core.magic.effects.records[mgefId]) or core.magic.effects[mgefId]
                    if mgef then
                        -- PLAY SOUND
                        local soundId = isAoe and (mgef.areaSound or mgef.hitSound) or (mgef.hitSound or mgef.castSound)
                        if soundId and soundId ~= "" then
                            pcall(function() core.sound.playSound3d(soundId, self) end)
                        end

                        -- PLAY VFX
                        local vfxStaticId = isAoe and mgef.areaStatic or mgef.hitStatic
                        if not vfxStaticId or vfxStaticId == "" then vfxStaticId = mgef.hitStatic or mgef.castStatic end
                        
                        if vfxStaticId and vfxStaticId ~= "" then
                            local staticRecord = (types.Static.records and types.Static.records[vfxStaticId]) or (types.Static and types.Static[vfxStaticId])
                            if staticRecord and staticRecord.model then
                                pcall(function()
                                    self:sendEvent('AddVfx', {
                                        model = staticRecord.model,
                                        options = {
                                            particleTextureOverride = mgef.particle or "",
                                            loop = false,
                                            vfxId = "enchant_hit_" .. tostring(enchantId) .. "_" .. tostring(i),
                                        }
                                    })
                                end)
                            end
                        end
                    end
                end
            end
        end,

        ProjectilePhysics_RequestDebugDeathInfo = function(data)
            local player = data.player
            if player then
                -- Force detection
                local detected = getDeathAnimationType(true)
                local engineBones = {}
                -- [CALIBRATION] Step 1: Capture every pose bone that actually exists
                local poseData = poseTransforms[detected]
                if poseData then
                    for boneName, _ in pairs(poseData) do
                        local ok, pos = pcall(anim.getPartPosition, self, boneName)
                        if ok and pos then
                            engineBones[boneName] = { pos = util.vector3(pos.x, pos.y, pos.z) }
                        end
                    end
                end

                -- [CALIBRATION] Step 2: Capture standard NPC bones for proximity mapping
                local standardBones = {
                    "Bip01 Head", "Bip01 Neck", "Bip01 Spine2", "Bip01 Spine1", "Bip01 Spine", "Bip01 Pelvis",
                    "Bip01 L UpperArm", "Bip01 L Forearm", "Bip01 L Hand",
                    "Bip01 R UpperArm", "Bip01 R Forearm", "Bip01 R Hand",
                    "Bip01 L Thigh", "Bip01 L Calf", "Bip01 L Foot",
                    "Bip01 R Thigh", "Bip01 R Calf", "Bip01 R Foot",
                    "Root Bone", "Head", "Spine1", "Pelvis" -- Variations
                }
                for _, bName in ipairs(standardBones) do
                    local ok, pos = pcall(anim.getPartPosition, self, bName)
                    if ok and pos then
                        engineBones[bName] = { pos = util.vector3(pos.x, pos.y, pos.z), isStandard = true }
                    end
                end
                
                -- [DEBUG] Count how many engine bones we actually captured
                local capturedCount = 0
                for _ in pairs(engineBones) do capturedCount = capturedCount + 1 end
                debugLog(string.format("Calibration Prep: Captured %d bones from engine for %s", capturedCount, tostring(self.recordId)))

                player:sendEvent('ProjectilePhysics_DebugSpawnResponse', {
                    target = self,
                    deathAnim = detected,
                    engineBones = engineBones
                })
            end
        end,
    }
}