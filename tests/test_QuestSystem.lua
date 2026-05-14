--!strict
-- tests/test_QuestSystem.lua
-- Lightweight assert-based tests for QuestSystem.

local QuestSystem = require(script.Parent.Parent.src.QuestSystem)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. ": expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. ": expected true")
	end
end

local function assertFalse(a: boolean, msg: string)
	if a then
		error(msg .. ": expected false")
	end
end

local function createMockEventBus()
	local bus = {
		_events = {} :: { [string]: { any } },
		Subscribe = function(self: any, eventName: string, callback: (any) -> ()): () -> ()
			return function() end
		end,
		Emit = function(self: any, eventName: string, payload: any)
			if not self._events[eventName] then
				self._events[eventName] = {}
			end
			table.insert(self._events[eventName], payload)
		end,
	}
	return bus
end

local function makeSampleQuestDef(id: string, prereqs: { string }?): {
	id: string,
	title: string,
	description: string,
	objectives: { any },
	rewards: { any },
	prerequisites: { string }?
}
	return {
		id = id,
		title = "Test Quest " .. id,
		description = "A test quest.",
		objectives = {
			{ id = "obj1", description = "Collect 3 apples", targetCount = 3, currentCount = 0, completed = false },
			{ id = "obj2", description = "Talk to NPC", targetCount = 1, currentCount = 0, completed = false },
		},
		rewards = {
			{ type = "xp", id = "xp", amount = 100 },
			{ type = "item", id = "gem", amount = 1 },
		},
		prerequisites = prereqs,
	}
end

-- Test 1: RegisterQuest and AcceptQuest
print("TEST: RegisterQuest + AcceptQuest")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))

	local ok = qs:AcceptQuest("q1")
	assertTrue(ok, "AcceptQuest should succeed")

	local active = qs:GetActiveQuests()
	assertEq(#active, 1, "Active quest count")
	if active[1] then
		assertEq(active[1].questId, "q1", "Active quest ID")
		assertEq(active[1].state, "active", "Active quest state")
	end

	local events = bus._events["QuestAccepted"] or {}
	assertEq(#events, 1, "QuestAccepted event count")
end

-- Test 2: AcceptQuest fails for unknown quest
print("TEST: AcceptQuest unknown quest")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	local ok = qs:AcceptQuest("unknown")
	assertFalse(ok, "AcceptQuest should fail for unknown quest")
end

-- Test 3: AcceptQuest fails if already active
print("TEST: AcceptQuest already active")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))
	qs:AcceptQuest("q1")
	local ok = qs:AcceptQuest("q1")
	assertFalse(ok, "AcceptQuest should fail if already active")
end

-- Test 4: AdvanceObjective
print("TEST: AdvanceObjective")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))
	qs:AcceptQuest("q1")

	qs:AdvanceObjective("q1", "obj1", 2)
	local progress = qs:GetQuestProgress("q1")
	-- obj1: 2/3, obj2: 0/1. Total: 2/4 = 0.5
	assertEq(progress, 0.5, "Progress after advancing obj1 by 2")

	local advEvents = bus._events["ObjectiveAdvanced"] or {}
	assertEq(#advEvents, 1, "ObjectiveAdvanced event count")
	if advEvents[1] then
		assertEq(advEvents[1].questId, "q1", "ObjectiveAdvanced questId")
		assertEq(advEvents[1].objectiveId, "obj1", "ObjectiveAdvanced objectiveId")
		assertEq(advEvents[1].currentCount, 2, "ObjectiveAdvanced currentCount")
	end
end

-- Test 5: AdvanceObjective auto-completes quest
print("TEST: AdvanceObjective auto-complete")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))
	qs:AcceptQuest("q1")

	-- Complete all objectives
	qs:AdvanceObjective("q1", "obj1", 3)
	qs:AdvanceObjective("q1", "obj2", 1)

	-- Should auto-complete
	local active = qs:GetActiveQuests()
	assertEq(#active, 0, "No active quests after completion")

	local completed = qs:GetCompletedQuests()
	assertEq(#completed, 0, "Not in completed until turned in")

	local completedEvents = bus._events["QuestCompleted"] or {}
	assertEq(#completedEvents, 1, "QuestCompleted event count")
end

-- Test 6: CompleteQuest manually
print("TEST: CompleteQuest manually")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))
	qs:AcceptQuest("q1")

	local ok = qs:CompleteQuest("q1")
	assertTrue(ok, "CompleteQuest should succeed")

	-- GetActiveQuests only returns state=="active"; completed quests are excluded
	local active = qs:GetActiveQuests()
	assertEq(#active, 0, "Completed quest not returned by GetActiveQuests")

	-- Double-complete should fail
	local ok2 = qs:CompleteQuest("q1")
	assertFalse(ok2, "CompleteQuest should fail if already completed")
end

-- Test 7: TurnInQuest
print("TEST: TurnInQuest")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))
	qs:AcceptQuest("q1")
	qs:CompleteQuest("q1")

	local rewards = qs:TurnInQuest("q1")
	assertTrue(rewards ~= nil, "TurnInQuest should return rewards")
	if rewards then
		assertEq(#rewards, 2, "Reward count")
		assertEq(rewards[1].type, "xp", "First reward type")
		assertEq(rewards[1].amount, 100, "First reward amount")
	end

	local turnedInEvents = bus._events["QuestTurnedIn"] or {}
	assertEq(#turnedInEvents, 1, "QuestTurnedIn event count")

	local grantedEvents = bus._events["QuestRewardsGranted"] or {}
	assertEq(#grantedEvents, 1, "QuestRewardsGranted event count")

	local completedList = qs:GetCompletedQuests()
	assertEq(#completedList, 1, "Completed quest count")
	assertEq(completedList[1], "q1", "Completed quest ID")
end

-- Test 8: TurnInQuest fails if not completed
print("TEST: TurnInQuest fails if not completed")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))
	qs:AcceptQuest("q1")

	local rewards = qs:TurnInQuest("q1")
	assertTrue(rewards == nil, "TurnInQuest should fail if quest not completed")
end

-- Test 9: AbandonQuest
print("TEST: AbandonQuest")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))
	qs:AcceptQuest("q1")

	qs:AbandonQuest("q1")
	local active = qs:GetActiveQuests()
	assertEq(#active, 0, "No active quests after abandon")

	local abandonEvents = bus._events["QuestAbandoned"] or {}
	assertEq(#abandonEvents, 1, "QuestAbandoned event count")

	-- Can accept again after abandoning
	local ok = qs:AcceptQuest("q1")
	assertTrue(ok, "Can re-accept after abandon")
end

-- Test 10: Prerequisites
print("TEST: Prerequisites")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))
	qs:RegisterQuest(makeSampleQuestDef("q2", { "q1" }))

	-- q2 should not be available until q1 is completed
	assertFalse(qs:IsQuestAvailable("q2"), "q2 should not be available before q1 completed")
	assertTrue(qs:IsQuestAvailable("q1"), "q1 should be available")

	-- Accept and complete q1
	qs:AcceptQuest("q1")
	qs:CompleteQuest("q1")
	qs:TurnInQuest("q1")

	-- Now q2 should be available
	assertTrue(qs:IsQuestAvailable("q2"), "q2 should be available after q1 completed")

	local ok = qs:AcceptQuest("q2")
	assertTrue(ok, "AcceptQuest q2 should succeed after prerequisite met")
end

-- Test 11: GetQuestProgress
print("TEST: GetQuestProgress")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))

	-- Not active
	assertEq(qs:GetQuestProgress("q1"), 0, "Progress for non-active quest")

	qs:AcceptQuest("q1")
	assertEq(qs:GetQuestProgress("q1"), 0, "Progress at start")

	qs:AdvanceObjective("q1", "obj1", 3)
	-- obj1 done (3/3), obj2 not started (0/1). Total: 3/4 = 0.75
	assertEq(qs:GetQuestProgress("q1"), 0.75, "Progress after obj1 done")

	qs:AdvanceObjective("q1", "obj2", 1)
	-- Should auto-complete, quest no longer active. Completed quest -> progress 1
	assertEq(qs:GetQuestProgress("q1"), 1, "Progress after completion")
end

-- Test 12: IsQuestAvailable
print("TEST: IsQuestAvailable")
do
	local bus = createMockEventBus()
	local qs = QuestSystem.new(bus)
	qs:RegisterQuest(makeSampleQuestDef("q1"))

	assertFalse(qs:IsQuestAvailable("unknown"), "Unknown quest")
	assertTrue(qs:IsQuestAvailable("q1"), "Available quest")

	qs:AcceptQuest("q1")
	assertFalse(qs:IsQuestAvailable("q1"), "Already active")

	qs:CompleteQuest("q1")
	qs:TurnInQuest("q1")
	assertFalse(qs:IsQuestAvailable("q1"), "Already completed")
end

print("[test_QuestSystem] All tests passed!")

return true
