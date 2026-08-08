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
- a backend on `$PATH`. Auto-detection takes the first one it finds, in this
  order:

  | OS | order | preset |
  |---|---|---|
  | macOS | [`tongue`](https://github.com/xom11/tongue) | `tongue` |
  | | [`macism`](https://github.com/laishulu/macism) | `macism` |
  | | [`im-select`](https://github.com/daehahn/im-select) | `im_select` |
  | Linux | `fcitx5-remote` (ships with fcitx5) | `fcitx5` |
  | Windows | `im-select.exe` | `im_select_exe` |

  Anything else — bring your own, see [Custom backends](#custom-backends).

`tongue` is first on macOS on purpose. `macism` and `im-select` read and write
**input-source IDs**, which is the weaker lever: with an external IME, `vi` and
`en` are the *same* input source, so they cannot tell them apart. They are still
worth detecting — a machine using macOS's own Vietnamese, Japanese or Chinese
input sources is served perfectly well by them — but `:checkhealth` says so out
loud when you land on one, because the plugin looks identical from the outside
either way.

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
  -- Override auto-detection: a preset name, or a table. See "Custom backends".
  backend = nil,
  -- The token to force in Normal mode. Overrides whatever the resolved backend
  -- brought with it — including an auto-detected one.
  english = nil,
  -- Warn when the backend fails, times out, or answers with something
  -- unusable. Throttled to one message per 30 s per kind.
  notify = true,
  -- Per-command deadline, milliseconds. A hung backend must not wedge the
  -- plugin for the rest of the session.
  timeout = 2000,
})
```

The deadline is enforced by the plugin itself, not just handed to `vim.system`.
That distinction matters if you write your own backend: `vim.system`'s `timeout`
kills the process it started but still waits for the stdout pipe to close, and a
shell wrapper that runs its work in a subprocess leaves a grandchild holding
that pipe open. Measured: a wrapper forking `sleep 5` with `timeout = 200` called
back after 5016 ms; the same script using `exec` came back at 202 ms.

`notify = false` silences *runtime* warnings. A malformed `backend` or `english`
is always reported — that is a config bug, and a plugin whose whole job is to
stop you typing in the wrong language has no business failing quietly. Being
*inert* stays silent, because that is not a bug: no IME tool on this machine, and
SSH, are correct outcomes.

### Picking a backend by name

The common case is not writing a backend — it is having one of them already and
disagreeing with one value:

```lua
-- I have macism, and this machine types on US rather than ABC.
require("tongue").setup({ english = "com.apple.keylayout.US" })

-- Skip detection entirely and name the preset.
require("tongue").setup({ backend = "macism" })
require("tongue").setup({ backend = "im-select" })  -- `im_select` works too
```

`english` applies to whatever backend was resolved, auto-detected or not, and is
validated against it: `backend = "tongue", english = "com.apple.keylayout.US"` is
an error rather than a plugin that runs while discarding every reading it takes.

> **Get `english` right, because macism will not tell you when you get it
> wrong.** Measured on macism 3.1.1: an input source that does not exist on this
> machine makes it print `Input source … does not exist!` **on stdout** and exit
> **0**. Nothing distinguishes that from success, so a wrong `english` is a
> plugin that runs, reports healthy, and switches nothing. Check your value
> first: `macism <your-id>` followed by `macism` should read it back.

### Custom backends

A backend is four keys, plus an optional note. Anything that satisfies them
works, and the built-in presets are nothing more than tables of exactly this
shape:

```lua
require("tongue").setup({
  backend = {
    english = "1033",              -- token to force in Normal mode  (required)
    get     = { "im-select.exe" }, -- argv; prints the current token (required)
    set     = { "im-select.exe" }, -- argv; the token is appended    (required)
    unknown = nil,                 -- token meaning "no idea" -> treated as english
    tokens  = nil,                 -- allow-list; nil means anything one-word
    note    = nil,                 -- printed by :checkhealth; no other effect
  },
})
```

`get` must print exactly one whitespace-free token on stdout. Output containing
interior whitespace is rejected rather than cleaned up, deliberately: readers
that merge stderr into stdout turn a stray warning into a single
plausible-looking token, which then gets stored and replayed as an argument
forever.

Presets are available as `require("tongue.presets").tongue`, `.macism`,
`.im_select`, `.im_select_exe` and `.fcitx5`.

**What has actually been run.**

- **macism** — verified end to end on macOS 26.5.1 with Neovim 0.12.4 and macism
  3.1.1, driving the real macOS Vietnamese IM (`com.apple.inputmethod.VietnameseIM.VietnameseTelex`):
  auto-detection picks it when `tongue` is absent, startup records the live
  source and forces `ABC`, Insert restores Vietnamese, leaving forces `ABC`, and
  a switch made by hand mid-Insert is the one that comes back. Reads cost ~22 ms,
  against ~40–50 ms for `tongue`, which also has an IME process to move.
  With `tongue` installed as well, `tongue` still wins — as intended.
- **im-select.exe** — driven end to end on Windows 11 ARM64 with Neovim 0.12.4 as
  a hand-written backend. Its *auto-detection* is new here and has not run on a
  Windows machine.
- **im-select** (macOS) — not run. Same shape as macism, and covered as a chain
  and as data, but the binary itself is untested here.

Every OS chain, Linux and Windows included, is exercised from a Mac:
`tests/backend_spec.lua` drives `resolve()` through an injected prober rather
than asking the real machine.

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
