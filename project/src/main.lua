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
  -- love.graphics.getDimensions(): 현재 창 크기(픽셀 폭, 높이)를 반환.
  local w, h = love.graphics.getDimensions()
  -- 화면 중앙이 지도 중심(cx,cy)을 가리키게: cam.xy = center - 화면절반/scale.
  return cx - (w / 2) / scale, cy - (h / 2) / scale
end

--- LÖVE 시작 시 1회. 폰트 로드·헥스 기하 캐시·카메라 초기화.
function love.load()
  state.regions = game_data.regions
  -- love.graphics.newFont(path, size): 지정 ttf 파일로 폰트 객체 생성(한글 표시용).
  -- 경로는 LÖVE 식별자(소스 루트 = project/src) 기준 → "assets/..."
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
    -- love.graphics.setColor(r,g,b,a): 이후 그리기 색(0~1). a=불투명도.
    love.graphics.setColor(c[1], c[2], c[3], config.map.fillAlpha)
    -- love.graphics.polygon("fill", verts): 평면 정점배열로 다각형 채우기.
    --   헥스는 볼록이라 "fill" 안전(삼각화 불필요).
    love.graphics.polygon("fill", corners[r.id])
  end

  -- ② 경계선(=인접). 채움 위에 올려야 인접 경계가 가려지지 않음.
  love.graphics.setColor(config.colors.territoryBorder)
  -- love.graphics.setLineWidth(px): 이후 선/외곽선 두께(월드 단위).
  love.graphics.setLineWidth(config.map.borderWidth)
  for _, r in ipairs(regions) do
    -- "line" 모드 = 채움 없이 외곽선만.
    love.graphics.polygon("line", corners[r.id])
  end

  -- ③ 선택 헥스 강조
  if state.selectedId then
    love.graphics.setColor(config.colors.selectBorder)
    love.graphics.setLineWidth(config.map.selectBorderWidth)
    love.graphics.polygon("line", corners[state.selectedId])
  end

  -- ④ 이름(헥스 중심, 그림자+본문). 그림자 = 채움색 위 가독성 확보.
  local boxW = 120 -- 가운데 정렬용 가상 박스 폭(px). 중심 기준 좌우로 절반씩.
  for _, r in ipairs(regions) do
    local c = state.centers[r.id]
    -- 박스를 헥스 중심에 맞춤: 가로는 -boxW/2, 세로는 글자높이 절반만큼 올림.
    local tx, ty = c.x - boxW / 2, c.y - config.map.fontSize / 2
    -- love.graphics.printf(text, x, y, limit, align): limit 폭 안에서 정렬 출력.
    love.graphics.setColor(config.colors.textShadow)
    love.graphics.printf(r.name, tx + 1, ty + 1, boxW, "center") -- 1px 우하향 그림자
    love.graphics.setColor(config.colors.text)
    love.graphics.printf(r.name, tx, ty, boxW, "center")
  end
end

--- 매 프레임 화면을 그린다. (읽기 전용 — 상태 변경 금지)
function love.draw()
  -- love.graphics.setFont(font): 이후 텍스트에 쓸 폰트 지정.
  love.graphics.setFont(state.font)
  -- love.graphics.clear(color): 화면 전체를 배경색으로 지움(매 프레임 초기화).
  love.graphics.clear(config.colors.background)

  local cam = state.cam
  -- 카메라 변환 적용. push/pop = 변환행렬 스택 저장/복원(이 블록만 영향).
  -- love.graphics.push(): 현재 좌표변환 상태를 스택에 저장.
  love.graphics.push()
  -- scale → translate 순서: screen = (world - cam.xy) * scale.
  -- love.graphics.scale(sx,sy): 이후 그리기를 배율만큼 확대/축소.
  love.graphics.scale(cam.scale, cam.scale)
  -- love.graphics.translate(dx,dy): 이후 그리기를 평행이동(카메라 좌상단만큼).
  love.graphics.translate(-cam.x, -cam.y)

  drawHexMap() -- 이 안은 월드 좌표 직접 사용

  -- love.graphics.pop(): push 로 저장한 변환 상태로 복원(오버레이는 화면 고정).
  love.graphics.pop()

  -- UI 오버레이 (카메라 변환 밖 = 화면 고정 좌표)
  love.graphics.setColor(config.colors.text)
  local sel = state.selectedId and Region.byId(state.regions, state.selectedId) or nil
  local info = sel and ("선택: " .. sel.name) or "지역을 클릭하세요 · 드래그=이동 · 휠=줌"
  -- love.graphics.print(text, x, y): 폰트로 텍스트를 좌상단 기준 출력.
  love.graphics.print(info, 16, 16)
end

--- 좌클릭: 드래그 시작 + 클릭 헥스 선택.
-- @param x,y number  스크린 좌표
-- @param button number  1=좌, 2=우, 3=중 (LÖVE 마우스 버튼 번호)
-- @side 부작용: state.drag.active, state.selectedId 변경
function love.mousepressed(x, y, button)
  if button ~= 1 then return end -- 좌클릭만 처리(우/중클릭 무시)
  state.drag.active = true
  -- 클릭은 스크린 좌표 → 카메라로 월드 좌표 환산해야 헥스와 비교 가능.
  local wx, wy = Camera.screenToWorld(state.cam, x, y)
  local hit = Region.cellAt(state.regions, wx, wy, config.map.hexSize)
  if hit then state.selectedId = hit.id end
end

--- 좌버튼 드래그 중 카메라 패닝.
-- @param x,y number   현재 스크린 좌표(미사용)
-- @param dx,dy number 직전 프레임 대비 이동량(픽셀) — LÖVE 가 제공
-- @side 부작용: 카메라 위치 이동
function love.mousemoved(x, y, dx, dy)
  if not state.drag.active then return end -- 버튼 안 눌렀으면 패닝 안 함
  -- 커서를 따라 지도가 끌려오도록 카메라는 반대로(-dx,-dy) 이동.
  Camera.move(state.cam, -dx, -dy)
end

--- 좌버튼 뗌 → 드래그 종료.
function love.mousereleased(x, y, button)
  if button == 1 then state.drag.active = false end
end

--- 휠 → 커서 기준 줌.
-- @param dx number  가로 휠(미사용)
-- @param dy number  세로 휠: >0 위로(확대), <0 아래로(축소)
-- @side 부작용: 카메라 배율/위치 변경
function love.wheelmoved(dx, dy)
  if dy == 0 then return end -- 세로 휠 없으면 무시
  -- 한 칸당 zoomStep 배. 아래로는 그 역수(1/step)로 축소.
  local factor = (dy > 0) and config.camera.zoomStep or (1 / config.camera.zoomStep)
  -- love.mouse.getPosition(): 현재 커서의 스크린 좌표(x,y) 반환. 줌 고정점으로 사용.
  local mx, my = love.mouse.getPosition()
  Camera.zoomAt(state.cam, factor, mx, my)
end
