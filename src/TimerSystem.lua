--!strict
-- TimerSystem.lua
-- General-purpose timer/countdown utility with loop support and auto-cleanup.

local RunService = game:GetService("RunService")

local EventBus = require(script.Parent.Core.EventBus)

local TimerSystem = {}
TimerSystem.__index = TimerSystem

export type TimerCallback = () -> () | (timerId: string) -> () | nil

export type TimerEntry = {
	id: string,
	duration: number,
	remaining: number,
	callback: TimerCallback,
	loop: boolean,
	active: boolean,
	_lastWholeSecond: number,
}

export type TimerSystem = {
	StartTimer: (self: TimerSystem, duration: number, callback: TimerCallback?, loop: boolean?) -> string,
	StopTimer: (self: TimerSystem, id: string) -> (),
	PauseTimer: (self: TimerSystem, id: string) -> (),
	ResumeTimer: (self: TimerSystem, id: string) -> (),
	GetRemaining: (self: TimerSystem, id: string) -> number,
	GetProgress: (self: TimerSystem, id: string) -> number,
	StopAll: (self: TimerSystem) -> (),
	Destroy: (self: TimerSystem) -> (),

	-- Private
	_eventBus: EventBus.EventBus,
	_timers: { [string]: TimerEntry },
	_counter: number,
	_connection: RBXScriptConnection?,
	_running: boolean,
}

function TimerSystem.new(eventBus: EventBus.EventBus): TimerSystem
	local self = setmetatable({}, TimerSystem) :: TimerSystem
	self._eventBus = eventBus
	self._timers = {}
	self._counter = 0
	self._connection = nil
	self._running = false
	return self
end

function TimerSystem:_startConnection()
	if self._running then return end
	self._running = true
	self._connection = RunService.Heartbeat:Connect(function(dt: number)
		self:_update(dt)
	end)
end

function TimerSystem:_stopConnection()
	self._running = false
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

function TimerSystem:_checkAutoCleanup()
	local hasActive = false
	for _, timer in pairs(self._timers) do
		if timer.active then
			hasActive = true
			break
		end
	end
	if not hasActive then
		self:_stopConnection()
	end
end

function TimerSystem:_generateId(): string
	self._counter += 1
	return "timer_" .. tostring(self._counter) .. "_" .. tostring(os.clock())
end

function TimerSystem:_update(dt: number)
	local timersToRemove: { string } = {}

	for id, timer in pairs(self._timers) do
		if not timer.active then continue end

		timer.remaining -= dt

		-- Emit TimerTick every whole second change
		local wholeSecond = math.floor(timer.remaining)
		if wholeSecond ~= timer._lastWholeSecond then
			timer._lastWholeSecond = wholeSecond
			self._eventBus:Emit("TimerTick", {
				id = timer.id,
				remaining = math.max(0, timer.remaining),
				duration = timer.duration,
				progress = math.clamp(1 - (timer.remaining / timer.duration), 0, 1),
			})
		end

		if timer.remaining <= 0 then
			-- Timer completed
			local callback = timer.callback
			if callback then
				local success, err = pcall(function()
					(callback :: any)(timer.id)
				end)
				if not success then
					warn("TimerSystem: Callback error for timer '" .. timer.id .. "': " .. tostring(err))
				end
			end

			self._eventBus:Emit("TimerCompleted", {
				id = timer.id,
				duration = timer.duration,
				loop = timer.loop,
			})

			if timer.loop then
				-- Restart the timer with original duration
				timer.remaining = timer.duration
				timer._lastWholeSecond = math.floor(timer.duration)
				self._eventBus:Emit("TimerStarted", {
					id = timer.id,
					duration = timer.duration,
					remaining = timer.duration,
					loop = true,
					restarted = true,
				})
			else
				table.insert(timersToRemove, id)
			end
		end
	end

	-- Clean up non-looping completed timers
	for _, id in ipairs(timersToRemove) do
		self._timers[id] = nil
		self._eventBus:Emit("TimerStopped", {
			id = id,
			reason = "completed",
		})
	end

	self:_checkAutoCleanup()
end

function TimerSystem:StartTimer(duration: number, callback: TimerCallback?, loop: boolean?): string
	if duration <= 0 then
		error("TimerSystem: duration must be > 0")
	end

	local id = self:_generateId()
	local timerEntry: TimerEntry = {
		id = id,
		duration = duration,
		remaining = duration,
		callback = callback,
		loop = if loop ~= nil then loop else false,
		active = true,
		_lastWholeSecond = math.floor(duration),
	}

	self._timers[id] = timerEntry
	self:_startConnection()

	self._eventBus:Emit("TimerStarted", {
		id = id,
		duration = duration,
		remaining = duration,
		loop = timerEntry.loop,
		restarted = false,
	})

	return id
end

function TimerSystem:StopTimer(id: string)
	local timer = self._timers[id]
	if not timer then return end

	timer.active = false
	self._timers[id] = nil
	self._eventBus:Emit("TimerStopped", {
		id = id,
		reason = "stopped",
	})
	self:_checkAutoCleanup()
end

function TimerSystem:PauseTimer(id: string)
	local timer = self._timers[id]
	if not timer then
		warn("TimerSystem: Timer '" .. id .. "' not found.")
		return
	end
	if not timer.active then return end

	timer.active = false
end

function TimerSystem:ResumeTimer(id: string)
	local timer = self._timers[id]
	if not timer then
		warn("TimerSystem: Timer '" .. id .. "' not found.")
		return
	end
	if timer.active then return end

	timer.active = true
	timer._lastWholeSecond = math.floor(timer.remaining)
	self:_startConnection()
end

function TimerSystem:GetRemaining(id: string): number
	local timer = self._timers[id]
	if not timer then return 0 end
	return math.max(0, timer.remaining)
end

function TimerSystem:GetProgress(id: string): number
	local timer = self._timers[id]
	if not timer then return 1 end
	if timer.duration <= 0 then return 1 end
	return math.clamp(1 - (timer.remaining / timer.duration), 0, 1)
end

function TimerSystem:StopAll()
	for id, timer in pairs(self._timers) do
		timer.active = false
		self._eventBus:Emit("TimerStopped", {
			id = id,
			reason = "stopAll",
		})
	end
	table.clear(self._timers)
	self:_stopConnection()
end

function TimerSystem:Destroy()
	self:StopAll()
	self._timers = {}
end

return TimerSystem
