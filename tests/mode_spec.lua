local typing = require("tongue.mode").typing

return function(t)
	-- The full table from `:help mode()`. Several of these cannot be reached
	-- reliably from a headless test, which is exactly why the predicate is pure.
	-- EVERY row, this time. The previous version said "the full table" and listed
	-- 27 of the 37, quietly omitting the blockwise modes (which are a literal
	-- CTRL-V / CTRL-S byte, not the letters), the Select-mode `v_CTRL-O` variants,
	-- and the overstrike command-line modes 0.11 added. A predicate this small is
	-- only worth having if the table it is checked against is the real one.
	local CTRL_V, CTRL_S = "\22", "\19"

	local TYPES = {
		-- produce text
		["i"] = true, -- Insert
		["ic"] = true, -- Insert mode completion
		["ix"] = true, -- Insert, CTRL-X completion
		["R"] = true, -- Replace
		["Rc"] = true,
		["Rx"] = true,
		["Rv"] = true, -- virtual replace
		["Rvc"] = true,
		["Rvx"] = true,
		["t"] = true, -- terminal-insert: keys go to the job
		["niI"] = true, -- i_CTRL-O from Insert
		["niR"] = true, -- i_CTRL-O from Replace
		["niV"] = true, -- i_CTRL-O from virtual Replace

		-- do not
		["n"] = false,
		["no"] = false, -- operator-pending
		["nov"] = false,
		["noV"] = false,
		["no" .. CTRL_V] = false,
		["nt"] = false, -- terminal-NORMAL: starts with n, must not read as `t`
		["ntT"] = false,
		["v"] = false,
		["vs"] = false, -- v_CTRL-O from Select
		["V"] = false,
		["Vs"] = false,
		[CTRL_V] = false, -- Visual blockwise
		[CTRL_V .. "s"] = false,
		["s"] = false, -- Select: first printable key moves it to Insert anyway
		["S"] = false,
		[CTRL_S] = false, -- Select blockwise
		["c"] = false, -- command-line
		["ce"] = false, -- Normal Ex mode, gQ
		["cr"] = false, -- command-line overstrike, 0.11+
		["cv"] = false, -- Vim Ex mode, Q
		["cvr"] = false,
		["r"] = false, -- hit-enter prompt
		["rm"] = false, -- the -- more -- prompt
		["r?"] = false, -- a :confirm query
		["!"] = false, -- :!sh
	}

	t.test("typing() classifies every documented mode", function()
		for mode, want in pairs(TYPES) do
			t.eq(typing(mode), want, ("mode %q"):format(mode))
		end
	end)

	t.test("terminal-normal is not typing, terminal-insert is", function()
		t.eq(typing("t"), true, "t")
		t.eq(typing("nt"), false, "nt -- the trap: `nt` contains `t`")
	end)

	t.test("i_CTRL-O stays 'typing' at both ends, so it crosses no boundary", function()
		-- i:niI then niI:i. Both sides true => the handler's `was == now` guard
		-- fires and the backend is never touched. See the `ctrl-o` state test.
		t.eq(typing("i"), typing("niI"), "i vs niI")
	end)

	t.test("completion sub-modes stay 'typing', so churn crosses no boundary", function()
		t.eq(typing("ix"), typing("i"), "ix vs i")
		t.eq(typing("ic"), typing("i"), "ic vs i")
	end)
end
