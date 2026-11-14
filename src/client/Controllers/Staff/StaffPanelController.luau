--!strict
--[[
	StaffPanelController: the staff panel, opened with L (the key the old
	Loreteam panel used). No commands to remember: pick a player from the
	list, then press the action you want. Choices (weapon, ability, faction,
	phase) are buttons that cycle through what exists in config.

	Tabs
	  Players  pick someone in the server, then: view record, set rank, class,
	           grant/revoke kits and G abilities, approve Trials, set
	           faction, whitelist
	  PD       status, start, phase, pause/resume, end, history
	  Deaths   pending reports; confirm or dismiss by report id
	  Command  type any staff command (the full list is under /staff)

	Everything goes through the StaffCommand remote, so the server checks
	permissions exactly as for chat commands. Non-staff can't open it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Kits = require(Shared.Combat.Config.Kits)
local Classes = require(Shared.Combat.Config.Classes)
local GAbilities = require(Shared.Combat.Config.GAbilities)
local WorldConfig = require(Shared.Config.WorldConfig)
local PDPhases = require(Shared.PDEvent.PDPhases)

local LocalPlayer = Players.LocalPlayer
local OPEN_KEY = Enum.KeyCode.L

local COLORS = {
	bg = Color3.fromRGB(24, 28, 33),
	panel = Color3.fromRGB(32, 37, 43),
	field = Color3.fromRGB(38, 44, 51),
	button = Color3.fromRGB(45, 52, 60),
	go = Color3.fromRGB(62, 120, 88),
	stop = Color3.fromRGB(140, 60, 60),
	accent = Color3.fromRGB(150, 200, 255),
	text = Color3.new(1, 1, 1),
	dim = Color3.fromRGB(170, 180, 190),
}

local StaffPanelController = {}

local function sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(className)
	for k, v in props do
		(instance :: any)[k] = v
	end
	instance.Parent = parent
	return instance
end

local function quote(text: string): string
	return '"' .. string.gsub(text, '"', "'") .. '"'
end

function StaffPanelController:Start()
	local gui = make("ScreenGui", {
		Name = "StaffPanel",
		ResetOnSpawn = false,
		Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, LocalPlayer:WaitForChild("PlayerGui"))

	local frame = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 680, 0, 540),
		BackgroundColor3 = COLORS.bg,
		BorderSizePixel = 0,
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, frame)

	make("TextLabel", {
		Text = "Staff panel",
		Position = UDim2.new(0, 14, 0, 8),
		Size = UDim2.new(0.5, 0, 0, 24),
		BackgroundTransparency = 1,
		TextColor3 = COLORS.text,
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, frame)
	local close = make("TextButton", {
		Text = "Close (L)",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.new(0, 90, 0, 24),
		BackgroundColor3 = COLORS.button,
		TextColor3 = COLORS.text,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
	}, frame)
	close.Activated:Connect(function()
		gui.Enabled = false
	end)

	-- Reply area, shared by every tab.
	local output = make("TextLabel", {
		Text = "Replies from the server appear here.",
		Position = UDim2.new(0, 12, 1, -112),
		Size = UDim2.new(1, -24, 0, 100),
		BackgroundColor3 = COLORS.panel,
		TextColor3 = COLORS.dim,
		Font = Enum.Font.Code,
		TextSize = 13,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, frame)
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingTop = UDim.new(0, 4) }, output)

	local busy = false
	local function run(line: string)
		if busy then
			return
		end
		busy = true
		output.TextColor3 = COLORS.dim
		output.Text = "..."
		local ok, reply = Net.Invoke("StaffCommand", line)
		output.TextColor3 = if ok then COLORS.text else Color3.fromRGB(255, 140, 140)
		output.Text = tostring(reply or (if ok then "Done." else "No reply."))
		busy = false
	end

	-- Tabs
	local tabBar = make("Frame", {
		Position = UDim2.new(0, 12, 0, 40),
		Size = UDim2.new(1, -24, 0, 28),
		BackgroundTransparency = 1,
	}, frame)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, tabBar)
	local body = make("Frame", {
		Position = UDim2.new(0, 12, 0, 76),
		Size = UDim2.new(1, -24, 1, -196),
		BackgroundTransparency = 1,
	}, frame)

	local pages: { [string]: Frame } = {}
	local tabButtons: { [string]: TextButton } = {}
	local function showTab(name: string)
		for n, page in pages do
			page.Visible = n == name
			tabButtons[n].BackgroundColor3 = if n == name then COLORS.go else COLORS.button
		end
	end
	local function addTab(name: string, order: number): Frame
		local b = make("TextButton", {
			Text = name,
			Size = UDim2.new(0, 110, 1, 0),
			BackgroundColor3 = COLORS.button,
			TextColor3 = COLORS.text,
			Font = Enum.Font.GothamMedium,
			TextSize = 14,
			LayoutOrder = order,
		}, tabBar)
		local page =
			make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, body)
		pages[name] = page
		tabButtons[name] = b
		b.Activated:Connect(function()
			showTab(name)
		end)
		return page
	end

	-- Small widgets ------------------------------------------------------
	local function label(text: string, parent: Instance, width: number?): TextLabel
		return make("TextLabel", {
			Text = text,
			Size = UDim2.new(0, width or 90, 0, 28),
			BackgroundTransparency = 1,
			TextColor3 = COLORS.dim,
			Font = Enum.Font.Gotham,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, parent)
	end
	local function button(text: string, parent: Instance, color: Color3?, width: number?): TextButton
		return make("TextButton", {
			Text = text,
			Size = UDim2.new(0, width or 96, 0, 28),
			BackgroundColor3 = color or COLORS.button,
			TextColor3 = COLORS.text,
			Font = Enum.Font.GothamMedium,
			TextSize = 13,
			AutoButtonColor = true,
		}, parent)
	end
	local function field(placeholder: string, parent: Instance, width: number?): TextBox
		return make("TextBox", {
			PlaceholderText = placeholder,
			Text = "",
			Size = UDim2.new(0, width or 140, 0, 28),
			BackgroundColor3 = COLORS.field,
			TextColor3 = COLORS.text,
			PlaceholderColor3 = Color3.fromRGB(120, 130, 140),
			Font = Enum.Font.Gotham,
			TextSize = 13,
			ClearTextOnFocus = false,
		}, parent)
	end
	-- A button that cycles through `options`; returns a getter.
	local function picker(options: { string }, parent: Instance, width: number?): () -> string
		local index = 1
		local b = button((options[1] or "-") .. "  >", parent, COLORS.field, width or 130)
		b.Activated:Connect(function()
			index = index % math.max(1, #options) + 1
			b.Text = (options[index] or "-") .. "  >"
		end)
		return function()
			return options[index] or ""
		end
	end
	local function row(parent: Instance, order: number): Frame
		local r = make("Frame", {
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundTransparency = 1,
			LayoutOrder = order,
		}, parent)
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}, r)
		return r
	end
	local function stack(parent: Instance): Frame
		make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, parent)
		return parent :: Frame
	end

	-- Players tab ------------------------------------------------------
	local playersPage = addTab("Players", 1)
	local playerList = make("ScrollingFrame", {
		Size = UDim2.new(0, 170, 1, 0),
		BackgroundColor3 = COLORS.panel,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, playersPage)
	make("UIListLayout", { Padding = UDim.new(0, 4) }, playerList)
	make(
		"UIPadding",
		{ PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) },
		playerList
	)

	local actions = make("Frame", {
		Position = UDim2.new(0, 180, 0, 0),
		Size = UDim2.new(1, -180, 1, 0),
		BackgroundTransparency = 1,
	}, playersPage)
	stack(actions)

	local selected: string? = nil
	local selectedLabel = label("Pick a player on the left.", row(actions, 0), 400)
	selectedLabel.TextColor3 = COLORS.accent
	selectedLabel.Font = Enum.Font.GothamBold

	local function withPlayer(build: (string) -> string): () -> ()
		return function()
			if not selected then
				output.Text = "Pick a player first."
				return
			end
			run(build(selected))
		end
	end

	local note = field("Note (optional, saved in the log)", row(actions, 1), 300)
	local function n(): string
		return if note.Text ~= "" then " " .. quote(note.Text) else ""
	end

	local r1 = row(actions, 2)
	button("View record", r1, COLORS.go, 120).Activated:Connect(withPlayer(function(p)
		return "/record " .. p
	end))
	button("Approve next Trial", r1, nil, 150).Activated:Connect(withPlayer(function(p)
		return "/trial " .. p .. " approve" .. n()
	end))

	local r2 = row(actions, 3)
	label("Rank", r2, 60)
	local rankBox = field("e.g. 2", r2, 60)
	button("Set rank", r2).Activated:Connect(withPlayer(function(p)
		return "/rank " .. p .. " " .. (if rankBox.Text ~= "" then rankBox.Text else "0") .. n()
	end))

	-- Class locks the character to one weapon (Lancer = spear only); the
	-- server equips it automatically. The kit row sets that weapon's level.
	local rc = row(actions, 4)
	label("Class", rc, 60)
	local class = picker(sortedKeys(Classes), rc, 130)
	button("Set class", rc, COLORS.go).Activated:Connect(withPlayer(function(p)
		return "/class " .. p .. " " .. class()
	end))

	local r3 = row(actions, 5)
	label("Kit level", r3, 60)
	local weapon = picker(sortedKeys(Kits), r3, 110)
	local levelBox = field("level", r3, 50)
	button("Grant", r3, COLORS.go, 70).Activated:Connect(withPlayer(function(p)
		return "/kit "
			.. p
			.. " grant "
			.. weapon()
			.. " "
			.. (if levelBox.Text ~= "" then levelBox.Text else "1")
			.. n()
	end))
	button("Revoke", r3, COLORS.stop, 70).Activated:Connect(withPlayer(function(p)
		return "/kit " .. p .. " revoke " .. weapon() .. n()
	end))

	local r4 = row(actions, 6)
	label("G ability", r4, 60)
	local ability = picker(sortedKeys(GAbilities), r4, 130)
	local source = picker({ "Lore", "Event", "Contribution", "Purchase" }, r4, 100)
	button("Grant", r4, COLORS.go, 70).Activated:Connect(withPlayer(function(p)
		return "/gability " .. p .. " grant " .. ability() .. " " .. source() .. n()
	end))
	button("Revoke", r4, COLORS.stop, 70).Activated:Connect(withPlayer(function(p)
		return "/gability " .. p .. " revoke " .. ability() .. n()
	end))

	local factionKeys = sortedKeys(WorldConfig.Factions)
	local r5 = row(actions, 7)
	label("Faction", r5, 60)
	local faction = picker(factionKeys, r5, 120)
	local roleBox = field("role key", r5, 110)
	button("Set", r5, nil, 70).Activated:Connect(withPlayer(function(p)
		local f = faction()
		local role = roleBox.Text
		if role == "" then
			role = (WorldConfig.Factions[f] :: any).defaultRole or ""
		end
		return "/faction " .. p .. " " .. f .. " " .. role .. n()
	end))

	local r6 = row(actions, 8)
	label("Access", r6, 60)
	button("Whitelist", r6, COLORS.go).Activated:Connect(withPlayer(function(p)
		return "/whitelist add " .. p .. n()
	end))
	button("Remove", r6, COLORS.stop).Activated:Connect(withPlayer(function(p)
		return "/whitelist remove " .. p .. n()
	end))
	button("Trade log", r6).Activated:Connect(withPlayer(function(p)
		return "/tradelog " .. p .. " hours=24"
	end))

	local function refreshPlayers()
		for _, child in playerList:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		for _, plr in Players:GetPlayers() do
			local b = make("TextButton", {
				Text = plr.DisplayName .. "\n@" .. plr.Name,
				Size = UDim2.new(1, 0, 0, 38),
				BackgroundColor3 = if plr.Name == selected then COLORS.go else COLORS.button,
				TextColor3 = COLORS.text,
				Font = Enum.Font.Gotham,
				TextSize = 12,
			}, playerList)
			b.Activated:Connect(function()
				selected = plr.Name
				selectedLabel.Text = "Selected: " .. plr.DisplayName .. " (@" .. plr.Name .. ")"
				refreshPlayers()
			end)
		end
	end
	Players.PlayerAdded:Connect(refreshPlayers)
	Players.PlayerRemoving:Connect(function()
		task.defer(refreshPlayers)
	end)

	-- PD tab -------------------------------------------------------------
	local pdPage = stack(addTab("PD event", 2))
	local p1 = row(pdPage, 1)
	button("Status", p1, COLORS.go).Activated:Connect(function()
		run("/pd status")
	end)
	button("History", p1).Activated:Connect(function()
		run("/pd history")
	end)
	local p2 = row(pdPage, 2)
	local eventName = field("Event name", p2, 220)
	button("Start PD", p2, COLORS.go, 110).Activated:Connect(function()
		run("/pd start " .. quote(if eventName.Text ~= "" then eventName.Text else "PD event"))
	end)
	local p3 = row(pdPage, 3)
	label("Phase", p3, 60)
	local phaseNames = {}
	for _, phase in (PDPhases :: any).Order or { "Preparation", "Development", "Conflict", "Resolution" } do
		table.insert(phaseNames, phase)
	end
	local phase = picker(phaseNames, p3, 140)
	button("Set phase", p3).Activated:Connect(function()
		run("/pd phase " .. phase())
	end)
	local p4 = row(pdPage, 4)
	local reason = field("Reason / summary", p4, 220)
	button("Pause", p4).Activated:Connect(function()
		run("/pd pause " .. quote(reason.Text))
	end)
	button("Resume", p4).Activated:Connect(function()
		run("/pd resume")
	end)
	button("End PD", p4, COLORS.stop).Activated:Connect(function()
		run("/pd end " .. quote(reason.Text))
	end)

	-- Deaths tab ---------------------------------------------------------
	local deathPage = stack(addTab("Deaths", 3))
	local d1 = row(deathPage, 1)
	button("Show pending", d1, COLORS.go, 120).Activated:Connect(function()
		run("/death list")
	end)
	local d2 = row(deathPage, 2)
	local reportBox = field("Report id", d2, 120)
	local circumstances = field("Circumstances / reason", d2, 240)
	local d3 = row(deathPage, 3)
	button("Confirm death", d3, COLORS.stop, 130).Activated:Connect(function()
		run("/death confirm " .. reportBox.Text .. " " .. quote(circumstances.Text))
	end)
	button("Dismiss report", d3, nil, 130).Activated:Connect(function()
		run("/death dismiss " .. reportBox.Text .. " " .. quote(circumstances.Text))
	end)
	label("Confirming makes the death permanent (GDD 3.4).", row(deathPage, 4), 400)

	-- Command tab --------------------------------------------------------
	local cmdPage = stack(addTab("Command", 4))
	local c1 = row(cmdPage, 1)
	local commandBox = field("/command ...  (try /staff)", c1, 480)
	button("Run", c1, COLORS.go, 80).Activated:Connect(function()
		if commandBox.Text ~= "" then
			run(commandBox.Text)
		end
	end)
	commandBox.FocusLost:Connect(function(enter)
		if enter and commandBox.Text ~= "" then
			run(commandBox.Text)
		end
	end)
	button("List commands", row(cmdPage, 2), nil, 130).Activated:Connect(function()
		run("/staff")
	end)

	showTab("Players")
	gui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if gui.Enabled then
			refreshPlayers()
		end
	end)

	-- L toggles. The server refuses non-staff, so the panel never opens for them.
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= OPEN_KEY then
			return
		end
		if gui.Enabled then
			gui.Enabled = false
			return
		end
		local ok = Net.Invoke("StaffCommand", "/staff")
		if ok then
			refreshPlayers()
			gui.Enabled = true
		end
	end)
end

return StaffPanelController
