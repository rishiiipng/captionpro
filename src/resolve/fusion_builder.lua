--[[
  fusion_builder.lua
  Creates Fusion Text+ composition clips on the timeline to match subtitles.

  Resolve 21 behaviour (confirmed via live probing):
    • InsertFusionCompositionIntoTimeline() uses INSERT/SPLICE mode.
      It cuts the clip at the playhead, inserts a fresh 120-frame comp,
      and pushes the right portion forward — creating "pushed remnant" clips.
    • resolve:OpenPage("edit") must be called once before the insert loop;
      repeated calls deselect the video track and cause nil returns.
    • SetProperty("End"/"Duration") returns false — clips cannot be resized.
    • comp:SetAttrs({COMPN_GlobalEnd = n}) limits text visibility inside the
      clip even though the clip's timeline duration stays at 120 frames.

  Insertion strategy — 3 phases:
    1. Insert all empty Fusion comps (no comp editing between inserts).
    2. Delete pushed remnants (clips starting at or after last_start + 120).
    3. Re-fetch surviving clips, match by start_frame, then set text & style.
]]

local M = {}

-- ── Logging ──────────────────────────────────────────────────────────────────

local _log_dir  = (os.getenv("USERPROFILE") or ".") .. "/CaptionPro Logs"
local _log_path = _log_dir .. "/build.log"
os.execute('cmd /c if not exist "' .. _log_dir:gsub("/", "\\") .. '" mkdir "' .. _log_dir:gsub("/", "\\") .. '"')

local function log(msg)
  local f = io.open(_log_path, "a")
  if f then
    f:write(os.date("[%H:%M:%S] ") .. tostring(msg) .. "\n")
    f:close()
  end
end

function M.clear_log()
  local f = io.open(_log_path, "w")
  if f then
    f:write("=== CaptionPro Lua run " .. os.date() .. " ===\n")
    f:close()
  end
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function frame_to_tc(frame, fps)
  local f  = math.floor(fps)
  local ff = frame % f
  local ss = math.floor(frame / f) % 60
  local mm = math.floor(frame / (f * 60)) % 60
  local hh = math.floor(frame / (f * 3600))
  return string.format("%02d:%02d:%02d:%02d", hh, mm, ss, ff)
end

local function wire_to_media_out(comp, tool)
  local media_out = comp:FindTool("MediaOut1")
  if not media_out then
    -- GetToolList type-filter is unreliable in Resolve 21; scan manually
    local all = comp:GetToolList(false) or {}
    for _, t in pairs(all) do
      local name = (t:GetAttrs() or {})["TOOLS_Name"] or ""
      if name:match("^MediaOut") or name:match("^Output") then
        media_out = t; break
      end
    end
  end
  if media_out then
    media_out:ConnectInput("Input", tool)
  else
    log("ERROR: MediaOut not found in comp — text node not connected")
  end
end

-- ── Text-node creation ────────────────────────────────────────────────────────

local function add_bare_text_node(comp, text)
  comp:Lock()
  local ok, err = pcall(function()
    local t = comp:AddTool("TextPlus")
    t:SetInput("StyledText", text)
    wire_to_media_out(comp, t)
  end)
  comp:Unlock()
  if not ok then error("add_bare_text_node: " .. tostring(err)) end
end

-- Parse a .setting file into a plain Lua table using a stub environment.
-- bmd.readfile() wraps the result in ordered()/typed tables that are hard to
-- iterate safely; io.open + loadstring with shim constructors gives clean tables.
local function parse_setting(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local src = f:read("*all")
  f:close()

  -- pass(t) returns t if it's a table, otherwise returns a function that does.
  -- This lets us stub ordered(), Input{}, TextPlus{}, etc. uniformly.
  local pass = function(t)
    if type(t) == "table" then return t end
    return function(u) return type(u) == "table" and u or {} end
  end
  local env = setmetatable(
    { ordered = function() return pass end, Input = pass },
    { __index = function(_, _) return pass end }
  )

  local chunk = loadstring and loadstring("return " .. src)
  if not chunk then return nil end
  if setfenv then setfenv(chunk, env) end
  local ok, result = pcall(chunk)
  return (ok and type(result) == "table") and result or nil
end

-- Extract TextPlus style inputs from a parsed setting table.
local function extract_style(parsed)
  if not (parsed and parsed.Tools) then return {} end
  local style = {}
  for _, td in pairs(parsed.Tools) do
    if type(td) == "table" and td.Inputs then
      for k, v in pairs(td.Inputs) do
        if type(v) == "table" and k ~= "StyledText" and v.Value ~= nil then
          style[k] = v.Value
        end
      end
      break
    end
  end
  return style
end

--- Apply a .setting macro to a Fusion composition, then set the subtitle text.
local function apply_macro(comp, macro_path, text)
  local parsed = parse_setting(macro_path)
  local style  = extract_style(parsed)

  comp:Lock()
  local ok, err = pcall(function()
    local done = false

    local bmd_data = bmd.readfile(macro_path)
    if bmd_data then
      comp:Paste(bmd_data)
      local tool_name = (type(bmd_data) == "table" and bmd_data.ActiveTool)
                     or (parsed and parsed.Tools and next(parsed.Tools))
                     or "TextPlus1"
      local tp = comp:FindTool(tool_name)
      if not tp then
        local all = comp:GetToolList(false) or {}
        for _, t in pairs(all) do
          local n = (t:GetAttrs() or {})["TOOLS_Name"] or ""
          if not n:match("^MediaOut") and not n:match("^Output") then
            tp = t; break
          end
        end
      end
      if tp then
        tp:SetInput("StyledText", text)
        wire_to_media_out(comp, tp)
        done = true
      else
        log("WARN: paste succeeded but TextPlus not found — using fallback")
      end
    end

    if not done then
      local t = comp:AddTool("TextPlus")
      for k, v in pairs(style) do
        pcall(function() t:SetInput(k, v) end)
      end
      t:SetInput("StyledText", text)
      wire_to_media_out(comp, t)
    end
  end)
  comp:Unlock()
  if not ok then error("apply_macro: " .. tostring(err)) end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Convert subtitle clips to Fusion composition clips on the timeline.
-- @param timeline           Resolve timeline object
-- @param subtitles          array of { text, start_frame, end_frame }
-- @param target_video_track integer (1-based)
-- @param opts               table:
--   macro_path_primary    path for highlight lines  (nil = bare text)
--   macro_path_secondary  path for normal lines     (nil = bare text)
--   highlight_indices     array of 1-based indices that are highlights
function M.subtitles_to_fusion_clips(timeline, subtitles, target_video_track, opts)
  opts = opts or {}
  local macro_p  = opts.macro_path_primary
  local macro_s  = opts.macro_path_secondary
  local hi_list  = opts.highlight_indices or {}
  target_video_track = target_video_track or 1

  if #subtitles == 0 then return end

  local fps = tonumber(timeline:GetSetting("timelineFrameRate")) or 24

  -- Build O(1) highlight lookup
  local hi_set = {}
  for _, idx in ipairs(hi_list) do hi_set[idx] = true end

  -- ── Phase 1: insert all empty comps ────────────────────────────────────────
  -- One resolve:OpenPage("edit") before the loop; never inside it.
  if resolve then resolve:OpenPage("edit") end

  log(string.format("Phase 1: inserting %d clips  (video track %d)",
      #subtitles, target_video_track))

  for _, sub in ipairs(subtitles) do
    local tc = frame_to_tc(sub.start_frame, fps)
    timeline:SetCurrentTimecode(tc)
    local clip = timeline:InsertFusionCompositionIntoTimeline()
    if not clip then
      error(string.format(
        "InsertFusionCompositionIntoTimeline() returned nil at %s.\n"
        .. "Ensure a video track is selected (highlighted) in the Edit page "
        .. "and that it is not locked before running CaptionPro.",
        tc))
    end
  end

  -- ── Phase 2: delete pushed remnants ────────────────────────────────────────
  -- INSERT mode pushes old clip right-portions past last_start + 120 frames.
  -- Never use clip:GetEnd() for the threshold — the API sometimes returns the
  -- left portion of the cut clip, not the newly inserted one.
  local default_dur = math.floor(fps * 5 + 0.5)  -- 120 frames @ 24 fps
  local last_end    = subtitles[#subtitles].start_frame + default_dur

  local all_clips = timeline:GetItemListInTrack("video", target_video_track) or {}
  local remnants  = {}
  for _, c in ipairs(all_clips) do
    if c:GetStart() >= last_end then
      table.insert(remnants, c)
    end
  end
  log(string.format("Phase 2: removing %d pushed remnant(s)", #remnants))
  if #remnants > 0 then
    timeline:DeleteClips(remnants)
  end

  -- ── Phase 3: match survivors → assign text ─────────────────────────────────
  log(string.format("Phase 3: %d clips  highlights=%d  macro_p=%s  macro_s=%s",
      #subtitles, #hi_list,
      macro_p and macro_p:match("[^\\/]+$") or "none",
      macro_s and macro_s:match("[^\\/]+$") or "none"))
  local final_clips = timeline:GetItemListInTrack("video", target_video_track) or {}
  local by_start    = {}
  for _, c in ipairs(final_clips) do
    by_start[c:GetStart()] = c
  end

  for i, sub in ipairs(subtitles) do
    local clip = by_start[sub.start_frame]
    if not clip then
      -- Build available-frames list for the error message
      local avail = {}
      for k in pairs(by_start) do table.insert(avail, tostring(k)) end
      table.sort(avail)
      error(string.format(
        "No Fusion clip at frame %d (%s) after cleanup.\nAvailable: [%s]",
        sub.start_frame, frame_to_tc(sub.start_frame, fps),
        table.concat(avail, ", ")))
    end

    local comp = clip:GetFusionCompByIndex(1)
    if not comp then
      error(string.format("Clip at frame %d has no Fusion comp.", sub.start_frame))
    end

    local dur = sub.end_frame - sub.start_frame
    comp:SetAttrs({ COMPN_GlobalEnd = dur - 1, COMPN_RenderEnd = dur - 1 })

    local macro = hi_set[i] and macro_p or macro_s
    if macro and macro ~= "" then
      apply_macro(comp, macro, sub.text)
    else
      add_bare_text_node(comp, sub.text)
    end

    log(string.format("  [%d] frame=%-7d  %s  %s",
        i, sub.start_frame,
        hi_set[i] and "HI    " or "normal",
        sub.text:sub(1, 50)))
  end
end

return M
