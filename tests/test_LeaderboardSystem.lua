--!strict
-- tests/test_LeaderboardSystem.lua
-- Lightweight assert-based tests for LeaderboardSystem.

local EventBus = require(script.Parent.Parent.src.Core.EventBus)
local Config = require(script.Parent.Parent.src.Core.Config)
local LeaderboardSystem = require(script.Parent.Parent.src.LeaderboardSystem)

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. ": expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTablesEq(a: { any }, b: { any }, msg: string)
	if #a ~= #b then
		error(msg .. ": length expected " .. tostring(#b) .. " got " .. tostring(#a))
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			error(msg .. "[" .. tostring(i) .. "]: expected " .. tostring(b[i]) .. " got " .. tostring(a[i]))
		end
	end
end

local function runTests()
	print("[test_LeaderboardSystem] Starting tests...")

	-- Test 1: Constructor
	local bus = EventBus.new()
	local config = Config.new()
	local lbs = LeaderboardSystem.new(bus, nil, config)
	assertEq(typeof(lbs.RegisterBoard), "function", "Constructor: RegisterBoard is a function")
	assertEq(typeof(lbs.SubmitScore), "function", "Constructor: SubmitScore is a function")
	assertEq(typeof(lbs.GetTop), "function", "Constructor: GetTop is a function")
	assertEq(typeof(lbs.GetPlayerRank), "function", "Constructor: GetPlayerRank is a function")
	assertEq(typeof(lbs.GetPlayerScore), "function", "Constructor: GetPlayerScore is a function")
	assertEq(typeof(lbs.ResetBoard), "function", "Constructor: ResetBoard is a function")
	print("  [PASS] Constructor")

	-- Test 2: RegisterBoard
	lbs:RegisterBoard({
		name = "test-board",
		maxEntries = 100,
		sortOrder = "desc" :: "desc",
	})
	local top = lbs:GetTop("test-board", 10)
	assertEq(#top, 0, "RegisterBoard: new board has no entries")
	print("  [PASS] RegisterBoard")

	-- Test 3: SubmitScore and GetTop
	lbs:SubmitScore("test-board", "player1", "Alice", 100)
	lbs:SubmitScore("test-board", "player2", "Bob", 200)
	lbs:SubmitScore("test-board", "player3", "Charlie", 150)

	top = lbs:GetTop("test-board", 3)
	assertEq(#top, 3, "SubmitScore: 3 entries submitted")
	assertEq(top[1].playerId, "player2", "GetTop: highest score first (desc)")
	assertEq(top[1].score, 200, "GetTop: highest score value")
	assertEq(top[2].playerId, "player3", "GetTop: second highest")
	assertEq(top[3].playerId, "player1", "GetTop: third highest")
	print("  [PASS] SubmitScore and GetTop")

	-- Test 4: SubmitScore only updates if better (desc)
	lbs:SubmitScore("test-board", "player1", "Alice", 250)
	top = lbs:GetTop("test-board", 3)
	assertEq(top[1].playerId, "player1", "SubmitScore better: player1 now first")
	assertEq(top[1].score, 250, "SubmitScore better: new score recorded")

	-- Worse score should not update
	lbs:SubmitScore("test-board", "player1", "Alice", 50)
	local score = lbs:GetPlayerScore("test-board", "player1")
	assertEq(score, 250, "SubmitScore worse: score not changed")
	print("  [PASS] SubmitScore improvement check")

	-- Test 5: GetPlayerRank
	local rank = lbs:GetPlayerRank("test-board", "player2")
	assertEq(rank, 2, "GetPlayerRank: player2 is rank 2")
	rank = lbs:GetPlayerRank("test-board", "nonexistent")
	assertEq(rank, nil, "GetPlayerRank: nonexistent player returns nil")
	print("  [PASS] GetPlayerRank")

	-- Test 6: GetPlayerScore
	local pscore = lbs:GetPlayerScore("test-board", "player3")
	assertEq(pscore, 150, "GetPlayerScore: player3 has score 150")
	pscore = lbs:GetPlayerScore("test-board", "nonexistent")
	assertEq(pscore, nil, "GetPlayerScore: nonexistent player returns nil")
	print("  [PASS] GetPlayerScore")

	-- Test 7: Events - ScoreSubmitted and LeaderboardUpdated
	local scoreSubmittedFired = false
	local leaderboardUpdatedFired = false
	bus:Subscribe("ScoreSubmitted", function(_payload: any)
		scoreSubmittedFired = true
	end)
	bus:Subscribe("LeaderboardUpdated", function(_payload: any)
		leaderboardUpdatedFired = true
	end)
	local lbs2 = LeaderboardSystem.new(bus, nil, nil)
	lbs2:RegisterBoard({ name = "event-board", maxEntries = 10, sortOrder = "desc" :: "desc" })
	lbs2:SubmitScore("event-board", "p1", "Test", 100)
	assertEq(scoreSubmittedFired, true, "Event: ScoreSubmitted fired")
	assertEq(leaderboardUpdatedFired, true, "Event: LeaderboardUpdated fired")
	print("  [PASS] Event emission")

	-- Test 8: ResetBoard
	lbs:ResetBoard("test-board")
	top = lbs:GetTop("test-board", 10)
	assertEq(#top, 0, "ResetBoard: board is empty after reset")
	print("  [PASS] ResetBoard")

	-- Test 9: Ascending sort order
	local lbs3 = LeaderboardSystem.new(EventBus.new(), nil, nil)
	lbs3:RegisterBoard({ name = "asc-board", maxEntries = 10, sortOrder = "asc" :: "asc" })
	lbs3:SubmitScore("asc-board", "p1", "A", 100)
	lbs3:SubmitScore("asc-board", "p2", "B", 50)
	lbs3:SubmitScore("asc-board", "p3", "C", 75)
	local ascTop = lbs3:GetTop("asc-board", 3)
	assertEq(ascTop[1].playerId, "p2", "Asc: lowest score first")
	assertEq(ascTop[1].score, 50, "Asc: lowest score value")
	assertEq(ascTop[2].playerId, "p3", "Asc: middle score")
	assertEq(ascTop[3].playerId, "p1", "Asc: highest score last")
	print("  [PASS] Ascending sort order")

	-- Test 10: PlayerRankChanged event
	local rankChangedFired = false
	bus:Subscribe("PlayerRankChanged", function(payload: any)
		rankChangedFired = true
		assertEq(payload.boardName, "rank-board", "PlayerRankChanged: boardName")
		assertEq(payload.playerId, "ranker", "PlayerRankChanged: playerId")
	end)
	local lbs4 = LeaderboardSystem.new(bus, nil, nil)
	lbs4:RegisterBoard({ name = "rank-board", maxEntries = 10, sortOrder = "desc" :: "desc" })
	lbs4:SubmitScore("rank-board", "ranker", "First", 100)
	lbs4:SubmitScore("rank-board", "other", "Other", 200)
	-- ranker was rank 1, now should be rank 2 after other submitted 200
	lbs4:SubmitScore("rank-board", "ranker", "First", 300)
	-- ranker back to rank 1 - rank should have changed
	assertEq(rankChangedFired, true, "Event: PlayerRankChanged fired")
	print("  [PASS] PlayerRankChanged event")

	print("[test_LeaderboardSystem] All tests passed!")
end

runTests()

return true
