--- Vector icons for the status bar, generated with cairo.
--
-- Every glyph is drawn as vector paths, so the bar depends on neither a
-- symbol font nor an icon theme. Icons are rendered supersampled (2x) and
-- cached as cairo surfaces, then displayed by a plain imagebox.
--
--     icons.battery { level = 98, charging = false, fg = "#ffffff", bg = "#000000" }
--     icons.ac      { connected = true }
--     icons.volume  { muted = false }

local lgi = require "lgi"
local cairo = lgi.cairo
local gcolor = require "gears.color"

local icons = {}

local SS = 2 -- supersampling factor

-- Logical size of every icon at 96 DPI.
local sizes = {
	battery = { 20, 10 },
	ac      = { 12, 12 },
	volume  = { 16, 12 },
}

-- cairo_line_cap_t / cairo_line_join_t values (ABI stable).
local cap_round = (cairo.LineCap and cairo.LineCap.ROUND) or 1
local join_round = (cairo.LineJoin and cairo.LineJoin.ROUND) or 1

-- Scale the icons with the font, so they keep the same visual weight next
-- to the bar's text (the font height already accounts for Xft DPI). A
-- battery 10 logical pixels tall ends up as tall as the digits at 32 px.
do
	local ok, beautiful = pcall(require, "beautiful")
	if ok and beautiful.get_font_height then
		local ok2, font_height = pcall(beautiful.get_font_height)
		if ok2 and type(font_height) == "number" and font_height > 0 then
			icons.scale = math.max(1, font_height / 20)
		end
	end
end
icons.scale = icons.scale or 1

--- Logical size of an icon, scaled for the current DPI.
-- @treturn number, number width, height
function icons.size(name)
	local s = assert(sizes[name], "unknown icon '" .. tostring(name) .. "'")
	return math.ceil(s[1] * icons.scale), math.ceil(s[2] * icons.scale)
end

local function set_color(cr, color, fallback)
	local r, g, b, a = gcolor.parse_color(type(color) == "string" and color or "")
	if not r then
		r, g, b, a = gcolor.parse_color(fallback)
	end
	cr:set_source_rgba(r, g, b, a or 1)
end

local function rounded_rect(cr, x, y, w, h, r)
	r = math.min(r, w / 2, h / 2)
	cr:move_to(x + r, y)
	cr:line_to(x + w - r, y)
	cr:arc(x + w - r, y + r, r, -math.pi / 2, 0)
	cr:line_to(x + w, y + h - r)
	cr:arc(x + w - r, y + h - r, r, 0, math.pi / 2)
	cr:line_to(x + r, y + h)
	cr:arc(x + r, y + h - r, r, math.pi / 2, math.pi)
	cr:line_to(x, y + r)
	cr:arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
	cr:close_path()
end

-- Lightning bolt, normalized to a box.
local bolt_shape = {
	{ 0.50, 0.00 }, { 0.10, 0.55 }, { 0.40, 0.55 },
	{ 0.30, 1.00 }, { 0.90, 0.45 }, { 0.60, 0.45 },
}

local function bolt_path(cr, x, y, w, h)
	cr:move_to(x + bolt_shape[1][1] * w, y + bolt_shape[1][2] * h)
	for i = 2, #bolt_shape do
		cr:line_to(x + bolt_shape[i][1] * w, y + bolt_shape[i][2] * h)
	end
	cr:close_path()
end

-- A diagonal "off" slash with a halo in the bar background color, so it
-- stays readable on top of both the icon and the empty space.
local function slash(cr, x1, y1, x2, y2, fg, bg)
	set_color(cr, bg, "#000000")
	cr:set_line_width(2.6)
	cr:move_to(x1, y1)
	cr:line_to(x2, y2)
	cr:stroke_preserve()
	set_color(cr, fg, "#ffffff")
	cr:set_line_width(1.4)
	cr:stroke()
end

local cache = {}

local function render(name, key, draw)
	if cache[key] then return cache[key] end
	local s = assert(sizes[name], "unknown icon '" .. tostring(name) .. "'")
	local pw = math.ceil(s[1] * icons.scale * SS)
	local ph = math.ceil(s[2] * icons.scale * SS)
	local surf = cairo.ImageSurface(cairo.Format.ARGB32, pw, ph)
	local cr = cairo.Context(surf)
	cr:scale(pw / s[1], ph / s[2]) -- draw in logical units
	draw(cr, s[1], s[2])
	surf:flush()
	cache[key] = surf
	return surf
end

--- Battery icon.
-- @tparam table o `{ level = 0..100, charging = bool, fg = color, bg = color }`
function icons.battery(o)
	o = o or {}
	local level = math.max(0, math.min(100, math.floor((o.level or 0) + 0.5)))
	local charging = o.charging and true or false
	local fg, bg = o.fg, o.bg
	-- Quantize the fill: sub-percent differences are invisible anyway.
	local bucket = math.floor((level + 2.5) / 5) * 5
	local key = ("battery|%d|%s|%s|%s"):format(bucket, charging and "c" or "-", fg or "", bg or "")

	return render("battery", key, function(cr)
		local fill = fg
		if charging then
			fill = "#4cc36a"
		elseif bucket <= 10 then
			fill = "#e05555"
		elseif bucket <= 20 then
			fill = "#d19a66"
		end

		-- Casing
		set_color(cr, fg, "#ffffff")
		cr:set_line_width(1.5)
		rounded_rect(cr, 0.75, 0.75, 16.5, 8.5, 2.2)
		cr:stroke()
		-- Terminal nub (overlaps the casing stroke so it looks attached)
		rounded_rect(cr, 17, 3.25, 2.6, 3.5, 1.2)
		cr:fill()

		-- Charge level
		if bucket > 0 then
			set_color(cr, fill, "#4cc36a")
			rounded_rect(cr, 2.5, 2.5, math.max(1.6, 13 * bucket / 100), 5, 1)
			cr:fill()
		end

		-- Charging bolt, haloed against whatever is behind it
		if charging then
			bolt_path(cr, 6.7, 2.6, 4.6, 5)
			set_color(cr, bg, "#000000")
			cr:set_line_width(2.2)
			cr:set_line_join(join_round)
			cr:stroke_preserve()
			set_color(cr, fg, "#ffffff")
			cr:fill()
		end
	end)
end

--- AC (mains) icon: a plug, crossed out when not connected.
-- @tparam table o `{ connected = bool, fg = color, bg = color }`
function icons.ac(o)
	o = o or {}
	local connected = o.connected and true or false
	local fg, bg = o.fg, o.bg
	local key = ("ac|%s|%s|%s"):format(connected and "in" or "out", fg or "", bg or "")

	return render("ac", key, function(cr)
		set_color(cr, fg, "#ffffff")
		cr:set_line_cap(cap_round)

		-- Prongs
		cr:set_line_width(1.6)
		cr:move_to(3.9, 1.4)
		cr:line_to(3.9, 5.6)
		cr:stroke()
		cr:move_to(8.1, 1.4)
		cr:line_to(8.1, 5.6)
		cr:stroke()

		-- Body
		rounded_rect(cr, 1.5, 5, 9, 4.8, 1.6)
		cr:fill()

		-- Cable
		cr:set_line_width(1.8)
		cr:move_to(6, 9.2)
		cr:line_to(6, 11.2)
		cr:stroke()

		if not connected then
			slash(cr, 1, 11, 11, 1, fg, bg)
		end
	end)
end

--- Volume icon: a speaker with sound waves, crossed out when muted.
-- @tparam table o `{ muted = bool, fg = color, bg = color }`
function icons.volume(o)
	o = o or {}
	local muted = o.muted and true or false
	local fg, bg = o.fg, o.bg
	local key = ("volume|%s|%s|%s"):format(muted and "m" or "-", fg or "", bg or "")

	return render("volume", key, function(cr)
		set_color(cr, fg, "#ffffff")

		-- Speaker
		cr:move_to(1, 4.7)
		cr:line_to(4.6, 4.7)
		cr:line_to(8.7, 1)
		cr:line_to(8.7, 11)
		cr:line_to(4.6, 7.3)
		cr:line_to(1, 7.3)
		cr:close_path()
		cr:fill()

		if muted then
			slash(cr, 1.6, 10.6, 10.6, 1.4, fg, bg)
		else
			-- Sound waves
			cr:set_line_cap(cap_round)
			cr:set_line_width(1.4)
			cr:arc(9.4, 6, 2.9, math.rad(-50), math.rad(50))
			cr:stroke()
			cr:arc(9.4, 6, 5.4, math.rad(-50), math.rad(50))
			cr:stroke()
		end
	end)
end

return icons
