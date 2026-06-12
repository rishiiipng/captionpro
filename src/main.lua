--[[
  CaptionPro.lua  -  Entry point (Workspace > Scripts > Comp > CaptionPro)

  DaVinci Resolve injects `resolve`, `fusion`/`fu`, and `bmd` as globals.
  This file resolves the source directory, sets package.path, then launches
  the UI panel.  Every step is written to a startup log file so failures
  are diagnosable even if no UI can be shown.
]]

-- ===========================================================================
-- 0.  Startup log  (written before any require/UI so crashes are visible)
-- ===========================================================================

local _log_dir  = (os.getenv("USERPROFILE") or os.getenv("HOME") or ".") .. "/CaptionPro Logs"
local _log_path = _log_dir .. "/startup.log"
os.execute('cmd /c if not exist "' .. _log_dir:gsub("/", "\\") .. '" mkdir "' .. _log_dir:gsub("/", "\\") .. '"')

local function slog(msg)
  local f = io.open(_log_path, "a")
  if f then
    f:write(os.date("[%H:%M:%S] ") .. tostring(msg) .. "\n")
    f:close()
  end
end

-- Fresh log each launch
do
  local f = io.open(_log_path, "w")
  if f then
    f:write("=== CaptionPro startup  " .. os.date() .. " ===\n")
    f:close()
  end
end

slog("Script file: " .. (debug.getinfo(1,"S").source or "?"))
slog("resolve=" .. tostring(resolve) ..
     "  fusion=" .. tostring(fusion) ..
     "  fu=" .. tostring(fu) ..
     "  bmd=" .. tostring(bmd))

-- ===========================================================================
-- 1.  Normalise globals  (Resolve exposes both `fu` and `fusion`)
-- ===========================================================================

-- `fu` is the preferred short alias inside Resolve scripts;
-- `fusion` is the full name. Either may be the one that is non-nil.
if not fu and fusion then fu = fusion end

slog("fu after normalise: " .. tostring(fu))

-- ===========================================================================
-- 2.  Resolve the CaptionPro_src/ directory
-- ===========================================================================

local src_dir = nil

-- Strategy A: derive from this file's own path via debug.getinfo.
-- This is the most reliable method - it uses the actual path Resolve loaded
-- this file from, so it works regardless of install location.
-- Source looks like: @C:\Users\...\Scripts\Comp\CaptionPro.lua
do
  local info_src = debug.getinfo(1, "S").source or ""
  if info_src:sub(1,1) == "@" then info_src = info_src:sub(2) end
  info_src = info_src:gsub("\\", "/")
  -- Strip last two components (Comp/CaptionPro.lua) to get Scripts dir
  local scripts_dir = info_src:match("^(.*)/[^/]+/[^/]+$")
  if scripts_dir then
    src_dir = scripts_dir .. "/CaptionPro_src/"
    slog("Strategy A (debug.getinfo): src_dir=" .. src_dir)
  end
end

-- Strategy B: hard-coded AppData fallback (Windows)
if not src_dir then
  local appdata = os.getenv("APPDATA")
  if appdata then
    src_dir = appdata:gsub("\\", "/") ..
              "/Blackmagic Design/DaVinci Resolve/Support/Fusion/Scripts" ..
              "/CaptionPro_src/"
    slog("Strategy B (AppData fallback): src_dir=" .. src_dir)
  end
end

-- NOTE: fu:GetGlobalPathMap() was tried previously but returns Fusion internal
-- path aliases like "UserPaths:Scripts/" which Lua's require() cannot resolve.

if not src_dir then
  slog("FATAL: could not determine src_dir")
  -- Show a plain error via print; UI is not available yet
  print("CaptionPro Lua: cannot determine script source directory. " ..
        "Check " .. _log_path)
  return
end

slog("Final src_dir: " .. src_dir)

-- ===========================================================================
-- 3.  Register package search path
-- ===========================================================================

package.path = src_dir .. "?.lua;"
             .. src_dir .. "?/init.lua;"
             .. package.path

slog("package.path prefix set.")

-- ===========================================================================
-- 4.  Launch panel
-- ===========================================================================

local ok, err = pcall(function()
  local panel = require("ui.panel")
  slog("panel module loaded OK")
  panel.launch()
  slog("panel.launch() returned")
end)

if not ok then
  local msg = tostring(err)
  slog("LAUNCH ERROR: " .. msg)

  -- Try to show a UI error dialog
  local shown = false
  if fu then
    local ui_ok = pcall(function()
      local ui   = fu.UIManager
      local disp = bmd.UIDispatcher(ui)  -- dot, not colon; colon passes bmd as UIMan
      local win  = disp:AddWindow({
        WindowTitle = "CaptionPro - Startup Error",
        ID          = "ErrWin",
        ui:VGroup({ Spacing = 6,
          ui:Label({ Text = "CaptionPro failed to start:",
                     Font = ui:Font({ Bold = true }),
                     StyleSheet = "color: #ff6666;" }),
          ui:TextEdit({ ID = "ErrText", ReadOnly = true,
                        Text = msg .. "\n\nLog file: " .. _log_path }),
          ui:Label({ Text = "Send the log file to: aniket.bhattacharjee@gmail.com",
                     StyleSheet = "color: #888888;" }),
          ui:Button({ ID = "CloseBtn", Text = "Close" }),
        }),
      })
      -- Geometry must be set after creation, not inside AddWindow (see Rule 2)
      win:Move(200, 200)
      win:Resize(480, 340)
      win.On.ErrWin.Close     = function() disp:ExitLoop() end
      win.On.CloseBtn.Clicked = function() disp:ExitLoop() end
      win:Show()
      disp:RunLoop()
      win:Hide()
    end)
    shown = ui_ok
  end

  if not shown then
    -- Last resort: Resolve's built-in alert (always available)
    if fusion then
      pcall(function()
        fusion:GetCurrentComp():Print(
          "CaptionPro Lua error: " .. msg ..
          "\nLog: " .. _log_path)
      end)
    end
    print("CaptionPro Lua error: " .. msg)
    print("Log file: " .. _log_path)
  end
end
