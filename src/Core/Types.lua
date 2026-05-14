--!strict
-- Core/Types.lua
-- Shared type aliases for the modular library.

export type ItemDef = {
	id: string,
	name: string,
	maxStack: number,
	equippable: boolean,
	-- Whether this item can be transferred via TradeSystem.
	-- Optional for backward compatibility; nil is treated as TRUE (tradeable).
	-- Set to false for soul-bound items (quest items, lifetime rewards, etc.)
	tradeable: boolean?,
	metadata: { [string]: any }?,
}

export type SkillDef = {
	id: string,
	name: string,
	cooldown: number,
	castTime: number,
	effect: (target: any) -> (),
}

export type XPProfile = {
	currentXP: number,
	level: number,
	xpToNext: number,
	formula: (level: number) -> number,
}

export type Theme = {
	primary: Color3,
	secondary: Color3,
	background: Color3,
	text: Color3,
	font: Font,
	cornerRadius: number,
}

export type Slot = { itemId: string, quantity: number, equipped: boolean }

export type SaveData = { [string]: any }

-- =============================================================================
-- Pet types — used by PetSystem.
-- =============================================================================
-- Six lifecycle stages matching Adopt Me convention:
-- Egg -> Newborn -> Junior -> PreTeen -> Teen -> PostTeen -> FullGrown
--
-- Stored as a string union so a saved pet entity is plain JSON-friendly data
-- and survives DataStore round-trips without extra serialization logic.
export type PetStage = "Egg" | "Newborn" | "Junior" | "PreTeen" | "Teen" | "PostTeen" | "FullGrown"

-- Rarity tiers determine how long a pet takes to age up and which grow-tasks
-- (feed/play/sleep counts) it requires per stage. Common pets grow fastest;
-- legendary pets are a long-term investment.
export type PetRarity = "common" | "uncommon" | "rare" | "ultraRare" | "legendary"

-- Care-task counters tracked per stage. A pet only advances when ALL three
-- thresholds for its current stage are met (and the elapsed-time gate clears).
-- Mirrors the Adopt Me daily-task model.
export type PetGrowTasks = {
	feedCount: number,
	playCount: number,
	sleepCount: number,
}

-- Static species definition — registered once at startup, never mutated.
-- Multiple PetEntity instances can share the same PetDef.
export type PetDef = {
	id: string,                    -- species id, e.g. "fennec_fox"
	displayName: string,
	rarity: PetRarity,
	-- Asset ids per stage (Egg uses the egg model, others use pet meshes).
	-- Optional per-stage; a single mesh that scales is also valid.
	meshAssetIds: { [string]: string }?,
	iconAssetId: string?,
	-- Care-stat decay rates (units per second). Tuned per species.
	hungerDecayPerSec: number,
	happinessDecayPerSec: number,
	energyDecayPerSec: number,
	-- Per-stage requirements: { [stageName] = { feedCount, playCount, sleepCount } }
	growTasks: { [string]: PetGrowTasks },
	-- Minimum elapsed seconds in each stage before advancement is allowed,
	-- regardless of task completion. Lets owners enjoy each stage.
	minStageDurationSec: { [string]: number },
}

-- A unique pet instance owned by a player. Persists across sessions.
-- All fields are JSON-serializable so the whole struct can be written to
-- DataStoreSafe without custom (de)serialization.
export type PetEntity = {
	id: string,                    -- unique uuid per pet
	defId: string,                 -- references PetDef.id
	ownerId: number,               -- player UserId
	nickname: string,
	stage: PetStage,
	bornAt: number,                -- os.time() of hatch
	ageSeconds: number,            -- accumulated live time
	hunger: number,                -- 0..100, 100 = full
	happiness: number,             -- 0..100
	energy: number,                -- 0..100
	-- Progress toward next-stage advancement.
	progress: PetGrowTasks,
	-- State flags
	isNeon: boolean,
	isMega: boolean,
	-- Location flags — at most ONE should be true at a time.
	isFollowing: boolean,          -- one of player's "out" pets (max 2)
	inPen: boolean,                -- in the AFK-aging pet pen (max 4)
	-- Custom data slot for future features (accessories, traits, etc.)
	metadata: { [string]: any }?,
}

return nil
