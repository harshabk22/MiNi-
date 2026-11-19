# Contributing

Bug reports, fixes and improvements are all welcome.

## Before you start
- **Bugs and ideas:** open an issue first, so we can agree on the approach.
- **Security problems:** don't open an issue. Follow [SECURITY.md](SECURITY.md) instead.

## Setup
```bash
./install.sh                     # Python env, model, app
```

## Rules
1. **Everything stays local.** No telemetry, no cloud AI, no new network calls without a clear reason in the PR.
2. **Safety stays on.** Don't weaken the approval prompts, the sandbox or the password-field check.
3. **No personal data in commits.** `assistant/data/`, logs, `.db` files and vocabularies are git-ignored. Keep it that way.
4. **Keep it small.** Mini has to run on an 8 GB Mac. Discuss new dependencies in an issue first.
5. **Tests must pass:**
   ```bash
   assistant/.venv/bin/python assistant/tests/test_mini.py      # Mini (offline, ~2 s)
   cd dictate && ./build.sh && .build/dictatetest               # Mini Dictate (macOS 26+)
   ```
6. **Match the style around you.** Short functions, comments that explain *why*, no dead code.

## Pull requests
- One change per PR, with a clear title ("Fix: …", "Add: …").
- Say what you tested and on which macOS version.
- Update the README if behaviour changes.

By contributing, you agree to release your work under the [MIT License](LICENSE) and to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
