--!strict
-- XPSystem.lua
-- XP, leveling, and progression bar system.

local TweenService = game:GetService("TweenService")

local EventBus = require(script.Parent.Core.EventBus)
local Config = require(script.Parent.Core.Config)
local Types = require(script.Parent.Core.Types)

local XPSystem = {}
XPSystem.__index = XPSystem

export type XPSystem = {
	AddXP: (self: XPSystem, amount: number) -> (),
	GetLevel: (self: XPSystem) -> number,
	GetProgress: (self: XPSystem) -> number,
	GetXPData: (self: XPSystem) -> Types.XPProfile,
	SetXPBar: (self: XPSystem, guiBar: Frame) -> (),

	-- Private
	_eventBus: EventBus.EventBus,
	_config: Config.Config,
	_currentXP: number,
	_level: number,
	_formula: (level: number) -> number,
	_xpBar: Frame?,
	_tween: Tween?,
}

function XPSystem.new(eventBus: EventBus.EventBus, config: Config.Config): XPSystem
	local self = setmetatable({}, XPSystem) :: XPSystem
	self._eventBus = eventBus
	self._config = config
	self._currentXP = 0
	self._level = 1
	self._formula = config:Get("xpFormula", function(lvl: number): number
		return math.floor(100 * lvl ^ 1.5)
	end) :: (level: number) -> number
	self._xpBar = nil
	self._tween = nil
	return self
end

function XPSystem:AddXP(amount: number)
	if amount <= 0 then return end
	self._currentXP += amount

	local xpToNext = self._formula(self._level)
	local didLevelUp = false
	local oldLevel = self._level

	while self._currentXP >= xpToNext do
		self._currentXP -= xpToNext
		self._level += 1
		didLevelUp = true
		xpToNext = self._formula(self._level)
	end

	self._eventBus:Emit("XPAdded", {
		amount = amount,
		currentXP = self._currentXP,
		level = self._level,
		xpToNext = xpToNext,
	})

	if didLevelUp then
		self._eventBus:Emit("LevelUp", {
			oldLevel = oldLevel,
			level = self._level,
			currentXP = self._currentXP,
			xpToNext = xpToNext,
		})
	end

	self:_updateXPBar()
end

function XPSystem:GetLevel(): number
	return self._level
end

function XPSystem:GetProgress(): number
	local xpToNext = self._formula(self._level)
	if xpToNext <= 0 then return 1 end
	return math.clamp(self._currentXP / xpToNext, 0, 1)
end

function XPSystem:GetXPData(): Types.XPProfile
	local xpToNext = self._formula(self._level)
	return {
		currentXP = self._currentXP,
		level = self._level,
		xpToNext = xpToNext,
		formula = self._formula,
	}
end

function XPSystem:SetXPBar(guiBar: Frame)
	self._xpBar = guiBar
	self:_updateXPBar()
end

function XPSystem:_updateXPBar()
	local bar = self._xpBar
	if not bar then return end

	local progress = self:GetProgress()
	local targetSize = UDim2.new(progress, 0, bar.Size.Y.Scale, bar.Size.Y.Offset)

	if self._tween then
		self._tween:Cancel()
	end

	local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	self._tween = TweenService:Create(bar, tweenInfo, { Size = targetSize })
	self._tween:Play()

	self._eventBus:Emit("XPBarUpdated", {
		progress = progress,
		level = self._level,
		currentXP = self._currentXP,
	})
end

-- Cancel any in-flight bar tween and drop the bar reference. We don't
-- destroy the bar Frame itself — it's externally owned by whoever called
-- SetXPBar.
function XPSystem:Destroy()
	if self._tween then
		self._tween:Cancel()
	end
	self._tween = nil
	self._xpBar = nil
end

return XPSystem
