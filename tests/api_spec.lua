--- The public surface: what a process costs, `:Tongue`, and the API a
--- statusline is expected to call.
---
--- The cost tests are the point of this file. Everything else here is cheap to
--- keep working; the number of processes a mode change spawns is the one
--- property that regresses silently -- the plugin still behaves correctly while
--- costing twice as much, and nothing but a count can see it.

local h = require("helpers")

local function st()
	return require("tongue").status()
end

--- Source `plugin/tongue.lua` for real.
---
--- `nvim -u NONE` skips plugin loading entirely, and the runner puts the plugin
--- on the runtimepath only after startup -- so without this the command under
--- test would be one the suite created itself, which proves nothing about the
--- file users actually get.
local function load_plugin()
	vim.g.loaded_tongue = nil
	vim.cmd("runtime plugin/tongue.lua")
end

--- Run `fn` with `vim.notify` collected rather than printed.
---
--- A malformed backend is reported even with `notify = false` -- deliberately,
--- it is a config bug -- so the two tests below that arm one on purpose would
--- otherwise spray the suite's output with an error that is the expected result.
local function quietly(fn)
	local real = vim.notify
	local seen = {}
	vim.notify = function(msg, level)
		seen[#seen + 1] = { msg = tostring(msg), level = level }
	end
	local ok, err = pcall(fn)
	-- Drained BEFORE the stub is put back: every notification this plugin sends
	-- is `vim.schedule`d, so restoring first hands them all to the real one.
	vim.wait(50)
	vim.notify = real
	if not ok then
		error(err, 0)
	end
	return seen
end

return function(t)
	-- ── what a mode change costs ──────────────────────────────────────────────

	t.test("entering Insert costs one process, not two", function()
		-- We forced English on the way out and know it landed, so reading the
		-- machine before restoring asks a question whose answer we hold. The read
		-- is also the ~40-50 ms the user waits for their IME to come back.
		h.arm({ machine = "vi" })
		h.settle()
		local before = #h.calls()

		h.enter()
		h.settle()
		t.eq(#h.calls() - before, 1, "restoring must cost the `set` and nothing else")
		t.eq(h.machine(), "vi", "and it must actually restore")

		h.leave()
		h.settle()
		-- Leaving still reads: a switch made by hand mid-Insert can only be
		-- learned from the machine, and that is what `observe` is for.
		t.eq(#h.calls() - before, 3, "leaving costs a read plus the force back to English")
		t.eq(h.machine(), "en")
	end)

	t.test("a session that never leaves English costs nothing to enter", function()
		-- The majority case, and the one the old version paid a process for on
		-- every single `i`.
		h.arm({ machine = "en" })
		h.settle()
		local before = #h.calls()

		h.enter()
		h.settle()
		t.eq(#h.calls() - before, 0, "nothing to change means nothing to spawn")

		h.leave()
		h.settle()
		t.eq(#h.calls() - before, 1, "and leaving costs the read, with no `set` to follow it")
		t.eq(h.machine(), "en")
	end)

	t.test("verify = true buys the old read-before-every-switch behaviour back", function()
		-- The counterweight: without this, "fast" could quietly mean "does not
		-- work", and the option could rot without anyone noticing.
		h.arm({ machine = "vi", verify = true })
		h.settle()
		local before = #h.calls()

		h.enter()
		h.settle()
		t.eq(#h.calls() - before, 2, "verify must read before it writes")
		t.eq(h.machine(), "vi")

		h.leave()
		h.settle()
		t.eq(#h.calls() - before, 4)
		t.eq(h.machine(), "en")
	end)

	t.test("the fast path never skips a pending observation", function()
		-- The one thing the cache must not be allowed to shortcut. A switch made
		-- by hand during Insert exists only on the machine; skipping the read on
		-- the way out would lose it permanently.
		h.arm({ machine = "en" })
		h.settle()
		h.enter()
		h.settle()
		h.set_machine("zh")
		h.leave()
		h.settle()
		t.eq(st().last_layout, "zh", "leaving Insert must always read")
		t.eq(h.machine(), "en")
	end)

	-- ── enable / disable ──────────────────────────────────────────────────────

	t.test("disable stops acting and leaves the machine alone", function()
		h.arm({ machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "precondition")

		require("tongue").disable()
		t.eq(st().attached, false)
		t.eq(h.machine(), "vi", "disable must not switch anything")

		local before = #h.calls()
		h.leave()
		h.enter()
		h.settle()
		t.eq(#h.calls(), before, "a disabled plugin must spawn nothing")
	end)

	t.test("enable resumes, and re-learns rather than trusting a stale cache", function()
		h.arm({ machine = "en" })
		h.settle()
		require("tongue").disable()

		-- Everything could have moved while we were not looking; this is what it
		-- looks like when it does.
		h.set_machine("zh")
		t.eq(require("tongue").enable(), true)
		h.settle()
		t.eq(st().attached, true)
		t.eq(st().last_layout, "zh", "enable must observe, not assume")
		t.eq(h.machine(), "en", "and reconcile to English for Normal mode")
	end)

	t.test("toggle reports the state it left behind", function()
		h.arm({ machine = "en" })
		h.settle()
		t.eq(require("tongue").toggle(), false, "was attached, so it must now be off")
		t.eq(st().attached, false)
		t.eq(require("tongue").toggle(), true)
		h.settle()
		t.eq(st().attached, true)
	end)

	t.test("enable is false, not an error, when there is nothing to drive", function()
		quietly(function()
			require("tongue").setup({ backend = { english = "en" }, notify = false })
		end)
		t.eq(st().enabled, false)
		t.eq(require("tongue").enable(), false)
		t.eq(require("tongue").toggle(), false)
	end)

	t.test("sync re-reads even when nothing in Neovim moved", function()
		h.arm({ machine = "en" })
		h.settle()
		-- A global hotkey pressed in Normal mode: no mode change, no focus event,
		-- nothing for the plugin to react to. `sync` is the way out.
		h.set_machine("zh")
		local before = #h.calls()
		require("tongue").sync()
		h.settle()
		t.ok(#h.calls() > before, "sync must actually spawn something")
		t.eq(h.machine(), "en", "and put Normal mode back into English")
	end)

	-- ── the statusline surface ────────────────────────────────────────────────

	t.test("token() is the intent, and it is correct before the process returns", function()
		h.arm({ machine = "vi", delay = 60 })
		h.settle()
		local tongue = require("tongue")
		t.eq(tongue.token(), "en", "Normal mode wants English")
		h.enter()
		-- Deliberately NOT settled: the whole point is that a statusline can be
		-- right immediately rather than 200 ms late.
		t.eq(tongue.token(), "vi", "Insert wants the remembered layout, at once")
		h.settle()
		t.eq(tongue.layout(), "vi")
		h.leave()
		h.settle()
	end)

	t.test("statusline says nothing while English is in force", function()
		h.arm({ machine = "vi" })
		h.settle()
		local tongue = require("tongue")
		t.eq(tongue.statusline(), "", "English is the boring case; a statusline should stay quiet")
		h.enter()
		t.eq(tongue.statusline(), "vi")
		t.eq(tongue.statusline({ format = "[%s]" }), "[vi]")
		h.leave()
		h.settle()

		tongue.disable()
		t.eq(tongue.token(), nil, "a disabled plugin is driving nothing")
		t.eq(tongue.statusline({ inactive = "-" }), "-")
		tongue.enable()
		h.settle()
	end)

	t.test("TongueChanged fires on a real change and stays silent otherwise", function()
		h.arm({ machine = "vi" })
		h.settle()

		local seen = {}
		local group = vim.api.nvim_create_augroup("tongue_test_events", { clear = true })
		vim.api.nvim_create_autocmd("User", {
			group = group,
			pattern = "TongueChanged",
			callback = function(ev)
				seen[#seen + 1] = ev.data
			end,
		})

		h.enter()
		h.settle()
		t.ok(#seen > 0, "entering Insert must be announced")
		t.eq(seen[#seen].token, "vi")

		local after_enter = #seen
		-- Completion churn crosses no boundary, so nothing changed and nothing
		-- may be announced -- otherwise a statusline component redraws on every
		-- keystroke of a completion.
		h.mode("i", "ix")
		h.mode("ix", "i")
		h.settle()
		t.eq(#seen, after_enter, "sub-mode churn must not fire the event")

		h.leave()
		h.settle()
		t.eq(seen[#seen].token, "en")

		-- Disabling fires too, with a nil token, and that is the contract a
		-- statusline component depends on: without it the component keeps showing
		-- a layout the plugin is no longer driving, forever.
		local before_disable = #seen
		require("tongue").disable()
		t.eq(#seen, before_disable + 1, "disabling must be announced")
		t.eq(seen[#seen].token, nil, "nothing is in force, so there is no token")
		require("tongue").enable()
		h.settle()

		vim.api.nvim_del_augroup_by_id(group)
	end)

	-- ── :Tongue ───────────────────────────────────────────────────────────────

	t.test("plugin/tongue.lua declares :Tongue without loading the plugin", function()
		-- `plugin/` is sourced for every user on every start. If it required the
		-- module, everyone would pay for the plugin's module body -- including the
		-- people who never call setup().
		package.loaded["tongue"] = nil
		package.loaded["tongue.command"] = nil
		load_plugin()
		t.eq(package.loaded["tongue"], nil, "sourcing plugin/ must not load lua/tongue")
		t.ok(vim.fn.exists(":Tongue") == 2, ":Tongue must exist")
	end)

	t.test("completion offers the subcommands, and filters by what is typed", function()
		local cmd = require("tongue.command")
		t.eq(cmd.complete(""), cmd.subcommands)
		t.eq(cmd.complete("t"), { "toggle" })
		t.eq(cmd.complete("e"), { "enable" })
		t.eq(cmd.complete("zz"), {})
	end)

	t.test("the status report survives every state it can be run in", function()
		-- It is the first thing anyone runs when the plugin appears to do nothing,
		-- so a report that throws is worse than no report at all.
		local cmd = require("tongue.command")

		h.arm({ machine = "vi" })
		h.settle()
		local lines = cmd.report()
		t.ok(#lines > 1, "an active plugin must have something to say")
		t.ok(table.concat(lines, "\n"):find("remembers", 1, true) ~= nil, "including the layout it will restore")

		require("tongue").disable()
		t.ok(table.concat(cmd.report(), "\n"):find("DISABLED", 1, true) ~= nil, "and it must say when it is off")

		quietly(function()
			require("tongue").setup({ backend = { english = "en" }, notify = false })
		end)
		local inert = table.concat(cmd.report(), "\n")
		t.ok(inert:find("inactive", 1, true) ~= nil, "an inert plugin says why: " .. inert)
	end)

	t.test("an unknown subcommand is reported, not silently ignored", function()
		h.arm({ machine = "en" })
		h.settle()
		local seen = quietly(function()
			require("tongue.command").run("staus")
		end)
		t.eq(seen[1] and seen[1].level, vim.log.levels.ERROR)
		t.ok(seen[1].msg:find("status", 1, true) ~= nil, "and it must list the real ones: " .. seen[1].msg)
	end)
end
