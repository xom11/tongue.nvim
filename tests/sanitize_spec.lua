local backend = require("tongue.backend")

return function(t)
	local B = {
		english = "en",
		get = { "x" },
		set = { "x" },
		unknown = "unknown",
		tokens = { "en", "vi", "zh" },
	}
	local OPEN = { english = "keyboard-us", get = { "x" }, set = { "x" } } -- no `tokens`

	t.test("accepts clean tokens, trimmed", function()
		t.eq(backend.sanitize(B, "en\n"), "en")
		t.eq(backend.sanitize(B, "vi\n"), "vi")
		t.eq(backend.sanitize(B, "  zh  \n"), "zh")
	end)

	t.test("maps the backend's `unknown` sentinel to English", function()
		-- Feeding "unknown" back would just be `tongue unknown` -> exit 2.
		t.eq(backend.sanitize(B, "unknown\n"), "en")
	end)

	t.test("rejects empty output", function()
		local tok, err = backend.sanitize(B, "")
		t.eq(tok, nil)
		t.eq(err, "empty output")
	end)

	t.test("rejects stderr bleed instead of welding it into a token", function()
		-- THE regression this file exists for. `vim.fn.system` merges stderr into
		-- stdout; collapsing whitespace turns each of these into one
		-- plausible-looking token that then gets stored and replayed forever.
		for _, raw in ipairs({
			"WARN: something\nvi\n",
			"objc[1234]: class registered twice\nvi\n",
			"dyld: lazy symbol binding failed\nen\n",
		}) do
			local tok, err = backend.sanitize(B, raw)
			t.eq(tok, nil, ("must reject %q"):format(raw))
			t.eq(err, "multi-token output")
		end
	end)

	t.test("rejects a token the backend never declared", function()
		-- What a name collision looks like: some other program called `tongue`
		-- answering with something entirely reasonable-for-it.
		local tok, err = backend.sanitize(B, "com.apple.keylayout.ABC\n")
		t.eq(tok, nil)
		t.eq(err, "token not in the backend's declared set")
	end)

	t.test("a backend with no declared set still rejects multi-token output", function()
		-- fcitx5 deliberately declares no `tokens` (its input-method set is open),
		-- so the one-token rule is the ONLY garbage detector it has.
		t.eq(backend.sanitize(OPEN, "lotus\n"), "lotus")
		t.eq(backend.sanitize(OPEN, "keyboard-us\n"), "keyboard-us")
		local tok = backend.sanitize(OPEN, "WARN: x\nlotus\n")
		t.eq(tok, nil, "multi-token must still fail without a declared set")
	end)

	t.test("validate() rejects backends that would fail silently", function()
		local cases = {
			{ nil, "backend must be a table" },
			{ {}, "backend.english must be a non-empty string" },
			{ { english = "" }, "backend.english must be a non-empty string" },
			{ { english = "en" }, "backend.get must be a non-empty list of strings" },
			{ { english = "en", get = {} }, "backend.get must be a non-empty list of strings" },
			{
				{ english = "en", get = { "x" } },
				"backend.set must be a non-empty list of strings",
			},
			{
				{ english = "en", get = { "x" }, set = { "x" }, unknown = 7 },
				"backend.unknown must be a string or nil",
			},
			{
				-- An allow-list that omits `english` would discard every reading
				-- the plugin is guaranteed to produce.
				{ english = "en", get = { "x" }, set = { "x" }, tokens = { "vi" } },
				"backend.tokens must contain backend.english",
			},
		}
		for _, case in ipairs(cases) do
			local b, err = backend.validate(case[1])
			t.eq(b, nil, ("should reject %s"):format(vim.inspect(case[1])))
			t.eq(err, case[2])
		end
		t.ok(backend.validate(B) ~= nil, "the good one must pass")
		t.ok(backend.validate(OPEN) ~= nil, "no-tokens backend must pass")
	end)
end
