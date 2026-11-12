# Design: Gathering, Crafting, Facilities and Territory

Covers GDD §10 (Resource Gathering and Economy), §11 (Crafting), §12 (Facilities) and §13 (Territory and Entitlements).

Status: **implemented, pending review.** Every delivery step in §10 is built. §12 lists what is still open. This system sits on top of the core, staff/PD, inventory and combat systems; the interfaces it uses are listed in §8.

---

## 1. Principles

1. **Server-authoritative.** Every gather, craft, build, damage and capture is validated on the server. Clients send intents only.
2. **Crafting never grants kits.** A crafted weapon is an item with a variation (look + Critical attack). It never writes to kit, rank, Trial or G ability records. Whether the holder can *use* the moveset is the combat system's kit check (GDD §11.2, §16.5).
3. **Entitlements are staff-only records.** The game stores and enforces entitlements but never creates, transfers or revokes one by itself. Only Loreteam (and, where noted, staff with an explicit permission) can change them (GDD §13.2–13.3, §17).
4. **Config owns content.** Every resource, recipe, station, facility type, territory and display name is data in `src/shared/Economy/Config/`. Code refers only to stable ids (`res_scrap_alloy`, `fac_forward_base`). No setting-specific names or assets are hard-coded; display names are original and live in config so they can be changed without code edits. Faction ids are the core `WorldConfig.Factions` keys (`FactionA`, `FactionB`, `RogueA`, `RogueB`). Territory and build-zone display names go in `WorldConfig.Places`, per the core rule that place names live only there.
5. **PD-gated.** World-changing actions (gather, craft, build, damage, capture) only happen while a PD event is active, using the core PD state. Each gate is a config flag so staff can relax it for testing.
6. **Everything is logged.** Gathers, crafts, facility state changes, captures and entitlement changes are written to an audit log that moderators and Loreteam can read.

---

## 2. Resources (GDD §10)

### 2.1 Resource definitions

Resources are ordinary inventory items with `category = "Resource"` and a resource tier. Defined in `Economy/Config/Resources.luau`:

```lua
res_scrap_alloy = {
    displayName = "Scrap Alloy",
    tier = "Common",          -- Common | Industrial | Natural | Rare
    stackMax = 100,
    tradeable = true,         -- default; set false to apply the Untradeable tag
    description = "Salvaged metal for basic repairs and construction.",
},
```

Tiers map to GDD §10.2: Common, Industrial, Natural and Rare. Tier drives default node scarcity and is shown in UI, but has no hidden rules of its own.

### 2.2 Resource nodes

A node is a placed world object tagged `ResourceNode` with attribute `nodeType`. Node types in `Economy/Config/ResourceNodes.luau`:

```lua
node_scrap_pile = {
    yields      = { { item = "res_scrap_alloy", min = 2, max = 4 } },
    gatherTime  = 3,              -- seconds of uninterrupted channel
    toolTag     = nil,            -- optional item tag required (e.g. "tool_cutter")
    capacity    = 20,             -- gathers before depletion
    regen       = { mode = "PerEvent" },  -- PerEvent | Timed(seconds) | None
    factions    = nil,            -- nil = anyone; or list of faction ids
    territory   = nil,            -- set from placement; see §5
},
```

**Scarcity (GDD §10.3).** Each node has finite `capacity`. When it hits zero it is depleted and cannot be gathered.

- `PerEvent`: refills at the start of each PD event (the default for Rare).
- `Timed`: refills one unit every N seconds during an active PD.
- `None`: one-time deposit. Loreteam/Dev reseed it manually.

**Distribution between PDs.** Staff can enable, disable, re-tier or change capacity of individual nodes between PDs with a staff command. This lets distribution follow the Loreteam's narrative (GDD §10.3) without a code change. Node state (remaining capacity, enabled) is persisted in world state.

### 2.3 Gathering flow

1. Client fires `Gather:Request(nodeId)`.
2. Server checks: PD active, player alive and not downed, within range, node enabled and not depleted, faction allowed, tool held (if required), territory access allowed (§5.3), and the node is not already being gathered by this player.
3. Server starts a channel of `gatherTime`. Moving out of range, taking damage or entering combat cancels it.
4. On completion: decrement capacity, roll yield, add items through the inventory API. If the inventory is full, the gather fails before capacity is spent.
5. Log `{player, character, node, items, time}`.

Hunting and other sources in §10.1 (exploration, operations, event rewards) all grant resources through the same inventory API. Hunting creatures are out of scope here and can reuse the node model later (a creature drops a node-like yield on death).

### 2.4 Resource loss and capture (GDD §10.4)

No new mechanism is needed. Resources are lost through systems that already exist or are defined here:

- PD death puts them into the death satchel (inventory thread).
- Trades and theft go through inventory.
- Facility storage can be looted or seized when a facility is destroyed or captured (§4.5).

---

## 3. Crafting (GDD §11)

### 3.1 Recipes

`Economy/Config/Recipes.luau`:

```lua
rcp_blade_serrated = {
    displayName = "Serrated Blade",
    inputs      = { res_scrap_alloy = 6, res_fibre_cord = 2 },
    outputs     = { { item = "wpn_sword", variation = "var_sword_serrated", qty = 1 } },
    station     = "stn_forge",          -- station type required
    craftTime   = 8,
    factions    = { "FactionA" },            -- nil = any faction
    requires    = {                     -- all optional
        minRank      = nil,             -- read from core rank record; never modified
        permission   = "craft_weapons", -- faction-leadership or staff-granted flag
    },
},
```

**Requirement checks (GDD §11.3).** A craft succeeds only if all of these hold:

- The player has every input in their inventory.
- The player is at a working station of the right type (§3.2).
- The player's faction is allowed.
- If `minRank` is set, the character's rank (read-only) meets it.
- If `permission` is set, the character holds that permission. Permissions are granted by faction leadership or staff through the core permission API. Crafting reads them and never grants them.

**Recipe locks.** Staff can lock or unlock a recipe globally or per faction at runtime, for narrative restrictions on specific equipment (GDD §11.3). This is a staff command, and changes are logged.

### 3.2 Stations

A station is either a standalone world object or a function of a facility (§4). `Economy/Config/Stations.luau` defines station types (`stn_workbench`, `stn_forge`, `stn_field_lab`…). A facility-provided station only works while that facility is `Operational`, so damaging or capturing a facility removes its crafting from the owner (GDD §12.4).

### 3.3 Crafting flow

1. Client fires `Craft:Request(recipeId, stationId)`.
2. Server validates §3.1 plus range to the station and PD active.
3. Channel `craftTime`. It cancels on leaving range, entering combat or the station going non-operational.
4. On completion, a **single inventory transaction** removes the inputs and adds the outputs. If any part fails, nothing changes, so there are no lost materials and no duplicated outputs.
5. Log `{player, character, recipe, station, inputs, outputs, time}`.

### 3.4 Weapon crafting (GDD §11.2, §5.5)

A crafted weapon is an item instance:

```lua
{ itemId = "wpn_sword", variation = "var_sword_serrated", crafter = characterId }
```

`variation` selects the appearance and R Critical attack defined by the combat thread. The weapon type (`wpn_sword`) maps to the kit the combat system checks when the player tries to equip or use it. **Crafting code has no access to kit records.** A player can craft, hold and trade a sword they are not approved to use. Equipping it without a kit is refused by combat validation.

---

## 4. Facilities (GDD §12)

### 4.1 Facility types

`Economy/Config/Facilities.luau` defines each type by function, not by lore name:

```lua
fac_forward_base = {
    displayName = "Forward Operating Base",
    factions    = { "FactionA" },
    cost        = { res_scrap_alloy = 120, res_circuitry = 20 },
    buildPoints = 300,              -- work required to finish
    maxHealth   = 5000,
    footprint   = "Large",
    provides    = { "spawn_point", "storage:200" },
    capturable  = true,
    capturePoint = { radius = 25, holdTime = 120 },
    requiresTerritory = "ownedOrContested",
},
```

Provided functions (the `provides` list) cover what GDD §12.2–12.3 lists:

| Function | Used by |
|---|---|
| `station:<type>` | Weapon Manufacturing, Weapon Crafting Stations, Research Labs |
| `storage:<slots>` | Storage & Logistics, Resource Storage |
| `extractor:<nodeType>` | Resource Extraction Stations, Gathering Areas (passively fills storage from a linked node) |
| `heal_zone` | Medical Stations, Medical and Healing Areas |
| `spawn_point` | Forward Operating Bases, Clan Settlements |
| `comms` | Communications Facilities (map pings for the owning faction) |
| `ceremony_site` | Spiritual and Cultural Sites (a marker for Loreteam events; no automatic effects) |
| `defence` | Defensive Outposts and Positions (higher health, capture point) |

The default config ships one facility type per GDD bullet for each faction, using original display names.

### 4.2 Lifecycle

```
Planned ──contribute materials + build work──▶ UnderConstruction ──▶ Operational
Operational ──damage──▶ Damaged (< 50% HP, functions degraded)
Damaged ──repair──▶ Operational
Damaged/Operational ──0 HP──▶ Destroyed (ruin; rebuild from Planned)
Operational/Damaged ──capture──▶ Operational under the new faction
```

- **Placement.** A player with the faction's `build` permission places a blueprint in a valid build zone. Build zones are config regions tied to territories (§5). The server checks footprint collisions, the territory rule and the per-faction facility cap.
- **Construction.** Any faction member can deposit materials and do build work (hold interact). This keeps it cooperative (GDD §12.1). It finishes when both the cost and `buildPoints` are met.
- **Repair.** Costs a fraction of the materials plus build work.
- **Persistence.** Facilities persist across PD events in world state (GDD §3.3). Destruction is only cleaned up by staff.

### 4.3 Damage (GDD §12.4)

- Facilities can only be damaged during an active PD, in the **Conflict** phase if the core PD state exposes phases (config flag).
- Damage comes through the combat system's damage pipeline using a structure target type. Weapons, abilities and siege items can carry a structure damage multiplier in their combat config.
- Same-faction damage is ignored.

### 4.4 Capture

A capturable facility has a capture point. During an active PD:

1. Attackers stand in the radius with no living defenders present. Progress fills over `holdTime`.
2. Defenders in the radius pause progress (contested). Progress decays slowly while attackers are absent.
3. At 100%, ownership moves to the attacking faction. Facility functions switch to the new owner and storage is handled per §4.5.
4. The event is logged and Loreteam is notified, since major facility losses carry narrative consequences that they decide (GDD §12.4).

Staff can also set owner, health or state directly with a staff command, to apply Loreteam-recognised outcomes from events run outside the mechanics.

### 4.5 Facility storage on capture or destruction

| Event | Storage contents |
|---|---|
| Destroyed | A configurable share (default 50%) drops as a lootable cache for the rest of the PD. The rest is lost. |
| Captured | Contents transfer to the capturing faction. |
| Staff action | Whatever the staff command specifies. |

This ties into GDD §19 item 1 (stored items and death). The inventory thread defines storage containers. Facility storage is faction-owned, not character-owned, so it is never included in a death satchel.

---

## 5. Territory (GDD §13.1)

### 5.1 Model

Territories are named regions in `Economy/Config/Territories.luau`, each with a world volume:

```lua
ter_north_ridge = {
    place       = "NorthRidge", -- display name from WorldConfig.Places
    adjacent    = { "ter_falls", "ter_basin" },
    landmark    = false,        -- narrative landmark flag
    buildZones  = { "bz_north_ridge_1" },
},
```

Runtime state per territory (persisted):

```lua
{ controller = "FactionA" | "FactionB" | nil, status = "Held" | "Contested" | "Neutral",
  since = timestamp, source = "capture" | "staff" }
```

### 5.2 How control changes

Control changes in two ways, both logged:

1. **In-game capture.** A territory's controller is the faction that owns its designated **anchor facility** (or, if it has none, a capture point placed for that purpose). Capturing the anchor moves control.
2. **Staff ruling.** Loreteam sets the controller directly to record an outcome from an operation, event or political decision (GDD §13.1). A staff ruling can also **lock** a territory so it cannot be captured until unlocked.

See open question Q1 about whether in-game capture should take effect immediately or wait for Loreteam ratification.

### 5.3 What control does

- **Gathering access.** Nodes inside a territory can be set per-node to `ControllerOnly`, `Anyone` or `ContestedAnyone`.
- **Building.** Build zones require the territory to be held by your faction, or contested if the facility type allows it.
- **Map display.** Faction colours on the map and a territory list UI.

Control never changes ranks, kits or entitlements by itself.

---

## 6. Entitlements and challenges (GDD §13.2–13.3)

### 6.1 Entitlement records

```lua
{
    id          = "ent_000123",
    kind        = "Leadership" | "FacilityControl" | "ResourceAccess"
                | "OperationAuthority" | "Representative" | "TerritoryControl",
    holder      = { type = "character" | "faction" | "group", id = "..." },
    subject     = { type = "facility" | "territory" | "node" | "role" | "operation", id = "..." },
    status      = "Active" | "Suspended" | "Vacated" | "Revoked",
    grantedBy   = staffUserId,
    grantedAt   = timestamp,
    notes       = "string",
    history     = { { action, by, at, reason }, ... },
}
```

### 6.2 Authority

- **Create, transfer, suspend, revoke:** Loreteam only, through staff tools. The server checks the core staff-role API on every write, and there is no other code path that writes to the store.
- **Read:** all staff. Players can see public entitlements (who leads what) in a UI.
- **Gameplay enforcement:** systems can *read* entitlements to gate actions, for example `FacilityControl` lets the holder withdraw from that facility's storage. A capture changes facility *ownership* (faction), not the entitlement. When the subject changes hands, the entitlement is flagged **Needs review** for the Loreteam rather than being rewritten automatically.
- **Character death:** when a holder character is confirmed PD-dead, their character-held entitlements are set to `Vacated` (not deleted, history kept) and flagged for Loreteam. This keeps the GDD §4.5 rule that progression does not survive death, without the game deciding a successor.

### 6.3 Challenges

A challenge is also a record, so the Loreteam can run challenges by any method in GDD §13.3 (combat, resource contribution, leadership challenge, special Trial, and so on):

```lua
{
    id = "chl_000045", entitlementId = "ent_000123",
    challenger = { type = "character" | "faction", id = "..." },
    method = "Combat" | "ResourceContribution" | "MilitaryOperation"
           | "Political" | "Leadership" | "SpecialTrial" | "Other",
    status = "Submitted" | "Approved" | "Scheduled" | "Resolved" | "Rejected",
    outcome = nil | "Upheld" | "Transferred",
    filedAt, resolvedBy, resolvedAt, notes,
}
```

- Players can **submit** a challenge (rate-limited). Everything after that is a Loreteam action.
- Resolving with `Transferred` performs the entitlement transfer in the same staff action, so the outcome and the change are one logged step.
- `ResourceContribution` challenges can optionally escrow the contributed items in a staff-held container until resolution, then return or consume them. This is off by default.

---

## 7. Data and persistence

| Store | Scope | Contents |
|---|---|---|
| `WorldState` | Global | Node state, facilities, territory state |
| `Entitlements` | Global | Entitlement and challenge records |
| `AuditLog` | Global, append-only | Gather, craft, facility, capture and entitlement events |
| Inventory stores | Per character / container | Owned by the inventory thread |

- Writes go through a single service per store with versioned updates (`UpdateAsync`), so two servers can't overwrite each other's facility state.
- World state is loaded on server start and saved on change (debounced) and at PD end.
- The audit log is capped and paged for staff UI. The schema matches whatever the core thread's log uses.

---

## 8. Dependencies on other systems

Core calls are from `/mnt/project-files/core/CORE_API.md`. Inventory and combat names are still placeholders until those threads publish their APIs.

**Core framework**

- `CharacterService:GetActiveCharacter(player)` for character id, `faction`, `role` and `rank` (read only).
- `CharacterService:IsAlive(player)`, and `CharacterService:RegisterSwitchGuard` to block switching characters mid-channel.
- `PermadeathService.Permadeath` signal, used to vacate character-held entitlements (§6.2). This system adds no transfer hook, because it holds no character items.
- `DataService:RegisterSection("Economy", { scope = "Character", ... })` only for small per-character state (gather cooldowns). World state, entitlements and the audit log are their own stores (§7) on the core `SafeStore` wrapper.
- `Shared.Net` and `Net/Remotes.luau` for the `Gather`, `Craft`, `Facility`, `Territory` and `Entitlement` remotes.

**Staff tools and PD events**

- `PDEventService:IsActive()` and `PDEventService:GetActiveEvent()` (phase, if exposed), plus PD start and end signals. These drive node refill, cache cleanup and every gate.
- `StaffService:HasPermission(player, permission)`. Proposed permissions: `economy.nodes`, `economy.recipes`, `facility.admin`, `territory.rule`, `entitlement.write`. `entitlement.write` and `territory.rule` should be Loreteam-only.
- Faction-level permissions for players (`build`, `craft_weapons`). If no faction permission system exists, these become role checks against `WorldConfig.Factions[faction].roles` in config.

**Inventory**

- `Inventory.Transact(character, { remove = {...}, add = {...} })`: atomic, returns success or reason.
- `Inventory.HasItems`, `Inventory.HasTag` (tools).
- Container API for facility storage (faction-owned containers).
- Item definitions accepting `category`, `tier`, `variation` and `tradeable`.

**Combat**

- `Combat.IsInCombat(player)` to cancel channels.
- Structure damage: a way to register facility hitboxes as damageable targets and receive damage events.
- Weapon variation registry (so recipes can reference valid `variation` ids).

---

## 9. Module layout

This follows the core Rojo layout. The inventory system already uses the `Economy` folders, so this system uses `Production` (gathering, crafting) and, later, `Territory` (facilities, territory, entitlements).

```
src/shared/Production/
  ProductionConfig.luau   flags, ranges, role permission flags
  ProductionRemotes.luau
  Config/ResourceNodes.luau  Recipes.luau  Stations.luau
src/server/Services/Production/
  NodeEngine.luau          pure node rules (scarcity, regen, staff overrides)
  CraftingEngine.luau      pure recipe rules and all-or-nothing apply
  GatheringService.luau    CraftingService.luau    ProductionAdminService.luau
  Channels.luau  ProductionDeps.luau  WorldStore.luau   helpers (not *Service)
src/client/Controllers/Production/
  GatherController.luau    proximity prompts for nodes and stations
src/shared/Territory/
  TerritoryConfig.luau  TerritoryRemotes.luau
  Config/Facilities.luau  Territories.luau   (territory display names live in WorldConfig.Places)
src/server/Services/Territory/
  FacilityEngine.luau  TerritoryEngine.luau  EntitlementEngine.luau   pure rules
  FacilityService.luau  TerritoryService.luau  EntitlementService.luau
src/client/Controllers/Territory/
  FacilityController.luau   proximity prompts for build zones and facilities
tests/Specs/Production/*.spec.luau  tests/Specs/Territory/*.spec.luau
tools/run-world-specs.lua   runs the pure specs with plain Lua 5.4
```

Resources are the inventory system's `Material.*` items for now (placeholder content in its `ItemDefinitions`). Node and recipe configs reference those ids.

---

## 10. Delivery plan

Each step is its own PR:

1. **This design doc.**
2. **Config + ResourceNodeService** (gathering, scarcity, refill, staff node commands).
3. **CraftingService + stations** (recipes, requirement checks, atomic transactions, recipe locks).
4. **FacilityService** (placement, construction, damage, repair, capture, storage outcomes).
5. **TerritoryService** (control state, anchor capture, staff rulings, access rules, map UI).
6. **EntitlementService** (records, challenges, staff tools, death vacating).

All six steps are implemented on this branch. Facilities take damage through `CombatService:RegisterStructure`. Staff use chat commands registered with `StaffCommandService:RegisterCommand` (`/nodes`, `/node`, `/recipe`, `/facility`, `/territory`, `/ent`, `/challenge`).

---

## 11. Open questions

**Q1. Should in-game territory capture take effect immediately?**
Recommended: yes. Capture changes control live during the PD, so gathering and building react straight away, and Loreteam can override or reverse it with a staff ruling. The alternative is that capture only creates a *pending* result that Loreteam ratifies at PD Resolution. That gives more narrative control but makes the battlefield feel unresponsive.

**Q2. Should gathering and crafting work outside PD events?**
Recommended: no, both are PD-only by default (GDD §3.1 places them in the event). Each is a config flag.

**Q3. Facility storage when destroyed.** Is the 50% lootable cache and 50% lost split right?

**Q4. Facility caps.** Should there be a per-faction cap on facility count, or per-territory caps only?

**Q5. Independent affiliations.** Can Rogues and Lone Warriors build facilities or hold territory? Recommended: they can gather and craft at neutral stations, but not build or hold territory, which keeps the main conflict central (GDD §2.3).

---

## 12. Not done yet

- **Facility storage** (§4.5). Facilities flagged `storage` don't hold items yet. Storing them needs a faction-owned container from the inventory system, which only has character containers today.
- **Spawn points, heal zones, comms and passive extractors** are markers in config only. They need the systems that would use them.
- **A real UI** for building, crafting and the territory map. The current clients use proximity prompts only.
- **More than one server.** World state (nodes, facilities, territory, entitlements) is one global record per section, and the last write wins. That's fine while a PD runs on one server. Several servers at once would need cross-server messaging.
