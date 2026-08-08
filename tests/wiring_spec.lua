--- Does a real keystroke actually reach the plugin?
---
--- `state_spec.lua` proves the state machine is right given a sequence of mode
--- transitions. It cannot prove that the transitions arrive, and that is a
--- separate claim with a sharp edge: `<C-c>` leaves Insert mode without firing
--- `InsertLeave` at all. An implementation built on InsertEnter/InsertLeave
--- passes every state test and still strands you in Vietnamese in Normal mode.
---
--- Neither `nvim -l` nor `nvim -c` can hold Insert mode from inside a blocking
--- Lua script -- measured, both ways -- so this drives a second, real Neovim
--- over `--listen` / `--remote-send`.

local uv = vim.uv or vim.loop

local src = debug.getinfo(1, "S").source:sub(2)
local here = vim.fn.fnamemodify(src, ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

local function wait_until(fn, timeout)
	local t0 = uv.hrtime()
	while (uv.hrtime() - t0) / 1e6 < (timeout or 5000) do
		if fn() then
			return true
		end
		vim.wait(20)
	end
	return false
end

return function(t)
	local tmp = vim.fn.tempname()
	vim.fn.mkdir(tmp, "p")

	local sock = tmp .. "/sock"
	local state = tmp .. "/state"
	local log = tmp .. "/log"

	vim.fn.writefile({ "vi" }, state)
	vim.fn.writefile({}, log)

	vim.env.TONGUE_ROOT = root
	vim.env.FAKE_IM = here .. "/fixtures/fake-im"
	vim.env.FAKE_IM_STATE = state
	vim.env.FAKE_IM_LOG = log
	vim.env.FAKE_IM_DELAY_MS = "0"
	vim.env.FAKE_IM_FAIL = nil

	local function machine()
		local ok, lines = pcall(vim.fn.readfile, state)
		if not ok then
			return nil
		end
		return (table.concat(lines, "\n"):gsub("%s+$", ""))
	end

	local server = vim.system({
		vim.v.progpath,
		"--headless",
		"-n", -- no swapfile
		"-i",
		"NONE", -- no shada
		"-u",
		here .. "/wiring_init.lua",
		"--listen",
		sock,
	}, { text = true })

	local function send(keys)
		return vim.system({ vim.v.progpath, "--server", sock, "--remote-send", keys }, { text = true }):wait(5000)
	end

	--- Evaluate an expression in the throwaway editor, or throw.
	---
	--- The throw is the point. This used to hand back `""` for a dead server, an
	--- unreachable socket or an expression that errored -- and the one assertion
	--- this whole file exists to make compares two of these values to each other.
	--- With both empty it passed, agreeing with itself, while proving nothing
	--- about `<C-c>` or about why this plugin listens to ModeChanged at all.
	local function expr(e)
		local out = vim.system({ vim.v.progpath, "--server", sock, "--remote-expr", e }, { text = true }):wait(5000)
		local value = (out.stdout or ""):gsub("%s+$", "")
		if out.code ~= 0 or value == "" then
			error(
				("--remote-expr %s failed (code=%s, stderr=%s)"):format(e, tostring(out.code), tostring(out.stderr)),
				2
			)
		end
		return value
	end

	local function shutdown()
		pcall(function()
			vim.system({ vim.v.progpath, "--server", sock, "--remote-send", "<C-\\><C-N>:qa!<CR>" }, {}):wait(2000)
		end)
		vim.wait(300)
		pcall(function()
			server:kill(15)
		end)
	end

	local up = wait_until(function()
		return uv.fs_stat(sock) ~= nil
	end, 10000)

	if not up then
		shutdown()
		t.test("real editor: server starts", function()
			error("the throwaway Neovim never created its socket at " .. sock)
		end)
		return
	end

	t.test("real editor: startup forces English", function()
		t.ok(
			wait_until(function()
				return machine() == "en"
			end),
			("startup should have forced English; machine=%s"):format(tostring(machine()))
		)
	end)

	t.test("real editor: a real `i` restores the layout", function()
		send("i")
		t.ok(
			wait_until(function()
				return machine() == "vi"
			end),
			("a real keystroke should have restored Vietnamese; machine=%s"):format(tostring(machine()))
		)
	end)

	t.test("real editor: <C-c> forces English even though InsertLeave never fires", function()
		local before = expr('luaeval("_G.insert_leaves")')
		t.ok(tonumber(before) ~= nil, "the counter must be a real number, not a failed query: " .. before)
		send("<C-c>")
		t.ok(
			wait_until(function()
				return machine() == "en"
			end),
			("<C-c> should have forced English; machine=%s"):format(tostring(machine()))
		)

		local after = expr('luaeval("_G.insert_leaves")')
		t.eq(
			after,
			before,
			"InsertLeave must NOT have fired for <C-c> -- this is exactly why the plugin listens to ModeChanged"
		)
	end)

	t.test("real editor: <Esc> works too", function()
		send("i")
		t.ok(
			wait_until(function()
				return machine() == "vi"
			end),
			"second entry into Insert should restore"
		)
		send("<Esc>")
		t.ok(
			wait_until(function()
				return machine() == "en"
			end),
			"<Esc> should force English"
		)
	end)

	shutdown()
end
