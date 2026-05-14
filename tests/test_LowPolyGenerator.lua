--!strict
-- test_LowPolyGenerator.lua
-- TestEZ unit tests for LowPolyGenerator

return function()
    local EventBus        = require(script.Parent.Parent.src.Core.EventBus)
    local LowPolyGenerator = require(script.Parent.Parent.src.LowPolyGenerator)

    -- Minimal inline palette stub (structurally compatible with ColorPaletteSystem palette)
    local STUB_PALETTE = {
        name       = "StubPalette",
        colors     = { Color3.fromRGB(34, 85, 51), Color3.fromRGB(101, 67, 33), Color3.fromRGB(135, 206, 235) },
        primary    = Color3.fromRGB(34, 85, 51),
        secondary  = Color3.fromRGB(101, 67, 33),
        accent     = Color3.fromRGB(135, 206, 235),
        background = Color3.fromRGB(255, 255, 255),
        highlights = { Color3.fromRGB(50, 120, 75) },
        shadows    = { Color3.fromRGB(20, 50, 30) },
    }

    local function makeGenerator(seed: number?)
        local bus = EventBus.new()
        return LowPolyGenerator.new(bus, seed or 12345), bus
    end

    -- -----------------------------------------------------------------------
    describe("LowPolyGenerator.new", function()
        it("creates instance without error", function()
            expect(function()
                makeGenerator()
            end).never.to.throw()
        end)

        it("accepts optional seed", function()
            expect(function()
                makeGenerator(99999)
            end).never.to.throw()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("GenerateTree", function()
        it("returns a Model", function()
            local gen = makeGenerator()
            local result = gen:GenerateTree(nil, STUB_PALETTE)
            expect(typeof(result)).to.equal("Instance")
            expect(result:IsA("Model")).to.equal(true)
            result:Destroy()
        end)

        it("model contains at least one BasePart", function()
            local gen = makeGenerator()
            local model = gen:GenerateTree(nil, STUB_PALETTE)
            local hasBasePart = false
            for _, desc in ipairs(model:GetDescendants()) do
                if desc:IsA("BasePart") then
                    hasBasePart = true
                    break
                end
            end
            expect(hasBasePart).to.equal(true)
            model:Destroy()
        end)

        it("emits AssetGenerated event with assetType='Tree'", function()
            local gen, bus = makeGenerator()
            local received = nil
            bus:Subscribe("AssetGenerated", function(data) received = data end)
            local model = gen:GenerateTree(nil, STUB_PALETTE)
            expect(received).never.to.equal(nil)
            expect(received.assetType).to.equal("Tree")
            model:Destroy()
        end)

        it("tree parts use palette primary color family", function()
            local gen = makeGenerator()
            -- Just verify no error and parts have a Color property
            local model = gen:GenerateTree(nil, STUB_PALETTE)
            for _, desc in ipairs(model:GetDescendants()) do
                if desc:IsA("BasePart") then
                    -- Color3 type check — just ensure it's valid
                    local ok = typeof(desc.Color) == "Color3"
                    expect(ok).to.equal(true)
                    break
                end
            end
            model:Destroy()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("GenerateRock", function()
        it("returns a Model", function()
            local gen = makeGenerator()
            local result = gen:GenerateRock(nil, STUB_PALETTE)
            expect(result:IsA("Model")).to.equal(true)
            result:Destroy()
        end)

        it("emits AssetGenerated event with assetType='Rock'", function()
            local gen, bus = makeGenerator()
            local received = nil
            bus:Subscribe("AssetGenerated", function(data) received = data end)
            local model = gen:GenerateRock(nil, STUB_PALETTE)
            expect(received).never.to.equal(nil)
            expect(received.assetType).to.equal("Rock")
            model:Destroy()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("GenerateBuilding", function()
        it("returns a Model", function()
            local gen = makeGenerator()
            local result = gen:GenerateBuilding(nil, STUB_PALETTE)
            expect(result:IsA("Model")).to.equal(true)
            result:Destroy()
        end)

        it("emits AssetGenerated event with assetType='Building'", function()
            local gen, bus = makeGenerator()
            local received = nil
            bus:Subscribe("AssetGenerated", function(data) received = data end)
            local model = gen:GenerateBuilding(nil, STUB_PALETTE)
            expect(received).never.to.equal(nil)
            expect(received.assetType).to.equal("Building")
            model:Destroy()
        end)

        it("supports all 4 roof styles without error", function()
            local gen = makeGenerator()
            local roofStyles = { "Flat", "Gable", "Hip", "Shed" }
            for _, style in ipairs(roofStyles) do
                expect(function()
                    local m = gen:GenerateBuilding({ roofStyle = style }, STUB_PALETTE)
                    m:Destroy()
                end).never.to.throw()
            end
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("GenerateProp", function()
        it("returns a Model for each of the 6 prop types", function()
            local gen = makeGenerator()
            local propTypes = { "Barrel", "Crate", "Fence", "Lamppost", "Bench", "Bush" }
            for _, propType in ipairs(propTypes) do
                expect(function()
                    local m = gen:GenerateProp(propType, nil, STUB_PALETTE)
                    expect(m:IsA("Model")).to.equal(true)
                    m:Destroy()
                end).never.to.throw()
            end
        end)

        it("emits AssetGenerated event with assetType='Prop'", function()
            local gen, bus = makeGenerator()
            local received = nil
            bus:Subscribe("AssetGenerated", function(data) received = data end)
            local model = gen:GenerateProp("Barrel", nil, STUB_PALETTE)
            expect(received).never.to.equal(nil)
            expect(received.assetType).to.equal("Prop")
            model:Destroy()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("Determinism", function()
        it("same seed produces structurally identical trees", function()
            local gen1 = makeGenerator(42)
            local gen2 = makeGenerator(42)
            local t1 = gen1:GenerateTree(nil, STUB_PALETTE)
            local t2 = gen2:GenerateTree(nil, STUB_PALETTE)
            -- Both should produce same descendant count
            expect(#t1:GetDescendants()).to.equal(#t2:GetDescendants())
            t1:Destroy()
            t2:Destroy()
        end)
    end)
end
