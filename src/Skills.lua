--!strict
-- Skills.lua
-- Cooldowns, casting, and effect application for skills.

local Skills = {}
Skills.__index = Skills

export type SkillDef = {
	id: string,
	name: string,
	cooldown: number,
	castTime: number,
	effect: (target: any) -> (),
}

export type CooldownEntry = { endsAt: number }
export type CastEntry = { skillId: string, startedAt: number, duration: number, sequence: number }

export type Skills = {
	RegisterSkill: (self: Skills, def: SkillDef) -> (),
	Cast: (self: Skills, skillId: string, target: any?) -> boolean,
	IsOnCooldown: (self: Skills, skillId: string) -> boolean,
	GetCooldownRemaining: (self: Skills, skillId: string) -> number,
	InterruptCast: (self: Skills) -> (),
}

function Skills.new(eventBus: { Emit: (self: any, eventName: string, payload: any) -> () }, skillDefs: { SkillDef }?): Skills
	local self = setmetatable({}, Skills)
	self._eventBus = eventBus
	self._skillDefs = {} :: { [string]: SkillDef }
	self._cooldowns = {} :: { [string]: CooldownEntry }
	self._currentCast = nil :: CastEntry?
	self._castSequence = 0

	if skillDefs then
		for _, def in ipairs(skillDefs) do
			self._skillDefs[def.id] = def
		end
	end

	return self
end

function Skills:RegisterSkill(def: SkillDef)
	self._skillDefs[def.id] = def
end

function Skills:IsOnCooldown(skillId: string): boolean
	local entry = self._cooldowns[skillId]
	if not entry then
		return false
	end
	return tick() < entry.endsAt
end

function Skills:GetCooldownRemaining(skillId: string): number
	local entry = self._cooldowns[skillId]
	if not entry then
		return 0
	end
	local remaining = entry.endsAt - tick()
	return if remaining > 0 then remaining else 0
end

function Skills:_startCooldown(skillId: string, cooldown: number)
	local endsAt = tick() + cooldown
	self._cooldowns[skillId] = { endsAt = endsAt }
	self._eventBus:Emit("CooldownStarted", { skillId = skillId, endsAt = endsAt })

	task.delay(cooldown, function()
		local entry = self._cooldowns[skillId]
		if entry and entry.endsAt <= tick() then
			self._cooldowns[skillId] = nil
			self._eventBus:Emit("CooldownEnded", { skillId = skillId })
		end
	end)
end

function Skills:Cast(skillId: string, target: any?): boolean
	local def = self._skillDefs[skillId]
	if not def then
		return false
	end

	if self:IsOnCooldown(skillId) then
		return false
	end

	if self._currentCast then
		return false
	end

	self._eventBus:Emit("CastStarted", { skillId = skillId, target = target, castTime = def.castTime })

	if def.castTime > 0 then
		self._castSequence += 1
		local seq = self._castSequence
		self._currentCast = { skillId = skillId, startedAt = tick(), duration = def.castTime, sequence = seq }
		local currentSkillId = skillId
		local currentTarget = target

		task.delay(def.castTime, function()
			local cast = self._currentCast
			if cast and cast.skillId == currentSkillId and cast.sequence == seq then
				self._currentCast = nil
				self._eventBus:Emit("CastSucceeded", { skillId = currentSkillId, target = currentTarget })
				def.effect(currentTarget)
				self:_startCooldown(currentSkillId, def.cooldown)
			end
		end)

		return true
	else
		self._eventBus:Emit("CastSucceeded", { skillId = skillId, target = target })
		def.effect(target)
		self:_startCooldown(skillId, def.cooldown)
		return true
	end
end

function Skills:InterruptCast()
	local cast = self._currentCast
	if not cast then
		return
	end
	self._currentCast = nil
	self._eventBus:Emit("CastFailed", { skillId = cast.skillId, reason = "interrupted" })
end

-- Cancel any in-flight cast and clear all state. Pending task.delay
-- callbacks for cast completion and cooldown expiry both re-check state
-- before firing, so clearing the tables here makes them no-op.
function Skills:Destroy()
	self._currentCast = nil
	self._skillDefs = {}
	self._cooldowns = {}
end

return Skills
