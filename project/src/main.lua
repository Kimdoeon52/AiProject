--[[
main.lua — LÖVE2D 생명주기 (표현·입력 계층)

  이 모듈의 책임:
    - LÖVE 콜백(load/update/draw/입력)을 구현해 지도를 그리고 입력을 처리한다.
    - 데이터(game_data)·유틸(camera/region)을 조합만 한다. 규칙 로직은 두지 않는다.
  관계:
    - config   : 색상·줌·노드 크기 등 상수.
    - game_data: 지역 데이터(소유).
    - camera   : 스크린↔월드 좌표 변환·이동·줌 (순수 함수).
    - region   : 인접선 목록·클릭 판정 (순수 함수).

  계층 원칙 (CLAUDE.md):
    - draw 는 상태를 바꾸지 않는다(읽기 전용). 상태 변경은 입력 콜백/update 에서만.
    - 모든 모듈 참조는 local. 암묵적 전역 없음.
--]]

local config = require("config")
local game_data = require("game_data")
local Camera = require("camera")
local Region = require("region")

-- 모듈 지역 상태 (전역 아님, 이 파일 스코프 local).
local state = {
  regions = nil,      -- 지역 데이터 참조
  cam = nil,          -- 카메라
  font = nil,         -- 한글 폰트
  connections = nil,  -- 미리 계산한 인접선 목록 (정적이라 load 때 1회)
  selectedId = nil,   -- 현재 선택된 지역 id (없으면 nil)
  drag = { active = false, button = 1 }, -- 좌드래그 패닝 상태
}

--- 지역 좌표들의 중심을 구해 카메라를 지도 중앙에 맞춘다.
-- 화면 중앙(폭/2, 높이/2)에 지도 무게중심이 오도록 cam.x/y 를 잡는다.
-- @return number, number  초기 cam.x, cam.y
local function initialCameraOffset(regions, scale)
  -- 모든 노드의 평균 좌표 = 대략적 지도 중심
  local sx, sy, n = 0, 0, 0
  for _, r in ipairs(regions) do
    sx = sx + r.x
    sy = sy + r.y
    n = n + 1
  end
  local cx, cy = sx / n, sy / n -- 월드 기준 지도 중심

  -- 화면 중심이 (cx, cy)를 가리키게: cam.xy = center - screenHalf/scale
  local w, h = love.graphics.getDimensions()
  return cx - (w / 2) / scale, cy - (h / 2) / scale
end

--- LÖVE 시작 시 1회 호출. 리소스 로드·초기 상태 구성.
function love.load()
  state.regions = game_data.regions

  -- 한글 폰트 로드. 경로는 LÖVE 식별자(소스 루트) 기준 → "assets/..."
  -- love.graphics.newFont(path, size): 지정 ttf 로 폰트 객체 생성.
  state.font = love.graphics.newFont("assets/fonts/malgun.ttf", config.map.fontSize)

  -- 인접선은 데이터가 고정이라 매 프레임 다시 계산하지 않고 여기서 한 번만.
  state.connections = Region.connections(state.regions)

  -- 카메라 생성 + 초기 위치를 지도 중앙으로.
  local scale = 1.0
  local ox, oy = initialCameraOffset(state.regions, scale)
  state.cam = Camera.new({
    x = ox, y = oy, scale = scale,
    minScale = config.camera.minScale,
    maxScale = config.camera.maxScale,
  })
end

--- 매 프레임 상태 갱신. (Day1: 입력이 즉시 반영되므로 갱신할 상태 없음)
-- draw 와 분리해 두는 자리. 추후 애니메이션/턴 타이머 등이 여기로.
-- @param dt number  직전 프레임과의 시간차(초)
function love.update(dt)
  -- 의도적으로 비움. (draw 에서 상태를 바꾸지 않기 위한 책임 분리 자리)
end

--- 한 지역 노드(원 + 테두리 + 이름)를 그린다.
-- @param r table  지역 레코드
-- @param isSelected boolean  선택 강조 여부
local function drawRegionNode(r, isSelected)
  local radius = config.map.nodeRadius
  local fill = config.colors[r.owner] or config.colors.neutral

  -- 내부 채움 (세력색) — love.graphics.circle("fill", x, y, r): 원 채우기
  love.graphics.setColor(fill)
  love.graphics.circle("fill", r.x, r.y, radius)

  -- 테두리: 선택 > 기본. (플레이어 흰 테두리는 소유 개념 도입 후 — 추후)
  if isSelected then
    love.graphics.setColor(config.colors.selectBorder)
    love.graphics.setLineWidth(4)
  else
    love.graphics.setColor(config.colors.nodeBorder)
    love.graphics.setLineWidth(2)
  end
  love.graphics.circle("line", r.x, r.y, radius)

  -- 이름: 노드 아래 가운데 정렬. printf(text, x, y, limit, align)
  -- limit 폭의 박스를 노드 중심에 맞춰 가운데 정렬한다.
  love.graphics.setColor(config.colors.text)
  local boxW = 160
  love.graphics.printf(r.name, r.x - boxW / 2, r.y + radius + 4, boxW, "center")
end

--- 매 프레임 화면을 그린다. (읽기 전용 — 상태 변경 금지)
function love.draw()
  love.graphics.setFont(state.font)

  -- 배경
  love.graphics.clear(config.colors.background)

  local cam = state.cam

  -- 카메라 변환 적용: 월드 좌표를 그대로 그리되 화면에 맞춰 이동/확대.
  --   screen = (world - cam.xy) * scale  →  scale 후 translate(-cam.xy)
  love.graphics.push()
  love.graphics.scale(cam.scale, cam.scale)        -- 확대/축소
  love.graphics.translate(-cam.x, -cam.y)          -- 카메라 좌상단만큼 이동
  -- 이 push 블록 안에서는 월드 좌표를 직접 써서 그리면 된다.

  -- ① 인접선 (노드보다 먼저 → 노드가 선 위에 올라오게)
  love.graphics.setColor(config.colors.line)
  love.graphics.setLineWidth(2)
  for _, ln in ipairs(state.connections) do
    -- ln = {x1, y1, x2, y2}
    love.graphics.line(ln[1], ln[2], ln[3], ln[4])
  end

  -- ② 노드 + 이름
  for _, r in ipairs(state.regions) do
    drawRegionNode(r, r.id == state.selectedId)
  end

  love.graphics.pop()

  -- ③ UI 오버레이 (카메라 변환 밖, 화면 고정 좌표)
  love.graphics.setColor(config.colors.text)
  local sel = state.selectedId and Region.byId(state.regions, state.selectedId) or nil
  local info = sel and ("선택: " .. sel.name) or "지역을 클릭하세요 · 드래그=이동 · 휠=줌"
  love.graphics.print(info, 16, 16)
end

--- 마우스 버튼 누름. 좌클릭: 드래그 시작 + 지역 선택 판정.
-- @param x number  스크린 X
-- @param y number  스크린 Y
-- @param button number  1=좌, 2=우, 3=중
function love.mousepressed(x, y, button)
  if button ~= 1 then return end

  state.drag.active = true -- 좌드래그 패닝 시작

  -- 클릭 지점을 월드 좌표로 바꿔 노드 포함 판정.
  local wx, wy = Camera.screenToWorld(state.cam, x, y)
  local hit = Region.hitTest(state.regions, wx, wy, config.map.nodeRadius)
  if hit then
    state.selectedId = hit.id
  end
  -- 빈 곳 클릭은 선택 유지(드래그 시작만). 선택 해제는 추후 정책에 맡김.
end

--- 마우스 이동. 좌버튼 누른 채 이동하면 카메라 패닝.
-- @param x number  현재 스크린 X
-- @param y number  현재 스크린 Y
-- @param dx number  직전 대비 X 이동량(픽셀)
-- @param dy number  직전 대비 Y 이동량(픽셀)
function love.mousemoved(x, y, dx, dy)
  if not state.drag.active then return end
  -- 손으로 지도를 끄는 느낌: 커서가 오른쪽으로 가면 지도도 오른쪽으로.
  -- → 카메라는 반대로(-dx) 이동해야 같은 월드 점이 커서를 따라온다.
  Camera.move(state.cam, -dx, -dy)
end

--- 마우스 버튼 뗌. 좌버튼이면 드래그 종료.
function love.mousereleased(x, y, button)
  if button == 1 then
    state.drag.active = false
  end
end

--- 마우스 휠. 커서 위치 기준으로 확대/축소.
-- @param dx number  가로 휠(미사용)
-- @param dy number  세로 휠 (>0 위로=확대, <0 아래로=축소)
function love.wheelmoved(dx, dy)
  if dy == 0 then return end
  -- 휠 한 칸당 zoomStep 배. 위로 굴리면 확대, 아래로 굴리면 그 역수.
  local factor = (dy > 0) and config.camera.zoomStep or (1 / config.camera.zoomStep)
  local mx, my = love.mouse.getPosition() -- 현재 커서 스크린 좌표
  Camera.zoomAt(state.cam, factor, mx, my)
end
