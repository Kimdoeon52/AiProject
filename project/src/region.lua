--[[
region.lua — 지역 조회 / 헥스 인접 / 클릭 판정 (순수 Lua, love 비의존)

  이 모듈의 책임:
    - 지역 목록(game_data.regions)을 받아 id 조회, 헥스 인접 판정,
      클릭 픽셀이 속한 헥스(영토) 판정을 제공한다.
  관계:
    - 데이터는 game_data.lua 소유(각 지역 axial q,r). 이 모듈은 주입받아 쓴다.
    - hex.lua 로 좌표 변환·인접을 계산한다.
    - main.lua 가 cellAt 으로 클릭 영토를 고른다.
    - love.* 비의존 → project/tests/ 에서 순수 단위 테스트 가능.

  주의: 무상태 함수. 매번 regions 인자를 받는다. (데이터 소유는 game_data)
--]]

local Hex = require("hex")

local Region = {}

--- id 로 지역을 찾는다.
-- @param regions table  지역 레코드 배열
-- @param id string
-- @return table|nil
function Region.byId(regions, id)
  for _, r in ipairs(regions) do
    if r.id == id then
      return r
    end
  end
  return nil
end

--- 같은 axial(q,r) 의 지역을 찾는다. (헥스→지역 역조회)
-- @param regions table
-- @param q,r number
-- @return table|nil
local function atAxial(regions, q, r)
  for _, reg in ipairs(regions) do
    if reg.q == q and reg.r == r then
      return reg
    end
  end
  return nil
end

--- 지역의 인접 지역 목록 (헥스 6이웃 중 실재하는 것).
-- GDD 5장: 맞닿은 헥스 = 인접. 별도 neighbors 데이터 없이 좌표로 산출.
-- @param regions table
-- @param id string
-- @return table  인접 지역 배열(0~6개)
function Region.adjacent(regions, id)
  local self = Region.byId(regions, id)
  if not self then return {} end
  local out = {}
  for _, nb in ipairs(Hex.neighbors(self.q, self.r)) do
    local reg = atAxial(regions, nb[1], nb[2])
    if reg then out[#out + 1] = reg end
  end
  return out
end

--- 두 지역이 헥스 인접인지.
-- @param regions table
-- @param idA,idB string
-- @return boolean
function Region.areAdjacent(regions, idA, idB)
  local a = Region.byId(regions, idA)
  local b = Region.byId(regions, idB)
  if not a or not b then return false end
  for _, nb in ipairs(Hex.neighbors(a.q, a.r)) do
    if nb[1] == b.q and nb[2] == b.r then
      return true
    end
  end
  return false
end

--- 월드 픽셀(wx,wy)이 속한 영토(헥스)를 고른다.
-- 1) 픽셀 → 최근접 헥스 axial → 그 좌표의 지역.
-- 2) 빈 헥스(지역 없음)면 중심이 가장 가까운 지역으로 폴백.
-- @param regions table
-- @param wx,wy number  월드 좌표(클릭 지점)
-- @param size number   헥스 반경(config.map.hexSize)
-- @return table|nil
function Region.cellAt(regions, wx, wy, size)
  local q, r = Hex.pixelToAxial(wx, wy, size)
  local hit = atAxial(regions, q, r)
  if hit then return hit end

  -- 폴백: 헥스 중심까지 거리 최소 지역.
  local best, bestD = nil, nil
  for _, reg in ipairs(regions) do
    local cx, cy = Hex.axialToPixel(reg.q, reg.r, size)
    local dx, dy = wx - cx, wy - cy
    local d = dx * dx + dy * dy
    if not bestD or d < bestD then
      bestD = d
      best = reg
    end
  end
  return best
end

return Region
