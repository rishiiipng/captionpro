--[[
  subtitle_reader.lua
  Reads subtitle clips from the current timeline's subtitle track.
  Returns a plain Lua array of clip-tables — no Resolve objects escape.
]]

local M = {}

--- Fetch all non-empty subtitle clips from `track_index` (1-based).
-- Returns an array of { text, start_frame, end_frame, track_index }.
-- Raises a string error on failure.
function M.fetch_subtitles(timeline, track_index)
  track_index = track_index or 1

  local n = timeline:GetTrackCount("subtitle")
  if n == 0 then
    error("The current timeline has no subtitle tracks.")
  end
  if track_index > n then
    error(string.format(
      "Subtitle track %d does not exist (timeline has %d subtitle track(s)).",
      track_index, n))
  end

  local raw = timeline:GetItemListInTrack("subtitle", track_index)
  if not raw then return {} end

  local result = {}
  for _, clip in ipairs(raw) do
    local text = clip:GetName()
    -- Skip gap / spacer clips that Resolve inserts between real subtitles
    if text and text:match("%S") then
      local s = clip:GetStart()
      local e = clip:GetEnd()
      if e > s then
        table.insert(result, {
          text        = text,
          start_frame = s,
          end_frame   = e,
          track_index = track_index,
        })
      end
    end
  end

  return result
end

return M
