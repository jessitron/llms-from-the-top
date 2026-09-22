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