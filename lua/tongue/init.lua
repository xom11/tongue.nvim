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
--- Three properties are load-bearing and easy to break:
---
---   1. Nothing here blocks the UI. A backend read costs ~40-50 ms, and the
---      obvious implementation pays that on every single exit from Insert mode.
---   2. Mode tracking goes through `ModeChanged`, not `InsertLeave`. `i_CTRL-C`
---      leaves Insert *without firing InsertLeave* (`:help i_CTRL-C`), which
---      strands you in Normal mode with the IME still on -- indefinitely.
---   3. A process is spawned only when it can change something. The obvious
---      implementation reads the machine on every boundary; half of those reads
---      ask a question we already know the answer to. See the fast path in
---      `cycle`.

local api = vim.api

local M = {}

--- `vim.system` is the floor: it is the only reader that separates stdout from
--- stderr, and the only one with a timeout. Both matter -- see `sanitize` and
--- `run` below. A `jobstart` fallback would reintroduce the bug this fixes.
local MIN_NVIM = "nvim-0.10"

--- Floor for `setup({ timeout = ... })`.
---
--- Not a round number picked for looks: `tongue` itself costs ~40-50 ms and
--- macism ~22 ms, so anything under this is a deadline that fires before a
--- healthy backend can answer -- which reads exactly like a broken backend.
local MIN_TIMEOUT = 100

local uv = vim.uv or vim.loop

--- Hoisted rather than required per call. `require` on a loaded module is a hash
--- lookup and a function call, and `sanitize` sits under every single read.
local backends = require("tongue.backend")
local sanitize = backends.sanitize
local typing = require("tongue.mode").typing

-- ── types ───────────────────────────────────────────────────────────────────

---@class tongue.Backend
---@field english string Token forced in Normal mode.
---@field get string[] argv printing the current token on stdout.
---@field set string[] argv selecting a token; the token is appended.
---@field unknown? string Token meaning "unrecognised"; treated as `english`.
---@field tokens? string[] Allow-list; must contain `english`. nil means any single word.
---@field note? string Printed by `:checkhealth tongue`; no other effect.

---@class tongue.Opts
---@field backend? string|tongue.Backend Preset name or table. nil auto-detects.
---@field english? string Overrides the resolved backend's English token.
---@field notify? boolean Warn on backend failure. Default true.
---@field timeout? integer Per-command deadline in milliseconds. Default 2000.
---@field verify? boolean Re-read the machine before every switch. Default false.

---@class tongue.Status
---@field enabled boolean A backend was resolved.
---@field attached boolean Autocommands are installed; the plugin is acting.
---@field misconfigured boolean Inert because of a config bug, not because there is nothing here.
---@field reason string Which backend and why, or why none. For humans.
---@field backend tongue.Backend? A copy -- mutating it changes nothing.
---@field last_layout string? Token Insert mode will restore.
---@field inserting boolean
---@field busy boolean A command is in flight.
---@field observe boolean The next trusted read records the user's own choice.
---@field applied string? Token of our most recent believed `set`.
---@field timeout integer
---@field verify boolean

-- ── configuration ───────────────────────────────────────────────────────────

---@type tongue.Backend?
local cfg = nil -- resolved backend, or nil => plugin inert
local reason = "not set up"
local timeout_ms = 2000
local notify = true
local verify = false

-- Rebuilt on every failure in the old version, which for a broken backend is
-- every mode change. Neither can change after `setup`, so both are built once.
local get_str, set_str = "", ""

-- ── state ───────────────────────────────────────────────────────────────────
--
-- last_layout : the token the user was last *observed* typing in
-- inserting   : are we in a mode where keys produce text
-- busy        : a get(+set) cycle is in flight  (single-flight)
-- observe     : the next successful read records the user's own choice
-- applied     : the token of OUR most recent believed `set`, else nil
--
-- `applied` looks redundant and is not. It does two jobs. It is what lets
-- `observe` tell "the user chose English" apart from "our own restore just
-- landed" -- drop it and the plugin silently forgets your Vietnamese the first
-- time you leave Insert mode quickly. And it is the cache that lets `cycle` skip
-- a read whose answer is already known.

-- epoch   : bumped on every crossing of the typing boundary; a reading taken
--           under an older epoch describes a mode we have already left
-- recheck  : a boundary was crossed while a command was in flight
-- session : bumped by every `setup()`. A command in flight belongs to the
--           configuration that started it, and `:Lazy reload` or a config
--           reload can replace that configuration underneath it.
local last_layout, inserting, busy, observe, applied
local epoch, recheck, session = 0, false, 0
local augroup = nil
local attached = false
local misconfigured = false

local warned = {}

--- Warn at most once per `key` per 30 s.
---
--- A broken backend fires on every mode change; an unthrottled notify would bury
--- the editor, and burying it is how a user ends up disabling the warning
--- instead of fixing the cause. Formatting happens AFTER the throttle, so the
--- suppressed messages cost nothing but their arguments.
local function warn(key, fmt, ...)
	if not notify then
		return
	end
	local now = uv.hrtime()
	if warned[key] and (now - warned[key]) < 30e9 then
		return
	end
	warned[key] = now
	local msg = fmt:format(...)
	vim.schedule(function()
		vim.notify("tongue.nvim: " .. msg, vim.log.levels.WARN)
	end)
end

local function clip(s)
	if #s > 200 then
		return s:sub(1, 200) .. "..."
	end
	return s
end

local function tail(stderr)
	if type(stderr) ~= "string" then
		return ""
	end
	local s = stderr:gsub("%s+$", "")
	if s == "" then
		return ""
	end
	return " -- stderr: " .. clip(s)
end

-- ── reading the machine ─────────────────────────────────────────────────────

local SPAWN_FAILED = -1

local function why_code(code)
	if code == 124 then
		-- Naming the budget is what makes the warning fixable. "timed out" alone
		-- sends people looking at their backend when the answer is one option.
		return ("timed out after %d ms (raise it with setup({ timeout = ... }))"):format(timeout_ms)
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

	-- Guarded for the same reason as the spawn below, and it is the same failure:
	-- `assert` on `uv.new_timer()`'s `nil, err` pair throws on THIS stack, which
	-- is inside `cycle` with `busy` already true. File-descriptor exhaustion is
	-- rare and "the plugin is dead for the rest of the session, silently" is not
	-- a proportionate response to it.
	local ok_timer, timer = pcall(uv.new_timer)
	if not ok_timer or not timer then
		return vim.schedule(function()
			cb({ code = SPAWN_FAILED, signal = 0, stdout = "", stderr = "no timer: " .. tostring(timer) })
		end)
	end

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

--- Read the machine. `cb(token, unknown)`; `token` is nil when the read failed.
---
--- The backend is captured rather than read from `cfg` inside the callback. A
--- second `setup()` can land while this is in flight, and a callback that reads
--- the module-level `cfg` then indexes whatever the new configuration left there
--- -- `nil` when the new config was rejected, which throws out of a scheduled
--- callback and latches `busy` for the rest of the session.
local function get_async(b, cb)
	run(b.get, function(out)
		if out.code ~= 0 then
			warn("get-failed", "`%s` %s%s", get_str, why_code(out.code), tail(out.stderr))
			return cb(nil)
		end
		local token, err, unknown = sanitize(b, out.stdout)
		if not token then
			warn("get-garbage", "unusable output from `%s` (%s)%s", get_str, err, tail(out.stderr))
		end
		cb(token, unknown)
	end)
end

--- Run `set`, and report whether we can BELIEVE it.
---
--- Exit code alone is not enough, and that is measured rather than defensive:
--- macism 3.1.1 answers a nonexistent input source with `Input source ... does
--- not exist!` on STDOUT and still exits 0. There is no code to read, so what it
--- printed is the only evidence that anything went wrong -- and taking exit 0 at
--- its word leaves the plugin recording a switch that never happened, silently,
--- for the rest of the session.
---
--- A successful `set` has nothing to say: `tongue en` writes to neither stream,
--- and neither does `fcitx5-remote -s`. Output here means something is wrong.
local function set_async(b, token, cb)
	-- Built by hand rather than `vim.list_extend(vim.deepcopy(...))`: this is a
	-- flat list of strings on the hot path, and deepcopy pays for recursion and
	-- cycle detection that a list of strings can never need.
	local src = b.set
	local n = #src
	local argv = {}
	for i = 1, n do
		argv[i] = src[i]
	end
	argv[n + 1] = token

	run(argv, function(out)
		if out.code ~= 0 then
			warn("set-failed", "`%s %s` %s%s", set_str, token, why_code(out.code), tail(out.stderr))
			return cb(false)
		end
		local said = (out.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if said ~= "" then
			warn("set-noisy", "`%s %s` exited 0 but printed: %s", set_str, token, clip(said))
			return cb(false)
		end
		cb(true)
	end)
end

-- ── the state machine ───────────────────────────────────────────────────────

local cycle, finish

--- The intent, DERIVED rather than captured.
---
--- Snapshotting the desired token into a variable and reading it back in a
--- callback just moves the staleness one level down: by the time a 50 ms read
--- returns, the mode may have changed twice.
local function want()
	return inserting and last_layout or cfg.english
end

-- ── telling the outside world ───────────────────────────────────────────────

local said_token, said_layout

--- Fire `User TongueChanged`, but only when something actually moved.
---
--- Diffed rather than fired unconditionally, because the point of the event is
--- that a statusline component can redraw on it: one that fired on every mode
--- change would cost more than the plugin does. The payload carries the INTENT,
--- not a reading -- it is right the instant the mode changes, ~200 ms before the
--- machine gets there, which is what a statusline wants.
local function announce()
	local token = (cfg and attached) and want() or nil
	local layout = cfg and last_layout or nil
	if token == said_token and layout == said_layout then
		return
	end
	said_token, said_layout = token, layout
	api.nvim_exec_autocmds("User", {
		pattern = "TongueChanged",
		modeline = false,
		data = { token = token, layout = layout, inserting = inserting or false },
	})
end

finish = function(applied_for)
	busy = false
	if not cfg then
		return -- `setup()` turned the plugin inert while this was in flight
	end
	announce()
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
	if not cfg or not attached or busy then
		return
	end

	local w = want()

	-- ── the fast path ───────────────────────────────────────────────────────
	--
	-- `applied` is not a guess. It is the token our own last command put on the
	-- machine and was believed to have applied, cleared the instant anything
	-- could have invalidated it: a failed or noisy `set`, a `FocusGained`, an
	-- explicit `sync()`. So when it already equals the intent there is nothing
	-- to do at all, and when it does not, that `set` is going out whatever a
	-- read would have said -- which makes the read a 40-50 ms tax on the one
	-- operation the user can feel.
	--
	-- Measured against the fixture: an Insert round trip cost four processes and
	-- now costs two, and entering Insert in a session that never leaves English
	-- costs none.
	--
	-- What it gives up is exactly one case: an input method changed by hand *in
	-- Normal mode*, with no focus event to notice it. That change now survives
	-- into Insert instead of being overwritten -- which is arguably what pressing
	-- the hotkey meant. `verify = true` buys the old behaviour back.
	--
	-- NEVER taken while `observe` is pending. That request exists precisely to
	-- learn something the cache cannot know, and skipping the read there would
	-- make the plugin permanently blind to a switch made mid-Insert.
	-- Captured, not read back from the module in the callbacks. A second
	-- `setup()` can land while a command is in flight, and everything it touches
	-- -- `cfg`, `epoch`, `busy` -- would otherwise be read by a callback that
	-- belongs to the configuration before it.
	local b = cfg
	local my_session = session

	if not verify and not observe and applied ~= nil then
		if applied == w then
			return
		end
		busy = true
		recheck = false
		return set_async(b, w, function(believed)
			if session ~= my_session then
				return
			end
			applied = believed and w or nil
			finish(w)
		end)
	end

	busy = true
	recheck = false
	local my = epoch

	get_async(b, function(current, unsure)
		-- A `setup()` landed while this was in flight. It has already reset the
		-- state machine and released the latch, so the only correct thing to do
		-- with this reading is drop it: it speaks a different backend's
		-- vocabulary, and acting on it would consume the new `observe` and write
		-- `last_layout` from a token that means nothing here.
		if session ~= my_session then
			return
		end

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

		-- `unsure` is the backend's shrug -- `tongue` printing `unknown`, or
		-- `im-select.exe` printing `0` because there is no foreground window. It
		-- arrives here AS `english` so a caller can still act, and treating it as
		-- English was two silent bugs at once: the `observe` branch read the shrug
		-- as a deliberate switch and forgot the layout you were typing in, and the
		-- comparison below concluded "already English" and issued no `set` -- so
		-- Normal mode quietly stopped being forced, which is the one thing this
		-- plugin promises.
		if observe and current ~= nil and not unsure then
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

		local now_want = want()

		if current == nil then
			-- Never restore blind: guessing wrong here drops you into Normal mode
			-- with an IME on. Forcing English blind is always safe, so that one
			-- still goes through.
			if now_want ~= cfg.english then
				return finish(now_want)
			end
		elseif current == now_want and not unsure then
			applied = current
			return finish(now_want)
		end

		set_async(b, now_want, function(believed)
			if session ~= my_session then
				return
			end
			applied = believed and now_want or nil
			finish(now_want)
		end)
	end)
end

--- Forget what we believe about the machine, then reconcile.
---
--- Everything that can invalidate the cache funnels through here. Something
--- outside Neovim may have moved the input method, so neither `applied` nor a
--- reading already in flight can be trusted.
local function resync()
	applied = nil
	epoch = epoch + 1
	if busy then
		recheck = true
	end
	cycle()
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
	-- Announced BEFORE the cycle: the intent is already correct, and a statusline
	-- should redraw now rather than when a process comes back.
	announce()
	cycle()
end

local function attach()
	augroup = api.nvim_create_augroup("tongue.nvim", { clear = true })
	attached = true

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
			-- One `vim.v` lookup instead of two. This runs on every operator, every
			-- visual selection and every `:`, so it is the hottest code here even
			-- though it usually decides to do nothing.
			local ev = vim.v.event
			on_mode(ev.old_mode, ev.new_mode)
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
				resync()
			end
		end,
	})
end

local function detach()
	if augroup then
		api.nvim_del_augroup_by_id(augroup)
		augroup = nil
	end
	attached = false
end

-- ── public API ──────────────────────────────────────────────────────────────

--- Set up the plugin. Required -- nothing happens on `require` alone.
---@param opts tongue.Opts?
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

	detach()
	warned = {}
	said_token, said_layout = nil, nil

	-- Monotonic and never reset. A command already in flight belongs to the
	-- configuration that started it, and `:Lazy reload` -- or any config reload --
	-- replaces that configuration underneath it. `epoch` goes up for the same
	-- reason: resetting it to 0 let a reading taken under the old backend satisfy
	-- the freshness check and be acted on by the new state machine.
	session = session + 1
	epoch = epoch + 1

	cfg = nil
	last_layout, inserting, busy, applied, observe = nil, false, false, nil, false
	recheck = false
	misconfigured = false

	notify = opts.notify ~= false
	verify = opts.verify == true

	--- Report a config bug and stay inert. Never silenced by `notify = false`:
	--- that switch is for a flaky backend, not for a broken config.
	local function bad(msg)
		reason, misconfigured = msg, true
		vim.schedule(function()
			vim.notify("tongue.nvim: " .. msg, vim.log.levels.ERROR)
		end)
	end

	-- Validated rather than silently defaulted, because every wrong value here
	-- fails in a way that looks like something else. `timeout = "2s"` reads as
	-- nil and would quietly become 2000. `timeout = 0` starts a uv timer that
	-- fires on the next turn of the loop, so every command reports "timed out"
	-- instantly and the plugin is dead while giving a plausible-sounding reason.
	-- A negative value is cast to an enormous unsigned duration by libuv, so the
	-- deadline never fires at all -- and that deadline is the only thing that
	-- releases the latch when a backend hangs.
	local t = tonumber(opts.timeout)
	if opts.timeout ~= nil and (not t or t < MIN_TIMEOUT) then
		return bad(
			("timeout must be a number of milliseconds >= %d, got %s"):format(MIN_TIMEOUT, vim.inspect(opts.timeout))
		)
	end
	timeout_ms = t or 2000

	local resolved, err, fatal = backends.resolve(opts)
	cfg, reason = resolved, err

	if not cfg then
		-- Inert is a legitimate outcome (SSH, a machine with no IME tool), so it
		-- is not a warning. A *malformed* config is, though -- that is a bug and
		-- silence would hide it.
		--
		-- `resolve` makes the call, not this line. Deciding here means guessing
		-- from `opts` alone, and `opts` cannot tell you whether an `english` is
		-- wrong -- that depends on which backend ended up receiving it.
		if fatal then
			bad(err)
		end
		return
	end

	get_str = table.concat(cfg.get, " ")
	set_str = table.concat(cfg.set, " ")

	last_layout = cfg.english

	attach()

	-- Reconcile once at startup, asynchronously. The editor may well be opening
	-- while the IME is on, and no mode change or focus event is guaranteed to
	-- follow. `observe` is set so that this first read also records what you were
	-- using -- so the first `i` restores it instead of stranding you in English.
	observe = true
	vim.schedule(function()
		announce()
		cycle()
	end)
end

--- Start acting again after `disable()`.
---
--- A cold start, not a resume: anything at all may have happened while the
--- plugin was not looking, so the cache is dropped and the layout is learned
--- afresh.
---@return boolean ok false when there is no backend to drive
function M.enable()
	if not cfg then
		return false
	end
	if attached then
		return true
	end
	attach()
	inserting = typing(vim.fn.mode(1))
	observe = true
	resync()
	announce()
	return true
end

--- Stop acting.
---
--- The machine is left exactly where it is. Switching it on the way out would be
--- a surprise in one direction or the other, and the user's own hotkey is one
--- keystroke away.
function M.disable()
	detach()
	announce()
end

---@return boolean enabled the state after toggling
function M.toggle()
	if attached then
		M.disable()
		return false
	end
	return M.enable()
end

--- Re-read the machine and re-assert the token for the current mode.
---
--- For a keymap, and for after something outside Neovim moved the input method
--- without Neovim ever losing focus -- the one case the fast path in `cycle`
--- cannot see by itself.
function M.sync()
	if not cfg or not attached then
		return
	end
	inserting = typing(vim.fn.mode(1))
	observe = true
	resync()
end

--- The token that should be in force right now.
---
--- The plugin's INTENT, which is right the instant the mode changes rather than
--- when the process returns. `nil` when inert or disabled.
---@return string?
function M.token()
	if not cfg or not attached then
		return nil
	end
	return want()
end

--- The token Insert mode will restore. `nil` when inert.
---@return string?
function M.layout()
	return cfg and last_layout or nil
end

---@class tongue.StatuslineOpts
---@field english? string Shown while English is in force. Default "".
---@field inactive? string Shown while inert or disabled. Default "".
---@field format? string `string.format` pattern for every other token. Default "%s".

--- A statusline fragment: the empty string whenever there is nothing worth
--- saying, which is most of the time.
---
--- Pairs with `User TongueChanged`, which fires only when this value can have
--- changed -- so a component can refresh on the event instead of polling.
---@param opts tongue.StatuslineOpts?
---@return string
function M.statusline(opts)
	opts = opts or {}
	local token = M.token()
	if token == nil then
		return opts.inactive or ""
	end
	if token == cfg.english then
		return opts.english or ""
	end
	return (opts.format or "%s"):format(token)
end

--- Internal, for tests only. See `on_mode`.
---@private
function M._on_mode(old_mode, new_mode)
	on_mode(old_mode, new_mode)
end

--- Current state. For `:checkhealth tongue`, `:Tongue status`, and bug reports.
---
--- `backend` is a COPY. The resolved backend is often one of the shared preset
--- tables, and handing out a reference is how a caller's `.english =` poisons
--- every later `setup()` in the session.
---@return tongue.Status
function M.status()
	return {
		enabled = cfg ~= nil,
		attached = attached,
		-- `resolve` already separates "nothing to drive here" from "you configured
		-- this wrong", and the distinction was being thrown away one line after it
		-- was computed: `:checkhealth` printed a typo'd config as benign `info`,
		-- styled identically to an SSH session, long after the startup error had
		-- scrolled off the screen.
		misconfigured = misconfigured,
		reason = reason,
		backend = cfg and vim.deepcopy(cfg) or nil,
		last_layout = last_layout,
		inserting = inserting,
		busy = busy,
		observe = observe,
		applied = applied,
		timeout = timeout_ms,
		verify = verify,
	}
end

return M
