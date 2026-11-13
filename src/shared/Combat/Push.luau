--!strict
--[[
	Push: knockback that survives Humanoid movement control.

	Setting AssemblyLinearVelocity once is cancelled within a frame or two by
	the Humanoid's own walking. A short LinearVelocity holds the push for
	`duration`, then the body carries on ballistically. Call it where the body
	is simulated: the owning client for player characters (CombatKnockback),
	the server for NPCs.
]]

local Debris = game:GetService("Debris")

local Push = {}

Push.DURATION = 0.18

function Push.apply(root: BasePart, velocity: Vector3, duration: number?)
	local existing = root:FindFirstChild("CombatPush")
	if existing then
		existing:Destroy()
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "CombatPush"
	local mover = Instance.new("LinearVelocity")
	mover.Attachment0 = attachment
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	mover.MaxForce = math.huge
	mover.VectorVelocity = velocity
	mover.Parent = attachment
	attachment.Parent = root
	Debris:AddItem(attachment, duration or Push.DURATION)
end

return Push
