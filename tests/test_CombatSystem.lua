--!strict
-- tests/test_CombatSystem.lua
-- Lightweight assert-based tests for CombatSystem.

local EventBus = require(script.Parent.Parent.src.Core.EventBus)
local Config = require(script.Parent.Parent.src.Core.Config)
local CombatSystem = require(script.Parent.Parent.src.CombatSystem)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. ": expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. ": expected true")
	end
end

local function assertFalse(a: boolean, msg: string)
	if a then
		error(msg .. ": expected false")
	end
end

local function runTests()
	print("[test_CombatSystem] Starting tests...")

	-- Test 1: RegisterEntity and GetStats
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		combat:RegisterEntity("hero", {
			maxHealth = 100,
			currentHealth = 100,
			attack = 10,
			defense = 5,
			critChance = 0.25,
			critMultiplier = 2,
		})

		local stats = combat:GetStats("hero")
		assertTrue(stats ~= nil, "GetStats should return stats")
		if stats then
			assertEq(stats.maxHealth, 100, "GetStats maxHealth")
			assertEq(stats.currentHealth, 100, "GetStats currentHealth")
			assertEq(stats.attack, 10, "GetStats attack")
			assertEq(stats.defense, 5, "GetStats defense")
		end
		print("  [PASS] RegisterEntity and GetStats")
	end

	-- Test 2: DealDamage basic
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		combat:RegisterEntity("attacker", {
			maxHealth = 100, currentHealth = 100,
			attack = 10, defense = 0,
			critChance = 0, critMultiplier = 2,
		})
		combat:RegisterEntity("target", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 5,
			critChance = 0, critMultiplier = 2,
		})

		local result = combat:DealDamage("attacker", "target", 10)
		assertEq(result.rawDamage, 15, "DealDamage rawDamage = base + attack - defense = 10 + 10 - 5")
		assertEq(result.isCrit, false, "DealDamage isCrit")
		assertTrue(result.isAlive, "DealDamage target isAlive")

		local targetStats = combat:GetStats("target")
		assertTrue(targetStats ~= nil, "GetStats target")
		if targetStats then
			assertEq(targetStats.currentHealth, 85, "Target health after damage")
		end
		print("  [PASS] DealDamage basic")
	end

	-- Test 3: DamageDealt event
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		combat:RegisterEntity("a", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})
		combat:RegisterEntity("b", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})

		local eventFired = false
		bus:Subscribe("DamageDealt", function(payload: any)
			eventFired = true
			assertEq(payload.attackerId, "a", "DamageDealt attackerId")
			assertEq(payload.targetId, "b", "DamageDealt targetId")
			assertEq(payload.finalDamage, 5, "DamageDealt finalDamage")
		end)

		combat:DealDamage("a", "b", 5)
		assertTrue(eventFired, "DamageDealt event should fire")
		print("  [PASS] DamageDealt event")
	end

	-- Test 4: Heal and EntityHealed event
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		combat:RegisterEntity("hero", {
			maxHealth = 100, currentHealth = 50,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})

		local healedEvent = false
		bus:Subscribe("EntityHealed", function(payload: any)
			healedEvent = true
			assertEq(payload.entityId, "hero", "EntityHealed entityId")
			assertEq(payload.amount, 20, "EntityHealed amount")
			assertEq(payload.currentHealth, 70, "EntityHealed currentHealth")
		end)

		combat:Heal("hero", 20)
		assertTrue(healedEvent, "EntityHealed event should fire")

		local stats = combat:GetStats("hero")
		assertTrue(stats ~= nil, "GetStats hero")
		if stats then
			assertEq(stats.currentHealth, 70, "Health after heal")
		end
		print("  [PASS] Heal and EntityHealed event")
	end

	-- Test 5: Heal clamped to maxHealth
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		combat:RegisterEntity("hero", {
			maxHealth = 100, currentHealth = 90,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})

		combat:Heal("hero", 20)
		local stats = combat:GetStats("hero")
		assertTrue(stats ~= nil, "GetStats hero")
		if stats then
			assertEq(stats.currentHealth, 100, "Health should be clamped to maxHealth")
		end
		print("  [PASS] Heal clamped to maxHealth")
	end

	-- Test 6: EntityDied event
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		combat:RegisterEntity("villain", {
			maxHealth = 20, currentHealth = 20,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})
		combat:RegisterEntity("killer", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})

		local diedEvent = false
		bus:Subscribe("EntityDied", function(payload: any)
			diedEvent = true
			assertEq(payload.entityId, "villain", "EntityDied entityId")
			assertEq(payload.killerId, "killer", "EntityDied killerId")
		end)

		local result = combat:DealDamage("killer", "villain", 25)
		assertFalse(result.isAlive, "Target should be dead")
		assertTrue(diedEvent, "EntityDied event should fire")
		assertFalse(combat:IsAlive("villain"), "IsAlive should return false")
		print("  [PASS] EntityDied event")
	end

	-- Test 7: IsAlive for unknown entity
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		assertFalse(combat:IsAlive("nobody"), "IsAlive for unknown entity")
		print("  [PASS] IsAlive unknown entity")
	end

	-- Test 8: Damage formula floor of 1
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		combat:RegisterEntity("weak", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 100,
			critChance = 0, critMultiplier = 2,
		})
		combat:RegisterEntity("target2", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 100,
			critChance = 0, critMultiplier = 2,
		})

		local result = combat:DealDamage("weak", "target2", 0)
		assertEq(result.finalDamage, 1, "Damage should be at least 1")
		print("  [PASS] Damage floor of 1")
	end

	-- Test 9: GetEntitiesInRange / SetHitbox
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		combat:RegisterEntity("e1", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})
		combat:RegisterEntity("e2", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})

		local part1 = Instance.new("Part")
		part1.Position = Vector3.new(0, 0, 0)
		local part2 = Instance.new("Part")
		part2.Position = Vector3.new(5, 0, 0)

		combat:SetHitbox("e1", part1)
		combat:SetHitbox("e2", part2)

		local inRange = combat:GetEntitiesInRange(Vector3.new(0, 0, 0), 3)
		assertEq(#inRange, 1, "Only e1 should be in range")
		assertEq(inRange[1], "e1", "e1 should be in range")

		local inRange2 = combat:GetEntitiesInRange(Vector3.new(0, 0, 0), 10)
		assertEq(#inRange2, 2, "Both entities should be in range")

		part1:Destroy()
		part2:Destroy()
		print("  [PASS] SetHitbox and GetEntitiesInRange")
	end

	-- Test 10: ApplyDamageInRadius
	do
		local bus = EventBus.new()
		local combat = CombatSystem.new(bus, Config.new())
		combat:RegisterEntity("center", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})
		combat:RegisterEntity("nearby", {
			maxHealth = 100, currentHealth = 100,
			attack = 0, defense = 0,
			critChance = 0, critMultiplier = 2,
		})

		local partCenter = Instance.new("Part")
		partCenter.Position = Vector3.new(0, 0, 0)
		local partNearby = Instance.new("Part")
		partNearby.Position = Vector3.new(3, 0, 0)

		combat:SetHitbox("center", partCenter)
		combat:SetHitbox("nearby", partNearby)

		local results = combat:ApplyDamageInRadius(Vector3.new(0, 0, 0), 5, 10, "center")
		assertEq(#results, 1, "Only nearby should be damaged (center excluded)")
		assertEq(results[1].isAlive, true, "Nearby should survive")

		local nearbyStats = combat:GetStats("nearby")
		assertTrue(nearbyStats ~= nil, "GetStats nearby")
		if nearbyStats then
			assertEq(nearbyStats.currentHealth, 90, "Nearby took 10 damage")
		end

		partCenter:Destroy()
		partNearby:Destroy()
		print("  [PASS] ApplyDamageInRadius")
	end

	print("[test_CombatSystem] All tests passed!")
end

runTests()

return true
