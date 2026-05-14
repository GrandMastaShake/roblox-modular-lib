--!strict
-- test_PetSystem.lua
-- Tests for PetSystem module.
--
-- These tests exercise PetSystem's public API without standing up a full
-- Roblox runtime. We mock EventBus + Config and skip the heartbeat-driven
-- decay path (those tests would require a Roblox server with RunService).

local PetSystem = require(script.Parent.Parent.src.PetSystem)

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

local function assertEq(a: any, b: any, msg: string)
	if a ~= b then
		error(msg .. " expected " .. tostring(b) .. " got " .. tostring(a))
	end
end

local function assertTrue(a: boolean, msg: string)
	if not a then
		error(msg .. " expected true")
	end
end

local function assertFalse(a: boolean, msg: string)
	if a then
		error(msg .. " expected false")
	end
end

local function assertNotNil(a: any, msg: string)
	if a == nil then
		error(msg .. " expected non-nil")
	end
end

local function createMockEventBus()
	return {
		_events = {} :: { [string]: { any } },
		Subscribe = function(_self: any, _eventName: string, _callback: (any) -> ()): () -> ()
			return function() end
		end,
		Emit = function(self: any, eventName: string, payload: any)
			if not self._events[eventName] then
				self._events[eventName] = {}
			end
			table.insert(self._events[eventName], payload)
		end,
	}
end

local function createMockConfig()
	-- Minimal mock that mimics Config.new() — supports only Get with default.
	local store: { [string]: any } = {}
	return {
		Get = function(_self: any, key: string, default: any?): any
			local v = store[key]
			if v == nil then
				return default
			end
			return v
		end,
		Set = function(_self: any, key: string, value: any)
			store[key] = value
		end,
		Reset = function(_self: any) end,
		All = function(_self: any) return {} end,
	}
end

local function basicSpecies(id: string, rarity: string?): any
	return {
		id                   = id,
		displayName          = id,
		rarity               = rarity or "common",
		hungerDecayPerSec    = 1.0,
		happinessDecayPerSec = 1.0,
		energyDecayPerSec    = 1.0,
	}
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

print("TEST: DefineSpecies registers and emits event")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)

	sys:DefineSpecies(basicSpecies("fox"))

	assertNotNil(sys:GetSpecies("fox"), "Species 'fox' should be registered")
	assertEq(#(bus._events["PetSpeciesRegistered"] or {}), 1, "PetSpeciesRegistered count")

	sys:Destroy()
end

print("TEST: HatchEgg creates pet, returns id, emits PetHatched")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local petId = sys:HatchEgg("fox", 12345, "Sparky")
	assertNotNil(petId, "HatchEgg should return a pet id")

	local pet = sys:GetPet(petId :: string)
	assertNotNil(pet, "GetPet should find the new pet")
	if pet then
		assertEq(pet.defId, "fox", "Pet defId")
		assertEq(pet.ownerId, 12345, "Pet ownerId")
		assertEq(pet.nickname, "Sparky", "Pet nickname")
		assertEq(pet.stage, "Egg", "New pet starts as Egg")
		assertEq(pet.hunger, 100, "Egg starts at full hunger")
	end

	assertEq(#(bus._events["PetHatched"] or {}), 1, "PetHatched count")

	sys:Destroy()
end

print("TEST: HatchEgg fails for unknown species")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)

	local petId = sys:HatchEgg("nonexistent", 1, nil)
	assertEq(petId, nil, "HatchEgg should return nil for unknown species")

	sys:Destroy()
end

print("TEST: Care actions reject Egg-stage pets")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local petId = sys:HatchEgg("fox", 1, "Sparky") :: string
	assertFalse(sys:Feed(petId), "Cannot feed an Egg")
	assertFalse(sys:Play(petId), "Cannot play with an Egg")
	assertFalse(sys:Sleep(petId), "Cannot put Egg to sleep")

	sys:Destroy()
end

print("TEST: Care actions on non-Egg pet raise stat and progress")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local petId = sys:HatchEgg("fox", 1, nil) :: string
	-- Manually transition past Egg for this test.
	local pet = sys:GetPet(petId)
	assertNotNil(pet, "Pet exists")
	if pet then
		pet.stage = "Newborn"
		pet.hunger = 50
	end

	assertTrue(sys:Feed(petId, 25), "Feed should succeed")
	pet = sys:GetPet(petId)
	if pet then
		assertEq(pet.hunger, 75, "Hunger should be raised to 75")
		assertEq(pet.progress.feedCount, 1, "feedCount should increment")
	end

	assertEq(#(bus._events["PetCared"] or {}), 1, "PetCared event")

	sys:Destroy()
end

print("TEST: SetFollowing respects max-following cap")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	cfg:Set("petMaxFollowing", 2)
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local p1 = sys:HatchEgg("fox", 1, nil) :: string
	local p2 = sys:HatchEgg("fox", 1, nil) :: string
	local p3 = sys:HatchEgg("fox", 1, nil) :: string

	assertTrue(sys:SetFollowing(p1, true), "First following ok")
	assertTrue(sys:SetFollowing(p2, true), "Second following ok")
	assertFalse(sys:SetFollowing(p3, true), "Third following should be capped")

	assertEq(#sys:GetFollowingPets(1), 2, "Two pets following")

	sys:Destroy()
end

print("TEST: SetInPen and SetFollowing are mutually exclusive")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local p = sys:HatchEgg("fox", 1, nil) :: string
	assertTrue(sys:SetFollowing(p, true), "Following on")
	assertTrue(sys:SetInPen(p, true), "Pen on (should auto-disable following)")

	local pet = sys:GetPet(p)
	if pet then
		assertFalse(pet.isFollowing, "Following should be off after pen on")
		assertTrue(pet.inPen, "Pen should be on")
	end

	sys:Destroy()
end

print("TEST: Release removes pet and emits event")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local petId = sys:HatchEgg("fox", 1, nil) :: string
	assertTrue(sys:HasPet(petId), "Pet exists")
	assertTrue(sys:Release(petId), "Release succeeds")
	assertFalse(sys:HasPet(petId), "Pet gone after release")

	assertEq(#(bus._events["PetReleased"] or {}), 1, "PetReleased event")

	sys:Destroy()
end

print("TEST: Serialize / Deserialize round-trip")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local p1 = sys:HatchEgg("fox", 42, "A") :: string
	local p2 = sys:HatchEgg("fox", 42, "B") :: string

	local serialized = sys:Serialize(42)
	assertEq(#serialized, 2, "Two pets serialized")

	-- New system, re-register species, deserialize.
	local sys2 = PetSystem.new(bus, cfg)
	sys2:DefineSpecies(basicSpecies("fox"))
	local restored = sys2:Deserialize(serialized)
	assertEq(restored, 2, "Two pets deserialized")
	assertNotNil(sys2:GetPet(p1), "p1 restored")
	assertNotNil(sys2:GetPet(p2), "p2 restored")

	sys:Destroy()
	sys2:Destroy()
end

print("TEST: Deserialize skips pets whose species isn't registered")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	-- intentionally don't register species
	local count = sys:Deserialize({
		{
			id = "x", defId = "ghost", ownerId = 1, nickname = "G",
			stage = "Newborn", bornAt = 0, ageSeconds = 0,
			hunger = 100, happiness = 100, energy = 100,
			progress = { feedCount = 0, playCount = 0, sleepCount = 0 },
			isNeon = false, isMega = false, isFollowing = false, inPen = false,
		},
	})
	assertEq(count, 0, "Zero deserialized when species missing")

	sys:Destroy()
end

print("TEST: OwnsPet correctly checks ownership")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local petId = sys:HatchEgg("fox", 100, nil) :: string
	assertTrue(sys:OwnsPet(100, petId), "Player 100 owns it")
	assertFalse(sys:OwnsPet(200, petId), "Player 200 does not")

	sys:Destroy()
end

print("TEST: TransferOwnership moves pet to new owner and emits event")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local petId = sys:HatchEgg("fox", 100, nil) :: string
	-- Mark following so we can verify it gets cleared on transfer.
	sys:SetFollowing(petId, true)

	assertTrue(sys:TransferOwnership(petId, 200), "Transfer succeeds")
	assertTrue(sys:OwnsPet(200, petId), "Pet owned by 200 after transfer")
	assertFalse(sys:OwnsPet(100, petId), "Original owner no longer owns it")

	local pet = sys:GetPet(petId)
	if pet then
		assertFalse(pet.isFollowing, "Following cleared on transfer")
		assertFalse(pet.inPen, "Pen cleared on transfer")
	end

	local events = bus._events["PetOwnershipTransferred"] or {}
	assertEq(#events, 1, "PetOwnershipTransferred fired exactly once")
	if events[1] then
		assertEq(events[1].previousOwnerId, 100, "previousOwnerId")
		assertEq(events[1].newOwnerId, 200, "newOwnerId")
	end

	sys:Destroy()
end

print("TEST: TransferOwnership to same owner is a no-op")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)
	sys:DefineSpecies(basicSpecies("fox"))

	local petId = sys:HatchEgg("fox", 100, nil) :: string
	assertTrue(sys:TransferOwnership(petId, 100), "Same-owner transfer ok")
	local events = bus._events["PetOwnershipTransferred"] or {}
	assertEq(#events, 0, "No event emitted for same-owner transfer")

	sys:Destroy()
end

print("TEST: TransferOwnership of nonexistent pet returns false")
do
	local bus = createMockEventBus()
	local cfg = createMockConfig()
	local sys = PetSystem.new(bus, cfg)

	assertFalse(sys:TransferOwnership("ghost", 1), "Cannot transfer ghost pet")

	sys:Destroy()
end

print("All PetSystem tests passed!")

return true
