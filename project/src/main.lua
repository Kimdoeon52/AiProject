--[[
main.lua — LÖVE2D 생명주기 (표현·입력 계층)

  이 모듈의 책임:
    - LÖVE 콜백(load/update/draw/입력)으로 화면을 그리고 입력을 처리한다.
    - 두 화면(scene)을 오간다: "select"(시나리오 선택) → "map"(헥스 지도).
    - 데이터(game_data)·유틸(hex/camera/region/ui)을 조합만 한다. 규칙 로직 없음.
  관계:
    - config   : 색·줌·헥스 크기 등 상수.
    - game_data: 지역(헥스) + 시나리오(세력/소유).
    - hex/camera/region : 좌표·카메라·클릭(순수).
    - ui       : 버튼 렌더/클릭.

  표현 (GDD):
    - 지도 = 육각형 1칸/지역. 채움색 = 선택한 시나리오의 지역 소유 세력색(GDD 4·6장).
    - 미소유 지역 = 중립(회색).

  계층 원칙 (CLAUDE.md): draw 는 읽기만(상태 변경은 입력/update). 모든 참조 local.
--]]

local config = require("config")
local game_data = require("game_data")
local Camera = require("camera")
local Region = require("region")
local Hex = require("hex")
local UI = require("ui")

-- 모듈 지역 상태 (전역 아님).
local state = {
  scene = "select",   -- "select" | "map"
  scenario = nil,     -- 선택된 시나리오 레코드(game_data.scenarios 의 한 항목)
  regions = nil,      -- 지역(헥스) 데이터
  centers = nil,      -- [id] = {x,y} 헥스 중심 픽셀 (캐시)
  corners = nil,      -- [id] = {x1,y1,...} 헥스 6꼭짓점 (캐시)
  cam = nil,
  font = nil,
  titleFont = nil,    -- 선택 화면 제목용 큰 폰트
  selectedId = nil,
  -- 마우스 누름 상태(지도 화면 전용). 누르면 생기고 떼면 nil.
  press = nil,
}

-- ── 카메라/경계 ──────────────────────────────────────────

--- 모든 헥스 꼭짓점을 감싸는 월드 경계(AABB). (카메라 클램프용)
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

--- 화면 크기에 맞춰 줌 하한(fit)·상한 재계산 + 경계 클램프.
local function refitCamera()
  local cam = state.cam
  local w, h = love.graphics.getDimensions()
  local fit = Camera.fitScale(cam, w, h)
  cam.minScale = fit
  cam.maxScale = fit * config.camera.maxZoomFactor
  if cam.scale < fit then cam.scale = fit end
  Camera.clamp(cam, w, h)
end

-- ── 시나리오 색 조회 ─────────────────────────────────────

--- 지역의 채움색을 현재 시나리오 소유 세력에서 가져온다.
-- 소유 없음 → 중립 회색.
-- @param r table  지역 레코드
-- @return table  {r,g,b}
local function regionColor(r)
  local sc = state.scenario
  if sc then
    local fid = sc.ownership[r.id]
    local f = fid and sc.factions[fid]
    if f then return f.color end
  end
  return config.colors.neutral
end

--- 지역 소유 세력의 표시 이름(없으면 "중립").
local function regionFactionName(r)
  local sc = state.scenario
  local fid = sc and sc.ownership[r.id]
  local f = fid and sc.factions[fid]
  return f and f.name or "중립"
end

-- ── load ─────────────────────────────────────────────────

function love.load()
  state.regions = game_data.regions
  -- love.graphics.newFont(path, size): ttf 로 폰트 객체 생성(한글용).
  state.font = love.graphics.newFont("assets/fonts/malgun.ttf", config.map.fontSize)
  state.titleFont = love.graphics.newFont("assets/fonts/malgun.ttf", 40)

  -- 헥스 중심·꼭짓점은 정적 → 1회 캐시.
  local size = config.map.hexSize
  state.centers, state.corners = {}, {}
  for _, r in ipairs(state.regions) do
    local cx, cy = Hex.axialToPixel(r.q, r.r, size)
    state.centers[r.id] = { x = cx, y = cy }
    state.corners[r.id] = Hex.corners(cx, cy, size)
  end

  -- 카메라(지도 경계). scale=0 → refit 이 fit 으로 채움. 지도 진입 시 refit 재호출.
  state.cam = Camera.new({ x = 0, y = 0, scale = 0, bounds = mapBounds(state.corners) })
  -- 시작은 시나리오 선택 화면.
  state.scene = "select"
end

--- 창 크기 변경 시 카메라 재적합. (지도 화면에서만 의미)
function love.resize(w, h)
  if state.scene == "map" then refitCamera() end
end

function love.update(dt)
  -- 비움 (draw 에서 상태 변경 금지)
end

-- ── 선택 화면 ────────────────────────────────────────────

--- 시나리오 버튼 목록을 화면 크기에 맞춰 만든다. (draw·입력에서 같은 레이아웃 공유)
-- @return table  UI 버튼 배열(value = 시나리오 인덱스)
local function buildScenarioButtons()
  local w, h = love.graphics.getDimensions()
  local bw, bh, gap = 520, 76, 18
  local n = #game_data.scenarios
  local totalH = n * bh + (n - 1) * gap
  local x = (w - bw) / 2
  local y0 = h / 2 - totalH / 2 + 30 -- 제목 아래로 약간 내림
  local btns = {}
  for i, sc in ipairs(game_data.scenarios) do
    local label = string.format("%s  (%d년)", sc.name, sc.year)
    btns[i] = UI.newButton(x, y0 + (i - 1) * (bh + gap), bw, bh, label, i)
  end
  return btns
end

local function drawSelect()
  local w = love.graphics.getWidth()
  love.graphics.clear(config.colors.background)

  -- 제목
  love.graphics.setFont(state.titleFont)
  love.graphics.setColor(config.colors.text)
  love.graphics.printf("삼국 패권 — 시나리오 선택", 0, 90, w, "center")

  -- 버튼들 (마우스 위치로 hover 강조)
  love.graphics.setFont(state.font)
  local mx, my = love.mouse.getPosition()
  for _, btn in ipairs(buildScenarioButtons()) do
    UI.draw(btn, { hovered = UI.hit(btn, mx, my), accent = config.colors.selectBorder })
  end

  love.graphics.setColor(config.colors.text)
  love.graphics.printf("시나리오를 클릭해 시작", 0, love.graphics.getHeight() - 60, w, "center")
end

-- ── 지도 화면 ────────────────────────────────────────────

--- 헥스 지도: ① 채움(시나리오 세력색) → ② 경계 → ③ 선택 → ④ 이름.
local function drawHexMap()
  local regions, corners = state.regions, state.corners

  for _, r in ipairs(regions) do
    local c = regionColor(r)
    love.graphics.setColor(c[1], c[2], c[3], config.map.fillAlpha)
    love.graphics.polygon("fill", corners[r.id])
  end

  love.graphics.setColor(config.colors.territoryBorder)
  love.graphics.setLineWidth(config.map.borderWidth)
  for _, r in ipairs(regions) do
    love.graphics.polygon("line", corners[r.id])
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
end

--- 좌상단 세력 범례(시나리오 세력 색·이름).
local function drawLegend()
  local sc = state.scenario
  if not sc then return end
  local x, y = 16, 44
  local sw = 16 -- 색 견본 한 변
  -- factions 를 이름 정렬 없이 순회(테이블 순서). 한 줄씩.
  for _, f in pairs(sc.factions) do
    love.graphics.setColor(f.color)
    love.graphics.rectangle("fill", x, y, sw, sw, 3, 3)
    love.graphics.setColor(config.colors.text)
    love.graphics.print(f.name, x + sw + 8, y - 2)
    y = y + sw + 6
  end
end

local function drawMap()
  love.graphics.clear(config.colors.background)
  local cam = state.cam
  love.graphics.push()
  love.graphics.scale(cam.scale, cam.scale)
  love.graphics.translate(-cam.x, -cam.y)
  drawHexMap()
  love.graphics.pop()

  -- 오버레이(화면 고정): 시나리오/선택 정보 + 범례.
  love.graphics.setColor(config.colors.text)
  local head = string.format("%s (%d년)  ·  Esc=시나리오 선택", state.scenario.name, state.scenario.year)
  love.graphics.print(head, 16, 16)
  local sel = state.selectedId and Region.byId(state.regions, state.selectedId) or nil
  if sel then
    love.graphics.printf(sel.name .. " — " .. regionFactionName(sel),
      love.graphics.getWidth() - 320, 16, 304, "right")
  end
  drawLegend()
end

-- ── draw 디스패치 ────────────────────────────────────────

function love.draw()
  love.graphics.setFont(state.font)
  if state.scene == "select" then
    drawSelect()
  else
    drawMap()
  end
end

-- ── 입력 ─────────────────────────────────────────────────

--- 시나리오를 골라 지도 화면으로 전환.
-- @param idx number  game_data.scenarios 인덱스
local function startScenario(idx)
  state.scenario = game_data.scenarios[idx]
  state.selectedId = nil
  state.scene = "map"
  refitCamera() -- 지도 진입 시 fit/중앙 맞춤
end

function love.mousepressed(x, y, button)
  if button ~= 1 then return end

  if state.scene == "select" then
    -- 메뉴는 누른 즉시 판정(드래그 개념 없음).
    for _, btn in ipairs(buildScenarioButtons()) do
      if UI.hit(btn, x, y) then
        startScenario(btn.value)
        return
      end
    end
    return
  end

  -- 지도: 누름 기록(클릭/드래그는 이동량으로 판정).
  state.press = { x = x, y = y, moved = 0, dragging = false }
end

function love.mousemoved(x, y, dx, dy)
  if state.scene ~= "map" then return end
  local p = state.press
  if not p then return end

  p.moved = p.moved + math.sqrt(dx * dx + dy * dy)
  if not p.dragging and p.moved >= config.input.dragThreshold then
    p.dragging = true -- 임계 초과 → 드래그(팬)
  end
  if p.dragging then
    Camera.move(state.cam, -dx, -dy)
    local w, h = love.graphics.getDimensions()
    Camera.clamp(state.cam, w, h)
  end
end

function love.mousereleased(x, y, button)
  if button ~= 1 or state.scene ~= "map" then return end
  local p = state.press
  state.press = nil
  if not p or p.dragging then return end -- 드래그였으면 선택 취소

  local wx, wy = Camera.screenToWorld(state.cam, p.x, p.y)
  local hit = Region.cellAt(state.regions, wx, wy, config.map.hexSize)
  if hit then state.selectedId = hit.id end
end

--- 키 입력. 지도에서 Esc → 시나리오 선택으로 복귀.
-- @param key string
function love.keypressed(key)
  if key == "escape" then
    if state.scene == "map" then
      state.scene = "select"
      state.selectedId = nil
      state.press = nil
    else
      love.event.quit() -- 선택 화면에서 Esc → 종료
    end
  end
end

--- 휠 → 커서 기준 줌.
-- [비활성] 지도가 항상 전체 fit 이라 확대 쓸모 불명확 → 꺼둠(코드 보존).
--   재활성하려면 아래 주석 해제. (camera.zoomAt/fitScale 는 살아있음.)
function love.wheelmoved(dx, dy)
  -- if state.scene ~= "map" then return end
  -- if dy == 0 then return end
  -- local factor = (dy > 0) and config.camera.zoomStep or (1 / config.camera.zoomStep)
  -- local mx, my = love.mouse.getPosition()
  -- Camera.zoomAt(state.cam, factor, mx, my)
  -- local w, h = love.graphics.getDimensions()
  -- Camera.clamp(state.cam, w, h)
end
