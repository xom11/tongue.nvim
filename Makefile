.PHONY: test test-pure lint fmt fmt-check doc all

# The whole suite. Needs a POSIX shell for tests/fixtures/fake-im.
test:
	nvim --headless --clean -u NONE -l tests/run.lua

# Just the specs that touch nothing but Lua. ~200 ms instead of ~11 s, and it is
# also all that can run on Windows -- see the `windows` job in CI.
test-pure:
	nvim --headless --clean -u NONE -l tests/run.lua mode sanitize backend

# No luarocks, no luacheck install. See the header of tests/lint.lua.
lint:
	nvim --headless --clean -u NONE -l tests/lint.lua

fmt:
	stylua lua plugin tests

fmt-check:
	stylua --check lua plugin tests

# doc/tags is generated, not committed (.gitignore). Regenerating it is the only
# way a malformed tag is ever noticed: `:help` silently finds nothing otherwise.
#
# The width check enforces the `tw=78` the file's own modeline declares. Vim will
# not complain about an 81-column line; it just wraps it in the middle of a word
# for every reader with a standard-width window.
# The fence check is not decoration. A reflow pass once wrapped straight THROUGH
# a `>lua` block, welding two code samples and the closing `<` into a paragraph,
# and it shipped: `helptags` does not care, the width check did not care, and the
# damage is invisible in a diff you skim. Counting the fences catches exactly it.
doc:
	@awk 'length > 78 { printf "%s:%d: %d columns (tw=78)\n", FILENAME, NR, length; bad=1 } \
		/>(lua|vim)$$/ { opened++ } \
		/^<$$/ { closed++ } \
		FNR == 1 && $$1 !~ /^\*[a-z._-]+\*$$/ { printf "%s:1: first line must start with a *tag*\n", FILENAME; bad=1 } \
		END { \
			if (opened != closed) { printf "%s: %d code fences opened, %d closed\n", FILENAME, opened, closed; bad=1 } \
			exit bad \
		}' doc/*.txt
	nvim --headless --clean -u NONE -c 'helptags doc' -c 'quit'

all: fmt-check lint test doc
