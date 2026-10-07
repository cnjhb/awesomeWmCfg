local terminal = "sakura"
local browser = "firefox"
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

local lgi = require "lgi"
local Gtk = lgi.require("Gtk", "3.0")
local Gio = lgi.Gio
Gtk.init()

local aweterm = require "aweterm"
local awfm = require "awfm"

naughty.connect_signal("request::display_error", function(message, startup)
	naughty.notification {
		urgency = "critical",
		title   = "Oops, an error happened" .. (startup and " during startup!" or "!"),
		message = message
	}
end)

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

-- Status bar icons are generated as vector graphics (see icons.lua): no
-- symbol font or icon theme required.
local icons = require "icons"

local function status_icon(name)
	local w, h = icons.size(name)
	return wibox.widget {
		widget        = wibox.widget.imagebox,
		resize        = true,
		upscale       = false,
		halign        = "center",
		valign        = "center",
		forced_width  = w,
		forced_height = h,
	}
end

local volume_icon = status_icon "volume"
local ac_icon = status_icon "ac"
local battery_icon = status_icon "battery"
local battery_text = wibox.widget {
	widget = wibox.widget.textbox,
	valign = "center",
}
local battery_box = wibox.widget {
	layout = wibox.layout.fixed.horizontal,
	spacing = 5,
	battery_icon,
	battery_text,
}

local function read_sysfs(path)
	local f = io.open(path)
	if not f then return nil end
	local content = f:read "*a"
	f:close()
	return content
end

-- Power state comes from UPower; sysfs is the fallback when the daemon is
-- not available.
local upower, up_client, up_display, up_states
do
	local ok, mod = pcall(lgi.require, "UPowerGlib")
	local ok2, client = ok and pcall(mod.Client) or false
	if ok2 and client then
		upower, up_client = mod, client
		up_display = client:get_display_device()
		up_states = {
			[mod.DeviceState.CHARGING]          = "charging",
			[mod.DeviceState.DISCHARGING]       = "discharging",
			[mod.DeviceState.FULLY_CHARGED]     = "full",
			[mod.DeviceState.EMPTY]             = "empty",
			[mod.DeviceState.PENDING_CHARGE]    = "idle",
			[mod.DeviceState.PENDING_DISCHARGE] = "idle",
		}
	end
end

local sysfs_states = {
	charging = "charging",
	discharging = "discharging",
	full = "full",
	["not charging"] = "idle",
	unknown = "unknown",
}

-- Returns { ac = bool|nil, level = number|nil, status = string, ... }
local function power_state()
	local s = {}
	if up_client then
		for _, d in ipairs(up_client:get_devices()) do
			if d.kind == upower.DeviceKind.LINE_POWER and d.online ~= nil then
				s.ac = d.online == true
			end
		end
		if up_display and (up_display.state ~= upower.DeviceState.UNKNOWN
				or (up_display.percentage or 0) > 0) then
			s.level = math.floor(up_display.percentage + 0.5)
			s.status = up_states[up_display.state] or "unknown"
			s.tte = up_display.time_to_empty
			s.ttf = up_display.time_to_full
		end
	end
	if s.ac == nil and s.level == nil then
		local online = read_sysfs "/sys/class/power_supply/ACAD/online"
		if online then
			s.ac = tonumber(online) == 1
		end
		local capacity = tonumber(read_sysfs "/sys/class/power_supply/BAT0/capacity")
		if capacity then
			s.level = math.max(0, math.min(100, capacity))
			local status = (read_sysfs "/sys/class/power_supply/BAT0/status" or ""):lower()
			s.status = sysfs_states[status:match "^%s*(.-)%s*$"] or "unknown"
		end
	end
	return s
end

local status_cn = {
	charging = "充电中",
	discharging = "放电中",
	full = "已充满",
	empty = "电量耗尽",
	idle = "未充电",
	unknown = "未知",
}

local function fmt_duration(sec)
	if not sec or sec <= 0 then return nil end
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	if h > 0 then
		return string.format("%d 小时 %d 分", h, m)
	end
	return string.format("%d 分钟", m)
end

local power_tooltip = awful.tooltip {
	objects = { ac_icon, battery_box },
	mode = "outside",
	preferred_positions = { "bottom", "top" },
}

local function update_volume_icon(muted, level)
	volume_icon.image = icons.volume {
		muted = muted or level == 0,
		fg = beautiful.fg_normal,
		bg = beautiful.bg_normal,
	}
end
update_volume_icon(false, 100) -- until the GSettings values are read

local function refresh_power()
	local s = power_state()
	local fg, bg = beautiful.fg_normal, beautiful.bg_normal

	ac_icon.visible = s.ac ~= nil
	if s.ac ~= nil then
		ac_icon.image = icons.ac { connected = s.ac, fg = fg, bg = bg }
	end

	local lines = {
		string.format("交流电源：%s",
			s.ac == nil and "未知" or (s.ac and "已接入" or "未接入")),
	}

	battery_box.visible = s.level ~= nil
	if s.level ~= nil then
		battery_icon.image = icons.battery {
			level = s.level,
			charging = s.status == "charging",
			fg = fg, bg = bg,
		}
		battery_text.text = string.format("%d%%", s.level)
		lines[#lines + 1] = string.format("电池：%d%%（%s）",
			s.level, status_cn[s.status] or s.status)

		local charging = s.status == "charging"
		local eta = charging and fmt_duration(s.ttf) or fmt_duration(s.tte)
		if eta then
			lines[#lines + 1] = (charging and "充满还需 " or "预计可用 ") .. eta
		end
	end

	power_tooltip.text = table.concat(lines, "\n")
end

gears.timer {
	timeout = 5,
	call_now = true,
	autostart = true,
	callback = refresh_power,
}

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

	s.mypromptbox = awful.widget.prompt()

	local tasklist = awful.widget.tasklist {
		screen = s,
		filter = awful.widget.tasklist.filter.currenttags,
		buttons = {
			awful.button({}, 1, function(c)
				c:activate { context = "tasklist", action = "toggle_minimization" }
			end),
			awful.button({}, 3, function() awful.menu.client_list { theme = { width = 250 } } end),
			awful.button({}, 4, function() awful.client.focus.byidx(-1) end),
			awful.button({}, 5, function() awful.client.focus.byidx(1) end),
		},
	}
	local bar = awful.wibar {
		position = "top",
		screen = s,
		widget = {
			layout = wibox.layout.align.horizontal,
			{
				layout = wibox.layout.fixed.horizontal,
				s.mypromptbox,
				taglist,
			},
			tasklist,
			{
				widget = wibox.container.margin,
				left = 6,
				right = 10,
				{
					layout = wibox.layout.fixed.horizontal,
					spacing = 12,
					tray,
					awful.widget.layoutbox {
						screen = s,
					},
					textclock,
					volume_icon,
					ac_icon,
					battery_box,
				},
			},
		}
	}
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
		awful.key {
			modifiers = { modkey },
			key = "t",
			on_press = function(c)
				c.ontop = not c.ontop
			end,
			description = "toggle keep on top",
		},
		awful.key {
			modifiers = { modkey },
			key = "Print",
			on_press = function(c)
				screenshot.interactive = false
				screenshot.client = c
				screenshot:refresh()
				screenshot:save()
			end,
			description = "take screenshot for client",
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
			screenshot.client = nil
			screenshot:refresh()
		end,
		description = "take interactive screenshot",
	},
	awful.key {
		modifiers = {},
		key = "Print",
		on_press = function()
			screenshot.interactive = false
			screenshot.client = nil
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
		on_press = function()
			local win = aweterm {}
			win:show_all()
		end,
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
		on_press = function() awfm.launch { terminal = terminal } end,
		description = "open a file manager",
	},
	awful.key {
		modifiers = { modkey },
		key = "r",
		on_press = function() awful.screen.focused().mypromptbox:run() end,
		description = "run prompt",
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

local source = Gio.SettingsSchemaSource.get_default()
if source:lookup "cn.jhb.awesome" then
	local settings = Gio.Settings.new "cn.jhb.awesome"
	local backlight = io.open("/sys/class/backlight/amdgpu_bl0/brightness", "w")
	if backlight then
		local max_brightness = tonumber(io.open("/sys/class/backlight/amdgpu_bl0/max_brightness"):read())
		backlight:write(string.format("%d", settings:get_int "brightness" * max_brightness / 100))
		backlight:flush()
		settings.on_changed["brightness"] = function()
			backlight:write(string.format("%d", settings:get_int "brightness" * max_brightness / 100))
			backlight:flush()
			naughty.notification {
				title = "Backlight",
				message = string.format("%d%%", settings:get_int "brightness")
			}
		end
		awful.keyboard.append_global_keybindings {
			group = "backlight",
			awful.key {
				modifiers = {},
				key = "XF86MonBrightnessUp",
				on_press = function()
					settings:set_int("brightness",
						settings:get_int "brightness" > 90 and 100 or
						settings:get_int "brightness" + 10)
				end,
				description = "increase brightness",
			},
			awful.key {
				modifiers = {},
				key = "XF86MonBrightnessDown",
				on_press = function()
					settings:set_int("brightness",
						settings:get_int "brightness" < 10 and 0 or
						settings:get_int "brightness" - 10)
				end,
				description = "decrease brightness",
			},
		}
	end

	os.execute(string.format("amixer set Master %d%%", settings:get_int "volume"))
	update_volume_icon(settings:get_boolean "mute", settings:get_int "volume")
	settings.on_changed["volume"] = function()
		naughty.notification {
			title = "volume",
			message = string.format("%d%%", settings:get_int "volume")
		}
		os.execute(string.format("amixer set Master %d%%", settings:get_int "volume"))
		update_volume_icon(settings:get_boolean "mute", settings:get_int "volume")
	end
	os.execute("amixer set Master " .. (settings:get_boolean "mute" and "mute" or "unmute"))
	settings.on_changed["mute"] = function()
		naughty.notification {
			title = "mute",
			message = string.format("%s", settings:get_boolean "mute")
		}
		update_volume_icon(settings:get_boolean "mute", settings:get_int "volume")
		os.execute("amixer set Master " .. (settings:get_boolean "mute" and "mute" or "unmute"))
	end

	awful.keyboard.append_global_keybindings {
		group = "volume",
		awful.key {
			modifiers = {},
			key = "XF86AudioRaiseVolume",
			on_press = function()
				settings:set_int("volume",
					settings:get_int "volume" > 90 and 100 or
					settings:get_int "volume" + 10)
			end,
			description = "increase volume",
		},
		awful.key {
			modifiers = {},
			key = "XF86AudioLowerVolume",
			on_press = function()
				settings:set_int("volume",
					settings:get_int "volume" < 10 and 0 or
					settings:get_int "volume" - 10)
			end,
			description = "decrease volume",
		},
		awful.key {
			modifiers = {},
			key = "XF86AudioMute",
			on_press = function()
				settings:set_boolean("mute", not settings:get_boolean "mute")
			end,
			description = "mute",
		},
	}
end

client.connect_signal("mouse::enter", function(c)
	c:activate { context = "mouse_enter", raise = false }
end)
