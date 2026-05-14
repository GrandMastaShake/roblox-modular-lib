--!strict
-- NotificationSystem.lua
-- Toast notifications with auto-dismiss, colored bars, and tweened animations.

local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local EventBus = require(script.Parent.Core.EventBus)
local Config = require(script.Parent.Core.Config)

local NotificationSystem = {}
NotificationSystem.__index = NotificationSystem

export type NotificationType = "info" | "success" | "warning" | "error"

export type Notification = {
	id: string,
	type: NotificationType,
	title: string,
	message: string,
	duration: number,
	timestamp: number,
}

export type NotificationSystem = {
	Show: (self: NotificationSystem, notifType: NotificationType, title: string, message: string, duration: number?) -> string,
	Dismiss: (self: NotificationSystem, id: string) -> (),
	DismissAll: (self: NotificationSystem) -> (),
	SetContainer: (self: NotificationSystem, guiParent: Instance) -> (),
	GetHistory: (self: NotificationSystem, limit: number?) -> { Notification },

	-- Private
	_eventBus: EventBus.EventBus,
	_config: Config.Config,
	_container: Instance?,
	_activeNotifications: { [string]: { notif: Notification, frame: Frame?, dismissConnection: thread? } },
	_history: { Notification },
	_idCounter: number,
}

local TYPE_COLORS: { [NotificationType]: Color3 } = {
	info = Color3.fromRGB(59, 130, 246), -- blue
	success = Color3.fromRGB(34, 197, 94), -- green
	warning = Color3.fromRGB(234, 179, 8), -- yellow
	error = Color3.fromRGB(239, 68, 68), -- red
}

function NotificationSystem.new(eventBus: EventBus.EventBus, config: Config.Config?): NotificationSystem
	local self = setmetatable({}, NotificationSystem) :: NotificationSystem
	self._eventBus = eventBus
	self._config = config or Config.new()
	self._container = nil
	self._activeNotifications = {}
	self._history = {}
	self._idCounter = 0
	return self
end

function NotificationSystem:_generateId(): string
	self._idCounter += 1
	local success, guid = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if success then
		return guid
	end
	return "notif_" .. tostring(self._idCounter)
end

function NotificationSystem:_createNotificationFrame(notif: Notification): Frame
	local container = self._container
	if not container then
		-- Create a fallback ScreenGui if no container set
		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "NotificationSystemContainer"
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = true
		-- Parent to PlayerGui if available, otherwise keep unparented
		local success = pcall(function()
			local Players = game:GetService("Players")
			screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		end)
		if not success then
			screenGui.Parent = game:GetService("CoreGui")
		end
		container = screenGui
		self._container = screenGui
	end

	local frame = Instance.new("Frame")
	frame.Name = "Notification_" .. notif.id
	frame.Size = UDim2.new(0, 300, 0, 80)
	frame.Position = UDim2.new(1, 20, 0, 20 + (#self._history * 90)) -- stack vertically
	frame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	frame.BorderSizePixel = 0
	frame.Parent = container

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local colorBar = Instance.new("Frame")
	colorBar.Name = "ColorBar"
	colorBar.Size = UDim2.new(0, 4, 1, 0)
	colorBar.Position = UDim2.new(0, 0, 0, 0)
	colorBar.BackgroundColor3 = TYPE_COLORS[notif.type]
	colorBar.BorderSizePixel = 0
	colorBar.Parent = frame

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 6)
	barCorner.Parent = colorBar

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -20, 0, 24)
	titleLabel.Position = UDim2.new(0, 12, 0, 4)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = notif.title
	titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextSize = 16
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Parent = frame

	local messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "Message"
	messageLabel.Size = UDim2.new(1, -20, 0, 48)
	messageLabel.Position = UDim2.new(0, 12, 0, 28)
	messageLabel.BackgroundTransparency = 1
	messageLabel.Text = notif.message
	messageLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	messageLabel.Font = Enum.Font.Gotham
	messageLabel.TextSize = 14
	messageLabel.TextXAlignment = Enum.TextXAlignment.Left
	messageLabel.TextWrapped = true
	messageLabel.Parent = frame

	return frame
end

function NotificationSystem:_animateIn(frame: Frame)
	local targetX = -320 -- Position from right edge
	local tweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(frame, tweenInfo, {
		Position = UDim2.new(1, targetX, frame.Position.Y.Scale, frame.Position.Y.Offset),
	})
	tween:Play()
end

function NotificationSystem:_animateOut(frame: Frame, onComplete: () -> ())
	local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local tween = TweenService:Create(frame, tweenInfo, {
		Position = UDim2.new(1, 20, frame.Position.Y.Scale, frame.Position.Y.Offset),
	})
	tween.Completed:Connect(function()
		onComplete()
	end)
	tween:Play()
end

function NotificationSystem:Show(
	notifType: NotificationType,
	title: string,
	message: string,
	duration: number?
): string
	local dur = duration or self._config:Get("notificationDuration", 3)
	local id = self:_generateId()
	local now = tick()

	local notif: Notification = {
		id = id,
		type = notifType,
		title = title,
		message = message,
		duration = dur,
		timestamp = now,
	}

	table.insert(self._history, notif)

	local frame = self:_createNotificationFrame(notif)
	self._activeNotifications[id] = {
		notif = notif,
		frame = frame,
		dismissConnection = nil,
	}

	self:_animateIn(frame)

	self._eventBus:Emit("NotificationShown", {
		id = id,
		type = notifType,
		title = title,
		message = message,
		duration = dur,
	})

	-- Auto-dismiss after duration
	local dismissThread = task.delay(dur, function()
		self:_dismissById(id, true)
	end)
	self._activeNotifications[id].dismissConnection = dismissThread

	return id
end

function NotificationSystem:_dismissById(id: string, expired: boolean)
	local entry = self._activeNotifications[id]
	if not entry then
		return
	end

	self._activeNotifications[id] = nil

	if entry.dismissConnection then
		pcall(task.cancel, entry.dismissConnection)
	end

	local frame = entry.frame
	if frame then
		self:_animateOut(frame, function()
			frame:Destroy()
		end)
	else
		if entry.frame then
			entry.frame:Destroy()
		end
	end

	if expired then
		self._eventBus:Emit("NotificationExpired", {
			id = id,
			type = entry.notif.type,
		})
	else
		self._eventBus:Emit("NotificationDismissed", {
			id = id,
			type = entry.notif.type,
		})
	end
end

function NotificationSystem:Dismiss(id: string)
	self:_dismissById(id, false)
end

function NotificationSystem:DismissAll()
	local idsToDismiss = {}
	for id, _ in pairs(self._activeNotifications) do
		table.insert(idsToDismiss, id)
	end
	for _, id in ipairs(idsToDismiss) do
		self:_dismissById(id, false)
	end
end

function NotificationSystem:SetContainer(guiParent: Instance)
	self._container = guiParent
end

function NotificationSystem:GetHistory(limit: number?): { Notification }
	local result = table.clone(self._history)
	if limit and limit > 0 then
		while #result > limit do
			table.remove(result, 1)
		end
	end
	return result
end

-- Cancel pending auto-dismiss tasks, destroy any remaining frames, and
-- clear history. We don't destroy the externally-set _container — that
-- belongs to whoever passed it in.
function NotificationSystem:Destroy()
	for id, entry in pairs(self._activeNotifications) do
		if entry.dismissConnection then
			pcall(task.cancel, entry.dismissConnection)
		end
		if entry.frame and entry.frame.Parent then
			entry.frame:Destroy()
		end
		self._activeNotifications[id] = nil
	end
	self._activeNotifications = {}
	self._history = {}
end

return NotificationSystem
