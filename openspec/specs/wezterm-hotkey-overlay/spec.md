# Spec: wezterm-hotkey-overlay

## Purpose

Provide an in-terminal, fuzzy-filterable overlay in WezTerm that documents the available hotkeys (WezTerm mux leader bindings plus curated Neovim and Claude Code references) and can execute the mux bindings, generated from a single source of truth so bindings and documentation never drift.

## Requirements

### Requirement: Hotkey overlay is invocable via LEADER ?

The WezTerm configuration SHALL bind `LEADER ?` to open an in-terminal overlay listing the categorized hotkeys.

#### Scenario: Opening the overlay

- **WHEN** the user presses the leader key (Ctrl+Space) followed by `?`
- **THEN** an overlay titled "Hotkeys" opens over the current pane

#### Scenario: Dismissing the overlay

- **WHEN** the overlay is open and the user presses Escape
- **THEN** the overlay closes without executing any action

### Requirement: Overlay lists every leader binding with key and description

The overlay SHALL display one entry per leader keybinding under the `MUX` category, showing the key and a human-readable description, and SHALL support fuzzy filtering by typing.
Only `MUX` entries SHALL be used to generate `config.keys`; reference categories MUST NOT produce keybindings.

#### Scenario: All bindings listed

- **WHEN** the overlay is open
- **THEN** every binding defined with `mods = LEADER` in the configuration appears as a `[MUX]` entry showing its key and description

#### Scenario: Fuzzy filtering

- **WHEN** the overlay is open and the user types "split"
- **THEN** the list narrows to entries whose labels fuzzy-match "split", regardless of category

#### Scenario: Reference sections do not create keybindings

- **WHEN** the configuration is loaded
- **THEN** `config.keys` contains exactly one binding per MUX table entry and none for NVIM or CLAUDE entries

### Requirement: Selecting an overlay entry executes its binding

The overlay SHALL execute the action of the selected entry in the pane the overlay was opened from.

#### Scenario: Executing an action from the overlay

- **WHEN** the user opens the overlay, selects the "Split horizontal" entry, and confirms with Enter
- **THEN** the current pane splits horizontally, exactly as if the user had pressed `LEADER \`

### Requirement: Bindings and overlay derive from a single source of truth

The leader keybindings in `config.keys` and the overlay entries SHALL both be generated from one shared data table, and all pre-existing leader bindings SHALL retain their exact key and action.

#### Scenario: No drift between bindings and overlay

- **WHEN** a leader binding is added to or removed from the shared table
- **THEN** both the active keybinding and its overlay entry appear or disappear together, with no second location to update

#### Scenario: Existing bindings unchanged

- **WHEN** the refactored configuration is loaded
- **THEN** every leader binding that existed before the change (splits, pane navigation, resize, zoom, close, tabs, rename, tab numbers, copy mode) works with the same key and behavior as before

### Requirement: Overlay entries are grouped into labeled categories

Every overlay entry SHALL carry a visible category label, with entries of the same category listed contiguously.
The initial categories are `MUX` (WezTerm leader bindings), `NVIM` (Neovim keymaps), and `CLAUDE` (Claude Code CLI shortcuts).

#### Scenario: Categories are visible and grouped

- **WHEN** the overlay is open with no filter text
- **THEN** each entry's label starts with its category tag (e.g. `[MUX]`, `[NVIM]`, `[CLAUDE]`) and each category's entries appear as one contiguous block

#### Scenario: Filtering by category name

- **WHEN** the overlay is open and the user types `nvim`
- **THEN** the list narrows to the NVIM section's entries

### Requirement: Overlay includes an NVIM reference section

The overlay SHALL include a curated NVIM category listing the custom keymaps defined in `.config/nvim/lua/keymaps.lua`, each shown with its key chord and a human-readable description.

#### Scenario: NVIM keymaps listed

- **WHEN** the overlay is open
- **THEN** the NVIM section lists the custom keymaps (escape chords, window navigation and resize, line moves, quickfix, buffer navigation, splits, diagnostics) with their key chords

### Requirement: Overlay includes a CLAUDE CLI reference section

The overlay SHALL include a curated CLAUDE category listing default Claude Code CLI keyboard shortcuts relevant to daily use, each shown with its key and a human-readable description.

#### Scenario: Claude Code shortcuts listed

- **WHEN** the overlay is open
- **THEN** the CLAUDE section lists default Claude Code CLI shortcuts (e.g. mode cycling, interrupt, bash prefix) with their keys

### Requirement: Reference entries are display-only

Entries in reference categories (NVIM, CLAUDE) SHALL NOT carry a WezTerm action; selecting one SHALL close the overlay without executing anything or modifying any pane.

#### Scenario: Selecting a reference entry

- **WHEN** the user opens the overlay, highlights an NVIM or CLAUDE entry, and confirms with Enter
- **THEN** the overlay closes and no action is performed in the terminal
