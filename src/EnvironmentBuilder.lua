--!strict
-- EnvironmentBuilder.lua
-- Scene composition: terrain + low-poly assets + lighting + palette.
-- Handles placement, cleanup, lighting presets, and scene statistics.

local Lighting = game:GetService("Lighting")

export type SceneConfig = {
	seed: number,
	size: Vector2,
	paletteName: string,
	styleName: string,
	terrainEnabled: boolean,
	treeDensity: number,
	rockDensity: number,
	buildingCount: number,
	propDensity: number,
	waterLevel: number,
}

export type Scene = {
	root: Folder,
	terrainFolder: Folder,
	objectFolder: Folder,
	lightFolder: Folder,
	objectCount: number,
	partCount: number,
	-- Asset arrays for LOD registration and external iteration
	trees: { Model },
	rocks: { Model },
	buildings: { Model },
	props: { Model },
	-- Scene metadata (mirrors SceneConfig for easy access post-build)
	seed: number,
	sizeX: number,
	sizeZ: number,
	paletteName: string,
	styleName: string,
}

-- Forward-declared types for optional dependencies
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

export type PaletteSystem = {
	CreatePalette: (self: PaletteSystem, name: string, colors: { Color3 }) -> ColorPalette,
	GetColor: (self: PaletteSystem, paletteName: string, index: number) -> Color3,
	ShiftHue: (self: PaletteSystem, color: Color3, shiftDegrees: number) -> Color3,
	Darken: (self: PaletteSystem, color: Color3, amount: number) -> Color3,
	Lighten: (self: PaletteSystem, color: Color3, amount: number) -> Color3,
	ApplyToModel: (self: PaletteSystem, model: Model, paletteName: string) -> (),
	GetPalette: (self: PaletteSystem, name: string) -> ColorPalette?,
	ListPalettes: (self: PaletteSystem) -> { string },
}

export type TreeConfig = {
	height: number,
	trunkWidth: number,
	foliageRadius: number,
	foliageLayers: number,
	foliageDensity: number,
	paletteIndex: number,
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
	paletteIndex: number,
}

export type LowPolyGenerator = {
	GenerateTree: (self: LowPolyGenerator, position: Vector3, config: TreeConfig?) -> Model,
	GenerateRock: (self: LowPolyGenerator, position: Vector3, config: RockConfig?) -> Model,
	GenerateBuilding: (self: LowPolyGenerator, position: Vector3, config: BuildingConfig?) -> Model,
	GenerateProp: (self: LowPolyGenerator, position: Vector3, config: PropConfig?) -> Model,
	SetPalette: (self: LowPolyGenerator, palette: ColorPalette) -> (),
}

export type TerrainConfig = {
	chunkSize: number,
	maxHeight: number,
	seaLevel: number,
	erosion: boolean,
	erosionIterations: number,
}

export type TerrainGenerator = {
	GenerateChunk: (self: TerrainGenerator, cx: number, cz: number) -> {
		cx: number,
		cz: number,
		heightmap: { { number } },
		surfaceY: { { number } },
		biomeMap: { { string } },
	},
	ApplyToTerrain: (self: TerrainGenerator, chunk: any) -> (),
	GetHeightAt: (self: TerrainGenerator, worldX: number, worldZ: number) -> number,
	SetTerrainConfig: (self: TerrainGenerator, config: TerrainConfig) -> (),
}

type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
	Once: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
}

export type EnvironmentBuilder = {
	BuildScene: (self: EnvironmentBuilder, config: SceneConfig) -> Scene,
	PlaceAsset: (self: EnvironmentBuilder, assetType: string, position: Vector3, config: any?) -> Model,
	ClearScene: (self: EnvironmentBuilder) -> (),
	SetLighting: (self: EnvironmentBuilder, styleName: string) -> (),
	GetSceneStats: (self: EnvironmentBuilder) -> { objectCount: number, partCount: number },
}

-- ---------------------------------------------------------------------------
-- Default configs used when optional generators are missing
-- ---------------------------------------------------------------------------

local DEFAULT_SCENE_CONFIG: SceneConfig = {
	seed = 42,
	size = Vector2.new(500, 500),
	paletteName = "Minimalist",
	styleName = "Minimalist",
	terrainEnabled = true,
	treeDensity = 5,
	rockDensity = 3,
	buildingCount = 2,
	propDensity = 8,
	waterLevel = 0,
}

local DEFAULT_TREE_CONFIG: TreeConfig = {
	height = 12,
	trunkWidth = 1,
	foliageRadius = 4,
	foliageLayers = 3,
	foliageDensity = 0.7,
	paletteIndex = 1,
}

local DEFAULT_ROCK_CONFIG: RockConfig = {
	size = 6,
	jaggedness = 0.6,
	segments = 5,
	flatTop = false,
}

local DEFAULT_BUILDING_CONFIG: BuildingConfig = {
	width = 12,
	depth = 10,
	stories = 2,
	roofType = "peaked",
	windows = true,
	door = true,
	balcony = false,
}

local DEFAULT_PROP_CONFIG: PropConfig = {
	propType = "crate",
	scale = 1,
	paletteIndex = 1,
}

-- Lighting presets keyed by style name
local LIGHTING_PRESETS: { [string]: {
	clockTime: number,
	brightness: number,
	ambient: Color3,
	outdoorAmbient: Color3,
	fogColor: Color3?,
	fogStart: number?,
	fogEnd: number?,
	fogEnabled: boolean,
} } = {
	Minimalist = {
		clockTime = 14,
		brightness = 2,
		ambient = Color3.new(0.8, 0.8, 0.8),
		outdoorAmbient = Color3.new(1, 1, 1),
		fogColor = nil,
		fogStart = nil,
		fogEnd = nil,
		fogEnabled = false,
	},
	Forest = {
		clockTime = 12,
		brightness = 1.5,
		ambient = Color3.new(0.4, 0.6, 0.3),
		outdoorAmbient = Color3.new(0.6, 0.8, 0.5),
		fogColor = Color3.new(0.7, 0.8, 0.7),
		fogStart = 200,
		fogEnd = 800,
		fogEnabled = true,
	},
	Sunset = {
		clockTime = 18,
		brightness = 1.2,
		ambient = Color3.new(0.8, 0.5, 0.3),
		outdoorAmbient = Color3.new(0.9, 0.6, 0.4),
		fogColor = Color3.new(1, 0.6, 0.3),
		fogStart = 100,
		fogEnd = 600,
		fogEnabled = true,
	},
	Ocean = {
		clockTime = 12,
		brightness = 1.8,
		ambient = Color3.new(0.3, 0.4, 0.6),
		outdoorAmbient = Color3.new(0.5, 0.7, 0.9),
		fogColor = Color3.new(0.6, 0.8, 1),
		fogStart = 150,
		fogEnd = 700,
		fogEnabled = true,
	},
}

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local EnvironmentBuilder = {}
EnvironmentBuilder.__index = EnvironmentBuilder

--- Create a new EnvironmentBuilder.
-- @param eventBus   Required. Typed EventBus for cross-module events.
-- @param terrainGen Optional. TerrainGenerator instance for terrain creation.
-- @param lowPolyGen Optional. LowPolyGenerator instance for asset generation.
-- @param paletteSys Optional. ColorPaletteSystem instance for palette application.
-- @return           A new EnvironmentBuilder instance.
function EnvironmentBuilder.new(
	eventBus: EventBus,
	terrainGen: TerrainGenerator?,
	lowPolyGen: LowPolyGenerator?,
	paletteSys: PaletteSystem?
): EnvironmentBuilder
	local self = setmetatable({}, EnvironmentBuilder)

	self._eventBus = eventBus
	self._terrainGen = terrainGen
	self._lowPolyGen = lowPolyGen
	self._paletteSys = paletteSys
	self._currentScene = nil :: Scene?
	self._rng = Random.new(42)
	self._placements = {} :: { { position: Vector3, radius: number } }

	return self
end

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

--- Seed the internal RNG from the scene config seed.
function EnvironmentBuilder:_seedRNG(seed: number)
	self._rng = Random.new(seed)
end

--- Get a random position within the scene bounds at a given Y height.
function EnvironmentBuilder:_randomPosition(sizeX: number, sizeZ: number, y: number): Vector3
	local x = self._rng:NextNumber(-sizeX / 2, sizeX / 2)
	local z = self._rng:NextNumber(-sizeZ / 2, sizeZ / 2)
	return Vector3.new(x, y, z)
end

--- Check if a position overlaps with any already-placed object.
function EnvironmentBuilder:_isOverlapping(pos: Vector3, radius: number): boolean
	for _, placed in ipairs(self._placements) do
		local dist = (pos - placed.position).Magnitude
		if dist < (radius + placed.radius) then
			return true
		end
	end
	return false
end

--- Record a placement so future placements can avoid overlap.
function EnvironmentBuilder:_recordPlacement(pos: Vector3, radius: number)
	table.insert(self._placements, { position = pos, radius = radius })
end

--- Sample terrain height at (worldX, worldZ) using the terrain generator.
-- Falls back to a simple noise-based height when no generator is available.
function EnvironmentBuilder:_getTerrainHeight(worldX: number, worldZ: number): number
	if self._terrainGen then
		return self._terrainGen:GetHeightAt(worldX, worldZ)
	end
	-- Fallback: flat ground at y=0
	return 0
end

--- Find a random surface position that doesn't overlap existing placements.
function EnvironmentBuilder:_findValidPosition(
	sizeX: number,
	sizeZ: number,
	objectRadius: number,
	maxAttempts: number?
): Vector3?
	local attempts = maxAttempts or 50
	for _ = 1, attempts do
		local flatPos = self:_randomPosition(sizeX, sizeZ, 0)
		local height = self:_getTerrainHeight(flatPos.X, flatPos.Z)
		local pos = Vector3.new(flatPos.X, height, flatPos.Z)
		if not self:_isOverlapping(pos, objectRadius) then
			self:_recordPlacement(pos, objectRadius)
			return pos
		end
	end
	return nil
end

--- Count all BaseParts that are descendants of `instance`.
function EnvironmentBuilder:_countParts(instance: Instance): number
	local count = 0
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

--- Build a default tree Model when LowPolyGenerator is not available.
function EnvironmentBuilder:_buildDefaultTree(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "DefaultTree"

	-- Trunk
	local trunk = Instance.new("Part")
	trunk.Name = "Trunk"
	trunk.Shape = Enum.PartType.Cylinder
	trunk.Size = Vector3.new(8, 1, 1)
	trunk.Orientation = Vector3.new(0, 0, 90)
	trunk.Position = position + Vector3.new(0, 4, 0)
	trunk.Anchored = true
	trunk.Material = Enum.Material.SmoothPlastic
	trunk.Color = Color3.fromRGB(101, 67, 33)
	trunk.Parent = model

	-- Foliage
	local foliage = Instance.new("Part")
	foliage.Name = "Foliage"
	foliage.Shape = Enum.PartType.Ball
	foliage.Size = Vector3.new(8, 8, 8)
	foliage.Position = position + Vector3.new(0, 9, 0)
	foliage.Anchored = true
	foliage.Material = Enum.Material.SmoothPlastic
	foliage.Color = Color3.fromRGB(34, 139, 34)
	foliage.Parent = model

	return model
end

--- Build a default rock Model when LowPolyGenerator is not available.
function EnvironmentBuilder:_buildDefaultRock(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "DefaultRock"

	local rock = Instance.new("Part")
	rock.Name = "Rock"
	rock.Shape = Enum.PartType.Ball
	rock.Size = Vector3.new(4, 3, 4)
	rock.Position = position + Vector3.new(0, 1.5, 0)
	rock.Anchored = true
	rock.Material = Enum.Material.Slate
	rock.Color = Color3.fromRGB(128, 128, 128)
	rock.Parent = model

	return model
end

--- Build a default building Model when LowPolyGenerator is not available.
function EnvironmentBuilder:_buildDefaultBuilding(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "DefaultBuilding"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = Enum.PartType.Block
	body.Size = Vector3.new(10, 12, 10)
	body.Position = position + Vector3.new(0, 6, 0)
	body.Anchored = true
	body.Material = Enum.Material.SmoothPlastic
	body.Color = Color3.fromRGB(200, 180, 160)
	body.Parent = model

	local roof = Instance.new("Part")
	roof.Name = "Roof"
	roof.Shape = Enum.PartType.Block
	roof.Size = Vector3.new(12, 2, 12)
	roof.Position = position + Vector3.new(0, 13, 0)
	roof.Anchored = true
	roof.Material = Enum.Material.SmoothPlastic
	roof.Color = Color3.fromRGB(160, 80, 60)
	roof.Parent = model

	return model
end

--- Build a default prop Model when LowPolyGenerator is not available.
function EnvironmentBuilder:_buildDefaultProp(position: Vector3, propType: string?): Model
	local model = Instance.new("Model")
	model.Name = "DefaultProp_" .. (propType or "crate")

	local prop = Instance.new("Part")
	prop.Name = "Prop"
	prop.Shape = Enum.PartType.Block
	prop.Size = Vector3.new(2, 2, 2)
	prop.Position = position + Vector3.new(0, 1, 0)
	prop.Anchored = true
	prop.Material = Enum.Material.Wood
	prop.Color = Color3.fromRGB(160, 120, 80)
	prop.Parent = model

	return model
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Place a single asset of the given type at the specified position.
-- @param assetType  One of: "tree", "rock", "building", "prop"
-- @param position   World position (Vector3) to place the asset
-- @param config     Optional asset-specific configuration table
-- @return           The created Model instance
function EnvironmentBuilder:PlaceAsset(assetType: string, position: Vector3, config: any?): Model
	local model: Model

	if assetType == "tree" then
		if self._lowPolyGen then
			model = self._lowPolyGen:GenerateTree(position, config or DEFAULT_TREE_CONFIG)
		else
			model = self:_buildDefaultTree(position)
		end
		self._eventBus:Emit("AssetPlaced", { assetType = "tree", model = model, position = position })
	elseif assetType == "rock" then
		if self._lowPolyGen then
			model = self._lowPolyGen:GenerateRock(position, config or DEFAULT_ROCK_CONFIG)
		else
			model = self:_buildDefaultRock(position)
		end
		self._eventBus:Emit("AssetPlaced", { assetType = "rock", model = model, position = position })
	elseif assetType == "building" then
		if self._lowPolyGen then
			model = self._lowPolyGen:GenerateBuilding(position, config or DEFAULT_BUILDING_CONFIG)
		else
			model = self:_buildDefaultBuilding(position)
		end
		self._eventBus:Emit("AssetPlaced", { assetType = "building", model = model, position = position })
	elseif assetType == "prop" then
		if self._lowPolyGen then
			model = self._lowPolyGen:GenerateProp(position, config or DEFAULT_PROP_CONFIG)
		else
			model = self:_buildDefaultProp(position, config and config.propType)
		end
		self._eventBus:Emit("AssetPlaced", { assetType = "prop", model = model, position = position })
	else
		error("[EnvironmentBuilder] Unknown assetType: " .. tostring(assetType))
	end

	return model
end

--- Set lighting properties on the Roblox Lighting service.
-- @param styleName  One of: "Minimalist", "Forest", "Sunset", "Ocean"
function EnvironmentBuilder:SetLighting(styleName: string)
	local preset = LIGHTING_PRESETS[styleName]
	if not preset then
		warn("[EnvironmentBuilder] Unknown lighting style: " .. tostring(styleName) .. ", defaulting to Minimalist")
		preset = LIGHTING_PRESETS["Minimalist"]
	end

	Lighting.ClockTime = preset.clockTime
	Lighting.Brightness = preset.brightness
	Lighting.Ambient = preset.ambient
	Lighting.OutdoorAmbient = preset.outdoorAmbient

	if preset.fogEnabled then
		Lighting.FogColor = preset.fogColor or Color3.new(0.75, 0.75, 0.75)
		Lighting.FogStart = preset.fogStart or 0
		Lighting.FogEnd = preset.fogEnd or 1000
	else
		Lighting.FogColor = Color3.new(0.75, 0.75, 0.75)
		Lighting.FogStart = 0
		Lighting.FogEnd = 100000
	end

	self._eventBus:Emit("LightingSet", {
		styleName  = styleName,
		preset     = preset,
		brightness = preset.brightness,
		ambient    = preset.ambient,
	})
end

--- Remove the current scene and reset lighting to defaults.
function EnvironmentBuilder:ClearScene()
	local objectsRemoved = 0
	if self._currentScene then
		objectsRemoved = self._currentScene.objectCount
		local root = self._currentScene.root
		if root and root.Parent then
			root:Destroy()
		end
		self._currentScene = nil
	end

	self._placements = {}

	-- Reset lighting to default
	Lighting.ClockTime = 14
	Lighting.Brightness = 1
	Lighting.Ambient = Color3.new(0.5, 0.5, 0.5)
	Lighting.OutdoorAmbient = Color3.new(0.5, 0.5, 0.5)
	Lighting.FogColor = Color3.new(0.75, 0.75, 0.75)
	Lighting.FogStart = 0
	Lighting.FogEnd = 100000

	self._eventBus:Emit("SceneCleared", { objectsRemoved = objectsRemoved })
end

--- Count objects and parts in the current scene.
-- @return  A table with `objectCount` (Model count) and `partCount` (BasePart count)
function EnvironmentBuilder:GetSceneStats(): { objectCount: number, partCount: number }
	if not self._currentScene then
		return { objectCount = 0, partCount = 0 }
	end

	local root = self._currentScene.root
	if not root or not root.Parent then
		return { objectCount = 0, partCount = 0 }
	end

	local objectCount = 0
	local partCount = 0

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Model") then
			objectCount += 1
		elseif descendant:IsA("BasePart") then
			partCount += 1
		end
	end

	return { objectCount = objectCount, partCount = partCount }
end

--- Build a full scene from a SceneConfig.
-- 1. Create root folder structure
-- 2. Generate terrain (if enabled and generator available)
-- 3. Scatter trees, rocks, props
-- 4. Place buildings (non-overlapping)
-- 5. Apply palette
-- 6. Set lighting
-- @param config  SceneConfig describing the desired scene
-- @return        A Scene table with stats and folder references
function EnvironmentBuilder:BuildScene(config: SceneConfig): Scene
	-- Clear any existing scene first
	self:ClearScene()

	-- Seed RNG
	self:_seedRNG(config.seed)

	-- 1. Create root folder
	local rootName = "LowPolyScene_" .. tostring(config.seed)
	local existing = workspace:FindFirstChild(rootName)
	if existing then
		existing:Destroy()
	end

	local root = Instance.new("Folder")
	root.Name = rootName
	root.Parent = workspace

	local terrainFolder = Instance.new("Folder")
	terrainFolder.Name = "Terrain"
	terrainFolder.Parent = root

	local objectFolder = Instance.new("Folder")
	objectFolder.Name = "Objects"
	objectFolder.Parent = root

	local lightFolder = Instance.new("Folder")
	lightFolder.Name = "Lighting"
	lightFolder.Parent = root

	self._placements = {}

	local sizeX = config.size.X
	local sizeZ = config.size.Y

	-- 2. Generate terrain
	if config.terrainEnabled and self._terrainGen then
		-- Generate enough chunks to cover the scene size
		local chunkSize = 64 -- default chunk size assumption
		local chunksX = math.ceil(sizeX / chunkSize)
		local chunksZ = math.ceil(sizeZ / chunkSize)

		for cx = 0, chunksX - 1 do
			for cz = 0, chunksZ - 1 do
				local chunk = self._terrainGen:GenerateChunk(cx, cz)
				self._terrainGen:ApplyToTerrain(chunk)
			end
		end
	elseif config.terrainEnabled then
		-- Fallback: create a flat baseplate-like terrain representation
		local base = Instance.new("Part")
		base.Name = "TerrainBase"
		base.Size = Vector3.new(sizeX, 1, sizeZ)
		base.Position = Vector3.new(0, -0.5, 0)
		base.Anchored = true
		base.Material = Enum.Material.Grass
		base.Color = Color3.fromRGB(85, 170, 85)
		base.Parent = terrainFolder
	end

	-- Asset tracking arrays (returned in Scene for LOD registration etc.)
	local trees:     { Model } = {}
	local rocks:     { Model } = {}
	local buildings: { Model } = {}
	local props:     { Model } = {}

	-- 3. Scatter trees
	local treeCount = math.floor((sizeX * sizeZ) / 10000 * config.treeDensity)
	for _ = 1, treeCount do
		local pos = self:_findValidPosition(sizeX, sizeZ, 8)
		if pos then
			local treeModel = self:PlaceAsset("tree", pos, DEFAULT_TREE_CONFIG)
			treeModel.Parent = objectFolder
			table.insert(trees, treeModel)
		end
	end

	-- 4. Scatter rocks
	local rockCount = math.floor((sizeX * sizeZ) / 10000 * config.rockDensity)
	for _ = 1, rockCount do
		local pos = self:_findValidPosition(sizeX, sizeZ, 5)
		if pos then
			local rockModel = self:PlaceAsset("rock", pos, DEFAULT_ROCK_CONFIG)
			rockModel.Parent = objectFolder
			table.insert(rocks, rockModel)
		end
	end

	-- 5. Place buildings (non-overlapping, larger clearance)
	for _ = 1, config.buildingCount do
		local pos = self:_findValidPosition(sizeX, sizeZ, 20)
		if pos then
			local buildingModel = self:PlaceAsset("building", pos, DEFAULT_BUILDING_CONFIG)
			buildingModel.Parent = objectFolder
			table.insert(buildings, buildingModel)
		end
	end

	-- 6. Scatter props
	local propCount = math.floor((sizeX * sizeZ) / 10000 * config.propDensity)
	local propTypes = { "crate", "barrel", "fence", "lamp", "sign", "campfire" }
	for _ = 1, propCount do
		local pos = self:_findValidPosition(sizeX, sizeZ, 2)
		if pos then
			local idx = math.clamp(self._rng:NextInteger(1, #propTypes), 1, #propTypes)
			local propCfg = table.clone(DEFAULT_PROP_CONFIG)
			propCfg.propType = propTypes[idx]
			local propModel = self:PlaceAsset("prop", pos, propCfg)
			propModel.Parent = objectFolder
			table.insert(props, propModel)
		end
	end

	-- 7. Apply palette to all objects
	if self._paletteSys then
		for _, child in ipairs(objectFolder:GetChildren()) do
			if child:IsA("Model") then
				pcall(function()
					self._paletteSys:ApplyToModel(child :: Model, config.paletteName)
				end)
			end
		end
		for _, child in ipairs(terrainFolder:GetChildren()) do
			if child:IsA("Model") then
				pcall(function()
					self._paletteSys:ApplyToModel(child :: Model, config.paletteName)
				end)
			end
		end
	end

	-- 8. Set lighting
	self:SetLighting(config.styleName)

	-- Compute stats
	local stats = self:GetSceneStats()

	-- Build and store scene (includes asset arrays for LOD registration)
	local scene: Scene = {
		root          = root,
		terrainFolder = terrainFolder,
		objectFolder  = objectFolder,
		lightFolder   = lightFolder,
		objectCount   = stats.objectCount,
		partCount     = stats.partCount,
		trees         = trees,
		rocks         = rocks,
		buildings     = buildings,
		props         = props,
		seed          = config.seed,
		sizeX         = sizeX,
		sizeZ         = sizeZ,
		paletteName   = config.paletteName,
		styleName     = config.styleName,
	}

	self._currentScene = scene

	self._eventBus:Emit("SceneBuilt", {
		scene       = scene,
		config      = config,
		stats       = stats,
		-- Flat fields for convenient subscriber access
		seed        = config.seed,
		sizeX       = sizeX,
		sizeZ       = sizeZ,
		objectCount = stats.objectCount,
		partCount   = stats.partCount,
		paletteName = config.paletteName,
		styleName   = config.styleName,
	})

	return scene
end

return EnvironmentBuilder
