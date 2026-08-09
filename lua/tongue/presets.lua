--- Built-in backends.
---
--- These are *data*, not privileged code: anything here can be written by hand
--- in `setup({ backend = ... })`, and a hand-written backend is resolved by the
--- exact same path. That is the whole reason this file is separate -- so that
--- "supported" never means "hardcoded somewhere you cannot reach".

--- Said out loud by `:checkhealth` for every backend that carries it.
---
--- These backends work, and they are worth auto-detecting -- a machine using
--- macOS's own Vietnamese/Japanese/Chinese input sources is served perfectly
--- well by them. But they move ONE lever where `tongue` moves two, and the
--- difference is invisible until the day it matters. Auto-detecting them without
--- saying this would be a silent downgrade of the one guarantee this plugin
--- makes.
local INPUT_SOURCE_ONLY = "this backend reads and writes the OS input-source ID only (a locale ID on Windows). "
	.. "With an external IME -- GoTiengViet, EVKey, OpenKey, GoNhanh, UniKey -- Vietnamese and English are the "
	.. "SAME input source, so it cannot tell them apart: it will run, and change nothing you can see. "
	.. "On macOS, install `tongue` (github.com/xom11/tongue) if you use one of those."

--- The same warning one level lower down, for a backend that moves the keyboard
--- layout and does not even know an input method exists.
local LAYOUT_ONLY = "this backend reads and writes the X keyboard layout only. It does not know about ibus, fcitx "
	.. "or any other input-method framework, so if one is running, it is what decides whether you type Vietnamese "
	.. "-- and this cannot see it. Prefer the preset for whichever framework you run."

--- Measured on Ubuntu 26.04 arm64 with IBus 1.5.34-rc2 under sway 1.11.
---
--- Selecting a real input-method engine makes `ibus engine` shell out to
--- `setxkbmap`, and it exits 1 when that fails -- which it does on a Wayland
--- session with no usable X display. The engine DOES change; only the exit code
--- lies. Switching to an `xkb:` engine (which is what `english` is) exits 0.
---
--- This is why a `set` that reports failure is confirmed with a read rather than
--- taken at its word -- see `set_async` in `init.lua`. With that confirmation the
--- lie costs one extra read per restore and nothing else: no warning, and the
--- cache stays usable. Without it, every restore was reported as a failure and
--- the read-skipping fast path could never engage.
local IBUS_EXITS_NONZERO = "measured with IBus 1.5.34-rc2: selecting an input-method engine exits 1 even when it "
	.. "succeeds, because `ibus engine` also runs `setxkbmap` and that fails without a usable X display. "
	.. "tongue.nvim handles it -- a `set` that reports failure is confirmed against the machine before being "
	.. "believed -- so the only cost is one extra read per restore. Running under X, or with XWayland reachable, "
	.. "removes the cause."

--- Measured on Ubuntu 26.04 arm64 with fcitx5 5.1.19.
---
--- `fcitx5-remote -s` exits 0 and prints nothing whether the switch happened or
--- not: an input-method name that is not in the current group is accepted in
--- silence and changes nothing. That is the macism 3.1.1 failure shape with the
--- last signal removed -- there is no exit code AND no output to read -- so a
--- running plugin cannot see it at the moment of the switch. `:checkhealth` can,
--- because it can afford to switch and look; that is what its `set` probe is for.
local FCITX5_SILENT_FAILURE = "measured with fcitx5 5.1.19: `fcitx5-remote -s` exits 0 and prints nothing even when "
	.. "the input method does not exist or is not in your current group, so a wrong `english` would give you a "
	.. "plugin that runs, reports healthy, and switches nothing. Nothing the running plugin reads can detect that "
	.. "-- so run `:checkhealth tongue` while your OTHER input method is active, and it will try the switch and "
	.. "tell you. Note also that `-n` needs a focused input context and prints nothing without one."

return {
	--- github.com/xom11/tongue -- macOS, and the reason this plugin exists.
	---
	--- `tongue` speaks in *modes* ("en"/"vi"/"zh") rather than input-source IDs.
	--- That distinction is the point: with an external Vietnamese IME, `vi` and
	--- `en` are both `com.apple.keylayout.ABC`, so an input-source ID cannot
	--- express the difference at all. `tongue en` moves both levers -- it selects
	--- the layout *and* turns the IME off -- and re-reads the machine before
	--- exiting 0.
	---
	--- NOTE: the `tongue` crate on crates.io is an unrelated program (a shell).
	--- Install from the repository, never `cargo install tongue`.
	tongue = {
		english = "en",
		get = { "tongue" },
		set = { "tongue" },
		-- What `tongue` prints when the live state matches no configured mode.
		-- Feeding it back would just be `tongue unknown` -> exit 2.
		unknown = "unknown",
		tokens = { "en", "vi", "zh" },
	},

	--- macism -- github.com/laishulu/macism. macOS.
	---
	--- Same shape as every other backend here: bare invocation prints the current
	--- input source, one argument selects it.
	---
	--- `english` defaults to `ABC` rather than `US` because that is the layout an
	--- external Vietnamese IME sits on top of, and the default every plugin in
	--- this space has settled on. A machine that types on something else says so:
	--- `setup({ english = "com.apple.keylayout.US" })`.
	macism = {
		english = "com.apple.keylayout.ABC",
		get = { "macism" },
		set = { "macism" },
		-- Deliberately no `tokens`: the installed input sources are whatever this
		-- machine has, and an allow-list here would reject valid setups. The
		-- one-token rule in `sanitize` is still the garbage detector.
		note = INPUT_SOURCE_ONLY,
	},

	--- im-select -- github.com/daehahn/im-select. macOS.
	---
	--- Older and more widely installed than `macism`, hence last in the macOS
	--- chain rather than absent: if both are present, `macism` is the one that
	--- keeps working on current macOS.
	im_select = {
		english = "com.apple.keylayout.ABC",
		get = { "im-select" },
		set = { "im-select" },
		note = INPUT_SOURCE_ONLY,
	},

	--- im-select.exe -- the Windows build of the same tool.
	---
	--- Windows speaks locale IDs, not input-source IDs: `1033` is en-US. Same
	--- contract otherwise, and the same blind spot.
	im_select_exe = {
		english = "1033",
		get = { "im-select.exe" },
		set = { "im-select.exe" },
		-- `im-select.exe` reads the layout of the FOREGROUND WINDOW, and answers
		-- `0` when there is none. Measured over SSH into Windows 11 ARM64 -- where
		-- this matters, because Windows OpenSSH leaves $SSH_TTY unset and so the
		-- plugin's SSH guard never fires. `0` is LOCALE_NEUTRAL and never a real
		-- layout, and locale IDs are open-ended so no `tokens` list could reject
		-- it; declaring it as the no-idea sentinel is what stops the plugin
		-- remembering it as the layout to restore.
		unknown = "0",
		note = INPUT_SOURCE_ONLY,
	},

	--- fcitx5, via its own remote-control CLI. Linux.
	---
	--- Deliberately no `tokens`: a fcitx5 install can carry any set of input
	--- methods, so an allow-list here would reject perfectly valid setups. The
	--- one-token rule in `sanitize` still catches garbage.
	---
	--- Measured on fcitx5 5.1.19: the contract fits exactly -- `-n` prints one
	--- token, `-s <name>` is silent and exits 0 -- with one sharp edge that the
	--- note records, and one that it cannot. `-n` needs a focused input context;
	--- with none it prints NOTHING and still exits 0, which `sanitize` rejects as
	--- empty output. That is the safe direction: an unreadable machine is never
	--- restored to blind, only forced to English.
	fcitx5 = {
		english = "keyboard-us",
		get = { "fcitx5-remote", "-n" },
		set = { "fcitx5-remote", "-s" },
		note = FCITX5_SILENT_FAILURE,
	},

	--- ibus, via its own CLI. Linux -- the default on GNOME.
	---
	--- `ibus engine` prints the active engine; `ibus engine <name>` selects one.
	--- Same shape as every other backend here, which is why it costs a table
	--- rather than a branch.
	---
	--- `xkb:us::eng` is the plain US layout as ibus names it. A machine whose
	--- English engine is something else says so with `english = "..."`; `ibus
	--- list-engine` prints the names this machine actually has.
	---
	--- Unlike macism, ibus IS the IME: selecting an engine turns the Vietnamese
	--- one off, which is the lever that matters. The note below is about
	--- something else -- see IBUS_EXITS_NONZERO.
	ibus = {
		english = "xkb:us::eng",
		get = { "ibus", "engine" },
		set = { "ibus", "engine" },
		note = IBUS_EXITS_NONZERO,
	},

	--- xkb-switch -- github.com/grwlf/xkb-switch. Linux/X11.
	---
	--- The lowest lever available: it moves the X keyboard layout and knows
	--- nothing about any IME, so it is last in the Linux chain rather than absent.
	--- On a machine with no input-method framework at all -- a plain us/vn XKB
	--- layout pair -- it is exactly right, and on a machine with one it carries
	--- the same blind spot macism does.
	xkb_switch = {
		english = "us",
		get = { "xkb-switch" },
		set = { "xkb-switch", "-s" },
		note = LAYOUT_ONLY,
	},
}
