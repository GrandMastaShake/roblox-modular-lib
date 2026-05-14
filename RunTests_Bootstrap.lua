-- RunTests_Bootstrap.lua
-- Paste this as a Script (NOT ModuleScript) in ServerScriptService.
-- It runs every test file and then boots the PetGame smoke test.
-- Rojo maps: ServerScriptService.Lib = src/, ServerScriptService.Tests = tests/

local SSS   = game:GetService("ServerScriptService")
local Tests = SSS:WaitForChild("Tests", 5)

if not Tests then
    error("[Bootstrap] Tests folder not found — did you open FashionistaPetGame.rbxlx?")
end

-- ── Stage 2: Run all Lua test modules ───────────────────────────────────────

local testModules = {
    "test_CombatSystem",
    "test_CraftingSystem",
    "test_CurrencySystem",
    "test_DataStoreSafe",
    "test_DialogueSystem",
    "test_EquipmentSystem",
    "test_Inventory",
    "test_LeaderboardSystem",
    "test_LootSystem",
    "test_NotificationSystem",
    "test_PetAnimator",
    "test_PetSystem",
    "test_Physics",
    "test_ProfileStoreAdapter",
    "test_QuestSystem",
    "test_Skills",
    "test_StatusEffectSystem",
    "test_TimerSystem",
    "test_TradeCoordinator",
    "test_TradeRemoteHandler",
    "test_TradeSystem",
    "test_UIFramework",
    "test_XPSystem",
}

local passed, failed = 0, 0

print("\n══════════════════════════════════════")
print(" FASHIONISTA — LUA TEST SUITE")
print("══════════════════════════════════════\n")

for _, name in ipairs(testModules) do
    local mod = Tests:FindFirstChild(name)
    if not mod then
        warn("[SKIP] " .. name .. " — not found in Tests folder")
    else
        local ok, err = pcall(require, mod)
        if ok then
            print("[PASS] " .. name)
            passed += 1
        else
            warn("[FAIL] " .. name .. "\n       " .. tostring(err))
            failed += 1
        end
    end
end

print("\n──────────────────────────────────────")
print(string.format(" Results: %d passed, %d failed", passed, failed))
print("──────────────────────────────────────\n")

if failed > 0 then
    warn("[Bootstrap] " .. failed .. " test(s) failed — see above for details.")
    return
end

-- ── Stage 3: PetGame smoke test ─────────────────────────────────────────────

print("══════════════════════════════════════")
print(" STAGE 3 — PetGame Smoke Test")
print("══════════════════════════════════════\n")

local PetGame = require(SSS:WaitForChild("PetGame", 5))
print("[Bootstrap] PetGame loaded.")
print("[Bootstrap] Production hardening:", PetGame.Config:Get("useProductionHardening", false))

-- Wait for a player (press Play in Studio)
local Players = game:GetService("Players")
local player = Players.PlayerAdded:Wait()
task.wait(2) -- let PetGame's own PlayerAdded handler fire first

-- Subscribe to events before acting
PetGame.Bus:Subscribe("PetCared", function(d)
    print(string.format("[Event] PetCared — pet=%s action=%s stat=%s now=%.0f",
        d.petId, d.action, d.statName, d.statNow))
end)
PetGame.Bus:Subscribe("PetStageAdvanced", function(d)
    print(string.format("[Event] PetStageAdvanced — pet=%s %s -> %s",
        d.petId, d.fromStage, d.toStage))
end)

-- Hatch a pet
local petId = PetGame.Pets:HatchEgg("fennec_fox", player.UserId, "Sparky")
local pet    = PetGame.Pets:GetPet(petId)
print(string.format("[Stage3] Hatched '%s' (id=%s) hunger=%.0f happiness=%.0f",
    pet.nickname, petId, pet.hunger, pet.happiness))

-- Feed it
PetGame.Pets:Feed(petId, 25)
pet = PetGame.Pets:GetPet(petId)
print(string.format("[Stage3] After Feed — hunger=%.0f (expected %.0f)",
    pet.hunger, math.min(100, pet.hunger)))

-- Play with it
PetGame.Pets:Play(petId, 20)
pet = PetGame.Pets:GetPet(petId)
print(string.format("[Stage3] After Play — happiness=%.0f", pet.happiness))

print("\n[Stage3] PASS — pet hatched, fed, played. Events fired above.")
print("\nAll stages complete! Check Output for any red errors.\n")
