--- Backend resolution: the ONLY module that knows what machine this is.
---
--- `init.lua` deliberately knows nothing about the OS, `$SSH_TTY`, or which
--- executables exist. That is what makes the state machine testable: a test
--- hands it a fake backend and the real detection never runs.

local presets = require("tongue.presets")

local M = {}

M.presets = presets

local function is_string_list(v)
	if type(v) ~= "table" or #v == 0 then
		return false
	end
	for _, item in ipairs(v) do
		if type(item) ~= "string" then
			return false
		end
	end
	return true
end

--- Validate a backend table.
---
--- Returns `backend` on success, or `nil, err`. A malformed backend is an
--- error, never a silent fallback to "do nothing" -- a plugin whose entire job
--- is to stop you typing in the wrong language has no business failing quietly.
---@param b table?
---@return table?, string?
function M.validate(b)
	if type(b) ~= "table" then
		return nil, "backend must be a table"
	end
	if type(b.english) ~= "string" or b.english == "" then
		return nil, "backend.english must be a non-empty string"
	end
	if not is_string_list(b.get) then
		return nil, "backend.get must be a non-empty list of strings"
	end
	if not is_string_list(b.set) then
		return nil, "backend.set must be a non-empty list of strings"
	end
	if b.unknown ~= nil and type(b.unknown) ~= "string" then
		return nil, "backend.unknown must be a string or nil"
	end
	if b.tokens ~= nil then
		if not is_string_list(b.tokens) then
			return nil, "backend.tokens must be a non-empty list of strings, or nil"
		end
		-- Without this, `english` itself would fail `sanitize` and every single
		-- read would be discarded -- an allow-list that rejects the one token the
		-- plugin is guaranteed to produce.
		if not vim.tbl_contains(b.tokens, b.english) then
			return nil, "backend.tokens must contain backend.english"
		end
	end
	return b
end

--- Pick a backend for this machine.
---
--- Returns `backend, reason` when one is found, or `nil, reason` when the plugin
--- should stay inert. `reason` is for `:checkhealth`, not for control flow.
---@param opts table?
---@return table?, string
function M.resolve(opts)
	opts = opts or {}

	-- An explicitly configured backend wins outright, including over SSH: the
	-- user said so, and second-guessing an explicit setting is how config stops
	-- being predictable.
	if opts.backend ~= nil then
		local b, err = M.validate(opts.backend)
		if not b then
			return nil, err
		end
		return b, "explicit"
	end

	-- Auto-detection stops here in an SSH session. The input method that matters
	-- is the one on the machine in front of you, and that is the client's, not
	-- this one's -- switching here would change nothing you can see while
	-- spawning a process on every mode change.
	if vim.env.SSH_TTY then
		return nil, "SSH session (auto-detection skipped; set `backend` explicitly to override)"
	end

	local uv = vim.uv or vim.loop
	local sysname = uv.os_uname().sysname

	if sysname == "Darwin" and vim.fn.executable("tongue") == 1 then
		return presets.tongue, "tongue"
	end
	if sysname == "Linux" and vim.fn.executable("fcitx5-remote") == 1 then
		return presets.fcitx5, "fcitx5-remote"
	end

	return nil, ("no supported input-method tool found on %s"):format(sysname)
end

--- Turn raw backend stdout into a token, or `nil, reason`.
---
--- Interior whitespace is REJECTED rather than stripped, and that is the whole
--- garbage detector. A backend that writes a warning to stderr yields output
--- like `"WARN: something\nvi"` through any reader that merges the two streams
--- -- which is most of them, `vim.fn.system` included. Collapsing whitespace
--- turns that into `WARNsomethingvi`: one plausible-looking token, which then
--- gets stored as the layout to restore and fed back as an argument forever.
--- Nothing about it looks wrong until you notice your IME never comes back.
---
--- This lives here rather than in `init.lua` because it is pure and depends only
--- on the backend -- which makes it directly testable.
---@param b table backend
---@param raw string?
---@return string?, string?
function M.sanitize(b, raw)
	local s = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then
		return nil, "empty output"
	end
	if b.unknown and s == b.unknown then
		return b.english
	end
	if s:find("%s") then
		return nil, "multi-token output"
	end
	if b.tokens and not vim.tbl_contains(b.tokens, s) then
		return nil, "token not in the backend's declared set"
	end
	return s
end

return M
