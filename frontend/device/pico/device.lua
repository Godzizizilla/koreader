--[[--
read_pico e-reader as a remote display + touch panel (selected with KO_PICO=host:port).

KOReader runs on a host (Mac now, a Raspberry Pi CM0 later); the bridge
(read_pico firmware repo, tools/koreader_bridge) forwards frames over USB to the e-reader
and sends its touches back.
]]

local Generic = require("device/generic/device")
local logger = require("logger")

local function yes() return true end
local function no() return false end

local Device = Generic:extend{
    model = "Pico",
    isTouchDevice = yes,
    hasMultitouch = yes,
    hasKeys = yes,
    hasEinkScreen = yes,
    hasColorScreen = no,
    canHWDither = no,
    hasFrontlight = no,
    hasWifiToggle = no,
    -- 4.7" 684x1216
    display_dpi = 297,
    home_dir = os.getenv("KO_PICO_HOME") or os.getenv("HOME"),
}

function Device:init()
    self.link = require("device/pico/link"):new{ address = os.getenv("KO_PICO") }
    self.screen = require("device/pico/framebuffer"):new{
        device = self,
        debug = logger.dbg,
        link = self.link,
    }
    self.link.on_connect = function()
        self.screen:pushAll()
        self.link:commit()
    end
    self.input = require("device/input"):new{
        device = self,
        input = self.link:inputBackend(),
        -- The three touch keys under the panel: left, middle, right.
        event_map = {
            [1] = "LPgBack",
            [2] = "Menu",
            [3] = "LPgFwd",
        },
    }
    Generic.init(self)
end

return Device
