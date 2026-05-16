--!strict
-- TradeSystem.lua
-- Player-to-player trading with two-phase confirmation and timeout.
-- Phase 1: Both players accept (offers locked).
-- Phase 2: Both players confirm → atomic inventory + currency swap.
-- Trades auto-cancel after TRADE_TIMEOUT_SECONDS via TimerSystem.
--
-- ZERO HARD-COUPLING: all dependencies injected via constructor.
-- Inline structural types keep this module --!strict compatible.

-- ---------------------------------------------------------------------------
-- Inline structural types (Luau structural typing — no require needed)
-- ---------------------------------------------------------------------------

type EventBus = {
    Subscribe: (self: EventBus, eventName: string, callback: (any) -> ()) -> () -> (),
    Emit: (self: EventBus, eventName: string, payload: any) -> (),
}

type Inventory = {
    AddItem:     (self: Inventory, itemId: string, quantity: number) -> boolean,
    RemoveItem:  (self: Inventory, itemId: string, quantity: number) -> boolean,
    GetAllSlots: (self: Inventory) -> { { itemId: string, quantity: number } },
}

type CurrencySystem = {
    CanAfford: (self: CurrencySystem, currencyId: string, amount: number) -> boolean,
    Subtract:  (self: CurrencySystem, currencyId: string, amount: number, reason: string) -> boolean,
    Add:       (self: CurrencySystem, currencyId: string, amount: number, reason: string) -> (),
    GetBalance:(self: CurrencySystem, currencyId: string) -> number,
}

type TimerSystem = {
    StartTimer: (self: TimerSystem, duration: number, callback: () -> (), loop: boolean) -> string,
    StopTimer:  (self: TimerSystem, timerId: string) -> (),
}

-- ---------------------------------------------------------------------------
-- Module table
-- ---------------------------------------------------------------------------

local TradeSystem = {}
TradeSystem.__index = TradeSystem

-- ---------------------------------------------------------------------------
-- Type aliases (exported)
-- ---------------------------------------------------------------------------

export type TradeSlot  = { itemId: string, quantity: number }
export type TradeOffer = { items: { TradeSlot }, bucks: number }
export type TradeState = "pending" | "accepted" | "confirmed" | "completed" | "cancelled"

export type Trade = {
    tradeId:    string,
    playerA:    string,
    playerB:    string,
    offerA:     TradeOffer,
    offerB:     TradeOffer,
    state:      TradeState,
    acceptedA:  boolean,
    acceptedB:  boolean,
    confirmedA: boolean,
    confirmedB: boolean,
    startedAt:  number,
    timerId:    string?,
}

export type TradeSystem = {
    RequestTrade:     (self: TradeSystem, fromPlayer: string, toPlayer: string) -> string?,
    AddItem:          (self: TradeSystem, tradeId: string, playerId: string, itemId: string, quantity: number) -> boolean,
    RemoveItem:       (self: TradeSystem, tradeId: string, playerId: string, itemId: string) -> boolean,
    AddBucks:         (self: TradeSystem, tradeId: string, playerId: string, amount: number) -> boolean,
    AcceptTrade:      (self: TradeSystem, tradeId: string, playerId: string) -> boolean,
    ConfirmTrade:     (self: TradeSystem, tradeId: string, playerId: string) -> boolean,
    CancelTrade:      (self: TradeSystem, tradeId: string, playerId: string?) -> (),
    GetTrade:         (self: TradeSystem, tradeId: string) -> Trade?,
    GetPlayerTrades:  (self: TradeSystem, playerId: string) -> { Trade },
    GetActiveTradeFor:(self: TradeSystem, playerId: string) -> string?,
    Destroy:          (self: TradeSystem) -> (),

    -- Internals
    _eventBus:      EventBus,
    _inventory:     Inventory,
    _inventoryMap:  { [string]: Inventory }?,  -- optional per-player map
    _currency:      CurrencySystem,
    _timer:         TimerSystem,
    _trades:        { [string]: Trade },
    _counter:       number,
    _activePlayers: { [string]: string },  -- playerId → tradeId
}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local TRADE_TIMEOUT_SECONDS = 120
local BUCKS_CURRENCY_ID     = "bucks"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function _deepCopyOffer(offer: TradeOffer): TradeOffer
    local itemsCopy: { TradeSlot } = {}
    for _, slot in ipairs(offer.items) do
        table.insert(itemsCopy, { itemId = slot.itemId, quantity = slot.quantity })
    end
    return { items = itemsCopy, bucks = offer.bucks }
end

local function _deepCopyTrade(trade: Trade): Trade
    return {
        tradeId    = trade.tradeId,
        playerA    = trade.playerA,
        playerB    = trade.playerB,
        offerA     = _deepCopyOffer(trade.offerA),
        offerB     = _deepCopyOffer(trade.offerB),
        state      = trade.state,
        acceptedA  = trade.acceptedA,
        acceptedB  = trade.acceptedB,
        confirmedA = trade.confirmedA,
        confirmedB = trade.confirmedB,
        startedAt  = trade.startedAt,
        timerId    = trade.timerId,
    }
end

local function _findSlotIndex(items: { TradeSlot }, itemId: string): number
    for i, slot in ipairs(items) do
        if slot.itemId == itemId then return i end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function TradeSystem.new(
    eventBus:  EventBus,
    inventory: Inventory,
    currency:  CurrencySystem,
    timer:     TimerSystem
): TradeSystem
    local self = setmetatable({}, TradeSystem) :: TradeSystem
    self._eventBus      = eventBus
    self._inventory     = inventory
    self._currency      = currency
    self._timer         = timer
    self._trades        = {}
    self._counter       = 0
    self._activePlayers = {}
    return self
end

-- ---------------------------------------------------------------------------
-- Request trade
-- ---------------------------------------------------------------------------

function TradeSystem:RequestTrade(fromPlayer: string, toPlayer: string): string?
    if fromPlayer == toPlayer then
        warn("[TradeSystem] Cannot trade with yourself")
        return nil
    end
    if self._activePlayers[fromPlayer] then
        warn("[TradeSystem] Player '" .. fromPlayer .. "' is already in an active trade")
        return nil
    end
    if self._activePlayers[toPlayer] then
        warn("[TradeSystem] Player '" .. toPlayer .. "' is already in an active trade")
        return nil
    end

    self._counter += 1
    local tradeId = "trade_" .. tostring(self._counter) .. "_" .. tostring(math.floor(os.clock() * 1000))

    local trade: Trade = {
        tradeId    = tradeId,
        playerA    = fromPlayer,
        playerB    = toPlayer,
        offerA     = { items = {}, bucks = 0 },
        offerB     = { items = {}, bucks = 0 },
        state      = "pending",
        acceptedA  = false,
        acceptedB  = false,
        confirmedA = false,
        confirmedB = false,
        startedAt  = os.time(),
        timerId    = nil,
    }

    -- Auto-cancel after timeout
    local sys = self
    trade.timerId = self._timer:StartTimer(TRADE_TIMEOUT_SECONDS, function()
        sys:_onTimeout(tradeId)
    end, false)

    self._trades[tradeId] = trade
    self._activePlayers[fromPlayer] = tradeId
    self._activePlayers[toPlayer]   = tradeId

    self._eventBus:Emit("TradeRequested", {
        tradeId    = tradeId,
        fromPlayer = fromPlayer,
        toPlayer   = toPlayer,
        state      = "pending",
    })

    return tradeId
end

-- ---------------------------------------------------------------------------
-- Modify offer
-- ---------------------------------------------------------------------------

function TradeSystem:AddItem(tradeId: string, playerId: string, itemId: string, quantity: number): boolean
    if quantity <= 0 then return false end

    local trade = self._trades[tradeId]
    if not trade then
        warn("[TradeSystem] Trade '" .. tradeId .. "' not found")
        return false
    end
    if trade.state ~= "pending" then
        warn("[TradeSystem] Trade is not pending (state: " .. trade.state .. ")")
        return false
    end

    local offer: TradeOffer? = nil
    if playerId == trade.playerA then
        offer = trade.offerA
    elseif playerId == trade.playerB then
        offer = trade.offerB
    else
        warn("[TradeSystem] Player '" .. playerId .. "' is not part of this trade")
        return false
    end
    if not offer then return false end

    -- Validate inventory covers existing offer + new quantity
    local alreadyOffered = 0
    local existingIdx = _findSlotIndex(offer.items, itemId)
    if existingIdx > 0 then
        alreadyOffered = offer.items[existingIdx].quantity
    end
    if not self:_playerHasItem(playerId, itemId, alreadyOffered + quantity) then
        warn("[TradeSystem] Player '" .. playerId .. "' cannot offer " .. itemId .. " x" .. tostring(alreadyOffered + quantity) .. " (insufficient inventory)")
        return false
    end

    local idx = existingIdx
    if idx > 0 then
        offer.items[idx].quantity += quantity
    else
        table.insert(offer.items, { itemId = itemId, quantity = quantity })
    end

    self._eventBus:Emit("ItemTraded", {
        tradeId  = tradeId,
        playerId = playerId,
        itemId   = itemId,
        quantity = quantity,
        action   = "added",
    })

    return true
end

function TradeSystem:RemoveItem(tradeId: string, playerId: string, itemId: string): boolean
    local trade = self._trades[tradeId]
    if not trade then return false end
    if trade.state ~= "pending" then return false end

    local offer: TradeOffer? = nil
    if playerId == trade.playerA then
        offer = trade.offerA
    elseif playerId == trade.playerB then
        offer = trade.offerB
    else
        return false
    end
    if not offer then return false end

    local idx = _findSlotIndex(offer.items, itemId)
    if idx == 0 then return false end

    local removedQty = offer.items[idx].quantity
    table.remove(offer.items, idx)

    self._eventBus:Emit("ItemTraded", {
        tradeId  = tradeId,
        playerId = playerId,
        itemId   = itemId,
        quantity = removedQty,
        action   = "removed",
    })

    return true
end

function TradeSystem:AddBucks(tradeId: string, playerId: string, amount: number): boolean
    if amount <= 0 then return false end

    local trade = self._trades[tradeId]
    if not trade then return false end
    if trade.state ~= "pending" then return false end

    local offer: TradeOffer? = nil
    if playerId == trade.playerA then
        offer = trade.offerA
    elseif playerId == trade.playerB then
        offer = trade.offerB
    else
        return false
    end
    if not offer then return false end

    local newTotal = offer.bucks + amount
    if not self._currency:CanAfford(BUCKS_CURRENCY_ID, newTotal) then
        warn("[TradeSystem] Player '" .. playerId .. "' cannot afford " .. tostring(newTotal) .. " bucks total")
        return false
    end

    offer.bucks = newTotal

    self._eventBus:Emit("BucksTraded", {
        tradeId  = tradeId,
        playerId = playerId,
        amount   = amount,
        action   = "added",
    })

    return true
end

-- ---------------------------------------------------------------------------
-- Accept trade (phase 1)
-- ---------------------------------------------------------------------------

function TradeSystem:AcceptTrade(tradeId: string, playerId: string): boolean
    local trade = self._trades[tradeId]
    if not trade then
        warn("[TradeSystem] Trade '" .. tradeId .. "' not found")
        return false
    end
    if trade.state ~= "pending" then return false end

    if playerId == trade.playerA then
        if trade.acceptedA then return false end
        trade.acceptedA = true
    elseif playerId == trade.playerB then
        if trade.acceptedB then return false end
        trade.acceptedB = true
    else
        warn("[TradeSystem] Player '" .. playerId .. "' is not part of this trade")
        return false
    end

    self._eventBus:Emit("TradeAccepted", {
        tradeId   = tradeId,
        playerId  = playerId,
        acceptedA = trade.acceptedA,
        acceptedB = trade.acceptedB,
    })

    if trade.acceptedA and trade.acceptedB then
        trade.state      = "accepted"
        trade.confirmedA = false
        trade.confirmedB = false
        self._eventBus:Emit("TradeStateChanged", {
            tradeId = tradeId,
            state   = "accepted",
            message = "Both players accepted. Confirm to complete.",
        })
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Confirm trade (phase 2) → executes swap if both confirmed
-- ---------------------------------------------------------------------------

function TradeSystem:ConfirmTrade(tradeId: string, playerId: string): boolean
    local trade = self._trades[tradeId]
    if not trade then
        warn("[TradeSystem] Trade '" .. tradeId .. "' not found")
        return false
    end
    if trade.state ~= "accepted" then
        warn("[TradeSystem] Trade must be 'accepted' to confirm (current: " .. trade.state .. ")")
        return false
    end

    if playerId == trade.playerA then
        if trade.confirmedA then return false end
        trade.confirmedA = true
    elseif playerId == trade.playerB then
        if trade.confirmedB then return false end
        trade.confirmedB = true
    else
        warn("[TradeSystem] Player '" .. playerId .. "' is not part of this trade")
        return false
    end

    self._eventBus:Emit("TradeConfirmed", {
        tradeId    = tradeId,
        playerId   = playerId,
        confirmedA = trade.confirmedA,
        confirmedB = trade.confirmedB,
    })

    if trade.confirmedA and trade.confirmedB then
        trade.state = "confirmed"
        self:_executeTrade(tradeId)
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Cancel trade
-- ---------------------------------------------------------------------------

function TradeSystem:CancelTrade(tradeId: string, playerId: string?)
    local trade = self._trades[tradeId]
    if not trade then return end
    if trade.state == "completed" or trade.state == "cancelled" then return end

    -- Validate caller is a participant (nil playerId = system/timeout cancel)
    if playerId ~= nil and playerId ~= trade.playerA and playerId ~= trade.playerB then
        warn("[TradeSystem] Player '" .. playerId .. "' cannot cancel a trade they are not part of")
        return
    end

    local oldState = trade.state
    trade.state = "cancelled"

    self._activePlayers[trade.playerA] = nil
    self._activePlayers[trade.playerB] = nil

    if trade.timerId then
        self._timer:StopTimer(trade.timerId)
        trade.timerId = nil
    end

    self._eventBus:Emit("TradeCancelled", {
        tradeId     = tradeId,
        cancelledBy = playerId,
        oldState    = oldState,
    })
end

-- ---------------------------------------------------------------------------
-- Query
-- ---------------------------------------------------------------------------

function TradeSystem:GetTrade(tradeId: string): Trade?
    local trade = self._trades[tradeId]
    return trade and _deepCopyTrade(trade) or nil
end

function TradeSystem:GetPlayerTrades(playerId: string): { Trade }
    local result: { Trade } = {}
    for _, trade in pairs(self._trades) do
        if trade.playerA == playerId or trade.playerB == playerId then
            if trade.state ~= "completed" and trade.state ~= "cancelled" then
                table.insert(result, _deepCopyTrade(trade))
            end
        end
    end
    return result
end

function TradeSystem:GetActiveTradeFor(playerId: string): string?
    return self._activePlayers[playerId] or nil
end

-- ---------------------------------------------------------------------------
-- Internal: execute atomic swap
-- ---------------------------------------------------------------------------

function TradeSystem:_executeTrade(tradeId: string)
    local trade = self._trades[tradeId]
    if not trade or trade.state ~= "confirmed" then return end

    -- Re-validate both offers before moving anything
    local okA = self:_validateOffer(trade.offerA, trade.playerA)
    local okB = self:_validateOffer(trade.offerB, trade.playerB)

    if not okA or not okB then
        trade.state = "cancelled"
        if trade.timerId then
            self._timer:StopTimer(trade.timerId)
            trade.timerId = nil
        end
        self._eventBus:Emit("TradeCancelled", {
            tradeId  = tradeId,
            reason   = "validation_failed",
            oldState = "confirmed",
        })
        return
    end

    -- Atomic deduct then grant
    self:_deductOffer(trade.offerA, trade.playerA)
    self:_deductOffer(trade.offerB, trade.playerB)
    self:_grantOffer(trade.offerA, trade.playerB)
    self:_grantOffer(trade.offerB, trade.playerA)

    trade.state = "completed"
    if trade.timerId then
        self._timer:StopTimer(trade.timerId)
        trade.timerId = nil
    end

    self._activePlayers[trade.playerA] = nil
    self._activePlayers[trade.playerB] = nil

    self._eventBus:Emit("TradeCompleted", {
        tradeId = tradeId,
        playerA = trade.playerA,
        playerB = trade.playerB,
        offerA  = { items = trade.offerA.items, bucks = trade.offerA.bucks },
        offerB  = { items = trade.offerB.items, bucks = trade.offerB.bucks },
    })
end

function TradeSystem:_validateOffer(offer: TradeOffer, playerId: string): boolean
    if offer.bucks > 0 then
        if not self._currency:CanAfford(BUCKS_CURRENCY_ID, offer.bucks) then
            return false
        end
    end
    for _, slot in ipairs(offer.items) do
        if not self:_playerHasItem(playerId, slot.itemId, slot.quantity) then
            return false
        end
    end
    return true
end

function TradeSystem:_deductOffer(offer: TradeOffer, playerId: string)
    if offer.bucks > 0 then
        self._currency:Subtract(BUCKS_CURRENCY_ID, offer.bucks, "trade_deduct_" .. playerId)
    end
    for _, slot in ipairs(offer.items) do
        self._inventory:RemoveItem(slot.itemId, slot.quantity)
    end
end

function TradeSystem:_grantOffer(offer: TradeOffer, playerId: string)
    if offer.bucks > 0 then
        self._currency:Add(BUCKS_CURRENCY_ID, offer.bucks, "trade_grant_" .. playerId)
    end
    for _, slot in ipairs(offer.items) do
        self._inventory:AddItem(slot.itemId, slot.quantity)
    end
end

-- NOTE: In a single-player deployment the injected inventory belongs to
-- one player so playerId is informational only. In a multi-player setup
-- inject per-player inventories via _inventoryMap = { [playerId]: Inventory }.
function TradeSystem:_playerHasItem(playerId: string, itemId: string, quantity: number): boolean
    local inv = (self._inventoryMap and self._inventoryMap[playerId]) or self._inventory
    if inv.GetItemQuantity then
        return inv:GetItemQuantity(itemId) >= quantity
    end
    local slots = inv:GetAllSlots()
    local total = 0
    for _, slot in ipairs(slots) do
        if slot.itemId == itemId then
            total += slot.quantity
        end
    end
    return total >= quantity
end

function TradeSystem:_onTimeout(tradeId: string)
    local trade = self._trades[tradeId]
    if not trade then return end
    if trade.state == "completed" or trade.state == "cancelled" then return end
    local oldState = trade.state
    trade.state   = "cancelled"
    trade.timerId = nil
    self._activePlayers[trade.playerA] = nil
    self._activePlayers[trade.playerB] = nil
    self._eventBus:Emit("TradeCancelled", {
        tradeId  = tradeId,
        reason   = "timeout",
        oldState = oldState,
    })
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------

function TradeSystem:Destroy()
    for _, trade in pairs(self._trades) do
        if trade.timerId then
            self._timer:StopTimer(trade.timerId)
        end
    end
    table.clear(self._trades)
end

return TradeSystem
