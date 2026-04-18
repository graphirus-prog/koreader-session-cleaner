# Session Cleaner

Session Cleaner is a standalone KOReader plugin for inspecting and cleaning suspicious reading sessions directly from KOReader's statistics database.

Its purpose is very specific: help users identify useless or misleading session fragments in their reading history and remove them safely from the real SQLite source, instead of merely hiding them in the interface.

## What it does

Session Cleaner:

- browses books with reading statistics
- reconstructs sessions from raw `page_stat_data` rows
- highlights suspicious sessions such as no-page-advance and short sessions
- shows the exact raw rows that belong to each session
- can delete the real underlying rows from `statistics.sqlite3`
- can create a backup before deletion
- supports multi-select deletion
- uses KOReader's native menu shell for stable fullscreen navigation
- includes UI scale presets

## Why it exists

KOReader statistics are very useful, but they can accumulate misleading fragments over time: tiny accidental opens, duplicate fragments, no-page-advance sessions, and other noise that makes the reading history less trustworthy.

Session Cleaner is designed as a maintenance tool for users who want more control over their statistics and want to clean the real data safely.

## Safety

Session Cleaner edits the real `statistics.sqlite3` database.

Deletion is always explicit and confirmed. If backup-before-delete is enabled, the plugin creates a backup before removing rows.

The plugin is built around a trusted database/session engine that was preserved through the UI rewrite.

## Highlights in v1.10.1

Version `v1.10.1` is the recommended public baseline.

This release keeps the trusted database/session engine and replaces the older UI with a stable native KOReader menu-based interface.

### Main improvements over the old version

- stable fullscreen native-menu rewrite
- preserved DB/session engine
- exact session inspection before deletion
- multi-select session deletion
- UI scale presets
- cleaner typography and safer row presentation
- faster post-delete navigation through in-memory hot-path updates

## Installation

1. Download the latest release asset ZIP.
2. Extract it so you get a folder named `sessioncleaner.koplugin`.
3. Copy that folder into KOReader's `plugins` directory.
4. Restart KOReader.

## Basic workflow

1. Open **Session Cleaner** from the KOReader menu.
2. Browse books with statistics.
3. Open a book to inspect its reconstructed sessions.
4. Filter suspicious sessions if needed.
5. Open a session to inspect the exact rows that belong to it.
6. Delete one or multiple sessions only after reviewing them.

## Repository layout

- `sessioncleaner.koplugin/core/` — trusted database/session/settings/util engine
- `sessioncleaner.koplugin/main.lua` — navigation and flow
- `sessioncleaner.koplugin/sessioncleaner_presenter.lua` — display-ready data
- `sessioncleaner.koplugin/sessioncleaner_bookcards.lua` — book row presentation
- `sessioncleaner.koplugin/sessioncleaner_sessioncards.lua` — session row presentation
- `sessioncleaner.koplugin/sessioncleaner_renderer.lua` — menu-facing row rendering

## Notes

This plugin is designed to be practical and safe, not magical. It helps you review and clean suspicious statistics data, but the source of truth remains KOReader's database.

Smaller readers may naturally show fewer rows and more truncation than larger devices. That is expected.
