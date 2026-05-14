--!strict
-- DialogueSystem.lua
-- NPC dialogue trees with choices, conditions, and auto-advance.

local EventBus = require(script.Parent.Core.EventBus)

local DialogueSystem = {}
DialogueSystem.__index = DialogueSystem

export type DialogueChoice = {
	text: string,
	nextNodeId: string?,
	condition: (() -> boolean)?,
	action: ((player: Player) -> ())?,
}

export type DialogueNode = {
	id: string,
	speaker: string,
	text: string,
	choices: { DialogueChoice }?,
	autoNext: string?, -- node to auto-advance to (no choices)
	onEnter: ((player: Player) -> ())?,
}

export type DialogueTree = {
	id: string,
	rootNodeId: string,
	nodes: { DialogueNode },
}

export type DialogueSession = {
	treeId: string,
	currentNodeId: string,
	player: Player,
}

export type DialogueSystem = {
	RegisterTree: (self: DialogueSystem, tree: DialogueTree) -> (),
	StartDialogue: (self: DialogueSystem, treeId: string, player: Player) -> DialogueNode?,
	ChooseOption: (self: DialogueSystem, choiceIndex: number) -> DialogueNode?,
	GetCurrentNode: (self: DialogueSystem) -> DialogueNode?,
	EndDialogue: (self: DialogueSystem) -> (),
	IsInDialogue: (self: DialogueSystem) -> boolean,

	-- Private
	_eventBus: EventBus.EventBus,
	_trees: { [string]: DialogueTree },
	_session: DialogueSession?,
}

function DialogueSystem.new(eventBus: EventBus.EventBus): DialogueSystem
	local self = setmetatable({}, DialogueSystem) :: DialogueSystem
	self._eventBus = eventBus
	self._trees = {}
	self._session = nil
	return self
end

function DialogueSystem:RegisterTree(tree: DialogueTree)
	self._trees[tree.id] = tree
end

function DialogueSystem:StartDialogue(treeId: string, player: Player): DialogueNode?
	local tree = self._trees[treeId]
	if not tree then
		warn("DialogueSystem: tree '" .. treeId .. "' not registered")
		return nil
	end

	self._session = {
		treeId = treeId,
		currentNodeId = tree.rootNodeId,
		player = player,
	}

	self._eventBus:Emit("DialogueStarted", {
		treeId = treeId,
		player = player,
		nodeId = tree.rootNodeId,
	})

	return self:_displayCurrentNode()
end

function DialogueSystem:_getFilteredChoices(node: DialogueNode): { DialogueChoice }
	if not node.choices then
		return {}
	end

	local filtered = {}
	for _, choice in ipairs(node.choices) do
		if choice.condition then
			if choice.condition() then
				table.insert(filtered, choice)
			end
		else
			table.insert(filtered, choice)
		end
	end
	return filtered
end

function DialogueSystem:_displayCurrentNode(): DialogueNode?
	local session = self._session
	if not session then
		return nil
	end

	local tree = self._trees[session.treeId]
	if not tree then
		return nil
	end

	local currentNode: DialogueNode? = nil
	for _, node in ipairs(tree.nodes) do
		if node.id == session.currentNodeId then
			currentNode = node
			break
		end
	end

	if not currentNode then
		return nil
	end

	-- Call onEnter callback if present
	if currentNode.onEnter then
		currentNode.onEnter(session.player)
	end

	self._eventBus:Emit("NodeDisplayed", {
		treeId = session.treeId,
		nodeId = currentNode.id,
		speaker = currentNode.speaker,
		text = currentNode.text,
		player = session.player,
	})

	-- Auto-advance if no choices and autoNext is set
	local filteredChoices = self:_getFilteredChoices(currentNode)
	if #filteredChoices == 0 and currentNode.autoNext then
		session.currentNodeId = currentNode.autoNext
		return self:_displayCurrentNode()
	end

	return currentNode
end

function DialogueSystem:ChooseOption(choiceIndex: number): DialogueNode?
	local session = self._session
	if not session then
		warn("DialogueSystem: no active dialogue session")
		return nil
	end

	local tree = self._trees[session.treeId]
	if not tree then
		return nil
	end

	local currentNode: DialogueNode? = nil
	for _, node in ipairs(tree.nodes) do
		if node.id == session.currentNodeId then
			currentNode = node
			break
		end
	end

	if not currentNode then
		return nil
	end

	local filteredChoices = self:_getFilteredChoices(currentNode)
	local choice = filteredChoices[choiceIndex]
	if not choice then
		warn("DialogueSystem: choice index " .. choiceIndex .. " not available")
		return nil
	end

	self._eventBus:Emit("DialogueChoiceMade", {
		treeId = session.treeId,
		nodeId = currentNode.id,
		choiceIndex = choiceIndex,
		choiceText = choice.text,
		player = session.player,
	})

	-- Execute action if present
	if choice.action then
		choice.action(session.player)
	end

	-- Advance to next node
	if choice.nextNodeId then
		session.currentNodeId = choice.nextNodeId
		return self:_displayCurrentNode()
	else
		-- End dialogue if no next node
		self:EndDialogue()
		return nil
	end
end

function DialogueSystem:GetCurrentNode(): DialogueNode?
	local session = self._session
	if not session then
		return nil
	end

	local tree = self._trees[session.treeId]
	if not tree then
		return nil
	end

	for _, node in ipairs(tree.nodes) do
		if node.id == session.currentNodeId then
			return node
		end
	end

	return nil
end

function DialogueSystem:EndDialogue()
	local session = self._session
	if not session then
		return
	end

	self._eventBus:Emit("DialogueEnded", {
		treeId = session.treeId,
		player = session.player,
	})

	self._session = nil
end

function DialogueSystem:IsInDialogue(): boolean
	return self._session ~= nil
end

-- End any active dialogue and clear all registered trees.
function DialogueSystem:Destroy()
	if self._session then
		self:EndDialogue()
	end
	self._trees = {}
	self._session = nil
end

return DialogueSystem
