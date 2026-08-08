-- Sourced by Neovim at startup, for every user, before anything is configured.
-- So it does exactly two things: guard against being sourced twice, and declare
-- one command whose callback loads the plugin lazily. Nothing here calls
-- `require("tongue")` -- doing so would run the plugin's module body on every
-- start, including for people who never call `setup()`.

if vim.g.loaded_tongue then
	return
end
vim.g.loaded_tongue = 1

vim.api.nvim_create_user_command("Tongue", function(a)
	require("tongue.command").run(a.args)
end, {
	nargs = "?",
	desc = "tongue.nvim: status | enable | disable | toggle | sync",
	complete = function(lead)
		return require("tongue.command").complete(lead)
	end,
})
