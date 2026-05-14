--!strict
-- LODSystem.lua
-- Level-of-detail system for low-poly assets.  Manages simplification of distant
-- models by swapping them for pre-generated reduced-part versions or billboards.
--
-- DESIGN:
--   - Each registered Model tracks its current LOD level (0..3).
--   - LOD rules are registered per asset type (tree, rock, building) and define
--     distance thresholds at which to switch levels.
--   - Simplified models are generated on first switch and cached.
--   - Auto-LOD mode uses RunService.Heartbeat to periodically evaluate distances.
--
-- EVENTS EMITTED:
--   LODChanged      -> { model, assetType, oldLevel, newLevel, distance }
--   ModelSimplified -> { model, assetType, level }
--   ModelRestored   -> { model, assetType, level }

local RunService = game:GetService("RunService")

-- =============================================================================
-- TYPE DEFINITIONS
-- =============================================================================

export type LODLevel = number  -- 0..3; literal union not supported in current Luau

export type LODThreshold = {
	distance: number,
	level: LODLevel,
}

export type LODRules = {
	thresholds: { LODThreshold },
}

export type ModelLODInfo = {
	currentLevel: LODLevel,
	assetType: string,
	lodModels: { [number]: Model },
	originalParent: Instance?,   -- parent to restore when going back from nil
	billboardPart: BasePart?,    -- cached billboard part for level 3
	simplificationCache: {      -- cached visibility states per level
		[number]: { [BasePart]: boolean },
	},
}

export type LODSystem = {
	SetLODLevel: (self: LODSystem, model: Model, level: LODLevel) -> (),
	UpdateLOD: (self: LODSystem, cameraPosition: Vector3) -> (),
	RegisterLODRules: (self: LODSystem, assetType: string, rules: LODRules) -> (),
	EnableAutoLOD: (self: LODSystem, interval: number) -> (),
	DisableAutoLOD: (self: LODSystem) -> (),
	RegisterModel: (self: LODSystem, model: Model, assetType: string) -> (),
	UnregisterModel: (self: LODSystem, model: Model) -> (),
	GetModelLODInfo: (self: LODSystem, model: Model) -> ModelLODInfo?,
	Clear: (self: LODSystem) -> (),
}

type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
	Once: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
}

-- =============================================================================
-- DEFAULT LOD RULES (distance thresholds per asset type)
-- =============================================================================

local DEFAULT_TREE_RULES: LODRules = {
	thresholds = {
		{ distance = 0,   level = 0 :: LODLevel },
		{ distance = 200, level = 1 :: LODLevel },
		{ distance = 400, level = 2 :: LODLevel },
		{ distance = 800, level = 3 :: LODLevel },
	},
}

local DEFAULT_ROCK_RULES: LODRules = {
	thresholds = {
		{ distance = 0,   level = 0 :: LODLevel },
		{ distance = 150, level = 1 :: LODLevel },
		{ distance = 300, level = 2 :: LODLevel },
		{ distance = 600, level = 3 :: LODLevel },
	},
}

local DEFAULT_BUILDING_RULES: LODRules = {
	thresholds = {
		{ distance = 0,    level = 0 :: LODLevel },
		{ distance = 300,  level = 1 :: LODLevel },
		{ distance = 600,  level = 2 :: LODLevel },
		{ distance = 1000, level = 3 :: LODLevel },
	},
}

-- =============================================================================
-- MODULE
-- =============================================================================

local LODSystem = {}
LODSystem.__index = LODSystem

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------
function LODSystem.new(eventBus: EventBus): LODSystem
	local self = setmetatable({}, LODSystem)

	self._eventBus = eventBus
	self._registry = {} :: { [Model]: ModelLODInfo }
	self._rules = {} :: { [string]: LODRules }
	self._heartbeatConnection = nil
	self._lastUpdateTime = 0
	self._updateInterval = 1
	self._enabled = false

	-- Register default rules for known asset types
	self:RegisterLODRules("tree", DEFAULT_TREE_RULES)
	self:RegisterLODRules("rock", DEFAULT_ROCK_RULES)
	self:RegisterLODRules("building", DEFAULT_BUILDING_RULES)

	return self
end

--------------------------------------------------------------------------------
-- RegisterLOD Rules: store distance thresholds for an asset type
--------------------------------------------------------------------------------
function LODSystem:RegisterLODRules(assetType: string, rules: LODRules)
	-- Sort thresholds by distance ascending for reliable lookup
	local sorted = table.clone(rules.thresholds)
	table.sort(sorted, function(a: LODThreshold, b: LODThreshold)
		return a.distance < b.distance
	end)
	self._rules[assetType] = { thresholds = sorted }
end

--------------------------------------------------------------------------------
-- _getRuleForDistance: find the LOD level matching a distance for an asset type
--------------------------------------------------------------------------------
function LODSystem:_getRuleForDistance(assetType: string, distance: number): LODLevel
	local rules = self._rules[assetType]
	if not rules then
		return 0 :: LODLevel
	end

	local matchedLevel: LODLevel = 0 :: LODLevel
	for _, threshold in ipairs(rules.thresholds) do
		if distance >= threshold.distance then
			matchedLevel = threshold.level
		else
			break
		end
	end
	return matchedLevel
end

--------------------------------------------------------------------------------
-- _getModelPosition: get the world position of a model ( PrimaryPart or bounding )
--------------------------------------------------------------------------------
function LODSystem:_getModelPosition(model: Model): Vector3
	if model.PrimaryPart then
		return model.PrimaryPart.Position
	end

	-- Fallback: compute bounding-box center
	local parts = model:GetDescendants()
	local count = 0
	local sum = Vector3.zero
	for _, part in ipairs(parts) do
		if part:IsA("BasePart") then
			sum += part.Position
			count += 1
		end
	end
	if count > 0 then
		return sum / count
	end
	return Vector3.zero
end

--------------------------------------------------------------------------------
-- _generateSimplification: create simplification cache for a given level
--   Level 1: hide 50% of Parts (every other Part)
--   Level 2: hide 80% of Parts (keep only large Parts)
--   Level 3: replace with single billboard Part
--------------------------------------------------------------------------------
function LODSystem:_generateSimplification(model: Model, level: LODLevel): { [BasePart]: boolean }
	local allParts: { BasePart } = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(allParts, desc)
		end
	end

	local visibilityMap: { [BasePart]: boolean } = {}

	if level == 1 then
		-- Level 1: hide every other part (keep 50%)
		for i, part in ipairs(allParts) do
			visibilityMap[part] = (i % 2 == 1) -- keep odd-indexed parts
		end

	elseif level == 2 then
		-- Level 2: hide 80%, keep only the largest 20% by volume
		local sortedParts = table.clone(allParts)
		table.sort(sortedParts, function(a: BasePart, b: BasePart)
			local volA = a.Size.X * a.Size.Y * a.Size.Z
			local volB = b.Size.X * b.Size.Y * b.Size.Z
			return volA > volB
		end)
		local keepCount = math.max(1, math.floor(#sortedParts * 0.2))
		for i, part in ipairs(sortedParts) do
			visibilityMap[part] = (i <= keepCount)
		end

	elseif level == 3 then
		-- Level 3: billboard - hide ALL original parts, use billboard instead
		for _, part in ipairs(allParts) do
			visibilityMap[part] = false
		end
	end

	return visibilityMap
end

--------------------------------------------------------------------------------
-- _getOrCreateBillboard: create a single billboard Part for level 3
--------------------------------------------------------------------------------
function LODSystem:_getOrCreateBillboard(model: Model, info: ModelLODInfo): BasePart
	if info.billboardPart and info.billboardPart.Parent then
		return info.billboardPart
	end

	-- Compute bounding box to size the billboard
	local parts: { BasePart } = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end

	local size = Vector3.new(4, 4, 0.1) -- default
	local pos = self:_getModelPosition(model)

	if #parts > 0 then
		local minCorner = Vector3.new(math.huge, math.huge, math.huge)
		local maxCorner = Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, part in ipairs(parts) do
			local halfSize = part.Size / 2
			minCorner = Vector3.new(
				math.min(minCorner.X, part.Position.X - halfSize.X),
				math.min(minCorner.Y, part.Position.Y - halfSize.Y),
				math.min(minCorner.Z, part.Position.Z - halfSize.Z)
			)
			maxCorner = Vector3.new(
				math.max(maxCorner.X, part.Position.X + halfSize.X),
				math.max(maxCorner.Y, part.Position.Y + halfSize.Y),
				math.max(maxCorner.Z, part.Position.Z + halfSize.Z)
			)
		end
		local bounds = maxCorner - minCorner
		-- Billboard: width = max of X/Z, height = Y, depth = thin plane
		size = Vector3.new(
			math.max(bounds.X, bounds.Z),
			bounds.Y,
			0.1
		)
		pos = (minCorner + maxCorner) / 2
	end

	local billboard = Instance.new("Part")
	billboard.Name = model.Name .. "_Billboard"
	billboard.Size = size
	billboard.Position = pos
	billboard.Anchored = true
	billboard.CanCollide = false
	billboard.Transparency = 0.3
	billboard.Material = Enum.Material.SmoothPlastic
	billboard.Shape = Enum.PartType.Block

	-- Use a BillboardGui-style appearance: bright color from original
	local avgColor = Color3.fromRGB(120, 180, 80)
	if #parts > 0 then
		local r, g, b = 0, 0, 0
		local colorCount = 0
		for _, part in ipairs(parts) do
			r += part.Color.R
			g += part.Color.G
			b += part.Color.B
			colorCount += 1
		end
		if colorCount > 0 then
			avgColor = Color3.new(r / colorCount, g / colorCount, b / colorCount)
		end
	end
	billboard.Color = avgColor

	-- Add a SurfaceGui or Decal to make it look like a billboard sprite
	local decal = Instance.new("Decal")
	decal.Face = Enum.NormalId.Front
	decal.Color3 = avgColor
	decal.Transparency = 0.5
	decal.Parent = billboard

	local decalBack = Instance.new("Decal")
	decalBack.Face = Enum.NormalId.Back
	decalBack.Color3 = avgColor
	decalBack.Transparency = 0.5
	decalBack.Parent = billboard

	billboard.Parent = model
	info.billboardPart = billboard

	return billboard
end

--------------------------------------------------------------------------------
-- _removeBillboard: remove the billboard part from a model
--------------------------------------------------------------------------------
function LODSystem:_removeBillboard(info: ModelLODInfo)
	if info.billboardPart then
		info.billboardPart:Destroy()
		info.billboardPart = nil
	end
end

--------------------------------------------------------------------------------
-- _applyLevel: switch a model to a specific LOD level
--------------------------------------------------------------------------------
function LODSystem:_applyLevel(model: Model, info: ModelLODInfo, newLevel: LODLevel)
	local oldLevel = info.currentLevel
	if oldLevel == newLevel then
		return
	end

	-- Emit pre-change event for restoration tracking
	if newLevel > oldLevel then
		self._eventBus:Emit("ModelSimplified", {
			model = model,
			assetType = info.assetType,
			level = newLevel,
		})
	else
		self._eventBus:Emit("ModelRestored", {
			model = model,
			assetType = info.assetType,
			level = newLevel,
		})
	end

	-- CASE: Switching to or from level 0 (original)
	if oldLevel == 0 then
		-- Leaving full detail: save original parent
		info.originalParent = model.Parent
	end

	if newLevel == 0 then
		-- Restore all parts to visible
		self:_removeBillboard(info)
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Transparency = 0
			end
		end
		-- Restore parent if it was changed
		if info.originalParent and model.Parent ~= info.originalParent then
			model.Parent = info.originalParent
		end
		info.simplificationCache = {}

	elseif newLevel == 3 then
		-- Billboard mode: hide all original parts, show billboard
		self:_removeBillboard(info) -- clean up old billboard
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Transparency = 1
			end
		end
		local billboard = self:_getOrCreateBillboard(model, info)
		billboard.Transparency = 0.3
		-- Ensure billboard part is visible (not the model-level hiding)
		if billboard.Transparency == 1 then
			billboard.Transparency = 0.3
		end
		-- Make billboard face camera by clearing cache
		info.simplificationCache[3] = nil

	else
		-- Level 1 or 2: part visibility mode
		self:_removeBillboard(info)

		-- Generate simplification cache on first use
		if not info.simplificationCache[newLevel] then
			info.simplificationCache[newLevel] = self:_generateSimplification(model, newLevel)
		end
		local cache = info.simplificationCache[newLevel]

		-- Apply visibility: show kept parts, hide removed parts
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("BasePart") and desc ~= info.billboardPart then
				local shouldShow = cache[desc]
				if shouldShow == nil then
					shouldShow = true -- parts not in cache default to visible
				end
				desc.Transparency = shouldShow and 0 or 1
			end
		end
	end

	info.currentLevel = newLevel

	self._eventBus:Emit("LODChanged", {
		model = model,
		assetType = info.assetType,
		oldLevel = oldLevel,
		newLevel = newLevel,
	})
end

--------------------------------------------------------------------------------
-- SetLODLevel: public API to force a model to a specific LOD level
--------------------------------------------------------------------------------
function LODSystem:SetLODLevel(model: Model, level: LODLevel)
	local info = self._registry[model]
	if not info then
		warn(string.format("[LODSystem] Model '%s' is not registered. Call RegisterModel first.", model.Name))
		return
	end

	self:_applyLevel(model, info, level)
end

--------------------------------------------------------------------------------
-- RegisterModel: add a model to the LOD registry
--------------------------------------------------------------------------------
function LODSystem:RegisterModel(model: Model, assetType: string)
	if self._registry[model] then
		return -- already registered
	end

	local info: ModelLODInfo = {
		currentLevel = 0 :: LODLevel,
		assetType = assetType,
		lodModels = {},
		originalParent = model.Parent,
		billboardPart = nil,
		simplificationCache = {},
	}
	self._registry[model] = info
end

--------------------------------------------------------------------------------
-- UnregisterModel: remove a model from the LOD registry
--------------------------------------------------------------------------------
function LODSystem:UnregisterModel(model: Model)
	local info = self._registry[model]
	if not info then
		return
	end

	-- Restore original state before removing
	if info.currentLevel ~= 0 then
		self:_applyLevel(model, info, 0 :: LODLevel)
	end
	self:_removeBillboard(info)
	self._registry[model] = nil
end

--------------------------------------------------------------------------------
-- GetModelLODInfo: get the current LOD info for a model
--------------------------------------------------------------------------------
function LODSystem:GetModelLODInfo(model: Model): ModelLODInfo?
	return self._registry[model]
end

--------------------------------------------------------------------------------
-- UpdateLOD: evaluate all registered models and switch LOD levels based on
-- distance from the given camera position.
--------------------------------------------------------------------------------
function LODSystem:UpdateLOD(cameraPosition: Vector3)
	for model, info in pairs(self._registry) do
		-- Skip destroyed models
		if not model or not model.Parent then
			continue
		end

		local modelPos = self:_getModelPosition(model)
		local distance = (cameraPosition - modelPos).Magnitude
		local targetLevel = self:_getRuleForDistance(info.assetType, distance)

		if targetLevel ~= info.currentLevel then
			self:_applyLevel(model, info, targetLevel)
		end
	end
end

--------------------------------------------------------------------------------
-- EnableAutoLOD: connect to RunService.Heartbeat for automatic LOD updates
--------------------------------------------------------------------------------
function LODSystem:EnableAutoLOD(interval: number)
	self:DisableAutoLOD() -- disconnect any existing connection

	self._updateInterval = interval
	self._enabled = true
	self._lastUpdateTime = tick()

	self._heartbeatConnection = RunService.Heartbeat:Connect(function()
		if not self._enabled then
			return
		end

		local now = tick()
		if now - self._lastUpdateTime >= self._updateInterval then
			self._lastUpdateTime = now

			-- Get camera position from workspace.CurrentCamera
			local camera = workspace.CurrentCamera
			if camera then
				self:UpdateLOD(camera.CFrame.Position)
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- DisableAutoLOD: disconnect the heartbeat connection
--------------------------------------------------------------------------------
function LODSystem:DisableAutoLOD()
	self._enabled = false
	if self._heartbeatConnection then
		self._heartbeatConnection:Disconnect()
		self._heartbeatConnection = nil
	end
end

--------------------------------------------------------------------------------
-- Clear: unregister all models and clean up
--------------------------------------------------------------------------------
function LODSystem:Clear()
	self:DisableAutoLOD()

	-- Restore all models to full detail before clearing
	for model, info in pairs(self._registry) do
		if model and model.Parent then
			if info.currentLevel ~= 0 then
				self:_applyLevel(model, info, 0 :: LODLevel)
			end
			self:_removeBillboard(info)
		end
	end

	table.clear(self._registry)
end

return LODSystem
