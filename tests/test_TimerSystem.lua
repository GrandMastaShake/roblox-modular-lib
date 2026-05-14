--!strict
-- tests/test_TimerSystem.lua
-- Lightweight assert-based tests for TimerSystem.

local EventBus = require(script.Parent.Parent.src.Core.EventBus)
local TimerSystem = require(script.Parent.Parent.src.TimerSystem)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. ": expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertNear(a: number, b: number, epsilon: number, msg: string)
	if math.abs(a - b) > epsilon then
		error(msg .. ": expected near " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function runTests()
	print("[test_TimerSystem] Starting tests...")

	-- Test 1: Constructor
	local bus = EventBus.new()
	local ts = TimerSystem.new(bus)
	assertEq(typeof(ts.StartTimer), "function", "Constructor: StartTimer is a function")
	assertEq(typeof(ts.StopTimer), "function", "Constructor: StopTimer is a function")
	assertEq(typeof(ts.PauseTimer), "function", "Constructor: PauseTimer is a function")
	assertEq(typeof(ts.ResumeTimer), "function", "Constructor: ResumeTimer is a function")
	assertEq(typeof(ts.GetRemaining), "function", "Constructor: GetRemaining is a function")
	assertEq(typeof(ts.GetProgress), "function", "Constructor: GetProgress is a function")
	assertEq(typeof(ts.StopAll), "function", "Constructor: StopAll is a function")
	assertEq(typeof(ts.Destroy), "function", "Constructor: Destroy is a function")
	ts:Destroy()
	print("  [PASS] Constructor")

	-- Test 2: StartTimer returns unique id
	local ts2 = TimerSystem.new(EventBus.new())
	local id1 = ts2:StartTimer(5)
	local id2 = ts2:StartTimer(3)
	assertEq(typeof(id1), "string", "StartTimer: returns string id")
	assertEq(typeof(id2), "string", "StartTimer: returns string id")
	assertEq(id1 == id2, false, "StartTimer: ids are unique")
	ts2:Destroy()
	print("  [PASS] StartTimer returns unique id")

	-- Test 3: GetRemaining and GetProgress
	local ts3 = TimerSystem.new(EventBus.new())
	local id3 = ts3:StartTimer(10)
	local remaining = ts3:GetRemaining(id3)
	assertNear(remaining, 10, 0.1, "GetRemaining: initially near duration")
	local progress = ts3:GetProgress(id3)
	assertNear(progress, 0, 0.01, "GetProgress: initially near 0")
	ts3:Destroy()
	print("  [PASS] GetRemaining and GetProgress")

	-- Test 4: StopTimer
	local ts4 = TimerSystem.new(EventBus.new())
	local id4 = ts4:StartTimer(10)
	ts4:StopTimer(id4)
	local rem = ts4:GetRemaining(id4)
	assertEq(rem, 0, "StopTimer: remaining is 0 after stop")
	ts4:Destroy()
	print("  [PASS] StopTimer")

	-- Test 5: PauseTimer and ResumeTimer
	local ts5 = TimerSystem.new(EventBus.new())
	local id5 = ts5:StartTimer(10)
	ts5:PauseTimer(id5)
	local remBefore = ts5:GetRemaining(id5)
	task.wait(0.2)
	local remAfter = ts5:GetRemaining(id5)
	assertNear(remBefore, remAfter, 0.05, "PauseTimer: remaining does not change while paused")
	ts5:ResumeTimer(id5)
	assertEq(ts5:GetRemaining(id5) > 0, true, "ResumeTimer: timer still has remaining time")
	ts5:Destroy()
	print("  [PASS] PauseTimer and ResumeTimer")

	-- Test 6: TimerStarted event
	local startFired = false
	local startBus = EventBus.new()
	startBus:Subscribe("TimerStarted", function(payload: any)
		startFired = true
		assertEq(typeof(payload.id), "string", "TimerStarted: payload has id")
		assertEq(payload.duration, 5, "TimerStarted: payload has correct duration")
	end)
	local ts6 = TimerSystem.new(startBus)
	local _id6 = ts6:StartTimer(5)
	assertEq(startFired, true, "Event: TimerStarted fired")
	ts6:Destroy()
	print("  [PASS] TimerStarted event")

	-- Test 7: TimerStopped event
	local stopFired = false
	local stopBus = EventBus.new()
	stopBus:Subscribe("TimerStopped", function(payload: any)
		stopFired = true
		assertEq(typeof(payload.id), "string", "TimerStopped: payload has id")
		assertEq(payload.reason, "stopped", "TimerStopped: payload reason is 'stopped'")
	end)
	local ts7 = TimerSystem.new(stopBus)
	local id7 = ts7:StartTimer(10)
	ts7:StopTimer(id7)
	-- Give a frame for event processing
	task.wait()
	assertEq(stopFired, true, "Event: TimerStopped fired")
	ts7:Destroy()
	print("  [PASS] TimerStopped event")

	-- Test 8: Loop timer restarts automatically
	local ts8 = TimerSystem.new(EventBus.new())
	local loopCount = 0
	local id8 = ts8:StartTimer(0.1, function(_timerId: string)
		loopCount += 1
	end, true)
	task.wait(0.35)
	-- Timer should have fired at least 2-3 times with looping
	assertEq(loopCount >= 2, true, "Loop: callback fired multiple times (got " .. tostring(loopCount) .. ")")
	ts8:StopTimer(id8)
	ts8:Destroy()
	print("  [PASS] Loop timer")

	-- Test 9: Non-looping timer auto-cleanup
	local completedFired = false
	local compBus = EventBus.new()
	compBus:Subscribe("TimerCompleted", function(_payload: any)
		completedFired = true
	end)
	local ts9 = TimerSystem.new(compBus)
	local _id9 = ts9:StartTimer(0.05)
	task.wait(0.15)
	assertEq(completedFired, true, "Auto-cleanup: TimerCompleted fired")
	-- Timer should be auto-removed
	assertEq(ts9:GetRemaining(_id9), 0, "Auto-cleanup: timer removed after completion")
	ts9:Destroy()
	print("  [PASS] Auto-cleanup")

	-- Test 10: StopAll
	local ts10 = TimerSystem.new(EventBus.new())
	local _id10a = ts10:StartTimer(10)
	local _id10b = ts10:StartTimer(20)
	local _id10c = ts10:StartTimer(30)
	ts10:StopAll()
	assertEq(ts10:GetRemaining(_id10a), 0, "StopAll: first timer stopped")
	assertEq(ts10:GetRemaining(_id10b), 0, "StopAll: second timer stopped")
	assertEq(ts10:GetRemaining(_id10c), 0, "StopAll: third timer stopped")
	ts10:Destroy()
	print("  [PASS] StopAll")

	-- Test 11: GetProgress returns 1 for unknown timer
	local ts11 = TimerSystem.new(EventBus.new())
	local prog = ts11:GetProgress("nonexistent-timer-id")
	assertEq(prog, 1, "GetProgress: unknown timer returns 1")
	ts11:Destroy()
	print("  [PASS] GetProgress for unknown timer")

	-- Test 12: Callback receives timer id
	local callbackGotId: string = ""
	local ts12 = TimerSystem.new(EventBus.new())
	local id12 = ts12:StartTimer(0.05, function(timerId: string)
		callbackGotId = timerId
	end)
	task.wait(0.15)
	assertEq(callbackGotId, id12, "Callback: receives correct timer id")
	ts12:Destroy()
	print("  [PASS] Callback receives timer id")

	print("[test_TimerSystem] All tests passed!")
end

runTests()

return true
