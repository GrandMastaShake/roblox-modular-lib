--!strict
-- ExampleLowPolyScene.lua
-- Comprehensive integration demo showing the full low-poly asset pipeline:
--   ColorPaletteSystem -> LowPolyGenerator -> EnvironmentBuilder -> StylePresets -> LODSystem
--
-- WHAT THIS FILE DEMONSTRATES:
--   1. How to instantiate every low-poly module with the shared EventBus via DI.
--   2. How to build a complete low-poly scene (terrain, trees, rocks, buildings, props).
--   3. How to apply color palettes and style presets for visual cohesion.
--   4. How to register scene objects with the LODSystem for automatic level-of-detail.
--   5. How to cycle palettes at runtime to demonstrate dynamic theming.
--   6. How to subscribe to cross-module events for debugging and analytics.
--
-- ARCHITECTURE NOTES:
--   - No low-poly module imports another module directly. All cross-module
--     communication flows through the shared EventBus.
--   - EnvironmentBuilder is the orchestrator; it calls each subsystem in pipeline order.
--   - LODSystem manages performance by simplifying distant assets automatically.
--   - ColorPaletteSystem ensures every asset shares a cohesive color theme.
--   - StylePresets control the visual style (flat-shaded, voxel, hand-painted, etc.).

-- =============================================================================
-- REQUIRE PATHS
-- =============================================================================

-- Core services (shared infrastructure used by ALL modules)
local EventBus = require(script.Parent.src.Core.EventBus)
local Config = require(script.Parent.src.Core.Config)

-- Low-poly pipeline modules (all depend on Core via DI; never on each other directly)
local ColorPaletteSystem = require(script.Parent.src.ColorPaletteSystem)
local LowPolyGenerator = require(script.Parent.src.LowPolyGenerator)
local EnvironmentBuilder = require(script.Parent.src.EnvironmentBuilder)
local StylePresets = require(script.Parent.src.StylePresets)
local LODSystem = require(script.Parent.src.LODSystem)

-- =============================================================================
-- SHARED SERVICE SETUP (The "wiring harness")
-- =============================================================================

-- EventBus: the central nervous system. Every module gets the SAME bus so they
-- can communicate by event name without direct references.
local bus = EventBus.new()

-- Config: global tuning values for the low-poly scene.
local config = Config.new({
	-- Scene generation seed: same seed -> reproducible scene layout.
	seed = 42,

	-- Scene size in studs (X, Z).  400x400 = a sizeable playable area.
	sceneSizeX = 400,
	sceneSizeZ = 400,

	-- Asset density controls (objects per 100x100 stud area)
	treeDensity = 3,
	rockDensity = 2,
	propDensity = 4,

	-- Number of buildings to place
	buildingCount = 2,

	-- Terrain and water
	terrainEnabled = true,
	waterLevel = 16,

	-- Visual style
	paletteName = "Forest",
	styleName = "FlatShaded",

	-- LOD configuration
	lodEnabled = true,
	lodUpdateInterval = 1.0, -- seconds between LOD evaluations

	-- Palette cycling demo
	paletteCycleEnabled = true,
	paletteCycleInterval = 10, -- seconds between palette switches
})

-- =============================================================================
-- MODULE INSTANTIATION (Dependency Injection)
-- =============================================================================
-- Each module receives only the shared services it needs.  This satisfies the
-- "zero hard coupling" rule: you can swap any module or mock the bus in tests.

-- ColorPaletteSystem: manages limited color palettes for visual cohesion.
-- Every asset in the scene will pull colors from the active palette.
local paletteSys = ColorPaletteSystem.new(bus)

-- LowPolyGenerator: procedural low-poly mesh generation from primitives.
-- Creates trees, rocks, buildings, and props from Roblox Parts/Wedges.
local lowPolyGen = LowPolyGenerator.new(bus)

-- StylePresets: pre-built visual style configurations.
-- Controls material, bevel, color variation, shadow intensity, and outlines.
local stylePresets = StylePresets.new(bus)

-- EnvironmentBuilder: the scene orchestrator.
-- Composes terrain + scattered assets + lighting + palette into a unified scene.
local envBuilder = EnvironmentBuilder.new(
	bus,            -- eventBus        (required)
	nil,            -- terrainGen      (optional; uses default)
	lowPolyGen,     -- lowPolyGen      (required for asset generation)
	paletteSys      -- paletteSys      (required for color theming)
)

-- LODSystem: level-of-detail management for performance.
-- Simplifies distant assets by reducing part count or swapping to billboards.
local lodSys = LODSystem.new(bus)

-- =============================================================================
-- EVENT SUBSCRIPTIONS (Cross-module wiring)
-- =============================================================================
-- Because modules emit events and never call each other directly, we wire
-- reactions HERE in the composition root.  This is the only file that knows
-- about ALL modules, making the system easy to refactor.

-- ---------------------------------------------------------------------------
-- ColorPaletteSystem events
-- ---------------------------------------------------------------------------
bus:Subscribe("PaletteCreated", function(data)
	print(string.format(
		"[Palette] Created palette '%s' with %d colors",
		data.name, #data.palette.colors
	))
end)

bus:Subscribe("PaletteApplied", function(data)
	-- data.modelName and data.partsRecolored are now emitted by ColorPaletteSystem
	print(string.format(
		"[Palette] Applied palette '%s' to model '%s' (%d parts recolored)",
		data.paletteName, data.modelName or "?", data.partsRecolored or 0
	))
end)

bus:Subscribe("PaletteSwitched", function(data)
	print(string.format(
		"[Palette] Switched scene palette: '%s' -> '%s'",
		data.fromPalette, data.toPalette
	))
end)

-- ---------------------------------------------------------------------------
-- LowPolyGenerator events
-- ---------------------------------------------------------------------------
bus:Subscribe("TreeGenerated", function(data)
	-- print(string.format(
	--     "[Generator] Tree generated at (%.1f, %.1f, %.1f) | %d parts",
	--     data.position.X, data.position.Y, data.position.Z, data.partCount
	-- ))
end)

bus:Subscribe("RockGenerated", function(data)
	-- print(string.format(
	--     "[Generator] Rock generated at (%.1f, %.1f, %.1f) | %d parts",
	--     data.position.X, data.position.Y, data.position.Z, data.partCount
	-- ))
end)

bus:Subscribe("BuildingGenerated", function(data)
	print(string.format(
		"[Generator] Building generated at (%.1f, %.1f, %.1f) | %d parts | %d stories",
		data.position.X, data.position.Y, data.position.Z,
		data.partCount, data.stories or 1
	))
end)

bus:Subscribe("PropGenerated", function(data)
	-- print(string.format(
	--     "[Generator] Prop '%s' generated at (%.1f, %.1f, %.1f)",
	--     data.propType, data.position.X, data.position.Y, data.position.Z
	-- ))
end)

-- ---------------------------------------------------------------------------
-- EnvironmentBuilder events
-- ---------------------------------------------------------------------------
bus:Subscribe("SceneBuilt", function(data)
	-- Flat fields emitted by EnvironmentBuilder:BuildScene
	print(string.format(
		"[EnvBuilder] Scene BUILT | seed=%d size=(%d, %d) objects=%d parts=%d palette=%s style=%s",
		data.seed or 0, data.sizeX or 0, data.sizeZ or 0,
		data.objectCount or 0, data.partCount or 0,
		data.paletteName or "?", data.styleName or "?"
	))
end)

bus:Subscribe("AssetPlaced", function(data)
	-- print(string.format(
	--     "[EnvBuilder] Placed %s at (%.1f, %.1f, %.1f)",
	--     data.assetType, data.position.X, data.position.Y, data.position.Z
	-- ))
end)

bus:Subscribe("LightingSet", function(data)
	-- data.brightness and data.ambient are now flat fields on the payload
	print(string.format(
		"[EnvBuilder] Lighting set for style '%s' | brightness=%.2f ambient=%s",
		data.styleName, data.brightness or 0, tostring(data.ambient)
	))
end)

bus:Subscribe("SceneCleared", function(data)
	print(string.format(
		"[EnvBuilder] Scene CLEARED | %d objects removed",
		data.objectsRemoved
	))
end)

-- ---------------------------------------------------------------------------
-- StylePresets events
-- ---------------------------------------------------------------------------
bus:Subscribe("PresetApplied", function(data)
	-- data.modelName and data.material are now emitted by StylePresets
	print(string.format(
		"[Style] Applied preset '%s' to model '%s' | material=%s",
		data.presetName, data.modelName or "?", tostring(data.material)
	))
end)

-- ---------------------------------------------------------------------------
-- LODSystem events
-- ---------------------------------------------------------------------------
bus:Subscribe("LODChanged", function(data)
	-- Only log significant LOD changes (to level 2 or 3, or back to 0)
	if data.newLevel >= 2 or data.oldLevel >= 2 then
		print(string.format(
			"[LOD] Model '%s' (%s): level %d -> %d",
			data.model.Name, data.assetType, data.oldLevel, data.newLevel
		))
	end
end)

bus:Subscribe("ModelSimplified", function(data)
	-- Distant models are being simplified for performance
	-- This is expected behavior; no need to log every one
end)

bus:Subscribe("ModelRestored", function(data)
	-- Models coming back to full detail as camera approaches
end)

-- =============================================================================
-- SCENE BUILDING
-- =============================================================================

print("\n=================================================================")
print("  EXAMPLE LOW-POLY SCENE: Starting pipeline demo")
print("=================================================================\n")

-- Build the scene with the configuration defined above.
-- EnvironmentBuilder will:
--   1. Generate terrain (if enabled) using TerrainGenerator
--   2. Scatter trees based on treeDensity across the scene area
--   3. Scatter rocks based on rockDensity
--   4. Place buildings at strategic locations
--   5. Scatter props (crates, barrels, fences, lamps, signs, campfires)
--   6. Apply the selected color palette to all generated assets
--   7. Apply the selected style preset for visual consistency
--   8. Set up lighting and atmosphere
--   9. Create water plane at waterLevel

local scene = envBuilder:BuildScene({
	seed = config:Get("seed", 42),
	size = Vector2.new(
		config:Get("sceneSizeX", 400),
		config:Get("sceneSizeZ", 400)
	),
	paletteName = config:Get("paletteName", "Forest"),
	styleName = config:Get("styleName", "FlatShaded"),
	terrainEnabled = config:Get("terrainEnabled", true),
	treeDensity = config:Get("treeDensity", 3),
	rockDensity = config:Get("rockDensity", 2),
	buildingCount = config:Get("buildingCount", 2),
	propDensity = config:Get("propDensity", 4),
	waterLevel = config:Get("waterLevel", 16),
})

-- =============================================================================
-- LOD REGISTRATION
-- =============================================================================
-- Register all scene objects with the LODSystem so distant assets are
-- automatically simplified.  This is the key performance optimization:
-- objects far from the camera render with fewer parts.

if config:Get("lodEnabled", true) then
	print("\n[LOD] Registering scene objects for level-of-detail...")

	-- Register trees
	if scene.trees then
		for _, tree in ipairs(scene.trees) do
			lodSys:RegisterModel(tree, "tree")
		end
		print(string.format("[LOD] Registered %d trees", #scene.trees))
	end

	-- Register rocks
	if scene.rocks then
		for _, rock in ipairs(scene.rocks) do
			lodSys:RegisterModel(rock, "rock")
		end
		print(string.format("[LOD] Registered %d rocks", #scene.rocks))
	end

	-- Register buildings
	if scene.buildings then
		for _, building in ipairs(scene.buildings) do
			lodSys:RegisterModel(building, "building")
		end
		print(string.format("[LOD] Registered %d buildings", #scene.buildings))
	end

	-- Register props
	if scene.props then
		for _, prop in ipairs(scene.props) do
			-- Props use rock LOD rules (simpler thresholds)
			lodSys:RegisterModel(prop, "rock")
		end
		print(string.format("[LOD] Registered %d props", #scene.props))
	end

	-- Enable automatic LOD updates every N seconds
	local lodInterval = config:Get("lodUpdateInterval", 1.0)
	lodSys:EnableAutoLOD(lodInterval)
	print(string.format("[LOD] Auto-LOD enabled (interval: %.1fs)", lodInterval))
end

-- =============================================================================
-- PALETTE CYCLING DEMO
-- =============================================================================
-- Every 10 seconds, switch the scene's color palette to demonstrate dynamic
-- theming.  This cycles through: Forest -> Sunset -> Ocean -> Minimalist.

local paletteCycleTask = nil
if config:Get("paletteCycleEnabled", true) then
	local palettes = { "Forest", "Sunset", "Ocean", "Minimalist" }
	local currentPaletteIndex = 1

	-- Find the starting palette in the cycle
	for i, name in ipairs(palettes) do
		if name == config:Get("paletteName", "Forest") then
			currentPaletteIndex = i
			break
		end
	end

	paletteCycleTask = task.spawn(function()
		while true do
			task.wait(config:Get("paletteCycleInterval", 10))

			-- Move to next palette in cycle
			currentPaletteIndex = (currentPaletteIndex % #palettes) + 1
			local nextPalette = palettes[currentPaletteIndex]
			local currentPalette = config:Get("paletteName", "Forest")

			if nextPalette ~= currentPalette then
				print(string.format(
					"\n[PaletteCycle] Switching palette: %s -> %s",
					currentPalette, nextPalette
				))

				-- Apply the new palette to all scene objects
				paletteSys:ApplyPaletteToScene(scene, nextPalette)
				config:Set("paletteName", nextPalette)

				-- Emit palette switch event
				bus:Emit("PaletteSwitched", {
					fromPalette = currentPalette,
					toPalette = nextPalette,
				})
			end
		end
	end)

	print(string.format(
		"[PaletteCycle] Palette cycling enabled (interval: %ds, palettes: %s)",
		config:Get("paletteCycleInterval", 10),
		table.concat(palettes, ", ")
	))
end

-- =============================================================================
-- SCENE STATISTICS
-- =============================================================================

print("\n=================================================================")
print("  LOW-POLY SCENE STATISTICS")
print("=================================================================")
print(string.format("  Seed:              %d", scene.seed or config:Get("seed", 42)))
print(string.format("  Size:              %d x %d studs", scene.sizeX or 400, scene.sizeZ or 400))
print(string.format("  Object count:      %d", scene.objectCount or 0))
print(string.format("  Part count:        %d", scene.partCount or 0))
print(string.format("  Active palette:    %s", scene.palette and scene.palette.name or "unknown"))
print(string.format("  Active style:      %s", config:Get("styleName", "FlatShaded")))
print(string.format("  Trees:             %d", scene.trees and #scene.trees or 0))
print(string.format("  Rocks:             %d", scene.rocks and #scene.rocks or 0))
print(string.format("  Buildings:         %d", scene.buildings and #scene.buildings or 0))
print(string.format("  Props:             %d", scene.props and #scene.props or 0))
print(string.format("  LOD enabled:       %s", tostring(config:Get("lodEnabled", true))))
print(string.format("  Palette cycling:   %s", tostring(config:Get("paletteCycleEnabled", true))))
print("=================================================================\n")

-- =============================================================================
-- LOD DISTANCE REFERENCE
-- =============================================================================

print("=================================================================")
print("  LOD DISTANCE THRESHOLDS")
print("=================================================================")
print("  Asset Type  |  Full (L0)  |  Medium (L1)  |  Simple (L2)  |  Billboard (L3)")
print("  ------------|-------------|---------------|---------------|----------------")
print("  Trees       |    0-200    |   200-400     |   400-800     |    800+")
print("  Rocks       |    0-150    |   150-300     |   300-600     |    600+")
print("  Buildings   |    0-300    |   300-600     |   600-1000    |    1000+")
print("=================================================================\n")

-- =============================================================================
-- MANUAL LOD DEMO (one-time evaluation at startup)
-- =============================================================================
-- Perform a single LOD evaluation from a distant camera position to show
-- the system working immediately.

if config:Get("lodEnabled", true) then
	-- Simulate a camera far from the scene center
	local demoCameraPos = Vector3.new(500, 100, 500)
	lodSys:UpdateLOD(demoCameraPos)

	-- Count how many objects were simplified
	local simplifiedCount = 0
	for _, model in ipairs(scene.trees or {}) do
		local info = lodSys:GetModelLODInfo(model)
		if info and info.currentLevel > 0 then
			simplifiedCount += 1
		end
	end
	for _, model in ipairs(scene.rocks or {}) do
		local info = lodSys:GetModelLODInfo(model)
		if info and info.currentLevel > 0 then
			simplifiedCount += 1
		end
	end
	for _, model in ipairs(scene.buildings or {}) do
		local info = lodSys:GetModelLODInfo(model)
		if info and info.currentLevel > 0 then
			simplifiedCount += 1
		end
	end

	print(string.format(
		"[LOD] Demo evaluation from (500, 100, 500): %d objects simplified",
		simplifiedCount
	))

	-- Now restore everything from the scene center
	task.delay(2, function()
		local centerPos = Vector3.new(0, 50, 0)
		lodSys:UpdateLOD(centerPos)
		print("[LOD] Restored all objects to full detail (camera at center)\n")
	end)
end

-- =============================================================================
-- MODULE STATUS
-- =============================================================================

print("=================================================================")
print("  MODULE STATUS")
print("=================================================================")
print(string.format("  [OK] ColorPaletteSystem  | palettes: %s", table.concat(paletteSys:ListPalettes(), ", ")))
print(string.format("  [OK] LowPolyGenerator    | ready"))
print(string.format("  [OK] EnvironmentBuilder  | ready"))
print(string.format("  [OK] StylePresets        | presets: %s", table.concat(stylePresets:ListPresets(), ", ")))
print(string.format("  [OK] LODSystem           | auto-lod: %s", tostring(config:Get("lodEnabled", true))))
print("=================================================================\n")

-- =============================================================================
-- PUBLIC API
-- =============================================================================

export type ExampleLowPolyScene = {
	Bus: typeof(bus),
	Config: typeof(config),
	Scene: typeof(scene),
	PaletteSystem: typeof(paletteSys),
	LowPolyGenerator: typeof(lowPolyGen),
	EnvironmentBuilder: typeof(envBuilder),
	StylePresets: typeof(stylePresets),
	LODSystem: typeof(lodSys),
	Stop: () -> (),
}

local api: ExampleLowPolyScene = {
	Bus = bus,
	Config = config,
	Scene = scene,
	PaletteSystem = paletteSys,
	LowPolyGenerator = lowPolyGen,
	EnvironmentBuilder = envBuilder,
	StylePresets = stylePresets,
	LODSystem = lodSys,

	-- Stop: call this to clean up all background tasks and restore full detail
	Stop = function()
		lodSys:DisableAutoLOD()
		lodSys:Clear()
		if paletteCycleTask then
			task.cancel(paletteCycleTask)
			paletteCycleTask = nil
		end
		print("[ExampleLowPolyScene] Stopped: LOD disabled, palette cycling halted")
	end,
}

-- =============================================================================
-- CUSTOMIZATION GUIDE (commented)
-- =============================================================================
--[[

HOW TO CUSTOMIZE THIS DEMO:

1.  Change the scene size:
    Set config.sceneSizeX = 800 and config.sceneSizeZ = 800 for a larger world.
    More objects will be generated (scales with area), so LOD becomes more important.

2.  Adjust asset density:
    - config.treeDensity = 5   -> denser forests (more trees per 100x100 area)
    - config.rockDensity = 1   -> fewer rocks
    - config.buildingCount = 5 -> more buildings
    - config.propDensity = 8   -> lots of small props

3.  Change the starting palette:
    Set config.paletteName = "Sunset" or "Ocean" for a different color theme.
    Available palettes: "Forest", "Sunset", "Ocean", "Minimalist", "Voxel", "Monochrome"

4.  Change the visual style:
    Set config.styleName = "Voxel" for a blockier look, or "HandPainted" for softer.
    Available styles: "Minimalist", "Voxel", "HandPainted", "FlatShaded", "Gradient"

5.  Disable palette cycling:
    Set config.paletteCycleEnabled = false to keep a single palette.

6.  Adjust LOD update rate:
    Set config.lodUpdateInterval = 0.5 for more responsive LOD switching,
    or 2.0 for less frequent checks (better performance).

7.  Add custom LOD rules:
    Call lodSys:RegisterLODRules("myAssetType", {
        thresholds = {
            { distance = 0,   level = 0 },
            { distance = 100, level = 1 },
            { distance = 250, level = 2 },
            { distance = 500, level = 3 },
        },
    })

8.  Manual LOD control:
    -- Force a specific model to full detail:
    lodSys:SetLODLevel(someModel, 0)
    -- Force a specific model to billboard:
    lodSys:SetLODLevel(someModel, 3)
    -- Temporarily disable auto-LOD:
    lodSys:DisableAutoLOD()
    -- Re-enable:
    lodSys:EnableAutoLOD(1.0)

9.  Get LOD info for analytics:
    local info = lodSys:GetModelLODInfo(someModel)
    if info then
        print("Current level: " .. info.currentLevel)
        print("Asset type: " .. info.assetType)
    end

10. Clean up when leaving:
    Call api.Stop() to disable LOD, stop palette cycling, and restore all
    models to full detail before switching scenes or shutting down.

--]]

return api
