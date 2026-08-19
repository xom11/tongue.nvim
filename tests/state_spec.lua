local h = require("helpers")

local function st()
	return require("tongue").status()
end

return function(t)
	t.test("startup forces English and records what you were using", function()
		h.arm({ machine = "vi" })
		h.settle()
		t.eq(h.machine(), "en", "Normal mode must end up in English")
		t.eq(st().last_layout, "vi", "the layout in use at startup must be remembered")
	end)

	t.test("Insert restores it, leaving forces English again", function()
		h.arm({ machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "entering Insert must restore the remembered layout")
		h.leave()
		h.settle()
		t.eq(h.machine(), "en")
		t.eq(st().last_layout, "vi")
	end)

	t.test("a fast Esc leaves no stray restore behind", function()
		-- THE regression. A read costs 60 ms here and the exit lands inside that
		-- window. The pre-plugin implementation ended this scenario with the
		-- machine in Vietnamese *and* `last_layout` poisoned to "en", so the next
		-- `i` restored English -- permanently, with no event able to correct it.
		h.arm({ machine = "vi", delay = 60 })
		h.settle()
		t.eq(st().last_layout, "vi", "precondition")

		h.enter()
		h.leave() -- immediately, while the read is still in flight
		h.settle()

		t.eq(h.machine(), "en", "must not be stranded in Vietnamese in Normal mode")
		t.eq(st().last_layout, "vi", "must not have forgotten the layout")
	end)

	t.test("the same round trip, unhurried, still restores", function()
		-- Control for the test above: proves it does not pass by never restoring.
		h.arm({ machine = "vi", delay = 60 })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "given time, the restore must happen")
		h.leave()
		h.settle()
		t.eq(h.machine(), "en")
	end)

	t.test("a manual switch during Insert is noticed", function()
		h.arm({ machine = "en" })
		h.settle()
		h.enter()
		h.settle()
		h.set_machine("zh") -- the user's own global hotkey, behind our back
		h.leave()
		h.settle()
		t.eq(h.machine(), "en", "still forced to English on the way out")
		t.eq(st().last_layout, "zh", "and the manual choice is what gets restored next")
	end)

	t.test("English chosen by the user is not mistaken for our own echo", function()
		-- The `applied == last_layout` guard. User types in Vietnamese, leaves,
		-- comes back, deliberately switches to English, leaves again: the plugin
		-- must now remember English, not keep resurrecting Vietnamese.
		h.arm({ machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "precondition")
		h.set_machine("en") -- user turns the IME off themselves
		h.leave()
		h.settle()
		t.eq(st().last_layout, "en", "a deliberate switch to English must stick")
		h.enter()
		h.settle()
		t.eq(h.machine(), "en", "and Insert must not drag Vietnamese back")
	end)

	t.test("i_CTRL-O costs nothing", function()
		h.arm({ machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		local before = #h.calls()
		h.mode("i", "niI") -- <C-o>
		h.mode("niI", "i") -- ...and back
		h.settle()
		t.eq(#h.calls(), before, "i_CTRL-O crosses no typing boundary; it must not touch the backend")
		h.leave()
		h.settle()
	end)

	t.test("completion churn costs nothing", function()
		h.arm({ machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		local before = #h.calls()
		for _, pair in ipairs({ { "i", "ix" }, { "ix", "i" }, { "i", "ic" }, { "ic", "i" } }) do
			h.mode(pair[1], pair[2])
		end
		h.settle()
		-- Reacting here re-selects the input source mid-composition, which is
		-- precisely the CJK sub-mode flicker.
		t.eq(#h.calls(), before, "completion never leaves Insert; it must not touch the backend")
		h.leave()
		h.settle()
	end)

	t.test("terminal-normal is Normal, terminal-insert is typing", function()
		h.arm({ machine = "vi" })
		h.settle()
		local before = #h.calls()
		h.mode("n", "nt") -- opening a terminal buffer: still Normal
		h.settle()
		t.eq(#h.calls(), before, "n -> nt crosses no boundary")
		h.mode("nt", "t") -- actually typing into the terminal
		h.settle()
		t.eq(h.machine(), "vi", "terminal-insert must restore the layout")
		h.mode("t", "nt")
		h.settle()
		t.eq(h.machine(), "en")
	end)

	t.test("a storm of mode changes coalesces", function()
		h.arm({ machine = "en", delay = 40 })
		h.settle()
		local before = #h.calls()
		for _ = 1, 30 do
			h.enter()
			h.leave()
		end
		h.settle()
		local n = #h.calls() - before
		t.ok(n <= 8, ("60 mode changes must not mean 60 processes; got %d"):format(n))
	end)

	t.test("a failing backend does not spin", function()
		h.arm({ machine = "en", fail = true })
		h.settle()
		local before = #h.calls()
		h.enter()
		h.leave()
		h.settle()
		local n = #h.calls() - before
		t.ok(n > 0, "it should still try")
		t.ok(n < 12, ("a broken backend must not be retried forever; got %d calls"):format(n))
		t.eq(st().busy, false, "and it must not be left mid-cycle")
	end)

	t.test("a hanging backend releases the latch AT the timeout", function()
		-- The old version of this test used delay=900 against a 6000 ms settle
		-- budget, so it passed because the command finished on its own -- deleting
		-- `timeout` from vim.system entirely still left the suite 30/30 green.
		--
		-- The real hard case: `fake-im` forks `sleep`, and that grandchild inherits
		-- the stdout pipe. `vim.system` SIGTERMs the shell at `timeout` but still
		-- waits for EOF, so its callback arrives at the *delay*, not the timeout.
		-- Measured before the fix: delay=5000 / timeout=150 released at 10175 ms.
		-- The uv timer in `run()` is what makes the timeout a real deadline.
		h.arm({ machine = "en", delay = 5000, timeout = 150 })
		local uv = vim.uv or vim.loop
		vim.wait(3000, function()
			return st().busy
		end, 2)
		local t0 = uv.hrtime()
		t.ok(h.settle(2500), "a hung command must release the single-flight latch")
		t.eq(st().busy, false)
		t.ok((uv.hrtime() - t0) / 1e6 < 1500, "must release at the timeout, not when the child finally exits")
	end)

	t.test("a reading older than a mode change is not acted on", function()
		-- The stale-read bug, and the one the fixture could not previously reveal.
		-- Real CLIs answer from the OS the instant they start; a 60 ms read that
		-- spans `i` -> hotkey -> Esc therefore reports the layout from BEFORE the
		-- user's switch. Acting on it ends in Normal mode with the IME still on,
		-- and zero `set` commands issued.
		h.arm({ machine = "en", delay = 60 })
		h.settle()
		h.enter()
		h.settle()

		-- The read window is on the way OUT, not the way in. Entering Insert
		-- stopped reading the machine when the fast path landed, so the version of
		-- this test that opened its window with `h.enter()` was describing a read
		-- that no longer happens -- and stayed green on the strength of its other
		-- assertions. `observe` is what guarantees a read here, and `observe` is
		-- only ever set on the way out.
		h.leave() -- read starts here
		-- Block until the child has actually taken its snapshot. Without this the
		-- write below can land BEFORE the fork gets to read, the reading comes
		-- back fresh, and the test proves nothing. This used to be `vim.wait(25)`,
		-- a bet on how fast a shell starts; the fixture now says when it is ready.
		h.await_snapshot()
		h.set_machine("vi") -- user's global hotkey, inside the read window
		h.enter() -- boundary crossed while that reading is still in flight
		h.leave() -- and straight back out
		h.settle()
		t.eq(h.machine(), "en", "must not be left in Normal mode with the IME on")
		t.eq(st().last_layout, "vi", "and the switch made behind our back must be remembered")
	end)

	t.test("a switch made mid-Insert survives a fast exit", function()
		-- Same shape, slower hand: the observation must not simply be dropped
		-- because a command happened to be in flight when Insert was left.
		h.arm({ machine = "en", delay = 60 })
		h.settle()
		h.enter()
		h.settle()
		h.set_machine("zh")
		h.enter() -- churn to get a command in flight
		h.leave()
		h.settle()
		t.eq(st().last_layout, "zh", "the manual switch must not be forgotten")
	end)

	t.test("a failed read does not burn the pending observation", function()
		h.arm({ machine = "en" })
		h.settle()
		h.enter()
		h.settle()
		h.set_machine("vi")
		vim.env.FAKE_IM_FAIL = "1"
		h.leave()
		h.settle()
		vim.env.FAKE_IM_FAIL = nil
		-- The read failed, so nothing could be learned -- but the request to learn
		-- must survive rather than being consumed by the failure.
		--
		-- Only `enter` here, deliberately: another `leave` would set `observe`
		-- afresh and hide a version that burns it, which is how this test first
		-- passed against the very bug it is named for.
		h.enter()
		h.settle()
		t.eq(st().last_layout, "vi", "the layout must still get learned once reads work again")
	end)

	t.test("a backend that cannot be started does not wedge the plugin", function()
		-- vim.system raises ENOENT on THIS stack rather than calling back, so an
		-- unguarded spawn escapes through the autocmd with `busy` already true --
		-- plugin dead for the rest of the session, silently.
		require("tongue").setup({
			backend = { english = "en", get = { "tongue-nvim-no-such-binary" }, set = { "tongue-nvim-no-such-binary" } },
			notify = false,
		})
		h.settle(2000)
		t.eq(st().enabled, true, "an explicit backend is still configured")
		t.eq(st().busy, false, "a failed spawn must release the latch")
		for _ = 1, 3 do
			h.enter()
			h.leave()
		end
		h.settle(2000)
		t.eq(st().busy, false, "and must keep releasing it")
	end)

	t.test("an unreadable backend never restores blind", function()
		-- Forcing English on a failed read is safe; restoring is not -- guessing
		-- wrong drops you into Normal mode with an IME on.
		--
		-- `verify` on purpose. This is the guard on the READ path, and the fast
		-- path in `cycle` takes no read at all, so it cannot reach this branch --
		-- what it does instead is the test below. Arming without `verify` here
		-- would quietly stop exercising the branch this test is named for.
		h.arm({ machine = "vi", verify = true })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "precondition")
		h.leave()
		h.settle()

		vim.env.FAKE_IM_FAIL = "1"
		local calls_before, sets_before = #h.calls(), h.count("set")
		h.enter()
		h.settle()
		vim.env.FAKE_IM_FAIL = nil
		t.ok(#h.calls() > calls_before, "it must at least have tried to read")
		t.eq(h.count("set"), sets_before, "but must not have issued a blind restore")
		h.leave()
		h.settle()
	end)

	t.test("a backend that breaks mid-session still ends Normal mode in English", function()
		-- The fast path trusts `applied` and issues the restore with no read, so
		-- the guard above cannot apply to it. What has to survive instead is the
		-- invariant that actually matters: however badly the backend behaves,
		-- leaving Insert ends in English -- and a `set` that could not be believed
		-- is never recorded as applied, so the very next cycle drops back to
		-- reading rather than compounding the lie.
		h.arm({ machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "precondition")
		h.leave()
		h.settle()
		t.eq(h.machine(), "en", "precondition")

		vim.env.FAKE_IM_FAIL = "1"
		h.enter()
		h.settle()
		t.eq(st().applied, nil, "a set that failed must not be recorded as applied")
		vim.env.FAKE_IM_FAIL = nil

		h.leave()
		h.settle()
		t.eq(h.machine(), "en", "Normal mode must still end in English")
	end)

	t.test("a backend that shrugs still gets English forced, and keeps the layout", function()
		-- `tongue` prints `unknown` when the live state matches no configured mode,
		-- and `im-select.exe` prints `0` when there is no foreground window. Both
		-- used to arrive as plain "English", with two silent consequences: the
		-- `observe` branch read the shrug as a deliberate switch and forgot the
		-- layout, and -- worse -- "already English" meant no `set` was issued at
		-- all, so Normal mode quietly stopped being forced. That is the plugin's
		-- one guarantee, failing without a word.
		h.arm({ machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		t.eq(st().last_layout, "vi", "precondition")
		t.eq(h.machine(), "vi", "precondition")

		h.set_machine("unknown")
		h.leave()
		h.settle()
		t.eq(h.machine(), "en", "a shrug is not English; English must still be forced")
		t.eq(st().last_layout, "vi", "and the remembered layout must survive it")
		t.eq(st().observe, true, "a shrug is not evidence, so the observation must still be pending")
	end)

	t.test("a reading belongs to the setup() that started it", function()
		-- `:Lazy reload`, and every config reload, calls `setup()` again -- possibly
		-- while a command is still running. That command was started by the
		-- configuration BEFORE the reload, and its answer speaks that backend's
		-- vocabulary. Adopting it consumes the new `observe` and writes
		-- `last_layout` from a token the new backend has never heard of.
		--
		-- Three things make this safe and all three are here: the reading is
		-- dropped by session, `epoch` is bumped rather than reset to 0 (a reset let
		-- a stale reading satisfy the freshness check), and the backend is captured
		-- at call time so the callback never indexes a `cfg` that `setup()` has
		-- since set to nil.
		h.arm({ machine = "zh", delay = 300 })
		vim.wait(60)
		t.eq(st().busy, true, "precondition: the startup read must still be running")

		-- The second configuration cannot read at all, so its `observe` stays
		-- pending -- and a pending `observe` is precisely the window in which a
		-- stale reading does damage. Arming a working backend instead lets the new
		-- session consume its own `observe` within milliseconds, and the test
		-- passes against the bug it is named for.
		h.arm({ machine = "en", fail = true })
		vim.wait(400) -- the previous configuration's 300 ms read lands in here
		vim.env.FAKE_IM_FAIL = nil

		t.eq(st().observe, true, "precondition: the new session must still be waiting to learn")
		t.eq(st().last_layout, "en", "and it must not learn it from the previous backend's reading")
		t.eq(st().busy, false, "nor be left with the latch down")
	end)

	t.test("setup() that rejects its config releases everything the old one held", function()
		-- The rejected path used to return before resetting `busy`, so a command
		-- in flight left the latch down for the rest of the session -- the plugin
		-- dead, silently, which is the exact failure `run`'s pcall exists to stop.
		h.arm({ machine = "vi", delay = 300 })
		h.settle()
		h.enter()
		vim.wait(60)
		t.eq(st().busy, true, "precondition: a command must actually be in flight")

		local real = vim.notify
		vim.notify = function() end
		require("tongue").setup({ backend = { english = "en" }, notify = false }) -- rejected
		vim.wait(500)
		vim.notify = real

		t.eq(st().enabled, false, "the new configuration is the one that counts")
		t.eq(st().misconfigured, true, "and it must be remembered as a config bug, not as inertness")
		t.eq(st().busy, false, "the latch must be down")

		h.arm({ machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "a rejected setup must not poison the next one")
		h.leave()
		h.settle()
	end)

	t.test("a `set` whose exit code lies is confirmed, not believed", function()
		-- Measured on IBus 1.5.34-rc2: `ibus engine <an IME engine>` changes the
		-- engine and then exits 1, because it also shells out to `setxkbmap` and
		-- that fails without a usable X display. Taking the exit code at its word
		-- costs a warning on every restore AND forbids the cache, so every
		-- boundary goes back to reading first.
		--
		-- One read settles it. The rule is unchanged -- a `set` we cannot believe
		-- is not recorded as applied -- but the exit code stops being the last
		-- word when the machine itself can be asked.
		local real = vim.notify
		local seen = {}
		vim.notify = function(msg)
			seen[#seen + 1] = tostring(msg)
		end
		local ok, err = pcall(function()
			h.arm({ machine = "vi", set_exit = 1, notify = true })
			h.settle()
			h.enter()
			h.settle()
		end)
		vim.wait(150)
		vim.notify = real
		t.ok(ok, "must not throw: " .. tostring(err))

		t.eq(h.machine(), "vi", "the switch did happen, whatever the exit code said")
		t.eq(st().applied, "vi", "and it must be recorded, or the cache is dead for the session")
		t.eq(#seen, 0, "a switch that worked must not be reported as a failure: " .. vim.inspect(seen))

		-- And the cache being alive is the whole point: the next entry into
		-- Insert costs nothing.
		h.leave()
		h.settle()
		local before = #h.calls()
		h.enter()
		h.settle()
		t.ok(#h.calls() - before <= 2, "the fast path must be usable again")
		h.leave()
		h.settle()
	end)

	t.test("a `set` that really did nothing is still not believed", function()
		-- The counterweight. Confirming a failed `set` must not become a way of
		-- believing every failure: the fixture's noisy `set` exits 0 and changes
		-- nothing, and the confirming read is what proves it changed nothing.
		local real = vim.notify
		local seen = {}
		vim.notify = function(msg)
			seen[#seen + 1] = tostring(msg)
		end
		local ok, err = pcall(function()
			h.arm({ machine = "vi", set_noise = "Input source en does not exist!", notify = true })
			h.settle()
			vim.wait(200)
		end)
		vim.wait(150)
		vim.notify = real
		t.ok(ok, "must not throw: " .. tostring(err))

		t.eq(h.machine(), "vi", "the fixture must not have moved -- that is the point of the case")
		t.eq(st().applied, nil, "a set we cannot trust must not be recorded as applied")
		local told = false
		for _, m in ipairs(seen) do
			if m:find("does not exist", 1, true) then
				told = true
			end
		end
		t.ok(told, "and the user still has to be told: " .. vim.inspect(seen))
	end)

	t.test("setup() twice does not double up", function()
		h.arm({ machine = "vi" })
		h.settle()
		-- Same fake files, so the call log keeps accumulating -- which is what
		-- would make a duplicated augroup visible.
		require("tongue").setup({ backend = h.backend, notify = false })
		h.settle()
		local before = #h.calls()
		h.enter()
		h.settle()
		local n = #h.calls() - before
		t.ok(n <= 2, ("one entry into Insert must cost at most one get+set; got %d"):format(n))
		h.leave()
		h.settle()
	end)

	t.test("a second setup() drives the new argv, not the one it replaced", function()
		-- The documented answer to a backend whose right answer changes while
		-- Neovim runs (|tongue-backends|): work it out yourself and call `setup()`
		-- again. That is only a recipe if the new argv is the one that runs, and
		-- nothing else here asserts it -- every other second-`setup()` test uses
		-- the same fixture argv and differs only by environment.
		h.arm({ machine = "vi" })
		h.settle()

		local other = vim.fn.tempname()
		vim.fn.writefile({}, other)
		-- `env` rather than a second fixture: same script, different log, so the
		-- only thing that can put a line in `other` is the new argv being spawned.
		local routed = { "env", "FAKE_IM_LOG=" .. other, h.fake_im }
		require("tongue").setup({
			backend = vim.tbl_extend("force", h.backend, { get = routed, set = routed }),
			notify = false,
			timeout = 3000,
		})
		h.settle()
		h.enter()
		h.settle()

		t.ok(#vim.fn.readfile(other) > 0, "the second setup()'s argv must be the one that runs")
		h.leave()
		h.settle()
	end)

	t.test("an invalid backend refuses to run rather than doing nothing quietly", function()
		require("tongue").setup({ backend = { english = "en" }, notify = false })
		local s = st()
		t.eq(s.enabled, false)
		t.eq(s.reason, "backend.get must be a non-empty list of strings")
	end)

	t.test("a `set` that exits 0 but prints is the failure it looks like", function()
		-- Measured on macism 3.1.1: setting an input source that does not exist
		-- prints `Input source ... does not exist!` on STDOUT and exits 0. There
		-- is no exit code to read, so what it printed is the only signal there is
		-- -- and without this the plugin records the set as applied, says nothing,
		-- and switches nothing for the rest of the session.
		--
		-- Every built-in backend is silent on a successful set: `tongue en` writes
		-- to neither stream, and so does the fixture.
		local real = vim.notify
		local seen = {}
		vim.notify = function(msg)
			seen[#seen + 1] = tostring(msg)
		end
		local ok, err = pcall(function()
			h.arm({ machine = "vi", set_noise = "Input source en does not exist!", notify = true })
			h.settle()
			vim.wait(200, function()
				return #seen > 0
			end)
		end)
		vim.notify = real
		t.ok(ok, "must not throw: " .. tostring(err))

		t.eq(h.machine(), "vi", "the fixture must not have moved -- that is the point of the case")
		t.eq(st().applied, nil, "a set we cannot trust must not be recorded as applied")

		local told = false
		for _, msg in ipairs(seen) do
			if msg:find("does not exist", 1, true) then
				told = true
			end
		end
		t.ok(told, "and the user has to be told: " .. vim.inspect(seen))

		-- It must not spin: `finish` re-derives the intent, which has not moved,
		-- so a permanently failing set costs one attempt per boundary and no more.
		t.ok(h.count("set") <= 2, ("a failing set must not loop; got %d"):format(h.count("set")))
	end)

	t.test("a config bug in `english` alone is still announced", function()
		-- `backend` used to be the only knob that could produce a config error, so
		-- the error path only ever checked that one. `english` can too, and a
		-- typo there would otherwise leave the plugin inert without a word --
		-- which is the exact failure this plugin exists to refuse to commit.
		--
		-- `notify = false` deliberately does NOT silence this: it silences runtime
		-- warnings about a flaky backend, not a broken config.
		local real = vim.notify
		local seen = {}
		vim.notify = function(msg, level)
			seen[#seen + 1] = { msg = msg, level = level }
		end
		-- Drain what an earlier test already scheduled. Notifications are deferred,
		-- so the previous case's error lands in THIS stub otherwise -- and the test
		-- passes on somebody else's message.
		vim.wait(100)
		seen = {}
		local ok, err = pcall(function()
			require("tongue").setup({ english = 42, notify = false })
			-- The notification is scheduled, so the loop has to turn.
			vim.wait(500, function()
				return #seen > 0
			end)
		end)
		vim.notify = real
		t.ok(ok, "setup must not throw: " .. tostring(err))

		t.eq(st().enabled, false)
		t.ok(seen[1] ~= nil, "a malformed `english` must be reported")
		t.eq(seen[1].level, vim.log.levels.ERROR)
		t.ok(seen[1].msg:find("english", 1, true) ~= nil, "and it must say what is wrong: " .. tostring(seen[1].msg))
	end)
end
