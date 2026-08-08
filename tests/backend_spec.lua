--- `backend.resolve` -- the only part of the plugin that asks what machine it is.
---
--- Every case here drives a FAKE prober, which is the whole reason `resolve`
--- takes one. Left to ask the real OS, this file could only ever test the
--- machine it happens to run on: the Linux chain and the Windows chain would be
--- untested forever, and untested-forever is exactly how the `im-select.exe`
--- branch shipped broken once already.

local backend = require("tongue.backend")
local presets = require("tongue.presets")

--- A prober that says `sysname` is the OS and only `...` are on $PATH.
local function probe(sysname, ...)
	local have = {}
	for _, name in ipairs({ ... }) do
		have[name] = true
	end
	return {
		sysname = sysname,
		executable = function(name)
			return have[name] == true
		end,
	}
end

--- Run `fn` with $SSH_TTY set, then put the environment back.
local function under_ssh(fn)
	local saved = vim.env.SSH_TTY
	vim.env.SSH_TTY = "/dev/ttys000"
	local ok, err = pcall(fn)
	vim.env.SSH_TTY = saved
	if not ok then
		error(err, 0)
	end
end

return function(t)
	-- ── the candidate chain ───────────────────────────────────────────────────

	t.test("tongue wins on macOS even when the others are installed", function()
		-- The ordering is the promise: adding macism must not change what a
		-- machine with `tongue` already does. macism cannot see an external IME
		-- at all, so silently preferring it would be a downgrade.
		local b, why = backend.resolve({}, probe("Darwin", "tongue", "macism", "im-select"))
		t.eq(why, "tongue")
		t.eq(b.english, "en")
	end)

	t.test("macOS falls through to macism when tongue is absent", function()
		local b, why = backend.resolve({}, probe("Darwin", "macism", "im-select"))
		t.eq(why, "macism")
		t.eq(b.get, { "macism" })
	end)

	t.test("macOS falls through to im-select last", function()
		local b, why = backend.resolve({}, probe("Darwin", "im-select"))
		t.eq(why, "im-select")
		t.eq(b.get, { "im-select" })
	end)

	t.test("Linux resolves fcitx5-remote", function()
		local b, why = backend.resolve({}, probe("Linux", "fcitx5-remote"))
		t.eq(why, "fcitx5-remote")
		t.eq(b.english, "keyboard-us")
	end)

	t.test("Windows resolves im-select.exe", function()
		-- This machine is macOS. The binary cannot be run from here, but the
		-- chain that picks it can -- and picking it is the part that regressed
		-- last time.
		local b, why = backend.resolve({}, probe("Windows_NT", "im-select.exe"))
		t.eq(why, "im-select.exe")
		t.eq(b.english, "1033")
	end)

	t.test("a bare machine resolves to nothing, and says which OS", function()
		local b, why = backend.resolve({}, probe("Darwin"))
		t.eq(b, nil)
		t.ok(why:find("Darwin", 1, true) ~= nil, "the reason must name the OS: " .. why)
	end)

	t.test("an OS with no chain at all is inert, not an error", function()
		local b, why = backend.resolve({}, probe("OpenBSD", "tongue"))
		t.eq(b, nil)
		t.ok(why:find("OpenBSD", 1, true) ~= nil, "the reason must name the OS: " .. why)
	end)

	-- ── choosing a preset by name ─────────────────────────────────────────────

	t.test("a preset can be named as a string", function()
		-- Detection is skipped entirely: the user said which one they want, and
		-- the binary may well live somewhere `executable()` cannot see.
		local b, why = backend.resolve({ backend = "macism" }, probe("Darwin"))
		t.eq(b.get, { "macism" })
		t.ok(why:find("macism", 1, true) ~= nil, "the reason must name the preset: " .. tostring(why))
	end)

	t.test("preset names tolerate the punctuation of the binary", function()
		-- Nobody types Lua identifiers into their config; they type the name of
		-- the program they installed.
		for _, name in ipairs({ "im_select", "im-select" }) do
			local b = backend.resolve({ backend = name }, probe("Darwin"))
			t.eq(b and b.get, { "im-select" }, ("%q must resolve"):format(name))
		end
		local b = backend.resolve({ backend = "im-select.exe" }, probe("Darwin"))
		t.eq(b and b.get, { "im-select.exe" })
	end)

	t.test("an unknown preset name is an error that lists the real ones", function()
		-- Never fall back to auto-detection here: the user was explicit, and a
		-- typo that silently resolves to something else is unpredictable config.
		local b, err = backend.resolve({ backend = "im-selct" }, probe("Darwin", "tongue"))
		t.eq(b, nil)
		t.ok(err:find("macism", 1, true) ~= nil, "the error must list valid names: " .. err)
		t.ok(err:find("tongue", 1, true) ~= nil, "the error must list valid names: " .. err)
	end)

	-- ── overriding the English token ──────────────────────────────────────────

	t.test("english overrides an auto-detected backend", function()
		-- The common case by far: macism is already installed and the only thing
		-- wrong is that this machine types on US, not ABC.
		local b = backend.resolve({ english = "com.apple.keylayout.US" }, probe("Darwin", "macism"))
		t.eq(b.english, "com.apple.keylayout.US")
		t.eq(b.get, { "macism" })
	end)

	t.test("english overrides a named preset", function()
		local b = backend.resolve({ backend = "im-select", english = "com.apple.keylayout.US" }, probe("Darwin"))
		t.eq(b.english, "com.apple.keylayout.US")
	end)

	t.test("overriding english does not scribble on the shared preset", function()
		-- The one case that separates a correct implementation from one that
		-- poisons the module table for the rest of the session: the SECOND
		-- setup() would inherit the first one's override.
		backend.resolve({ english = "com.apple.keylayout.US" }, probe("Darwin", "macism"))
		t.eq(presets.macism.english, "com.apple.keylayout.ABC", "presets.macism was mutated")

		local b = backend.resolve({}, probe("Darwin", "macism"))
		t.eq(b.english, "com.apple.keylayout.ABC", "a later resolve inherited the override")
	end)

	t.test("english is validated against the backend that receives it", function()
		-- `tongue` speaks in modes, not input-source IDs. Accepting this would
		-- make `sanitize` discard every reading for the rest of the session --
		-- the plugin alive, and useless.
		local b, err = backend.resolve({ backend = "tongue", english = "com.apple.keylayout.US" }, probe("Darwin"))
		t.eq(b, nil)
		t.eq(err, "backend.tokens must contain backend.english")
	end)

	t.test("a malformed english is rejected", function()
		for _, bad in ipairs({ 42, "", true }) do
			local b, err = backend.resolve({ english = bad }, probe("Darwin", "macism"))
			t.eq(b, nil, ("should reject english = %s"):format(vim.inspect(bad)))
			t.ok(err:find("english", 1, true) ~= nil, "the error must name the offending key: " .. err)
		end
	end)

	t.test("a config bug is flagged as one; a bare machine is not", function()
		-- `setup()` has to tell "you configured this wrong" -- say so, loudly --
		-- apart from "there is nothing to drive here" -- stay quiet. Inert is a
		-- legitimate outcome on a machine with no IME tool and over SSH; a config
		-- bug reported the same way is one that never gets noticed.
		local _, _, fatal = backend.resolve({ english = 42 }, probe("Darwin"))
		t.eq(fatal, true, "a malformed english is a config bug on any machine")

		_, _, fatal = backend.resolve({ backend = "im-selct" }, probe("Darwin"))
		t.eq(fatal, true, "so is a preset name that does not exist")

		_, _, fatal = backend.resolve({ backend = "tongue", english = "us" }, probe("Darwin"))
		t.eq(fatal, true, "so is an english the chosen backend cannot accept")

		_, _, fatal = backend.resolve({}, probe("Darwin"))
		t.eq(fatal, nil, "a machine with no tool is inert, not misconfigured")

		under_ssh(function()
			local _, _, f = backend.resolve({}, probe("Darwin", "tongue"))
			t.eq(f, nil, "and neither is SSH")
		end)
	end)

	t.test("a malformed english is caught before the machine is consulted", function()
		-- Otherwise it is silently outranked by "no backend here": the user typo'd
		-- their config and hears about their laptop's package list instead. The
		-- shape of the config is knowable without asking the OS anything.
		local b, err, fatal = backend.resolve({ english = 42 }, probe("Haiku"))
		t.eq(b, nil)
		t.eq(err, "english must be a non-empty string")
		t.eq(fatal, true)
	end)

	-- ── SSH ───────────────────────────────────────────────────────────────────

	t.test("SSH stops auto-detection but never an explicit choice", function()
		under_ssh(function()
			local b, why = backend.resolve({}, probe("Darwin", "tongue"))
			t.eq(b, nil)
			t.ok(why:find("SSH", 1, true) ~= nil, "the reason must say SSH: " .. why)

			-- Both explicit forms outrank it. The user said so, and second-guessing
			-- an explicit setting is how config stops being predictable.
			t.ok(backend.resolve({ backend = "macism" }, probe("Darwin")) ~= nil, "a named preset must win")
			t.ok(
				backend.resolve({ backend = presets.fcitx5 }, probe("Darwin")) ~= nil,
				"a hand-written backend must win"
			)
		end)
	end)

	-- ── the contract ──────────────────────────────────────────────────────────

	t.test("a hand-written backend still resolves as `explicit`", function()
		local b, why = backend.resolve({ backend = { english = "x", get = { "p" }, set = { "p" } } }, probe("Darwin"))
		t.eq(why, "explicit")
		t.eq(b.english, "x")
	end)

	t.test("note is a documented key, and must be a string", function()
		-- It carries no control meaning -- `health` prints it and nothing else
		-- reads it -- but a number here would blow up vim.health at the exact
		-- moment the user is trying to diagnose something.
		local base = { english = "x", get = { "p" }, set = { "p" } }
		local b, err = backend.validate(vim.tbl_extend("force", base, { note = 7 }))
		t.eq(b, nil)
		t.eq(err, "backend.note must be a string or nil")
		t.ok(backend.validate(vim.tbl_extend("force", base, { note = "hi" })) ~= nil, "a string note must pass")
	end)

	t.test("every built-in preset satisfies the contract", function()
		-- Presets used to be trusted without validation. They are data, and data
		-- gets edited: this is what makes a broken one fail here rather than on
		-- somebody's machine.
		for name, b in pairs(presets) do
			local ok, err = backend.validate(b)
			t.ok(ok ~= nil, ("preset %q is malformed: %s"):format(name, tostring(err)))
		end
	end)

	t.test("the input-source presets warn about external IMEs", function()
		-- The price of auto-detecting them. Without this the plugin can silently
		-- pick a backend that cannot see the difference it exists to enforce.
		for _, name in ipairs({ "macism", "im_select", "im_select_exe" }) do
			local note = presets[name] and presets[name].note
			t.ok(type(note) == "string" and note ~= "", ("preset %q must carry a note"):format(name))
		end
		t.eq(presets.tongue.note, nil, "tongue moves both levers; it needs no warning")
	end)
end
