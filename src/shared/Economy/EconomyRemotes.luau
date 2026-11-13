--[[
	Remote names used by the economy systems. They must also be listed in
	Shared.Net.Remotes (Events / Functions) so the server creates them at boot.

	Payloads:
		InventoryUpdated  S->C  { items = { {uid, itemId, quantity} } }

		TradeRequest      C->S  targetUserId                 -> ok, reason
		TradeRespond      C->S  tradeId, accept              -> ok, reason
		TradeSetOffer     C->S  tradeId, { {uid, quantity} } -> ok, reason
		TradeConfirm      C->S  tradeId                      -> ok, reason
		TradeCancel       C->S  tradeId                      -> ok, reason
		TradeState        S->C  trade description (TradeEngine:Describe), event name

		SatchelOpened     S->C  satchelId, { {uid, itemId, quantity} }
		SatchelLoot       C->S  satchelId, picks? ({ {uid, quantity?} } or nil for all) -> ok, reasonOrTaken
		SatchelClose      C->S  satchelId

		QueryTradeLog     C->S  query (staff with ViewTradeLogs only) -> entries
]]

return {
	Events = {
		"InventoryUpdated",
		"TradeState",
		"SatchelOpened",
		"SatchelClose",
	},
	Functions = {
		"TradeRequest",
		"TradeRespond",
		"TradeSetOffer",
		"TradeConfirm",
		"TradeCancel",
		"SatchelLoot",
		"QueryTradeLog",
	},
}
