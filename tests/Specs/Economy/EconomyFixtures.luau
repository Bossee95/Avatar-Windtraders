-- Shared setup for the economy specs: a test item registry, a manual clock and
-- scheduler, fake players and a world state the engines read through their deps.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = ServerScriptService.Server.Services.Economy
local SharedEconomy = ReplicatedStorage.Shared.Economy

local ItemRegistry = require(SharedEconomy.ItemRegistry)
local EconomyConfig = require(SharedEconomy.EconomyConfig)
local InventoryStore = require(Economy.InventoryStore)
local TradeLog = require(Economy.TradeLog)
local TradeEngine = require(Economy.TradeEngine)
local SatchelEngine = require(Economy.SatchelEngine)

local Fixtures = {}

Fixtures.Items = {
	{ id = "Weapon.Sword", name = "Sword", description = "A sword.", category = "Weapon", variationId = "Sword_Standard" },
	{ id = "Material.Common", name = "Common Material", description = "Plentiful.", category = "Material", stackable = true, maxStack = 50 },
	{ id = "Material.Rare", name = "Rare Material", description = "Scarce.", category = "Material", stackable = true },
	{ id = "Special.Heirloom", name = "Heirloom", description = "Bound.", category = "Special", untradeable = true },
}

local function copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

-- Builds a full test world. overrides: config fields to change.
function Fixtures.world(overrides)
	local w = { time = 0, timers = {}, players = {} }
	w.config = copy(EconomyConfig)
	for k, v in pairs(overrides or {}) do
		w.config[k] = v
	end
	w.pdActive = true
	w.pdEventId = "pd-1"
	w.inCombat = {}

	w.registry = ItemRegistry.new(Fixtures.Items)
	w.inventory = InventoryStore.new({ registry = w.registry })
	w.log = TradeLog.new({
		now = function()
			return w.time
		end,
	})

	function w.now()
		return w.time
	end
	function w.delay(seconds, fn)
		local timer = { at = w.time + seconds, fn = fn }
		table.insert(w.timers, timer)
		return function()
			timer.cancelled = true
		end
	end
	-- Advances the clock and runs due timers in order.
	function w.advance(seconds)
		w.time = w.time + seconds
		local ran = true
		while ran do
			ran = false
			for i, timer in ipairs(w.timers) do
				if timer.at <= w.time then
					table.remove(w.timers, i)
					if not timer.cancelled then
						timer.fn()
					end
					ran = true
					break
				end
			end
		end
	end

	function w.player(userId, faction)
		local p = { UserId = userId, faction = faction or "FactionA", characterId = tostring(userId) .. "-1", position = 0 }
		w.players[userId] = p
		return p
	end
	function w.charKey(p)
		return w.inventory.Container.Character(p.characterId)
	end
	function w.give(p, itemId, qty)
		return w.inventory:Grant(w.charKey(p), itemId, qty)[1]
	end

	w.trades = TradeEngine.new({
		inventory = w.inventory,
		registry = w.registry,
		log = w.log,
		config = w.config,
		now = w.now,
		delay = w.delay,
		getUserId = function(p)
			return p.UserId
		end,
		getCharacterId = function(p)
			return p.characterId
		end,
		getFaction = function(p)
			return p.faction
		end,
		isTradingOpen = function()
			return w.pdActive
		end,
		getPDEventId = function()
			return w.pdEventId
		end,
		isInCombat = function(p)
			return w.inCombat[p] == true
		end,
		getDistance = function(a, b)
			return math.abs(a.position - b.position)
		end,
	})

	w.satchels = SatchelEngine.new({
		inventory = w.inventory,
		registry = w.registry,
		log = w.log,
		config = w.config,
		now = w.now,
		isLootOpen = function(eventId)
			return w.pdActive and eventId == w.pdEventId
		end,
		getUserId = function(p)
			return p.UserId
		end,
		getCharacterId = function(p)
			return p.characterId
		end,
		getFaction = function(p)
			return p.faction
		end,
		getDistance = function(p, location)
			return math.abs(p.position - location)
		end,
	})
	return w
end

return Fixtures
