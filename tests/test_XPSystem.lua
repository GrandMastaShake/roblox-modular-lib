--!strict
-- tests/test_XPSystem.lua
-- Lightweight assert-based tests for XPSystem.

local EventBus = require(script.Parent.Parent.src.Core.EventBus)
local Config = require(script.Parent.Parent.src.Core.Config)
local XPSystem = require(script.Parent.Parent.src.XPSystem)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertNear(a: number, b: number, epsilon: number, msg: string)
	if math.abs(a - b) > epsilon then
		error(msg .. " expected near " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function runTests()
	print("[test_XPSystem] Starting tests...")

	-- Test 1: Constructor
	local bus = EventBus.new()
	local config = Config.new()
	local xp = XPSystem.new(bus, config)
	assertEq(xp:GetLevel(), 1, "Constructor: initial level")
	assertEq(xp:GetProgress(), 0, "Constructor: initial progress")
	print("  [PASS] Constructor")

	-- Test 2: AddXP without level up
	xp:AddXP(50)
	assertEq(xp:GetLevel(), 1, "AddXP(50): level stays 1")
	local progress = xp:GetProgress()
	assertNear(progress, 50 / 100, 0.001, "AddXP(50): progress")
	print("  [PASS] AddXP without level up")

	-- Test 3: AddXP causing level up (default formula: 100 * 1^1.5 = 100)
	xp:AddXP(60)
	-- 50 + 60 = 110, so level 2 with 10 XP, xpToNext = floor(100 * 2^1.5) = floor(100 * 2.828) = 282
	assertEq(xp:GetLevel(), 2, "AddXP(60): level up to 2")
	assertNear(xp:GetProgress(), 10 / 282, 0.001, "AddXP(60): progress after level up")
	print("  [PASS] AddXP with level up")

	-- Test 4: GetXPData
	local data = xp:GetXPData()
	assertEq(data.level, 2, "GetXPData: level")
	assertEq(data.currentXP, 10, "GetXPData: currentXP")
	assertEq(data.xpToNext, 282, "GetXPData: xpToNext")
	print("  [PASS] GetXPData")

	-- Test 5: Custom formula via config
	local customConfig = Config.new({ xpFormula = function(lvl: number): number return lvl * 50 end })
	local xp2 = XPSystem.new(bus, customConfig)
	xp2:AddXP(120)
	-- Level 1 needs 50, level 2 needs 100. 120 total = level 3 with 20 XP remaining (wait: 120 - 50 = 70, 70 - 100 = -30, so level 2 with 70)
	-- Actually: 120 >= 50, subtract 50 -> 70, 70 >= 100? No. So level 2 with 70 XP
	assertEq(xp2:GetLevel(), 2, "Custom formula: level after 120 XP")
	assertEq(xp2:GetXPData().xpToNext, 100, "Custom formula: xpToNext for level 2")
	print("  [PASS] Custom formula")

	-- Test 6: Event emission
	local xpAddedFired = false
	local levelUpFired = false
	bus:Subscribe("XPAdded", function(_payload: any)
		xpAddedFired = true
	end)
	bus:Subscribe("LevelUp", function(_payload: any)
		levelUpFired = true
	end)
	local xp3 = XPSystem.new(bus, Config.new())
	xp3:AddXP(150)
	-- Should trigger both XPAdded and LevelUp
	assertEq(xpAddedFired, true, "Event: XPAdded should fire")
	assertEq(levelUpFired, true, "Event: LevelUp should fire")
	print("  [PASS] Event emission")

	print("[test_XPSystem] All tests passed!")
end

runTests()

return true
