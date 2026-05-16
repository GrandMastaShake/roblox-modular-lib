--!strict
--[[
    SaveSystem v1.2.0
    Persistent world-state saving via an injected DataStore.
    Uses UpdateAsync (atomic, safe under concurrent server writes) for all saves.
    GetAsync is used for loads. The injected `dataStore` must expose both methods —
    a raw DataStore or a DataStoreSafe wrapper both qualify.
--]]

local SaveSystem = {}
SaveSystem.__index = SaveSystem

-- ── Types ────────────────────────────────────────────────────────────────────

export type WorldSaveData = {
    seed:             number,
    size:             number,
    modifiedChunks:   { [string]: ChunkSaveData },
    playerPlacements: { Placement },
    metadata:         { created: number, lastSaved: number, version: string },
}

export type ChunkSaveData = {
    cx: number, cz: number,
    heightmap:        { { number } },
    biomeMap:         { { string } },
    objectPlacements: { Placement },
    isModified:       boolean,
}

export type Placement = { x: number, y: number, z: number, objectId: string }
export type WorldData  = { seed: number, size: number, chunks: { [string]: ChunkData } }
export type ChunkData  = { cx: number, cz: number, heightmap: { { number } }, biomeMap: { { string } } }
export type EventBus   = { Emit: (any, string, any?) -> (), Subscribe: (any, string, (any?) -> ()) -> () }
export type Config     = { autoSaveInterval: number? }

export type SaveSystem = {
    SaveWorld:       (self: SaveSystem, worldData: WorldData) -> boolean,
    LoadWorld:       (self: SaveSystem) -> WorldSaveData?,
    SaveChunk:       (self: SaveSystem, chunk: ChunkData) -> boolean,
    LoadChunk:       (self: SaveSystem, cx: number, cz: number) -> ChunkSaveData?,
    QueueChunkSave:  (self: SaveSystem, cx: number, cz: number) -> (),
    FlushQueue:      (self: SaveSystem) -> boolean,
    AutoSave:        (self: SaveSystem, intervalSeconds: number) -> (),
    GetSaveMetadata: (self: SaveSystem) -> { created: number, lastSaved: number, version: string },
}

-- ── Keys ─────────────────────────────────────────────────────────────────────

local KEY_WORLD    = "world_main_v1"
local KEY_CHUNK    = "chunk_%d_%d_v1"   -- formatted with cx, cz
local SAVE_VERSION = "1.1.0"

-- ── Constructor ───────────────────────────────────────────────────────────────

function SaveSystem.new(eventBus: EventBus, dataStore: any, config: Config?): SaveSystem
    local self = setmetatable({}, SaveSystem)
    self._eventBus  = eventBus
    self._dataStore = dataStore
    self._config    = config or { autoSaveInterval = 60 }
    self._saveQueue = {} :: { [string]: boolean }
    self._metadata  = { created = os.time(), lastSaved = 0, version = SAVE_VERSION }
    return self :: any
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- UpdateAsync is atomic under concurrent server access — safer than SetAsync.
-- The transform function always returns the new data, ignoring the old value
-- (last-write-wins per key, which is correct for chunk and world snapshots).
local function _safeUpdate(ds: any, key: string, data: any): boolean
    local ok, err = pcall(function()
        ds:UpdateAsync(key, function(_old: any)
            return data
        end)
    end)
    if not ok then
        warn("[SaveSystem] UpdateAsync failed for key '" .. key .. "': " .. tostring(err))
    end
    return ok
end

local function _safeGet(ds: any, key: string): (boolean, any)
    local ok, result = pcall(function()
        return ds:GetAsync(key)
    end)
    if not ok then
        warn("[SaveSystem] GetAsync failed for key '" .. key .. "': " .. tostring(result))
        return false, nil
    end
    return true, result
end

-- ── Public API ────────────────────────────────────────────────────────────────

function SaveSystem:SaveWorld(worldData: WorldData): boolean
    local payload = {
        seed             = worldData.seed,
        size             = worldData.size,
        metadata         = {
            created    = self._metadata.created,
            lastSaved  = os.time(),
            version    = SAVE_VERSION,
        },
    }
    local ok = _safeUpdate(self._dataStore, KEY_WORLD, payload)
    if ok then
        self._metadata.lastSaved = os.time()
        self._eventBus:Emit("WorldSaved", worldData)
    end
    return ok
end

function SaveSystem:LoadWorld(): WorldSaveData?
    local ok, data = _safeGet(self._dataStore, KEY_WORLD)
    if not ok or data == nil then return nil end
    self._eventBus:Emit("WorldLoaded", data)
    return data :: WorldSaveData
end

function SaveSystem:SaveChunk(chunk: ChunkData): boolean
    local key = string.format(KEY_CHUNK, chunk.cx, chunk.cz)
    local ok = _safeUpdate(self._dataStore, key, chunk)
    if ok then
        self._saveQueue[string.format("%d_%d", chunk.cx, chunk.cz)] = nil
        self._eventBus:Emit("ChunkSaved", chunk)
    end
    return ok
end

function SaveSystem:LoadChunk(cx: number, cz: number): ChunkSaveData?
    local key = string.format(KEY_CHUNK, cx, cz)
    local ok, data = _safeGet(self._dataStore, key)
    if not ok or data == nil then return nil end
    self._eventBus:Emit("ChunkLoaded", { cx = cx, cz = cz })
    return data :: ChunkSaveData
end

function SaveSystem:QueueChunkSave(cx: number, cz: number): ()
    self._saveQueue[string.format("%d_%d", cx, cz)] = true
end

function SaveSystem:FlushQueue(): boolean
    local allOk = true
    local count = 0
    for key in pairs(self._saveQueue) do
        -- Parse "cx_cz" back to numbers.
        local cx, cz = string.match(key, "^(-?%d+)_(-?%d+)$")
        if cx and cz then
            local cxn, czn = tonumber(cx), tonumber(cz)
            if cxn and czn then
                local chunkData: ChunkData = { cx = cxn, cz = czn, heightmap = {}, biomeMap = {} }
                local ok = self:SaveChunk(chunkData)
                if not ok then allOk = false end
                count += 1
            end
        end
    end
    self._saveQueue = {}
    self._eventBus:Emit("AutoSaveTriggered", { chunksFlushed = count, allOk = allOk })
    return allOk
end

function SaveSystem:AutoSave(intervalSeconds: number): ()
    task.spawn(function()
        while true do
            task.wait(intervalSeconds)
            self:FlushQueue()
        end
    end)
end

function SaveSystem:GetSaveMetadata(): { created: number, lastSaved: number, version: string }
    return table.clone(self._metadata)
end

return SaveSystem
