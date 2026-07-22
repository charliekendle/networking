# Contributing

## Setup

```bash
rokit install          # rojo, wally, stylua, selene, luau-lsp
wally install
```

## Workflow

1. Branch from `main`.
2. Make changes. Every public function gets `--[=[ ]=]` doc comments and stays `--!strict`.
3. Format + lint: `stylua src tests playtest && selene src tests`.
4. Analyze: `rojo sourcemap test.project.json -o sourcemap.json` then `luau-lsp analyze --sourcemap sourcemap.json --definitions <globalTypes.d.luau> src tests playtest` — must be clean.
5. Test: `rojo build test.project.json -o test.rbxl`, open in Studio, **Run** (unit specs must all pass) and **Play** (all playtest markers must print OK).
6. Add/extend a spec in `tests/` for any behavior change. Specs are plain `{ [name]: (expect) -> () }` tables — see `tests/TestKit.luau`.
7. Update `CHANGELOG.md` under Unreleased.
8. PR. CI runs lint + strict analysis.

## Design rules (short version)

- `Shared/*` never requires `Server/` or `Client/`. `Types` requires nothing.
- Security decisions fail **closed**.
- The hot path allocates nothing it doesn't have to (no table.pack unless middleware/validation actually applies).
- The package detects and reports abuse; it never punishes players itself.
- Wire format changes require new tags, never reinterpreting existing ones.

## Releasing (maintainer)

Bump `wally.toml` + `Network.Version` (must match), finalize CHANGELOG, tag `vX.Y.Z`, push the tag — the release workflow verifies the version match, publishes to Wally (needs `WALLY_TOKEN` secret), and cuts a GitHub release.
