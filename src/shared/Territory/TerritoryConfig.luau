--[[
	TerritoryConfig: tunables and open-decision flags for facilities, territory and
	entitlements (GDD §12, §13). See docs/design/gathering-crafting-territory.md §11.
]]

return {
	-- Factions that may build facilities and hold territory (design doc Q5:
	-- independents gather and craft but don't build or hold land).
	BuildingFactions = { FactionA = true, FactionB = true },

	-- Max facilities per faction (design doc Q4). nil = no cap.
	MaxFacilitiesPerFaction = 30,

	-- Building, damage and capture happen only during an active PD.
	BuildRequiresActivePD = true,

	-- Build work: one channel of WorkSeconds adds WorkPerChannel build points.
	WorkSeconds = 4,
	WorkPerChannel = 10,

	-- Repair: one channel of WorkSeconds restores RepairPerChannel health
	-- and costs RepairCost from the repairer's inventory.
	RepairPerChannel = 250,
	RepairCost = { ["Material.Common"] = 5 },

	-- Health while under construction starts at this share of maxHealth and
	-- grows with progress.
	ConstructionHealthShare = 0.1,

	-- Below this share of maxHealth a facility is Damaged and its stations stop.
	DamagedThreshold = 0.5,

	-- Capture progress lost per second (as a share of captureTime) when no
	-- attacker is present.
	CaptureDecayRate = 0.5,
	CaptureTickInterval = 0.5,

	-- Design doc Q1: in-game capture changes territory control immediately;
	-- Loreteam can override or lock it. Set false to require Loreteam ratification
	-- (capture then only records a pending result).
	CaptureChangesTerritoryImmediately = true,

	-- Who may gather in a territory: "Anyone" | "ControllerOrNeutral" | "ControllerOrContested".
	NodeAccess = "ControllerOrContested",
	-- Where a faction may build: "Owned" | "OwnedOrContested" | "OwnedOrNeutral".
	BuildAccess = "OwnedOrNeutral",

	-- Players may have this many open challenges at once.
	MaxOpenChallengesPerCharacter = 2,

	Range = 15, -- studs to place, contribute to, work on or repair a facility
}
