# Changelog

All notable changes to Session Cleaner are documented here.

This project follows a practical changelog style: the goal is to make it clear what changed for users and what changed for maintainers, without pretending every internal edit is equally important.

---

## [1.10.1] - 2026-04-18

### Summary

Session Cleaner v1.10.1 is the recommended public baseline.

This release preserves the trusted database/session engine and brings the plugin to a stable native KOReader menu-based interface. It also improves the real cleanup workflow with batch selection, UI scale presets, exact session inspection, and much faster post-delete navigation.

### User-facing improvements

- stable fullscreen native-menu rewrite
- exact session inspection before deletion
- multi-select session deletion
- UI scale presets: `ultra_tiny`, `compact`, `normal`, `large`
- cleaner and safer row presentation
- book-list page memory when navigating back from sessions
- much faster post-delete responsiveness through in-memory hot-path updates

### Technical changes

- split presentation and UI responsibilities into dedicated modules:
  - `sessioncleaner_presenter.lua`
  - `sessioncleaner_renderer.lua`
  - `sessioncleaner_bookcards.lua`
  - `sessioncleaner_sessioncards.lua`
- moved the stable engine modules into `sessioncleaner.koplugin/core/`
- lazy runtime module loading with surfaced load errors
- added `ui_scale` to persistent settings and normalized stale values at startup
- deduplicated and sanitized row IDs before delete operations
- preserved the trusted database/session engine without modifying its core behavior

### Safety

- deletion still requires explicit confirmation
- backup-before-delete support is preserved
- transaction-based deletion is preserved
- exact raw rows are shown before removal

---

## [1.9.3] - 2026-04-18

### Summary

Focused readability and structural cleanup on top of the stable native-menu branch.

### Changes

- introduced dedicated presentation modules extracted from `main.lua`
- added the `core/` subdirectory for the stable engine modules
- improved module loading and runtime path resolution
- introduced named UI scale presets
- improved book and session row truncation behavior
- added book-list page-position memory
- improved row-ID deduplication before deletion

### Notes

This version was an important structural step, but `1.10.1` is the better public release baseline.

---

## [pre-1.9.3]

Initial functional release.

### Characteristics

- flat file layout
- most logic concentrated in `main.lua`
- book browsing
- session reconstruction
- backup creation
- safe row deletion with confirmation dialogs
