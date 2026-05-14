--!strict
-- Inventory.lua
-- Slot-based inventory with stacking and equipping support.

local Inventory = {}
Inventory.__index = Inventory

export type Slot = { itemId: string, quantity: number, equipped: boolean }
export type ItemDef = {
	id: string,
	name: string,
	maxStack: number,
	equippable: boolean,
	-- Optional. nil is treated as true (tradeable). Set false for soul-bound items.
	tradeable: boolean?,
	metadata: { [string]: any }?,
}

export type Inventory = {
	AddItem: (self: Inventory, itemId: string, quantity: number?) -> boolean,
	RemoveItem: (self: Inventory, itemId: string, quantity: number?) -> boolean,
	GetSlot: (self: Inventory, index: number) -> Slot?,
	EquipItem: (self: Inventory, index: number) -> boolean,
	UnequipItem: (self: Inventory, index: number) -> boolean,
	GetAllSlots: (self: Inventory) -> { Slot },
	GetItemQuantity: (self: Inventory, itemId: string) -> number,
	HasItem: (self: Inventory, itemId: string, quantity: number?) -> boolean,
	IsItemTradeable: (self: Inventory, itemId: string) -> boolean,
	DefineItem: (self: Inventory, itemDef: ItemDef) -> (),
}

function Inventory.new(eventBus: { Emit: (self: any, eventName: string, payload: any) -> () }, maxSlots: number): Inventory
	local self = setmetatable({}, Inventory)
	self._eventBus = eventBus
	self._maxSlots = maxSlots
	self._itemDefs = {} :: { [string]: ItemDef }
	self._slots = {} :: { [number]: Slot }
	return self
end

function Inventory:DefineItem(itemDef: ItemDef)
	self._itemDefs[itemDef.id] = itemDef
end

function Inventory:_getDef(itemId: string): ItemDef?
	return self._itemDefs[itemId]
end

function Inventory:_findEmptySlot(): number?
	for i = 1, self._maxSlots do
		if not self._slots[i] then
			return i
		end
	end
	return nil
end

function Inventory:_findStackableSlot(itemId: string, maxStack: number): number?
	for i = 1, self._maxSlots do
		local slot = self._slots[i]
		if slot and slot.itemId == itemId and slot.quantity < maxStack then
			return i
		end
	end
	return nil
end

function Inventory:AddItem(itemId: string, quantity: number?): boolean
	local qty = quantity or 1
	if qty <= 0 then
		return false
	end

	local def = self:_getDef(itemId)
	if not def then
		return false
	end

	local maxStack = def.maxStack
	local remaining = qty

	-- Try to stack into existing slots first
	while remaining > 0 do
		local stackIdx = self:_findStackableSlot(itemId, maxStack)
		if stackIdx then
			local slot = self._slots[stackIdx]
			local space = maxStack - slot.quantity
			local toAdd = math.min(remaining, space)
			slot.quantity += toAdd
			remaining -= toAdd
			self._eventBus:Emit("ItemAdded", { itemId = itemId, quantity = toAdd, slotIndex = stackIdx })
		else
			break
		end
	end

	-- Overflow into empty slots
	while remaining > 0 do
		local emptyIdx = self:_findEmptySlot()
		if not emptyIdx then
			self._eventBus:Emit("InventoryFull", { itemId = itemId, remaining = remaining })
			return false
		end
		local toAdd = math.min(remaining, maxStack)
		self._slots[emptyIdx] = { itemId = itemId, quantity = toAdd, equipped = false }
		remaining -= toAdd
		self._eventBus:Emit("ItemAdded", { itemId = itemId, quantity = toAdd, slotIndex = emptyIdx })
	end

	return true
end

function Inventory:RemoveItem(itemId: string, quantity: number?): boolean
	local qty = quantity or 1
	if qty <= 0 then
		return false
	end

	local def = self:_getDef(itemId)
	if not def then
		return false
	end

	local remaining = qty
	local indicesToCheck = {}
	for i = 1, self._maxSlots do
		local slot = self._slots[i]
		if slot and slot.itemId == itemId then
			table.insert(indicesToCheck, i)
		end
	end

	for _, idx in ipairs(indicesToCheck) do
		if remaining <= 0 then
			break
		end
		local slot = self._slots[idx]
		if slot then
			local toRemove = math.min(remaining, slot.quantity)
			slot.quantity -= toRemove
			remaining -= toRemove
			self._eventBus:Emit("ItemRemoved", { itemId = itemId, quantity = toRemove, slotIndex = idx })
			if slot.quantity <= 0 then
				self._slots[idx] = nil
			end
		end
	end

	return remaining <= 0
end

function Inventory:GetSlot(index: number): Slot?
	if index < 1 or index > self._maxSlots then
		return nil
	end
	local slot = self._slots[index]
	if not slot then
		return nil
	end
	return { itemId = slot.itemId, quantity = slot.quantity, equipped = slot.equipped }
end

function Inventory:EquipItem(index: number): boolean
	if index < 1 or index > self._maxSlots then
		return false
	end
	local slot = self._slots[index]
	if not slot then
		return false
	end
	local def = self:_getDef(slot.itemId)
	if not def or not def.equippable then
		return false
	end
	if slot.equipped then
		return false
	end
	slot.equipped = true
	self._eventBus:Emit("ItemEquipped", { itemId = slot.itemId, slotIndex = index, equipped = true })
	return true
end

function Inventory:UnequipItem(index: number): boolean
	if index < 1 or index > self._maxSlots then
		return false
	end
	local slot = self._slots[index]
	if not slot then
		return false
	end
	if not slot.equipped then
		return false
	end
	slot.equipped = false
	self._eventBus:Emit("ItemEquipped", { itemId = slot.itemId, slotIndex = index, equipped = false })
	return true
end

function Inventory:GetAllSlots(): { Slot }
	local result = {}
	for i = 1, self._maxSlots do
		local slot = self._slots[i]
		if slot then
			table.insert(result, { itemId = slot.itemId, quantity = slot.quantity, equipped = slot.equipped })
		end
	end
	return result
end

-- Returns the total quantity of `itemId` across all slots.
-- Used by CraftingSystem and PetSystem to perform direct, synchronous
-- inventory checks without the event-bus round-trip.
function Inventory:GetItemQuantity(itemId: string): number
	local total = 0
	for i = 1, self._maxSlots do
		local slot = self._slots[i]
		if slot and slot.itemId == itemId then
			total += slot.quantity
		end
	end
	return total
end

-- Convenience: returns true if at least `quantity` of `itemId` is present.
function Inventory:HasItem(itemId: string, quantity: number?): boolean
	local needed = quantity or 1
	return self:GetItemQuantity(itemId) >= needed
end

-- Returns true if the item is tradeable. Items with nil tradeable are treated
-- as TRUE (backward compatible — most items in a pet game are tradeable).
-- TradeSystem calls this to gate offer additions.
function Inventory:IsItemTradeable(itemId: string): boolean
	local def = self._itemDefs[itemId]
	if not def then
		return false  -- unknown items can't be traded
	end
	if def.tradeable == false then
		return false
	end
	return true  -- nil or true → tradeable
end

-- Clear all item definitions and slot state.
function Inventory:Destroy()
	self._itemDefs = {}
	self._slots = {}
end

return Inventory
