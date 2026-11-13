--!strict
-- Shows staff command replies and alerts (e.g. new death reports) as system
-- messages in chat. Only staff ever receive StaffMessage.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Net = require(ReplicatedStorage.Shared.Net)

local StaffController = {}

local COLORS = {
	info = "#9ad1ff",
	alert = "#ffcf6b",
	error = "#ff7b7b",
}

local function escape(text: string): string
	return (string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
end

function StaffController:Start()
	Net.OnEvent("StaffMessage", function(text: string, kind: string)
		local channels = TextChatService:FindFirstChild("TextChannels")
		local channel = channels and channels:FindFirstChild("RBXSystem") or (channels and channels:FindFirstChild("RBXGeneral"))
		if channel == nil or not channel:IsA("TextChannel") then
			print("[Staff]", text)
			return
		end
		local color = COLORS[kind] or COLORS.info
		for _, line in string.split(text, "\n") do
			channel:DisplaySystemMessage(`<font color="{color}">[Staff] {escape(line)}</font>`)
		end
	end)
end

return StaffController
