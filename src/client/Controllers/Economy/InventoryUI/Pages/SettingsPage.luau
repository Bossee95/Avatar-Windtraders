--!strict
--[[
	SettingsPage: music and sound-effect volume, low graphics and show
	hitboxes (from the old M menu). Values come from SettingsController,
	which applies and saves them.

	Sliders: drag, click the track, or use the - / + buttons (10% steps).
	Toggles: click the switch.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SettingsConfig = require(Shared.Settings.SettingsConfig)

local SettingsController = require(script.Parent.Parent.Parent.Parent.SettingsController)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local C = Theme.Colors
local F = Theme.Fonts
local make = Theme.make
local label = Theme.label

local ROW_HEIGHT = 92

local SettingsPage = {}
SettingsPage.__index = SettingsPage

local function smallButton(parent: Instance, text: string, x: number): TextButton
	local button = make("TextButton", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, x, 0.5, 0),
		Size = UDim2.fromOffset(36, 36),
		Text = text,
		Font = F.Heading,
		TextSize = 20,
		TextColor3 = C.Text,
		BackgroundColor3 = C.PanelDeep,
		AutoButtonColor = true,
	}, parent)
	Theme.corner(button, 18)
	Theme.stroke(button, C.GlowSoft, 1, 0.3)
	return button
end

-- Builds one slider; returns a function that shows a value.
local function buildSlider(control: Frame, key: string): (number) -> ()
	local minus = smallButton(control, "-", 0)
	local track = make("TextButton", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 50, 0.5, 0),
		Size = UDim2.new(1, -170, 0, 10),
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.PanelDeep,
	}, control)
	Theme.corner(track, 5)
	Theme.stroke(track, C.GlowSoft, 1, 0.4)
	local fill = make("Frame", { Size = UDim2.fromScale(0.5, 1), BackgroundColor3 = C.Glow }, track)
	Theme.corner(fill, 5)
	local knob = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = C.Text,
		ZIndex = 2,
	}, track)
	Theme.corner(knob, 11)
	Theme.stroke(knob, C.Select, 2, 0)
	local plus = smallButton(control, "+", 0)
	plus.AnchorPoint = Vector2.new(1, 0.5)
	plus.Position = UDim2.new(1, -64, 0.5, 0)
	local percent = label({
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(56, 30),
		Font = F.Heading,
		TextSize = 17,
		TextColor3 = C.Amber,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, control)

	local function setFromX(x: number)
		local width = math.max(track.AbsoluteSize.X, 1)
		local value = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
		SettingsController:Set(key, math.floor(value * 100 + 0.5) / 100)
	end
	local dragging = false
	track.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end)
	local function step(delta: number)
		local current = SettingsController:Get(key) :: number
		SettingsController:Set(key, math.floor((current + delta) * 10 + 0.5) / 10)
	end
	minus.Activated:Connect(function()
		step(-0.1)
	end)
	plus.Activated:Connect(function()
		step(0.1)
	end)

	return function(value: number)
		fill.Size = UDim2.fromScale(value, 1)
		knob.Position = UDim2.fromScale(value, 0.5)
		percent.Text = string.format("%d%%", math.floor(value * 100 + 0.5))
	end
end

-- Builds one on/off switch; returns a function that shows a value.
local function buildToggle(control: Frame, key: string): (boolean) -> ()
	local switch = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(120, 36),
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = C.PanelDeep,
	}, control)
	Theme.corner(switch, 18)
	local stroke = Theme.stroke(switch, C.GlowSoft, 1.5, 0.2)
	local knob = make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(28, 28),
		BackgroundColor3 = C.Text,
	}, switch)
	Theme.corner(knob, 14)
	local text = label({
		Size = UDim2.fromScale(1, 1),
		Font = F.Heading,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
	}, switch)
	switch.Activated:Connect(function()
		SettingsController:Set(key, SettingsController:Get(key) ~= true)
	end)
	return function(on: boolean)
		switch.BackgroundColor3 = if on then C.GlowSoft else C.PanelDeep
		stroke.Color = if on then C.Glow else C.GlowSoft
		knob.Position = if on then UDim2.new(1, -32, 0.5, 0) else UDim2.new(0, 4, 0.5, 0)
		text.Text = if on then "ON" else "OFF"
		text.TextColor3 = if on then C.Text else C.TextFaint
	end
end

function SettingsPage.new(parent: Instance, _ctx: any)
	local self = setmetatable({}, SettingsPage) :: any
	self.frame =
		Widgets.page(parent, "Settings", "Saved to your account, so they follow you to every server.")
	self.views = {} :: { [string]: (any) -> () }

	local list = make("Frame", {
		Position = UDim2.fromOffset(32, 110),
		Size = UDim2.new(1, -64, 1, -130),
		BackgroundTransparency = 1,
	}, self.frame)
	make("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, list)

	for index, setting in SettingsConfig.List do
		local row = make("Frame", {
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			BackgroundColor3 = C.Tile,
			BackgroundTransparency = 0.2,
			LayoutOrder = index,
		}, list)
		Theme.corner(row, 12)
		Theme.stroke(row, C.GlowSoft, 1, 0.5)
		make("UIPadding", { PaddingLeft = UDim.new(0, 22), PaddingRight = UDim.new(0, 22) }, row)
		label({
			Position = UDim2.fromOffset(0, 18),
			Size = UDim2.new(0.45, 0, 0, 26),
			Text = setting.label,
			Font = F.Heading,
			TextSize = 19,
		}, row)
		label({
			Position = UDim2.fromOffset(0, 46),
			Size = UDim2.new(0.45, 0, 0, 36),
			Text = setting.help,
			TextSize = 14,
			TextWrapped = true,
			TextColor3 = C.TextDim,
			TextYAlignment = Enum.TextYAlignment.Top,
		}, row)
		local control = make("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.new(0.5, 0, 0, 40),
			BackgroundTransparency = 1,
		}, row)
		if setting.kind == "Slider" then
			self.views[setting.key] = buildSlider(control, setting.key) :: any
		else
			self.views[setting.key] = buildToggle(control, setting.key) :: any
		end
	end

	local changed: any = SettingsController.Changed
	changed:Connect(function(key, value)
		local view = self.views[key]
		if view then
			view(value)
		end
	end)
	return self
end

function SettingsPage.Show(self: any)
	self.frame.Visible = true
	for key, view in self.views do
		view(SettingsController:Get(key))
	end
end

function SettingsPage.Hide(self: any)
	self.frame.Visible = false
end

return SettingsPage
