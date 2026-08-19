# Changelog

Notable changes only. Dates are the day the change landed on `main`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] — 2026-08-19

One warning, for the one failure this plugin could not previously name. Nothing
about how it drives an input method changed.

### Added

- **`:checkhealth tongue` warns when an SSH variable is set and the plugin is
  running anyway.** That combination can only mean `backend` was named
  explicitly, because an explicit backend is exactly what overrides the SSH
  guard — and it is the one case where every other check passes while `get` and
  `set` drive a machine nobody is typing on. Neovim on one machine, the keyboard
  on another, and the input method that turns your keystrokes into Vietnamese
  living on neither of the two the plugin can see.

  The warning names the variable, names this machine, and leads with the check
  that settles it: run the `get` argv by hand while you switch input method on
  the machine you are *typing* on. If the token never moves, this is the wrong
  machine.

  A warning rather than an error, because the condition is a proxy and not
  evidence. `$SSH_CONNECTION` can be a fossil — a multiplexer or daemon first
  started over SSH exports it to every session it serves afterwards, local ones
  included — and a backend can already be a script that routes to the client.
  Both directions of wrongness are now written down under Known limitations.

- **A backend that has to follow the environment has a documented answer**
  (`:help tongue-backend-env`). `get` and `set` stay fixed argv — they sit on
  the hot path, one of them runs inside `VimLeavePre`, and both run under a
  deadline the plugin owns, so none of them is a place to call back into your
  config. What moves instead: a backend is a program, so it can be a script that
  decides per call in its own process; and when the *answer* changes while
  Neovim runs, `setup()` can simply be called again, which is what `:Lazy
  reload` has always done.

### Tests

- Three new tests, each verified to fail without the change: the warning fires
  and names the variable that fired (all three of them), `backend.ssh_var` is
  the single copy of that rule rather than a loop copied next to the warning,
  and — the counterweight — a machine with no SSH variable gets no warning at
  all. Without that last one a version that warns unconditionally passes every
  other test in the file, since the runner clears all three variables before the
  suite starts.
- One test pins the documented recipe: a second `setup()` drives the new argv,
  not the one it replaced. Red when `setup()` is mutated to keep the backend it
  already had — a mutation the rest of the suite barely notices, because every
  other second-`setup()` test uses the same fixture argv and differs only by
  environment.

## [1.2.0] — 2026-08-17

### Added

- **`restore_on_unfocus`** — give the layout back when Neovim stops being the
  editor you are typing into. Off by default; see `:help tongue-unfocus`.

  An input method is machine-global, and until now the plugin only ever thought
  about Neovim's own modes. Forcing English in Normal mode therefore leaked out
  of the editor: switch to another pane, tab or application and you were typing
  English there, with nothing left to turn the IME back on but your own hotkey.

  Three ways out of the editor, and only one of them is a focus event.
  `FocusLost` restores asynchronously like every other switch. `VimSuspend`
  (`<C-z>`) and `VimLeavePre` (`:q`) fire **no focus event at all** — the
  terminal owning the pane keeps the keyboard throughout — and neither has a
  "later" to schedule into, so both restore **synchronously**, blocking for the
  one backend call. Coming back through `FocusGained` or `VimResume` re-asserts
  English exactly as before.

  Verified end to end on macOS with the real `tongue` backend inside herdr:
  focused Normal mode holds English, switching pane or tab restores Vietnamese,
  switching back forces English, and `:q` restores Vietnamese with no focus event
  involved.

### Fixed

- **`FocusGained` now records that focus returned even while you are typing.**
  The reconcile is still skipped mid-composition — that is what keeps IME
  candidate windows from flickering — but the flag behind it is not. Without the
  split, focus regained during Insert left the plugin believing it was still in
  the background, and the next `<Esc>` asked for the layout instead of English:
  Normal mode stranded in Vietnamese with no remaining event able to correct it.
  Only reachable with `restore_on_unfocus` on.

### Changed

- **Focus handling moved behind `on_focus`, mirroring `on_mode`**, and is
  exercised through `_on_focus` in tests. This is not tidying: under `nvim -l`
  there is no main loop, so nothing can hold Insert mode and `vim.fn.mode(1)`
  answers `"n"` however the state machine was driven. A test written against the
  autocmd takes the not-typing branch every single time — which is exactly how
  the first version of `tests/unfocus_spec.lua` went green against a
  deliberately broken guard.

## [1.1.1] — 2026-08-09

The last backend that had never been run is now run. Nothing in the plugin's
behaviour changed.

### Fixed

- **The `im-select` link was dead.** README, `:help`, `presets.lua` and the design
  spec all pointed at `github.com/daehahn/im-select`, which returns 404 and
  always has. The tool is
  [`daipeihust/im-select`](https://github.com/daipeihust/im-select). Anyone who
  followed the link to install the backend this plugin auto-detects found nothing
  there.

### Changed

- **im-select verified end to end** on macOS 26.5.1 arm64, Neovim 0.12.4,
  im-select 1.0.1, against the real macOS Vietnamese input method
  (`com.apple.inputmethod.VietnameseIM.VietnameseTelex`). Startup records the
  live source and forces `ABC`, a switch made by hand is remembered, Insert
  restores it, leaving forces `ABC`. Zero warnings; the fast path stays engaged.

  Its contract is the cleanest of the input-source backends: `im-select` prints
  one token and exits 0, `im-select <id>` is silent and exits 0 for a real
  source, and **exits 1 for one that does not exist** — the only one of them that
  reports a bad token at all. (macism exits 0 and prints to stdout; fcitx5 exits
  0 in silence.)

  `:checkhealth tongue`'s `set` probe was confirmed against it in both
  directions: `` ok `set` works: "…VietnameseTelex" -> "com.apple.keylayout.ABC" ``
  with a correct `english`, and ``error `im-select …NoSuchThing` did not take``
  with a wrong one.

  On the same machine with `tongue` also installed, auto-detection still resolves
  `tongue` — the ordering promise, checked on a machine that actually has both
  rather than through an injected prober.

- **`tongue` itself verified end to end** on the same machine, through
  auto-detection rather than an explicit `backend`: it resolves `tongue`, startup
  forces `en`, a hand switch to `vi` is remembered, Insert restores it, leaving
  forces `en`. Its contract is exact — `tongue` prints the mode and exits 0,
  `tongue <mode>` is silent and exits 0, and an unknown mode exits 2 with a
  message on stderr.

With that, every one of the seven backends this plugin ships has been driven
against its real binary.

## [1.1.0] — 2026-08-09

1.0.2 documented two backend quirks as things the plugin could not do anything
about. One of them was wrong, and the other was only half true. Both are now
handled, and both fixes were verified against the real binaries on Ubuntu 26.04.

### Changed

- **A `set` that reports failure is confirmed against the machine before it is
  believed.** "Said it failed" and "failed" are not the same thing: IBus
  1.5.34-rc2 exits 1 while the engine changes, because `ibus engine` also shells
  out to `setxkbmap` and that fails without a usable X display. Taking the exit
  code at its word cost a warning on every restore *and* forbade the cache, so
  every boundary went back to reading first.

  One read settles it, and it costs nothing on a backend that does not lie — the
  confirmation only runs when a `set` reports failure at all. Measured against
  real ibus: warnings per restore went from 1 to 0, and `applied` from `nil` to
  the token, so the fast path works again.

  It is deliberately not an ibus special case. The rule is unchanged — a `set`
  we cannot believe is never recorded as applied — and all that changes is
  refusing to conclude from an exit code when the machine can just be asked.

- **`:checkhealth tongue` now tries the switch, not just the read.** That is the
  only way to catch a `set` that lies in the other direction: fcitx5 5.1.19
  accepts an input-method name outside your group in complete silence, exit 0,
  changing nothing. There is no exit code and no output, so nothing a *running*
  plugin reads can see it — but a diagnostic can switch and look.

  The probe only ever switches *towards* `english`, only from somewhere else,
  and puts the machine back. Already in English there is nothing to prove and it
  says so. If it fails to restore, it fails towards the state Normal mode wants
  anyway. Verified against real fcitx5 with a deliberately wrong `english`:

  ```
  error `fcitx5-remote -s keyboard-de` exited 0 and printed nothing,
        but the machine is still "unikey"
  ```

  The README and `:help tongue-health` previously said health "only ever reads",
  as if that were a property rather than a choice. It was a choice.

### Fixed

- **Two tests were racing the clock and one of them lost.** `fixture_spec` and
  `state_spec` both had to write the machine *inside* a read window, and both
  did it by guessing (`vim.wait(50)`, `vim.wait(25)`) how long a shell takes to
  start. The suite got heavier and the guess started failing. The fixture now
  reports when it has taken its snapshot, and the tests wait for that.
- `state_spec`'s stale-read test was opening its read window with `h.enter()` —
  which stopped reading the machine when the fast path landed in 1.0.0. It had
  been passing on its other assertions ever since. It now opens the window on
  the way *out*, where `observe` guarantees a read, and it has been re-verified
  to fail when the epoch guard is removed.

## [1.0.2] — 2026-08-09

The three Linux backends stop being documented guesses. All three were driven
end to end on **Ubuntu 26.04 arm64 / Neovim 0.11.6**, in a headless sway 1.11
session with XWayland, against fcitx5 5.1.19 + fcitx5-unikey, IBus 1.5.34-rc2 +
ibus-unikey, and xkb-switch 2.1.0 with a `us,vn` layout pair. For each: startup
records the live method and forces English, a switch made by hand is remembered,
entering Insert restores it, leaving forces English again.

No behaviour changed. What changed is what `:checkhealth tongue` tells you.

### Added

- `presets.ibus` and `presets.fcitx5` now carry a `note`, because each has an
  edge that only appears against the real binary and that a user cannot deduce
  from the plugin's behaviour:
  - **ibus** exits **1 when it succeeds.** `ibus engine <name>` also runs
    `setxkbmap`, which fails without a usable X display; the engine changes
    anyway. Switching to an `xkb:` engine (what `english` is) exits 0. The
    plugin cannot tell that from a real failure, so it warns on every restore
    and the read-skipping fast path never engages.
  - **fcitx5** exits **0, silently, when it does not succeed.** An input-method
    name that is not in your current group is accepted in silence and changes
    nothing — the macism 3.1.1 failure with the last signal removed, and the one
    case this plugin genuinely cannot detect. Its `-n` also prints nothing at
    all without a focused input context.
  - **xkb-switch** fits the contract exactly and is the only one of the three
    that reports a bad token (exit 2, with a message).
- `make doc` now checks vimdoc structure, not just width: code fences must
  balance and the first line must carry the file's `*tag*`.

### Fixed

- **`doc/tongue.txt` shipped damaged in 1.0.0 and 1.0.1.** A reflow pass wrapped
  straight through a `>lua` block in the Setup section, welding two config
  examples and the closing `<` into a paragraph, and splitting the title line in
  two. `helptags` does not validate either, and the width check that was added
  at the time only counted columns — hence the structural check above.

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

[1.3.0]: https://github.com/xom11/tongue.nvim/releases/tag/v1.3.0
[1.2.0]: https://github.com/xom11/tongue.nvim/releases/tag/v1.2.0
[1.1.1]: https://github.com/xom11/tongue.nvim/releases/tag/v1.1.1
[1.1.0]: https://github.com/xom11/tongue.nvim/releases/tag/v1.1.0
[1.0.2]: https://github.com/xom11/tongue.nvim/releases/tag/v1.0.2
[1.0.1]: https://github.com/xom11/tongue.nvim/releases/tag/v1.0.1
[1.0.0]: https://github.com/xom11/tongue.nvim/releases/tag/v1.0.0
