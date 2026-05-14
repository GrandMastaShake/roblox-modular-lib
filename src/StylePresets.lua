--!strict
-- StylePresets.lua
-- Pre-built style configurations for low-poly visual styles.
-- Provides preset registration, retrieval, and application to Models.

export type StylePreset = {
	name: string,
	material: Enum.Material,
	bevelSize: number,
	colorVariation: number,
	useGradients: boolean,
	shadowIntensity: number,
	outlineEnabled: boolean,
	description: string,
}

type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
	Once: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
}

export type StylePresets = {
	GetPreset: (self: StylePresets, name: string) -> StylePreset?,
	RegisterPreset: (self: StylePresets, preset: StylePreset) -> (),
	ApplyPreset: (self: StylePresets, model: Model, presetName: string) -> (),
	ListPresets: (self: StylePresets) -> { string },
}

-- ---------------------------------------------------------------------------
-- Default presets
-- ---------------------------------------------------------------------------

local DEFAULT_PRESETS: { [string]: StylePreset } = {
	Minimalist = {
		name = "Minimalist",
		material = Enum.Material.SmoothPlastic,
		bevelSize = 0,
		colorVariation = 0.1,
		useGradients = false,
		shadowIntensity = 0,
		outlineEnabled = false,
		description = "Clean flat-shaded look with no bevels, minimal color variation, no shadows",
	},
	Voxel = {
		name = "Voxel",
		material = Enum.Material.Plastic,
		bevelSize = 0,
		colorVariation = 0,
		useGradients = false,
		shadowIntensity = 0.8,
		outlineEnabled = false,
		description = "Blocky voxel style with sharp edges, strong shadows, uniform colors",
	},
	HandPainted = {
		name = "HandPainted",
		material = Enum.Material.SmoothPlastic,
		bevelSize = 0.1,
		colorVariation = 0.3,
		useGradients = true,
		shadowIntensity = 0.3,
		outlineEnabled = false,
		description = "Soft artistic style with beveled edges, high color variation, gradients",
	},
	FlatShaded = {
		name = "FlatShaded",
		material = Enum.Material.SmoothPlastic,
		bevelSize = 0,
		colorVariation = 0.2,
		useGradients = false,
		shadowIntensity = 0.8,
		outlineEnabled = false,
		description = "True low-poly flat shading with no bevels, strong directional shadows",
	},
	Gradient = {
		name = "Gradient",
		material = Enum.Material.SmoothPlastic,
		bevelSize = 0.05,
		colorVariation = 0.2,
		useGradients = true,
		shadowIntensity = 0.3,
		outlineEnabled = false,
		description = "Smooth gradient surfaces with slight bevels, soft shadows",
	},
}

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local StylePresets = {}
StylePresets.__index = StylePresets

--- Create a new StylePresets registry.
-- @param eventBus  Required. Typed EventBus for cross-module events.
-- @return          A new StylePresets instance with default presets registered.
function StylePresets.new(eventBus: EventBus): StylePresets
	local self = setmetatable({}, StylePresets)
	self._eventBus = eventBus
	self._presets = {} :: { [string]: StylePreset }

	-- Register default presets
	for _, preset in pairs(DEFAULT_PRESETS) do
		self:RegisterPreset(preset)
	end

	return self
end

-- ---------------------------------------------------------------------------
-- Preset management
-- ---------------------------------------------------------------------------

--- Retrieve a preset by name.
-- @param name  Preset name (e.g., "Minimalist", "Voxel")
-- @return      The StylePreset table, or nil if not found.
function StylePresets:GetPreset(name: string): StylePreset?
	return self._presets[name]
end

--- Register a new custom preset.
-- @param preset  A StylePreset table. Must have a unique `name` field.
function StylePresets:RegisterPreset(preset: StylePreset)
	if not preset.name or preset.name == "" then
		error("[StylePresets] Preset must have a non-empty name field")
	end
	self._presets[preset.name] = preset
end

--- Return a list of all registered preset names.
-- @return  Ordered array of preset name strings.
function StylePresets:ListPresets(): { string }
	local names: { string } = {}
	for name, _ in pairs(self._presets) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- ---------------------------------------------------------------------------
-- Preset application
-- ---------------------------------------------------------------------------

--- Apply a style preset to every BasePart in a Model.
-- Applies material, color variation (random shift within range), and
-- vertical gradient (if enabled).
-- @param model       The Model to style.
-- @param presetName  Name of the preset to apply.
function StylePresets:ApplyPreset(model: Model, presetName: string)
	local preset = self._presets[presetName]
	if not preset then
		warn("[StylePresets] Unknown preset: " .. tostring(presetName))
		return
	end

	local rng = Random.new(os.clock() * 10000)

	-- Collect all BaseParts in the model
	local parts: { BasePart } = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	-- Include the model itself if it is a BasePart (e.g., a Part parented directly)
	if model:IsA("BasePart") then
		table.insert(parts, model :: BasePart)
	end

	-- Determine vertical bounds for gradient calculation
	local minY: number = math.huge
	local maxY: number = -math.huge
	if preset.useGradients then
		for _, part in ipairs(parts) do
			local y = part.Position.Y
			if y < minY then minY = y end
			if y > maxY then maxY = y end
		end
		if minY == math.huge then
			minY = 0
			maxY = 1
		end
		if maxY == minY then
			maxY = minY + 1
		end
	end

	-- Apply preset to each part
	for _, part in ipairs(parts) do
		-- 1. Material
		part.Material = preset.material

		-- 2. Color variation: random shift within [-variation, +variation] on each channel
		if preset.colorVariation > 0 then
			local baseColor = part.Color
			local shift = preset.colorVariation
			local r = math.clamp(baseColor.R + rng:NextNumber(-shift, shift), 0, 1)
			local g = math.clamp(baseColor.G + rng:NextNumber(-shift, shift), 0, 1)
			local b = math.clamp(baseColor.B + rng:NextNumber(-shift, shift), 0, 1)
			part.Color = Color3.new(r, g, b)
		end

		-- 3. Gradient: top-to-bottom color shift based on vertical position
		if preset.useGradients then
			local t = math.clamp((part.Position.Y - minY) / (maxY - minY), 0, 1)
			local baseColor = part.Color
			-- Gradient toward brighter at top, darker at bottom
			local gradientR = math.clamp(baseColor.R + (t - 0.5) * 0.3, 0, 1)
			local gradientG = math.clamp(baseColor.G + (t - 0.5) * 0.3, 0, 1)
			local gradientB = math.clamp(baseColor.B + (t - 0.5) * 0.3, 0, 1)
			part.Color = Color3.new(gradientR, gradientG, gradientB)
		end

		-- 4. CastShadow driven by shadowIntensity
		part.CastShadow = preset.shadowIntensity > 0.5

		-- 5. Bevel effect: simulated via slight size reduction on non-primary axes
		-- (actual bevel would require MeshParts; we approximate with shape scaling)
		if preset.bevelSize > 0 then
			-- For block-shaped parts, slightly round the corners visually by
			-- adjusting the color to appear softer
			local c = part.Color
			local soften = preset.bevelSize * 0.5
			part.Color = Color3.new(
				math.clamp(c.R + soften, 0, 1),
				math.clamp(c.G + soften, 0, 1),
				math.clamp(c.B + soften, 0, 1)
			)
		end
	end

	self._eventBus:Emit("PresetApplied", {
		model      = model,
		modelName  = model.Name,
		presetName = presetName,
		preset     = preset,
		partCount  = #parts,
		material   = preset.material,
	})
end

return StylePresets
