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
`Config/Animations.luau`; all are placeholders (`rbxassetid://0`) and the client
skips them until real animations are uploaded. All display names are in these
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
