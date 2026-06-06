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
  -- 마우스 누름 상태. 누르면 생기고 떼면 nil.
  --   x,y    : 누른 스크린 좌표(클릭 판정 기준점)
  --   moved  : 누른 뒤 누적 이동 픽셀(임계 비교용)
  --   dragging : 임계 초과해 드래그(팬)로 전환됐는지
  press = nil,
}

--- 모든 헥스 꼭짓점을 감싸는 월드 경계(AABB)를 구한다. (카메라 클램프용)
-- @param corners table  [id] = {x1,y1,...}
-- @return table  { x0, y0, x1, y1 }
local function mapBounds(corners)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, poly in pairs(corners) do
    for i = 1, #poly, 2 do
      local px, py = poly[i], poly[i + 1]
      if px < x0 then x0 = px end
      if py < y0 then y0 = py end
      if px > x1 then x1 = px end
      if py > y1 then y1 = py end
    end
  end
  return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

--- 화면 크기에 맞춰 카메라 줌 하한(fit)·상한을 다시 잡고 경계 안으로 클램프.
-- load 와 창 크기 변경(love.resize) 양쪽에서 호출.
local function refitCamera()
  local cam = state.cam
  local w, h = love.graphics.getDimensions()
  -- 줌아웃 바닥 = 전체 지도 fit 배율. 상한 = fit × maxZoomFactor.
  local fit = Camera.fitScale(cam, w, h)
  cam.minScale = fit
  cam.maxScale = fit * config.camera.maxZoomFactor
  if cam.scale < fit then cam.scale = fit end -- 현재 배율이 바닥 밑이면 끌어올림
  Camera.clamp(cam, w, h)
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

  -- 지도 경계로 카메라 생성. scale=0 으로 두고 refit 이 fit 배율을 채운다.
  state.cam = Camera.new({ x = 0, y = 0, scale = 0, bounds = mapBounds(state.corners) })
  refitCamera() -- 초기 줌=전체 지도 fit, 중앙 정렬
end

--- 창 크기 변경 시 카메라 재적합(fit/클램프). LÖVE 가 자동 호출.
-- @param w,h number  새 창 크기
function love.resize(w, h)
  refitCamera()
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

--- 좌버튼 누름: 누름 상태만 기록(아직 선택/팬 안 함).
-- 클릭이냐 드래그냐는 떼거나 임계 초과 시점에 결정한다(아래 두 콜백).
-- @param x,y number  스크린 좌표
-- @param button number  1=좌, 2=우, 3=중 (LÖVE 마우스 버튼 번호)
-- @side 부작용: state.press 설정
function love.mousepressed(x, y, button)
  if button ~= 1 then return end -- 좌클릭만 처리(우/중클릭 무시)
  state.press = { x = x, y = y, moved = 0, dragging = false }
end

--- 마우스 이동: 누른 상태면 누적 이동을 보고 클릭/드래그를 가른다.
-- 누적 이동 < 임계 → 아직 클릭 후보(팬 안 함). 임계 도달 → 드래그 확정 → 팬.
-- (임계 전 미세 이동으로 화면이 떨리지 않도록, 확정 이후에만 카메라를 움직인다.)
-- @param x,y number   현재 스크린 좌표(미사용)
-- @param dx,dy number 직전 대비 이동량(픽셀) — LÖVE 가 제공
-- @side 부작용: state.press.moved/dragging, 카메라 위치
function love.mousemoved(x, y, dx, dy)
  local p = state.press
  if not p then return end -- 버튼 안 눌렀으면 무시

  -- 이번 프레임 이동 거리를 누적(맨해튼 근사 대신 유클리드).
  p.moved = p.moved + math.sqrt(dx * dx + dy * dy)
  if not p.dragging and p.moved >= config.input.dragThreshold then
    p.dragging = true -- 임계 초과 → 드래그(팬)로 전환, 이후 클릭 취소
  end

  if p.dragging then
    -- 커서를 따라 지도가 끌려오도록 카메라는 반대로(-dx,-dy) 이동 후 경계 클램프.
    Camera.move(state.cam, -dx, -dy)
    local w, h = love.graphics.getDimensions()
    Camera.clamp(state.cam, w, h)
  end
end

--- 좌버튼 뗌: 드래그가 아니었으면(이동 < 임계) 그때서야 클릭 = 헥스 선택.
-- 드래그였으면 선택하지 않는다(요구사항: 큰 이동은 팬만).
-- @side 부작용: state.selectedId, state.press 해제
function love.mousereleased(x, y, button)
  if button ~= 1 then return end
  local p = state.press
  state.press = nil
  if not p or p.dragging then return end -- 드래그였으면 선택 취소

  -- 클릭 확정: 누른 지점을 월드 좌표로 환산해 헥스 선택.
  local wx, wy = Camera.screenToWorld(state.cam, p.x, p.y)
  local hit = Region.cellAt(state.regions, wx, wy, config.map.hexSize)
  if hit then state.selectedId = hit.id end
end

--- 휠 → 커서 기준 줌.
-- [비활성] 현재 지도는 항상 "전체 fit" 으로 보여서 확대의 쓸모가 불명확 →
--   줌 동작을 잠시 꺼둔다(코드는 보존). 확대 기능을 다시 쓰려면 아래 블록의
--   주석을 풀면 된다. (camera.zoomAt/fitScale/maxZoomFactor 는 그대로 살아있음.)
-- @param dx number  가로 휠(미사용)
-- @param dy number  세로 휠: >0 위로(확대), <0 아래로(축소)
-- @side 부작용: (활성 시) 카메라 배율/위치 변경
function love.wheelmoved(dx, dy)
  -- // 줌 비활성: 아무 것도 안 함. 재활성하려면 아래 주석 해제.
  -- if dy == 0 then return end -- 세로 휠 없으면 무시
  -- -- 한 칸당 zoomStep 배. 아래로는 그 역수(1/step)로 축소.
  -- local factor = (dy > 0) and config.camera.zoomStep or (1 / config.camera.zoomStep)
  -- -- love.mouse.getPosition(): 현재 커서의 스크린 좌표(x,y) 반환. 줌 고정점으로 사용.
  -- local mx, my = love.mouse.getPosition()
  -- Camera.zoomAt(state.cam, factor, mx, my)
  -- local w, h = love.graphics.getDimensions()
  -- Camera.clamp(state.cam, w, h) -- 줌 후 지도 밖이 보이지 않게 가둠
end
