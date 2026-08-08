--- `:checkhealth tongue`
---
--- This exists because every failure mode of this plugin is silent by nature.
--- It does nothing visible when it works, and it does nothing visible when the
--- backend is missing, renamed, or is a different program that happens to share
--- the name. Health is the only place that says which of those is happening.

local H = {}

local function run(argv, timeout)
	local ok, res = pcall(function()
		return vim.system(argv, { text = true }):wait(timeout or 3000)
	end)
	if not ok then
		return nil, tostring(res)
	end
	return res
end

function H.check()
	local health = vim.health
	health.start("tongue.nvim")

	if vim.fn.has("nvim-0.10") == 0 then
		health.error("Neovim 0.10+ required (vim.system)")
		return
	end
	health.ok("Neovim " .. tostring(vim.version()))

	local tongue = require("tongue")
	local st = tongue.status()

	if st.reason == "not set up" then
		health.error("setup() has not been called", {
			'add `require("tongue").setup()` to your config',
		})
		return
	end

	if not st.enabled then
		-- Not an error. Inert is the correct outcome on a machine with no input
		-- method tool, and over SSH.
		health.info("inactive: " .. tostring(st.reason))
		return
	end

	health.ok(("active via %s"):format(st.reason))

	local cfg = st.backend
	local exe = cfg.get[1]
	local path = vim.fn.exepath(exe)
	if path == "" then
		health.error(("`%s` is not on $PATH, but detection said it was"):format(exe))
		return
	end
	health.info(("%s -> %s"):format(exe, path))

	-- One real read. This is what catches a backend that is the wrong program:
	-- name collisions happen (there is an unrelated `tongue` crate on crates.io,
	-- a shell), and `executable()` cannot tell them apart.
	local out, err = run(cfg.get)
	if not out then
		health.error(("could not run `%s`: %s"):format(table.concat(cfg.get, " "), err))
		return
	end

	if out.code ~= 0 then
		health.error(
			("`%s` exited %d"):format(table.concat(cfg.get, " "), out.code),
			{ (out.stderr or ""):gsub("%s+$", "") }
		)
		return
	end

	-- Exit 0 with a noisy stderr is worth saying out loud even though the plugin
	-- itself tolerates it: any reader that merges the streams -- which is most of
	-- them, including `vim.fn.system` -- would corrupt the token silently.
	local stderr = (out.stderr or ""):gsub("%s+$", "")
	if stderr ~= "" then
		health.warn(("`%s` writes to stderr even on success"):format(exe), { stderr })
	end

	local raw = (out.stdout or ""):gsub("%s+$", "")
	local token = raw:gsub("^%s+", "")
	if token == "" then
		health.error(("`%s` printed nothing"):format(exe))
	elseif token:find("%s") then
		health.error(
			("`%s` printed more than one token: %q"):format(exe, raw),
			{ "is this the program you think it is? check the path above" }
		)
	elseif cfg.tokens and not vim.tbl_contains(cfg.tokens, token) then
		health.error(
			("`%s` printed %q, which is not in the backend's declared set (%s)"):format(
				exe,
				token,
				table.concat(cfg.tokens, ", ")
			),
			{ "is this the program you think it is? check the path above" }
		)
	else
		health.ok(("reads back %q"):format(token))
	end

	health.info(("remembered Insert-mode layout: %s"):format(tostring(st.last_layout)))
	health.info(("command timeout: %d ms"):format(st.timeout))
end

return H
