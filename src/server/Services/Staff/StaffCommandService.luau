--!strict
-- Chat commands for staff, plus a "StaffCommand" remote that runs the same
-- command lines so a staff UI can be built on top later.
--
-- Commands are typed in chat. Arguments with spaces go in quotes. Add
-- char=<characterId> to target a character other than the active one
-- (required when the player is offline). Type /staff for the list.
--
-- Every command calls a permission-checked service method; this file only
-- parses text and formats replies.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Net = require(ReplicatedStorage.Shared.Net)
local PDPhases = require(ReplicatedStorage.Shared.PDEvent.PDPhases)
local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)

local AccessGateService = require(script.Parent.AccessGateService)
local CommandParser = require(script.Parent.CommandParser)
local AuditLogService = require(script.Parent.AuditLogService)
local DeathReviewService = require(script.Parent.DeathReviewService)
local DevToolsService = require(script.Parent.DevToolsService)
local LoreteamService = require(script.Parent.LoreteamService)
local ModerationService = require(script.Parent.ModerationService)
local StaffNotify = require(script.Parent.StaffNotify)
local StaffService = require(script.Parent.StaffService)
local StaffTargets = require(script.Parent.StaffTargets)
local PDEventService = require(script.Parent.Parent.PDEvent.PDEventService)

local DataService: any = nil

local P = Permissions.Permission

type Args = { string }
type Opts = { [string]: string }
type Handler = (player: Player, args: Args, opts: Opts) -> string

type Command = {
	alias: string,
	usage: { string },
	-- Shown in /staff only to players holding at least one of these.
	permissions: { string },
	run: Handler,
}

local StaffCommandService = {}

--------------------------------------------------------------------------
-- Parsing

local function rest(args: Args, from: number): string?
	if #args < from then
		return nil
	end
	return table.concat(args, " ", from)
end

local function fmtTime(t: number?): string
	if t == nil then
		return "-"
	end
	return os.date("!%Y-%m-%d %H:%M UTC", t) :: string
end

local function done(ok: boolean, err: string?, success: string): string
	return if ok then success else `Failed: {err}`
end

local function needTarget(args: Args, index: number): (number?, string?)
	local text = args[index]
	if text == nil then
		return nil, "Name a player (username or user id)."
	end
	return StaffTargets.ResolveUserId(text)
end

--------------------------------------------------------------------------
-- Commands

local commands: { [string]: Command } = {}

local function register(command: Command)
	commands[command.alias] = command
end

register({
	alias = "/pd",
	usage = {
		"/pd status",
		'/pd start "<event name>" [phase]',
		"/pd pause [reason]",
		"/pd resume",
		"/pd phase <Preparation|Development|Conflict|Resolution>",
		"/pd end [summary]",
		"/pd forceend [summary]  (ends even with unreviewed death reports)",
		"/pd history",
	},
	permissions = { P.ControlPDEvent, P.PausePDEvent },
	run = function(player, args)
		local sub = string.lower(args[1] or "status")
		if sub == "status" then
			local event = PDEventService:GetActiveEvent()
			if event == nil then
				return "No PD event is running."
			end
			local record = PDEventService:GetRecord()
			local pending = DeathReviewService:GetPendingCount(event.id)
			local lastPause = record and record.pauseLog[#record.pauseLog]
			local pauseText = if event.paused and lastPause then ` Paused: {lastPause.reason}.` else ""
			return `PD "{event.name}" ({event.id}) is {event.state}, phase {event.phase}. Started {fmtTime(event.startedAt)} by {StaffTargets.DisplayName(event.startedBy)}. Death reports awaiting review: {pending}.{pauseText}`
		elseif sub == "start" then
			local name = args[2]
			if name == nil then
				return 'Usage: /pd start "<event name>" [phase]'
			end
			local phase = args[3] and PDPhases.Normalize(args[3]) or nil
			if args[3] and phase == nil then
				return `Unknown phase "{args[3]}".`
			end
			local ok, err = PDEventService:StartEvent(player, name, phase)
			return done(ok, err, `PD event "{name}" started.`)
		elseif sub == "pause" then
			local ok, err = PDEventService:PauseEvent(player, rest(args, 2))
			return done(ok, err, "PD event paused. Trading, satchel looting and PD deaths are off until resumed.")
		elseif sub == "resume" then
			local ok, err = PDEventService:ResumeEvent(player)
			return done(ok, err, "PD event resumed.")
		elseif sub == "phase" then
			local phase = args[2] and PDPhases.Normalize(args[2])
			if phase == nil then
				return `Usage: /pd phase <{table.concat(PDPhases.Order, "|")}>`
			end
			local ok, err = PDEventService:SetPhase(player, phase)
			return done(ok, err, `Phase set to {phase}.`)
		elseif sub == "end" or sub == "forceend" then
			local ok, err = PDEventService:EndEvent(player, rest(args, 2), sub == "forceend")
			return done(ok, err, "PD event ended. Remaining death satchels are removed and trading is closed.")
		elseif sub == "history" then
			local history = PDEventService:GetHistory(5)
			if #history == 0 then
				return "No past PD events recorded."
			end
			local lines = { "Recent PD events:" }
			for _, e in history do
				table.insert(lines, `{e.id} "{e.name}" {fmtTime(e.startedAt)} to {fmtTime(e.endedAt)}{if e.summary then ": " .. e.summary else ""}`)
			end
			return table.concat(lines, "\n")
		end
		return "Unknown /pd command. Type /staff for help."
	end,
})

register({
	alias = "/record",
	usage = { "/record <player> [char=<id>]" },
	permissions = { P.ViewRecords },
	run = function(player, args, opts)
		if not StaffService:HasPermission(player, P.ViewRecords) then
			return "You do not have permission to do that."
		end
		local userId, err = needTarget(args, 1)
		if userId == nil then
			return err :: string
		end
		local c, cErr = StaffTargets.GetCharacter(DataService, userId, opts.char)
		if c == nil then
			return cErr :: string
		end
		local trials = {}
		for _, t in c.trials do
			table.insert(trials, t.id)
		end
		local kits = {}
		for weaponType, kit in c.kits do
			table.insert(kits, `{weaponType} L{kit.level}`)
		end
		local abilities = {}
		for abilityId, a in c.abilities do
			table.insert(abilities, `{abilityId} ({a.source})`)
		end
		return `{c.name} [{c.id}] {c.faction}/{c.role}, {c.status}, rank {c.rank}\nTrials: {if #trials > 0 then table.concat(trials, ", ") else "none"}\nKits: {if #kits > 0 then table.concat(kits, ", ") else "none"}\nG abilities: {if #abilities > 0 then table.concat(abilities, ", ") else "none"}`
	end,
})

register({
	alias = "/faction",
	usage = { "/faction <player> <factionKey> <roleKey> [note] [char=<id>]" },
	permissions = { P.ManageRanks },
	run = function(player, args, opts)
		local userId, err = needTarget(args, 1)
		if userId == nil then
			return err :: string
		end
		if args[2] == nil or args[3] == nil then
			return "Usage: /faction <player> <factionKey> <roleKey> [note]"
		end
		local ok, e = LoreteamService:SetFaction(player, userId, opts.char, args[2], args[3], rest(args, 4))
		return done(ok, e, `Faction set to {args[2]}/{args[3]}.`)
	end,
})

register({
	alias = "/rank",
	usage = { "/rank <player> <rank> [note] [char=<id>]" },
	permissions = { P.ManageRanks },
	run = function(player, args, opts)
		local userId, err = needTarget(args, 1)
		if userId == nil then
			return err :: string
		end
		local rank = tonumber(args[2] or "")
		if rank == nil then
			return "Usage: /rank <player> <rank> [note]"
		end
		local ok, e = LoreteamService:SetRank(player, userId, opts.char, rank, rest(args, 3))
		return done(ok, e, `Rank set to {rank}.`)
	end,
})

register({
	alias = "/trial",
	usage = {
		"/trial <player> approve [trialId] [note] [char=<id>]  (defaults to the next Trial in order)",
		"/trial <player> revoke <trialId> [note]  (also revokes later Trials)",
	},
	permissions = { P.ManageTrials },
	run = function(player, args, opts)
		local userId, err = needTarget(args, 1)
		if userId == nil then
			return err :: string
		end
		local sub = string.lower(args[2] or "")
		if sub == "approve" then
			local ok, e = LoreteamService:ApproveTrial(player, userId, opts.char, args[3], rest(args, 4))
			return done(ok, e, "Trial approved.")
		elseif sub == "revoke" then
			if args[3] == nil then
				return "Usage: /trial <player> revoke <trialId> [note]"
			end
			local ok, e = LoreteamService:RevokeTrial(player, userId, opts.char, args[3], rest(args, 4))
			return done(ok, e, `Trial {args[3]} and any later Trials revoked.`)
		end
		return "Usage: /trial <player> approve [trialId] | revoke <trialId>"
	end,
})

register({
	alias = "/kit",
	usage = { "/kit <player> grant <weaponType> <level> [note] [char=<id>]", "/kit <player> revoke <weaponType> [note]" },
	permissions = { P.AssignKits },
	run = function(player, args, opts)
		local userId, err = needTarget(args, 1)
		if userId == nil then
			return err :: string
		end
		local sub = string.lower(args[2] or "")
		if sub == "grant" then
			local level = tonumber(args[4] or "")
			if args[3] == nil or level == nil then
				return "Usage: /kit <player> grant <weaponType> <level> [note]"
			end
			local ok, e = LoreteamService:GrantKit(player, userId, opts.char, args[3], level, rest(args, 5))
			return done(ok, e, `Level {level} {args[3]} kit assigned.`)
		elseif sub == "revoke" then
			if args[3] == nil then
				return "Usage: /kit <player> revoke <weaponType> [note]"
			end
			local ok, e = LoreteamService:RevokeKit(player, userId, opts.char, args[3], rest(args, 4))
			return done(ok, e, `{args[3]} kit revoked.`)
		end
		return "Usage: /kit <player> grant <weaponType> <level> | revoke <weaponType>"
	end,
})

register({
	alias = "/gability",
	usage = {
		"/gability <player> grant <abilityId> <Lore|Event|Contribution|Purchase> [note] [char=<id>]",
		"/gability <player> revoke <abilityId> [note]",
	},
	permissions = { P.AssignLoreGAbilities, P.AssignPurchasedGAbilities },
	run = function(player, args, opts)
		local userId, err = needTarget(args, 1)
		if userId == nil then
			return err :: string
		end
		local sub = string.lower(args[2] or "")
		if sub == "grant" then
			if args[3] == nil or args[4] == nil then
				return "Usage: /gability <player> grant <abilityId> <Lore|Event|Contribution|Purchase> [note]"
			end
			local source = string.upper(string.sub(args[4], 1, 1)) .. string.lower(string.sub(args[4], 2))
			local ok, e = LoreteamService:GrantAbility(player, userId, opts.char, args[3], source, rest(args, 5))
			return done(ok, e, `G ability {args[3]} granted ({source}).`)
		elseif sub == "revoke" then
			if args[3] == nil then
				return "Usage: /gability <player> revoke <abilityId> [note]"
			end
			local ok, e = LoreteamService:RevokeAbility(player, userId, opts.char, args[3], rest(args, 4))
			return done(ok, e, `G ability {args[3]} revoked.`)
		end
		return "Usage: /gability <player> grant <abilityId> <source> | revoke <abilityId>"
	end,
})

register({
	alias = "/skin",
	usage = { "/skin <player> grant <skinId> [note]", "/skin <player> revoke <skinId> [note]", "/skin <player> list" },
	permissions = { P.AssignSkins },
	run = function(player, args)
		local userId, err = needTarget(args, 1)
		if userId == nil then
			return err :: string
		end
		local sub = string.lower(args[2] or "list")
		if sub == "grant" or sub == "revoke" then
			if args[3] == nil then
				return `Usage: /skin <player> {sub} <skinId> [note]`
			end
			local method = if sub == "grant" then DevToolsService.GrantSkin else DevToolsService.RevokeSkin
			local ok, e = method(DevToolsService, player, userId, args[3], rest(args, 4))
			return done(ok, e, `Skin {args[3]} {if sub == "grant" then "granted" else "revoked"}.`)
		elseif sub == "list" then
			local skins, e = DevToolsService:ListSkins(player, userId)
			if skins == nil then
				return `Failed: {e}`
			end
			return if #skins == 0 then "No skins." else "Skins: " .. table.concat(skins, ", ")
		end
		return "Usage: /skin <player> grant|revoke <skinId> | list"
	end,
})

register({
	alias = "/death",
	usage = {
		"/death list",
		"/death confirm <reportId> <circumstances>",
		"/death dismiss <reportId> <reason>",
		"/death direct <player> <circumstances> [char=<id>]  (a witnessed death with no report)",
	},
	permissions = { P.ConfirmDeath },
	run = function(player, args, opts)
		if not StaffService:HasPermission(player, P.ConfirmDeath) then
			return "You do not have permission to do that."
		end
		local sub = string.lower(args[1] or "list")
		if sub == "list" then
			local reports = DeathReviewService:ListReports(nil, "Pending")
			if #reports == 0 then
				return "No death reports awaiting review."
			end
			local lines = { "Death reports awaiting review:" }
			for _, r in reports do
				local killer = if r.killerUserId then " killed by " .. StaffTargets.DisplayName(r.killerUserId) else ""
				table.insert(lines, `{r.id}: {StaffTargets.DisplayName(r.userId)} [{r.characterId}]{killer}, {r.cause or "unknown cause"}, {fmtTime(r.occurredAt)}`)
			end
			return table.concat(lines, "\n")
		elseif sub == "confirm" then
			if args[2] == nil then
				return "Usage: /death confirm <reportId> <circumstances>"
			end
			local ok, e = DeathReviewService:ConfirmReport(player, args[2], rest(args, 3))
			return done(ok, e, "Permanent Death confirmed and processed.")
		elseif sub == "dismiss" then
			if args[2] == nil then
				return "Usage: /death dismiss <reportId> <reason>"
			end
			local ok, e = DeathReviewService:DismissReport(player, args[2], rest(args, 3))
			return done(ok, e, "Death report dismissed. The character lives.")
		elseif sub == "direct" then
			local userId, err = needTarget(args, 2)
			if userId == nil then
				return err :: string
			end
			local ok, e = DeathReviewService:ConfirmDirect(player, userId, opts.char, rest(args, 3))
			return done(ok, e, "Permanent Death confirmed and processed.")
		end
		return "Usage: /death list | confirm <id> <circumstances> | dismiss <id> <reason> | direct <player> <circumstances>"
	end,
})

register({
	alias = "/tradelog",
	usage = { "/tradelog [player] [hours=24]" },
	permissions = { P.ViewTradeLogs },
	run = function(player, args, opts)
		local userId: number? = nil
		if args[1] then
			local id, err = StaffTargets.ResolveUserId(args[1])
			if id == nil then
				return err :: string
			end
			userId = id
		end
		local hours = math.clamp(tonumber(opts.hours or "24") or 24, 1, 24 * 30)
		local logs, e = ModerationService:QueryTradeLogs(player, { playerUserId = userId, since = os.time() - hours * 3600 })
		if logs == nil then
			return `Failed: {e}`
		end
		if #logs == 0 then
			return "No trades found."
		end
		local lines = { `{#logs} trade(s) in the last {hours}h:` }
		for i, entry in logs do
			if i > 15 then
				table.insert(lines, `...and {#logs - 15} more.`)
				break
			end
			local a = entry.playerA or entry.fromUserId or entry.a
			local b = entry.playerB or entry.toUserId or entry.b
			table.insert(lines, `{fmtTime(entry.at or entry.time)} {tostring(a)} <-> {tostring(b)} {entry.status or ""} {entry.id or ""}`)
		end
		return table.concat(lines, "\n")
	end,
})

register({
	alias = "/audit",
	usage = { "/audit [player] [days=1]" },
	permissions = { P.ViewAuditLog },
	run = function(player, args, opts)
		if not StaffService:HasPermission(player, P.ViewAuditLog) then
			return "You do not have permission to do that."
		end
		local userId: number? = nil
		if args[1] then
			local id, err = StaffTargets.ResolveUserId(args[1])
			if id == nil then
				return err :: string
			end
			userId = id
		end
		local days = tonumber(opts.days or "1") or 1
		-- A player filter matches entries where they acted or were acted on.
		local entries
		if userId then
			entries = AuditLogService:Query({ actorUserId = userId, days = days, limit = 15 })
			for _, e in AuditLogService:Query({ targetUserId = userId, days = days, limit = 15 }) do
				table.insert(entries, e)
			end
			table.sort(entries, function(a, b)
				return a.at > b.at
			end)
		else
			entries = AuditLogService:Query({ days = days, limit = 15 })
		end
		if #entries == 0 then
			return "No audit entries."
		end
		local lines = { "Audit log (newest first):" }
		for i, e in entries do
			if i > 15 then
				break
			end
			local target = if e.target then " -> " .. StaffTargets.DisplayName(e.target) else ""
			table.insert(lines, `{fmtTime(e.at)} {if e.actor == 0 then "system" else StaffTargets.DisplayName(e.actor)} {e.action}{target}`)
		end
		return table.concat(lines, "\n")
	end,
})

register({
	alias = "/whitelist",
	usage = { "/whitelist add <player> [note]", "/whitelist remove <player> [note]", "/whitelist check <player>" },
	permissions = { P.ManageAccess },
	run = function(player, args)
		local sub = string.lower(args[1] or "")
		local userId, err = needTarget(args, 2)
		if userId == nil then
			return err :: string
		end
		if sub == "add" then
			local ok, e = AccessGateService:AddToWhitelist(player, userId, rest(args, 3))
			return done(ok, e, `{StaffTargets.DisplayName(userId)} can now join.`)
		elseif sub == "remove" then
			local ok, e = AccessGateService:RemoveFromWhitelist(player, userId, rest(args, 3))
			return done(ok, e, `{StaffTargets.DisplayName(userId)} removed from the whitelist.`)
		elseif sub == "check" then
			if not StaffService:HasPermission(player, P.ManageAccess) then
				return "You do not have permission to do that."
			end
			return if AccessGateService:IsWhitelisted(userId) then "Whitelisted." else "Not on the in-game whitelist."
		end
		return "Usage: /whitelist add|remove|check <player>"
	end,
})

register({
	alias = "/staff",
	usage = { "/staff" },
	permissions = {},
	run = function(player)
		local roles = StaffService:GetRoles(player)
		local lines = { `Your roles: {table.concat(roles, ", ")}` }
		for _, command in commands do
			local visible = #command.permissions == 0
			for _, perm in command.permissions do
				if StaffService:HasPermission(player, perm) then
					visible = true
				end
			end
			if visible and command.alias ~= "/staff" then
				for _, usage in command.usage do
					table.insert(lines, usage)
				end
			end
		end
		return table.concat(lines, "\n")
	end,
})

--------------------------------------------------------------------------
-- Dispatch

function StaffCommandService:Run(player: Player, line: string): (boolean, string)
	if not StaffService:IsStaff(player) then
		return false, "Staff only."
	end
	local alias, args, opts = CommandParser.Parse(line)
	local command = commands[alias]
	if command == nil then
		return false, "Unknown command. Type /staff for the list."
	end
	local ok, reply = pcall(command.run, player, args, opts)
	if not ok then
		warn(`[StaffCommandService] {alias} failed: {reply}`)
		return false, "That command hit an error. It has been logged."
	end
	return true, reply
end

function StaffCommandService:Init()
	DataService = require(script.Parent.Parent.DataService)
end

function StaffCommandService:Start()
	local folder = Instance.new("Folder")
	folder.Name = "StaffCommands"
	for alias in commands do
		local command = Instance.new("TextChatCommand")
		command.Name = "Staff_" .. string.sub(alias, 2)
		command.PrimaryAlias = alias
		command.Parent = folder
		command.Triggered:Connect(function(textSource: TextSource, text: string)
			local player = Players:GetPlayerByUserId(textSource.UserId)
			-- Non-staff get no response, so the commands stay invisible to them.
			if player == nil or not StaffService:IsStaff(player) then
				return
			end
			local ok, reply = StaffCommandService:Run(player, text)
			StaffNotify.Reply(player, reply, if ok then "info" else "error")
		end)
	end
	folder.Parent = TextChatService

	Net.OnInvoke("StaffCommand", function(player: Player, line: any)
		if type(line) ~= "string" or #line > 1000 then
			return false, "Invalid command."
		end
		return StaffCommandService:Run(player, line)
	end, { rateLimit = 4 })
end

return StaffCommandService
