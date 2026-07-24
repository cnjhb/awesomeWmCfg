local lgi = require "lgi"
local Gtk = lgi.require("Gtk", "3.0")
local Gdk = lgi.require("Gdk", "3.0")
local GLib = lgi.GLib
local GLibUnix = lgi.GLibUnix
local Vte = lgi.require("Vte", "2.91")
local _, gears = pcall(require, "gears")
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

local sp = require "libserialport"


return function(arg)
	arg.device = arg.device or "/dev/ttyUSB0"
	arg.baudrate = arg.baudrate or 115200
	local t = sp.get_port_by_name(arg.device)
	if not t then
		return
	end

	t:open(sp.SP_MODE_READ_WRITE)
	t:set_baudrate(arg.baudrate)
	t:set_bits(8)
	t:set_parity(sp.SP_PARITY_NONE)
	t:set_stopbits(1)
	t:set_flowcontrol(sp.SP_FLOWCONTROL_NONE)

	local fd = t:get_port_handle()

	local term = Vte.Terminal {
	}
	term:set_colors(nil, Gdk.RGBA.parse "#282a36", term_rgba)

	local win = Gtk.Window {
		title = arg.device .. " " .. arg.baudrate,
		child = term,
		default_width = 800,
		default_height = 600,
	}

	function term:on_commit(text)
		t:nonblocking_write(text)
	end

	local in_tag = GLibUnix.fd_add_full(GLib.PRIORITY_DEFAULT, fd, GLib.IOCondition.IN, function()
		term:feed(t:nonblocking_read(1024))
		return GLib.SOURCE_CONTINUE
	end)

	local hup_tag = GLibUnix.fd_add_full(GLib.PRIORITY_DEFAULT, fd, GLib.IOCondition.HUP, function()
		win:close()
		return GLib.SOURCE_CONTINUE
	end)

	if gears then
		win:set_icon_from_file(gears.filesystem.get_awesome_icon_dir().."/awesome64.png")
	end

	function win:on_destroy()
		GLib.Source.remove(in_tag)
		GLib.Source.remove(hup_tag)
		t:close()
	end

	return win
end
