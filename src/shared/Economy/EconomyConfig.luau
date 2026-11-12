--[[
	EconomyConfig

	Tunables and open design decisions for inventory, trading and death satchels
	(GDD §8, §9, §16.2-16.4).

	Flags marked [GDD §19.x] are open design questions. Each is set to a provisional
	default so the systems can run, and should be revisited once the decision is made.
]]

local EconomyConfig = {
	-- [GDD §19.1] Inventory and storage on death.
	-- false: only items the character is carrying go into the death satchel. Separately
	-- stored items survive (they stay in the character's storage container, which is
	-- never handed to a new character).
	-- true: tradeable stored items are also moved into the satchel.
	StorageItemsDropOnDeath = false,

	-- [GDD §19.2] Who may loot a death satchel.
	--   "Anyone"       - any living character in the PD
	--   "SameFaction"  - only characters of the deceased's faction (ally recovery)
	--   "OtherFaction" - only characters of a different faction
	SatchelLootableBy = "Anyone",
	-- [GDD §19.2] Several players may loot one satchel at the same time. Every claim is
	-- atomic, so whoever claims an item first gets it and later claims fail cleanly.
	-- false: one looter at a time (a satchel is held by the first player to open it).
	SatchelConcurrentLooting = true,
	-- Whether the same player (on a new character) may loot their old character's satchel.
	SatchelOwnerCanLoot = false,
	-- Maximum distance (studs) between a looter and the satchel. nil disables the check.
	SatchelLootRange = 12,

	-- [GDD §19.3] Trading restrictions.
	BlockTradeInCombat = true,
	AllowCrossFactionTrade = true,
	-- Maximum distance (studs) between two traders. nil disables the check.
	TradeRange = 30,

	-- [GDD §19.4] Trading confirmation.
	TradeCountdownSeconds = 5,
	TradeRequestTimeoutSeconds = 30,
	-- Changing either offer clears both confirmations (always on; listed for clarity).
	TradeOfferChangeResetsConfirm = true,
	MaxItemsPerOffer = 16,

	-- [GDD §19.8] PD boundaries.
	-- false: trading stops while a PD is paused, and open trades are cancelled.
	TradeAllowedWhilePaused = false,
	-- false: satchels stay in the world while paused but cannot be looted.
	SatchelLootWhilePaused = false,

	-- How many trade log entries are kept in server memory for quick moderator queries.
	TradeLogMemoryLimit = 2000,
	-- DataStore that persists trade and satchel log entries.
	TradeLogDataStore = "EconomyTradeLog_v1",
}

return EconomyConfig
