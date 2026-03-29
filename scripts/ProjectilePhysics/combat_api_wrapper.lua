-- combat_api_wrapper.lua
-- Unified interface for OpenMW Combat API v111+ with fallbacks for older versions
-- Also provides enhanced hit-position-based armor durability (better than vanilla random selection)

local core = require('openmw.core')
local types = require('openmw.types')
local util = require('openmw.util')

local I = require('openmw.interfaces')

local storage = require('openmw.storage')

local M = {}

-- Settings
local debugSettings = storage.globalSection('SettingsProjectilePhysics')

local function debugLog(message)
    if debugSettings:get('debugMode') then
        print('[CombatAPI] ' .. message)
    end
end

-- API Detection
M.hasCombatAPI = false
M.apiVersion = 0

-- Silent check for I.Combat (Requires OpenMW 0.49+)
if I.Combat then
    M.apiVersion = I.Combat.version or 1
    M.hasCombatAPI = true
else
    debugLog("WARNING: I.Combat interface is NOT available! Ensure OpenMW 0.49+ and OmwCombat script is loaded. Combat features will be disabled.")
    M.hasCombatAPI = false
end

-- Attack Source Types (the key addition from Combat API)
M.ATTACK_SOURCE_TYPES = M.hasCombatAPI 
    and I.Combat.ATTACK_SOURCE_TYPES 
    or { 
        Melee = 'Melee', 
        Ranged = 'Ranged', 
        Magic = 'Magic', 
        Unspecified = 'Unspecified' 
    }

-- ============================================================================
-- HIT-POSITION-BASED ARMOR SLOT MAPPING
-- Maps body regions (from hit coordinates) to specific armor equipment slots
-- This replaces vanilla's random armor selection for more realistic durability
-- ============================================================================

local Actor = types.Actor
local Armor = types.Armor
local Item = types.Item
local SLOT = Actor.EQUIPMENT_SLOT

-- Slot weights for damage calculation (vanilla values from UESP)
local SLOT_WEIGHTS = {
    [SLOT.Cuirass]       = 0.30,
    [SLOT.Helmet]        = 0.10,
    [SLOT.Greaves]       = 0.10,
    [SLOT.Boots]         = 0.10,
    [SLOT.RightPauldron] = 0.10,
    [SLOT.LeftPauldron]  = 0.10,
    [SLOT.RightGauntlet] = 0.05,
    [SLOT.LeftGauntlet]  = 0.05,
    [SLOT.CarriedLeft]   = 0.10, -- Shield
}

-- Map body category to primary armor slot
local CATEGORY_TO_SLOT = {
    Head      = SLOT.Helmet,
    BackHead  = SLOT.Helmet,
    Torso     = SLOT.Cuirass,
    Back      = SLOT.Cuirass,
    LArm      = SLOT.LeftPauldron,
    RArm      = SLOT.RightPauldron,
    LUpperLeg = SLOT.Greaves,
    RUpperLeg = SLOT.Greaves,
    LLowerLeg = SLOT.Boots,
    RLowerLeg = SLOT.Boots,
}

-- Fallback slots if primary is empty
local SLOT_FALLBACKS = {
    [SLOT.Helmet]        = { SLOT.Cuirass },
    [SLOT.LeftPauldron]  = { SLOT.Cuirass, SLOT.LeftGauntlet },
    [SLOT.RightPauldron] = { SLOT.Cuirass, SLOT.RightGauntlet },
    [SLOT.Greaves]       = { SLOT.Cuirass },
    [SLOT.Boots]         = { SLOT.Greaves, SLOT.Cuirass },
}

-- Get category from hit position (relative to actor, Y-inverted for logic)
local function getCategoryFromHitPos(relativePos)
    local x, y, z = relativePos.x, relativePos.y, relativePos.z
    local isFront = y > 0

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

    -- TORSO / BACK
    return isFront and "Torso" or "Back"
end

-- Check if item is valid armor
local function isValidArmor(item)
    if not item then return false end
    local ok, result = pcall(function()
        return Armor.objectIsInstance(item)
    end)
    return ok and result
end

-- Check if item is a shield specifically
local function isShield(item)
    if not isValidArmor(item) then return false end
    local ok, rec = pcall(function() return Armor.record(item) end)
    if not ok or not rec then return false end
    return rec.type == Armor.TYPE.Shield
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Get the armor slot that should receive durability damage based on hit position
--- @param actor GameObject The actor being hit
--- @param hitPos Vector3 World position of the hit
--- @return GameObject|nil The armor item to damage, or nil if no armor covers that area
function M.getArmorAtHitPosition(actor, hitPos)
    if not actor or not hitPos then return nil end
    
    local eq = Actor.getEquipment(actor)
    if not eq then return nil end
    
    -- Convert world hit to actor-local coordinates
    local invRot = actor.rotation:inverse()
    local relativePos = invRot * (hitPos - actor.position)
    -- Y-invert for logic (rig is backwards)
    local logicPos = util.vector3(relativePos.x, -relativePos.y, relativePos.z)
    
    -- Get body category from hit position
    local category = getCategoryFromHitPos(logicPos)
    
    -- Get primary slot for this category
    local primarySlot = CATEGORY_TO_SLOT[category]
    if not primarySlot then primarySlot = SLOT.Cuirass end
    
    -- Check primary slot
    local item = eq[primarySlot]
    if isValidArmor(item) then
        -- Special case: CarriedLeft must be a shield
        if primarySlot == SLOT.CarriedLeft and not isShield(item) then
            item = nil
        else
            return item
        end
    end
    
    -- Try fallback slots
    local fallbacks = SLOT_FALLBACKS[primarySlot]
    if fallbacks then
        for _, fallbackSlot in ipairs(fallbacks) do
            item = eq[fallbackSlot]
            if isValidArmor(item) then
                return item
            end
        end
    end
    
    return nil -- No armor at this position
end

--- Get the armor rating contribution for the hit position
--- @param actor GameObject The actor being hit
--- @param hitPos Vector3 World position of the hit
--- @return number The effective armor rating for that body region
function M.getArmorRatingAtHitPosition(actor, hitPos)
    local item = M.getArmorAtHitPosition(actor, hitPos)
    if not item then
        -- Unarmored contribution for this slot
        local unarmoredSkill = M.getSkillModified(actor, 'unarmored')
        return (unarmoredSkill * unarmoredSkill) * 0.0065
    end
    
    -- Use Combat API if available
    if M.hasCombatAPI then
        return I.Combat.getEffectiveArmorRating(item, actor)
    end
    
    -- Fallback calculation
    local rec = Armor.record(item)
    if not rec then return 0 end
    
    local baseAR = rec.baseArmor or 0
    local skillId = M.getArmorSkill(item)
    if skillId == 'unarmored' then return 0 end
    
    local armorSkill = M.getSkillModified(actor, skillId)
    local skillMult = armorSkill / 30
    
    -- Condition factor
    local maxCond = rec.health or 1
    local curCond = maxCond
    local data = Item.itemData(item)
    if data and data.condition then
        curCond = math.max(0, math.min(data.condition, maxCond))
    end
    local condMult = (maxCond > 0) and (curCond / maxCond) or 1
    
    return math.floor(baseAR * skillMult * condMult)
end

--- Apply durability damage to armor at hit position
--- @param actor GameObject The actor being hit
--- @param hitPos Vector3 World position of the hit
--- @param damage number The incoming damage amount
--- @return boolean True if armor was damaged
function M.applyArmorDurabilityAtHitPosition(actor, hitPos, damage)
    local item = M.getArmorAtHitPosition(actor, hitPos)
    if not item then return false end
    
    local rec = Armor.record(item)
    if not rec then return false end
    
    local data = Item.itemData(item)
    if not data then return false end
    
    -- Calculate durability loss (vanilla formula: damage * fWeaponDamageMult)
    local fWeaponDamageMult = 0.1
    pcall(function()
        fWeaponDamageMult = core.getGMST('fWeaponDamageMult') or 0.1
    end)
    
    local durabilityLoss = math.max(1, math.floor(damage * fWeaponDamageMult))
    local oldCondition = data.condition or rec.health or 100
    local newCondition = math.max(0, oldCondition - durabilityLoss)
    
    data.condition = newCondition
    
    return true
end

-- ============================================================================
-- SKILL & ARMOR HELPERS
-- ============================================================================

--- Get skill value safely across different actor types
--- @param actor GameObject
--- @param skillId string
--- @return number
function M.getSkillModified(actor, skillId)
    local function tryLookup(root)
        if not root then return nil end
        local skillTable = root.skills
        if not skillTable then return nil end
        local fn = skillTable[skillId]
        if not fn then return nil end
        local stat = fn(actor)
        return stat and stat.modified
    end

    local val = tryLookup(types.Actor.stats)
    if val == nil then val = tryLookup(types.NPC.stats) end
    if val == nil and actor.type == types.Player then 
        val = tryLookup(types.Player.stats) 
    end
    
    return val or 0
end

--- Get armor skill for item
--- @param item GameObject
--- @return string Skill ID ('heavyarmor', 'mediumarmor', 'lightarmor', 'unarmored')
function M.getArmorSkill(item)
    if M.hasCombatAPI then
        local id = I.Combat.getArmorSkill(item)
        return id or 'unarmored'
    end
    
    if not isValidArmor(item) then return 'unarmored' end
    
    local rec = Armor.record(item)
    if not rec or not rec.weight then return 'unarmored' end
    
    if rec.weight > 30 then return 'heavyarmor' end
    if rec.weight > 10 then return 'mediumarmor' end
    return 'lightarmor'
end

-- ============================================================================
-- COMBAT API WRAPPERS
-- ============================================================================

--- Get total armor rating for actor
--- @param actor GameObject
--- @return number
function M.getArmorRating(actor)
    if M.hasCombatAPI then
        return I.Combat.getArmorRating(actor)
    end
    
    -- Fallback to existing implementation
    local ok, vanillaAR = pcall(require, 'scripts.ProjectilePhysics.vanilla_armor_rating')
    if ok then
        local result = vanillaAR.computeVanillaArmorRating(actor)
        return result.armorRating or 0
    end
    return 0
end

--- Adjust damage for armor (pure calculation, no side effects)
--- @param damage number
--- @param actor GameObject
--- @return number
function M.adjustDamageForArmor(damage, actor)
    if M.hasCombatAPI then
        return I.Combat.adjustDamageForArmor(damage, actor)
    end
    
    -- Fallback formula
    local ar = M.getArmorRating(actor)
    if ar <= 0 or damage <= 0 then return damage end
    local factor = math.min(1 + (ar / damage), 4)
    return damage / factor
end

--- Adjust damage for armor at specific hit position
--- @param damage number
--- @param actor GameObject
--- @param hitPos Vector3
--- @return number
function M.adjustDamageForArmorAtPosition(damage, actor, hitPos)
    local ar = M.getArmorRatingAtHitPosition(actor, hitPos)
    if ar <= 0 or damage <= 0 then return damage end
    local factor = math.min(1 + (ar / damage), 4)
    return damage / factor
end

--- Apply armor to attack (with side effects: durability, skill XP, sound)
--- @param attack table AttackInfo-like table
--- @return boolean True if Combat API handled it
function M.applyArmor(attack)
    if M.hasCombatAPI then
        I.Combat.applyArmor(attack)
        return true
    end
    return false
end

--- Apply difficulty adjustment to damage
--- @param attack table
--- @param defendant GameObject
function M.adjustDamageForDifficulty(attack, defendant)
    if M.hasCombatAPI then
        I.Combat.adjustDamageForDifficulty(attack, defendant)
    end
    -- No fallback for older versions
end

--- Spawn blood effect at position
--- @param position Vector3
--- @return boolean
function M.spawnBloodEffect(position)
    if M.hasCombatAPI and I.Combat.spawnBloodEffect then
        I.Combat.spawnBloodEffect(position)
        return true
    end
    return false
end

--- Pick random armor (vanilla behavior)
--- @param actor GameObject
--- @return GameObject|nil
function M.pickRandomArmor(actor)
    if M.hasCombatAPI then
        return I.Combat.pickRandomArmor(actor)
    end
    
    -- Fallback: simple random selection
    local slots = { SLOT.Cuirass, SLOT.Helmet, SLOT.Greaves, SLOT.Boots, 
                    SLOT.RightPauldron, SLOT.LeftPauldron }
    local eq = Actor.getEquipment(actor)
    if not eq then return nil end
    
    -- Shuffle and find first valid armor
    for i = #slots, 2, -1 do
        local j = math.random(i)
        slots[i], slots[j] = slots[j], slots[i]
    end
    
    for _, slot in ipairs(slots) do
        local item = eq[slot]
        if isValidArmor(item) then
            return item
        end
    end
    return nil
end

--- Full hit processing via Combat API
--- @param actor GameObject Target actor
--- @param attackInfo table AttackInfo structure
--- @return boolean True if Combat API interface handled it, false otherwise
function M.onHit(actor, attackInfo)
    if M.hasCombatAPI and I.Combat then
        local ok, err = pcall(function() I.Combat.onHit(attackInfo) end)
        if not ok then debugLog("I.Combat.onHit error: " .. tostring(err)) end
        return ok
    end
    
    -- [FALLBACK] If interface is missing, attempt to reach a global handler
    if core.sendGlobalEvent then
        core.sendGlobalEvent('Combat_onHit', attackInfo)
        -- debugLog("[CombatAPI] I.Combat missing - Sent fallback 'Combat_onHit' event")
        return false -- Allow local script's manual fallback to run
    end
    
    return false
end

--- Register custom hit handler
--- @param handler function
--- @return boolean
function M.addOnHitHandler(handler)
    if M.hasCombatAPI and I.Combat and I.Combat.addOnHitHandler then
        I.Combat.addOnHitHandler(handler)
        return true
    end
    return false
end

return M
