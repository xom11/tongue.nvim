--- `:checkhealth tongue` had no test at all, and that is exactly why it shipped
--- with a call that threw an error out of the very check meant to diagnose a
--- broken backend.
---
--- `:checkhealth` proper cannot run under `nvim -l`, so `vim.health` is replaced
--- with a collector and `check()` is called directly. That covers everything
--- this module actually decides; the rendering is Neovim's problem.

local h = require("helpers")

local function collect(fn)
	local real = vim.health
	local seen = {}
	-- The stub must be as STRICT as the real vim.health, not merely as capable.
	-- A permissive collector happily accepted `{ "boom", 1 }` -- the exact value
	-- that makes the real one throw -- so this file passed against the bug it was
	-- written to catch.
	local function record(level)
		return function(msg, advice)
			if type(msg) ~= "string" then
				error(("vim.health.%s: expected string message, got %s"):format(level, type(msg)))
			end
			if advice ~= nil then
				if type(advice) == "string" then
					advice = { advice }
				elseif type(advice) ~= "table" then
					error(("vim.health.%s: advice must be a string or list, got %s"):format(level, type(advice)))
				end
				for i, line in ipairs(advice) do
					if type(line) ~= "string" then
						error(("vim.health.%s: advice[%d] must be a string, got %s"):format(level, i, type(line)))
					end
				end
			end
			seen[#seen + 1] = { level = level, msg = msg, advice = advice }
		end
	end
	vim.health = {
		start = record("start"),
		ok = record("ok"),
		info = record("info"),
		warn = record("warn"),
		error = record("error"),
	}
	local ok, err = pcall(fn)
	vim.health = real
	return ok, err, seen
end

local function check()
	return collect(function()
		require("tongue.health").check()
	end)
end

local function find(seen, level, pattern)
	for _, e in ipairs(seen) do
		if e.level == level and e.msg:find(pattern) then
			return e
		end
	end
	return nil
end

return function(t)
	t.test("a non-zero exit is reported, not thrown", function()
		-- The regression: `{ (out.stderr):gsub(...) }` builds `{ "boom", 1 }`,
		-- and vim.health rejects the number -- aborting the whole check and
		-- losing the stderr, the token, everything.
		h.arm({ machine = "en", fail = true })
		h.settle()
		local ok, err, seen = check()
		t.ok(ok, "checkhealth must not throw: " .. tostring(err))
		t.ok(find(seen, "error", "exited") ~= nil, "and it must say the command failed")
	end)

	t.test("the backend's `unknown` sentinel is not reported as a wrong binary", function()
		-- `unknown` is a legitimate answer -- the backend saying it does not
		-- recognise the live state. Calling it an error accuses the user of
		-- installing the wrong program while everything works.
		--
		-- Set AFTER settling, like the declared-set case below: the plugin now
		-- treats a shrug as "not English" and forces English, so arming with it
		-- would leave health looking at `en`.
		h.arm({ machine = "en" })
		h.settle()
		h.set_machine("unknown")
		local ok, err, seen = check()
		t.ok(ok, "must not throw: " .. tostring(err))
		t.eq(find(seen, "error", "declared set"), nil, "must not be an error")
		t.ok(find(seen, "info", "unknown") ~= nil, "it belongs in info")
	end)

	t.test("a token outside the declared set IS reported", function()
		-- Set it AFTER settling: the plugin's own startup read rejects the token
		-- and forces English, so arming with it would leave health nothing to see.
		h.arm({ machine = "en" })
		h.settle()
		h.set_machine("com.apple.keylayout.ABC")
		local ok, err, seen = check()
		t.ok(ok, "must not throw: " .. tostring(err))
		t.ok(find(seen, "error", "declared set") ~= nil, "an unknown token is how a name collision looks")
	end)

	t.test("a healthy backend reads back cleanly", function()
		h.arm({ machine = "vi" })
		h.settle()
		local ok, err, seen = check()
		t.ok(ok, "must not throw: " .. tostring(err))
		t.ok(find(seen, "ok", "active via") ~= nil, "must report the resolved backend")
		t.ok(find(seen, "ok", "reads back") ~= nil, "and the value it read")
	end)

	t.test("a backend that carries a note has it read out", function()
		-- The price of auto-detecting macism and im-select. They cannot see an
		-- external IME at all, so a machine that lands on one is running a plugin
		-- that looks healthy and enforces nothing. `:checkhealth` is the only
		-- place that can say so, and a note nobody prints is a note nobody reads.
		h.arm({ machine = "vi" })
		h.settle()
		local carrier = vim.deepcopy(h.backend)
		carrier.note = "MOVES ONLY ONE LEVER"
		require("tongue").setup({ backend = carrier, notify = false })
		h.settle()

		local ok, err, seen = check()
		t.ok(ok, "must not throw: " .. tostring(err))
		t.ok(find(seen, "warn", "MOVES ONLY ONE LEVER") ~= nil, "the note must be surfaced as a warning")
	end)

	t.test("a backend with nothing to warn about warns about nothing", function()
		-- The counterweight to the test above: a note printed unconditionally, or
		-- printed for `tongue`, would train the user to ignore the one case where
		-- it matters.
		h.arm({ machine = "vi" })
		h.settle()
		local ok, err, seen = check()
		t.ok(ok, "must not throw: " .. tostring(err))
		t.eq(find(seen, "warn", "lever"), nil, "no note, no warning")
	end)

	t.test("an SSH variable is warned about, and the warning names it", function()
		-- The failure nothing else here can see: Neovim on one machine, the
		-- keyboard on another. The plugin is running at all only because
		-- `backend` was named explicitly -- which overrides the SSH guard on
		-- purpose -- so every other check in this file passes while `get` and
		-- `set` drive a machine nobody is typing on.
		--
		-- All three variables, for the reason `backend.lua` reads all three:
		-- which one survives to Neovim is not something the plugin chooses.
		h.arm({ machine = "en" })
		h.settle()
		for _, name in ipairs({ "SSH_TTY", "SSH_CONNECTION", "SSH_CLIENT" }) do
			vim.env[name] = "10.0.0.2 51000 10.0.0.1 22"
			local ok, err, seen = check()
			-- Cleared BEFORE the assertions. `t.ok` throws and `t.test` pcalls it,
			-- so a line after a failed assert never runs -- and a leaked variable
			-- turns every later spec into a different test than the one written.
			vim.env[name] = nil
			t.ok(ok, "must not throw: " .. tostring(err))
			local e = find(seen, "warn", "keystrokes come from")
			t.ok(e ~= nil, "driving the wrong machine must be called out: " .. vim.inspect(seen))
			t.ok(e.msg:find(name, 1, true) ~= nil, "and the warning must name the variable that fired: " .. e.msg)
		end
	end)

	t.test("no SSH variable, no warning about the machine", function()
		-- The counterweight, and it is not ceremony: the condition above is a
		-- proxy, so a version that fires unconditionally passes every other test
		-- in this file. `tests/run.lua` clears all three variables before the
		-- suite starts, which is exactly what makes such a version invisible.
		h.arm({ machine = "en" })
		h.settle()
		local ok, err, seen = check()
		t.ok(ok, "must not throw: " .. tostring(err))
		t.eq(find(seen, "warn", "keystrokes come from"), nil, "no SSH variable, nothing to say")
	end)

	t.test("health exercises `set`, and puts the machine back", function()
		-- The only way to catch a backend whose `set` lies: measured on fcitx5
		-- 5.1.19, `-s <a name not in your group>` exits 0, prints nothing and
		-- changes nothing. There is no exit code and no output for the running
		-- plugin to read -- but a diagnostic can just look.
		h.arm({ machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "precondition: not already in English")

		local ok, err, seen = check()
		t.ok(ok, "must not throw: " .. tostring(err))
		t.ok(find(seen, "ok", "`set` works") ~= nil, "a working set must be reported: " .. vim.inspect(seen))
		t.eq(h.machine(), "vi", "and the machine must be left where the user had it")
		h.leave()
		h.settle()
	end)

	t.test("a `set` that exits 0 and changes nothing is caught here, and nowhere else", function()
		h.arm({ machine = "vi", set_noise = "" })
		h.settle()
		h.enter()
		h.settle()
		-- From here the fixture accepts every `set` in silence and ignores it,
		-- which is exactly what fcitx5 does with a name outside your group.
		vim.env.FAKE_IM_SET_NOISE = nil
		vim.env.FAKE_IM_SET_IGNORE = "1"
		local ok, err, seen = check()
		vim.env.FAKE_IM_SET_IGNORE = nil
		t.ok(ok, "must not throw: " .. tostring(err))
		local e = find(seen, "error", "exited 0 and printed nothing")
		t.ok(e ~= nil, "the silent failure must be an error: " .. vim.inspect(seen))
		t.ok(
			table.concat(e.advice or {}, " "):find("no exit code", 1, true) ~= nil,
			"and it must say why the plugin itself cannot see it"
		)
		h.leave()
		h.settle()
	end)

	t.test("a config bug is an error, not the same `info` as an SSH session", function()
		-- `resolve` computes the distinction and `setup` records it; it used to be
		-- thrown away one line later. A user who typo'd their config and ran the
		-- documented way to diagnose this plugin was told `inactive: ...` in the
		-- same neutral style as "there is no IME tool here", long after the startup
		-- error had scrolled off the screen.
		local real = vim.notify
		vim.notify = function() end
		require("tongue").setup({ backend = "no-such-preset", notify = false })
		vim.wait(100)
		vim.notify = real

		local ok, err, seen = check()
		t.ok(ok, "must not throw: " .. tostring(err))
		t.ok(find(seen, "error", "misconfigured") ~= nil, "a config bug must be an error: " .. vim.inspect(seen))
		t.eq(find(seen, "info", "inactive"), nil, "and must not also be filed as benign")
	end)

	t.test("an inactive plugin is information, not an error", function()
		-- No backend on this machine, and SSH, are correct outcomes.
		require("tongue").setup({ backend = nil, notify = false })
		local ok, err, seen = check()
		t.ok(ok, "must not throw: " .. tostring(err))
		if require("tongue").status().enabled then
			-- This machine does have a backend; nothing to assert.
			return
		end
		t.eq(find(seen, "error", "."), nil, "being inert must not be an error")
		t.ok(find(seen, "info", "inactive") ~= nil, "but it must say so")
	end)
end
