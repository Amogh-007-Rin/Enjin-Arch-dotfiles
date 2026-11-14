-- ~/.config/hypr/hyprland.lua
-- Docs: https://wiki.hypr.land/Configuring/Start/

---- MY PROGRAMS ----

mainMod    = "SUPER"
terminal   = "kitty"
menu       = "rofi -show drun"
fileManager = "thunar"
browser    = "brave"

-- Overrides written by Quickshell (Settings > Configs): mainMod, browser.
-- Must load before keybinds.lua, which reads these globals when binding.
do
    local f = os.getenv("HOME") .. "/.config/quickshell/state/prefs.lua"
    local fh = io.open(f, "r")
    if fh then
        fh:close()
        local ok, err = pcall(dofile, f)
        if not ok then print("state/prefs.lua failed: " .. tostring(err)) end
    end
end

-- The installer may generate hardware-specific GPU environment settings.
-- Keep them outside the repository and load them only when present.
do
    local f = os.getenv("HOME") .. "/.config/hypr/gpu.lua"
    local fh = io.open(f, "r")
    if fh then
        fh:close()
        local ok, err = pcall(dofile, f)
        if not ok then print("gpu.lua failed: " .. tostring(err)) end
    end
end

---- AUTOSTART ----
local function repair_wallpaper_outputs()
    -- Monitor hotplug/reconfiguration can leave awww with a stale Wayland
    -- output registry. The helper repairs that registry and reapplies the
    -- saved wallpaper to every active output.
    hl.exec_cmd("~/.config/hypr/scripts/wallpaper-monitor-sync.sh --once")
end

hl.on("monitor.added", repair_wallpaper_outputs)
hl.on("monitor.removed", repair_wallpaper_outputs)
hl.on("monitor.layout_changed", repair_wallpaper_outputs)
hl.on("config.reloaded", repair_wallpaper_outputs)

hl.on("hyprland.start", function()
    -- hl.exec_cmd("dunst") replaced with quickshell
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
    hl.exec_cmd("nm-applet")
    hl.exec_cmd("wl-paste --type text --watch cliphist store")
    hl.exec_cmd("wl-paste --type image --watch cliphist store")
    hl.exec_cmd("awww-daemon --no-cache")
    hl.exec_cmd("~/.config/hypr/scripts/wallpaper-monitor-sync.sh --once")
    hl.exec_cmd("sleep 1 && QSG_RENDER_LOOP=basic QS_ICON_THEME=Papirus qs")
end)

---- ENVIRONMENT VARIABLES ----

hl.env("XCURSOR_SIZE", "14")
hl.env("QT_QPA_PLATFORM", "wayland")
hl.env("MOZ_ENABLE_WAYLAND", "1")

---- INPUT ----

hl.config({
    input = {
        kb_layout = "us",
        follow_mouse = 1,
        sensitivity = 0.5,
        touchpad = {
            natural_scroll = false,
            tap_to_click = true,
        },
    },
})

-- LAYOUT
hl.config({
    dwindle = { preserve_split = true },
})
hl.config({
    master = { new_status = "master" },
})

-- MISC
hl.config({
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
    },
})

local f = os.getenv("HOME") .. "/.config/quickshell/state/devices.lua"
if io.open(f, "r") then dofile(f) end

---- SPLIT-OUT FILES ----

require("monitors")
require("keybinds")
require("look")
do
    local f = os.getenv("HOME") .. "/.config/quickshell/state/look.lua"
    local fh = io.open(f, "r")
    if fh then
        fh:close()
        local ok, err = pcall(dofile, f)
        if not ok then print("state/look.lua failed: " .. tostring(err)) end
    end
end
require("rules")

-- HyprMod managed settings
require("hyprland-gui")

-- Let applications follow the same XDG choice as Super+B.
hl.env("BROWSER", "python3 " .. os.getenv("HOME") .. "/.config/hypr/scripts/default-browser.py")
