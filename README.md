# Windtraders

A closed-community Permanent Death roleplay experience for Roblox.

## Getting started

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install`
   in this folder to get Rojo, Selene and StyLua.
2. Install the Rojo plugin in Roblox Studio.
3. Run `rojo serve` and connect from the Rojo plugin, or build a place file
   with `rojo build -o Windtraders.rbxlx` and open it.
4. Press Play. With Studio API access off, accounts are kept in memory only
   (a warning says so). Turn on *Game Settings → Security → Enable Studio
   Access to API Services* to use real DataStores.

Tests: `rojo build test.project.json -o test.rbxlx`, open it, press Run and
read the Output window.

## Layout

| Folder       | In Studio                                   |
|--------------|---------------------------------------------|
| `src/shared` | `ReplicatedStorage.Shared`                  |
| `src/server` | `ServerScriptService.Server`                |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` |
| `tests`      | `ServerScriptService.Tests` (test place only) |

Faction, role and place names are all in
`src/shared/Config/WorldConfig.luau`; rename them there.

The shared APIs every system builds on (services, networking, account and
character data, Permanent Death) are documented in
[`docs/CORE_API.md`](docs/CORE_API.md).
