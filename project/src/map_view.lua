--[[
map_view.lua — 지도(월드) 렌더링 (표현 계층) — GDD 5·6·12장

  이 모듈의 책임:
    - 헥스 지도의 "월드 좌표 그리기"만 담당한다: 지역 채움색·경계·플레이어 테두리·
      군주 후보 강조·선택 강조·지역 이름·진행 중 부대 명령 경로(점선 화살표).
    - 좌상단 세력 범례(화면 고정)도 그린다.
  관계:
    - main.lua : 카메라 변환(push/scale/translate) 안에서 MapView.drawWorld(state) 호출,
                 변환 밖에서 MapView.drawLegend(state) 호출. 입력·패널·팝업은 main 책임.
    - overlay.lua : 군주 선택 중 후보 세력 강조 대상(highlightFaction) 조회.
    - config / movement : 색·선 두께 등 상수, 명령 종류(이동/수송) 구분.
  설계:
    - draw 는 읽기만(상태 변경 X). state 를 인자로 받는 무상태 렌더러(main 의 state 를 그대로 읽음).
    - main.lua 가 800줄(CLAUDE.md)을 넘겨 "지도 렌더" 책임을 떼어낸 모듈(popup/dev_popup 분리와 같은 선례).

  state 의존 필드(주입, 읽기 전용):
    regions, corners, centers, scenario, ownership, playerFactionId, selectedId, orders
--]]

local config = require("config")
local Overlay = require("overlay")
local Movement = require("movement")

local MapView = {}

-- ── 시나리오 색 조회 ─────────────────────────────────────

--- 지역의 채움색을 현재 시나리오 소유 세력에서 가져온다. 소유 없음 → 중립 회색.
-- 소유 조회는 정규화된 런타임 맵(state.ownership) 기준 — 중립 강등이 색에 반영된다(GDD 6장).
-- @param state table
-- @param r table  지역 레코드
-- @return table  {r,g,b}
local function regionColor(state, r)
  local sc = state.scenario
  if sc and state.ownership then
    local fid = state.ownership[r.id]
    local f = fid and sc.factions[fid]
    if f then return f.color end
  end
  return config.colors.neutral
end

-- ── 부대 명령 경로(점선 화살표, GDD 12장) ────────────────

--- 두 점 사이를 점선 + 화살촉으로 그린다(부대 경로 표시). 월드 좌표.
-- 좌표 계산: 방향 단위벡터(ux,uy)로 dash/gap 만큼 끊어 선분을 찍고, 끝에 삼각 화살촉.
--   화살촉 자리를 남기려 선분은 끝에서 headLen 만큼 못 미쳐서 멈춘다.
-- @param x1,y1,x2,y2 number  출발→목적 월드 좌표(헥스 중심)
-- @param color table         점선 색({r,g,b})
local function drawDashedArrow(x1, y1, x2, y2, color)
  local dx, dy = x2 - x1, y2 - y1
  -- math.sqrt: 제곱근(C 의 sqrt). 두 점 거리 = 빗변 길이.
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end -- 같은 지역(거리 0) 방어
  local ux, uy = dx / len, dy / len -- 진행 방향 단위벡터
  local o = config.orders
  love.graphics.setColor(color)
  love.graphics.setLineWidth(o.lineWidth)

  -- 점선: 시작부터 (len-headLen) 까지 dash 그리고 gap 띄우기를 반복.
  local lineEnd = math.max(0, len - o.headLen)
  local d = 0
  while d < lineEnd do
    local s = d
    local e = math.min(d + o.dashLen, lineEnd)
    -- love.graphics.line(x1,y1,x2,y2): 두 점 직선. 여기선 점선 한 칸.
    love.graphics.line(x1 + ux * s, y1 + uy * s, x1 + ux * e, y1 + uy * e)
    d = d + o.dashLen + o.gapLen
  end

  -- 화살촉(목적지 끝 삼각형). px,py = 진행 방향에 수직인 단위벡터.
  local hx, hy = x1 + ux * len, y1 + uy * len      -- 끝점(목적지 중심)
  local bx, by = hx - ux * o.headLen, hy - uy * o.headLen -- 화살촉 밑변 중앙
  local px, py = -uy, ux                             -- 수직 벡터(좌우 날개용)
  local wing = o.headLen * 0.5
  -- love.graphics.polygon("fill", x1,y1, x2,y2, x3,y3): 삼각형 채우기.
  love.graphics.polygon("fill", hx, hy, bx + px * wing, by + py * wing, bx - px * wing, by - py * wing)
end

--- 진행 중인 부대 명령 경로를 지도에 그린다(GDD 12장). 이동=하늘, 수송=주황 점선.
-- 출발지/목적지 헥스 중심(state.centers)을 잇는다. 도착 시 명령이 목록에서 빠져 화살표도 사라진다.
local function drawOrderArrows(state)
  if not state.orders then return end
  for _, ord in ipairs(state.orders) do
    local a = state.centers[ord.from]
    local b = state.centers[ord.to]
    if a and b then
      local col = (ord.kind == Movement.ORDER.transport)
        and config.orders.transportColor or config.orders.moveColor
      drawDashedArrow(a.x, a.y, b.x, b.y, col)
    end
  end
end

-- ── 헥스 지도 ────────────────────────────────────────────

--- 헥스 지도(월드)를 그린다: ① 채움(세력색) → ② 경계 → ②-b 군주후보 강조 → ③ 선택 → ④ 이름 → ⑤ 경로.
-- 카메라 변환 안에서 호출(월드 좌표). (읽기 전용)
-- @param state table
function MapView.drawWorld(state)
  local regions, corners = state.regions, state.corners

  for _, r in ipairs(regions) do
    local c = regionColor(state, r)
    love.graphics.setColor(c[1], c[2], c[3], config.map.fillAlpha)
    love.graphics.polygon("fill", corners[r.id])
  end

  love.graphics.setColor(config.colors.territoryBorder)
  love.graphics.setLineWidth(config.map.borderWidth)
  for _, r in ipairs(regions) do
    love.graphics.polygon("line", corners[r.id])
  end

  -- 플레이어 소유 지역에 흰 테두리(GDD 6장). 소유=현재 시나리오 ownership 이 플레이어 세력.
  if state.playerFactionId then
    love.graphics.setColor(config.colors.playerBorder)
    love.graphics.setLineWidth(config.map.selectBorderWidth)
    for _, r in ipairs(regions) do
      if state.ownership and state.ownership[r.id] == state.playerFactionId then
        love.graphics.polygon("line", corners[r.id])
      end
    end
  end

  -- 군주 선택 중 후보 영지 강조(GDD 6장 강조 톤 — 노랑). overlay 가 고른 후보 세력의 소유 지역.
  --   확정 전이라 playerFactionId 는 아직 nil → 이 강조로 "이 군주를 고르면 갖는 땅"을 미리 보여준다.
  local hi = Overlay.highlightFaction(state)
  if hi then
    love.graphics.setColor(config.colors.selectBorder)
    love.graphics.setLineWidth(config.map.selectBorderWidth)
    for _, r in ipairs(regions) do
      if state.ownership and state.ownership[r.id] == hi then
        love.graphics.polygon("line", corners[r.id])
      end
    end
  end

  if state.selectedId then
    love.graphics.setColor(config.colors.selectBorder)
    love.graphics.setLineWidth(config.map.selectBorderWidth)
    love.graphics.polygon("line", corners[state.selectedId])
  end

  local boxW = 120
  for _, r in ipairs(regions) do
    local c = state.centers[r.id]
    local tx, ty = c.x - boxW / 2, c.y - config.map.fontSize / 2
    love.graphics.setColor(config.colors.textShadow)
    love.graphics.printf(r.name, tx + 1, ty + 1, boxW, "center")
    love.graphics.setColor(config.colors.text)
    love.graphics.printf(r.name, tx, ty, boxW, "center")
  end

  -- ⑤ 진행 중 부대 명령 경로(점선 화살표) — 이름 위에 그려 잘 보이게(GDD 12장).
  drawOrderArrows(state)
end

--- 좌상단 세력 범례(시나리오 세력 색 견본 + 이름)를 그린다. 화면 고정(카메라 변환 밖). (읽기 전용)
-- @param state table
function MapView.drawLegend(state)
  local sc = state.scenario
  if not sc then return end
  local x, y = 16, 44 -- 시작 좌표(좌상단 여백 16, 헤더 텍스트 아래 44)
  local sw = 16       -- 색 견본 정사각 한 변(px)
  -- factions 를 이름 정렬 없이 순회(테이블 순서). 한 줄씩.
  for _, f in pairs(sc.factions) do
    love.graphics.setColor(f.color)
    love.graphics.rectangle("fill", x, y, sw, sw, 3, 3)
    love.graphics.setColor(config.colors.text)
    love.graphics.print(f.name, x + sw + 8, y - 2)
    y = y + sw + 6
  end
end

return MapView
