# Combat and weapon kits

Implements GDD §5 (weapons and kits), §6 (combat) and §16.5 (combat validation).

## How a moveset is put together

| Input | Comes from | Config file |
|---|---|---|
| M1 combo | the weapon **type** (shared by every variation of it) | `Config/WeaponTypes.luau` |
| Z, X, C | the **kit**: `Kits[weaponType][level]` | `Config/Kits.luau` |
| R Critical | the equipped weapon **variation** | `Config/Variations.luau` |
| G | a separately assigned **G ability** the player has selected | `Config/GAbilities.luau` |

Every move (damage, hitbox, windup, recovery, cooldown, effects, animation key)
is an entry in `Config/Actions.luau`. Animation keys map to ids in
`Config/Animations.luau`; the spear M1 combo and the movement/defence set use
the original Studio animations, the rest are placeholders (`rbxassetid://0`)
that the client skips until real animations are uploaded. All display names are in these
config files. Global rules (combat tag duration, which states block switching,
rate limits) are in `Config/CombatSettings.luau`.

`ConfigValidator` checks every reference and value when the server starts. If
it finds a problem, combat stays disabled and the problems are printed, so a
typo cannot reach a fight.

### Adding content

* **New weapon variation** (e.g. a crafted sword): add a `Variations` entry with
  its `weaponType` and a `critical` action id, and add that Critical to
  `Actions` with `kind = "Critical"`. It shares the sword M1 and kit
  automatically.
* **New kit level**: add `Kits.<WeaponType>[n]` with its Z/X/C action ids.
* **New weapon type**: add it to `WeaponTypes` with an M1 combo, then give it
  kits in `Kits` and at least one variation.
* **New G ability**: add `GAbilities.<Id>` pointing at a `kind = "G"` action.
  Its id is what staff grant through `ProgressionService:GrantAbility`.

New effect *types* (beyond Knockback, Stun, SelfBuff, SelfRoot, Smoke) need code
in `CombatService`.

## Who grants what

The game never unlocks anything (GDD §4.4, §17). The server reads permissions
from the active character record on every action:

* `character.kits[weaponType].level`: set by the Loreteam via
  `ProgressionService:GrantKit/RevokeKit`. One overall rank; a character can
  hold several weapon types at once.
* `character.abilities[abilityId]`: G abilities, via
  `ProgressionService:GrantAbility/RevokeAbility`.
* Weapon ownership: the inventory system registers
  `CombatService:SetVariationOwnershipProvider`. Owning a weapon never grants
  its kit (§11.2).

On `Init`, CombatService registers `ProgressionService:SetValidator` for
"WeaponType" and "Ability", so staff can only grant weapon types and G
abilities that exist in this config.

A revoke takes effect on the next input, and `CharacterChanged` (Kits,
Abilities, Status) triggers `Revalidate`, which unequips at once if the kit or
item is gone, even mid-combat.

## Defence: block, perfect block, dodge (§6.6)

Rules live in the pure module `src/shared/Combat/Defense.luau` (specs in
`tests/Specs/Combat/Defense.spec.luau`); numbers in `CombatSettings.Block`,
`CombatSettings.Dodge` and `CombatSettings.HitStun`. First values come from the
original hand-built Studio combat, except dodge i-frames (0.4 s, was 1 s, to
keep dodges counterable).

* **F (hold)** raises a block (`CombatBlock` true/false). Each blocked hit
  drains the action's `blockDrain` (default 1) from `MaxCounts`; at zero it
  breaks (hit lands x `BlockBrokenDamageMultiplier`, defender stunned).
  Charges return one per `CountRegenTime` after any lockout.
* A hit within `PerfectWindowStart..PerfectWindowEnd` seconds of raising the
  block is a **perfect block**: no damage, a charge back, attacker stunned.
* Hits from behind (more than 90 degrees off the defender's facing) and
  `unblockable` actions go through.
* **Q** dodges (`CombatDodge` direction). The server spends a charge, grants
  `IFrameDuration` of invulnerability and cancels a pending windup; the
  client moves its own character (`Dodge.Distance` over `Dodge.Duration`).
* An unblocked hit **staggers** for `HitStun`: no actions, movement unaffected
  (GDD 6A.5). Block breaks and perfect-block stuns freeze movement.
* Attacking lowers the block. NPC targets have no defence.
* Every Critical (`kind = "Critical"`) is a guard break: a held block breaks
  in one hit. A perfect block still stops it and stuns the attacker, which
  cancels the rest of a flurry.
* The block can be raised from the moment your own swing's last hit check
  happens (`swingLandsAt`), never during your windup. Raising it cancels the
  rest of the recovery and any queued input; the combo index is kept.

### Reference-clip pacing (Bossee, 2026-11-13)

* M1: a hit every ~0.28 s (windup 0.18-0.2 + recovery 0.08-0.1), 0.3 s
  `comboEndlag` after hit 4. Spear animations play faster (`animationSpeed`)
  to land on the shorter windups.
* R / M2: melee Criticals are 4 hits 0.15 s apart with `hyperArmor` (hits
  land but don't stagger, knock back or interrupt), a red `glow`, and a
  `finalEffects` launch on the last hit; 7 s cooldown. Ranged Criticals keep
  their shapes and cooldowns but glow and guard-break too.
* Only a perfect block glows: a 0.12 s blue flash. Holding a normal block has no body tint
  (`Config/Effects`).

The server tells the defender `CombatDefenseState` and everyone
`CombatDefense(character, kind, extra)` for animations and VFX.

## Downed, carry and execution (§6.7)

Rules in `src/shared/Combat/KnockCore.luau` (specs in
`tests/Specs/Combat/KnockCore.spec.luau`), wiring in
`Server/Services/Combat/KnockService.luau`, input and ragdoll in
`Client/Controllers/Combat/KnockController.luau`; numbers in
`CombatSettings.Knock` (from the original Studio knock system).

* Player characters (and NPC rigs tagged `Knockable`) never die from damage:
  at `HealthLimit` they are downed (`character.Knocked = "Down"`) and get up
  after `Duration`. Damage while down adds `ExtendOnDamage`, capped.
* **V** carries the nearest downed character within `SearchRadius` (welded
  to the carrier, who owns its physics). V again or any damage to the carrier
  drops it. The recovery timer pauses while carried.
* **B** starts an execution: the executioner is rooted for `GripDuration`;
  damage or B again cancels it. When it completes the target dies and
  `CombatService:RecordHit` credits the executioner, so the death report sent
  to `DeathReviewService` names them (§3.4).
* While downed, carrying or executing (`player.KnockAction`), CombatService
  rejects attacks, blocks, dodges and weapon switching.
* After a carry or grip ends the target can't be picked up for `DropImmunity`.

## Lag compensation

Melee (Box and Radius) hitboxes forgive the attacker's latency: a player the
server-time hitbox misses still counts if, rewound by the attacker's ping plus
`InterpolationDelay` (capped at `MaxRewind`), they were inside the hitbox plus
`Padding`, with clear line of sight. Positions are sampled `SampleRate` times
a second into `Shared/Combat/LagHistory` ring buffers. Rays and cones use
server time. Settings: `CombatSettings.LagCompensation`. This replaces the
third-party "Rewind" library the old Studio combat used (it was not brought
over: its licence is unknown).

## Effects and HUD

`CombatVFXController` plays the particle folders named in
`Config/Effects.luau` (from `ReplicatedStorage.VFX` in the place) on hits,
blocks, perfect blocks, block breaks and dodges. `CombatHUDController` is a
plain placeholder readout of block and dodge charges and the downed timer.

## Weapon models

`CombatService` welds `ServerStorage.WeaponModels.<variationId>` (or
`.<weaponType>`) to the right hand when it exists: a BasePart or a Model with
a PrimaryPart. An Attachment named `Grip` inside is lined up with the hand's
`RightGripAttachment`. Without a model it falls back to the placeholder part.

## Server validation (§16.5)

`CombatService` checks, per request:

* the active character is alive and has a kit for the weapon type
* the variation exists and is owned
* only one weapon is equipped (equipping replaces it). The inventory also limits a character to carrying one weapon (GDD §5.3), so this is a backstop
* no weapon or G-ability switching while combat-tagged, mid-action, stunned or
  dead; character switching is blocked while tagged (switch guard "Combat")
* G abilities are assigned to the character
* cooldowns, action lockout (windup + recovery), combo pacing, remote rate limits
* hitboxes are built on the server from server positions. The client sends
  only the input and an aim direction, which is normalised and pitch-clamped.
  Rays and cones are blocked by walls.

Taking or dealing combat damage tags a player for `CombatTagDuration` (20 s,
placeholder for §19.5).

## Integration points

```lua
CombatService:Equip(player, variationId) -> (ok, err?)
CombatService:Unequip(player) -> (ok, err?)
CombatService:SelectGAbility(player, abilityId?) -> (ok, err?)
CombatService:GetEquipped(player) -> { variationId, weaponType }?
CombatService:IsInCombat(player) -> boolean
CombatService:TagCombat(player)
CombatService:Revalidate(player)
CombatService:SetVariationOwnershipProvider(fn(player, variationId) -> boolean)
CombatService:RegisterStructure(model, { faction?, onDamage }) -> unregister
CombatService:SetTargetFilter(fn(attacker, targetModel) -> boolean)   -- friendly fire, safe zones
CombatService:SetDamageHandler(fn(attacker, humanoid, amount, actionId))
CombatService.CombatTagChanged   -- (player, isTagged), on transitions only
CombatService.ActionPerformed    -- (player, actionId, targets)
```

Every avatar death of a living character is sent to
`DeathReviewService:ReportDeath` with the last attacker (within 10 s) for
moderator review. Combat never confirms a permanent death.

### Remotes

Declared in `src/shared/Combat/CombatRemotes.luau` (merged by `Shared.Net`):

| Name | Kind | Direction | Payload |
|---|---|---|---|
| `CombatUseAction` | Event | client → server | `input` ("M1"/"Z"/"X"/"C"/"R"/"G"), `aim: Vector3?` |
| `CombatEquip` | Function | client → server | `variationId` → `(ok, err)` |
| `CombatUnequip` | Function | client → server | → `(ok, err)` |
| `CombatSelectGAbility` | Function | client → server | `abilityId?` → `(ok, err)` |
| `CombatState` | Event | server → client | `{ variationId, gAbilityId, inCombat, combatTagRemaining, cooldowns }` |
| `CombatActionStarted` | Event | server → all | `character, actionId, input` |
| `CombatHit` | Event | server → all | `character, actionId, { targets }` |
| `CombatKnockback` | Event | server → target | `velocity` |
| `CombatNotice` | Event | server → client | `kind, ...` (rejections, forced unequip) |

## Testing in Studio

`CombatSettings.StudioGrantAll` (on by default, Studio only) grants every kit at
its top level, every variation and every G ability, so the moveset can be tried
without staff tools. Keys 1 to 4 equip Sword/Spear/Bow/Rifle, 5 unequips, 6
cycles the G ability. Set it to `false` to test real permissions.

Specs in `tests/Specs/Combat` cover the rules, combat tag, cooldowns and config
validation.

## Open decisions (placeholders until settled)

* §19.5: combat tag length (20 s) and which states block switching.
* §19.6: every G ability's numbers, and whether the shotgun needs ammunition.
* All damage, ranges and cooldowns are first-pass numbers for balancing.
* Knockback on players is applied by their own client. Movement abilities
  (dashes) are not in yet.

## Structures

Facilities can take combat damage:

```lua
local unregister = CombatService:RegisterStructure(model, {
	faction = "FactionA",                       -- hits from this faction are ignored
	onDamage = function(attacker, amount, actionId) end,
})
```

Every hitbox shape can hit a registered structure. Rays stop at the first
thing they hit. Damage counts only while `PDEventService:IsActive()`, except
under Studio grant-all. `amount` includes the action's optional
`structureMultiplier` (default 1, and 0 means the action can't damage
structures). The structure is unregistered automatically when its model is
destroyed.
