--!strict
-- TradeRemoteHandler.lua
-- Reference implementation of the RemoteEvent hardening layer for trades.
--
-- ============================================================================
-- WHAT THIS IS (AND ISN'T)
-- ============================================================================
--
-- This module is a REFERENCE. It shows the canonical pattern for the
-- network-edge layer of a trade system: per-player rate limiting, rigorous
-- input sanitization, uni-directional remote routing, and zero-trust
-- handling of every client payload. The Perplexity research treats every
-- incoming RemoteEvent as a potential exploit vector.
--
-- A real game's RemoteEvent layer almost certainly needs to deviate from
-- this file in *some* way:
--
--   * The exact rate limits depend on the gameplay tempo (a fast-paced
--     trade hub might bump TradeAddItem from 0.25s -> 0.1s).
--   * The remote names depend on existing project conventions.
--   * The state-broadcast back to clients (the Server -> Client side)
--     might use Roblox's new Attribute-based replication instead of
--     RemoteEvents.
--
-- We ship this as a working baseline that:
--   1. Demonstrates the pattern end-to-end.
--   2. Plugs into the existing TradeSystem without modification.
--   3. Can be customized via the Config keys at the top of the file.
--
-- ============================================================================
-- DEPENDENCY INJECTION
-- ============================================================================
--
-- Required deps:
--   trades:    TradeSystem        -- the state-machine module
--   inventory: any                -- expose :IsItemTradeable, :GetItemQuantity
--   pets:      any                -- expose :OwnsPet
--
-- Required remotes (passed in so the caller controls Folder/RemoteEvent
-- placement; we don't reach into ReplicatedStorage):
--   inbound  : { [eventName]: RemoteEvent }   -- Client -> Server
--   outbound : { [eventName]: RemoteEvent }   -- Server -> Client
--
-- The expected eventName set:
--   inbound:  TradeRequest, TradeAccept, TradeAddPet, TradeRemovePet,
--             TradeAddItem, TradeRemoveItem, TradeSetReady, TradeConfirm,
--             TradeCancel
--   outbound: TradeStateUpdate, TradeError
--
-- ============================================================================
-- EMITTED EVENTS (from this module)
-- ============================================================================
--
-- TradeRemoteRejected { uid, eventName, reason }
-- TradeRemoteAccepted { uid, eventName }

local Players  = game:GetService("Players")

local EventBus = require(script.Parent.Core.EventBus)
local Config   = require(script.Parent.Core.Config)

local TradeRemoteHandler = {}
TradeRemoteHandler.__index = TradeRemoteHandler

-- ----------------------------------------------------------------------------
-- Defaults (overridable via Config)
-- ----------------------------------------------------------------------------

local DEFAULT_RATE_LIMITS: { [string]: number } = {
	TradeRequest    = 2.0,
	TradeAccept     = 1.0,
	TradeAddPet     = 0.25,
	TradeRemovePet  = 0.25,
	TradeAddItem    = 0.25,
	TradeRemoveItem = 0.25,
	TradeSetReady   = 0.5,
	TradeConfirm    = 1.0,
	TradeCancel     = 0.5,
}

local MAX_ITEM_ID_LEN = 64
local MAX_NICKNAME_LEN = 32
local MAX_QUANTITY = 1_000_000

-- Whitelist regex for item ids and pet ids. Alphanumeric + underscore + hyphen.
-- Anything else is rejected at the boundary; keeps DataStore-injection
-- attack surface minimal.
local SAFE_ID_PATTERN = "^[%w_%-]+$"

-- ----------------------------------------------------------------------------
-- Types
-- ----------------------------------------------------------------------------

export type TradeRemoteHandlerDeps = {
	trades:    any,
	inventory: any,
	pets:      any,
	inbound:   { [string]: RemoteEvent },
	outbound:  { [string]: RemoteEvent }?,
}

export type TradeRemoteHandler = {
	Destroy: (self: TradeRemoteHandler) -> (),

	-- Private
	_eventBus:     EventBus.EventBus,
	_config:       Config.Config,
	_deps:         TradeRemoteHandlerDeps,
	_rateLimits:   { [string]: number },
	_lastFired:    { [string]: number },   -- key = userId .. ":" .. eventName
	_connections:  { RBXScriptConnection },
	_destroyed:    boolean,
}

-- ----------------------------------------------------------------------------
-- Constructor
-- ----------------------------------------------------------------------------

function TradeRemoteHandler.new(
	eventBus: EventBus.EventBus,
	deps: TradeRemoteHandlerDeps,
	config: Config.Config?
): TradeRemoteHandler
	local self = setmetatable({}, TradeRemoteHandler) :: TradeRemoteHandler
	self._eventBus = eventBus
	self._config = config or Config.new()
	self._deps = deps
	self._lastFired = {}
	self._connections = {}
	self._destroyed = false

	-- Rate limits start from defaults; per-event Config keys can override
	-- (e.g. tradeRateLimit_TradeAddItem = 0.1)
	self._rateLimits = {}
	for eventName, defaultRate in pairs(DEFAULT_RATE_LIMITS) do
		self._rateLimits[eventName] = self._config:Get(
			"tradeRateLimit_" .. eventName,
			defaultRate
		) :: number
	end

	self:_wireHandlers()
	return self
end

-- ----------------------------------------------------------------------------
-- Sanitization helpers
-- ----------------------------------------------------------------------------

local function isSafeId(s: any): boolean
	if typeof(s) ~= "string" then return false end
	if #s == 0 or #s > MAX_ITEM_ID_LEN then return false end
	if string.find(s :: string, "\0") then return false end
	return string.match(s :: string, SAFE_ID_PATTERN) ~= nil
end

local function isSafeNickname(s: any): boolean
	if typeof(s) ~= "string" then return false end
	if #s == 0 or #s > MAX_NICKNAME_LEN then return false end
	if string.find(s :: string, "\0") then return false end
	return true
end

local function isPositiveInt(n: any): boolean
	if typeof(n) ~= "number" then return false end
	if n ~= n then return false end  -- NaN
	if n <= 0 then return false end
	if n > MAX_QUANTITY then return false end
	if math.floor(n) ~= n then return false end
	return true
end

-- ----------------------------------------------------------------------------
-- Rate limiting
-- ----------------------------------------------------------------------------

function TradeRemoteHandler:_checkRate(uid: number, eventName: string): boolean
	local key = uid .. ":" .. eventName
	local limit = self._rateLimits[eventName] or 1.0
	local now = os.clock()
	local last = self._lastFired[key]
	if last and now - last < limit then
		return false
	end
	self._lastFired[key] = now
	return true
end

function TradeRemoteHandler:_reject(uid: number, eventName: string, reason: string)
	self._eventBus:Emit("TradeRemoteRejected", { uid = uid, eventName = eventName, reason = reason })
	-- Optionally tell the client; outbound is optional so existing
	-- composition roots that don't wire it up still work.
	if self._deps.outbound and self._deps.outbound.TradeError then
		local player = Players:GetPlayerByUserId(uid)
		if player then
			pcall(function()
				self._deps.outbound.TradeError:FireClient(player, eventName, reason)
			end)
		end
	end
end

function TradeRemoteHandler:_accept(uid: number, eventName: string)
	self._eventBus:Emit("TradeRemoteAccepted", { uid = uid, eventName = eventName })
end

-- ----------------------------------------------------------------------------
-- Per-event handlers
-- ----------------------------------------------------------------------------

function TradeRemoteHandler:_wireHandlers()
	local inbound = self._deps.inbound

	if inbound.TradeRequest then
		table.insert(self._connections, inbound.TradeRequest.OnServerEvent:Connect(function(player, targetUserId)
			self:_onTradeRequest(player, targetUserId)
		end))
	end
	if inbound.TradeAccept then
		table.insert(self._connections, inbound.TradeAccept.OnServerEvent:Connect(function(player, tradeId)
			self:_onTradeAccept(player, tradeId)
		end))
	end
	if inbound.TradeAddPet then
		table.insert(self._connections, inbound.TradeAddPet.OnServerEvent:Connect(function(player, tradeId, petId)
			self:_onTradeAddPet(player, tradeId, petId)
		end))
	end
	if inbound.TradeRemovePet then
		table.insert(self._connections, inbound.TradeRemovePet.OnServerEvent:Connect(function(player, tradeId, petId)
			self:_onTradeRemovePet(player, tradeId, petId)
		end))
	end
	if inbound.TradeAddItem then
		table.insert(self._connections, inbound.TradeAddItem.OnServerEvent:Connect(function(player, tradeId, itemId, quantity)
			self:_onTradeAddItem(player, tradeId, itemId, quantity)
		end))
	end
	if inbound.TradeRemoveItem then
		table.insert(self._connections, inbound.TradeRemoveItem.OnServerEvent:Connect(function(player, tradeId, itemId, quantity)
			self:_onTradeRemoveItem(player, tradeId, itemId, quantity)
		end))
	end
	if inbound.TradeSetReady then
		table.insert(self._connections, inbound.TradeSetReady.OnServerEvent:Connect(function(player, tradeId, ready)
			self:_onTradeSetReady(player, tradeId, ready)
		end))
	end
	if inbound.TradeConfirm then
		table.insert(self._connections, inbound.TradeConfirm.OnServerEvent:Connect(function(player, tradeId, confirmed)
			self:_onTradeConfirm(player, tradeId, confirmed)
		end))
	end
	if inbound.TradeCancel then
		table.insert(self._connections, inbound.TradeCancel.OnServerEvent:Connect(function(player, tradeId)
			self:_onTradeCancel(player, tradeId)
		end))
	end
end

function TradeRemoteHandler:_onTradeRequest(player: Player, targetUserId: any)
	local uid = player.UserId
	if not self:_checkRate(uid, "TradeRequest") then
		return self:_reject(uid, "TradeRequest", "rate_limited")
	end
	if typeof(targetUserId) ~= "number" then
		return self:_reject(uid, "TradeRequest", "bad_target_type")
	end
	if targetUserId == uid then
		return self:_reject(uid, "TradeRequest", "self_trade")
	end
	if not Players:GetPlayerByUserId(targetUserId) then
		return self:_reject(uid, "TradeRequest", "target_offline")
	end
	local tradeId = self._deps.trades:Propose(uid, targetUserId)
	if not tradeId then
		return self:_reject(uid, "TradeRequest", "propose_failed")
	end
	self:_accept(uid, "TradeRequest")
end

function TradeRemoteHandler:_onTradeAccept(player: Player, tradeId: any)
	local uid = player.UserId
	if not isSafeId(tradeId) then
		return self:_reject(uid, "TradeAccept", "bad_trade_id")
	end
	if not self:_checkRate(uid, "TradeAccept") then
		return self:_reject(uid, "TradeAccept", "rate_limited")
	end
	if not self._deps.trades:Accept(tradeId, uid) then
		return self:_reject(uid, "TradeAccept", "accept_failed")
	end
	self:_accept(uid, "TradeAccept")
end

function TradeRemoteHandler:_onTradeAddPet(player: Player, tradeId: any, petId: any)
	local uid = player.UserId
	if not self:_checkRate(uid, "TradeAddPet") then
		return self:_reject(uid, "TradeAddPet", "rate_limited")
	end
	if not isSafeId(tradeId) or not isSafeId(petId) then
		return self:_reject(uid, "TradeAddPet", "bad_id")
	end
	-- Server-side ownership check before the trade module sees the request.
	-- This is belt-and-suspenders \u2014 TradeSystem also validates \u2014 but it
	-- shaves an unnecessary round trip on the failure path.
	if not self._deps.pets:OwnsPet(uid, petId) then
		return self:_reject(uid, "TradeAddPet", "not_owner")
	end
	if not self._deps.trades:AddPet(tradeId, uid, petId) then
		return self:_reject(uid, "TradeAddPet", "add_failed")
	end
	self:_accept(uid, "TradeAddPet")
end

function TradeRemoteHandler:_onTradeRemovePet(player: Player, tradeId: any, petId: any)
	local uid = player.UserId
	if not self:_checkRate(uid, "TradeRemovePet") then
		return self:_reject(uid, "TradeRemovePet", "rate_limited")
	end
	if not isSafeId(tradeId) or not isSafeId(petId) then
		return self:_reject(uid, "TradeRemovePet", "bad_id")
	end
	if not self._deps.trades:RemovePet(tradeId, uid, petId) then
		return self:_reject(uid, "TradeRemovePet", "remove_failed")
	end
	self:_accept(uid, "TradeRemovePet")
end

function TradeRemoteHandler:_onTradeAddItem(player: Player, tradeId: any, itemId: any, quantity: any)
	local uid = player.UserId
	if not self:_checkRate(uid, "TradeAddItem") then
		return self:_reject(uid, "TradeAddItem", "rate_limited")
	end
	if not isSafeId(tradeId) or not isSafeId(itemId) then
		return self:_reject(uid, "TradeAddItem", "bad_id")
	end
	if not isPositiveInt(quantity) then
		return self:_reject(uid, "TradeAddItem", "bad_quantity")
	end
	if self._deps.inventory.IsItemTradeable
		and not self._deps.inventory:IsItemTradeable(itemId) then
		return self:_reject(uid, "TradeAddItem", "soulbound")
	end
	if not self._deps.trades:AddItem(tradeId, uid, itemId, quantity) then
		return self:_reject(uid, "TradeAddItem", "add_failed")
	end
	self:_accept(uid, "TradeAddItem")
end

function TradeRemoteHandler:_onTradeRemoveItem(player: Player, tradeId: any, itemId: any, quantity: any)
	local uid = player.UserId
	if not self:_checkRate(uid, "TradeRemoveItem") then
		return self:_reject(uid, "TradeRemoveItem", "rate_limited")
	end
	if not isSafeId(tradeId) or not isSafeId(itemId) then
		return self:_reject(uid, "TradeRemoveItem", "bad_id")
	end
	-- quantity is optional on remove (nil means "remove all").
	if quantity ~= nil and not isPositiveInt(quantity) then
		return self:_reject(uid, "TradeRemoveItem", "bad_quantity")
	end
	if not self._deps.trades:RemoveItem(tradeId, uid, itemId, quantity) then
		return self:_reject(uid, "TradeRemoveItem", "remove_failed")
	end
	self:_accept(uid, "TradeRemoveItem")
end

function TradeRemoteHandler:_onTradeSetReady(player: Player, tradeId: any, ready: any)
	local uid = player.UserId
	if not self:_checkRate(uid, "TradeSetReady") then
		return self:_reject(uid, "TradeSetReady", "rate_limited")
	end
	if not isSafeId(tradeId) then
		return self:_reject(uid, "TradeSetReady", "bad_trade_id")
	end
	if typeof(ready) ~= "boolean" then
		return self:_reject(uid, "TradeSetReady", "bad_ready_type")
	end
	if not self._deps.trades:SetReady(tradeId, uid, ready) then
		return self:_reject(uid, "TradeSetReady", "set_ready_failed")
	end
	self:_accept(uid, "TradeSetReady")
end

function TradeRemoteHandler:_onTradeConfirm(player: Player, tradeId: any, confirmed: any)
	local uid = player.UserId
	if not self:_checkRate(uid, "TradeConfirm") then
		return self:_reject(uid, "TradeConfirm", "rate_limited")
	end
	if not isSafeId(tradeId) then
		return self:_reject(uid, "TradeConfirm", "bad_trade_id")
	end
	if typeof(confirmed) ~= "boolean" then
		return self:_reject(uid, "TradeConfirm", "bad_confirmed_type")
	end
	if not self._deps.trades:Confirm(tradeId, uid, confirmed) then
		return self:_reject(uid, "TradeConfirm", "confirm_failed")
	end
	self:_accept(uid, "TradeConfirm")
end

function TradeRemoteHandler:_onTradeCancel(player: Player, tradeId: any)
	local uid = player.UserId
	if not self:_checkRate(uid, "TradeCancel") then
		return self:_reject(uid, "TradeCancel", "rate_limited")
	end
	if not isSafeId(tradeId) then
		return self:_reject(uid, "TradeCancel", "bad_trade_id")
	end
	if not self._deps.trades:Cancel(tradeId, uid) then
		return self:_reject(uid, "TradeCancel", "cancel_failed")
	end
	self:_accept(uid, "TradeCancel")
end

-- ----------------------------------------------------------------------------
-- Cleanup
-- ----------------------------------------------------------------------------

function TradeRemoteHandler:Destroy()
	self._destroyed = true
	for _, conn in ipairs(self._connections) do
		if conn and conn.Connected then
			conn:Disconnect()
		end
	end
	self._connections = {}
	self._lastFired = {}
end

return TradeRemoteHandler
