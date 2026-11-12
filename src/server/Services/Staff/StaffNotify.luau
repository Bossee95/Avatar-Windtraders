--!strict
-- Sends staff-facing system messages to clients (shown in chat by
-- StaffController). Helper module, not a service.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local StaffService = require(script.Parent.StaffService)

local StaffNotify = {}

local MAX_LENGTH = 1500

local function send(player: Player, text: string, kind: string?)
	Net.Fire("StaffMessage", player, string.sub(text, 1, MAX_LENGTH), kind or "info")
end

function StaffNotify.Reply(player: Player, text: string, kind: string?)
	send(player, text, kind)
end

function StaffNotify.ToPermission(permission: string, text: string)
	for _, player in Players:GetPlayers() do
		if StaffService:HasPermission(player, permission) then
			send(player, text, "alert")
		end
	end
end

return StaffNotify
