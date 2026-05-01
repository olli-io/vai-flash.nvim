---@class Flash.Labeler
---@field state Flash.State
---@field used table<string, string>
---@field labels string[]
local M = {}
M.__index = M

function M.new(state)
  local self
  self = setmetatable({}, M)
  self.state = state
  self.used = {}
  self:reset()
  return self
end

function M:labeler()
  return function()
    return self:update()
  end
end

function M:update()
  self:reset()

  if #self.state.pattern() < self.state.opts.label.min_pattern_length then
    return
  end

  local matches = self:filter()

  for _, match in ipairs(matches) do
    self:label(match, true)
  end

  for _, match in ipairs(matches) do
    if not self:label(match) then
      break
    end
  end
end

function M:reset()
  local skip = {} ---@type table<string, boolean>
  self.labels = {}

  for _, l in ipairs(self.state:labels()) do
    if not skip[l] then
      self.labels[#self.labels + 1] = l
      skip[l] = true
    end
  end
  for _, m in ipairs(self.state.results) do
    if m.label ~= false then
      m.label = nil
    end
  end
end

function M:valid(label)
  return vim.tbl_contains(self.labels, label)
end

function M:use(label)
  self.labels = vim.tbl_filter(function(c)
    return c ~= label
  end, self.labels)
end

---@param m Flash.Match
---@param used boolean?
function M:label(m, used)
  if m.label ~= nil then
    return true
  end
  local pos = m.pos:id(m.win)
  local label ---@type string?
  if used then
    label = self.used[pos]
  else
    label = self.labels[1]
  end
  if label and self:valid(label) then
    self:use(label)
    local reuse = self.state.opts.label.reuse == "all"
      or (self.state.opts.label.reuse == "lowercase" and label:lower() == label)

    if reuse then
      self.used[pos] = label
    end
    m.label = label
  end
  return #self.labels > 0
end

function M:filter()
  ---@type Flash.Match[]
  local ret = {}

  local target = self.state.target

  local from = vim.api.nvim_win_get_cursor(self.state.win)
  ---@type table<number, boolean>
  local folds = {}

  -- only label visible matches
  for _, match in ipairs(self.state.results) do
    -- and don't label the first match in the current window
    local skip = (target and match.pos == target.pos)
      and not self.state.opts.label.current
      and match.win == self.state.win

    -- Only label the first match in each fold
    if not skip and match.fold then
      if folds[match.fold] then
        skip = true
      else
        folds[match.fold] = true
      end
    end

    if not skip then
      table.insert(ret, match)
    end
  end

  -- Collapse runs of identical single-character matches. For repeating char
  -- patterns like `------`, `=====`, `((`, `{{`, only the leftmost match in
  -- each run is labeled — labeling every char produces visually indistinct
  -- back-to-back labels with no buffer chars in between. Multi-char matches
  -- (e.g. `foofoo` searching `foo`) are left for the visual-overlap filter
  -- below.
  do
    local by_line = {} ---@type table<string, Flash.Match[]>
    for _, m in ipairs(ret) do
      local key = m.win .. ":" .. m.pos[1]
      by_line[key] = by_line[key] or {}
      table.insert(by_line[key], m)
    end
    local drop = {} ---@type table<table, boolean>
    for _, line_matches in pairs(by_line) do
      if #line_matches > 1 then
        table.sort(line_matches, function(a, b)
          return a.pos[2] < b.pos[2]
        end)
        local first = line_matches[1]
        local buf = vim.api.nvim_win_get_buf(first.win)
        local line_text = (vim.api.nvim_buf_get_lines(buf, first.pos[1] - 1, first.pos[1], false) or {})[1] or ""
        for i = 2, #line_matches do
          local prev = line_matches[i - 1]
          local cur = line_matches[i]
          local prev_one = prev.end_pos[2] == prev.pos[2]
          local cur_one = cur.end_pos[2] == cur.pos[2]
          if
            prev_one
            and cur_one
            and cur.pos[2] == prev.pos[2] + 1
            and line_text:sub(prev.pos[2] + 1, prev.pos[2] + 1) == line_text:sub(cur.pos[2] + 1, cur.pos[2] + 1)
          then
            drop[cur] = true
          end
        end
      end
    end
    if next(drop) then
      ret = vim.tbl_filter(function(m)
        return not drop[m]
      end, ret)
    end
  end

  -- sort by current win, other win, then by distance
  table.sort(ret, function(a, b)
    local use_distance = self.state.opts.label.distance and a.win == self.state.win

    if a.win ~= b.win then
      local aw = a.win == self.state.win and 0 or a.win
      local bw = b.win == self.state.win and 0 or b.win
      return aw < bw
    end
    if use_distance then
      local dfrom = from[1] * vim.go.columns + from[2]
      local da = a.pos[1] * vim.go.columns + a.pos[2]
      local db = b.pos[1] * vim.go.columns + b.pos[2]
      return math.abs(dfrom - da) < math.abs(dfrom - db)
    end
    if a.pos[1] ~= b.pos[1] then
      return a.pos[1] < b.pos[1]
    end
    return a.pos[2] < b.pos[2]
  end)

  -- Two-character labels overlay the match starting at pos. A match's
  -- visual footprint is therefore [pos, max(end_pos, pos + label_width - 1)]:
  -- whichever extends further, the match text or the label overlay. Adjacent
  -- matches whose footprints overlap on the same line drop the further one
  -- (closer matches win via the distance sort above), so labels never collide
  -- with each other or with another match's text.
  local label_width = 2
  local accepted = {} ---@type table<string, {left:number,right:number}[]>
  ret = vim.tbl_filter(function(m)
    local key = m.win .. ":" .. m.pos[1]
    local m_left = m.pos[2]
    local m_right = math.max(m.end_pos[2], m.pos[2] + label_width - 1)
    local items = accepted[key]
    if items then
      for _, p in ipairs(items) do
        if m_left <= p.right and p.left <= m_right then
          return false
        end
      end
    end
    accepted[key] = accepted[key] or {}
    table.insert(accepted[key], { left = m_left, right = m_right })
    return true
  end, ret)

  return ret
end

return M
