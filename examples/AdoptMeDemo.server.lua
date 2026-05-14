--!strict
--[[
	AdoptMeDemo.lua
	================================================================================
	Adopt Me style game demo wiring 33 modules from the modular library together
	via dependency injection and the EventBus pub/sub pattern.

	The world is hand-built in Roblox Studio (or imported from Blender).
	Procedural terrain modules (TerrainGenerator, ChunkManager, WorldBuilder, etc.)
	live in src/ and can be plugged into other projects — they are not wired here.

	Systems active in this demo:
	- Pet system: 20 pets, 4 eggs, hatching, leveling, tricks, neon crafting
	- Economy: Bucks currency, shop NPCs with dialogue trees, player trading
	- Home building: furniture placement, room painting, home types
	- Vehicle system: equip/spawn/despawn with physics-based movement
	- Quest system: 3 daily quests with objective tracking
	- Weather cycling, biome audio, day/night atmosphere
	- Auto-save via DataStoreSafe, leaderboards, UI framework

	DEPENDENCY INJECTION PATTERN:
	Every module receives its dependencies through constructor arguments rather
	than hard-coding require() calls. This makes the architecture testable,
	swappable, and loosely coupled.

	EVENT BUS PATTERN:
	All modules communicate through EventBus:Subscribe/Emit rather than direct
	method calls. This decouples producers from consumers.

	Total modules wired: 33
	================================================================================
--]]

-- =============================================================================
-- SECTION 1: MODULE IMPORTS — Require all 33 modules organised by category
-- =============================================================================

-- Core foundation (4)
local EventBus     = require(script.Parent.src.Core.EventBus)
local Config       = require(script.Parent.src.Core.Config)
local Types        = require(script.Parent.src.Core.Types)
local StateMachine = require(script.Parent.src.Core.StateMachine)

-- Game mechanics (17)
local XPSystem           = require(script.Parent.src.XPSystem)
local UIFramework        = require(script.Parent.src.UIFramework)
local Physics            = require(script.Parent.src.Physics)
local DataStoreSafe      = require(script.Parent.src.DataStoreSafe)
local Inventory          = require(script.Parent.src.Inventory)
local Skills             = require(script.Parent.src.Skills)
local QuestSystem        = require(script.Parent.src.QuestSystem)
local DialogueSystem     = require(script.Parent.src.DialogueSystem)
local CombatSystem       = require(script.Parent.src.CombatSystem)
local CurrencySystem     = require(script.Parent.src.CurrencySystem)
local CraftingSystem     = require(script.Parent.src.CraftingSystem)
local EquipmentSystem    = require(script.Parent.src.EquipmentSystem)
local LootSystem         = require(script.Parent.src.LootSystem)
local StatusEffectSystem = require(script.Parent.src.StatusEffectSystem)
local LeaderboardSystem  = require(script.Parent.src.LeaderboardSystem)
local TimerSystem        = require(script.Parent.src.TimerSystem)
local NotificationSystem = require(script.Parent.src.NotificationSystem)

-- Environment & art style (3)
-- ColorPaletteSystem manages limited color palettes for UI/vehicles/furniture.
-- StylePresets provides preset art-style configurations.
-- LODSystem reduces mesh detail for distant objects to maintain performance.
-- NOTE: LowPolyGenerator and EnvironmentBuilder (procedural object scattering)
-- live in src/ for use in other games but are not needed with a hand-built map.
local ColorPaletteSystem = require(script.Parent.src.ColorPaletteSystem)
local StylePresets       = require(script.Parent.src.StylePresets)
local LODSystem          = require(script.Parent.src.LODSystem)

-- Extensions (5)
-- AtmosphereSystem drives per-biome lighting and fog; used here for day/night.
-- NOTE: The full procedural terrain pipeline (NoiseLib, TerrainGenerator,
-- ErosionSimulator, BiomeSystem, ObjectPlacer, WaterSystem, CaveSystem,
-- ChunkManager, WorldBuilder) lives in src/ for other games to plug in.
local AtmosphereSystem  = require(script.Parent.src.AtmosphereSystem)
local SaveSystem        = require(script.Parent.src.SaveSystem)
local PathfindingSystem = require(script.Parent.src.PathfindingSystem)
local WeatherSystem     = require(script.Parent.src.WeatherSystem)
local AudioSystem       = require(script.Parent.src.AudioSystem)

-- Adopt Me domain systems (4)
local PetSystem     = require(script.Parent.src.PetSystem)
local HomeSystem    = require(script.Parent.src.HomeSystem)
local TradeSystem   = require(script.Parent.src.TradeSystem)
local VehicleSystem = require(script.Parent.src.VehicleSystem)

-- Type aliases
type PetDef    = PetSystem.PetDef
type OwnedPet  = PetSystem.OwnedPet
type TradeOffer = TradeSystem.TradeOffer


-- =============================================================================
-- SECTION 2: DEPENDENCY INJECTION WIRING — Instantiate all 33 modules
-- =============================================================================

local bus = EventBus.new()
local config = Config.new({
	autoSaveInterval      = 120,
	weatherCycleInterval  = 300,
	moodDecayInterval     = 60,
	leaderboardInterval   = 60,
	dailyQuestCount       = 3,
	startingBucks         = 500,
	xpFormula = function(lvl: number): number return math.floor(100 * lvl ^ 1.5) end,
})

-- Core gameplay systems
local inv        = Inventory.new(bus, 50)
local currency   = CurrencySystem.new(bus, config)
local xp         = XPSystem.new(bus, config)
local quests     = QuestSystem.new(bus, config)
local skills     = Skills.new(bus)
local dialogue   = DialogueSystem.new(bus)
local ui         = UIFramework.new(bus)
local store      = DataStoreSafe.new("AdoptMeData")
local notify     = NotificationSystem.new(bus, config)
local timer      = TimerSystem.new(bus)
local statusFx   = StatusEffectSystem.new(bus)
local equip      = EquipmentSystem.new(bus)
local craft      = CraftingSystem.new(bus)
local loot       = LootSystem.new(bus)
local combat     = CombatSystem.new(bus)
local leaderboard = LeaderboardSystem.new(bus, store, config)
local physics    = Physics.new(bus)

-- Environment & art style
local palette    = ColorPaletteSystem.new(bus, config)
local styles     = StylePresets.new(bus)
local lod        = LODSystem.new(bus)

-- Atmosphere for day/night lighting transitions
local atmos      = AtmosphereSystem.new(bus)

-- Extensions
local save        = SaveSystem.new(bus, store, config)
local pathfinding = PathfindingSystem.new(bus, { slopeLimit = 45, resolution = 4 })
local weather     = WeatherSystem.new(bus, { defaultInterval = 300 })
local audio       = AudioSystem.new(bus, { masterVolume = 0.5 })

-- Adopt Me domain systems
local pets     = PetSystem.new(bus, inv, xp, timer)
local homes    = HomeSystem.new(bus, inv, currency)
local trade    = TradeSystem.new(bus, inv, currency, timer)
local vehicles = VehicleSystem.new(bus, inv)

print("[AdoptMeDemo] All 33 modules instantiated via dependency injection.")


-- =============================================================================
-- SECTION 3: COLOR PALETTE — Art-style colours for UI, vehicles, and furniture
-- =============================================================================
-- Register the game's colour palette so ColorPaletteSystem can supply
-- consistent colours to vehicle paint, furniture swatches, and UI elements.

local adoptMePalette = palette:CreatePalette("AdoptMe", {
	Color3.fromRGB(34,  85,  51),   -- deep green
	Color3.fromRGB(106, 168, 79),   -- leaf green
	Color3.fromRGB(101, 67,  33),   -- bark brown
	Color3.fromRGB(194, 178, 128),  -- sand
	Color3.fromRGB(135, 206, 235),  -- sky blue
	Color3.fromRGB(255, 223, 186),  -- warm cream
	Color3.fromRGB(255, 105, 97),   -- coral / pet-shop pink
	Color3.fromRGB(255, 213, 0),    -- golden Bucks yellow
})

-- Apply the "FlatShaded" style preset for a clean low-poly look.
styles:ApplyPreset("FlatShaded")


-- =============================================================================
-- SECTION 4: PET SYSTEM SETUP — 20 pets, 4 eggs, hatching, leveling, neon
-- =============================================================================

local PET_REGISTRY: { PetDef } = {
	-- Starter Egg pool (common only — first pet is always a familiar friend)
	{ id = "dog",      name = "Dog",           rarity = "common",     modelId = "rbxassetid://pet_dog",      eggId = "starter_egg", tricks = { "sit", "lay_down", "roll_over", "beg" },        favoriteFoods = { "food_bacon", "food_apple" },        flyable = false, rideable = false },
	{ id = "cat",      name = "Cat",           rarity = "common",     modelId = "rbxassetid://pet_cat",      eggId = "starter_egg", tricks = { "sit", "lay_down", "pounce", "beg" },           favoriteFoods = { "food_fish", "food_milk" },          flyable = false, rideable = false },
	-- Common
	{ id = "bunny",    name = "Bunny",         rarity = "common",     modelId = "rbxassetid://pet_bunny",    eggId = "egg_cracked", tricks = { "hop", "sit", "spin" },                         favoriteFoods = { "food_carrot", "food_apple" },       flyable = false, rideable = false },
	-- Uncommon
	{ id = "bear",     name = "Bear",          rarity = "uncommon",   modelId = "rbxassetid://pet_bear",     eggId = "egg_cracked", tricks = { "sit", "dance", "lay_down" },                   favoriteFoods = { "food_honey", "food_apple" },        flyable = false, rideable = false },
	{ id = "fox",      name = "Fox",           rarity = "uncommon",   modelId = "rbxassetid://pet_fox",      eggId = "egg_cracked", tricks = { "pounce", "dig", "sit" },                       favoriteFoods = { "food_bacon", "food_berry" },        flyable = false, rideable = false },
	{ id = "meerkat",  name = "Meerkat",       rarity = "uncommon",   modelId = "rbxassetid://pet_meerkat",  eggId = "egg_cracked", tricks = { "stand", "dig", "sit" },                        favoriteFoods = { "food_bug", "food_apple" },          flyable = false, rideable = false },
	-- Rare
	{ id = "wolf",     name = "Wolf",          rarity = "rare",       modelId = "rbxassetid://pet_wolf",     eggId = "egg_pet",     tricks = { "howl", "sit", "pounce", "dig" },               favoriteFoods = { "food_meat", "food_bacon" },         flyable = false, rideable = false },
	{ id = "crow",     name = "Crow",          rarity = "rare",       modelId = "rbxassetid://pet_crow",     eggId = "egg_cracked", tricks = { "fly_loop", "perch", "caw" },                   favoriteFoods = { "food_cracker", "food_berry" },      flyable = true,  rideable = false },
	{ id = "elephant", name = "Elephant",      rarity = "rare",       modelId = "rbxassetid://pet_elephant", eggId = "egg_cracked", tricks = { "trumpet", "sit", "stomp" },                    favoriteFoods = { "food_peanut", "food_banana" },      flyable = false, rideable = true  },
	{ id = "hyena",    name = "Hyena",         rarity = "rare",       modelId = "rbxassetid://pet_hyena",    eggId = "egg_cracked", tricks = { "laugh", "sit", "pounce" },                     favoriteFoods = { "food_meat", "food_bacon" },         flyable = false, rideable = false },
	-- Ultra-Rare
	{ id = "giraffe",  name = "Giraffe",       rarity = "ultra-rare", modelId = "rbxassetid://pet_giraffe",  eggId = "egg_pet",     tricks = { "stretch", "sit", "eat_leaf" },                 favoriteFoods = { "food_leaf", "food_apple" },         flyable = false, rideable = true  },
	{ id = "parrot",   name = "Parrot",        rarity = "ultra-rare", modelId = "rbxassetid://pet_parrot",   eggId = "egg_pet",     tricks = { "fly_loop", "talk", "perch", "dance" },         favoriteFoods = { "food_cracker", "food_apple" },      flyable = true,  rideable = false },
	{ id = "owl",      name = "Owl",           rarity = "ultra-rare", modelId = "rbxassetid://pet_owl",      eggId = "egg_pet",     tricks = { "fly_loop", "hoot", "perch", "pounce" },        favoriteFoods = { "food_mouse", "food_bacon" },        flyable = true,  rideable = false },
	{ id = "turtle",   name = "Turtle",        rarity = "ultra-rare", modelId = "rbxassetid://pet_turtle",   eggId = "egg_pet",     tricks = { "hide", "swim", "sit" },                        favoriteFoods = { "food_lettuce", "food_apple" },      flyable = false, rideable = false },
	{ id = "penguin",  name = "Penguin",       rarity = "ultra-rare", modelId = "rbxassetid://pet_penguin",  eggId = "egg_pet",     tricks = { "slide", "swim", "waddle", "sit" },             favoriteFoods = { "food_fish", "food_snow_cone" },     flyable = false, rideable = false },
	-- Legendary
	{ id = "dragon",   name = "Dragon",        rarity = "legendary",  modelId = "rbxassetid://pet_dragon",   eggId = "egg_royal",   tricks = { "fly_loop", "fire_breath", "sit", "dance" },    favoriteFoods = { "food_golden_apple", "food_meat" },  flyable = true,  rideable = true  },
	{ id = "unicorn",  name = "Unicorn",       rarity = "legendary",  modelId = "rbxassetid://pet_unicorn",  eggId = "egg_royal",   tricks = { "fly_loop", "rainbow", "dance", "sit" },        favoriteFoods = { "food_golden_apple", "food_sugar" }, flyable = true,  rideable = true  },
	{ id = "griffin",  name = "Griffin",       rarity = "legendary",  modelId = "rbxassetid://pet_griffin",  eggId = "egg_royal",   tricks = { "fly_loop", "sit", "pounce", "dive" },          favoriteFoods = { "food_meat", "food_golden_apple" },  flyable = true,  rideable = true  },
	{ id = "kangaroo", name = "Kangaroo",      rarity = "legendary",  modelId = "rbxassetid://pet_kangaroo", eggId = "egg_royal",   tricks = { "hop", "kick", "sit", "pouch" },                favoriteFoods = { "food_carrot", "food_apple" },       flyable = false, rideable = true  },
	{ id = "shadow",   name = "Shadow Dragon", rarity = "legendary",  modelId = "rbxassetid://pet_shadow",   eggId = nil,           tricks = { "fly_loop", "shadow_burst", "sit", "dance" },   favoriteFoods = { "food_shadow_apple" },               flyable = true,  rideable = true  },
}

for _, petDef in ipairs(PET_REGISTRY) do
	pets:RegisterPet(petDef)
end
print("[AdoptMeDemo] Registered " .. tostring(#PET_REGISTRY) .. " pets.")

-- Register the 4 egg types as inventory items.
-- Starter (free), Cracked (350 Bucks), Pet Egg (600), Royal (1450).
inv:DefineItem({ id = "starter_egg", name = "Starter Egg", maxStack = 1,  equippable = false })
inv:DefineItem({ id = "egg_cracked", name = "Cracked Egg", maxStack = 10, equippable = false })
inv:DefineItem({ id = "egg_pet",     name = "Pet Egg",     maxStack = 10, equippable = false })
inv:DefineItem({ id = "egg_royal",   name = "Royal Egg",   maxStack = 10, equippable = false })

-- Register food items
local FOODS = {
	"food_apple", "food_bacon", "food_banana", "food_carrot", "food_fish",
	"food_meat",  "food_golden_apple", "food_honey", "food_cracker", "food_lettuce",
}
for _, foodId in ipairs(FOODS) do
	local label = foodId:gsub("food_", ""):gsub("_", " ")
	label = label:sub(1,1):upper() .. label:sub(2)
	inv:DefineItem({ id = foodId, name = label, maxStack = 99, equippable = false })
end

-- Give every new player a Starter Egg on join.
bus:Subscribe("PlayerJoined", function(data: { playerId: string, playerName: string })
	inv:AddItem("starter_egg", 1)
	print("[AdoptMeDemo] Gave Starter Egg to " .. data.playerName)
	notify:Show("success", "Welcome!", "You received a Starter Egg! Open it to get your first pet.", 5)
end)

-- Hatch an egg when the player uses one from inventory.
bus:Subscribe("ItemUsed", function(data: { itemId: string })
	if data.itemId:match("^egg_") or data.itemId == "starter_egg" then
		local hatchedPet = pets:HatchEgg(data.itemId)
		if hatchedPet then
			inv:RemoveItem(data.itemId, 1)
			notify:Show("success", "Pet Hatched!", "You got a " .. hatchedPet.name .. "!", 5)
		end
	end
end)

-- Pet mood decays every 60 seconds.
timer:StartTimer(60, function()
	pets:UpdateMood(60)
end, true)

-- Feeding a pet grants XP.
bus:Subscribe("PetFed", function(data: { instanceId: string, xp: number })
	xp:AddXP(10)
	notify:Show("info", "Pet Fed", "Your pet enjoyed the food! +10 XP", 3)
	quests:AdvanceObjective("quest_daily_feed", "obj_feed", 1)
end)

bus:Subscribe("PetPlayed", function(data: { instanceId: string, fun: number })
	quests:AdvanceObjective("quest_daily_play", "obj_play", 1)
end)

bus:Subscribe("TrickTaught", function(data: { instanceId: string, trickId: string })
	notify:Show("success", "Trick Learned!", "Your pet learned " .. data.trickId:gsub("_", " ") .. "!", 4)
end)

bus:Subscribe("NeonCreated", function(data: { instanceId: string, defId: string })
	notify:Show("success", "Neon Pet Created!", "Your pets combined into a glowing Neon " .. data.defId .. "!", 6)
end)


-- =============================================================================
-- SECTION 5: ECONOMY & TRADING — Bucks, shop NPCs, player trading
-- =============================================================================

currency:RegisterCurrency({
	id             = "bucks",
	name           = "Bucks",
	symbol         = "$",
	defaultBalance = 500,
})

-- Pet Shop NPC
local petShopDialogue = {
	id = "pet_shop",
	rootNodeId = "greeting",
	nodes = {
		{ id = "greeting", speaker = "Pet Shop Keeper", text = "Welcome to the Pet Shop! Looking for a new friend?",
		  choices = {
			  { text = "Buy Cracked Egg (350 Bucks)",  condition = function() return currency:CanAfford("bucks", 350)  end, action = function() currency:Subtract("bucks", 350,  "bought_cracked_egg"); inv:AddItem("egg_cracked", 1); notify:Show("success", "Purchased!", "You bought a Cracked Egg!", 3) end },
			  { text = "Buy Pet Egg (600 Bucks)",      condition = function() return currency:CanAfford("bucks", 600)  end, action = function() currency:Subtract("bucks", 600,  "bought_pet_egg");    inv:AddItem("egg_pet",    1); notify:Show("success", "Purchased!", "You bought a Pet Egg!", 3) end },
			  { text = "Buy Royal Egg (1450 Bucks)",   condition = function() return currency:CanAfford("bucks", 1450) end, action = function() currency:Subtract("bucks", 1450, "bought_royal_egg");  inv:AddItem("egg_royal",  1); notify:Show("success", "Purchased!", "You bought a Royal Egg!", 3) end },
			  { text = "Nevermind", nextNodeId = nil },
		  } },
	},
}
dialogue:RegisterTree(petShopDialogue)

-- Furniture Shop NPC
local furnitureShopDialogue = {
	id = "furniture_shop",
	rootNodeId = "greeting",
	nodes = {
		{ id = "greeting", speaker = "Furniture Clerk", text = "Decorate your home with our finest furniture!",
		  choices = {
			  { text = "Buy Sofa (200 Bucks)", condition = function() return currency:CanAfford("bucks", 200) end, action = function() currency:Subtract("bucks", 200, "bought_sofa"); inv:AddItem("furn_sofa", 1); notify:Show("success", "Purchased!", "You bought a Sofa!", 3) end },
			  { text = "Buy Bed (150 Bucks)",  condition = function() return currency:CanAfford("bucks", 150) end, action = function() currency:Subtract("bucks", 150, "bought_bed");  inv:AddItem("furn_bed",  1); notify:Show("success", "Purchased!", "You bought a Bed!", 3) end },
			  { text = "Buy TV (300 Bucks)",   condition = function() return currency:CanAfford("bucks", 300) end, action = function() currency:Subtract("bucks", 300, "bought_tv");   inv:AddItem("furn_tv",   1); notify:Show("success", "Purchased!", "You bought a TV!", 3) end },
			  { text = "Nevermind", nextNodeId = nil },
		  } },
	},
}
dialogue:RegisterTree(furnitureShopDialogue)

-- Vehicle Shop NPC
local vehicleShopDialogue = {
	id = "vehicle_shop",
	rootNodeId = "greeting",
	nodes = {
		{ id = "greeting", speaker = "Vehicle Dealer", text = "Need a ride? Check out our vehicles!",
		  choices = {
			  { text = "Buy Bicycle (100 Bucks)",     condition = function() return currency:CanAfford("bucks", 100)  end, action = function() currency:Subtract("bucks", 100,  "bought_bicycle");    notify:Show("success", "Purchased!", "You bought a Bicycle!", 3) end },
			  { text = "Buy Car (500 Bucks)",          condition = function() return currency:CanAfford("bucks", 500)  end, action = function() currency:Subtract("bucks", 500,  "bought_car");        notify:Show("success", "Purchased!", "You bought a Car!", 3) end },
			  { text = "Buy Sports Car (1200 Bucks)", condition = function() return currency:CanAfford("bucks", 1200) end, action = function() currency:Subtract("bucks", 1200, "bought_sports_car"); notify:Show("success", "Purchased!", "You bought a Sports Car!", 3) end },
			  { text = "Nevermind", nextNodeId = nil },
		  } },
	},
}
dialogue:RegisterTree(vehicleShopDialogue)

-- General Store NPC
local generalStoreDialogue = {
	id = "general_store",
	rootNodeId = "greeting",
	nodes = {
		{ id = "greeting", speaker = "Shopkeeper", text = "Welcome! We have food, treats, and supplies for your pets!",
		  choices = {
			  { text = "Buy Apple (5 Bucks)",         condition = function() return currency:CanAfford("bucks", 5)  end, action = function() currency:Subtract("bucks", 5,  "bought_apple");        inv:AddItem("food_apple",        5); notify:Show("success", "Purchased!", "You bought 5 Apples!", 3) end },
			  { text = "Buy Golden Apple (50 Bucks)", condition = function() return currency:CanAfford("bucks", 50) end, action = function() currency:Subtract("bucks", 50, "bought_golden_apple"); inv:AddItem("food_golden_apple", 1); notify:Show("success", "Purchased!", "You bought a Golden Apple!", 3) end },
			  { text = "Buy Pizza (20 Bucks)",        condition = function() return currency:CanAfford("bucks", 20) end, action = function() currency:Subtract("bucks", 20, "bought_pizza");        inv:AddItem("food_pizza",        1); notify:Show("success", "Purchased!", "You bought a Pizza!", 3) end },
			  { text = "Nevermind", nextNodeId = nil },
		  } },
	},
}
dialogue:RegisterTree(generalStoreDialogue)

-- Trading: two-phase confirmation flow.
bus:Subscribe("TradeRequested", function(data: { tradeId: string, playerA: string, playerB: string })
	notify:Show("warning", "Trade Request!", data.playerA .. " wants to trade with you!", 5)
end)

bus:Subscribe("TradeCompleted", function(data: { tradeId: string, offerA: TradeOffer, offerB: TradeOffer })
	notify:Show("success", "Trade Complete!", "Items and Bucks were exchanged successfully!", 5)
	quests:AdvanceObjective("quest_daily_trade", "obj_trade", 1)
end)


-- =============================================================================
-- SECTION 6: HOME BUILDING — Free apartment, furniture, room painting
-- =============================================================================

local FURNITURE_CATALOG = {
	{ id = "furn_sofa",  name = "Sofa",  category = "seating",     modelId = "rbxassetid://furn_sofa",  footprint = Vector2.new(3, 1.5), price = 200, interactable = true,  colorOptions = { Color3.fromRGB(150, 50, 50), Color3.fromRGB(50, 50, 150), Color3.fromRGB(50, 150, 50) } },
	{ id = "furn_bed",   name = "Bed",   category = "bedroom",     modelId = "rbxassetid://furn_bed",   footprint = Vector2.new(3, 4),   price = 150, interactable = true,  colorOptions = { Color3.fromRGB(200, 200, 200), Color3.fromRGB(150, 100, 50) } },
	{ id = "furn_tv",    name = "TV",    category = "electronics", modelId = "rbxassetid://furn_tv",    footprint = Vector2.new(2, 0.5), price = 300, interactable = true,  colorOptions = nil },
	{ id = "furn_table", name = "Table", category = "furniture",   modelId = "rbxassetid://furn_table", footprint = Vector2.new(3, 3),   price = 100, interactable = false, colorOptions = { Color3.fromRGB(101, 67, 33) } },
	{ id = "furn_lamp",  name = "Lamp",  category = "lighting",    modelId = "rbxassetid://furn_lamp",  footprint = Vector2.new(1, 1),   price = 50,  interactable = true,  colorOptions = nil },
	{ id = "furn_plant", name = "Plant", category = "decoration",  modelId = "rbxassetid://furn_plant", footprint = Vector2.new(1, 1),   price = 30,  interactable = false, colorOptions = { Color3.fromRGB(34, 139, 34) } },
}
for _, furnDef in ipairs(FURNITURE_CATALOG) do
	homes:RegisterFurniture(furnDef)
	inv:DefineItem({ id = furnDef.id, name = furnDef.name, maxStack = 99, equippable = false })
end

-- Every player gets a free Apartment on join.
bus:Subscribe("PlayerJoined", function(data: { playerId: string })
	local home = homes:BuyHome(data.playerId, "apartment")
	if home then
		print("[AdoptMeDemo] Gave free Apartment to " .. data.playerId)
	end
end)

bus:Subscribe("FurniturePlaced", function(data: { instanceId: string, defId: string, roomId: string })
	notify:Show("success", "Furniture Placed!", data.defId .. " placed in your home!", 3)
end)

bus:Subscribe("RoomPainted", function(data: { roomId: string, wallColor: Color3, floorColor: Color3 })
	notify:Show("info", "Room Painted!", "Your room has a fresh new look!", 3)
end)


-- =============================================================================
-- SECTION 7: VEHICLE SYSTEM — Equip, spawn, drive, paint
-- =============================================================================

local VEHICLE_REGISTRY = {
	{ id = "veh_bicycle",    name = "Bicycle",    category = "bike"        :: "bike",        modelId = "rbxassetid://veh_bicycle",    speed = 25, seats = 1, price = 100,  rarity = "common"     },
	{ id = "veh_car",        name = "Car",         category = "car"         :: "car",         modelId = "rbxassetid://veh_car",        speed = 40, seats = 4, price = 500,  rarity = "common"     },
	{ id = "veh_sports_car", name = "Sports Car",  category = "car"         :: "car",         modelId = "rbxassetid://veh_sports_car", speed = 65, seats = 2, price = 1200, rarity = "rare"       },
	{ id = "veh_jeep",       name = "Jeep",        category = "car"         :: "car",         modelId = "rbxassetid://veh_jeep",       speed = 35, seats = 4, price = 800,  rarity = "uncommon"   },
	{ id = "veh_convertible",name = "Convertible", category = "car"         :: "car",         modelId = "rbxassetid://veh_convertible",speed = 50, seats = 2, price = 1500, rarity = "ultra-rare" },
	{ id = "veh_helicopter", name = "Helicopter",  category = "helicopter"  :: "helicopter",  modelId = "rbxassetid://veh_helicopter", speed = 80, seats = 4, price = 3000, rarity = "legendary"  },
	{ id = "veh_hoverboard", name = "Hoverboard",  category = "hoverboard"  :: "hoverboard",  modelId = "rbxassetid://veh_hoverboard", speed = 45, seats = 1, price = 400,  rarity = "rare"       },
	{ id = "veh_skateboard", name = "Skateboard",  category = "bike"        :: "bike",        modelId = "rbxassetid://veh_skateboard", speed = 20, seats = 1, price = 75,   rarity = "common"     },
	{ id = "veh_boat",       name = "Boat",        category = "boat"        :: "boat",        modelId = "rbxassetid://veh_boat",       speed = 30, seats = 3, price = 600,  rarity = "uncommon"   },
	{ id = "veh_unicycle",   name = "Unicycle",    category = "bike"        :: "bike",        modelId = "rbxassetid://veh_unicycle",   speed = 15, seats = 1, price = 50,   rarity = "common"     },
}

for _, vehDef in ipairs(VEHICLE_REGISTRY) do
	vehicles:RegisterVehicle(vehDef)
end

-- Every player gets a free skateboard on join.
bus:Subscribe("PlayerJoined", function(data: { playerId: string })
	vehicles:GiveVehicle(data.playerId .. "_skateboard", "veh_skateboard", Color3.fromRGB(200, 50, 50))
end)

bus:Subscribe("VehicleSpawned", function(data: { instanceId: string, defId: string })
	local def = vehicles:GetVehicleDef(data.defId)
	notify:Show("info", "Vehicle Spawned!", (def and def.name or "Vehicle") .. " is ready to drive!", 3)
end)

bus:Subscribe("VehiclePainted", function(data: { instanceId: string, color: Color3 })
	notify:Show("info", "Vehicle Painted!", "Your ride has a fresh coat of paint!", 3)
end)


-- =============================================================================
-- SECTION 8: QUESTS & DAILY REWARDS — 3 daily quests + login bonus
-- =============================================================================

local QUEST_DEFS = {
	{
		id = "quest_daily_feed",
		title = "Feed Your Pet",
		description = "Feed your pet once to keep it happy and healthy!",
		objectives = {
			{ id = "obj_feed", description = "Feed your pet", targetCount = 1, currentCount = 0, completed = false },
		},
		rewards = { { type = "currency", id = "bucks", amount = 50 } },
	},
	{
		id = "quest_daily_trade",
		title = "Make a Trade",
		description = "Complete one trade with another player!",
		objectives = {
			{ id = "obj_trade", description = "Complete a trade", targetCount = 1, currentCount = 0, completed = false },
		},
		rewards = { { type = "currency", id = "bucks", amount = 100 } },
	},
	{
		id = "quest_daily_play",
		title = "Play With Pet",
		description = "Play with your pet 3 times!",
		objectives = {
			{ id = "obj_play", description = "Play with pet", targetCount = 3, currentCount = 0, completed = false },
		},
		rewards = { { type = "currency", id = "bucks", amount = 75 } },
	},
}

for _, questDef in ipairs(QUEST_DEFS) do
	quests:RegisterQuest(questDef)
end

bus:Subscribe("PlayerJoined", function(data: { playerId: string })
	for _, questDef in ipairs(QUEST_DEFS) do
		quests:AcceptQuest(questDef.id)
	end
	print("[AdoptMeDemo] Accepted 3 daily quests for " .. data.playerId)
end)

bus:Subscribe("QuestCompleted", function(data: { questId: string })
	local rewards = quests:TurnInQuest(data.questId)
	if rewards then
		for _, reward in ipairs(rewards) do
			if reward.type == "currency" then
				currency:Add(reward.id, reward.amount, "quest_reward_" .. data.questId)
			end
		end
		notify:Show("success", "Quest Complete!", data.questId .. " finished! Rewards granted!", 5)
	end
end)

-- Daily login reward (50-200 Bucks or random food)
local lastLoginStore: { [string]: number } = {}
bus:Subscribe("PlayerJoined", function(data: { playerId: string })
	local now = os.time()
	local lastLogin = lastLoginStore[data.playerId] or 0
	local daysSince = math.floor((now - lastLogin) / 86400)
	if daysSince >= 1 or lastLogin == 0 then
		local rewardType = math.random(1, 2)
		if rewardType == 1 then
			local bucksAmount = math.random(50, 200)
			currency:Add("bucks", bucksAmount, "daily_reward")
			notify:Show("success", "Daily Reward!", "You got " .. tostring(bucksAmount) .. " Bucks!", 5)
		else
			local foodReward = FOODS[math.random(1, #FOODS)]
			inv:AddItem(foodReward, math.random(1, 5))
			notify:Show("success", "Daily Reward!", "You got some " .. foodReward:gsub("food_","") .. "!", 5)
		end
		lastLoginStore[data.playerId] = now
	end
end)


-- =============================================================================
-- SECTION 9: WEATHER & AUDIO — Cycling weather, biome ambience, day/night
-- =============================================================================

weather:EnableRandomWeather(300)

-- Biome soundscapes (still useful even without procedural terrain — zones in
-- the hand-built map can emit "BiomeEntered" events to switch soundscapes).
audio:RegisterBiomeSoundscape("temperate_forest", {
	daySounds    = { "rbxassetid://amb_forest_day" },
	nightSounds  = { "rbxassetid://amb_forest_night" },
	transitionTime = 3,
	volume       = 0.5,
})
audio:RegisterBiomeSoundscape("grassland", {
	daySounds    = { "rbxassetid://amb_plains_day" },
	nightSounds  = { "rbxassetid://amb_plains_night" },
	transitionTime = 3,
	volume       = 0.4,
})
audio:RegisterBiomeSoundscape("town", {
	daySounds    = { "rbxassetid://amb_town_day" },
	nightSounds  = { "rbxassetid://amb_town_night" },
	transitionTime = 3,
	volume       = 0.4,
})

audio:PlayBiomeAmbience("grassland")

-- 20-minute full day cycle: dawn -> dusk -> dawn.
local function startDayNightCycle()
	task.spawn(function()
		while true do
			atmos:TransitionAtmosphere("Grassland", "Desert", 600)  -- 10 min day
			audio:SetTimeOfDay(12)
			task.wait(600)
			atmos:TransitionAtmosphere("Desert", "Grassland", 600)  -- 10 min night
			audio:SetTimeOfDay(0)
			task.wait(600)
		end
	end)
end
startDayNightCycle()


-- =============================================================================
-- SECTION 10: SAVE & PERSISTENCE — Auto-save every 120s, load on join
-- =============================================================================

save:AutoSave(120)

bus:Subscribe("PlayerJoined", function(data: { playerId: string })
	local savedData = save:LoadWorld()
	if savedData then
		print("[AdoptMeDemo] Loaded world data for " .. data.playerId .. ", version: " .. savedData.metadata.version)
	else
		print("[AdoptMeDemo] No saved data for " .. data.playerId .. ", starting fresh.")
	end
end)

bus:Subscribe("PlayerLeaving", function(data: { playerId: string })
	local ok = save:FlushQueue()
	if ok then
		print("[AdoptMeDemo] Force-saved data for leaving player " .. data.playerId)
	end
end)


-- =============================================================================
-- SECTION 11: LEADERBOARD — Richest players, top 10 display
-- =============================================================================

leaderboard:RegisterBoard({
	name          = "richest_players",
	maxEntries    = 100,
	sortOrder     = "desc",
	resetInterval = nil,
})

timer:StartTimer(60, function()
	local bucksBalance = currency:GetBalance("bucks")
	leaderboard:SubmitScore("richest_players", "player_local", "Player", bucksBalance)
end, true)

bus:Subscribe("LeaderboardUpdated", function(data: { boardName: string })
	if data.boardName == "richest_players" then
		local top10 = leaderboard:GetTop("richest_players", 10)
		print("[AdoptMeDemo] --- Top 10 Richest Players ---")
		for rank, entry in ipairs(top10) do
			print("  " .. tostring(rank) .. ". " .. entry.playerName .. ": $" .. tostring(entry.score))
		end
	end
end)


-- =============================================================================
-- SECTION 12: UI & NOTIFICATIONS — Bucks bar, pet panel, quest tracker
-- =============================================================================
-- UI is CLIENT-SIDE only. Guard ensures this is skipped on the server.
-- In production, move this section into a LocalScript sharing the same bus.

local _runService = game:GetService("RunService")
if _runService:IsClient() then
	local Players   = game:GetService("Players")
	local localPlayer = Players.LocalPlayer
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name         = "AdoptMeUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent       = localPlayer:WaitForChild("PlayerGui")

	-- Bucks bar (top-left)
	local bucksBar = ui:CreateBar(screenGui, UDim2.new(0, 200, 0, 30), Color3.fromRGB(0, 170, 0))
	bucksBar.Position = UDim2.new(0, 10, 0, 10)
	bus:Subscribe("CurrencyBalanceChanged", function(data: { currencyId: string, newBalance: number })
		if data.currencyId == "bucks" then
			ui:ThemeBar(bucksBar, math.clamp(data.newBalance / 10000, 0, 1))
		end
	end)

	-- Auto-equip the first pet hatched
	bus:Subscribe("EggHatched", function(data: { petName: string, instanceId: string })
		pets:SetEquippedPet(data.instanceId)
	end)

	-- Pet status panel (below Bucks bar)
	local petPanel = Instance.new("Frame")
	petPanel.Name                 = "PetStatusPanel"
	petPanel.Size                 = UDim2.new(0, 250, 0, 120)
	petPanel.Position             = UDim2.new(0, 10, 0, 50)
	petPanel.BackgroundColor3     = Color3.fromRGB(30, 30, 30)
	petPanel.BackgroundTransparency = 0.3
	petPanel.BorderSizePixel      = 0
	petPanel.Parent               = screenGui
	local petCorner = Instance.new("UICorner")
	petCorner.CornerRadius = UDim.new(0, 8)
	petCorner.Parent       = petPanel

	-- Quest tracker (top-right)
	local questPanel = Instance.new("Frame")
	questPanel.Name                 = "QuestTracker"
	questPanel.Size                 = UDim2.new(0, 250, 0, 150)
	questPanel.Position             = UDim2.new(1, -260, 0, 10)
	questPanel.BackgroundColor3     = Color3.fromRGB(30, 30, 30)
	questPanel.BackgroundTransparency = 0.3
	questPanel.BorderSizePixel      = 0
	questPanel.Parent               = screenGui
	local questCorner = Instance.new("UICorner")
	questCorner.CornerRadius = UDim.new(0, 8)
	questCorner.Parent       = questPanel

	bus:Subscribe("LevelUp", function(data: { level: number })
		notify:Show("success", "Level Up!", "You reached level " .. tostring(data.level) .. "!", 4)
	end)

	bus:Subscribe("WeatherChanged", function(data: { type: string })
		notify:Show("info", "Weather Changed!", "It's now " .. data.type .. " outside!", 4)
	end)
else
	print("[AdoptMeDemo] Section 12 skipped (server context — UI runs on LocalScript in production)")
end


-- =============================================================================
-- SECTION 13: EVENT SUBSCRIPTIONS — Debug log for all events
-- =============================================================================

bus:Subscribe("EggHatched", function(data: { petName: string, rarity: string, instanceId: string })
	print("[EVENT] EggHatched: " .. data.petName .. " (" .. data.rarity .. ") id=" .. data.instanceId)
end)

bus:Subscribe("PetFed", function(data: { instanceId: string, hunger: number, xp: number })
	print("[EVENT] PetFed: pet=" .. data.instanceId .. " hunger=" .. tostring(data.hunger))
end)

bus:Subscribe("PetPlayed", function(data: { instanceId: string, fun: number, xp: number })
	print("[EVENT] PetPlayed: pet=" .. data.instanceId .. " fun=" .. tostring(data.fun))
end)

bus:Subscribe("PetAgedUp", function(data: { instanceId: string, oldStage: string, newStage: string, xp: number })
	print("[EVENT] PetAgedUp: pet=" .. data.instanceId .. " " .. data.oldStage .. " -> " .. data.newStage)
end)

bus:Subscribe("NeonCreated", function(data: { instanceId: string, defId: string })
	print("[EVENT] NeonCreated: " .. data.defId .. " id=" .. data.instanceId)
end)

bus:Subscribe("TradeCompleted", function(data: { tradeId: string })
	print("[EVENT] TradeCompleted: trade=" .. data.tradeId)
end)

bus:Subscribe("FurniturePlaced", function(data: { instanceId: string, defId: string })
	print("[EVENT] FurniturePlaced: " .. data.defId .. " id=" .. data.instanceId)
end)

bus:Subscribe("VehicleSpawned", function(data: { instanceId: string, defId: string })
	print("[EVENT] VehicleSpawned: " .. data.defId .. " id=" .. data.instanceId)
end)

bus:Subscribe("QuestCompleted", function(data: { questId: string })
	print("[EVENT] QuestCompleted: " .. data.questId)
end)

bus:Subscribe("WeatherChanged", function(data: { type: string, intensity: number })
	print("[EVENT] WeatherChanged: " .. data.type .. " intensity=" .. tostring(data.intensity))
end)

bus:Subscribe("AutoSaveTriggered", function(data: { chunksFlushed: number })
	print("[EVENT] AutoSave: " .. tostring(data.chunksFlushed) .. " chunks flushed")
end)

bus:Subscribe("LeaderboardUpdated", function(data: { boardName: string })
	print("[EVENT] LeaderboardUpdated: " .. data.boardName)
end)

bus:Subscribe("CurrencyBalanceChanged", function(data: { currencyId: string, newBalance: number })
	print("[EVENT] CurrencyBalanceChanged: " .. data.currencyId .. " = " .. tostring(data.newBalance))
end)

bus:Subscribe("PetEquipped", function(data: { instanceId: string? })
	print("[EVENT] PetEquipped: " .. tostring(data.instanceId))
end)

bus:Subscribe("RoomPainted", function(data: { roomId: string })
	print("[EVENT] RoomPainted: " .. data.roomId)
end)


-- =============================================================================
-- SECTION 14: GAME LOOP — Heartbeat-driven update system
-- =============================================================================

local RunService = game:GetService("RunService")

local moodTimer        = 0
local weatherTimer     = 0
local saveTimer        = 0
local leaderboardTimer = 0
local lodTimer         = 0

local heartbeatConnection = RunService.Heartbeat:Connect(function(dt: number)
	-- Pet mood decay (every 60s)
	moodTimer += dt
	if moodTimer >= 60 then
		moodTimer = 0
		pets:UpdateMood(60)
		local equipped = pets:GetEquippedPet()
		if equipped and equipped.hunger < 30 then
			notify:Show("warning", "Pet is Hungry!", equipped.name .. " needs food!", 4)
		end
	end

	-- Weather check (every 300s — WeatherSystem.EnableRandomWeather handles
	-- the actual state change; this just gives it a manual update hook)
	weatherTimer += dt
	if weatherTimer >= 300 then
		weatherTimer = 0
		weather:Update(300)
	end

	-- Auto-save check (every 120s)
	saveTimer += dt
	if saveTimer >= 120 then
		saveTimer = 0
		save:FlushQueue()
		bus:Emit("AutoSaveTriggered", { chunksFlushed = 0 })
	end

	-- Leaderboard submit (every 60s)
	leaderboardTimer += dt
	if leaderboardTimer >= 60 then
		leaderboardTimer = 0
		local bucksBalance = currency:GetBalance("bucks")
		leaderboard:SubmitScore("richest_players", "player_local", "Player", bucksBalance)
	end

	-- LOD update ping (every 2s — LODSystem listens for this event)
	lodTimer += dt
	if lodTimer >= 2 then
		lodTimer = 0
		bus:Emit("LODUpdate", { timestamp = tick() })
	end

	-- Per-frame systems
	-- StatusEffectSystem self-ticks via its own internal Heartbeat (set up in .new())
	audio:Update(dt)
end)

-- Cleanup on script destroy
local function cleanup()
	heartbeatConnection:Disconnect()
	timer:Destroy()
	trade:Destroy()
	notify:DismissAll()
	weather:DisableRandomWeather()
	print("[AdoptMeDemo] Cleanup complete.")
end


-- =============================================================================
-- STARTUP
-- =============================================================================

bus:Emit("AdoptMeDemoInitialized", {
	moduleCount    = 33,
	petCount       = #PET_REGISTRY,
	vehicleCount   = #VEHICLE_REGISTRY,
	furnitureCount = #FURNITURE_CATALOG,
	version        = "2.0.0",
})

print("================================================================================")
print("  AdoptMeDemo.lua — INITIALIZED SUCCESSFULLY")
print("  33 modules wired via EventBus + Dependency Injection")
print("  " .. tostring(#PET_REGISTRY) .. " pets | " .. tostring(#VEHICLE_REGISTRY) .. " vehicles | " .. tostring(#FURNITURE_CATALOG) .. " furniture items")
print("  Map: hand-built in Roblox Studio")
print("  Terrain pipeline available in src/ for other projects")
print("================================================================================")

return {
	-- Core
	bus       = bus,
	config    = config,
	-- Game Mechanics
	inv       = inv,
	currency  = currency,
	xp        = xp,
	quests    = quests,
	skills    = skills,
	dialogue  = dialogue,
	ui        = ui,
	store     = store,
	notify    = notify,
	timer     = timer,
	statusFx  = statusFx,
	equip     = equip,
	craft     = craft,
	loot      = loot,
	combat    = combat,
	leaderboard = leaderboard,
	physics   = physics,
	-- Environment
	palette   = palette,
	styles    = styles,
	lod       = lod,
	atmos     = atmos,
	-- Extensions
	save        = save,
	pathfinding = pathfinding,
	weather     = weather,
	audio       = audio,
	-- Adopt Me Domain
	pets      = pets,
	homes     = homes,
	trade     = trade,
	vehicles  = vehicles,
	-- Game Data
	PET_REGISTRY      = PET_REGISTRY,
	VEHICLE_REGISTRY  = VEHICLE_REGISTRY,
	FURNITURE_CATALOG = FURNITURE_CATALOG,
	QUEST_DEFS        = QUEST_DEFS,
	-- Cleanup
	cleanup   = cleanup,
}
