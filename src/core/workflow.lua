--[[
  workflow.lua
  Orchestrates the full subtitle → animated Text+ pipeline.
]]

local subtitle_reader    = require("resolve.subtitle_reader")
local highlight_analyzer = require("core.highlight_analyzer")
local fusion_builder     = require("resolve.fusion_builder")

local M = {}

--- Run the full conversion pipeline.
-- @param config  table:
--   subtitle_track_index  integer (default 1)
--   target_video_track    integer (default 1)
--   macro_path_primary    string or nil
--   macro_path_secondary  string or nil
--   use_macros            bool
--   use_highlights        bool
--   delete_subtitle_track bool
-- @param progress_cb  optional function(percent 0-100, label)
-- @return result table  { status, count, highlighted }
function M.run(config, progress_cb)
  local function prog(pct, msg)
    if progress_cb then progress_cb(pct, msg) end
  end

  fusion_builder.clear_log()

  -- Resolve globals are available directly (injected by Resolve)
  local pm       = resolve:GetProjectManager()
  local project  = pm:GetCurrentProject()
  if not project then error("No project is currently open.") end

  local timeline = project:GetCurrentTimeline()
  if not timeline then error("No timeline is currently active.") end

  -- ── Step 1: fetch subtitles ─────────────────────────────────────────────
  prog(0, "Fetching subtitles…")
  local subtitles = subtitle_reader.fetch_subtitles(
      timeline, config.subtitle_track_index or 1)
  prog(15, string.format("Found %d subtitle clip(s).", #subtitles))

  if #subtitles == 0 then
    prog(100, "Nothing to do — no subtitle clips found.")
    return { status = "nothing_to_do", count = 0, highlighted = 0 }
  end

  -- ── Step 2: highlight analysis ──────────────────────────────────────────
  local highlight_indices = {}
  if config.use_highlights then
    local ap = function(frac, label)
      prog(15 + math.floor(frac * 40), label)
    end
    local frac = config.highlight_fraction or 0.30
    highlight_indices = highlight_analyzer.analyze_highlights(subtitles, frac, ap)
    prog(55, string.format("Highlights: %d of %d lines flagged.",
        #highlight_indices, #subtitles))
  else
    prog(55, "Highlight detection skipped.")
  end

  -- ── Step 3: build Fusion clips ──────────────────────────────────────────
  prog(60, string.format("Inserting %d Fusion clip(s)…", #subtitles))

  local macro_p = config.use_macros and config.macro_path_primary  or nil
  local macro_s = config.use_macros and config.macro_path_secondary or nil

  fusion_builder.subtitles_to_fusion_clips(
    timeline,
    subtitles,
    config.target_video_track or 1,
    {
      macro_path_primary   = macro_p,
      macro_path_secondary = macro_s,
      highlight_indices    = highlight_indices,
    }
  )

  prog(95, "All Fusion clips created.")

  -- ── Step 4: optional subtitle-track cleanup ─────────────────────────────
  if config.delete_subtitle_track then
    prog(95, "Deleting subtitle track…")
    local track_idx = config.subtitle_track_index or 1
    local clips = timeline:GetItemListInTrack("subtitle", track_idx)
    if clips and #clips > 0 then
      timeline:DeleteClips(clips)
    end
  end

  prog(100, string.format("Done. %d clip(s) converted, %d highlighted.",
      #subtitles, #highlight_indices))

  return { status = "ok", count = #subtitles, highlighted = #highlight_indices }
end

return M
