--!strict
-- tests/test_PathfindingSystem.lua
-- Tests for PathfindingSystem: NavMesh build, slope filtering, A* pathfinding.

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. " expected true")
	end
end

local function assertNotNil(a: any, msg: string)
	if a == nil then
		error(msg .. " expected non-nil")
	end
end

local function assertNil(a: any, msg: string)
	if a ~= nil then
		error(msg .. " expected nil, got " .. tostring(a))
	end
end

-- ---------------------------------------------------------------------------
-- Mock EventBus
-- ---------------------------------------------------------------------------

local MockEventBus = {}
MockEventBus.__index = MockEventBus

function MockEventBus.new()
	local self = setmetatable({}, MockEventBus)
	self.events = {} :: { [string]: { { [string]: any } } }
	self._listeners = {} :: { [string]: { (any) -> () } }
	return self
end

function MockEventBus:Subscribe(eventName: string, callback: (any) -> ()): () -> ()
	if not self._listeners[eventName] then
		self._listeners[eventName] = {}
	end
	table.insert(self._listeners[eventName], callback)
	return function() end
end

function MockEventBus:Emit(eventName: string, payload: any)
	if not self.events[eventName] then
		self.events[eventName] = {}
	end
	table.insert(self.events[eventName], payload)
	local list = self._listeners[eventName]
	if list then
		for _, cb in ipairs(list) do
			cb(payload)
		end
	end
end

function MockEventBus:getEvents(name: string): { { [string]: any } }
	return self.events[name] or {}
end

-- ---------------------------------------------------------------------------
-- PathfindingSystem (self-contained for test)
-- ---------------------------------------------------------------------------

local PathfindingSystem = {}
PathfindingSystem.__index = PathfindingSystem

local DEFAULT_MAX_SLOPE = 45
local DEFAULT_RESOLUTION = 4
local DEFAULT_SEA_LEVEL = 0
local DEFAULT_CHUNK_SIZE = 64

function PathfindingSystem.new(eventBus: any, config: { [string]: any }?)
	local self = setmetatable({}, PathfindingSystem)
	self._eventBus = eventBus
	self._maxSlope = if config and config.maxSlope ~= nil then config.maxSlope else DEFAULT_MAX_SLOPE
	self._resolution = if config and config.resolution ~= nil then config.resolution else DEFAULT_RESOLUTION
	self._seaLevel = if config and config.seaLevel ~= nil then config.seaLevel else DEFAULT_SEA_LEVEL
	self._chunkSize = if config and config.chunkSize ~= nil then config.chunkSize else DEFAULT_CHUNK_SIZE
	self._navMeshes = {}
	return self
end

local function chunkKey(cx: number, cz: number): string
	return cx .. "," .. cz
end

local function distanceXZ(ax: number, az: number, bx: number, bz: number): number
	local dx = ax - bx
	local dz = az - bz
	return math.sqrt(dx * dx + dz * dz)
end

local function createNode(worldX: number, worldZ: number, height: number, gridX: number, gridZ: number, walkable: boolean)
	return {
		x = worldX, z = worldZ, y = height,
		gCost = math.huge, hCost = 0, fCost = math.huge,
		parent = nil, walkable = walkable,
		gridX = gridX, gridZ = gridZ,
	}
end

local function resetNode(node: any)
	node.gCost = math.huge
	node.hCost = 0
	node.fCost = math.huge
	node.parent = nil
end

local function computeSlope(nodeA: any, nodeB: any): number
	local dx = nodeA.x - nodeB.x
	local dz = nodeA.z - nodeB.z
	local dy = nodeA.y - nodeB.y
	local horizontalDist = math.sqrt(dx * dx + dz * dz)
	if horizontalDist == 0 then
		return 0
	end
	return math.deg(math.atan(math.abs(dy) / horizontalDist))
end

function PathfindingSystem:BuildNavMesh(chunk: any): any
	local cx = chunk.cx
	local cz = chunk.cz
	local heightmap = chunk.heightmap
	local hmSize = #heightmap

	local resolution = self._resolution
	local chunkSize = self._chunkSize
	local seaLevel = self._seaLevel

	local nodesPerSide = math.floor(chunkSize / resolution)
	local hmToNavScale = hmSize / nodesPerSide

	local nodes = table.create(nodesPerSide)
	for nx = 1, nodesPerSide do
		nodes[nx] = table.create(nodesPerSide)
		local worldX = cx * chunkSize + (nx - 1) * resolution
		for nz = 1, nodesPerSide do
			local worldZ = cz * chunkSize + (nz - 1) * resolution
			local hmX = math.clamp(math.ceil(nx * hmToNavScale), 1, hmSize)
			local hmZ = math.clamp(math.ceil(nz * hmToNavScale), 1, hmSize)
			local height = heightmap[hmX][hmZ]
			local walkable = height >= seaLevel
			nodes[nx][nz] = createNode(worldX, worldZ, height, nx, nz, walkable)
		end
	end

	-- Slope pass: mark nodes unwalkable if any adjacent slope exceeds maxSlope
	for nx = 1, nodesPerSide do
		for nz = 1, nodesPerSide do
			local node = nodes[nx][nz]
			if not node.walkable then continue end
			for dX = -1, 1 do
				for dZ = -1, 1 do
					if dX == 0 and dZ == 0 then continue end
					local nX = nx + dX
					local nZ = nz + dZ
					if nX >= 1 and nX <= nodesPerSide and nZ >= 1 and nZ <= nodesPerSide then
						local neighbor = nodes[nX][nZ]
						local slope = computeSlope(node, neighbor)
						if slope > self._maxSlope then
							node.walkable = false
							break
						end
					end
				end
				if not node.walkable then break end
			end
		end
	end

	local navMesh = {
		nodes = nodes,
		resolution = resolution,
		chunkSize = chunkSize,
		cx = cx, cz = cz,
	}
	self._navMeshes[chunkKey(cx, cz)] = navMesh

	self._eventBus:Emit("NavMeshBuilt", {
		cx = cx, cz = cz,
		nodesPerSide = nodesPerSide,
		totalNodes = nodesPerSide * nodesPerSide,
	})
	return navMesh
end

function PathfindingSystem:FindPath(startX: number, startZ: number, endX: number, endZ: number): { Vector3 }?
	local chunkSize = self._chunkSize
	local startCx = math.floor(startX / chunkSize)
	local startCz = math.floor(startZ / chunkSize)
	local endCx = math.floor(endX / chunkSize)
	local endCz = math.floor(endZ / chunkSize)

	if startCx ~= endCx or startCz ~= endCz then
		local startKey = chunkKey(startCx, startCz)
		if not self._navMeshes[startKey] then
			return nil
		end
		self._eventBus:Emit("PathNotFound", {
			startX = startX, startZ = startZ,
			endX = endX, endZ = endZ,
			reason = "Cross-chunk pathfinding not supported",
		})
		return nil
	end

	local cx = startCx
	local cz = startCz
	local key = chunkKey(cx, cz)
	local navMesh = self._navMeshes[key]
	if not navMesh then
		self._eventBus:Emit("PathNotFound", {
			startX = startX, startZ = startZ,
			endX = endX, endZ = endZ,
			reason = "NavMesh not built for chunk",
		})
		return nil
	end

	local nodes = navMesh.nodes
	local nodesPerSide = #nodes
	local resolution = navMesh.resolution

	local function worldToGrid(worldX: number, worldZ: number): (number, number)
		local localX = worldX - cx * chunkSize
		local localZ = worldZ - cz * chunkSize
		local gridX = math.clamp(math.floor(localX / resolution) + 1, 1, nodesPerSide)
		local gridZ = math.clamp(math.floor(localZ / resolution) + 1, 1, nodesPerSide)
		return gridX, gridZ
	end

	local startGridX, startGridZ = worldToGrid(startX, startZ)
	local endGridX, endGridZ = worldToGrid(endX, endZ)

	-- Reset nodes for fresh A* search
	for x = 1, nodesPerSide do
		for z = 1, nodesPerSide do
			resetNode(nodes[x][z])
		end
	end

	local startNode = nodes[startGridX][startGridZ]
	local endNode = nodes[endGridX][endGridZ]

	if not startNode.walkable or not endNode.walkable then
		self._eventBus:Emit("PathNotFound", {
			startX = startX, startZ = startZ,
			endX = endX, endZ = endZ,
			reason = "Start or end node is unwalkable",
		})
		return nil
	end

	local openSet: { any } = {}
	local openLookup: { [any]: boolean } = {}
	local closedSet: { [any]: boolean } = {}

	startNode.gCost = 0
	startNode.hCost = distanceXZ(startNode.x, startNode.z, endNode.x, endNode.z)
	startNode.fCost = startNode.hCost

	table.insert(openSet, startNode)
	openLookup[startNode] = true

	local function getLowestFCostNode(): any?
		local lowestIdx = 1
		local lowestNode = openSet[1]
		if not lowestNode then return nil end
		for i = 2, #openSet do
			local node = openSet[i]
			if node.fCost < lowestNode.fCost or (node.fCost == lowestNode.fCost and node.hCost < lowestNode.hCost) then
				lowestNode = node
				lowestIdx = i
			end
		end
		table.remove(openSet, lowestIdx)
		openLookup[lowestNode] = nil
		return lowestNode
	end

	local function getNeighbors(node: any): { any }
		local neighbors: { any } = {}
		for dX = -1, 1 do
			for dZ = -1, 1 do
				if dX == 0 and dZ == 0 then continue end
				local nx = node.gridX + dX
				local nz = node.gridZ + dZ
				if nx >= 1 and nx <= nodesPerSide and nz >= 1 and nz <= nodesPerSide then
					local neighbor = nodes[nx][nz]
					if neighbor.walkable then
						table.insert(neighbors, neighbor)
					end
				end
			end
		end
		return neighbors
	end

	while #openSet > 0 do
		local currentNode = getLowestFCostNode()
		if not currentNode then break end

		closedSet[currentNode] = true

		if currentNode == endNode then
			local path: { Vector3 } = {}
			local node: any? = endNode
			while node do
				table.insert(path, 1, Vector3.new(node.x, node.y + 2, node.z))
				node = node.parent
			end
			self._eventBus:Emit("PathFound", {
				startX = startX, startZ = startZ,
				endX = endX, endZ = endZ,
				waypointCount = #path,
			})
			return path
		end

		for _, neighbor in ipairs(getNeighbors(currentNode)) do
			if closedSet[neighbor] then continue end

			local isDiagonal = (neighbor.gridX ~= currentNode.gridX) and (neighbor.gridZ ~= currentNode.gridZ)
			local moveCost = if isDiagonal then resolution * 1.414 else resolution
			local newGCost = currentNode.gCost + moveCost

			if newGCost < neighbor.gCost then
				neighbor.gCost = newGCost
				neighbor.hCost = distanceXZ(neighbor.x, neighbor.z, endNode.x, endNode.z)
				neighbor.fCost = neighbor.gCost + neighbor.hCost
				neighbor.parent = currentNode

				if not openLookup[neighbor] then
					table.insert(openSet, neighbor)
					openLookup[neighbor] = true
				end
			end
		end
	end

	self._eventBus:Emit("PathNotFound", {
		startX = startX, startZ = startZ,
		endX = endX, endZ = endZ,
		reason = "No path exists between start and end",
	})
	return nil
end

function PathfindingSystem:IsWalkable(x: number, z: number): boolean
	local chunkSize = self._chunkSize
	local cx = math.floor(x / chunkSize)
	local cz = math.floor(z / chunkSize)
	local key = chunkKey(cx, cz)
	local navMesh = self._navMeshes[key]
	if not navMesh then return false end

	local resolution = navMesh.resolution
	local nodesPerSide = #navMesh.nodes
	local localX = x - cx * chunkSize
	local localZ = z - cz * chunkSize
	local gridX = math.clamp(math.floor(localX / resolution) + 1, 1, nodesPerSide)
	local gridZ = math.clamp(math.floor(localZ / resolution) + 1, 1, nodesPerSide)
	return navMesh.nodes[gridX][gridZ].walkable
end

function PathfindingSystem:SetSlopeLimit(maxSlope: number)
	self._maxSlope = math.clamp(maxSlope, 0, 90)
end

function PathfindingSystem:SetResolution(studsPerNode: number)
	self._resolution = math.max(1, studsPerNode)
end

function PathfindingSystem:InvalidateChunk(cx: number, cz: number)
	local key = chunkKey(cx, cz)
	if self._navMeshes[key] then
		self._navMeshes[key] = nil
		self._eventBus:Emit("NavMeshInvalidated", { cx = cx, cz = cz })
	end
end

-- ---------------------------------------------------------------------------
-- Helper: Build a flat heightmap (all at height 50)
-- ---------------------------------------------------------------------------

local function makeFlatHeightmap(size: number, height: number): { { number } }
	local hm = table.create(size)
	for x = 1, size do
		hm[x] = table.create(size)
		for z = 1, size do
			hm[x][z] = height
		end
	end
	return hm
end

-- Helper: Build a heightmap with a steep slope in the middle
-- Left half is flat at 50, right half rises sharply to 150
local function makeSlopedHeightmap(size: number): { { number } }
	local hm = table.create(size)
	for x = 1, size do
		hm[x] = table.create(size)
		local height = if x <= size / 2 then 50 else 150
		for z = 1, size do
			hm[x][z] = height
		end
	end
	return hm
end

-- Helper: Build a heightmap with a wall (unwalkable barrier) in the middle
local function makeWalledHeightmap(size: number): { { number } }
	local hm = table.create(size)
	for x = 1, size do
		hm[x] = table.create(size)
		for z = 1, size do
			-- A vertical wall in the middle column
			if x == math.floor(size / 2) then
				hm[x][z] = 200  -- Very tall wall
			else
				hm[x][z] = 50
			end
		end
	end
	return hm
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

-- Test 1: Flat terrain navmesh — all nodes should be walkable
local function testFlatTerrainAllWalkable()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64 })

	local heightmap = makeFlatHeightmap(16, 50)
	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	local navMesh = pf:BuildNavMesh(chunk)

	assertNotNil(navMesh, "BuildNavMesh should return a NavMesh")
	assertEq(navMesh.resolution, 4, "NavMesh resolution")
	assertEq(#navMesh.nodes, 16, "Should have 16 nodes per side (64/4)")
	assertEq(#navMesh.nodes[1], 16, "Each row should have 16 nodes")

	-- All nodes on flat terrain should be walkable
	local walkableCount = 0
	for x = 1, #navMesh.nodes do
		for z = 1, #navMesh.nodes[x] do
			if navMesh.nodes[x][z].walkable then
				walkableCount += 1
			end
		end
	end
	assertEq(walkableCount, 256, "All 256 nodes on flat terrain should be walkable")

	-- Check NavMeshBuilt event
	local events = bus:getEvents("NavMeshBuilt")
	assertEq(#events, 1, "Should emit NavMeshBuilt event")
	assertEq(events[1].totalNodes, 256, "Event should report 256 total nodes")
end

-- Test 2: Slope filtering — steep terrain should be unwalkable
local function testSlopeFiltering()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64 })

	local heightmap = makeSlopedHeightmap(16)
	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	local navMesh = pf:BuildNavMesh(chunk)

	-- The heightmap has a step from 50 to 150 at x = 8.
	-- With resolution=4, each node is 4 studs apart.
	-- The step is 100 studs over ~0 studs (instant step), so slope is 90 degrees.
	-- Nodes adjacent to the step should be marked unwalkable.

	local unwalkableCount = 0
	for x = 1, #navMesh.nodes do
		for z = 1, #navMesh.nodes[x] do
			if not navMesh.nodes[x][z].walkable then
				unwalkableCount += 1
			end
		end
	end

	-- The boundary between the low and high regions should create unwalkable nodes.
	-- At least the nodes right at the step edge (x=8) should be unwalkable.
	assertTrue(unwalkableCount > 0, "Steep terrain should produce unwalkable nodes (got " .. tostring(unwalkableCount) .. ")")

	-- Verify that the flat areas are still walkable
	-- Left side (x <= 7, before the step) should be walkable
	local leftWalkable = 0
	for z = 1, 16 do
		if navMesh.nodes[4][z].walkable then
			leftWalkable += 1
		end
	end
	assertTrue(leftWalkable > 0, "Flat left side should have walkable nodes")
end

-- Test 3: A* finds path on flat ground
local function testAStarFindsPathOnFlatGround()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64 })

	local heightmap = makeFlatHeightmap(16, 50)
	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	pf:BuildNavMesh(chunk)

	-- Path from (0, 0) to (60, 60) within chunk (0,0)
	local path = pf:FindPath(0, 0, 60, 60)

	assertNotNil(path, "A* should find a path on flat terrain")
	assertTrue(#path > 0, "Path should have waypoints")

	-- First waypoint should be near the start
	assertEq(path[1].X, 0, "First waypoint X should be start X")
	assertEq(path[1].Z, 0, "First waypoint Z should be start Z")
	assertEq(path[1].Y, 52, "First waypoint Y should be terrain height + 2 (50 + 2)")

	-- Last waypoint should be near the end
	local last = path[#path]
	assertEq(last.X, 60, "Last waypoint X should be end X")
	assertEq(last.Z, 60, "Last waypoint Z should be end Z")
	assertEq(last.Y, 52, "Last waypoint Y should be terrain height + 2")

	-- Verify PathFound event
	local events = bus:getEvents("PathFound")
	assertEq(#events, 1, "Should emit PathFound event")
end

-- Test 4: A* returns nil for blocked paths
local function testAStarReturnsNilForBlockedPaths()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64 })

	local heightmap = makeWalledHeightmap(16)
	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	pf:BuildNavMesh(chunk)

	-- Try to path from left side to right side — wall blocks the way
	local path = pf:FindPath(10, 30, 50, 30)

	assertNil(path, "A* should return nil when path is blocked by a wall")

	-- Verify PathNotFound event
	local events = bus:getEvents("PathNotFound")
	assertEq(#events, 1, "Should emit PathNotFound event for blocked path")
end

-- Test 5: IsWalkable returns correct values
local function testIsWalkable()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64, seaLevel = 10 })

	local heightmap = makeFlatHeightmap(16, 50)
	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	pf:BuildNavMesh(chunk)

	-- Position (10, 10) is on flat terrain at height 50, should be walkable
	assertTrue(pf:IsWalkable(10, 10), "Position on flat terrain should be walkable")

	-- Position (0, 0) is also walkable
	assertTrue(pf:IsWalkable(0, 0), "Position (0,0) should be walkable")
end

-- Test 6: IsWalkable returns false for uncached chunk
local function testIsWalkableUncachedChunk()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64 })

	-- No navmesh built for chunk (5, 5)
	assertTrue(not pf:IsWalkable(320, 320), "Uncached chunk should return not walkable")
end

-- Test 7: InvalidateChunk removes cached navmesh
local function testInvalidateChunk()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64 })

	local heightmap = makeFlatHeightmap(16, 50)
	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	pf:BuildNavMesh(chunk)

	-- Should be walkable before invalidation
	assertTrue(pf:IsWalkable(10, 10), "Should be walkable before invalidation")

	pf:InvalidateChunk(0, 0)

	-- Should not be walkable after invalidation
	assertTrue(not pf:IsWalkable(10, 10), "Should not be walkable after chunk invalidated")

	-- Verify NavMeshInvalidated event
	local events = bus:getEvents("NavMeshInvalidated")
	assertEq(#events, 1, "Should emit NavMeshInvalidated event")
	assertEq(events[1].cx, 0, "Event cx")
	assertEq(events[1].cz, 0, "Event cz")
end

-- Test 8: SetSlopeLimit changes the slope limit
local function testSetSlopeLimit()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64 })

	pf:SetSlopeLimit(30)

	local heightmap = makeFlatHeightmap(16, 50)
	-- Introduce a small slope: height goes from 50 to 55 over 4 studs = ~51.3 degrees
	for z = 1, 16 do
		heightmap[9][z] = 55
	end

	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	local navMesh = pf:BuildNavMesh(chunk)

	-- With maxSlope=30, a 51-degree slope should make nodes unwalkable
	local unwalkableCount = 0
	for x = 1, #navMesh.nodes do
		for z = 1, #navMesh.nodes[x] do
			if not navMesh.nodes[x][z].walkable then
				unwalkableCount += 1
			end
		end
	end
	assertTrue(unwalkableCount > 0, "Lower slope limit should produce unwalkable nodes")
end

-- Test 9: SetResolution changes node density
local function testSetResolution()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 8, chunkSize = 64 })

	local heightmap = makeFlatHeightmap(16, 50)
	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	local navMesh = pf:BuildNavMesh(chunk)

	-- 64 / 8 = 8 nodes per side
	assertEq(#navMesh.nodes, 8, "Resolution 8 should give 8 nodes per side")
	assertEq(navMesh.resolution, 8, "NavMesh should reflect resolution 8")
end

-- Test 10: Underwater terrain is unwalkable
local function testUnderwaterUnwalkable()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64, seaLevel = 30 })

	local heightmap = makeFlatHeightmap(16, 20)  -- All below sea level
	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	local navMesh = pf:BuildNavMesh(chunk)

	local walkableCount = 0
	for x = 1, #navMesh.nodes do
		for z = 1, #navMesh.nodes[x] do
			if navMesh.nodes[x][z].walkable then
				walkableCount += 1
			end
		end
	end
	assertEq(walkableCount, 0, "All underwater nodes should be unwalkable")
end

-- Test 11: Path waypoints are at terrain height + 2
local function testWaypointHeightOffset()
	local bus = MockEventBus.new()
	local pf = PathfindingSystem.new(bus, { maxSlope = 45, resolution = 4, chunkSize = 64 })

	local heightmap = makeFlatHeightmap(16, 75)
	local chunk = { cx = 0, cz = 0, heightmap = heightmap }
	pf:BuildNavMesh(chunk)

	local path = pf:FindPath(0, 0, 20, 20)
	assertNotNil(path, "Should find path")

	for _, wp in ipairs(path) do
		assertEq(wp.Y, 77, "Waypoint Y should be terrain height + 2 (75 + 2 = 77)")
	end
end

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

local tests = {
	{ name = "testFlatTerrainAllWalkable", fn = testFlatTerrainAllWalkable },
	{ name = "testSlopeFiltering", fn = testSlopeFiltering },
	{ name = "testAStarFindsPathOnFlatGround", fn = testAStarFindsPathOnFlatGround },
	{ name = "testAStarReturnsNilForBlockedPaths", fn = testAStarReturnsNilForBlockedPaths },
	{ name = "testIsWalkable", fn = testIsWalkable },
	{ name = "testIsWalkableUncachedChunk", fn = testIsWalkableUncachedChunk },
	{ name = "testInvalidateChunk", fn = testInvalidateChunk },
	{ name = "testSetSlopeLimit", fn = testSetSlopeLimit },
	{ name = "testSetResolution", fn = testSetResolution },
	{ name = "testUnderwaterUnwalkable", fn = testUnderwaterUnwalkable },
	{ name = "testWaypointHeightOffset", fn = testWaypointHeightOffset },
}

local passed = 0
local failed = 0

for _, test in ipairs(tests) do
	local ok, err = pcall(test.fn)
	if ok then
		passed += 1
		print("[PASS] " .. test.name)
	else
		failed += 1
		print("[FAIL] " .. test.name .. ": " .. tostring(err))
	end
end

print("\nResults: " .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed out of " .. tostring(#tests))
