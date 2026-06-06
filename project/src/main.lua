--[[
main.lua — LÖVE2D 생명주기 (표현·입력 계층)

  이 모듈의 책임:
    - LÖVE 콜백(load/update/draw/입력)을 구현해 헥스 지도를 그리고 입력을 처리한다.
    - 데이터(game_data)·유틸(hex/camera/region)을 조합만 한다. 규칙 로직은 두지 않는다.
  관계:
    - config   : 색상·줌·헥스 크기 등 상수.
    - game_data: 지역(헥스 axial) 데이터.
    - hex      : axial→픽셀/꼭짓점 변환 (순수).
    - camera   : 스크린↔월드 변환·이동·줌 (순수).
    - region   : 클릭 헥스 판정(cellAt) (순수).

  지도 표현 (GDD 5장):
    - 각 지역 = 육각형 1칸. 세력색 채움 + 경계선. 맞닿은 경계 = 인접.

  계층 원칙 (CLAUDE.md):
    - draw 는 상태를 바꾸지 않는다(읽기 전용). 상태 변경은 입력 콜백/update 에서만.
    - 모든 모듈 참조는 local. 암묵적 전역 없음.
--]]

local config = require("config")
local game_data = require("game_data")
local Camera = require("camera")
local Region = require("region")
local Hex = require("hex")

-- 모듈 지역 상태 (전역 아님).
local state = {
  regions = nil,      -- 지역(헥스) 데이터
  centers = nil,      -- [id] = {x,y} 헥스 중심 픽셀 (load 때 캐시)
  corners = nil,      -- [id] = {x1,y1,...} 헥스 6꼭짓점 (load 때 캐시)
  cam = nil,
  font = nil,
  selectedId = nil,
  drag = { active = false },
}

--- 헥스 중심들의 평균을 화면 중앙에 두도록 카메라 초기 위치 계산.
-- @return number, number  cam.x, cam.y
local function initialCameraOffset(centers, scale)
  local sx, sy, n = 0, 0, 0
  for _, c in pairs(centers) do
    sx = sx + c.x; sy = sy + c.y; n = n + 1
  end
  local cx, cy = sx / n, sy / n
  local w, h = love.graphics.getDimensions()
  return cx - (w / 2) / scale, cy - (h / 2) / scale
end

--- LÖVE 시작 시 1회. 폰트 로드·헥스 기하 캐시·카메라 초기화.
function love.load()
  state.regions = game_data.regions
  state.font = love.graphics.newFont("assets/fonts/malgun.ttf", config.map.fontSize)

  -- 헥스 중심·꼭짓점은 정적이라 load 때 1회만 계산해 캐시.
  local size = config.map.hexSize
  state.centers, state.corners = {}, {}
  for _, r in ipairs(state.regions) do
    local cx, cy = Hex.axialToPixel(r.q, r.r, size)
    state.centers[r.id] = { x = cx, y = cy }
    state.corners[r.id] = Hex.corners(cx, cy, size)
  end

  local scale = 1.0
  local ox, oy = initialCameraOffset(state.centers, scale)
  state.cam = Camera.new({
    x = ox, y = oy, scale = scale,
    minScale = config.camera.minScale,
    maxScale = config.camera.maxScale,
  })
end

--- 매 프레임 상태 갱신. (현재 입력 즉시 반영이라 비움)
-- @param dt number
function love.update(dt)
  -- 의도적으로 비움 (draw 에서 상태 변경 금지 — 책임 분리)
end

--- 헥스 지도 전체를 그린다: ① 채움 → ② 경계 → ③ 선택 → ④ 이름.
local function drawHexMap()
  local regions, corners = state.regions, state.corners

  -- ① 세력색 채움
  for _, r in ipairs(regions) do
    local c = config.colors[r.owner] or config.colors.neutral
    love.graphics.setColor(c[1], c[2], c[3], config.map.fillAlpha)
    love.graphics.polygon("fill", corners[r.id])
  end

  -- ② 경계선(=인접)
  love.graphics.setColor(config.colors.territoryBorder)
  love.graphics.setLineWidth(config.map.borderWidth)
  for _, r in ipairs(regions) do
    love.graphics.polygon("line", corners[r.id])
  end

  -- ③ 선택 헥스 강조
  if state.selectedId then
    love.graphics.setColor(config.colors.selectBorder)
    love.graphics.setLineWidth(config.map.selectBorderWidth)
    love.graphics.polygon("line", corners[state.selectedId])
  end

  -- ④ 이름(헥스 중심, 그림자+본문)
  local boxW = 120
  for _, r in ipairs(regions) do
    local c = state.centers[r.id]
    local tx, ty = c.x - boxW / 2, c.y - config.map.fontSize / 2
    love.graphics.setColor(config.colors.textShadow)
    love.graphics.printf(r.name, tx + 1, ty + 1, boxW, "center")
    love.graphics.setColor(config.colors.text)
    love.graphics.printf(r.name, tx, ty, boxW, "center")
  end
end

--- 매 프레임 화면을 그린다. (읽기 전용 — 상태 변경 금지)
function love.draw()
  love.graphics.setFont(state.font)
  love.graphics.clear(config.colors.background)

  local cam = state.cam
  love.graphics.push()
  love.graphics.scale(cam.scale, cam.scale)
  love.graphics.translate(-cam.x, -cam.y)

  drawHexMap()

  love.graphics.pop()

  -- UI 오버레이 (화면 고정)
  love.graphics.setColor(config.colors.text)
  local sel = state.selectedId and Region.byId(state.regions, state.selectedId) or nil
  local info = sel and ("선택: " .. sel.name) or "지역을 클릭하세요 · 드래그=이동 · 휠=줌"
  love.graphics.print(info, 16, 16)
end

--- 좌클릭: 드래그 시작 + 클릭 헥스 선택.
-- @param x,y number  스크린 좌표
-- @param button number
function love.mousepressed(x, y, button)
  if button ~= 1 then return end
  state.drag.active = true
  local wx, wy = Camera.screenToWorld(state.cam, x, y)
  local hit = Region.cellAt(state.regions, wx, wy, config.map.hexSize)
  if hit then state.selectedId = hit.id end
end

--- 좌버튼 드래그 중 카메라 패닝.
function love.mousemoved(x, y, dx, dy)
  if not state.drag.active then return end
  Camera.move(state.cam, -dx, -dy)
end

--- 좌버튼 뗌 → 드래그 종료.
function love.mousereleased(x, y, button)
  if button == 1 then state.drag.active = false end
end

--- 휠 → 커서 기준 줌.
function love.wheelmoved(dx, dy)
  if dy == 0 then return end
  local factor = (dy > 0) and config.camera.zoomStep or (1 / config.camera.zoomStep)
  local mx, my = love.mouse.getPosition()
  Camera.zoomAt(state.cam, factor, mx, my)
end
