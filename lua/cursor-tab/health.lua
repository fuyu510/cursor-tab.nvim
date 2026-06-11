local M = {}

local function health()
	return vim.health or require("health")
end

local function ok(message)
	local h = health()
	if h.ok then
		h.ok(message)
	else
		h.report_ok(message)
	end
end

local function warn(message)
	local h = health()
	if h.warn then
		h.warn(message)
	else
		h.report_warn(message)
	end
end

local function error(message)
	local h = health()
	if h.error then
		h.error(message)
	else
		h.report_error(message)
	end
end

local function info(message)
	local h = health()
	if h.info then
		h.info(message)
	else
		h.report_info(message)
	end
end

local function start(message)
	local h = health()
	if h.start then
		h.start(message)
	else
		h.report_start(message)
	end
end

local function file_exists(path)
	return path and path ~= "" and vim.fn.filereadable(path) == 1
end

local function read_json_file(path)
	if not file_exists(path) then
		return nil
	end

	local lines = vim.fn.readfile(path)
	if not lines or #lines == 0 then
		return nil
	end

	local ok_json, decoded = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
	if ok_json then
		return decoded
	end

	return nil
end

local function state_db_candidates()
	if vim.env.CURSOR_TAB_STATE_DB and vim.env.CURSOR_TAB_STATE_DB ~= "" then
		return { vim.env.CURSOR_TAB_STATE_DB }
	end

	local home = vim.loop.os_homedir()
	local sysname = vim.loop.os_uname().sysname:lower()

	if sysname == "darwin" then
		return {
			home .. "/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
		}
	end

	if sysname == "linux" then
		local candidates = {}
		if vim.env.XDG_CONFIG_HOME and vim.env.XDG_CONFIG_HOME ~= "" then
			table.insert(candidates, vim.env.XDG_CONFIG_HOME .. "/Cursor/User/globalStorage/state.vscdb")
			table.insert(candidates, vim.env.XDG_CONFIG_HOME .. "/cursor/User/globalStorage/state.vscdb")
		end
		table.insert(candidates, home .. "/.config/Cursor/User/globalStorage/state.vscdb")
		table.insert(candidates, home .. "/.config/cursor/User/globalStorage/state.vscdb")
		return candidates
	end

	return {}
end

local function agent_auth_candidates()
	local candidates = {}
	if vim.env.CURSOR_AUTH_TOKEN and vim.env.CURSOR_AUTH_TOKEN ~= "" then
		return candidates
	end
	if vim.env.CURSOR_TAB_ACCESS_TOKEN and vim.env.CURSOR_TAB_ACCESS_TOKEN ~= "" then
		return candidates
	end

	local home = vim.loop.os_homedir()
	if vim.env.XDG_CONFIG_HOME and vim.env.XDG_CONFIG_HOME ~= "" then
		table.insert(candidates, vim.env.XDG_CONFIG_HOME .. "/cursor/auth.json")
		table.insert(candidates, vim.env.XDG_CONFIG_HOME .. "/Cursor/auth.json")
	end
	table.insert(candidates, home .. "/.config/cursor/auth.json")
	table.insert(candidates, home .. "/.config/Cursor/auth.json")
	return candidates
end

local function find_state_db()
	for _, path in ipairs(state_db_candidates()) do
		if file_exists(path) then
			return path
		end
	end
	return nil
end

local function find_agent_auth()
	for _, path in ipairs(agent_auth_candidates()) do
		local data = read_json_file(path)
		if data and data.accessToken and data.accessToken ~= "" then
			return path
		end
	end
	return nil
end

local function sqlite_has_value(db_path, keys)
	for _, key in ipairs(keys) do
		local query = "SELECT value FROM ItemTable WHERE key = '" .. key .. "' LIMIT 1;"
		local result = vim.fn.system({ "sqlite3", db_path, query })
		if vim.v.shell_error == 0 and vim.trim(result) ~= "" then
			return true, key
		end
	end
	return false, nil
end

local function has_local_machine_id()
	return file_exists("/etc/machine-id") or file_exists("/var/lib/dbus/machine-id")
end

function M.check()
	start("cursor-tab.nvim")

	local ok_module, cursor_tab = pcall(require, "cursor-tab")
	if ok_module then
		ok("Lua module can be required")
	else
		error("Lua module cannot be required: " .. tostring(cursor_tab))
		return
	end

	if vim.g.loaded_cursor_tab then
		ok("Plugin file has loaded")
	else
		warn("Plugin file has not loaded yet. If using lazy.nvim with defaults.lazy = true, add event/cmd triggers.")
	end

	if vim.fn.exists(":CursorTab") == 2 then
		ok(":CursorTab command is available")
	else
		warn(":CursorTab command is not available yet")
	end

	local installer_ok, installer = pcall(require, "cursor-tab.installer")
	if not installer_ok then
		error("Installer module cannot be required: " .. tostring(installer))
		return
	end

	local platform = installer.get_platform()
	if platform then
		ok("Supported platform: " .. platform)
	else
		error("Unsupported platform")
	end

	if vim.fn.executable("curl") == 1 then
		ok("curl is executable")
	else
		error("curl is required to download the server binary")
	end

	if cursor_tab.server_path and installer.binary_exists(cursor_tab.server_path) then
		ok("Server binary is executable: " .. cursor_tab.server_path)
	else
		local source = debug.getinfo(cursor_tab.setup, "S").source
		local plugin_dir = vim.fn.fnamemodify(source:sub(2), ":h:h")
		local binary_path = installer.get_binary_path(plugin_dir)
		if installer.binary_exists(binary_path) then
			ok("Server binary is executable: " .. binary_path)
		else
			warn("Server binary is missing or not executable: " .. binary_path)
		end
	end

	local db_path = find_state_db()
	if db_path then
		ok("Cursor state database found")
		info("Cursor state database: " .. db_path)

		if vim.fn.executable("sqlite3") == 1 then
			ok("sqlite3 is executable")

			local has_token = sqlite_has_value(db_path, { "cursorAuth/accessToken" })
			if has_token then
				ok("Cursor access token is present")
			else
				error("Cursor access token was not found. Open Cursor and sign in.")
			end

			local has_machine_id, key = sqlite_has_value(db_path, {
				"telemetry.macMachineId",
				"storage.serviceMachineId",
				"telemetry.machineId",
				"telemetry.devDeviceId",
			})
			if has_machine_id then
				ok("Cursor machine ID is present: " .. key)
			else
				error("Cursor machine ID was not found")
			end
		else
			error("sqlite3 is required to read Cursor state database")
		end
	else
		local auth_path = find_agent_auth()
		local has_access_token_env = vim.env.CURSOR_TAB_ACCESS_TOKEN and vim.env.CURSOR_TAB_ACCESS_TOKEN ~= ""
		local has_cursor_auth_env = vim.env.CURSOR_AUTH_TOKEN and vim.env.CURSOR_AUTH_TOKEN ~= ""

		if has_access_token_env or has_cursor_auth_env or auth_path then
			info("Cursor state database was not found; using Cursor Agent or environment auth")
		else
			warn("Cursor state database was not found")
		end
		for _, candidate in ipairs(state_db_candidates()) do
			info("Checked: " .. candidate)
		end

		if has_access_token_env then
			ok("Cursor access token is present from CURSOR_TAB_ACCESS_TOKEN")
		elseif has_cursor_auth_env then
			ok("Cursor access token is present from CURSOR_AUTH_TOKEN")
		else
			if auth_path then
				ok("Cursor Agent auth token is present")
				info("Cursor Agent auth file: " .. auth_path)
			else
				error("Cursor access token was not found. Open Cursor Agent and run `cursor login`, or set CURSOR_TAB_ACCESS_TOKEN.")
			end
		end

		if vim.env.CURSOR_TAB_MACHINE_ID and vim.env.CURSOR_TAB_MACHINE_ID ~= "" then
			ok("Cursor machine ID is present from CURSOR_TAB_MACHINE_ID")
		elseif has_local_machine_id() then
			ok("Local machine ID is available")
		else
			error("Cursor machine ID was not found. Set CURSOR_TAB_MACHINE_ID.")
		end
	end
end

return M
