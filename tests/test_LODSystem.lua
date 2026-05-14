--!strict
-- test_LODSystem.lua
-- TestEZ unit tests for LODSystem

return function()
    local EventBus = require(script.Parent.Parent.src.Core.EventBus)
    local LODSystem = require(script.Parent.Parent.src.LODSystem)

    local function makeSystem()
        local bus = EventBus.new()
        return LODSystem.new(bus), bus
    end

    -- Helper: create a minimal Model with one Part
    local function makeModel(name: string, size: Vector3?): Model
        local model = Instance.new("Model")
        model.Name = name or "TestModel"
        local part = Instance.new("Part")
        part.Size = size or Vector3.new(4, 4, 4)
        part.CFrame = CFrame.new(0, 0, 0)
        part.Anchored = true
        part.Parent = model
        return model
    end

    -- -----------------------------------------------------------------------
    describe("LODSystem.new", function()
        it("creates instance without error", function()
            expect(function()
                makeSystem()
            end).never.to.throw()
        end)

        it("has no registered objects initially", function()
            local sys = makeSystem()
            -- No objects should be registered at start
            expect(function()
                -- Unregistering a model that was never registered should be a no-op
                local model = makeModel("Ghost")
                sys:UnregisterObject(model)
                model:Destroy()
            end).never.to.throw()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("RegisterObject", function()
        it("registers a model without error", function()
            local sys = makeSystem()
            local model = makeModel("Reg1")
            expect(function()
                sys:RegisterObject(model)
            end).never.to.throw()
            model:Destroy()
        end)

        it("emits ObjectRegistered event", function()
            local sys, bus = makeSystem()
            local received = nil
            bus:Subscribe("ObjectRegistered", function(data) received = data end)
            local model = makeModel("RegEvent")
            sys:RegisterObject(model)
            expect(received).never.to.equal(nil)
            expect(received.modelName).to.equal("RegEvent")
            model:Destroy()
        end)

        it("can register the same model twice without error (idempotent)", function()
            local sys = makeSystem()
            local model = makeModel("Double")
            expect(function()
                sys:RegisterObject(model)
                sys:RegisterObject(model)
            end).never.to.throw()
            model:Destroy()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("UnregisterObject", function()
        it("unregisters a previously registered model", function()
            local sys = makeSystem()
            local model = makeModel("Unreg1")
            sys:RegisterObject(model)
            expect(function()
                sys:UnregisterObject(model)
            end).never.to.throw()
            model:Destroy()
        end)

        it("emits ObjectUnregistered event", function()
            local sys, bus = makeSystem()
            local received = nil
            bus:Subscribe("ObjectUnregistered", function(data) received = data end)
            local model = makeModel("UnregEvent")
            sys:RegisterObject(model)
            sys:UnregisterObject(model)
            expect(received).never.to.equal(nil)
            expect(received.modelName).to.equal("UnregEvent")
            model:Destroy()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("SetLODLevel", function()
        it("sets LOD level 0 (full) without error", function()
            local sys = makeSystem()
            local model = makeModel("LODSet0")
            sys:RegisterObject(model)
            expect(function()
                sys:SetLODLevel(model, 0)
            end).never.to.throw()
            model:Destroy()
        end)

        it("sets LOD level 3 (billboard) without error", function()
            local sys = makeSystem()
            local model = makeModel("LODSet3")
            sys:RegisterObject(model)
            expect(function()
                sys:SetLODLevel(model, 3)
            end).never.to.throw()
            model:Destroy()
        end)

        it("emits LODLevelChanged event with correct level", function()
            local sys, bus = makeSystem()
            local received = nil
            bus:Subscribe("LODLevelChanged", function(data) received = data end)
            local model = makeModel("LODEvt")
            sys:RegisterObject(model)
            sys:SetLODLevel(model, 2)
            expect(received).never.to.equal(nil)
            expect(received.level).to.equal(2)
            model:Destroy()
        end)

        it("all 4 LOD levels (0-3) can be applied in sequence", function()
            local sys = makeSystem()
            local model = makeModel("LODAll")
            sys:RegisterObject(model)
            expect(function()
                for level = 0, 3 do
                    sys:SetLODLevel(model, level)
                end
            end).never.to.throw()
            model:Destroy()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("UpdateLOD (camera distance)", function()
        it("can be called with a camera CFrame without error", function()
            local sys = makeSystem()
            local model = makeModel("UpdateTest")
            sys:RegisterObject(model)
            local cam = CFrame.new(Vector3.new(0, 50, 200))
            expect(function()
                sys:UpdateLOD(cam)
            end).never.to.throw()
            model:Destroy()
        end)

        it("very close camera selects level 0", function()
            local sys, bus = makeSystem()
            local lastLevel = -1
            bus:Subscribe("LODLevelChanged", function(data)
                lastLevel = data.level
            end)
            local model = makeModel("CloseCam")
            sys:RegisterObject(model)
            -- Camera right on top of the model
            local cam = CFrame.new(Vector3.new(0, 0, 0))
            sys:UpdateLOD(cam)
            -- Level 0 = full detail for close distances
            expect(lastLevel).to.equal(0)
            model:Destroy()
        end)

        it("very distant camera selects level 3", function()
            local sys, bus = makeSystem()
            local lastLevel = -1
            bus:Subscribe("LODLevelChanged", function(data)
                lastLevel = data.level
            end)
            local model = makeModel("FarCam")
            sys:RegisterObject(model)
            -- Camera 5000 studs away
            local cam = CFrame.new(Vector3.new(5000, 0, 0))
            sys:UpdateLOD(cam)
            -- Level 3 = billboard for extreme distances
            expect(lastLevel).to.equal(3)
            model:Destroy()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("Destroy / cleanup", function()
        it("Destroy disconnects RunService heartbeat without error", function()
            local sys = makeSystem()
            expect(function()
                sys:Destroy()
            end).never.to.throw()
        end)
    end)
end
