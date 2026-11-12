# Core framework API

This is the contract the other systems (combat, inventory/trading/satchels,
staff tools/PD events, gathering/crafting/territory) build on.

## 1. Layout and tooling

Rojo 7 + Luau. No Wally packages yet; everything is in-repo.

| Folder        | Rojo path in the DataModel                    |
|---------------|-----------------------------------------------|
| `src/shared`  | `ReplicatedStorage.Shared`                    |
| `src/server`  | `ServerScriptService.Server`                  |
| `src/client`  | `StarterPlayer.StarterPlayerScripts.Client`   |
| `tests`       | `ServerScriptService.Tests` (only in `test.project.json`) |

```
src/shared/
  Config/WorldConfig.luau   faction / role / place display names (the ONLY place names live)
  Config/GameConfig.luau    limits, DataStore names, timings
  Net/init.luau             networking layer
  Net/Remotes.luau          registry of every remote name
  Util/Signal.luau          signal class
  Util/Table.luau           deepCopy, deepFreeze, reconcile
  Loader.luau               service/controller lifecycle
  Types.luau                shared record types
src/server/
  Main.server.luau          boots every *Service
  Services/DataService.luau
  Services/CharacterService.luau
  Services/ProgressionService.luau
  Services/PermadeathService.luau
  Data/SafeStore.luau       session-locked DataStore wrapper
  Data/MockDataStore.luau   in-memory DataStore (Studio without API access, tests)
  Data/Schema.luau          default records, sections, migrations
  Rules/Progression.luau    pure rules for ranks, Trials, kits, G abilities
  Rules/Permadeath.luau     pure Permanent Death pipeline
src/client/
  Main.client.luau          boots every *Controller
  Controllers/CharacterController.luau        client state + create/select requests
  Controllers/CharacterScreenController.luau  placeholder character screen UI
```

Put your own code in `src/server/Services/<YourArea>/`, `src/client/Controllers/<YourArea>/`
and `src/shared/<YourArea>/`. Names, factions and places must come from
`WorldConfig`; never hard-code a display name or a setting-specific asset.

## 2. Services and the loader

`Shared.Loader` loads every ModuleScript under `Server.Services` (subfolders
included) whose name ends in `Service`. On the client it does the same for
`Client.Controllers` and names ending in `Controller`. Helper modules with
other names are ignored, so keep helpers next to your service.

```lua
local MyService = {}

function MyService:Init()   -- optional. Runs for all services first. Must not yield.
end

function MyService:Start()  -- optional. Runs after every Init, each in its own thread.
end

return MyService
```

Get another service with a plain `require(script.Parent.CharacterService)` or
`Loader.Get("CharacterService")`. Register hooks/sections in `Init`, start
loops and connect to players in `Start`.

**Call convention:** every service method is called with a colon:
`CharacterService:GetActiveCharacter(player)`.

## 3. Signal (`Shared.Util.Signal`)

```lua
local sig = Signal.new()
local conn = sig:Connect(function(...) end)  -- handlers run in their own thread
sig:Once(fn)
sig:Fire(...)
sig:Wait()
conn:Disconnect()
sig:DisconnectAll()
```

## 4. Networking (`Shared.Net`)

Declare your remotes in your own ModuleScript anywhere under `src/shared`
whose name ends in `Remotes`, e.g. `src/shared/Combat/CombatRemotes.luau`:

```lua
return {
  Events = { CombatHit = true },
  Functions = { CombatEquip = true },
}
```

Net merges every `*Remotes` module with the core `Net/Remotes.luau`, so no
system edits another's file. The server creates them all under
`ReplicatedStorage.Remotes` at boot, and an undeclared name errors
immediately.

Server:
```lua
Net.OnEvent(name, function(player, ...) end, opts?)
Net.OnInvoke(name, function(player, ...) return ... end, opts?)
Net.Fire(name, player, ...)
Net.FireAll(name, ...)
Net.FireList(name, { players }, ...)
-- opts = { rateLimit = callsPerSecond (default 10), validate = function(...) -> boolean }
```
Requests over the rate limit or failing `validate` are dropped (an invoke
returns `nil`). Handler errors are caught and logged; the server never trusts
client arguments, so always validate.

Client:
```lua
Net.Fire(name, ...)
Net.Invoke(name, ...)
Net.OnEvent(name, function(...) end)
```

## 5. Data (`DataService`)

One DataStore record per account, session-locked (no two servers can hold it),
saved with `UpdateAsync`, autosaved every 60 s, saved on leave and on
shutdown. In Studio without API access it falls back to an in-memory store and
warns. If an account cannot be loaded the player is kicked rather than given a
blank profile.

### Sections: where your data goes

Systems store their own data in named sections instead of adding fields to the
core records:

```lua
DataService:RegisterSection("Inventory", { scope = "Character", default = { items = {} } })
DataService:RegisterSection("Skins",     { scope = "Account",   default = { owned = {} } })
```

* `scope = "Character"` lives in `character.sections[name]`. It is **wiped by
  Permanent Death** (after the transfer hooks run) and created fresh for every
  new character.
* `scope = "Account"` lives in `account.sections[name]`. Permanent Death
  **never touches it**. Weapon skins belong here (GDD §7.3, §16.6).

Register in `Init`. Defaults are deep-copied and reconciled into old records,
so adding fields later is safe. Because sections share the account record you
get session locking and an atomic save with the PD reset for free.

```lua
DataService:GetAccount(player) -> Account?
DataService:WaitForAccount(player, timeout?) -> Account?
DataService:GetAccountSection(player, name) -> table?
DataService:GetCharacterSection(player, name, characterId?) -> table?  -- active character by default
DataService:GetAccountByUserId(userId) -> Account?   -- only if loaded in this server
DataService:GetPlayer(userId) -> Player?
DataService:SaveNow(player) -> boolean
DataService:UpdateOffline(userId, fn(account) -> (boolean?, string?)) -> (boolean, string?)
DataService:PeekOffline(userId) -> (boolean, Account?)   -- read-only, no lock
DataService:IsLoaded(userId) -> boolean
DataService:RegisterLoadGuard(name, fn(player) -> boolean) -- in :Init(); may yield
DataService.AccountLoaded:Connect(function(player, account) end)
DataService.AccountReleasing:Connect(function(player, account) end) -- last chance before final save
```

`UpdateOffline` runs `fn(account)` once on any account and saves it:

* player in this server: runs on the live copy, then saves;
* player nowhere: locks the stored record on this server, runs `fn`, saves
  and releases (the player can't load into this server meanwhile);
* another server holds the lock: fails with `"LockedByOtherServer"` (route the
  change to that server with MessagingService, or retry later).

`fn` may yield. Return `false, reason` to reject the change: an offline record
is then released unsaved, so validate before mutating a live one. Other
errors: `"NotFound"`, `"RequestFailed"`, `"EditFailed: <error>"`.

Load guards run before an account is locked. Any guard returning anything
but `true` means the account is never loaded (the access gate kicks).

Mutate section tables in place; they are saved with the account. Do not
replace `account.sections[name]` itself.

## 6. Records (`Shared.Types`)

```lua
Account = {
  schemaVersion: number,
  userId: number,
  createdAt: number,
  activeCharacterId: string?,
  characterOrder: { string },              -- creation order, includes dead characters
  characters: { [string]: Character },     -- dead characters are kept as history
  nextCharacterSeq: number,
  sections: { [string]: any },             -- account-scope sections (e.g. Skins)
}

Character = {
  id: string,                 -- "<userId>-<seq>", unique across the game, never reused
  userId: number,
  name: string,
  faction: string,            -- WorldConfig.Factions key, e.g. "FactionA"
  role: string,               -- WorldConfig.Factions[faction].roles key
  status: "Alive" | "Dead",
  createdAt: number,
  rank: number,               -- one overall faction rank, 0 = unranked (Loreteam only)
  trials: { { id: string, approvedBy: number, at: number } },        -- in completion order
  kits: { [weaponType]: { level: number, grantedBy: number, at: number } },
  abilities: { [abilityId]: { source: string, grantedBy: number, at: number } },  -- G abilities
  sections: { [string]: any },  -- character-scope sections (e.g. Inventory)
  log: { { at, actor, action, details } },  -- last 100 progression changes
  death: nil | { at, pdEventId, confirmedBy, reason, final = { rank, trials, kits, abilities, faction, role } },
}
```

Records are owned by these services. Read them freely, change them only
through the APIs below (sections excepted).

## 7. CharacterService

```lua
CharacterService:GetActiveCharacter(player) -> Character?
CharacterService:GetActiveCharacterId(player) -> string?
CharacterService:GetCharacter(player, characterId) -> Character?
CharacterService:ListCharacters(player) -> { Character }        -- creation order, dead included
CharacterService:IsAlive(player, characterId?) -> boolean       -- active character by default
CharacterService:CreateCharacter(player, { name, faction, role }) -> (boolean, idOrError)
CharacterService:SelectCharacter(player, characterId) -> (boolean, error?)
CharacterService:DeselectCharacter(player) -> (boolean, error?)
CharacterService:RegisterSwitchGuard(name, fn(player, fromId?, toId?) -> (boolean, string?))
CharacterService:RegisterCreateGuard(name, fn(player, { name, faction, role }) -> (boolean, string?))
CharacterService:GetState(player) -> summary   -- same shape the client gets

CharacterService.CharacterSelected:Connect(function(player, characterId?, previousId?) end)
CharacterService.CharacterChanged:Connect(function(player?, userId, characterId, field) end)
-- field: "Created" | "Faction" | "Rank" | "Trials" | "Kits" | "Abilities" | "Status"
```

Switch guards let combat block switching characters while in combat, and the
PD thread block switching during an active PD. Any guard returning `false`
blocks the switch. Create guards are for recruitment limits and faction
balance (GDD §15.3).

Creation rules: names are 3 to 24 letters (spaces, `'` and `-` allowed inside)
and pass Roblox text filtering; only `GameConfig.Characters.PlayerSelectableFactions`
can be picked (independent affiliations are assigned by staff with
`SetFaction`); leadership roles can't be picked; at most
`MaxAliveCharacters` living characters per account.

Spawning: `Players.CharacterAutoLoads` is off. The avatar spawns when a living
character is selected; with none selected the player stays on the character
screen. Ordinary (non-PD) deaths respawn the same character after
`Players.RespawnTime` unless `RespawnAfterNonPermanentDeath` is turned off.

## 8. ProgressionService (Loreteam setters)

No permission checks here: the staff tools wrap these after
`StaffService.HasPermission`. Every call takes the acting staff member's
userId, works on online and offline accounts, appends to `character.log`,
fires `CharacterService.CharacterChanged`, and returns `(ok, err)`.

```lua
ProgressionService:SetFaction(actor, userId, characterId, faction, role)
ProgressionService:SetRank(actor, userId, characterId, rank)
ProgressionService:ApproveTrial(actor, userId, characterId, trialId)   -- must be the next trial in order
ProgressionService:RevokeTrial(actor, userId, characterId, trialId)    -- also revokes the later trials
ProgressionService:GrantKit(actor, userId, characterId, weaponType, level)
ProgressionService:RevokeKit(actor, userId, characterId, weaponType)
ProgressionService:GrantAbility(actor, userId, characterId, abilityId, source)
ProgressionService:RevokeAbility(actor, userId, characterId, abilityId)
ProgressionService:GetNextTrial(character) -> string?
ProgressionService:SetValidator("WeaponType" | "Ability", fn(id) -> boolean)
ProgressionService.Changed:Connect(function(actor, userId, characterId, action, details) end)
```

Trial order per faction comes from `WorldConfig.Factions[faction].trials`
(an empty list means no order is enforced yet). Kit levels can't exceed the
overall rank while `KitLevelCappedByRank` is on. Combat registers validators
so only catalogued weapon types and G abilities can be granted. Nothing is
ever granted automatically (GDD §4.4).

Errors: `InvalidArguments`, `CharacterNotFound`, `CharacterDead`,
`InvalidFaction`, `InvalidRole`, `InvalidRank`, `InvalidTrial`,
`UnknownTrial`, `OutOfOrder`, `AlreadyCompleted`, `NotCompleted`,
`InvalidWeaponType`, `InvalidLevel`, `KitLevelAboveRank`, `InvalidAbility`,
`InvalidSource`, `AlreadyGranted`, `NotGranted`, plus the `UpdateOffline` errors.

## 9. PermadeathService (GDD §16.3)

```lua
PermadeathService:ConfirmDeath({
  userId = number, characterId = string, pdEventId = string,
  confirmedBy = number, reason = string?, location = CFrame?,
}) -> (boolean, error?)
PermadeathService:SetPdEventProvider(fn() -> string?)    -- returns the active PD event id, or nil
PermadeathService:RegisterTransferHook(name, fn(ctx), { rollback = fn(ctx) }?)
PermadeathService.Permadeath:Connect(function(player?, userId, characterId, pdEventId) end)
```

Pipeline:
1. Refuse unless a PD event is active and `pdEventId` matches it, and the
   character exists, is alive and is not already being processed.
2. Mark the character `Dead` and write `character.death` (who, when, why, and
   a `final` snapshot of its progression: the historical record).
3. Run every transfer hook, in registration order, with
   `ctx = { player?, userId, characterId, pdEventId, location?, character (frozen pre-reset copy), sections (live character sections) }`.
   The satchel hook takes tradeable items out of `ctx.sections.Inventory` and
   puts them in a satchel.
4. Reset progression (rank, trials, kits, abilities) and wipe every character
   section. Account sections (skins) are untouched.
5. Clear the active character, save immediately, fire `Permadeath`, and return
   the player to the character screen.

Hooks run synchronously and must not yield (a yielding hook counts as
failed). If any hook fails, the `rollback` of every hook that already
completed runs in reverse order, then the character record (sections
included) is restored from a pre-death copy, and `ConfirmDeath` returns
`false, "HookFailed:<name>"`. So a rollback only needs to undo effects
outside the record, such as an in-world satchel.

Works for players who already left (combat logging): the record is locked on
this server while it is processed, and hooks get `player = nil`.

Errors: `InvalidRequest`, `NoActivePd`, `PdMismatch`, `AlreadyProcessing`,
`CharacterNotFound`, `AlreadyDead`, `HookFailed:<name>`, `LockedByOtherServer`,
`RequestFailed`. A second `ConfirmDeath` for the same character returns
`false, "AlreadyDead"`.

Why the record can't duplicate items: the reset happens in memory under the
session lock before anything is saved. If the server dies before the save,
the character comes back alive with its items and the in-world satchel
disappears with the server; if it dies after, the items exist only in the
satchel. There is never a moment where both are persisted.

## 10. WorldConfig (`Shared.Config.WorldConfig`)

Generic keys, editable display names:

```lua
WorldConfig.Factions.FactionA = { displayName = "Faction A", kind = "Primary", roles = { Command = {...}, Military = {...}, ... }, trials = { ... } }
WorldConfig.Factions.FactionB = { ... roles = { Leader, SpiritualLeader, Hunter, Warrior, Gatherer, Craftsperson } }
WorldConfig.Factions.RogueA   = { kind = "Independent", ... }   -- rogues
WorldConfig.Factions.RogueB   = { kind = "Independent", ... }   -- lone warriors
WorldConfig.Places = { ... }
WorldConfig.getFactionName(key), WorldConfig.getRoleName(faction, role), WorldConfig.getPlaceName(key)
WorldConfig.isValidRole(faction, role)
```

## 11. Remotes used by the core

| Name | Kind | Direction | Payload |
|---|---|---|---|
| `AccountState` | Event | server → client | `{ activeCharacterId, characters = { summary } }` |
| `GetAccountState` | Function | client → server | → same summary as `AccountState` |
| `CreateCharacter` | Function | client → server | `{ name, faction, role? }` → `(ok, idOrError)` |
| `SelectCharacter` | Function | client → server | `characterId` → `(ok, error)` |

Summaries sent to clients only contain `id, name, faction, role, status, rank`
per character, plus `maxAliveCharacters`.

Client side, `CharacterController` holds the latest summary
(`:GetState()`, `:GetActiveCharacter()`, `.StateChanged`) and wraps the
requests (`:CreateCharacter(request)`, `:SelectCharacter(id)`).

## 12. Tests

`rojo build test.project.json -o test.rbxlx`, open it in Studio and press
Run. `tests/Runner.server.luau` runs every `*.spec` module under
`ServerScriptService.Tests` against `MockDataStore` and prints the result.
A spec returns `function(t)` and uses `t.test(name, fn)`, `t.expect(v).toBe(x)`,
`t.expect(v).toEqual(x)`, `t.expect(fn).toThrow()`, `t.expect(v).toBeNil()`,
`t.expect(v).toBeTruthy()`.
