local ffi = require "ffi"
local math = require "math"

ffi.cdef [[
/** Standard flow control combinations. */
enum sp_flowcontrol {
	/** No flow control. */
	SP_FLOWCONTROL_NONE = 0,
	/** Software flow control using XON/XOFF characters. */
	SP_FLOWCONTROL_XONXOFF = 1,
	/** Hardware flow control using RTS/CTS signals. */
	SP_FLOWCONTROL_RTSCTS = 2,
	/** Hardware flow control using DTR/DSR signals. */
	SP_FLOWCONTROL_DTRDSR = 3
};
/** Parity settings. */
enum sp_parity {
	/** Special value to indicate setting should be left alone. */
	SP_PARITY_INVALID = -1,
	/** No parity. */
	SP_PARITY_NONE = 0,
	/** Odd parity. */
	SP_PARITY_ODD = 1,
	/** Even parity. */
	SP_PARITY_EVEN = 2,
	/** Mark parity. */
	SP_PARITY_MARK = 3,
	/** Space parity. */
	SP_PARITY_SPACE = 4
};
/** Return values. */
enum sp_return {
	/** Operation completed successfully. */
	SP_OK = 0,
	/** Invalid arguments were passed to the function. */
	SP_ERR_ARG = -1,
	/** A system error occurred while executing the operation. */
	SP_ERR_FAIL = -2,
	/** A memory allocation failed while executing the operation. */
	SP_ERR_MEM = -3,
	/** The requested operation is not supported by this system or device. */
	SP_ERR_SUPP = -4
};

enum sp_mode {
	/** Open port for read access. */
	SP_MODE_READ = 1,
	/** Open port for write access. */
	SP_MODE_WRITE = 2,
	/** Open port for read and write access. @since 0.1.1 */
	SP_MODE_READ_WRITE = 3
};
enum sp_return sp_blocking_write(struct sp_port *port, const void *buf, size_t count, unsigned int timeout_ms);

enum sp_return sp_set_parity(struct sp_port *port, enum sp_parity parity);

enum sp_return sp_set_stopbits(struct sp_port *port, int stopbits);

enum sp_return sp_set_flowcontrol(struct sp_port *port, enum sp_flowcontrol flowcontrol);

enum sp_return sp_set_bits(struct sp_port *port, int bits);

enum sp_return sp_set_baudrate(struct sp_port *port, int baudrate);

enum sp_return sp_list_ports(struct sp_port ***list_ptr);

void sp_free_port_list(struct sp_port **ports);

enum sp_return sp_get_port_by_name(const char *portname, struct sp_port **port_ptr);

enum sp_return sp_open(struct sp_port *port, enum sp_mode flags);

enum sp_return sp_close(struct sp_port *port);

enum sp_return sp_copy_port(const struct sp_port *port, struct sp_port **copy_ptr);

void sp_free_port(struct sp_port *port);

char *sp_get_port_name(const struct sp_port *port);

enum sp_return sp_blocking_write(struct sp_port *port, const void *buf, size_t count, unsigned int timeout_ms);

enum sp_return sp_input_waiting(struct sp_port *port);

enum sp_return sp_nonblocking_read(struct sp_port *port, void *buf, size_t count);

enum sp_return sp_nonblocking_write(struct sp_port* port,const void *buf, size_t count);

enum sp_return sp_get_port_handle(const struct sp_port* port,void* result_ptr);

struct sp_port;

struct lua_sp_port{
    struct sp_port * ptr;
};
]]

local sp = ffi.load "libserialport"
local buffer_t = ffi.typeof "uint8_t[?]"

ffi.metatype("struct lua_sp_port", {
	__gc = function(port)
		if port.ptr ~= nil then
			sp.sp_free_port(port.ptr)
		end
	end,
	__tostring = function(port)
		local result = tostring(port.ptr)
		if port.ptr ~= nil then
			result = result .. ' name: ' ..
			    ffi.string(sp.sp_get_port_name(port.ptr))
		end
		return result
	end,
	__index = {
		open = function(port, mode)
			assert(port.ptr ~= nil)
			return sp.sp_open(port.ptr, mode)
		end,
		close = function(port)
			assert(port.ptr ~= nil)
			return sp.sp_close(port.ptr)
		end,
		set_flowcontrol = function(port, flowcontrol)
			assert(port.ptr ~= nil)
			return sp.sp_set_flowcontrol(port.ptr, flowcontrol)
		end,
		set_baudrate = function(port, baudrate)
			assert(port.ptr ~= nil)
			return sp.sp_set_baudrate(port.ptr, baudrate)
		end,
		set_bits = function(port, bits)
			assert(port.ptr ~= nil)
			return sp.sp_set_bits(port.ptr, bits)
		end,
		set_parity = function(port, parity)
			assert(port.ptr ~= nil)
			return sp.sp_set_parity(port.ptr, parity)
		end,
		set_stopbits = function(port, stopbits)
			assert(port.ptr ~= nil)
			return sp.sp_set_stopbits(port.ptr, stopbits)
		end,
		blocking_write = function(port, buf, timeout_ms)
			assert(port.ptr ~= nil)
			assert(buf ~= nil)
			if timeout_ms == nil then
				timeout_ms = 0
			end
			return sp.sp_blocking_write(port.ptr, buf, #buf, timeout_ms)
		end,
		nonblocking_write = function(port, buf)
			assert(port.ptr ~= nil)
			assert(buf ~= nil)
			return sp.sp_nonblocking_write(port.ptr, buf, #buf)
		end,
		input_waiting = function(port)
			assert(port.ptr ~= nil)
			return sp.sp_input_waiting(port.ptr)
		end,
		get_port_name = function(port)
			assert(port.ptr ~= nil)
			local result = sp.sp_get_port_name(port.ptr)
			assert(result ~= nil)
			return ffi.string(result)
		end,
		nonblocking_read = function(port, count)
			assert(port.ptr ~= nil)
			local buf = buffer_t(count)
			local result = sp.sp_nonblocking_read(port.ptr, buf, count)
			if result > 0 then
				local str = ffi.string(buf, result)
				return str, result
			else
				return nil, result
			end
		end,
		get_port_handle = function(port)
			assert(port.ptr ~= nil)
			local buf = ffi.new("int[1]")
			local result = sp.sp_get_port_handle(port.ptr, buf)
			if result == sp.SP_OK then
				return buf[0]
			else
				return nil
			end
		end
	},
})

local function wrl_port(port)
	local wrl = ffi.new("struct lua_sp_port")
	wrl.ptr = port
	return wrl
end

local function new_port(old_port)
	if type(old_port) == "string" then
		local port = ffi.new("struct sp_port *[1]")
		local result = sp.sp_get_port_by_name(old_port, port)
		if result == sp.SP_OK then
			return wrl_port(port[0])
		else
			return nil
		end
	elseif ffi.istype("struct sp_port*", old_port) then
		local port = ffi.new("struct sp_port *[1]")
		local result = sp.sp_copy_port(old_port, port)
		if result == sp.SP_OK then
			return wrl_port(port[0])
		else
			return nil
		end
	else
		error("unsupport");
	end
end

local function list_ports()
	local c_ports = ffi.new("struct sp_port **[1]")
	local result = sp.sp_list_ports(c_ports)
	if result == sp.SP_OK then
		local ports = {}
		for i = 0, math.huge do
			if c_ports[0][i] ~= nil then
				ports[i + 1] = new_port(c_ports[0][i])
			else
				break;
			end
		end
		sp.sp_free_port_list(c_ports[0])
		return ports;
	else
		return nil, result
	end
end

local M = {
	list_ports = list_ports,
	get_port_by_name = new_port,
}

setmetatable(M, { __index = sp })

return M
