--!strict
-- CombatSystem.lua
-- Damage, health, hitboxes, and combat states.

local RunService = game:GetService("RunService")

local EventBus = require(script.Parent.Core.EventBus)
local Config = require(script.Parent.Core.Config)

local CombatSystem = {}
CombatSystem.__index = CombatSystem

export type CombatStats = {
	maxHealth: number,
	currentHealth: number,
	attack: number,
	defense: number,
	critChance: number,
	critMultiplier: number,
}

export type DamageResult = {
	rawDamage: number,
	finalDamage: number,
	isCrit: boolean,
	isAlive: boolean,
}

export type CombatSystem = {
	RegisterEntity: (self: CombatSystem, entityId: string, stats: CombatStats) -> (),
	DealDamage: (self: CombatSystem, attackerId: string, targetId: string, baseDamage: number?) -> DamageResult,
	Heal: (self: CombatSystem, entityId: string, amount: number) -> (),
	GetStats: (self: CombatSystem, entityId: string) -> CombatStats?,
	IsAlive: (self: CombatSystem, entityId: string) -> boolean,
	SetHitbox: (self: CombatSystem, entityId: string, hitbox: BasePart) -> (),
	GetEntitiesInRange: (self: CombatSystem, origin: Vector3, radius: number) -> { string },
	ApplyDamageInRadius: (self: CombatSystem, origin: Vector3, radius: number, damage: number, excludeId: string?) -> { DamageResult },

	-- Private
	_eventBus: EventBus.EventBus,
	_config: Config.Config,
	_entities: { [string]: CombatStats },
	_hitboxes: { [string]: BasePart },
	_connections: { RBXScriptConnection },
}

function CombatSystem.new(eventBus: EventBus.EventBus, config: Config.Config?): CombatSystem
	local self = setmetatable({}, CombatSystem) :: CombatSystem
	self._eventBus = eventBus
	self._config = config or Config.new()
	self._entities = {}
	self._hitboxes = {}
	self._connections = {}

	local conn = RunService.Heartbeat:Connect(function(dt: number)
		self._eventBus:Emit("CombatTick", { dt = dt })
	end)
	table.insert(self._connections, conn)

	return self
end

function CombatSystem:RegisterEntity(entityId: string, stats: CombatStats)
	self._entities[entityId] = {
		maxHealth = stats.maxHealth,
		currentHealth = stats.currentHealth,
		attack = stats.attack,
		defense = stats.defense,
		critChance = stats.critChance,
		critMultiplier = stats.critMultiplier,
	}
end

function CombatSystem:DealDamage(attackerId: string, targetId: string, baseDamage: number?): DamageResult
	local base = baseDamage or 0
	local attackerStats = self._entities[attackerId]
	local targetStats = self._entities[targetId]

	if not targetStats then
		return { rawDamage = base, finalDamage = 0, isCrit = false, isAlive = false }
	end

	local attack = attackerStats and attackerStats.attack or 0
	local isCrit = attackerStats and (math.random() < attackerStats.critChance) or false
	local critMultiplier = attackerStats and attackerStats.critMultiplier or 2

	local rawDamage = base + attack - targetStats.defense
	local finalDamage = math.max(1, math.floor(rawDamage * (isCrit and critMultiplier or 1)))

	targetStats.currentHealth -= finalDamage
	if targetStats.currentHealth < 0 then
		targetStats.currentHealth = 0
	end

	local alive = targetStats.currentHealth > 0

	self._eventBus:Emit("DamageDealt", {
		attackerId = attackerId,
		targetId = targetId,
		rawDamage = rawDamage,
		finalDamage = finalDamage,
		isCrit = isCrit,
	})

	if not alive then
		self._eventBus:Emit("EntityDied", {
			entityId = targetId,
			killerId = attackerId,
		})
	end

	return {
		rawDamage = rawDamage,
		finalDamage = finalDamage,
		isCrit = isCrit,
		isAlive = alive,
	}
end

function CombatSystem:Heal(entityId: string, amount: number)
	if amount <= 0 then return end

	local stats = self._entities[entityId]
	if not stats then return end

	local oldHealth = stats.currentHealth
	stats.currentHealth = math.min(stats.maxHealth, stats.currentHealth + amount)
	local healedAmount = stats.currentHealth - oldHealth

	if healedAmount > 0 then
		self._eventBus:Emit("EntityHealed", {
			entityId = entityId,
			amount = healedAmount,
			currentHealth = stats.currentHealth,
			maxHealth = stats.maxHealth,
		})
	end
end

function CombatSystem:GetStats(entityId: string): CombatStats?
	local stats = self._entities[entityId]
	if not stats then return nil end
	return {
		maxHealth = stats.maxHealth,
		currentHealth = stats.currentHealth,
		attack = stats.attack,
		defense = stats.defense,
		critChance = stats.critChance,
		critMultiplier = stats.critMultiplier,
	}
end

function CombatSystem:IsAlive(entityId: string): boolean
	local stats = self._entities[entityId]
	if not stats then return false end
	return stats.currentHealth > 0
end

function CombatSystem:SetHitbox(entityId: string, hitbox: BasePart)
	self._hitboxes[entityId] = hitbox
end

function CombatSystem:GetEntitiesInRange(origin: Vector3, radius: number): { string }
	local result = {}
	for id, hitbox in pairs(self._hitboxes) do
		if hitbox then
			local dist = (hitbox.Position - origin).Magnitude
			if dist <= radius then
				table.insert(result, id)
			end
		end
	end
	return result
end

function CombatSystem:ApplyDamageInRadius(
	origin: Vector3,
	radius: number,
	damage: number,
	excludeId: string?
): { DamageResult }
	local results = {}
	for entityId, hitbox in pairs(self._hitboxes) do
		if entityId ~= excludeId and hitbox then
			local dist = (hitbox.Position - origin).Magnitude
			if dist <= radius then
				local result = self:DealDamage("_environment", entityId, damage)
				table.insert(results, result)
			end
		end
	end
	return results
end

-- Disconnect Heartbeat connection and clear all entity / hitbox state.
-- Safe to call multiple times.
function CombatSystem:Destroy()
	for _, conn in ipairs(self._connections) do
		if conn and conn.Connected then
			conn:Disconnect()
		end
	end
	self._connections = {}
	self._entities = {}
	self._hitboxes = {}
end

return CombatSystem
