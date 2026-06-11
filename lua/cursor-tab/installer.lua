local M = {}

function M.get_platform()
	-- Detect OS and architecture
	local os = vim.loop.os_uname().sysname:lower()
	local arch = vim.loop.os_uname().machine

	-- Map to release naming
	if os == "darwin" then
		if arch == "arm64" then
			return "darwin-arm64"
		else
			return "darwin-amd64"
		end
	elseif os == "linux" then
		if arch == "aarch64" or arch == "arm64" then
			return "linux-arm64"
		else
			return "linux-amd64"
		end
	end

	return nil -- Unsupported platform
end

function M.get_binary_path(plugin_dir)
	return plugin_dir .. "/bin/cursor-tab-server"
end

function M.has_generated_proto(plugin_dir)
	return vim.fn.filereadable(plugin_dir .. "/cursor-api/gen/aiserver/v1/AiServerice.pb.go") == 1
		and vim.fn.filereadable(plugin_dir .. "/cursor-api/gen/aiserver/v1/aiserverv1connect/AiServerice.connect.go") == 1
end

function M.binary_exists(binary_path)
	return vim.fn.filereadable(binary_path) == 1 and vim.fn.executable(binary_path) == 1
end

function M.binary_is_stale(binary_path, plugin_dir)
	local binary_time = vim.fn.getftime(binary_path)
	if binary_time <= 0 then
		return true
	end

	local patterns = {
		"go.mod",
		"go.sum",
		"cmd/**/*.go",
		"internal/**/*.go",
		"cursor-api/gen/**/*.go",
	}

	for _, pattern in ipairs(patterns) do
		local files = vim.fn.globpath(plugin_dir, pattern, false, true)
		for _, file in ipairs(files) do
			if vim.fn.getftime(file) > binary_time then
				return true
			end
		end
	end

	return false
end

function M.run_job(args, opts, callback)
	opts = opts or {}
	local output = {}

	local job = vim.fn.jobstart(args, {
		cwd = opts.cwd,
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if data then
				vim.list_extend(output, data)
			end
		end,
		on_stderr = function(_, data)
			if data then
				vim.list_extend(output, data)
			end
		end,
		on_exit = function(_, exit_code)
			if callback then
				callback(exit_code == 0, table.concat(output, "\n"))
			end
		end,
	})

	if job == 0 or job == -1 then
		if callback then
			callback(false, "failed to start job: " .. table.concat(args, " "))
		end
		return false
	end

	return true
end

function M.download_binary(plugin_dir, callback)
	local platform = M.get_platform()
	if not platform then
		vim.notify("cursor-tab: Unsupported platform", vim.log.levels.ERROR)
		if callback then
			callback(false)
		end
		return false
	end

	local binary_name = "cursor-tab-server-" .. platform
	local url = string.format("https://github.com/fuyu510/cursor-tab.nvim/releases/download/latest/%s", binary_name)

	local bin_dir = plugin_dir .. "/bin"
	local binary_path = bin_dir .. "/cursor-tab-server"
	local download_path = bin_dir .. "/" .. binary_name

	-- Create bin directory
	vim.fn.mkdir(bin_dir, "p")

	vim.notify("cursor-tab: Downloading server binary...", vim.log.levels.INFO)

	-- Download binary
	local download_job = vim.fn.jobstart({ "curl", "-fsSL", "-o", download_path, url }, {
		on_exit = function(_, exit_code)
			if exit_code ~= 0 then
				vim.notify("cursor-tab: Failed to download binary", vim.log.levels.ERROR)
				if callback then
					callback(false)
				end
				return
			end

			-- Make executable and rename
			vim.fn.system({ "chmod", "+x", download_path })
			vim.fn.system({ "mv", download_path, binary_path })

			vim.notify("cursor-tab: Binary installed successfully", vim.log.levels.INFO)
			if callback then
				callback(true)
			end
		end,
	})

	if download_job == 0 or download_job == -1 then
		vim.notify("cursor-tab: Failed to start download job", vim.log.levels.ERROR)
		if callback then
			callback(false)
		end
		return false
	end

	return download_job ~= 0 and download_job ~= -1
end

function M.build_binary(plugin_dir, callback)
	local binary_path = M.get_binary_path(plugin_dir)

	if vim.fn.executable("make") ~= 1 then
		vim.notify("cursor-tab: Cannot build server binary: make is not executable", vim.log.levels.ERROR)
		if callback then
			callback(false)
		end
		return false
	end

	if vim.fn.executable("go") ~= 1 then
		vim.notify("cursor-tab: Cannot build server binary: go is not executable", vim.log.levels.ERROR)
		if callback then
			callback(false)
		end
		return false
	end

	if vim.fn.executable("buf") ~= 1 and not M.has_generated_proto(plugin_dir) then
		vim.notify("cursor-tab: Cannot build server binary: buf is required to generate protobuf code", vim.log.levels.ERROR)
		if callback then
			callback(false)
		end
		return false
	end

	vim.fn.mkdir(plugin_dir .. "/bin", "p")
	vim.notify("cursor-tab: Building server binary from source...", vim.log.levels.INFO)

	return M.run_job({ "make", "build" }, { cwd = plugin_dir }, function(success, output)
		if success and M.binary_exists(binary_path) then
			vim.notify("cursor-tab: Binary built successfully", vim.log.levels.INFO)
			if callback then
				callback(true)
			end
			return
		end

		vim.notify("cursor-tab: Failed to build server binary", vim.log.levels.ERROR)
		if output and output ~= "" then
			vim.notify("cursor-tab build output: " .. output, vim.log.levels.WARN)
		end
		if callback then
			callback(false)
		end
	end)
end

function M.ensure_binary(plugin_dir)
	local binary_path = M.get_binary_path(plugin_dir)

	-- Check if binary already exists, is executable, and matches the checked-out source.
	if M.binary_exists(binary_path) and not M.binary_is_stale(binary_path, plugin_dir) then
		return true
	end

	if M.binary_exists(binary_path) then
		vim.notify("cursor-tab: Server binary is stale, rebuilding...", vim.log.levels.INFO)
		local build_done = false
		local build_success = false
		M.build_binary(plugin_dir, function(result)
			build_success = result
			build_done = true
		end)
		local build_timeout = 300000 -- 5 minutes
		local build_start = vim.loop.now()
		while not build_done and (vim.loop.now() - build_start) < build_timeout do
			vim.wait(100)
		end
		if build_success then
			return true
		end
	end

	-- Binary missing or not executable, try to download
	vim.notify("cursor-tab: Binary not found, downloading...", vim.log.levels.INFO)

	-- Download/build synchronously on first setup (blocking is acceptable here)
	local done = false
	local success = false
	M.download_binary(plugin_dir, function(result)
		if result then
			success = true
			done = true
			return
		end

		vim.notify("cursor-tab: Download failed, trying local build...", vim.log.levels.WARN)
		M.build_binary(plugin_dir, function(build_result)
			success = build_result
			done = true
		end)
	end)

	-- Wait for download/build to complete (with timeout)
	local timeout = 300000 -- 5 minutes
	local start = vim.loop.now()
	while not done and (vim.loop.now() - start) < timeout do
		vim.wait(100)
	end

	return success
end

return M
