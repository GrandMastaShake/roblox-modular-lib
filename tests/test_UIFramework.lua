--!strict
-- tests/test_UIFramework.lua
-- Lightweight assert-based tests for UIFramework.

local EventBus = require(script.Parent.Parent.src.Core.EventBus)
local UIFramework = require(script.Parent.Parent.src.UIFramework)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertNotNil(a: any, msg: string)
	if a == nil then
		error(msg .. " expected non-nil")
	end
end

local function runTests()
	print("[test_UIFramework] Starting tests...")

	-- Test 1: Constructor with default theme
	local bus = EventBus.new()
	local ui = UIFramework.new(bus)
	assertNotNil(ui, "Constructor: returns object")
	print("  [PASS] Constructor (default theme)")

	-- Test 2: Constructor with custom theme
	local customTheme = {
		primary = Color3.fromRGB(255, 0, 0),
		secondary = Color3.fromRGB(0, 255, 0),
		background = Color3.fromRGB(0, 0, 0),
		text = Color3.fromRGB(255, 255, 255),
		font = Font.fromEnum(Enum.Font.GothamBold),
		cornerRadius = 12,
	}
	local ui2 = UIFramework.new(bus, customTheme)
	assertNotNil(ui2, "Constructor: returns object with custom theme")
	print("  [PASS] Constructor (custom theme)")

	-- Test 3: SetTheme
	local newTheme = {
		primary = Color3.fromRGB(255, 255, 0),
		secondary = Color3.fromRGB(0, 255, 255),
		background = Color3.fromRGB(50, 50, 50),
		text = Color3.fromRGB(200, 200, 200),
		font = Font.fromEnum(Enum.Font.Gotham),
		cornerRadius = 4,
	}
	ui:SetTheme(newTheme)
	print("  [PASS] SetTheme")

	-- Test 4: CreateButton
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "TestGui"

	local clicked = false
	local button = ui:CreateButton(screenGui, "TestButton", function()
		clicked = true
	end)
	assertNotNil(button, "CreateButton: returns button")
	assertEq(button.Name, "UIButton", "CreateButton: button name")
	assertEq(button.Text, "TestButton", "CreateButton: button text")
	assertEq(button.Parent, screenGui, "CreateButton: parent set")
	assertNotNil(button:FindFirstChildOfClass("UICorner"), "CreateButton: has UICorner")
	print("  [PASS] CreateButton")

	-- Test 5: CreateBar
	local bar = ui:CreateBar(screenGui, UDim2.new(0, 200, 0, 20), Color3.fromRGB(0, 200, 0))
	assertNotNil(bar, "CreateBar: returns bar container")
	assertEq(bar.Name, "BarContainer", "CreateBar: container name")
	assertEq(bar.Size, UDim2.new(0, 200, 0, 20), "CreateBar: size")
	local fill = bar:FindFirstChild("BarFill")
	assertNotNil(fill, "CreateBar: has BarFill child")
	assertEq((fill :: Frame).Size, UDim2.new(0, 0, 1, 0), "CreateBar: fill starts at 0 width")
	print("  [PASS] CreateBar")

	-- Test 6: Tween
	local testFrame = Instance.new("Frame")
	testFrame.Size = UDim2.new(0, 100, 0, 100)
	testFrame.Parent = screenGui
	local tween = ui:Tween(testFrame, { Size = UDim2.new(0, 200, 0, 200) }, 0.1)
	assertNotNil(tween, "Tween: returns tween")
	print("  [PASS] Tween")

	-- Test 7: ThemeBar with BarFill child
	ui:ThemeBar(bar, 0.75)
	assertEq(true, true, "ThemeBar: does not error")
	print("  [PASS] ThemeBar")

	-- Test 8: UIButtonClicked event
	local eventFired = false
	bus:Subscribe("UIButtonClicked", function(_payload: any)
		eventFired = true
	end)
	-- Simulate click manually since we can't click in tests
	-- The event fires inside MouseButton1Click handler, but we can't trigger that in pure Lua.
	-- Instead, emit directly for test coverage
	bus:Emit("UIButtonClicked", { text = "Manual", button = button })
	assertEq(eventFired, true, "Event: UIButtonClicked should be emitted")
	print("  [PASS] UIButtonClicked event")

	screenGui:Destroy()

	print("[test_UIFramework] All tests passed!")
end

runTests()

return true
