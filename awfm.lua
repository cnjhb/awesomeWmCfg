-- awfm: a Thunar-ish file manager for awesome, written with lgi + Gtk3.
--
-- All file access goes through Gio, so local paths and gvfs locations
-- (sftp://, smb://, dav://, recent:///, trash:/// ...) behave the same.
-- Directory listings use lgi's coroutine based async API (Gio.Async.start
-- + the async_* methods), so a slow mount cannot freeze the window. Copy,
-- move and trash run through the synchronous Gio entry points: the async
-- variants in this box's GIR metadata are mis-wired (see transfer()).
--
-- Usage from rc.lua:
--   local awfm = require "awfm"
--   awfm.launch { path = "~/Pictures", terminal = "sakura" }
--
-- Notes about this environment (lgi quirks that shaped the code below):
--   * GTK objects have no connect_signal here, signals are set as
--     properties: button.on_clicked = function() end
--   * bitflags arguments must never be nil, hence the NONE/OVERWRITE
--   * Gio.FileType enumerations come back as names, so compare tostring()
--   * accessing a member this GIR does not know throws, it does not return
--     nil, so nothing is ever probed with if obj.member then
--   * the coroutine based async calls yield, so they are funnelled through
--     await(), which wraps them in pcall and reports failure as a value
local lgi = require "lgi"
local Gtk = lgi.require("Gtk", "3.0")
local Gdk = lgi.require("Gdk", "3.0")
local GLib = lgi.GLib
local Gio = lgi.Gio
local Pango = lgi.Pango
local GdkPixbuf = lgi.require("GdkPixbuf", "2.0")
local GObject = lgi.GObject
local naughty = require "naughty"
local awful = require "awful"

local NONE = Gio.FileQueryInfoFlags.NONE
local OVERWRITE = Gio.FileCopyFlags.OVERWRITE
local HOME = GLib.get_home_dir()
local HOME_URI = Gio.File.new_for_path(HOME):get_uri()
local ICON_SIZE = 48
local TRASH_URI = "trash:///"
local RECENT_URI = "recent:///"
local MAX_ROWS = 5000

local TYPE_PIXBUF = GdkPixbuf.Pixbuf._gtype
local TYPE_TEXT = GObject.type_from_name "gchararray"
local TYPE_BOOL = GObject.type_from_name "gboolean"

-- Gio.FileInfo hands the file type back as its name here, while the
-- enumeration constant prints as a number, so accept either
local DIRECTORY = { "DIRECTORY", tostring(Gio.FileType.DIRECTORY) }
local ATTRS = table.concat({
	"standard::name", "standard::type", "standard::size", "standard::icon",
	"standard::content-type", "standard::is-hidden", "standard::is-symlink",
	"access::can-write", "access::can-execute", "time::modified",
}, ",")
local TRASH_ATTRS = "standard::name,standard::type,standard::size,standard::icon," ..
	"trash::deletion-date,access::can-write"
-- recent:// hands out opaque ids as standard::name, so ask for the display
-- name and for standard::target-uri, which carries the bookmarked uri
local RECENT_ATTRS = table.concat({
	"standard::name", "standard::display-name", "standard::target-uri",
	"standard::type", "standard::size", "standard::icon", "standard::content-type",
	"standard::is-hidden", "standard::is-symlink", "access::can-write", "time::modified",
}, ",")

-- store columns
local COL_ICON, COL_NAME, COL_URI, COL_ISDIR, COL_SIZE, COL_TIME, COL_TIP = 1, 2, 3, 4, 5, 6, 7

-- ---------------------------------------------------------------- helpers

local function idle(fn)
	-- never talk to Gio or GTK straight from an X event handler
	GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
		fn()
		return false
	end)
end

-- Every async_* call yields, so it cannot be wrapped in a plain pcall. This
-- box's lgi also gets confused once a bare async call yields for the second
-- time in one coroutine (the GError escapes through the main loop instead of
-- coming back as a return value), while yielding across pcall works. So all
-- async calls funnel through here and report failure as a return value.
--
-- Pass exactly the arguments the C function wants: lgi fills in io_priority,
-- cancellable and the callback itself, and takes the receiver as the first
-- one. Anything extra lands on the progress callback slot and blows up.
local function await(fn, ...)
	local res = { n = select("#", ...), pcall(fn, ...) }
	if not res[1] then
		return nil, res[2]
	end
	return unpack(res, 2, res.n + 1)
end

local function notify(title, text)
	naughty.notification {
		title = title,
		message = text or "",
		timeout = 5,
	}
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_lines(s)
	local out = {}
	for line in (s or ""):gmatch "[^\n]+" do
		out[#out + 1] = line
	end
	return out
end

-- "img2.png" -> "img00000000000000000002.png", so plain string compare
-- sorts the way people expect
local function natural_key(name)
	return name:lower():gsub("%d+", function(d)
		return ("%018d"):format(tonumber(d) or 0)
	end)
end

local function human_size(bytes)
	local units = { "B", "K", "M", "G", "T" }
	local size, unit = bytes, 1
	while size >= 1024 and unit < #units do
		size, unit = size / 1024, unit + 1
	end
	if unit == 1 then
		return ("%d %s"):format(size, units[unit])
	end
	return ("%.1f %s"):format(size, units[unit])
end

local function file_time(date_time)
	if not date_time then
		return ""
	end
	return date_time:format "%Y-%m-%d %H:%M"
end

local function is_directory(info)
	local kind = tostring(info:get_file_type())
	for _, name in ipairs(DIRECTORY) do
		if kind == name then
			return true
		end
	end
	return false
end

-- first icon name the icon theme actually knows
local function pick_icon(theme, ...)
	for i = 1, select("#", ...) do
		local name = select(i, ...)
		if name and theme:has_icon(name) then
			return name
		end
	end
	return "text-x-generic"
end

local function icon_pixbuf(theme, info, isdir)
	if not info then
		return theme:load_icon("text-x-generic", ICON_SIZE, Gtk.IconLookupFlags.FORCE_SIZE)
	end
	local icon = info:get_icon()
	if icon then
		local ok, names = pcall(function() return icon:get_names() end)
		if ok and names then
			for _, name in ipairs(names) do
				if theme:has_icon(name) then
					local pixbuf = theme:load_icon(name, ICON_SIZE, Gtk.IconLookupFlags.FORCE_SIZE)
					if pixbuf then
						return pixbuf
					end
				end
			end
		end
		-- a real file (e.g. an image): scale it down instead
		local okp, path = pcall(function() return icon:get_file():get_path() end)
		if okp and path then
			local okb, pixbuf = pcall(GdkPixbuf.Pixbuf.new_from_file_at_scale,
				path, ICON_SIZE, ICON_SIZE, true)
			if okb and pixbuf then
				return pixbuf
			end
		end
	end
	return theme:load_icon(isdir and "folder" or "text-x-generic",
		ICON_SIZE, Gtk.IconLookupFlags.FORCE_SIZE)
end

local function special_dir(kind, fallback)
	local ok, dir = pcall(GLib.get_user_special_dir, kind)
	if ok and type(dir) == "string" and dir ~= "" then
		return (dir:gsub("/+$", ""))
	end
	return HOME .. "/" .. fallback
end

local function shellescape(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function to_uri(text)
	if text:match "^%a[%w+.-]*://" then
		return text
	end
	local path = text:gsub("^~", HOME)
	local ok, uri = pcall(GLib.filename_to_uri, path, nil)
	if ok then
		return uri
	end
	return Gio.File.new_for_path(path):get_uri()
end

local function parent_uri(uri)
	local parent = Gio.File.new_for_uri(uri):get_parent()
	return parent and parent:get_uri() or uri
end

local function base_name(uri)
	local name = Gio.File.new_for_uri(uri):get_basename()
	return (name and name ~= "") and name or uri
end

-- what to call the place we are in: gvfs names trash:/// and recent:///
-- after their basenames, which read as "/" and ""
local function place_name(uri)
	if uri == TRASH_URI then
		return "Trash"
	end
	if uri == RECENT_URI then
		return "Recent"
	end
	return base_name(uri)
end

local function file_of(uri)
	if uri:sub(1, 1) == "/" then
		return Gio.File.new_for_path(uri)
	end
	return Gio.File.new_for_uri(uri)
end

local function is_directory_uri(uri)
	local ok, info = pcall(function()
		return file_of(uri):query_info("standard::type", NONE)
	end)
	return ok and is_directory(info)
end

-- gvfs does not hand out trash::original-path, so read the .trashinfo
-- files of the home trash directly
local function trash_original(name)
	local fh = io.open(HOME .. "/.local/share/Trash/info/" .. name .. ".trashinfo", "r")
	if not fh then
		return nil
	end
	local found
	for line in fh:lines() do
		found = line:match "^Path=(.+)$" or found
	end
	fh:close()
	if not found then
		return nil
	end
	found = trim(found)
	if found:sub(1, 1) == "/" then
		return found
	end
	return HOME .. "/.local/share/Trash/files/" .. found
end

local function places()
	return {
		{ name = "Home", icon = { "user-home", "folder" }, uri = to_uri(HOME) },
		{ name = "Desktop", icon = { "user-desktop", "folder" },
			uri = to_uri(special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP, "Desktop")) },
		{ name = "Documents", icon = { "folder-documents", "folder" },
			uri = to_uri(special_dir(GLib.UserDirectory.DIRECTORY_DOCUMENTS, "Documents")) },
		{ name = "Downloads", icon = { "folder-download", "folder" },
			uri = to_uri(special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOADS, "Downloads")) },
		{ name = "Music", icon = { "folder-music", "audio-x-generic", "folder" },
			uri = to_uri(special_dir(GLib.UserDirectory.DIRECTORY_MUSIC, "Music")) },
		{ name = "Pictures", icon = { "folder-pictures", "image-x-generic", "folder" },
			uri = to_uri(special_dir(GLib.UserDirectory.DIRECTORY_PICTURES, "Pictures")) },
		{ name = "Videos", icon = { "folder-videos", "video-x-generic", "folder" },
			uri = to_uri(special_dir(GLib.UserDirectory.DIRECTORY_VIDEOS, "Videos")) },
		{ name = "Recent", icon = { "document-open-recent", "document-open", "folder" },
			uri = RECENT_URI },
		{ name = "Trash", icon = { "user-trash", "user-trash-full" }, uri = TRASH_URI },
	}
end

local function mounted_volumes()
	local out = {}
	local ok, monitor = pcall(function() return Gio.VolumeMonitor.get() end)
	if not ok or not monitor then
		return out
	end
	local mounts = monitor:get_mounts() or {}
	for _, mount in ipairs(mounts) do
		local root = mount:get_root()
		local path = root and root:get_path()
		if path and path ~= "/" then
			out[#out + 1] = {
				name = mount:get_name() or path,
				icon = { "drive-harddisk", "drive-removable-media", "media-flash", "computer" },
				uri = root:get_uri(),
			}
		end
	end
	return out
end

local function button(icon_name, tooltip, callback)
	local b = Gtk.Button {
		image = Gtk.Image { icon_name = icon_name },
		tooltip_text = tooltip,
	}
	b.on_clicked = callback
	b:show()
	return b
end

local function prompt(win, opts)
	local dialog = Gtk.Dialog {
		title = opts.title,
		transient_for = win,
		modal = true,
		use_header_bar = 1,
	}
	dialog:add_button("Cancel", Gtk.ResponseType.CANCEL)
	dialog:add_button(opts.action or "OK", Gtk.ResponseType.OK)
	dialog:set_default_response(Gtk.ResponseType.OK)
	local entry = Gtk.Entry {
		text = opts.initial or "",
		activates_default = true,
		width_chars = 40,
		xalign = 0,
	}
	local box = Gtk.Box {
		orientation = Gtk.Orientation.VERTICAL,
		spacing = 8,
		border_width = 12,
	}
	local label = Gtk.Label { label = opts.label, xalign = 0 }
	label:show()
	entry:show()
	box:pack_start(label, false, false, 0)
	box:pack_start(entry, false, false, 0)
	dialog:get_content_area():pack_start(box, false, false, 0)
	dialog.on_response = function(self, response)
		local text = trim(entry.text)
		self:destroy()
		if response == Gtk.ResponseType.OK and text ~= "" then
			opts.on_ok(text)
		end
	end
	dialog:show_all()
	entry:grab_focus()
	entry:select_region(0, -1)
	return dialog
end

local function confirm(win, opts)
	local dialog = Gtk.MessageDialog {
		transient_for = win,
		modal = true,
		message_type = Gtk.MessageType.QUESTION,
		buttons = Gtk.ButtonsType.NONE,
		text = opts.text,
		secondary_text = opts.secondary,
		use_header_bar = 1,
	}
	dialog:add_button("Cancel", Gtk.ResponseType.CANCEL)
	dialog:add_button(opts.action or "Delete", Gtk.ResponseType.ACCEPT)
	dialog:set_default_response(Gtk.ResponseType.ACCEPT)
	dialog.on_response = function(self, response)
		self:destroy()
		if response == Gtk.ResponseType.ACCEPT then
			opts.on_ok()
		end
	end
	dialog:show_all()
	return dialog
end

local function popup_menu(items, event)
	local menu = Gtk.Menu()
	for _, item in ipairs(items) do
		if item == "sep" then
			local sep = Gtk.SeparatorMenuItem()
			sep:show()
			menu:append(sep)
		else
			local entry = Gtk.MenuItem {
				label = item.label,
				sensitive = item.enabled ~= false,
			}
			if item.action then
				entry.on_activate = item.action
			end
			menu:append(entry)
		end
	end
	menu.on_selection_done = function() menu:destroy() end
	menu:show_all()
	if event then
		menu:popup_at_pointer(event)
	else
		menu:popup()
	end
	return menu
end

-- ----------------------------------------------------------------- window

local current
local control

local function new(arg)
	arg = arg or {}
	local terminal = arg.terminal or os.getenv "TERMINAL" or "xterm"
	local show_hidden = arg.show_hidden and true or false
	local theme = Gtk.IconTheme.get_default()

	local win = Gtk.Window {
		title = "Files",
		default_width = 960,
		default_height = 640,
	}

	-- state
	local store = Gtk.ListStore.new { TYPE_PIXBUF, TYPE_TEXT, TYPE_TEXT,
		TYPE_BOOL, TYPE_TEXT, TYPE_TEXT, TYPE_TEXT }
	local history = {}
	local history_index = 0
	local clipboard = {}
	local sidebar_rows = {}
	local truncated = false
	local active_cancel
	local generation = 0
	local ready = false
	-- uris that should be selected again once the next listing lands, used when
	-- a row survives a reload under a different name (rename)
	local pending_select = {}

	-- widget callbacks below are wired before these are defined
	local load, go, go_back, go_forward, go_up
	local toggle_hidden, toggle_location, current_uri

	-- ----------------------------------------------------------- widgets
	local view = Gtk.TreeView { model = store }
	view:append_column((function()
		local col = Gtk.TreeViewColumn { title = "" }
		local cell = Gtk.CellRendererPixbuf()
		col:pack_start(cell, false)
		col:add_attribute(cell, "pixbuf", COL_ICON - 1)
		return col
	end)())
	view:append_column((function()
		local col = Gtk.TreeViewColumn {
			title = "Name",
			expand = true,
			resizable = true,
			min_width = 240,
		}
		local cell = Gtk.CellRendererText {
			ellipsize = Pango.EllipsizeMode.END,
		}
		col:pack_start(cell, true)
		col:add_attribute(cell, "text", COL_NAME - 1)
		return col
	end)())
	view:append_column((function()
		local col = Gtk.TreeViewColumn { title = "Size" }
		local cell = Gtk.CellRendererText {
			xalign = 1,
			ellipsize = Pango.EllipsizeMode.END,
		}
		col:pack_start(cell, false)
		col:add_attribute(cell, "text", COL_SIZE - 1)
		return col
	end)())
	view:append_column((function()
		local col = Gtk.TreeViewColumn { title = "Modified" }
		local cell = Gtk.CellRendererText { xalign = 1 }
		col:pack_start(cell, false)
		col:add_attribute(cell, "text", COL_TIME - 1)
		return col
	end)())
	view:set_tooltip_column(COL_TIP - 1)
	view:set_headers_visible(true)
	view:set_enable_search(false)
	view:append_column((function()
		local col = Gtk.TreeViewColumn { title = "" }
		col:pack_start(Gtk.CellRendererText(), false)
		return col
	end)())
	view:get_selection():set_mode(Gtk.SelectionMode.MULTIPLE)
	view:grab_focus()

	local scroller = Gtk.ScrolledWindow {
		hscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
		vscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
		shadow_type = Gtk.ShadowType.IN,
	}
	scroller:add(view)

	local status_label = Gtk.Label { xalign = 0, ellipsize = Pango.EllipsizeMode.END }
	local nav_back = button("go-previous-symbolic", "Back (Alt+Left)", function()
		idle(function() go_back() end)
	end)
	local nav_forward = button("go-next-symbolic", "Forward (Alt+Right)", function()
		idle(function() go_forward() end)
	end)
	local nav_up = button("go-up-symbolic", "Parent folder (Alt+Up)", function()
		idle(function() go_up() end)
	end)
	local refresh_button = button("view-refresh-symbolic", "Refresh (F5)", function()
		idle(function() load(current_uri()) end)
	end)
	local hidden_button = Gtk.ToggleButton {
		image = Gtk.Image {
			icon_name = pick_icon(theme, "view-reveal-symbolic", "view-conceal-symbolic", "folder"),
		},
		active = show_hidden,
		tooltip_text = "Show hidden files (Ctrl+H)",
	}
	hidden_button:show()
	hidden_button.on_toggled = function(b)
		if b.active ~= show_hidden then
			show_hidden = b.active
			idle(function() load(current_uri()) end)
		end
	end

	local path_button = Gtk.Button { relief = Gtk.ReliefStyle.NONE }
	path_button.on_clicked = function() toggle_location(true) end
	local location = Gtk.Entry {
		placeholder_text = "path or URI, e.g. ~/Downloads or sftp://host/",
		xalign = 0,
	}

	local header = Gtk.HeaderBar { title = "Files" }
	header:pack_start(nav_back)
	header:pack_start(nav_forward)
	header:pack_start(nav_up)
	header:pack_start(refresh_button)
	header:pack_end(hidden_button)
	header:pack_start(path_button)
	header:pack_start(location)
	win:set_titlebar(header)

	location.on_activate = function(entry)
		local text = trim(entry.text)
		if text ~= "" then
			toggle_location(false)
			idle(function() go(to_uri(text)) end)
		end
	end
	location.on_key_press_event = function(_, event)
		if event.keyval == Gdk.KEY_Escape then
			toggle_location(false)
			return true
		end
		return false
	end

	local sidebar = Gtk.ListBox { selection_mode = Gtk.SelectionMode.SINGLE }
	for _, place in ipairs(places()) do
		local row = Gtk.ListBoxRow()
		local box = Gtk.Box {
			orientation = Gtk.Orientation.HORIZONTAL,
			spacing = 8,
			border_width = 4,
		}
		local image = Gtk.Image { icon_name = pick_icon(theme, unpack(place.icon)) }
		local label = Gtk.Label {
			label = place.name,
			xalign = 0,
			ellipsize = Pango.EllipsizeMode.END,
		}
		image:show()
		label:show()
		box:pack_start(image, false, false, 0)
		box:pack_start(label, true, true, 0)
		row:add(box)
		sidebar:add(row)
		sidebar_rows[#sidebar_rows + 1] = { widget = row, uri = place.uri }
	end
	sidebar.on_row_selected = function()
		local row = sidebar:get_selected_row()
		if not row or not ready then
			return
		end
		for _, entry in ipairs(sidebar_rows) do
			if entry.widget == row then
				-- load() highlights the current place, so an event that
				-- points at where we already are is just that echo
				if entry.uri ~= current_uri() then
					idle(function() go(entry.uri) end)
				end
				return
			end
		end
	end

	local volumes = Gtk.Box {
		orientation = Gtk.Orientation.VERTICAL,
		spacing = 2,
	}
	for _, place in ipairs(mounted_volumes()) do
		local image = Gtk.Image { icon_name = pick_icon(theme, unpack(place.icon)) }
		local label = Gtk.Label {
			label = place.name,
			xalign = 0,
			ellipsize = Pango.EllipsizeMode.END,
		}
		local box = Gtk.Box {
			orientation = Gtk.Orientation.HORIZONTAL,
			spacing = 8,
		}
		image:show()
		label:show()
		box:pack_start(image, false, false, 0)
		box:pack_start(label, true, true, 0)
		local vol_button = Gtk.Button { relief = Gtk.ReliefStyle.NONE }
		vol_button:add(box)
		vol_button.on_clicked = function() idle(function() go(place.uri) end) end
		volumes:pack_start(vol_button, false, false, 0)
	end

	local side_box = Gtk.Box {
		orientation = Gtk.Orientation.VERTICAL,
		spacing = 6,
		border_width = 6,
	}
	side_box:pack_start(sidebar, true, true, 0)
	side_box:pack_start(Gtk.Separator { orientation = Gtk.Orientation.HORIZONTAL }, false, false, 0)
	side_box:pack_start(volumes, false, false, 0)

	local side_scroll = Gtk.ScrolledWindow {
		hscrollbar_policy = Gtk.PolicyType.NEVER,
		vscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
		width_request = 180,
	}
	side_scroll:add(side_box)

	local main_box = Gtk.Box { orientation = Gtk.Orientation.VERTICAL }
	main_box:pack_start(scroller, true, true, 0)
	main_box:pack_start(Gtk.Separator { orientation = Gtk.Orientation.HORIZONTAL }, false, false, 0)
	main_box:pack_start(status_label, false, false, 6)

	local root_box = Gtk.Box { orientation = Gtk.Orientation.HORIZONTAL }
	root_box:pack_start(side_scroll, false, false, 0)
	root_box:pack_start(main_box, true, true, 0)
	win:add(root_box)

	-- ---------------------------------------------------------- plumbing
	function current_uri()
		return history[history_index] or HOME_URI
	end

	local function update_status()
		local total = store:iter_n_children(nil)
		local picked = view:get_selection():count_selected_rows()
		local where = place_name(current_uri())
		if truncated then
			where = where .. "  (showing first " .. MAX_ROWS .. ")"
		end
		if picked == 0 then
			status_label.label = ("%s  -  %d item%s"):format(where, total, total == 1 and "" or "s")
		else
			status_label.label = ("%s  -  %d of %d selected"):format(where, picked, total)
		end
		nav_back.sensitive = history_index > 1
		nav_forward.sensitive = history[history_index + 1] ~= nil
		nav_up.sensitive = current_uri() ~= TRASH_URI and current_uri() ~= RECENT_URI
			and parent_uri(current_uri()) ~= current_uri()
	end

	local function sync_sidebar(uri)
		local hit
		for _, entry in ipairs(sidebar_rows) do
			if entry.uri == uri then
				hit = entry.widget
				break
			end
		end
		local selected = sidebar:get_selected_row()
		if hit then
			-- load() highlights the current place, so an event that points
			-- at where we already are is just that echo
			if selected ~= hit then
				sidebar:select_row(hit)
			end
		elseif selected then
			-- not one of the places: nothing to highlight
			sidebar:select_row(nil)
		end
	end

	-- --------------------------------------------------------- selection
	local function row_path(index)
		local path = Gtk.TreePath.new_first()
		for _ = 1, index do
			path:next()
		end
		return path
	end

	local function selected_uris()
		local uris = {}
		for _, path in ipairs(view:get_selection():get_selected_rows()) do
			uris[#uris + 1] = store[store:get_iter(path)][COL_URI]
		end
		table.sort(uris)
		return uris
	end

	local function in_trash()
		return current_uri() == TRASH_URI
	end

	-- rows in recent:/// carry the uri of the real file behind them, so an
	-- accidental Delete or Rename there would hit that file: leave the
	-- Recent view read only, apart from Open and Copy
	local function in_recent()
		return current_uri() == RECENT_URI
	end

	-- keep Gtk's focus row on the selection, otherwise Return and the arrow
	-- keys walk off to the row below
	local moving_cursor = false
	local function sync_cursor()
		if moving_cursor then
			return
		end
		local paths = view:get_selection():get_selected_rows()
		if #paths == 0 then
			return
		end
		local cursor = view:get_cursor()
		if cursor and cursor:compare(paths[1]) == 0 then
			return
		end
		moving_cursor = true
		view:set_cursor(paths[1], view:get_column(0), false)
		moving_cursor = false
	end

	local function select_only(uri)
		view:get_selection():unselect_all()
		local rows = store:iter_n_children(nil)
		for i = 0, rows - 1 do
			local path = row_path(i)
			if store[store:get_iter(path)][COL_URI] == uri then
				view:get_selection():select_path(path)
				sync_cursor()
				return true
			end
		end
		return false
	end

	local function reselect(uris)
		if #uris == 0 then
			return
		end
		local wanted = {}
		for _, uri in ipairs(uris) do
			wanted[uri] = true
		end
		local picker = view:get_selection()
		local rows = store:iter_n_children(nil)
		for i = 0, rows - 1 do
			local path = row_path(i)
			if wanted[store[store:get_iter(path)][COL_URI]] then
				picker:select_path(path)
			end
		end
		sync_cursor()
	end

	-- fill the model for one directory listing
	local function fill(rows, keep)
		store:clear()
		truncated = #rows > MAX_ROWS
		if truncated then
			local trimmed = {}
			for i = 1, MAX_ROWS do
				trimmed[i] = rows[i]
			end
			rows = trimmed
		end
		for _, row in ipairs(rows) do
			store:append {
				row.pixbuf,
				row.name,
				row.uri,
				row.isdir,
				row.size,
				row.modified,
				row.tooltip,
			}
		end
		reselect(keep)
	end

	local function sort_rows(rows)
		table.sort(rows, function(a, b)
			if a.isdir ~= b.isdir then
				return a.isdir
			end
			return a.key < b.key
		end)
	end

	local function describe(info, isdir)
		local bits = {}
		local ok, content = pcall(function() return info:get_content_type() end)
		if ok and content then
			bits[#bits + 1] = content
		end
		if isdir then
			bits[#bits + 1] = "folder"
		else
			local size = info:get_size()
			bits[#bits + 1] = ("%s (%d bytes)"):format(human_size(size), size)
		end
		bits[#bits + 1] = "modified " .. file_time(info:get_modification_date_time())
		local okw, writable = pcall(function() return info:get_attribute_boolean "access::can-write" end)
		if okw then
			bits[#bits + 1] = writable and "writable" or "read only"
		end
		if info:get_is_symlink() then
			bits[#bits + 1] = "symlink"
		end
		return table.concat(bits, "\n")
	end

	function load(uri)
		local file = file_of(uri)
		history[history_index] = uri
		sync_sidebar(uri)
		-- reloading the same directory should not throw the selection away
		local keep = pending_select
		if #keep == 0 and uri == current_uri() then
			keep = selected_uris()
		end
		pending_select = {}
		view:get_selection():unselect_all()
		local in_trash = uri == TRASH_URI
		local in_recent = uri == RECENT_URI
		local where = place_name(uri)
		win.title = where
		local label = path_button
		label.label = where
		update_status()

		-- fail fast (and synchronously) for missing or unreadable places
		local ok, err = pcall(function()
			return file:query_info("standard::name", NONE)
		end)
		if not ok then
			store:clear()
			update_status()
			notify("Cannot open " .. base_name(uri), tostring(err))
			return
		end

		-- a slower listing may still finish after we moved on: let it, and
		-- throw the result away instead of cancelling it (cancelling pushes
		-- a GError into the coroutine, which lgi cannot report nicely)
		generation = generation + 1
		local mine = generation
		local cancellable = Gio.Cancellable()
		active_cancel = cancellable

		-- the coroutine yields inside async_*, so no pcall around the body
		Gio.Async.start(function()
			local attrs = in_trash and TRASH_ATTRS
				or (in_recent and RECENT_ATTRS or ATTRS)
			local enumerator, failure = await(file.async_enumerate_children, file,
				attrs, NONE)
			if not enumerator then
				if mine == generation then
					store:clear()
					update_status()
					notify("Cannot open " .. base_name(uri), tostring(failure))
				end
				return
			end
			local rows = {}
			local shown = 0
			while true do
				local batch = await(enumerator.async_next_files, enumerator, 128)
				if not batch then
					break
				end
				if #batch == 0 then
					break
				end
				for _, info in ipairs(batch) do
					if show_hidden or not info:get_is_hidden() then
						shown = shown + 1
						if shown <= MAX_ROWS * 2 then
							local isdir = is_directory(info)
							-- recent:// returns an opaque id as the name and
							-- the bookmarked uri as the target
							local name = in_recent
								and info:get_display_name() or info:get_name()
							local child = file:get_child(info:get_name())
							local uri_of_row = in_recent
								and info:get_attribute_string "standard::target-uri"
								or nil
							if not uri_of_row or uri_of_row == "" then
								uri_of_row = child:get_uri()
							end
							local tip = describe(info, isdir)
							if in_recent then
								tip = tip .. "\n" .. uri_of_row
							end
							rows[#rows + 1] = {
								name = name,
								uri = uri_of_row,
								isdir = isdir,
								key = natural_key(name),
								size = isdir and "" or human_size(info:get_size()),
								modified = file_time(info:get_modification_date_time()),
								tooltip = tip,
								pixbuf = icon_pixbuf(theme, info, isdir),
							}
						end
					end
				end
			end
			pcall(function() enumerator:close() end)
			if mine ~= generation then
				return
			end
			sort_rows(rows)
			fill(rows, keep)
			update_status()
		end, cancellable)()
	end

	function go(uri)
		history_index = history_index + 1
		while #history > history_index do
			history[#history] = nil
		end
		load(uri)
	end

	function go_back()
		if history_index > 1 then
			history_index = history_index - 1
			load(history[history_index])
		end
	end

	function go_forward()
		if history[history_index + 1] then
			history_index = history_index + 1
			load(history[history_index])
		end
	end

	function go_up()
		local uri = current_uri()
		if uri ~= TRASH_URI and uri ~= RECENT_URI then
			local parent = parent_uri(uri)
			if parent ~= uri then
				go(parent)
			end
		end
	end

	-- ---------------------------------------------------------- actions
	local function open_uris(uris)
		for _, uri in ipairs(uris) do
			if is_directory_uri(uri) then
				go(uri)
				return
			end
		end
		for _, uri in ipairs(uris) do
			local ok, err = pcall(Gio.AppInfo.launch_default_for_uri, uri, nil)
			if not ok then
				notify("Cannot open " .. base_name(uri), tostring(err))
			end
		end
	end

	local function activate_row(path)
		local row = store[store:get_iter(path)]
		if row[COL_ISDIR] then
			go(row[COL_URI])
		else
			open_uris { row[COL_URI] }
		end
	end

	local function activate_selection()
		local cursor = view:get_cursor()
		local rows = store:iter_n_children(nil)
		-- compare against the last row to catch a cursor left over from a
		-- listing that has since been replaced
		if cursor and rows > 0 and cursor:compare(row_path(rows - 1)) <= 0 then
			activate_row(cursor)
			return
		end
		local uris = selected_uris()
		if #uris > 0 then
			open_uris(uris)
		end
	end

	local function edit_file(uri)
		local path = file_of(uri):get_path()
		if not path then
			notify("Cannot edit this location", base_name(uri))
			return
		end
		-- with_shell, not spawn: awful.spawn's second argument is the startup
		-- notification rules, $EDITOR may carry arguments of its own and the
		-- path has to survive spaces either way
		awful.spawn.with_shell(("exec %s %s"):format(
			arg.editor or os.getenv "EDITOR" or os.getenv "VISUAL" or "nvim",
			shellescape(path)))
	end

	local function terminal_here()
		local path = file_of(current_uri()):get_path()
		if not path then
			notify("No terminal here", place_name(current_uri()))
			return
		end
		awful.spawn.with_shell(("cd %s && exec %s"):format(shellescape(path),
			shellescape(terminal)))
	end

	local function clipboard_set_text(text)
		-- Gtk.Clipboard.set_uris is missing from this lgi build, so the
		-- uris travel as plain text and are re-split on the way out
		return Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD):set_text(text, -1)
	end

	local function put_on_clipboard(mode, uris)
		clipboard.mode = mode
		clipboard.uris = uris
		local ok = pcall(clipboard_set_text, table.concat(uris, "\n") .. "\n")
		if not ok then
			notify("Clipboard is read-only", "kept " .. #uris .. " item(s) inside awfm")
		end
	end

	local function clipboard_uris()
		if clipboard.uris and #clipboard.uris > 0 then
			return clipboard.mode, clipboard.uris
		end
		local c = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
		-- probing a member this lgi build may not have throws, so each try
		-- gets a pcall of its own instead of an if
		local ok, uris = pcall(function() return c:wait_for_uris() end)
		if ok and uris and #uris > 0 then
			return "copy", uris
		end
		local okt, text = pcall(function() return c:wait_for_text() end)
		if okt then
			local list = split_lines(text)
			if #list > 0 then
				return "copy", list
			end
		end
		return nil, {}
	end

	local function unique_child(dir, name)
		local candidate = dir:get_child(name)
		local n = 1
		while candidate:query_exists() do
			local base = name:gsub("%s*%(%d+%)$", "")
			candidate = dir:get_child(("%s (%d)"):format(base, n))
			n = n + 1
		end
		return candidate
	end

	local function after_change()
		load(current_uri())
	end

	-- GFile.move_async/copy_async are unusable here: the GIR on this box drops
	-- the two gpointer parameters, so lgi ends up passing the callback in the
	-- wrong slot.  The synchronous twins introspect fine, so use those and keep
	-- the transfer off the refresh path.
	local function transfer(source, target, moving)
		if moving then
			return source:move(target, OVERWRITE, nil, nil)
		end
		return source:copy(target, OVERWRITE, nil, nil)
	end

	local function new_folder()
		prompt(win, {
			title = "New Folder",
			label = "Folder name:",
			initial = "New Folder",
			action = "Create",
			on_ok = function(name)
				local dir = file_of(current_uri())
				if not is_directory_uri(dir:get_uri()) then
					return
				end
				local target = dir:get_child(name)
				local path = target:get_path()
				if not path then
					notify("Cannot create " .. name, "no such location")
					return
				end
				-- Gio.File.make_directory is missing its name argument in the
				-- GIR this box ships, so go through GLib for local paths
				local code = GLib.mkdir(path, tonumber("755", 8))
				if code == 0 then
					notify("Folder created", target:get_uri())
				else
					notify("Cannot create " .. name, GLib.strerror(code))
				end
				after_change()
			end,
		})
	end

	local function rename(uri)
		prompt(win, {
			title = "Rename",
			label = "New name:",
			initial = base_name(uri),
			action = "Rename",
			on_ok = function(name)
				local file = file_of(uri)
				local dir = file:get_parent()
				local ok, err = transfer(file, dir:get_child(name), true)
				notify(ok and "Renamed" or "Cannot rename " .. base_name(uri),
					ok and name or tostring(err))
				if ok then
					pending_select = { dir:get_child(name):get_uri() }
				end
				after_change()
			end,
		})
	end

	local function restore(uris)
		local restored, failed = 0, {}
		for _, uri in ipairs(uris) do
			local dest = trash_original(base_name(uri))
			if dest and transfer(file_of(uri), Gio.File.new_for_path(dest), true) then
				restored = restored + 1
			else
				failed[#failed + 1] = base_name(uri)
			end
		end
		notify("Restored", ("%d item(s)"):format(restored))
		for _, name in ipairs(failed) do
			notify("Cannot restore " .. name, "original location unknown")
		end
		after_change()
	end

	local function move_to_trash(uris)
		local failed = {}
		Gio.Async.start(function()
			for _, uri in ipairs(uris) do
				local f = file_of(uri)
				if not await(f.async_trash, f) then
					failed[#failed + 1] = base_name(uri)
				end
			end
			if #failed > 0 then
				notify("Trash failed", ("%s stayed put"):format(table.concat(failed, ", ")))
			end
			after_change()
		end)()
	end

	local function delete_forever(uris)
		Gio.Async.start(function()
			local failed = {}
			for _, uri in ipairs(uris) do
				local f = file_of(uri)
				if not await(f.async_delete, f) then
					failed[#failed + 1] = base_name(uri)
				end
			end
			for _, name in ipairs(failed) do
				notify("Cannot delete " .. name, "")
			end
			after_change()
		end)()
	end

	local function delete_selection(permanent)
		if in_recent() then
			return
		end
		local uris = selected_uris()
		if #uris == 0 then
			return
		end
		if permanent or in_trash() then
			confirm(win, {
				text = ("Permanently delete %d item(s)?"):format(#uris),
				secondary = "This cannot be undone.",
				on_ok = function() delete_forever(uris) end,
			})
		else
			move_to_trash(uris)
		end
	end

	local function paste()
		if in_recent() then
			notify("Cannot paste here", "Recent is not a folder")
			return
		end
		local mode, uris = clipboard_uris()
		if #uris == 0 then
			notify("Clipboard is empty", "copy something first")
			return
		end
		local dir = file_of(current_uri())
		local done = 0
		for _, uri in ipairs(uris) do
			local ok, err = transfer(file_of(uri), unique_child(dir, base_name(uri)),
				mode == "cut")
			if ok then
				done = done + 1
			else
				notify("Cannot paste " .. base_name(uri), tostring(err))
			end
		end
		if mode == "cut" then
			clipboard = {}
		end
		notify((mode == "cut" and "Moved" or "Copied"),
			("%d item(s) into %s"):format(done, place_name(current_uri())))
		after_change()
	end

	function toggle_hidden()
		show_hidden = not show_hidden
		hidden_button.active = show_hidden
		load(current_uri())
	end

	function toggle_location(force)
		local show = force
		if show == nil then
			show = not location.visible
		end
		location.visible = show
		path_button.visible = not show
		if show then
			location.text = current_uri()
			location:grab_focus()
			location:select_region(0, -1)
		else
			view:grab_focus()
		end
	end

	local function context_menu(event)
		local uris = selected_uris()
		local one = #uris == 1 and uris[1] or nil
		popup_menu({
			{ label = "Open", enabled = one ~= nil,
				action = function() open_uris { one } end },
			{ label = "Open Containing Folder", enabled = one ~= nil and not in_trash(),
				action = function() go(parent_uri(one)) end },
			{ label = "Open in Terminal", enabled = not in_recent(),
				action = terminal_here },
			{ label = "Edit with $EDITOR", enabled = one ~= nil and not in_trash(),
				action = function() edit_file(one) end },
			"sep",
			{ label = "Cut", enabled = #uris > 0 and not in_recent(),
				action = function() put_on_clipboard("cut", uris) end },
			{ label = "Copy", enabled = #uris > 0,
				action = function() put_on_clipboard("copy", uris) end },
			{ label = "Paste", enabled = not in_recent(), action = paste },
			{ label = "Rename", enabled = one ~= nil and not in_trash()
				and not in_recent(),
				action = function() rename(one) end },
			{ label = in_trash() and "Restore From Trash" or "Move to Trash",
				enabled = #uris > 0 and not in_recent(),
				action = function()
					if in_trash() then
						restore(uris)
					else
						move_to_trash(uris)
					end
				end },
			{ label = "Delete Permanently", enabled = #uris > 0 and in_trash(),
				action = function() delete_selection(true) end },
			"sep",
			{ label = "New Folder", enabled = not in_trash() and not in_recent(),
				action = new_folder },
			{ label = "Show Hidden Files", action = toggle_hidden },
			{ label = "Refresh", action = function() after_change() end },
		}, event)
	end

	-- ----------------------------------------------------------- signals
	view.on_row_activated = function(_, path)
		-- the path belongs to Gtk and is only good while this signal runs,
		-- so turn it into text before the idle handler gets to it
		local row = path:to_string()
		idle(function()
			local again = Gtk.TreePath.new_from_string(row)
			if again then
				activate_row(again)
			end
		end)
	end
	view.on_button_press_event = function(self, event)
		if event.button == 3 then
			local path = self:get_path_at_pos(event.x, event.y)
			if path then
				if not self:get_selection():path_is_selected(path) then
					self:get_selection():unselect_all()
					self:get_selection():select_path(path)
				end
			else
				self:get_selection():unselect_all()
			end
			-- same story with the event itself: popup_at_pointer wants the
			-- live one, so no idle here
			context_menu(event)
			return true
		end
		return false
	end
	view:get_selection().on_changed = function()
		sync_cursor()
		update_status()
	end

	local bindings = {
		{ Gdk.KEY_Return, nil, activate_selection },
		{ Gdk.KEY_KP_Enter, nil, activate_selection },
		{ Gdk.KEY_Delete, false, function() delete_selection(false) end },
		{ Gdk.KEY_Delete, true, function() delete_selection(true) end },
		{ Gdk.KEY_F2, false, function()
			local uris = selected_uris()
			if #uris == 1 and not in_recent() and not in_trash() then
				rename(uris[1])
			end
		end },
		{ Gdk.KEY_F5, false, function() after_change() end },
		{ Gdk.KEY_BackSpace, false, go_up },
		{ Gdk.KEY_Left, "alt", go_back },
		{ Gdk.KEY_Right, "alt", go_forward },
		{ Gdk.KEY_Up, "alt", go_up },
		{ Gdk.KEY_a, "ctrl", function() view:get_selection():select_all() end },
		{ Gdk.KEY_c, "ctrl", function()
			local uris = selected_uris()
			if #uris > 0 then
				put_on_clipboard("copy", uris)
			end
		end },
		{ Gdk.KEY_x, "ctrl", function()
			local uris = selected_uris()
			if #uris > 0 then
				put_on_clipboard("cut", uris)
			end
		end },
		{ Gdk.KEY_v, "ctrl", paste },
		{ Gdk.KEY_l, "ctrl", function() toggle_location() end },
		{ Gdk.KEY_h, "ctrl", toggle_hidden },
		{ Gdk.KEY_n, "ctrl", new_folder },
	}

	win.on_key_press_event = function(_, event)
		if location.visible then
			return false
		end
		-- lgi hands Gdk.ModifierType over as a table whose truthy keys are the
		-- names of the masks that are currently held, so ask it that way
		local ctrl = event.state.CONTROL_MASK == true
		local shift = event.state.SHIFT_MASK == true
		local alt = event.state.MOD1_MASK == true
		for _, binding in ipairs(bindings) do
			if event.keyval == binding[1] then
				local want = binding[2]
				local have = want == nil
					or (want == "ctrl" and ctrl)
					or (want == "alt" and alt)
					or (want == true and shift)
					or (want == false and not ctrl and not shift and not alt)
				if have then
					idle(binding[3])
					return true
				end
			end
		end
		return false
	end

	win.on_delete_event = function()
		win:destroy()
		return false
	end
	win.on_destroy = function()
		if active_cancel then
			active_cancel:cancel()
		end
		if current == win then
			current = nil
			control = nil
		end
	end

	-- ---------------------------------------------------------- kick off
	win:show_all()
	location.visible = false
	win.title = "Files"
	path_button.label = base_name(HOME)
	-- focus has to wait until the window is on screen, otherwise the
	-- sidebar keeps it and the arrow keys walk the places instead of the files
	view:grab_focus()

	local start = arg.path and to_uri(arg.path) or HOME_URI
	history[1] = start
	history_index = 1
	ready = true
	load(start)

	control = {
		win = win,
		view = view,
		uri = current_uri,
		go = go,
		reload = after_change,
		back = go_back,
		forward = go_forward,
		up = go_up,
		selected = selected_uris,
		select = select_only,
		trash = function() move_to_trash(selected_uris()) end,
		context_menu = context_menu,
		location = location,
		store = store,
		count = function() return store:iter_n_children(nil) end,
		name_of = function(row) return store[row][COL_NAME] end,
		uri_of = function(row) return store[row][COL_URI] end,
		row_path = row_path,
	}
	return win
end

-- ------------------------------------------------------------------- api

local M = {}

function M.new(arg)
	local win = new(arg)
	current = win
	return win
end

function M.launch(arg)
	arg = arg or {}
	if current then
		current:present()
		if arg.path and control then
			idle(function() control.go(to_uri(arg.path)) end)
		end
		return current
	end
	return M.new(arg)
end

-- exposed for tests and for driving the window from rc.lua
function M.control()
	return control
end

return setmetatable(M, {
	__call = function(_, arg) return M.launch(arg) end,
})
