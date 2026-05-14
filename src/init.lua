--!strict
--[[
    roblox-modular-lib v1.3.0
    Central re-export module — 49 modules organized by category

    Categories:
    - Core        (4)   : EventBus, Types, Config, StateMachine
    - Mechanics   (15)  : XP, Inventory, Crafting, Currency, Combat, Quest,
                          Dialogue, Skills, Equipment, StatusEffects, Loot,
                          Leaderboard, Timer, Notifications, UI
    - Social      (6)   : PetSystem, PetAnimator, TradeSystem, TradeCoordinator,
                          TradeRemoteHandler, ProfileStoreAdapter
    - Domain      (2)   : HomeSystem, VehicleSystem
    - Terrain     (10)  : NoiseLib, TerrainGenerator, BiomeSystem, ChunkManager,
                          WorldBuilder, WaterSystem, ErosionSimulator, CaveSystem,
                          AtmosphereSystem, ObjectPlacer
    - Data        (2)   : DataStoreSafe, Physics
    - Extensions  (4)   : SaveSystem, PathfindingSystem, WeatherSystem, AudioSystem
    - Visual      (5)   : ColorPaletteSystem, LowPolyGenerator, StylePresets,
                          EnvironmentBuilder, LODSystem
--]]

local modularLib = {

    ---------------------------------------------------------------------------
    -- Core Infrastructure (4 modules)
    ---------------------------------------------------------------------------
    Core = {
        EventBus     = require(script.Core.EventBus),
        Types        = require(script.Core.Types),
        Config       = require(script.Core.Config),
        StateMachine = require(script.Core.StateMachine),
    },

    ---------------------------------------------------------------------------
    -- Game Mechanics (15 modules)
    ---------------------------------------------------------------------------
    -- Progression & Economy
    XPSystem       = require(script.XPSystem),
    Skills         = require(script.Skills),
    Inventory      = require(script.Inventory),
    CurrencySystem = require(script.CurrencySystem),

    -- Combat & Effects
    CombatSystem       = require(script.CombatSystem),
    StatusEffectSystem = require(script.StatusEffectSystem),
    LootSystem         = require(script.LootSystem),
    EquipmentSystem    = require(script.EquipmentSystem),

    -- Quests & Dialogue
    QuestSystem    = require(script.QuestSystem),
    DialogueSystem = require(script.DialogueSystem),

    -- Social & Display
    LeaderboardSystem  = require(script.LeaderboardSystem),
    NotificationSystem = require(script.NotificationSystem),
    UIFramework        = require(script.UIFramework),

    -- Utilities
    TimerSystem    = require(script.TimerSystem),
    CraftingSystem = require(script.CraftingSystem),

    ---------------------------------------------------------------------------
    -- Social & Pet Systems (6 modules)
    ---------------------------------------------------------------------------
    PetSystem            = require(script.PetSystem),
    PetAnimator          = require(script.PetAnimator),
    TradeSystem          = require(script.TradeSystem),
    TradeCoordinator     = require(script.TradeCoordinator),
    TradeRemoteHandler   = require(script.TradeRemoteHandler),
    ProfileStoreAdapter  = require(script.ProfileStoreAdapter),

    ---------------------------------------------------------------------------
    -- Terrain Generation (10 modules)
    ---------------------------------------------------------------------------
    -- Noise & Generation
    NoiseLib         = require(script.NoiseLib),
    TerrainGenerator = require(script.TerrainGenerator),
    WorldBuilder     = require(script.WorldBuilder),

    -- Biome & Atmosphere
    BiomeSystem      = require(script.BiomeSystem),
    AtmosphereSystem = require(script.AtmosphereSystem),
    WaterSystem      = require(script.WaterSystem),

    -- Chunk & Object Management
    ChunkManager = require(script.ChunkManager),
    ObjectPlacer = require(script.ObjectPlacer),

    -- Terrain Features
    ErosionSimulator = require(script.ErosionSimulator),
    CaveSystem       = require(script.CaveSystem),

    ---------------------------------------------------------------------------
    -- Visual / Low-Poly Pipeline (5 modules)
    ---------------------------------------------------------------------------
    ColorPaletteSystem = require(script.ColorPaletteSystem),
    LowPolyGenerator   = require(script.LowPolyGenerator),
    StylePresets       = require(script.StylePresets),
    EnvironmentBuilder = require(script.EnvironmentBuilder),
    LODSystem          = require(script.LODSystem),

    ---------------------------------------------------------------------------
    -- Adopt Me Domain Systems (2 modules)
    ---------------------------------------------------------------------------
    HomeSystem    = require(script.HomeSystem),
    VehicleSystem = require(script.VehicleSystem),

    ---------------------------------------------------------------------------
    -- Data & Physics (2 modules)
    ---------------------------------------------------------------------------
    DataStoreSafe = require(script.DataStoreSafe),
    Physics       = require(script.Physics),

    ---------------------------------------------------------------------------
    -- Extension Systems (4 modules)
    ---------------------------------------------------------------------------
    SaveSystem        = require(script.SaveSystem),
    PathfindingSystem = require(script.PathfindingSystem),
    WeatherSystem     = require(script.WeatherSystem),
    AudioSystem       = require(script.AudioSystem),
}

return modularLib
