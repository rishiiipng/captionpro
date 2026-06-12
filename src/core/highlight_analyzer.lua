--[[
  highlight_analyzer.lua
  Scores subtitle lines with TF-IDF + linguistic heuristics entirely on-machine.
  Returns 1-based indices of the top 30 % highest-scoring lines.
]]

local M = {}

-- ── Tokenisation ─────────────────────────────────────────────────────────────

local STOP_WORDS = {
  a=1, an=1, the=1, but=1, on=1, at=1, to=1,
  of=1, with=1, is=1, it=1, this=1, that=1, was=1, are=1,
  be=1, as=1, by=1, from=1, we=1, you=1, he=1, she=1, they=1,
  i=1, my=1, your=1, our=1, its=1, so=1, did=1, has=1, have=1,
  had=1, will=1, would=1, can=1, could=1, just=1, also=1, all=1,
  -- reserved keywords must use bracket syntax
  ["and"]=1, ["or"]=1, ["in"]=1, ["not"]=1, ["do"]=1, ["for"]=1,
}

local function tokenize(text)
  local tokens = {}
  for word in text:lower():gmatch("[%a]+") do
    if #word > 2 and not STOP_WORDS[word] then
      table.insert(tokens, word)
    end
  end
  return tokens
end

-- ── TF-IDF ───────────────────────────────────────────────────────────────────

local function compute_tf(tokens)
  local counts, max_c = {}, 0
  for _, w in ipairs(tokens) do
    counts[w] = (counts[w] or 0) + 1
    if counts[w] > max_c then max_c = counts[w] end
  end
  if max_c > 0 then
    for w in pairs(counts) do counts[w] = counts[w] / max_c end
  end
  return counts
end

local function tfidf_scores(subtitles)
  local N = #subtitles
  if N == 0 then return {} end

  local all_tf, df = {}, {}
  for i, sub in ipairs(subtitles) do
    local tokens = tokenize(sub.text)
    local tf     = compute_tf(tokens)
    all_tf[i]    = tf
    local seen   = {}
    for w in pairs(tf) do
      if not seen[w] then
        seen[w] = true
        df[w]   = (df[w] or 0) + 1
      end
    end
  end

  local scores = {}
  for i = 1, N do
    local score = 0
    for w, tf_val in pairs(all_tf[i]) do
      local idf = math.log((N + 1) / ((df[w] or 0) + 1))
      score = score + tf_val * idf
    end
    scores[i] = score
  end
  return scores
end

-- ── Heuristics ───────────────────────────────────────────────────────────────

local function heuristic_bonus(text)
  local bonus = 0

  -- All-caps words  (strong/emphatic)
  for word in text:gmatch("[%a]+") do
    if #word > 1 and word == word:upper() then
      bonus = bonus + 2
      break
    end
  end

  -- Exclamation → high emotion
  if text:find("!", 1, true) then bonus = bonus + 2 end

  -- Question → engagement hook
  if text:find("?", 1, true) then bonus = bonus + 1 end

  -- Very short line  (punchy statement)
  local words = 0
  for _ in text:gmatch("%S+") do words = words + 1 end
  if words <= 4 then bonus = bonus + 1.5 end

  -- Contains a number / statistic
  if text:find("%d") then bonus = bonus + 0.5 end

  -- Long line with many unique words → information-dense
  if words >= 8 then bonus = bonus + 0.5 end

  return bonus
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Analyse subtitle lines and return 1-based indices of highlighted ones.
-- @param subtitles    array of { text, start_frame, end_frame, … }
-- @param top_fraction fraction 0-1 of lines to highlight (default 0.30)
-- @param progress_cb  optional function(fraction 0-1, label)
-- @return  array of 1-based indices
function M.analyze_highlights(subtitles, top_fraction, progress_cb)
  local N = #subtitles
  if N == 0 then return {} end

  if progress_cb then progress_cb(0.1, "Computing TF-IDF scores…") end

  local tf_scores = tfidf_scores(subtitles)

  if progress_cb then progress_cb(0.6, "Applying heuristics…") end

  local final = {}
  for i = 1, N do
    final[i] = (tf_scores[i] or 0) + heuristic_bonus(subtitles[i].text)
  end

  local fraction = (type(top_fraction) == "number") and top_fraction or 0.30
  local top_n    = math.max(1, math.floor(N * fraction))

  if progress_cb then progress_cb(1.0, "Highlight analysis complete.") end

  -- Sort indices by score descending, return exactly top_n.
  -- Threshold comparison was discarded because ties at the boundary over-include.
  local order = {}
  for i = 1, N do order[i] = i end
  table.sort(order, function(a, b) return final[a] > final[b] end)

  local indices = {}
  for j = 1, top_n do
    table.insert(indices, order[j])
  end
  return indices
end

return M
