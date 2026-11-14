--!strict
--[[
	Theme: colours, fonts and small builders shared by the inventory screen.

	The look is the game's own: Pandora at night. Deep teal glass panels, a
	thin bioluminescent cyan edge, violet for the selection and warm amber for
	numbers. Change the palette here and every inventory element follows.
]]

local Theme = {}

Theme.Colors = {
	Backdrop = Color3.fromRGB(4, 12, 18),
	Panel = Color3.fromRGB(10, 28, 34),
	PanelDeep = Color3.fromRGB(6, 18, 24),
	Tile = Color3.fromRGB(14, 38, 44),
	TileEmpty = Color3.fromRGB(10, 26, 31),
	TileHover = Color3.fromRGB(22, 56, 62),
	Glow = Color3.fromRGB(86, 232, 214), -- bioluminescent cyan
	GlowSoft = Color3.fromRGB(44, 120, 116),
	Select = Color3.fromRGB(178, 120, 255), -- violet
	SelectDeep = Color3.fromRGB(70, 36, 120),
	Amber = Color3.fromRGB(255, 196, 102),
	Text = Color3.fromRGB(232, 246, 242),
	TextDim = Color3.fromRGB(150, 182, 178),
	TextFaint = Color3.fromRGB(92, 122, 120),
	Bound = Color3.fromRGB(255, 132, 120),
	Equipped = Color3.fromRGB(120, 255, 170),
}

Theme.Fonts = {
	Title = Enum.Font.Jura,
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.Gotham,
	Medium = Enum.Font.GothamMedium,
	Number = Enum.Font.GothamBlack,
}

-- Layout is designed at this resolution and scaled with a UIScale.
Theme.DesignSize = Vector2.new(1600, 900)

function Theme.make(className: string, props: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(className)
	for key, value in props do
		(instance :: any)[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function Theme.corner(parent: Instance, radius: number?): UICorner
	return Theme.make("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, parent)
end

function Theme.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	return Theme.make("UIStroke", {
		Color = color or Theme.Colors.GlowSoft,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

function Theme.gradient(parent: Instance, top: Color3, bottom: Color3, rotation: number?): UIGradient
	return Theme.make("UIGradient", {
		Color = ColorSequence.new(top, bottom),
		Rotation = rotation or 90,
	}, parent)
end

function Theme.label(props: { [string]: any }, parent: Instance?): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		TextColor3 = Theme.Colors.Text,
		Font = Theme.Fonts.Body,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}
	for key, value in props do
		defaults[key] = value
	end
	return Theme.make("TextLabel", defaults, parent)
end

-- A glass panel: deep teal fill, soft vertical gradient and a glowing edge.
function Theme.panel(props: { [string]: any }, parent: Instance?): Frame
	local defaults: { [string]: any } = {
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
	}
	for key, value in props do
		defaults[key] = value
	end
	local frame = Theme.make("Frame", defaults, parent)
	Theme.corner(frame, 14)
	Theme.stroke(frame, Theme.Colors.GlowSoft, 1.5, 0.25)
	Theme.gradient(frame, Color3.new(1, 1, 1), Color3.fromRGB(150, 170, 175))
	return frame
end

--[[
	Ornament: a small vine flourish (a dot flanked by two tapering strokes)
	used as a divider under headings. Pure frames, no image assets.
]]
function Theme.flourish(parent: Instance, position: UDim2, width: number, color: Color3?): Frame
	local tint = color or Theme.Colors.Glow
	local holder = Theme.make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.fromOffset(width, 8),
		BackgroundTransparency = 1,
	}, parent)
	for side = -1, 1, 2 do
		local line = Theme.make("Frame", {
			AnchorPoint = Vector2.new(if side < 0 then 1 else 0, 0.5),
			Position = UDim2.new(0.5, side * 8, 0.5, 0),
			Size = UDim2.new(0.5, -10, 0, 2),
			BackgroundColor3 = tint,
			BorderSizePixel = 0,
		}, holder)
		Theme.make("UIGradient", {
			Transparency = NumberSequence.new(if side < 0 then 1 else 0, if side < 0 then 0 else 1),
		}, line)
	end
	local seed = Theme.make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(7, 7),
		Rotation = 45,
		BackgroundColor3 = tint,
		BorderSizePixel = 0,
	}, holder)
	Theme.corner(seed, 2)
	return holder
end

-- A key hint chip, e.g. [M] Close.
function Theme.keyHint(parent: Instance, key: string, text: string, order: number): Frame
	local row = Theme.make("Frame", {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 28),
		BackgroundTransparency = 1,
		LayoutOrder = order,
	}, parent)
	Theme.make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	local chip = Theme.make("Frame", {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(26, 24),
		BackgroundColor3 = Theme.Colors.PanelDeep,
		LayoutOrder = 1,
	}, row)
	Theme.corner(chip, 6)
	Theme.stroke(chip, Theme.Colors.Glow, 1, 0.35)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7) }, chip)
	Theme.label({
		Text = key,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		Font = Theme.Fonts.Heading,
		TextSize = 13,
		TextColor3 = Theme.Colors.Glow,
		TextXAlignment = Enum.TextXAlignment.Center,
	}, chip)
	Theme.label({
		Text = text,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		Font = Theme.Fonts.Medium,
		TextSize = 15,
		TextColor3 = Theme.Colors.TextDim,
		LayoutOrder = 2,
	}, row)
	return row
end

return Theme
