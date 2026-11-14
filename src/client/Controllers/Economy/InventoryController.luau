--!strict
--[[
	InventoryController: the client's copy of the active character's carried
	items. The server pushes the full list on every change (InventoryUpdated).

	Public API for UI code:
	  InventoryController:GetItems() -> { { uid, itemId, quantity } }
	  InventoryController:GetDefinition(itemId) -> item definition?
	  InventoryController.Changed  Signal(items)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local ItemRegistry = require(Shared.Economy.ItemRegistry)
local ItemDefinitions = require(Shared.Economy.ItemDefinitions)

export type Item = { uid: string, itemId: string, quantity: number }

local InventoryController = {}

InventoryController.Changed = Signal.new() -- (items)

local registry = ItemRegistry.new(ItemDefinitions)
local items: { Item } = {}
local received = false

local function setItems(payload: any)
	if type(payload) ~= "table" or type(payload.items) ~= "table" then
		return
	end
	received = true
	items = payload.items
	InventoryController.Changed:Fire(items)
end

function InventoryController:GetItems(): { Item }
	return items
end

function InventoryController:GetDefinition(itemId: string): any
	return registry:Get(itemId)
end

function InventoryController:Start()
	Net.OnEvent("InventoryUpdated", setItems)
	if not received then
		local payload = Net.Invoke("GetInventory")
		if not received then
			setItems(payload)
		end
	end
end

return InventoryController
