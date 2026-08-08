--- The fixture is load-bearing, so it gets tested too.
---
--- `fake-im` must answer with the state as of when it STARTED, not as of when
--- it finishes. That is how a real CLI behaves -- it asks the OS immediately
--- and returns later -- and it is the only reason `state_spec` can construct a
--- reading that is older than a mode change.
---
--- Without this test, quietly reverting the fixture to sleep-then-read leaves
--- the whole suite green while structurally disabling the test that guards the
--- worst bug this plugin ever had. Verified: that mutation is invisible to
--- every other test in the suite.

local h = require("helpers")

return function(t)
	t.test("fake-im reports the state from when it started, not when it finished", function()
		local tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		local state = tmp .. "/state"
		vim.fn.writefile({ "en" }, state)

		local env = {
			FAKE_IM_STATE = state,
			FAKE_IM_DELAY_MS = "150",
		}

		local out, done = nil, false
		vim.system({ h.fake_im }, { text = true, env = env }, function(o)
			out = o
			done = true
		end)

		-- Let it get past the fork and reach its snapshot, then move the state
		-- underneath it.
		vim.wait(50)
		vim.fn.writefile({ "vi" }, state)

		t.ok(
			vim.wait(3000, function()
				return done
			end),
			"the fixture must finish"
		)

		t.eq(((out.stdout or ""):gsub("%s+$", "")), "en", "a snapshot taken at start, not a fresh read at the end")
	end)

	t.test("fake-im forks its sleep, which is the hard case for timeouts", function()
		-- `vim.system{timeout=}` kills the direct child but waits for the stdout
		-- pipe to close, and a forked grandchild holds it open. If this fixture
		-- ever `exec`s instead, the timeout test in state_spec stops proving that
		-- the plugin's own deadline works, because vim.system's would suffice.
		-- Comments only, stripped: the file explains the exec/fork distinction in
		-- prose, so grepping the whole thing finds the word it is warning about.
		local code = {}
		for _, line in ipairs(vim.fn.readfile(h.fake_im)) do
			if not line:match("^%s*#") then
				code[#code + 1] = line
			end
		end
		local src = table.concat(code, "\n")
		t.ok(src:find("sleep ") ~= nil, "the fixture must actually sleep")
		t.eq(src:find("exec%s+sleep"), nil, "exec would make the grandchild disappear")
	end)
end
