--[[
  fusion_builder.lua
  Creates animated text clips on the timeline to match subtitles.

  Resolve 21 behaviour (confirmed via live probing):
    • comp:Paste() silently adds NOTHING inside embedded timeline Fusion comps —
      direct table, clipboard, and unwrapped-group payloads all fail. Macros can
      therefore NOT be applied after inserting an empty Fusion composition.
    • The supported path is Timeline:InsertFusionTitleIntoTimeline(titleName),
      which inserts a clip with the full macro (animation, modifiers, effects)
      already inside. The macro .setting must live in Resolve's
      Fusion\Templates\Edit\Titles folder, scanned at application startup.
    • InsertFusion*IntoTimeline() uses INSERT/SPLICE mode: it cuts the clip at
      the playhead, inserts a fresh 120-frame clip, and pushes the right portion
      forward — creating "pushed remnant" clips.
    • resolve:OpenPage("edit") must be called once before the insert loop;
      repeated calls deselect the video track and cause nil returns.
    • comp:SetAttrs({COMPN_GlobalEnd = n}) limits text visibility inside the
      clip even though the clip's timeline duration stays at 120 frames.

  Insertion strategy — 3 phases:
    1. Insert all clips (Fusion Title when a macro is set, empty comp otherwise).
    2. Delete pushed remnants (clips starting at or after last_start + 120).
    3. Re-fetch surviving clips, match by start_frame, set text & duration.
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
    f:write("=== CaptionPro run " .. os.date() .. " ===\n")
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

-- ── Macro .setting parsing (for the styled-text fallback path) ────────────────

-- Parse a .setting file into a plain Lua table using a stub environment.
local function parse_setting(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local src = f:read("*all")
  f:close()

  -- Stub: a callable, self-indexing object so every constructor expression in
  -- the file resolves — ordered(){...}, Input{...}, FuID{...}, and dotted names
  -- like ofx.com.blackmagicdesign.resolvefx.EdgeDetect{...} (OFX plugin tools).
  -- A plain function stub breaks on the dotted form: indexing a function errors.
  local stub
  stub = setmetatable({}, {
    __index = function() return stub end,
    __call  = function(_, t) return type(t) == "table" and t or stub end,
  })
  local env = setmetatable({}, { __index = function() return stub end })

  local chunk = loadstring and loadstring("return " .. src)
  if not chunk then return nil end
  if setfenv then setfenv(chunk, env) end
  local ok, result = pcall(chunk)
  return (ok and type(result) == "table") and result or nil
end

-- Extract TextPlus style inputs from a parsed setting table.
-- Recurses into GroupOperator inner Tools so complex macros yield at least
-- Font/Size/Style for the styled-text fallback path. Only extracts from tools
-- that have a Font input (TextPlus signature); skips table-valued inputs
-- (Gradient, FuID, animated SourceOp refs) that can't be set via SetInput.
local function extract_style(parsed)
  if not (parsed and parsed.Tools) then return {} end
  local style = {}
  local function scan(tools)
    if type(tools) ~= "table" then return false end
    for _, td in pairs(tools) do
      if type(td) == "table" then
        if td.Inputs and td.Inputs.Font then
          for k, v in pairs(td.Inputs) do
            if type(v) == "table" and k ~= "StyledText"
               and v.Value ~= nil and type(v.Value) ~= "table" then
              style[k] = v.Value
            end
          end
          return true
        elseif td.Tools then
          if scan(td.Tools) then return true end
        end
      end
    end
    return false
  end
  scan(parsed.Tools)
  return style
end

-- ── Text helpers ──────────────────────────────────────────────────────────────

local function add_bare_text_node(comp, text, style)
  comp:Lock()
  local ok, err = pcall(function()
    local t = comp:AddTool("TextPlus")
    if style then
      for k, v in pairs(style) do
        pcall(function() t:SetInput(k, v) end)
      end
    end
    t:SetInput("StyledText", text)
    wire_to_media_out(comp, t)
  end)
  comp:Unlock()
  if not ok then error("add_bare_text_node: " .. tostring(err)) end
end

-- Set the subtitle text inside a title clip's comp.
--   1. StyledTextFollower.Text — animated macros; the Follower drives
--      TextPlus.StyledText, so setting it updates the per-character animation.
--   2. TextPlus.StyledText     — simple macros.
-- Returns how the text was set, or nil if no text tool was found.
local function set_text_on_comp(comp, text)
  local all = comp:GetToolList(false) or {}
  for _, t in pairs(all) do
    if (t:GetAttrs() or {})["TOOLS_RegID"] == "StyledTextFollower" then
      pcall(function() t:SetInput("Text", text) end)
      return "follower"
    end
  end
  for _, t in pairs(all) do
    if (t:GetAttrs() or {})["TOOLS_RegID"] == "TextPlus" then
      pcall(function() t:SetInput("StyledText", text) end)
      return "textplus"
    end
  end
  return nil
end

-- ── Title template installation ───────────────────────────────────────────────

local function titles_dir()
  local appdata = os.getenv("APPDATA")
  if not appdata then return nil end
  return appdata .. "\\Blackmagic Design\\DaVinci Resolve\\Support" ..
         "\\Fusion\\Templates\\Edit\\Titles"
end

--- Ensure a macro .setting is installed as a Fusion Title template.
-- Resolve scans the Titles folder at startup, so a freshly installed macro
-- needs a restart before InsertFusionTitleIntoTimeline can find it.
-- @return title_name, installed_now(bool), err
function M.ensure_title_installed(macro_path)
  local name = (macro_path:match("[^\\/]+$") or ""):gsub("%.setting$", "")
  if name == "" then return nil, false, "Invalid macro path: " .. tostring(macro_path) end

  local dir = titles_dir()
  if not dir then return nil, false, "APPDATA environment variable not set." end
  local dst = dir .. "\\" .. name .. ".setting"

  local sf = io.open(macro_path, "rb")
  if not sf then return nil, false, "Cannot read macro file: " .. macro_path end
  local src_data = sf:read("*all")
  sf:close()

  local df = io.open(dst, "rb")
  if df then
    local dst_data = df:read("*all")
    df:close()
    if dst_data == src_data then
      return name, false, nil  -- already installed, identical content
    end
  end

  os.execute('cmd /c if not exist "' .. dir .. '" mkdir "' .. dir .. '"')
  local of = io.open(dst, "wb")
  if not of then return nil, false, "Cannot write title template: " .. dst end
  of:write(src_data)
  of:close()
  log("installed title template: " .. dst)
  return name, true, nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Convert subtitle clips to animated text clips on the timeline.
-- @param timeline           Resolve timeline object
-- @param subtitles          array of { text, start_frame, end_frame }
-- @param target_video_track integer (1-based)
-- @param opts               table:
--   title_primary         Fusion Title name for highlight lines (nil = no macro)
--   title_secondary       Fusion Title name for normal lines    (nil = no macro)
--   macro_path_primary    original .setting path (style fallback if title fails)
--   macro_path_secondary  original .setting path (style fallback if title fails)
--   highlight_indices     array of 1-based indices that are highlights
function M.subtitles_to_fusion_clips(timeline, subtitles, target_video_track, opts)
  opts = opts or {}
  local title_p = opts.title_primary
  local title_s = opts.title_secondary
  local macro_p = opts.macro_path_primary
  local macro_s = opts.macro_path_secondary
  local hi_list = opts.highlight_indices or {}
  target_video_track = target_video_track or 1

  if #subtitles == 0 then return end

  local fps = tonumber(timeline:GetSetting("timelineFrameRate")) or 24

  -- Build O(1) highlight lookup
  local hi_set = {}
  for _, idx in ipairs(hi_list) do hi_set[idx] = true end

  -- ── Phase 1: insert all clips ───────────────────────────────────────────────
  -- One resolve:OpenPage("edit") before the loop; never inside it.
  if resolve then resolve:OpenPage("edit") end

  log(string.format("Phase 1: inserting %d clips  (video track %d)  title_p=%s  title_s=%s",
      #subtitles, target_video_track,
      tostring(title_p or "none"), tostring(title_s or "none")))

  local inserted_kind = {}   -- per index: "title" or "comp"
  local title_failed  = {}   -- title name -> true once insert failed

  for i, sub in ipairs(subtitles) do
    local tc = frame_to_tc(sub.start_frame, fps)
    timeline:SetCurrentTimecode(tc)

    local clip  = nil
    local title = hi_set[i] and title_p or title_s

    if title and not title_failed[title] then
      clip = timeline:InsertFusionTitleIntoTimeline(title)
      if not clip then
        title_failed[title] = true
        log("WARN: InsertFusionTitle('" .. title .. "') returned nil — " ..
            "falling back to styled Text+. If this macro was just installed, " ..
            "RESTART DaVinci Resolve to make the title available.")
      end
    end

    if clip then
      inserted_kind[i] = "title"
    else
      clip = timeline:InsertFusionCompositionIntoTimeline()
      if not clip then
        error(string.format(
          "InsertFusionCompositionIntoTimeline() returned nil at %s.\n"
          .. "Ensure a video track is selected (highlighted) in the Edit page "
          .. "and that it is not locked before running CaptionPro.",
          tc))
      end
      inserted_kind[i] = "comp"
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

  -- ── Phase 3: match survivors → set text & duration ─────────────────────────
  log(string.format("Phase 3: %d clips  highlights=%d", #subtitles, #hi_list))

  local final_clips = timeline:GetItemListInTrack("video", target_video_track) or {}
  local by_start    = {}
  for _, c in ipairs(final_clips) do
    by_start[c:GetStart()] = c
  end

  -- Lazy style extraction for the fallback path (one parse per macro file)
  local style_cache = {}
  local function style_for(path)
    if not path then return nil end
    if style_cache[path] == nil then
      style_cache[path] = extract_style(parse_setting(path)) or {}
    end
    return style_cache[path]
  end

  for i, sub in ipairs(subtitles) do
    local clip = by_start[sub.start_frame]
    if not clip then
      local avail = {}
      for k in pairs(by_start) do table.insert(avail, tostring(k)) end
      table.sort(avail)
      error(string.format(
        "No clip at frame %d (%s) after cleanup.\nAvailable: [%s]",
        sub.start_frame, frame_to_tc(sub.start_frame, fps),
        table.concat(avail, ", ")))
    end

    local comp = clip:GetFusionCompByIndex(1)
    if not comp then
      error(string.format("Clip at frame %d has no Fusion comp.", sub.start_frame))
    end

    local dur = sub.end_frame - sub.start_frame
    comp:SetAttrs({ COMPN_GlobalEnd = dur - 1, COMPN_RenderEnd = dur - 1 })

    local how
    if inserted_kind[i] == "title" then
      how = set_text_on_comp(comp, sub.text)
      if not how then
        -- Diagnostic dump: which tools does a title clip's comp actually contain?
        local names = {}
        for _, t in pairs(comp:GetToolList(false) or {}) do
          local a = t:GetAttrs() or {}
          table.insert(names, (a["TOOLS_Name"] or "?") .. "(" .. (a["TOOLS_RegID"] or "?") .. ")")
        end
        log("  WARN no text tool found in title comp; tools: " .. table.concat(names, "  "))
        how = "none"
      end
    else
      local mpath = hi_set[i] and macro_p or macro_s
      add_bare_text_node(comp, sub.text, style_for(mpath))
      how = mpath and "styled" or "bare"
    end

    log(string.format("  [%d] frame=%-7d  %s  %s  %s",
        i, sub.start_frame,
        hi_set[i] and "HI    " or "normal",
        how, sub.text:sub(1, 50)))
  end
end

return M
