--!strict
-- LowPolyGenerator.lua
-- Procedural low-poly mesh generation from Roblox primitives.
-- NOTE: ColorPaletteSystem is NOT required here to preserve zero hard-coupling.
-- The ColorPalette type is declared inline (structurally identical to
-- ColorPalette) so any compatible palette is accepted.

local LowPolyGenerator = {}
LowPolyGenerator.__index = LowPolyGenerator

-- Inline palette type — same shape as ColorPalette.
-- Luau structural typing means instances from ColorPaletteSystem are compatible.
export type ColorPalette = {
	name: string,
	colors: { Color3 },
	primary: Color3,
	secondary: Color3,
	accent: Color3,
	background: Color3,
	highlights: { Color3 },
	shadows: { Color3 },
}

export type TreeConfig = {
	height: number,
	trunkWidth: number,
	foliageRadius: number,
	foliageLayers: number,
	foliageDensity: number,
	paletteIndex: number?,
}

export type RockConfig = {
	size: number,
	jaggedness: number,
	segments: number,
	flatTop: boolean,
}

export type BuildingConfig = {
	width: number,
	depth: number,
	stories: number,
	roofType: "flat" | "peaked" | "dome" | "none",
	windows: boolean,
	door: boolean,
	balcony: boolean,
}

export type PropConfig = {
	propType: "crate" | "barrel" | "fence" | "lamp" | "sign" | "campfire",
	scale: number,
	paletteIndex: number?,
}

export type LowPolyGenerator = {
	GenerateTree: (self: LowPolyGenerator, position: Vector3, config: TreeConfig?) -> Model,
	GenerateRock: (self: LowPolyGenerator, position: Vector3, config: RockConfig?) -> Model,
	GenerateBuilding: (self: LowPolyGenerator, position: Vector3, config: BuildingConfig?) -> Model,
	GenerateProp: (self: LowPolyGenerator, position: Vector3, config: PropConfig?) -> Model,
	SetPalette: (self: LowPolyGenerator, palette: ColorPalette) -> (),
}

-- Utility functions
local function randomRange(min: number, max: number): number
	return min + math.random() * (max - min)
end

local function randomInt(min: number, max: number): number
	return math.random(min, max)
end

-- Default tree config
local function defaultTreeConfig(): TreeConfig
	return {
		height = 12,
		trunkWidth = 1,
		foliageRadius = 4,
		foliageLayers = 3,
		foliageDensity = 0.8,
		paletteIndex = nil,
	}
end

-- Default rock config
local function defaultRockConfig(): RockConfig
	return {
		size = 3,
		jaggedness = 0.7,
		segments = 6,
		flatTop = false,
	}
end

-- Default building config
local function defaultBuildingConfig(): BuildingConfig
	return {
		width = 8,
		depth = 8,
		stories = 2,
		roofType = "peaked",
		windows = true,
		door = true,
		balcony = false,
	}
end

-- Default prop config
local function defaultPropConfig(): PropConfig
	return {
		propType = "crate",
		scale = 1,
		paletteIndex = nil,
	}
end

-- Merge user config with defaults
local function mergeConfig<T>(defaults: T, user: T?): T
	if not user then
		return defaults
	end
	local result = table.clone(defaults :: any)
	for k, v in pairs(user :: any) do
		result[k] = v
	end
	return result :: T
end

function LowPolyGenerator.new(eventBus: any): LowPolyGenerator
	local self = setmetatable({}, LowPolyGenerator)
	self._eventBus = eventBus
	self._palette = nil :: ColorPalette?
	self._seed = math.random(1, 100000)
	return self
end

function LowPolyGenerator:SetPalette(palette: ColorPalette): ()
	self._palette = palette
end

-- Get a color from the current palette or a fallback
local function getPaletteColor(palette: ColorPalette?, index: number): Color3
	if palette then
		return palette.colors[index] or palette.primary
	end
	-- Fallbacks
	local fallbacks = {
		Color3.fromRGB(200, 200, 200),
		Color3.fromRGB(100, 100, 100),
		Color3.fromRGB(50, 50, 50),
		Color3.fromRGB(255, 255, 255),
	}
	return fallbacks[index] or fallbacks[1]
end

-- ==========================================
-- GenerateTree
-- ==========================================
function LowPolyGenerator:GenerateTree(position: Vector3, config: TreeConfig?): Model
	local cfg = mergeConfig(defaultTreeConfig(), config)
	local model = Instance.new("Model")
	model.Name = "LowPolyTree"

	local palette = self._palette
	math.randomseed(self._seed + math.floor(position.X * 100 + position.Z))

	-- Trunk: stack 3-5 cylindrical Parts
	local trunkSegments = randomInt(3, 5)
	local trunkHeight = cfg.height * 0.45
	local segmentHeight = trunkHeight / trunkSegments
	local trunkBaseWidth = cfg.trunkWidth

	for i = 1, trunkSegments do
		local part = Instance.new("Part")
		part.Name = "Trunk" .. i
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(segmentHeight, trunkBaseWidth * (1 - (i - 1) * 0.08), trunkBaseWidth * (1 - (i - 1) * 0.08))
		-- Slight random offset for organic look
		local offset = Vector3.new(randomRange(-0.1, 0.1), 0, randomRange(-0.1, 0.1))
		part.Position = position
			+ Vector3.new(0, (i - 1) * segmentHeight + segmentHeight / 2, 0)
			+ offset
		part.Orientation = Vector3.new(0, randomRange(-3, 3), randomRange(-2, 2))
		part.Color = getPaletteColor(palette, 3) -- brown tone
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = true
		part.Parent = model
	end

	-- Foliage: 2-4 layers of Wedges arranged in cone shape
	local foliageLayers = randomInt(2, 4)
	local foliageStartY = position.Y + trunkHeight * 0.7
	local foliageTotalHeight = cfg.height * 0.55
	local layerHeight = foliageTotalHeight / foliageLayers

	for layer = 1, foliageLayers do
		local layerRadius = cfg.foliageRadius * (1 - (layer - 1) / foliageLayers) * randomRange(0.85, 1.15)
		local layerY = foliageStartY + (layer - 1) * layerHeight
		local wedgesInLayer = math.max(4, math.floor(6 * cfg.foliageDensity * (layerRadius / cfg.foliageRadius)))

		for w = 1, wedgesInLayer do
			local wedge = Instance.new("WedgePart")
			wedge.Name = "Foliage_L" .. layer .. "_W" .. w
			local wHeight = layerHeight * randomRange(0.8, 1.2)
			local wWidth = layerRadius * randomRange(0.4, 0.6)
			local wLength = layerRadius * randomRange(0.8, 1.0)
			wedge.Size = Vector3.new(wWidth, wHeight, wLength)

			local angle = (w / wedgesInLayer) * math.pi * 2 + randomRange(-0.3, 0.3)
			local radiusOffset = layerRadius * randomRange(0.2, 0.6)
			wedge.Position = position
				+ Vector3.new(
					math.cos(angle) * radiusOffset,
					layerY + wHeight / 2,
					math.sin(angle) * radiusOffset
				)
			wedge.Orientation = Vector3.new(
				randomRange(-15, 15),
				math.deg(angle) + randomRange(0, 30),
				randomRange(-10, 10)
			)
			-- Green tones for foliage
			local greenIndex = randomInt(1, 2)
			wedge.Color = getPaletteColor(palette, greenIndex)
			wedge.Material = Enum.Material.SmoothPlastic
			wedge.Anchored = true
			wedge.Parent = model
		end

		-- Top cap for each layer (a small Part)
		local cap = Instance.new("Part")
		cap.Name = "FoliageCap" .. layer
		cap.Size = Vector3.new(layerRadius * 0.5, layerHeight * 0.3, layerRadius * 0.5)
		cap.Position = position + Vector3.new(0, layerY + layerHeight * 0.8, 0)
		cap.Orientation = Vector3.new(randomRange(-5, 5), randomRange(0, 90), randomRange(-5, 5))
		cap.Color = getPaletteColor(palette, 2)
		cap.Material = Enum.Material.SmoothPlastic
		cap.Anchored = true
		cap.Parent = model
	end

	-- Top foliage crown
	local crown = Instance.new("Part")
	crown.Name = "FoliageCrown"
	crown.Size = Vector3.new(cfg.foliageRadius * 0.4, cfg.foliageRadius * 0.5, cfg.foliageRadius * 0.4)
	crown.Position = position + Vector3.new(0, foliageStartY + foliageTotalHeight, 0)
	crown.Color = getPaletteColor(palette, 2)
	crown.Material = Enum.Material.SmoothPlastic
	crown.Anchored = true
	crown.Parent = model

	model:PivotTo(CFrame.new(position))
	self._eventBus:Emit("TreeGenerated", { model = model, position = position, config = cfg })
	return model
end

-- ==========================================
-- GenerateRock
-- ==========================================
function LowPolyGenerator:GenerateRock(position: Vector3, config: RockConfig?): Model
	local cfg = mergeConfig(defaultRockConfig(), config)
	local model = Instance.new("Model")
	model.Name = "LowPolyRock"

	local palette = self._palette
	math.randomseed(self._seed + math.floor(position.X * 100 + position.Z * 10))

	local numSegments = randomInt(4, 12)

	for i = 1, numSegments do
		local isWedge = math.random() < 0.4
		local size = cfg.size * randomRange(0.3, 0.8)
		local part: BasePart
		if isWedge then
			part = Instance.new("WedgePart")
		else
			part = Instance.new("Part")
		end
		part.Name = "Rock" .. i

		local sx = size * randomRange(0.6, 1.2)
		local sy = size * randomRange(0.4, 1.0) * (cfg.flatTop and 0.5 or 1.0)
		local sz = size * randomRange(0.6, 1.2)
		part.Size = Vector3.new(sx, sy, sz)

		-- Random offset from center, clustered
		local angle = randomRange(0, math.pi * 2)
		local dist = cfg.size * randomRange(0, 0.6)
		part.Position = position + Vector3.new(
			math.cos(angle) * dist,
			math.max(sy / 2, position.Y + sy / 2 - cfg.size * 0.3),
			math.sin(angle) * dist
		)

		-- Random rotation for jagged look
		part.Orientation = Vector3.new(
			randomRange(-cfg.jaggedness * 45, cfg.jaggedness * 45),
			randomRange(0, 360),
			randomRange(-cfg.jaggedness * 30, cfg.jaggedness * 30)
		)

		-- Gray or tan color
		local colorIndex = math.random() < 0.6 and 3 or 4
		part.Color = getPaletteColor(palette, colorIndex)
		part.Material = Enum.Material.Slate
		part.Anchored = true
		part.Parent = model
	end

	-- Base platform rock
	local base = Instance.new("Part")
	base.Name = "RockBase"
	base.Size = Vector3.new(cfg.size * 1.5, cfg.size * 0.3, cfg.size * 1.5)
	base.Position = position + Vector3.new(0, cfg.size * 0.15, 0)
	base.Color = getPaletteColor(palette, 4)
	base.Material = Enum.Material.Slate
	base.Anchored = true
	base.Parent = model

	model:PivotTo(CFrame.new(position))
	self._eventBus:Emit("RockGenerated", { model = model, position = position, config = cfg })
	return model
end

-- ==========================================
-- GenerateBuilding
-- ==========================================
function LowPolyGenerator:GenerateBuilding(position: Vector3, config: BuildingConfig?): Model
	local cfg = mergeConfig(defaultBuildingConfig(), config)
	local model = Instance.new("Model")
	model.Name = "LowPolyBuilding"

	local palette = self._palette
	math.randomseed(self._seed + math.floor(position.X * 1000 + position.Z * 100))

	local w = cfg.width
	local d = cfg.depth
	local storyHeight = 4
	local totalHeight = cfg.stories * storyHeight
	local wallThickness = 0.3

	-- Walls: 4-6 Parts forming a box per story
	for story = 1, cfg.stories do
		local baseY = position.Y + (story - 1) * storyHeight

		-- Front wall
		local frontWall = Instance.new("Part")
		frontWall.Name = "Wall_Front_S" .. story
		frontWall.Size = Vector3.new(w, storyHeight, wallThickness)
		frontWall.Position = position + Vector3.new(0, baseY + storyHeight / 2, d / 2 - wallThickness / 2)
		frontWall.Color = getPaletteColor(palette, 1)
		frontWall.Material = Enum.Material.SmoothPlastic
		frontWall.Anchored = true
		frontWall.Parent = model

		-- Back wall
		local backWall = Instance.new("Part")
		backWall.Name = "Wall_Back_S" .. story
		backWall.Size = Vector3.new(w, storyHeight, wallThickness)
		backWall.Position = position + Vector3.new(0, baseY + storyHeight / 2, -d / 2 + wallThickness / 2)
		backWall.Color = getPaletteColor(palette, 1)
		backWall.Material = Enum.Material.SmoothPlastic
		backWall.Anchored = true
		backWall.Parent = model

		-- Left wall
		local leftWall = Instance.new("Part")
		leftWall.Name = "Wall_Left_S" .. story
		leftWall.Size = Vector3.new(wallThickness, storyHeight, d - wallThickness * 2)
		leftWall.Position = position + Vector3.new(-w / 2 + wallThickness / 2, baseY + storyHeight / 2, 0)
		leftWall.Color = getPaletteColor(palette, 1)
		leftWall.Material = Enum.Material.SmoothPlastic
		leftWall.Anchored = true
		leftWall.Parent = model

		-- Right wall
		local rightWall = Instance.new("Part")
		rightWall.Name = "Wall_Right_S" .. story
		rightWall.Size = Vector3.new(wallThickness, storyHeight, d - wallThickness * 2)
		rightWall.Position = position + Vector3.new(w / 2 - wallThickness / 2, baseY + storyHeight / 2, 0)
		rightWall.Color = getPaletteColor(palette, 1)
		rightWall.Material = Enum.Material.SmoothPlastic
		rightWall.Anchored = true
		rightWall.Parent = model

		-- Floor/ceiling separator per story
		local floor = Instance.new("Part")
		floor.Name = "Floor_S" .. story
		floor.Size = Vector3.new(w - wallThickness * 2, 0.2, d - wallThickness * 2)
		floor.Position = position + Vector3.new(0, baseY, 0)
		floor.Color = getPaletteColor(palette, 3)
		floor.Material = Enum.Material.SmoothPlastic
		floor.Anchored = true
		floor.Parent = model

		-- Windows: small blue Parts on walls
		if cfg.windows then
			local windowsPerWall = math.max(1, math.floor(w / 3))
			for wi = 1, windowsPerWall do
				-- Front windows
				local win = Instance.new("Part")
				win.Name = "Window_S" .. story .. "_W" .. wi
				win.Size = Vector3.new(1.2, 1.2, 0.1)
				local winX = -w / 2 + (wi / (windowsPerWall + 1)) * w
				win.Position = position + Vector3.new(winX, baseY + storyHeight * 0.6, d / 2)
				win.Color = getPaletteColor(palette, 5)
				win.Material = Enum.Material.SmoothPlastic
				win.Anchored = true
				win.Parent = model
			end
		end

		-- Balcony on upper floors
		if cfg.balcony and story > 1 then
			local balcony = Instance.new("Part")
			balcony.Name = "Balcony_S" .. story
			balcony.Size = Vector3.new(w * 0.6, 0.2, d * 0.25)
			balcony.Position = position + Vector3.new(0, baseY, d / 2 + d * 0.125)
			balcony.Color = getPaletteColor(palette, 3)
			balcony.Material = Enum.Material.SmoothPlastic
			balcony.Anchored = true
			balcony.Parent = model

			-- Balcony railing
			local railing = Instance.new("Part")
			railing.Name = "BalconyRail_S" .. story
			railing.Size = Vector3.new(w * 0.6, 0.1, 0.1)
			railing.Position = position + Vector3.new(0, baseY + 1, d / 2 + d * 0.25)
			railing.Color = getPaletteColor(palette, 3)
			railing.Material = Enum.Material.SmoothPlastic
			railing.Anchored = true
			railing.Parent = model
		end
	end

	-- Door on ground floor
	if cfg.door then
		local door = Instance.new("Part")
		door.Name = "Door"
		door.Size = Vector3.new(2, 3, 0.2)
		door.Position = position + Vector3.new(0, 1.5, d / 2 + 0.1)
		door.Color = getPaletteColor(palette, 3)
		door.Material = Enum.Material.SmoothPlastic
		door.Anchored = true
		door.Parent = model
	end

	-- Roof
	if cfg.roofType == "peaked" then
		-- Two Wedges forming a peaked roof
		local roofHeight = math.min(w, d) * 0.35
		local roofY = position.Y + totalHeight

		local wedge1 = Instance.new("WedgePart")
		wedge1.Name = "RoofLeft"
		wedge1.Size = Vector3.new(w + 0.5, roofHeight, d + 0.5)
		wedge1.Position = position + Vector3.new(0, roofY + roofHeight / 2, 0)
		wedge1.Orientation = Vector3.new(0, 0, 90)
		wedge1.Color = getPaletteColor(palette, 4)
		wedge1.Material = Enum.Material.SmoothPlastic
		wedge1.Anchored = true
		wedge1.Parent = model

		local wedge2 = Instance.new("WedgePart")
		wedge2.Name = "RoofRight"
		wedge2.Size = Vector3.new(w + 0.5, roofHeight, d + 0.5)
		wedge2.Position = position + Vector3.new(0, roofY + roofHeight / 2, 0)
		wedge2.Orientation = Vector3.new(0, 0, -90)
		wedge2.Color = getPaletteColor(palette, 4)
		wedge2.Material = Enum.Material.SmoothPlastic
		wedge2.Anchored = true
		wedge2.Parent = model

	elseif cfg.roofType == "dome" then
		-- Stacked Wedges for dome effect
		local domeLayers = 3
		local domeBase = math.min(w, d)
		for i = 1, domeLayers do
			local domePart = Instance.new("Part")
			domePart.Name = "Dome" .. i
			local scale = 1 - (i - 1) / domeLayers
			domePart.Size = Vector3.new(domeBase * scale, domeBase * 0.2, domeBase * scale)
			domePart.Shape = Enum.PartType.Ball
			domePart.Position = position + Vector3.new(0, totalHeight + domeBase * 0.1 * i, 0)
			domePart.Color = getPaletteColor(palette, 4)
			domePart.Material = Enum.Material.SmoothPlastic
			domePart.Anchored = true
			domePart.Parent = model
		end
		-- Flat cap on top
		local cap = Instance.new("Part")
		cap.Name = "DomeCap"
		cap.Size = Vector3.new(domeBase * 0.3, 0.2, domeBase * 0.3)
		cap.Position = position + Vector3.new(0, totalHeight + domeBase * 0.4, 0)
		cap.Color = getPaletteColor(palette, 4)
		cap.Material = Enum.Material.SmoothPlastic
		cap.Anchored = true
		cap.Parent = model

	elseif cfg.roofType == "flat" then
		local flatRoof = Instance.new("Part")
		flatRoof.Name = "FlatRoof"
		flatRoof.Size = Vector3.new(w + 0.2, 0.3, d + 0.2)
		flatRoof.Position = position + Vector3.new(0, totalHeight + 0.15, 0)
		flatRoof.Color = getPaletteColor(palette, 3)
		flatRoof.Material = Enum.Material.SmoothPlastic
		flatRoof.Anchored = true
		flatRoof.Parent = model
	end

	model:PivotTo(CFrame.new(position))
	self._eventBus:Emit("BuildingGenerated", { model = model, position = position, config = cfg })
	return model
end

-- ==========================================
-- GenerateProp
-- ==========================================
function LowPolyGenerator:GenerateProp(position: Vector3, config: PropConfig?): Model
	local cfg = mergeConfig(defaultPropConfig(), config)
	local model = Instance.new("Model")
	local palette = self._palette
	math.randomseed(self._seed + math.floor(position.X * 500 + position.Z * 50))

	if cfg.propType == "crate" then
		model.Name = "LowPolyCrate"
		local s = 2 * cfg.scale
		-- 6 Parts forming a cube
		local faces = {
			{ name = "Bottom", size = Vector3.new(s, 0.1, s), pos = Vector3.new(0, -s / 2, 0) },
			{ name = "Top",    size = Vector3.new(s, 0.1, s), pos = Vector3.new(0, s / 2, 0) },
			{ name = "Front",  size = Vector3.new(s, s, 0.1), pos = Vector3.new(0, 0, s / 2) },
			{ name = "Back",   size = Vector3.new(s, s, 0.1), pos = Vector3.new(0, 0, -s / 2) },
			{ name = "Left",   size = Vector3.new(0.1, s, s), pos = Vector3.new(-s / 2, 0, 0) },
			{ name = "Right",  size = Vector3.new(0.1, s, s), pos = Vector3.new(s / 2, 0, 0) },
		}
		for _, face in ipairs(faces) do
			local part = Instance.new("Part")
			part.Name = face.name
			part.Size = face.size
			part.Position = position + face.pos
			part.Color = getPaletteColor(palette, 3)
			part.Material = Enum.Material.SmoothPlastic
			part.Anchored = true
			part.Parent = model
		end

	elseif cfg.propType == "barrel" then
		model.Name = "LowPolyBarrel"
		local r = 1 * cfg.scale
		local h = 2.5 * cfg.scale
		-- 8 Parts forming a cylinder approximation
		for i = 1, 8 do
			local part = Instance.new("Part")
			part.Name = "Barrel" .. i
			local angle = (i / 8) * math.pi * 2
			local thickness = r * 0.35
			part.Size = Vector3.new(thickness, h, r * 0.8)
			part.Position = position + Vector3.new(
				math.cos(angle) * r * 0.6,
				h / 2,
				math.sin(angle) * r * 0.6
			)
			part.Orientation = Vector3.new(0, math.deg(angle), 0)
			part.Color = getPaletteColor(palette, 2)
			part.Material = Enum.Material.SmoothPlastic
			part.Anchored = true
			part.Parent = model
		end

	elseif cfg.propType == "fence" then
		model.Name = "LowPolyFence"
		-- 3 Parts per section: 2 posts + 1 rail
		local sectionLength = 4 * cfg.scale
		-- Post 1
		local post1 = Instance.new("Part")
		post1.Name = "Post1"
		post1.Size = Vector3.new(0.2, 1.5, 0.2)
		post1.Position = position + Vector3.new(-sectionLength / 2, 0.75, 0)
		post1.Color = getPaletteColor(palette, 3)
		post1.Material = Enum.Material.SmoothPlastic
		post1.Anchored = true
		post1.Parent = model

		-- Post 2
		local post2 = Instance.new("Part")
		post2.Name = "Post2"
		post2.Size = Vector3.new(0.2, 1.5, 0.2)
		post2.Position = position + Vector3.new(sectionLength / 2, 0.75, 0)
		post2.Color = getPaletteColor(palette, 3)
		post2.Material = Enum.Material.SmoothPlastic
		post2.Anchored = true
		post2.Parent = model

		-- Rail
		local rail = Instance.new("Part")
		rail.Name = "Rail"
		rail.Size = Vector3.new(sectionLength, 0.1, 0.1)
		rail.Position = position + Vector3.new(0, 1.2, 0)
		rail.Color = getPaletteColor(palette, 3)
		rail.Material = Enum.Material.SmoothPlastic
		rail.Anchored = true
		rail.Parent = model

	elseif cfg.propType == "lamp" then
		model.Name = "LowPolyLamp"
		-- Post (1 Part)
		local post = Instance.new("Part")
		post.Name = "LampPost"
		post.Size = Vector3.new(0.2, 4 * cfg.scale, 0.2)
		post.Position = position + Vector3.new(0, 2 * cfg.scale, 0)
		post.Color = getPaletteColor(palette, 2)
		post.Material = Enum.Material.SmoothPlastic
		post.Anchored = true
		post.Parent = model

		-- Lamp head arm (1 Part)
		local arm = Instance.new("Part")
		arm.Name = "LampArm"
		arm.Size = Vector3.new(0.8 * cfg.scale, 0.15, 0.15)
		arm.Position = position + Vector3.new(0.4 * cfg.scale, 4 * cfg.scale, 0)
		arm.Color = getPaletteColor(palette, 2)
		arm.Material = Enum.Material.SmoothPlastic
		arm.Anchored = true
		arm.Parent = model

		-- Lamp head housing (4 Parts forming a small box)
		local lampHeadY = 4 * cfg.scale
		local lampParts = {
			{ name = "HeadTop",    size = Vector3.new(0.5, 0.1, 0.5), pos = Vector3.new(0.8 * cfg.scale, lampHeadY + 0.15, 0) },
			{ name = "HeadFront",  size = Vector3.new(0.5, 0.3, 0.1), pos = Vector3.new(0.8 * cfg.scale, lampHeadY, 0.25) },
			{ name = "HeadBack",   size = Vector3.new(0.5, 0.3, 0.1), pos = Vector3.new(0.8 * cfg.scale, lampHeadY, -0.25) },
			{ name = "HeadLeft",   size = Vector3.new(0.1, 0.3, 0.5), pos = Vector3.new(0.55 * cfg.scale, lampHeadY, 0) },
			{ name = "HeadRight",  size = Vector3.new(0.1, 0.3, 0.5), pos = Vector3.new(1.05 * cfg.scale, lampHeadY, 0) },
		}
		for _, lp in ipairs(lampParts) do
			local part = Instance.new("Part")
			part.Name = lp.name
			part.Size = lp.size
			part.Position = position + lp.pos
			part.Color = getPaletteColor(palette, 2)
			part.Material = Enum.Material.SmoothPlastic
			part.Anchored = true
			part.Parent = model
		end

		-- Glowing Part
		local glow = Instance.new("Part")
		glow.Name = "LampGlow"
		glow.Size = Vector3.new(0.3, 0.2, 0.3)
		glow.Position = position + Vector3.new(0.8 * cfg.scale, lampHeadY - 0.05, 0)
		glow.Color = Color3.fromRGB(255, 220, 100)
		glow.Material = Enum.Material.Neon
		glow.Anchored = true
		glow.Parent = model

		-- Base
		local base = Instance.new("Part")
		base.Name = "LampBase"
		base.Size = Vector3.new(0.6, 0.1, 0.6)
		base.Position = position + Vector3.new(0, 0.05, 0)
		base.Color = getPaletteColor(palette, 3)
		base.Material = Enum.Material.SmoothPlastic
		base.Anchored = true
		base.Parent = model

	elseif cfg.propType == "sign" then
		model.Name = "LowPolySign"
		-- 2 vertical posts
		local post1 = Instance.new("Part")
		post1.Name = "PostLeft"
		post1.Size = Vector3.new(0.15, 2.5 * cfg.scale, 0.15)
		post1.Position = position + Vector3.new(-0.8 * cfg.scale, 1.25 * cfg.scale, 0)
		post1.Color = getPaletteColor(palette, 3)
		post1.Material = Enum.Material.SmoothPlastic
		post1.Anchored = true
		post1.Parent = model

		local post2 = Instance.new("Part")
		post2.Name = "PostRight"
		post2.Size = Vector3.new(0.15, 2.5 * cfg.scale, 0.15)
		post2.Position = position + Vector3.new(0.8 * cfg.scale, 1.25 * cfg.scale, 0)
		post2.Color = getPaletteColor(palette, 3)
		post2.Material = Enum.Material.SmoothPlastic
		post2.Anchored = true
		post2.Parent = model

		-- Sign board
		local board = Instance.new("Part")
		board.Name = "SignBoard"
		board.Size = Vector3.new(2 * cfg.scale, 1 * cfg.scale, 0.1)
		board.Position = position + Vector3.new(0, 2 * cfg.scale, 0)
		board.Color = getPaletteColor(palette, 4)
		board.Material = Enum.Material.SmoothPlastic
		board.Anchored = true
		board.Parent = model

	elseif cfg.propType == "campfire" then
		model.Name = "LowPolyCampfire"
		-- 8 Parts: 6 stones in a circle + 1 wood pile + 1 glowing orange Part
		for i = 1, 6 do
			local stone = Instance.new("Part")
			stone.Name = "Stone" .. i
			local angle = (i / 6) * math.pi * 2
			stone.Size = Vector3.new(
				0.4 * cfg.scale * randomRange(0.7, 1.3),
				0.3 * cfg.scale * randomRange(0.7, 1.0),
				0.4 * cfg.scale * randomRange(0.7, 1.3)
			)
			stone.Position = position + Vector3.new(
				math.cos(angle) * 0.8 * cfg.scale,
				stone.Size.Y / 2,
				math.sin(angle) * 0.8 * cfg.scale
			)
			stone.Orientation = Vector3.new(
				randomRange(-10, 10),
				randomRange(0, 360),
				randomRange(-10, 10)
			)
			stone.Color = getPaletteColor(palette, 3)
			stone.Material = Enum.Material.Slate
			stone.Anchored = true
			stone.Parent = model
		end

		-- Wood pile (1 Part)
		local wood = Instance.new("Part")
		wood.Name = "WoodPile"
		wood.Size = Vector3.new(0.8 * cfg.scale, 0.3 * cfg.scale, 0.8 * cfg.scale)
		wood.Position = position + Vector3.new(0, 0.15 * cfg.scale, 0)
		wood.Color = getPaletteColor(palette, 3)
		wood.Material = Enum.Material.Wood
		wood.Anchored = true
		wood.Parent = model

		-- Glowing fire Part
		local fire = Instance.new("Part")
		fire.Name = "FireGlow"
		fire.Size = Vector3.new(0.5 * cfg.scale, 0.6 * cfg.scale, 0.5 * cfg.scale)
		fire.Position = position + Vector3.new(0, 0.5 * cfg.scale, 0)
		fire.Color = Color3.fromRGB(255, 127, 0)
		fire.Material = Enum.Material.Neon
		fire.Anchored = true
		fire.Parent = model
	end

	model:PivotTo(CFrame.new(position))
	self._eventBus:Emit("PropGenerated", { model = model, position = position, config = cfg })
	return model
end

return LowPolyGenerator
