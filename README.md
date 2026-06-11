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

1. Use `:CursorTab toggle` to enable/disable
2. Use `:checkhealth cursor-tab` after the plugin has loaded to verify Cursor auth, dependencies, and the server binary.
