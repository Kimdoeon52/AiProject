--[[
hex.lua — 육각형(헥스) 좌표 변환·인접 (순수 Lua, love 비의존)

  이 모듈의 책임:
    - axial 좌표(q,r)와 월드 픽셀 좌표를 서로 변환한다 (포인티탑 헥스).
    - 헥스 6 꼭짓점, 6 인접 방향을 제공한다.
    - 클릭 픽셀을 가장 가까운 헥스(q,r)로 반올림한다(cube 라운딩).
  관계:
    - main.lua : 헥스 중심·꼭짓점으로 채움/경계/이름을 그린다.
    - region.lua : pixelToAxial 로 클릭 영토를 판정한다.
    - love.* 비의존 → project/tests/ 에서 순수 단위 테스트 가능.

  좌표계 (pointy-top, axial q,r):
    - 헥스는 위/아래가 꼭짓점(뾰족), 좌우가 변. 가로 줄(row) 단위 벌집.
    - size = 헥스 중심에서 꼭짓점까지 거리.
    - 변환식:
        x = size * √3 * (q + r/2)
        y = size * 3/2 * r
    - 가로 이웃 간격 = √3*size, 세로 줄 간격 = 1.5*size.
--]]

local Hex = {}

local SQRT3 = math.sqrt(3)

-- 인접 6방향 (axial). 시계 방향 순회. region 인접 산출·이웃 탐색에 사용.
Hex.DIRS = {
  { 1, 0 }, { 1, -1 }, { 0, -1 }, { -1, 0 }, { -1, 1 }, { 0, 1 },
}

--- axial(q,r) → 월드 픽셀 중심 좌표.
-- @param q,r number  axial 좌표
-- @param size number 헥스 반경(중심→꼭짓점)
-- @return number, number  픽셀 x, y
function Hex.axialToPixel(q, r, size)
  return size * SQRT3 * (q + r / 2), size * 1.5 * r
end

-- 분수 큐브 좌표를 가장 가까운 정수 헥스로 반올림.
-- 큐브 제약 x+y+z=0 을 유지하려고, 반올림 오차가 가장 큰 축을 보정한다.
local function cubeRound(x, y, z)
  local rx, ry, rz = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
  local dx, dy, dz = math.abs(rx - x), math.abs(ry - y), math.abs(rz - z)
  if dx > dy and dx > dz then
    rx = -ry - rz
  elseif dy > dz then
    ry = -rx - rz
  else
    rz = -rx - ry
  end
  return rx, rz -- axial q=rx, r=rz
end

--- 월드 픽셀 → 가장 가까운 axial(q,r). (클릭 판정용)
-- 픽셀을 분수 axial 로 역변환한 뒤 cube 라운딩.
-- @param px,py number  월드 픽셀
-- @param size number   헥스 반경
-- @return number, number  정수 q, r
function Hex.pixelToAxial(px, py, size)
  local q = (SQRT3 / 3 * px - 1 / 3 * py) / size
  local r = (2 / 3 * py) / size
  -- axial(q,r) → cube(x=q, z=r, y=-x-z)
  return cubeRound(q, -q - r, r)
end

--- 헥스 6 꼭짓점을 평면 배열로 반환 (love.graphics.polygon 용).
-- 포인티탑: 꼭짓점 각도 = 60°*i − 30° (위 꼭짓점부터).
-- @param cx,cy number  헥스 중심 픽셀
-- @param size number   반경
-- @return table  {x1,y1,...,x6,y6}
function Hex.corners(cx, cy, size)
  local pts = {}
  for i = 0, 5 do
    local ang = math.rad(60 * i - 30)
    pts[#pts + 1] = cx + size * math.cos(ang)
    pts[#pts + 1] = cy + size * math.sin(ang)
  end
  return pts
end

--- axial(q,r) 의 인접 6 헥스 좌표 목록.
-- @param q,r number
-- @return table  { {q,r}, ... } 6개
function Hex.neighbors(q, r)
  local out = {}
  for _, d in ipairs(Hex.DIRS) do
    out[#out + 1] = { q + d[1], r + d[2] }
  end
  return out
end

--- axial 좌표를 맵 키 문자열로. (역맵 조회용)
-- @param q,r number
-- @return string  "q,r"
function Hex.key(q, r)
  return q .. "," .. r
end

return Hex
