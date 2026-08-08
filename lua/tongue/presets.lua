--- Built-in backends.
---
--- These are *data*, not privileged code: anything here can be written by hand
--- in `setup({ backend = ... })`, and a hand-written backend is resolved by the
--- exact same path. That is the whole reason this file is separate -- so that
--- "supported" never means "hardcoded somewhere you cannot reach".

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
