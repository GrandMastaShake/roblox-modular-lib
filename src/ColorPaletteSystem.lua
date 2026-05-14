--!strict
-- ColorPaletteSystem.lua
-- Limited color palettes, palette switching, and harmony rules for low-poly assets.

local Config = require(script.Parent.Core.Config)

local ColorPaletteSystem = {}
ColorPaletteSystem.__index = ColorPaletteSystem

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
	ApplyPaletteToScene: (self: PaletteSystem, scene: any, paletteName: string) -> (),
	GetPalette: (self: PaletteSystem, name: string) -> ColorPalette?,
	ListPalettes: (self: PaletteSystem) -> { string },
}

-- Clamp helper
local function clamp(v: number, min: number, max: number): number
	return math.max(min, math.min(max, v))
end

-- Convert Color3 to HSV, shift hue, return new Color3
local function color3ToHSV(c: Color3): (number, number, number)
	return Color3.toHSV(c)
end

-- Build a palette from a name and ordered color array
local function buildPalette(name: string, colors: { Color3 }): ColorPalette
	local prim = colors[1] or Color3.new(1, 1, 1)
	local sec = colors[2] or prim
	local acc = colors[3] or sec
	local bg = colors[#colors] or prim

	-- Highlights: lighter variants of first half
	local highlights: { Color3 } = {}
	for i = 1, math.min(3, #colors) do
		local h, s, v = color3ToHSV(colors[i])
		table.insert(highlights, Color3.fromHSV(h, s * 0.7, math.min(1, v * 1.2)))
	end

	-- Shadows: darker variants of first half
	local shadows: { Color3 } = {}
	for i = 1, math.min(3, #colors) do
		local h, s, v = color3ToHSV(colors[i])
		table.insert(shadows, Color3.fromHSV(h, s * 1.1, v * 0.5))
	end

	return {
		name = name,
		colors = colors,
		primary = prim,
		secondary = sec,
		accent = acc,
		background = bg,
		highlights = highlights,
		shadows = shadows,
	}
end

function ColorPaletteSystem.new(eventBus: any, config: Config.Config?): PaletteSystem
	local self = setmetatable({}, ColorPaletteSystem)
	self._eventBus = eventBus
	self._config = config
	self._palettes = {} :: { [string]: ColorPalette }

	-- Register 6 default palettes
	self:CreatePalette("Minimalist", {
		Color3.fromRGB(255, 255, 255),
		Color3.fromRGB(200, 200, 200),
		Color3.fromRGB(80, 80, 80),
		Color3.fromRGB(66, 135, 245),
	})

	self:CreatePalette("Forest", {
		Color3.fromRGB(34, 85, 51),
		Color3.fromRGB(106, 168, 79),
		Color3.fromRGB(101, 67, 33),
		Color3.fromRGB(194, 178, 128),
		Color3.fromRGB(135, 206, 235),
		Color3.fromRGB(255, 255, 255),
	})

	self:CreatePalette("Sunset", {
		Color3.fromRGB(255, 127, 80),
		Color3.fromRGB(255, 105, 180),
		Color3.fromRGB(128, 0, 128),
		Color3.fromRGB(75, 0, 130),
		Color3.fromRGB(255, 215, 0),
		Color3.fromRGB(255, 248, 220),
	})

	self:CreatePalette("Ocean", {
		Color3.fromRGB(0, 60, 120),
		Color3.fromRGB(0, 128, 128),
		Color3.fromRGB(0, 200, 200),
		Color3.fromRGB(194, 178, 128),
		Color3.fromRGB(255, 127, 80),
		Color3.fromRGB(255, 255, 255),
	})

	self:CreatePalette("Voxel", {
		Color3.fromRGB(200, 50, 50),
		Color3.fromRGB(50, 150, 50),
		Color3.fromRGB(50, 50, 200),
		Color3.fromRGB(200, 200, 50),
		Color3.fromRGB(50, 200, 200),
		Color3.fromRGB(200, 50, 200),
		Color3.fromRGB(200, 100, 50),
		Color3.fromRGB(100, 100, 100),
	})

	self:CreatePalette("Monochrome", {
		Color3.fromRGB(0, 0, 0),
		Color3.fromRGB(64, 64, 64),
		Color3.fromRGB(128, 128, 128),
		Color3.fromRGB(192, 192, 192),
		Color3.fromRGB(255, 255, 255),
	})

	return self
end

function ColorPaletteSystem:CreatePalette(name: string, colors: { Color3 }): ColorPalette
	local palette = buildPalette(name, colors)
	self._palettes[name] = palette
	self._eventBus:Emit("PaletteCreated", { name = name, palette = palette })
	return palette
end

function ColorPaletteSystem:GetColor(paletteName: string, index: number): Color3
	local palette = self._palettes[paletteName]
	if not palette then
		warn("[ColorPaletteSystem] Palette not found: " .. paletteName)
		return Color3.new(1, 1, 1)
	end
	return palette.colors[index] or palette.primary
end

function ColorPaletteSystem:ShiftHue(color: Color3, shiftDegrees: number): Color3
	local h, s, v = color3ToHSV(color)
	local shiftedH = (h + shiftDegrees / 360) % 1
	return Color3.fromHSV(shiftedH, s, v)
end

function ColorPaletteSystem:Darken(color: Color3, amount: number): Color3
	local h, s, v = color3ToHSV(color)
	return Color3.fromHSV(h, s, clamp(v - amount, 0, 1))
end

function ColorPaletteSystem:Lighten(color: Color3, amount: number): Color3
	local h, s, v = color3ToHSV(color)
	return Color3.fromHSV(h, s, clamp(v + amount, 0, 1))
end

function ColorPaletteSystem:ApplyToModel(model: Model, paletteName: string): ()
	local palette = self._palettes[paletteName]
	if not palette then
		warn("[ColorPaletteSystem] Cannot apply: palette '" .. paletteName .. "' not found")
		return
	end

	local colors = palette.colors
	if #colors == 0 then
		return
	end

	-- Map material categories to color indices
	local function mapMaterialToColorIndex(material: Enum.Material): number
		local matName = tostring(material):match("%w+") or ""

		-- Plastic/SmoothPlastic → primary (index 1)
		if matName == "Plastic" or matName == "SmoothPlastic" then
			return 1
		end

		-- Wood/WoodPlanks → brown tones (index 3)
		if matName == "Wood" or matName == "WoodPlanks" then
			return math.min(3, #colors)
		end

		-- Grass/LeafyGrass → green tones (index 2)
		if matName == "Grass" or matName == "LeafyGrass" or matName == "Foilage" then
			return math.min(2, #colors)
		end

		-- Slate/Concrete/Pavement/Brick/Cobblestone → gray tones (index 3 or 2)
		if matName == "Slate" or matName == "Concrete" or matName == "Pavement"
			or matName == "Brick" or matName == "Cobblestone" then
			return math.min(3, #colors)
		end

		-- Sand/Sandstone/Rock/Marble/Granite → tan/earth tones
		if matName == "Sand" or matName == "Sandstone" or matName == "Rock"
			or matName == "Marble" or matName == "Granite" or matName == "Limestone" then
			return math.min(4, #colors)
		end

		-- Glass/Neon/ForceField → sky/accent tones
		if matName == "Glass" or matName == "Neon" or matName == "ForceField" then
			return math.min(5, #colors)
		end

		-- Metal/DiamondPlate/CorrodedMetal/Fabric/Ice/Pebble
		if matName == "Metal" or matName == "DiamondPlate" or matName == "CorrodedMetal"
			or matName == "Fabric" or matName == "Ice" or matName == "Pebble" then
			return math.min(2, #colors)
		end

		return 1
	end

	local function applyToDescendants(parent: Instance)
		for _, child in ipairs(parent:GetDescendants()) do
			if child:IsA("BasePart") then
				local colorIndex = mapMaterialToColorIndex(child.Material)
				local targetColor = colors[colorIndex]
				if targetColor then
					child.Color = targetColor
				end
			end
		end
	end

	-- Count parts that will be recolored for the event payload
	local partsRecolored = 0
	for _, child in ipairs(model:GetDescendants()) do
		if child:IsA("BasePart") then
			partsRecolored += 1
		end
	end

	applyToDescendants(model)
	self._eventBus:Emit("PaletteApplied", {
		model          = model,
		modelName      = model.Name,
		paletteName    = paletteName,
		partsRecolored = partsRecolored,
	})
end

--- Apply a palette to every Model inside a scene's objectFolder.
-- Convenience wrapper for EnvironmentBuilder scenes.
-- @param scene       A Scene table (must have an `objectFolder: Folder` field).
-- @param paletteName The palette to apply.
function ColorPaletteSystem:ApplyPaletteToScene(scene: any, paletteName: string)
	if not scene then
		return
	end
	local objectFolder = scene.objectFolder
	if not objectFolder then
		warn("[ColorPaletteSystem] ApplyPaletteToScene: scene has no objectFolder")
		return
	end
	for _, child in ipairs(objectFolder:GetChildren()) do
		if child:IsA("Model") then
			self:ApplyToModel(child :: Model, paletteName)
		end
	end
end

function ColorPaletteSystem:GetPalette(name: string): ColorPalette?
	return self._palettes[name]
end

function ColorPaletteSystem:ListPalettes(): { string }
	local names: { string } = {}
	for name, _ in pairs(self._palettes) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return ColorPaletteSystem
