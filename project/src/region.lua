--[[
region.lua — 지역 조회 / 인접 판정 / 클릭 판정 (순수 Lua, love 비의존)

  이 모듈의 책임:
    - 지역 목록(game_data.regions)을 받아 id 조회, 인접 여부, 인접쌍 목록,
      좌표 클릭(점-원 포함) 판정을 제공한다.
  관계:
    - 데이터는 game_data.lua 가 소유한다. 이 모듈은 그 데이터를 "주입받아" 쓴다.
    - 표현 계층(main.lua)이 인접선 렌더(connections)와 노드 클릭(hitTest)에 쓴다.
    - love.* 비의존 → project/tests/ 에서 순수 단위 테스트 가능.

  주의: 내부 캐시를 두지 않고 매번 regions 인자를 받는 무상태 함수로 둔다.
        (데이터 소유는 game_data, 규칙 변형은 추후 game_state 책임 — 계층 분리)
--]]

local Region = {}

--- id 로 지역을 찾는다.
-- @param regions table  지역 레코드 배열
-- @param id string      찾을 지역 id
-- @return table|nil     일치 지역, 없으면 nil
function Region.byId(regions, id)
  for _, r in ipairs(regions) do
    if r.id == id then
      return r
    end
  end
  return nil
end

--- 두 지역이 인접한지 판정한다.
-- A 의 neighbors 목록에 B 가 있으면 인접으로 본다.
-- (데이터는 양방향 일관을 가정하지만, 한쪽만 확인해도 충분.)
-- @param regions table
-- @param idA string
-- @param idB string
-- @return boolean
function Region.areAdjacent(regions, idA, idB)
  local a = Region.byId(regions, idA)
  if not a or not a.neighbors then
    return false
  end
  for _, nid in ipairs(a.neighbors) do
    if nid == idB then
      return true
    end
  end
  return false
end

--- 중복 없는 인접쌍 목록을 만든다 (인접선을 한 변당 1회만 그리기 위함).
-- A-B 와 B-A 는 같은 변이므로, 양 끝 좌표를 한 번만 담는다.
-- @param regions table
-- @return table  { {x1,y1,x2,y2}, ... }  각 원소가 한 인접선
function Region.connections(regions)
  local seen = {}   -- "idA|idB" (정렬된 쌍) 중복 방지 집합
  local lines = {}

  for _, r in ipairs(regions) do
    if r.neighbors then
      for _, nid in ipairs(r.neighbors) do
        local other = Region.byId(regions, nid)
        if other then
          -- id 두 개를 사전순 정렬해 키로 → A|B 와 B|A 가 같은 키
          local key
          if r.id < nid then
            key = r.id .. "|" .. nid
          else
            key = nid .. "|" .. r.id
          end
          if not seen[key] then
            seen[key] = true
            lines[#lines + 1] = { r.x, r.y, other.x, other.y }
          end
        end
      end
    end
  end
  return lines
end

--- 월드 좌표(wx,wy)가 어떤 지역 노드(원) 안에 있는지 판정한다.
-- 점-원 포함 판정: 중심까지 거리 제곱이 반경 제곱 이하이면 안쪽.
-- (sqrt 안 쓰고 제곱끼리 비교 — 더 싸고 정확.)
-- 노드가 겹칠 경우 배열 뒤쪽(나중에 그린, 위에 보이는) 지역을 우선한다.
-- @param regions table
-- @param wx number  월드 X (클릭 지점)
-- @param wy number  월드 Y
-- @param radius number  노드 반경 (config.map.nodeRadius)
-- @return table|nil  맞은 지역, 없으면 nil
function Region.hitTest(regions, wx, wy, radius)
  local r2 = radius * radius
  local hit = nil
  for _, reg in ipairs(regions) do
    local dx = wx - reg.x
    local dy = wy - reg.y
    if dx * dx + dy * dy <= r2 then
      hit = reg -- 마지막으로 맞은 것이 최종 → 위에 그려진 노드 우선
    end
  end
  return hit
end

return Region
