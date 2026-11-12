--!strict
--[[
	Shared record types. See docs/CORE_API.md for the meaning of each field.
]]

export type CharacterStatus = "Alive" | "Dead"

export type TrialEntry = {
	id: string,
	approvedBy: number,
	at: number,
}

export type KitEntry = {
	level: number,
	grantedBy: number,
	at: number,
}

export type AbilityEntry = {
	source: string, -- "Purchase" | "Lore" | "Event" | "Contribution" | other approved method
	grantedBy: number,
	at: number,
}

export type LogEntry = {
	at: number,
	actor: number,
	action: string,
	details: { [string]: any }?,
}

export type DeathRecord = {
	at: number,
	pdEventId: string,
	confirmedBy: number,
	reason: string?,
	final: {
		faction: string,
		role: string,
		rank: number,
		trials: { TrialEntry },
		kits: { [string]: KitEntry },
		abilities: { [string]: AbilityEntry },
	},
}

export type Character = {
	id: string,
	userId: number,
	name: string,
	faction: string,
	role: string,
	status: CharacterStatus,
	createdAt: number,
	rank: number,
	trials: { TrialEntry },
	kits: { [string]: KitEntry },
	abilities: { [string]: AbilityEntry },
	sections: { [string]: any },
	log: { LogEntry },
	death: DeathRecord?,
}

export type Account = {
	schemaVersion: number,
	userId: number,
	createdAt: number,
	activeCharacterId: string?,
	characterOrder: { string },
	characters: { [string]: Character },
	nextCharacterSeq: number,
	sections: { [string]: any },
}

-- What clients are allowed to see about a character.
export type CharacterSummary = {
	id: string,
	name: string,
	faction: string,
	role: string,
	status: CharacterStatus,
	rank: number,
}

return {}
