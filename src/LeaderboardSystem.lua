--!strict
-- LeaderboardSystem.lua
-- Sorted leaderboards with optional DataStoreSafe backend.

local EventBus = require(script.Parent.Core.EventBus)
local Config = require(script.Parent.Core.Config)
local Types = require(script.Parent.Core.Types)
local DataStoreSafe = require(script.Parent.DataStoreSafe)

local LeaderboardSystem = {}
LeaderboardSystem.__index = LeaderboardSystem

export type LeaderboardEntry = {
	playerId: string,
	playerName: string,
	score: number,
	timestamp: number,
}

export type LeaderboardConfig = {
	name: string,
	maxEntries: number,
	sortOrder: "asc" | "desc",
	resetInterval: number?,
}

export type LeaderboardSystem = {
	RegisterBoard: (self: LeaderboardSystem, config: LeaderboardConfig) -> (),
	SubmitScore: (self: LeaderboardSystem, boardName: string, playerId: string, playerName: string, score: number) -> (),
	GetTop: (self: LeaderboardSystem, boardName: string, count: number?) -> { LeaderboardEntry },
	GetPlayerRank: (self: LeaderboardSystem, boardName: string, playerId: string) -> number?,
	GetPlayerScore: (self: LeaderboardSystem, boardName: string, playerId: string) -> number?,
	ResetBoard: (self: LeaderboardSystem, boardName: string) -> (),

	-- Private
	_eventBus: EventBus.EventBus,
	_dataStore: DataStoreSafe.DataStoreSafe?,
	_config: Config.Config?,
	_boards: { [string]: { LeaderboardEntry } },
	_boardConfigs: { [string]: LeaderboardConfig },
}

function LeaderboardSystem.new(
	eventBus: EventBus.EventBus,
	dataStore: DataStoreSafe.DataStoreSafe?,
	config: Config.Config?
): LeaderboardSystem
	local self = setmetatable({}, LeaderboardSystem) :: LeaderboardSystem
	self._eventBus = eventBus
	self._dataStore = dataStore
	self._config = config
	self._boards = {}
	self._boardConfigs = {}
	return self
end

function LeaderboardSystem:RegisterBoard(config: LeaderboardConfig)
	local name = config.name
	if self._boards[name] then
		warn("LeaderboardSystem: Board '" .. name .. "' is already registered. Overwriting.")
	end

	self._boardConfigs[name] = config
	self._boards[name] = {}

	-- Attempt to load persisted data if DataStore is available
	if self._dataStore then
		local saved = self._dataStore:Load("lb_" .. name)
		if saved and typeof(saved) == "table" then
			self._boards[name] = saved :: { LeaderboardEntry }
		end
	end
end

function LeaderboardSystem:_isBetterScore(boardName: string, newScore: number, oldScore: number): boolean
	local boardConfig = self._boardConfigs[boardName]
	local sortOrder = if boardConfig then boardConfig.sortOrder else "desc"

	if sortOrder == "asc" then
		return newScore < oldScore
	else
		return newScore > oldScore
	end
end

function LeaderboardSystem:_sortBoard(boardName: string)
	local board = self._boards[boardName]
	if not board then return end

	local boardConfig = self._boardConfigs[boardName]
	local sortOrder = if boardConfig then boardConfig.sortOrder else "desc"

	table.sort(board, function(a: LeaderboardEntry, b: LeaderboardEntry): boolean
		if sortOrder == "asc" then
			if a.score ~= b.score then
				return a.score < b.score
			end
		else
			if a.score ~= b.score then
				return a.score > b.score
			end
		end
		return a.timestamp < b.timestamp
	end)
end

function LeaderboardSystem:_persistBoard(boardName: string)
	if self._dataStore then
		self._dataStore:Save("lb_" .. boardName, self._boards[boardName] :: Types.SaveData)
	end
end

function LeaderboardSystem:SubmitScore(boardName: string, playerId: string, playerName: string, score: number)
	local board = self._boards[boardName]
	if not board then
		warn("LeaderboardSystem: Board '" .. boardName .. "' not found. Call RegisterBoard first.")
		return
	end

	local existingEntry: LeaderboardEntry? = nil
	local existingIndex: number? = nil

	for i, entry in ipairs(board) do
		if entry.playerId == playerId then
			existingEntry = entry
			existingIndex = i
			break
		end
	end

	if existingEntry then
		if self:_isBetterScore(boardName, score, existingEntry.score) then
			local oldRank = self:GetPlayerRank(boardName, playerId)
			existingEntry.score = score
			existingEntry.timestamp = os.time()
			existingEntry.playerName = playerName
			self:_sortBoard(boardName)
			self:_persistBoard(boardName)

			local newRank = self:GetPlayerRank(boardName, playerId)
			if oldRank and newRank and oldRank ~= newRank then
				self._eventBus:Emit("PlayerRankChanged", {
					boardName = boardName,
					playerId = playerId,
					oldRank = oldRank,
					newRank = newRank,
					score = score,
				})
			end

			self._eventBus:Emit("ScoreSubmitted", {
				boardName = boardName,
				playerId = playerId,
				playerName = playerName,
				score = score,
				improved = true,
			})
			self._eventBus:Emit("LeaderboardUpdated", {
				boardName = boardName,
				top = self:GetTop(boardName, 10),
			})
		else
			self._eventBus:Emit("ScoreSubmitted", {
				boardName = boardName,
				playerId = playerId,
				playerName = playerName,
				score = score,
				improved = false,
			})
		end
	else
		table.insert(board, {
			playerId = playerId,
			playerName = playerName,
			score = score,
			timestamp = os.time(),
		} :: LeaderboardEntry)

		self:_sortBoard(boardName)
		self:_persistBoard(boardName)

		self._eventBus:Emit("ScoreSubmitted", {
			boardName = boardName,
			playerId = playerId,
			playerName = playerName,
			score = score,
			improved = true,
		})
		self._eventBus:Emit("LeaderboardUpdated", {
			boardName = boardName,
			top = self:GetTop(boardName, 10),
		})
	end
end

function LeaderboardSystem:GetTop(boardName: string, count: number?): { LeaderboardEntry }
	local board = self._boards[boardName]
	if not board then
		return {}
	end

	local limit = count or 10
	local result: { LeaderboardEntry } = {}

	for i = 1, math.min(limit, #board) do
		result[i] = board[i]
	end

	return result
end

function LeaderboardSystem:GetPlayerRank(boardName: string, playerId: string): number?
	local board = self._boards[boardName]
	if not board then return nil end

	for i, entry in ipairs(board) do
		if entry.playerId == playerId then
			return i
		end
	end

	return nil
end

function LeaderboardSystem:GetPlayerScore(boardName: string, playerId: string): number?
	local board = self._boards[boardName]
	if not board then return nil end

	for _, entry in ipairs(board) do
		if entry.playerId == playerId then
			return entry.score
		end
	end

	return nil
end

function LeaderboardSystem:ResetBoard(boardName: string)
	if not self._boards[boardName] then
		warn("LeaderboardSystem: Board '" .. boardName .. "' not found.")
		return
	end

	self._boards[boardName] = {}

	if self._dataStore then
		self._dataStore:Save("lb_" .. boardName, {})
	end

	self._eventBus:Emit("LeaderboardUpdated", {
		boardName = boardName,
		top = {},
		reset = true,
	})
end

-- Clear all in-memory boards and configs. We deliberately do NOT call
-- :Destroy on the underlying _dataStore — it's externally owned (the
-- composition root passes it in) and may be shared with other systems.
function LeaderboardSystem:Destroy()
	self._boards = {}
	self._boardConfigs = {}
end

return LeaderboardSystem
