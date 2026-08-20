--- `exchange`: read and write in ONE backend round trip.
---
--- Why this exists: over a remote backend one round trip dominates everything.
--- Measured 20/08/2026 driving a Windows keyboard from a Mac, one leg cost
--- 656 ms -- of which 293 ms was Windows starting a fresh PowerShell before any
--- work began -- so leaving Insert cost 1318 ms against a 150-400 ms window.
---
--- The pair cannot simply become one call: the read on the way out is what
--- `observe` consumes to learn a layout the user chose mid-Insert, and dropping
--- it makes the plugin permanently blind to that. `exchange` keeps the reading
--- and pays for one trip instead of two.
---
--- It is deliberately NOT used on the way back INTO Insert. That direction
--- restores a remembered layout, and `init.lua` refuses to restore blind -- a
--- failed read there must leave the machine alone rather than guess, and an
--- exchange has already written by the time its answer arrives. Forcing English
--- is safe blind; restoring is not.

local h = require("helpers")

local function st()
	return require("tongue").status()
end

return function(t)
	t.test("leaving Insert costs ONE call, not two", function()
		h.arm({ exchange = true, machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "precondition: Insert restored the layout")

		local before = #h.calls()
		h.leave()
		h.settle()

		t.eq(h.machine(), "en", "Normal mode must still end up in English")
		-- Only the calls THIS boundary emitted. Startup legitimately exchanges
		-- too -- it also forces English with `observe` pending -- so a count over
		-- the whole log would measure the wrong thing.
		local after = vim.list_slice(h.calls(), before + 1)
		t.eq(#after, 1, "leaving Insert must emit exactly one backend call")
		t.eq(after[1], "exchange en", "and it must be the exchange")
	end)

	t.test("the reading exchange returns is still learned", function()
		-- The whole point: one trip, but `observe` still gets its evidence. The
		-- user switched to Chinese mid-Insert; the exchange both reads that and
		-- forces English, and the next `i` must come back to Chinese.
		h.arm({ exchange = true, machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		h.set_machine("zh")
		h.leave()
		h.settle()

		t.eq(h.machine(), "en")
		t.eq(st().last_layout, "zh", "the mid-Insert switch must be remembered")

		h.enter()
		h.settle()
		t.eq(h.machine(), "zh", "and restored")
	end)

	t.test("entering Insert does NOT exchange -- restoring blind is unsafe", function()
		h.arm({ exchange = true, machine = "vi" })
		h.settle()
		h.leave() -- make sure `observe` is pending so the fast path is unavailable
		h.settle()

		local before = #h.calls()
		h.enter()
		h.settle()
		local after = vim.list_slice(h.calls(), before + 1)
		for _, line in ipairs(after) do
			t.ok(line:sub(1, 8) ~= "exchange", "restore must not use exchange, got: " .. line)
		end
	end)

	t.test("a backend without exchange behaves exactly as before", function()
		h.arm({ machine = "vi" }) -- no exchange
		h.settle()
		h.enter()
		h.settle()
		local before = #h.calls()
		h.leave()
		h.settle()

		t.eq(h.machine(), "en")
		t.eq(h.count("exchange"), 0, "no exchange may be emitted")
		local after = vim.list_slice(h.calls(), before + 1)
		t.ok(#after >= 2, "the old path still reads then writes, got " .. #after)
	end)

	t.test("an exchange that fails outright is not believed", function()
		-- A write that exits 0, prints nothing and changes nothing is invisible
		-- to `exchange` for exactly the reason it is invisible to `get`+`set` --
		-- see the FAKE_IM_SET_IGNORE note in the fixture; `:checkhealth` is what
		-- catches that shape, by looking at the machine. What must NOT happen is
		-- believing an exchange that failed loudly.
		h.arm({ exchange = true, machine = "vi" })
		h.settle()
		h.enter()
		h.settle()
		vim.env.FAKE_IM_FAIL = "1"
		h.leave()
		h.settle()
		vim.env.FAKE_IM_FAIL = nil

		t.eq(st().applied, nil, "a failed exchange must not be recorded as applied")
	end)

	t.test("validate rejects a malformed exchange", function()
		local backend = require("tongue.backend")
		local base = { english = "en", get = { "x" }, set = { "x" } }

		local ok = backend.validate(vim.tbl_extend("force", {}, base))
		t.ok(ok, "exchange is optional")

		local b1 = backend.validate(vim.tbl_extend("force", {}, base, { exchange = "nope" }))
		t.eq(b1, nil, "a string is not a command list")

		local b2 = backend.validate(vim.tbl_extend("force", {}, base, { exchange = {} }))
		t.eq(b2, nil, "an empty list is not a command")

		local b3 = backend.validate(vim.tbl_extend("force", {}, base, { exchange = { "x", 1 } }))
		t.eq(b3, nil, "a non-string element is not allowed")

		local b4 = backend.validate(vim.tbl_extend("force", {}, base, { exchange = { "x" } }))
		t.ok(b4, "a well-formed exchange is accepted")
	end)
end
