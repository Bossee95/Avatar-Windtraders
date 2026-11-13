--!strict
--[[
	Movement-impairing status on any Humanoid (players and NPCs).

	"Stun" cancels the target's windups, blocks actions and weapon switching,
	and stops movement. "Stagger" (hit stun) does the same to actions but
	leaves movement alone, so a struck player can still walk away (GDD 6A.5:
	the combat tag never stops movement). "Root" only stops movement (used by
	self effects such as aiming a long shot). Movement is restored when every
	movement effect on the humanoid has expired. The current state is
	mirrored to the attributes CombatStunned / CombatRooted on the character
	so clients and other systems can read it.
]]

local StatusEffects = {}

type Entry = {
	stunUntil: number,
	staggerUntil: number,
	rootUntil: number,
	frozen: boolean,
	walkSpeed: number,
	jumpPower: number,
	jumpHeight: number,
}

type Field = "stunUntil" | "staggerUntil" | "rootUntil"

local entries: { [Humanoid]: Entry } = {}

local function refresh(humanoid: Humanoid)
	local entry = entries[humanoid]
	if not entry then
		return
	end
	local now = os.clock()
	local stunned = now < entry.stunUntil or now < entry.staggerUntil
	local frozen = now < entry.stunUntil or now < entry.rootUntil
	local model = humanoid.Parent
	if model then
		model:SetAttribute("CombatStunned", stunned or nil)
		model:SetAttribute("CombatRooted", (now < entry.rootUntil) or nil)
	end
	if frozen and not entry.frozen then
		entry.walkSpeed = humanoid.WalkSpeed
		entry.jumpPower = humanoid.JumpPower
		entry.jumpHeight = humanoid.JumpHeight
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
		entry.frozen = true
	elseif not frozen and entry.frozen then
		if humanoid.Parent then
			humanoid.WalkSpeed = entry.walkSpeed
			humanoid.JumpPower = entry.jumpPower
			humanoid.JumpHeight = entry.jumpHeight
		end
		entry.frozen = false
	end
	if not stunned and not frozen then
		entries[humanoid] = nil
	end
end

local function apply(humanoid: Humanoid, field: Field, duration: number)
	if duration <= 0 then
		return
	end
	local entry = entries[humanoid]
	if not entry then
		entry = {
			stunUntil = 0,
			staggerUntil = 0,
			rootUntil = 0,
			frozen = false,
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
	refresh(humanoid)
	task.delay(duration + 0.01, refresh, humanoid)
end

function StatusEffects.stun(humanoid: Humanoid, duration: number)
	apply(humanoid, "stunUntil", duration)
end

-- Hit stun: no actions for `duration`, movement unaffected.
function StatusEffects.stagger(humanoid: Humanoid, duration: number)
	apply(humanoid, "staggerUntil", duration)
end

function StatusEffects.root(humanoid: Humanoid, duration: number)
	apply(humanoid, "rootUntil", duration)
end

-- True while stunned or staggered (no actions, no weapon switching).
function StatusEffects.isStunned(humanoid: Humanoid?): boolean
	if not humanoid then
		return false
	end
	local entry = entries[humanoid]
	if not entry then
		return false
	end
	local now = os.clock()
	return now < entry.stunUntil or now < entry.staggerUntil
end

function StatusEffects.clear(humanoid: Humanoid)
	local entry = entries[humanoid]
	if entry then
		entry.stunUntil = 0
		entry.staggerUntil = 0
		entry.rootUntil = 0
		refresh(humanoid)
	end
end

return StatusEffects
