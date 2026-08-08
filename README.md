# tongue.nvim

Force English in Normal mode, restore your input method in Insert mode — for
IMEs that are a **process, not an input source**.

Every other plugin in this space switches macOS *input sources*. That is the
wrong lever for an external Vietnamese IME: GoTiengViet, EVKey, OpenKey and
GoNhanh all sit on top of `com.apple.keylayout.ABC`, so "Vietnamese" and
"English" are the **same** input source and the difference is invisible to a
tool that only reads input-source IDs. tongue.nvim drives
[`tongue`](https://github.com/xom11/tongue), which moves the layout *and* the
IME process and verifies the machine actually got there.

It also never blocks the UI, and it handles `<C-c>` — which fires no
`InsertLeave` at all.

## Requirements

- Neovim **0.10+** (`vim.system`)
- a backend on `$PATH`:
  - macOS — [`tongue`](https://github.com/xom11/tongue)
  - Linux — `fcitx5-remote` (ships with fcitx5)
  - anything else — bring your own, see [Custom backends](#custom-backends)

> **Do not run `cargo install tongue`.** The `tongue` crate on crates.io is an
> unrelated program (a shell) that happens to install a binary of the same name.
> Install from [the repository](https://github.com/xom11/tongue).

## Install

```lua
-- lazy.nvim
{ "xom11/tongue.nvim", opts = {} }

-- vim.pack (Neovim 0.12+)
vim.pack.add({ { src = "https://github.com/xom11/tongue.nvim" } })
require("tongue").setup()
```

`setup()` is required — nothing happens on `require` alone.

On a machine with no supported backend, and in SSH sessions, the plugin resolves
to nothing and stays completely inert. That is not an error: over SSH the input
method that matters belongs to the client, not to the host you typed on.

## Behaviour

| You do | It does |
|---|---|
| start Neovim | reads the machine once, remembers what you were using, forces English |
| enter Insert / Terminal-insert | restores what you were last typing in |
| leave Insert — `<Esc>`, `<C-c>`, `:normal!`, a macro | forces English |
| switch IME yourself mid-Insert | notices, and restores *that* next time |
| completion popups, `i_CTRL-O` | nothing — those never leave Insert |
| regain window focus in Normal mode | re-asserts English |

Every backend call is asynchronous and single-flight: 60 mode changes in a
burst cost one process, not 60.

## Configuration

```lua
require("tongue").setup({
  -- Override auto-detection. See "Custom backends".
  backend = nil,
  -- Warn when the backend fails, times out, or answers with something
  -- unusable. Throttled to one message per 30 s per kind.
  notify = true,
  -- Per-command timeout, milliseconds. A hung backend must not wedge the
  -- plugin for the rest of the session.
  timeout = 2000,
})
```

`notify = false` silences *runtime* warnings. A malformed `backend` is always
reported — that is a config bug, and a plugin whose whole job is to stop you
typing in the wrong language has no business failing quietly.

### Custom backends

A backend is four keys. Anything that satisfies them works, and the built-in
presets are nothing more than tables of exactly this shape:

```lua
require("tongue").setup({
  backend = {
    english = "1033",              -- token to force in Normal mode  (required)
    get     = { "im-select.exe" }, -- argv; prints the current token (required)
    set     = { "im-select.exe" }, -- argv; the token is appended    (required)
    unknown = nil,                 -- token meaning "no idea" -> treated as english
    tokens  = nil,                 -- allow-list; nil means anything one-word
  },
})
```

`get` must print exactly one whitespace-free token on stdout. Output containing
interior whitespace is rejected rather than cleaned up, deliberately: readers
that merge stderr into stdout turn a stray warning into a single
plausible-looking token, which then gets stored and replayed as an argument
forever.

Presets are available as `require("tongue.presets").tongue` and `.fcitx5`.

Windows is not detected automatically. There was an `im-select.exe` branch and
it was removed before release because it had never actually been run — the
config above is the supported way to use one.

## `:checkhealth tongue`

Every failure mode here is silent by nature: the plugin does nothing visible
when it works, and nothing visible when the backend is missing, renamed, or is a
different program that happens to share its name. Health is where you find out
which.

## Known limitations

- Command-line mode counts as Normal. Right for `:`, arguably wrong for `/`, and
  the mode string cannot tell them apart.
- Switching takes as long as your backend takes (~200 ms for `tongue`, because
  it starts and stops an IME process). There is a window after leaving Insert
  where the switch has not landed yet. Nothing in an editor plugin can close it.
- If you switch IME by hand *while* a command of ours is already in flight and
  leave Insert in the same instant, that one change is missed. It corrects
  itself on the next Insert session.

## Tests

```sh
nvim --headless --clean -u NONE -l tests/run.lua
```

No busted, no plenary, no luarocks: what is worth testing here is an async state
machine and real editor behaviour, so the only runtime that proves anything is
Neovim itself. `tests/wiring_spec.lua` drives a second, real Neovim over
`--remote-send`, because neither `nvim -l` nor `nvim -c` can hold Insert mode
from inside a blocking script — a suite written with `feedkeys` would pass while
driving nothing.

## License

MIT
