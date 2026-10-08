--[[--
TCP link to the read_pico bridge (tools/koreader_bridge in the read_pico firmware repo).

KOReader → bridge: rendered rectangles (physical BB8 pixels) tagged with the KOReader refresh type,
and a commit marker once per UI loop iteration.
Bridge → KOReader: raw touch contacts and the e-reader's touch keys.

Also serves as the input backend (same contract as ffi/input_*: waitForEvent(sec, usec)).

Message framing (both directions): "KP" | type u8 | len u32 (little-endian) | payload
]]

local ffi = require("ffi")
local logger = require("logger")
local socket = require("socket")
local C = ffi.C

require("ffi/posix_h")
require("ffi/linux_input_h")

local T_FRAME = 1
local T_COMMIT = 2
local T_TOUCH = 0x10
local T_KEY = 0x11

-- KOReader refresh type → wire code (must match the firmware's usb_link.h).
local KO_TYPE = {
    a2 = 0, fast = 1, ui = 2, partial = 3, flashui = 4, flashpartial = 5, full = 6,
}

local function u16(v) return string.char(bit.band(v, 0xFF), bit.band(bit.rshift(v, 8), 0xFF)) end
local function u32(v)
    return string.char(bit.band(v, 0xFF), bit.band(bit.rshift(v, 8), 0xFF),
                       bit.band(bit.rshift(v, 16), 0xFF), bit.band(bit.rshift(v, 24), 0xFF))
end
local function rd16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end

local Link = {
    host = "127.0.0.1",
    port = 7788,
    sock = nil,
    rx = "",
    dirty = false,
    next_retry = 0,
    -- touch id from the device → { slot, tracking_id }
    contacts = nil,
    next_tracking_id = 1,
    on_connect = nil,
}

function Link:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if o.address then
        local h, p = o.address:match("^(.-):(%d+)$")
        if h then o.host, o.port = h, tonumber(p) end
    end
    o.contacts = {}
    return o
end

function Link:connected() return self.sock ~= nil end

function Link:_drop(why)
    if self.sock then
        logger.warn("pico: bridge link lost:", why)
        self.sock:close()
    end
    self.sock = nil
    self.rx = ""
    self.contacts = {}
end

function Link:_ensure()
    if self.sock or socket.gettime() < self.next_retry then return end
    self.next_retry = socket.gettime() + 1
    local s = socket.tcp()
    s:settimeout(0.2)
    if s:connect(self.host, self.port) then
        s:setoption("tcp-nodelay", true)
        self.sock = s
        logger.info("pico: connected to bridge", self.host, self.port)
        -- The bridge knows nothing yet: resend the whole screen.
        if self.on_connect then self.on_connect() end
    else
        s:close()
    end
end

function Link:_send(t, payload)
    self:_ensure()
    if not self.sock then return end
    self.sock:settimeout(5)
    local ok, err = self.sock:send("KP" .. string.char(t) .. u32(#payload) .. payload)
    if not ok then self:_drop(err) end
end

--- Push one rendered rectangle (physical coordinates, w*h BB8 bytes).
function Link:sendFrame(mode, inverse, x, y, w, h, pixels)
    self:_send(T_FRAME, string.char(KO_TYPE[mode] or KO_TYPE.partial, inverse and 1 or 0)
        .. u16(x) .. u16(y) .. u16(w) .. u16(h) .. pixels)
    self.dirty = true
end

function Link:commit()
    if not self.dirty then return end
    self.dirty = false
    self:_send(T_COMMIT, "")
end

local function now_timeval()
    local ts = ffi.new("struct timespec")
    C.clock_gettime(C.CLOCK_MONOTONIC_COARSE, ts)
    return { sec = tonumber(ts.tv_sec), usec = math.floor(tonumber(ts.tv_nsec) / 1000) }
end

-- Turn a full contact list into MT protocol B events, like ffi/SDL3.lua does for mice and fingers.
function Link:_touch(payload, out)
    local tv = now_timeval()
    local function ev(t, code, value)
        table.insert(out, { type = t, code = code, value = value, time = tv })
    end
    local seen = {}
    local n = payload:byte(1)
    for i = 0, n - 1 do
        local o = 2 + i * 5
        local id, x, y = payload:byte(o), rd16(payload, o + 1), rd16(payload, o + 3)
        seen[id] = true
        local c = self.contacts[id]
        if not c then
            local used = {}
            for _, v in pairs(self.contacts) do used[v.slot] = true end
            local slot = 0
            while used[slot] do slot = slot + 1 end
            c = { slot = slot, tracking_id = self.next_tracking_id }
            self.next_tracking_id = self.next_tracking_id + 1
            self.contacts[id] = c
            ev(C.EV_ABS, C.ABS_MT_SLOT, c.slot)
            ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, c.tracking_id)
        else
            ev(C.EV_ABS, C.ABS_MT_SLOT, c.slot)
        end
        ev(C.EV_ABS, C.ABS_MT_POSITION_X, x)
        ev(C.EV_ABS, C.ABS_MT_POSITION_Y, y)
    end
    for id, c in pairs(self.contacts) do
        if not seen[id] then
            ev(C.EV_ABS, C.ABS_MT_SLOT, c.slot)
            ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, -1)
            self.contacts[id] = nil
        end
    end
    ev(C.EV_SYN, C.SYN_REPORT, 0)
end

function Link:_key(payload, out)
    local tv = now_timeval()
    -- Touch keys only report presses: synthesize press + release.
    local code = payload:byte(1) + 1
    table.insert(out, { type = C.EV_KEY, code = code, value = 1, time = tv })
    table.insert(out, { type = C.EV_KEY, code = code, value = 0, time = tv })
end

function Link:_parse(out)
    while #self.rx >= 7 do
        if self.rx:sub(1, 2) ~= "KP" then
            self:_drop("bad magic")
            return
        end
        local t = self.rx:byte(3)
        local len = rd16(self.rx, 4) + rd16(self.rx, 6) * 65536
        if #self.rx < 7 + len then return end
        local payload = self.rx:sub(8, 7 + len)
        self.rx = self.rx:sub(8 + len)
        if t == T_TOUCH then self:_touch(payload, out)
        elseif t == T_KEY then self:_key(payload, out) end
    end
end

--- Input backend: wait up to (sec, usec) for touch/keys from the bridge.
function Link:waitForEvent(sec, usec)
    -- One UIManager iteration ends here: whatever was refreshed belongs to one batch.
    self:commit()
    local deadline = sec and socket.gettime() + sec + usec / 1e6
    local out = {}
    while true do
        self:_ensure()
        local left = deadline and math.max(0, deadline - socket.gettime()) or 1
        if self.sock then
            local r = socket.select({ self.sock }, nil, math.min(left, 1))
            if r and r[1] then
                self.sock:settimeout(0)
                local data, err, partial = self.sock:receive(65536)
                data = data or partial
                if data and #data > 0 then self.rx = self.rx .. data end
                if err == "closed" then self:_drop(err) end
                self:_parse(out)
                if #out > 0 then return true, out end
            end
        else
            socket.sleep(math.min(left, 0.2))
        end
        if deadline and socket.gettime() >= deadline then return false, C.ETIME end
    end
end

--- Wrap as an input module (dot-call functions, like ffi/input_*).
function Link:inputBackend()
    return {
        waitForEvent = function(sec, usec) return self:waitForEvent(sec, usec) end,
        closeAll = function() end,
    }
end

return Link
