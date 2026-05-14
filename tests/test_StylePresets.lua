--!strict
-- test_StylePresets.lua
-- TestEZ unit tests for StylePresets

return function()
    local EventBus    = require(script.Parent.Parent.src.Core.EventBus)
    local StylePresets = require(script.Parent.Parent.src.StylePresets)

    local function makeSystem()
        local bus = EventBus.new()
        return StylePresets.new(bus), bus
    end

    -- -----------------------------------------------------------------------
    describe("StylePresets.new", function()
        it("creates instance with 5 default presets", function()
            local sys = makeSystem()
            local names = sys:ListPresets()
            expect(#names).to.equal(5)
        end)

        it("registers Minimalist, Voxel, HandPainted, FlatShaded, Gradient by default", function()
            local sys = makeSystem()
            local defaults = { "Minimalist", "Voxel", "HandPainted", "FlatShaded", "Gradient" }
            for _, name in ipairs(defaults) do
                expect(sys:GetPreset(name)).never.to.equal(nil)
            end
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("RegisterPreset", function()
        it("registers a new custom preset", function()
            local sys = makeSystem()
            sys:RegisterPreset({
                name            = "TestPreset",
                material        = Enum.Material.Neon,
                bevelSize       = 0.05,
                colorVariation  = 0.1,
                useGradients    = false,
                shadowIntensity = 0.5,
                outlineEnabled  = false,
                description     = "A test preset",
            })
            expect(sys:GetPreset("TestPreset")).never.to.equal(nil)
        end)

        it("throws on preset with empty name", function()
            local sys = makeSystem()
            expect(function()
                sys:RegisterPreset({
                    name            = "",
                    material        = Enum.Material.Plastic,
                    bevelSize       = 0,
                    colorVariation  = 0,
                    useGradients    = false,
                    shadowIntensity = 0,
                    outlineEnabled  = false,
                    description     = "invalid",
                })
            end).to.throw()
        end)

        it("overwrites an existing preset with the same name", function()
            local sys = makeSystem()
            sys:RegisterPreset({
                name            = "Minimalist",
                material        = Enum.Material.Neon,
                bevelSize       = 0.99,
                colorVariation  = 0.99,
                useGradients    = true,
                shadowIntensity = 0.99,
                outlineEnabled  = true,
                description     = "overwritten",
            })
            local preset = sys:GetPreset("Minimalist")
            expect(preset).never.to.equal(nil)
            expect(preset.bevelSize).to.equal(0.99)
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("GetPreset", function()
        it("returns nil for unknown preset name", function()
            local sys = makeSystem()
            expect(sys:GetPreset("DoesNotExist")).to.equal(nil)
        end)

        it("returns correct material for Voxel preset", function()
            local sys = makeSystem()
            local preset = sys:GetPreset("Voxel")
            expect(preset.material).to.equal(Enum.Material.Plastic)
        end)

        it("returns useGradients=true for HandPainted preset", function()
            local sys = makeSystem()
            local preset = sys:GetPreset("HandPainted")
            expect(preset.useGradients).to.equal(true)
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("ListPresets", function()
        it("returns sorted array", function()
            local sys = makeSystem()
            local names = sys:ListPresets()
            local sorted = true
            for i = 2, #names do
                if names[i] < names[i - 1] then
                    sorted = false
                    break
                end
            end
            expect(sorted).to.equal(true)
        end)

        it("count increases after RegisterPreset", function()
            local sys = makeSystem()
            local before = #sys:ListPresets()
            sys:RegisterPreset({
                name            = "Extra",
                material        = Enum.Material.Glass,
                bevelSize       = 0,
                colorVariation  = 0,
                useGradients    = false,
                shadowIntensity = 0,
                outlineEnabled  = false,
                description     = "extra preset",
            })
            expect(#sys:ListPresets()).to.equal(before + 1)
        end)
    end)

    -- -----------------------------------------------------------------------
    describe("ApplyPreset", function()
        it("warns without error for unknown preset name", function()
            local sys = makeSystem()
            local model = Instance.new("Model")
            expect(function()
                sys:ApplyPreset(model, "NoSuchPreset")
            end).never.to.throw()
            model:Destroy()
        end)

        it("sets material on all BaseParts", function()
            local sys = makeSystem()
            local model = Instance.new("Model")
            local part = Instance.new("Part")
            part.Parent = model
            sys:ApplyPreset(model, "Voxel")
            expect(part.Material).to.equal(Enum.Material.Plastic)
            model:Destroy()
        end)

        it("sets CastShadow=true when shadowIntensity > 0.5", function()
            local sys = makeSystem()
            -- Voxel has shadowIntensity = 0.8
            local model = Instance.new("Model")
            local part = Instance.new("Part")
            part.Parent = model
            sys:ApplyPreset(model, "Voxel")
            expect(part.CastShadow).to.equal(true)
            model:Destroy()
        end)

        it("sets CastShadow=false when shadowIntensity <= 0.5", function()
            local sys = makeSystem()
            -- Minimalist has shadowIntensity = 0
            local model = Instance.new("Model")
            local part = Instance.new("Part")
            part.Parent = model
            sys:ApplyPreset(model, "Minimalist")
            expect(part.CastShadow).to.equal(false)
            model:Destroy()
        end)

        it("emits PresetApplied with modelName, presetName, material, partCount", function()
            local sys, bus = makeSystem()
            local received = nil
            bus:Subscribe("PresetApplied", function(data) received = data end)
            local model = Instance.new("Model")
            local part = Instance.new("Part")
            part.Parent = model
            sys:ApplyPreset(model, "FlatShaded")
            expect(received).never.to.equal(nil)
            expect(received.presetName).to.equal("FlatShaded")
            expect(received.modelName).to.equal(model.Name)
            expect(received.partCount).to.equal(1)
            expect(received.material).to.equal(Enum.Material.SmoothPlastic)
            model:Destroy()
        end)

        it("handles empty model (no BaseParts) without error", function()
            local sys = makeSystem()
            local model = Instance.new("Model")
            expect(function()
                sys:ApplyPreset(model, "Minimalist")
            end).never.to.throw()
            model:Destroy()
        end)
    end)
end
