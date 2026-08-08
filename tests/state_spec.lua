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
		h.enter() -- read starts now, snapshotting "en"
		h.set_machine("vi") -- user's global hotkey, inside the read window
		h.leave() -- and straight back out
		h.settle()
		t.eq(h.machine(), "en", "must not be left in Normal mode with the IME on")
		t.eq(st().last_layout, "vi", "and the switch made mid-Insert must be remembered")
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
		h.enter()
		h.leave()
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
		h.arm({ machine = "vi" })
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

	t.test("an invalid backend refuses to run rather than doing nothing quietly", function()
		require("tongue").setup({ backend = { english = "en" }, notify = false })
		local s = st()
		t.eq(s.enabled, false)
		t.eq(s.reason, "backend.get must be a non-empty list of strings")
	end)
end
