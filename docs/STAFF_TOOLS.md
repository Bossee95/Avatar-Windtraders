# Staff tools and PD event control

Code: `src/server/Services/Staff/`, `src/server/Services/PDEvent/`,
`src/shared/Staff/`, `src/shared/PDEvent/`, `src/client/Controllers/Staff/`.

## Roles and permissions (GDD §17)

Defined in `Shared.Staff.Permissions`. The server re-checks every action.

| Permission | Loreteam | Moderation | Development |
|---|:-:|:-:|:-:|
| ControlPDEvent (start, end, phase) | ✓ | | |
| PausePDEvent (pause, resume) | ✓ | ✓ | |
| ManageRanks (rank, faction) | ✓ | | |
| ManageTrials | ✓ | | |
| AssignKits | ✓ | | |
| AssignLoreGAbilities (Lore, Event, Contribution) | ✓ | | |
| ConfirmDeath | | ✓ | |
| ViewTradeLogs | | ✓ | |
| ManageAccess (whitelist) | | ✓ | |
| AssignSkins | | | ✓ |
| AssignPurchasedGAbilities (Purchase) | | | ✓ |
| ViewAuditLog, ViewRecords | ✓ | ✓ | ✓ |

`Owner` holds everything. The place owner is always Owner, and in Studio every
tester is Owner (`StaffConfig.StudioOwner`).

Roles come from `src/server/Services/Staff/StaffConfig.luau`: Roblox group rank
thresholds (`GroupId`, `GroupRankRoles`) and explicit `UserRoles`.

## Closed-community access (GDD §15.1)

`AccessGateService` admits a player if they hold a staff role, are in the group
at or above `Access.MinGroupRank`, are in `Access.StaticWhitelist`, or were
whitelisted in-game with `/whitelist add`. Everyone else is kicked, and their
account is never loaded (DataService load guard). Studio play-solo is let
through (`Access.AllowInStudio`).

## PD boundaries (GDD §3.2, §19.8)

| State | Meaning |
|---|---|
| Inactive | No event. Trading, satchel looting and Permanent Death are off. |
| Active | Event running. Everything event-gated is on. |
| Paused | Event exists but is halted. Trading and looting are off, open trades are cancelled, and deaths that happen while paused are not PD deaths. Moderators can still confirm deaths that happened while Active. |

- A PD **begins** when the Loreteam starts it (`/pd start`).
- It **pauses** when Loreteam or Moderation pauses it, or automatically if the
  last server running it shuts down or crashes (it comes back Paused, never Active).
- It **resumes** only by staff action.
- It **concludes** when the Loreteam ends it. Ending is refused while death
  reports are awaiting review (`/pd forceend` overrides). On end, satchels are
  removed and the event is archived to history.
- A death only counts if it happened inside one of the event's Active windows.

Phases (Preparation, Development, Conflict, Resolution) are labels that can be
set in any order (§3.2 calls them guidelines).

Other systems use `PDEventService:IsActive()`, `:GetActiveEvent()`,
`:IsPlayerInActiveEvent(player)` and the `EventStarted / EventPaused /
EventResumed / EventEnded / PhaseChanged` signals. Clients read the
`PDState`, `PDPhase`, `PDEventId`, `PDEventName` attributes on ReplicatedStorage.

## Death confirmation (GDD §3.4, §16.3)

Combat calls `DeathReviewService:ReportDeath` for every death. Deaths outside an
Active window are ignored; the rest are queued and online moderators are
alerted. A moderator confirms (`/death confirm <id> <circumstances>`), which
calls `PermadeathService:ConfirmDeath`, or dismisses. Moderators cannot confirm
their own character's death.

## Chat commands

Type `/staff` in game for the list you are allowed to use. `char=<id>` targets a
specific character (otherwise the player's current or last-played one).

```
/pd status | start "<name>" [phase] | pause [reason] | resume | phase <phase> | end [summary] | forceend [summary] | history
/record <player>
/faction <player> <factionKey> <roleKey> [note]
/rank <player> <rank> [note]
/trial <player> approve [trialId] [note]   (defaults to the next Trial in order)
/trial <player> revoke <trialId> [note]
/kit <player> grant <weaponType> <level> [note] | revoke <weaponType> [note]
/gability <player> grant <abilityId> <Lore|Event|Contribution|Purchase> [note] | revoke <abilityId>
/skin <player> grant <skinId> | revoke <skinId> | list
/death list | confirm <reportId> <circumstances> | dismiss <reportId> <reason> | direct <player> <circumstances>
/tradelog [player] [hours=24]
/audit [player] [days=1]
/whitelist add|remove|check <player> [note]
```

The `StaffCommand` remote runs the same command lines, for a future staff panel.

## Audit log

Every staff action, every death report and every automatic pause is written to
`AuditLogService` (DataStore, one key per UTC day, flushed every 30 s and on
shutdown). Read it with `/audit` or `AuditLogService:Query`.
