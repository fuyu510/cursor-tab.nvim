# cursor-tab.nvim

⚠️ **Experimental** - Very loosely tested, under active development. Use at your own risk.

Brings Cursor's AI-powered tab completion to Neovim. Get code suggestions as you type and accept them with Tab, just like in Cursor IDE.

## Requirements

**System:**
- macOS and Linux are supported
- curl (for HTTP requests and binary download)
- sqlite3 (to read Cursor IDE credentials from `state.vscdb`)
- Go 1.21+, make, and buf CLI if the server binary must be built locally

**Critical:**
- **Cursor IDE or Cursor Agent must be installed**
- **You must be signed into Cursor** (plugin reads your auth token automatically)

Without Cursor installed or Cursor Agent authenticated, the plugin won't work.

Cursor auth is read from Cursor's global state database first:
- macOS: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- Linux: `${XDG_CONFIG_HOME:-~/.config}/Cursor/User/globalStorage/state.vscdb`

If the Cursor IDE database is not present, the plugin falls back to Cursor Agent auth:
- Linux: `${XDG_CONFIG_HOME:-~/.config}/cursor/auth.json`

You can also override auth with environment variables:
- `CURSOR_TAB_ACCESS_TOKEN` or `CURSOR_AUTH_TOKEN`
- `CURSOR_TAB_MACHINE_ID`

## Installation

### lazy.nvim

If you use lazy.nvim's default behavior (`defaults.lazy = false`), this is enough:

```lua
{
  "fuyu510/cursor-tab.nvim",
}
```

lazy.nvim runs the bundled `build.lua` on install/update, so the server binary is prepared automatically.
It downloads the release binary first; if no release binary is available, it falls back to building the server locally with `make build`.

If your lazy.nvim config sets `defaults.lazy = true`, add load triggers:

```lua
{
  "fuyu510/cursor-tab.nvim",
  event = "InsertEnter",
  cmd = { "CursorTab", "CursorTabInstall" },
}
```

Without a trigger, lazy.nvim installs the plugin but never loads it, so `:CursorTab` and `:checkhealth cursor-tab` will not be available.

### packer.nvim
```lua
use {
  "fuyu510/cursor-tab.nvim",
  config = function()
    require("cursor-tab").setup()
  end
}
```

### vim-plug
```vim
Plug 'fuyu510/cursor-tab.nvim'
```

Add to `init.lua`:
```lua
require("cursor-tab").setup()
```

### Manual Binary Installation

If auto-download fails, you can manually install:
1. Download the binary for your platform from [Releases](https://github.com/fuyu510/cursor-tab.nvim/releases/latest)
2. Place it at `~/.local/share/nvim/lazy/cursor-tab.nvim/bin/cursor-tab-server` (or equivalent path for your plugin manager)
3. Make it executable: `chmod +x path/to/cursor-tab-server`

Or run `:CursorTabInstall` in Neovim to retry auto-installation.

### Custom Server Path (Optional)
```lua
require("cursor-tab").setup({
  server_path = "/custom/path/to/cursor-tab-server"
})
```

### Building from Source (Optional)

If you prefer to build from source:

```bash
# Requirements: Go 1.21+ and make; buf CLI is only needed if generated protobuf files are missing
git clone https://github.com/fuyu510/cursor-tab.nvim ~/.config/nvim/pack/plugins/start/cursor-tab.nvim
cd ~/.config/nvim/pack/plugins/start/cursor-tab.nvim
make build
```

## Config

### Full Setup Example

```lua
require("cursor-tab").setup({
  -- Path to the server binary (auto-detected by default)
  server_path = nil,

  -- Debounce delay in ms before requesting a suggestion after typing stops
  debounce_time_ms = 600,

  -- Suppress new requests for this duration (ms) after accepting a suggestion
  suppress_duration_ms = 1200,

  -- Additional filetypes to disable (merged with built-in defaults)
  disabled_filetypes = {},

  -- Additional buffer types to disable (merged with built-in defaults)
  disabled_buftypes = {},

  -- Max lines to compare when trimming overlapping context from suggestions
  max_context_lines = 5,

  -- Key to accept suggestions in insert mode
  accept_key = "<Tab>",

  -- Disable suggestions for dotfiles (files starting with '.')
  -- Prevents sending sensitive config files to Cursor API
  disable_dotfiles = true,
})
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `server_path` | auto | Custom path to the `cursor-tab-server` binary |
| `debounce_time_ms` | `600` | Delay (ms) after typing stops before requesting a suggestion |
| `suppress_duration_ms` | `1200` | Duration (ms) to suppress new requests after accepting a suggestion |
| `disabled_filetypes` | `{}` | Extra filetypes to disable (added to built-in: `TelescopePrompt`, `prompt`, `neo-tree`, `NvimTree`, `help`, `qf`) |
| `disabled_buftypes` | `{}` | Extra buffer types to disable (added to built-in: `acwrite`, `help`, `nofile`, `nowrite`, `prompt`, `quickfix`, `terminal`) |
| `max_context_lines` | `5` | Max lines used to detect and trim overlapping context between suggestions and existing buffer content |
| `accept_key` | `<Tab>` | Insert-mode key to accept a suggestion |
| `disable_dotfiles` | `true` | Skip suggestions for dotfiles (files starting with `.`) to prevent sending sensitive configs to Cursor API |

### Commands

| Command | Description |
|---------|-------------|
| `:CursorTab toggle` | Toggle enable/disable |
| `:CursorTab enable` | Enable suggestions |
| `:CursorTab disable` | Disable suggestions |
| `:CursorTabInstall` | Re-install the server binary |

Use `:checkhealth cursor-tab` after the plugin has loaded to verify Cursor auth, dependencies, and the server binary.
