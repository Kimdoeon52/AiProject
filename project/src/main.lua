--[[
main.lua — LÖVE2D 생명주기 (표현·입력 계층)

  이 모듈의 책임:
    - LÖVE 콜백(load/update/draw/입력)을 구현해 영토 지도를 그리고 입력을 처리한다.
    - 데이터(game_data)·유틸(camera/region/voronoi)을 조합만 한다. 규칙 로직은 두지 않는다.
  관계:
    - config   : 색상·줌·경계 두께 등 상수.
    - game_data: 지역(시드) 데이터(소유).
    - voronoi  : 시드 → 영토 폴리곤 분할 (순수 함수).
    - camera   : 스크린↔월드 좌표 변환·이동·줌 (순수 함수).
    - region   : 클릭 영토 판정(cellAt) 등 (순수 함수).

  지도 표현 (GDD 5장):
    - 각 지역은 보로노이 영토 폴리곤. 세력색으로 채우고 경계선을 그린다.
    - 맞닿은 경계선이 곧 인접 표현(별도 연결선 없음).

  계층 원칙 (CLAUDE.md):
    - draw 는 상태를 바꾸지 않는다(읽기 전용). 상태 변경은 입력 콜백/update 에서만.
    - 모든 모듈 참조는 local. 암묵적 전역 없음.
--]]

local config = require("config")
local game_data = require("game_data")
local Camera = require("camera")
local Region = require("region")
local Voronoi = require("voronoi")

-- 모듈 지역 상태 (전역 아님, 이 파일 스코프 local).
local state = {
  regions = nil,      -- 지역(시드) 데이터 참조
  cells = nil,        -- 보로노이 영토 폴리곤 배열. cells[i] ↔ regions[i]
  cam = nil,          -- 카메라
  font = nil,         -- 한글 폰트
  selectedId = nil,   -- 현재 선택된 지역 id (없으면 nil)
  drag = { active = false }, -- 좌드래그 패닝 상태
}

--- 시드(지역) 좌표들의 중심을 구해 카메라를 지도 중앙에 맞춘다.
-- 화면 중앙에 지도 무게중심이 오도록 cam.x/y 를 잡는다.
-- @return number, number  초기 cam.x, cam.y
local function initialCameraOffset(regions, scale)
  local sx, sy, n = 0, 0, 0
  for _, r in ipairs(regions) do
    sx = sx + r.x; sy = sy + r.y; n = n + 1
  end
  local cx, cy = sx / n, sy / n -- 월드 기준 지도 중심
  local w, h = love.graphics.getDimensions()
  return cx - (w / 2) / scale, cy - (h / 2) / scale
end

--- LÖVE 시작 시 1회 호출. 리소스 로드·영토 생성·초기 상태 구성.
function love.load()
  state.regions = game_data.regions

  -- 한글 폰트 로드. 경로는 LÖVE 식별자(소스 루트) 기준 → "assets/..."
  state.font = love.graphics.newFont("assets/fonts/malgun.ttf", config.map.fontSize)

  -- 영토 폴리곤은 시드가 고정이라 load 때 1회만 보로노이 분할.
  --   bbox = 시드 외곽 + 여백. 셀이 화면 밖까지 자연스럽게 뻗도록.
  local bbox = Voronoi.boundsOf(state.regions, config.map.mapMargin)
  state.cells = Voronoi.computeCells(state.regions, bbox)

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
-- @param dt number  직전 프레임과의 시간차(초)
function love.update(dt)
  -- 의도적으로 비움. (draw 에서 상태를 바꾸지 않기 위한 책임 분리 자리)
end

--- 폴리곤(평면 정점 배열)을 채우거나 외곽선으로 그린다.
-- love.graphics.polygon(mode, x1,y1,x2,y2,...): 보로노이 셀은 볼록이라 fill 안전.
-- @param mode string  "fill" | "line"
-- @param poly table   {x1,y1,x2,y2,...}
local function drawPoly(mode, poly)
  if #poly >= 6 then -- 최소 3정점(6값) 이상일 때만
    love.graphics.polygon(mode, poly)
  end
end

--- 영토 전체를 그린다: ① 채움 → ② 경계선 → ③ 선택 강조 → ④ 이름.
-- 채움을 먼저 다 칠한 뒤 경계선을 올려, 인접 경계가 채움에 가려지지 않게 한다.
local function drawTerritories()
  local regions, cells = state.regions, state.cells

  -- ① 세력색 채움
  for i, r in ipairs(regions) do
    local c = config.colors[r.owner] or config.colors.neutral
    love.graphics.setColor(c[1], c[2], c[3], config.map.fillAlpha)
    drawPoly("fill", cells[i])
  end

  -- ② 영토 경계선(=인접)
  love.graphics.setColor(config.colors.territoryBorder)
  love.graphics.setLineWidth(config.map.borderWidth)
  for i = 1, #cells do
    drawPoly("line", cells[i])
  end

  -- ③ 선택 영토 강조(노란 굵은 테두리)
  if state.selectedId then
    for i, r in ipairs(regions) do
      if r.id == state.selectedId then
        love.graphics.setColor(config.colors.selectBorder)
        love.graphics.setLineWidth(config.map.selectBorderWidth)
        drawPoly("line", cells[i])
        break
      end
    end
  end

  -- ④ 지역 이름(시드 위치, 그림자 + 본문으로 가독성 확보)
  local boxW = 160
  for _, r in ipairs(regions) do
    local tx, ty = r.x - boxW / 2, r.y - config.map.fontSize / 2
    love.graphics.setColor(config.colors.textShadow)
    love.graphics.printf(r.name, tx + 1, ty + 1, boxW, "center") -- 1px 그림자
    love.graphics.setColor(config.colors.text)
    love.graphics.printf(r.name, tx, ty, boxW, "center")
  end
end

--- 매 프레임 화면을 그린다. (읽기 전용 — 상태 변경 금지)
function love.draw()
  love.graphics.setFont(state.font)
  love.graphics.clear(config.colors.background)

  local cam = state.cam

  -- 카메라 변환: screen = (world - cam.xy) * scale → scale 후 translate(-cam.xy)
  love.graphics.push()
  love.graphics.scale(cam.scale, cam.scale)
  love.graphics.translate(-cam.x, -cam.y)

  drawTerritories() -- 이 블록 안은 월드 좌표 직접 사용

  love.graphics.pop()

  -- UI 오버레이 (카메라 변환 밖, 화면 고정 좌표)
  love.graphics.setColor(config.colors.text)
  local sel = state.selectedId and Region.byId(state.regions, state.selectedId) or nil
  local info = sel and ("선택: " .. sel.name) or "영토를 클릭하세요 · 드래그=이동 · 휠=줌"
  love.graphics.print(info, 16, 16)
end

--- 마우스 버튼 누름. 좌클릭: 드래그 시작 + 클릭 영토 선택.
-- @param x,y number  스크린 좌표
-- @param button number  1=좌, 2=우, 3=중
function love.mousepressed(x, y, button)
  if button ~= 1 then return end
  state.drag.active = true

  -- 클릭 지점을 월드 좌표로 → 최근접 시드(=영토) 선택.
  local wx, wy = Camera.screenToWorld(state.cam, x, y)
  local hit = Region.cellAt(state.regions, wx, wy)
  if hit then state.selectedId = hit.id end
end

--- 마우스 이동. 좌버튼 누른 채 이동하면 카메라 패닝.
-- @param x,y number  현재 스크린 좌표
-- @param dx,dy number  직전 대비 이동량(픽셀)
function love.mousemoved(x, y, dx, dy)
  if not state.drag.active then return end
  -- 커서를 따라 지도가 끌려오도록 카메라는 반대로(-dx,-dy) 이동.
  Camera.move(state.cam, -dx, -dy)
end

--- 마우스 버튼 뗌. 좌버튼이면 드래그 종료.
function love.mousereleased(x, y, button)
  if button == 1 then state.drag.active = false end
end

--- 마우스 휠. 커서 위치 기준으로 확대/축소.
-- @param dx number  가로 휠(미사용)
-- @param dy number  세로 휠 (>0 확대, <0 축소)
function love.wheelmoved(dx, dy)
  if dy == 0 then return end
  local factor = (dy > 0) and config.camera.zoomStep or (1 / config.camera.zoomStep)
  local mx, my = love.mouse.getPosition()
  Camera.zoomAt(state.cam, factor, mx, my)
end
