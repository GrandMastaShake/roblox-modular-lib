--!strict
-- Physics.lua
-- Helpers: knockback, projectiles, raycast ground check.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local EventBus = require(script.Parent.Core.EventBus)

local Physics = {}
Physics.__index = Physics

export type Physics = {
	Knockback: (self: Physics, target: BasePart, direction: Vector3, force: number, duration: number) -> (),
	LaunchProjectile: (self: Physics, origin: Vector3, direction: Vector3, speed: number, onHit: (BasePart) -> ()) -> Part,
	IsGrounded: (self: Physics, part: BasePart, distance: number?) -> boolean,
	ApplyForce: (self: Physics, part: BasePart, force: Vector3, duration: number) -> (),

	_eventBus: EventBus.EventBus,
	_projectiles: { [Part]: boolean },
	_connections: { RBXScriptConnection },
}

function Physics.new(eventBus: EventBus.EventBus): Physics
	local self = setmetatable({}, Physics) :: Physics
	self._eventBus = eventBus
	self._projectiles = {}
	self._connections = {}
	return self
end

function Physics:Knockback(target: BasePart, direction: Vector3, force: number, duration: number)
	if not target or not target:IsA("BasePart") then
		return
	end

	local unitDir = if direction.Magnitude > 0 then direction.Unit else Vector3.new(0, 0, -1)

	-- Use BodyVelocity for temporary knockback (simplest temporary velocity override)
	local bv = Instance.new("BodyVelocity")
	bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	bv.Velocity = unitDir * force
	bv.Parent = target

	self._eventBus:Emit("KnockbackApplied", {
		target = target,
		direction = unitDir,
		force = force,
		duration = duration,
	})

	task.delay(duration, function()
		if bv then
			bv:Destroy()
		end
	end)
end

function Physics:LaunchProjectile(
	origin: Vector3,
	direction: Vector3,
	speed: number,
	onHit: (BasePart) -> ()
): Part
	local unitDir = if direction.Magnitude > 0 then direction.Unit else Vector3.new(0, 0, -1)

	local projectile = Instance.new("Part")
	projectile.Name = "Projectile"
	projectile.Shape = Enum.PartType.Ball
	projectile.Size = Vector3.new(1, 1, 1)
	projectile.Position = origin
	projectile.Anchored = false
	projectile.CanCollide = true
	projectile.Material = Enum.Material.Neon
	projectile.BrickColor = BrickColor.new("Bright red")
	projectile.Parent = Workspace

	-- Apply direct linear velocity (simplest projectile motion)
	projectile.AssemblyLinearVelocity = unitDir * speed

	self._projectiles[projectile] = true

	self._eventBus:Emit("ProjectileLaunched", {
		projectile = projectile,
		origin = origin,
		direction = unitDir,
		speed = speed,
	})

	local connection: RBXScriptConnection? = nil
	connection = projectile.Touched:Connect(function(hit: BasePart)
		if not self._projectiles[projectile] then
			return
		end

		-- Ignore hitting the projectile itself or descendants
		if hit:IsDescendantOf(projectile) then
			return
		end

		self._eventBus:Emit("ProjectileHit", {
			projectile = projectile,
			hit = hit,
			position = projectile.Position,
		})

		if onHit then
			onHit(hit)
		end

		self._projectiles[projectile] = nil
		if connection then
			connection:Disconnect()
		end
		projectile:Destroy()
	end)

	-- Fallback cleanup: destroy projectile after 10 seconds if it never hits
	task.delay(10, function()
		if self._projectiles[projectile] then
			self._projectiles[projectile] = nil
			if connection then
				connection:Disconnect()
			end
			if projectile.Parent then
				projectile:Destroy()
			end
		end
	end)

	return projectile
end

function Physics:IsGrounded(part: BasePart, distance: number?): boolean
	if not part then
		return false
	end

	local checkDistance: number = distance or 3
	local size = part.Size
	local bottomCenter = part.Position - Vector3.new(0, size.Y / 2, 0)
	local rayOrigin = bottomCenter + Vector3.new(0, 0.1, 0) -- start slightly above bottom face
	local rayDirection = Vector3.new(0, -checkDistance, 0)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = { part }
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	local result = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	return result ~= nil
end

function Physics:ApplyForce(part: BasePart, force: Vector3, duration: number)
	if not part or not part:IsA("BasePart") then
		return
	end

	-- Use VectorForce with a temporary attachment for a time-limited impulse feel
	local attachment = Instance.new("Attachment")
	attachment.Name = "PhysicsForceAttachment"
	attachment.Parent = part

	local vectorForce = Instance.new("VectorForce")
	vectorForce.Force = force
	vectorForce.ApplyAtCenterOfMass = true
	vectorForce.Attachment0 = attachment
	vectorForce.Parent = part

	-- Enable force
	vectorForce.Enabled = true

	-- Clean up after duration
	task.delay(duration, function()
		if vectorForce then
			vectorForce:Destroy()
		end
		if attachment then
			attachment:Destroy()
		end
	end)
end

-- Disconnect any tracked connections, destroy any in-flight projectiles
-- still in play, and clear state. Knockback / ApplyForce use task.delay
-- with self-contained cleanup, so they finish on their own — we don't
-- track them and don't try to cancel.
function Physics:Destroy()
	for _, conn in ipairs(self._connections) do
		if conn and conn.Connected then
			conn:Disconnect()
		end
	end
	self._connections = {}
	for projectile in pairs(self._projectiles) do
		if projectile and projectile.Parent then
			projectile:Destroy()
		end
	end
	self._projectiles = {}
end

return Physics
