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

local last_layout, inserting, busy, observe, applied
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

--- Run argv, hand the result to `cb` on the main loop.
---
--- `timeout` is not optional insurance: without it a backend that hangs leaves
--- `busy` true forever and the plugin dies silently mid-session, which is the
--- exact failure mode it is supposed to prevent.
local function run(argv, cb)
	vim.system(argv, { text = true, timeout = timeout_ms }, function(out)
		vim.schedule(function()
			cb(out)
		end)
	end)
end

local function get_async(cb)
	run(cfg.get, function(out)
		if out.code ~= 0 then
			local what = out.code == 124 and "timed out" or ("exited " .. out.code)
			warn("get-failed", ("`%s` %s%s"):format(table.concat(cfg.get, " "), what, tail(out.stderr)))
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
			local what = out.code == 124 and "timed out" or ("exited " .. out.code)
			warn("set-failed", ("`%s` %s%s"):format(table.concat(argv, " "), what, tail(out.stderr)))
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
	-- spin.
	if want() ~= applied_for then
		cycle()
	end
end

cycle = function()
	if not cfg or busy then
		return
	end
	busy = true

	get_async(function(current)
		if observe then
			observe = false
			if current == nil then
				-- A failed read is not evidence. Keep what we had.
			elseif current ~= cfg.english then
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
	-- Only take a reading when we are idle. Mid-cycle, the machine may be showing
	-- our own in-flight change rather than the user's.
	if not now and not busy then
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
