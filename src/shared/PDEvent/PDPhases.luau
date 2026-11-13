--!strict
-- PD event states and phases shared by server and client.
--
-- State answers "is a PD running right now?" and is what other systems gate on.
-- Phase is the organisational label from GDD §3.2. Phases are guidelines, not
-- restrictions (§3.2), so any phase may follow any other while an event runs.

local PDPhases = {}

PDPhases.State = table.freeze({
	Inactive = "Inactive", -- no event; trading, satchels and PD deaths are all off
	Active = "Active", -- event running; everything event-gated is on
	Paused = "Paused", -- event exists but is halted; event-gated systems are off
})

PDPhases.Phase = table.freeze({
	Preparation = "Preparation",
	Development = "Development",
	Conflict = "Conflict",
	Resolution = "Resolution",
})

PDPhases.Order = table.freeze({
	PDPhases.Phase.Preparation,
	PDPhases.Phase.Development,
	PDPhases.Phase.Conflict,
	PDPhases.Phase.Resolution,
})

function PDPhases.IsValidPhase(phase: any): boolean
	return type(phase) == "string" and PDPhases.Phase[phase] ~= nil
end

-- Case-insensitive lookup so staff can type "/pd phase conflict".
function PDPhases.Normalize(phase: string): string?
	local lower = string.lower(phase)
	for _, name in PDPhases.Order do
		if string.lower(name) == lower then
			return name
		end
	end
	return nil
end

return table.freeze(PDPhases)
