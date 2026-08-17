--- Test plumbing: a controllable fake backend, plus the waiting discipline the
--- async core needs.

local uv = vim.uv or vim.loop

local M = {}

local src = debug.getinfo(1, "S").source:sub(2)
M.fake_im = vim.fn.fnamemodify(src, ":p:h") .. "/fixtures/fake-im"

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local seq = 0

--- Write the machine's input method directly, behind the plugin's back.
--- This is what "the user hit their global hotkey" looks like from here.
function M.set_machine(token)
	vim.fn.writefile({ token }, M.state)
end

function M.machine()
	local ok, lines = pcall(vim.fn.readfile, M.state)
	if not ok then
		return nil
	end
	return (table.concat(lines, "\n"):gsub("%s+$", ""))
end

--- Every backend invocation, in order: "get" / "set <token>".
--- Asserting on the sequence, not just the end state, is the point -- the bugs
--- this suite guards against all produce a correct-looking end state some of
--- the time.
function M.calls()
	local ok, lines = pcall(vim.fn.readfile, M.log)
	if not ok then
		return {}
	end
	return lines
end

function M.count(kind)
	local n = 0
	for _, line in ipairs(M.calls()) do
		if line == kind or line:sub(1, #kind + 1) == kind .. " " then
			n = n + 1
		end
	end
	return n
end

--- Fresh fake backend + `setup()`.
---@param o table? machine, delay (ms), fail, notify
function M.arm(o)
	o = o or {}
	seq = seq + 1
	M.state = ("%s/state%d"):format(tmp, seq)
	M.log = ("%s/log%d"):format(tmp, seq)

	M.set_machine(o.machine or "en")
	vim.fn.writefile({}, M.log)

	vim.env.FAKE_IM_STATE = M.state
	vim.env.FAKE_IM_LOG = M.log
	vim.env.FAKE_IM_DELAY_MS = tostring(o.delay or 0)
	vim.env.FAKE_IM_FAIL = o.fail and "1" or nil
	vim.env.FAKE_IM_SET_NOISE = o.set_noise or nil
	vim.env.FAKE_IM_SET_EXIT = o.set_exit and tostring(o.set_exit) or nil
	M.marker = ("%s/snap%d"):format(tmp, seq)
	vim.fn.writefile({}, M.marker)
	vim.env.FAKE_IM_SNAP_MARKER = M.marker

	M.backend = {
		english = "en",
		get = { M.fake_im },
		set = { M.fake_im },
		unknown = "unknown",
		tokens = { "en", "vi", "zh" },
	}

	require("tongue").setup({
		backend = M.backend,
		notify = o.notify or false,
		timeout = o.timeout or 3000,
		verify = o.verify or false,
		restore_on_unfocus = o.unfocus or false,
	})
end

--- Drive one mode transition.
---
--- Real keystrokes are deliberately NOT used here, and the reason is measured:
--- under `nvim -l` there is no main loop, so `feedkeys(..., "x")` enters and
--- leaves Insert in the same call (`n:i` immediately followed by `i:n`) and
--- `startinsert` does nothing at all; under `nvim -c` a blocking Lua script
--- starves the loop that would consume `nvim_input`, so no key is ever seen.
--- Either way a test written with keys would drive nothing and pass.
---
--- The state machine consumes a sequence of (old, new) transitions and nothing
--- else, so feeding it that sequence is faithful. That real transitions actually
--- reach it -- including `<C-c>`, which fires no InsertLeave -- is a separate
--- claim, proved against a real editor in `wiring_spec.lua`.
function M.mode(old, new)
	require("tongue")._on_mode(old, new)
end

function M.enter()
	M.mode("n", "i")
end

function M.leave()
	M.mode("i", "n")
end

--- How many readings the fixture has snapshotted so far.
local function snaps()
	local st = uv.fs_stat(M.marker or "")
	return st and st.size or 0
end

--- Block until the in-flight `get` has taken its snapshot, and not a moment
--- longer.
---
--- The cases that matter here all turn on writing the machine INSIDE the read
--- window: too early and the reading comes back fresh, so the test proves
--- nothing and passes against the very bug it is named for. That timing used to
--- be guessed -- `vim.wait(25)`, `vim.wait(50)` -- which is a race with a shell
--- script's startup, and it lost the first time the suite got heavier.
---@param timeout integer?
function M.await_snapshot(timeout)
	local before = snaps()
	local t0 = uv.hrtime()
	while (uv.hrtime() - t0) / 1e6 < (timeout or 3000) do
		if snaps() > before then
			return true
		end
		vim.wait(5)
	end
	error("the fixture never reached its snapshot", 2)
end

--- Wait until no cycle is in flight AND none starts for a further 100 ms.
---
--- `busy` alone is not enough: `finish` can re-enter `cycle` immediately when the
--- intent moved while a command was running, and the whole point of several
--- tests is what happens on that second lap.
---
--- Times out by THROWING, not by returning false. The old version returned a
--- boolean that exactly one of forty-odd call sites checked, so a wedged cycle
--- -- which is precisely the failure mode the hard cases here are about -- left
--- every other test asserting against whatever stale state was lying around.
--- Since `en` is both the startup state and the most common expectation, a wedge
--- usually produced a green run.
---@param timeout integer?
---@param opts table? `{ soft = true }` to get the boolean back instead
function M.settle(timeout, opts)
	timeout = timeout or 5000
	local tongue = require("tongue")
	local t0 = uv.hrtime()
	local quiet = nil
	while (uv.hrtime() - t0) / 1e6 < timeout do
		vim.wait(10)
		if tongue.status().busy then
			quiet = nil
		else
			quiet = quiet or uv.hrtime()
			if (uv.hrtime() - quiet) / 1e6 >= 100 then
				return true
			end
		end
	end
	if opts and opts.soft then
		return false
	end
	error(
		("settle timed out after %d ms -- a cycle never finished (busy=%s)"):format(
			timeout,
			tostring(tongue.status().busy)
		),
		2
	)
end

return M
