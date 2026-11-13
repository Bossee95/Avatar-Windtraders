--[[
	FacilityController

	Minimal client side for facilities: proximity prompts only, until a proper build
	and territory UI exists. The server decides everything.

	Build zones: a "Build" prompt places the zone's suggested facility (attribute
	Facility on the BuildZone part) or, without one, the first type the player's
	faction can build.
	Facilities: "Deposit" hands over every outstanding material the player carries,
	"Work" does one build channel, "Repair" one repair channel.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Net = require(ReplicatedStorage.Shared.Net)
local Facilities = require(ReplicatedStorage.Shared.Territory.Config.Facilities)

local FacilityController = {}

local snapshots = {} -- facilityId -> latest snapshot
local myFaction = nil

local function notify(text)
	pcall(StarterGui.SetCore, StarterGui, "SendNotification", { Title = "Facilities", Text = text, Duration = 3 })
end

local function prompt(part, action, object, onTriggered)
	local p = Instance.new("ProximityPrompt")
	p.ActionText = action
	p.ObjectText = object
	p.RequiresLineOfSight = false
	p.MaxActivationDistance = 25
	p.Parent = part
	p.Triggered:Connect(onTriggered)
	return p
end

local function defaultTypeFor(faction)
	local keys = {}
	for key, def in pairs(Facilities) do
		if table.find(def.factions, faction) then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return keys[1]
end

local function setupZone(part)
	local zoneId = part:GetAttribute("ZoneId") or part:GetFullName()
	prompt(part, "Build", "Build zone", function()
		local typeId = part:GetAttribute("Facility") or defaultTypeFor(myFaction)
		if not typeId then
			notify("Your faction can't build here.")
			return
		end
		local ok, result = Net.Invoke("FacilityPlace", typeId, zoneId)
		notify(ok and ("Started " .. Facilities[typeId].displayName) or ("Can't build: " .. tostring(result)))
	end)
end

local function setupFacility(model)
	local id = model:GetAttribute("FacilityId")
	local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not id or not part or part:FindFirstChildOfClass("ProximityPrompt") then
		return
	end
	prompt(part, "Deposit", "Materials", function()
		local snap = snapshots[id]
		local total = 0
		for itemId, qty in pairs(snap and snap.outstanding or {}) do
			local ok, accepted = Net.Invoke("FacilityContribute", id, itemId, qty)
			if ok then
				total = total + accepted
			end
		end
		notify(total > 0 and ("Deposited " .. total .. " materials") or "Nothing to deposit")
	end).KeyboardKeyCode = Enum.KeyCode.F
	prompt(part, "Work", "Construction", function()
		local ok, result = Net.Invoke("FacilityWork", id)
		if not ok then
			notify("Can't work: " .. tostring(result))
		end
	end).KeyboardKeyCode = Enum.KeyCode.E
	prompt(part, "Repair", "Facility", function()
		local ok, result = Net.Invoke("FacilityRepair", id)
		if not ok then
			notify("Can't repair: " .. tostring(result))
		end
	end).KeyboardKeyCode = Enum.KeyCode.R
end

function FacilityController:Start()
	Net.OnEvent("AccountState", function(state)
		for _, c in ipairs(state.characters or {}) do
			if c.id == state.activeCharacterId then
				myFaction = c.faction
			end
		end
	end)
	Net.OnEvent("FacilityState", function(snap)
		snapshots[snap.id] = (not snap.removed) and snap or nil
	end)

	for _, part in ipairs(CollectionService:GetTagged("BuildZone")) do
		setupZone(part)
	end
	CollectionService:GetInstanceAddedSignal("BuildZone"):Connect(setupZone)

	local folder = workspace:WaitForChild("Facilities", 30)
	if folder then
		local function watch(model)
			if model:IsA("Model") then
				if model:GetAttribute("FacilityId") then
					setupFacility(model)
				else
					model:GetAttributeChangedSignal("FacilityId"):Once(function()
						setupFacility(model)
					end)
				end
			end
		end
		for _, model in ipairs(folder:GetChildren()) do
			watch(model)
		end
		folder.ChildAdded:Connect(watch)
	end
end

return FacilityController
