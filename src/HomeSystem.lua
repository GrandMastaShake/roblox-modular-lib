--!strict
-- HomeSystem.lua
-- Furniture placement, room management, and home customization.
-- Adopt Me-style home building with 30 furniture items, 5 home types,
-- collision-aware placement, and room painting.

-- ---------------------------------------------------------------------------
-- Inline structural types (no require coupling)
-- ---------------------------------------------------------------------------
type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
}

type Inventory = {
	AddItem:     (self: Inventory, itemId: string, quantity: number) -> boolean,
	RemoveItem:  (self: Inventory, itemId: string, quantity: number) -> boolean,
	GetAllSlots: (self: Inventory) -> { { itemId: string, quantity: number } },
}

type CurrencySystem = {
	CanAfford:  (self: CurrencySystem, currencyId: string, amount: number) -> boolean,
	Subtract:   (self: CurrencySystem, currencyId: string, amount: number, reason: string) -> boolean,
	Add:        (self: CurrencySystem, currencyId: string, amount: number, reason: string) -> (),
	GetBalance: (self: CurrencySystem, currencyId: string) -> number,
}

local HomeSystem = {}
HomeSystem.__index = HomeSystem

export type HomeType = "apartment" | "cottage" | "mansion" | "treehouse" | "castle"
export type RoomType = "living" | "bedroom" | "kitchen" | "bathroom" | "garden" | "garage"

export type FurnitureDef = {
	id: string,
	name: string,
	category: string,
	modelId: string,
	footprint: Vector2, -- studs (x, z)
	price: number,
	colorOptions: { Color3 }?,
	interactable: boolean, -- can player interact?
}

export type PlacedFurniture = {
	instanceId: string,
	defId: string,
	cframe: CFrame,
	color: Color3,
	roomId: string,
}

export type Room = {
	roomId: string,
	roomType: RoomType,
	furniture: { PlacedFurniture },
	size: Vector2,
	wallColor: Color3,
	floorColor: Color3,
}

export type Home = {
	homeId: string,
	ownerId: string,
	homeType: HomeType,
	rooms: { Room },
	name: string,
}

export type HomeDef = {
	homeType: HomeType,
	name: string,
	price: number,
	roomCount: number,
	roomTypes: { RoomType },
	roomSizes: { Vector2 },
}

export type HomeSystem = {
	RegisterFurniture:   (self: HomeSystem, def: FurnitureDef) -> (),
	BuyHome:             (self: HomeSystem, ownerId: string, homeType: HomeType) -> Home?,
	PlaceFurniture:      (self: HomeSystem, homeId: string, roomId: string, defId: string, cframe: CFrame, color: Color3?) -> PlacedFurniture?,
	MoveFurniture:       (self: HomeSystem, homeId: string, instanceId: string, newCFrame: CFrame) -> boolean,
	RemoveFurniture:     (self: HomeSystem, homeId: string, instanceId: string) -> boolean,
	PaintRoom:           (self: HomeSystem, homeId: string, roomId: string, wallColor: Color3, floorColor: Color3) -> (),
	GetHome:             (self: HomeSystem, homeId: string) -> Home?,
	GetPlayerHome:       (self: HomeSystem, playerId: string) -> Home?,
	ListFurnitureCatalog:(self: HomeSystem) -> { FurnitureDef },

	-- Private
	_eventBus:        EventBus,
	_inventory:       Inventory,
	_currency:        CurrencySystem,
	_furnitureDefs:   { [string]: FurnitureDef },
	_homeDefs:        { [HomeType]: HomeDef },
	_homes:           { [string]: Home },
	_playerHomes:     { [string]: string }, -- playerId -> homeId
	_nextInstanceId:  number,
}

-- ---------------------------------------------------------------------------
-- Helper: generate a unique instance id
-- ---------------------------------------------------------------------------
local function _generateId(prefix: string, counter: number): string
	return prefix .. "_" .. tostring(counter) .. "_" .. tostring(math.random(1000, 9999))
end

-- ---------------------------------------------------------------------------
-- Helper: AABB overlap check between two axis-aligned rectangles
-- ---------------------------------------------------------------------------
local function _aabbOverlap(
	ax: number, az: number, aw: number, ah: number,
	bx: number, bz: number, bw: number, bh: number
): boolean
	return ax < bx + bw and ax + aw > bx and az < bz + bh and az + ah > bz
end

-- ---------------------------------------------------------------------------
-- Helper: check if a furniture placement collides with existing furniture
-- ---------------------------------------------------------------------------
local function _checkCollision(
	placed: { PlacedFurniture },
	furnitureDefs: { [string]: FurnitureDef },
	newDefId: string,
	newCFrame: CFrame,
	excludeInstanceId: string?
): boolean
	local newDef = furnitureDefs[newDefId]
	if not newDef then
		return true -- invalid def = treat as collision
	end

	local newFx = newDef.footprint.X
	local newFz = newDef.footprint.Y
	local newPos = newCFrame.Position
	local newX = newPos.X - newFx / 2
	local newZ = newPos.Z - newFz / 2

	for _, existing in ipairs(placed) do
		if excludeInstanceId and existing.instanceId == excludeInstanceId then
			continue
		end
		local existingDef = furnitureDefs[existing.defId]
		if not existingDef then
			continue
		end
		local exFx = existingDef.footprint.X
		local exFz = existingDef.footprint.Y
		local exPos = existing.cframe.Position
		local exX = exPos.X - exFx / 2
		local exZ = exPos.Z - exFz / 2

		if _aabbOverlap(newX, newZ, newFx, newFz, exX, exZ, exFx, exFz) then
			return true -- collision detected
		end
	end

	return false -- no collision
end

-- ---------------------------------------------------------------------------
-- Helper: check if furniture is within room boundaries
-- ---------------------------------------------------------------------------
local function _inRoomBounds(room: Room, cframe: CFrame, footprint: Vector2): boolean
	local pos = cframe.Position
	local halfX = footprint.X / 2
	local halfZ = footprint.Y / 2
	local roomX = room.size.X
	local roomZ = room.size.Y

	-- Furniture must be fully inside [0, roomX] x [0, roomZ]
	local minX = pos.X - halfX
	local maxX = pos.X + halfX
	local minZ = pos.Z - halfZ
	local maxZ = pos.Z + halfZ

	return minX >= 0 and maxX <= roomX and minZ >= 0 and maxZ <= roomZ
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------
function HomeSystem.new(
	eventBus: EventBus,
	inventory: Inventory,
	currency: CurrencySystem
): HomeSystem
	local self = setmetatable({}, HomeSystem) :: HomeSystem
	self._eventBus       = eventBus
	self._inventory      = inventory
	self._currency       = currency
	self._furnitureDefs  = {}
	self._homeDefs       = {}
	self._homes          = {}
	self._playerHomes    = {}
	self._nextInstanceId = 1

	-- Register 5 home types
	local homeDefs: { HomeDef } = {
		{
			homeType  = "apartment" :: HomeType,
			name      = "Apartment",
			price     = 0,
			roomCount = 2,
			roomTypes = { "living", "bedroom" },
			roomSizes = { Vector2.new(16, 12), Vector2.new(10, 10) },
		},
		{
			homeType  = "cottage" :: HomeType,
			name      = "Cottage",
			price     = 500,
			roomCount = 3,
			roomTypes = { "living", "bedroom", "kitchen" },
			roomSizes = { Vector2.new(14, 12), Vector2.new(12, 10), Vector2.new(10, 8) },
		},
		{
			homeType  = "mansion" :: HomeType,
			name      = "Mansion",
			price     = 2000,
			roomCount = 5,
			roomTypes = { "living", "bedroom", "kitchen", "bathroom", "garden" },
			roomSizes = {
				Vector2.new(20, 16), Vector2.new(16, 14), Vector2.new(14, 12),
				Vector2.new(10, 8),  Vector2.new(24, 20),
			},
		},
		{
			homeType  = "treehouse" :: HomeType,
			name      = "Treehouse",
			price     = 1500,
			roomCount = 3,
			roomTypes = { "living", "bedroom", "garden" },
			roomSizes = { Vector2.new(12, 10), Vector2.new(10, 10), Vector2.new(18, 16) },
		},
		{
			homeType  = "castle" :: HomeType,
			name      = "Castle",
			price     = 5000,
			roomCount = 6,
			roomTypes = { "living", "bedroom", "kitchen", "bathroom", "garden", "garage" },
			roomSizes = {
				Vector2.new(24, 20), Vector2.new(18, 16), Vector2.new(16, 14),
				Vector2.new(12, 10), Vector2.new(30, 24), Vector2.new(20, 16),
			},
		},
	}

	for _, def in ipairs(homeDefs) do
		self._homeDefs[def.homeType] = def
	end

	-- Register 30 default furniture items
	local defaultFurniture: { FurnitureDef } = {
		-- Beds
		{ id = "bed_basic",   name = "Basic Bed",   category = "Beds",    modelId = "rbxassetid:bed_basic",   footprint = Vector2.new(4, 6), price = 100, interactable = true },
		{ id = "bed_bunk",    name = "Bunk Bed",     category = "Beds",    modelId = "rbxassetid:bed_bunk",    footprint = Vector2.new(4, 6), price = 250, interactable = true },
		{ id = "bed_canopy",  name = "Canopy Bed",   category = "Beds",    modelId = "rbxassetid:bed_canopy",  footprint = Vector2.new(6, 8), price = 500, interactable = true },
		-- Seating
		{ id = "chair_wooden", name = "Wooden Chair", category = "Seating", modelId = "rbxassetid:chair_wooden", footprint = Vector2.new(2, 2), price = 50,  interactable = true },
		{ id = "sofa",         name = "Sofa",          category = "Seating", modelId = "rbxassetid:sofa",         footprint = Vector2.new(6, 3), price = 200, interactable = true },
		{ id = "beanbag",      name = "Beanbag",        category = "Seating", modelId = "rbxassetid:beanbag",      footprint = Vector2.new(3, 3), price = 75,  interactable = true },
		{ id = "armchair",     name = "Armchair",       category = "Seating", modelId = "rbxassetid:armchair",     footprint = Vector2.new(3, 3), price = 150, interactable = true },
		-- Tables
		{ id = "table_coffee", name = "Coffee Table", category = "Tables", modelId = "rbxassetid:table_coffee", footprint = Vector2.new(3, 2), price = 80,  interactable = true },
		{ id = "table_dining", name = "Dining Table", category = "Tables", modelId = "rbxassetid:table_dining", footprint = Vector2.new(6, 4), price = 150, interactable = true },
		{ id = "desk",         name = "Desk",          category = "Tables", modelId = "rbxassetid:desk",         footprint = Vector2.new(4, 2), price = 120, interactable = true },
		-- Storage
		{ id = "bookshelf", name = "Bookshelf", category = "Storage", modelId = "rbxassetid:bookshelf", footprint = Vector2.new(4, 1), price = 100, interactable = true },
		{ id = "wardrobe",  name = "Wardrobe",  category = "Storage", modelId = "rbxassetid:wardrobe",  footprint = Vector2.new(4, 2), price = 180, interactable = true },
		{ id = "chest",     name = "Chest",     category = "Storage", modelId = "rbxassetid:chest",     footprint = Vector2.new(2, 1), price = 90,  interactable = true },
		-- Decor
		{ id = "tv",       name = "TV",       category = "Decor", modelId = "rbxassetid:tv",       footprint = Vector2.new(4, 1), price = 300, interactable = true },
		{ id = "lamp",     name = "Lamp",     category = "Decor", modelId = "rbxassetid:lamp",     footprint = Vector2.new(1, 1), price = 60,  interactable = true },
		{ id = "painting", name = "Painting", category = "Decor", modelId = "rbxassetid:painting", footprint = Vector2.new(2, 1), price = 150, interactable = false },
		{ id = "plant",    name = "Plant",    category = "Decor", modelId = "rbxassetid:plant",    footprint = Vector2.new(1, 1), price = 40,  interactable = false },
		{ id = "rug",      name = "Rug",      category = "Decor", modelId = "rbxassetid:rug",      footprint = Vector2.new(6, 4), price = 80,  interactable = false },
		{ id = "clock",    name = "Clock",    category = "Decor", modelId = "rbxassetid:clock",    footprint = Vector2.new(1, 1), price = 50,  interactable = false },
		-- Kitchen
		{ id = "fridge",  name = "Fridge",  category = "Kitchen", modelId = "rbxassetid:fridge",  footprint = Vector2.new(2, 2), price = 250, interactable = true },
		{ id = "stove",   name = "Stove",   category = "Kitchen", modelId = "rbxassetid:stove",   footprint = Vector2.new(2, 2), price = 200, interactable = true },
		{ id = "counter", name = "Counter", category = "Kitchen", modelId = "rbxassetid:counter", footprint = Vector2.new(2, 1), price = 100, interactable = true },
		{ id = "sink",    name = "Sink",    category = "Kitchen", modelId = "rbxassetid:sink",    footprint = Vector2.new(2, 2), price = 80,  interactable = true },
		-- Outdoor
		{ id = "mailbox",       name = "Mailbox",       category = "Outdoor", modelId = "rbxassetid:mailbox",       footprint = Vector2.new(1, 1), price = 30,  interactable = true },
		{ id = "garden_bench",  name = "Garden Bench",  category = "Outdoor", modelId = "rbxassetid:garden_bench",  footprint = Vector2.new(4, 2), price = 100, interactable = true },
		{ id = "fountain",      name = "Fountain",      category = "Outdoor", modelId = "rbxassetid:fountain",      footprint = Vector2.new(6, 6), price = 400, interactable = true },
		{ id = "flower_pot",    name = "Flower Pot",    category = "Outdoor", modelId = "rbxassetid:flower_pot",    footprint = Vector2.new(1, 1), price = 25,  interactable = false },
		{ id = "fence_section", name = "Fence Section", category = "Outdoor", modelId = "rbxassetid:fence_section", footprint = Vector2.new(4, 1), price = 40,  interactable = false },
		-- Misc
		{ id = "trophy_case", name = "Trophy Case", category = "Misc", modelId = "rbxassetid:trophy_case", footprint = Vector2.new(4, 2), price = 500, interactable = true },
		{ id = "piano",       name = "Piano",       category = "Misc", modelId = "rbxassetid:piano",       footprint = Vector2.new(4, 3), price = 800, interactable = true },
		{ id = "fireplace",   name = "Fireplace",   category = "Misc", modelId = "rbxassetid:fireplace",   footprint = Vector2.new(4, 1), price = 350, interactable = true },
	}

	for _, def in ipairs(defaultFurniture) do
		self:RegisterFurniture(def)
	end

	return self
end

-- ---------------------------------------------------------------------------
-- RegisterFurniture: add a furniture definition to the catalog
-- ---------------------------------------------------------------------------
function HomeSystem:RegisterFurniture(def: FurnitureDef)
	self._furnitureDefs[def.id] = def
	self._eventBus:Emit("FurnitureRegistered", {
		id       = def.id,
		name     = def.name,
		category = def.category,
		price    = def.price,
	})
end

-- ---------------------------------------------------------------------------
-- BuyHome: charge currency and create a home with rooms
-- ---------------------------------------------------------------------------
function HomeSystem:BuyHome(ownerId: string, homeType: HomeType): Home?
	local homeDef = self._homeDefs[homeType]
	if not homeDef then
		return nil
	end

	-- Check if player already owns a home
	if self._playerHomes[ownerId] then
		return nil
	end

	-- Charge Bucks (free homes skip currency check)
	if homeDef.price > 0 then
		if not self._currency:CanAfford("bucks", homeDef.price) then
			return nil
		end
		local ok = self._currency:Subtract("bucks", homeDef.price, "buy_home_" .. homeType)
		if not ok then
			return nil
		end
	end

	-- Create rooms
	local rooms: { Room } = {}
	for i = 1, homeDef.roomCount do
		local roomType = homeDef.roomTypes[i] or "living"
		local roomSize = homeDef.roomSizes[i] or Vector2.new(10, 10)
		local room: Room = {
			roomId    = "room_" .. tostring(i) .. "_" .. tostring(math.random(1000, 9999)),
			roomType  = roomType :: RoomType,
			furniture = {},
			size      = roomSize,
			wallColor  = Color3.fromRGB(230, 230, 230),
			floorColor = Color3.fromRGB(180, 160, 130),
		}
		table.insert(rooms, room)
	end

	-- Create home
	local homeId = _generateId("home", self._nextInstanceId)
	self._nextInstanceId += 1

	local home: Home = {
		homeId    = homeId,
		ownerId   = ownerId,
		homeType  = homeType,
		rooms     = rooms,
		name      = homeDef.name,
	}

	self._homes[homeId]       = home
	self._playerHomes[ownerId] = homeId

	self._eventBus:Emit("HomeBought", {
		homeId   = homeId,
		ownerId  = ownerId,
		homeType = homeType,
		name     = homeDef.name,
		price    = homeDef.price,
	})

	return home
end

-- ---------------------------------------------------------------------------
-- PlaceFurniture: check inventory, room bounds, collision; place if valid
-- ---------------------------------------------------------------------------
function HomeSystem:PlaceFurniture(
	homeId: string,
	roomId: string,
	defId: string,
	cframe: CFrame,
	color: Color3?
): PlacedFurniture?
	local home = self._homes[homeId]
	if not home then
		return nil
	end

	-- Find the room
	local room: Room? = nil
	for _, r in ipairs(home.rooms) do
		if r.roomId == roomId then
			room = r
			break
		end
	end
	if not room then
		return nil
	end

	-- Verify furniture definition exists
	local def = self._furnitureDefs[defId]
	if not def then
		return nil
	end

	-- Check inventory has this item (look for it in any slot)
	local hasItem = false
	local allSlots = self._inventory:GetAllSlots()
	for _, slot in ipairs(allSlots) do
		if slot.itemId == defId and slot.quantity > 0 then
			hasItem = true
			break
		end
	end
	if not hasItem then
		return nil
	end

	-- Check room boundaries
	if not _inRoomBounds(room, cframe, def.footprint) then
		return nil
	end

	-- Check collision with existing furniture
	if _checkCollision(room.furniture, self._furnitureDefs, defId, cframe, nil) then
		return nil
	end

	-- Deduct from inventory
	local removed = self._inventory:RemoveItem(defId, 1)
	if not removed then
		return nil
	end

	-- Create placed furniture
	local instanceId = _generateId("furn", self._nextInstanceId)
	self._nextInstanceId += 1

	local placedColor = color or Color3.fromRGB(163, 162, 165)
	local placed: PlacedFurniture = {
		instanceId = instanceId,
		defId      = defId,
		cframe     = cframe,
		color      = placedColor,
		roomId     = roomId,
	}

	table.insert(room.furniture, placed)

	self._eventBus:Emit("FurniturePlaced", {
		homeId     = homeId,
		roomId     = roomId,
		instanceId = instanceId,
		defId      = defId,
		name       = def.name,
		cframe     = cframe,
		color      = placedColor,
	})

	return placed
end

-- ---------------------------------------------------------------------------
-- MoveFurniture: relocate existing furniture to a new CFrame
-- ---------------------------------------------------------------------------
function HomeSystem:MoveFurniture(homeId: string, instanceId: string, newCFrame: CFrame): boolean
	local home = self._homes[homeId]
	if not home then
		return false
	end

	-- Find the furniture and its room
	for _, room in ipairs(home.rooms) do
		for _, furn in ipairs(room.furniture) do
			if furn.instanceId == instanceId then
				local def = self._furnitureDefs[furn.defId]
				if not def then
					return false
				end

				-- Check room boundaries
				if not _inRoomBounds(room, newCFrame, def.footprint) then
					return false
				end

				-- Check collision (excluding self)
				if _checkCollision(room.furniture, self._furnitureDefs, furn.defId, newCFrame, instanceId) then
					return false
				end

				-- Update position
				local oldCFrame = furn.cframe
				furn.cframe = newCFrame

				self._eventBus:Emit("FurnitureMoved", {
					homeId     = homeId,
					roomId     = room.roomId,
					instanceId = instanceId,
					defId      = furn.defId,
					oldCFrame  = oldCFrame,
					newCFrame  = newCFrame,
				})

				return true
			end
		end
	end

	return false
end

-- ---------------------------------------------------------------------------
-- RemoveFurniture: remove furniture from a room and return to inventory
-- ---------------------------------------------------------------------------
function HomeSystem:RemoveFurniture(homeId: string, instanceId: string): boolean
	local home = self._homes[homeId]
	if not home then
		return false
	end

	for _, room in ipairs(home.rooms) do
		for i, furn in ipairs(room.furniture) do
			if furn.instanceId == instanceId then
				-- Return to inventory
				self._inventory:AddItem(furn.defId, 1)

				-- Remove from room
				table.remove(room.furniture, i)

				self._eventBus:Emit("FurnitureRemoved", {
					homeId     = homeId,
					roomId     = room.roomId,
					instanceId = instanceId,
					defId      = furn.defId,
				})

				return true
			end
		end
	end

	return false
end

-- ---------------------------------------------------------------------------
-- PaintRoom: change wall and floor colors of a room
-- ---------------------------------------------------------------------------
function HomeSystem:PaintRoom(homeId: string, roomId: string, wallColor: Color3, floorColor: Color3)
	local home = self._homes[homeId]
	if not home then
		return
	end

	for _, room in ipairs(home.rooms) do
		if room.roomId == roomId then
			local oldWall  = room.wallColor
			local oldFloor = room.floorColor
			room.wallColor  = wallColor
			room.floorColor = floorColor

			self._eventBus:Emit("RoomPainted", {
				homeId       = homeId,
				roomId       = roomId,
				oldWallColor  = oldWall,
				oldFloorColor = oldFloor,
				newWallColor  = wallColor,
				newFloorColor = floorColor,
			})

			return
		end
	end
end

-- ---------------------------------------------------------------------------
-- GetHome: retrieve a home by id (returns deep copy to prevent mutation)
-- ---------------------------------------------------------------------------
function HomeSystem:GetHome(homeId: string): Home?
	local home = self._homes[homeId]
	if not home then
		return nil
	end

	local roomsCopy: { Room } = {}
	for _, room in ipairs(home.rooms) do
		local furnCopy: { PlacedFurniture } = {}
		for _, f in ipairs(room.furniture) do
			table.insert(furnCopy, {
				instanceId = f.instanceId,
				defId      = f.defId,
				cframe     = f.cframe,
				color      = f.color,
				roomId     = f.roomId,
			})
		end
		table.insert(roomsCopy, {
			roomId     = room.roomId,
			roomType   = room.roomType,
			furniture  = furnCopy,
			size       = room.size,
			wallColor  = room.wallColor,
			floorColor = room.floorColor,
		})
	end

	return {
		homeId   = home.homeId,
		ownerId  = home.ownerId,
		homeType = home.homeType,
		rooms    = roomsCopy,
		name     = home.name,
	}
end

-- ---------------------------------------------------------------------------
-- GetPlayerHome: retrieve the home owned by a player
-- ---------------------------------------------------------------------------
function HomeSystem:GetPlayerHome(playerId: string): Home?
	local homeId = self._playerHomes[playerId]
	if not homeId then
		return nil
	end
	return self:GetHome(homeId)
end

-- ---------------------------------------------------------------------------
-- ListFurnitureCatalog: return all registered furniture definitions
-- ---------------------------------------------------------------------------
function HomeSystem:ListFurnitureCatalog(): { FurnitureDef }
	local result: { FurnitureDef } = {}
	for _, def in pairs(self._furnitureDefs) do
		table.insert(result, {
			id           = def.id,
			name         = def.name,
			category     = def.category,
			modelId      = def.modelId,
			footprint    = def.footprint,
			price        = def.price,
			colorOptions = def.colorOptions,
			interactable = def.interactable,
		})
	end
	-- Sort by category then name for consistent display
	table.sort(result, function(a: FurnitureDef, b: FurnitureDef): boolean
		if a.category ~= b.category then
			return a.category < b.category
		end
		return a.name < b.name
	end)
	return result
end

return HomeSystem
