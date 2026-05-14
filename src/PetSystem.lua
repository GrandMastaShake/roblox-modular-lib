--!strict
-- PetSystem.lua
-- Pet ownership, hatching, leveling, tricks, moods, accessories, and neon crafting.
-- 20 default pets, 4 eggs with weighted rarity rolls, XP-based aging,
-- per-tick mood decay (via TimerSystem), and Destroy() cleanup.
--
-- ZERO HARD-COUPLING: dependencies are injected via constructor.
-- Inline structural types (EventBus, Inventory, XPSystem, TimerSystem) keep
-- this module decoupled while remaining --!strict compatible.

-- ---------------------------------------------------------------------------
-- Inline structural types (Luau structural typing — no require needed)
-- ---------------------------------------------------------------------------

type EventBus = {
    Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
    Emit: (self: EventBus, eventName: string, payload: any) -> (),
}

type Inventory = {
    AddItem:    (self: Inventory, itemId: string, quantity: number) -> boolean,
    RemoveItem: (self: Inventory, itemId: string, quantity: number) -> boolean,
    GetAllSlots: (self: Inventory) -> { { itemId: string, quantity: number } },
}

type XPSystem = {
    AddXP:    (self: XPSystem, amount: number) -> (),
    GetLevel: (self: XPSystem) -> number,
}

type TimerSystem = {
    StartTimer: (self: TimerSystem, duration: number, callback: () -> (), loop: boolean) -> string,
    StopTimer:  (self: TimerSystem, timerId: string) -> (),
}

-- ---------------------------------------------------------------------------
-- Module table
-- ---------------------------------------------------------------------------

local PetSystem = {}
PetSystem.__index = PetSystem

-- ---------------------------------------------------------------------------
-- Type aliases (exported for consumers)
-- ---------------------------------------------------------------------------

export type PetRarity = "common" | "uncommon" | "rare" | "ultra-rare" | "legendary"
export type PetStage  = "egg" | "newborn" | "junior" | "pre-teen" | "teen" | "post-teen" | "full-grown"
export type PetMood   = "happy" | "hungry" | "sleepy" | "playful" | "sick" | "excited"

export type PetDef = {
    id:           string,
    name:         string,
    rarity:       PetRarity,
    modelId:      string,
    tricks:       { string },
    favoriteFoods:{ string },
    flyable:      boolean,
    rideable:     boolean,
}

export type OwnedPet = {
    instanceId:    string,
    defId:         string,
    name:          string,
    rarity:        PetRarity,
    stage:         PetStage,
    xp:            number,
    mood:          PetMood,
    moodValue:     number,
    hunger:        number,
    energy:        number,
    fun:           number,
    accessories:   { string },
    isNeon:        boolean,
    isFly:         boolean,
    isRide:        boolean,
    lastFed:       number,
    lastPlayed:    number,
    learnedTricks: { string },
}

export type EggDef = {
    id:            string,
    name:          string,
    rarityWeights: { [PetRarity]: number },
}

export type PetSystem = {
    -- Registration
    RegisterPet:  (self: PetSystem, def: PetDef)  -> (),
    RegisterEgg:  (self: PetSystem, def: EggDef)  -> (),

    -- Hatching & access
    HatchEgg:    (self: PetSystem, eggItemId: string) -> OwnedPet?,
    GetPet:      (self: PetSystem, instanceId: string) -> OwnedPet?,
    GetAllPets:  (self: PetSystem) -> { OwnedPet },

    -- Care
    FeedPet:     (self: PetSystem, instanceId: string, foodItemId: string) -> boolean,
    PlayWithPet: (self: PetSystem, instanceId: string) -> boolean,

    -- Tricks
    TeachTrick:  (self: PetSystem, instanceId: string, trickId: string) -> boolean,
    DoTrick:     (self: PetSystem, instanceId: string, trickId: string) -> boolean,

    -- Accessories
    EquipAccessory: (self: PetSystem, instanceId: string, accessoryId: string) -> boolean,

    -- Aging & neon
    AgeUpPet: (self: PetSystem, instanceId: string) -> boolean,
    MakeNeon: (self: PetSystem, instanceIds: { string }) -> OwnedPet?,

    -- Equipped
    GetEquippedPet: (self: PetSystem) -> OwnedPet?,
    SetEquippedPet: (self: PetSystem, instanceId: string?) -> (),

    -- Mood
    UpdateMood: (self: PetSystem, dt: number) -> (),

    -- Save / load
    Serialize:   (self: PetSystem, userId: number?) -> { OwnedPet },
    Deserialize: (self: PetSystem, data: { OwnedPet }) -> (),

    -- Cleanup
    Destroy: (self: PetSystem) -> (),

    -- Internals
    _eventBus:          EventBus,
    _inventory:         Inventory,
    _xpSystem:          XPSystem,
    _timer:             TimerSystem,
    _definitions:       { [string]: PetDef },
    _eggDefs:           { [string]: EggDef },
    _ownedPets:         { [string]: OwnedPet },
    _equippedInstanceId:string?,
    _moodTimerId:       string?,
    _instanceCounter:   number,
}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local STAGES: { PetStage } = { "newborn", "junior", "pre-teen", "teen", "post-teen", "full-grown" }

local STAGE_XP: { [PetStage]: number } = {
    newborn       = 0,
    junior        = 50,
    ["pre-teen"]  = 150,
    teen          = 300,
    ["post-teen"] = 500,
    ["full-grown"]= 800,
}

local ALL_TRICKS: { string } = { "Sit", "Lay Down", "Roll Over", "Dance", "Backflip", "Bounce" }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function _clamp01(v: number): number
    return math.clamp(v, 0, 100)
end

local function _deepCopyPet(pet: OwnedPet): OwnedPet
    return {
        instanceId     = pet.instanceId,
        defId          = pet.defId,
        name           = pet.name,
        rarity         = pet.rarity,
        stage          = pet.stage,
        xp             = pet.xp,
        mood           = pet.mood,
        moodValue      = pet.moodValue,
        hunger         = pet.hunger,
        energy         = pet.energy,
        fun            = pet.fun,
        accessories    = table.clone(pet.accessories),
        isNeon         = pet.isNeon,
        isFly          = pet.isFly,
        isRide         = pet.isRide,
        lastFed        = pet.lastFed,
        lastPlayed     = pet.lastPlayed,
        learnedTricks  = table.clone(pet.learnedTricks),
    }
end

local function _indexOf(arr: { string }, val: string): number
    for i, v in ipairs(arr) do
        if v == val then
            return i
        end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function PetSystem.new(
    eventBus: EventBus,
    inventory: Inventory,
    xpSystem: XPSystem,
    timer: TimerSystem
): PetSystem
    local self = setmetatable({}, PetSystem) :: PetSystem

    self._eventBus       = eventBus
    self._inventory      = inventory
    self._xpSystem       = xpSystem
    self._timer          = timer
    self._definitions    = {}
    self._eggDefs        = {}
    self._ownedPets      = {}
    self._equippedInstanceId = nil
    self._instanceCounter    = 0

    -- Register 20 default pets
    local defaultPets: { PetDef } = {
        -- Common
        { id = "dog",    name = "Dog",    rarity = "common", modelId = "rbxassetid://pet_dog",    tricks = { "Sit", "Lay Down" }, favoriteFoods = { "dog_food", "treat" },    flyable = false, rideable = false },
        { id = "cat",    name = "Cat",    rarity = "common", modelId = "rbxassetid://pet_cat",    tricks = { "Sit", "Lay Down" }, favoriteFoods = { "cat_food", "fish" },     flyable = false, rideable = false },
        { id = "bunny",  name = "Bunny",  rarity = "common", modelId = "rbxassetid://pet_bunny",  tricks = { "Sit", "Bounce" },  favoriteFoods = { "carrot", "lettuce" },     flyable = false, rideable = false },
        { id = "blue_dog", name = "Blue Dog", rarity = "common", modelId = "rbxassetid://pet_blue_dog", tricks = { "Sit", "Lay Down" }, favoriteFoods = { "dog_food", "treat" }, flyable = false, rideable = false },
        -- Uncommon
        { id = "bear",   name = "Bear",   rarity = "uncommon", modelId = "rbxassetid://pet_bear",   tricks = { "Sit", "Dance" },    favoriteFoods = { "honey", "berries" },    flyable = false, rideable = false },
        { id = "fox",    name = "Fox",    rarity = "uncommon", modelId = "rbxassetid://pet_fox",    tricks = { "Sit", "Roll Over" },favoriteFoods = { "chicken", "berries" },  flyable = false, rideable = false },
        { id = "wolf",   name = "Wolf",   rarity = "uncommon", modelId = "rbxassetid://pet_wolf",   tricks = { "Sit", "Lay Down" }, favoriteFoods = { "meat", "bones" },       flyable = false, rideable = false },
        { id = "chocolate_labrador", name = "Chocolate Labrador", rarity = "uncommon", modelId = "rbxassetid://pet_choc_lab", tricks = { "Sit", "Lay Down", "Roll Over" }, favoriteFoods = { "dog_food" }, flyable = false, rideable = false },
        -- Rare
        { id = "turtle",   name = "Turtle",   rarity = "rare", modelId = "rbxassetid://pet_turtle",   tricks = { "Sit", "Lay Down", "Roll Over" }, favoriteFoods = { "lettuce", "seaweed" }, flyable = false, rideable = false },
        { id = "kangaroo", name = "Kangaroo", rarity = "rare", modelId = "rbxassetid://pet_kangaroo", tricks = { "Sit", "Bounce", "Backflip" },     favoriteFoods = { "carrot", "grass" },    flyable = false, rideable = false },
        { id = "elephant", name = "Elephant", rarity = "rare", modelId = "rbxassetid://pet_elephant", tricks = { "Sit", "Dance" },                  favoriteFoods = { "peanuts", "banana" },  flyable = false, rideable = false },
        { id = "hyena",    name = "Hyena",    rarity = "rare", modelId = "rbxassetid://pet_hyena",    tricks = { "Sit", "Roll Over" },               favoriteFoods = { "meat", "bones" },      flyable = false, rideable = false },
        -- Ultra-Rare
        { id = "giraffe", name = "Giraffe", rarity = "ultra-rare", modelId = "rbxassetid://pet_giraffe", tricks = { "Sit", "Lay Down", "Dance" }, favoriteFoods = { "leaves", "apple" },  flyable = true,  rideable = true  },
        { id = "parrot",  name = "Parrot",  rarity = "ultra-rare", modelId = "rbxassetid://pet_parrot",  tricks = { "Sit", "Dance" },              favoriteFoods = { "seeds", "cracker" }, flyable = true,  rideable = false },
        { id = "owl",     name = "Owl",     rarity = "ultra-rare", modelId = "rbxassetid://pet_owl",     tricks = { "Sit", "Lay Down" },           favoriteFoods = { "seeds", "mouse" },   flyable = true,  rideable = false },
        { id = "crow",    name = "Crow",    rarity = "ultra-rare", modelId = "rbxassetid://pet_crow",    tricks = { "Sit", "Lay Down" },           favoriteFoods = { "seeds", "berries" }, flyable = true,  rideable = false },
        -- Legendary
        { id = "dragon",  name = "Dragon",        rarity = "legendary", modelId = "rbxassetid://pet_dragon",  tricks = ALL_TRICKS, favoriteFoods = { "meat", "golden_apple" },           flyable = true, rideable = true },
        { id = "unicorn", name = "Unicorn",        rarity = "legendary", modelId = "rbxassetid://pet_unicorn", tricks = ALL_TRICKS, favoriteFoods = { "apple", "rainbow_cake" },          flyable = true, rideable = true },
        { id = "griffin", name = "Griffin",        rarity = "legendary", modelId = "rbxassetid://pet_griffin", tricks = ALL_TRICKS, favoriteFoods = { "meat", "golden_apple" },           flyable = true, rideable = true },
        { id = "shadow",  name = "Shadow Dragon",  rarity = "legendary", modelId = "rbxassetid://pet_shadow",  tricks = ALL_TRICKS, favoriteFoods = { "shadow_berry", "dark_chocolate" }, flyable = true, rideable = true },
    }
    for _, def in ipairs(defaultPets) do
        self:RegisterPet(def)
    end

    -- Register 4 default eggs
    local defaultEggs: { EggDef } = {
        {
            id = "starter_egg", name = "Starter Egg",
            rarityWeights = { common = 100, uncommon = 0, rare = 0, ["ultra-rare"] = 0, legendary = 0 },
        },
        {
            id = "cracked_egg", name = "Cracked Egg",
            rarityWeights = { common = 45, uncommon = 33, rare = 14.5, ["ultra-rare"] = 6, legendary = 1.5 },
        },
        {
            id = "pet_egg", name = "Pet Egg",
            rarityWeights = { common = 20, uncommon = 35, rare = 27, ["ultra-rare"] = 15, legendary = 3 },
        },
        {
            id = "royal_egg", name = "Royal Egg",
            rarityWeights = { common = 0, uncommon = 25, rare = 37, ["ultra-rare"] = 30, legendary = 8 },
        },
    }
    for _, egg in ipairs(defaultEggs) do
        self:RegisterEgg(egg)
    end

    -- Start mood-decay timer (every 60 seconds)
    self._moodTimerId = timer:StartTimer(60, function()
        self:UpdateMood(60)
    end, true)

    return self
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

function PetSystem:RegisterPet(def: PetDef)
    self._definitions[def.id] = def
    self._eventBus:Emit("PetRegistered", {
        petId  = def.id,
        name   = def.name,
        rarity = def.rarity,
    })
end

function PetSystem:RegisterEgg(def: EggDef)
    self._eggDefs[def.id] = def
end

-- ---------------------------------------------------------------------------
-- Hatch egg
-- ---------------------------------------------------------------------------

function PetSystem:HatchEgg(eggItemId: string): OwnedPet?
    local eggDef = self._eggDefs[eggItemId]
    if not eggDef then
        warn("[PetSystem] Unknown egg '" .. eggItemId .. "'")
        return nil
    end

    -- Consume egg from inventory
    local removed = self._inventory:RemoveItem(eggItemId, 1)
    if not removed then
        warn("[PetSystem] Player does not have egg '" .. eggItemId .. "'")
        return nil
    end

    -- Roll rarity
    local roll = math.random(1, 100)
    local cumulative = 0
    local chosenRarity: PetRarity = "common"
    for _, rarity in ipairs({ "common", "uncommon", "rare", "ultra-rare", "legendary" }) do
        local weight = eggDef.rarityWeights[rarity :: PetRarity] or 0
        cumulative += weight
        if roll <= cumulative then
            chosenRarity = rarity :: PetRarity
            break
        end
    end

    -- Pick a random pet of that rarity
    local candidates: { PetDef } = {}
    for _, def in pairs(self._definitions) do
        if def.rarity == chosenRarity then
            table.insert(candidates, def)
        end
    end
    if #candidates == 0 then
        warn("[PetSystem] No pets found for rarity '" .. chosenRarity .. "'")
        return nil
    end

    local chosenDef = candidates[math.random(1, #candidates)]

    self._instanceCounter += 1
    local instanceId = "pet_" .. tostring(self._instanceCounter) .. "_" .. tostring(os.clock())

    local owned: OwnedPet = {
        instanceId    = instanceId,
        defId         = chosenDef.id,
        name          = chosenDef.name,
        rarity        = chosenRarity,
        stage         = "newborn",
        xp            = 0,
        mood          = "happy",
        moodValue     = 80,
        hunger        = 80,
        energy        = 80,
        fun           = 80,
        accessories   = {},
        isNeon        = false,
        isFly         = chosenDef.flyable,
        isRide        = chosenDef.rideable,
        lastFed       = os.time(),
        lastPlayed    = os.time(),
        learnedTricks = {},
    }

    self._ownedPets[instanceId] = owned

    self._eventBus:Emit("EggHatched", {
        eggId      = eggItemId,
        petId      = chosenDef.id,
        petName    = chosenDef.name,
        instanceId = instanceId,
        rarity     = chosenRarity,
        stage      = "newborn",
    })

    return _deepCopyPet(owned)
end

-- ---------------------------------------------------------------------------
-- Get pet(s)
-- ---------------------------------------------------------------------------

function PetSystem:GetPet(instanceId: string): OwnedPet?
    local pet = self._ownedPets[instanceId]
    return pet and _deepCopyPet(pet) or nil
end

function PetSystem:GetAllPets(): { OwnedPet }
    local result: { OwnedPet } = {}
    for _, pet in pairs(self._ownedPets) do
        table.insert(result, _deepCopyPet(pet))
    end
    return result
end

-- Returns a flat list of all owned pets suitable for DataStore persistence.
function PetSystem:Serialize(userId: number?): { OwnedPet }
    return self:GetAllPets()
end

-- Restores owned pets from a previously serialized list (e.g. loaded from DataStore).
function PetSystem:Deserialize(data: { OwnedPet }): ()
    for _, petData in ipairs(data) do
        if petData.instanceId and petData.defId then
            self._ownedPets[petData.instanceId] = petData
        end
    end
end

-- ---------------------------------------------------------------------------
-- Care: Feed / Play
-- ---------------------------------------------------------------------------

function PetSystem:FeedPet(instanceId: string, foodItemId: string): boolean
    local pet = self._ownedPets[instanceId]
    if not pet then
        warn("[PetSystem] Pet '" .. instanceId .. "' not found")
        return false
    end

    local removed = self._inventory:RemoveItem(foodItemId, 1)
    if not removed then
        warn("[PetSystem] Food '" .. foodItemId .. "' not in inventory")
        return false
    end

    pet.hunger   = _clamp01(pet.hunger + 30)
    pet.lastFed  = os.time()

    -- Favourite food bonus
    local def = self._definitions[pet.defId]
    if def then
        for _, fav in ipairs(def.favoriteFoods) do
            if fav == foodItemId then
                pet.hunger = _clamp01(pet.hunger + 10)
                pet.fun    = _clamp01(pet.fun + 10)
                break
            end
        end
    end

    self:_reevaluateMood(pet)

    self._eventBus:Emit("PetFed", {
        instanceId = instanceId,
        foodItemId = foodItemId,
        hunger     = pet.hunger,
        mood       = pet.mood,
    })

    return true
end

function PetSystem:PlayWithPet(instanceId: string): boolean
    local pet = self._ownedPets[instanceId]
    if not pet then
        warn("[PetSystem] Pet '" .. instanceId .. "' not found")
        return false
    end

    pet.fun        = _clamp01(pet.fun + 30)
    pet.energy     = _clamp01(pet.energy - 5)
    pet.lastPlayed = os.time()

    self:_reevaluateMood(pet)

    self._eventBus:Emit("PetPlayed", {
        instanceId = instanceId,
        fun        = pet.fun,
        energy     = pet.energy,
        mood       = pet.mood,
    })

    return true
end

-- ---------------------------------------------------------------------------
-- Tricks
-- ---------------------------------------------------------------------------

function PetSystem:TeachTrick(instanceId: string, trickId: string): boolean
    local pet = self._ownedPets[instanceId]
    if not pet then
        warn("[PetSystem] Pet '" .. instanceId .. "' not found")
        return false
    end

    if _indexOf(ALL_TRICKS, trickId) == 0 then
        warn("[PetSystem] Unknown trick '" .. trickId .. "'")
        return false
    end

    if _indexOf(pet.learnedTricks, trickId) > 0 then
        return false -- already learned
    end

    local def = self._definitions[pet.defId]
    if def then
        local canLearn = false
        for _, t in ipairs(def.tricks) do
            if t == trickId then canLearn = true break end
        end
        if not canLearn then
            warn("[PetSystem] Pet '" .. pet.defId .. "' cannot learn trick '" .. trickId .. "'")
            return false
        end
    end

    table.insert(pet.learnedTricks, trickId)
    pet.xp += 10
    self:_tryAgeUp(pet)

    self._eventBus:Emit("TrickTaught", {
        instanceId = instanceId,
        trickId    = trickId,
        xp         = pet.xp,
    })

    return true
end

function PetSystem:DoTrick(instanceId: string, trickId: string): boolean
    local pet = self._ownedPets[instanceId]
    if not pet then
        warn("[PetSystem] Pet '" .. instanceId .. "' not found")
        return false
    end

    if _indexOf(pet.learnedTricks, trickId) == 0 then
        warn("[PetSystem] Pet has not learned trick '" .. trickId .. "'")
        return false
    end

    pet.xp     += 5
    pet.fun     = _clamp01(pet.fun + 5)
    pet.energy  = _clamp01(pet.energy - 3)
    self:_tryAgeUp(pet)
    self:_reevaluateMood(pet)

    self._eventBus:Emit("TrickDone", {
        instanceId = instanceId,
        trickId    = trickId,
        xp         = pet.xp,
    })

    return true
end

-- ---------------------------------------------------------------------------
-- Accessories
-- ---------------------------------------------------------------------------

function PetSystem:EquipAccessory(instanceId: string, accessoryId: string): boolean
    local pet = self._ownedPets[instanceId]
    if not pet then
        warn("[PetSystem] Pet '" .. instanceId .. "' not found")
        return false
    end

    for _, acc in ipairs(pet.accessories) do
        if acc == accessoryId then return false end
    end

    table.insert(pet.accessories, accessoryId)

    self._eventBus:Emit("AccessoryEquipped", {
        instanceId  = instanceId,
        accessoryId = accessoryId,
        accessories = table.clone(pet.accessories),
    })

    return true
end

-- ---------------------------------------------------------------------------
-- Aging
-- ---------------------------------------------------------------------------

function PetSystem:_tryAgeUp(pet: OwnedPet)
    local currentIdx = _indexOf(STAGES, pet.stage)
    if currentIdx == 0 or currentIdx >= #STAGES then return end
    local nextStage = STAGES[currentIdx + 1]
    local xpNeeded  = STAGE_XP[nextStage]
    if xpNeeded and pet.xp >= xpNeeded then
        local oldStage = pet.stage
        pet.stage = nextStage
        self._eventBus:Emit("PetAgedUp", {
            instanceId = pet.instanceId,
            oldStage   = oldStage,
            newStage   = nextStage,
            xp         = pet.xp,
        })
    end
end

function PetSystem:AgeUpPet(instanceId: string): boolean
    local pet = self._ownedPets[instanceId]
    if not pet then
        warn("[PetSystem] Pet '" .. instanceId .. "' not found")
        return false
    end

    local currentIdx = _indexOf(STAGES, pet.stage)
    if currentIdx == 0 or currentIdx >= #STAGES then return false end

    local nextStage = STAGES[currentIdx + 1]
    local xpNeeded  = STAGE_XP[nextStage]
    if xpNeeded then
        pet.xp = xpNeeded
        self:_tryAgeUp(pet)
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Neon crafting: consume 4 full-grown identical pets → 1 neon
-- ---------------------------------------------------------------------------

function PetSystem:MakeNeon(instanceIds: { string }): OwnedPet?
    if #instanceIds ~= 4 then
        warn("[PetSystem] MakeNeon requires exactly 4 pets, got " .. tostring(#instanceIds))
        return nil
    end

    local targetDefId: string? = nil
    for _, id in ipairs(instanceIds) do
        local pet = self._ownedPets[id]
        if not pet then
            warn("[PetSystem] Pet '" .. id .. "' not found")
            return nil
        end
        if pet.stage ~= "full-grown" then
            warn("[PetSystem] Pet '" .. id .. "' is not full-grown (stage: " .. pet.stage .. ")")
            return nil
        end
        if targetDefId == nil then
            targetDefId = pet.defId
        elseif pet.defId ~= targetDefId then
            warn("[PetSystem] All 4 pets must be the same type for neon crafting")
            return nil
        end
    end

    if not targetDefId then return nil end

    -- Consume the 4 source pets
    for _, id in ipairs(instanceIds) do
        self._ownedPets[id] = nil
    end

    -- Clear equipped if one of the consumed pets was equipped
    if self._equippedInstanceId then
        for _, id in ipairs(instanceIds) do
            if id == self._equippedInstanceId then
                self._equippedInstanceId = nil
                break
            end
        end
    end

    self._instanceCounter += 1
    local instanceId = "pet_neon_" .. tostring(self._instanceCounter) .. "_" .. tostring(os.clock())

    local def = self._definitions[targetDefId]
    local neonPet: OwnedPet = {
        instanceId    = instanceId,
        defId         = targetDefId,
        name          = (def and def.name or "Unknown") .. " (Neon)",
        stage         = "full-grown",
        xp            = 800,
        mood          = "happy",
        moodValue     = 100,
        hunger        = 100,
        energy        = 100,
        fun           = 100,
        accessories   = {},
        isNeon        = true,
        isFly         = def and def.flyable or false,
        isRide        = def and def.rideable or false,
        lastFed       = os.time(),
        lastPlayed    = os.time(),
        learnedTricks = {},
    }

    self._ownedPets[instanceId] = neonPet

    self._eventBus:Emit("NeonCreated", {
        instanceId  = instanceId,
        defId       = targetDefId,
        name        = neonPet.name,
        sourcePets  = instanceIds,
    })

    return _deepCopyPet(neonPet)
end

-- ---------------------------------------------------------------------------
-- Equipped pet
-- ---------------------------------------------------------------------------

function PetSystem:GetEquippedPet(): OwnedPet?
    if not self._equippedInstanceId then return nil end
    return self:GetPet(self._equippedInstanceId)
end

function PetSystem:SetEquippedPet(instanceId: string?)
    if instanceId == nil then
        self._equippedInstanceId = nil
        return
    end
    if not self._ownedPets[instanceId] then
        warn("[PetSystem] Cannot equip unknown pet '" .. tostring(instanceId) .. "'")
        return
    end
    self._equippedInstanceId = instanceId
end

-- ---------------------------------------------------------------------------
-- Mood system
-- ---------------------------------------------------------------------------

function PetSystem:_reevaluateMood(pet: OwnedPet)
    local oldMood = pet.mood
    local newMood: PetMood = "happy"

    if pet.hunger < 20 then
        newMood = "hungry"
    elseif pet.energy < 20 then
        newMood = "sleepy"
    elseif pet.fun < 20 then
        newMood = "playful"
    elseif pet.hunger > 50 and pet.energy > 50 and pet.fun > 50 then
        newMood = "happy"
    end

    pet.moodValue = math.floor((pet.hunger + pet.energy + pet.fun) / 3)
    pet.mood      = newMood

    if oldMood ~= newMood then
        self._eventBus:Emit("MoodChanged", {
            instanceId = pet.instanceId,
            oldMood    = oldMood,
            newMood    = newMood,
            moodValue  = pet.moodValue,
        })
    end
end

function PetSystem:UpdateMood(dt: number)
    local decay = dt / 60
    for _, pet in pairs(self._ownedPets) do
        pet.hunger = _clamp01(pet.hunger - decay)
        pet.energy = _clamp01(pet.energy - decay)
        pet.fun    = _clamp01(pet.fun    - decay)
        self:_reevaluateMood(pet)
    end
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------

function PetSystem:Destroy()
    if self._moodTimerId then
        self._timer:StopTimer(self._moodTimerId)
        self._moodTimerId = nil
    end
end

return PetSystem
