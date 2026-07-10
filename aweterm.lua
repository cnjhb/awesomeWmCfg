local lgi = require "lgi"
local Gtk = lgi.require("Gtk", "3.0")
local Gdk = lgi.require("Gdk", "3.0")
local GLib = lgi.GLib
local Vte = lgi.require("Vte", "2.91")
local HOME = os.getenv "HOME"
local SHELL = os.getenv "SHELL"
local term_colors = {
	"#21222c",
	"#ff5555",
	"#50fa7b",
	"#f1fa8c",
	"#bd93f9",
	"#ff79c6",
	"#8be9fd",
	"#f8f8f2",

	"#6272a4",
	"#ff6e6e",
	"#69ff94",
	"#ffffa5",
	"#d6acff",
	"#ff92df",
	"#a4ffff",
	"#ffffff",
}
local term_rgba = {
}
for i = 1, #term_colors do
	term_rgba[i] = Gdk.RGBA.parse(term_colors[i])
end

return function(arg)
	arg = arg or {}
	arg.cmd = arg.cmd or SHELL
	local term = Vte.Terminal {
		scrollback_lines = 20000
	}
	term:spawn_sync(Vte.PtyFlags.DEFAULT, HOME, { arg.cmd }, nil, GLib.SpawnFlags.DEFAULT, function()
	end)
	term:set_colors(nil, Gdk.RGBA.parse "#282a36", term_rgba)
	local win = Gtk.Window {
		icon_name = "terminal",
		child = term,
		title = "Terminal",
	}
	function term:on_child_exited()
		win:close()
	end

	term.on_termprop_changed[Vte.TERMPROP_XTERM_TITLE] = function()
		local title = term:get_termprop_string(Vte.TERMPROP_XTERM_TITLE)
		win.title = title and "" .. title or "Terminal"
	end
	function win:on_key_press_event(event)
		if event.state.CONTROL_MASK and event.state.SHIFT_MASK then
			if event.keyval == Gdk.KEY_C then
				term:copy_clipboard()
				return true
			elseif event.keyval == Gdk.KEY_V then
				term:paste_clipboard()
				return true
			end
		end
	end

	return win
end
