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
local GameState = require("game_state")
local Camera = require("camera")
local Region = require("region")
local Hex = require("hex")
local UI = require("ui")
local Popup = require("popup")

-- 모듈 지역 상태 (전역 아님).
local state = {
  scene = "select",   -- "select" | "faction" | "map"
  scenario = nil,     -- 선택된 시나리오 레코드(game_data.scenarios 의 한 항목)
  regions = nil,      -- 지역(헥스) 데이터
  centers = nil,      -- [id] = {x,y} 헥스 중심 픽셀 (캐시)
  corners = nil,      -- [id] = {x1,y1,...} 헥스 6꼭짓점 (캐시)
  cam = nil,
  font = nil,
  titleFont = nil,    -- 선택 화면 제목용 큰 폰트
  selectedId = nil,
  turn = nil,         -- 턴 상태 { year, month, count } (GameState.newTurn)
  officers = nil,     -- 런타임 장수 배열(GameState.buildOfficers). 턴 리셋 대상.
  -- 플레이어(군주) 정보 — 세력 선택 후 확정.
  playerFactionId = nil, -- 플레이어 세력 id (흰 테두리·선물 게이팅 기준)
  regionState = nil,     -- 런타임 지역상태 맵 { [id]={금·군량·내부수치} } (GameState.buildRegions)
  ownership = nil,       -- 런타임 소유 맵 { [regionId]=fid } (정규화 복사본, GameState.normalizeOwnership)
  governors = nil,       -- 태수 맵 { [regionId]=officerId } (GameState.assignGovernors)
  factionInventory = nil,-- 세력별 미장착 장비고 { [fid]={장비,...} } (장비 선물 대상)
  -- 팝업 UI 상태(지도 화면). draw 는 읽기만, 변경은 입력 콜백.
  listOpen = false,   -- 장수 목록 팝업 열림 여부
  regionInfoOpen = false, -- 지역 정보 팝업 열림 여부(GDD 17장)
  detailId = nil,     -- 상세 보는 장수 id (nil=목록만)
  sub = nil,          -- 서브 팝업: nil | "gold" | "equip"
  giftAmount = 1,     -- 금 선물 선택 금액(1~goldGiftMax)
  notice = nil,       -- 일시 안내 문구(예: "금 부족") — 표시용
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
  -- 소유 조회는 정규화된 런타임 맵(state.ownership) 기준 — 중립 강등이 색에 반영된다(GDD 6장).
  if sc and state.ownership then
    local fid = state.ownership[r.id]
    local f = fid and sc.factions[fid]
    if f then return f.color end
  end
  return config.colors.neutral
end

--- 지역 소유 세력의 표시 이름(없으면 "중립").
local function regionFactionName(r)
  local sc = state.scenario
  local fid = state.ownership and state.ownership[r.id]
  local f = (sc and fid) and sc.factions[fid]
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
  -- 버튼 폭/높이/간격(px). 화면 가로 중앙 + 세로 가운데 정렬에 사용.
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

--- 시나리오 선택 화면을 그린다. (읽기 전용)
-- 제목 → 시나리오 버튼들(마우스 hover 강조) → 하단 안내.
-- 부작용 없음(상태 변경은 입력 콜백에서). 버튼 레이아웃은 buildScenarioButtons 공유.
local function drawSelect()
  local w = love.graphics.getWidth()
  love.graphics.clear(config.colors.background)

  -- 제목 (큰 폰트). y=90 = 상단 여백.
  love.graphics.setFont(state.titleFont)
  love.graphics.setColor(config.colors.text)
  love.graphics.printf("삼국 패권 — 시나리오 선택", 0, 90, w, "center")

  -- 버튼들. 커서가 버튼 위면(UI.hit) hover 강조로 그린다.
  love.graphics.setFont(state.font)
  -- love.mouse.getPosition(): 현재 커서 스크린 좌표. hover 판정용.
  local mx, my = love.mouse.getPosition()
  for _, btn in ipairs(buildScenarioButtons()) do
    UI.draw(btn, { hovered = UI.hit(btn, mx, my), accent = config.colors.selectBorder })
  end

  -- 하단 안내. 화면 바닥에서 60px 위.
  love.graphics.setColor(config.colors.text)
  love.graphics.printf("시나리오를 클릭해 시작", 0, love.graphics.getHeight() - 60, w, "center")
end

-- ── 세력(군주) 선택 화면 ─────────────────────────────────

--- 장수 베이스에서 id 로 이름을 찾는다(군주 이름 표시용 헬퍼).
-- @param id string
-- @return string  이름(없으면 id 그대로)
local function officerBaseName(id)
  for _, o in ipairs(game_data.officers) do
    if o.id == id then return o.name end
  end
  return id
end

--- 현재 시나리오의 세력을 표시 순서가 안정적인 배열로 만든다.
-- factions 는 id 키 테이블(순회 순서 비결정) → id 기준 정렬로 매번 같은 순서 보장.
-- @return table  { {id=, faction=}, ... }
local function sortedFactions()
  local list = {}
  for fid, f in pairs(state.scenario.factions) do
    list[#list + 1] = { id = fid, faction = f }
  end
  -- table.sort(t, cmp): 제자리 정렬. cmp(a,b)=a가 b보다 앞이면 true.
  --   (C# List.Sort(Comparison) / C++ std::sort 와 같은 개념)
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

--- 세력 선택 버튼 목록을 만든다. (draw·입력 공유 레이아웃)
-- @return table  UI 버튼 배열(value = 세력 id)
local function buildFactionButtons()
  local w, h = love.graphics.getDimensions()
  local list = sortedFactions()
  local bw, bh, gap = 620, 56, 14
  local n = #list
  local totalH = n * bh + (n - 1) * gap
  local x = (w - bw) / 2
  local y0 = h / 2 - totalH / 2 + 40
  local btns = {}
  for i, item in ipairs(list) do
    -- 라벨: "세력명 — 군주: 군주명". 군주=세력 lord 장수.
    local label = string.format("%s   —   군주: %s", item.faction.name, officerBaseName(item.faction.lord))
    btns[i] = UI.newButton(x, y0 + (i - 1) * (bh + gap), bw, bh, label, item.id)
  end
  return btns
end

--- 세력 선택 화면을 그린다. (읽기 전용)
local function drawFactionSelect()
  local w = love.graphics.getWidth()
  love.graphics.clear(config.colors.background)

  love.graphics.setFont(state.titleFont)
  love.graphics.setColor(config.colors.text)
  love.graphics.printf(state.scenario.name .. " — 세력 선택", 0, 70, w, "center")

  love.graphics.setFont(state.font)
  local mx, my = love.mouse.getPosition()
  for _, btn in ipairs(buildFactionButtons()) do
    local hovered = UI.hit(btn, mx, my)
    -- 세력색 견본을 버튼 왼쪽에 칠해 색 구분(GDD 6장).
    local f = state.scenario.factions[btn.value]
    UI.draw(btn, { hovered = hovered, accent = config.colors.selectBorder })
    love.graphics.setColor(f.color)
    love.graphics.rectangle("fill", btn.x + 10, btn.y + btn.h / 2 - 10, 20, 20, 3, 3)
  end

  love.graphics.setColor(config.colors.text)
  love.graphics.printf("플레이할 세력을 클릭   ·   Esc=시나리오로", 0, love.graphics.getHeight() - 60, w, "center")
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

--- 좌상단 세력 범례(시나리오 세력 색 견본 + 이름)를 그린다.
-- @side 부작용 없음(읽기 전용).
local function drawLegend()
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

-- ── 우측 패널 + 턴 버튼 (GDD 17장) ───────────────────────

--- 우측 패널의 화면 사각형(스크린 좌표)을 계산한다.
-- 화면 오른쪽에 세로로 꽉 차는 고정 패널. 클릭이 패널 위인지 판정에도 쓴다.
-- @return number,number,number,number  x, y, w, h
local function panelRect()
  local sw, sh = love.graphics.getDimensions()
  local w = config.panel.width
  return sw - w, 0, w, sh
end

--- 최하단 턴 버튼을 만든다(패널 레이아웃 기준). draw·클릭에서 같은 버튼 공유.
-- @return table  UI 버튼 레코드(라벨 = 다음 진행 안내)
local function turnButton()
  local px, _, pw = panelRect()
  local sh = love.graphics.getHeight()
  local m, bh = config.panel.buttonMargin, config.panel.buttonHeight
  local x = px + m
  local y = sh - m - bh          -- 패널 하단에서 margin 만큼 위
  local w = pw - m * 2
  return UI.newButton(x, y, w, bh, "턴 종료 ▶ (다음 달)", "endturn")
end

--- "장수 확인" 버튼을 만든다(턴 버튼 바로 위). draw·클릭 공유 레이아웃.
-- @return table  UI 버튼
local function officerCheckButton()
  local tb = turnButton()
  local gap = 12
  -- 턴 버튼 위에 한 칸. 같은 폭/높이.
  return UI.newButton(tb.x, tb.y - tb.h - gap, tb.w, tb.h, "장수 확인", "officers")
end

--- "정보 확인" 버튼을 만든다(장수 확인 버튼 바로 위). 선택 지역 상세 팝업 열기용.
-- @return table  UI 버튼
local function infoCheckButton()
  local ob = officerCheckButton()
  local gap = 12
  return UI.newButton(ob.x, ob.y - ob.h - gap, ob.w, ob.h, "정보 확인", "info")
end

--- 턴 진행에 넘길 컨텍스트(장수 목록 + 미구현 시스템 훅)를 만든다.
-- 아직 없는 시스템(도착·성장·AI·수확)은 로그만 남기는 스텁 콜백으로 둔다.
--   콜백은 game_state.advanceTurn 이 정해진 순서로 호출(시그니처 function(turn, ctx)).
-- @return table  ctx
local function turnContext()
  local ownership = state.ownership -- 정규화된 런타임 소유 맵(세금/수확은 실효 소유 지역만)
  return {
    officers = state.officers, -- 턴 시작 시 행동완료 리셋 대상
    -- print(): 콘솔(터미널) 출력. love.graphics.print(화면 그리기)와 다름.
    --   lovec(콘솔판)에서 보임 → 턴/수확 진행 확인용.
    onTurnEnd = function(t) print(string.format("[턴] %d년 %d월 종료 (턴 #%d)", t.year, t.month, t.count)) end,
    -- 세금·군량·인구 성장 단계(GDD 9장): 소유 지역마다 세금을 그 지역 금에 가산.
    --   규칙은 game_state.collectTaxes 가 수행(태수 정치 반영). 여기선 호출만.
    onGrowth = function()
      local total = GameState.collectTaxes(state.regionState, state.governors, state.officers, ownership)
      print(string.format("[세금] 소유 지역 총 징수 %d금", total))
    end,
    -- 7월 수확 훅(GDD 9장): 소유 지역마다 수확 군량을 그 지역 군량에 가산.
    onHarvest = function(t)
      local total = GameState.harvestAll(state.regionState, state.governors, state.officers, ownership)
      print(string.format("[수확] %d년 %d월 — 소유 지역 총 수확 %d군량", t.year, t.month, total))
    end,
    -- onArrivals / onAI 는 아직 미정 → 생략(=빈 스텁). 시스템 생기면 끼운다.
  }
end

--- 턴을 한 칸 진행한다(버튼 클릭 시). 규칙은 game_state 가 담당.
-- 부작용: state.turn(연/월/카운트) 변경, 장수 행동완료 리셋.
local function advanceGameTurn()
  GameState.advanceTurn(state.turn, turnContext())
end

--- 우측 정보 패널을 그린다. (읽기 전용)
-- 상단: 현재 연/월 → 그 아래 선택 지역 정보 → 최하단 턴 버튼.
local function drawPanel()
  local px, py, pw, ph = panelRect()

  -- 패널 배경(반투명). setColor 4번째 인자 = 알파.
  love.graphics.setColor(config.panel.bg)
  love.graphics.rectangle("fill", px, py, pw, ph)

  local x = px + config.panel.pad
  local y = py + config.panel.pad
  local textW = pw - config.panel.pad * 2
  local gap = config.panel.lineGap

  -- ① 상단: 현재 연/월 (GDD 17장 날짜).
  love.graphics.setColor(config.colors.text)
  local t = state.turn
  love.graphics.print(string.format("%d년 %d월", t.year, t.month), x, y)
  y = y + gap
  love.graphics.print(state.scenario.name, x, y)
  y = y + gap
  -- 플레이어 세력명 + 군주 금 보유고(GDD 9장).
  local pf = state.playerFactionId and state.scenario.factions[state.playerFactionId]
  if pf then
    love.graphics.print("세력: " .. pf.name, x, y); y = y + gap
    -- 금은 지역별 보유(GDD 9장). 패널엔 "군주가 위치한 지역의 금"(선물이 차감하는 풀)을 표시.
    local lordRid = GameState.lordRegionId(state.officers, state.playerFactionId, state.scenario)
    local lordRegion = lordRid and state.regionState[lordRid]
    love.graphics.print("금(군주 소재): " .. (lordRegion and lordRegion.gold or 0), x, y); y = y + gap
  end
  y = y + 6

  -- 구분선
  love.graphics.setColor(0.3, 0.32, 0.38)
  love.graphics.setLineWidth(1)
  love.graphics.line(x, y, x + textW, y)
  y = y + 10

  -- ② 선택 지역 정보(있으면).
  love.graphics.setColor(config.colors.text)
  local sel = state.selectedId and Region.byId(state.regions, state.selectedId) or nil
  if sel then
    love.graphics.print(sel.name, x, y); y = y + gap
    love.graphics.print("소유: " .. regionFactionName(sel), x, y); y = y + gap
    -- 이 지역 장수 수(어제 작업 연결). state.officers 가 있을 때만.
    if state.officers then
      local here = GameState.officersInRegion(state.officers, sel.id)
      love.graphics.print("장수: " .. #here .. "명", x, y); y = y + gap
    end
  else
    love.graphics.setColor(0.7, 0.72, 0.78)
    love.graphics.print("지역을 클릭해 선택", x, y)
  end

  -- ③ 하단 버튼들: "정보 확인"·"장수 확인"(선택 지역 있을 때만 활성) + "턴 종료".
  local mx, my = love.mouse.getPosition()
  local DISABLED = { text = { 0.5, 0.52, 0.58 }, border = { 0.3, 0.31, 0.36 } }

  local info = infoCheckButton()
  if state.selectedId then
    UI.draw(info, { hovered = UI.hit(info, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(info, DISABLED) -- 선택 지역 없으면 비활성(클릭은 입력에서 무시)
  end

  local chk = officerCheckButton()
  if state.selectedId then
    UI.draw(chk, { hovered = UI.hit(chk, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(chk, DISABLED)
  end

  local btn = turnButton()
  UI.draw(btn, { hovered = UI.hit(btn, mx, my), accent = config.colors.selectBorder })
end

--- 지도 화면을 그린다. (읽기 전용)
-- 카메라 변환(scale→translate) 안에서 헥스 지도 → 변환 밖에서 화면 고정 오버레이
-- (시나리오/선택 정보 + 세력 범례).
local function drawMap()
  love.graphics.clear(config.colors.background)
  local cam = state.cam
  love.graphics.push()
  love.graphics.scale(cam.scale, cam.scale)
  love.graphics.translate(-cam.x, -cam.y)
  drawHexMap()
  love.graphics.pop()

  -- 오버레이(화면 고정): 좌상단 헤더 + 범례 + 우측 정보 패널.
  love.graphics.setColor(config.colors.text)
  local head = string.format("%s (%d년)  ·  Esc=시나리오 선택", state.scenario.name, state.scenario.year)
  love.graphics.print(head, 16, 16)
  drawLegend()
  -- 우측 패널(연/월 + 선택 지역 정보 + 턴 버튼). 선택 지역 표시는 여기로 통합.
  drawPanel()
  -- 팝업(장수 목록/상세/선물)은 패널 위에 모달로 덮어 그린다.
  Popup.draw(state)
end

-- ── draw 디스패치 ────────────────────────────────────────

--- 매 프레임 화면을 그린다. 현재 scene 에 따라 선택/지도 화면으로 분기. (읽기 전용)
function love.draw()
  -- love.graphics.setFont(font): 이후 텍스트 기본 폰트 지정.
  love.graphics.setFont(state.font)
  if state.scene == "select" then
    drawSelect()
  elseif state.scene == "faction" then
    drawFactionSelect()
  else
    drawMap()
  end
end

-- ── 입력 ─────────────────────────────────────────────────

--- 시나리오를 골라 지도 화면으로 전환.
-- @param idx number  game_data.scenarios 인덱스
-- 태수 동률 선정용 rng. love.math.random(n): 1..n 정수(시드 있는 LÖVE 난수).
--   game_state 는 love 비의존이라 rng 를 "주입"받는다(테스트는 고정 rng 사용).
local function rng(n) return love.math.random(n) end

local function startScenario(idx)
  state.scenario = game_data.scenarios[idx]
  state.selectedId = nil
  -- 턴 상태(시작 연/월) + 런타임 장수 구성.
  state.turn = GameState.newTurn(state.scenario)
  state.officers = GameState.buildOfficers(game_data, state.scenario)
  -- 소유↔배치 정합성 정규화(GDD 6장): active 0명 소유 지역은 중립으로 강등한 "복사본"을 쓴다.
  --   game_data 원본 불변 — 런타임 소유는 state.ownership 가 진실원본이 된다.
  local ownership, demoted = GameState.normalizeOwnership(state.scenario, state.officers)
  state.ownership = ownership
  -- 강등(중립 전환)된 지역을 콘솔에 한 줄씩 남긴다(왜 중립이 됐는지 추적용).
  for _, d in ipairs(demoted) do
    print(string.format("[정합성] 지역 '%s' active 0명 → 세력 '%s' 소유 해제(중립)", d.region, d.faction))
  end
  -- 런타임 지역상태(금·군량 보유) 구성 — 금 진실원본 = 지역별(GDD 9장).
  state.regionState = GameState.buildRegions(game_data, state.scenario)
  -- 초기 장비 적용(군주 귀속 미장착 장비고) + 지역별 태수 자동 선정(GDD 5·8장).
  --   정규화 뒤에 태수를 뽑으므로, 중립 강등된 빈 지역은 assignGovernor 가 nil 반환(태수 자동 해제).
  state.factionInventory = GameState.applyInitialEquipment(game_data, state.scenario, state.officers)
  state.governors = GameState.assignGovernors(state.regions, state.officers, rng)
  -- 시나리오 진입 후엔 "세력(군주) 선택" 단계로(GDD 3장 흐름 2번).
  state.scene = "faction"
end

--- 플레이할 세력(군주)을 확정하고 지도로 진입한다.
-- 군주 = 그 세력의 lord 장수(GDD 7장). 별도 타입 없이 세력 id 로 플레이어를 표시.
-- 부작용: playerFactionId/gold 설정, 씬 전환, 카메라 재적합.
-- @param factionId string  선택한 세력 id
local function chooseFaction(factionId)
  state.playerFactionId = factionId
  -- 금은 지역별 보유가 진실원본(GDD 9장) → 군주 금고 placeholder 없음.
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

  if state.scene == "faction" then
    -- 세력(군주) 선택: 버튼 클릭 → 플레이어 세력 확정 후 지도로.
    for _, btn in ipairs(buildFactionButtons()) do
      if UI.hit(btn, x, y) then
        chooseFaction(btn.value)
        return
      end
    end
    return
  end

  -- 지도: 팝업이 열려 있으면 팝업이 클릭을 먼저 소비(모달).
  if Popup.consumeClick(state, x, y) then return end

  -- 최하단 턴 버튼(누른 즉시 실행).
  if UI.hit(turnButton(), x, y) then
    advanceGameTurn()
    return
  end

  -- "정보 확인" 버튼(선택 지역 있을 때만) → 지역 정보 팝업 열기.
  if state.selectedId and UI.hit(infoCheckButton(), x, y) then
    state.regionInfoOpen = true
    return
  end

  -- "장수 확인" 버튼(선택 지역 있을 때만) → 목록 팝업 열기.
  if state.selectedId and UI.hit(officerCheckButton(), x, y) then
    state.listOpen = true
    state.detailId = nil
    state.sub = nil
    return
  end

  -- 누름 기록(클릭/드래그는 이동량으로 판정).
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

  -- 누른 지점이 우측 패널 위면 지도 선택 안 함(패널이 지도를 가린다).
  local px, py, pw, ph = panelRect()
  if p.x >= px and p.x <= px + pw and p.y >= py and p.y <= py + ph then
    return
  end

  local wx, wy = Camera.screenToWorld(state.cam, p.x, p.y)
  local hit = Region.cellAt(state.regions, wx, wy, config.map.hexSize)
  if hit then state.selectedId = hit.id end
end

--- 키 입력. 지도에서 Esc → 시나리오 선택으로 복귀.
-- @param key string
function love.keypressed(key)
  if key ~= "escape" then return end

  if state.scene == "map" then
    -- 팝업이 열려 있으면 안쪽(서브팝업)부터 한 겹씩 닫는다(GDD 17장 ESC).
    if state.sub then
      state.sub = nil; state.notice = nil
    elseif state.detailId then
      state.detailId = nil
    elseif state.listOpen then
      state.listOpen = false
    elseif state.regionInfoOpen then
      state.regionInfoOpen = false -- 지역 정보 팝업 닫기(독립 모달)
    else
      -- 팝업이 없으면 지도 → 시나리오 선택으로(상태 초기화).
      state.scene = "select"
      state.selectedId = nil
      state.playerFactionId = nil
      state.press = nil
    end
  elseif state.scene == "faction" then
    state.scene = "select" -- 세력 선택 → 시나리오 선택으로
  else
    love.event.quit() -- 선택 화면에서 Esc → 종료
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
