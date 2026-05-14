--!strict
-- test_EnvironmentBuilder.lua
-- TestEZ unit tests for EnvironmentBuilder

return function()
    local EventBus          = require(script.Parent.Parent.src.Core.EventBus)
    local EnvironmentBuilder = require(script.Parent.Parent.src.EnvironmentBuilder)

    -- Minimal stub for LowPolyGenerator dependency
    local function makeLowPolyStub()
        return {
            GenerateTree     = function(_, ...) local m = Instance.new("Model") return m end,
            GenerateRock     = function(_, ...) local m = Instance.new("Model") return m end,
            GenerateBuilding = function(_, ...) local m = Instance.new("Model") return m end,
            GenerateProp     = function(_, ...) local m = Instance.new("Model") return m end,
        }
    end

    -- Minimal stub for ColorPaletteSystem dependency
    local STUB_PALETTE = {
        name       = "StubPal",
        colors     = { Color3.fromRGB(100, 150, 80) },
        primary    = Color3.fromRGB(100, 150, 80),
        secondary  = Color3.fromRGB(80, 100, 60),
        accent     = Color3.fromRGB(200, 180, 100),
        background = Color3.fromRGB(220, 220, 200),
        highlights = {},
        shadows    = {},
    }

    local function makePaletteSysStub()
        return {
            GetPalette   = function(_, _name) return STUB_PALETTE end,
            ApplyToModel = function(_, _model, _name) end,
            ApplyPaletteToScene = function(_, _scene, _name) end,
        }
    end

    -- Minimal stub for StylePresets dependency
    local function makeStyleStub()
        return {
            GetPreset   = function(_, _name)
                return {
                    name            = "Minimalist",
                    material        = Enum.Material.SmoothPlastic,
                    bevelSize       = 0,
                    colorVariation  = 0.1,
                    useGradients    = false,
                    shadowIntensity = 0,
                    outlineEnabled  = false,
                    description     = "stub",
                }
            end,
            ApplyPreset = function(_, _model, _name) end,
        }
    end

    local function makeBuilder()
        local bus = EventBus.new()
        local gen = makeLowPolyStub()
        local pal = makePaletteSysStub()
        local sty = makeStyleStub()
        return EnvironmentBuilder.new(bus, gen, pal, sty), bus
    end

    -- -----------------------------------------------------------------------
    describe("EnvironmentBuilder.new", function()
        it("creates instance without error", function()
            expect(function()
                makeBuilder()
            end).never.to.throw()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("SetLighting", function()
        it("applies a known lighting style without error", function()
            local builder = makeBuilder()
            expect(function()
                builder:SetLighting("Natural")
            end).never.to.throw()
        end)

        it("emits LightingSet event with styleName", function()
            local builder, bus = makeBuilder()
            local received = nil
            bus:Subscribe("LightingSet", function(data) received = data end)
            builder:SetLighting("Natural")
            expect(received).never.to.equal(nil)
            expect(received.styleName).to.equal("Natural")
        end)

        it("emits LightingSet with flat brightness and ambient fields", function()
            local builder, bus = makeBuilder()
            local received = nil
            bus:Subscribe("LightingSet", function(data) received = data end)
            builder:SetLighting("Natural")
            expect(typeof(received.brightness)).to.equal("number")
            expect(typeof(received.ambient)).to.equal("Color3")
        end)

        it("warns without error for unknown lighting style", function()
            local builder = makeBuilder()
            expect(function()
                builder:SetLighting("UnknownStyle")
            end).never.to.throw()
        end)

        it("supports all built-in styles", function()
            local builder = makeBuilder()
            local styles = { "Natural", "Stylized", "Dramatic", "Soft", "Night", "Sunset" }
            for _, style in ipairs(styles) do
                expect(function()
                    builder:SetLighting(style)
                end).never.to.throw()
            end
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("BuildScene", function()
        it("returns a Scene table with required fields", function()
            local builder = makeBuilder()
            local scene = builder:BuildScene({
                sizeX      = 50,
                sizeZ      = 50,
                treeCount  = 2,
                rockCount  = 1,
                buildingCount = 0,
                propCount  = 1,
                paletteName = "StubPal",
                styleName  = "Minimalist",
                seed       = 1,
            })
            expect(scene).never.to.equal(nil)
            expect(scene.root).never.to.equal(nil)
            expect(scene.objectFolder).never.to.equal(nil)
            expect(scene.objectCount).never.to.equal(nil)
            expect(scene.partCount).never.to.equal(nil)
        end)

        it("scene asset arrays are populated", function()
            local builder = makeBuilder()
            local scene = builder:BuildScene({
                sizeX      = 50,
                sizeZ      = 50,
                treeCount  = 2,
                rockCount  = 1,
                buildingCount = 1,
                propCount  = 1,
                paletteName = "StubPal",
                styleName  = "Minimalist",
                seed       = 1,
            })
            expect(#scene.trees).to.equal(2)
            expect(#scene.rocks).to.equal(1)
            expect(#scene.buildings).to.equal(1)
            expect(#scene.props).to.equal(1)
        end)

        it("emits SceneBuilt with flat fields", function()
            local builder, bus = makeBuilder()
            local received = nil
            bus:Subscribe("SceneBuilt", function(data) received = data end)
            builder:BuildScene({
                sizeX      = 30,
                sizeZ      = 30,
                treeCount  = 1,
                rockCount  = 0,
                buildingCount = 0,
                propCount  = 0,
                paletteName = "StubPal",
                styleName  = "Minimalist",
                seed       = 7,
            })
            expect(received).never.to.equal(nil)
            expect(received.sizeX).to.equal(30)
            expect(received.sizeZ).to.equal(30)
            expect(received.seed).to.equal(7)
            expect(received.paletteName).to.equal("StubPal")
            expect(received.styleName).to.equal("Minimalist")
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("ClearScene", function()
        it("clears a scene built earlier without error", function()
            local builder = makeBuilder()
            builder:BuildScene({
                sizeX      = 20,
                sizeZ      = 20,
                treeCount  = 1,
                rockCount  = 1,
                buildingCount = 0,
                propCount  = 0,
                paletteName = "StubPal",
                styleName  = "Minimalist",
                seed       = 2,
            })
            expect(function()
                builder:ClearScene()
            end).never.to.throw()
        end)

        it("emits SceneCleared event", function()
            local builder, bus = makeBuilder()
            local received = nil
            bus:Subscribe("SceneCleared", function(data) received = data end)
            builder:BuildScene({
                sizeX = 20, sizeZ = 20,
                treeCount = 0, rockCount = 0, buildingCount = 0, propCount = 0,
                paletteName = "StubPal", styleName = "Minimalist", seed = 3,
            })
            builder:ClearScene()
            expect(received).never.to.equal(nil)
        end)

        it("clears when no scene has been built (no error)", function()
            local builder = makeBuilder()
            expect(function()
                builder:ClearScene()
            end).never.to.throw()
        end)
    end)
end
