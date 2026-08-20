# tongue.nvim

[![ci](https://github.com/xom11/tongue.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/xom11/tongue.nvim/actions/workflows/ci.yml)
![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)
![dependencies none](https://img.shields.io/badge/dependencies-none-brightgreen)
![License MIT](https://img.shields.io/badge/license-MIT-blue)

Force English in Normal mode, restore your input method in Insert mode — for
IMEs that are a **process, not an input source**.

Every other plugin in this space switches macOS *input sources*. That is the
wrong lever for an external Vietnamese IME: GoTiengViet, EVKey, OpenKey and
GoNhanh all sit on top of `com.apple.keylayout.ABC`, so "Vietnamese" and
"English" are the **same** input source and the difference is invisible to a
tool that only reads input-source IDs. tongue.nvim drives
[`tongue`](https://github.com/xom11/tongue), which moves the layout *and* the
IME process and verifies the machine actually got there.

It also never blocks the UI, it handles `<C-c>` — which fires no `InsertLeave`
at all — and it spawns a process only when one can change something: entering
Insert costs a single command, and in a session that never leaves English it
costs none.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Behaviour](#behaviour)
- [Commands](#commands)
- [Configuration](#configuration)
- [Custom backends](#custom-backends)
- [Statusline](#statusline)
- [`:checkhealth tongue`](#checkhealth-tongue)
- [Troubleshooting](#troubleshooting)
- [How this differs from the alternatives](#how-this-differs-from-the-alternatives)
- [Known limitations](#known-limitations)
- [Tests](#tests)
- [Contributing](#contributing)

## Requirements

- Neovim **0.10+** (`vim.system`)
- a backend on `$PATH`. Auto-detection takes the first one it finds, in this
  order:

  | OS | order | preset |
  |---|---|---|
  | macOS | [`tongue`](https://github.com/xom11/tongue) | `tongue` |
  | | [`macism`](https://github.com/laishulu/macism) | `macism` |
  | | [`im-select`](https://github.com/daipeihust/im-select) | `im_select` |
  | Linux | `fcitx5-remote` (ships with fcitx5) | `fcitx5` |
  | | `ibus` (ships with ibus — the GNOME default) | `ibus` |
  | | [`xkb-switch`](https://github.com/grwlf/xkb-switch) | `xkb_switch` |
  | | `im-select.exe` (WSL: the Windows IME is the one you can see) | `im_select_exe` |
  | Windows | `im-select.exe` | `im_select_exe` |

  Anything else — bring your own, see [Custom backends](#custom-backends).

The order is a promise, not an accident. On macOS `tongue` comes first because
`macism` and `im-select` read and write **input-source IDs**, which is the
weaker lever: with an external IME, `vi` and `en` are the *same* input source, so
they cannot tell them apart. On Linux an input-method framework (fcitx5, ibus)
outranks `xkb-switch` for the same reason — `xkb-switch` moves the keyboard
layout and cannot see that a framework is running at all. The weaker backends are
still worth detecting — a machine using the OS's own Vietnamese, Japanese or
Chinese input sources is served perfectly well by them — but `:checkhealth` says
so out loud when you land on one, because the plugin looks identical from the
outside either way.

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

-- mini.deps
MiniDeps.add({ source = "xom11/tongue.nvim" })
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
| regain window focus in Normal mode | re-reads the machine and re-asserts English |
| leave the editor entirely — another pane, `<C-z>`, `:q` | nothing, unless `restore_on_unfocus = true` |

Every backend call is asynchronous and single-flight: 60 mode changes in a burst
cost one process, not 60.

And most boundaries cost nothing at all. Leaving Insert always reads the machine
— a switch you made by hand can only be learned from it — but entering Insert
does not: the plugin forced English on the way out and knows it landed, so it
issues the restore directly instead of asking a question it already holds the
answer to. Measured against the test fixture, an Insert round trip went from four
processes to three, and a session that never leaves English from two to one. The
restore also lands one whole read (~40–50 ms with `tongue`) sooner, which is the
part you can feel.

The one thing that gives up is an input method changed by hand **in Normal
mode**, with no focus event to notice it. That change now survives into Insert
instead of being overwritten — arguably what pressing the hotkey meant — and
`setup({ verify = true })` buys the old read-before-every-switch behaviour back
if you disagree.

### Leaving the editor

An input method is machine-global. Everything above can ignore that, because
"Normal mode" and "Insert mode" only exist while Neovim has the keyboard — but
the moment it does not, forcing English is forcing it on whatever you switched
*to*. Alt-tab to a browser from Normal mode and you are typing English there,
with no way back except your own hotkey.

`restore_on_unfocus = true` gives the layout back on the way out:

```lua
require("tongue").setup({ restore_on_unfocus = true })
```

Three ways out, and only one of them is a focus event:

| Leaving by | Event | How the restore is issued |
|---|---|---|
| another pane, tab, window, app | `FocusLost` | asynchronously, like every other switch |
| `<C-z>` | `VimSuspend` | **blocking** |
| `:q` | `VimLeavePre` | **blocking** |

The last two fire no focus event at all — the terminal that owns the pane never
stopped being focused, so nothing announces them — and neither has a "later" to
schedule into. `<C-z>` stops the process, so a callback runs only once the user
is already back; `VimLeavePre` is the last moment the event loop exists. Both
therefore block for as long as the backend takes (~200 ms with `tongue`), once,
on a keystroke you are already waiting on — but never longer than 500 ms, no
matter what `timeout` says. A restore that has not landed by then will not land
before the process is gone either, so past that point a bigger deadline only
buys editor freeze; a `timeout` set *below* 500 ms still wins. Handling only
`FocusLost` fixes the case you noticed and leaves the neighbouring two to read
as an intermittent bug.

Coming back is unchanged: `FocusGained` (and `VimResume`) re-read the machine and
re-assert English, so Normal mode is English again before you type into it.

It is off by default because the cost is real — every focus change across the
boundary costs a backend call, and a terminal that reports focus while an IME
candidate window is open will report it more often than you expect. Turn it on
if you live in a multiplexer.

## Commands

`:Tongue` takes one subcommand, with completion:

| Command | Effect |
|---|---|
| `:Tongue` or `:Tongue status` | what the plugin is doing right now, without spawning anything |
| `:Tongue toggle` | stop / start acting |
| `:Tongue enable` | start acting; re-learns the layout rather than trusting a stale cache |
| `:Tongue disable` | stop acting; the input method is left exactly where it is |
| `:Tongue sync` | re-read the machine and re-assert — for a switch Neovim never saw |

`:Tongue status` is instant and says what the plugin *intends*;
[`:checkhealth tongue`](#checkhealth-tongue) spawns the backend and says whether
it *works*. Reach for the first when the behaviour surprises you, the second when
nothing happens at all.

The same things are callable, for keymaps:

```lua
vim.keymap.set("n", "<leader>ti", require("tongue").toggle, { desc = "tongue.nvim on/off" })
```

| Function | Returns |
|---|---|
| `require("tongue").enable()` | `true`, or `false` when there is no backend to drive |
| `require("tongue").disable()` | — |
| `require("tongue").toggle()` | the state it left behind |
| `require("tongue").sync()` | — |
| `require("tongue").token()` | the token that should be in force now; `nil` when inert |
| `require("tongue").layout()` | the token Insert mode will restore |
| `require("tongue").status()` | everything, for bug reports |

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
  -- plugin for the rest of the session. Minimum 100: a shorter deadline fires
  -- before a healthy backend can answer, which reads exactly like a broken one.
  timeout = 2000,
  -- Read the machine before every switch instead of trusting the plugin's own
  -- last successful one. Costs one extra process per Insert entry; buys back
  -- noticing an input method you changed in Normal mode. See "Behaviour".
  verify = false,
  -- Put your layout back when Neovim stops being the editor you are typing
  -- into: focus lost, <C-z>, or :q. See "Leaving the editor".
  restore_on_unfocus = false,
})
```

The deadline is enforced by the plugin itself, not just handed to `vim.system`.
That distinction matters if you write your own backend: `vim.system`'s `timeout`
kills the process it started but still waits for the stdout pipe to close, and a
shell wrapper that runs its work in a subprocess leaves a grandchild holding
that pipe open. Measured: a wrapper forking `sleep 5` with `timeout = 200` called
back after 5016 ms; the same script using `exec` came back at 202 ms.

`notify = false` silences *runtime* warnings. A malformed `backend`, `english` or
`timeout` is always reported — that is a config bug, and a plugin whose whole job
is to stop you typing in the wrong language has no business failing quietly.
Being *inert* stays silent, because that is not a bug: no IME tool on this
machine, and SSH, are correct outcomes.

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

> **Get `english` right.** Measured on macism 3.1.1: an input source that does
> not exist on this machine makes it print `Input source … does not exist!` **on
> stdout** and exit **0** — a failure with no exit code to read. The plugin
> catches this (a `set` that prints anything is not believed), and so does
> `:checkhealth tongue`, which tries the switch rather than only reading. Run it
> while your other input method is active.

### Custom backends

A backend is four keys, plus two optional ones. Anything that satisfies them
works, and the built-in presets are nothing more than tables of exactly this
shape:

```lua
require("tongue").setup({
  backend = {
    english = "1033",              -- token to force in Normal mode  (required)
    get     = { "im-select.exe" }, -- argv; prints the current token (required)
    set     = { "im-select.exe" }, -- argv; the token is appended    (required)
    exchange = nil,                -- argv; sets the appended token AND prints
                                   --   the previous one. Optional: saves a
                                   --   round trip where one is expensive.
    unknown = nil,                 -- token meaning "I do not recognise this"
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

`exchange` is optional and is only ever a speed optimisation. It does what `get`
then `set` do, in one process: it selects the appended token and prints the token
that was there **before**. Unlike `set`, printing is its contract, so output is
never read as failure.

It is used on exactly one boundary — leaving Insert, where the plugin forces
English — and never when restoring a remembered layout. An exchange has already
written by the time its answer arrives, so it is only safe where writing blind is
safe: forcing English always is, restoring is not. `verify = true` disables it,
since that option asks for a read before every switch.

Worth wiring up only where a round trip is expensive. Locally it saves ~40 ms and
is not worth the extra command; over ssh it is the difference between one leg and
two. Measured driving a Windows keyboard from a Mac on 2026-08-20: one leg cost
656 ms — 293 ms of it Windows starting a fresh PowerShell before doing any work —
so leaving Insert cost 1318 ms against a window of 150–400 ms.

`set` must be **silent** on success. Anything it writes to stdout is treated as a
failure, whatever the exit code says — `tongue en` and `fcitx5-remote -s` both
print nothing, and macism 3.1.1 reports a nonexistent input source exactly that
way while still exiting 0. A backend with no exit code worth reading leaves its
output as the only evidence there is.

A `set` that reports failure is **confirmed against the machine** before it is
believed, because "said it failed" and "failed" are not the same thing: IBus
1.5.34-rc2 exits 1 while the engine changes, since `ibus engine` also shells out
to `setxkbmap`. One read settles it, and it costs nothing on a backend that does
not lie — the confirmation only happens when a `set` reports failure at all.

`unknown` is what your backend prints when it does not recognise the live state.
It is **not** treated as English: a shrug is not evidence, so the plugin neither
learns a layout from it nor concludes "already English" and skips the switch.
Forcing English is exactly what should happen there, and it does.

Presets are available as `require("tongue.presets").tongue`, `.macism`,
`.im_select`, `.im_select_exe`, `.fcitx5`, `.ibus` and `.xkb_switch`.

**What has actually been run.** Every one of the seven backends, against its
real binary.

- **tongue** — verified end to end on macOS 26.5.1 arm64 with Neovim 0.12.4,
  through auto-detection rather than an explicit `backend`. Its contract is
  exact: `tongue` prints the mode and exits 0, `tongue <mode>` is silent and
  exits 0, an unknown mode exits 2 with a message on stderr.

- **macism** — verified end to end on macOS 26.5.1 with Neovim 0.12.4 and macism
  3.1.1, driving the real macOS Vietnamese IM (`com.apple.inputmethod.VietnameseIM.VietnameseTelex`):
  auto-detection picks it when `tongue` is absent, startup records the live
  source and forces `ABC`, Insert restores Vietnamese, leaving forces `ABC`, and
  a switch made by hand mid-Insert is the one that comes back. Reads cost ~22 ms,
  against ~40–50 ms for `tongue`, which also has an IME process to move.
  With `tongue` installed as well, `tongue` still wins — as intended.
- **im-select.exe** — driven end to end on Windows 11 ARM64 with Neovim 0.12.4 as
  a hand-written backend. Auto-detection verified on that machine too: `uname`
  reports `Windows_NT`, the chain resolves `im-select.exe`, and `english`,
  `backend = "im-select.exe"` and a rejected malformed `english` all behave as
  documented. The pure specs now run there on every push (see [Tests](#tests));
  the rest of the suite cannot, because `tests/fixtures/fake-im` is a POSIX shell
  script. That is a limitation of the harness, not of the plugin.
- **fcitx5, ibus and xkb-switch** — driven end to end on **Ubuntu 26.04 arm64,
  Neovim 0.11.6**, in a headless sway 1.11 session with XWayland, against
  fcitx5 5.1.19 + fcitx5-unikey, IBus 1.5.34-rc2 + ibus-unikey, and xkb-switch
  2.1.0 with a `us,vn` layout pair. For each: startup records the live method and
  forces English, a switch made by hand is remembered, entering Insert restores
  it, leaving forces English again.

  Two of the three have a sharp edge that only shows up against the real binary,
  and `:checkhealth tongue` now prints both:

  | | `get` | `set` on success | `set` on a bad token |
  |---|---|---|---|
  | `xkb-switch` | `us` | exit 0, silent | **exit 2 + a clear message** |
  | `fcitx5` | one token — **empty with no focused input context** | exit 0, silent | **exit 0, silent, changes nothing** |
  | `ibus` | `xkb:us::eng` | **exit 1** for an IME engine, 0 for an `xkb:` one | exit 1 |

  `xkb-switch` fits the contract exactly.

  `ibus` exits 1 while succeeding, because `ibus engine` also runs `setxkbmap`
  and that fails without a usable X display. The plugin handles it: a `set` that
  reports failure is **confirmed against the machine** before being believed, so
  the lie costs one extra read per restore and nothing else — no warning, and the
  cache stays usable. That confirmation is general, not an ibus special case.

  `fcitx5` accepts a name that is not in your group in complete silence — the
  macism failure with the last signal removed. Nothing a *running* plugin reads
  can detect it, so `:checkhealth tongue` tries the switch and looks. Run it
  while your other input method is active.
- **im-select** (macOS) — driven end to end on **macOS 26.5.1 arm64 (Apple
  silicon), Neovim 0.12.4, im-select 1.0.1**, against the real macOS Vietnamese
  input method (`com.apple.inputmethod.VietnameseIM.VietnameseTelex`). `im-select`
  prints `com.apple.keylayout.ABC` and exits 0; `im-select <id>` is silent and
  exits 0 for a real input source and **exits 1 for one that does not exist** —
  the cleanest of the input-source backends, since it is the only one that
  reports a bad token at all. Full round trip, zero warnings. On the same machine
  with `tongue` also installed, auto-detection still picks `tongue`, as the
  ordering promises.

Every OS chain, Linux and Windows included, is exercised from a Mac:
`tests/backend_spec.lua` drives `resolve()` through an injected prober rather
than asking the real machine.

### When the backend depends on the environment

`get` and `set` are argv, fixed at `setup()`. That is deliberate: they sit on the
hot path, one of them runs inside `VimLeavePre` where the event loop is about to
stop being ours, and both run under a deadline this plugin owns. None of those
three is a place to call back into your config.

Two things follow, and between them they cover a moving target.

A backend is a **program**, so a backend can be a script. Whatever it has to work
out — which machine, which of two tools, which display — it works out per call,
in its own process, off the main loop. That is also how you drive an input method
that is not on this machine: a wrapper that speaks one vocabulary and forwards to
whichever side owns the keyboard.

If the **answer** changes while Neovim is running, call `setup()` again. It
replaces the backend, forgets the remembered layout — correct, a token from one
machine means nothing on another — and reads the machine once. `:Lazy reload` has
always done exactly this. Do it inside `vim.schedule()`, because `setup()` clears
and rebuilds the plugin's own augroup:

```lua
vim.api.nvim_create_autocmd("FocusGained", {
  group = vim.api.nvim_create_augroup("my-route", { clear = true }),
  callback = function()
    vim.schedule(function()
      require("tongue").setup({ backend = my_backend_for_now() })
    end)
  end,
})
```

Keep that function cheap, or make it asynchronous — `vim.system` with a callback
that calls `setup()` when it answers. Nothing here needs it to be synchronous.

## Statusline

`token()` is the plugin's *intent*, so it is right the instant the mode changes
rather than ~200 ms later when the process returns. `User TongueChanged` fires
only when that value can have changed — never on completion churn, never on the
59 coalesced mode changes of a burst — so a component can refresh on the event
instead of polling.

```lua
-- lualine
require("lualine").setup({
  sections = { lualine_x = { require("tongue").statusline } },
})
```

`statusline(opts)` returns the empty string whenever there is nothing worth
saying, which is most of the time:

```lua
require("tongue").statusline({
  format   = " %s",  -- anything that is not English   (default "%s")
  english  = "",     -- while English is in force      (default "")
  inactive = "",     -- while inert or disabled        (default "")
})
```

Rolling your own, or refreshing a cached component:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "TongueChanged",
  callback = function(ev)
    -- ev.data = { token = "vi", layout = "vi", inserting = true }
    --
    -- `token` and `layout` are BOTH nil while the plugin is inert or disabled,
    -- and that firing is the point: it is what tells a component to clear
    -- itself after `:Tongue disable`. Handle nil, or use `statusline()`, which
    -- already does.
    vim.cmd.redrawstatus()
  end,
})
```

The same surface is the hook for things the plugin deliberately does not do
itself. Turning it off inside a fuzzy-finder prompt, for instance:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "TelescopePrompt",
  callback = function() require("tongue").disable() end,
})
vim.api.nvim_create_autocmd("BufLeave", {
  callback = function()
    if vim.bo.filetype == "TelescopePrompt" then require("tongue").enable() end
  end,
})
```

## `:checkhealth tongue`

Every failure mode here is silent by nature: the plugin does nothing visible
when it works, and nothing visible when the backend is missing, renamed, or is a
different program that happens to share its name. Health is where you find out
which. It reports:

- which backend was resolved and why, and whether it is currently disabled
- both the `get` and the `set` binary, resolved to full paths
- a backend that writes to stderr on success, or answers with more than one token
- a token outside the backend's declared set — what a name collision looks like
- a **config bug**, as an error rather than the same neutral note as "there is no
  IME tool on this machine"
- an **SSH variable on a plugin that is running anyway** — which can only mean
  `backend` was named explicitly, because that is what overrides the SSH guard.
  It is the one combination where everything above passes and the plugin still
  drives a machine nobody is typing on, so the warning names the variable and
  this machine's hostname, and hands you the one-line check that settles it

It also **tries the switch**, not just the read — and that is the only way to
catch a `set` that lies, which is the failure people actually hit (`fcitx5` with
a name outside your group; macism with an input source that does not exist).
The probe only ever switches *towards* `english`, and only from somewhere else,
then puts the machine back:

```
ok    reads back "unikey"
ok    `set` works: "unikey" -> "keyboard-us"
```

If you are already in English there is nothing to prove, and it says so — switch
to your other input method and run it again. If it fails to restore, it fails
towards the state Normal mode wants anyway.

## Troubleshooting

**Nothing happens at all.** Run `:checkhealth tongue`. Inert over SSH and inert
on a machine with no backend are both correct outcomes, and both say so. If it
says `setup() has not been called`, `require` alone is not enough.

**It runs, reports healthy, and switches nothing.** You are almost certainly on
`macism`, `im-select`, `im-select.exe` or `xkb-switch` while using an external
IME. Those read and write the OS input source, and an external IME does not
change it — `:checkhealth` prints exactly this warning when you land on one. On
macOS, install [`tongue`](https://github.com/xom11/tongue).

**It forgets my layout.** The plugin only learns from the machine on the way
*out* of Insert. If your backend's `get` is failing it never learns anything, and
`:checkhealth` will say so. If your backend answers with a no-idea sentinel,
declare it as `unknown` — see [Custom backends](#custom-backends).

**Vietnamese comes back in my fuzzy finder.** A finder's prompt buffer is Insert
mode, so it gets your layout back. The recipe under [Statusline](#statusline)
turns it off there. (The command line is different: `:` and `/` count as Normal
and stay English.)

**I changed my IME with a global hotkey and Neovim did not notice.** Nothing
tells an editor about that. `:Tongue sync` re-reads the machine on demand, and
regaining window focus does it automatically.

**It is slow, or I see the wrong language for a moment.** A switch takes as long
as your backend takes — ~200 ms for `tongue`, which starts and stops an IME
process. Nothing in an editor plugin can close that window.

When reporting a bug, paste `:checkhealth tongue` and `:Tongue status`.

## How this differs from the alternatives

`im-select.nvim`, `smartim`, `vim-barbaric`, `fcitx.nvim` and the rest read and
write an **input-source ID**. That is what their backends expose, and it is the
right lever for the OS's own Vietnamese, Japanese and Chinese input sources —
tongue.nvim detects and drives those same tools.

The difference is structural rather than a matter of quality: an external IME is
a process layered on top of `com.apple.keylayout.ABC`, so "typing Vietnamese"
and "typing English" share one input-source ID. No amount of care makes an ID
distinguish two states that have the same ID. `tongue` exposes *modes* instead
(`en`/`vi`/`zh`) and moves both levers, and this plugin is built around that
contract while still speaking the ID-based one for everyone else.

Two smaller differences, called out because they are easy to get wrong and there
are regression tests here for both:

- **`<C-c>` fires no `InsertLeave`** (`:help i_CTRL-C`). Anything wired to
  `InsertEnter`/`InsertLeave` strands you in Normal mode with the IME still on,
  until the next time you enter and leave Insert properly. This plugin listens to
  `ModeChanged`, and `tests/wiring_spec.lua` drives a real second Neovim over
  `--remote-send` to prove the keystroke actually arrives.
- **Completion churns modes** (`i:ix`, `ix:i`, `i:ic`, `ic:i`) without ever
  leaving Insert. Reacting to those re-selects the input source mid-composition,
  which is the CJK sub-mode flicker people report. Here they cross no boundary
  and cost nothing.

## Known limitations

- Command-line mode counts as Normal. Right for `:`, arguably wrong for `/`, and
  the mode string cannot tell them apart.
- **The SSH guard reads the environment, and environments lie.** It fires on
  `$SSH_TTY`, `$SSH_CONNECTION` or `$SSH_CLIENT` — all three, because tmux's
  `update-environment` refreshes `SSH_CONNECTION` on attach and never `SSH_TTY`,
  so `ssh box` → `tmux attach` → `nvim` arrives with only the former. A tmux
  server first started inside an SSH session keeps a stale value for as long as
  it lives, which leaves the plugin inert locally; `:checkhealth` names the
  variable that fired so you can see that is what happened. Windows OpenSSH sets
  none of the three (measured on Windows 11 ARM64), so editing over SSH *into*
  Windows does auto-detect `im-select.exe` — which needs a foreground window and
  answers `0` without one. That `0` is declared as the backend's no-idea
  sentinel, so it is no longer mistaken for a layout to restore, but nothing
  useful happens either.
- **Nothing tells this plugin who is typing**, and those three variables are the
  closest thing there is. They are *right* when the keyboard is at the other end:
  `ssh box` → `nvim`, with or without a multiplexer, and `ssh -X` or waypipe too
  — the program runs there while the display and the input method are here. That
  is what `:checkhealth` warns about. They are *wrong* when a multiplexer or
  daemon first started over SSH exports a fossil to every session it serves
  afterwards, when the whole session really is at the far end (VNC, RDP), on
  `ssh localhost`, or when the backend is already a script that routes to the
  client. And they are *absent* on remoting that is not SSH: `docker exec`,
  `kubectl exec`, a serial console, an editor's own remote protocol — and Neovim
  reached over Windows OpenSSH, which sets none of the three. Hence a warning
  with a check attached, rather than an error.
- Switching takes as long as your backend takes (~200 ms for `tongue`, because
  it starts and stops an IME process). There is a window after leaving Insert
  where the switch has not landed yet. Nothing in an editor plugin can close it.
- If you switch IME by hand *while* a command of ours is already in flight and
  leave Insert in the same instant, that one change is missed. It corrects
  itself on the next Insert session.
- An input method changed by hand **in Normal mode** survives into Insert rather
  than being overwritten, because entering Insert no longer re-reads the machine.
  `verify = true` if you want the old behaviour.
- What comes back is what you were *using*, and a reading is the only way the
  plugin knows. A reading taken while English is already in force — at startup,
  or on any crossing you reach before switching back — makes English the thing
  it remembers, so leaving the editor puts English back. That looks exactly like
  `restore_on_unfocus` never firing; `require("tongue").layout()` tells them
  apart, since it returns the token that would be given back. One switch to your
  own input method, made in Insert, corrects it for the rest of the session.

- The layout is remembered **per Neovim**, not per buffer: one token, whichever
  buffer you were in when you chose it.

## Tests

```sh
make test        # everything
make test-pure   # only the specs that need nothing but Lua (~200 ms)
make lint        # accidental globals, unknown globals, syntax
make fmt         # stylua
make all         # all of the above, plus helptags
```

or without `make`:

```sh
nvim --headless --clean -u NONE -l tests/run.lua
nvim --headless --clean -u NONE -l tests/run.lua mode sanitize backend
nvim --headless --clean -u NONE -l tests/lint.lua
```

No busted, no plenary, no luarocks: what is worth testing here is an async state
machine and real editor behaviour, so the only runtime that proves anything is
Neovim itself. `tests/wiring_spec.lua` drives a second, real Neovim over
`--remote-send`, because neither `nvim -l` nor `nvim -c` can hold Insert mode
from inside a blocking script — a suite written with `feedkeys` would pass while
driving nothing.

`tests/lint.lua` is the same idea applied to linting: it reads LuaJIT's own
bytecode to find accidental globals and typo'd global reads, so the check runs
wherever Neovim does rather than only where somebody installed luacheck. It
self-tests before it runs, because the first version of its pattern matched
nothing and cheerfully reported a clean repo.

CI runs the full suite on Linux and macOS against Neovim stable, nightly and the
promised 0.10.0 floor, and the pure specs on a real Windows runner.

## Contributing

Bug reports are most useful with `:checkhealth tongue` and `:Tongue status`
pasted in, plus your Neovim version and which backend you are on.

For pull requests, `make all` must pass, and a change in behaviour wants a test
that **fails without it**. That last part is not a formality here: several tests
in this suite were written against a real bug and passed anyway, and every one of
them now carries a comment saying so.

## License

MIT
