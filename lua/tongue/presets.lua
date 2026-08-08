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
		note = INPUT_SOURCE_ONLY,
	},

	--- fcitx5, via its own remote-control CLI. Linux.
	---
	--- Deliberately no `tokens`: a fcitx5 install can carry any set of input
	--- methods, so an allow-list here would reject perfectly valid setups. The
	--- one-token rule in `sanitize` still catches garbage.
	fcitx5 = {
		english = "keyboard-us",
		get = { "fcitx5-remote", "-n" },
		set = { "fcitx5-remote", "-s" },
	},
}
