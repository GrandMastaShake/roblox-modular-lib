--!strict
-- UIFramework.lua
-- Theming, tweening, and component base for UI.

local TweenService = game:GetService("TweenService")

local EventBus = require(script.Parent.Core.EventBus)
local Types = require(script.Parent.Core.Types)

local UIFramework = {}
UIFramework.__index = UIFramework

local DEFAULT_FONT = Font.fromEnum(Enum.Font.GothamBold)

local DEFAULT_THEME: Types.Theme = {
	primary = Color3.fromRGB(0, 170, 255),
	secondary = Color3.fromRGB(255, 85, 0),
	background = Color3.fromRGB(30, 30, 30),
	text = Color3.fromRGB(240, 240, 240),
	font = DEFAULT_FONT,
	cornerRadius = 8,
}

export type UIFramework = {
	SetTheme: (self: UIFramework, theme: Types.Theme) -> (),
	CreateButton: (self: UIFramework, parent: Instance, text: string, onClick: () -> ()) -> TextButton,
	CreateBar: (self: UIFramework, parent: Instance, size: UDim2, color: Color3?) -> Frame,
	Tween: (self: UIFramework, object: Instance, props: { [string]: any }, duration: number) -> Tween,
	ThemeBar: (self: UIFramework, bar: Frame, progress: number) -> (),

	-- Private
	_eventBus: EventBus.EventBus,
	_theme: Types.Theme,
}

function UIFramework.new(eventBus: EventBus.EventBus, theme: Types.Theme?): UIFramework
	local self = setmetatable({}, UIFramework) :: UIFramework
	self._eventBus = eventBus
	self._theme = theme or table.clone(DEFAULT_THEME)
	return self
end

function UIFramework:SetTheme(theme: Types.Theme)
	self._theme = theme
end

function UIFramework:CreateButton(parent: Instance, text: string, onClick: () -> ()): TextButton
	local theme = self._theme

	local button = Instance.new("TextButton")
	button.Name = "UIButton"
	button.Text = text
	button.FontFace = theme.font
	button.TextColor3 = theme.text
	button.BackgroundColor3 = theme.primary
	button.Size = UDim2.new(0, 120, 0, 40)
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, theme.cornerRadius)
	corner.Parent = button

	button.MouseButton1Click:Connect(function()
		self._eventBus:Emit("UIButtonClicked", {
			text = text,
			button = button,
		})
		onClick()
	end)

	return button
end

function UIFramework:CreateBar(parent: Instance, size: UDim2, color: Color3?): Frame
	local theme = self._theme

	local container = Instance.new("Frame")
	container.Name = "BarContainer"
	container.Size = size
	container.BackgroundColor3 = theme.background
	container.BorderSizePixel = 0
	container.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, theme.cornerRadius)
	corner.Parent = container

	local fill = Instance.new("Frame")
	fill.Name = "BarFill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = color or theme.primary
	fill.BorderSizePixel = 0
	fill.Parent = container

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, theme.cornerRadius)
	fillCorner.Parent = fill

	return container
end

function UIFramework:Tween(object: Instance, props: { [string]: any }, duration: number): Tween
	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(object, tweenInfo, props)
	tween:Play()
	return tween
end

function UIFramework:ThemeBar(bar: Frame, progress: number)
	local clamped = math.clamp(progress, 0, 1)
	local fill = bar:FindFirstChild("BarFill")
	if not fill or not fill:IsA("Frame") then
		-- If no internal fill frame, tween the bar itself on X scale
		self:Tween(bar, { Size = UDim2.new(clamped, bar.Size.X.Offset, bar.Size.Y.Scale, bar.Size.Y.Offset) }, 0.3)
		self._eventBus:Emit("BarUpdated", { bar = bar, progress = clamped })
		return
	end

	self:Tween(fill, { Size = UDim2.new(clamped, 0, 1, 0) }, 0.3)
	self._eventBus:Emit("BarUpdated", { bar = bar, progress = clamped })
end

-- Stateless module: nothing to disconnect or destroy. Provided for
-- consistency with the rest of the lib so a composition root can call
-- :Destroy uniformly across every module.
function UIFramework:Destroy()
	self._theme = DEFAULT_THEME
end

return UIFramework
