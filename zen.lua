local terminal = "gnome-terminal"
local browser = "firefox"
local file_manager = "thunar"
local modkey = "Mod4"

require "awful.autofocus"
local gears = require "gears"
local naughty = require "naughty"
local beautiful = require "beautiful"
local awful = require "awful"
local wibox = require "wibox"
local ruled = require("ruled")
local menubar = require "menubar"
menubar.utils.terminal = terminal
local hotkeys_popup = require "awful.hotkeys_popup"
local somodoro = require "somodoro"


naughty.connect_signal("request::display_error", function(message, startup)
	naughty.notification {
		urgency = "critical",
		title   = "Oops, an error happened" .. (startup and " during startup!" or "!"),
		message = message
	}
end)

local pomodoro = somodoro()

local tag = tag
local screen = screen
local client = client
local awesome = awesome

ruled.client.connect_signal("request::rules", function()
	ruled.client.append_rule {
		id         = "global",
		rule       = {},
		properties = {
			focus     = awful.client.focus.filter,
			raise     = true,
			screen    = awful.screen.preferred,
			placement = awful.placement.centered
		}
	}
end)

beautiful.init(gears.filesystem.get_themes_dir() .. "gtk/theme.lua")

tag.connect_signal("request::default_layouts", function()
	awful.layout.append_default_layouts {
		awful.layout.suit.spiral.dwindle,
		awful.layout.suit.floating,
	}
end)

screen.connect_signal("request::wallpaper", function(s)
	awful.wallpaper {
		screen = s,
		bg = "#000000",
		widget = {
			{
				image     = gears.filesystem.get_configuration_dir()
				    .. "wallpaper.jpg",
				upscale   = false,
				downscale = false,
				widget    = wibox.widget.imagebox,
			},
			valign = "center",
			halign = "center",
			tiled  = false,
			widget = wibox.container.tile,
		}
	}
end)
local textclock = wibox.widget.textclock "%H:%M"
local cal = awful.widget.calendar_popup.month()
cal:attach(textclock, "tr")
local tray = wibox.widget.systray()

local pomodorobar = wibox.widget {
	max_value = pomodoro.seconds,
	value = 700,
	color = beautiful.bg_focus,
	background_color = beautiful.bg_normal,
	width = 0,
	widget = wibox.widget.progressbar
}
local pomodorotext = wibox.widget {
	widget = wibox.widget.textbox,
	text = "Pomodoro",
}
local pomodorost = wibox.widget {
	widget = wibox.widget.textbox,
	text = "",
}
local pomodorowidget = wibox.widget {
	pomodorobar,
	{
		layout = wibox.layout.fixed.horizontal,
		halign = "center",
		valign = "center",
		pomodorost,
		pomodorotext,
	},
	layout = wibox.layout.stack,
	visible = false,
}
pomodoro:connect_signal("somodoro::update", function()
	pomodorobar.value = pomodoro.elapsed
	local remaining = pomodoro.seconds - pomodoro.elapsed
	pomodorotext.text = string.format("%02d:%02d", remaining / 60, remaining % 60)
end)
pomodoro:connect_signal("somodoro::pause", function()
	pomodorost.text = ""
end)
pomodoro:connect_signal("somodoro::resume", function()
	pomodorost.text = ""
end)

local pomodorocolors = {
	begin = {
		tasklist_bg_focus = beautiful.tasklist_bg_focus
	},
	finish = {
		tasklist_bg_focus = beautiful.taglist_bg_focus
	}
}
beautiful.tasklist_bg_focus = beautiful.taglist_bg_focus
pomodoro:connect_signal("somodoro::begin", function()
	tray.visible = false
	textclock.visible = false
	pomodorowidget.visible = true
	pomodorost.text = ""
	beautiful.tasklist_bg_focus = pomodorocolors.begin.tasklist_bg_focus
end)
pomodoro:connect_signal("somodoro::finish", function()
	tray.visible = true
	textclock.visible = true
	pomodorowidget.visible = false
	beautiful.tasklist_bg_focus = pomodorocolors.finish.tasklist_bg_focus
	naughty.notification {
		title = "Pomodoro",
		message = "finished",
	}
end)
screen.connect_signal("request::desktop_decoration", function(s)
	awful.tag({ "1", "2", "3", "4", "5", "6", "7",
		"8", "9", "0" }, s, awful.layout.layouts[1])
	local taglist = awful.widget.taglist {
		screen = s,
		filter = awful.widget.taglist.filter.all,
		buttons = {
			awful.button({}, 1, function(t) t:view_only() end),
		}
	}
	local tasklist = awful.widget.tasklist {
		screen = s,
		filter = awful.widget.tasklist.filter.currenttags,
	}
	local bar = awful.wibar {
		position = "top",
		screen = s,
		widget = {
			layout = wibox.layout.align.horizontal,
			taglist,
			tasklist,
			{
				layout = wibox.layout.fixed.horizontal,
				tray,
				awful.widget.layoutbox {
					screen = s,
				},
				textclock,
				pomodorowidget,
			},
		}
	}
	pomodoro:connect_signal("somodoro::begin", function()
		bar.position = "bottom"
		tasklist.filter = awful.widget.tasklist.filter.focused
		taglist.filter = awful.widget.taglist.filter.selected
	end)
	pomodoro:connect_signal("somodoro::finish", function()
		bar.position = "top"
		tasklist.filter = awful.widget.tasklist.filter.currenttags
		taglist.filter = awful.widget.taglist.filter.all
	end)
end)

client.connect_signal("request::default_mousebindings", function()
	awful.mouse.append_client_mousebindings {
		awful.button({}, 1, function(c)
			c:activate { context = "mouse_click" }
		end),
		awful.button({ modkey }, 1, function(c)
			c:activate { context = "mouse_click", action = "mouse_move" }
		end),
		awful.button({ modkey }, 3, function(c)
			c:activate { context = "mouse_click", action = "mouse_resize" }
		end),
	}
end)

client.connect_signal("request::default_keybindings", function()
	awful.keyboard.append_client_keybindings {
		group = "client",
		awful.key {
			modifiers = { modkey },
			key = "f",
			on_press = function(c)
				c.fullscreen = not c.fullscreen
				c:raise()
			end,
			description = "toggle fullscreen",
		},
		awful.key {
			modifiers = { modkey, "Shift" },
			key = "c",
			on_press = function(c) c:kill() end,
			description = "close",
		},
		awful.key {
			modifiers = { modkey },
			key = "m",
			on_press = function(c)
				c.maximized = not c.maximized
				c:raise()
			end,
			description = "(un)maximize",
		},
		awful.key {
			modifiers = { modkey, "Control" },
			key = "space",
			on_press = awful.client.floating.toggle,
			description = "toggle floating",
		},
		awful.key {
			modifiers = { modkey, "Control" },
			key = "Return",
			on_press = function(c)
				c:swap(awful.client.getmaster())
			end,
			description = "move to master",
		},
		awful.key {
			modifiers = { modkey },
			key = "o",
			on_press = function(c)
				c:move_to_screen()
			end,
			description = "move to screen",
		},
	}
end)

awful.keyboard.append_global_keybindings {
	group = "awesome",
	awful.key {
		modifiers = { modkey },
		key = "s",
		on_press = hotkeys_popup.show_help,
		description = "show help",
	},
	awful.key {
		modifiers = { modkey, "Control" },
		key = "r",
		on_press = awesome.restart,
		description = "reload awesome",
	},
	awful.key {
		modifiers = { modkey, "Shift" },
		key = "q",
		on_press = awesome.quit,
		description = "quit awesome",
	}
}

local screenshot = awful.screenshot {
}
screenshot.directory = screenshot.directory .. "/Screenshots"
screenshot:connect_signal("file::saved", function(self)
	naughty.notification {
		title = self.file_name,
		message = "Screenshot saved",
		icon = self.surface,
		icon_size = 128,
	}
	awful.spawn("xclip -selection clipboard -t image/png " .. self.file_path)
end)
awful.keyboard.append_global_keybindings {
	group = "client",
	awful.key {
		modifiers = { modkey },
		key = "j",
		on_press = function() awful.client.focus.byidx(1) end,
		description = "focus next by index",
	},
	awful.key {
		modifiers = { modkey },
		key = "k",
		on_press = function() awful.client.focus.byidx(-1) end,
		description = "focus previous by index",
	},
	awful.key {
		modifiers = { modkey, "Shift" },
		key = "j",
		on_press = function() awful.client.swap.byidx(1) end,
		description = "swap with next client by index",
	},
	awful.key {
		modifiers = { modkey, "Shift" },
		key = "k",
		on_press = function() awful.client.swap.byidx(-1) end,
		description = "swap with previous client by index",
	},
	awful.key {
		modifiers = { "Shift" },
		key = "Print",
		on_press = function()
			screenshot.interactive = true
			screenshot:refresh()
		end,
		description = "take interactive screenshot",
	},
	awful.key {
		modifiers = {},
		key = "Print",
		on_press = function()
			screenshot.interactive = false
			screenshot:refresh()
			screenshot:save()
		end,
		description = "take screenshot",
	},
}

awful.keyboard.append_global_keybindings {
	group = "launcher",
	awful.key {
		modifiers = { modkey },
		key = "Return",
		on_press = function() awful.spawn(terminal) end,
		description = "open a terminal",
	},
	awful.key {
		modifiers = { modkey },
		key = "'",
		on_press = function() awful.spawn(browser) end,
		description = "open a browser",
	},
	awful.key {
		modifiers = { modkey },
		key = "p",
		on_press = menubar.show,
		description = "show the menubar",
	},
	awful.key {
		modifiers = { modkey },
		key = "d",
		on_press = function() awful.spawn(file_manager) end,
		description = "open a file manager",
	},
}

awful.keyboard.append_global_keybindings {
	group = "tag",
	awful.key {
		modifiers   = { modkey },
		keygroup    = "numrow",
		description = "only view tag",
		on_press    = function(index)
			local s = awful.screen.focused()
			local t = s.tags[index]
			if t then
				t:view_only()
			end
		end,
	},
	awful.key {
		modifiers   = { modkey, "Shift" },
		keygroup    = "numrow",
		description = "move focused client to tag",
		group       = "tag",
		on_press    = function(index)
			if client.focus then
				local t = client.focus.screen.tags[index]
				if t then
					client.focus:move_to_tag(t)
				end
			end
		end,
	},
}

awful.keyboard.append_global_keybindings {
	group = "screen",
	awful.key {
		modifiers = { modkey, "Control" },
		key = "j",
		on_press = function() awful.screen.focus_relative(1) end,
		description = "focus the next screen",
	},
	awful.key {
		modifiers = { modkey, "Control" },
		key = "k",
		on_press = function() awful.screen.focus_relative(-1) end,
		description = "focus the previous screen",
	},
}

awful.keyboard.append_global_keybindings {
	group = "somodoro",
	awful.key {
		modifiers = { modkey, "Shift" },
		key = "p",
		on_press = function()
			pomodoro:toggle()
		end,
		description = "toggle pomodoro",
	},
	awful.key {
		modifiers = { modkey, "Control" },
		key = "p",
		on_press = function()
			pomodoro:finish()
		end,
		description = "finish pomodoro",
	},
}
