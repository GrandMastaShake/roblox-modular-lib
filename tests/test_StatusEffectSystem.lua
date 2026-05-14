--!strict
-- tests/test_StatusEffectSystem.lua
-- Lightweight assert-based tests for StatusEffectSystem.

local EventBus = require(script.Parent.Parent.src.Core.EventBus)
local StatusEffectSystem = require(script.Parent.Parent.src.StatusEffectSystem)

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
	print("[test_StatusEffectSystem] Starting tests...")

	-- Test 1: RegisterEffect and Apply
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		effects:RegisterEffect({
			id = "burn",
			name = "Burn",
			category = "debuff",
			maxStacks = 3,
			duration = 5,
			tickInterval = nil,
			onApply = nil,
			onTick = nil,
			onRemove = nil,
		})

		local ok = effects:Apply("burn", "target1", "source1", 1)
		assertTrue(ok, "Apply should succeed")
		assertTrue(effects:HasEffect("target1", "burn"), "HasEffect should be true")
		assertEq(effects:GetEffectStacks("target1", "burn"), 1, "Stacks should be 1")
		print("  [PASS] RegisterEffect and Apply")
	end

	-- Test 2: EffectApplied event
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		effects:RegisterEffect({
			id = "freeze",
			name = "Freeze",
			category = "debuff",
			maxStacks = 1,
			duration = 3,
		})

		local fired = false
		bus:Subscribe("EffectApplied", function(payload: any)
			fired = true
			assertEq(payload.effectId, "freeze", "EffectApplied effectId")
			assertEq(payload.targetId, "hero", "EffectApplied targetId")
			assertEq(payload.stacks, 1, "EffectApplied stacks")
			assertEq(payload.sourceId, "ice_mage", "EffectApplied sourceId")
		end)

		effects:Apply("freeze", "hero", "ice_mage")
		assertTrue(fired, "EffectApplied event should fire")
		print("  [PASS] EffectApplied event")
	end

	-- Test 3: Stacking
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		effects:RegisterEffect({
			id = "poison",
			name = "Poison",
			category = "debuff",
			maxStacks = 3,
			duration = 5,
		})

		effects:Apply("poison", "victim", "snake", 1)
		effects:Apply("poison", "victim", "snake", 1)
		effects:Apply("poison", "victim", "snake", 1)

		assertEq(effects:GetEffectStacks("victim", "poison"), 3, "Stacks should be 3")
		print("  [PASS] Stacking")
	end

	-- Test 4: Stack cap and refresh
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		effects:RegisterEffect({
			id = "bleed",
			name = "Bleed",
			category = "debuff",
			maxStacks = 2,
			duration = 5,
		})

		effects:Apply("bleed", "victim", "boss", 2)
		assertEq(effects:GetEffectStacks("victim", "bleed"), 2, "Stacks should be at max (2)")

		effects:Apply("bleed", "victim", "boss", 1)
		assertEq(effects:GetEffectStacks("victim", "bleed"), 2, "Stacks should still be 2 (capped)")
		assertTrue(effects:HasEffect("victim", "bleed"), "Effect should still be active (refreshed)")
		print("  [PASS] Stack cap and refresh")
	end

	-- Test 5: EffectStacked event
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		effects:RegisterEffect({
			id = "strength",
			name = "Strength",
			category = "buff",
			maxStacks = 5,
			duration = 10,
		})

		local stackedFired = false
		bus:Subscribe("EffectStacked", function(payload: any)
			stackedFired = true
			assertEq(payload.effectId, "strength", "EffectStacked effectId")
			assertEq(payload.stacks, 2, "EffectStacked stacks")
		end)

		effects:Apply("strength", "hero", "potion")
		effects:Apply("strength", "hero", "potion")
		assertTrue(stackedFired, "EffectStacked should fire")
		print("  [PASS] EffectStacked event")
	end

	-- Test 6: Remove
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		effects:RegisterEffect({
			id = "slow",
			name = "Slow",
			category = "debuff",
			maxStacks = 1,
			duration = 10,
		})

		effects:Apply("slow", "hero", "trap")
		assertTrue(effects:HasEffect("hero", "slow"), "Should have slow effect")

		local removedFired = false
		bus:Subscribe("EffectRemoved", function(payload: any)
			removedFired = true
			assertEq(payload.effectId, "slow", "EffectRemoved effectId")
			assertEq(payload.targetId, "hero", "EffectRemoved targetId")
		end)

		effects:Remove("slow", "hero")
		assertFalse(effects:HasEffect("hero", "slow"), "Should not have slow effect after remove")
		assertTrue(removedFired, "EffectRemoved should fire")
		print("  [PASS] Remove")
	end

	-- Test 7: RemoveAllFromSource
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		effects:RegisterEffect({
			id = "curse1",
			name = "Curse of Weakness",
			category = "debuff",
			maxStacks = 1,
			duration = 10,
		})
		effects:RegisterEffect({
			id = "curse2",
			name = "Curse of Slowness",
			category = "debuff",
			maxStacks = 1,
			duration = 10,
		})

		effects:Apply("curse1", "hero", "warlock")
		effects:Apply("curse2", "hero", "warlock")
		effects:Apply("curse1", "hero", "other", 1)

		assertEq(effects:GetEffectStacks("hero", "curse1"), 1, "curse1 from warlock")

		effects:RemoveAllFromSource("warlock", "hero")

		assertFalse(effects:HasEffect("hero", "curse1"), "curse1 from warlock removed")
		assertFalse(effects:HasEffect("hero", "curse2"), "curse2 from warlock removed")
		print("  [PASS] RemoveAllFromSource")
	end

	-- Test 8: GetActiveEffects
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		effects:RegisterEffect({
			id = "regen",
			name = "Regeneration",
			category = "buff",
			maxStacks = 1,
			duration = 5,
		})
		effects:RegisterEffect({
			id = "haste",
			name = "Haste",
			category = "buff",
			maxStacks = 1,
			duration = 5,
		})

		effects:Apply("regen", "hero", "cleric")
		effects:Apply("haste", "hero", "mage")

		local active = effects:GetActiveEffects("hero")
		assertEq(#active, 2, "Should have 2 active effects")
		print("  [PASS] GetActiveEffects")
	end

	-- Test 9: HasEffect false for unknown target/effect
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		assertFalse(effects:HasEffect("nobody", "nothing"), "HasEffect for unknown should be false")
		assertEq(effects:GetEffectStacks("nobody", "nothing"), 0, "GetEffectStacks for unknown should be 0")
		print("  [PASS] HasEffect unknown")
	end

	-- Test 10: onApply callback
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		local callbackTarget: string? = nil
		local callbackStacks: number = 0

		effects:RegisterEffect({
			id = "shield",
			name = "Shield",
			category = "buff",
			maxStacks = 1,
			duration = 5,
			onApply = function(targetId: string, stacks: number)
				callbackTarget = targetId
				callbackStacks = stacks
			end,
		})

		effects:Apply("shield", "tank", "paladin")
		assertEq(callbackTarget, "tank", "onApply targetId")
		assertEq(callbackStacks, 1, "onApply stacks")
		print("  [PASS] onApply callback")
	end

	-- Test 11: onRemove callback
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		local removedTarget: string? = nil

		effects:RegisterEffect({
			id = "aura",
			name = "Aura",
			category = "buff",
			maxStacks = 1,
			duration = 5,
			onRemove = function(targetId: string, _stacks: number)
				removedTarget = targetId
			end,
		})

		effects:Apply("aura", "hero", "priest")
		effects:Remove("aura", "hero")
		assertEq(removedTarget, "hero", "onRemove targetId")
		print("  [PASS] onRemove callback")
	end

	-- Test 12: Apply to unknown effect returns false
	do
		local bus = EventBus.new()
		local effects = StatusEffectSystem.new(bus)
		local ok = effects:Apply("unknown", "hero", "source")
		assertFalse(ok, "Apply unknown effect should fail")
		print("  [PASS] Apply unknown effect fails")
	end

	print("[test_StatusEffectSystem] All tests passed!")
end

runTests()

return true
