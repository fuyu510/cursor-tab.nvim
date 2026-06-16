local M = {}

M.ns_id = vim.api.nvim_create_namespace("cursor_tab")
M.current_suggestion = nil
M.current_suggestion_text = nil
M.current_line = nil
M.current_col = nil
M.accepting = false
M.server_url = nil
M.server_port = nil
M.server_ready = false
M.server_path = nil
M.server_job = nil
M.stopping_server = false
M.debounce_timer = nil
M.debounce_time_ms = 600
M.enabled = true
M.pending_job = nil
M.next_suggestion_id = nil
M.last_error = nil
M.current_bufnr = nil
M.current_changedtick = nil
M.current_request = nil
M.request_seq = 0
M.suppress_until = 0
M.suppress_bufnr = nil
M.suppress_changedtick = nil
M.suppress_duration_ms = 1200
M.disabled_filetypes = {
	TelescopePrompt = true,
	prompt = true,
	["neo-tree"] = true,
	NvimTree = true,
	help = true,
	qf = true,
}
M.disabled_buftypes = {
	acwrite = true,
	help = true,
	nofile = true,
	nowrite = true,
	prompt = true,
	quickfix = true,
	terminal = true,
}
M.max_context_lines = 5
M.accept_key = "<Tab>"
M.disable_dotfiles = true

function M.notify_error(message)
	if not message or message == "" or message == M.last_error then
		return
	end
	M.last_error = message
	vim.notify("cursor-tab: " .. message, vim.log.levels.ERROR)
end

function M.setup(opts)
	opts = opts or {}
	M.debounce_time_ms = opts.debounce_time_ms or M.debounce_time_ms
	M.suppress_duration_ms = opts.suppress_duration_ms or M.suppress_duration_ms
	if opts.disabled_filetypes then
		for _, filetype in ipairs(opts.disabled_filetypes) do
			M.disabled_filetypes[filetype] = true
		end
	end

	if opts.disabled_buftypes then
		for _, buftype in ipairs(opts.disabled_buftypes) do
			M.disabled_buftypes[buftype] = true
		end
	end

	M.max_context_lines = opts.max_context_lines or M.max_context_lines
	M.accept_key = opts.accept_key or M.accept_key
	if opts.disable_dotfiles ~= nil then
		M.disable_dotfiles = opts.disable_dotfiles
	end

	if not opts.server_path then
		local installer = require("cursor-tab.installer")
		local source = debug.getinfo(1, "S").source
		local plugin_dir = vim.fn.fnamemodify(source:sub(2), ":h:h")

		-- Try to ensure binary exists (download if needed)
		if not installer.ensure_binary(plugin_dir) then
			vim.notify("cursor-tab: Failed to install server binary. Try running :CursorTabInstall", vim.log.levels.ERROR)
			return
		end

		M.server_path = installer.get_binary_path(plugin_dir)
	else
		M.server_path = opts.server_path
	end

	M.ensure_server()

	-- Cleanup server on Neovim exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			if M.server_job then
				M.stopping_server = true
				vim.fn.jobstop(M.server_job)
				M.server_job = nil
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChangedI" }, {
		callback = function()
			M.show_suggestion()
		end,
	})

	vim.api.nvim_create_autocmd({ "InsertLeave" }, {
		callback = function()
			M.stop_pending_request()
			M.clear_suggestion()
		end,
	})

	vim.keymap.set("i", M.accept_key, function()
		if M.accept_suggestion() then
			return ""
		else
			return "\t"
		end
	end, { noremap = true, silent = true, expr = true })

	vim.api.nvim_create_user_command("CursorTab", function(args)
		if args.args == "toggle" then
			M.enabled = not M.enabled
			if M.enabled then
				vim.notify("CursorTab enabled", vim.log.levels.INFO)
			else
				M.clear_suggestion()
				vim.notify("CursorTab disabled", vim.log.levels.INFO)
			end
		elseif args.args == "enable" then
			M.enabled = true
			vim.notify("CursorTab enabled", vim.log.levels.INFO)
		elseif args.args == "disable" then
			M.enabled = false
			M.clear_suggestion()
			vim.notify("CursorTab disabled", vim.log.levels.INFO)
		else
			vim.notify("Usage: :CursorTab [toggle|enable|disable]", vim.log.levels.ERROR)
		end
	end, {
		nargs = 1,
		complete = function()
			return { "toggle", "enable", "disable" }
		end,
	})

	vim.api.nvim_create_user_command("CursorTabInstall", function()
		local installer = require("cursor-tab.installer")
		local source = debug.getinfo(1, "S").source
		local plugin_dir = vim.fn.fnamemodify(source:sub(2), ":h:h")

		installer.download_binary(plugin_dir, function(success)
			if success then
				vim.notify("cursor-tab: Installation complete. Restart Neovim.", vim.log.levels.INFO)
			else
				vim.notify("cursor-tab: Installation failed", vim.log.levels.ERROR)
			end
		end)
	end, {})
end

function M.stop_pending_request()
	if M.debounce_timer then
		vim.fn.timer_stop(M.debounce_timer)
		M.debounce_timer = nil
	end
	if M.pending_job then
		vim.fn.jobstop(M.pending_job)
		M.pending_job = nil
	end
	M.current_request = nil
end

function M.suppress_requests(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	M.suppress_bufnr = bufnr
	M.suppress_changedtick = vim.b[bufnr].changedtick
	M.suppress_until = vim.loop.now() + M.suppress_duration_ms
end

function M.is_request_suppressed(bufnr)
	if not bufnr or M.suppress_bufnr ~= bufnr then
		return false
	end
	if vim.loop.now() > M.suppress_until then
		return false
	end
	if M.suppress_changedtick and vim.b[bufnr].changedtick > M.suppress_changedtick + 1 then
		return false
	end
	return true
end

function M.is_buffer_supported(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	local buftype = vim.bo[bufnr].buftype
	if buftype ~= "" or M.disabled_buftypes[buftype] then
		return false
	end

	local filetype = vim.bo[bufnr].filetype
	if filetype == "" or M.disabled_filetypes[filetype] then
		return false
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if file_path == "" then
		return false
	end

	if M.disable_dotfiles then
		local filename = vim.fn.fnamemodify(file_path, ":t")
		if filename:sub(1, 1) == "." then
			return false
		end
	end

	return vim.bo[bufnr].modifiable
end

function M.relative_path(path, workspace_path)
	if not path or path == "" then
		return path
	end
	if not workspace_path or workspace_path == "" then
		return path
	end

	local normalized_workspace = vim.fn.fnamemodify(workspace_path, ":p"):gsub("/$", "")
	local normalized_path = vim.fn.fnamemodify(path, ":p")
	local prefix = normalized_workspace .. "/"

	if vim.startswith(normalized_path, prefix) then
		return normalized_path:sub(#prefix + 1)
	end

	return path
end

function M.new_request_context()
	local bufnr = vim.api.nvim_get_current_buf()
	if not M.is_buffer_supported(bufnr) then
		return nil
	end
	if M.is_request_suppressed(bufnr) then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local workspace_path = vim.fn.getcwd()
	local file_path = vim.api.nvim_buf_get_name(bufnr)

	M.request_seq = M.request_seq + 1
	return {
		id = M.request_seq,
		bufnr = bufnr,
		changedtick = vim.b[bufnr].changedtick,
		line = cursor[1] - 1,
		col = cursor[2],
		file_path = file_path,
		relative_file_path = M.relative_path(file_path, workspace_path),
		language_id = vim.bo[bufnr].filetype,
		workspace_path = workspace_path,
	}
end

function M.request_context_valid(ctx)
	if not ctx or not vim.api.nvim_buf_is_valid(ctx.bufnr) then
		return false
	end
	if vim.api.nvim_get_current_buf() ~= ctx.bufnr then
		return false
	end
	if not M.is_buffer_supported(ctx.bufnr) then
		return false
	end
	if vim.b[ctx.bufnr].changedtick ~= ctx.changedtick then
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	return cursor[1] - 1 == ctx.line and cursor[2] == ctx.col
end

function M.normalize_range(range_replace, bufnr, request_line)
	if not range_replace then
		return nil
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local raw_start = tonumber(range_replace.start_line)
	local raw_end = tonumber(range_replace.end_line)
	if not raw_start or not raw_end then
		return nil
	end

	local candidates = {
		{ start_line = raw_start, end_line = raw_end },
		{ start_line = raw_start - 1, end_line = raw_end - 1 },
	}

	local best = nil
	local best_score = math.huge
	for _, candidate in ipairs(candidates) do
		if candidate.start_line >= 0 and candidate.start_line < line_count then
			candidate.end_line = math.max(candidate.start_line, math.min(candidate.end_line, line_count - 1))
			local distance = math.abs(candidate.start_line - request_line)
			local span = math.max(0, candidate.end_line - candidate.start_line)
			local score = distance * 10 + span
			if score < best_score then
				best = candidate
				best_score = score
			end
		end
	end

	if not best then
		return nil
	end

	best.start_column = tonumber(range_replace.start_column) or 0
	best.end_column = tonumber(range_replace.end_column) or -1
	return best
end

function M.clean_suggestion_text(suggestion, range_replace)
	suggestion = (suggestion or ""):gsub("\r", "")
	if range_replace and vim.startswith(suggestion, "\n") then
		return suggestion:sub(2)
	end
	return suggestion
end

function M.trim_existing_context(bufnr, range_replace, suggestion, request_line)
	if not range_replace or suggestion == "" then
		return suggestion, range_replace
	end

	local suggestion_lines = vim.split(suggestion, "\n", { plain = true })
	if #suggestion_lines == 0 then
		return suggestion, range_replace
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local max_context_lines = M.max_context_lines

	local outside_prefix = 0
	local prefix_limit = math.min(max_context_lines, range_replace.start_line, #suggestion_lines)
	for count = prefix_limit, 1, -1 do
		local before_lines = vim.api.nvim_buf_get_lines(bufnr, range_replace.start_line - count, range_replace.start_line, false)
		local matches = #before_lines == count
		for i = 1, count do
			if before_lines[i] ~= suggestion_lines[i] then
				matches = false
				break
			end
		end
		if matches then
			outside_prefix = count
			break
		end
	end

	local outside_suffix = 0
	local suffix_anchors = { range_replace.end_line }
	if request_line and request_line ~= range_replace.end_line then
		table.insert(suffix_anchors, request_line)
	end
	for _, anchor_line in ipairs(suffix_anchors) do
		local suffix_available = math.max(0, line_count - anchor_line - 1)
		local suffix_limit = math.min(max_context_lines, suffix_available, #suggestion_lines - outside_prefix)
		for count = suffix_limit, 1, -1 do
			local after_lines = vim.api.nvim_buf_get_lines(bufnr, anchor_line + 1, anchor_line + 1 + count, false)
			local matches = #after_lines == count
			for i = 1, count do
				local suggestion_index = #suggestion_lines - count + i
				if after_lines[i] ~= suggestion_lines[suggestion_index] then
					matches = false
					break
				end
			end
			if matches then
				outside_suffix = math.max(outside_suffix, count)
				break
			end
		end
	end

	if outside_suffix == 0 then
		for _, anchor_line in ipairs(suffix_anchors) do
			local suffix_available = math.max(0, line_count - anchor_line - 1)
			local suffix_limit = math.min(max_context_lines, suffix_available)
			local after_lines = vim.api.nvim_buf_get_lines(bufnr, anchor_line + 1, anchor_line + 1 + suffix_limit, false)
			local min_match = math.min(2, #after_lines)

			if min_match >= 2 then
				for suggestion_start = outside_prefix + 1, #suggestion_lines - min_match + 1 do
					local max_match = math.min(#after_lines, #suggestion_lines - suggestion_start + 1)
					for count = max_match, min_match, -1 do
						local matches = true
						for i = 1, count do
							if after_lines[i] ~= suggestion_lines[suggestion_start + i - 1] then
								matches = false
								break
							end
						end
						if matches then
							outside_suffix = #suggestion_lines - suggestion_start + 1
							break
						end
					end
					if outside_suffix > 0 then
						break
					end
				end
			end

			if outside_suffix > 0 then
				break
			end
		end
	end

	if outside_prefix > 0 or outside_suffix > 0 then
		local kept_lines = {}
		for i = outside_prefix + 1, #suggestion_lines - outside_suffix do
			table.insert(kept_lines, suggestion_lines[i])
		end
		if #kept_lines == 0 then
			return suggestion, range_replace
		end
		suggestion_lines = kept_lines
	end

	local current_lines = vim.api.nvim_buf_get_lines(bufnr, range_replace.start_line, range_replace.end_line + 1, false)
	if #current_lines == 0 then
		return table.concat(suggestion_lines, "\n"), range_replace
	end

	local prefix = 0
	while prefix < #current_lines and prefix < #suggestion_lines do
		if current_lines[prefix + 1] ~= suggestion_lines[prefix + 1] then
			break
		end
		prefix = prefix + 1
	end

	local suffix = 0
	while suffix < (#current_lines - prefix) and suffix < (#suggestion_lines - prefix) do
		local current_index = #current_lines - suffix
		local suggestion_index = #suggestion_lines - suffix
		if current_lines[current_index] ~= suggestion_lines[suggestion_index] then
			break
		end
		suffix = suffix + 1
	end

	if prefix == 0 and suffix == 0 then
		return table.concat(suggestion_lines, "\n"), range_replace
	end

	local kept_lines = {}
	local last_suggestion_line = #suggestion_lines - suffix
	for i = prefix + 1, last_suggestion_line do
		table.insert(kept_lines, suggestion_lines[i])
	end
	if #kept_lines == 0 then
		return suggestion, range_replace
	end

	local trimmed_range = {
		start_line = range_replace.start_line + prefix,
		end_line = range_replace.end_line - suffix,
		start_column = range_replace.start_column,
		end_column = range_replace.end_column,
	}

	if trimmed_range.end_line < trimmed_range.start_line then
		trimmed_range.end_line = trimmed_range.start_line
	end

	return table.concat(kept_lines, "\n"), trimmed_range
end

function M.replacement_col_for_line(line_text, col, suggestion)
	local replace_col = col
	for candidate = #line_text, col + 1, -1 do
		if vim.startswith(suggestion, line_text:sub(1, candidate)) then
			replace_col = candidate
			break
		end
	end
	if replace_col ~= col then
		return replace_col
	end
	for candidate = math.min(col, #line_text), 1, -1 do
		if vim.startswith(suggestion, line_text:sub(1, candidate)) then
			local trailing = line_text:sub(candidate + 1)
			if trailing:match("^[%s%)%]%}]*$") then
				return #line_text
			end
		end
	end
	return replace_col
end

function M.preview_overlay_col(line_text, col, first_suggestion_line)
	local max_col = math.min(col, #line_text)
	for candidate = max_col, 1, -1 do
		if vim.startswith(first_suggestion_line, line_text:sub(1, candidate)) then
			return candidate
		end
	end
	return 0
end

function M.ensure_server()
	if M.server_job and vim.fn.jobwait({ M.server_job }, 0)[1] == -1 then
		return true
	end

	if not M.server_path then
		return false
	end

	-- Reset state
	M.server_ready = false
	M.server_port = nil
	M.server_url = nil

	M.server_job = vim.fn.jobstart({ M.server_path, "--port", "0" }, {
		on_stdout = function(_, data)
			if data and #data > 0 then
				for _, line in ipairs(data) do
					-- Parse "SERVER_PORT=12345" from stdout
					local port = line:match("SERVER_PORT=(%d+)")
					if port then
						M.server_port = tonumber(port)
						M.server_url = "http://localhost:" .. M.server_port
						M.server_ready = true
					end
				end
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 and not M.stopping_server then
				vim.notify("cursor-tab server exited with code " .. exit_code, vim.log.levels.ERROR)
			end
			M.stopping_server = false
			M.server_job = nil
			M.server_ready = false
			M.server_port = nil
			M.server_url = nil
		end,
		on_stderr = function(_, data)
			if data and #data > 0 and data[1] ~= "" then
				vim.notify("cursor-tab server: " .. table.concat(data, "\n"), vim.log.levels.WARN)
			end
		end,
	})

	if M.server_job == 0 or M.server_job == -1 then
		vim.notify("Failed to start cursor-tab server at " .. M.server_path, vim.log.levels.ERROR)
		M.server_job = nil
		return false
	end

	-- Wait a bit for server to initialize and report its port
	vim.defer_fn(function() end, 100)
	return true
end

function M.get_suggestion(suggestion_id, callback, request_ctx)
	if not M.ensure_server() then
		if callback then
			callback(nil)
		end
		return
	end

	-- Wait for server to be ready (port discovered)
	if not M.server_ready or not M.server_url then
		-- Retry after a short delay
		vim.defer_fn(function()
			M.get_suggestion(suggestion_id, callback, request_ctx)
		end, 50)
		return
	end

	if M.pending_job then
		vim.fn.jobstop(M.pending_job)
		M.pending_job = nil
	end

	if suggestion_id then
		-- GET existing suggestion from store
		M.pending_job = vim.fn.jobstart({
			"curl",
			"-s",
			"-X",
			"GET",
			M.server_url .. "/suggestion/" .. suggestion_id,
		}, {
			on_stdout = function(_, data)
				if not data or #data == 0 then
					return
				end

				local response_text = table.concat(data, "\n")
				if response_text == "" then
					return
				end

				local ok, response = pcall(vim.fn.json_decode, response_text)
				if ok and response and response.suggestion then
					M.last_error = nil
					if callback then
						callback(response.suggestion, response.range_replace, response.next_suggestion_id, response.should_remove_leading_eol)
					end
				else
					if ok and response and response.error then
						M.notify_error(response.error)
					end
					if callback then
						callback(nil, nil, nil, false)
					end
				end

				M.pending_job = nil
			end,
			on_exit = function()
				M.pending_job = nil
			end,
			stdout_buffered = true,
		})
	else
		-- POST new suggestion request to Cursor
		if not request_ctx or not M.request_context_valid(request_ctx) then
			if callback then
				callback(nil, nil, nil, false)
			end
			return
		end

		local req = {
			file_contents = table.concat(vim.api.nvim_buf_get_lines(request_ctx.bufnr, 0, -1, false), "\n"),
			line = request_ctx.line,
			column = request_ctx.col,
			file_path = request_ctx.relative_file_path,
			language_id = request_ctx.language_id,
			workspace_path = request_ctx.workspace_path,
		}

		local json_data = vim.fn.json_encode(req)
		local tmpfile = vim.fn.tempname()
		local f = io.open(tmpfile, "w")
		if not f then
			if callback then
				callback(nil, nil, nil, false)
			end
			return
		end
		f:write(json_data)
		f:close()

		M.pending_job = vim.fn.jobstart({
			"curl",
			"-s",
			"-X",
			"POST",
			"-H",
			"Content-Type: application/json",
			"-d",
			"@" .. tmpfile,
			M.server_url .. "/suggestion/new",
		}, {
			on_stdout = function(_, data)
				if not data or #data == 0 then
					return
				end

				local response_text = table.concat(data, "\n")
				if response_text == "" then
					return
				end

				local ok, response = pcall(vim.fn.json_decode, response_text)
				if ok and response and response.suggestion then
					M.last_error = nil
					if callback then
						callback(response.suggestion, response.range_replace, response.next_suggestion_id, response.should_remove_leading_eol)
					end
				else
					if ok and response and response.error then
						M.notify_error(response.error)
					end
					if callback then
						callback(nil, nil, nil, false)
					end
				end

				M.pending_job = nil
			end,
			on_exit = function()
				M.pending_job = nil
				os.remove(tmpfile)
			end,
			stdout_buffered = true,
		})
	end
end

function M.display_suggestion(ctx, suggestion, range_replace, next_suggestion_id)
	if not suggestion or not M.request_context_valid(ctx) then
		return
	end
	if vim.fn.mode() ~= "i" then
		return
	end

	local bufnr = ctx.bufnr
	local normalized_range = M.normalize_range(range_replace, bufnr, ctx.line)
	local display_text = M.clean_suggestion_text(suggestion, normalized_range)
	display_text, normalized_range = M.trim_existing_context(bufnr, normalized_range, display_text, ctx.line)
	if display_text == "" then
		return
	end

	local sug_lines = vim.split(display_text, "\n", { plain = true })
	if #sug_lines >= 1 then
		local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
		local after_start = ctx.line + 1
		if after_start < buf_line_count then
			local window = math.min(#sug_lines + 10, buf_line_count - after_start)
			local after_lines = vim.api.nvim_buf_get_lines(bufnr, after_start, after_start + window, false)

			for start = 1, #after_lines - #sug_lines + 1 do
				local all_match = true
				for j = 1, #sug_lines do
					if vim.trim(sug_lines[j]) ~= vim.trim(after_lines[start + j - 1]) then
						all_match = false
						break
					end
				end
				if all_match then
					return
				end
			end

			local trailing = 0
			for i = 0, #after_lines - 1 do
				local sug_idx = #sug_lines - i
				local buf_idx = #after_lines - i
				if sug_idx >= 1 and buf_idx >= 1 and vim.trim(sug_lines[sug_idx]) == vim.trim(after_lines[buf_idx]) then
					trailing = trailing + 1
				else
					break
				end
			end
			if trailing > 0 and trailing < #sug_lines then
				local kept = {}
				for i = 1, #sug_lines - trailing do
					table.insert(kept, sug_lines[i])
				end
				display_text = table.concat(kept, "\n")
				normalized_range = nil
			end
		end
	end

	local accept_text = display_text
	if display_text == "" then
		return
	end

	local display_line = ctx.line
	local display_col = ctx.col
	local render_as_block = false

	if normalized_range then
		display_line = normalized_range.start_line
		if normalized_range.start_line ~= ctx.line or normalized_range.end_line ~= ctx.line then
			display_col = 0
			render_as_block = true
		end

		if normalized_range.start_line == ctx.line and normalized_range.end_line == ctx.line then
			local current_line_text = vim.api.nvim_buf_get_lines(bufnr, ctx.line, ctx.line + 1, false)[1] or ""
			local replaced_text = current_line_text:sub(1, ctx.col)
			if vim.startswith(display_text, replaced_text) then
				display_text = display_text:sub(#replaced_text + 1)
			end
		end
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if display_line < 0 or display_line >= line_count then
		return
	end

	local display_line_text = vim.api.nvim_buf_get_lines(bufnr, display_line, display_line + 1, false)[1] or ""
	if display_col > #display_line_text then
		display_col = #display_line_text
	end

	M.clear_suggestion()
	M.current_bufnr = bufnr
	M.current_changedtick = vim.b[bufnr].changedtick
	M.current_suggestion_text = accept_text
	M.current_range_replace = normalized_range
	M.next_suggestion_id = next_suggestion_id

	local lines = vim.split(display_text, "\n", { plain = true })
	local virt_lines = {}

	if render_as_block then
		local first_line = lines[1] or ""
		local current_line_text = vim.api.nvim_buf_get_lines(bufnr, ctx.line, ctx.line + 1, false)[1] or ""
		local overlay_col = M.preview_overlay_col(current_line_text, ctx.col, first_line)
		local overlay_text = first_line:sub(overlay_col + 1)

		M.current_suggestion = vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, ctx.line, overlay_col, {
			virt_text = { { overlay_text, "Comment" } },
			virt_text_pos = "overlay",
			hl_mode = "combine",
		})

		for i = 2, #lines do
			local text = lines[i]
			table.insert(virt_lines, { { text, "Comment" } })
		end

		if #virt_lines > 0 then
			vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, ctx.line, 0, {
				virt_lines = virt_lines,
				virt_lines_above = false,
			})
		end
	else
		for i, text in ipairs(lines) do
			if i == 1 then
				M.current_suggestion = vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, display_line, display_col, {
					virt_text = { { text, "Comment" } },
					virt_text_pos = "inline",
					hl_mode = "combine",
				})
			else
				table.insert(virt_lines, { { text, "Comment" } })
			end
		end

		if #virt_lines > 0 then
			local mark = vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, display_line, display_col, {
				virt_lines = virt_lines,
				virt_lines_above = false,
			})
			M.current_suggestion = M.current_suggestion or mark
		end
	end

	M.current_line = display_line
	M.current_col = display_col
end

function M.show_suggestion(suggestion_id)
	-- Allow showing chained suggestions even while accepting
	if not M.enabled or (M.accepting and not suggestion_id) then
		return
	end

	if M.debounce_timer then
		vim.fn.timer_stop(M.debounce_timer)
		M.debounce_timer = nil
	end

	M.clear_suggestion()

	-- If suggestion_id provided, get next suggestion immediately without debouncing
	if suggestion_id then
		local request_ctx = M.new_request_context()
		if not request_ctx then
			M.accepting = false
			return
		end
		M.current_request = request_ctx
		M.get_suggestion(suggestion_id, function(suggestion, range_replace, next_suggestion_id, should_remove_leading_eol)
			if not suggestion then
				return
			end

			M.display_suggestion(request_ctx, suggestion, range_replace, next_suggestion_id)
			-- Done showing next suggestion, allow new suggestions
			M.accepting = false
		end, request_ctx)
		return
	end

	-- Otherwise, debounce and get new suggestion
	M.debounce_timer = vim.fn.timer_start(M.debounce_time_ms, function()
		M.debounce_timer = nil

		if vim.fn.mode() ~= "i" then
			return
		end

		local request_ctx = M.new_request_context()
		if not request_ctx then
			return
		end
		M.current_request = request_ctx

		M.get_suggestion(nil, function(suggestion, range_replace, next_suggestion_id, should_remove_leading_eol)
			if not suggestion then
				return
			end

			if M.current_request and M.current_request.id ~= request_ctx.id then
				return
			end
			M.display_suggestion(request_ctx, suggestion, range_replace, next_suggestion_id)
		end, request_ctx)
	end)
end

function M.clear_suggestion()
	if M.current_bufnr and vim.api.nvim_buf_is_valid(M.current_bufnr) then
		vim.api.nvim_buf_clear_namespace(M.current_bufnr, M.ns_id, 0, -1)
	elseif vim.api.nvim_get_current_buf() then
		vim.api.nvim_buf_clear_namespace(0, M.ns_id, 0, -1)
	end

	M.current_suggestion = nil
	M.current_suggestion_text = nil
	M.current_range_replace = nil
	M.current_line = nil
	M.current_col = nil
	M.current_bufnr = nil
	M.current_changedtick = nil
	M.next_suggestion_id = nil
end

function M.accept_suggestion()
	if not M.current_suggestion or M.accepting or not M.current_suggestion_text then
		return false
	end
	if vim.fn.mode() ~= "i" then
		return false
	end

	local bufnr = vim.api.nvim_get_current_buf()
	if not M.current_bufnr or bufnr ~= M.current_bufnr or not M.is_buffer_supported(bufnr) then
		M.clear_suggestion()
		return false
	end

	if M.current_changedtick and vim.b[bufnr].changedtick ~= M.current_changedtick then
		M.clear_suggestion()
		return false
	end

	local line = vim.api.nvim_win_get_cursor(0)[1] - 1
	local col = vim.api.nvim_win_get_cursor(0)[2]
	local suggestion = M.current_suggestion_text
	local range_replace = M.current_range_replace
	local next_suggestion_id = M.next_suggestion_id
	local accepted_changedtick = M.current_changedtick

	M.accepting = true
	M.stop_pending_request()
	M.suppress_requests(bufnr)
	M.clear_suggestion()

	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
			M.accepting = false
			return
		end
		if accepted_changedtick and vim.b[bufnr].changedtick ~= accepted_changedtick then
			M.accepting = false
			return
		end

		-- Temporarily disable TextChangedI event during text insertion
		local eventignore_save = vim.o.eventignore
		vim.o.eventignore = "TextChangedI"

		local lines = vim.split(suggestion, "\n", { plain = true })

		if range_replace then
			local start_line = range_replace.start_line
			local end_line = range_replace.end_line
			local line_count = vim.api.nvim_buf_line_count(bufnr)
			local range_out_of_bounds = start_line < 0 or start_line >= line_count

			if true then
				local clean_suggestion = suggestion
				if vim.startswith(clean_suggestion, "\n") then
					clean_suggestion = string.sub(clean_suggestion, 2)
				end

				local clean_lines = vim.split(clean_suggestion, "\n", { plain = true })
				local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
				local replace_col = M.replacement_col_for_line(line_text, col, clean_suggestion)
				local after = line_text:sub(replace_col + 1)

				if #clean_lines == 1 then
					vim.api.nvim_buf_set_text(bufnr, line, 0, line, replace_col, { clean_suggestion })
					vim.api.nvim_win_set_cursor(0, { line + 1, #clean_suggestion })
				else
					clean_lines[#clean_lines] = clean_lines[#clean_lines] .. after
					vim.api.nvim_buf_set_lines(bufnr, line, line + 1, false, clean_lines)
					vim.api.nvim_win_set_cursor(0, { line + #clean_lines, #clean_lines[#clean_lines] - #after })
				end
			else
				end_line = math.min(end_line, line_count - 1)
				local range_size = end_line - start_line + 1
				if #lines < range_size then
					end_line = start_line + #lines - 1
				end
				vim.api.nvim_buf_set_lines(bufnr, start_line, end_line + 1, false, lines)
				vim.api.nvim_win_set_cursor(0, { start_line + #lines, #lines[#lines] })
			end
		else
			local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
			if #lines == 1 then
				vim.api.nvim_buf_set_text(bufnr, line, col, line, col, { suggestion })
				vim.api.nvim_win_set_cursor(0, { line + 1, col + #suggestion })
			else
				local before = line_text:sub(1, col)
				local after = line_text:sub(col + 1)

				lines[1] = before .. lines[1]
				lines[#lines] = lines[#lines] .. after

				vim.api.nvim_buf_set_lines(bufnr, line, line + 1, false, lines)
				vim.api.nvim_win_set_cursor(0, { line + #lines, #lines[#lines] - #after })
			end
		end
		M.suppress_requests(bufnr)

		-- Restore eventignore
		vim.o.eventignore = eventignore_save

		M.accepting = false
	end)

	return true
end

return M
