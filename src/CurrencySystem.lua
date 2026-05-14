--!strict
-- CurrencySystem.lua
-- Multiple currencies, transactions, and balances.

local EventBus = require(script.Parent.Core.EventBus)
local Config = require(script.Parent.Core.Config)

local CurrencySystem = {}
CurrencySystem.__index = CurrencySystem

export type CurrencyDef = {
	id: string,
	name: string,
	symbol: string,
	defaultBalance: number,
}

export type CurrencyTransaction = {
	currencyId: string,
	amount: number,
	reason: string,
	timestamp: number,
}

export type CurrencySystem = {
	RegisterCurrency: (self: CurrencySystem, def: CurrencyDef) -> (),
	Add: (self: CurrencySystem, currencyId: string, amount: number, reason: string?) -> boolean,
	Subtract: (self: CurrencySystem, currencyId: string, amount: number, reason: string?) -> boolean,
	GetBalance: (self: CurrencySystem, currencyId: string) -> number,
	CanAfford: (self: CurrencySystem, currencyId: string, amount: number) -> boolean,
	Transfer: (self: CurrencySystem, currencyId: string, amount: number, target: CurrencySystem?) -> boolean,
	GetHistory: (self: CurrencySystem, currencyId: string, limit: number?) -> { CurrencyTransaction },

	-- Private
	_eventBus: EventBus.EventBus,
	_config: Config.Config,
	_currencies: { [string]: CurrencyDef },
	_balances: { [string]: number },
	_history: { [string]: { CurrencyTransaction } },
}

function CurrencySystem.new(eventBus: EventBus.EventBus, config: Config.Config?): CurrencySystem
	local self = setmetatable({}, CurrencySystem) :: CurrencySystem
	self._eventBus = eventBus
	self._config = config or Config.new()
	self._currencies = {}
	self._balances = {}
	self._history = {}
	return self
end

function CurrencySystem:RegisterCurrency(def: CurrencyDef)
	self._currencies[def.id] = def
	if self._balances[def.id] == nil then
		self._balances[def.id] = def.defaultBalance
	end
	if not self._history[def.id] then
		self._history[def.id] = {}
	end
end

function CurrencySystem:Add(currencyId: string, amount: number, reason: string?): boolean
	if amount <= 0 then return false end

	local def = self._currencies[currencyId]
	if not def then return false end

	local oldBalance = self._balances[currencyId]
	self._balances[currencyId] = oldBalance + amount

	self._eventBus:Emit("CurrencyAdded", {
		currencyId = currencyId,
		amount = amount,
		newBalance = self._balances[currencyId],
	})
	self._eventBus:Emit("CurrencyBalanceChanged", {
		currencyId = currencyId,
		oldBalance = oldBalance,
		newBalance = self._balances[currencyId],
	})

	self:_logTransaction(currencyId, amount, reason or "add")
	return true
end

function CurrencySystem:Subtract(currencyId: string, amount: number, reason: string?): boolean
	if amount <= 0 then return false end

	local def = self._currencies[currencyId]
	if not def then return false end

	local allowDebt = self._config:Get("allowDebt", false) :: boolean
	local currentBalance = self._balances[currencyId]

	if not allowDebt and currentBalance < amount then
		return false
	end

	local oldBalance = currentBalance
	self._balances[currencyId] = currentBalance - amount

	self._eventBus:Emit("CurrencySubtracted", {
		currencyId = currencyId,
		amount = amount,
		newBalance = self._balances[currencyId],
	})
	self._eventBus:Emit("CurrencyBalanceChanged", {
		currencyId = currencyId,
		oldBalance = oldBalance,
		newBalance = self._balances[currencyId],
	})

	self:_logTransaction(currencyId, -amount, reason or "subtract")
	return true
end

function CurrencySystem:GetBalance(currencyId: string): number
	return self._balances[currencyId] or 0
end

function CurrencySystem:CanAfford(currencyId: string, amount: number): boolean
	return self:GetBalance(currencyId) >= amount
end

function CurrencySystem:Transfer(currencyId: string, amount: number, target: CurrencySystem?): boolean
	if not target then return false end
	if amount <= 0 then return false end

	local def = self._currencies[currencyId]
	if not def then return false end

	local ok = self:Subtract(currencyId, amount, "transfer_out")
	if not ok then return false end

	target:Add(currencyId, amount, "transfer_in")
	return true
end

function CurrencySystem:GetHistory(currencyId: string, limit: number?): { CurrencyTransaction }
	local logs = self._history[currencyId] or {}
	local result = {}
	local startIdx = 1
	if limit and limit > 0 and limit < #logs then
		startIdx = #logs - limit + 1
	end
	for i = startIdx, #logs do
		table.insert(result, {
			currencyId = logs[i].currencyId,
			amount = logs[i].amount,
			reason = logs[i].reason,
			timestamp = logs[i].timestamp,
		})
	end
	return result
end

function CurrencySystem:_logTransaction(currencyId: string, amount: number, reason: string)
	if not self._history[currencyId] then
		self._history[currencyId] = {}
	end
	table.insert(self._history[currencyId], {
		currencyId = currencyId,
		amount = amount,
		reason = reason,
		timestamp = os.time(),
	})
	self._eventBus:Emit("TransactionLogged", {
		currencyId = currencyId,
		amount = amount,
		reason = reason,
		timestamp = os.time(),
	})
end

-- Clear all currency definitions, balances, and history.
function CurrencySystem:Destroy()
	self._currencies = {}
	self._balances = {}
	self._history = {}
end

return CurrencySystem
