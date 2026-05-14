--!strict
-- tests/test_DialogueSystem.lua
-- Lightweight assert-based tests for DialogueSystem.

local DialogueSystem = require(script.Parent.Parent.src.DialogueSystem)

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

local function createMockPlayer(): Player
	return newproxy(true) :: any
end

local function makeSampleTree(): {
	id: string,
	rootNodeId: string,
	nodes: { any }
}
	return {
		id = "tree1",
		rootNodeId = "start",
		nodes = {
			{
				id = "start",
				speaker = "NPC",
				text = "Hello, adventurer!",
				choices = {
					{ text = "Hi!", nextNodeId = "greeting" },
					{ text = "Goodbye", nextNodeId = nil },
				},
			},
			{
				id = "greeting",
				speaker = "NPC",
				text = "Nice to meet you!",
				choices = nil,
				autoNext = "farewell",
			},
			{
				id = "farewell",
				speaker = "NPC",
				text = "See you later!",
				choices = nil,
				autoNext = nil,
			},
		},
	}
end

-- Test 1: RegisterTree + StartDialogue
print("TEST: RegisterTree + StartDialogue")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)
	local tree = makeSampleTree()
	ds:RegisterTree(tree)

	local mockPlayer = createMockPlayer()
	local node = ds:StartDialogue("tree1", mockPlayer)
	assertTrue(node ~= nil, "StartDialogue should return a node")
	if node then
		assertEq(node.id, "start", "Should start at root node")
		assertEq(node.speaker, "NPC", "Speaker")
		assertEq(node.text, "Hello, adventurer!", "Text")
	end

	assertTrue(ds:IsInDialogue(), "Should be in dialogue")

	local events = bus._events["DialogueStarted"] or {}
	assertEq(#events, 1, "DialogueStarted event count")

	local nodeEvents = bus._events["NodeDisplayed"] or {}
	assertEq(#nodeEvents, 1, "NodeDisplayed event count")
end

-- Test 2: StartDialogue with unknown tree
print("TEST: StartDialogue unknown tree")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)
	local mockPlayer = createMockPlayer()
	local node = ds:StartDialogue("unknown", mockPlayer)
	assertTrue(node == nil, "StartDialogue should return nil for unknown tree")
	assertFalse(ds:IsInDialogue(), "Should not be in dialogue")
end

-- Test 3: ChooseOption advances to next node
print("TEST: ChooseOption advances")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)
	local tree = makeSampleTree()
	ds:RegisterTree(tree)

	local mockPlayer = createMockPlayer()
	ds:StartDialogue("tree1", mockPlayer)

	local nextNode = ds:ChooseOption(1)
	assertTrue(nextNode ~= nil, "ChooseOption should return next node")
	if nextNode then
		-- "greeting" has no choices and autoNext="farewell", so auto-advance fires immediately
		assertEq(nextNode.id, "farewell", "Should auto-advance through greeting to farewell")
	end

	local choiceEvents = bus._events["DialogueChoiceMade"] or {}
	assertEq(#choiceEvents, 1, "DialogueChoiceMade event count")
	if choiceEvents[1] then
		assertEq(choiceEvents[1].choiceIndex, 1, "Choice index")
		assertEq(choiceEvents[1].choiceText, "Hi!", "Choice text")
	end
end

-- Test 4: ChooseOption with invalid index
print("TEST: ChooseOption invalid index")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)
	local tree = makeSampleTree()
	ds:RegisterTree(tree)

	local mockPlayer = createMockPlayer()
	ds:StartDialogue("tree1", mockPlayer)

	local nextNode = ds:ChooseOption(99)
	assertTrue(nextNode == nil, "ChooseOption with invalid index should return nil")
end

-- Test 5: ChooseOption ends dialogue when no nextNodeId
print("TEST: ChooseOption ends dialogue")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)
	local tree = makeSampleTree()
	ds:RegisterTree(tree)

	local mockPlayer = createMockPlayer()
	ds:StartDialogue("tree1", mockPlayer)

	-- Choose "Goodbye" which has no nextNodeId
	local nextNode = ds:ChooseOption(2)
	assertTrue(nextNode == nil, "ChooseOption with no next should return nil")
	assertFalse(ds:IsInDialogue(), "Should not be in dialogue after ending")

	local endEvents = bus._events["DialogueEnded"] or {}
	assertEq(#endEvents, 1, "DialogueEnded event count")
end

-- Test 6: Auto-advance through autoNext chain
print("TEST: Auto-advance autoNext")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)
	local tree = makeSampleTree()
	ds:RegisterTree(tree)

	local mockPlayer = createMockPlayer()
	ds:StartDialogue("tree1", mockPlayer)

	-- Choose option 1 -> goes to "greeting" which autoNext -> "farewell"
	local node = ds:ChooseOption(1)
	-- greeting has autoNext="farewell" and no choices, so it auto-advances
	assertTrue(node ~= nil, "Should land on farewell node")
	if node then
		assertEq(node.id, "farewell", "Should auto-advance to farewell")
	end

	-- farewell has no choices and no autoNext, so dialogue ends there
end

-- Test 7: GetCurrentNode
print("TEST: GetCurrentNode")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)
	local tree = makeSampleTree()
	ds:RegisterTree(tree)

	assertTrue(ds:GetCurrentNode() == nil, "No current node outside dialogue")

	local mockPlayer = createMockPlayer()
	ds:StartDialogue("tree1", mockPlayer)

	local node = ds:GetCurrentNode()
	assertTrue(node ~= nil, "Should have current node")
	if node then
		assertEq(node.id, "start", "Current node id")
	end
end

-- Test 8: EndDialogue
print("TEST: EndDialogue")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)
	local tree = makeSampleTree()
	ds:RegisterTree(tree)

	local mockPlayer = createMockPlayer()
	ds:StartDialogue("tree1", mockPlayer)
	assertTrue(ds:IsInDialogue(), "Should be in dialogue")

	ds:EndDialogue()
	assertFalse(ds:IsInDialogue(), "Should not be in dialogue after EndDialogue")

	local endEvents = bus._events["DialogueEnded"] or {}
	assertEq(#endEvents, 1, "DialogueEnded event count")
end

-- Test 9: EndDialogue when not in dialogue (no error)
print("TEST: EndDialogue when not in dialogue")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)
	ds:EndDialogue()
	assertFalse(ds:IsInDialogue(), "Should still not be in dialogue")
end

-- Test 10: Choice filtering by condition
print("TEST: Choice condition filtering")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)

	local conditionValue = false
	local tree = {
		id = "condTree",
		rootNodeId = "start",
		nodes = {
			{
				id = "start",
				speaker = "NPC",
				text = "Can you help me?",
				choices = {
					{ text = "Yes", nextNodeId = "help", condition = function() return true end },
					{ text = "Maybe", nextNodeId = "maybe", condition = function() return conditionValue end },
					{ text = "No", nextNodeId = nil },
				},
			},
			{ id = "help", speaker = "NPC", text = "Thanks!", choices = nil },
			{ id = "maybe", speaker = "NPC", text = "Think about it.", choices = nil },
		},
	}
	ds:RegisterTree(tree)

	local mockPlayer = createMockPlayer()
	ds:StartDialogue("condTree", mockPlayer)

	-- Only "Yes" and "No" should be available ("Maybe" condition is false)
	-- Try ChooseOption(2) - should be "No" since "Maybe" is filtered out
	local node = ds:ChooseOption(2)
	assertTrue(node == nil, "Choosing 'No' should end dialogue")
	assertFalse(ds:IsInDialogue(), "Dialogue should end")

	-- Now test with condition true
	conditionValue = true
	ds:StartDialogue("condTree", mockPlayer)
	-- Now 3 choices: Yes, Maybe, No. ChooseOption(2) = Maybe
	local node2 = ds:ChooseOption(2)
	assertTrue(node2 ~= nil, "Maybe should now be available")
	if node2 then
		assertEq(node2.id, "maybe", "Should advance to maybe node")
	end
end

-- Test 11: Choice with action callback
print("TEST: Choice action callback")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)

	local actionCalled = false
	local tree = {
		id = "actionTree",
		rootNodeId = "start",
		nodes = {
			{
				id = "start",
				speaker = "NPC",
				text = "Take this.",
				choices = {
					{
						text = "Accept",
						nextNodeId = nil,
						action = function(_player: Player)
							actionCalled = true
						end,
					},
				},
			},
		},
	}
	ds:RegisterTree(tree)

	local mockPlayer = createMockPlayer()
	ds:StartDialogue("actionTree", mockPlayer)
	ds:ChooseOption(1)
	assertTrue(actionCalled, "Action callback should have been called")
end

-- Test 12: onEnter callback
print("TEST: onEnter callback")
do
	local bus = createMockEventBus()
	local ds = DialogueSystem.new(bus)

	local onEnterCalled = false
	local tree = {
		id = "enterTree",
		rootNodeId = "start",
		nodes = {
			{
				id = "start",
				speaker = "NPC",
				text = "Welcome!",
				onEnter = function(_player: Player)
					onEnterCalled = true
				end,
			},
		},
	}
	ds:RegisterTree(tree)

	local mockPlayer = createMockPlayer()
	ds:StartDialogue("enterTree", mockPlayer)
	assertTrue(onEnterCalled, "onEnter should have been called")
end

print("[test_DialogueSystem] All tests passed!")

return true
