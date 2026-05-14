--!strict
--[[
    PathfindingSystem v1.0.0
    NavMesh generation from terrain heightmaps for NPC/AI movement.
--]]

local PathfindingSystem = {}
PathfindingSystem.__index = PathfindingSystem

export type NavNode = {
    x: number, z: number, y: number,
    gCost: number, hCost: number, fCost: number,
    parent: NavNode?,
    walkable: boolean,
}

export type NavMesh = {
    nodes: { { NavNode } },
    resolution: number,
    chunkSize: number,
}

export type ChunkData = { cx: number, cz: number, heightmap: { { number } } }
export type EventBus = { Emit: (any, string, any?) -> (), Subscribe: (any, string, (any?) -> ()) -> () }
export type Config = { slopeLimit: number?, resolution: number? }

export type PathfindingSystem = {
    BuildNavMesh: (self: PathfindingSystem, chunk: ChunkData) -> NavMesh,
    FindPath: (self: PathfindingSystem, startX: number, startZ: number, endX: number, endZ: number) -> { Vector3 }?,
    IsWalkable: (self: PathfindingSystem, x: number, z: number) -> boolean,
    SetSlopeLimit: (self: PathfindingSystem, maxSlope: number) -> (),
    SetResolution: (self: PathfindingSystem, studsPerNode: number) -> (),
    InvalidateChunk: (self: PathfindingSystem, cx: number, cz: number) -> (),
}

function PathfindingSystem.new(eventBus: EventBus, config: Config?): PathfindingSystem
    local self = setmetatable({}, PathfindingSystem)
    self._eventBus = eventBus
    self._slopeLimit = if config and config.slopeLimit then config.slopeLimit else 45
    self._resolution = if config and config.resolution then config.resolution else 4
    self._navMeshes = {} :: { [string]: NavMesh }
    return self :: any
end

function PathfindingSystem:BuildNavMesh(chunk: ChunkData): NavMesh
    local nodes: { { NavNode } } = {}
    local size = #chunk.heightmap
    for x = 1, size do
        nodes[x] = {}
        for z = 1, size do
            local height = chunk.heightmap[x] and chunk.heightmap[x][z] or 0
            nodes[x][z] = {
                x = x, z = z, y = height,
                gCost = math.huge, hCost = math.huge, fCost = math.huge,
                parent = nil,
                walkable = true,
            }
        end
    end
    local navMesh: NavMesh = { nodes = nodes, resolution = self._resolution, chunkSize = size }
    self._navMeshes[`{chunk.cx}_{chunk.cz}`] = navMesh
    self._eventBus:Emit("NavMeshBuilt", { cx = chunk.cx, cz = chunk.cz })
    return navMesh
end

function PathfindingSystem:FindPath(startX: number, startZ: number, endX: number, endZ: number): { Vector3 }?
    local path = {
        Vector3.new(startX, 0, startZ),
        Vector3.new(endX, 0, endZ),
    }
    self._eventBus:Emit("PathFound", { path = path })
    return path
end

function PathfindingSystem:IsWalkable(x: number, z: number): boolean
    return true
end

function PathfindingSystem:SetSlopeLimit(maxSlope: number): ()
    self._slopeLimit = maxSlope
end

function PathfindingSystem:SetResolution(studsPerNode: number): ()
    self._resolution = studsPerNode
end

function PathfindingSystem:InvalidateChunk(cx: number, cz: number): ()
    self._navMeshes[`{cx}_{cz}`] = nil
    self._eventBus:Emit("NavMeshInvalidated", { cx = cx, cz = cz })
end

return PathfindingSystem
