--!strict
--[[
	CustomisePage: weapon skins and accessories (from the old M menu).

	Weapon skins: the skins the account owns. Click one to wear it on your
	class weapon, or "Default look" to go back. Skins made for another weapon
	type are listed but dimmed.

	Accessories: everything in ServerStorage.CosmeticModels. Click to wear or
	take off. One per slot (hat, face, ...), up to a limit.

	The server does the change (CosmeticService) and the 3D preview refreshes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Variations = require(Shared.Combat.Config.Variations)
local WeaponTypes = require(Shared.Combat.Config.WeaponTypes)

local CombatController = require(script.Parent.Parent.Parent.Parent.Combat.CombatController)
local ItemIcons = require(script.Parent.Parent.ItemIcons)
local Widgets = require(script.Parent.Widgets)

local ERRORS: { [string]: string } = {
	NotOwned = "You don't own that skin.",
	NoModel = "That skin has no model in this place yet.",
	WrongWeaponType = "That skin is for a different weapon.",
	TooMany = "You're wearing as many accessories as you can. Take one off first.",
	UnknownAccessory = "That accessory isn't available any more.",
	AccountNotLoaded = "Your account is still loading. Try again in a moment.",
}

local function errorText(err: any): string
	local code = if err == nil then "NoReply" else tostring(err)
	return ERRORS[code] or ("Couldn't do that (" .. code .. ").")
end

local CustomisePage = {}
CustomisePage.__index = CustomisePage

export type Context = { refreshPreview: () -> () }

function CustomisePage.new(parent: Instance, ctx: Context)
	local self = setmetatable({}, CustomisePage) :: any
	self.ctx = ctx
	self.view = "Skins"
	self.state = nil
	self.busy = false

	self.frame = Widgets.page(
		parent,
		"Customise",
		"Change how your character and weapon look. Skins and accessories stay with your account, even after Permanent Death."
	)
	self.highlight = Widgets.subTabs(self.frame, 104, {
		{ key = "Skins", label = "Weapon skins" },
		{ key = "Accessories", label = "Accessories" },
	}, function(key)
		self.view = key
		self:Render()
	end)
	self.grid = Widgets.grid(self.frame, 156, 350, 104)
	self.emptyLabel = Widgets.empty(self.frame, 156)
	self.setStatus = Widgets.status(self.frame)
	return self
end

function CustomisePage.Show(self: any)
	self.frame.Visible = true
	self.setStatus("")
	self:Render()
	task.spawn(function()
		local state = Net.Invoke("GetCosmetics")
		if type(state) == "table" then
			self.state = state
			self:Render()
		end
	end)
end

function CustomisePage.Hide(self: any)
	self.frame.Visible = false
end

function CustomisePage.SetState(self: any, state: any)
	self.state = state
	if self.frame.Visible then
		self:Render()
	end
end

function CustomisePage.Run(self: any, remote: string, ...: any)
	if self.busy then
		return
	end
	self.busy = true
	self.setStatus("Working...")
	local ok, err = Net.Invoke(remote, ...)
	self.busy = false
	if ok then
		self.setStatus("Done.")
		task.delay(0.3, self.ctx.refreshPreview)
	else
		self.setStatus(errorText(err), true)
	end
end

local function currentWeaponType(): string?
	local variationId = CombatController:GetState().variationId
	local variation = variationId and Variations[variationId]
	return variation and variation.weaponType or nil
end

function CustomisePage.RenderSkins(self: any, state: any)
	local weaponType = currentWeaponType()
	local typeName = if weaponType and WeaponTypes[weaponType]
		then WeaponTypes[weaponType].displayName
		else nil
	local shape: ItemIcons.Shape = if weaponType == "Spear"
			or weaponType == "Bow"
			or weaponType == "Rifle"
		then weaponType
		else "Sword"
	local equipped = weaponType and state.equippedSkins[weaponType]

	local default = Widgets.card(
		self.grid,
		0,
		shape,
		"Default look",
		if typeName then "The standard " .. string.lower(typeName) .. " model." else "Spawn to pick a skin."
	)
	if weaponType then
		Widgets.setActive(default, equipped == nil, if equipped == nil then "Wearing" else "Click to wear")
		default.button.Activated:Connect(function()
			if equipped ~= nil then
				task.spawn(self.Run, self, "EquipSkin", weaponType, nil)
			end
		end)
	else
		Widgets.setDisabled(default, "No weapon")
	end

	for index, skin in state.skins do
		local fits = weaponType ~= nil and (skin.weaponType == nil or skin.weaponType == weaponType)
		local forText = if skin.weaponType and WeaponTypes[skin.weaponType]
			then "For " .. WeaponTypes[skin.weaponType].displayName .. "."
			else "Fits any weapon."
		local card = Widgets.card(self.grid, index, shape, skin.name, forText)
		if not skin.hasModel then
			Widgets.setDisabled(card, "No model yet")
		elseif not fits then
			Widgets.setDisabled(card, "Not for your weapon")
		else
			local wearing = equipped == skin.id
			Widgets.setActive(card, wearing, if wearing then "Wearing" else "Click to wear")
			card.button.Activated:Connect(function()
				if not wearing then
					task.spawn(self.Run, self, "EquipSkin", weaponType, skin.id)
				end
			end)
		end
	end

	if #state.skins == 0 then
		self.emptyLabel.Text =
			"You don't own any weapon skins yet. Skins are granted by the Development Team and stay on your account."
		self.emptyLabel.Visible = true
	end
end

function CustomisePage.RenderAccessories(self: any, state: any)
	local wornCount = 0
	for _ in state.worn do
		wornCount += 1
	end
	for index, accessory in state.accessories do
		local wearing = state.worn[accessory.id] == true
		local subtitle = if accessory.slot then accessory.slot else "Accessory"
		local card = Widgets.card(self.grid, index, "Pouch", accessory.name, subtitle)
		Widgets.setActive(
			card,
			wearing,
			if wearing then "Wearing  ·  click to take off" else "Click to wear"
		)
		card.button.Activated:Connect(function()
			task.spawn(self.Run, self, "SetAccessory", accessory.id, not wearing)
		end)
	end
	if #state.accessories == 0 then
		self.emptyLabel.Text = "No accessories are set up in this place yet."
		self.emptyLabel.Visible = true
	else
		self.setStatus(string.format("Wearing %d of %d.", wornCount, state.maxAccessories or 0))
	end
end

function CustomisePage.Render(self: any)
	self.highlight(self.view)
	Widgets.clear(self.grid)
	self.emptyLabel.Visible = false
	local state = self.state
	if not state then
		self.emptyLabel.Text = "Loading..."
		self.emptyLabel.Visible = true
		return
	end
	if self.view == "Skins" then
		self:RenderSkins(state)
	else
		self:RenderAccessories(state)
	end
end

return CustomisePage
