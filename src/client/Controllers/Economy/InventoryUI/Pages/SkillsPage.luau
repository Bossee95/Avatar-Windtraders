--!strict
--[[
	SkillsPage: pick which G ability goes on the G key (from the old M menu).

	Lists the G abilities this character holds (sent in CombatState) and sets
	the active one through CombatSelectGAbility. Like weapons, it can't be
	changed during combat.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GAbilities = require(Shared.Combat.Config.GAbilities)
local Actions = require(Shared.Combat.Config.Actions)

local CombatController = require(script.Parent.Parent.Parent.Parent.Combat.CombatController)
local Widgets = require(script.Parent.Widgets)

local ERRORS: { [string]: string } = {
	InCombat = "You can't change your G ability during combat.",
	Busy = "Finish your current action first.",
	AbilityNotAssigned = "Your character doesn't hold that ability any more.",
	NoCharacter = "Spawn your character first.",
}

local SkillsPage = {}
SkillsPage.__index = SkillsPage

function SkillsPage.new(parent: Instance, _ctx: any)
	local self = setmetatable({}, SkillsPage) :: any
	self.busy = false
	self.frame = Widgets.page(
		parent,
		"Skills",
		"Your G key uses one ability. Click an ability to put it on G. You can't swap during combat."
	)
	self.grid = Widgets.grid(self.frame, 110, 350, 104)
	self.emptyLabel = Widgets.empty(self.frame, 110)
	self.setStatus = Widgets.status(self.frame)
	local stateChanged: any = CombatController.StateChanged
	stateChanged:Connect(function()
		if self.frame.Visible then
			self:Render()
		end
	end)
	return self
end

function SkillsPage.Show(self: any)
	self.frame.Visible = true
	self.setStatus("")
	self:Render()
end

function SkillsPage.Hide(self: any)
	self.frame.Visible = false
end

local function describe(abilityId: string): string
	local ability = GAbilities[abilityId]
	local action = ability and (Actions :: any)[ability.action]
	local parts = {}
	if action and type(action.cooldown) == "number" then
		table.insert(parts, string.format("%gs cooldown", action.cooldown))
	end
	if action and type(action.damage) == "number" and action.damage > 0 then
		table.insert(parts, string.format("%d damage", action.damage))
	end
	if ability and ability.requiresWeapon then
		table.insert(parts, "needs a weapon")
	end
	return if #parts > 0 then table.concat(parts, "  ·  ") else "G ability"
end

function SkillsPage.Pick(self: any, abilityId: string?)
	if self.busy then
		return
	end
	self.busy = true
	self.setStatus("Working...")
	local ok, err = CombatController:SelectGAbility(abilityId)
	self.busy = false
	if ok then
		self.setStatus(if abilityId then "Now on G." else "G cleared.")
	else
		local code = if err == nil then "NoReply" else tostring(err)
		self.setStatus(ERRORS[code] or ("Couldn't do that (" .. code .. ")."), true)
	end
end

function SkillsPage.Render(self: any)
	Widgets.clear(self.grid)
	local state = CombatController:GetState()
	local owned: { string } = (state :: any).gAbilities or {}
	for index, abilityId in owned do
		local ability = GAbilities[abilityId]
		local name = if ability then ability.displayName else abilityId
		local card = Widgets.card(self.grid, index, "Medal", name, describe(abilityId))
		local active = state.gAbilityId == abilityId
		Widgets.setActive(card, active, if active then "On G  ·  click to clear" else "Click to put on G")
		card.button.Activated:Connect(function()
			task.spawn(self.Pick, self, if active then nil else abilityId)
		end)
	end
	self.emptyLabel.Visible = #owned == 0
	self.emptyLabel.Text =
		"You haven't been granted any G abilities yet. They're awarded by the Loreteam, at events and for contributions."
end

return SkillsPage
