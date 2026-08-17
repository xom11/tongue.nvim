--- `restore_on_unfocus`: put the layout back when Neovim stops being the thing
--- you are typing into.
---
--- An input method is machine-global. Everything else in this plugin can afford
--- to ignore that, because "Normal mode" and "Insert mode" only exist while
--- Neovim has the keyboard -- but the moment it does not, forcing English is
--- forcing it on some *other* application, which is the one thing this plugin has
--- no mandate to do.
---
--- Three ways out of the editor, and only one of them is a focus event:
---
---   * focus lost      -- another pane, another tab, another window
---   * `VimSuspend`    -- `<C-z>`, back to the shell in the SAME pane
---   * `VimLeavePre`   -- `:q`, ditto
---
--- The last two fire no focus event at all: the terminal that owns the pane never
--- stopped being focused, so nothing tells the editor anything. They are covered
--- here because leaving them out fixes the symptom the user noticed and leaves
--- the two neighbouring ones behind, feeling like an intermittent bug.

local h = require("helpers")

local function st()
	return require("tongue").status()
end

local function fire(event)
	vim.api.nvim_exec_autocmds(event, { modeline = false })
end

return function(t)
	t.test("losing focus in Normal mode puts the layout back", function()
		h.arm({ machine = "vi", unfocus = true })
		h.settle()
		t.eq(h.machine(), "en", "precondition: Normal mode is English")
		t.eq(st().last_layout, "vi", "precondition: the layout was learned")

		fire("FocusLost")
		h.settle()
		t.eq(h.machine(), "vi", "the layout must be restored for whatever has the keyboard now")
	end)

	t.test("regaining focus forces English again", function()
		h.arm({ machine = "vi", unfocus = true })
		h.settle()
		fire("FocusLost")
		h.settle()
		t.eq(h.machine(), "vi", "precondition")

		fire("FocusGained")
		h.settle()
		t.eq(h.machine(), "en", "back in Normal mode, English is forced again")
		t.eq(st().last_layout, "vi", "and the layout is still remembered")
	end)

	t.test("off by default -- losing focus changes nothing", function()
		h.arm({ machine = "vi" })
		h.settle()
		local before = h.count("set")

		fire("FocusLost")
		h.settle()
		t.eq(h.machine(), "en", "the documented default is unchanged")
		t.eq(h.count("set"), before, "and it costs no process either")
	end)

	t.test("FocusGained while typing still clears the flag", function()
		-- The trap in the obvious implementation. `FocusGained` reconciles only
		-- when NOT typing -- IME candidate windows generate spurious focus events
		-- mid-composition and re-selecting the source there is the CJK flicker. But
		-- the *flag* must be recorded regardless: skip it and `focused` stays false
		-- past the return, so the next `<Esc>` asks for the layout instead of
		-- English and strands Normal mode in Vietnamese -- with no event left that
		-- would correct it.
		--
		-- Driven through `_on_focus` rather than the autocmd, and that is the whole
		-- point of the seam. `h.enter()` moves the state machine into Insert but not
		-- the editor, which under `nvim -l` cannot hold Insert at all -- so the
		-- autocmd's own `vim.fn.mode(1)` reports `"n"`, the guard is never reached,
		-- and this test passed against a deliberately broken version of it.
		local tongue = require("tongue")
		h.arm({ machine = "vi", unfocus = true })
		h.settle()
		h.enter()
		h.settle()
		t.eq(h.machine(), "vi", "precondition: Insert restored the layout")

		tongue._on_focus(false, true)
		tongue._on_focus(true, true) -- arrives while still in Insert
		h.settle()
		t.eq(st().focused, true, "the flag must be recorded even though the reconcile is skipped")

		h.leave()
		h.settle()
		t.eq(h.machine(), "en", "leaving Insert must still force English")
	end)

	t.test("FocusGained always reconciles, even when focus was never lost", function()
		-- The documented default behaviour, and the thing an early return on
		-- `focused == gained` would silently delete. With `restore_on_unfocus` off
		-- no FocusLost is registered at all, so `focused` is permanently true and a
		-- deduplicated handler would make every FocusGained a no-op -- taking the
		-- plugin's only answer to "I changed my IME with a global hotkey" with it.
		h.arm({ machine = "vi" })
		h.settle()
		h.set_machine("zh") -- behind the plugin's back, as a global hotkey would
		fire("FocusGained")
		h.settle()
		t.eq(h.machine(), "en", "regaining focus must re-assert English regardless")
	end)

	t.test("nothing to put back costs no process", function()
		-- Someone who types English in Insert too. `last_layout` is the English
		-- token, so the restore is a no-op -- and must be recognised as one before
		-- it spawns anything, because this fires on every focus change.
		h.arm({ machine = "en", unfocus = true })
		h.settle()
		local before = h.count("set")

		fire("FocusLost")
		h.settle()
		t.eq(h.machine(), "en")
		t.eq(h.count("set"), before, "no `set` for a restore that changes nothing")
	end)

	t.test("suspending puts the layout back, resuming forces English", function()
		h.arm({ machine = "vi", unfocus = true })
		h.settle()

		fire("VimSuspend")
		-- Deliberately NOT settled first. `<C-z>` stops the process, so an async
		-- callback scheduled here does not run until the user comes back -- by
		-- which time the shell they wanted the layout for is gone.
		t.eq(h.machine(), "vi", "the restore must have landed before the event returned")

		fire("VimResume")
		h.settle()
		t.eq(h.machine(), "en", "resuming is a return to Normal mode")
	end)

	t.test("quitting puts the layout back, synchronously", function()
		h.arm({ machine = "vi", unfocus = true })
		h.settle()

		fire("VimLeavePre")
		-- Same reason, harder: after this the event loop is gone entirely, so
		-- there is no "later" for a scheduled callback to run in.
		t.eq(h.machine(), "vi", "the restore must have landed before the event returned")
	end)

	t.test("quitting with the flag off leaves the machine alone", function()
		h.arm({ machine = "vi" })
		h.settle()
		fire("VimLeavePre")
		t.eq(h.machine(), "en", "the documented default does not touch the machine on exit")
	end)

	t.test("status reports the flag and the current focus", function()
		h.arm({ machine = "vi", unfocus = true })
		h.settle()
		t.eq(st().restore_on_unfocus, true)
		t.eq(st().focused, true)

		fire("FocusLost")
		h.settle()
		t.eq(st().focused, false, "`:Tongue status` must be able to explain why it is in Vietnamese")
	end)
end
