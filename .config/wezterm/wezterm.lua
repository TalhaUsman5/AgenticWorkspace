local wezterm = require('wezterm')
local config = wezterm.config_builder()
local act = wezterm.action

local is_windows = wezterm.target_triple:find('windows') ~= nil
local is_linux = wezterm.target_triple:find('linux') ~= nil

-- No multiplexer domain: every window is a plain local GUI process. WezTerm's
-- own tabs and panes still work; what is gone is session persistence across a
-- GUI close or reboot, along with the mirrored-pane resize bugs that came with
-- it (wezterm/wezterm#2351, #6884).

-- Launch fullscreen. Without a mux domain the GUI always starts via plain
-- `wezterm start`, so 'gui-startup' is the only startup event that fires
-- ('gui-attached' fires in its place only when attaching to a domain).
wezterm.on('gui-startup', function(cmd)
  local _, _, window = wezterm.mux.spawn_window(cmd or {})
  window:gui_window():toggle_fullscreen()
end)

-- Appearance: frameless single-window, no distractions
config.window_decorations = is_windows and 'INTEGRATED_BUTTONS|RESIZE' or 'NONE'
config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = true
config.window_padding = { left = 2, right = 2, top = 2, bottom = 2 }

-- Font
config.font = wezterm.font('IosevkaTerm Nerd Font', { weight = 'Regular' })
config.font_size = is_windows and 12.0 or 14.0
config.line_height = 1.1

-- Color scheme
config.color_scheme = 'Catppuccin Mocha'

-- Performance
config.max_fps = 120
config.animation_fps = 60
config.front_end = 'WebGpu'
-- Prefer the discrete GPU (RTX) over the Intel iGPU; WebGpu defaults to the
-- low-power adapter, whose drivers cause stale-pane artifacts on split/close.
config.webgpu_power_preference = 'HighPerformance'

-- Inactive pane dimming
config.inactive_pane_hsb = {
  saturation = 0.8,
  brightness = 0.6,
}

-- Shell per platform
if is_windows then
  config.default_prog = { 'pwsh.exe', '-NoLogo' }
  config.window_background_opacity = 0.95
else
  config.default_prog = { '/bin/zsh' }
  config.window_background_opacity = 1.0
  config.enable_wayland = true
end

-- Scrollback
config.scrollback_lines = 10000

-- Leader key: F24 (M5 on the Keychron, remapped via Keychron Launcher).
-- WezTerm's Windows backend does not decode F21-F24 into named keys
-- (wezterm/wezterm#5749), so match the raw Win32 virtual key code instead:
-- VK_F24 = 0x87 = 135. Ctrl+Space also works as a secondary leader via the
-- 'secondary_leader' key table below, built from the same mux_bindings.
config.leader = { key = 'raw:135', timeout_milliseconds = 1000 }

-- Leader bindings: single source of truth for config.keys AND the hotkey overlay.
-- Add/remove bindings here only; both the keybinding and its overlay entry follow.
local mux_bindings = {
  -- Pane splits
  { key = '\\', desc = 'Split horizontal', action = act.SplitHorizontal { domain = 'CurrentPaneDomain' } },
  { key = '-',  desc = 'Split vertical',   action = act.SplitVertical   { domain = 'CurrentPaneDomain' } },

  -- Pane navigation (vim-style)
  { key = 'h', desc = 'Focus pane left',  action = act.ActivatePaneDirection('Left') },
  { key = 'j', desc = 'Focus pane down',  action = act.ActivatePaneDirection('Down') },
  { key = 'k', desc = 'Focus pane up',    action = act.ActivatePaneDirection('Up') },
  { key = 'l', desc = 'Focus pane right', action = act.ActivatePaneDirection('Right') },

  -- Pane resize
  { key = 'H', desc = 'Resize pane left',  action = act.AdjustPaneSize { 'Left',  5 } },
  { key = 'J', desc = 'Resize pane down',  action = act.AdjustPaneSize { 'Down',  5 } },
  { key = 'K', desc = 'Resize pane up',    action = act.AdjustPaneSize { 'Up',    5 } },
  { key = 'L', desc = 'Resize pane right', action = act.AdjustPaneSize { 'Right', 5 } },

  -- Pane zoom / close
  { key = 'z', desc = 'Toggle pane zoom', action = act.TogglePaneZoomState },
  { key = 'x', desc = 'Close pane',       action = act.CloseCurrentPane { confirm = true } },

  -- Tabs
  { key = 'c', desc = 'New tab',      action = act.SpawnTab 'CurrentPaneDomain' },
  { key = 'w', desc = 'Close tab',    action = act.CloseCurrentTab { confirm = true } },
  { key = 'n', desc = 'Next tab',     action = act.ActivateTabRelative(1) },
  { key = 'p', desc = 'Previous tab', action = act.ActivateTabRelative(-1) },
  { key = ',', desc = 'Rename tab',   action = act.PromptInputLine {
    description = 'Rename tab',
    action = wezterm.action_callback(function(window, _, line)
      if line then window:active_tab():set_title(line) end
    end),
  }},

  -- Jump to tab by number
  { key = '1', desc = 'Go to tab 1', action = act.ActivateTab(0) },
  { key = '2', desc = 'Go to tab 2', action = act.ActivateTab(1) },
  { key = '3', desc = 'Go to tab 3', action = act.ActivateTab(2) },
  { key = '4', desc = 'Go to tab 4', action = act.ActivateTab(3) },
  { key = '5', desc = 'Go to tab 5', action = act.ActivateTab(4) },

  -- Copy mode
  { key = '[', desc = 'Copy mode', action = act.ActivateCopyMode },

  -- Hotkey overlay (action assigned below, after hotkey_overlay is defined,
  -- so the overlay's choice list includes this entry too).
  -- SHIFT must be explicit: LEADER + shifted punctuation is not normalized
  -- the way shifted letters are (wezterm/wezterm#394).
  { key = '?', mods = 'LEADER|SHIFT', desc = 'Show this hotkey overlay' },
}

-- Reference sections: shown in the hotkey overlay for lookup only. These are
-- not WezTerm bindings and never reach config.keys; selecting one just
-- dismisses the overlay.
local reference_sections = {
  {
    -- Mirrors the custom keymaps in .config/nvim/lua/keymaps.lua (curated by
    -- hand, not parsed) - update both together.
    name = 'NVIM',
    entries = {
      { key = '<Space>',        desc = 'Leader key' },
      { key = 'jk / kj',        desc = 'Exit insert mode' },
      { key = '<C-h/j/k/l>',    desc = 'Focus window left/down/up/right' },
      { key = '<C-Arrows>',     desc = 'Resize window' },
      { key = 'J / K (visual)', desc = 'Move selection down/up' },
      { key = '<C-d> / <C-u>',  desc = 'Half-page scroll, centered' },
      { key = 'n / N',          desc = 'Next/prev match, centered' },
      { key = 'p (visual)',     desc = 'Paste without clobbering register' },
      { key = '<Esc>',          desc = 'Clear search highlight' },
      { key = '<Ldr>qo / qc',   desc = 'Open/close quickfix' },
      { key = ']q / [q',        desc = 'Next/prev quickfix item' },
      { key = '<S-l> / <S-h>',  desc = 'Next/prev buffer' },
      { key = '<Ldr>bd',        desc = 'Delete buffer' },
      { key = '<C-s>',          desc = 'Save file' },
      { key = '<Ldr>sv / sh',   desc = 'Vertical/horizontal split' },
      { key = '<Ldr>sc',        desc = 'Close split' },
      { key = ']d / [d',        desc = 'Next/prev diagnostic' },
      { key = '<Ldr>d',         desc = 'Show diagnostic float' },
    },
  },
  {
    -- Claude Code CLI defaults (code.claude.com/docs/en/interactive-mode).
    name = 'CLAUDE',
    entries = {
      { key = 'Shift+Tab',      desc = 'Cycle permission modes' },
      { key = 'Esc',            desc = 'Interrupt Claude / close dialog' },
      { key = 'Esc Esc',        desc = 'Clear draft, or rewind menu' },
      { key = '! prefix',       desc = 'Shell mode: run command directly' },
      { key = '@',              desc = 'File path autocomplete' },
      { key = '/ prefix',       desc = 'Commands and skills menu' },
      { key = 'Ctrl+O',         desc = 'Toggle transcript viewer' },
      { key = 'Ctrl+R',         desc = 'Search prompt history' },
      { key = 'Ctrl+B',         desc = 'Background running task' },
      { key = 'Ctrl+T',         desc = 'Toggle task checklist' },
      { key = 'Ctrl+G',         desc = 'Edit prompt in text editor' },
      { key = 'Shift+Enter',    desc = 'Insert newline' },
      { key = 'Alt+P',          desc = 'Switch model' },
      { key = 'Alt+T',          desc = 'Toggle extended thinking' },
    },
  },
}

-- Hotkey overlay (LEADER ?): fuzzy-searchable categorized cheatsheet.
-- MUX entries execute when selected, which-key style; reference entries
-- (NVIM, CLAUDE) are display-only and just dismiss. The bracketed category
-- prefix keeps sections fuzzy-filterable (e.g. type 'nvim').
local function hotkey_overlay()
  local function label(section, key, desc)
    return string.format('%-8s %-14s %s', '[' .. section .. ']', key, desc)
  end
  local choices = {}
  for i, b in ipairs(mux_bindings) do
    table.insert(choices, {
      id = 'mux:' .. i,
      label = label('MUX', 'LEADER ' .. b.key, b.desc),
    })
  end
  for _, section in ipairs(reference_sections) do
    for i, e in ipairs(section.entries) do
      table.insert(choices, {
        id = string.format('ref:%s:%d', section.name, i),
        label = label(section.name, e.key, e.desc),
      })
    end
  end
  return act.InputSelector {
    title = 'Hotkeys',
    choices = choices,
    fuzzy = true,
    fuzzy_description = 'Filter hotkeys: ',
    action = wezterm.action_callback(function(window, pane, id)
      local i = id and id:match('^mux:(%d+)$')
      if i then
        window:perform_action(mux_bindings[tonumber(i)].action, pane)
      end
    end),
  }
end

mux_bindings[#mux_bindings].action = hotkey_overlay()

config.keys = {}
for _, b in ipairs(mux_bindings) do
  table.insert(config.keys, { key = b.key, mods = b.mods or 'LEADER', action = b.action })
end

-- Secondary leader (Ctrl+Space): mirrors every LEADER binding through a
-- one-shot key table, since WezTerm allows only a single config.leader.
local leader_table = {}
for _, b in ipairs(mux_bindings) do
  local mods = (b.mods or 'LEADER'):gsub('LEADER|?', '')
  table.insert(leader_table, {
    key = b.key,
    mods = mods == '' and 'NONE' or mods,
    action = b.action,
  })
end
table.insert(config.keys, {
  key = 'Space',
  mods = 'CTRL',
  action = act.ActivateKeyTable {
    name = 'secondary_leader',
    one_shot = true,
    timeout_milliseconds = 1000,
  },
})

-- Copy mode: vi keys
config.key_tables = {
  secondary_leader = leader_table,
  copy_mode = {
    { key = 'h',      mods = 'NONE', action = act.CopyMode('MoveLeft') },
    { key = 'j',      mods = 'NONE', action = act.CopyMode('MoveDown') },
    { key = 'k',      mods = 'NONE', action = act.CopyMode('MoveUp') },
    { key = 'l',      mods = 'NONE', action = act.CopyMode('MoveRight') },
    { key = 'Escape', mods = 'NONE', action = act.CopyMode('Close') },
    { key = 'q',      mods = 'NONE', action = act.CopyMode('Close') },
  },
}

return config
