--!strict
-- Quickstart.server.lua
-- Minimum viable wiring of roblox-modular-lib for a pet game.
-- Drop this into ServerScriptService (with Rojo syncing) and hit Play.
-- All 3 core systems boot in < 1ms; no terrain pipeline needed.

local src = game:GetService("ServerScriptService"):WaitForChild("src")

local EventBus   = require(src.Core.EventBus)
local Config     = require(src.Core.Config)
local TimerSystem = require(src.TimerSystem)
local Inventory  = require(src.Inventory)
local XPSystem   = require(src.XPSystem)
local PetSystem  = require(src.PetSystem)

-- 1. Create the shared event bus — single root for all cross-module events.
local bus = EventBus.new()
local cfg = Config.new({ debug = true })

-- 2. Wire dependencies bottom-up (no module reaches up).
local timer = TimerSystem.new(bus)
local inv   = Inventory.new(bus, 50)   -- 50 inventory slots
local xp    = XPSystem.new(bus, cfg)
local pets  = PetSystem.new(bus, inv, xp, timer)

-- 3. Register items so the inventory can hold them.
inv:DefineItem({ id = "cracked_egg", name = "Cracked Egg", maxStack = 10, equippable = false })
inv:DefineItem({ id = "fish",        name = "Fish",        maxStack = 20, equippable = false })

-- 4. Subscribe to events before triggering anything.
bus:Subscribe("EggHatched", function(data)
    print("[QuickStart] Egg hatched! Got:", data.petName, "(", data.rarity, ")")
end)

bus:Subscribe("PetFed", function(data)
    print("[QuickStart] Pet fed — hunger:", data.hunger)
end)

bus:Subscribe("PetAgedUp", function(data)
    print("[QuickStart] Pet aged up:", data.oldStage, "→", data.newStage)
end)

-- 5. Give the player an egg and hatch it.
inv:AddItem("cracked_egg", 1)
local pet = pets:HatchEgg("cracked_egg")

if pet then
    print("[QuickStart] Hatched", pet.name, "| instanceId:", pet.instanceId)

    -- Feed the pet (requires fish in inventory).
    inv:AddItem("fish", 1)
    pets:FeedPet(pet.instanceId, "fish")

    -- Force XP for a quick age-up demo.
    pets._ownedPets[pet.instanceId].xp = 9999
    pets:AgeUpPet(pet.instanceId)
end

print("[QuickStart] Done — open Output panel to see events.")
