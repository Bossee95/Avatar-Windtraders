# Inventory, trading and death satchels

Covers GDD §8 (items, inventory, trading), §9 (Permanent Death and death satchels) and §16.2–16.4.

## Where things live

| File | What it does |
|---|---|
| `src/shared/Economy/EconomyConfig.luau` | Tunables and the open §19 decisions as flags |
| `src/shared/Economy/ItemDefinitions.luau` | Every item (placeholder content for now) |
| `src/shared/Economy/ItemRegistry.luau` | Item rules: category, `untradeable`, stacking, weapon `variationId` |
| `src/shared/Economy/EconomyRemotes.luau` | Remote names and payloads (also need listing in `Shared.Net.Remotes`) |
| `src/server/Services/Economy/InventoryStore.luau` | Pure engine: who holds which item; atomic batch transfers |
| `src/server/Services/Economy/TradeEngine.luau` | Pure engine: trade state machine and validation |
| `src/server/Services/Economy/SatchelEngine.luau` | Pure engine: satchel creation, looting, clearing |
| `src/server/Services/Economy/TradeLog.luau` | Pure engine: trade and satchel records, queries |
| `src/server/Services/Economy/SkinStore.luau` | Pure rules for account-wide skins |
| `src/server/Services/Economy/*Service.luau` | Roblox wiring: data sections, remotes, PD/combat/character hooks |

The engines take every dependency as an argument, so they run outside Studio:

```
lua5.4 tools/run-economy-specs.lua
```

The same `tests/Specs/Economy/*.spec.luau` files run in Studio through the core test runner.

## Data

- **Carried items**: character-scope data section `Inventory` (`{ items = { {uid, itemId, quantity} } }`). It is wiped by Permanent Death after the satchel hook has run.
- **Weapon skins**: account-scope section `Skins` (`{ owned = { [skinId] = {grantedBy, grantedAt, note} } }`). Permanent Death never touches it, and there is no trade or transfer path.
- **Satchels**: in server memory only, tied to one PD event.
- **Trade log**: server memory plus the `EconomyTradeLog_v1` DataStore (`entry:<id>`, `player:<userId>` index).

## Trading flow

Request → accept/decline → both set offers → both confirm → countdown (`TradeCountdownSeconds`) → re-validate → atomic swap.

Any offer change clears both confirmations. Either player can cancel at any point before the swap. A trade is cancelled if the PD pauses or ends, if either player leaves, switches character, dies or is combat-tagged, or if anything fails the final check. Every closed trade is logged with its status and reason.

Final checks: both players are in the active PD, both still have the same living character, neither is in combat, the factions are allowed to trade, both are in range, every offered item is still in the offerer's carried inventory and is tradeable, and the countdown token is still current, so a trade can apply only once.

**Atomicity.** The swap is one `InventoryStore:ApplyTransfers` call. It validates the whole batch first, then applies it without yielding, so on a Roblox server nothing can observe a half-done trade. Both accounts are saved right after. The two players' records are still separate DataStore keys, so a server crash between the two saves can leave one side unsaved. Non-stackable items keep their `uid` when they change hands, which lets moderators spot a duplicate in the logs.

## Death satchels

`PermadeathService:RegisterTransferHook("Satchel", ...)` does the following:

1. Cancels the dead player's open trade.
2. Moves every tradeable carried item into a new satchel.
3. Destroys untradeable items, which are lost with the character.
4. Places a satchel part with a "Search" prompt at the death location.

If a later hook fails, the rollback hook undoes all of this. A satchel can only be looted during its own PD, and only while that PD is not paused. When the PD ends, every satchel from it and all of its contents are removed and logged.

## Inventory screen (client)

Press **M** (gamepad: Back) or the *Inventory* button on the HUD. Code is in
`src/client/Controllers/Economy/`:

- `InventoryController` keeps the client's copy of carried items (`InventoryUpdated`, plus one `GetInventory` call on start).
- `InventoryScreenController` builds the screen: five labelled category tabs (Weapons, Gear, Materials, Supplies, Keepsakes), a 5-wide grid of item tiles with stack counts, a detail panel (name, tags, description, stats) and a live 3D preview of the character that can be dragged to turn.
- `InventoryUI/Theme` holds the colours and fonts, `InventoryUI/ItemIcons` draws placeholder icons from frames, `InventoryUI/CharacterPreview` runs the 3D preview.

Weapons are class-locked, so the Weapons tab shows the class weapon marked *Class* with no equip button. If the class default weapon isn't an inventory item it is still listed.

### Pages (keys 1-4, gamepad LT / RT)

The M screen has four pages across the top. The 3D preview stays on the right for all of them.

1. **Inventory**: the item grid described above.
2. **Customise** (`InventoryUI/Pages/CustomisePage`, server `Services/Cosmetics/CosmeticService`):
   - *Weapon skins*: skins the account owns (SkinService). Click one to wear it on your class weapon, or *Default look* to go back. A skin's model is `ServerStorage.WeaponSkins.<skinId>` (set up like `WeaponModels`), with an optional `WeaponType` attribute to limit it to one weapon type and an optional `DisplayName`. The choice is saved per weapon type in the `Skins` account section (`equipped`), and CombatService welds it in place of the normal model.
   - *Accessories*: every `Accessory` in `ServerStorage.CosmeticModels`, worn with `Humanoid:AddAccessory` and put back on every spawn. They're saved in the account-scope `Cosmetics` section, so they survive Permanent Death. Optional attributes are `DisplayName` and `Slot` (one per slot). The limit is `CosmeticConfig.MaxAccessories`.
3. **Skills** (`Pages/SkillsPage`): the G abilities the character holds (now sent in `CombatState.gAbilities`). Click one to put it on G, or click the active one to clear G. This uses `CombatSelectGAbility`, so it can't be changed in combat.
4. **Settings** (`Pages/SettingsPage`, `Controllers/SettingsController`, server `Services/SettingsService`): music volume, sound-effects volume, low graphics and show hitboxes. They're saved in the account-scope `Settings` section. The volumes drive `SoundService.Music` and `SoundService.SFX` SoundGroups, so music and effects need to play through those groups. Low graphics turns off shadows and post effects on this client. Show hitboxes draws your own attack areas briefly (`Combat/HitboxViewController`).

To give an item real art, add `icon = "rbxassetid://..."` to its entry in `ItemDefinitions` (optionally `iconColor = { r, g, b }` to tint the drawn placeholder instead).

While the screen is open `UIState.IsMenuOpen()` is true and the combat, defense and knock controllers ignore keys, so Q/E switch tabs without dodging and WASD moves the selection instead of the character.

## Open decisions (GDD §19)

| # | Flag(s) | Current default |
|---|---|---|
| 1 | `StorageItemsDropOnDeath` | `false`: only carried items drop. No storage system exists yet. |
| 2 | `SatchelLootableBy`, `SatchelConcurrentLooting`, `SatchelOwnerCanLoot` | Anyone can loot, several looters at once (first claim wins), and the owner's new character can't loot the old satchel |
| 3 | `BlockTradeInCombat`, `AllowCrossFactionTrade` | No trading in combat; cross-faction trading allowed |
| — | `MaxWeaponsPerCharacter` | `1`: a character carries at most one weapon (your rule); trades and looting that would exceed it are refused, swaps are fine |
| 4 | `TradeCountdownSeconds`, `TradeRequestTimeoutSeconds` | 5 s countdown, 30 s request timeout, everything logged |
| 8 | `TradeAllowedWhilePaused`, `SatchelLootWhilePaused` | Both `false` |

## Not done yet

- Client trade and satchel UI. The remotes and state payloads are ready for it.
- A storage system (GDD §9.3). It's waiting on decision §19.1.
