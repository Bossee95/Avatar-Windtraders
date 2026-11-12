--[[
	Server entry point. Creates every registered remote, then starts every
	*Service under Server/Services (see Shared/Loader).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

Net.CreateAll()
Loader.Start(script.Parent.Services, "Service")
