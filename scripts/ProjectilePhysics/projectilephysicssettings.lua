-- ProjectilePhysicsSettings.lua
-- Settings page for Lua Projectile Physics mod

local storage = require('openmw.storage')
local I = require('openmw.interfaces')

-- Register UI (only in contexts that expose I.Settings)
if I.Settings and I.Settings.registerPage then
    -- Register the settings page (with error handling for reload)
    pcall(function()
        I.Settings.registerPage{
            key = 'ProjectilePhysicsPage',
            l10n = 'ProjectilePhysics',
            name = 'Projectile Physics',
            description = 'Realistic physics for all projectiles (arrows, bolts, thrown weapons). Requires MaxYari LuaPhysics Engine.',
        }
    end)

    -- Main settings group (with error handling for reload)
    pcall(function()
        I.Settings.registerGroup{
        key = 'SettingsProjectilePhysics',
        page = 'ProjectilePhysicsPage',
        l10n = 'ProjectilePhysics',
        name = 'General Settings',
        permanentStorage = true,
        order = 1,
        settings = {
            {
                key = 'enableProjectilePhysics',
                renderer = 'checkbox',
                name = 'Enable Projectile Physics',
                description = 'Apply physics to ALL projectiles (arrows, bolts, throwing weapons). Projectiles will collide with walls and objects instead of passing through.',
                default = true,
            },
            {
                key = 'enableNPCSupport',
                renderer = 'checkbox',
                name = 'Apply to NPCs & Creatures',
                description = 'When enabled, NPCs and Creatures will also use physics-based projectiles and the reworked damage system.',
                default = true,
            },
            {
                key = 'enableBounceDamage',
                renderer = 'checkbox',
                name = 'Enable Bounce Damage',
                description = 'If enabled, projectiles that have bounced off surfaces can still damage any actor they hit (including characters and creatures).',
                default = true,
            },
            {
                key = 'enableProjectileSticking',
                renderer = 'checkbox',
                name = 'Enable Projectile Sticking',
                description = 'If enabled, projectiles will stick to and move with NPCs they hit. If disabled, they will either break or bounce off.',
                default = true,
            },
            {
                key = 'projectileLifetime',
                renderer = 'number',
                name = 'Projectile Lifetime',
                description = 'Time in seconds before stuck projectiles are removed from the world.',
                default = 300,
                argument = {
                    min = 1,
                    max = 99999,
                    step = 1,
                },
            },
            {
                key = 'breakChance',
                renderer = 'number',
                name = 'Break Chance (Environment)',
                description = 'Chance (0-100%) for a projectile to break upon hitting the environment.',
                default = 25,
                argument = {
                    min = 0,
                    max = 100,
                    step = 1,
                },
            },
            {
                key = 'aoeBreakRate',
                renderer = 'number',
                name = 'AoE World Break Chance',
                description = 'Chance (0-100%) for an AoE projectile to break and detonate upon hitting the environment. If it survives, it will bounce without trigger the enchantment.',
                default = 50,
                argument = {
                    min = 0,
                    max = 100,
                    step = 1,
                },
            },
            {
                key = 'allowEnchantedRecovery',
                renderer = 'checkbox',
                name = 'Allow Enchanted Projectile Recovery',
                description = 'If enabled, enchanted/AoE projectiles follow regular salvage rules. If disabled, they can never be salvaged from bodies.',
                default = true,
            },
            {
                key = 'bounceDamageMultiplier',
                renderer = 'number',
                name = 'Bounce Damage Multiplier',
                description = 'Percentage of base damage (0-100%) that a projectile deals after bouncing.',
                default = 10,
                argument = {
                    min = 0,
                    max = 100,
                    step = 1,
                },
            },
            {
                key = 'playerHitBehavior',
                renderer = 'select',
                name = 'Projectile vs Player Behavior',
                description = 'Specify if projectiles should stick to or break on hitting the player.\n\n To remove the projectiles from yourself, aim at your feet and do:\n\n Sneak + Activate',
                default = 'stick',
                argument = {
                    l10n = 'ProjectilePhysics',
                    items = { 'stick', 'break' }
                }
            },
            {
                key = 'debugMode',
                renderer = 'checkbox',
                name = 'Debug Mode',
                description = 'Log projectile detection and physics events to console (performance impact).',
                default = false,
            },
            {
                key = 'enableSkillBasedRecoil',
                renderer = 'checkbox',
                name = 'Enable Skill-Based Recoil (Spread)',
                description = 'Applies shot spread based on Marksman skill.',
                default = false,
            },
            {
                key = 'maxRecoil',
                renderer = 'number',
                name = 'Maximum Recoil',
                description = 'Maximum angle of shot deviation (recoil) at 0 Marksman skill. Higher values mean more spread.',
                default = 0.08,
                argument = {
                    min = 0,
                    max = 1.0,
                    step = 0.01,
                },
            },
            {
                key = 'enableProjectileBlocking',
                renderer = 'checkbox',
                name = 'Enable Projectile Blocking',
                description = 'Allows actors to block incoming projectiles with a shield if in a weapon stance. Uses vanilla combat formulas and directional logic.',
                default = true,
            },
            {
                key = 'projectileLaunchOffsetMode',
                renderer = 'select',
                name = 'Select your installed animation set',
                description = 'Choose which animation set you have installed (choosing the wrong one will launch the projectiles from wrong place).',
                default = 'vanilla',
                argument = {
                    l10n = 'ProjectilePhysics',
                    items = { 'vanilla', 'reanimation' }
                }
            },
            {
                key = 'enableLocationalDamage',
                renderer = 'checkbox',
                name = 'Enable Locational Damage',
                description = 'Applies a damage multiplier based on where the projectile hits the enemy (e.g. Headshots do more damage, limb shots do less).',
                default = true,
            },
        },
    }
    end)

-- Velocity settings group
pcall(function()
    I.Settings.registerGroup{
        key = 'SettingsProjectilePhysicsVelocity',
        page = 'ProjectilePhysicsPage',
        l10n = 'ProjectilePhysics',
        name = 'Projectile Velocity',
        permanentStorage = true,
        order = 3,
        settings = {
            {
                key = 'arrowSpeed',
                renderer = 'number',
                name = 'Arrow Speed (Max)',
                description = 'Maximum speed of arrows when fully charged. (Vanilla mod default: 3500)',
                default = 3500,
                argument = { min = 100, max = 15000, step = 100 },
            },
            {
                key = 'boltSpeed',
                renderer = 'number',
                name = 'Bolt Speed',
                description = 'Fixed speed of crossbow bolts. (Vanilla mod default: 4000)',
                default = 4000,
                argument = { min = 100, max = 15000, step = 100 },
            },
            {
                key = 'thrownSpeed',
                renderer = 'number',
                name = 'Thrown Weapon Speed (Max)',
                description = 'Maximum speed of thrown weapons when fully charged. (Vanilla mod default: 2000)',
                default = 2000,
                argument = { min = 100, max = 15000, step = 100 },
            },
        },
    }
end)

-- Advanced settings group (with error handling for reload)
pcall(function()
    I.Settings.registerGroup{
        key = 'SettingsProjectilePhysicsAdvanced',
        page = 'ProjectilePhysicsPage',
        l10n = 'ProjectilePhysics',
        name = 'Advanced Settings',
        permanentStorage = true,
        order = 2,
        settings = {
            {
                key = 'hitDetectionMode',
                renderer = 'select',
                name = 'Hit Chance Method',
                description = 'Use vanilla engine hit chance calculation or direct hit when projectile touches the NPC for damage dealing.',
                default = 'vanilla',
                argument = {
                    l10n = 'ProjectilePhysics',
                    items = { 'vanilla', 'reallife' }
                }
            },
            {
                key = 'enableLiveInventorySync',
                renderer = 'checkbox',
                name = 'Live Inventory Sync (Firing Back)',
                description = 'If enabled, stuck projectiles are added to an NPCs inventory while they are alive, allowing them to fire the projectiles back at you. If disabled, items are only added upon death.',
                default = true,
            },
            {
                key = 'pickupMode',
                renderer = 'select',
                name = 'Pickup Mode (Marksman Skill Based)',
                description = 'Choose method to recover stuck projectiles:\n\n Activation(buggy) Activate stuck arrows directly on the body to attempt picking them up\n\n Inventory: loot projectiles directlyfrom NPC inventory - it will remove any failed picked projectiles from your inventory.\n\n Mass Harvest: loot projectiles with Sneak + Activate combo while looking near/at the body. It will do a success/fail roll on each of the projectiles on the body.',
                default = 'mass_harvest',
                argument = {
                    l10n = 'ProjectilePhysics',
                    items = { 'activation', 'inventory', 'mass_harvest' }
                }
            },
            {
                key = 'rangedOnUseToOnStrike',
                renderer = 'checkbox',
                name = 'Ranged weapons conversion onUse->onStrike',
                description = 'If enabled, marksman weapons with "Cast on Use" enchantments will act as onStrike instead. This applies to both Players and NPCs.',
                default = true,
            },
        },
    }
end)
end -- End of I.Settings check

-- Gravity settings group
pcall(function()
    I.Settings.registerGroup{
        key = 'SettingsProjectilePhysicsGravity',
        page = 'ProjectilePhysicsPage',
        l10n = 'ProjectilePhysics',
        name = 'Gravity Adjustment',
        description = 'Finetune the gravity for projectiles (range 0.1-5.0).',
        permanentStorage = true,
        order = 4,
        settings = {
            {
                key = 'arrowGravity',
                renderer = 'number',
                name = 'Arrows',
                default = 0.7,
                argument = { min = 0.0, max = 5.0, step = 0.1 },
            },
            {
                key = 'boltGravity',
                renderer = 'number',
                name = 'Bolts',
                default = 0.8,
                argument = { min = 0.0, max = 5.0, step = 0.1 },
            },
            {
                key = 'thrownGravity',
                renderer = 'number',
                name = 'Throwns',
                default = 0.6,
                argument = { min = 0.0, max = 5.0, step = 0.1 },
            },
        },
    }
end)

-- Return empty table as interface is just for registration
return {}
