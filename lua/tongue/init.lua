--- tongue.nvim
--- Force English in Normal mode, restore your input method in Insert mode.
---
--- Why this exists when six other plugins already switch input methods: they all
--- switch macOS *input sources*. An external Vietnamese IME (GoTiengViet, EVKey,
--- OpenKey, GoNhanh) is a process sitting on top of `com.apple.keylayout.ABC`, so
--- "Vietnamese" and "English" are the SAME input source and the difference is
--- invisible to every one of them. `tongue` moves both levers, so this plugin
--- drives `tongue` rather than the OS.
---
--- Two properties are load-bearing and easy to break:
---
---   1. Nothing here blocks the UI. A backend read costs ~40-50 ms, and the
---      obvious implementation pays that on every single exit from Insert mode.
---   2. Mode tracking goes through `ModeChanged`, not `InsertLeave`. `i_CTRL-C`
---      leaves Insert *without firing InsertLeave* (`:help i_CTRL-C`), which
---      strands you in Normal mode with the IME still on -- indefinitely.

local api = vim.api

local M = {}

--- `vim.system` is the floor: it is the only reader that separates stdout from
--- stderr, and the only one with a timeout. Both matter -- see `sanitize` and
--- `run` below. A `jobstart` fallback would reintroduce the bug this fixes.
local MIN_NVIM = "nvim-0.10"

local uv = vim.uv or vim.loop

-- ── configuration ───────────────────────────────────────────────────────────

local cfg = nil -- resolved backend, or nil => plugin inert
local reason = "not set up"
local timeout_ms = 2000
local notify = true

-- ── state ───────────────────────────────────────────────────────────────────
--
-- last_layout : the token the user was last *observed* typing in
-- inserting   : are we in a mode where keys produce text
-- busy        : a get(+set) cycle is in flight  (single-flight)
-- observe     : the next successful read records the user's own choice
-- applied     : the token of OUR most recent successful `set`, else nil
--
-- `applied` looks redundant and is not. It is what lets `observe` tell "the user
-- chose English" apart from "our own restore just landed". Drop it and the
-- plugin silently forgets your Vietnamese the first time you leave Insert mode
-- quickly.

-- epoch   : bumped on every crossing of the typing boundary; a reading taken
--           under an older epoch describes a mode we have already left
-- recheck  : a boundary was crossed while a command was in flight
local last_layout, inserting, busy, observe, applied
local epoch, recheck = 0, false
local augroup = nil

local warned = {}

local function warn(key, msg)
	if not notify then
		return
	end
	local now = uv.hrtime()
	-- 30 s per distinct message. A broken backend fires on every mode change;
	-- an unthrottled notify would bury the editor, and burying it is how a user
	-- ends up disabling the warning instead of fixing the cause.
	if warned[key] and (now - warned[key]) < 30e9 then
		return
	end
	warned[key] = now
	vim.schedule(function()
		vim.notify("tongue.nvim: " .. msg, vim.log.levels.WARN)
	end)
end

local function tail(stderr)
	if type(stderr) ~= "string" then
		return ""
	end
	local s = stderr:gsub("%s+$", "")
	if s == "" then
		return ""
	end
	if #s > 200 then
		s = s:sub(1, 200) .. "..."
	end
	return " -- stderr: " .. s
end

-- ── reading the machine ─────────────────────────────────────────────────────

local SPAWN_FAILED = -1

local function why(code)
	if code == 124 then
		return "timed out"
	elseif code == SPAWN_FAILED then
		return "could not be started"
	end
	return "exited " .. code
end

--- Run argv, hand the result to `cb` on the main loop. Exactly once.
---
--- `vim.system` fails in two ways that a plain callback never sees, and either
--- one leaves `busy` latched for the rest of the session -- the plugin dead,
--- silently, which is precisely the failure it exists to prevent:
---
---   * A failed spawn (ENOENT on a typo'd command, EACCES on a non-executable)
---     is raised with `error()` on THIS stack, not delivered to the callback.
---     Uncaught, it escapes through the ModeChanged autocmd with `busy` already
---     true. Hence `pcall`.
---
---   * `timeout` kills the direct child, but the callback only runs once the
---     stdout pipe closes. A backend that forks -- every shell wrapper does --
---     leaves a grandchild holding that pipe, so the callback arrives at the
---     grandchild's pace instead. Measured: a wrapper forking `sleep 5` with
---     timeout=200 called back after 5016 ms; the same script with `exec sleep 5`
---     after 202 ms. The timer below is the real deadline. `timeout` stays
---     because for a well-behaved backend it is what actually kills the process.
local function run(argv, cb)
	local done = false
	local timer = assert(uv.new_timer())

	local function settle(out)
		-- Not defensive padding: an orphaned grandchild does eventually exit and
		-- fire the real callback, which would deliver `cb` a second time for one
		-- command.
		if done then
			return
		end
		done = true
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
		vim.schedule(function()
			cb(out)
		end)
	end

	timer:start(timeout_ms, 0, function()
		settle({ code = 124, signal = 15, stdout = "", stderr = "" })
	end)

	local ok, err = pcall(vim.system, argv, { text = true, timeout = timeout_ms }, settle)
	if not ok then
		settle({ code = SPAWN_FAILED, signal = 0, stdout = "", stderr = tostring(err) })
	end
end

local function get_async(cb)
	run(cfg.get, function(out)
		if out.code ~= 0 then
			warn("get-failed", ("`%s` %s%s"):format(table.concat(cfg.get, " "), why(out.code), tail(out.stderr)))
			return cb(nil)
		end
		local token, err = require("tongue.backend").sanitize(cfg, out.stdout)
		if not token then
			warn(
				"get-garbage",
				("unusable output from `%s` (%s)%s"):format(table.concat(cfg.get, " "), err, tail(out.stderr))
			)
		end
		cb(token)
	end)
end

local function set_async(token, cb)
	local argv = vim.list_extend(vim.deepcopy(cfg.set), { token })
	run(argv, function(out)
		if out.code ~= 0 then
			warn("set-failed", ("`%s` %s%s"):format(table.concat(argv, " "), why(out.code), tail(out.stderr)))
		end
		cb(out.code)
	end)
end

-- ── the state machine ───────────────────────────────────────────────────────

local cycle, finish

local typing = require("tongue.mode").typing

--- The intent, DERIVED rather than captured.
---
--- Snapshotting the desired token into a variable and reading it back in a
--- callback just moves the staleness one level down: by the time a 50 ms read
--- returns, the mode may have changed twice.
local function want()
	return inserting and last_layout or cfg.english
end

finish = function(applied_for)
	busy = false
	-- Re-derive. If the intent moved while we were working, go again; if it did
	-- not, stop -- including when the command failed, so a broken backend cannot
	-- spin. `recheck` covers the case where the intent ended up back where it
	-- started but a boundary was crossed in between, so the reading we acted on
	-- described a mode we had already left.
	if recheck or want() ~= applied_for then
		cycle()
	end
end

cycle = function()
	if not cfg or busy then
		return
	end
	busy = true
	recheck = false
	local my = epoch

	get_async(function(current)
		-- A reading is only evidence about the mode that was current when it was
		-- taken. A real backend answers from the OS the instant it starts, so a
		-- 50 ms read that spans a mode change describes the mode we have left.
		if epoch ~= my then
			-- Do not act on it, and above all do not force English yet: that
			-- would overwrite the very state `observe` is still waiting to read.
			-- One more lap costs a read; getting this wrong costs the layout.
			recheck = true
			return finish(want())
		end

		if observe and current ~= nil then
			-- Cleared only on a reading we can trust. A failed read is not
			-- evidence -- burning the flag on it means the layout is never
			-- learned at all.
			observe = false
			if current ~= cfg.english then
				-- Unambiguous: we never set anything but English on the way out,
				-- so a non-English reading is the user's own doing.
				last_layout = current
			elseif applied == last_layout then
				-- English, and our own restore of `last_layout` had already
				-- landed -- so this English is a choice the user made, not our
				-- echo. Without this guard the plugin cannot tell the two apart
				-- and quietly forgets the layout you were typing in.
				last_layout = cfg.english
			end
		end

		local w = want()

		if current == nil then
			-- Never restore blind: guessing wrong here drops you into Normal mode
			-- with an IME on. Forcing English blind is always safe, so that one
			-- still goes through.
			if w ~= cfg.english then
				return finish(w)
			end
		elseif current == w then
			applied = current
			return finish(w)
		end

		set_async(w, function(code)
			applied = (code == 0) and w or nil
			finish(w)
		end)
	end)
end

-- ── wiring ──────────────────────────────────────────────────────────────────

--- Handle one mode transition.
---
--- Split out from the autocmd so tests can drive it directly. That is not a
--- convenience: under `nvim -l` the main loop never runs, so nothing can hold
--- Insert mode, and under `nvim -c` a blocking Lua script starves the very loop
--- that would consume `nvim_input`. Real keys are covered separately by
--- `tests/wiring_spec.lua`, which drives an actual editor over `--remote-send`.
local function on_mode(old_mode, new_mode)
	local was = typing(old_mode)
	local now = typing(new_mode)
	if was == now then
		return -- sub-mode churn; nothing crossed the boundary
	end
	inserting = now
	-- Every crossing invalidates any reading already in flight: it was taken
	-- before this boundary, so it describes a mode we have already left.
	epoch = epoch + 1
	if busy then
		recheck = true
	end
	if not now then
		-- Always ask to observe on the way out. Whether a given reading is
		-- trustworthy enough to observe *with* is decided in `cycle`, by epoch --
		-- dropping the request here instead (the obvious guard, `and not busy`)
		-- silently forgets a switch you made mid-Insert whenever you leave
		-- quickly, which is the thing this plugin promises to remember.
		observe = true
	end
	cycle()
end

local function attach()
	augroup = api.nvim_create_augroup("tongue.nvim", { clear = true })

	-- ONE handler, on ModeChanged, replacing InsertEnter/InsertLeave/TermEnter/
	-- TermLeave. Three reasons, all measured:
	--
	--   * `i_CTRL-C` fires no InsertLeave at all (`:help i_CTRL-C`), so the
	--     event-pair version leaves the IME on in Normal mode indefinitely.
	--   * completion churns modes (`i:ix`, `ix:i`, `i:ic`, `ic:i`) without ever
	--     leaving Insert. Reacting to those re-selects the input source mid
	--     composition, which is exactly the CJK sub-mode flicker.
	--   * `v:event.old_mode` says what we are leaving. `vim.fn.mode()` cannot:
	--     during `i:ic` it just answers "ic".
	api.nvim_create_autocmd("ModeChanged", {
		group = augroup,
		pattern = "*:*",
		callback = function()
			on_mode(vim.v.event.old_mode, vim.v.event.new_mode)
		end,
	})

	-- Regaining focus means something else may have moved the input method while
	-- we were away. Never while typing: the IME candidate window generates
	-- spurious FocusGained through tmux focus-events, and re-selecting the source
	-- mid-composition is the flicker again.
	api.nvim_create_autocmd("FocusGained", {
		group = augroup,
		callback = function()
			if not typing(vim.fn.mode(1)) then
				inserting = false
				-- Something outside Neovim may have moved the input method, so a
				-- reading already in flight cannot be trusted here either.
				epoch = epoch + 1
				if busy then
					recheck = true
				end
				cycle()
			end
		end,
	})
end

--- Set up the plugin. Required -- nothing happens on `require` alone.
---@param opts table?
function M.setup(opts)
	opts = opts or {}

	if vim.fn.has(MIN_NVIM) == 0 then
		vim.schedule(function()
			vim.notify(
				("tongue.nvim requires Neovim 0.10+ (vim.system); this is %s"):format(vim.version()),
				vim.log.levels.ERROR
			)
		end)
		return
	end

	if augroup then
		api.nvim_del_augroup_by_id(augroup)
		augroup = nil
	end
	warned = {}

	notify = opts.notify ~= false
	timeout_ms = tonumber(opts.timeout) or 2000

	local backend, why = require("tongue.backend").resolve(opts)
	cfg, reason = backend, why

	if not cfg then
		-- Inert is a legitimate outcome (SSH, a machine with no IME tool), so it
		-- is not a warning. A *malformed* backend is, though -- that is a config
		-- bug and silence would hide it.
		if opts.backend ~= nil then
			vim.schedule(function()
				vim.notify("tongue.nvim: " .. why, vim.log.levels.ERROR)
			end)
		end
		return
	end

	last_layout = cfg.english
	inserting = false
	busy = false
	applied = nil
	epoch = 0
	recheck = false

	attach()

	-- Reconcile once at startup, asynchronously. The editor may well be opening
	-- while the IME is on, and no mode change or focus event is guaranteed to
	-- follow. `observe` is set so that this first read also records what you were
	-- using -- so the first `i` restores it instead of stranding you in English.
	observe = true
	vim.schedule(cycle)
end

--- Internal, for tests only. See `on_mode`.
---@private
function M._on_mode(old_mode, new_mode)
	on_mode(old_mode, new_mode)
end

--- Current state. For `:checkhealth tongue` and for tests.
---@return table
function M.status()
	return {
		enabled = cfg ~= nil,
		reason = reason,
		backend = cfg,
		last_layout = last_layout,
		inserting = inserting,
		busy = busy,
		observe = observe,
		applied = applied,
		timeout = timeout_ms,
	}
end

return M
