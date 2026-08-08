--- A linter with no dependencies.  `nvim --headless --clean -u NONE -l tests/lint.lua`
---
--- `.luacheckrc` is here for anyone who has luacheck, but a check that only runs
--- where somebody remembered to install a luarocks package is a check that does
--- not run. Neovim ships LuaJIT, LuaJIT dumps its own bytecode, and a global read
--- or write is one opcode -- so the two mistakes that actually happen in a plugin
--- this size are catchable with nothing installed at all:
---
---   * an accidental global. A dropped `local` turns a variable into shared
---     editor state, and in a plugin that keeps its whole state machine in
---     upvalues that is a bug you find months later.
---   * a typo'd global read. `vim.lop.start` is caught by the language server;
---     `vim_loop` is caught by nothing and simply reads as `nil` at runtime.
---
--- It also compiles every file, which is the cheapest smoke test there is and
--- the reason a syntax error never reaches the suite.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

--- Globals any file here may read.
---
--- Deliberately short. Neovim's Lua is not a general-purpose runtime and this
--- plugin reaches for almost none of it; every name added here should be one
--- somebody had a reason to use.
local ALLOWED = {}
for _, name in ipairs({
	-- Lua 5.1 / LuaJIT standard library
	"assert",
	"collectgarbage",
	"debug",
	"error",
	"getmetatable",
	"io",
	"ipairs",
	"jit",
	"loadfile",
	"loadstring",
	"math",
	"next",
	"os",
	"package",
	"pairs",
	"pcall",
	"print",
	"rawequal",
	"rawget",
	"rawset",
	"require",
	"select",
	"setmetatable",
	"string",
	"table",
	"tonumber",
	"tostring",
	"type",
	"unpack",
	"xpcall",
	-- Neovim
	"vim",
}) do
	ALLOWED[name] = true
end

--- Per-file exceptions, for reads and writes alike.
---
--- One entry, and it earns its place: the throwaway editor `wiring_spec` drives
--- has to publish a counter somewhere its `--remote-expr` can reach, and `_G` is
--- that somewhere. Anywhere else, touching `_G` is the bug this file looks for.
local EXTRA = {
	["tests/wiring_init.lua"] = { _G = true, insert_leaves = true },
}

local bc = require("jit.bc")

--- Lines look like `0002    GSET     0   0      ; "oops_global"`.
---
--- The quotes are load-bearing: the first version of this pattern was written
--- without them, matched nothing at all, and reported a clean repo while the
--- probe it was tested against sat right there failing to be detected. Hence
--- `selftest` below.
local OPCODE = '(G[GS]ET)%s+%d+%s+%d+%s*;%s*"([%w_]+)"'

--- `jit.bc.dump` writes through `out:write(...)` and calls `out:flush()`; this
--- is the smallest thing that satisfies both. `true` for `all` recurses into
--- nested prototypes, which is the whole point -- a stray global inside a
--- callback is the common case, and the outer chunk's bytecode never mentions it.
local function bytecode(fn)
	local buf = {}
	bc.dump(fn, {
		write = function(_, ...)
			for i = 1, select("#", ...) do
				buf[#buf + 1] = tostring((select(i, ...)))
			end
		end,
		flush = function() end,
	}, true)
	return table.concat(buf)
end

--- Every global this chunk touches, as `{ ["GSET"..name] = true, ... }`.
local function globals(fn)
	local found = {}
	for op, name in bytecode(fn):gmatch(OPCODE) do
		found[op .. name] = true
	end
	return found
end

--- Prove the detector still detects. Cheap, and the alternative is a green
--- report that means nothing -- which is exactly what this file did once.
local function selftest()
	local probe = assert(loadstring("local function f() oops_g = 1 return unknown_g.x end return f"))
	local found = globals(probe)
	assert(found["GSEToops_g"], "lint.lua no longer sees a global WRITE -- did the bytecode format change?")
	assert(found["GGETunknown_g"], "lint.lua no longer sees a global READ -- did the bytecode format change?")
end

selftest()

local files = {}
for _, dir in ipairs({ "lua", "plugin", "tests" }) do
	for _, path in ipairs(vim.fn.globpath(root .. "/" .. dir, "**/*.lua", false, true)) do
		files[#files + 1] = path
	end
end
table.sort(files)

local problems = 0
local function fail(rel, msg)
	problems = problems + 1
	io.write(("  FAIL  %s: %s\n"):format(rel, msg))
end

for _, path in ipairs(files) do
	local rel = path:sub(#root + 2)
	local fn, err = loadfile(path)
	if not fn then
		fail(rel, "does not compile: " .. tostring(err))
	else
		local extra = EXTRA[rel] or {}
		-- Sorted: `pairs` order is a hash order, and a linter whose output
		-- reshuffles between runs is one nobody can diff.
		local keys = vim.tbl_keys(globals(fn))
		table.sort(keys)
		for _, key in ipairs(keys) do
			local op, name = key:sub(1, 4), key:sub(5)
			if not extra[name] then
				if op == "GSET" then
					fail(rel, ("assigns to the global %q -- missing a `local`?"):format(name))
				elseif not ALLOWED[name] then
					fail(rel, ("reads the unknown global %q"):format(name))
				end
			end
		end
	end
end

io.write(("\n%d files linted, %d problems\n"):format(#files, problems))
os.exit(problems == 0 and 0 or 1)
