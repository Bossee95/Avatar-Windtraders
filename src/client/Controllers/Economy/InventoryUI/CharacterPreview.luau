--!strict
--[[
	CharacterPreview: a live 3D copy of the local character in a ViewportFrame,
	so the inventory shows what the character is wearing and holding.

	The copy is rebuilt with :Refresh() (on open and when the equipped weapon
	changes). Drag with the mouse or a finger, or use the right thumbstick, to
	turn it. It plays the character's own idle animation when one is found.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)

local LocalPlayer = Players.LocalPlayer

local DRAG_SPEED = 0.012 -- radians per pixel
local FIELD_OF_VIEW = 28
local FRAME_MARGIN = 1.25 -- 25% breathing room around the body

local STRIP_CLASSES = {
	"Script",
	"LocalScript",
	"Sound",
	"ForceField",
	"BillboardGui",
	"ProximityPrompt",
	"ParticleEmitter",
	"Trail",
	"Beam",
	"Highlight",
}

local CharacterPreview = {}
CharacterPreview.__index = CharacterPreview

export type CharacterPreview = typeof(setmetatable(
	{} :: {
		viewport: ViewportFrame,
		world: WorldModel,
		camera: Camera,
		model: Model?,
		basePivot: CFrame,
		yaw: number,
		dragging: boolean,
		lastX: number,
		connections: { RBXScriptConnection },
	},
	CharacterPreview
))

function CharacterPreview.new(parent: Instance): CharacterPreview
	local viewport = Theme.make("ViewportFrame", {
		Name = "CharacterPreview",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Ambient = Color3.fromRGB(110, 140, 150),
		LightColor = Color3.fromRGB(220, 255, 250),
		LightDirection = Vector3.new(-0.6, -1, -0.8),
		Active = true,
		ZIndex = 2,
	}, parent)
	local world = Theme.make("WorldModel", {}, viewport)
	local camera = Theme.make("Camera", { FieldOfView = FIELD_OF_VIEW }, viewport)
	viewport.CurrentCamera = camera

	local self = setmetatable({
		viewport = viewport,
		world = world,
		camera = camera,
		model = nil,
		basePivot = CFrame.identity,
		yaw = 0,
		dragging = false,
		lastX = 0,
		connections = {},
	}, CharacterPreview)

	table.insert(
		self.connections,
		viewport.InputBegan:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				self.dragging = true
				self.lastX = input.Position.X
			end
		end)
	)
	table.insert(
		self.connections,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if
				self.dragging
				and (
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				self:Rotate((input.Position.X - self.lastX) * DRAG_SPEED)
				self.lastX = input.Position.X
			end
		end)
	)
	table.insert(
		self.connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				self.dragging = false
			end
		end)
	)
	return self
end

function CharacterPreview.Rotate(self: CharacterPreview, radians: number)
	self.yaw += radians
	local model = self.model
	if model then
		model:PivotTo(self.basePivot * CFrame.Angles(0, self.yaw, 0))
	end
end

local function idleAnimationId(source: Model): string?
	local animate = source:FindFirstChild("Animate")
	local idle = animate and animate:FindFirstChild("idle")
	if not idle then
		return nil
	end
	for _, child in idle:GetChildren() do
		if child:IsA("Animation") and child.AnimationId ~= "" then
			return child.AnimationId
		end
	end
	return nil
end

-- Moves the camera back until the whole body, head to feet, fits the
-- viewport with a margin, checking both height and width (the preview is
-- tall and narrow, so a wide weapon can be the limit).
function CharacterPreview.Frame(self: CharacterPreview)
	local model = self.model
	if not model then
		return
	end
	local pivot = model:GetPivot().Position
	local bottom, top, halfWidth = math.huge, -math.huge, 1
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local cf, size = part.CFrame, part.Size
			local half = (cf.RightVector * size.X / 2):Abs()
				+ (cf.UpVector * size.Y / 2):Abs()
				+ (cf.LookVector * size.Z / 2):Abs()
			bottom = math.min(bottom, cf.Position.Y - half.Y)
			top = math.max(top, cf.Position.Y + half.Y)
			local offset = cf.Position - pivot
			-- The copy turns, so use the larger of the X and Z reach.
			halfWidth = math.max(halfWidth, math.abs(offset.X) + half.X, math.abs(offset.Z) + half.Z)
		end
	end
	if bottom == math.huge then
		return
	end
	local height = math.max(top - bottom, 2)
	local absolute = self.viewport.AbsoluteSize
	local aspect = if absolute.X > 0 and absolute.Y > 0 then absolute.X / absolute.Y else 0.5
	local tanV = math.tan(math.rad(FIELD_OF_VIEW / 2))
	local tanH = tanV * aspect
	local fitHeight = (height / 2) / tanV
	local fitWidth = halfWidth / tanH + halfWidth
	local distance = math.max(fitHeight, fitWidth) * FRAME_MARGIN
	local target = Vector3.new(pivot.X, (top + bottom) / 2, pivot.Z)
	self.camera.CFrame = CFrame.lookAt(target + Vector3.new(0, 0, distance), target)
end

function CharacterPreview.Clear(self: CharacterPreview)
	if self.model then
		self.model:Destroy()
		self.model = nil
	end
end

-- Rebuilds the copy from the player's current character.
function CharacterPreview.Refresh(self: CharacterPreview)
	self:Clear()
	local source = LocalPlayer.Character
	if not source then
		return
	end

	local wasArchivable = source.Archivable
	source.Archivable = true
	local ok, clone = pcall(function()
		return source:Clone()
	end)
	source.Archivable = wasArchivable
	if not ok or not clone then
		return
	end
	local model = clone :: Model

	for _, descendant in model:GetDescendants() do
		for _, className in STRIP_CLASSES do
			if descendant:IsA(className) then
				descendant:Destroy()
				break
			end
		end
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
		model.PrimaryPart = root
	end

	model:PivotTo(CFrame.new())
	model.Parent = self.world
	self.model = model

	self:Frame()
	self.basePivot = model:GetPivot()
	self:Rotate(0)

	local animationId = idleAnimationId(source)
	if humanoid and animationId then
		local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
		animator.Parent = humanoid
		local animation = Instance.new("Animation")
		animation.AnimationId = animationId
		local loaded, track = pcall(function()
			return (animator :: Animator):LoadAnimation(animation)
		end)
		if loaded and track then
			track.Looped = true
			track:Play(0)
		end
	end
end

-- Turns the copy back to face the camera (on open).
function CharacterPreview.ResetRotation(self: CharacterPreview)
	self.yaw = 0
	self:Rotate(0)
end

return CharacterPreview
