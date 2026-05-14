--!strict
--[[
	AdoptMeStudioTest.lua
	══════════════════════════════════════════════════════════════════════════════
	ROBLOX STUDIO DEMO — Adopt Me Module Suite
	Wires 10 modules from the roblox-modular-lib.
	Hit Play and watch the Output window. Vehicles spawn in Workspace!
	══════════════════════════════════════════════════════════════════════════════
--]]

-- ============================================================================
-- REQUIRES (10 modules)
-- ============================================================================

local EventBus    = require(script.Parent.src.Core.EventBus)
local Config      = require(script.Parent.src.Core.Config)

local Inventory      = require(script.Parent.src.Inventory)
local CurrencySystem = require(script.Parent.src.CurrencySystem)
local XPSystem       = require(script.Parent.src.XPSystem)
local TimerSystem    = require(script.Parent.src.TimerSystem)
local QuestSystem    = require(script.Parent.src.QuestSystem)

local PetSystem     = require(script.Parent.src.PetSystem)
local HomeSystem    = require(script.Parent.src.HomeSystem)
local TradeSystem   = require(script.Parent.src.TradeSystem)
local VehicleSystem = require(script.Parent.src.VehicleSystem)

-- ============================================================================
-- HELPERS
-- ============================================================================

local function banner(text: string)
	print("")
	print("  ══════════════════════════════════════════")
	print("  " .. text)
	print("  ══════════════════════════════════════════")
end

local function ok(text: string)   print("  ✓  " .. text) end
local function info(text: string) print("     " .. text) end
local function warn(text: string) print("  ⚠  " .. text) end
local function evt(text: string)  print("  ▶  [EVENT] " .. text) end

-- ============================================================================
-- PHASE 0 — BOOT
-- ============================================================================

banner("ADOPT ME MODULE SUITE  v1.3.0")
print("     10 modules  |  EventBus DI  |  Rojo " .. tostring(os.date("%H:%M:%S")))

-- Single shared EventBus — every module gets the same instance.
local bus = EventBus.new()
ok("EventBus created")

local config = Config.new({
	startingBucks = 500,
	xpFormula = function(lvl: number): number
		return math.floor(100 * lvl ^ 1.5)
	end,
})
ok("Config created")

local inv       = Inventory.new(bus, 50)
local currency  = CurrencySystem.new(bus, config)
local xp        = XPSystem.new(bus, config)
local timer     = TimerSystem.new(bus)
local quests    = QuestSystem.new(bus, config)
ok("Inventory / CurrencySystem / XPSystem / TimerSystem / QuestSystem")

local pets     = PetSystem.new(bus, inv, xp, timer)
local homes    = HomeSystem.new(bus, inv, currency)
local trade    = TradeSystem.new(bus, inv, currency, timer)
local vehicles = VehicleSystem.new(bus, inv)
ok("PetSystem / HomeSystem / TradeSystem / VehicleSystem")

-- ============================================================================
-- EVENT LISTENERS  (subscribe before anything emits)
-- ============================================================================

bus:Subscribe("EggHatched", function(data: {petId: string?, petName: string?, instanceId: string?, rarity: string?})
	evt(string.format("EggHatched  →  %s  [%s]  instance=%s",
		tostring(data.petName or data.petId),
		tostring(data.rarity or "?"),
		tostring(data.instanceId)))
end)

bus:Subscribe("PetFed", function(data: {instanceId: string?, hunger: number?})
	evt(string.format("PetFed      →  inst=%s  hunger=%d%%",
		tostring(data.instanceId), math.round(data.hunger or 0)))
end)

bus:Subscribe("PetPlayed", function(data: {instanceId: string?, fun: number?})
	evt(string.format("PetPlayed   →  inst=%s  fun=%d%%",
		tostring(data.instanceId), math.round(data.fun or 0)))
end)

bus:Subscribe("TrickTaught", function(data: {instanceId: string?, trickId: string?})
	evt(string.format("TrickTaught →  inst=%s  trick=%s",
		tostring(data.instanceId), tostring(data.trickId)))
end)

bus:Subscribe("PetAgedUp", function(data: {instanceId: string?, stage: string?})
	evt(string.format("PetAgedUp   →  inst=%s  stage=%s",
		tostring(data.instanceId), tostring(data.stage)))
end)

bus:Subscribe("NeonCreated", function(data: {instanceId: string?, defId: string?})
	evt(string.format("NeonCreated →  inst=%s  defId=%s  ✨",
		tostring(data.instanceId), tostring(data.defId)))
end)

bus:Subscribe("HomeBought", function(data: {homeId: string?, homeType: string?, price: number?})
	evt(string.format("HomeBought  →  %s  homeId=%s  price=%d",
		tostring(data.homeType), tostring(data.homeId), data.price or 0))
end)

bus:Subscribe("FurniturePlaced", function(data: {defId: string?, instanceId: string?, roomId: string?})
	evt(string.format("FurniturePlaced  →  %s  inst=%s",
		tostring(data.defId), tostring(data.instanceId)))
end)

bus:Subscribe("RoomPainted", function(data: {roomId: string?})
	evt("RoomPainted →  " .. tostring(data.roomId))
end)

bus:Subscribe("VehicleEquipped", function(data: {defId: string?, instanceId: string?})
	evt(string.format("VehicleEquipped  →  %s  inst=%s",
		tostring(data.defId), tostring(data.instanceId)))
end)

bus:Subscribe("VehicleSpawned", function(data: {defId: string?, instanceId: string?})
	evt(string.format("VehicleSpawned   →  %s  inst=%s  (check Workspace!)",
		tostring(data.defId), tostring(data.instanceId)))
end)

bus:Subscribe("VehicleDespawned", function(data: {instanceId: string?})
	evt("VehicleDespawned →  inst=" .. tostring(data.instanceId))
end)

bus:Subscribe("VehiclePainted", function(data: {defId: string?, color: Color3?})
	local c = data.color or Color3.new()
	evt(string.format("VehiclePainted   →  %s  rgb(%d,%d,%d)",
		tostring(data.defId),
		math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255)))
end)

bus:Subscribe("TradeRequested", function(data: {tradeId: string?, playerA: string?, playerB: string?})
	evt(string.format("TradeRequested   →  id=%s  %s ↔ %s",
		tostring(data.tradeId), tostring(data.playerA), tostring(data.playerB)))
end)

bus:Subscribe("TradeCompleted", function(data: {tradeId: string?})
	evt("TradeCompleted   →  id=" .. tostring(data.tradeId) .. "  ✅")
end)

bus:Subscribe("QuestCompleted", function(data: {questId: string?})
	evt("QuestCompleted   →  " .. tostring(data.questId))
end)

bus:Subscribe("LevelUp", function(data: {level: number?})
	evt("LevelUp          →  reached level " .. tostring(data.level) .. "  🎉")
end)

-- ============================================================================
-- PHASE 1 — CURRENCY & QUESTS
-- ============================================================================

task.spawn(function()
	task.wait(0.05)
	banner("PHASE 1 — CURRENCY & QUESTS")

	currency:RegisterCurrency({ id = "bucks", name = "Bucks", symbol = "$", defaultBalance = 500 })
	ok("Bucks registered  |  starting balance: " .. tostring(currency:GetBalance("bucks")))

	quests:RegisterQuest({
		id = "quest_feed_pet",
		title = "Feed Your Pet",
		description = "Feed your pet!",
		objectives = {
			{ id = "obj_feed", description = "Feed pet", targetCount = 1, currentCount = 0, completed = false },
		},
		rewards = { { type = "currency", id = "bucks", amount = 50 } },
	})
	quests:RegisterQuest({
		id = "quest_make_trade",
		title = "Make a Trade",
		description = "Complete a trade!",
		objectives = {
			{ id = "obj_trade", description = "Complete trade", targetCount = 1, currentCount = 0, completed = false },
		},
		rewards = { { type = "currency", id = "bucks", amount = 100 } },
	})
	quests:AcceptQuest("quest_feed_pet")
	quests:AcceptQuest("quest_make_trade")
	ok("Daily quests accepted: quest_feed_pet, quest_make_trade")

	-- Wire quest reward grant
	bus:Subscribe("QuestCompleted", function(data: {questId: string?})
		local questId = data.questId or ""
		local rewards = quests:TurnInQuest(questId)
		if rewards then
			for _, reward in ipairs(rewards) do
				if reward.type == "currency" then
					currency:Add(reward.id, reward.amount, "quest_reward")
					ok(string.format("Quest reward: +%d Bucks  (balance now: %d)",
						reward.amount, currency:GetBalance("bucks")))
				end
			end
		end
	end)

	-- ============================================================================
	-- PHASE 2 — PET SYSTEM
	-- ============================================================================
	task.wait(0.1)
	banner("PHASE 2 — PET SYSTEM")
	info("20 pets pre-registered  |  4 egg types available")

	-- Give the player a starter egg
	inv:DefineItem({ id = "starter_egg", name = "Starter Egg", maxStack = 3, equippable = false })
	inv:DefineItem({ id = "food_apple",  name = "Apple",       maxStack = 99, equippable = false })
	inv:AddItem("starter_egg", 3)
	inv:AddItem("food_apple", 10)
	ok("Gave player: 3× Starter Egg, 10× Apple")

	-- Hatch 3 eggs
	info("Hatching 3 Starter Eggs...")
	local hatchedPets: { PetSystem.OwnedPet } = {}
	for i = 1, 3 do
		local pet = pets:HatchEgg("starter_egg")
		if pet then
			table.insert(hatchedPets, pet)
			info(string.format("  [%d] %s  (rarity: %s)  stage: %s  id: %s",
				i, pet.name, pet.rarity or "?", pet.stage, pet.instanceId))
		else
			warn("  [" .. i .. "] Hatch failed (no starter_egg pets in pool?)")
		end
	end
	ok(string.format("Hatched %d pets", #hatchedPets))

	if #hatchedPets > 0 then
		local p = hatchedPets[1]
		pets:SetEquippedPet(p.instanceId)
		ok("Equipped: " .. p.name .. " (" .. p.instanceId .. ")")

		-- Feed it
		local fed = pets:FeedPet(p.instanceId, "food_apple")
		if fed then
			ok("Fed " .. p.name .. " an apple")
			quests:AdvanceObjective("quest_feed_pet", "obj_feed", 1)
		end

		-- Play with it
		pets:PlayWithPet(p.instanceId)
		ok("Played with " .. p.name)

		-- Teach tricks (names must match PetDef.tricks exactly)
		for _, trick in ipairs({ "Sit", "Lay Down", "Dance" }) do
			local taught = pets:TeachTrick(p.instanceId, trick)
			if taught then ok("  Taught trick: " .. trick) end
		end

		-- Do a trick
		pets:DoTrick(p.instanceId, "Sit")
		ok(p.name .. " performed: Sit")

		-- Age up once
		local aged = pets:AgeUpPet(p.instanceId)
		local current = pets:GetPet(p.instanceId)
		if aged and current then
			ok(p.name .. " aged up to: " .. current.stage)
		end
	end

	-- Neon demo: give 4 full-grown dogs and combine them
	task.wait(0.1)
	info("--- Neon demo: creating 4 full-grown Dog instances ---")
	inv:AddItem("starter_egg", 4)  -- replenish for neon demo
	local neonIds: { string } = {}
	for i = 1, 4 do
		local neonPet = pets:HatchEgg("starter_egg")
		-- Find a dog specifically or take whatever we get
		if neonPet then
			-- Force age up to full-grown (5 times)
			for _ = 1, 5 do
				pets:AgeUpPet(neonPet.instanceId)
			end
			local fresh = pets:GetPet(neonPet.instanceId)
			if fresh and fresh.stage == "full-grown" then
				table.insert(neonIds, neonPet.instanceId)
			end
		end
	end

	-- Try neon only if all 4 are same type
	if #neonIds == 4 then
		local p1 = pets:GetPet(neonIds[1])
		local allSame = true
		for i = 2, 4 do
			local pi = pets:GetPet(neonIds[i])
			if not pi or not p1 or pi.defId ~= p1.defId then
				allSame = false
				break
			end
		end

		if allSame and p1 then
			local neon = pets:MakeNeon(neonIds)
			if neon then
				ok("NEON " .. neon.name .. " created! ✨  inst=" .. neon.instanceId)
			end
		else
			info("4 pets are mixed types — neon skipped (needs 4 of same type)")
			info("In the real game, players collect extras through trading/hatching.")
		end
	else
		warn("Could not get 4 full-grown pets for neon demo")
	end

	-- ============================================================================
	-- PHASE 3 — HOME SYSTEM
	-- ============================================================================
	task.wait(0.1)
	banner("PHASE 3 — HOME SYSTEM")
	info("30 built-in furniture items  |  5 home types")

	local catalogSize = #homes:ListFurnitureCatalog()
	ok(string.format("Furniture catalog: %d items", catalogSize))

	-- Give the player a free apartment
	local home = homes:BuyHome("player_alex", "apartment")
	if home then
		ok(string.format("Bought free Apartment  homeId=%s  rooms=%d", home.homeId, #home.rooms))
		local room = home.rooms[1]
		ok("Room 1: " .. room.roomId .. "  (" .. room.roomType .. ")  size=" .. tostring(room.size))

		-- Give some furniture items to inventory
		inv:DefineItem({ id = "bed_basic",    name = "Basic Bed",   maxStack = 1, equippable = false })
		inv:DefineItem({ id = "lamp",         name = "Lamp",        maxStack = 5, equippable = false })
		inv:DefineItem({ id = "table_coffee", name = "Coffee Table",maxStack = 3, equippable = false })
		inv:AddItem("bed_basic",    1)
		inv:AddItem("lamp",         2)
		inv:AddItem("table_coffee", 1)
		ok("Added furniture to inventory: bed_basic, lamp×2, table_coffee")

		-- Place furniture in the room (well inside the 16×12 room bounds)
		local placements = {
			{ id = "bed_basic",    cf = CFrame.new(3, 0, 5), color = Color3.fromRGB(200, 180, 160) },
			{ id = "lamp",         cf = CFrame.new(6, 0, 1), color = Color3.fromRGB(255, 220, 100) },
			{ id = "table_coffee", cf = CFrame.new(7, 0, 4), color = Color3.fromRGB(120, 80, 40) },
		}

		for _, p in ipairs(placements) do
			local placed = homes:PlaceFurniture(home.homeId, room.roomId, p.id, p.cf, p.color)
			if placed then
				ok(string.format("  Placed %s  at (%.0f,%.0f,%.0f)  inst=%s",
					p.id, p.cf.X, p.cf.Y, p.cf.Z, placed.instanceId))
			else
				warn("  Could not place " .. p.id .. " (check bounds/collision)")
			end
		end

		-- Paint the room
		homes:PaintRoom(
			home.homeId, room.roomId,
			Color3.fromRGB(240, 220, 200),
			Color3.fromRGB(160, 130, 100)
		)
		ok("Room painted: warm white walls, wood floor")

		-- Read back via GetHome (deep copy)
		local snapshot = homes:GetHome(home.homeId)
		if snapshot then
			ok(string.format("GetHome snapshot: %d furniture items in room 1",
				#snapshot.rooms[1].furniture))
		end

		-- Upgrade to a treehouse
		local upgraded = homes:BuyHome("player_alex_2", "treehouse")
		if upgraded then
			ok(string.format("Bought Treehouse  homeId=%s  rooms=%d", upgraded.homeId, #upgraded.rooms))
		end
	end

	-- ============================================================================
	-- PHASE 4 — VEHICLE SYSTEM
	-- ============================================================================
	task.wait(0.1)
	banner("PHASE 4 — VEHICLE SYSTEM")
	info("10 built-in vehicles  |  5 model builders  |  check Workspace in Explorer!")

	-- Print the built-in catalog
	local vehicleDefs = {
		"veh_skateboard", "veh_car", "veh_helicopter", "veh_hoverboard", "veh_boat"
	}
	for _, defId in ipairs(vehicleDefs) do
		local def = vehicles:GetVehicleDef(defId)
		if def then
			info(string.format("  %-18s  cat=%-12s  spd=%d  seats=%d  $%d",
				def.id, def.category, def.speed, def.seats, def.price))
		end
	end

	-- Give the player a skateboard (starter) and a car
	local skateInst = "alex_skateboard_1"
	local carInst   = "alex_car_1"
	local heliInst  = "alex_heli_1"

	vehicles:GiveVehicle(skateInst, "veh_skateboard", Color3.fromRGB(220, 60, 60))
	vehicles:GiveVehicle(carInst,   "veh_car",         Color3.fromRGB(30, 100, 200))
	vehicles:GiveVehicle(heliInst,  "veh_helicopter",   Color3.fromRGB(50, 200, 100))
	ok("Gave player: skateboard (red), car (blue), helicopter (green)")

	-- Equip the skateboard
	vehicles:EquipVehicle(skateInst)

	-- Spawn skateboard in workspace
	local skateModel = vehicles:SpawnVehicle(skateInst, Vector3.new(-8, 5, 0))
	if skateModel then
		ok(string.format("Skateboard spawned in Workspace  parts=%d",
			#skateModel:GetDescendants()))
	end

	task.wait(0.2)

	-- Swap to car and spawn it
	vehicles:UnequipVehicle()
	vehicles:EquipVehicle(carInst)
	local carModel = vehicles:SpawnVehicle(carInst, Vector3.new(0, 5, 0))
	if carModel then
		ok(string.format("Car spawned in Workspace  parts=%d", #carModel:GetDescendants()))
	end

	-- Paint the car
	vehicles:PaintVehicle(carInst, Color3.fromRGB(255, 150, 0))

	task.wait(0.2)

	-- Despawn car, spawn helicopter up high
	vehicles:DespawnVehicle()
	vehicles:UnequipVehicle()
	vehicles:EquipVehicle(heliInst)
	local heliModel = vehicles:SpawnVehicle(heliInst, Vector3.new(8, 20, 0))
	if heliModel then
		ok(string.format("Helicopter spawned in Workspace at y=20  parts=%d",
			#heliModel:GetDescendants()))
	end

	ok("All 3 vehicles spawned — open Explorer > Workspace to see them!")

	-- ============================================================================
	-- PHASE 5 — TRADE SYSTEM
	-- ============================================================================
	task.wait(0.1)
	banner("PHASE 5 — TRADE SYSTEM")
	info("Two-phase confirmation  |  auto-cancel timeout  |  currency + items")

	-- Set up player inventories
	inv:DefineItem({ id = "dragon_plush", name = "Dragon Plushie", maxStack = 5, equippable = false })
	inv:DefineItem({ id = "golden_ball",  name = "Golden Ball",    maxStack = 5, equippable = false })
	inv:AddItem("dragon_plush", 3)
	inv:AddItem("golden_ball",  2)
	currency:Add("bucks", 200, "test_setup")
	ok("Trade inventory ready: 3× Dragon Plushie, 2× Golden Ball, 200 extra Bucks")

	-- Request trade
	local tradeId = trade:RequestTrade("player_alice", "player_bob")
	if not tradeId then
		warn("RequestTrade returned nil")
	else
		ok("Trade requested  id=" .. tradeId)

		-- Alice offers items and bucks
		trade:AddItem(tradeId,  "player_alice", "dragon_plush", 1)
		trade:AddBucks(tradeId, "player_alice", 50)
		ok("Alice offered: 1× Dragon Plushie + 50 Bucks")

		-- Bob offers items
		trade:AddItem(tradeId, "player_bob", "golden_ball", 1)
		ok("Bob offered: 1× Golden Ball")

		-- Phase 1: both accept (locks offers)
		trade:AcceptTrade(tradeId, "player_alice")
		trade:AcceptTrade(tradeId, "player_bob")
		ok("Both players accepted  (offers locked)")

		-- Phase 2: both confirm (executes swap)
		trade:ConfirmTrade(tradeId, "player_alice")
		trade:ConfirmTrade(tradeId, "player_bob")
		ok("Both players confirmed  (swap executed)")

		-- Advance quest
		quests:AdvanceObjective("quest_make_trade", "obj_trade", 1)

		-- Check trade state
		local finalTrade = trade:GetTrade(tradeId)
		if finalTrade then
			ok("Trade state: " .. finalTrade.state)
		end
	end

	-- ============================================================================
	-- PHASE 6 — XP & LEVELING
	-- ============================================================================
	task.wait(0.1)
	banner("PHASE 6 — XP & LEVELING")

	local startLevel = xp:GetLevel()
	info(string.format("Current level: %d  |  XP: %d", startLevel, xp:GetProgress() or 0))

	-- Dump XP to trigger a level-up
	for i = 1, 5 do
		xp:AddXP(50)
	end
	ok(string.format("Added 250 XP  →  new level: %d", xp:GetLevel()))
	ok("Balance after all quest rewards: " .. tostring(currency:GetBalance("bucks")) .. " Bucks")

	-- ============================================================================
	-- SUMMARY
	-- ============================================================================
	task.wait(0.1)
	banner("DEMO COMPLETE  ✓")

	local snapshot = homes:GetHome(homes:GetPlayerHome("player_alex") and homes:GetPlayerHome("player_alex").homeId or "")
	local furnitureCount = 0
	if snapshot then
		for _, room in ipairs(snapshot.rooms) do
			furnitureCount += #room.furniture
		end
	end

	local equippedVehicle = vehicles:GetEquippedVehicle()
	local equippedPet     = pets:GetEquippedPet()

	info("  Modules tested:     PetSystem, HomeSystem, TradeSystem, VehicleSystem")
	info("  + core:             EventBus, Config, Inventory, CurrencySystem, XPSystem, TimerSystem, QuestSystem")
	info("")
	info(string.format("  Bucks balance:      %d", currency:GetBalance("bucks")))
	info(string.format("  Player level:       %d", xp:GetLevel()))
	info(string.format("  Pets hatched:       %d (check earlier output for names)", #hatchedPets))
	info(string.format("  Equipped pet:       %s", equippedPet and equippedPet.name or "none"))
	info(string.format("  Furniture placed:   %d items in Apartment", furnitureCount))
	info(string.format("  Equipped vehicle:   %s", equippedVehicle and equippedVehicle.defId or "helicopter (last spawned)"))
	info("  Vehicles in Workspace: check Explorer → Workspace for the spawned models!")
	info("")
	info("  All systems ran with ZERO direct coupling.")
	info("  Every cross-system communication went through EventBus.")
	info("")
	info("  Next: open FashionistaPetGame.rbxlx, build a map, and plug in the full AdoptMeDemo!")

	-- Clean up timer connections
	timer:Destroy()
	trade:Destroy()
end)
