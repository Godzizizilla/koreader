--[[--
Headless 8bpp framebuffer for the read_pico e-reader (684x1216, 16 gray levels).

Every refresh pushes its rectangle's pixels plus the KOReader refresh type to the bridge;
the e-reader picks the waveform (a full-screen "partial" becomes its row-staggered GL16 page-turn sweep).
fb_bpp = 8 enables KOReader's own ordered dithering to 16 levels, matching the panel.
]]

local BB = require("ffi/blitbuffer")
local ffi = require("ffi")

local framebuffer = {
    width = 684,
    height = 1216,
    fb_bpp = 8,
    link = nil,
}

function framebuffer:init()
    self.bb = BB.new(self.width, self.height, BB.TYPE_BB8)
    self.bb:fill(BB.COLOR_WHITE)
    self.copy_buf = ffi.new("uint8_t[?]", self.width * self.height)
    framebuffer.parent.init(self)
end

-- Physical rows of a (logical) rectangle, as one contiguous string.
function framebuffer:_push(mode, x, y, w, h)
    local bb = self.full_bb or self.bb
    x, y, w, h = bb:getBoundedRect(x, y, w, h)
    if w <= 0 or h <= 0 then return end
    local px, py, pw, ph = bb:getPhysicalRect(x, y, w, h)
    local src = ffi.cast("uint8_t*", bb.data)
    local stride = bb.stride
    for row = 0, ph - 1 do
        ffi.copy(self.copy_buf + row * pw, src + (py + row) * stride + px, pw)
    end
    self.link:sendFrame(mode, bb:getInverse() == 1, px, py, pw, ph, ffi.string(self.copy_buf, pw * ph))
end

--- Push the whole screen as a "full" refresh (e.g., after the bridge (re)connects).
function framebuffer:pushAll()
    local bb = self.full_bb or self.bb
    self:_push("full", 0, 0, bb:getWidth(), bb:getHeight())
end

local function imp(mode)
    return function(self, x, y, w, h)
        self:_push(mode, x, y, w, h)
    end
end

framebuffer.refreshFullImp = imp("full")
framebuffer.refreshPartialImp = imp("partial")
framebuffer.refreshNoMergePartialImp = imp("partial")
framebuffer.refreshFlashPartialImp = imp("flashpartial")
framebuffer.refreshUIImp = imp("ui")
framebuffer.refreshNoMergeUIImp = imp("ui")
framebuffer.refreshFlashUIImp = imp("flashui")
framebuffer.refreshFastImp = imp("fast")
framebuffer.refreshA2Imp = imp("a2")

return require("ffi/framebuffer"):extend(framebuffer)
