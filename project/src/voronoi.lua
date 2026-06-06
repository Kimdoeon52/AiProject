--[[
voronoi.lua — 시드 좌표를 보로노이 셀(영토 폴리곤)로 분할 (순수 Lua, love 비의존)

  이 모듈의 책임:
    - 시드 점 집합과 경계 사각형(bbox)을 받아, 각 시드의 보로노이 셀을 만든다.
    - 셀 = "그 시드가 다른 어떤 시드보다 가까운 점들의 영역" → 볼록 다각형.
    - 인접 영토끼리는 경계(수직이등분선)를 공유한다 → 경계선이 곧 인접 표현.
  관계:
    - main.lua 가 load 때 1회 호출해 영토 폴리곤을 캐시하고 채움/경계로 그린다.
    - love.* 비의존 → project/tests/ 에서 순수 단위 테스트 가능.

  알고리즘 (반평면 클리핑 / Sutherland-Hodgman):
    - 시드 S_i 의 셀 = 모든 j≠i 에 대해
        { p : dist(p,S_i) <= dist(p,S_j) }  (S_i,S_j 의 수직이등분선이 경계)
      들의 교집합.
    - bbox 사각형에서 출발해, 다른 시드마다 그 반평면으로 다각형을 잘라 나간다.
    - 보로노이 셀은 항상 볼록이라 love.graphics.polygon("fill", ...) 로 바로 채울 수 있다.

  복잡도: O(n^2 * 평균정점수). n=40 규모에선 무시할 수준이고 load 때 1회만.
--]]

local Voronoi = {}

-- 점이 반평면 안쪽인지: f(p) = (p - M)·n <= 0 이면 S_i 쪽(안쪽).
--   n = S_j - S_i (i→j 방향 법선), M = 두 시드 중점.
--   중점 M 에서 f=0, j 쪽으로 갈수록 f>0 → i 쪽은 f<=0.
local function inside(px, py, mx, my, nx, ny)
  return (px - mx) * nx + (py - my) * ny <= 0
end

-- 선분 A→B 와 경계직선(중점 M, 법선 n)의 교점.
-- fa, fb 는 A,B 의 부호값. t = fa/(fa-fb) 위치에서 교차.
local function intersect(ax, ay, bx, by, mx, my, nx, ny)
  local fa = (ax - mx) * nx + (ay - my) * ny
  local fb = (bx - mx) * nx + (by - my) * ny
  local t = fa / (fa - fb)
  return ax + t * (bx - ax), ay + t * (by - ay)
end

--- 볼록 다각형 poly 를 한 반평면으로 자른다 (Sutherland-Hodgman).
-- @param poly table  {x1,y1,x2,y2,...} 평면 정점 배열(닫힌 다각형)
-- @param mx,my number 경계 중점
-- @param nx,ny number 경계 법선(i→j)
-- @return table  잘린 다각형 정점 배열(빈 배열일 수 있음)
local function clip(poly, mx, my, nx, ny)
  local out = {}
  local n = #poly / 2
  for i = 1, n do
    local ax, ay = poly[2 * i - 1], poly[2 * i]
    local k = (i % n) + 1 -- 다음 정점(마지막은 처음으로 순환)
    local bx, by = poly[2 * k - 1], poly[2 * k]

    local ain = inside(ax, ay, mx, my, nx, ny)
    local bin = inside(bx, by, mx, my, nx, ny)

    if ain then
      out[#out + 1] = ax; out[#out + 1] = ay -- A 가 안쪽이면 유지
    end
    if ain ~= bin then
      -- 경계를 가로지르면 교점 추가
      local ix, iy = intersect(ax, ay, bx, by, mx, my, nx, ny)
      out[#out + 1] = ix; out[#out + 1] = iy
    end
  end
  return out
end

--- 모든 시드의 보로노이 셀을 만든다.
-- @param seeds table  { {x=,y=,...}, ... } 시드 레코드 배열(지역과 동일 구조 가능)
-- @param bbox table   { x0, y0, x1, y1 } 클립 경계 사각형
-- @return table  배열. cells[i] = { x1,y1,x2,y2,... } (seeds[i] 의 영토 폴리곤)
function Voronoi.computeCells(seeds, bbox)
  local cells = {}
  for i, si in ipairs(seeds) do
    -- bbox 사각형(시계 반대 방향)에서 시작
    local poly = {
      bbox.x0, bbox.y0,
      bbox.x1, bbox.y0,
      bbox.x1, bbox.y1,
      bbox.x0, bbox.y1,
    }
    -- 다른 모든 시드의 반평면으로 차례로 자른다
    for j, sj in ipairs(seeds) do
      if i ~= j then
        local mx, my = (si.x + sj.x) / 2, (si.y + sj.y) / 2 -- 중점
        local nx, ny = sj.x - si.x, sj.y - si.y             -- i→j 법선
        poly = clip(poly, mx, my, nx, ny)
        if #poly == 0 then break end -- 더 자를 게 없으면 중단(이론상 거의 없음)
      end
    end
    cells[i] = poly
  end
  return cells
end

--- 시드 좌표들을 감싸는 bbox 를 여백 margin 만큼 키워 만든다.
-- @param seeds table
-- @param margin number  외곽 여백(월드 px)
-- @return table  { x0, y0, x1, y1 }
function Voronoi.boundsOf(seeds, margin)
  local x0, y0 = math.huge, math.huge
  local x1, y1 = -math.huge, -math.huge
  for _, s in ipairs(seeds) do
    if s.x < x0 then x0 = s.x end
    if s.y < y0 then y0 = s.y end
    if s.x > x1 then x1 = s.x end
    if s.y > y1 then y1 = s.y end
  end
  return { x0 = x0 - margin, y0 = y0 - margin, x1 = x1 + margin, y1 = y1 + margin }
end

return Voronoi
