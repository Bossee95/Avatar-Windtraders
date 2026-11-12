--!strict
-- Small always-visible banner telling every player whether a PD event is
-- running, since deaths during one are permanent (GDD §3.1). Reads the
-- attributes PDEventService replicates on ReplicatedStorage.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PDStatusController = {}

local function build(): TextLabel
	local gui = Instance.new("ScreenGui")
	gui.Name = "PDStatus"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.IgnoreGuiInset = false

	local label = Instance.new("TextLabel")
	label.Name = "Banner"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0, 6)
	label.Size = UDim2.fromOffset(0, 26)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.BackgroundTransparency = 0.25
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.Visible = false
	label.Parent = gui

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = label
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = label

	gui.Parent = (Players.LocalPlayer :: Player):WaitForChild("PlayerGui")
	return label
end

function PDStatusController:Start()
	local label = build()
	local function refresh()
		local state = ReplicatedStorage:GetAttribute("PDState")
		local name = ReplicatedStorage:GetAttribute("PDEventName") or ""
		local phase = ReplicatedStorage:GetAttribute("PDPhase") or ""
		if state == "Active" then
			label.Visible = true
			label.TextColor3 = Color3.fromRGB(255, 120, 120)
			label.Text = `PD ACTIVE: {name} ({phase}). Deaths are permanent.`
		elseif state == "Paused" then
			label.Visible = true
			label.TextColor3 = Color3.fromRGB(255, 210, 120)
			label.Text = `PD PAUSED: {name}`
		else
			label.Visible = false
		end
	end
	for _, attr in { "PDState", "PDEventName", "PDPhase" } do
		ReplicatedStorage:GetAttributeChangedSignal(attr):Connect(refresh)
	end
	refresh()
end

return PDStatusController
