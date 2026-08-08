--- `:checkhealth tongue`
---
--- This exists because every failure mode of this plugin is silent by nature.
--- It does nothing visible when it works, and it does nothing visible when the
--- backend is missing, renamed, or is a different program that happens to share
--- the name. Health is the only place that says which of those is happening.

local H = {}

--- Run a backend command synchronously, within `timeout`.
---
--- `:wait(t)` alone is not a deadline. It waits, SIGKILLs the direct child, then
--- waits the full budget again -- and a backend that forks leaves a grandchild
--- holding the stdout pipe, so what you actually wait for is the grandchild.
--- Measured against this repo's own fixture with a 5 s forked sleep: `:wait(3000)`
--- returned after 5011 ms, i.e. the editor froze for five seconds inside the
--- diagnostic. Passing `timeout` to `vim.system` as well is what kills the tree.
local function run(argv, timeout)
	local ok, res = pcall(function()
		return vim.system(argv, { text = true, timeout = timeout }):wait(timeout)
	end)
	if not ok then
		return nil, tostring(res)
	end
	if not res then
		-- `:wait` gives back nil rather than a result when it gives up. Formatting
		-- that as the error produced the unactionable `could not run `tongue`: nil`.
		return nil, ("no answer within %d ms"):format(timeout)
	end
	return res
end

function H.check()
	-- Resolved here rather than at module scope, and both halves matter.
	--
	-- `vim.health.start` is the 0.10 rename of `report_start`, so on exactly the
	-- Neovim versions the guard below exists to serve, calling it first raises
	-- `attempt to call field 'start' (a nil value)` -- a stack trace from the very
	-- tool the user ran to find out what was wrong.
	--
	-- Reading `vim.health` per call is also what lets the suite substitute a
	-- strict collector for it; captured at load time, the real one would be
	-- frozen in and `:checkhealth` would go untested again.
	local health = vim.health
	local h_start = health.start or health.report_start
	local h_ok = health.ok or health.report_ok
	local h_info = health.info or health.report_info
	local h_warn = health.warn or health.report_warn
	local h_error = health.error or health.report_error

	-- Before the first `vim.health` call, not after it.
	if vim.fn.has("nvim-0.10") == 0 then
		h_start("tongue.nvim")
		h_error("Neovim 0.10+ required (vim.system)")
		return
	end

	h_start("tongue.nvim")
	h_ok("Neovim " .. tostring(vim.version()))

	local ok_req, tongue = pcall(require, "tongue")
	if not ok_req then
		h_error("could not load the plugin: " .. tostring(tongue))
		return
	end
	local st = tongue.status()

	if st.reason == "not set up" then
		h_error("setup() has not been called", {
			'add `require("tongue").setup()` to your config',
		})
		return
	end

	if not st.enabled then
		if st.misconfigured then
			-- The distinction `resolve` computes and `setup` records. Printing a
			-- typo'd config as benign `info`, styled identically to an SSH session,
			-- is how a config bug survives for months: the startup error scrolled
			-- away, and the tool you run to find out says everything is normal.
			h_error("misconfigured: " .. tostring(st.reason), {
				"fix the `backend`, `english` or `timeout` value passed to setup()",
			})
		else
			-- Not an error. Inert is the correct outcome on a machine with no input
			-- method tool, and over SSH.
			h_info("inactive: " .. tostring(st.reason))
		end
		return
	end

	if st.attached then
		h_ok(("active via %s"):format(st.reason))
	else
		h_warn(("resolved %s, but currently disabled"):format(st.reason), { "`:Tongue enable` turns it back on" })
	end

	local cfg = st.backend

	-- A backend can be working perfectly and still be the wrong lever. This is
	-- the only place that can say so: the plugin looks identical from the outside
	-- whether it is enforcing English or merely re-selecting an input source that
	-- was never the thing making you type Vietnamese.
	if cfg.note then
		h_warn(cfg.note)
	end

	local exe = cfg.get[1]
	local path = vim.fn.exepath(exe)
	if path == "" then
		h_error(("`%s` is not on $PATH, but detection said it was"):format(exe))
		return
	end
	h_info(("%s -> %s"):format(exe, path))

	-- `get` and `set` are separate argv by contract, and a hand-written backend is
	-- free to use two different programs. Only one of them was ever checked.
	local setexe = cfg.set[1]
	if setexe ~= exe then
		local setpath = vim.fn.exepath(setexe)
		if setpath == "" then
			h_error(("`%s` (the `set` command) is not on $PATH"):format(setexe))
		else
			h_info(("%s -> %s"):format(setexe, setpath))
		end
	end

	-- One real read. This is what catches a backend that is the wrong program:
	-- name collisions happen (there is an unrelated `tongue` crate on crates.io,
	-- a shell), and `executable()` cannot tell them apart.
	local out, err = run(cfg.get, st.timeout)
	if not out then
		h_error(("could not run `%s`: %s"):format(table.concat(cfg.get, " "), err), {
			("raise the budget with setup({ timeout = ... }); it is %d ms"):format(st.timeout),
		})
		return
	end

	if out.code ~= 0 then
		-- `gsub` returns TWO values, so writing it inline in a table constructor
		-- builds `{ "boom", 1 }` -- and vim.health rejects the number, throwing
		-- out of the very check that exists to diagnose this case.
		local errtail = (out.stderr or ""):gsub("%s+$", "")
		h_error(("`%s` exited %d"):format(table.concat(cfg.get, " "), out.code), errtail ~= "" and { errtail } or nil)
		return
	end

	-- Exit 0 with a noisy stderr is worth saying out loud even though the plugin
	-- itself tolerates it: any reader that merges the streams -- which is most of
	-- them, including `vim.fn.system` -- would corrupt the token silently.
	local stderr = (out.stderr or ""):gsub("%s+$", "")
	if stderr ~= "" then
		h_warn(("`%s` writes to stderr even on success"):format(exe), { stderr })
	end

	local raw = (out.stdout or ""):gsub("%s+$", "")
	local token = raw:gsub("^%s+", "")
	if token == "" then
		h_error(("`%s` printed nothing"):format(exe))
	elseif cfg.unknown and token == cfg.unknown then
		-- Must come before the checks below: `unknown` is a legitimate answer --
		-- the backend saying it does not recognise the live state -- and it is
		-- deliberately NOT listed in `tokens`. Reporting it as an error accuses the
		-- user of installing the wrong binary while the plugin is working perfectly.
		h_info(("reads back %q -- the backend does not recognise the live state; English is forced"):format(token))
	elseif token:find("%s") then
		h_error(
			("`%s` printed more than one token: %q"):format(exe, raw),
			{ "is this the program you think it is? check the path above" }
		)
	elseif cfg.tokens and not vim.tbl_contains(cfg.tokens, token) then
		h_error(
			("`%s` printed %q, which is not in the backend's declared set (%s)"):format(
				exe,
				token,
				table.concat(cfg.tokens, ", ")
			),
			{ "is this the program you think it is? check the path above" }
		)
	else
		h_ok(("reads back %q"):format(token))
	end

	h_info(("remembered Insert-mode layout: %s"):format(tostring(st.last_layout)))
	h_info(("command timeout: %d ms   verify: %s"):format(st.timeout, tostring(st.verify)))
end

return H
