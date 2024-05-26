local rtc_mem_log_address = 11
local rtc_mem_rtc_time_cal_address = 10
local rtcmem = require("rtcmem")

local M = {}

-- function M.dump(o)
-- 	if type(o) == "table" then
-- 		local s = "{"
-- 		for k, v in pairs(o) do
-- 			if type(k) ~= "number" then
-- 				k = '"' .. k .. '"'
-- 			end
-- 			s = s .. "[" .. k .. "] = " .. dump(v) .. ", "
-- 		end
-- 		return s .. "}"
-- 	else
-- 		return '"' .. tostring(o) .. '"'
-- 	end
-- end

local function int32_to_8(value)
	local a = value % 256
	local b = math.floor(value / 256 + 0.5) % 256
	local c = math.floor(value / 65536 + 0.5) % 256
	local d = math.floor(value / 16777216 + 0.5) % 256
	return a, b, c, d
end

local function int8_to_32(a, b, c, d)
	local v = a + b * 256 + c * 65536 + d * 16777216
	return v
end

function M.rtcmem_get_clock_calibration_status()
	local status, status_a, status_b, status_c
	status, status_a, status_b, status_c = int32_to_8(rtcmem.read32(rtc_mem_rtc_time_cal_address))
	if (status == status_a - 1) and (status == status_b - 2) and (status == status_c - 3) then
		return status
	else
		return nil
	end
end

function M.rtcmem_set_clock_calibration_status(cycle)
	rtcmem.write32(rtc_mem_rtc_time_cal_address, int8_to_32(cycle, cycle + 1, cycle + 2, cycle + 3))
end

function M.rtcmem_write_log_slot(slot, data32)
	local t = rtc_mem_log_address + (slot - 1 * 10)
	print(string.format("Writing 10 * 4 bytes integers starting at RTC location %d", t))
	for i = 1, 10 do
		rtcmem.write32(t + (i - 1), data32[i])
	end
end

function M.rtcmem_clear_log()
	print("Clearing RTC log.")
	for i = 0, 79 do
		rtcmem.write32(rtc_mem_log_address + i, i)
	end
end

function M.rtcmem_erase()
	print("Clearing RTCTime data...")
	for i = 0, 127 do
		rtcmem.write32(i, 0)
	end
end

function M.rtcmem_dump()
	print("Content of RTC memory:")
	for i = 0, 127 do
		local a, b, c, d = int32_to_8(rtcmem.read32(i))
		print(string.format("[%03d] %02x %02x %02x %02x", i, a, b, c, d))
	end
end

--[[
typedef struct pulse_log_t {
	uint8_t vcc;
	uint16_t ticks;
	uint8_t frames[LOG_FRAMES];
} pulse_log_t;
]]
function M.rtcmem_read_log_json()
	local j, a, b, c, d
	local cycles = {}
	local cycle_buf = {}
	local log = "{"

	j = 0
	for i = 0, 79 do
		a, b, c, d = int32_to_8(rtcmem.read32(rtc_mem_log_address + i))
		table.insert(cycle_buf, a)
		table.insert(cycle_buf, b)
		table.insert(cycle_buf, c)
		table.insert(cycle_buf, d)

		j = j + 4
		if j == 40 then
			table.insert(cycles, cycle_buf)
			cycle_buf = {}
			j = 0
		end
	end

	local valid_cycles = 0
	for cycle_idx, status in pairs(cycles) do
		local intbuf
		local checksum = 64
		local logbuf

		for byte_idx, byte in pairs(status) do
			if byte_idx < 40 then
				checksum = checksum + byte
			end

			if byte_idx == 1 then
				logbuf = '{"v":' .. tostring(byte)
			end

			-- First byte of the "ticks" uint16
			if byte_idx == 2 then
				intbuf = byte
			end

			if byte_idx == 3 then
				intbuf = intbuf + byte * 256
				logbuf = logbuf .. ',"t":' .. tostring(intbuf)
			end

			if byte_idx == 4 then
				logbuf = logbuf .. ',"f": [' .. tostring(byte)
			end

			if byte_idx > 4 and byte_idx < 39 then
				logbuf = logbuf .. "," .. tostring(byte)
			end

			if byte_idx == 39 then
				logbuf = logbuf .. "," .. tostring(byte) .. "]}"
			end

			if byte_idx == 40 then
				if checksum % 256 == byte then
					if valid_cycles > 0 then
						log = log .. ","
					end
					log = log .. '"' .. tostring(cycle_idx - 1) .. '": ' .. logbuf
					valid_cycles = valid_cycles + 1
				end
			end
		end
	end

	log = log .. "}"

	return log
end

function M.tiny_read_log()
	-- Pin mapping between ESP and NodeMCU IO
	--  IO  ESP     IO  ESP
	--  0   GPIO16  7   GPIO13
	--  1   GPIO5   8   GPIO15
	--  2   GPIO4   9   GPIO3
	--  3   GPIO0   10  GPIO1
	--  4   GPIO2   11  GPIO9
	--  5   GPIO14  12  GPIO10
	--  6   GPIO12

	local id = 0
	local sda = 1
	local scl = 2
	local slv = 0x5d
	local data32 = {}

	local i2c = require("i2c")

	i2c.setup(id, sda, scl, i2c.SLOW)
	i2c.address(id, slv, i2c.RECEIVER)

	local rec = i2c.read(id, 40)
	local byte = 0
	local temp = 0

	print(string.format("Dumped %d bytes from TINY", #rec))

	-- Encodes the 40 bytes into 10 32-bit integers
	for i = 1, #rec do
		local b = string.byte(rec:sub(i, i))

		--[print("I2C byte " .. (i - 1) .. ":" .. b)]]--

		temp = temp + b * 2 ^ (8 * byte)
		byte = byte + 1

		if (byte == 4) then
			table.insert(data32, temp)
			temp = 0
			byte = 0
		end
	end

	return data32
end

return M
