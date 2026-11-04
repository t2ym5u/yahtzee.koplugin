# Changelog

All notable changes to this project will be documented in this file.

## [1.0.4] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.0.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- First release: Yahtzee (Yam's) with five pip-drawn dice, three rolls a
  turn, tap-to-hold, and the full 13-box sheet — upper bonus at 63, 100-point
  Yahtzee bonus and the forced Joker rule.
- Solo with best score kept, 1-4 player hotseat, and up to three computer
  players using an expected-value dice keeper (averages ~240 points).
- Two-tap scoring: the first tap highlights a box with its score, the second
  writes it.
- Game saved and restored on close, French/Spanish/German translations.
