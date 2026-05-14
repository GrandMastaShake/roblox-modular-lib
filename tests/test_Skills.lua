--!strict
-- test_Skills.lua
-- Lightweight tests for Skills module.

local Skills = require(script.Parent.Parent.src.Skills)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. " expected true")
	end
end

local function assertFalse(a: boolean, msg: string)
	if a then
		error(msg .. " expected false")
	end
end

local function createMockEventBus()
	local bus = {
		_events = {} :: { [string]: { any } },
		Subscribe = function(self: any, eventName: string, callback: (any) -> ()): () -> ()
			return function() end
		end,
		Emit = function(self: any, eventName: string, payload: any)
			if not self._events[eventName] then
				self._events[eventName] = {}
			end
			table.insert(self._events[eventName], payload)
		end,
	}
	return bus
end

-- Test 1: RegisterSkill and instant Cast
print("TEST: RegisterSkill and instant Cast")
do
	local bus = createMockEventBus()
	local skills = Skills.new(bus)
	local effectCalled = false
	local effectTarget = nil

	local function effect(target: any)
		effectCalled = true
		effectTarget = target
	end

	skills:RegisterSkill({ id = "heal", name = "Heal", cooldown = 1, castTime = 0, effect = effect })

	local ok = skills:Cast("heal", "player1")
	assertTrue(ok, "Cast should succeed")
	assertTrue(effectCalled, "Effect should be called for instant cast")
	assertEq(effectTarget, "player1", "Effect target")

	local startedEvents = bus._events["CastStarted"] or {}
	local succeededEvents = bus._events["CastSucceeded"] or {}
	assertEq(#startedEvents, 1, "CastStarted events")
	assertEq(#succeededEvents, 1, "CastSucceeded events")
	if startedEvents[1] then
		assertEq(startedEvents[1].skillId, "heal", "CastStarted skillId")
	end
	if succeededEvents[1] then
		assertEq(succeededEvents[1].skillId, "heal", "CastSucceeded skillId")
	end
end

-- Test 2: Cooldown blocking
print("TEST: Cooldown blocking")
do
	local bus = createMockEventBus()
	local skills = Skills.new(bus)
	local effectCount = 0

	local function effect()
		effectCount += 1
	end

	skills:RegisterSkill({ id = "slash", name = "Slash", cooldown = 1, castTime = 0, effect = effect })

	local ok1 = skills:Cast("slash")
	assertTrue(ok1, "First cast should succeed")
	assertEq(effectCount, 1, "Effect count after first cast")

	local ok2 = skills:Cast("slash")
	assertFalse(ok2, "Second cast should fail (cooldown)")
	assertEq(effectCount, 1, "Effect count should not increase")

	assertTrue(skills:IsOnCooldown("slash"), "IsOnCooldown should be true")
	assertTrue(skills:GetCooldownRemaining("slash") > 0, "CooldownRemaining should be > 0")
end

-- Test 3: Cast while already casting
print("TEST: Cast while already casting")
do
	local bus = createMockEventBus()
	local skills = Skills.new(bus)

	local function effect() end
	skills:RegisterSkill({ id = "fireball", name = "Fireball", cooldown = 1, castTime = 0.5, effect = effect })

	local ok1 = skills:Cast("fireball")
	assertTrue(ok1, "First cast should succeed")

	local ok2 = skills:Cast("fireball")
	assertFalse(ok2, "Second cast should fail (already casting)")
end

-- Test 4: InterruptCast
print("TEST: InterruptCast")
do
	local bus = createMockEventBus()
	local skills = Skills.new(bus)
	local effectCalled = false

	local function effect()
		effectCalled = true
	end

	skills:RegisterSkill({ id = "channel", name = "Channel", cooldown = 1, castTime = 0.5, effect = effect })

	local ok = skills:Cast("channel")
	assertTrue(ok, "Cast should succeed")

	skills:InterruptCast()

	local failedEvents = bus._events["CastFailed"] or {}
	assertEq(#failedEvents, 1, "CastFailed events")
	if failedEvents[1] then
		assertEq(failedEvents[1].skillId, "channel", "CastFailed skillId")
		assertEq(failedEvents[1].reason, "interrupted", "CastFailed reason")
	end

	-- Wait to ensure delayed completion does not fire
	task.wait(0.6)
	assertFalse(effectCalled, "Effect should not be called after interrupt")
end

-- Test 5: Delayed cast succeeds
print("TEST: Delayed cast succeeds")
do
	local bus = createMockEventBus()
	local skills = Skills.new(bus)
	local effectCalled = false

	local function effect()
		effectCalled = true
	end

	skills:RegisterSkill({ id = "bolt", name = "Lightning Bolt", cooldown = 1, castTime = 0.2, effect = effect })

	local ok = skills:Cast("bolt")
	assertTrue(ok, "Cast should succeed immediately")
	assertFalse(effectCalled, "Effect should not be called immediately")

	task.wait(0.3)
	assertTrue(effectCalled, "Effect should be called after castTime")

	local succeededEvents = bus._events["CastSucceeded"] or {}
	assertEq(#succeededEvents, 1, "CastSucceeded events")
	if succeededEvents[1] then
		assertEq(succeededEvents[1].skillId, "bolt", "CastSucceeded skillId")
	end
end

-- Test 6: Constructor with skillDefs
print("TEST: Constructor with skillDefs")
do
	local bus = createMockEventBus()
	local function effect() end
	local defs = {
		{ id = "a", name = "A", cooldown = 0, castTime = 0, effect = effect },
		{ id = "b", name = "B", cooldown = 0, castTime = 0, effect = effect },
	}
	local skills = Skills.new(bus, defs)

	local ok1 = skills:Cast("a")
	local ok2 = skills:Cast("b")
	assertTrue(ok1, "Cast 'a' should succeed")
	assertTrue(ok2, "Cast 'b' should succeed")
end

-- Test 7: GetCooldownRemaining after cooldown ends
print("TEST: GetCooldownRemaining after cooldown ends")
do
	local bus = createMockEventBus()
	local skills = Skills.new(bus)
	local function effect() end
	skills:RegisterSkill({ id = "quick", name = "Quick", cooldown = 0.1, castTime = 0, effect = effect })

	skills:Cast("quick")
	assertTrue(skills:IsOnCooldown("quick"), "Should be on cooldown")
	task.wait(0.15)
	assertFalse(skills:IsOnCooldown("quick"), "Should not be on cooldown after delay")
	assertEq(skills:GetCooldownRemaining("quick"), 0, "CooldownRemaining should be 0")
end

print("All Skills tests passed.")

return true
