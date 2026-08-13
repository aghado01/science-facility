---
name: refactor
description: Behavior-preserving code transforms, code smell detection, and refactoring playbooks. Use when reviewing code for smells, cleaning up newly generated functions, or performing systematic refactoring.
---

# Refactoring skill for agents

Behavior-preserving mechanical transforms only. Never mix refactor with feature change or behavior change in the same step.

## Procedure
1. Restrict analysis to the current edit / generation scope.
2. Detect highest-severity smells (Duplicate Code, Long Method, Primitive Obsession, Speculative Generality, Long Parameter List / Data Clumps, Feature Envy, Shotgun Surgery / Divergent Change, Dead Code first).
3. Select the smallest safe technique from the matrix or cards.
4. Apply one transform.
5. Quick syntax / linter check (or AST sanity check if available), then re-run tests, typecheck, and reference search.
6. Repeat until triggers are gone or a design decision outside current scope is required.
7. Prefer deletion and simplification over new abstraction.

## Core principles
- One change, one behavior-preserving transform.
- Name by intention, not implementation.
- Delete before you abstract (anti-Speculative Generality).
- Prefer composition and small intentional surfaces over deep inheritance unless polymorphism clearly pays.
- Agents commonly emit Long Method + Primitive Obsession + Duplicate Code + Speculative Generality in one generation pass — run detection before commit.
- Mechanical steps only; stop when the smell is resolved or further work needs human design judgment.
- Selective loading: load `smells.md` for detection, `techniques.md` only for the chosen technique, `matrix.md` for quick crosswalk.

## Agent anti-patterns (post-generation scan)
- Long methods with nested conditionals and section comments
- Primitive-heavy domain data (status codes, ranges, money, identifiers)
- Near-duplicate helpers re-emitted across files
- Unused parameters, abstract classes with single concrete, “future” hooks
- Long parameter lists or repeated data groups
- Feature envy (methods that mostly manipulate another object’s data)

## File map
- `smells.md` — detection cards (Signals / Treat / Ignore)
- `techniques.md` — mechanical playbooks (When / Steps / Caution)
- `matrix.md` — smell → primary techniques crosswalk

Load only what is needed for the current step.
