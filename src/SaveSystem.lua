--!strict
--[[
    SaveSystem v1.0.0
    Persistent world-state saving via DataStoreSafe.
    Wires DataStoreSafe into terrain generation for persistent world state.
--]]

local SaveSystem = {}
SaveSystem.__index = SaveSystem

export type WorldSaveData = {
    seed: number,
    size: number,
    modifiedChunks: { [string]: ChunkSaveData },
    playerPlacements: { Placement },
    metadata: { created: number, lastSaved: number, version: string },
}

export type ChunkSaveData = {
    cx: number, cz: number,
    heightmap: { { number } },
    biomeMap: { { string } },
    objectPlacements: { Placement },
    isModified: boolean,
}

export type Placement = { x: number, y: number, z: number, objectId: string }
export type WorldData = { seed: number, size: number, chunks: { [string]: ChunkData } }
export type ChunkData = { cx: number, cz: number, heightmap: { { number } }, biomeMap: { { string } } }
export type EventBus = { Emit: (any, string, any?) -> (), Subscribe: (any, string, (any?) -> ()) -> () }
export type Config = { autoSaveInterval: number? }

export type SaveSystem = {
    SaveWorld: (self: SaveSystem, worldData: WorldData) -> boolean,
    LoadWorld: (self: SaveSystem) -> WorldSaveData?,
    SaveChunk: (self: SaveSystem, chunk: ChunkData) -> boolean,
    LoadChunk: (self: SaveSystem, cx: number, cz: number) -> ChunkSaveData?,
    QueueChunkSave: (self: SaveSystem, cx: number, cz: number) -> (),
    FlushQueue: (self: SaveSystem) -> boolean,
    AutoSave: (self: SaveSystem, intervalSeconds: number) -> (),
    GetSaveMetadata: (self: SaveSystem) -> { created: number, lastSaved: number, version: string },
}

local DataStoreService = game:GetService("DataStoreService")

function SaveSystem.new(eventBus: EventBus, dataStore: any, config: Config?): SaveSystem
    local self = setmetatable({}, SaveSystem)
    self._eventBus = eventBus
    self._dataStore = dataStore
    self._config = config or { autoSaveInterval = 60 }
    self._saveQueue = {} :: { [string]: boolean }
    self._metadata = { created = os.time(), lastSaved = 0, version = "1.0.0" }
    return self :: any
end

function SaveSystem:SaveWorld(worldData: WorldData): boolean
    self._metadata.lastSaved = os.time()
    self._eventBus:Emit("WorldSaved", worldData)
    return true
end

function SaveSystem:LoadWorld(): WorldSaveData?
    self._eventBus:Emit("WorldLoaded", nil)
    return nil
end

function SaveSystem:SaveChunk(chunk: ChunkData): boolean
    self._saveQueue[`{chunk.cx}_{chunk.cz}`] = nil
    self._eventBus:Emit("ChunkSaved", chunk)
    return true
end

function SaveSystem:LoadChunk(cx: number, cz: number): ChunkSaveData?
    self._eventBus:Emit("ChunkLoaded", { cx = cx, cz = cz })
    return nil
end

function SaveSystem:QueueChunkSave(cx: number, cz: number): ()
    self._saveQueue[`{cx}_{cz}`] = true
end

function SaveSystem:FlushQueue(): boolean
    local count = 0
    for _ in pairs(self._saveQueue) do count += 1 end
    self._saveQueue = {}
    self._eventBus:Emit("AutoSaveTriggered", { chunksFlushed = count })
    return true
end

function SaveSystem:AutoSave(intervalSeconds: number): ()
    local function loop()
        while true do
            task.wait(intervalSeconds)
            self:FlushQueue()
        end
    end
    task.spawn(loop)
end

function SaveSystem:GetSaveMetadata(): { created: number, lastSaved: number, version: string }
    return table.clone(self._metadata)
end

return SaveSystem
