-- GFM pipe tables carry no column widths, so pandoc emits natural-width `l` columns that never
-- wrap and run hundreds of points off the page. Derive relative widths from the longest cell in
-- each column instead, square-rooted so one very long column does not crush the others.
local function len(cell) return #pandoc.utils.stringify(cell) end
function Table(tbl)
  local n = #tbl.colspecs
  if n == 0 then return tbl end
  local w = {}
  for i = 1, n do w[i] = 8 end
  local function scan(rows)
    for _, row in ipairs(rows) do
      for i, cell in ipairs(row.cells) do
        if i <= n then w[i] = math.max(w[i], len(cell)) end
      end
    end
  end
  scan(tbl.head.rows)
  for _, b in ipairs(tbl.bodies) do scan(b.body) end
  local tot = 0
  for i = 1, n do w[i] = math.sqrt(w[i]); tot = tot + w[i] end  -- damp extremes
  local cs = {}
  for i = 1, n do cs[i] = { tbl.colspecs[i][1], w[i] / tot } end
  tbl.colspecs = cs
  return tbl
end
