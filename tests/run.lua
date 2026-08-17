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
--
-- All three, not just `SSH_TTY`: sshd sets `SSH_CONNECTION` and `SSH_CLIENT`
-- too, and a developer machine that happens to carry either one turned nine
-- backend specs red the day the guard learned to read them.
for _, name in ipairs({ "SSH_TTY", "SSH_CONNECTION", "SSH_CLIENT" }) do
	vim.env[name] = nil
end

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

-- Order matters: the cheap pure specs first, so a broken predicate is the first
-- thing you read rather than the last. `wiring` is last because it starts a
-- second Neovim and costs seconds where the others cost milliseconds.
local ALL = { "mode", "sanitize", "backend", "fixture", "state", "unfocus", "api", "health", "wiring" }

--- Which specs to run: every argument after `-l tests/run.lua`, or all of them.
---
--- Two reasons this is worth the eight lines. Locally it turns a 10 s edit loop
--- into a 200 ms one. On Windows it is the difference between a suite that runs
--- and no suite at all: `tests/fixtures/fake-im` is a POSIX shell script, so
--- every spec that drives it fails on ENOENT there -- but `mode`, `sanitize`
--- and `backend` touch nothing but Lua and pass fine.
local want = {}
for _, name in ipairs(vim.v.argv) do
	-- `vim.v.argv` is the WHOLE command line, `nvim --headless -l ...` included.
	-- Only names that are actually specs count; anything else is a flag.
	if vim.tbl_contains(ALL, name) then
		want[#want + 1] = name
	end
end
if #want == 0 then
	want = ALL
end

for _, spec in ipairs(want) do
	io.write(spec .. "\n")
	require(spec .. "_spec")(t)
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
