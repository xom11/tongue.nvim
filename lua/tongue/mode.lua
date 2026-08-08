--- What counts as "typing".
---
--- Its own module because it is the subtlest thing here and because being pure
--- makes it directly testable against the full mode-string table -- several of
--- which are impossible to reach reliably from a headless test.

local M = {}

--- Does this mode turn keystrokes into text?
---
--- Reference: `:help mode()`.
---
---   i, ic, ix        Insert, and its completion sub-modes    -> yes
---   R, Rc, Rx, Rv    Replace and friends                     -> yes
---   t                Terminal-insert                         -> yes
---   niI, niR, niV    i_CTRL-O: ONE Normal command, then back -> yes, see below
---   n, no, nov...    Normal, operator-pending                -> no
---   nt, ntT          Terminal-normal -- starts with `n`      -> no
---   c, cv            Command-line                            -> no, see below
---   v, V, s, S       Visual, Select                          -> no, see below
---
--- `ni*` counts as typing on purpose. `i_CTRL-O` runs a single Normal command
--- and returns to Insert, all inside a millisecond, while an input-method switch
--- takes ~200 ms. Acting on it could never land in time -- it could only produce
--- a visible flicker and two wasted processes.
---
--- Command-line mode reads as Normal. That is right for `:` and arguably wrong
--- for `/`, but the mode string cannot tell them apart, and forcing English on
--- `:` is the behaviour people actually want.
---
--- Select mode reads as Normal even though typing there replaces the selection:
--- the first printable key moves it straight to Insert, which fires ModeChanged
--- again and corrects it one switch later.
---@param mode string result of `mode(1)`, or `v:event.old_mode` / `new_mode`
---@return boolean
function M.typing(mode)
	return mode:find("^[iRt]") ~= nil or mode:find("^ni") ~= nil
end

return M
