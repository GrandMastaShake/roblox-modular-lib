--!strict
-- Core/EventBus.lua
-- Typed pub/sub event bus for cross-module communication.

local EventBus = {}
EventBus.__index = EventBus

export type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
	Once: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
}

function EventBus.new(): EventBus
	local self = setmetatable({}, EventBus)
	self._listeners = {} :: { [string]: { (any) -> () } }
	return self
end

function EventBus:Subscribe(eventName: string, callback: (any) -> ()): () -> ()
	if not self._listeners[eventName] then
		self._listeners[eventName] = {}
	end
	table.insert(self._listeners[eventName], callback)
	return function()
		local list = self._listeners[eventName]
		if list then
			for i, cb in ipairs(list) do
				if cb == callback then
					table.remove(list, i)
					break
				end
			end
		end
	end
end

function EventBus:Once(eventName: string, callback: (any) -> ()): () -> ()
	local disconnect: () -> () = nil
	local wrapped = function(payload: any)
		if disconnect then disconnect() end
		callback(payload)
	end
	disconnect = self:Subscribe(eventName, wrapped)
	return disconnect
end

function EventBus:Emit(eventName: string, payload: any)
	local list = self._listeners[eventName]
	if list then
		-- Copy list to avoid mutation issues if callbacks subscribe/unsubscribe
		local copy = table.clone(list)
		for _, callback in ipairs(copy) do
			pcall(callback, payload)
		end
	end
end

return EventBus