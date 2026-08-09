# Changelog

Notable changes only. Dates are the day the change landed on `main`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-08-09

Nothing here reaches a user's editor: `tests/lint.lua` is a development tool and
is not on any path the plugin runs. The tag exists so that the latest release
points at a commit whose CI is green on every platform, `windows` included.

### Fixed

- `tests/lint.lua` reported a false positive on Windows. `vim.fn.globpath`
  answers with `tests\wiring_init.lua` there, so the per-file exception keyed on
  `tests/wiring_init.lua` did not match and the one file allowed to touch `_G`
  was flagged. Separators are normalised now, and the linter's self-test checks
  that too — the machine that would notice is not the one running the suite.

  Found by the `windows` CI job added in 1.0.0, on its first real run.

## [1.0.0] — 2026-08-09

The first tagged release. The plugin existed untagged before this, so the
entries below describe what changed relative to that untagged state rather than
to a previous version.

`1.0.0` rather than `0.x` because the public surface is now settled and
documented — `setup()`, `enable()`, `disable()`, `toggle()`, `sync()`,
`token()`, `layout()`, `statusline()`, the `User TongueChanged` event, and the
backend table contract. Anything that breaks those will be `2.0.0`. It also
matters practically: under semver, `0.x` makes every minor bump a breaking
change, so `version = "*"` in lazy.nvim would pin users and never move them.

### Added

- `:Tongue` command with subcommands and completion: `status`, `toggle`,
  `enable`, `disable`, `sync`. `:Tongue status` reports what the plugin intends
  without spawning anything, which is the complement to `:checkhealth tongue`.
- Lua API: `enable()`, `disable()`, `toggle()`, `sync()`, `token()`, `layout()`,
  `statusline()`.
- `User TongueChanged` autocommand event, fired only when the value a statusline
  would show can actually have changed — not on completion churn, and not on the
  59 coalesced mode changes of a burst. Payload: `{ token, layout, inserting }`.
- `setup({ verify = true })` restores the pre-fast-path behaviour of reading the
  machine before every switch.
- Presets and detection for `ibus` and `xkb-switch` on Linux, and `im-select.exe`
  on a Linux `uname` (WSL, where the Windows input method is the one you can
  see). Neither Linux binary has been run against here — see the README.
- LuaCATS annotations (`tongue.Backend`, `tongue.Opts`, `tongue.Status`) and a
  `.luarc.json`, so a hand-written backend gets completion and field checking.
- `tests/lint.lua`: a dependency-free linter that reads LuaJIT bytecode to find
  accidental globals and typo'd global reads. It self-tests before it runs.
- CI now runs the pure specs on a real Windows runner, checks that `helptags`
  generates cleanly, and calls the same `make` targets the README publishes.

### Changed

- **Entering Insert no longer reads the machine.** The plugin forced English on
  the way out and knows it landed, so it issues the restore directly. An Insert
  round trip costs three processes instead of four, and a session that never
  leaves English costs one instead of two; the restore lands one whole read
  (~40–50 ms with `tongue`) sooner. Leaving Insert still always reads — a switch
  made by hand can only be learned from the machine.
  - Consequence, and the reason for `verify`: an input method changed by hand
    **in Normal mode**, with no focus event, now survives into Insert instead of
    being overwritten.
- `setup({ timeout = ... })` is validated instead of silently defaulted. A
  non-number, or anything under 100 ms, is reported as the config bug it is:
  `timeout = 0` made every command report "timed out" instantly, and a negative
  value disabled the deadline that exists to release the single-flight latch.
- `:checkhealth tongue` reports a config bug as an **error** rather than the same
  neutral note as "there is no IME tool on this machine", uses the configured
  `timeout` for its read, and resolves the `set` binary as well as the `get` one.
- The SSH guard reads `$SSH_CONNECTION` and `$SSH_CLIENT` as well as `$SSH_TTY`,
  and ignores an exported-but-empty value. tmux refreshes `SSH_CONNECTION` on
  attach and never `SSH_TTY`, so `ssh box` → `tmux attach` → `nvim` used to skip
  the guard entirely. The reason string now names the variable that fired.
- `status()` returns a copy of the backend table. It used to hand out a reference
  to a shared preset, so a caller's `.english = ...` poisoned every later
  `setup()` in the session. It also gained `attached`, `misconfigured` and
  `verify`.

### Fixed

- **A backend that does not recognise the live state no longer disables the one
  guarantee this plugin makes.** `unknown` (`tongue`) and `0` (`im-select.exe`
  with no foreground window) arrived as plain "English", so the plugin concluded
  the machine was already English and issued no switch at all — and the pending
  observation read the shrug as a deliberate choice and forgot the layout you
  were typing in. Both are now distinguished from a real reading.
- **`setup()` while a command was in flight could wedge the plugin for the rest
  of the session.** The in-flight callback read the module-level `cfg`, which the
  new `setup()` may have set to `nil`, and threw from inside a scheduled callback
  with the single-flight latch still down. `epoch` was also *reset* rather than
  bumped, so a reading taken under the previous backend could satisfy the
  freshness check and be adopted by the new one.
- `uv.new_timer()` failing threw out of the ModeChanged autocommand with the
  latch already down — the same failure the surrounding `pcall` exists to stop.
- Throttled warnings formatted their message before the throttle, and `set` deep
  copied its argv on every mode boundary.

### Tests

- Regression tests for every fix above, each verified to fail without it.
- `helpers.settle` now throws on timeout instead of returning a boolean that 40
  of its 41 call sites ignored — a wedged cycle used to leave the rest of the
  suite asserting against stale state, and since `en` is both the startup value
  and the usual expectation, a wedge often produced a green run.
- `wiring_spec`'s `--remote-expr` helper throws instead of returning `""`. The
  `<C-c>`/`InsertLeave` assertion — the one claim that whole file exists to make
  — compared two of those values and passed by agreeing with itself.
- `mode_spec` now covers all 37 rows of `:help mode()` rather than 27, including
  the blockwise modes (a literal `CTRL-V`/`CTRL-S` byte) and the overstrike
  command-line modes.
- Process-count budgets, so the fast path cannot silently regress into costing
  twice as much while still behaving correctly.

[1.0.1]: https://github.com/xom11/tongue.nvim/releases/tag/v1.0.1
[1.0.0]: https://github.com/xom11/tongue.nvim/releases/tag/v1.0.0
