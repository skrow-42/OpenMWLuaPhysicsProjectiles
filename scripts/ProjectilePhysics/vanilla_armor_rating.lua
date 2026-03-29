-- scripts/ProjectilePhysics/vanilla_armor_rating.lua
-- Morrowind-style Armor Rating from:
--   - equipped armor pieces (skill-scaled, condition-scaled)
--   - Unarmored skill for uncovered/clothing slots
--   - + Shield magic effect magnitude (direct AR add)
--
-- LuaJIT / Lua 5.1 compatible.

local core = require('openmw.core')
local types = require('openmw.types')
local I = require('openmw.interfaces')

local Actor = types.Actor
local NPC   = types.NPC
local Armor = types.Armor
local Item  = types.Item

local Combat = I and I.Combat

local SLOT = Actor.EQUIPMENT_SLOT

-- Vanilla weight factors (UESP):
-- Chest * 0.3 + (Shield + Head + Legs + Feet + RShoulder + LShoulder)*0.1 + (RHand + LHand)*0.05
local SLOT_WEIGHTS = {
  [SLOT.Cuirass]       = 0.30,
  [SLOT.Helmet]        = 0.10,
  [SLOT.Greaves]       = 0.10,
  [SLOT.Boots]         = 0.10,
  [SLOT.RightPauldron] = 0.10,
  [SLOT.LeftPauldron]  = 0.10,
  [SLOT.RightGauntlet] = 0.05,
  [SLOT.LeftGauntlet]  = 0.05,

  -- Shield is usually equipped in CarriedLeft, but that slot can hold non-shields too.
  -- We'll count it only if the equipped item is Armor.TYPE.Shield.
  [SLOT.CarriedLeft]   = 0.10,
}

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- Get an NPC/Player skill's modified value safely.
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
-- UnarmoredSkill^2 * 0.0065
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
-- pieceAR = BaseAR * (ArmorSkill / 30)
local function computeEquippedArmorPieceAR(item, actor)
  if (not item) or (not Armor.objectIsInstance(item)) then
    return nil -- caller decides unarmored
  end

  local rec = Armor.record(item)
  if not rec then
    return nil
  end

  local baseAR = rec.baseArmor or 0

  local skillId = getArmorSkillIdForItem(item)
  if skillId == 'unarmored' then
    return nil
  end

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

  return math.floor(raw + 1e-9)
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

  -- Version safe lookup: some versions have :getEffect, others just a list
  if maybeEffects.getEffect then
     local shieldEffect = maybeEffects:getEffect(core.magic.EFFECT_TYPE.Shield)
     return (shieldEffect and shieldEffect.magnitude) or 0
  end

  -- Fallback: iterate over effects list
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

    -- Shield slot handling
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
    -- components
    equipmentArmorRating = equipmentWeightedAR,
    magicArmorRating = magicAR, -- Shield magnitude

    -- totals
    armorRating = totalAR,
    armorRatingInt = math.floor(totalAR + 1e-9),

    anyArmorEquipped = anyArmorEquipped,

    -- extra debug
    unarmoredSlotAR = unarmoredSlotAR,
    breakdown = breakdown,
  }
end

return {
  computeVanillaArmorRating = computeVanillaArmorRating,
}
