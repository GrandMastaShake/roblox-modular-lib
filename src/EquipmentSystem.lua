--!strict
-- EquipmentSystem.lua
-- Gear slots with stat modifiers and type filtering.

local EquipmentSystem = {}
EquipmentSystem.__index = EquipmentSystem

export type EquipmentSlot = {
	id: string,
	name: string,
	allowedTypes: { string }?,
}

export type EquippedItem = {
	slotId: string,
	itemId: string,
	stats: { [string]: number }?,
}

export type EquipmentSystem = {
	RegisterSlot: (self: EquipmentSystem, slot: EquipmentSlot) -> (),
	Equip: (self: EquipmentSystem, slotId: string, itemId: string, itemStats: { [string]: number }?) -> boolean,
	Unequip: (self: EquipmentSystem, slotId: string) -> string?,
	GetEquipped: (self: EquipmentSystem, slotId: string) -> EquippedItem?,
	GetAllEquipped: (self: EquipmentSystem) -> { EquippedItem },
	GetTotalStats: (self: EquipmentSystem) -> { [string]: number },
}

type EventBus = {
	Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
	Emit: (self: EventBus, eventName: string, payload: any) -> (),
}

function EquipmentSystem.new(eventBus: EventBus): EquipmentSystem
	local self = setmetatable({}, EquipmentSystem)
	self._eventBus = eventBus
	self._slots = {} :: { [string]: EquipmentSlot }
	self._equipped = {} :: { [string]: EquippedItem }
	return self
end

function EquipmentSystem:RegisterSlot(slot: EquipmentSlot)
	self._slots[slot.id] = slot
end

function EquipmentSystem:Equip(slotId: string, itemId: string, itemStats: { [string]: number }?, itemType: string?): boolean
	local slot = self._slots[slotId]
	if not slot then
		return false
	end

	-- Check allowedTypes filter
	if slot.allowedTypes and #slot.allowedTypes > 0 then
		if not itemType then
			return false
		end
		local allowed = false
		for _, t in ipairs(slot.allowedTypes) do
			if t == itemType then
				allowed = true
				break
			end
		end
		if not allowed then
			return false
		end
	end

	local previousItemId: string? = nil
	local existing = self._equipped[slotId]
	if existing then
		previousItemId = existing.itemId
	end

	self._equipped[slotId] = {
		slotId = slotId,
		itemId = itemId,
		stats = itemStats,
	}

	self._eventBus:Emit("ItemEquipped", {
		slotId = slotId,
		itemId = itemId,
		previousItemId = previousItemId,
	})

	self:_emitStatsChanged()

	return true
end

function EquipmentSystem:Unequip(slotId: string): string?
	local equipped = self._equipped[slotId]
	if not equipped then
		return nil
	end

	local itemId = equipped.itemId
	self._equipped[slotId] = nil

	self._eventBus:Emit("ItemUnequipped", {
		slotId = slotId,
		itemId = itemId,
	})

	self:_emitStatsChanged()

	return itemId
end

function EquipmentSystem:GetEquipped(slotId: string): EquippedItem?
	local equipped = self._equipped[slotId]
	if not equipped then
		return nil
	end
	return {
		slotId = equipped.slotId,
		itemId = equipped.itemId,
		stats = equipped.stats and table.clone(equipped.stats) or nil,
	}
end

function EquipmentSystem:GetAllEquipped(): { EquippedItem }
	local result = {}
	for _, equipped in pairs(self._equipped) do
		table.insert(result, {
			slotId = equipped.slotId,
			itemId = equipped.itemId,
			stats = equipped.stats and table.clone(equipped.stats) or nil,
		})
	end
	return result
end

function EquipmentSystem:GetTotalStats(): { [string]: number }
	local totals: { [string]: number } = {}
	for _, equipped in pairs(self._equipped) do
		if equipped.stats then
			for statName, value in pairs(equipped.stats) do
				totals[statName] = (totals[statName] or 0) + value
			end
		end
	end
	return totals
end

function EquipmentSystem:_emitStatsChanged()
	local totals = self:GetTotalStats()
	self._eventBus:Emit("StatsChanged", { stats = totals })
end

-- Clear slots and equipped state.
function EquipmentSystem:Destroy()
	self._slots = {}
	self._equipped = {}
end

return EquipmentSystem
