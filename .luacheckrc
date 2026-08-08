-- luacheck configuration.
--
-- stylua formats; it does not read code. This is the half that does: unused
-- locals, shadowed names, accidental globals. All three have shipped here at
-- least once.

std = "luajit"
cache = true

-- Everything Neovim injects. `vim` is the only one the plugin touches, but the
-- test suite runs under `nvim -l` and reaches for the same globals.
globals = {
	"vim",
}

read_globals = {
	"vim",
}

-- The test runner sets `_G.insert_leaves` in the throwaway editor it drives.
files["tests/wiring_init.lua"] = {
	globals = { "insert_leaves" },
}

exclude_files = {
	".luacheckrc",
}

-- A line long enough to matter is caught by stylua's `column_width`, which is
-- the tool that can actually fix it. Duplicating the rule here only produces
-- warnings nothing will act on.
max_line_length = false
