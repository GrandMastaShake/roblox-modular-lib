--!strict
-- ExampleGame.lua
-- Comprehensive integration demo showing the full roblox-modular-lib wired together
-- via Dependency Injection (DI). No module imports another module directly; all
-- cross-module communication flows through the shared EventBus.
--
-- Architecture in one line:
--   1. Create shared services (EventBus, Config).
--   2. Instantiate every feature module, injecting those services.
--   3. Subscribe to events so modules react to each other without hard coupling.
--   4. Run a lightweight game loop or player-setup sequence.

-- =============================================================================
-- REQUIRE PATHS
-- =============================================================================
-- Core services (shared infrastructure)
local EventBus = require(script.Parent.src.Core.EventBus)
local Config   = require(script.Parent.src.Core.Config)
local Types    = require(script.Parent.src.Core.Types)   -- type aliases only; returns nil
local StateMachine = require(script.Parent.src.Core.StateMachine)

-- Feature modules (all depend on Core via DI; never on each other)
local XPSystem      = require(script.Parent.src.XPSystem)
local Inventory     = require(script.Parent.src.Inventory)
local Skills        = require(script.Parent.src.Skills)
local Physics       = require(script.Parent.src.Physics)
local UIFramework   = require(script.Parent.src.UIFramework)
local DataStoreSafe = require(script.Parent.src.DataStoreSafe)

-- =============================================================================
-- SHARED SERVICE SETUP (The "wiring harness")
-- =============================================================================

-- EventBus: the central nervous system. Every module gets the SAME bus so they
-- can talk to each other by event name rather than by direct reference.
local bus = EventBus.new()

-- Config: global tuning values. Modules read keys they care about via :Get().
-- This keeps magic numbers out of module internals.
local config = Config.new({
	xpFormula = function(lvl: number): number
		return math.floor(100 * lvl ^ 1.5)
	end,
	maxInventorySlots = 20,
	projectileSpeed = 60,
	knockbackForce = 500,
	defaultTheme = {
		primary      = Color3.fromRGB(0, 170, 255),
		secondary    = Color3.fromRGB(255, 85, 0),
		background   = Color3.fromRGB(30, 30, 30),
		text         = Color3.fromRGB(240, 240, 240),
		font         = Enum.Font.GothamBold,
		cornerRadius = 8,
	} :: Types.Theme,
})

-- =============================================================================
-- MODULE INSTANTIATION (Dependency Injection)
-- =============================================================================
-- Each module receives only the shared services it needs. This satisfies the
-- "zero hard coupling" rule: you can swap out any module or mock the bus/config
-- in tests without touching internal code.

local xp      = XPSystem.new(bus, config)
local inv     = Inventory.new(bus, config:Get("maxInventorySlots", 20))
local skills  = Skills.new(bus)
local physics = Physics.new(bus)
local ui      = UIFramework.new(bus, config:Get("defaultTheme"))
local store   = DataStoreSafe.new("PlayerData", { retries = 3, useCache = true })

-- =============================================================================
-- CROSS-MODULE EVENT WIRING (Where the magic happens)
-- =============================================================================
-- Because modules emit events and never call each other directly, we wire
-- reactions HERE in the composition root. This is the only file that knows
-- about ALL modules, making the system easy to refactor.

-- ---------------------------------------------------------------------------
-- XP → UI integration
-- ---------------------------------------------------------------------------
-- When XP is added, the XP module emits "XPAdded". We forward that to the UI
-- so the progress bar tweens. On "LevelUp" we flash a celebratory message.
bus:Subscribe("XPAdded", function(data)
	-- data carries { currentXP, amount, progress }
	print(string.format("[XP] Gained %d XP (total %d, progress %.0f%%)",
		data.amount, data.currentXP, data.progress * 100))
end)

bus:Subscribe("LevelUp", function(data)
	print(string.format("[XP] LEVEL UP! Reached level %d", data.level))
	-- UI celebration: create a temporary banner
	local banner = ui:CreateBar(game.StarterGui, UDim2.new(0, 300, 0, 50), Color3.fromRGB(255, 215, 0))
	banner.Position = UDim2.new(0.5, -150, 0, 50)
	ui:Tween(banner, { BackgroundTransparency = 1 }, 2)
end)

bus:Subscribe("XPBarUpdated", function(data)
	-- XPSystem already pushes progress to the bar it was given via SetXPBar.
	-- If we wanted extra UI reactions (e.g. sound), we could do that here.
end)

-- ---------------------------------------------------------------------------
-- Skills → Physics integration
-- ---------------------------------------------------------------------------
-- When a skill cast succeeds, we inspect the skillId. If it's a projectile
-- skill (e.g. "Fireball"), we ask the Physics module to launch a projectile
-- from the caster's character.
bus:Subscribe("CastSucceeded", function(data)
	print(string.format("[Skills] Cast succeeded: %s", data.skillId))

	if data.skillId == "Fireball" then
		local player = game.Players.LocalPlayer
		if not player or not player.Character then
			return
		end
		local hrp = player.Character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			return
		end
		local origin = (hrp :: BasePart).Position
		local direction = (hrp :: BasePart).CFrame.LookVector
		local speed = config:Get("projectileSpeed", 60)

		local projectile = physics:LaunchProjectile(origin, direction, speed, function(hit: BasePart)
			print(string.format("[Physics] Fireball hit %s", hit.Name))
			-- Knockback the hit part if it's a character
			local humanoid = hit.Parent and (hit.Parent :: Instance):FindFirstChildOfClass("Humanoid")
			if humanoid then
				local knockDir = (hit.Position - origin).Unit
				physics:Knockback(hit, knockDir, config:Get("knockbackForce", 500), 0.3)
			end
		end)
		print(string.format("[Physics] Launched Fireball projectile (%s)", projectile.Name))
	end
end)

bus:Subscribe("CastStarted", function(data)
	print(string.format("[Skills] Cast started: %s (%.1fs)", data.skillId, data.duration))
end)

bus:Subscribe("CastFailed", function(data)
	warn(string.format("[Skills] Cast failed: %s | Reason: %s", data.skillId, data.reason))
end)

bus:Subscribe("CooldownStarted", function(data)
	print(string.format("[Skills] Cooldown started: %s (%.1fs)", data.skillId, data.remaining))
end)

bus:Subscribe("CooldownEnded", function(data)
	print(string.format("[Skills] Cooldown ended: %s", data.skillId))
end)

-- ---------------------------------------------------------------------------
-- Inventory → UI integration
-- ---------------------------------------------------------------------------
-- When items are added, removed, or equipped, the UI layer updates slot icons.
-- We also emit a warning if the inventory is full.
bus:Subscribe("ItemAdded", function(data)
	print(string.format("[Inventory] Added %dx %s to slot %d", data.quantity, data.itemId, data.slotIndex))
end)

bus:Subscribe("ItemRemoved", function(data)
	print(string.format("[Inventory] Removed %dx %s from slot %d", data.quantity, data.itemId, data.slotIndex))
end)

bus:Subscribe("ItemEquipped", function(data)
	print(string.format("[Inventory] Equipped %s (slot %d)", data.itemId, data.slotIndex))
	-- UI feedback: briefly tint the equipped slot border
	-- (In a real game you'd reference the actual GUI slot frame.)
end)

bus:Subscribe("InventoryFull", function(_data)
	warn("[Inventory] Inventory is full! Cannot add more items.")
end)

-- ---------------------------------------------------------------------------
-- Physics event logging
-- ---------------------------------------------------------------------------
bus:Subscribe("ProjectileLaunched", function(data)
	print(string.format("[Physics] Projectile launched from %s", tostring(data.origin)))
end)

bus:Subscribe("ProjectileHit", function(data)
	print(string.format("[Physics] Projectile hit %s", data.hit.Name))
end)

bus:Subscribe("KnockbackApplied", function(data)
	print(string.format("[Physics] Knockback applied to %s", data.target.Name))
end)

-- =============================================================================
-- GAME STATE MACHINE (Demonstrates Core/StateMachine usage)
-- =============================================================================
-- A simple FSM for the player's in-game state. Modules don't know about it;
-- it's purely orchestration in this composition root.

local gameState = StateMachine.new({
	Lobby = {
		Enter = function(from: string)
			print("[State] Entered Lobby (from " .. from .. ")")
		end,
		Update = function(_dt: number)
			-- Lobby tick logic
		end,
		Leave = function(to: string)
			print("[State] Leaving Lobby -> " .. to)
		end,
	},
	Playing = {
		Enter = function(from: string)
			print("[State] Entered Playing (from " .. from .. ")")
		end,
		Update = function(dt: number)
			-- In a real game you'd tick skills, physics, etc. here.
			-- For the demo we just print a heartbeat every few seconds.
		end,
		Leave = function(to: string)
			print("[State] Leaving Playing -> " .. to)
		end,
	},
	Paused = {
		Enter = function(_from: string)
			print("[State] Paused")
		end,
		Update = function(_dt: number) end,
		Leave = function(to: string)
			print("[State] Resuming -> " .. to)
		end,
	},
}, "Lobby")

-- =============================================================================
-- PLAYER SETUP DEMO (What happens when a player joins)
-- =============================================================================

local function setupPlayer(player: Player)
	print(string.format("[Game] Setting up player %s", player.Name))

	-- 1. Define items so Inventory knows what they are.
	inv:DefineItem({
		id = "IronSword",
		name = "Iron Sword",
		maxStack = 1,
		equippable = true,
		metadata = { damage = 15 },
	})
	inv:DefineItem({
		id = "HealthPotion",
		name = "Health Potion",
		maxStack = 99,
		equippable = false,
		metadata = { healAmount = 25 },
	})
	inv:DefineItem({
		id = "ManaPotion",
		name = "Mana Potion",
		maxStack = 99,
		equippable = false,
		metadata = { restoreAmount = 30 },
	})

	-- 2. Register skills.
	skills:RegisterSkill({
		id = "Fireball",
		name = "Fireball",
		cooldown = 3,
		castTime = 0.5,
		effect = function(_target: any)
			print("[Skills] Fireball effect resolved")
		end,
	})
	skills:RegisterSkill({
		id = "Heal",
		name = "Heal",
		cooldown = 5,
		castTime = 0.2,
		effect = function(_target: any)
			print("[Skills] Heal effect resolved")
		end,
	})

	-- 3. Seed inventory with starter items.
	inv:AddItem("IronSword", 1)
	inv:AddItem("HealthPotion", 5)
	inv:AddItem("ManaPotion", 3)

	-- 4. Give starter XP (triggers LevelUp if threshold crossed).
	xp:AddXP(150)

	-- 5. DataStore: attempt async load so we can merge saved data later.
	task.spawn(function()
		local saved = store:Load(player.UserId .. "_profile")
		if saved then
			print(string.format("[DataStore] Loaded saved data for %s", player.Name))
			-- In a full implementation you'd restore xp, inventory, etc. from saved.
		else
			print(string.format("[DataStore] No prior save for %s", player.Name))
		end
	end)

	-- 6. Transition game state to Playing once the character spawns.
	player.CharacterAdded:Connect(function(_char)
		gameState:Transition("Playing")
	end)
end

-- =============================================================================
-- GAME LOOP (Heartbeat demonstration)
-- =============================================================================

local RunService = game:GetService("RunService")
local lastTick = tick()

RunService.Heartbeat:Connect(function()
	local now = tick()
	local dt = now - lastTick
	lastTick = now

	-- Tick the state machine so states with Update() callbacks run.
	gameState:Update(dt)

	-- Tick physics internal helpers (projectile raycasts, force decay, etc.).
	-- The Physics module registers its own Heartbeat in production; we just
	-- show that the composition root CAN drive it if desired.
end)

-- =============================================================================
-- PUBLIC API — The "game" object returned to the entry script
-- =============================================================================
-- This table exposes just enough surface area for a ServerScript or
-- LocalScript to start the experience. Everything underneath stays
-- encapsulated behind the DI boundary.

export type ExampleGame = {
	Bus: typeof(bus),
	Config: typeof(config),
	XP: typeof(xp),
	Inventory: typeof(inv),
	Skills: typeof(skills),
	Physics: typeof(physics),
	UI: typeof(ui),
	Store: typeof(store),
	State: typeof(gameState),
	SetupPlayer: (player: Player) -> (),
}

local gameAPI: ExampleGame = {
	Bus       = bus,
	Config    = config,
	XP        = xp,
	Inventory = inv,
	Skills    = skills,
	Physics   = physics,
	UI        = ui,
	Store     = store,
	State     = gameState,
	SetupPlayer = setupPlayer,
}

-- If running in a real Roblox environment, auto-wire PlayerAdded.
if game and game.Players then
	game.Players.PlayerAdded:Connect(setupPlayer)
	-- Also set up any players already in-game (studio play solo edge case).
	for _, plr in ipairs(game.Players:GetPlayers()) do
		setupPlayer(plr)
	end
end

return gameAPI
