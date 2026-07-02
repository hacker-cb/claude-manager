# Early-stage project policy (temporary)

Project-independent — drop this file into any pre-release project unchanged.
Remove it when the project no longer wants clean-break freedom (e.g. its first
external consumer, or a stable public release); deletion is a manual judgment
call, there is no trigger machinery here.

While active, this rule overrides any reflex toward backward-compatibility
discipline — deprecation trails, compatibility shims, migration/API stability,
additive-only schema changes.

## Principle

- Precondition — no external consumers yet: the only consumers are this repo
  and its dev/CI environments, rebuilt on every run, so a breaking change costs
  nothing outside the repo. Commit history is the audit trail.
- Make the clean change directly: rename, reshape, drop, and refactor wherever
  it improves the design. Keep no transitional or dual-shape scaffolding for
  backward compatibility.

## Rewrite freely

Everything below is internal-only until the project ships externally, so change
it in place with no compatibility layer:

- Schema & migrations — rewrite/merge/reorder the migration set and reseed;
  never stack a legacy migration to fake an upgrade path no one is on.
- Generated snapshots & catalogs (API/OpenAPI snapshot, permission catalog,
  wire-type codegen, …) — regenerate freely; they are drift guards, not contracts.
- API contracts & DTOs — rename fields, reshape, drop endpoints; no dual-shape
  transitional schemas.
- Identifiers — entity/field/column names, public exports/module paths, env
  vars, CLI commands/flags — rename or remove outright.

## Anti-patterns — do not introduce

- Deprecation markers kept for an absent external consumer (the language's
  `@deprecated` / `#[deprecated]` / equivalent).
- Compatibility shims or re-export aliases at an old path after a move or rename.
- Legacy-name fallbacks (`new || old`) for identifiers, config keys, routes,
  permission codes.
- "Soft" migrations — additive-legacy or copy-then-drop steps — where a clean
  replacement works.
- Bridge tables / view aliases for renamed entities, or coupling new code to an
  old name to avoid updating a generator/seed/snapshot.

## How to apply

- "Rename X to Y" = rename across the repo in one change. No phased rollout.
- In doubt whether a surface is depended on from outside the repo? While this
  rule is active, it isn't — change it freely.
