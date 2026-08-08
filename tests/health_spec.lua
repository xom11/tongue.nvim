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
	local function record(level)
		return function(msg, advice)
			seen[#seen + 1] = { level = level, msg = tostring(msg), advice = advice }
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
		-- `unknown` is a legitimate answer that sanitize maps to English, and it
		-- is deliberately absent from `tokens`. Calling it an error accuses the
		-- user of installing the wrong program while everything works.
		h.arm({ machine = "unknown" })
		h.settle()
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
