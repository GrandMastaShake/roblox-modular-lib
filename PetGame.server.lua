--!strict
-- PetGame.lua
-- Composition root for the pet-game demo, built on top of roblox-modular-lib.
--
-- ============================================================================
-- WHY THIS FILE EXISTS
-- ============================================================================
-- Every module in src/ is independent — they only know about Core (EventBus,
-- Config, Types). This file is the ONLY place that knows about every module
-- at once. It:
--
--   1. Creates the shared services (EventBus, Config).
--   2. Instantiates each feature module with dependency injection.
--   3. Wires cross-module reactions through the event bus.
--   4. Defines starter content (species, items, currencies, quests).
--   5. Sets up new players when they join.
--
-- This is the same pattern used by ExampleGame.lua, just retargeted to the
-- pet-care gameplay loop.
--
-- ============================================================================
-- DEMO SCOPE
-- ============================================================================
-- Implemented:
--   * Hatch eggs from inventory into unique pet entities
--   * Feed / play / sleep care loop with stat decay
--   * Stage advancement (Egg -> Newborn -> ... -> FullGrown)
--   * Following (max 2) and pet pen (max 4) mechanics
--   * Daily quests ("Feed your pet 3 times today")
--   * Currency rewards on stage-up + quest turn-in
--   * Pet-need notifications when stats dip below threshold
--   * Per-player save via DataStoreSafe
--   * Leaderboard for richest players
--   * Trade flow (propose -> offering -> ready -> confirming -> finalized)
--     with ownership re-validation and 60s auto-cancel timeout
--
-- Out of scope for this demo:
--   * Neon/Mega transformations (flag fields exist, no UI yet)
--   * Pet riding/flying animations (rig supports it, no game code yet)
--   * Cross-server marketplace
-- ============================================================================

-- Service requires
local Players       = game:GetService("Players")
local RunService    = game:GetService("RunService")

-- Core services
local EventBus      = require(script.Parent.src.Core.EventBus)
local Config        = require(script.Parent.src.Core.Config)
local Types         = require(script.Parent.src.Core.Types)
local StateMachine  = require(script.Parent.src.Core.StateMachine)

-- Feature modules
local Inventory          = require(script.Parent.src.Inventory)
local CurrencySystem     = require(script.Parent.src.CurrencySystem)
local XPSystem           = require(script.Parent.src.XPSystem)
local PetSystem          = require(script.Parent.src.PetSystem)
local QuestSystem        = require(script.Parent.src.QuestSystem)
local TimerSystem        = require(script.Parent.src.TimerSystem)
local NotificationSystem = require(script.Parent.src.NotificationSystem)
local LeaderboardSystem  = require(script.Parent.src.LeaderboardSystem)
local UIFramework        = require(script.Parent.src.UIFramework)
local DataStoreSafe      = require(script.Parent.src.DataStoreSafe)
local TradeSystem        = require(script.Parent.src.TradeSystem)
local PetAnimator        = require(script.Parent.src.PetAnimator)
-- Production-hardening modules. These are *optional* — the demo runs without
-- them. Wiring is gated on the `useProductionHardening` Config flag below.
local TradeCoordinator    = require(script.Parent.src.TradeCoordinator)
local ProfileStoreAdapter = require(script.Parent.src.ProfileStoreAdapter)

-- ============================================================================
-- 1. SHARED SERVICES
-- ============================================================================
-- A single EventBus + Config is shared across all modules. Modules fire
-- events into the bus; this file is what wires the reactions together.

local bus = EventBus.new()

local config = Config.new({
	-- Pet system tuning
	petMaxFollowing    = 2,        -- 2 pets out at once (Adopt Me-style)
	petMaxInPen        = 4,        -- 4-slot pet pen for AFK aging
	-- Currency
	starterBucks       = 500,
	starterGems        = 10,
	-- Production hardening (set to true in a deployed environment).
	-- When true, trades are routed through TradeCoordinator (2PC + WAL +
	-- post-commit verification) and player profiles are session-locked
	-- via ProfileStoreAdapter. When false (default), the demo uses the
	-- original direct in-memory transfer path which is still safe for a
	-- single-server demo and saves DataStore quota during local testing.
	useProductionHardening = false,
	-- Default theme for UI components
	defaultTheme = {
		primary      = Color3.fromRGB(255, 105, 180),  -- pink — fits the genre
		secondary    = Color3.fromRGB(135, 206, 250),  -- sky blue
		background   = Color3.fromRGB(30, 30, 40),
		text         = Color3.fromRGB(245, 245, 245),
		font         = Font.fromEnum(Enum.Font.GothamBold),
		cornerRadius = 12,
	} :: Types.Theme,
})

-- ============================================================================
-- 2. MODULE INSTANTIATION (Dependency Injection)
-- ============================================================================

local inv          = Inventory.new(bus, 50)
local currency     = CurrencySystem.new(bus, config)
local timers       = TimerSystem.new(bus)
local xp           = XPSystem.new(bus, config)
local pets         = PetSystem.new(bus, inv, xp, timers)
local quests       = QuestSystem.new(bus, config)
local notifs       = NotificationSystem.new(bus, config)
local store        = DataStoreSafe.new("PetGameSave_v1", { retries = 3, useCache = true })
local leaderboard  = LeaderboardSystem.new(bus, store, config)
local ui           = UIFramework.new(bus, config:Get("defaultTheme"))

-- ----------------------------------------------------------------------------
-- Optional production hardening: ProfileStoreAdapter + TradeCoordinator.
-- ----------------------------------------------------------------------------
-- These are constructed only when `useProductionHardening` is true. When
-- enabled:
--   * ProfileStoreAdapter manages session locks (delegating to community
--     ProfileStore module if present, falling back to DataStoreSafe v2
--     locks otherwise).
--   * TradeCoordinator wraps trade finalize with the 4-call UpdateAsync
--     2PC protocol from the Perplexity research — fence tokens, idempotent
--     transforms, post-commit dual-consensus verification, and crash
--     recovery on profile load.
--
-- TradeSystem accepts an optional `coordinator` dep — when nil, finalize
-- uses the original direct in-memory transfer (correct for single-server
-- demos). When provided, finalize delegates to coordinator:ExecuteTrade.
local profileAdapter: typeof(ProfileStoreAdapter.new("", bus, nil, config))? = nil
local coordinator: typeof(TradeCoordinator.new(bus, {} :: any, config))? = nil

if config:Get("useProductionHardening", false) :: boolean then
	profileAdapter = ProfileStoreAdapter.new("PetGameProfile_v1", bus, nil, config)

	-- The coordinator needs a fast WAL (MemoryStore) and a durable WAL
	-- (DataStore). We grab references to real services here; in tests
	-- they're swapped for mocks.
	local MemoryStoreService = game:GetService("MemoryStoreService")
	local DataStoreService   = game:GetService("DataStoreService")
	coordinator = TradeCoordinator.new(bus, {
		profileStore     = profileAdapter,
		pets             = pets,
		txnLogStore      = DataStoreService:GetDataStore("TradeWAL_v1"),
		txnCoordinator   = MemoryStoreService:GetSortedMap("TradeCoordinator_v1"),
		dataStoreService = DataStoreService,
	}, config)
	print("[PetGame] Production hardening enabled (TradeCoordinator + ProfileStoreAdapter active)")
end

-- TradeSystem is dependency-injected with the modules it needs to query and
-- mutate. We pass `timers` so trades auto-cancel after 60 s of inactivity
-- (`tradeTimeoutSec` config key). When production hardening is on,
-- `coordinator` routes finalize through TradeCoordinator's 2PC.
local trades       = TradeSystem.new(bus, inv, currency, timers)
-- PetAnimator subscribes to PetSystem events and drives in-world model
-- animations. The composition root is responsible for spawning the actual
-- pet Models and calling :RegisterPetModel(petId, model). PetAnimator
-- handles the rest (playback, crossfades, base-loop management, cleanup).
local animator    = PetAnimator.new(bus, config)

-- ============================================================================
-- 3. STARTER CONTENT
-- ============================================================================
-- Species, items, currencies, quests, leaderboards. In a production game
-- these would live in their own data modules — here they're inline to make
-- the demo readable in one file.

-- ----- Currencies -----------------------------------------------------------
currency:RegisterCurrency({
	id             = "bucks",
	name           = "Bucks",
	symbol         = "$",
	defaultBalance = config:Get("starterBucks", 500) :: number,
})
currency:RegisterCurrency({
	id             = "gems",
	name           = "Gems",
	symbol         = "💎",
	defaultBalance = config:Get("starterGems", 10) :: number,
})

-- ----- Inventory items ------------------------------------------------------
-- Eggs (will be consumed to hatch pets). Non-stackable so each egg is a
-- distinct slot, mirroring how Adopt Me handles unhatched eggs.
-- Note `tradeable=false` on the legendary egg — demonstrates the soul-bound
-- mechanism. Trade attempts to add this item are silently rejected.
inv:DefineItem({ id = "starter_egg",   name = "Starter Egg",    maxStack = 1, equippable = false, tradeable = true })
inv:DefineItem({ id = "egg_jungle",    name = "Jungle Egg",     maxStack = 1, equippable = false, tradeable = true })
inv:DefineItem({ id = "egg_legendary", name = "Legendary Egg",  maxStack = 1, equippable = false, tradeable = false })

-- Food / toys (stackable consumables).
inv:DefineItem({ id = "food_basic",    name = "Pet Food",       maxStack = 99, equippable = false })
inv:DefineItem({ id = "food_premium",  name = "Premium Food",   maxStack = 99, equippable = false,
	metadata = { hungerRestore = 50 } })
inv:DefineItem({ id = "toy_ball",      name = "Squeaky Ball",   maxStack = 99, equippable = false,
	metadata = { happinessRestore = 30 } })
inv:DefineItem({ id = "bed_cozy",      name = "Cozy Bed",       maxStack = 99, equippable = false,
	metadata = { energyRestore = 50 } })

-- ----- Pet species ----------------------------------------------------------
-- Three starter species across the rarity ladder. Decay rates are tuned so
-- common pets need attention every couple of minutes; legendary pets demand
-- much more upkeep but advance through stages faster (the trade-off).
pets:RegisterPet({
	id           = "fennec_fox",
	name         = "Fennec Fox",
	rarity       = "common",
	modelId      = "rbxassetid://0",
	tricks       = { "Sit", "Lay Down" },
	favoriteFoods = { "food_basic", "food_premium" },
	flyable      = false,
	rideable     = false,
})

pets:RegisterPet({
	id           = "jungle_panther",
	name         = "Jungle Panther",
	rarity       = "rare",
	modelId      = "rbxassetid://0",
	tricks       = { "Sit", "Lay Down", "Roll Over" },
	favoriteFoods = { "food_premium", "food_basic" },
	flyable      = false,
	rideable     = false,
})

pets:RegisterPet({
	id           = "shadow_dragon_pg",
	name         = "Shadow Dragon",
	rarity       = "legendary",
	modelId      = "rbxassetid://0",
	tricks       = { "Sit", "Lay Down", "Roll Over", "Dance", "Backflip" },
	favoriteFoods = { "food_premium" },
	flyable      = true,
	rideable     = true,
})

-- ----- Daily quests ---------------------------------------------------------
quests:RegisterQuest({
	id          = "daily_feed",
	title       = "Hungry Hungry Pets",
	description = "Feed any of your pets three times today.",
	objectives  = {
		{ id = "feed", description = "Feed pets", targetCount = 3, currentCount = 0, completed = false },
	},
	rewards = {
		{ type = "currency", id = "bucks", amount = 100 },
	},
})

quests:RegisterQuest({
	id          = "daily_play",
	title       = "Playtime",
	description = "Play with your pets twice today.",
	objectives  = {
		{ id = "play", description = "Play with pets", targetCount = 2, currentCount = 0, completed = false },
	},
	rewards = {
		{ type = "currency", id = "bucks", amount = 75 },
	},
})

quests:RegisterQuest({
	id          = "daily_sleep",
	title       = "Sweet Dreams",
	description = "Put a pet to sleep at least once today.",
	objectives  = {
		{ id = "sleep", description = "Pets put to sleep", targetCount = 1, currentCount = 0, completed = false },
	},
	rewards = {
		{ type = "currency", id = "bucks", amount = 50 },
	},
})

-- ----- Leaderboards ---------------------------------------------------------
leaderboard:RegisterBoard({
	name       = "richest",
	maxEntries = 100,
	sortOrder  = "desc",
})

leaderboard:RegisterBoard({
	name       = "oldest_pet",
	maxEntries = 100,
	sortOrder  = "desc",  -- highest age in seconds wins
})

-- ============================================================================
-- 4. CROSS-MODULE EVENT WIRING
-- ============================================================================
-- This is where the magic happens. Modules emit events; we react. Adding a
-- new behaviour (e.g. play a sound when a pet ages up) is a single Subscribe
-- call here — no module needs to be modified.

-- ----- PetSystem ↔ Notifications --------------------------------------------
bus:Subscribe("PetHatched", function(data)
	notifs:Show(
		"success",
		"It hatched!",
		string.format("Your %s '%s' is here!", data.defId, data.nickname),
		4
	)
end)

bus:Subscribe("PetStageAdvanced", function(data)
	notifs:Show(
		"info",
		"Pet grew up!",
		string.format("'%s' became a %s", data.petId, data.toStage),
		4
	)
	-- Reward currency on stage-up — keeps care loop satisfying.
	-- We don't know the owner from the event alone; look it up.
	local pet = pets:GetPet(data.petId)
	if pet then
		currency:Add("bucks", 25, "stage_advance")
	end
end)

bus:Subscribe("PetNeedsAttention", function(data)
	-- Throttled by PetSystem itself (60s repeat lockout).
	notifs:Show(
		"warning",
		"Your pet needs you!",
		string.format("Pet %s is low on %s (%.0f)", data.petId, data.need, data.statValue),
		3
	)
end)

-- ----- PetSystem ↔ QuestSystem ----------------------------------------------
-- Care actions advance daily quest objectives. Subscribing here means
-- QuestSystem doesn't have to know what PetSystem is.
bus:Subscribe("PetCared", function(data)
	if data.action == "feed" then
		quests:AdvanceObjective("daily_feed", "feed", 1)
	elseif data.action == "play" then
		quests:AdvanceObjective("daily_play", "play", 1)
	elseif data.action == "sleep" then
		quests:AdvanceObjective("daily_sleep", "sleep", 1)
	end
end)

-- ----- QuestSystem ↔ CurrencySystem -----------------------------------------
-- Rewards from completed quests get turned into actual currency increments.
-- The composition root is the only place that knows quest rewards map onto
-- currency — keeps QuestSystem agnostic of payment.
bus:Subscribe("QuestRewardsGranted", function(data)
	for _, reward in ipairs(data.rewards) do
		if reward.type == "currency" then
			currency:Add(reward.id, reward.amount, "quest:" .. data.questId)
		elseif reward.type == "item" then
			inv:AddItem(reward.id, reward.amount)
		end
		-- "xp" rewards would route to an XPSystem if we wired one in.
	end
end)

-- Auto-turn-in completed quests so the demo doesn't need a quest-board NPC.
bus:Subscribe("QuestCompleted", function(data)
	notifs:Show("success", "Quest complete!", "Tap your quest log to claim rewards.", 4)
	-- Real game: wait for player to click "Turn In" button. For demo, auto:
	task.delay(0.5, function()
		quests:TurnInQuest(data.questId)
	end)
end)

-- ----- Currency ↔ Leaderboard -----------------------------------------------
-- Push richest-player updates whenever bucks balance changes. We debounce by
-- only checking once a second to avoid hammering the leaderboard.
local lastLeaderboardPush = 0
bus:Subscribe("CurrencyBalanceChanged", function(data)
	if data.currencyId ~= "bucks" then return end
	local now = os.clock()
	if now - lastLeaderboardPush < 1.0 then return end
	lastLeaderboardPush = now
	-- Leaderboard ids are per-player in production; this demo is single-player.
	leaderboard:SubmitScore("richest", "demo_player", "Demo", data.newBalance)
end)

-- ----- Following / Pen state changes ----------------------------------------
-- Real game: spawn/despawn pet models in the world here.
bus:Subscribe("PetFollowingChanged", function(data)
	print(("[PetGame] Player %d now has %d pet(s) following")
		:format(data.ownerId, #data.followingPetIds))
end)

bus:Subscribe("PetPenChanged", function(data)
	print(("[PetGame] Player %d pen contains %d pet(s)")
		:format(data.ownerId, #data.penPetIds))
end)

-- ----- Trade lifecycle -------------------------------------------------------
-- These mirror the social-loop notifications a real pet game shows. The
-- TradeSystem itself never touches UI — it just emits events; this block
-- is the only place that knows trades and notifications go together.
bus:Subscribe("TradeProposed", function(data)
	notifs:Show("info", "Trade Proposal", string.format("Player %d wants to trade with you!", data.fromUid), 5)
end)

bus:Subscribe("TradeOfferLocked", function(data)
	notifs:Show("info", "Both Ready", "Review the offer carefully, then confirm to finalize.", 4)
end)

bus:Subscribe("TradeFinalized", function(data)
	notifs:Show("success", "Trade Complete!",
		string.format("%d pet(s) and %d item kind(s) changed hands.",
			#data.transfers.a.pets + #data.transfers.b.pets,
			(function()
				local n = 0
				for _ in pairs(data.transfers.a.items) do n += 1 end
				for _ in pairs(data.transfers.b.items) do n += 1 end
				return n
			end)()), 5)
end)

bus:Subscribe("TradeCancelled", function(data)
	local reason = data.reason == "timeout" and "timed out" or "was cancelled"
	notifs:Show("warning", "Trade " .. reason, "No items changed hands.", 4)
end)

-- ============================================================================
-- 5. SAVE / LOAD HELPERS
-- ============================================================================
-- A small wrapper that reads/writes the per-player snapshot. We pack
-- everything we want to persist into a single table.

type PlayerSave = {
	currency: { bucks: number, gems: number },
	inventory: { Types.Slot },
	pets: { Types.PetEntity },
	completedQuests: { string },
	savedAt: number,
}

local function saveKeyFor(userId: number): string
	return "p_" .. tostring(userId)
end

local function savePlayer(player: Player)
	local data: PlayerSave = {
		currency = {
			bucks = currency:GetBalance("bucks"),
			gems  = currency:GetBalance("gems"),
		},
		inventory       = inv:GetAllSlots(),
		pets            = pets:Serialize(player.UserId),
		completedQuests = quests:GetCompletedQuests(),
		savedAt         = os.time(),
	}
	store:Save(saveKeyFor(player.UserId), data :: any)
end

local function loadPlayer(player: Player)
	local raw = store:Load(saveKeyFor(player.UserId))
	if not raw then
		return false
	end
	local data = raw :: PlayerSave

	-- Restore currencies (we just overwrite the default balances).
	if data.currency then
		local diffBucks = (data.currency.bucks or 0) - currency:GetBalance("bucks")
		local diffGems  = (data.currency.gems  or 0) - currency:GetBalance("gems")
		if diffBucks ~= 0 then
			if diffBucks > 0 then currency:Add("bucks", diffBucks, "load")
			else currency:Subtract("bucks", -diffBucks, "load") end
		end
		if diffGems ~= 0 then
			if diffGems > 0 then currency:Add("gems", diffGems, "load")
			else currency:Subtract("gems", -diffGems, "load") end
		end
	end

	-- Restore inventory slot-by-slot.
	if data.inventory then
		for _, slot in ipairs(data.inventory) do
			inv:AddItem(slot.itemId, slot.quantity)
		end
	end

	-- Restore pets. Species must already be registered (they are, at startup).
	if data.pets then
		pets:Deserialize(data.pets)
	end

	return true
end

-- ============================================================================
-- 6. PLAYER SETUP
-- ============================================================================

local function setupPlayer(player: Player)
	print(("[PetGame] Setting up player %s (%d)"):format(player.Name, player.UserId))

	-- 6a. Try to load existing save.
	local loaded = loadPlayer(player)

	-- 6b. New players get a starter package.
	if not loaded then
		inv:AddItem("starter_egg", 1)
		inv:AddItem("food_basic", 5)
		inv:AddItem("toy_ball", 2)
		inv:AddItem("bed_cozy", 1)
		notifs:Show(
			"info",
			"Welcome!",
			"You got a Starter Egg, food, a toy, and a bed. Tap your inventory to hatch!",
			6
		)
	else
		notifs:Show("info", "Welcome back!", "Your pets missed you. 🐾", 4)
	end

	-- 6c. Activate today's daily quests if not already done.
	for _, questId in ipairs({ "daily_feed", "daily_play", "daily_sleep" }) do
		if quests:IsQuestAvailable(questId) then
			quests:AcceptQuest(questId)
		end
	end

	-- 6d. Auto-save every 60 seconds.
	task.spawn(function()
		while player.Parent do
			task.wait(60)
			savePlayer(player)
		end
	end)

	-- 6e. Save on leave.
	player.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			savePlayer(player)
		end
	end)
end

-- ============================================================================
-- 7. PUBLIC API
-- ============================================================================
-- Returned table lets test scripts and Studio commands poke the game state.

export type PetGameAPI = {
	Bus:          typeof(bus),
	Config:       typeof(config),
	Inventory:    typeof(inv),
	Currency:     typeof(currency),
	Pets:         typeof(pets),
	Quests:       typeof(quests),
	Notifications: typeof(notifs),
	Timers:       typeof(timers),
	Leaderboard:  typeof(leaderboard),
	UI:           typeof(ui),
	Store:        typeof(store),
	Trades:       typeof(trades),
	Animator:     typeof(animator),
	Coordinator:  typeof(coordinator),     -- nil unless useProductionHardening
	ProfileStore: typeof(profileAdapter), -- nil unless useProductionHardening
	SetupPlayer:  (player: Player) -> (),
	SavePlayer:   (player: Player) -> (),
}

local api: PetGameAPI = {
	Bus           = bus,
	Config        = config,
	Inventory     = inv,
	Currency      = currency,
	Pets          = pets,
	Quests        = quests,
	Notifications = notifs,
	Timers        = timers,
	Leaderboard   = leaderboard,
	UI            = ui,
	Store         = store,
	Trades        = trades,
	Animator      = animator,
	Coordinator   = coordinator,
	ProfileStore  = profileAdapter,
	SetupPlayer   = setupPlayer,
	SavePlayer    = savePlayer,
}

-- Auto-wire PlayerAdded if running in a real Roblox environment.
if RunService:IsRunning() and Players then
	Players.PlayerAdded:Connect(setupPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		setupPlayer(p)
	end
end

return api
