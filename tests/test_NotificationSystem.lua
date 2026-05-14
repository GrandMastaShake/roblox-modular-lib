--!strict
-- tests/test_NotificationSystem.lua
-- Lightweight assert-based tests for NotificationSystem.

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

-- Mock Roblox services before requiring NotificationSystem
local mockTweens = {} :: { any }
local mockFrames = {} :: { any }

local function createMockTweenService()
	return {
		Create = function(_self: any, instance: any, tweenInfo: any, props: any)
			local tween = {
				Instance = instance,
				TweenInfo = tweenInfo,
				Props = props,
				Playing = false,
				Play = function(self: any)
					self.Playing = true
				end,
				Pause = function(self: any)
					self.Playing = false
				end,
				Cancel = function(self: any)
					self.Playing = false
				end,
				Completed = {
					Connect = function(self: any, callback: () -> ())
						-- Store callback to fire later if needed
						self._callback = callback
						return { Disconnect = function() end }
					end,
					_callback = nil,
				},
			}
			table.insert(mockTweens, tween)
			return tween
		end,
	}
end

local function createMockHttpService()
	local counter = 0
	return {
		GenerateGUID = function(_self: any, _wrapInCurlyBraces: boolean): string
			counter += 1
			return "GUID-" .. tostring(counter)
		end,
	}
end

-- Build a minimal mock game environment
local mockGame = {
	_services = {} :: { [string]: any },
	GetService = function(self: any, name: string): any
		if name == "TweenService" then
			if not self._services[name] then
				self._services[name] = createMockTweenService()
			end
			return self._services[name]
		elseif name == "HttpService" then
			if not self._services[name] then
				self._services[name] = createMockHttpService()
			end
			return self._services[name]
		elseif name == "Players" then
			return {
				LocalPlayer = {
					WaitForChild = function(_self: any, _name: string) return Instance.new("PlayerGui") end,
					PlayerGui = Instance.new("Folder"),
				},
			}
		elseif name == "CoreGui" then
			return Instance.new("Folder")
		end
		return Instance.new(name)
	end,
}

-- Inject mock game
local originalGame = game
game = mockGame :: any

local NotificationSystem = require(script.Parent.Parent.src.NotificationSystem)

-- Restore
game = originalGame

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

-- Test 1: Show returns unique id
print("TEST: Show returns unique id")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	local id1 = ns:Show("info", "Title 1", "Message 1")
	local id2 = ns:Show("success", "Title 2", "Message 2")

	assertTrue(id1 ~= nil, "First Show should return an id")
	assertTrue(id2 ~= nil, "Second Show should return an id")
	assertTrue(id1 ~= id2, "Ids should be unique")
end

-- Test 2: Show emits NotificationShown
print("TEST: Show emits NotificationShown")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	ns:Show("warning", "Warning Title", "Warning message", 5)

	local events = bus._events["NotificationShown"] or {}
	assertEq(#events, 1, "NotificationShown event count")
	if events[1] then
		assertEq(events[1].type, "warning", "Event type")
		assertEq(events[1].title, "Warning Title", "Event title")
		assertEq(events[1].message, "Warning message", "Event message")
		assertEq(events[1].duration, 5, "Event duration")
		assertTrue(events[1].id ~= nil, "Event id")
	end
end

-- Test 3: Dismiss emits NotificationDismissed
print("TEST: Dismiss emits NotificationDismissed")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	local id = ns:Show("info", "To Dismiss", "This will be dismissed")
	ns:Dismiss(id)

	local events = bus._events["NotificationDismissed"] or {}
	assertEq(#events, 1, "NotificationDismissed event count")
	if events[1] then
		assertEq(events[1].id, id, "Dismissed event id")
	end
end

-- Test 4: DismissAll
print("TEST: DismissAll")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	ns:Show("info", "N1", "Message 1")
	ns:Show("error", "N2", "Message 2")
	ns:Show("success", "N3", "Message 3")

	ns:DismissAll()

	local events = bus._events["NotificationDismissed"] or {}
	assertEq(#events, 3, "NotificationDismissed event count after DismissAll")
end

-- Test 5: GetHistory
print("TEST: GetHistory")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	ns:Show("info", "H1", "History 1")
	ns:Show("success", "H2", "History 2")
	ns:Show("warning", "H3", "History 3")

	local history = ns:GetHistory()
	assertEq(#history, 3, "History count")
	assertEq(history[1].title, "H1", "First history title")
	assertEq(history[2].title, "H2", "Second history title")
	assertEq(history[3].title, "H3", "Third history title")
end

-- Test 6: GetHistory with limit
print("TEST: GetHistory with limit")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	ns:Show("info", "L1", "Limit 1")
	ns:Show("info", "L2", "Limit 2")
	ns:Show("info", "L3", "Limit 3")
	ns:Show("info", "L4", "Limit 4")

	local history = ns:GetHistory(2)
	assertEq(#history, 2, "History with limit=2")
	assertEq(history[1].title, "L3", "First limited history")
	assertEq(history[2].title, "L4", "Second limited history")
end

-- Test 7: Default duration from config
print("TEST: Default duration from config")
do
	local bus = createMockEventBus()
	local Config = require(script.Parent.Parent.src.Core.Config)
	local config = Config.new({ notificationDuration = 7 })
	local ns = NotificationSystem.new(bus, config)

	local id = ns:Show("info", "Custom Dur", "Should have 7s duration")
	local history = ns:GetHistory()
	assertEq(#history, 1, "History count")
	if history[1] then
		assertEq(history[1].duration, 7, "Custom default duration")
	end
end

-- Test 8: Different notification types stored correctly
print("TEST: Notification types")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	ns:Show("info", "Info", "Info msg")
	ns:Show("success", "Success", "Success msg")
	ns:Show("warning", "Warning", "Warning msg")
	ns:Show("error", "Error", "Error msg")

	local history = ns:GetHistory()
	assertEq(#history, 4, "All 4 types stored")
	assertEq(history[1].type, "info", "Info type")
	assertEq(history[2].type, "success", "Success type")
	assertEq(history[3].type, "warning", "Warning type")
	assertEq(history[4].type, "error", "Error type")
end

-- Test 9: Dismiss with unknown id (no error)
print("TEST: Dismiss unknown id")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	ns:Dismiss("nonexistent-id")
	local events = bus._events["NotificationDismissed"] or {}
	assertEq(#events, 0, "No event for unknown id")
end

-- Test 10: SetContainer
print("TEST: SetContainer")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	local mockContainer = Instance.new("ScreenGui")
	ns:SetContainer(mockContainer)

	-- Just verify no error when showing after setting container
	local id = ns:Show("info", "Container Test", "Test")
	assertTrue(id ~= nil, "Show should work after SetContainer")
end

-- Test 11: Show with explicit duration overrides default
print("TEST: Show explicit duration")
do
	local bus = createMockEventBus()
	local Config = require(script.Parent.Parent.src.Core.Config)
	local config = Config.new({ notificationDuration = 10 })
	local ns = NotificationSystem.new(bus, config)

	local id = ns:Show("info", "Override", "Override msg", 2)
	local history = ns:GetHistory()
	assertEq(#history, 1, "History count")
	if history[1] then
		assertEq(history[1].duration, 2, "Explicit duration should override config")
	end
end

-- Test 12: Multiple DismissAll is safe
print("TEST: Multiple DismissAll safe")
do
	local bus = createMockEventBus()
	local ns = NotificationSystem.new(bus)

	ns:Show("info", "N1", "Message 1")
	ns:DismissAll()
	ns:DismissAll() -- Should not error

	local events = bus._events["NotificationDismissed"] or {}
	assertEq(#events, 1, "Only 1 dismiss event (first DismissAll)")
end

print("[test_NotificationSystem] All tests passed!")

return true
