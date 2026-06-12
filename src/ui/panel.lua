--[[
  panel.lua - CaptionPro UIManager panel (Alpha)
  Workspace > Scripts > Comp > CaptionPro

  Two hard-won API rules for Resolve Lua UIManager:
    1. Use  bmd.UIDispatcher(ui)  NOT  bmd:UIDispatcher(ui)
       Colon passes bmd as the UIMan arg → Window() is nil at AddWindow.
    2. Do NOT put Geometry = {x,y,w,h} inside disp:AddWindow({}).
       AddWindow iterates all table-valued entries looking for widgets and calls
       :Window() on each; the plain numbers table has no Window method → crash.
       Use win:Move() + win:Resize() after creation instead.
]]

local workflow = require("core.workflow")

if not fu and fusion then fu = fusion end  -- luacheck: ignore

local M = {}

local VERSION       = "0.1-alpha"
local CREATOR       = "Rishi"
local CONTACT_EMAIL = "aniket.bhattacharjee@gmail.com"

local function get_log_path()
  return (os.getenv("USERPROFILE") or os.getenv("HOME") or ".") ..
         "/CaptionPro Logs/build.log"
end

local function write_error_log(msg)
  local path = get_log_path()
  local f = io.open(path, "a")
  if f then
    f:write("\n=== ERROR " .. os.date() .. " ===\n" .. tostring(msg) .. "\n")
    f:close()
  end
  return path
end

function M.launch()
  local ui   = fu.UIManager
  local disp = bmd.UIDispatcher(ui)  -- DOT not colon

  local win = disp:AddWindow({
    WindowTitle = "CaptionPro [Alpha]",
    ID          = "CaptionProWin",

    ui:VGroup({
      Spacing = 6,

      -- Header
      ui:Label({
        Text      = "CaptionPro",
        Alignment = { AlignHCenter = true },
        Font      = ui:Font({ PixelSize = 20, Bold = true }),
      }),
      ui:Label({
        Text      = "Subtitles  ->  Animated Fusion Text+",
        Alignment = { AlignHCenter = true },
      }),
      ui:Label({
        Text      = "Alpha v" .. VERSION ..
                    "  -  May contain bugs. Please report issues.",
        Alignment = { AlignHCenter = true },
        WordWrap  = true,
      }),
      ui:Label({ Text = "" }),

      -- Timeline settings
      ui:Label({
        Text = "TIMELINE SETTINGS",
        Font = ui:Font({ Bold = true }),
      }),
      ui:HGroup({ Spacing = 8,
        ui:Label({ Text = "Subtitle Track:", Weight = 0 }),
        ui:SpinBox({ ID = "SubTrackSpin", Minimum = 1, Maximum = 16, Value = 1, Weight = 0 }),
        ui:Label({ Text = "  Target Video Track:", Weight = 0 }),
        ui:SpinBox({ ID = "VidTrackSpin", Minimum = 1, Maximum = 16, Value = 1, Weight = 0 }),
      }),
      ui:CheckBox({
        ID = "DeleteSubCheck", Text = "Delete subtitle track after conversion",
        Checked = false,
      }),
      ui:Label({ Text = "" }),

      -- Highlight detection
      ui:Label({
        Text = "HIGHLIGHT DETECTION",
        Font = ui:Font({ Bold = true }),
      }),
      ui:CheckBox({
        ID = "UseHighlightsCheck", Text = "Enable Highlight Detection",
        Checked = true,
      }),
      ui:HGroup({ Spacing = 6,
        ui:Label({ ID = "HiPctLabel", Text = "Highlight top", Weight = 0 }),
        ui:SpinBox({ ID = "HiPctSpin", Minimum = 5, Maximum = 60, Value = 30, Weight = 0 }),
        ui:Label({ ID = "HiPctUnit", Text = "% of lines  (by importance score)" }),
      }),
      ui:TextEdit({
        ID          = "HiDescLabel",
        ReadOnly    = true,
        Text        = "Scores lines with TF-IDF and heuristics (all-caps, exclamations, short punchy phrases). No internet required.",
        MinimumSize = {300, 46},
        MaximumSize = {9999, 46},
      }),
      ui:Label({ Text = "" }),

      -- Macros
      ui:Label({
        Text = "ANIMATION MACROS",
        Font = ui:Font({ Bold = true }),
      }),
      ui:CheckBox({
        ID = "UseMacrosCheck", Text = "Apply Animation Macros  (.setting files)",
        Checked = true,
      }),
      ui:Label({ ID = "PrimaryLabel", Text = "Highlight macro  (flagged lines):" }),
      ui:HGroup({ Spacing = 4,
        ui:LineEdit({ ID = "PrimaryMacroPath", PlaceholderText = "Leave blank for plain text" }),
        ui:Button({ ID = "BrowsePrimary", Text = "Browse", Weight = 0 }),
      }),
      ui:Label({ ID = "SecondaryLabel", Text = "Normal macro  (remaining lines):" }),
      ui:HGroup({ Spacing = 4,
        ui:LineEdit({ ID = "SecondaryMacroPath", PlaceholderText = "Leave blank for plain text" }),
        ui:Button({ ID = "BrowseSecondary", Text = "Browse", Weight = 0 }),
      }),
      ui:TextEdit({
        ID          = "MacroDescLabel",
        ReadOnly    = true,
        Text        = "Highlight macro -> flagged lines.  Normal macro -> everything else.  Leave blank for plain unstyled text.",
        MinimumSize = {300, 46},
        MaximumSize = {9999, 46},
      }),
      ui:Label({ Text = "" }),

      -- Convert button
      ui:Button({
        ID   = "RunBtn",
        Text = "Convert Subtitles  ->  Animated Text+",
        Font = ui:Font({ PixelSize = 13, Bold = true }),
      }),
      ui:Label({ Text = "" }),

      -- Progress
      ui:Slider({
        ID = "ProgressBar", Minimum = 0, Maximum = 100, Value = 0, Enabled = false,
      }),
      ui:Label({
        ID = "StepLabel", Text = "Ready to convert.",
        Alignment = { AlignHCenter = true }, WordWrap = true,
      }),

      -- Error area
      ui:Label({ ID = "ErrorTitleLabel",   Text = "", WordWrap = true }),
      ui:TextEdit({
        ID = "ErrorText", ReadOnly = true, Text = "",
        Visible = false,
      }),
      ui:Label({ ID = "ErrorContactLabel", Text = "", WordWrap = true }),
      ui:Label({ Text = "" }),

      -- Footer
      ui:Label({
        Text      = "Created by " .. CREATOR .. "  -  v" .. VERSION,
        Alignment = { AlignHCenter = true },
      }),

    }),
  })

  -- Geometry must be set after creation, not inside AddWindow descriptor
  win:Move(100, 80)
  win:Resize(520, 800)

  -- ── Helpers ──────────────────────────────────────────────────────────────

  local highlight_controls = { "HiPctSpin", "HiPctLabel", "HiPctUnit", "HiDescLabel" }
  local macro_controls     = {
    "PrimaryMacroPath", "BrowsePrimary",
    "SecondaryMacroPath", "BrowseSecondary",
    "PrimaryLabel", "SecondaryLabel", "MacroDescLabel",
  }
  local all_inputs = {
    "SubTrackSpin", "VidTrackSpin", "DeleteSubCheck",
    "UseHighlightsCheck", "HiPctSpin",
    "UseMacrosCheck", "PrimaryMacroPath", "BrowsePrimary",
    "SecondaryMacroPath", "BrowseSecondary",
    "RunBtn",
  }

  local function set_enabled(ids, state)
    for _, id in ipairs(ids) do
      local w = win:Find(id)
      if w then w.Enabled = state end
    end
  end

  local function clear_error()
    win:Find("ErrorTitleLabel").Text   = ""
    win:Find("ErrorText").Text         = ""
    win:Find("ErrorText").Visible      = false
    win:Find("ErrorContactLabel").Text = ""
    win:Find("StepLabel").Text         = "Ready to convert."
  end

  local function show_error(msg, log_path)
    win:Find("ErrorTitleLabel").Text   = "An error occurred:"
    win:Find("ErrorText").Text         = tostring(msg)
    win:Find("ErrorText").Visible      = true
    win:Find("ErrorContactLabel").Text =
      "Please send the log file to the developer:\n" ..
      "  Log: " .. (log_path or get_log_path()) .. "\n" ..
      "  Contact: " .. CONTACT_EMAIL
    win:Find("StepLabel").Text = "Conversion failed - see error above."
  end

  local function update_progress(pct, label)
    win:Find("ProgressBar").Value = math.max(0, math.min(100, math.floor(pct)))
    win:Find("StepLabel").Text    = tostring(label)
  end

  clear_error()

  -- ── Events ───────────────────────────────────────────────────────────────

  win.On.UseHighlightsCheck.Clicked = function()
    set_enabled(highlight_controls, win:Find("UseHighlightsCheck").Checked)
  end

  win.On.UseMacrosCheck.Clicked = function()
    set_enabled(macro_controls, win:Find("UseMacrosCheck").Checked)
  end

  win.On.BrowsePrimary.Clicked = function()
    local path = fu:RequestFile("", "")
    if path and path ~= "" then win:Find("PrimaryMacroPath").Text = path end
  end

  win.On.BrowseSecondary.Clicked = function()
    local path = fu:RequestFile("", "")
    if path and path ~= "" then win:Find("SecondaryMacroPath").Text = path end
  end

  win.On.RunBtn.Clicked = function()
    clear_error()
    set_enabled(all_inputs, false)
    update_progress(0, "Starting...")

    local pm = resolve:GetProjectManager()
    if not pm then
      show_error("Could not access Resolve Project Manager.", nil)
      set_enabled(all_inputs, true)
      return
    end
    local project = pm:GetCurrentProject()
    if not project then
      show_error("No project is currently open.", nil)
      set_enabled(all_inputs, true)
      return
    end
    local timeline = project:GetCurrentTimeline()
    if not timeline then
      show_error("No timeline is active. Open a timeline and try again.", nil)
      set_enabled(all_inputs, true)
      return
    end

    local function nonempty(s)
      local v = s and s:match("^%s*(.-)%s*$")
      return (v and #v > 0) and v or nil
    end

    local config = {
      subtitle_track_index  = win:Find("SubTrackSpin").Value,
      target_video_track    = win:Find("VidTrackSpin").Value,
      macro_path_primary    = nonempty(win:Find("PrimaryMacroPath").Text),
      macro_path_secondary  = nonempty(win:Find("SecondaryMacroPath").Text),
      use_macros            = win:Find("UseMacrosCheck").Checked,
      use_highlights        = win:Find("UseHighlightsCheck").Checked,
      highlight_fraction    = win:Find("HiPctSpin").Value / 100.0,
      delete_subtitle_track = win:Find("DeleteSubCheck").Checked,
    }

    local run_ok, run_err = pcall(workflow.run, config, update_progress)
    if not run_ok then
      local log_path = write_error_log(tostring(run_err))
      show_error(tostring(run_err), log_path)
    end

    set_enabled(all_inputs, true)
    set_enabled(highlight_controls, win:Find("UseHighlightsCheck").Checked)
    set_enabled(macro_controls,     win:Find("UseMacrosCheck").Checked)
  end

  win.On.CaptionProWin.Close = function() disp:ExitLoop() end

  win:Show()
  disp:RunLoop()
  win:Hide()
end

return M
