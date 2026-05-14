--!strict
-- CraftingSystem.lua
-- Recipe-based crafting with ingredients/outputs and optional craft time.

local CraftingSystem = {}
CraftingSystem.__index = CraftingSystem

export type Ingredient = {
	itemId: string,
	quantity: number,
}

export type Recipe = {
	id: string,
	name: string,
	ingredients: { Ingredient },
	outputs: { Ingredient },
	craftTime: number?,
	category: string?,
}

export type CraftingSystem = {
	RegisterRecipe: (self: CraftingSystem, recipe: Recipe) -> (),
	CanCraft: (self: CraftingSystem, recipeId: string) -> boolean,
	Craft: (self: CraftingSystem, recipeId: string) -> boolean,
	GetAvailableRecipes: (self: CraftingSystem) -> { Recipe },
	GetRecipesByCategory: (self: CraftingSystem, category: string) -> { Recipe },
	GetCraftingProgress: (self: CraftingSystem) -> number,
}

type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
}

function CraftingSystem.new(eventBus: EventBus, inventoryRef: any?): CraftingSystem
	local self = setmetatable({}, CraftingSystem)
	self._eventBus = eventBus
	self._inventoryRef = inventoryRef
	self._recipes = {} :: { [string]: Recipe }
	self._canCraftCache = {} :: { [string]: boolean }
	self._crafting = false
	self._craftStartTime = 0
	self._craftEndTime = 0
	self._currentRecipeId = nil :: string?

	eventBus:Subscribe("InventoryCheckResponse", function(payload: any)
		if payload and payload.recipeId ~= nil then
			self._canCraftCache[payload.recipeId] = payload.canCraft
		end
	end)

	return self
end

function CraftingSystem:RegisterRecipe(recipe: Recipe)
	self._recipes[recipe.id] = recipe
	self._eventBus:Emit("RecipeUnlocked", { recipeId = recipe.id, recipe = recipe })
end

function CraftingSystem:CanCraft(recipeId: string): boolean
	local recipe = self._recipes[recipeId]
	if not recipe then
		return false
	end

	-- Use direct inventory reference if available
	if self._inventoryRef then
		local canCraft = true
		for _, ingredient in ipairs(recipe.ingredients) do
			local hasItem = false
			-- inventoryRef is expected to have a GetItemQuantity or similar method
			-- or we can fall back to event-based checks
			if typeof(self._inventoryRef.GetItemQuantity) == "function" then
				if self._inventoryRef:GetItemQuantity(ingredient.itemId) < ingredient.quantity then
					canCraft = false
					break
				end
			else
				hasItem = false
				canCraft = false
				break
			end
		end
		return canCraft
	end

	-- Event-based inventory check: emit request and read from cache
	self._canCraftCache[recipeId] = false
	self._eventBus:Emit("InventoryCheckRequest", {
		recipeId = recipeId,
		ingredients = recipe.ingredients,
	})

	-- Return cached value (may be stale on first call; caller can poll)
	return self._canCraftCache[recipeId] == true
end

function CraftingSystem:Craft(recipeId: string): boolean
	if self._crafting then
		self._eventBus:Emit("CraftFailed", { recipeId = recipeId, reason = "Already crafting" })
		return false
	end

	local recipe = self._recipes[recipeId]
	if not recipe then
		self._eventBus:Emit("CraftFailed", { recipeId = recipeId, reason = "Recipe not found" })
		return false
	end

	if not self:CanCraft(recipeId) then
		self._eventBus:Emit("CraftFailed", { recipeId = recipeId, reason = "Missing ingredients" })
		return false
	end

	local craftTime = recipe.craftTime or 0

	self._crafting = true
	self._currentRecipeId = recipeId
	self._craftStartTime = tick()
	self._craftEndTime = self._craftStartTime + craftTime

	self._eventBus:Emit("CraftStarted", {
		recipeId = recipeId,
		craftTime = craftTime,
	})

	if craftTime > 0 then
		task.delay(craftTime, function()
			if not self._crafting or self._currentRecipeId ~= recipeId then
				return
			end
			self:_completeCraft(recipe)
		end)
	else
		self:_completeCraft(recipe)
	end

	return true
end

function CraftingSystem:_completeCraft(recipe: Recipe)
	self._crafting = false
	self._currentRecipeId = nil
	self._craftStartTime = 0
	self._craftEndTime = 0

	self._eventBus:Emit("CraftCompleted", {
		recipeId = recipe.id,
		outputs = recipe.outputs,
	})
end

function CraftingSystem:GetAvailableRecipes(): { Recipe }
	local result = {}
	for _, recipe in pairs(self._recipes) do
		table.insert(result, recipe)
	end
	return result
end

function CraftingSystem:GetRecipesByCategory(category: string): { Recipe }
	local result = {}
	for _, recipe in pairs(self._recipes) do
		if recipe.category == category then
			table.insert(result, recipe)
		end
	end
	return result
end

function CraftingSystem:GetCraftingProgress(): number
	if not self._crafting then
		return -1
	end

	local now = tick()
	if now >= self._craftEndTime then
		return 1
	end

	local duration = self._craftEndTime - self._craftStartTime
	if duration <= 0 then
		return 1
	end

	local elapsed = now - self._craftStartTime
	return math.clamp(elapsed / duration, 0, 1)
end

-- Cancel any in-flight craft and clear all state. The pending task.delay
-- callback in :Craft re-checks `_crafting` and the recipe id before
-- completing, so by clearing those here we make stale callbacks no-op.
function CraftingSystem:Destroy()
	self._crafting = false
	self._currentRecipeId = nil
	self._craftStartTime = 0
	self._craftEndTime = 0
	self._recipes = {}
	self._canCraftCache = {}
end

return CraftingSystem
