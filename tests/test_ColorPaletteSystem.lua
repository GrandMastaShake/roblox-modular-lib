--!strict
-- test_ColorPaletteSystem.lua
-- TestEZ unit tests for ColorPaletteSystem

return function()
    local EventBus           = require(script.Parent.Parent.src.Core.EventBus)
    local ColorPaletteSystem = require(script.Parent.Parent.src.ColorPaletteSystem)

    -- Minimal stub for Config (not required by ColorPaletteSystem constructor)
    local function makeSystem()
        local bus = EventBus.new()
        return ColorPaletteSystem.new(bus, nil), bus
    end

    -- -----------------------------------------------------------------------
    describe("ColorPaletteSystem.new", function()
        it("creates instance with 6 default palettes", function()
            local sys = makeSystem()
            local names = sys:ListPalettes()
            expect(#names).to.equal(6)
        end)

        it("registers Minimalist, Forest, Sunset, Ocean, Voxel, Monochrome by default", function()
            local sys = makeSystem()
            local defaults = { "Minimalist", "Forest", "Sunset", "Ocean", "Voxel", "Monochrome" }
            for _, name in ipairs(defaults) do
                expect(sys:GetPalette(name)).never.to.equal(nil)
            end
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("CreatePalette", function()
        it("registers a new named palette", function()
            local sys = makeSystem()
            sys:CreatePalette("TestPal", {
                Color3.fromRGB(255, 0, 0),
                Color3.fromRGB(0, 255, 0),
            })
            expect(sys:GetPalette("TestPal")).never.to.equal(nil)
        end)

        it("returns a palette with correct name", function()
            local sys = makeSystem()
            local pal = sys:CreatePalette("Alpha", { Color3.fromRGB(100, 100, 100) })
            expect(pal.name).to.equal("Alpha")
        end)

        it("derives primary from first color", function()
            local sys = makeSystem()
            local c1 = Color3.fromRGB(200, 100, 50)
            local pal = sys:CreatePalette("PrimTest", { c1, Color3.fromRGB(0, 0, 0) })
            expect(pal.primary).to.equal(c1)
        end)

        it("derives highlights and shadows arrays", function()
            local sys = makeSystem()
            local pal = sys:CreatePalette("HLTest", {
                Color3.fromRGB(128, 128, 128),
                Color3.fromRGB(64, 64, 64),
            })
            expect(#pal.highlights > 0).to.equal(true)
            expect(#pal.shadows > 0).to.equal(true)
        end)

        it("emits PaletteCreated with correct name", function()
            local sys, bus = makeSystem()
            local received = nil
            bus:Subscribe("PaletteCreated", function(data) received = data end)
            sys:CreatePalette("Emit1", { Color3.new(1, 0, 0) })
            expect(received).never.to.equal(nil)
            expect(received.name).to.equal("Emit1")
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("GetColor", function()
        it("returns the color at given index", function()
            local sys = makeSystem()
            local c = Color3.fromRGB(10, 20, 30)
            sys:CreatePalette("IdxTest", { c, Color3.fromRGB(255, 255, 255) })
            expect(sys:GetColor("IdxTest", 1)).to.equal(c)
        end)

        it("falls back to primary for out-of-range index", function()
            local sys = makeSystem()
            local c = Color3.fromRGB(10, 20, 30)
            sys:CreatePalette("FallBack", { c })
            -- index 99 does not exist
            expect(sys:GetColor("FallBack", 99)).to.equal(c)
        end)

        it("warns and returns white for missing palette", function()
            local sys = makeSystem()
            local result = sys:GetColor("DoesNotExist", 1)
            expect(result).to.equal(Color3.new(1, 1, 1))
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("GetPalette / ListPalettes", function()
        it("GetPalette returns nil for unknown name", function()
            local sys = makeSystem()
            expect(sys:GetPalette("NoSuchPalette")).to.equal(nil)
        end)

        it("ListPalettes returns sorted array of names", function()
            local sys = makeSystem()
            sys:CreatePalette("Zebra", { Color3.new(1, 1, 1) })
            sys:CreatePalette("Apple", { Color3.new(0, 0, 0) })
            local names = sys:ListPalettes()
            -- Should be alphabetically sorted
            local sorted = true
            for i = 2, #names do
                if names[i] < names[i - 1] then
                    sorted = false
                    break
                end
            end
            expect(sorted).to.equal(true)
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("HSV manipulation", function()
        it("ShiftHue produces a different color", function()
            local sys = makeSystem()
            local base = Color3.fromHSV(0, 1, 1)   -- pure red
            local shifted = sys:ShiftHue(base, 120)  -- should be green
            local h, _, _ = Color3.toHSV(shifted)
            -- hue ~ 0.333 (120/360)
            expect(math.abs(h - 1/3) < 0.01).to.equal(true)
        end)

        it("Darken reduces value", function()
            local sys = makeSystem()
            local base = Color3.fromHSV(0.5, 0.5, 0.8)
            local dark = sys:Darken(base, 0.2)
            local _, _, v = Color3.toHSV(dark)
            expect(math.abs(v - 0.6) < 0.001).to.equal(true)
        end)

        it("Lighten increases value, clamped at 1", function()
            local sys = makeSystem()
            local base = Color3.fromHSV(0.5, 0.5, 0.9)
            local light = sys:Lighten(base, 0.5)
            local _, _, v = Color3.toHSV(light)
            expect(v).to.equal(1)
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("ApplyToModel", function()
        it("warns on unknown palette without error", function()
            local sys = makeSystem()
            local model = Instance.new("Model")
            -- Should warn but not throw
            expect(function()
                sys:ApplyToModel(model, "UnknownPalette")
            end).never.to.throw()
            model:Destroy()
        end)

        it("applies color to BaseParts", function()
            local sys = makeSystem()
            sys:CreatePalette("SolidRed", { Color3.fromRGB(255, 0, 0) })
            local model = Instance.new("Model")
            local part = Instance.new("Part")
            part.Parent = model
            sys:ApplyToModel(model, "SolidRed")
            expect(part.Color).to.equal(Color3.fromRGB(255, 0, 0))
            model:Destroy()
        end)

        it("emits PaletteApplied with partsRecolored > 0", function()
            local sys, bus = makeSystem()
            sys:CreatePalette("EmitTest", { Color3.fromRGB(0, 0, 255) })
            local received = nil
            bus:Subscribe("PaletteApplied", function(data) received = data end)
            local model = Instance.new("Model")
            local part = Instance.new("Part")
            part.Parent = model
            sys:ApplyToModel(model, "EmitTest")
            expect(received).never.to.equal(nil)
            expect(received.partsRecolored).to.equal(1)
            expect(received.modelName).to.equal(model.Name)
            model:Destroy()
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("ApplyPaletteToScene", function()
        it("does nothing when scene is nil", function()
            local sys = makeSystem()
            expect(function()
                sys:ApplyPaletteToScene(nil, "Minimalist")
            end).never.to.throw()
        end)

        it("warns when scene has no objectFolder", function()
            local sys = makeSystem()
            expect(function()
                sys:ApplyPaletteToScene({}, "Minimalist")
            end).never.to.throw()
        end)

        it("applies palette to all Model children of objectFolder", function()
            local sys = makeSystem()
            sys:CreatePalette("SceneBlue", { Color3.fromRGB(0, 0, 255) })

            local folder = Instance.new("Folder")
            local model = Instance.new("Model")
            model.Parent = folder
            local part = Instance.new("Part")
            part.Parent = model

            sys:ApplyPaletteToScene({ objectFolder = folder }, "SceneBlue")
            expect(part.Color).to.equal(Color3.fromRGB(0, 0, 255))
            folder:Destroy()
        end)
    end)
end
