-- init for the throwaway Neovim that `wiring_spec.lua` drives over --remote-send.
-- Everything it needs arrives through the environment.

vim.opt.rtp:prepend(vim.env.TONGUE_ROOT)

-- Counted so the spec can assert the thing the docs claim and the whole
-- ModeChanged design rests on: <C-c> leaves Insert WITHOUT firing InsertLeave.
_G.insert_leaves = 0
vim.api.nvim_create_autocmd("InsertLeave", {
	callback = function()
		_G.insert_leaves = _G.insert_leaves + 1
	end,
})

require("tongue").setup({
	backend = {
		english = "en",
		get = { vim.env.FAKE_IM },
		set = { vim.env.FAKE_IM },
		unknown = "unknown",
		tokens = { "en", "vi", "zh" },
	},
	notify = false,
})
