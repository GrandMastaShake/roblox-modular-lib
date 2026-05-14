--!strict
-- Core/Config.lua
-- Lightweight key-value configuration with defaults.

local Config = {}
Config.__index = Config

export type Config = {
	Get: (self: Config, key: string, default: any?) -> any,
	Set: (self: Config, key: string, value: any) -> (),
	Reset: (self: Config) -> (),
	All: (self: Config) -> { [string]: any },
}

function Config.new(defaults: { [string]: any }?): Config
	local self = setmetatable({}, Config)
	self._store = {}
	if defaults then
		for k, v in pairs(defaults) do
			self._store[k] = v
		end
	end
	return self
end

function Config:Get(key: string, default: any?): any
	local val = self._store[key]
	if val == nil then
		return default
	end
	return val
end

function Config:Set(key: string, value: any)
	self._store[key] = value
end

function Config:Reset()
	table.clear(self._store)
end

function Config:All(): { [string]: any }
	return table.clone(self._store)
end

return Config