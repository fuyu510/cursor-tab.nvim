local source = debug.getinfo(1, "S").source
local plugin_dir = vim.fn.fnamemodify(source:sub(2), ":h")
local installer = dofile(plugin_dir .. "/lua/cursor-tab/installer.lua")

if not installer.ensure_binary(plugin_dir) then
	error("cursor-tab: failed to install or build server binary")
end
