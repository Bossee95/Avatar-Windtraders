--[[
	Client entry point. Starts every *Controller under Client/Controllers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)

Loader.Start(script.Parent.Controllers, "Controller")
