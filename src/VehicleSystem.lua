--!strict
-- VehicleSystem.lua
-- Drivable vehicles with physics for Adopt Me-style gameplay.
-- 10 default vehicles across 5 categories: car, bike, hoverboard, helicopter, boat.
-- Primitive-based model spawning (no asset IDs required), BodyVelocity driving,
-- per-vehicle paint, and equip/unequip flow.
--
-- ZERO HARD-COUPLING: all dependencies injected via constructor.
-- Inline structural types keep this module --!strict compatible.

-- ---------------------------------------------------------------------------
-- Inline structural types (Luau structural typing — no require needed)
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

-- ---------------------------------------------------------------------------
-- Module table
-- ---------------------------------------------------------------------------

local VehicleSystem = {}
VehicleSystem.__index = VehicleSystem

-- ---------------------------------------------------------------------------
-- Type aliases (exported)
-- ---------------------------------------------------------------------------

export type VehicleCategory = "car" | "bike" | "hoverboard" | "helicopter" | "boat"

export type VehicleDef = {
    id:       string,
    name:     string,
    category: VehicleCategory,
    modelId:  string,
    speed:    number,
    seats:    number,
    price:    number,
    rarity:   string,
}

export type OwnedVehicle = {
    instanceId: string,
    defId:      string,
    color:      Color3,
    equipped:   boolean,
}

export type ActiveVehicle = {
    model:          Model,
    vehicleSeat:    VehicleSeat,
    bodyVelocity:   BodyVelocity,
    connection:     RBXScriptConnection?,
    ownedVehicleId: string,
}

export type VehicleSystem = {
    RegisterVehicle:   (self: VehicleSystem, def: VehicleDef) -> (),
    GiveVehicle:       (self: VehicleSystem, instanceId: string, defId: string, color: Color3?) -> OwnedVehicle,
    EquipVehicle:      (self: VehicleSystem, instanceId: string) -> boolean,
    UnequipVehicle:    (self: VehicleSystem) -> (),
    SpawnVehicle:      (self: VehicleSystem, instanceId: string, position: Vector3) -> Model?,
    DespawnVehicle:    (self: VehicleSystem) -> (),
    PaintVehicle:      (self: VehicleSystem, instanceId: string, color: Color3) -> boolean,
    GetEquippedVehicle:(self: VehicleSystem) -> OwnedVehicle?,
    GetVehicleDef:     (self: VehicleSystem, defId: string) -> VehicleDef?,

    -- Internals
    _eventBus:           EventBus,
    _inventory:          Inventory,
    _vehicleDefs:        { [string]: VehicleDef },
    _ownedVehicles:      { [string]: OwnedVehicle },
    _equippedInstanceId: string?,
    _activeVehicle:      ActiveVehicle?,
    _nextInstanceId:     number,
}

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function VehicleSystem.new(
    eventBus:  EventBus,
    inventory: Inventory
): VehicleSystem
    local self = setmetatable({}, VehicleSystem) :: VehicleSystem
    self._eventBus           = eventBus
    self._inventory          = inventory
    self._vehicleDefs        = {}
    self._ownedVehicles      = {}
    self._equippedInstanceId = nil
    self._activeVehicle      = nil
    self._nextInstanceId     = 1

    -- Register 10 default vehicle definitions
    local defaults: { VehicleDef } = {
        { id = "veh_bicycle",    name = "Bicycle",     category = "bike",       modelId = "rbxassetid:veh_bicycle",    speed = 30, seats = 1, price = 0,    rarity = "common"     },
        { id = "veh_car",        name = "Car",          category = "car",        modelId = "rbxassetid:veh_car",        speed = 50, seats = 4, price = 500,  rarity = "common"     },
        { id = "veh_sports_car", name = "Sports Car",   category = "car",        modelId = "rbxassetid:veh_sports_car", speed = 80, seats = 2, price = 2000, rarity = "rare"       },
        { id = "veh_jeep",       name = "Jeep",         category = "car",        modelId = "rbxassetid:veh_jeep",       speed = 55, seats = 4, price = 1500, rarity = "uncommon"   },
        { id = "veh_convertible",name = "Convertible",  category = "car",        modelId = "rbxassetid:veh_convertible",speed = 70, seats = 2, price = 3000, rarity = "rare"       },
        { id = "veh_helicopter", name = "Helicopter",   category = "helicopter", modelId = "rbxassetid:veh_helicopter", speed = 60, seats = 4, price = 8000, rarity = "legendary"  },
        { id = "veh_hoverboard", name = "Hoverboard",   category = "hoverboard", modelId = "rbxassetid:veh_hoverboard", speed = 45, seats = 1, price = 3000, rarity = "rare"       },
        { id = "veh_skateboard", name = "Skateboard",   category = "bike",       modelId = "rbxassetid:veh_skateboard", speed = 25, seats = 1, price = 500,  rarity = "common"     },
        { id = "veh_boat",       name = "Boat",         category = "boat",       modelId = "rbxassetid:veh_boat",       speed = 35, seats = 3, price = 2500, rarity = "uncommon"   },
        { id = "veh_unicycle",   name = "Unicycle",     category = "bike",       modelId = "rbxassetid:veh_unicycle",   speed = 20, seats = 1, price = 300,  rarity = "common"     },
    }
    for _, def in ipairs(defaults) do
        self:RegisterVehicle(def)
    end

    return self
end

-- ---------------------------------------------------------------------------
-- RegisterVehicle
-- ---------------------------------------------------------------------------

function VehicleSystem:RegisterVehicle(def: VehicleDef)
    self._vehicleDefs[def.id] = def
    self._eventBus:Emit("VehicleRegistered", {
        id       = def.id,
        name     = def.name,
        category = def.category,
        speed    = def.speed,
        seats    = def.seats,
        price    = def.price,
        rarity   = def.rarity,
    })
end

-- ---------------------------------------------------------------------------
-- GiveVehicle: programmatically grant an owned vehicle instance to the player.
-- Used by game scripts to give starter vehicles on join without direct field access.
-- ---------------------------------------------------------------------------

function VehicleSystem:GiveVehicle(instanceId: string, defId: string, color: Color3?): OwnedVehicle
    local owned: OwnedVehicle = {
        instanceId = instanceId,
        defId      = defId,
        color      = color or Color3.fromRGB(200, 50, 50),
        equipped   = false,
    }
    self._ownedVehicles[instanceId] = owned
    return owned
end

-- ---------------------------------------------------------------------------
-- EquipVehicle
-- ---------------------------------------------------------------------------

function VehicleSystem:EquipVehicle(instanceId: string): boolean
    local owned = self._ownedVehicles[instanceId]
    if not owned then return false end

    if self._equippedInstanceId then
        self:UnequipVehicle()
    end

    owned.equipped = true
    self._equippedInstanceId = instanceId

    self._eventBus:Emit("VehicleEquipped", {
        instanceId = instanceId,
        defId      = owned.defId,
        name       = self._vehicleDefs[owned.defId] and self._vehicleDefs[owned.defId].name or owned.defId,
    })

    return true
end

-- ---------------------------------------------------------------------------
-- UnequipVehicle
-- ---------------------------------------------------------------------------

function VehicleSystem:UnequipVehicle()
    if self._activeVehicle then
        self:DespawnVehicle()
    end

    local instanceId = self._equippedInstanceId
    if not instanceId then return end

    local owned = self._ownedVehicles[instanceId]
    if owned then owned.equipped = false end

    self._equippedInstanceId = nil

    self._eventBus:Emit("VehicleUnequipped", { instanceId = instanceId })
end

-- ---------------------------------------------------------------------------
-- Model builders — one per category
-- ---------------------------------------------------------------------------

local function _buildCarModel(vehicleName: string, color: Color3): (Model, VehicleSeat)
    local model   = Instance.new("Model")
    model.Name    = vehicleName

    local chassis = Instance.new("Part")
    chassis.Name     = "Chassis"
    chassis.Size     = Vector3.new(8, 1.5, 4)
    chassis.Position = Vector3.new(0, 1.75, 0)
    chassis.Anchored = true
    chassis.Material = Enum.Material.SmoothPlastic
    chassis.Color    = color
    chassis.Parent   = model

    local wheelOffsets = {
        { name = "WheelFL", pos = Vector3.new(-2.5, 0.75,  1.5) },
        { name = "WheelFR", pos = Vector3.new(-2.5, 0.75, -1.5) },
        { name = "WheelRL", pos = Vector3.new( 2.5, 0.75,  1.5) },
        { name = "WheelRR", pos = Vector3.new( 2.5, 0.75, -1.5) },
    }
    for _, w in ipairs(wheelOffsets) do
        local wheel      = Instance.new("Part")
        wheel.Name       = w.name
        wheel.Size       = Vector3.new(1.5, 1.5, 1.5)
        wheel.Shape      = Enum.PartType.Ball
        wheel.Position   = w.pos
        wheel.Anchored   = true
        wheel.Material   = Enum.Material.SmoothPlastic
        wheel.Color      = Color3.fromRGB(30, 30, 30)
        wheel.Parent     = model
    end

    local windshield             = Instance.new("Part")
    windshield.Name              = "Windshield"
    windshield.Size              = Vector3.new(0.2, 1.5, 3.5)
    windshield.Position          = Vector3.new(-1.5, 3, 0)
    windshield.Anchored          = true
    windshield.CanCollide        = false
    windshield.Material          = Enum.Material.SmoothPlastic
    windshield.Color             = Color3.fromRGB(173, 216, 230)
    windshield.Transparency      = 0.6
    windshield.Parent            = model

    local seat                   = Instance.new("VehicleSeat")
    seat.Name                    = "VehicleSeat"
    seat.Size                    = Vector3.new(3, 1, 3)
    seat.Position                = Vector3.new(0, 2.75, 0)
    seat.Anchored                = true
    seat.Material                = Enum.Material.SmoothPlastic
    seat.Color                   = Color3.fromRGB(64, 64, 64)
    seat.HeadsUpDisplay          = false
    seat.Parent                  = model

    model.PrimaryPart = chassis
    return model, seat
end

local function _buildBicycleModel(vehicleName: string, color: Color3): (Model, VehicleSeat)
    local model  = Instance.new("Model")
    model.Name   = vehicleName

    local frame  = Instance.new("Part")
    frame.Name   = "Frame"
    frame.Size   = Vector3.new(4, 0.5, 1)
    frame.Position = Vector3.new(0, 1.5, 0)
    frame.Anchored = true
    frame.Material = Enum.Material.SmoothPlastic
    frame.Color  = color
    frame.Parent = model

    local wheelOffsets = {
        { name = "WheelFront", pos = Vector3.new(-2, 1, 0) },
        { name = "WheelBack",  pos = Vector3.new( 2, 1, 0) },
    }
    for _, w in ipairs(wheelOffsets) do
        local wheel       = Instance.new("Part")
        wheel.Name        = w.name
        wheel.Size        = Vector3.new(1.5, 1.5, 0.5)
        wheel.Shape       = Enum.PartType.Cylinder
        wheel.CFrame      = CFrame.new(w.pos) * CFrame.Angles(0, 0, math.rad(90))
        wheel.Anchored    = true
        wheel.Material    = Enum.Material.SmoothPlastic
        wheel.Color       = Color3.fromRGB(30, 30, 30)
        wheel.Parent      = model
    end

    local seat           = Instance.new("VehicleSeat")
    seat.Name            = "VehicleSeat"
    seat.Size            = Vector3.new(1.5, 0.5, 1.5)
    seat.Position        = Vector3.new(1, 2.25, 0)
    seat.Anchored        = true
    seat.Material        = Enum.Material.SmoothPlastic
    seat.Color           = Color3.fromRGB(64, 64, 64)
    seat.HeadsUpDisplay  = false
    seat.Parent          = model

    model.PrimaryPart = frame
    return model, seat
end

local function _buildHelicopterModel(vehicleName: string, color: Color3): (Model, VehicleSeat)
    local model  = Instance.new("Model")
    model.Name   = vehicleName

    local body   = Instance.new("Part")
    body.Name    = "Body"
    body.Size    = Vector3.new(3, 2.5, 2)
    body.Position = Vector3.new(0, 3, 0)
    body.Anchored = true
    body.Material = Enum.Material.SmoothPlastic
    body.Color   = color
    body.Parent  = model

    local cockpit       = Instance.new("Part")
    cockpit.Name        = "Cockpit"
    cockpit.Size        = Vector3.new(2, 1.8, 1.8)
    cockpit.Position    = Vector3.new(-2, 3, 0)
    cockpit.Anchored    = true
    cockpit.Material    = Enum.Material.SmoothPlastic
    cockpit.Color       = Color3.fromRGB(173, 216, 230)
    cockpit.Transparency = 0.5
    cockpit.Parent      = model

    local tail          = Instance.new("Part")
    tail.Name           = "Tail"
    tail.Size           = Vector3.new(4, 0.6, 0.6)
    tail.Position       = Vector3.new(3, 4, 0)
    tail.Anchored       = true
    tail.Material       = Enum.Material.SmoothPlastic
    tail.Color          = color
    tail.Parent         = model

    local mainRotor     = Instance.new("Part")
    mainRotor.Name      = "MainRotor"
    mainRotor.Size      = Vector3.new(8, 0.2, 0.5)
    mainRotor.Position  = Vector3.new(0, 4.5, 0)
    mainRotor.Anchored  = true
    mainRotor.CanCollide = false
    mainRotor.Material  = Enum.Material.SmoothPlastic
    mainRotor.Color     = Color3.fromRGB(128, 128, 128)
    mainRotor.Parent    = model

    local skidOffsets = {
        { name = "SkidLeft",  pos = Vector3.new(0, 0.5,  1.2) },
        { name = "SkidRight", pos = Vector3.new(0, 0.5, -1.2) },
    }
    for _, s in ipairs(skidOffsets) do
        local skid      = Instance.new("Part")
        skid.Name       = s.name
        skid.Size       = Vector3.new(4, 0.3, 0.3)
        skid.Position   = s.pos
        skid.Anchored   = true
        skid.Material   = Enum.Material.SmoothPlastic
        skid.Color      = Color3.fromRGB(64, 64, 64)
        skid.Parent     = model
    end

    local seat          = Instance.new("VehicleSeat")
    seat.Name           = "VehicleSeat"
    seat.Size           = Vector3.new(2, 1, 1.5)
    seat.Position       = Vector3.new(-0.5, 2.5, 0)
    seat.Anchored       = true
    seat.Material       = Enum.Material.SmoothPlastic
    seat.Color          = Color3.fromRGB(64, 64, 64)
    seat.HeadsUpDisplay = false
    seat.Parent         = model

    model.PrimaryPart = body
    return model, seat
end

local function _buildHoverboardModel(vehicleName: string, color: Color3): (Model, VehicleSeat)
    local model  = Instance.new("Model")
    model.Name   = vehicleName

    local board  = Instance.new("Part")
    board.Name   = "Board"
    board.Size   = Vector3.new(3, 0.3, 1.2)
    board.Position = Vector3.new(0, 1.15, 0)
    board.Anchored = true
    board.Material = Enum.Material.SmoothPlastic
    board.Color  = color
    board.Parent = model

    local thrusterOffsets = {
        { name = "ThrusterL", pos = Vector3.new(-1, 0.5,  0.4) },
        { name = "ThrusterR", pos = Vector3.new(-1, 0.5, -0.4) },
    }
    for _, t in ipairs(thrusterOffsets) do
        local thruster      = Instance.new("Part")
        thruster.Name       = t.name
        thruster.Size       = Vector3.new(0.8, 0.8, 0.4)
        thruster.Position   = t.pos
        thruster.Anchored   = true
        thruster.Material   = Enum.Material.Neon
        thruster.Color      = Color3.fromRGB(0, 150, 255)
        thruster.Parent     = model
    end

    local seat          = Instance.new("VehicleSeat")
    seat.Name           = "VehicleSeat"
    seat.Size           = Vector3.new(2.5, 0.5, 1)
    seat.Position       = Vector3.new(0, 1.7, 0)
    seat.Anchored       = true
    seat.Material       = Enum.Material.SmoothPlastic
    seat.Color          = Color3.fromRGB(64, 64, 64)
    seat.HeadsUpDisplay = false
    seat.Parent         = model

    model.PrimaryPart = board
    return model, seat
end

local function _buildBoatModel(vehicleName: string, color: Color3): (Model, VehicleSeat)
    local model  = Instance.new("Model")
    model.Name   = vehicleName

    local hull   = Instance.new("Part")
    hull.Name    = "Hull"
    hull.Size    = Vector3.new(8, 1.5, 4)
    hull.Position = Vector3.new(0, 1, 0)
    hull.Anchored = true
    hull.Material = Enum.Material.SmoothPlastic
    hull.Color   = color
    hull.Parent  = model

    local driverSeat          = Instance.new("VehicleSeat")
    driverSeat.Name           = "VehicleSeat"
    driverSeat.Size           = Vector3.new(1.5, 1, 1.5)
    driverSeat.Position       = Vector3.new(-1.5, 2, 0)
    driverSeat.Anchored       = true
    driverSeat.Material       = Enum.Material.SmoothPlastic
    driverSeat.Color          = Color3.fromRGB(64, 64, 64)
    driverSeat.HeadsUpDisplay = false
    driverSeat.Parent         = model

    local passengerSeat        = Instance.new("Seat")
    passengerSeat.Name         = "PassengerSeat"
    passengerSeat.Size         = Vector3.new(1.5, 1, 1.5)
    passengerSeat.Position     = Vector3.new(1.5, 2, 0)
    passengerSeat.Anchored     = true
    passengerSeat.Material     = Enum.Material.SmoothPlastic
    passengerSeat.Color        = Color3.fromRGB(64, 64, 64)
    passengerSeat.Parent       = model

    local motor     = Instance.new("Part")
    motor.Name      = "Motor"
    motor.Size      = Vector3.new(1.5, 1.5, 1.5)
    motor.Position  = Vector3.new(4, 1.5, 0)
    motor.Anchored  = true
    motor.Material  = Enum.Material.SmoothPlastic
    motor.Color     = Color3.fromRGB(64, 64, 64)
    motor.Parent    = model

    model.PrimaryPart = hull
    return model, driverSeat
end

local function _buildGenericModel(vehicleName: string, color: Color3): (Model, VehicleSeat)
    local model  = Instance.new("Model")
    model.Name   = vehicleName

    local body   = Instance.new("Part")
    body.Name    = "Body"
    body.Size    = Vector3.new(4, 1.5, 3)
    body.Position = Vector3.new(0, 1.5, 0)
    body.Anchored = true
    body.Material = Enum.Material.SmoothPlastic
    body.Color   = color
    body.Parent  = model

    local seat          = Instance.new("VehicleSeat")
    seat.Name           = "VehicleSeat"
    seat.Size           = Vector3.new(2.5, 1, 2)
    seat.Position       = Vector3.new(0, 2.5, 0)
    seat.Anchored       = true
    seat.Material       = Enum.Material.SmoothPlastic
    seat.Color          = Color3.fromRGB(64, 64, 64)
    seat.HeadsUpDisplay = false
    seat.Parent         = model

    model.PrimaryPart = body
    return model, seat
end

-- ---------------------------------------------------------------------------
-- SpawnVehicle
-- ---------------------------------------------------------------------------

function VehicleSystem:SpawnVehicle(instanceId: string, position: Vector3): Model?
    local owned = self._ownedVehicles[instanceId]
    if not owned then return nil end

    if self._activeVehicle then
        self:DespawnVehicle()
    end

    local def = self._vehicleDefs[owned.defId]
    if not def then return nil end

    local model: Model
    local seat:  VehicleSeat

    if def.category == "car" then
        model, seat = _buildCarModel(def.name, owned.color)
    elseif def.category == "bike" then
        model, seat = _buildBicycleModel(def.name, owned.color)
    elseif def.category == "helicopter" then
        model, seat = _buildHelicopterModel(def.name, owned.color)
    elseif def.category == "hoverboard" then
        model, seat = _buildHoverboardModel(def.name, owned.color)
    elseif def.category == "boat" then
        model, seat = _buildBoatModel(def.name, owned.color)
    else
        model, seat = _buildGenericModel(def.name, owned.color)
    end

    model:SetPrimaryPartCFrame(CFrame.new(position))

    -- Unanchor all parts so physics applies
    for _, child in ipairs(model:GetDescendants()) do
        if child:IsA("BasePart") then
            child.Anchored = false
        end
    end

    -- BodyVelocity for movement (MaxForce starts at zero — enabled when seated)
    local bv         = Instance.new("BodyVelocity")
    bv.MaxForce      = Vector3.new(0, 0, 0)
    bv.Velocity      = Vector3.zero
    bv.Parent        = seat

    -- NOTE: In a real game, connect _startDriving(self, active) here when
    -- seat.Occupant changes. Omitted from this server-side module for safety;
    -- see the LocalScript driving layer for ThrottleFloat/SteerFloat input.

    local active: ActiveVehicle = {
        model          = model,
        vehicleSeat    = seat,
        bodyVelocity   = bv,
        connection     = nil,
        ownedVehicleId = instanceId,
    }
    self._activeVehicle = active

    self._eventBus:Emit("VehicleSpawned", {
        instanceId = instanceId,
        defId      = owned.defId,
        name       = def.name,
        position   = position,
        model      = model,
    })

    return model
end

-- ---------------------------------------------------------------------------
-- DespawnVehicle
-- ---------------------------------------------------------------------------

function VehicleSystem:DespawnVehicle()
    local active = self._activeVehicle
    if not active then return end

    if active.connection then
        active.connection:Disconnect()
        active.connection = nil
    end

    if active.bodyVelocity then
        active.bodyVelocity:Destroy()
    end

    local ownedId = active.ownedVehicleId
    if active.model then
        active.model:Destroy()
    end

    self._activeVehicle = nil

    self._eventBus:Emit("VehicleDespawned", { instanceId = ownedId })
end

-- ---------------------------------------------------------------------------
-- PaintVehicle
-- ---------------------------------------------------------------------------

function VehicleSystem:PaintVehicle(instanceId: string, color: Color3): boolean
    local owned = self._ownedVehicles[instanceId]
    if not owned then return false end

    local def = self._vehicleDefs[owned.defId]
    if not def then return false end

    owned.color = color

    -- Recolor spawned model in real-time (skip transparent parts)
    if self._activeVehicle and self._activeVehicle.ownedVehicleId == instanceId then
        local model = self._activeVehicle.model
        if model then
            for _, child in ipairs(model:GetDescendants()) do
                if child:IsA("BasePart") and child.Transparency < 0.5 then
                    local name = child.Name
                    if name ~= "Windshield" and name ~= "Cockpit" then
                        child.Color = color
                    end
                end
            end
        end
    end

    self._eventBus:Emit("VehiclePainted", {
        instanceId = instanceId,
        defId      = owned.defId,
        name       = def.name,
        color      = color,
    })

    return true
end

-- ---------------------------------------------------------------------------
-- GetEquippedVehicle
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- GetVehicleDef: read-only access to a registered vehicle definition.
-- Allows game scripts to display the name/speed/etc. without touching
-- the private _vehicleDefs field.
-- ---------------------------------------------------------------------------

function VehicleSystem:GetVehicleDef(defId: string): VehicleDef?
    return self._vehicleDefs[defId]
end

-- ---------------------------------------------------------------------------
-- GetEquippedVehicle
-- ---------------------------------------------------------------------------

function VehicleSystem:GetEquippedVehicle(): OwnedVehicle?
    local instanceId = self._equippedInstanceId
    if not instanceId then return nil end
    local owned = self._ownedVehicles[instanceId]
    if not owned then return nil end
    return {
        instanceId = owned.instanceId,
        defId      = owned.defId,
        color      = owned.color,
        equipped   = owned.equipped,
    }
end

return VehicleSystem
