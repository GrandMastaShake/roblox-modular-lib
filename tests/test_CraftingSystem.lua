--!strict
-- test_CraftingSystem.lua
-- Lightweight tests for CraftingSystem module.

local CraftingSystem = require(script.Parent.Parent.src.CraftingSystem)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. ": expected " .. tostring(b) .. " got " .. tostring(a))
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
		_listeners = {} :: { [string]: { (any) -> () } },
		Subscribe = function(self: any, eventName: string, callback: (any) -> ()): () -> ()
			if not self._listeners[eventName] then
				self._listeners[eventName] = {}
			end
			table.insert(self._listeners[eventName], callback)
			return function() end
		end,
		Emit = function(self: any, eventName: string, payload: any)
			if not self._events[eventName] then
				self._events[eventName] = {}
			end
			table.insert(self._events[eventName], payload)
			-- Notify listeners
			local listeners = self._listeners[eventName]
			if listeners then
				for _, cb in ipairs(listeners) do
					cb(payload)
				end
			end
		end,
	}
	return bus
end

-- Test 1: RegisterRecipe emits RecipeUnlocked
print("TEST: RegisterRecipe")
do
	local bus = createMockEventBus()
	local cs = CraftingSystem.new(bus)
	cs:RegisterRecipe({
		id = "iron_sword",
		name = "Iron Sword",
		ingredients = { { itemId = "iron_ore", quantity = 2 } },
		outputs = { { itemId = "iron_sword", quantity = 1 } },
		craftTime = 0,
		category = "weapons",
	})

	local events = bus._events["RecipeUnlocked"] or {}
	assertEq(#events, 1, "RecipeUnlocked event count")
	assertEq(events[1].recipeId, "iron_sword", "RecipeUnlocked recipeId")
end

-- Test 2: CanCraft returns false for unknown recipe
print("TEST: CanCraft unknown recipe")
do
	local bus = createMockEventBus()
	local cs = CraftingSystem.new(bus)
	local canCraft = cs:CanCraft("nonexistent")
	assertFalse(canCraft, "CanCraft should return false for unknown recipe")
end

-- Test 3: CanCraft with direct inventoryRef
print("TEST: CanCraft with inventoryRef")
do
	local bus = createMockEventBus()
	local inventoryRef = {
		GetItemQuantity = function(self: any, itemId: string): number
			if itemId == "iron_ore" then
				return 5
			end
			return 0
		end,
	}
	local cs = CraftingSystem.new(bus, inventoryRef)
	cs:RegisterRecipe({
		id = "iron_sword",
		name = "Iron Sword",
		ingredients = { { itemId = "iron_ore", quantity = 2 } },
		outputs = { { itemId = "iron_sword", quantity = 1 } },
	})

	local canCraft = cs:CanCraft("iron_sword")
	assertTrue(canCraft, "CanCraft should return true when ingredients available")
end

-- Test 4: CanCraft with insufficient ingredients via inventoryRef
print("TEST: CanCraft insufficient ingredients")
do
	local bus = createMockEventBus()
	local inventoryRef = {
		GetItemQuantity = function(self: any, itemId: string): number
			return 1
		end,
	}
	local cs = CraftingSystem.new(bus, inventoryRef)
	cs:RegisterRecipe({
		id = "iron_sword",
		name = "Iron Sword",
		ingredients = { { itemId = "iron_ore", quantity = 2 } },
		outputs = { { itemId = "iron_sword", quantity = 1 } },
	})

	local canCraft = cs:CanCraft("iron_sword")
	assertFalse(canCraft, "CanCraft should return false when not enough ingredients")
end

-- Test 5: Craft success (instant)
print("TEST: Craft success instant")
do
	local bus = createMockEventBus()
	local inventoryRef = {
		GetItemQuantity = function(self: any, itemId: string): number
			return 5
		end,
	}
	local cs = CraftingSystem.new(bus, inventoryRef)
	cs:RegisterRecipe({
		id = "iron_sword",
		name = "Iron Sword",
		ingredients = { { itemId = "iron_ore", quantity = 2 } },
		outputs = { { itemId = "iron_sword", quantity = 1 } },
		craftTime = 0,
	})

	local ok = cs:Craft("iron_sword")
	assertTrue(ok, "Craft should succeed")

	local startedEvents = bus._events["CraftStarted"] or {}
	local completedEvents = bus._events["CraftCompleted"] or {}
	assertEq(#startedEvents, 1, "CraftStarted event count")
	assertEq(#completedEvents, 1, "CraftCompleted event count")
end

-- Test 6: Craft fail (unknown recipe)
print("TEST: Craft fail unknown recipe")
do
	local bus = createMockEventBus()
	local cs = CraftingSystem.new(bus)
	local ok = cs:Craft("nonexistent")
	assertFalse(ok, "Craft should fail for unknown recipe")

	local failedEvents = bus._events["CraftFailed"] or {}
	assertEq(#failedEvents, 1, "CraftFailed event count")
end

-- Test 7: Craft fail (already crafting)
print("TEST: Craft fail already crafting")
do
	local bus = createMockEventBus()
	local inventoryRef = {
		GetItemQuantity = function(self: any, itemId: string): number
			return 5
		end,
	}
	local cs = CraftingSystem.new(bus, inventoryRef)
	cs:RegisterRecipe({
		id = "iron_sword",
		name = "Iron Sword",
		ingredients = { { itemId = "iron_ore", quantity = 2 } },
		outputs = { { itemId = "iron_sword", quantity = 1 } },
		craftTime = 5,
	})

	local ok1 = cs:Craft("iron_sword")
	assertTrue(ok1, "First craft should succeed")

	local ok2 = cs:Craft("iron_sword")
	assertFalse(ok2, "Second craft should fail (already crafting)")

	local failedEvents = bus._events["CraftFailed"] or {}
	assertEq(#failedEvents, 1, "CraftFailed event count")
	assertEq(failedEvents[1].reason, "Already crafting", "CraftFailed reason")
end

-- Test 8: Craft with delay (task.delay)
print("TEST: Craft with delay")
do
	local bus = createMockEventBus()
	local inventoryRef = {
		GetItemQuantity = function(self: any, itemId: string): number
			return 5
		end,
	}
	local cs = CraftingSystem.new(bus, inventoryRef)
	cs:RegisterRecipe({
		id = "iron_sword",
		name = "Iron Sword",
		ingredients = { { itemId = "iron_ore", quantity = 2 } },
		outputs = { { itemId = "iron_sword", quantity = 1 } },
		craftTime = 0.1,
	})

	local ok = cs:Craft("iron_sword")
	assertTrue(ok, "Craft should succeed")

	-- Should be crafting now
	local progress = cs:GetCraftingProgress()
	assertTrue(progress >= 0 and progress < 1, "Progress should be between 0 and 1 during craft")

	-- Wait for craft to complete
	task.wait(0.15)

	local progressAfter = cs:GetCraftingProgress()
	assertEq(progressAfter, -1, "Progress should be -1 after craft completes")

	local completedEvents = bus._events["CraftCompleted"] or {}
	assertEq(#completedEvents, 1, "CraftCompleted event count after delay")
end

-- Test 9: GetAvailableRecipes
print("TEST: GetAvailableRecipes")
do
	local bus = createMockEventBus()
	local cs = CraftingSystem.new(bus)
	cs:RegisterRecipe({
		id = "recipe_a",
		name = "Recipe A",
		ingredients = {},
		outputs = {},
	})
	cs:RegisterRecipe({
		id = "recipe_b",
		name = "Recipe B",
		ingredients = {},
		outputs = {},
	})

	local recipes = cs:GetAvailableRecipes()
	assertEq(#recipes, 2, "GetAvailableRecipes count")
end

-- Test 10: GetRecipesByCategory
print("TEST: GetRecipesByCategory")
do
	local bus = createMockEventBus()
	local cs = CraftingSystem.new(bus)
	cs:RegisterRecipe({
		id = "sword_recipe",
		name = "Sword",
		ingredients = {},
		outputs = {},
		category = "weapons",
	})
	cs:RegisterRecipe({
		id = "shield_recipe",
		name = "Shield",
		ingredients = {},
		outputs = {},
		category = "armor",
	})
	cs:RegisterRecipe({
		id = "axe_recipe",
		name = "Axe",
		ingredients = {},
		outputs = {},
		category = "weapons",
	})

	local weapons = cs:GetRecipesByCategory("weapons")
	assertEq(#weapons, 2, "GetRecipesByCategory weapons count")

	local armor = cs:GetRecipesByCategory("armor")
	assertEq(#armor, 1, "GetRecipesByCategory armor count")
end

-- Test 11: GetCraftingProgress when not crafting
print("TEST: GetCraftingProgress not crafting")
do
	local bus = createMockEventBus()
	local cs = CraftingSystem.new(bus)
	local progress = cs:GetCraftingProgress()
	assertEq(progress, -1, "GetCraftingProgress should be -1 when not crafting")
end

-- Test 12: InventoryCheckRequest emitted when no inventoryRef
print("TEST: InventoryCheckRequest event")
do
	local bus = createMockEventBus()
	local cs = CraftingSystem.new(bus)
	cs:RegisterRecipe({
		id = "test_recipe",
		name = "Test",
		ingredients = { { itemId = "wood", quantity = 1 } },
		outputs = {},
	})

	cs:CanCraft("test_recipe")

	local requestEvents = bus._events["InventoryCheckRequest"] or {}
	assertEq(#requestEvents, 1, "InventoryCheckRequest event count")
	assertEq(requestEvents[1].recipeId, "test_recipe", "InventoryCheckRequest recipeId")
end

print("All CraftingSystem tests passed.")

return true
