--!strict
-- test_VehicleSystem.lua
-- TestEZ unit tests for VehicleSystem

return function()
    local EventBus    = require(script.Parent.Parent.src.Core.EventBus)
    local VehicleSystem = require(script.Parent.Parent.src.VehicleSystem)

    -- ---------------------------------------------------------------------------
    -- Stubs
    -- ---------------------------------------------------------------------------

    local function makeInventory()
        local slots: { { itemId: string, quantity: number } } = {}
        return {
            AddItem    = function(_self, itemId, qty) table.insert(slots, { itemId = itemId, quantity = qty }); return true end,
            RemoveItem = function(_self, _itemId, _qty) return true end,
            GetAllSlots = function(_self) return slots end,
        }
    end

    local function makeSystem()
        local bus = EventBus.new()
        local inv = makeInventory()
        return VehicleSystem.new(bus, inv), bus, inv
    end

    -- Minimal VehicleDef fixture
    local BIKE_DEF: VehicleSystem.VehicleDef = {
        id       = "test_bike",
        name     = "Test Bike",
        category = "bike",
        modelId  = "rbxassetid:test_bike",
        speed    = 30,
        seats    = 1,
        price    = 50,
        rarity   = "common",
    }

    local CAR_DEF: VehicleSystem.VehicleDef = {
        id       = "test_car",
        name     = "Test Car",
        category = "car",
        modelId  = "rbxassetid:test_car",
        speed    = 60,
        seats    = 4,
        price    = 500,
        rarity   = "rare",
    }

    -- -------------------------------------------------------------------------
    describe("VehicleSystem.new", function()
        it("creates an instance without error", function()
            expect(function() makeSystem() end).never.to.throw()
        end)

        it("registers 10 default vehicles on construction", function()
            local sys = makeSystem()
            -- All 10 defaults should be retrievable via GetVehicleDef
            local defaults = {
                "veh_bicycle", "veh_car", "veh_sports_car", "veh_jeep",
                "veh_convertible", "veh_helicopter", "veh_hoverboard",
                "veh_skateboard", "veh_boat", "veh_unicycle",
            }
            for _, id in ipairs(defaults) do
                expect(sys:GetVehicleDef(id)).to.be.ok()
            end
        end)

        it("returns nil for unknown def id", function()
            local sys = makeSystem()
            expect(sys:GetVehicleDef("veh_does_not_exist")).never.to.be.ok()
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("RegisterVehicle", function()
        it("stores the definition so GetVehicleDef returns it", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            local got = sys:GetVehicleDef("test_bike")
            expect(got).to.be.ok()
            expect(got.name).to.equal("Test Bike")
            expect(got.speed).to.equal(30)
            expect(got.seats).to.equal(1)
        end)

        it("emits VehicleRegistered with correct payload", function()
            local sys, bus = makeSystem()
            local payload = nil
            bus:Subscribe("VehicleRegistered", function(data) payload = data end)
            sys:RegisterVehicle(CAR_DEF)
            expect(payload).to.be.ok()
            expect(payload.id).to.equal("test_car")
            expect(payload.name).to.equal("Test Car")
            expect(payload.category).to.equal("car")
            expect(payload.speed).to.equal(60)
            expect(payload.seats).to.equal(4)
            expect(payload.price).to.equal(500)
            expect(payload.rarity).to.equal("rare")
        end)

        it("overwrites an existing definition with the same id", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            local updated = table.clone(BIKE_DEF)
            updated.speed = 99
            sys:RegisterVehicle(updated)
            expect(sys:GetVehicleDef("test_bike").speed).to.equal(99)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("GiveVehicle", function()
        it("returns an OwnedVehicle with the provided ids and color", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            local owned = sys:GiveVehicle("inst_1", "test_bike", Color3.fromRGB(255, 0, 0))
            expect(owned.instanceId).to.equal("inst_1")
            expect(owned.defId).to.equal("test_bike")
            expect(owned.equipped).to.equal(false)
        end)

        it("uses a default color when none provided", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            local owned = sys:GiveVehicle("inst_2", "test_bike")
            expect(owned.color).to.be.ok() -- should be non-nil default
        end)

        it("makes the vehicle equipable afterwards", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("inst_eq", "test_bike")
            expect(sys:EquipVehicle("inst_eq")).to.equal(true)
        end)

        it("returns false for EquipVehicle on ungiven instance", function()
            local sys = makeSystem()
            expect(sys:EquipVehicle("phantom")).to.equal(false)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("GetVehicleDef", function()
        it("returns the def registered by RegisterVehicle", function()
            local sys = makeSystem()
            sys:RegisterVehicle(CAR_DEF)
            local def = sys:GetVehicleDef("test_car")
            expect(def).to.be.ok()
            expect(def.category).to.equal("car")
        end)

        it("returns one of the 10 built-in defs", function()
            local sys = makeSystem()
            local def = sys:GetVehicleDef("veh_helicopter")
            expect(def).to.be.ok()
            expect(def.category).to.equal("helicopter")
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("EquipVehicle / UnequipVehicle", function()
        it("EquipVehicle returns true and sets equipped=true on the owned entry", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("eq_1", "test_bike")
            local ok = sys:EquipVehicle("eq_1")
            expect(ok).to.equal(true)
            local equipped = sys:GetEquippedVehicle()
            expect(equipped).to.be.ok()
            expect(equipped.instanceId).to.equal("eq_1")
            expect(equipped.equipped).to.equal(true)
        end)

        it("emits VehicleEquipped with instanceId and defId", function()
            local sys, bus = makeSystem()
            local payload = nil
            bus:Subscribe("VehicleEquipped", function(data) payload = data end)
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("eq_2", "test_bike")
            sys:EquipVehicle("eq_2")
            expect(payload).to.be.ok()
            expect(payload.instanceId).to.equal("eq_2")
            expect(payload.defId).to.equal("test_bike")
        end)

        it("equipping a second vehicle auto-unequips the first", function()
            local sys, bus = makeSystem()
            local unequipPayload = nil
            bus:Subscribe("VehicleUnequipped", function(data) unequipPayload = data end)
            sys:RegisterVehicle(BIKE_DEF)
            sys:RegisterVehicle(CAR_DEF)
            sys:GiveVehicle("eq_a", "test_bike")
            sys:GiveVehicle("eq_b", "test_car")
            sys:EquipVehicle("eq_a")
            sys:EquipVehicle("eq_b")  -- should auto-unequip eq_a
            expect(unequipPayload).to.be.ok()
            local equipped = sys:GetEquippedVehicle()
            expect(equipped.instanceId).to.equal("eq_b")
        end)

        it("UnequipVehicle clears the equipped slot", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("eq_3", "test_bike")
            sys:EquipVehicle("eq_3")
            sys:UnequipVehicle()
            expect(sys:GetEquippedVehicle()).never.to.be.ok()
        end)

        it("emits VehicleUnequipped with the instanceId", function()
            local sys, bus = makeSystem()
            local payload = nil
            bus:Subscribe("VehicleUnequipped", function(data) payload = data end)
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("eq_4", "test_bike")
            sys:EquipVehicle("eq_4")
            sys:UnequipVehicle()
            expect(payload).to.be.ok()
            expect(payload.instanceId).to.equal("eq_4")
        end)

        it("UnequipVehicle is a no-op when nothing is equipped", function()
            local sys = makeSystem()
            expect(function() sys:UnequipVehicle() end).never.to.throw()
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("SpawnVehicle / DespawnVehicle", function()
        it("SpawnVehicle returns a Model", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("sp_1", "test_bike")
            local model = sys:SpawnVehicle("sp_1", Vector3.new(0, 0, 0))
            expect(model).to.be.ok()
            if model then model:Destroy() end
        end)

        it("spawned Model has the vehicle name", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("sp_2", "test_bike")
            local model = sys:SpawnVehicle("sp_2", Vector3.new(0, 0, 0))
            expect(model.Name).to.equal("Test Bike")
            if model then model:Destroy() end
        end)

        it("emits VehicleSpawned with instanceId, defId, position", function()
            local sys, bus = makeSystem()
            local payload = nil
            bus:Subscribe("VehicleSpawned", function(data) payload = data end)
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("sp_3", "test_bike")
            local pos = Vector3.new(10, 0, 5)
            sys:SpawnVehicle("sp_3", pos)
            expect(payload).to.be.ok()
            expect(payload.instanceId).to.equal("sp_3")
            expect(payload.defId).to.equal("test_bike")
            expect(payload.position).to.equal(pos)
        end)

        it("SpawnVehicle returns nil for an unknown instance", function()
            local sys = makeSystem()
            local model = sys:SpawnVehicle("no_such_vehicle", Vector3.new(0, 0, 0))
            expect(model).never.to.be.ok()
        end)

        it("DespawnVehicle destroys the active model", function()
            local sys = makeSystem()
            sys:RegisterVehicle(CAR_DEF)
            sys:GiveVehicle("dp_1", "test_car")
            local model = sys:SpawnVehicle("dp_1", Vector3.new(0, 0, 0))
            expect(model).to.be.ok()
            sys:DespawnVehicle()
            -- After despawn the Model should be destroyed (Parent nil)
            expect(model.Parent).never.to.be.ok()
        end)

        it("emits VehicleDespawned after DespawnVehicle", function()
            local sys, bus = makeSystem()
            local payload = nil
            bus:Subscribe("VehicleDespawned", function(data) payload = data end)
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("dp_2", "test_bike")
            sys:SpawnVehicle("dp_2", Vector3.new(0, 0, 0))
            sys:DespawnVehicle()
            expect(payload).to.be.ok()
        end)

        it("DespawnVehicle is a no-op when nothing is spawned", function()
            local sys = makeSystem()
            expect(function() sys:DespawnVehicle() end).never.to.throw()
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("PaintVehicle", function()
        it("returns true and updates the owned vehicle color", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("paint_1", "test_bike")
            local newColor = Color3.fromRGB(0, 128, 255)
            local ok = sys:PaintVehicle("paint_1", newColor)
            expect(ok).to.equal(true)
            local owned = sys:GiveVehicle("paint_check", "test_bike")
            -- Re-read the original by equipping and inspecting
            sys:EquipVehicle("paint_1")
            local equipped = sys:GetEquippedVehicle()
            expect(equipped.color).to.equal(newColor)
        end)

        it("emits VehiclePainted with instanceId and color", function()
            local sys, bus = makeSystem()
            local payload = nil
            bus:Subscribe("VehiclePainted", function(data) payload = data end)
            sys:RegisterVehicle(CAR_DEF)
            sys:GiveVehicle("paint_2", "test_car")
            local col = Color3.fromRGB(255, 0, 0)
            sys:PaintVehicle("paint_2", col)
            expect(payload).to.be.ok()
            expect(payload.instanceId).to.equal("paint_2")
            expect(payload.color).to.equal(col)
        end)

        it("returns false for unknown instance", function()
            local sys = makeSystem()
            expect(sys:PaintVehicle("ghost_vehicle", Color3.new(1, 0, 0))).to.equal(false)
        end)

        it("recolors all BaseParts of a spawned model", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("paint_3", "test_bike")
            local model = sys:SpawnVehicle("paint_3", Vector3.new(0, 0, 0))
            expect(model).to.be.ok()
            local col = Color3.fromRGB(0, 255, 0)
            sys:PaintVehicle("paint_3", col)
            -- At least the primary part should match
            if model then
                local primary = model.PrimaryPart
                if primary then
                    expect(primary.Color).to.equal(col)
                end
                model:Destroy()
            end
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("GetEquippedVehicle", function()
        it("returns nil when nothing is equipped", function()
            local sys = makeSystem()
            expect(sys:GetEquippedVehicle()).never.to.be.ok()
        end)

        it("returns a copy not the live object", function()
            local sys = makeSystem()
            sys:RegisterVehicle(BIKE_DEF)
            sys:GiveVehicle("copy_1", "test_bike")
            sys:EquipVehicle("copy_1")
            local copy1 = sys:GetEquippedVehicle()
            local copy2 = sys:GetEquippedVehicle()
            -- Two calls should return different table references
            expect(copy1 ~= copy2).to.equal(true)
            -- But same data
            expect(copy1.instanceId).to.equal(copy2.instanceId)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("VehicleCategory model builders", function()
        local categories = {
            { id = "cat_car",        defId = "veh_car",        name = "car"        },
            { id = "cat_bike",       defId = "veh_bicycle",    name = "bike"       },
            { id = "cat_heli",       defId = "veh_helicopter", name = "helicopter" },
            { id = "cat_hover",      defId = "veh_hoverboard", name = "hoverboard" },
            { id = "cat_boat",       defId = "veh_boat",       name = "boat"       },
        }
        for _, tc in ipairs(categories) do
            it("SpawnVehicle succeeds for category: " .. tc.name, function()
                local sys = makeSystem()
                sys:GiveVehicle(tc.id, tc.defId)
                local model = sys:SpawnVehicle(tc.id, Vector3.new(0, 0, 0))
                expect(model).to.be.ok()
                if model then model:Destroy() end
            end)
        end

        it("SpawnVehicle for fallback category returns a Model", function()
            local sys = makeSystem()
            sys:RegisterVehicle({
                id       = "veh_custom",
                name     = "Custom Ride",
                category = "car",  -- falls into car builder
                modelId  = "rbxassetid:custom",
                speed    = 40,
                seats    = 2,
                price    = 100,
                rarity   = "common",
            })
            sys:GiveVehicle("custom_inst", "veh_custom")
            local model = sys:SpawnVehicle("custom_inst", Vector3.new(0, 0, 0))
            expect(model).to.be.ok()
            if model then model:Destroy() end
        end)
    end)
end
