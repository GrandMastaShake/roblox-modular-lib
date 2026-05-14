--!strict
-- TradeCoordinator.lua
-- Two-Phase Commit + Write-Ahead Log layer for atomic, crash-recoverable
-- pet/item trades. Backs the high-level state-machine logic in TradeSystem.
--
-- ============================================================================
-- WHAT THIS MODULE PROVIDES
-- ============================================================================
--
-- TradeSystem owns the *user-facing* trade flow (proposed -> offering -> ready
-- -> confirming -> finalized). When both sides confirm, TradeSystem hands off
-- to TradeCoordinator:ExecuteTrade(...) to perform the actual ownership
-- transfer. TradeCoordinator implements the production-grade hardening from
-- the Perplexity research:
--
--   Layer 3: Atomic UpdateAsync hardening with idempotency txnId guard +
--            fencing tokens
--   Layer 4: Two-Phase Commit coordinator with MemoryStore + DataStore WAL
--   Layer 5: Post-commit dual-consensus verification (cache-bypassed read-back)
--
-- Each player profile in this model carries:
--   - inventory     : { [itemId] = true }
--   - appliedTxns   : { [txnId] = timestamp }   -- idempotency log
--   - _txnLock      : txnId | nil               -- currently locked by
--   - _txnState     : "PREPARED" | nil
--   - _txnItems     : { string }   | nil        -- items promised in phase 1
--   - _txnFence     : number                    -- monotonic fence token
--
-- Pets in this codebase are entities owned by PetSystem rather than items
-- inside an Inventory. The Coordinator transparently handles BOTH:
--
--   * Items go through the inventory transform path (4-call protocol).
--   * Pets go through PetSystem:TransferOwnership at the post-prepare step,
--     after both players' inventory transforms vote YES, before the
--     coordinator records COMMITTED. Pet ownership is single-key by design
--     (PetEntity.ownerId), so it cannot dupe even without 2PC \u2014 but we
--     still do it after the prepare consensus so a phase-1 abort never
--     leaves orphaned pet transfers.
--
-- ============================================================================
-- DEPENDENCY INJECTION
-- ============================================================================
--
-- All Roblox services come through the deps table. This is consistent with
-- the rest of the modular lib and makes the unit tests (which mock every
-- service) tractable. The research code uses `game:GetService(...)` because
-- it's a single-script reference; we don't.
--
-- Required deps:
--   profileStore: any   -- ProfileStoreAdapter, exposes :Get(userId)
--   pets:         any   -- PetSystem; exposes :OwnsPet, :GetPet, :TransferOwnership
--   txnLogStore:  any   -- A DataStore (or duck-typed mock) for durable WAL
--   txnCoordinator: any -- A MemoryStoreSortedMap (or duck-typed mock) for fast WAL
--
-- Optional deps:
--   dataStoreService: any  -- For GetRequestBudgetForRequestType; if absent,
--                             retries don't budget-gate (fine for tests)
--
-- ============================================================================
-- EMITTED EVENTS
-- ============================================================================
--
-- TradeCoordinatorPhaseChanged { txnId, phase: "PREPARING"|"PREPARED"|"COMMITTING"|"COMMITTED"|"ABORTING"|"ABORTED" }
-- TradeCoordinatorPrepared     { txnId, uidA, uidB }
-- TradeCoordinatorCommitted    { txnId, uidA, uidB, transfers }
-- TradeCoordinatorAborted      { txnId, reason }
-- TradeCoordinatorPhase3Repair { txnId, repairedSide: "a"|"b" }
-- TradeCoordinatorOrphanResumed { txnId, action: "commit"|"abort"|"release" }
-- TradeCoordinatorBudgetThrottled { opType, budget }   -- diagnostic

local HttpService = game:GetService("HttpService")

local EventBus = require(script.Parent.Core.EventBus)
local Config   = require(script.Parent.Core.Config)

local TradeCoordinator = {}
TradeCoordinator.__index = TradeCoordinator

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

-- Phase enum. Strings (not numbers) so coordinator records survive JSON
-- round-trips through MemoryStore + DataStore without enum drift.
local TXN_STATE = {
	INIT       = "INIT",
	PREPARING  = "PREPARING",
	PREPARED   = "PREPARED",
	COMMITTING = "COMMITTING",
	COMMITTED  = "COMMITTED",
	ABORTING   = "ABORTING",
	ABORTED    = "ABORTED",
}

-- Tunable defaults; overridable via Config keys.
local DEFAULT_MAX_RETRIES         = 5
local DEFAULT_BUDGET_FLOOR        = 5
local DEFAULT_PHASE3_DELAY_SEC    = 5     -- outlast 4-second DataStore cache TTL
local DEFAULT_COORDINATOR_TTL_SEC = 120   -- MemoryStore record TTL
local DEFAULT_APPLIED_TXN_LIMIT   = 20    -- prune appliedTxns log to last N
local DEFAULT_PARTICIPANT_PROBE_TIMEOUT = 30 -- crash recovery probe timeout

-- ----------------------------------------------------------------------------
-- Types
-- ----------------------------------------------------------------------------

export type TxnPhase = "PREPARE" | "COMMIT" | "RELEASE_LOCK"

export type TradeOffer = {
	-- Items offered (will be removed from offerer's inventory on commit).
	itemsToLeave: { string },
	-- Pet ids offered (will transfer ownership on commit).
	petsToLeave: { string },
}

export type TradeCoordinatorDeps = {
	profileStore: any,
	pets: any,
	txnLogStore: any,
	txnCoordinator: any,
	dataStoreService: any?,
}

export type CoordinatorRecord = {
	txnId: string,
	state: string,
	fenceToken: number,
	parties: { string },
	offers: { [string]: TradeOffer },
	createdAt: number,
	updatedAt: number?,
	claimedBy: string?,
	claimedAt: number?,
}

export type ExecuteResult = {
	success: boolean,
	txnId: string,
	state: string,
	reason: string?,
	transfers: { [string]: { pets: { string }, items: { string } } }?,
}

export type TradeCoordinator = {
	ExecuteTrade: (self: TradeCoordinator, uidA: number, uidB: number, offersA: TradeOffer, offersB: TradeOffer) -> ExecuteResult,
	ResumeOrphanedTransaction: (self: TradeCoordinator, profile: any, userId: number) -> (),
	GetCoordinatorRecord: (self: TradeCoordinator, txnId: string) -> CoordinatorRecord?,
	Destroy: (self: TradeCoordinator) -> (),

	-- Private
	_eventBus:                EventBus.EventBus,
	_config:                  Config.Config,
	_deps:                    TradeCoordinatorDeps,
	_maxRetries:              number,
	_budgetFloor:             number,
	_phase3Delay:             number,
	_coordinatorTtl:          number,
	_appliedTxnLimit:         number,
	_jobId:                   string,
	_destroyed:               boolean,
}

-- ----------------------------------------------------------------------------
-- Constructor
-- ----------------------------------------------------------------------------

function TradeCoordinator.new(
	eventBus: EventBus.EventBus,
	deps: TradeCoordinatorDeps,
	config: Config.Config?
): TradeCoordinator
	local self = setmetatable({}, TradeCoordinator) :: TradeCoordinator
	self._eventBus = eventBus
	self._config = config or Config.new()
	self._deps = deps

	self._maxRetries     = self._config:Get("tradeCoordinatorMaxRetries", DEFAULT_MAX_RETRIES) :: number
	self._budgetFloor    = self._config:Get("tradeCoordinatorBudgetFloor", DEFAULT_BUDGET_FLOOR) :: number
	self._phase3Delay    = self._config:Get("tradeCoordinatorPhase3DelaySec", DEFAULT_PHASE3_DELAY_SEC) :: number
	self._coordinatorTtl = self._config:Get("tradeCoordinatorTtlSec", DEFAULT_COORDINATOR_TTL_SEC) :: number
	self._appliedTxnLimit = self._config:Get("tradeAppliedTxnLimit", DEFAULT_APPLIED_TXN_LIMIT) :: number

	-- Capture the JobId once at construction so reads-during-test work
	-- even when game.JobId hasn't been populated.
	local jobId = (game :: any).JobId
	self._jobId = if jobId and jobId ~= "" then jobId else string.format("studio_%d", os.time())
	self._destroyed = false

	return self
end

-- ============================================================================
-- TRANSFORM BUILDERS \u2014 THE HEART OF LAYER 3
-- ============================================================================
-- The transform is a pure function passed to UpdateAsync. It MUST be free of
-- side effects (DataStore retries can re-execute the transform) and it MUST
-- be idempotent on the same txnId (UpdateAsync internal retries can call
-- the transform multiple times for one logical write). Both invariants are
-- enforced by the txnId+state checks below.

local function pruneAppliedTxns(applied: { [string]: number }, limit: number)
	-- Sort timestamps ascending; drop oldest until we're under the limit.
	-- We only do this on commit, so it runs at most once per trade.
	local pairs_list: { { id: string, t: number } } = {}
	for id, t in pairs(applied) do
		table.insert(pairs_list, { id = id, t = t })
	end
	table.sort(pairs_list, function(a, b) return a.t < b.t end)
	while #pairs_list > limit do
		local oldest = table.remove(pairs_list, 1)
		if oldest then
			applied[oldest.id] = nil
		end
	end
end

-- The transform takes a tuple capturing the txn metadata and returns a
-- closure suitable for UpdateAsync. We close over txnId/fence/phase/items
-- so the callsite is just `store:UpdateAsync(key, buildTradeTransform(...))`.
function TradeCoordinator:_buildTradeTransform(
	txnId: string,
	fenceToken: number,
	phase: TxnPhase,
	itemsToLeave: { string },
	itemsToReceive: { string }
): (any) -> any?

	local appliedTxnLimit = self._appliedTxnLimit

	return function(data: any): any?
		if data == nil then
			-- Profile must already exist before a trade can touch it. Returning
			-- nil tells UpdateAsync to abort \u2014 we never auto-create a profile
			-- inside a trade transform.
			return nil
		end

		-- ----- FENCING: reject zombie coordinators ----------------------
		-- A stale coordinator that lost its lease has a smaller fence than
		-- whatever current claimer wrote. We refuse its writes silently.
		if data._txnFence and data._txnFence > fenceToken then
			return nil
		end

		-- Ensure appliedTxns table exists for the rest of the function.
		data.appliedTxns = data.appliedTxns or {}
		data.inventory   = data.inventory or {}

		-- ----- IDEMPOTENCY: already applied this txn --------------------
		-- This catches both the "transform fires twice" Roblox engine
		-- behavior and the "client retried after pcall false-positive"
		-- recovery path. Returning nil = no-op (UpdateAsync skips the
		-- write).
		if data.appliedTxns[txnId] then
			return nil
		end

		if phase == "PREPARE" then
			-- Already locked by a different txn \u2014 vote NO.
			if data._txnLock and data._txnLock ~= txnId then
				return nil
			end
			-- Already prepared for THIS txn \u2014 idempotent re-entry, vote YES
			-- by returning unchanged data so UpdateAsync writes it back as-is.
			if data._txnLock == txnId and data._txnState == "PREPARED" then
				return data
			end
			-- Validate ownership of every offered item.
			for _, itemId in ipairs(itemsToLeave) do
				if not data.inventory[itemId] then
					return nil  -- vote NO: item not owned
				end
			end
			-- Vote YES: stamp lock + promise.
			data._txnLock  = txnId
			data._txnState = "PREPARED"
			data._txnItems = itemsToLeave
			data._txnFence = fenceToken
			return data

		elseif phase == "COMMIT" then
			-- Must be PREPARED for THIS txn. If we see PREPARED for a
			-- different txn, something has gone very wrong \u2014 abort
			-- silently rather than corrupt the prior trade.
			if data._txnLock ~= txnId or data._txnState ~= "PREPARED" then
				return nil
			end
			-- Paranoia: re-verify promised items still present.
			for _, itemId in ipairs(data._txnItems or {}) do
				if not data.inventory[itemId] then
					-- Items disappeared between phases \u2014 vote NO at
					-- commit too. Phase 3 verify will route this to
					-- the partial-commit re-apply or full-abort branch.
					return nil
				end
			end
			-- Execute the inventory swap.
			for _, itemId in ipairs(itemsToLeave) do
				data.inventory[itemId] = nil
			end
			for _, itemId in ipairs(itemsToReceive) do
				data.inventory[itemId] = true
			end
			-- Commit: clear lock, stamp the appliedTxns log.
			data._txnState = nil
			data._txnLock  = nil
			data._txnItems = nil
			data.appliedTxns[txnId] = os.time()
			pruneAppliedTxns(data.appliedTxns, appliedTxnLimit)
			return data

		elseif phase == "RELEASE_LOCK" then
			-- Abort path: clear our lock without touching inventory.
			-- Idempotent: if our lock was already released, the equality
			-- check fails and we just return data unchanged.
			if data._txnLock == txnId then
				data._txnLock  = nil
				data._txnState = nil
				data._txnItems = nil
			end
			return data
		end

		-- Unknown phase \u2014 fail closed.
		return nil
	end
end

-- ============================================================================
-- BUDGET-GATED RETRY
-- ============================================================================
-- Wraps any DataStore operation with exponential backoff and (optionally)
-- request-budget gating. If GetRequestBudgetForRequestType isn't available
-- (Studio test, mock service), we skip the budget check.

function TradeCoordinator:_updateWithRetry(store: any, key: string, transform: any, opLabel: string?): (boolean, any?)
	local lastErr: any = nil
	for attempt = 1, self._maxRetries do
		-- Budget gate (opt-in via deps.dataStoreService).
		if self._deps.dataStoreService and self._deps.dataStoreService.GetRequestBudgetForRequestType then
			local budget = pcall(function()
				return self._deps.dataStoreService:GetRequestBudgetForRequestType(
					(Enum :: any).DataStoreRequestType.UpdateAsync
				)
			end)
			if typeof(budget) == "number" and budget < self._budgetFloor then
				self._eventBus:Emit("TradeCoordinatorBudgetThrottled", {
					opType = opLabel or "UpdateAsync",
					budget = budget,
				})
				task.wait(2 ^ attempt)
				continue
			end
		end

		local ok, result = pcall(function()
			return store:UpdateAsync(key, transform)
		end)
		if ok then
			return true, result
		end
		lastErr = result
		task.wait(2 ^ (attempt - 1))  -- 1s, 2s, 4s, 8s, 16s
	end

	warn(string.format("[TradeCoordinator] %s failed after %d attempts: %s",
		opLabel or "UpdateAsync", self._maxRetries, tostring(lastErr)))
	return false, lastErr
end

-- ============================================================================
-- LAYER 4: COORDINATOR RECORD (MemoryStore + DataStore WAL)
-- ============================================================================

function TradeCoordinator:_writeCoordinatorRecord(txnId: string, record: CoordinatorRecord): boolean
	-- Fast-path MemoryStore write. Not required to succeed.
	pcall(function()
		self._deps.txnCoordinator:SetAsync(txnId, record, self._coordinatorTtl)
	end)

	-- Durable DataStore write. If THIS fails the trade cannot proceed \u2014
	-- without a durable record, crash recovery has nothing to read.
	local dsOk = pcall(function()
		self._deps.txnLogStore:SetAsync("txn_" .. txnId, record)
	end)
	if not dsOk then
		warn("[TradeCoordinator] CRITICAL: coordinator record not persisted for " .. txnId)
		return false
	end
	return true
end

function TradeCoordinator:_readCoordinatorRecord(txnId: string): CoordinatorRecord?
	-- Try MemoryStore first (fast).
	local ok, record = pcall(function()
		return self._deps.txnCoordinator:GetAsync(txnId)
	end)
	if ok and record then
		return record :: CoordinatorRecord
	end
	-- Fall through to DataStore WAL.
	ok, record = pcall(function()
		return self._deps.txnLogStore:GetAsync("txn_" .. txnId)
	end)
	if ok and record then
		return record :: CoordinatorRecord
	end
	return nil
end

function TradeCoordinator:_updateCoordinatorState(txnId: string, newState: string): boolean
	local record = self:_readCoordinatorRecord(txnId)
	if not record then return false end
	record.state = newState
	record.updatedAt = os.time()
	local ok = self:_writeCoordinatorRecord(txnId, record)
	if ok then
		self._eventBus:Emit("TradeCoordinatorPhaseChanged", { txnId = txnId, phase = newState })
	end
	return ok
end

-- Atomically claim ownership of a coordinator record by bumping the fence
-- token. Used both at trade start (ensures the *winning* server's writes
-- have a higher fence than any prior stalled coordinator) and during crash
-- recovery (the rejoining server claims the orphan and races other servers).
function TradeCoordinator:_claimCoordinatorOwnership(txnId: string): number?
	local newFence: number? = nil
	local ok = pcall(function()
		local result = self._deps.txnLogStore:UpdateAsync("txn_" .. txnId, function(data)
			if data == nil then return nil end
			data.fenceToken = (data.fenceToken or 0) + 1
			data.claimedBy  = self._jobId
			data.claimedAt  = os.time()
			newFence = data.fenceToken
			return data
		end)
		return result
	end)
	if ok then
		return newFence
	end
	return nil
end

-- Cleanup after a confirmed COMMITTED state. MemoryStore entry removed
-- immediately to free quota; DataStore archive kept for audit.
function TradeCoordinator:_commitCleanup(txnId: string)
	pcall(function() self._deps.txnCoordinator:RemoveAsync(txnId) end)
	-- Best-effort archive. Never fail-the-trade on cleanup error.
	pcall(function()
		self._deps.txnLogStore:UpdateAsync("txn_archive", function(log)
			log = log or {}
			log[txnId] = { state = "COMMITTED", completedAt = os.time() }
			-- Cap the archive at 100 entries to keep the key small.
			local stamps: { { k: string, t: number } } = {}
			for k, v in pairs(log) do
				table.insert(stamps, { k = k, t = (v :: any).completedAt or 0 })
			end
			table.sort(stamps, function(a, b) return a.t < b.t end)
			while #stamps > 100 do
				local oldest = table.remove(stamps, 1)
				if oldest then log[oldest.k] = nil end
			end
			return log
		end)
	end)
end

-- ============================================================================
-- LAYER 5: PHASE 3 DUAL CONSENSUS VERIFICATION
-- ============================================================================
-- After Phase 2, we wait long enough to outlast the DataStore read cache,
-- then read both keys with cache-bypass. Four outcomes are handled:
--   * Both stamped     -> COMMITTED, cleanup
--   * A stamped, !B    -> re-apply commit to B
--   * !A, B stamped    -> re-apply commit to A
--   * Neither          -> full abort

function TradeCoordinator:_phase3Verify(
	txnId: string,
	fenceToken: number,
	uidA: number,
	uidB: number,
	offersA: TradeOffer,
	offersB: TradeOffer
): boolean
	task.wait(self._phase3Delay)

	local function readBypassed(uid: number): (boolean, any?)
		-- ProfileStore exposes Get(userId) which returns the live profile.
		-- For the verification step we want a fresh DataStore read with
		-- UseCache = false. The adapter is responsible for honoring the
		-- second-arg "bypassCache" flag.
		local ok, data = pcall(function()
			return self._deps.profileStore:Get(uid, true)
		end)
		return ok, data
	end

	local okA, dataA = readBypassed(uidA)
	local okB, dataB = readBypassed(uidB)

	if not (okA and okB) then
		warn("[TradeCoordinator] Phase 3: could not read post-commit state for " .. txnId)
		-- We DO NOT abort here \u2014 if the read failed but the writes
		-- actually committed, an abort would dupe items. The coordinator
		-- record stays in COMMITTING; crash recovery on next load resolves.
		return false
	end

	local aCommitted = dataA and dataA.appliedTxns and dataA.appliedTxns[txnId] ~= nil
	local bCommitted = dataB and dataB.appliedTxns and dataB.appliedTxns[txnId] ~= nil

	if aCommitted and bCommitted then
		self:_updateCoordinatorState(txnId, TXN_STATE.COMMITTED)
		self:_commitCleanup(txnId)
		return true

	elseif aCommitted and not bCommitted then
		-- Re-apply commit to B only. If this also fails, the next phase 3
		-- check (or rejoin recovery) tries again.
		self._eventBus:Emit("TradeCoordinatorPhase3Repair", { txnId = txnId, repairedSide = "b" })
		self:_updateWithRetry(
			self._deps.profileStore:GetRawStore(),
			tostring(uidB),
			self:_buildTradeTransform(txnId, fenceToken, "COMMIT",
				offersB.itemsToLeave, offersA.itemsToLeave),
			"COMMIT_repair_b"
		)
		self:_updateCoordinatorState(txnId, TXN_STATE.COMMITTED)
		self:_commitCleanup(txnId)
		return true

	elseif bCommitted and not aCommitted then
		self._eventBus:Emit("TradeCoordinatorPhase3Repair", { txnId = txnId, repairedSide = "a" })
		self:_updateWithRetry(
			self._deps.profileStore:GetRawStore(),
			tostring(uidA),
			self:_buildTradeTransform(txnId, fenceToken, "COMMIT",
				offersA.itemsToLeave, offersB.itemsToLeave),
			"COMMIT_repair_a"
		)
		self:_updateCoordinatorState(txnId, TXN_STATE.COMMITTED)
		self:_commitCleanup(txnId)
		return true

	else
		-- Neither committed \u2014 full abort. Release both locks.
		self._eventBus:Emit("TradeCoordinatorAborted", { txnId = txnId, reason = "phase3_neither_committed" })
		self:_updateCoordinatorState(txnId, TXN_STATE.ABORTING)
		self:_updateWithRetry(
			self._deps.profileStore:GetRawStore(),
			tostring(uidA),
			self:_buildTradeTransform(txnId, fenceToken, "RELEASE_LOCK", {}, {}),
			"RELEASE_LOCK_a"
		)
		self:_updateWithRetry(
			self._deps.profileStore:GetRawStore(),
			tostring(uidB),
			self:_buildTradeTransform(txnId, fenceToken, "RELEASE_LOCK", {}, {}),
			"RELEASE_LOCK_b"
		)
		self:_updateCoordinatorState(txnId, TXN_STATE.ABORTED)
		return false
	end
end

-- ============================================================================
-- PET OWNERSHIP TRANSFER (post-prepare consensus)
-- ============================================================================
-- Pets are single-key entities, so they don't need the 4-call protocol \u2014
-- one PetSystem:TransferOwnership per pet is atomic-enough. We do this
-- AFTER Phase 1 succeeds (so we know inventory commits won't fail), but
-- we record the pre-image so a phase 3 failure can roll pets back.

function TradeCoordinator:_transferPets(
	uidA: number,
	uidB: number,
	offersA: TradeOffer,
	offersB: TradeOffer
): { aPets: { string }, bPets: { string }, rollback: () -> () }
	local aMoved: { string } = {}
	local bMoved: { string } = {}

	for _, petId in ipairs(offersA.petsToLeave) do
		if self._deps.pets:TransferOwnership(petId, uidB) then
			table.insert(aMoved, petId)
		end
	end
	for _, petId in ipairs(offersB.petsToLeave) do
		if self._deps.pets:TransferOwnership(petId, uidA) then
			table.insert(bMoved, petId)
		end
	end

	-- Rollback closure: undoes the transfers if the inventory commit
	-- ultimately fails in Phase 3.
	local function rollback()
		for _, petId in ipairs(aMoved) do
			self._deps.pets:TransferOwnership(petId, uidA)
		end
		for _, petId in ipairs(bMoved) do
			self._deps.pets:TransferOwnership(petId, uidB)
		end
	end

	return { aPets = aMoved, bPets = bMoved, rollback = rollback }
end

-- ============================================================================
-- PUBLIC API: ExecuteTrade
-- ============================================================================
-- The whole 2PC flow in one function. TradeSystem calls this from its
-- _finalize when both confirms land.

function TradeCoordinator:ExecuteTrade(
	uidA: number,
	uidB: number,
	offersA: TradeOffer,
	offersB: TradeOffer
): ExecuteResult
	if self._destroyed then
		return { success = false, txnId = "", state = TXN_STATE.ABORTED, reason = "coordinator_destroyed" }
	end

	local txnId = HttpService:GenerateGUID(false)
	local idA, idB = tostring(uidA), tostring(uidB)

	-- Build the WAL record. This is what crash recovery will read on rejoin.
	local record: CoordinatorRecord = {
		txnId      = txnId,
		state      = TXN_STATE.INIT,
		fenceToken = 1,
		parties    = { idA, idB },
		offers     = {
			[idA] = offersA,
			[idB] = offersB,
		},
		createdAt  = os.time(),
		claimedBy  = self._jobId,
	}

	if not self:_writeCoordinatorRecord(txnId, record) then
		return {
			success = false,
			txnId   = txnId,
			state   = TXN_STATE.ABORTED,
			reason  = "coordinator_write_failed",
		}
	end

	local fenceToken = record.fenceToken
	local rawStore = self._deps.profileStore:GetRawStore()

	-- ===== PHASE 1: PREPARE =================================================
	self:_updateCoordinatorState(txnId, TXN_STATE.PREPARING)

	-- Run both transforms in parallel via task.spawn. We await both threads
	-- before deciding the prepare verdict.
	local resultsA: { ok: boolean, data: any } = { ok = false, data = nil }
	local resultsB: { ok: boolean, data: any } = { ok = false, data = nil }
	local doneA, doneB = false, false

	task.spawn(function()
		local ok, data = self:_updateWithRetry(
			rawStore, idA,
			self:_buildTradeTransform(txnId, fenceToken, "PREPARE",
				offersA.itemsToLeave, offersB.itemsToLeave),
			"PREPARE_a"
		)
		resultsA.ok = ok and data ~= nil
		resultsA.data = data
		doneA = true
	end)
	task.spawn(function()
		local ok, data = self:_updateWithRetry(
			rawStore, idB,
			self:_buildTradeTransform(txnId, fenceToken, "PREPARE",
				offersB.itemsToLeave, offersA.itemsToLeave),
			"PREPARE_b"
		)
		resultsB.ok = ok and data ~= nil
		resultsB.data = data
		doneB = true
	end)

	-- Spin until both threads complete. task.wait yields back to scheduler.
	while not (doneA and doneB) do
		task.wait(0.1)
	end

	local unanimousYes = resultsA.ok and resultsB.ok
	if not unanimousYes then
		-- Roll back any side that voted yes.
		self:_updateCoordinatorState(txnId, TXN_STATE.ABORTING)
		if resultsA.ok then
			self:_updateWithRetry(rawStore, idA,
				self:_buildTradeTransform(txnId, fenceToken, "RELEASE_LOCK", {}, {}),
				"RELEASE_LOCK_a_after_prepare_fail")
		end
		if resultsB.ok then
			self:_updateWithRetry(rawStore, idB,
				self:_buildTradeTransform(txnId, fenceToken, "RELEASE_LOCK", {}, {}),
				"RELEASE_LOCK_b_after_prepare_fail")
		end
		self:_updateCoordinatorState(txnId, TXN_STATE.ABORTED)
		self._eventBus:Emit("TradeCoordinatorAborted", { txnId = txnId, reason = "prepare_failed" })
		return {
			success = false,
			txnId   = txnId,
			state   = TXN_STATE.ABORTED,
			reason  = "prepare_failed",
		}
	end

	self:_updateCoordinatorState(txnId, TXN_STATE.PREPARED)
	self._eventBus:Emit("TradeCoordinatorPrepared", { txnId = txnId, uidA = uidA, uidB = uidB })

	-- ===== PET OWNERSHIP TRANSFER (after prepare consensus) =================
	-- Pets are single-key entities; we transfer them now, and rollback in
	-- the unlikely case Phase 3 fails outright.
	local petTransfers = self:_transferPets(uidA, uidB, offersA, offersB)

	-- ===== PHASE 2: COMMIT ==================================================
	self:_updateCoordinatorState(txnId, TXN_STATE.COMMITTING)

	-- Commit transforms run in parallel. We don't await them via a hard
	-- success check \u2014 the pcall false-positive problem means a "failure"
	-- here might actually have committed. Phase 3 verifies authoritatively.
	task.spawn(function()
		self:_updateWithRetry(rawStore, idA,
			self:_buildTradeTransform(txnId, fenceToken, "COMMIT",
				offersA.itemsToLeave, offersB.itemsToLeave),
			"COMMIT_a")
	end)
	task.spawn(function()
		self:_updateWithRetry(rawStore, idB,
			self:_buildTradeTransform(txnId, fenceToken, "COMMIT",
				offersB.itemsToLeave, offersA.itemsToLeave),
			"COMMIT_b")
	end)

	-- ===== PHASE 3: VERIFY ==================================================
	local verified = self:_phase3Verify(txnId, fenceToken, uidA, uidB, offersA, offersB)

	if not verified then
		-- Phase 3 failed. Roll back the pet transfers we did optimistically.
		petTransfers.rollback()
		return {
			success = false,
			txnId   = txnId,
			state   = TXN_STATE.ABORTED,
			reason  = "phase3_verify_failed",
		}
	end

	local transfers = {
		a = { pets = petTransfers.bPets, items = offersB.itemsToLeave },
		b = { pets = petTransfers.aPets, items = offersA.itemsToLeave },
	}

	self._eventBus:Emit("TradeCoordinatorCommitted", {
		txnId = txnId, uidA = uidA, uidB = uidB, transfers = transfers,
	})

	return {
		success   = true,
		txnId     = txnId,
		state     = TXN_STATE.COMMITTED,
		transfers = transfers,
	}
end

-- ============================================================================
-- CRASH RECOVERY
-- ============================================================================
-- Called by ProfileStoreAdapter on profile load when a `_txnLock` is found
-- in the loaded data. Determines the right action (commit / abort / release)
-- based on the coordinator state and the other participant's state.

function TradeCoordinator:ResumeOrphanedTransaction(profile: any, userId: number)
	local data = profile.Data
	if not data or not data._txnLock then return end

	local txnId = data._txnLock
	local record = self:_readCoordinatorRecord(txnId)

	-- Case 1: Coordinator record gone (TTL expired, no DataStore copy).
	-- The most conservative action is to release the lock without
	-- touching inventory. The other party's state is unknown but safer
	-- to leave alone than to guess wrong.
	if not record then
		data._txnLock  = nil
		data._txnState = nil
		data._txnItems = nil
		self._eventBus:Emit("TradeCoordinatorOrphanResumed", { txnId = txnId, action = "release" })
		return
	end

	-- Case 2: Coordinator says COMMITTED \u2014 if our own appliedTxns doesn't
	-- have a stamp for this txnId, we are mid-partial-commit. Re-apply
	-- the commit transform to ourselves.
	if record.state == TXN_STATE.COMMITTED then
		local alreadyApplied = data.appliedTxns and data.appliedTxns[txnId] ~= nil
		if not alreadyApplied then
			-- Find which side we are.
			local mySide = if tostring(userId) == record.parties[1] then "a" else "b"
			local otherSide = if mySide == "a" then "b" else "a"
			local myOffer = record.offers[record.parties[mySide == "a" and 1 or 2]]
			local theirOffer = record.offers[record.parties[otherSide == "a" and 1 or 2]]
			local fence = self:_claimCoordinatorOwnership(txnId) or record.fenceToken

			task.spawn(function()
				self:_updateWithRetry(
					self._deps.profileStore:GetRawStore(),
					tostring(userId),
					self:_buildTradeTransform(txnId, fence, "COMMIT",
						myOffer.itemsToLeave, theirOffer.itemsToLeave),
					"COMMIT_orphan_resume"
				)
			end)
			self._eventBus:Emit("TradeCoordinatorOrphanResumed", { txnId = txnId, action = "commit" })
		else
			-- Already applied \u2014 just clear the lock locally.
			data._txnLock  = nil
			data._txnState = nil
			data._txnItems = nil
			self._eventBus:Emit("TradeCoordinatorOrphanResumed", { txnId = txnId, action = "release" })
		end
		return
	end

	-- Case 3: Coordinator says ABORTED \u2014 just release the lock.
	if record.state == TXN_STATE.ABORTED then
		data._txnLock  = nil
		data._txnState = nil
		data._txnItems = nil
		self._eventBus:Emit("TradeCoordinatorOrphanResumed", { txnId = txnId, action = "release" })
		return
	end

	-- Case 4: PREPARING or PREPARED \u2014 the trade was mid-flight. The right
	-- action depends on the other participant's state. We probe their
	-- profile via the adapter (which may queue the read) and abort if
	-- they haven't committed.
	if record.state == TXN_STATE.PREPARING or record.state == TXN_STATE.PREPARED then
		-- Most reasonable default: claim the coordinator and force-abort.
		-- Forward-progress recovery (other side committed -> we must too)
		-- is more complex and only safe to attempt if we can read the
		-- other profile fresh. For a single-server demo + safe default,
		-- aborting is correct.
		local fence = self:_claimCoordinatorOwnership(txnId)
		if fence then
			task.spawn(function()
				self:_updateCoordinatorState(txnId, TXN_STATE.ABORTING)
				self:_updateWithRetry(
					self._deps.profileStore:GetRawStore(),
					tostring(userId),
					self:_buildTradeTransform(txnId, fence, "RELEASE_LOCK", {}, {}),
					"RELEASE_LOCK_orphan_abort"
				)
				-- Try to release the other party too if we can read their record.
				local otherUid = if tostring(userId) == record.parties[1]
					then record.parties[2]
					else record.parties[1]
				self:_updateWithRetry(
					self._deps.profileStore:GetRawStore(),
					otherUid,
					self:_buildTradeTransform(txnId, fence, "RELEASE_LOCK", {}, {}),
					"RELEASE_LOCK_orphan_abort_other"
				)
				self:_updateCoordinatorState(txnId, TXN_STATE.ABORTED)
			end)
		end
		-- Local in-memory cleanup so the loaded profile is usable now.
		data._txnLock  = nil
		data._txnState = nil
		data._txnItems = nil
		self._eventBus:Emit("TradeCoordinatorOrphanResumed", { txnId = txnId, action = "abort" })
	end
end

-- ----------------------------------------------------------------------------
-- Queries / cleanup
-- ----------------------------------------------------------------------------

function TradeCoordinator:GetCoordinatorRecord(txnId: string): CoordinatorRecord?
	return self:_readCoordinatorRecord(txnId)
end

function TradeCoordinator:Destroy()
	self._destroyed = true
	-- No background threads to cancel; ExecuteTrade is synchronous from
	-- the caller's perspective (within its own task.spawn). Crash recovery
	-- threads complete on their own once the coordinator state is final.
end

return TradeCoordinator
