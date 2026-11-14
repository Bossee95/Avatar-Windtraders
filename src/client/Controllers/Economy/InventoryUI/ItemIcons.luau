--!strict
--[[
	ItemIcons: draws item and category icons out of plain GUI frames, so the
	inventory works before any icon art is uploaded.

	An item can override its drawn icon with real art: give its definition
	`icon = "rbxassetid://..."` in Shared.Economy.ItemDefinitions. An optional
	`iconColor = { r, g, b }` tints the drawn icon.

	Every shape is laid out in scale (0..1) inside its container, so the same
	drawing works for a 96px tile and a 30px tab.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Variations = require(ReplicatedStorage.Shared.Combat.Config.Variations)
local Theme = require(script.Parent.Theme)

local ItemIcons = {}

export type Shape = "Sword" | "Spear" | "Bow" | "Rifle" | "Crystal" | "Vial" | "Shield" | "Medal" | "Pouch"

local CATEGORY_SHAPE: { [string]: Shape } = {
	Weapon = "Sword",
	Material = "Crystal",
	Resource = "Crystal",
	Consumable = "Vial",
	Equipment = "Shield",
	Special = "Medal",
	EventReward = "Medal",
	Other = "Pouch",
}

local CATEGORY_COLOR: { [string]: Color3 } = {
	Weapon = Color3.fromRGB(196, 214, 222),
	Material = Color3.fromRGB(120, 210, 190),
	Resource = Color3.fromRGB(150, 220, 120),
	Consumable = Color3.fromRGB(255, 120, 140),
	Equipment = Color3.fromRGB(110, 170, 255),
	Special = Color3.fromRGB(255, 196, 102),
	EventReward = Color3.fromRGB(255, 196, 102),
	Other = Color3.fromRGB(190, 170, 140),
}

-- Placeholder materials get distinct colours until they have real art.
local ITEM_COLOR: { [string]: Color3 } = {
	["Material.Common"] = Color3.fromRGB(170, 190, 170),
	["Material.Industrial"] = Color3.fromRGB(140, 170, 200),
	["Material.Natural"] = Color3.fromRGB(120, 220, 120),
	["Material.Rare"] = Color3.fromRGB(190, 130, 255),
}

local function part(
	parent: Instance,
	x: number,
	y: number,
	w: number,
	h: number,
	rotation: number,
	color: Color3,
	radius: number?
): Frame
	local frame = Theme.make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(w, h),
		Rotation = rotation,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, parent)
	if radius then
		Theme.make("UICorner", { CornerRadius = UDim.new(radius, 0) }, frame)
	end
	return frame
end

local function shade(color: Color3, amount: number): Color3
	return color:Lerp(if amount < 0 then Color3.new(0, 0, 0) else Color3.new(1, 1, 1), math.abs(amount))
end

local DRAW: { [Shape]: (Instance, Color3) -> () } = {
	Sword = function(c: Instance, color: Color3)
		part(c, 0.58, 0.42, 0.11, 0.62, 45, color, 0.3)
		part(c, 0.6, 0.4, 0.035, 0.5, 45, shade(color, 0.5))
		part(c, 0.36, 0.64, 0.36, 0.08, 45, Theme.Colors.Amber, 0.5)
		part(c, 0.28, 0.72, 0.08, 0.2, 45, shade(color, -0.55), 0.4)
		part(c, 0.2, 0.8, 0.1, 0.1, 0, Theme.Colors.Amber, 0.5)
	end,
	Spear = function(c: Instance, color: Color3)
		part(c, 0.47, 0.53, 0.055, 0.82, 45, Color3.fromRGB(150, 110, 70), 0.5)
		part(c, 0.76, 0.24, 0.13, 0.26, 45, color, 0.45)
		part(c, 0.66, 0.34, 0.2, 0.05, 45, Theme.Colors.Amber, 0.5)
	end,
	Bow = function(c: Instance, color: Color3)
		local clip = Theme.make("Frame", {
			Position = UDim2.fromScale(0.18, 0.1),
			Size = UDim2.fromScale(0.36, 0.8),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
		}, c)
		local arc = Theme.make("Frame", {
			Position = UDim2.fromScale(0, 0),
			Size = UDim2.fromScale(2, 1),
			BackgroundTransparency = 1,
		}, clip)
		Theme.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, arc)
		Theme.make("UIStroke", { Color = color, Thickness = 3 }, arc)
		part(c, 0.54, 0.5, 0.025, 0.8, 0, shade(color, 0.6))
		part(c, 0.56, 0.5, 0.6, 0.035, 0, Color3.fromRGB(150, 110, 70))
		part(c, 0.86, 0.5, 0.1, 0.1, 45, Theme.Colors.Amber, 0.2)
	end,
	Rifle = function(c: Instance, color: Color3)
		part(c, 0.48, 0.47, 0.6, 0.13, 0, color, 0.25)
		part(c, 0.84, 0.44, 0.24, 0.05, 0, shade(color, -0.3))
		part(c, 0.16, 0.55, 0.2, 0.18, -12, shade(color, -0.45), 0.25)
		part(c, 0.44, 0.62, 0.08, 0.18, 14, shade(color, -0.45), 0.3)
		part(c, 0.56, 0.38, 0.18, 0.05, 0, Theme.Colors.Glow, 0.5)
	end,
	Crystal = function(c: Instance, color: Color3)
		part(c, 0.32, 0.6, 0.2, 0.2, 45, shade(color, -0.35), 0.15)
		part(c, 0.7, 0.62, 0.17, 0.17, 45, shade(color, -0.25), 0.15)
		part(c, 0.5, 0.45, 0.3, 0.3, 45, color, 0.15)
		part(c, 0.46, 0.4, 0.1, 0.1, 45, shade(color, 0.6), 0.3)
		part(c, 0.5, 0.82, 0.56, 0.06, 0, shade(color, -0.6), 0.5)
	end,
	Vial = function(c: Instance, color: Color3)
		part(c, 0.5, 0.6, 0.44, 0.48, 0, color, 0.3)
		part(c, 0.5, 0.31, 0.18, 0.14, 0, shade(color, 0.45), 0.2)
		part(c, 0.5, 0.22, 0.26, 0.07, 0, Theme.Colors.Amber, 0.5)
		part(c, 0.5, 0.62, 0.22, 0.06, 0, Color3.new(1, 1, 1), 0.5)
		part(c, 0.5, 0.62, 0.06, 0.22, 0, Color3.new(1, 1, 1), 0.5)
	end,
	Shield = function(c: Instance, color: Color3)
		part(c, 0.5, 0.42, 0.5, 0.36, 0, color, 0.15)
		part(c, 0.5, 0.6, 0.36, 0.36, 45, color, 0.15)
		part(c, 0.5, 0.52, 0.06, 0.48, 0, shade(color, 0.5), 0.5)
		part(c, 0.5, 0.4, 0.12, 0.12, 45, Theme.Colors.Amber, 0.3)
	end,
	Medal = function(c: Instance, color: Color3)
		part(c, 0.42, 0.26, 0.12, 0.32, -20, Color3.fromRGB(120, 90, 200), 0.2)
		part(c, 0.58, 0.26, 0.12, 0.32, 20, Color3.fromRGB(90, 200, 190), 0.2)
		local disc = part(c, 0.5, 0.62, 0.44, 0.44, 0, color, 0.5)
		Theme.make("UIStroke", { Color = shade(color, -0.4), Thickness = 2 }, disc)
		part(c, 0.5, 0.62, 0.18, 0.18, 45, shade(color, 0.6), 0.2)
	end,
	Pouch = function(c: Instance, color: Color3)
		part(c, 0.5, 0.6, 0.52, 0.46, 0, color, 0.4)
		part(c, 0.5, 0.34, 0.3, 0.12, 0, shade(color, -0.3), 0.5)
		part(c, 0.5, 0.4, 0.4, 0.04, 0, Theme.Colors.Amber, 0.5)
	end,
}

local function toColor(value: any): Color3?
	if typeof(value) == "Color3" then
		return value
	elseif type(value) == "table" and #value == 3 then
		return Color3.fromRGB(value[1], value[2], value[3])
	end
	return nil
end

function ItemIcons.shapeFor(def: any): Shape
	if def.category == "Weapon" and def.variationId then
		local variation = Variations[def.variationId]
		local weaponType = variation and variation.weaponType
		if weaponType == "Spear" or weaponType == "Bow" or weaponType == "Rifle" then
			return weaponType
		end
		return "Sword"
	end
	return CATEGORY_SHAPE[def.category] or "Pouch"
end

-- Draws one shape into `container` in a single colour (used for tab icons).
function ItemIcons.drawShape(container: Instance, shape: Shape, color: Color3)
	DRAW[shape](container, color)
end

-- Draws an item's icon into `container`: its uploaded art if it has some,
-- otherwise the drawn shape for its category or weapon type.
function ItemIcons.draw(container: Instance, def: any)
	if type(def.icon) == "string" and def.icon ~= "" then
		Theme.make("ImageLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Image = def.icon,
			ScaleType = Enum.ScaleType.Fit,
		}, container)
		return
	end
	local color = toColor(def.iconColor)
		or ITEM_COLOR[def.id]
		or CATEGORY_COLOR[def.category]
		or Theme.Colors.TextDim
	DRAW[ItemIcons.shapeFor(def)](container, color)
end

return ItemIcons
