--!strict
-- StatusEffectSystem.lua
-- Buffs/debuffs with duration, stacking, and expiration.

local RunService = game:GetService("RunService")

local EventBus = require(script.Parent.Core.EventBus)

local StatusEffectSystem = {}
StatusEffectSystem.__index = StatusEffectSystem

export type StatusEffectDef = {
	id: string,
	name: string,
	category: "buff" | "debuff" | "neutral",
	maxStacks: number,
	duration: number,
	tickInterval: number?,
	onApply: ((targetId: string, stacks: number) -> ())?,
	onTick: ((targetId: string, stacks: number) -> ())?,
	onRemove: ((targetId: string, stacks: number) -> ())?,
}

export type ActiveEffect = {
	defId: string,
	appliedAt: number,
	expiresAt: number,
	stacks: number,
	sourceId: string,
	nextTickAt: number?,
}

export type StatusEffectSystem = {
	RegisterEffect: (self: StatusEffectSystem, def: StatusEffectDef) -> (),
	Apply: (self: StatusEffectSystem, effectId: string, targetId: string, sourceId: string?, stacks: number?) -> boolean,
	Remove: (self: StatusEffectSystem, effectId: string, targetId: string) -> (),
	RemoveAllFromSource: (self: StatusEffectSystem, sourceId: string, targetId: string) -> (),
	GetActiveEffects: (self: StatusEffectSystem, targetId: string) -> { ActiveEffect },
	HasEffect: (self: StatusEffectSystem, targetId: string, effectId: string) -> boolean,
	GetEffectStacks: (self: StatusEffectSystem, targetId: string, effectId: string) -> number,

	-- Private
	_eventBus: EventBus.EventBus,
	_definitions: { [string]: StatusEffectDef },
	_active: { [string]: { [string]: ActiveEffect } },
	_connections: { RBXScriptConnection },
}

function StatusEffectSystem.new(eventBus: EventBus.EventBus): StatusEffectSystem
	local self = setmetatable({}, StatusEffectSystem) :: StatusEffectSystem
	self._eventBus = eventBus
	self._definitions = {}
	self._active = {}
	self._connections = {}

	local conn = RunService.Heartbeat:Connect(function(_dt: number)
		local now = os.clock()
		for targetId, effects in pairs(self._active) do
			for effectId, active in pairs(effects) do
				-- Expiration check
				if now >= active.expiresAt then
					local def = self._definitions[effectId]
					if def and def.onRemove then
						local cbOk, cbErr = pcall(def.onRemove, targetId, active.stacks)
						if not cbOk then
							warn("[StatusEffectSystem] onRemove error for '" .. effectId .. "': " .. tostring(cbErr))
						end
					end
					self._eventBus:Emit("EffectExpired", {
						effectId = effectId,
						targetId = targetId,
						stacks = active.stacks,
					})
					effects[effectId] = nil
				else
					-- Tick check
					local def = self._definitions[effectId]
					if def and def.tickInterval and def.tickInterval > 0 and active.nextTickAt and now >= active.nextTickAt then
						active.nextTickAt = now + def.tickInterval
						if def.onTick then
							local cbOk, cbErr = pcall(def.onTick, targetId, active.stacks)
							if not cbOk then
								warn("[StatusEffectSystem] onTick error for '" .. effectId .. "': " .. tostring(cbErr))
							end
						end
						self._eventBus:Emit("EffectTick", {
							effectId = effectId,
							targetId = targetId,
							stacks = active.stacks,
						})
					end
				end
			end
			-- Clean up empty target tables
			if next(effects) == nil then
				self._active[targetId] = nil
			end
		end
	end)
	table.insert(self._connections, conn)

	return self
end

function StatusEffectSystem:RegisterEffect(def: StatusEffectDef)
	self._definitions[def.id] = def
end

function StatusEffectSystem:Apply(
	effectId: string,
	targetId: string,
	sourceId: string?,
	stacks: number?
): boolean
	local def = self._definitions[effectId]
	if not def then return false end

	if not self._active[targetId] then
		self._active[targetId] = {}
	end

	local existing = self._active[targetId][effectId]
	local now = os.clock()
	local stackCount = stacks or 1

	if existing then
		-- Stack or refresh
		local newStacks = math.min(def.maxStacks, existing.stacks + stackCount)
		local didStack = newStacks > existing.stacks
		existing.stacks = newStacks
		existing.expiresAt = now + def.duration
		if def.tickInterval and def.tickInterval > 0 then
			existing.nextTickAt = now + def.tickInterval
		end

		if didStack then
			self._eventBus:Emit("EffectStacked", {
				effectId = effectId,
				targetId = targetId,
				stacks = existing.stacks,
				sourceId = sourceId or "",
			})
		end
	else
		local nextTickAt: number? = nil
		if def.tickInterval and def.tickInterval > 0 then
			nextTickAt = now + def.tickInterval
		end
		self._active[targetId][effectId] = {
			defId = effectId,
			appliedAt = now,
			expiresAt = now + def.duration,
			stacks = math.min(def.maxStacks, stackCount),
			sourceId = sourceId or "",
			nextTickAt = nextTickAt,
		}

		if def.onApply then
			local cbOk, cbErr = pcall(def.onApply, targetId, self._active[targetId][effectId].stacks)
			if not cbOk then
				warn("[StatusEffectSystem] onApply error for '" .. effectId .. "': " .. tostring(cbErr))
			end
		end

		self._eventBus:Emit("EffectApplied", {
			effectId = effectId,
			targetId = targetId,
			stacks = self._active[targetId][effectId].stacks,
			sourceId = sourceId or "",
		})
	end

	return true
end

function StatusEffectSystem:Remove(effectId: string, targetId: string)
	local effects = self._active[targetId]
	if not effects then return end

	local active = effects[effectId]
	if not active then return end

	local def = self._definitions[effectId]
	if def and def.onRemove then
		def.onRemove(targetId, active.stacks)
	end

	effects[effectId] = nil

	if next(effects) == nil then
		self._active[targetId] = nil
	end

	self._eventBus:Emit("EffectRemoved", {
		effectId = effectId,
		targetId = targetId,
		stacks = active.stacks,
	})
end

function StatusEffectSystem:RemoveAllFromSource(sourceId: string, targetId: string)
	local effects = self._active[targetId]
	if not effects then return end

	local toRemove = {}
	for effectId, active in pairs(effects) do
		if active.sourceId == sourceId then
			table.insert(toRemove, effectId)
		end
	end

	for _, effectId in ipairs(toRemove) do
		self:Remove(effectId, targetId)
	end
end

function StatusEffectSystem:GetActiveEffects(targetId: string): { ActiveEffect }
	local effects = self._active[targetId]
	local result = {}
	if effects then
		for _, active in pairs(effects) do
			table.insert(result, {
				defId = active.defId,
				appliedAt = active.appliedAt,
				expiresAt = active.expiresAt,
				stacks = active.stacks,
				sourceId = active.sourceId,
				nextTickAt = active.nextTickAt,
			})
		end
	end
	return result
end

function StatusEffectSystem:HasEffect(targetId: string, effectId: string): boolean
	local effects = self._active[targetId]
	if not effects then return false end
	return effects[effectId] ~= nil
end

function StatusEffectSystem:GetEffectStacks(targetId: string, effectId: string): number
	local effects = self._active[targetId]
	if not effects then return 0 end
	local active = effects[effectId]
	return active and active.stacks or 0
end

-- Disconnect the Heartbeat tick connection and clear all state. We do not
-- fire onRemove for the active effects — Destroy is for shutdown, not
-- gameplay-driven removal.
function StatusEffectSystem:Destroy()
	for _, conn in ipairs(self._connections) do
		if conn and conn.Connected then
			conn:Disconnect()
		end
	end
	self._connections = {}
	self._definitions = {}
	self._active = {}
end

return StatusEffectSystem
