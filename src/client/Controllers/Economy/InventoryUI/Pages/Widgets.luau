--!strict
--[[
	Widgets: building blocks shared by the inventory's pages (Customise,
	Skills, Settings): a page panel with a title, a scrolling card grid,
	selectable cards, sub-tab buttons and a status line.
]]

local Theme = require(script.Parent.Parent.Theme)
local ItemIcons = require(script.Parent.Parent.ItemIcons)

local C = Theme.Colors
local F = Theme.Fonts
local make = Theme.make
local label = Theme.label

local Widgets = {}

export type Card = {
	button: TextButton,
	icon: Frame,
	title: TextLabel,
	subtitle: TextLabel,
	badge: TextLabel,
}

-- A full-size glass panel with a title and a one-line explanation under it.
function Widgets.page(parent: Instance, title: string, intro: string): Frame
	local panel = Theme.panel({ Size = UDim2.fromScale(1, 1), Visible = false }, parent)
	label({
		Position = UDim2.fromOffset(32, 22),
		Size = UDim2.new(1, -64, 0, 34),
		Text = title,
		Font = F.Title,
		TextSize = 30,
	}, panel)
	label({
		Name = "Intro",
		Position = UDim2.fromOffset(32, 58),
		Size = UDim2.new(1, -64, 0, 40),
		Text = intro,
		TextSize = 16,
		TextWrapped = true,
		TextColor3 = C.TextDim,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, panel)
	return panel
end

-- A scrolling grid of cards. `top` is where it starts inside the panel.
function Widgets.grid(panel: Instance, top: number, cellWidth: number, cellHeight: number): ScrollingFrame
	local grid = make("ScrollingFrame", {
		Position = UDim2.fromOffset(32, top),
		Size = UDim2.new(1, -52, 1, -(top + 64)),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = C.Glow,
		ScrollBarImageTransparency = 0.4,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		SelectionGroup = true,
	}, panel)
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(cellWidth, cellHeight),
		CellPadding = UDim2.fromOffset(14, 14),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 2) }, grid)
	return grid
end

function Widgets.clear(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- A card: icon on the left, title, subtitle and a badge (e.g. "Wearing").
function Widgets.card(
	parent: Instance,
	order: number,
	shape: ItemIcons.Shape,
	title: string,
	subtitle: string
): Card
	local button = make("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.Tile,
		BackgroundTransparency = 0.1,
		LayoutOrder = order,
	}, parent)
	Theme.corner(button, 12)
	Theme.stroke(button, C.GlowSoft, 1.5, 0.45)
	local icon = make("Frame", {
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(0, 64, 1, -24),
		BackgroundColor3 = C.PanelDeep,
		BackgroundTransparency = 0.3,
	}, button)
	Theme.corner(icon, 10)
	local art = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(52, 52),
		BackgroundTransparency = 1,
	}, icon)
	ItemIcons.drawShape(art, shape, C.Glow)
	local titleLabel = label({
		Position = UDim2.fromOffset(90, 14),
		Size = UDim2.new(1, -100, 0, 24),
		Text = title,
		Font = F.Heading,
		TextSize = 18,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, button)
	local subtitleLabel = label({
		Position = UDim2.fromOffset(90, 40),
		Size = UDim2.new(1, -100, 0, 34),
		Text = subtitle,
		TextSize = 14,
		TextColor3 = C.TextDim,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, button)
	local badge = label({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 90, 1, -10),
		Size = UDim2.new(1, -100, 0, 20),
		Text = "",
		Font = F.Heading,
		TextSize = 13,
		TextColor3 = C.Glow,
	}, button)
	button.MouseEnter:Connect(function()
		if button:GetAttribute("Active") ~= true then
			button.BackgroundColor3 = C.TileHover
		end
	end)
	button.MouseLeave:Connect(function()
		if button:GetAttribute("Active") ~= true then
			button.BackgroundColor3 = C.Tile
		end
	end)
	return { button = button, icon = icon, title = titleLabel, subtitle = subtitleLabel, badge = badge }
end

-- Marks a card as the active choice (violet, like a selected item tile).
function Widgets.setActive(card: Card, active: boolean, badgeText: string?)
	card.button:SetAttribute("Active", active)
	card.button.BackgroundColor3 = if active then C.SelectDeep else C.Tile
	local stroke = card.button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if active then C.Select else C.GlowSoft
		stroke.Thickness = if active then 3 else 1.5
		stroke.Transparency = if active then 0 else 0.45
	end
	card.badge.Text = badgeText or ""
	card.badge.TextColor3 = if active then C.Equipped else C.Glow
end

-- Dims a card that can't be picked, with the reason as its badge.
function Widgets.setDisabled(card: Card, reason: string)
	card.button.AutoButtonColor = false
	card.button.BackgroundTransparency = 0.5
	card.title.TextColor3 = C.TextFaint
	card.badge.Text = reason
	card.badge.TextColor3 = C.TextFaint
end

-- A row of sub-tab buttons. Returns a function that highlights one key.
function Widgets.subTabs(
	panel: Instance,
	top: number,
	tabs: { { key: string, label: string } },
	onPick: (string) -> ()
): (string) -> ()
	local row = make("Frame", {
		Position = UDim2.fromOffset(32, top),
		Size = UDim2.new(1, -64, 0, 36),
		BackgroundTransparency = 1,
	}, panel)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	local buttons: { [string]: TextButton } = {}
	for index, tab in tabs do
		local button = make("TextButton", {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 36),
			Text = tab.label,
			Font = F.Medium,
			TextSize = 16,
			TextColor3 = C.TextDim,
			BackgroundColor3 = C.PanelDeep,
			BackgroundTransparency = 0.3,
			AutoButtonColor = true,
			LayoutOrder = index,
		}, row)
		Theme.corner(button, 18)
		Theme.stroke(button, C.GlowSoft, 1, 0.4)
		make("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 18) }, button)
		button.Activated:Connect(function()
			onPick(tab.key)
		end)
		buttons[tab.key] = button
	end
	return function(active: string)
		for key, button in buttons do
			local on = key == active
			button.BackgroundColor3 = if on then C.SelectDeep else C.PanelDeep
			button.TextColor3 = if on then C.Text else C.TextDim
			local stroke = button:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = if on then C.Select else C.GlowSoft
			end
		end
	end
end

-- A status line along the bottom of a page, for results and errors.
function Widgets.status(panel: Instance): (string, boolean?) -> ()
	local line = label({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 32, 1, -18),
		Size = UDim2.new(1, -64, 0, 28),
		Text = "",
		TextSize = 15,
		TextColor3 = C.Equipped,
	}, panel)
	return function(text: string, isError: boolean?)
		line.Text = text
		line.TextColor3 = if isError then C.Bound else C.Equipped
	end
end

-- Centered text shown over an empty list. Starts hidden.
function Widgets.empty(panel: Instance, top: number): TextLabel
	local note = label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, top + 60),
		Size = UDim2.new(1, -160, 0, 90),
		Text = "",
		TextWrapped = true,
		TextSize = 17,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 5,
	}, panel)
	return note
end

return Widgets
