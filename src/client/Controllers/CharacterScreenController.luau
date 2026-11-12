--!strict
--[[
	CharacterScreenController: a plain, functional character screen so the game
	is playable while the real UI is designed. Shown whenever the player has no
	active character: lists characters (dead ones greyed out as history), and
	lets the player create a new one or continue as a living one.

	Replace freely; it only uses CharacterController's public API.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local WorldConfig = require(Shared.Config.WorldConfig)
local GameConfig = require(Shared.Config.GameConfig)

local CharacterController = require(script.Parent.CharacterController)

local CharacterScreenController = {}

local gui: ScreenGui
local list: ScrollingFrame
local status: TextLabel
local nameBox: TextBox
local chosenFaction: string = GameConfig.Characters.PlayerSelectableFactions[1]
local factionButtons: { [string]: TextButton } = {}

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(className)
	for k, v in props do
		(instance :: any)[k] = v
	end
	instance.Parent = parent
	return instance
end

local function button(text: string, parent: Instance): TextButton
	return make("TextButton", {
		Text = text,
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundColor3 = Color3.fromRGB(45, 52, 60),
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamMedium,
		TextSize = 16,
		AutoButtonColor = true,
	}, parent)
end

local function setStatus(text: string)
	status.Text = text
end

local function refreshFactionButtons()
	for key, b in factionButtons do
		b.BackgroundColor3 = if key == chosenFaction then Color3.fromRGB(70, 110, 90) else Color3.fromRGB(45, 52, 60)
	end
end

local function render(state: any)
	gui.Enabled = state ~= nil and state.activeCharacterId == nil
	for _, child in list:GetChildren() do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
	if not state then
		return
	end
	for index, summary in state.characters do
		local label = string.format(
			"%s  ·  %s, %s  ·  rank %d%s",
			summary.name,
			WorldConfig.getFactionName(summary.faction),
			WorldConfig.getRoleName(summary.faction, summary.role),
			summary.rank,
			if summary.status == "Dead" then "  ·  deceased" else ""
		)
		local b = button(label, list)
		b.LayoutOrder = index
		if summary.status == "Dead" then
			b.AutoButtonColor = false
			b.TextColor3 = Color3.fromRGB(140, 140, 140)
		else
			b.Activated:Connect(function()
				setStatus("Selecting...")
				local ok, err = CharacterController:SelectCharacter(summary.id)
				setStatus(if ok then "" else "Couldn't select: " .. tostring(err))
			end)
		end
	end
end

function CharacterScreenController:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	gui = make("ScreenGui", { Name = "CharacterScreen", ResetOnSpawn = false, IgnoreGuiInset = true, Enabled = false }, playerGui)
	make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(15, 18, 22) }, gui)

	local panel = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 460, 0, 520),
		BackgroundTransparency = 1,
	}, gui)
	make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, panel)

	make("TextLabel", {
		Text = "Characters",
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundTransparency = 1,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 26,
		LayoutOrder = 1,
	}, panel)

	list = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, 200),
		BackgroundTransparency = 1,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 6,
		LayoutOrder = 2,
	}, panel)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, list)

	nameBox = make("TextBox", {
		PlaceholderText = "New character name",
		Text = "",
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundColor3 = Color3.fromRGB(30, 35, 40),
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.Gotham,
		TextSize = 16,
		ClearTextOnFocus = false,
		LayoutOrder = 3,
	}, panel)

	local factionRow = make("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, LayoutOrder = 4 }, panel)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, factionRow)
	local selectable = GameConfig.Characters.PlayerSelectableFactions
	for _, key in selectable do
		local b = button(WorldConfig.getFactionName(key), factionRow)
		b.Size = UDim2.new(1 / #selectable, -8, 1, 0)
		factionButtons[key] = b
		b.Activated:Connect(function()
			chosenFaction = key
			refreshFactionButtons()
		end)
	end
	refreshFactionButtons()

	local create = button("Create character", panel)
	create.LayoutOrder = 5
	create.Activated:Connect(function()
		setStatus("Creating...")
		local ok, result = CharacterController:CreateCharacter({ name = nameBox.Text, faction = chosenFaction })
		setStatus(if ok then "" else "Couldn't create: " .. tostring(result))
	end)

	status = make("TextLabel", {
		Text = "",
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		TextColor3 = Color3.fromRGB(230, 170, 120),
		Font = Enum.Font.Gotham,
		TextSize = 14,
		LayoutOrder = 6,
	}, panel)

	CharacterController.StateChanged:Connect(render)
	render(CharacterController:GetState())
end

return CharacterScreenController
