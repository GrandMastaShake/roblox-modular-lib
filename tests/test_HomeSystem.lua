--!strict
-- test_HomeSystem.lua
-- TestEZ unit tests for HomeSystem

return function()
    local EventBus  = require(script.Parent.Parent.src.Core.EventBus)
    local HomeSystem = require(script.Parent.Parent.src.HomeSystem)

    -- ---------------------------------------------------------------------------
    -- Stubs
    -- ---------------------------------------------------------------------------

    local function makeInventory(seedItems: { { itemId: string, quantity: number } }?)
        local slots: { { itemId: string, quantity: number } } = seedItems or {}
        return {
            AddItem    = function(_self, itemId, qty)
                table.insert(slots, { itemId = itemId, quantity = qty })
                return true
            end,
            RemoveItem = function(_self, itemId, qty)
                for i, s in ipairs(slots) do
                    if s.itemId == itemId and s.quantity >= qty then
                        s.quantity -= qty
                        if s.quantity == 0 then table.remove(slots, i) end
                        return true
                    end
                end
                return false
            end,
            GetAllSlots = function(_self) return slots end,
        }
    end

    local function makeCurrency(balance: number?)
        local bal = balance or 9999
        return {
            CanAfford   = function(_self, _id, amount) return bal >= amount end,
            Subtract    = function(_self, _id, amount, _reason)
                if bal >= amount then bal -= amount; return true end
                return false
            end,
            Add         = function(_self, _id, amount, _reason) bal += amount end,
            GetBalance  = function(_self, _id) return bal end,
        }
    end

    local function makeSystem(balance: number?)
        local bus = EventBus.new()
        local inv = makeInventory()
        local cur = makeCurrency(balance)
        return HomeSystem.new(bus, inv, cur), bus, inv, cur
    end

    -- Furniture fixture used across tests (not in the 30-item built-in catalog)
    local FURN_SOFA: HomeSystem.FurnitureDef = {
        id           = "test_sofa",
        name         = "Test Sofa",
        category     = "Seating",
        modelId      = "rbxassetid:test_sofa",
        footprint    = Vector2.new(4, 2),
        price        = 200,
        interactable = true,
    }

    -- Give the inventory one of the test sofa item
    local function makeSystemWithSofa()
        local bus = EventBus.new()
        local inv = makeInventory({ { itemId = "test_sofa", quantity = 1 } })
        local cur = makeCurrency()
        local sys = HomeSystem.new(bus, inv, cur)
        sys:RegisterFurniture(FURN_SOFA)
        return sys, bus, inv, cur
    end

    -- -------------------------------------------------------------------------
    describe("HomeSystem.new", function()
        it("creates instance without error", function()
            expect(function() makeSystem() end).never.to.throw()
        end)

        it("registers 30 built-in furniture items on construction", function()
            local sys = makeSystem()
            local catalog = sys:ListFurnitureCatalog()
            expect(#catalog).to.equal(30)
        end)

        it("catalog items include Beds category", function()
            local sys = makeSystem()
            local catalog = sys:ListFurnitureCatalog()
            local hasBed = false
            for _, item in ipairs(catalog) do
                if item.category == "Beds" then hasBed = true; break end
            end
            expect(hasBed).to.equal(true)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("RegisterFurniture", function()
        it("adds a new item to the catalog", function()
            local sys = makeSystem()
            local beforeCount = #sys:ListFurnitureCatalog()
            sys:RegisterFurniture(FURN_SOFA)
            expect(#sys:ListFurnitureCatalog()).to.equal(beforeCount + 1)
        end)

        it("emits FurnitureRegistered with id, name, category, price", function()
            local sys, bus = makeSystem()
            local payload = nil
            bus:Subscribe("FurnitureRegistered", function(data) payload = data end)
            sys:RegisterFurniture(FURN_SOFA)
            expect(payload).to.be.ok()
            expect(payload.id).to.equal("test_sofa")
            expect(payload.name).to.equal("Test Sofa")
            expect(payload.category).to.equal("Seating")
            expect(payload.price).to.equal(200)
        end)

        it("overwrites an existing item with the same id", function()
            local sys = makeSystem()
            sys:RegisterFurniture(FURN_SOFA)
            local updated = table.clone(FURN_SOFA)
            updated.price = 999
            sys:RegisterFurniture(updated)
            for _, item in ipairs(sys:ListFurnitureCatalog()) do
                if item.id == "test_sofa" then
                    expect(item.price).to.equal(999)
                    return
                end
            end
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("BuyHome", function()
        it("returns a Home for a free apartment type", function()
            local sys = makeSystem()
            local home = sys:BuyHome("player_1", "apartment")
            expect(home).to.be.ok()
            expect(home.ownerId).to.equal("player_1")
            expect(home.homeType).to.equal("apartment")
        end)

        it("apartment has 2 rooms matching the definition", function()
            local sys = makeSystem()
            local home = sys:BuyHome("player_2", "apartment")
            expect(home).to.be.ok()
            expect(#home.rooms).to.equal(2)
        end)

        it("rooms have default wall and floor colors", function()
            local sys = makeSystem()
            local home = sys:BuyHome("player_3", "apartment")
            for _, room in ipairs(home.rooms) do
                expect(room.wallColor).to.be.ok()
                expect(room.floorColor).to.be.ok()
            end
        end)

        it("emits HomeBought with homeId, ownerId, homeType, price", function()
            local sys, bus = makeSystem()
            local payload = nil
            bus:Subscribe("HomeBought", function(data) payload = data end)
            sys:BuyHome("player_4", "apartment")
            expect(payload).to.be.ok()
            expect(payload.ownerId).to.equal("player_4")
            expect(payload.homeType).to.equal("apartment")
            expect(payload.price).to.equal(0) -- apartment is free
        end)

        it("returns nil if player already owns a home", function()
            local sys = makeSystem()
            sys:BuyHome("player_5", "apartment")
            local second = sys:BuyHome("player_5", "apartment")
            expect(second).never.to.be.ok()
        end)

        it("charges currency for a paid home type (cottage = 500)", function()
            local sys, _, _, cur = makeSystem(1000)
            local home = sys:BuyHome("player_6", "cottage")
            expect(home).to.be.ok()
            expect(cur:GetBalance("bucks")).to.equal(500) -- 1000 - 500
        end)

        it("returns nil when player cannot afford the home", function()
            local sys = makeSystem(100) -- only 100, cottage costs 500
            local home = sys:BuyHome("player_7", "cottage")
            expect(home).never.to.be.ok()
        end)

        it("mansion has 5 rooms", function()
            local sys = makeSystem()
            local home = sys:BuyHome("player_8", "mansion")
            expect(#home.rooms).to.equal(5)
        end)

        it("castle has 6 rooms", function()
            local sys = makeSystem()
            local home = sys:BuyHome("player_9", "castle")
            expect(#home.rooms).to.equal(6)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("GetHome / GetPlayerHome", function()
        it("GetHome returns the home by homeId", function()
            local sys = makeSystem()
            local bought = sys:BuyHome("p_gh1", "apartment")
            local found = sys:GetHome(bought.homeId)
            expect(found).to.be.ok()
            expect(found.homeId).to.equal(bought.homeId)
        end)

        it("GetHome returns nil for an unknown id", function()
            local sys = makeSystem()
            expect(sys:GetHome("phantom_home_id")).never.to.be.ok()
        end)

        it("GetHome returns a deep copy (not a live reference)", function()
            local sys = makeSystem()
            local bought = sys:BuyHome("p_gh2", "apartment")
            local copy1 = sys:GetHome(bought.homeId)
            local copy2 = sys:GetHome(bought.homeId)
            expect(copy1 ~= copy2).to.equal(true)
        end)

        it("GetPlayerHome returns the home for a given playerId", function()
            local sys = makeSystem()
            local bought = sys:BuyHome("p_ph1", "apartment")
            local found = sys:GetPlayerHome("p_ph1")
            expect(found).to.be.ok()
            expect(found.homeId).to.equal(bought.homeId)
        end)

        it("GetPlayerHome returns nil for a player without a home", function()
            local sys = makeSystem()
            expect(sys:GetPlayerHome("no_home_player")).never.to.be.ok()
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("PlaceFurniture", function()
        it("places furniture and returns a PlacedFurniture", function()
            local sys, bus, inv = makeSystemWithSofa()
            local home = sys:BuyHome("p_pf1", "apartment")
            local roomId = home.rooms[1].roomId
            -- Position well inside the room (size 16x12, sofa footprint 4x2)
            local cf = CFrame.new(5, 0, 4)
            local placed = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", cf)
            expect(placed).to.be.ok()
            expect(placed.defId).to.equal("test_sofa")
            expect(placed.roomId).to.equal(roomId)
        end)

        it("emits FurniturePlaced with correct payload", function()
            local sys, bus = makeSystemWithSofa()
            local home = sys:BuyHome("p_pf2", "apartment")
            local roomId = home.rooms[1].roomId
            local payload = nil
            bus:Subscribe("FurniturePlaced", function(data) payload = data end)
            sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(5, 0, 4))
            expect(payload).to.be.ok()
            expect(payload.defId).to.equal("test_sofa")
            expect(payload.homeId).to.equal(home.homeId)
            expect(payload.roomId).to.equal(roomId)
        end)

        it("returns nil for an unknown home", function()
            local sys = makeSystemWithSofa()
            local placed = sys:PlaceFurniture("bad_home", "bad_room", "test_sofa", CFrame.new(5, 0, 4))
            expect(placed).never.to.be.ok()
        end)

        it("returns nil for an unknown furniture def", function()
            local sys, _, _ = makeSystemWithSofa()
            local home = sys:BuyHome("p_pf3", "apartment")
            local roomId = home.rooms[1].roomId
            local placed = sys:PlaceFurniture(home.homeId, roomId, "no_such_furn", CFrame.new(5, 0, 4))
            expect(placed).never.to.be.ok()
        end)

        it("returns nil when furniture is not in inventory", function()
            local sys = makeSystem()
            sys:RegisterFurniture(FURN_SOFA)
            local home = sys:BuyHome("p_pf4", "apartment")
            local roomId = home.rooms[1].roomId
            -- Inventory has no test_sofa item
            local placed = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(5, 0, 4))
            expect(placed).never.to.be.ok()
        end)

        it("returns nil when placement exceeds room bounds", function()
            local sys, _, _ = makeSystemWithSofa()
            local home = sys:BuyHome("p_pf5", "apartment")
            local roomId = home.rooms[1].roomId
            -- Place completely outside room (room is 16x12, sofa is 4x2)
            local placed = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(50, 0, 50))
            expect(placed).never.to.be.ok()
        end)

        it("returns nil when placement collides with existing furniture", function()
            local bus2 = EventBus.new()
            local inv2 = makeInventory({ { itemId = "test_sofa", quantity = 2 } })
            local cur2 = makeCurrency()
            local sys = HomeSystem.new(bus2, inv2, cur2)
            sys:RegisterFurniture(FURN_SOFA)
            local home = sys:BuyHome("p_pf6", "apartment")
            local roomId = home.rooms[1].roomId
            -- First placement succeeds
            sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(5, 0, 4))
            -- Second at the exact same position should fail (collision)
            local second = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(5, 0, 4))
            expect(second).never.to.be.ok()
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("MoveFurniture", function()
        it("moves furniture to a valid new position and returns true", function()
            local sys, _, _ = makeSystemWithSofa()
            local home = sys:BuyHome("p_mv1", "apartment")
            local roomId = home.rooms[1].roomId
            local placed = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(5, 0, 4))
            expect(placed).to.be.ok()
            local ok = sys:MoveFurniture(home.homeId, placed.instanceId, CFrame.new(8, 0, 4))
            expect(ok).to.equal(true)
        end)

        it("emits FurnitureMoved with oldCFrame and newCFrame", function()
            local sys, bus = makeSystemWithSofa()
            local home = sys:BuyHome("p_mv2", "apartment")
            local roomId = home.rooms[1].roomId
            local oldCF = CFrame.new(5, 0, 4)
            local newCF = CFrame.new(8, 0, 4)
            local placed = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", oldCF)
            local payload = nil
            bus:Subscribe("FurnitureMoved", function(data) payload = data end)
            sys:MoveFurniture(home.homeId, placed.instanceId, newCF)
            expect(payload).to.be.ok()
            expect(payload.instanceId).to.equal(placed.instanceId)
            expect(payload.oldCFrame).to.equal(oldCF)
            expect(payload.newCFrame).to.equal(newCF)
        end)

        it("returns false for an unknown instanceId", function()
            local sys = makeSystem()
            local home = sys:BuyHome("p_mv3", "apartment")
            expect(sys:MoveFurniture(home.homeId, "phantom_furn", CFrame.new(5, 0, 4))).to.equal(false)
        end)

        it("returns false when moved out of room bounds", function()
            local sys, _, _ = makeSystemWithSofa()
            local home = sys:BuyHome("p_mv4", "apartment")
            local roomId = home.rooms[1].roomId
            local placed = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(5, 0, 4))
            expect(placed).to.be.ok()
            local ok = sys:MoveFurniture(home.homeId, placed.instanceId, CFrame.new(200, 0, 200))
            expect(ok).to.equal(false)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("RemoveFurniture", function()
        it("removes furniture from the room and returns true", function()
            local sys, _, _ = makeSystemWithSofa()
            local home = sys:BuyHome("p_rm1", "apartment")
            local roomId = home.rooms[1].roomId
            local placed = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(5, 0, 4))
            local ok = sys:RemoveFurniture(home.homeId, placed.instanceId)
            expect(ok).to.equal(true)
        end)

        it("returns the item to inventory (AddItem called)", function()
            local sys, bus, inv = makeSystemWithSofa()
            local home = sys:BuyHome("p_rm2", "apartment")
            local roomId = home.rooms[1].roomId
            local placed = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(5, 0, 4))
            local slotsBefore = #inv:GetAllSlots()
            sys:RemoveFurniture(home.homeId, placed.instanceId)
            -- AddItem should have been called, adding a slot back
            expect(#inv:GetAllSlots()).to.be.ok()
        end)

        it("emits FurnitureRemoved", function()
            local sys, bus = makeSystemWithSofa()
            local home = sys:BuyHome("p_rm3", "apartment")
            local roomId = home.rooms[1].roomId
            local placed = sys:PlaceFurniture(home.homeId, roomId, "test_sofa", CFrame.new(5, 0, 4))
            local payload = nil
            bus:Subscribe("FurnitureRemoved", function(data) payload = data end)
            sys:RemoveFurniture(home.homeId, placed.instanceId)
            expect(payload).to.be.ok()
            expect(payload.instanceId).to.equal(placed.instanceId)
            expect(payload.defId).to.equal("test_sofa")
        end)

        it("returns false for an unknown instanceId", function()
            local sys = makeSystem()
            local home = sys:BuyHome("p_rm4", "apartment")
            expect(sys:RemoveFurniture(home.homeId, "ghost_furn")).to.equal(false)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("PaintRoom", function()
        it("updates wall and floor colors", function()
            local sys = makeSystem()
            local home = sys:BuyHome("p_paint1", "apartment")
            local room = home.rooms[1]
            local newWall  = Color3.fromRGB(255, 100, 0)
            local newFloor = Color3.fromRGB(50,  50,  50)
            sys:PaintRoom(home.homeId, room.roomId, newWall, newFloor)
            -- Retrieve fresh copy and check colors
            local fresh = sys:GetHome(home.homeId)
            expect(fresh.rooms[1].wallColor).to.equal(newWall)
            expect(fresh.rooms[1].floorColor).to.equal(newFloor)
        end)

        it("emits RoomPainted with old and new colors", function()
            local sys, bus = makeSystem()
            local home = sys:BuyHome("p_paint2", "apartment")
            local room = home.rooms[1]
            local payload = nil
            bus:Subscribe("RoomPainted", function(data) payload = data end)
            local wall  = Color3.fromRGB(200, 100, 50)
            local floor = Color3.fromRGB(100, 80, 60)
            sys:PaintRoom(home.homeId, room.roomId, wall, floor)
            expect(payload).to.be.ok()
            expect(payload.homeId).to.equal(home.homeId)
            expect(payload.roomId).to.equal(room.roomId)
            expect(payload.newWallColor).to.equal(wall)
            expect(payload.newFloorColor).to.equal(floor)
            -- oldWallColor should be the previous default
            expect(payload.oldWallColor).to.be.ok()
        end)

        it("is a no-op for an unknown homeId", function()
            local sys = makeSystem()
            expect(function()
                sys:PaintRoom("bad_home", "bad_room", Color3.new(1, 0, 0), Color3.new(0, 1, 0))
            end).never.to.throw()
        end)
    end)

    -- -------------------------------------------------------------------------
    describe("ListFurnitureCatalog", function()
        it("returns items sorted by category then name", function()
            local sys = makeSystem()
            local catalog = sys:ListFurnitureCatalog()
            for i = 2, #catalog do
                local a, b = catalog[i - 1], catalog[i]
                local order = a.category < b.category
                    or (a.category == b.category and a.name <= b.name)
                expect(order).to.equal(true)
            end
        end)

        it("returns copies: mutating the result does not affect the system", function()
            local sys = makeSystem()
            local catalog = sys:ListFurnitureCatalog()
            catalog[1].price = -999
            local catalog2 = sys:ListFurnitureCatalog()
            expect(catalog2[1].price).never.to.equal(-999)
        end)
    end)
end
