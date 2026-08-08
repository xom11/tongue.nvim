--- `:Tongue`, and everything it prints.
---
--- Its own module rather than a closure inside `plugin/tongue.lua` for two
--- reasons. `plugin/` is sourced on every Neovim start for every user, so it has
--- to stay a stub. And the report below is worth testing -- `:Tongue status` is
--- the first thing anyone runs when the plugin appears to do nothing, and a
--- report that throws at that moment is worse than no report.

local M = {}

--- Verb order is the order they are offered in completion, which is roughly the
--- order they are wanted: the thing you run to find out, then the things you run
--- to change something.
M.subcommands = { "status", "toggle", "enable", "disable", "sync" }

---@param lead string
---@return string[]
function M.complete(lead)
	return vim.tbl_filter(function(name)
		return name:sub(1, #lead) == lead
	end, M.subcommands)
end

--- The `:Tongue status` report, as a list of lines.
---
--- Returned rather than printed so a test can read it. It deliberately overlaps
--- `:checkhealth tongue` without replacing it: this one is instant and says what
--- the plugin is *doing*; health spawns the backend and says whether it *works*.
---@return string[]
function M.report()
	local st = require("tongue").status()
	local out = {}

	if not st.enabled then
		out[#out + 1] = "tongue.nvim -- inactive: " .. tostring(st.reason)
		if st.reason == "not set up" then
			out[#out + 1] = '  add `require("tongue").setup()` to your config'
		end
		return out
	end

	out[#out + 1] = ("tongue.nvim -- %s via %s"):format(st.attached and "active" or "DISABLED", st.reason)

	local b = st.backend
	out[#out + 1] = ("  backend      %s   english: %s"):format(table.concat(b.get, " "), b.english)
	out[#out + 1] = ("  mode         %s"):format(st.inserting and "typing" or "normal")
	-- The intent, not a reading. Saying what it *should* be is the honest answer:
	-- the plugin never reads the machine to answer a question nobody asked.
	out[#out + 1] = ("  wants        %s"):format(tostring(require("tongue").token()))
	out[#out + 1] = ("  remembers    %s   (restored on the next Insert)"):format(tostring(st.last_layout))
	out[#out + 1] = ("  believes     %s"):format(tostring(st.applied))
	out[#out + 1] = ("  timeout      %d ms   verify: %s"):format(st.timeout, tostring(st.verify))

	if b.note then
		out[#out + 1] = "  note         " .. b.note
	end
	return out
end

---@param arg string?
function M.run(arg)
	local tongue = require("tongue")
	local name = (arg == nil or arg == "") and "status" or arg

	if name == "status" then
		vim.notify(table.concat(M.report(), "\n"), vim.log.levels.INFO)
	elseif name == "enable" then
		if tongue.enable() then
			vim.notify("tongue.nvim: enabled", vim.log.levels.INFO)
		else
			vim.notify("tongue.nvim: no backend to enable -- see :checkhealth tongue", vim.log.levels.WARN)
		end
	elseif name == "disable" then
		tongue.disable()
		vim.notify("tongue.nvim: disabled (the input method is left where it is)", vim.log.levels.INFO)
	elseif name == "toggle" then
		vim.notify("tongue.nvim: " .. (tongue.toggle() and "enabled" or "disabled"), vim.log.levels.INFO)
	elseif name == "sync" then
		tongue.sync()
	else
		vim.notify(
			("tongue.nvim: unknown subcommand %q (try: %s)"):format(name, table.concat(M.subcommands, ", ")),
			vim.log.levels.ERROR
		)
	end
end

return M
