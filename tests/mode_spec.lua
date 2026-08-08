local typing = require("tongue.mode").typing

return function(t)
	-- The full table from `:help mode()`. Several of these cannot be reached
	-- reliably from a headless test, which is exactly why the predicate is pure.
	local TYPES = {
		-- produce text
		["i"] = true, -- Insert
		["ic"] = true, -- Insert, completion menu
		["ix"] = true, -- Insert, CTRL-X completion
		["R"] = true, -- Replace
		["Rc"] = true,
		["Rx"] = true,
		["Rv"] = true, -- virtual replace
		["Rvc"] = true,
		["t"] = true, -- terminal-insert
		["niI"] = true, -- i_CTRL-O from Insert
		["niR"] = true, -- i_CTRL-O from Replace
		["niV"] = true, -- i_CTRL-O from virtual Replace

		-- do not
		["n"] = false,
		["no"] = false, -- operator-pending
		["nov"] = false,
		["noV"] = false,
		["nt"] = false, -- terminal-NORMAL: starts with n, must not read as `t`
		["ntT"] = false,
		["v"] = false,
		["V"] = false,
		["s"] = false, -- Select: first printable key moves it to Insert anyway
		["S"] = false,
		["c"] = false, -- command-line
		["cv"] = false,
		["r"] = false, -- hit-enter prompt
		["rm"] = false,
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
