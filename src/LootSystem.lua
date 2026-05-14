--!strict
-- LootSystem.lua
-- Drop tables with weighted random selection and rarity tiers.

local LootSystem = {}
LootSystem.__index = LootSystem

export type RarityTier = {
	id: string,
	name: string,
	color: Color3,
	weight: number,
}

export type LootEntry = {
	itemId: string,
	quantity: number,
	rarityId: string,
	weight: number,
}

export type LootTable = {
	id: string,
	entries: { LootEntry },
	rollCount: number,
}

export type LootResult = {
	itemId: string,
	quantity: number,
	rarityId: string,
}

export type LootSystem = {
	RegisterRarity: (self: LootSystem, rarity: RarityTier) -> (),
	RegisterLootTable: (self: LootSystem, table: LootTable) -> (),
	Roll: (self: LootSystem, tableId: string, luckModifier: number?) -> { LootResult },
	GetRarityColor: (self: LootSystem, rarityId: string) -> Color3,
}

type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
}

function LootSystem.new(eventBus: EventBus): LootSystem
	local self = setmetatable({}, LootSystem)
	self._eventBus = eventBus
	self._rarities = {} :: { [string]: RarityTier }
	self._lootTables = {} :: { [string]: LootTable }
	self._rareThreshold = 0.2
	return self
end

function LootSystem:RegisterRarity(rarity: RarityTier)
	self._rarities[rarity.id] = rarity
end

function LootSystem:RegisterLootTable(tbl: LootTable)
	self._lootTables[tbl.id] = tbl
end

function LootSystem:Roll(tableId: string, luckModifier: number?): { LootResult }
	local tbl = self._lootTables[tableId]
	if not tbl then
		return {}
	end

	local luck = luckModifier or 1.0
	local results: { LootResult } = {}

	for _ = 1, tbl.rollCount do
		local effectiveWeights: { number } = {}
		local entries: { LootEntry } = {}
		local totalWeight = 0

		for _, entry in ipairs(tbl.entries) do
			local rarity = self._rarities[entry.rarityId]
			if rarity then
				local effectiveWeight = entry.weight * rarity.weight * luck
				table.insert(effectiveWeights, effectiveWeight)
				table.insert(entries, entry)
				totalWeight += effectiveWeight
			end
		end

		if totalWeight <= 0 or #entries == 0 then
			continue
		end

		local roll = math.random() * totalWeight
		local cumulative = 0
		local selectedEntry: LootEntry? = nil

		for i, weight in ipairs(effectiveWeights) do
			cumulative += weight
			if roll <= cumulative then
				selectedEntry = entries[i]
				break
			end
		end

		if not selectedEntry then
			selectedEntry = entries[#entries]
		end

		if selectedEntry then
			local result: LootResult = {
				itemId = selectedEntry.itemId,
				quantity = selectedEntry.quantity,
				rarityId = selectedEntry.rarityId,
			}
			table.insert(results, result)

			-- Check for rare drop
			local rarity = self._rarities[selectedEntry.rarityId]
			if rarity and rarity.weight < self._rareThreshold then
				self._eventBus:Emit("RareItemDropped", {
					itemId = selectedEntry.itemId,
					rarityId = selectedEntry.rarityId,
					rarityName = rarity.name,
				})
			end
		end
	end

	self._eventBus:Emit("LootDropped", {
		results = results,
		sourceId = tableId,
	})

	return results
end

function LootSystem:GetRarityColor(rarityId: string): Color3
	local rarity = self._rarities[rarityId]
	if rarity then
		return rarity.color
	end
	return Color3.new(1, 1, 1)
end

-- Clear rarity definitions and loot tables.
function LootSystem:Destroy()
	self._rarities = {}
	self._lootTables = {}
end

return LootSystem
