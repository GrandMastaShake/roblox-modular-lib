--!strict
-- QuestSystem.lua
-- Quest tracking with objectives, rewards, prerequisites, and states.

local EventBus = require(script.Parent.Core.EventBus)
local Config = require(script.Parent.Core.Config)

local QuestSystem = {}
QuestSystem.__index = QuestSystem

export type QuestObjective = {
	id: string,
	description: string,
	targetCount: number,
	currentCount: number,
	completed: boolean,
}

export type QuestReward = {
	type: string, -- "xp" | "currency" | "item"
	id: string,
	amount: number,
}

export type QuestDef = {
	id: string,
	title: string,
	description: string,
	objectives: { QuestObjective },
	rewards: { QuestReward },
	prerequisites: { string }?, -- quest IDs that must be completed first
}

export type ActiveQuest = {
	questId: string,
	objectives: { QuestObjective },
	state: "active" | "completed" | "turned_in",
	acceptedAt: number,
}

export type QuestSystem = {
	RegisterQuest: (self: QuestSystem, def: QuestDef) -> (),
	AcceptQuest: (self: QuestSystem, questId: string) -> boolean,
	AbandonQuest: (self: QuestSystem, questId: string) -> (),
	AdvanceObjective: (self: QuestSystem, questId: string, objectiveId: string, amount: number?) -> (),
	CompleteQuest: (self: QuestSystem, questId: string) -> boolean,
	TurnInQuest: (self: QuestSystem, questId: string) -> { QuestReward }?,
	GetActiveQuests: (self: QuestSystem) -> { ActiveQuest },
	GetCompletedQuests: (self: QuestSystem) -> { string },
	IsQuestAvailable: (self: QuestSystem, questId: string) -> boolean,
	GetQuestProgress: (self: QuestSystem, questId: string) -> number, -- 0..1

	-- Private
	_eventBus: EventBus.EventBus,
	_config: Config.Config,
	_questDefs: { [string]: QuestDef },
	_activeQuests: { [string]: ActiveQuest },
	_completedQuests: { [string]: boolean },
}

local function cloneObjectives(objectives: { QuestObjective }): { QuestObjective }
	local copy = table.create(#objectives)
	for _, obj in ipairs(objectives) do
		table.insert(copy, {
			id = obj.id,
			description = obj.description,
			targetCount = obj.targetCount,
			currentCount = obj.currentCount,
			completed = obj.completed,
		})
	end
	return copy
end

function QuestSystem.new(eventBus: EventBus.EventBus, config: Config.Config?): QuestSystem
	local self = setmetatable({}, QuestSystem) :: QuestSystem
	self._eventBus = eventBus
	self._config = config or Config.new()
	self._questDefs = {}
	self._activeQuests = {}
	self._completedQuests = {}
	return self
end

function QuestSystem:RegisterQuest(def: QuestDef)
	self._questDefs[def.id] = def
end

function QuestSystem:AcceptQuest(questId: string): boolean
	local def = self._questDefs[questId]
	if not def then
		warn("QuestSystem: quest '" .. questId .. "' not registered")
		return false
	end

	if self._activeQuests[questId] then
		return false -- Already active
	end

	if self._completedQuests[questId] then
		return false -- Already completed
	end

	-- Check prerequisites
	if def.prerequisites then
		for _, prereqId in ipairs(def.prerequisites) do
			if not self._completedQuests[prereqId] then
				return false
			end
		end
	end

	local now = tick()
	local activeQuest: ActiveQuest = {
		questId = questId,
		objectives = cloneObjectives(def.objectives),
		state = "active",
		acceptedAt = now,
	}

	self._activeQuests[questId] = activeQuest

	self._eventBus:Emit("QuestAccepted", {
		questId = questId,
		title = def.title,
		timestamp = now,
	})

	return true
end

function QuestSystem:AbandonQuest(questId: string)
	local active = self._activeQuests[questId]
	if not active then
		warn("QuestSystem: cannot abandon quest '" .. questId .. "', not active")
		return
	end

	self._activeQuests[questId] = nil

	self._eventBus:Emit("QuestAbandoned", {
		questId = questId,
		timestamp = tick(),
	})
end

function QuestSystem:AdvanceObjective(questId: string, objectiveId: string, amount: number?)
	local active = self._activeQuests[questId]
	if not active then
		warn("QuestSystem: cannot advance objective for quest '" .. questId .. "', not active")
		return
	end

	if active.state ~= "active" then
		return
	end

	local increment = amount or 1
	for _, obj in ipairs(active.objectives) do
		if obj.id == objectiveId then
			obj.currentCount = math.clamp(obj.currentCount + increment, 0, obj.targetCount)
			if obj.currentCount >= obj.targetCount then
				obj.completed = true
			end

			self._eventBus:Emit("ObjectiveAdvanced", {
				questId = questId,
				objectiveId = objectiveId,
				currentCount = obj.currentCount,
				targetCount = obj.targetCount,
				completed = obj.completed,
			})
			break
		end
	end

	-- Check if all objectives are completed and auto-complete
	local allCompleted = true
	for _, obj in ipairs(active.objectives) do
		if not obj.completed then
			allCompleted = false
			break
		end
	end

	if allCompleted then
		self:CompleteQuest(questId)
	end
end

function QuestSystem:CompleteQuest(questId: string): boolean
	local active = self._activeQuests[questId]
	if not active then
		return false
	end

	if active.state ~= "active" then
		return false
	end

	active.state = "completed"

	self._eventBus:Emit("QuestCompleted", {
		questId = questId,
		timestamp = tick(),
	})

	return true
end

function QuestSystem:TurnInQuest(questId: string): { QuestReward }?
	local active = self._activeQuests[questId]
	if not active then
		return nil
	end

	if active.state ~= "completed" then
		return nil
	end

	local def = self._questDefs[questId]
	if not def then
		return nil
	end

	active.state = "turned_in"
	self._completedQuests[questId] = true
	self._activeQuests[questId] = nil

	self._eventBus:Emit("QuestTurnedIn", {
		questId = questId,
		timestamp = tick(),
	})

	self._eventBus:Emit("QuestRewardsGranted", {
		questId = questId,
		rewards = def.rewards,
	})

	return table.clone(def.rewards)
end

function QuestSystem:GetActiveQuests(): { ActiveQuest }
	local result = {}
	for _, quest in pairs(self._activeQuests) do
		if quest.state == "active" then
			table.insert(result, quest)
		end
	end
	return result
end

function QuestSystem:GetCompletedQuests(): { string }
	local result = {}
	for questId, _ in pairs(self._completedQuests) do
		table.insert(result, questId)
	end
	return result
end

function QuestSystem:IsQuestAvailable(questId: string): boolean
	local def = self._questDefs[questId]
	if not def then
		return false
	end

	if self._activeQuests[questId] then
		return false
	end

	if self._completedQuests[questId] then
		return false
	end

	if def.prerequisites then
		for _, prereqId in ipairs(def.prerequisites) do
			if not self._completedQuests[prereqId] then
				return false
			end
		end
	end

	return true
end

function QuestSystem:GetQuestProgress(questId: string): number
	local active = self._activeQuests[questId]
	if not active then
		if self._completedQuests[questId] then
			return 1
		end
		return 0
	end

	if active.state == "completed" or active.state == "turned_in" then
		return 1
	end

	local totalTarget = 0
	local totalCurrent = 0
	for _, obj in ipairs(active.objectives) do
		totalTarget += obj.targetCount
		totalCurrent += math.min(obj.currentCount, obj.targetCount)
	end

	if totalTarget <= 0 then
		return 0
	end

	return math.clamp(totalCurrent / totalTarget, 0, 1)
end

-- Clear quest definitions, active quests, and the completed-quest log.
function QuestSystem:Destroy()
	self._questDefs = {}
	self._activeQuests = {}
	self._completedQuests = {}
end

return QuestSystem
