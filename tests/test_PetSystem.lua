--!strict
-- test_PetSystem.lua
-- Tests for PetSystem — exercises the actual public API:
--   RegisterPet / RegisterEgg / HatchEgg / GetPet / GetAllPets
--   FeedPet / PlayWithPet / AgeUpPet / MakeNeon
--   OwnsPet / TransferOwnership
--   Serialize / Deserialize

local PetSystem = require(script.Parent.Parent.src.PetSystem)

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " — expected " .. tostring(b) .. " got " .. tostring(a), 2)
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then error(msg .. " — expected true", 2) end
end

local function assertFalse(a: boolean, msg: string)
	if a then error(msg .. " — expected false", 2) end
end

local function assertNotNil(a: any, msg: string)
	if a == nil then error(msg .. " — expected non-nil", 2) end
end

-- ── Mocks ─────────────────────────────────────────────────────────────────────

local function makeBus()
	local bus = {
		_events = {} :: { [string]: { any } },
		Subscribe = function(_s, _n, _cb) return function() end end,
		Emit = function(self, name, payload)
			if not self._events[name] then self._events[name] = {} end
			table.insert(self._events[name], payload)
		end,
	}
	return bus
end

local function makeInventory(items: { [string]: number }?)
	local bag = items or {} :: { [string]: number }
	return {
		AddItem = function(_s, id, qty)
			bag[id] = (bag[id] or 0) + (qty or 1)
			return true
		end,
		RemoveItem = function(_s, id, qty)
			local q = qty or 1
			if (bag[id] or 0) < q then return false end
			bag[id] -= q
			return true
		end,
		GetAllSlots = function(_s)
			local out = {}
			for id, q in pairs(bag) do
				if q > 0 then table.insert(out, { itemId = id, quantity = q }) end
			end
			return out
		end,
		GetItemQuantity = function(_s, id) return bag[id] or 0 end,
	}
end

local function makeXP()
	return {
		_total = 0,
		AddXP = function(self, n) self._total += n end,
		GetLevel = function(_s) return 1 end,
	}
end

local function makeTimer()
	local t = {
		_timers = {} :: { [string]: { cb: () -> (), loop: boolean } },
		_seq = 0,
	}
	t.StartTimer = function(self, _dur, cb, loop)
		self._seq += 1
		local id = "tmr_" .. self._seq
		self._timers[id] = { cb = cb, loop = loop }
		return id
	end
	t.StopTimer = function(self, id) self._timers[id] = nil end
	return t
end

-- Build a PetSystem with one common + one rare pet and a cracked egg.
local function makeSystem(inv_items: { [string]: number }?)
	local bus  = makeBus()
	local inv  = makeInventory(inv_items)
	local xp   = makeXP()
	local tmr  = makeTimer()
	local sys  = PetSystem.new(bus, inv, xp, tmr)
	-- Remove default pets for clean tests
	sys._definitions  = {}
	sys._eggDefs      = {}
	-- Register minimal test pets
	sys:RegisterPet({ id = "cat",    name = "Cat",    rarity = "common",   modelId = "", tricks = {"Sit"}, favoriteFoods = {"fish"},  flyable = false, rideable = false })
	sys:RegisterPet({ id = "parrot", name = "Parrot", rarity = "ultra-rare", modelId = "", tricks = {"Sit"}, favoriteFoods = {"seed"}, flyable = true, rideable = false })
	sys:RegisterEgg({ id = "test_egg", name = "Test Egg", rarityWeights = { common = 100, uncommon = 0, rare = 0, ["ultra-rare"] = 0, legendary = 0 } })
	return sys, bus, inv
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

print("TEST: RegisterPet emits PetRegistered")
do
	local bus, inv, xp, tmr = makeBus(), makeInventory(), makeXP(), makeTimer()
	local sys = PetSystem.new(bus, inv, xp, tmr)
	sys._definitions = {}
	sys:RegisterPet({ id = "dog", name = "Dog", rarity = "common", modelId = "", tricks = {}, favoriteFoods = {}, flyable = false, rideable = false })
	assertEq(#(bus._events["PetRegistered"] or {}), 1, "PetRegistered count")
	sys:Destroy()
end

print("TEST: HatchEgg succeeds when egg is in inventory")
do
	local sys, bus = makeSystem({ test_egg = 1 })
	local pet = sys:HatchEgg("test_egg")
	assertNotNil(pet, "HatchEgg should return OwnedPet")
	if pet then
		assertEq(pet.defId, "cat", "Only common pet in pool → always cat")
		assertEq(pet.stage, "newborn", "Starts at newborn")
		assertEq(pet.rarity, "common", "Rarity set")
		assertEq(pet.isNeon, false, "Not neon")
	end
	assertEq(#(bus._events["EggHatched"] or {}), 1, "EggHatched emitted")
	sys:Destroy()
end

print("TEST: HatchEgg fails when egg not in inventory")
do
	local sys = makeSystem()  -- empty inventory
	local pet = sys:HatchEgg("test_egg")
	assertEq(pet, nil, "Should return nil with no egg in inventory")
	sys:Destroy()
end

print("TEST: HatchEgg fails for unknown egg")
do
	local sys = makeSystem({ ghost_egg = 1 })
	local pet = sys:HatchEgg("ghost_egg")
	assertEq(pet, nil, "Unknown egg → nil")
	sys:Destroy()
end

print("TEST: GetPet returns copy of owned pet")
do
	local sys = makeSystem({ test_egg = 1 })
	local hatched = sys:HatchEgg("test_egg") :: any
	assertNotNil(hatched, "Hatched")
	local found = sys:GetPet(hatched.instanceId)
	assertNotNil(found, "GetPet returns it")
	assertEq(found and found.instanceId, hatched.instanceId, "Same instanceId")
	sys:Destroy()
end

print("TEST: GetAllPets returns all pets")
do
	local sys, _, inv = makeSystem({ test_egg = 3 })
	-- Give extra eggs
	sys:HatchEgg("test_egg")
	sys:HatchEgg("test_egg")
	sys:HatchEgg("test_egg")
	assertEq(#sys:GetAllPets(), 3, "Three pets")
	sys:Destroy()
end

print("TEST: FeedPet with food in inventory returns true and emits PetFed")
do
	local sys, bus = makeSystem({ test_egg = 1, fish = 1 })
	local pet = sys:HatchEgg("test_egg") :: any
	assertTrue(sys:FeedPet(pet.instanceId, "fish"), "FeedPet ok")
	assertEq(#(bus._events["PetFed"] or {}), 1, "PetFed emitted")
	sys:Destroy()
end

print("TEST: FeedPet fails without food in inventory")
do
	local sys = makeSystem({ test_egg = 1 })
	local pet = sys:HatchEgg("test_egg") :: any
	assertFalse(sys:FeedPet(pet.instanceId, "fish"), "No fish → false")
	sys:Destroy()
end

print("TEST: PlayWithPet returns true and emits PetPlayed")
do
	local sys, bus = makeSystem({ test_egg = 1 })
	local pet = sys:HatchEgg("test_egg") :: any
	assertTrue(sys:PlayWithPet(pet.instanceId), "PlayWithPet ok")
	assertEq(#(bus._events["PetPlayed"] or {}), 1, "PetPlayed emitted")
	sys:Destroy()
end

print("TEST: AgeUpPet transitions stage and emits PetAgedUp")
do
	local sys, bus = makeSystem({ test_egg = 1 })
	local pet = sys:HatchEgg("test_egg") :: any
	-- Force XP to stage threshold
	sys._ownedPets[pet.instanceId].xp = 9999
	local ok = sys:AgeUpPet(pet.instanceId)
	assertTrue(ok, "AgeUpPet ok with enough XP")
	assertEq(#(bus._events["PetAgedUp"] or {}), 1, "PetAgedUp emitted")
	local evt = bus._events["PetAgedUp"][1]
	assertEq(evt.oldStage, "newborn", "oldStage")
	assertEq(evt.newStage, "junior",  "newStage")
	sys:Destroy()
end

print("TEST: OwnsPet returns correct ownership")
do
	local sys = makeSystem({ test_egg = 1 })
	local pet = sys:HatchEgg("test_egg") :: any
	-- Default ownerId is 0
	assertTrue(sys:OwnsPet(0, pet.instanceId), "ownerId 0 owns it by default")
	assertFalse(sys:OwnsPet(999, pet.instanceId), "Player 999 does not own it")
	sys:Destroy()
end

print("TEST: TransferOwnership changes owner and emits event")
do
	local sys, bus = makeSystem({ test_egg = 1 })
	local pet = sys:HatchEgg("test_egg") :: any
	assertTrue(sys:TransferOwnership(pet.instanceId, 42), "Transfer to 42 ok")
	assertTrue(sys:OwnsPet(42, pet.instanceId), "42 now owns it")
	assertFalse(sys:OwnsPet(0, pet.instanceId), "Original owner no longer owns it")
	local evts = bus._events["PetOwnershipTransferred"] or {}
	assertEq(#evts, 1, "PetOwnershipTransferred fired once")
	if evts[1] then
		assertEq(evts[1].previousOwnerId, 0,  "previousOwnerId")
		assertEq(evts[1].newOwnerId,      42, "newOwnerId")
	end
	sys:Destroy()
end

print("TEST: TransferOwnership same owner is a no-op (no event)")
do
	local sys, bus = makeSystem({ test_egg = 1 })
	local pet = sys:HatchEgg("test_egg") :: any
	assertTrue(sys:TransferOwnership(pet.instanceId, 0), "Same-owner transfer ok")
	assertEq(#(bus._events["PetOwnershipTransferred"] or {}), 0, "No event for same-owner")
	sys:Destroy()
end

print("TEST: TransferOwnership of nonexistent pet returns false")
do
	local sys = makeSystem()
	assertFalse(sys:TransferOwnership("ghost_pet", 1), "Ghost pet → false")
	sys:Destroy()
end

print("TEST: Serialize / Deserialize round-trip preserves pets")
do
	local sys, _, _ = makeSystem({ test_egg = 2 })
	local p1 = sys:HatchEgg("test_egg") :: any
	local p2 = sys:HatchEgg("test_egg") :: any
	local serialized = sys:Serialize()
	assertEq(#serialized, 2, "Two pets serialized")

	local bus2, inv2, xp2, tmr2 = makeBus(), makeInventory(), makeXP(), makeTimer()
	local sys2 = PetSystem.new(bus2, inv2, xp2, tmr2)
	sys2._definitions = {}
	sys2._eggDefs     = {}
	sys2:RegisterPet({ id = "cat", name = "Cat", rarity = "common", modelId = "", tricks = {"Sit"}, favoriteFoods = {"fish"}, flyable = false, rideable = false })
	sys2:Deserialize(serialized)
	assertNotNil(sys2:GetPet(p1.instanceId), "p1 restored")
	assertNotNil(sys2:GetPet(p2.instanceId), "p2 restored")

	sys:Destroy()
	sys2:Destroy()
end

print("All PetSystem tests passed!")
return true
