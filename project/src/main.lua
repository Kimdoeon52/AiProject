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
local DevPopup = require("dev_popup")
local Overlay = require("overlay")

-- 모듈 지역 상태 (전역 아님).
local state = {
  scene = "select",   -- "select" | "map" (군주 선택은 map 씬 위 오버레이 팝업으로)
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
  action = nil,       -- 수행 장수 선택 팝업 종류: nil | "recruit" | "train" (GDD 11장)
  giftAmount = 1,     -- 금 선물 선택 금액(1~goldGiftMax)
  notice = nil,       -- 일시 안내 문구(예: "금 부족") — 표시용
  -- 내정 팝업(GDD 10장). dev_popup.lua 가 읽고/변경한다. draw 는 읽기만.
  devOpen = false,    -- 내정 허브 팝업 열림 여부
  devItem = nil,      -- 투자 서브: nil | "flood" | "loyal" | "commerce" | "land"
  searchOpen = false, -- 인재 탐색/등용 서브 열림 여부
  investAmount = 0,   -- 투자금 슬라이더 값(0~지역 금)
  devPerformerId = nil, -- 선택한 수행 장수 id(없으면 태수/첫 장수 기본)
  rng = nil,          -- 확률 판정용 [0,1) 난수 함수(love.math.random) — game_state 주입용
  -- 흐름 오버레이(overlay.lua). 군주 선택은 지도 위 팝업, ESC 는 게임 메뉴.
  factionSelectOpen = false, -- 군주(세력) 선택 팝업 열림 여부(시나리오 진입 직후)
  factionPending = nil,      -- 군주 선택 중 고른 후보 세력 id(지도 영지 강조 대상)
  menuOpen = false,          -- ESC 게임 메뉴 팝업 열림 여부
  menuExitToMain = false,    -- 메뉴 "메인 화면으로" 요청 플래그(mousepressed 가 리셋 수행)
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
  -- 확률 판정용 난수 함수 주입(love 비의존 규칙 계층에 넘김 — 탐색/등용).
  --   love.math.random(): 인자 없으면 [0,1) 실수. game_state 의 attemptSearch/Recruit 가 rng() 로 호출.
  state.rng = function() return love.math.random() end
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

-- ── 지도 화면 ────────────────────────────────────────────
--   군주(세력) 선택은 별도 화면이 아니라 지도 위 오버레이 팝업(overlay.lua)으로 처리한다.

--- 헥스 지도: ① 채움(시나리오 세력색) → ② 경계 → ②-b 군주후보 강조 → ③ 선택 → ④ 이름.
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

  -- 군주 선택 중 후보 영지 강조(GDD 6장 선택 강조 톤 — 노랑). overlay 가 고른 후보 세력의 소유 지역.
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

--- "내정" 버튼을 만든다(정보 확인 버튼 바로 위). 내정 허브 팝업 열기용(GDD 10장).
-- @return table  UI 버튼
local function devButton()
  local ib = infoCheckButton()
  local gap = 12
  return UI.newButton(ib.x, ib.y - ib.h - gap, ib.w, ib.h, "내정", "dev")
end

--- "훈련" 버튼을 만든다(내정 버튼 바로 위). 수행 장수 선택 팝업 열기용 (GDD 11장).
-- @return table  UI 버튼
local function trainButton()
  local db = devButton()
  local gap = 12
  return UI.newButton(db.x, db.y - db.h - gap, db.w, db.h, "훈련", "train")
end

--- "징병" 버튼을 만든다(훈련 버튼 바로 위) (GDD 11장).
-- @return table  UI 버튼
local function recruitButton()
  local trb = trainButton()
  local gap = 12
  return UI.newButton(trb.x, trb.y - trb.h - gap, trb.w, trb.h, "징병", "recruit")
end

--- 선택 지역이 플레이어 소유인지(내정 버튼 활성 게이팅, GDD 10장 "소유 지역에서").
-- @return boolean
local function selectedOwnedByPlayer()
  return state.selectedId ~= nil
    and state.ownership ~= nil
    and state.ownership[state.selectedId] == state.playerFactionId
end

--- 선택 지역에서 징병/훈련 명령을 줄 수 있는지(버튼 활성 조건). 읽기 전용.
-- 조건: 플레이어 소유 + 그 지역에 이번 턴 행동 가능 장수 1명 이상.
--   "지역당 턴 1회"는 행동 가능 장수가 없으면(모두 actionDone) 비활성으로 충족된다(GDD 11장).
-- @return boolean
local function canCommandSelected()
  if not selectedOwnedByPlayer() then return false end
  -- 지역 내 행동 가능 장수 탐색.
  local here = GameState.officersInRegion(state.officers, state.selectedId)
  for _, o in ipairs(here) do
    if GameState.canAct(o) then return true end
  end
  return false
end

--- 턴 진행에 넘길 컨텍스트(장수 목록 + 미구현 시스템 훅)를 만든다.
-- 아직 없는 시스템(도착·성장·AI·수확)은 로그만 남기는 스텁 콜백으로 둔다.
--   콜백은 game_state.advanceTurn 이 정해진 순서로 호출(시그니처 function(turn, ctx)).
-- @return table  ctx
local function turnContext()
  local ownership = state.ownership -- 정규화된 런타임 소유 맵(세금/수확은 실효 소유 지역만)
  return {
    officers = state.officers, -- 턴 시작 시 행동완료 리셋 대상
    regionState = state.regionState, -- 턴 시작 시 내정(투자/탐색) 턴1회 플래그 리셋 대상(GDD 10장)
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

  -- ① 상단: 시나리오명 + 플레이어 세력명.
  --   날짜(연/월)는 좌상단 헤더 한 곳에만 표시한다(GDD 17장 "상단 좌측 날짜") → 패널에선 뺀다.
  --   금은 지역별 보유(GDD 9장)라 지역 정보 팝업에서 본다 → 패널 상단 금 표기 없음.
  love.graphics.setColor(config.colors.text)
  love.graphics.print(state.scenario.name, x, y)
  y = y + gap
  local pf = state.playerFactionId and state.scenario.factions[state.playerFactionId]
  if pf then
    love.graphics.print("세력: " .. pf.name, x, y); y = y + gap
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

  -- "내정" 버튼: 선택 지역이 플레이어 소유일 때만 활성(GDD 10장 "소유 지역에서").
  local dev = devButton()
  if selectedOwnedByPlayer() then
    UI.draw(dev, { hovered = UI.hit(dev, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(dev, DISABLED)
  end

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

  -- 징병·훈련 버튼: 플레이어 소유 + 행동 가능 장수 있을 때만 활성 (GDD 11장).
  local canCmd = canCommandSelected()
  local rec = recruitButton()
  local trn = trainButton()
  if canCmd then
    UI.draw(rec, { hovered = UI.hit(rec, mx, my), accent = config.colors.selectBorder })
    UI.draw(trn, { hovered = UI.hit(trn, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(rec, DISABLED) -- 비소유/미선택/행동 가능 장수 없음 → 비활성
    UI.draw(trn, DISABLED)
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

  -- 오버레이(화면 고정): 좌상단 헤더(현재 연/월 — GDD 17장 "상단 좌측 날짜") + 범례.
  love.graphics.setColor(config.colors.text)
  local t = state.turn
  local head = string.format("%d년 %d월  ·  %s  ·  Esc=메뉴", t.year, t.month, state.scenario.name)
  love.graphics.print(head, 16, 16)
  drawLegend()
  -- 군주 선택 중(pre-game)에는 패널 명령/턴 버튼을 숨긴다 — 아직 게임 시작 전.
  if not state.factionSelectOpen then
    drawPanel() -- 우측 패널(시나리오·세력 + 선택 지역 정보 + 명령/턴 버튼)
    -- 팝업(장수 목록/상세/선물)은 패널 위에 모달로 덮어 그린다.
    Popup.draw(state)
    -- 내정 팝업(허브/투자/탐색·등용)도 모달로 덮어 그린다(GDD 10장).
    DevPopup.draw(state)
  end
  -- 흐름 오버레이(군주 선택 / ESC 메뉴)는 최상단 모달로 덮어 그린다.
  Overlay.draw(state)
end

-- ── draw 디스패치 ────────────────────────────────────────

--- 매 프레임 화면을 그린다. 현재 scene 에 따라 선택/지도 화면으로 분기. (읽기 전용)
function love.draw()
  -- love.graphics.setFont(font): 이후 텍스트 기본 폰트 지정.
  love.graphics.setFont(state.font)
  if state.scene == "select" then
    drawSelect()
  else
    drawMap() -- 군주 선택은 지도 위 오버레이 팝업(overlay.lua)으로 처리
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
  -- 지도 씬으로 진입하되, 군주(세력) 선택 팝업을 띄운다(GDD 3장 흐름 2번 — 지도 보며 영지 확인).
  --   확정 전까지 playerFactionId 는 nil. overlay 가 확정 시 설정한다.
  state.playerFactionId = nil
  state.factionSelectOpen = true
  state.factionPending = nil
  state.scene = "map"
  refitCamera() -- 지도 진입 시 fit/중앙 맞춤
end

--- 게임을 접고 시나리오 선택(메인)으로 되돌린다. (ESC 메뉴 "메인 화면으로")
-- 부작용: 진행 상태/플래그 초기화 + 씬 전환.
local function resetToMain()
  state.scene = "select"
  state.playerFactionId = nil
  state.factionSelectOpen = false
  state.factionPending = nil
  state.menuOpen = false
  state.menuExitToMain = false
  state.selectedId = nil
  -- 열려 있던 팝업/누름 상태도 정리(다음 게임에 잔재 안 남게).
  state.listOpen, state.regionInfoOpen, state.detailId, state.sub = false, false, nil, nil
  state.devOpen, state.devItem, state.searchOpen = false, nil, false
  state.press = nil
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

  -- 지도: 흐름 오버레이(군주 선택 / ESC 메뉴)가 열려 있으면 최우선 모달로 소비.
  if Overlay.consumeClick(state, x, y) then
    if state.menuExitToMain then resetToMain() end -- 메뉴 "메인 화면으로" 요청 처리
    return
  end
  -- 팝업이 열려 있으면 팝업이 클릭을 먼저 소비(모달).
  if Popup.consumeClick(state, x, y) then return end
  -- 내정 팝업(허브/투자/탐색·등용)도 모달 — 열려 있으면 먼저 소비.
  if DevPopup.consumeClick(state, x, y) then return end

  -- 최하단 턴 버튼(누른 즉시 실행).
  if UI.hit(turnButton(), x, y) then
    advanceGameTurn()
    return
  end

  -- "내정" 버튼(선택 지역이 플레이어 소유일 때만) → 내정 허브 팝업 열기.
  if selectedOwnedByPlayer() and UI.hit(devButton(), x, y) then
    state.devOpen = true
    state.notice = nil
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

  -- "징병"·"훈련" 버튼(명령 가능 지역에서만) → 수행 장수 선택 팝업 열기 (GDD 11장).
  if canCommandSelected() then
    if UI.hit(recruitButton(), x, y) then
      state.action = "recruit"; state.listOpen = false; state.detailId = nil; state.notice = nil
      return
    end
    if UI.hit(trainButton(), x, y) then
      state.action = "train"; state.listOpen = false; state.detailId = nil; state.notice = nil
      return
    end
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
    -- ESC 우선순위(GDD 17장): 군주 선택 중이면 시나리오 선택으로 → 다른 팝업이 열렸으면
    --   그 팝업부터 한 겹씩 닫기 → 메뉴가 열렸으면 닫기(계속) → 아무것도 없으면 게임 메뉴 열기.
    if state.factionSelectOpen then
      -- 아직 게임 시작 전(군주 미확정) → 시나리오 선택으로 되돌림.
      resetToMain()
    elseif state.sub then
      state.sub = nil; state.notice = nil
    elseif state.action then
      state.action = nil; state.notice = nil -- 수행 장수 선택 팝업 닫기 (GDD 11장)
    elseif state.detailId then
      state.detailId = nil
    elseif state.listOpen then
      state.listOpen = false
    elseif state.regionInfoOpen then
      state.regionInfoOpen = false -- 지역 정보 팝업 닫기(독립 모달)
    elseif state.devItem then
      state.devItem = nil; state.notice = nil  -- 투자 서브 → 내정 허브로
    elseif state.searchOpen then
      state.searchOpen = false; state.notice = nil -- 탐색·등용 서브 → 닫기
    elseif state.devOpen then
      state.devOpen = false -- 내정 허브 닫기
    elseif state.menuOpen then
      state.menuOpen = false -- 게임 메뉴 닫기(계속 진행)
    else
      -- 다른 팝업이 하나도 없을 때만 ESC 가 게임 메뉴를 연다([계속]/[메인]).
      state.menuOpen = true
    end
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
