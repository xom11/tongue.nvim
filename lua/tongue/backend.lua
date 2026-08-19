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
---@param b tongue.Backend?
---@return tongue.Backend? backend
---@return string? err
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
	-- Carries no control meaning -- `health` prints it and nothing else reads it
	-- -- but a number reaching `vim.health` throws out of the very check the user
	-- ran to diagnose something.
	if b.note ~= nil and type(b.note) ~= "string" then
		return nil, "backend.note must be a string or nil"
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

--- What to look for, in priority order, per `uname` sysname.
---
--- `{ binary to probe for, preset key }`. This is data rather than a chain of
--- `if`s so that supporting one more tool is one line here plus one table in
--- `presets` -- no new branch, and nothing to keep in sync.
---
--- The ORDER is a promise, not an accident. `tongue` moves both levers (layout
--- and IME process); `macism` and `im-select` move one. A machine that has
--- `tongue` must keep choosing it, or adding these would quietly weaken the
--- exact guarantee the plugin exists for.
local CANDIDATES = {
	Darwin = {
		{ "tongue", "tongue" },
		{ "macism", "macism" },
		{ "im-select", "im_select" },
	},
	Linux = {
		{ "fcitx5-remote", "fcitx5" },
		{ "ibus", "ibus" },
		{ "xkb-switch", "xkb_switch" },
		-- WSL. A Linux `uname` with the Windows binary on $PATH is what WSL looks
		-- like from in here, and under WSL the input method that matters is the
		-- Windows one -- the terminal you are typing into is a Windows window.
		-- Last, so a real Linux desktop that happens to carry the exe is unaffected.
		{ "im-select.exe", "im_select_exe" },
	},
	Windows_NT = {
		{ "im-select.exe", "im_select_exe" },
	},
}

--- Look a preset up by name, tolerating the punctuation of the binary.
---
--- Preset keys are Lua identifiers so that `presets.im_select` reads like
--- `presets.tongue`, but nobody types Lua identifiers into their config -- they
--- type the name of the program they installed. One rule, not a table of
--- aliases: everything that is not alphanumeric becomes `_`.
---@param name string
---@return tongue.Backend? backend
---@return string? err
local function by_name(name)
	-- `gsub` returns TWO values; unparenthesised it would index `presets` with
	-- the name and then pass the match count along as a second argument.
	local b = presets[name] or presets[(name:gsub("[^%w]", "_"))]
	if b then
		return b
	end
	local known = vim.tbl_keys(presets)
	table.sort(known)
	return nil, ("unknown backend preset %q (known: %s)"):format(name, table.concat(known, ", "))
end

--- Is this an SSH session?
---
--- All three variables are set by sshd, and which of them survives to Neovim is
--- not a detail we get to ignore: tmux's default `update-environment` refreshes
--- `SSH_CONNECTION` on every client attach but NOT `SSH_TTY` (measured on tmux
--- 3.7b). Keying off `SSH_TTY` alone therefore misses `ssh box` -> `tmux attach`
--- -> `nvim` entirely, and the plugin spends a process per mode change driving
--- an input method on a machine nobody is looking at.
---
--- An exported-but-empty variable reads as `""`, which is truthy in Lua and is
--- how the old check could also fire on a purely local session.
---
--- Exported because `health` asks the same question at a different time, and one
--- copy of the empty-string rule is the point: a second loop written next to a
--- warning would drift, and the drifted copy would fire on a machine that never
--- saw SSH at all.
---@return string? name the variable that fired
function M.ssh_var()
	for _, name in ipairs({ "SSH_TTY", "SSH_CONNECTION", "SSH_CLIENT" }) do
		local v = vim.env[name]
		if type(v) == "string" and v ~= "" then
			return name
		end
	end
	return nil
end

--- Which backend, before any `english` override. See `M.resolve`.
---@return tongue.Backend? backend
---@return string reason
---@return boolean? fatal
local function pick(opts, probe)
	-- An explicitly configured backend wins outright, including over SSH: the
	-- user said so, and second-guessing an explicit setting is how config stops
	-- being predictable.
	if type(opts.backend) == "string" then
		-- Detection is skipped entirely rather than used as a fallback. A typo
		-- that silently resolves to some other backend is worse than an error.
		local b, err = by_name(opts.backend)
		if not b then
			return nil, err, true
		end
		return b, "explicit: " .. opts.backend
	end
	if opts.backend ~= nil then
		return opts.backend, "explicit" -- shape is checked by `M.resolve`
	end

	-- Auto-detection stops here in an SSH session. The input method that matters
	-- is the one on the machine in front of you, and that is the client's, not
	-- this one's -- switching here would change nothing you can see while
	-- spawning a process on every mode change.
	local ssh = M.ssh_var()
	if ssh then
		-- Naming the variable makes `:checkhealth` actionable: a stale `SSH_TTY`
		-- inherited from a tmux server that was first started over SSH is the one
		-- way this fires when it should not, and you cannot fix what you cannot see.
		return nil,
			("SSH session (%s is set; auto-detection skipped, set `backend` explicitly to override)"):format(ssh)
	end

	local sysname = probe.sysname or (vim.uv or vim.loop).os_uname().sysname
	local executable = probe.executable or function(name)
		return vim.fn.executable(name) == 1
	end

	for _, c in ipairs(CANDIDATES[sysname] or {}) do
		if executable(c[1]) then
			return presets[c[2]], c[1]
		end
	end

	return nil, ("no supported input-method tool found on %s"):format(sysname)
end

--- Pick a backend for this machine.
---
--- Returns `backend, reason` when one is found, or `nil, reason` when the plugin
--- should stay inert. `reason` is for `:checkhealth`, not for control flow.
---
--- `probe` exists so this is testable at all. Left to ask the real OS, the only
--- chain that could ever be exercised is the one belonging to whatever machine
--- the suite runs on -- and a Windows branch nobody can run is precisely how the
--- last one shipped broken. It is `init.lua`'s discipline (know nothing about
--- the machine, take it as an argument) applied one level down.
---
--- The third return value separates the two ways this can fail. Inert is a
--- legitimate outcome -- no IME tool on this machine, or an SSH session -- and
--- must stay quiet. A config bug is not, and staying quiet about one is how it
--- survives for months. `init.lua` needs to tell them apart and cannot do it by
--- reading `opts`: whether `english` is wrong depends on which backend received
--- it.
---@param opts tongue.Opts?
---@param probe table? `{ sysname: string, executable: fun(name):boolean }`, partial
---@return tongue.Backend? backend
---@return string reason
---@return boolean? fatal `true` when the reason is a config bug
function M.resolve(opts, probe)
	opts = opts or {}

	-- Shape of the config first, before the machine is consulted at all. A
	-- malformed `english` is wrong on every machine, including one with no
	-- backend and including SSH -- and if this ran later, "no supported tool
	-- found" would outrank it and the user would hear about their package list
	-- instead of their typo.
	if opts.english ~= nil and (type(opts.english) ~= "string" or opts.english == "") then
		return nil, "english must be a non-empty string", true
	end

	local b, why, fatal = pick(opts, probe or {})
	if not b then
		return nil, why, fatal
	end

	if opts.english ~= nil then
		-- COPY. Overriding in place would scribble on the shared preset table for
		-- the rest of the session: a second `setup()` -- which `:Lazy reload` and
		-- every config reload does -- would silently inherit the first one's
		-- override.
		b = vim.deepcopy(b)
		b.english = opts.english
	end

	-- After the override, and on every path including the built-in presets.
	-- Presets used to be trusted unconditionally; they are data, and data gets
	-- edited. This is also what turns `backend = "tongue", english = "<an
	-- input-source ID>"` into a loud error instead of a plugin that runs while
	-- `sanitize` discards every reading it ever takes.
	local ok, err = M.validate(b)
	if not ok then
		return nil, err, true
	end
	return b, why
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
---
--- The third return separates "the machine is in English" from "the backend has
--- no idea what the machine is in", and that separation is load-bearing. Both
--- used to come back as `english`, with two silent consequences: a shrug erased
--- the layout you were typing in (the `observe` branch read it as a deliberate
--- switch to English), and -- worse -- Normal mode stopped being forced at all,
--- because "already English" means no `set` is issued. Reachable with the shipped
--- presets: `im-select.exe` answers `0` whenever there is no foreground window,
--- and `tongue` answers `unknown` whenever the live state matches no configured
--- mode.
---@param b tongue.Backend
---@param raw string?
---@return string? token `english` when unknown, so a caller can still act
---@return string? err
---@return boolean? unknown the backend does not recognise the live state
function M.sanitize(b, raw)
	local s = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then
		return nil, "empty output"
	end
	if b.unknown and s == b.unknown then
		return b.english, nil, true
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
