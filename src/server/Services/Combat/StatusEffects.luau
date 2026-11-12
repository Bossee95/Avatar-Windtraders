--!strict
--[[
	Movement-impairing status on any Humanoid (players and NPCs).

	"Stun" cancels the target's windups and blocks actions and weapon
	switching. "Root" only stops movement (used by self effects such as
	aiming a long shot). Movement is restored when every effect on the
	humanoid has expired. The current state is mirrored to the attributes
	CombatStunned / CombatRooted on the character so clients and other
	systems can read it.
]]

local StatusEffects = {}

type Entry = {
	stunUntil: number,
	rootUntil: number,
	walkSpeed: number,
	jumpPower: number,
	jumpHeight: number,
}

local entries: { [Humanoid]: Entry } = {}

local function refresh(humanoid: Humanoid)
	local entry = entries[humanoid]
	if not entry then
		return
	end
	local now = os.clock()
	local stunned = now < entry.stunUntil
	local rooted = now < entry.rootUntil
	local model = humanoid.Parent
	if model then
		model:SetAttribute("CombatStunned", stunned or nil)
		model:SetAttribute("CombatRooted", rooted or nil)
	end
	if not stunned and not rooted then
		entries[humanoid] = nil
		if humanoid.Parent then
			humanoid.WalkSpeed = entry.walkSpeed
			humanoid.JumpPower = entry.jumpPower
			humanoid.JumpHeight = entry.jumpHeight
		end
	end
end

local function apply(humanoid: Humanoid, field: "stunUntil" | "rootUntil", duration: number)
	if duration <= 0 then
		return
	end
	local entry = entries[humanoid]
	if not entry then
		entry = {
			stunUntil = 0,
			rootUntil = 0,
			walkSpeed = humanoid.WalkSpeed,
			jumpPower = humanoid.JumpPower,
			jumpHeight = humanoid.JumpHeight,
		}
		entries[humanoid] = entry
	end
	local untilTime = os.clock() + duration
	if untilTime > entry[field] then
		entry[field] = untilTime
	end
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	refresh(humanoid)
	task.delay(duration + 0.01, refresh, humanoid)
end

function StatusEffects.stun(humanoid: Humanoid, duration: number)
	apply(humanoid, "stunUntil", duration)
end

function StatusEffects.root(humanoid: Humanoid, duration: number)
	apply(humanoid, "rootUntil", duration)
end

function StatusEffects.isStunned(humanoid: Humanoid?): boolean
	if not humanoid then
		return false
	end
	local entry = entries[humanoid]
	return entry ~= nil and os.clock() < entry.stunUntil
end

function StatusEffects.clear(humanoid: Humanoid)
	local entry = entries[humanoid]
	if entry then
		entry.stunUntil = 0
		entry.rootUntil = 0
		refresh(humanoid)
	end
end

return StatusEffects
