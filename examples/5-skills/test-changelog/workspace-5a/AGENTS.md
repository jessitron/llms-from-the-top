# Agents.md

In this project, whenever you make a change, please update the changelog.

Make a commit only when instructed.

## Changelog

Changelog entries in this project follow this format:

`## YYYY.MM.DD <emoji> <lowercase past-tense summary, no period> — <component tag>`

Emoji vocabulary:
✨ feature
🐛 fix
🔧 refactoring
📝 docs
⚡ perf
💥 breaking change

A 💥 entry is always followed by an indented `migrate:` line explaining the upgrade, e.g.:

## 2024.02.01 💥 renamed --name positional arg to --name flag — greeter

    migrate: replace `greeter Alice` with `greeter --name Alice`

New entries go at the top of the file, above the existing entries.

## Commit message style

Commit messages in this project follow this format:

<risk level> <emoji> <lowercase imperative summary, no period>

We divide all behaviors of the system into 3 sets. The change is intended to alter the Intended Change while not altering any of the Invariants. The Risk Levels are based on correctness guarantees: which invariants can this commit guarantee did not change, and can this commit guarantee that it changed the intended change in the way the authors intended?

| Risk Level        | Code | Example                                    | Meaning                                | Correctness Guarantees                                |
| ----------------- | ---- | ------------------------------------------ | -------------------------------------- | ----------------------------------------------------- |
| (Proven) Safe     | `.`  | `. r Extract method`                       | Addresses all known and unknown risks. | Intended Change, Known Invariants, Unknown Invariants |
| Validated         | `^`  | `^ r Extract method`                       | Addresses all known risks.             | Intended Change, Known Invariants                     |
| Risky             | `!`  | `! r Extract method`                       | Some known risks remain unverified.    | Intended Change                                       |
| (Probably) Broken | `@`  | `@ r Start extracting method with no name` | No risk attestation.                   |                                                       |

Emoji vocabulary:
✨ feature
🐛 fix
🔧 refactoring
📝 docs
⚡ perf
💥 breaking change
