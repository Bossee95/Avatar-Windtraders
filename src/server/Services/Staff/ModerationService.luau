--!strict
-- Moderation tools other than death review (GDD §2.5, §8.5, §16.4).
--
--   :QueryTradeLogs(actor, { playerUserId?, since?, until?, status? }) -> ({ any }?, err)  [ViewTradeLogs]
--
-- Trade records are owned by TradeLogService (inventory thread). Whitelist
-- management lives in AccessGateService; death confirmation in DeathReviewService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)

local AuditLogService = require(script.Parent.AuditLogService)
local StaffService = require(script.Parent.StaffService)

local P = Permissions.Permission

local ModerationService = {}

export type TradeLogQuery = {
	playerUserId: number?,
	since: number?,
	["until"]: number?,
	status: string?,
}

function ModerationService:QueryTradeLogs(actor: Player, query: TradeLogQuery): ({ any }?, string?)
	local allowed, permErr = StaffService:Require(actor, P.ViewTradeLogs)
	if not allowed then
		return nil, permErr
	end
	local ok, TradeLogService = pcall(Loader.Get, "TradeLogService")
	if not ok or TradeLogService == nil then
		return nil, "Trade logs are not available yet (TradeLogService is not loaded)."
	end
	local okQuery, result = pcall(TradeLogService.Query, TradeLogService, query)
	if not okQuery then
		return nil, `Trade log query failed: {result}`
	end
	-- Viewing trade records is itself recorded, for accountability.
	AuditLogService:Record(actor.UserId, "Mod.ViewTradeLogs", query.playerUserId, {
		since = query.since,
		["until"] = query["until"],
		status = query.status,
	})
	return result, nil
end

return ModerationService
