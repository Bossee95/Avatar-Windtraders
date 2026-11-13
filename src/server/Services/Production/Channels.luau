--[[
	Channels

	Timed, cancellable actions (gathering, crafting). One channel per player. The
	server re-checks `stillValid` every ChannelCheckInterval and cancels on failure,
	on combat, or on leaving. `onComplete` runs once, without yielding, when the time
	is up and the channel is still valid.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local ProductionConfig = require(ReplicatedStorage.Shared.Production.ProductionConfig)
local Deps = require(script.Parent.ProductionDeps)

local Channels = {}

local active = {} -- player -> channel

local function finish(player, channel, ok, reason, items)
	if active[player] ~= channel then
		return
	end
	active[player] = nil
	channel.done = true
	if player.Parent then
		Net.Fire("ChannelEnded", player, { kind = channel.kind, id = channel.id, ok = ok, reason = reason, items = items })
	end
end

function Channels.IsBusy(player)
	return active[player] ~= nil
end

function Channels.Cancel(player, reason)
	local channel = active[player]
	if channel then
		finish(player, channel, false, reason or "Cancelled")
	end
end

--[[
	spec:
		kind, id      shown to the client
		duration      seconds
		stillValid    function() -> ok, reason
		onComplete    function() -> ok, reason, items
]]
function Channels.Start(player, spec)
	if active[player] then
		return false, "Busy"
	end
	local channel = { kind = spec.kind, id = spec.id }
	active[player] = channel
	task.spawn(function()
		local elapsed = 0
		while elapsed < spec.duration do
			local dt = task.wait(math.min(ProductionConfig.ChannelCheckInterval, spec.duration - elapsed))
			elapsed = elapsed + dt
			if channel.done then
				return
			end
			if ProductionConfig.CancelChannelOnCombat and Deps.inCombat(player) then
				finish(player, channel, false, "InCombat")
				return
			end
			local ok, reason = spec.stillValid()
			if not ok then
				finish(player, channel, false, reason)
				return
			end
		end
		if channel.done then
			return
		end
		local ok, reason = spec.stillValid()
		if not ok then
			finish(player, channel, false, reason)
			return
		end
		local done, err, items = spec.onComplete()
		finish(player, channel, done, err, items)
	end)
	return true
end

Players.PlayerRemoving:Connect(function(player)
	active[player] = nil
end)

return Channels
