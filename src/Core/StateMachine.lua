--!strict
-- Core/StateMachine.lua
-- Finite state machine with Enter/Update/Leave lifecycle.

local StateMachine = {}
StateMachine.__index = StateMachine

export type StateTable = {
	[string]: {
		Enter: ((from: string) -> ())?,
		Update: ((dt: number) -> ())?,
		Leave: ((to: string) -> ())?,
	}
}

export type StateMachine = {
	Transition: (self: StateMachine, stateName: string) -> (),
	Update: (self: StateMachine, dt: number) -> (),
	Current: (self: StateMachine) -> string,
	Is: (self: StateMachine, stateName: string) -> boolean,
}

function StateMachine.new(states: StateTable, initial: string): StateMachine
	local self = setmetatable({}, StateMachine)
	self._states = states
	self._current = initial
	self._previous = ""
	local initState = states[initial]
	if initState and initState.Enter then
		initState.Enter("")
	end
	return self
end

function StateMachine:Transition(stateName: string)
	if stateName == self._current then return end
	local prev = self._current
	local prevState = self._states[prev]
	if prevState and prevState.Leave then
		prevState.Leave(stateName)
	end
	self._previous = prev
	self._current = stateName
	local newState = self._states[stateName]
	if newState and newState.Enter then
		newState.Enter(prev)
	end
end

function StateMachine:Update(dt: number)
	local state = self._states[self._current]
	if state and state.Update then
		state.Update(dt)
	end
end

function StateMachine:Current(): string
	return self._current
end

function StateMachine:Is(stateName: string): boolean
	return self._current == stateName
end

return StateMachine