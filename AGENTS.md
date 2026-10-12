# GravityReader development workflow

- The user loses motivation when repeated restarts require entering settings again. Keep the running app alive during development.
- Use `swift build` and `swift test` while iterating. Do not repeatedly run `dev.sh` or `build.sh`, replace the running app bundle, or re-sign it during intermediate changes.
- Package the app once after the final changes and checks. Restart at most once at the end, only when necessary to activate the completed work or when explicitly requested.
- If the user asks to avoid further restarts, save the completed changes and explain which changes await the next restart. Do not restart to inspect each individual UI change.
- Preserve existing settings, credentials, memory and voice profiles. Archive requested resets before changing active data.

- Current user instruction: do not restart, package, replace, or re-sign GravityReader.app until the user explicitly approves. Source edits and `swift build`/`swift test` are allowed. A fresh experience reset is queued in Application Support and must archive the latest saved experiences when the approved next startup occurs.
