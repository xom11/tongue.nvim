--- Test runner.  `nvim --headless --clean -u NONE -l tests/run.lua`
---
--- No busted, no plenary, no luarocks: the things worth testing here are an
--- async state machine and real Neovim mode transitions, so the only runtime
--- that proves anything is Neovim itself.

-- `:p` matters: run as `nvim -l tests/run.lua` the source is relative, and a
-- relative root silently fails to put the plugin on the runtimepath.
local src = debug.getinfo(1, "S").source:sub(2)
local here = vim.fn.fnamemodify(src, ":p:h") .. "/"
local root = vim.fn.fnamemodify(here, ":h:h")

vim.opt.rtp:prepend(root)
-- Neovim's Lua loader only looks under `<rtp>/lua`, so putting `tests/` on the
-- runtimepath would not make the specs requirable. Extend package.path instead.
package.path = here .. "?.lua;" .. package.path

-- Auto-detection bails out under SSH. Every spec passes an explicit backend so
-- this should not matter -- but a suite that can pass while testing nothing is
-- worse than no suite, and that is exactly how this one would fail.
vim.env.SSH_TTY = nil

local passed, failed = 0, 0
local current = "?"

local t = {}

function t.test(name, fn)
	current = name
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write(("  ok    %s\n"):format(name))
	else
		failed = failed + 1
		io.write(("  FAIL  %s\n        %s\n"):format(name, tostring(err)))
	end
end

local function show(v)
	if type(v) == "table" then
		return table.concat(vim.tbl_map(tostring, v), " | ")
	end
	return tostring(v)
end

function t.eq(got, want, what)
	if type(got) == "table" and type(want) == "table" then
		if not vim.deep_equal(got, want) then
			error(("%s\n          got:  %s\n          want: %s"):format(what or "mismatch", show(got), show(want)), 2)
		end
		return
	end
	if got ~= want then
		error(("%s\n          got:  %s\n          want: %s"):format(what or "mismatch", show(got), show(want)), 2)
	end
end

function t.ok(cond, what)
	if not cond then
		error(what or "expected truthy", 2)
	end
end

for _, spec in ipairs({ "mode", "sanitize", "state", "wiring" }) do
	io.write(spec .. "\n")
	require(spec .. "_spec")(t)
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
