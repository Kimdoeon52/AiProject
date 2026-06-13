--[[
dev_popup.lua — 내정(투자/인재 탐색·등용) 모달 팝업 (표현·입력 보조)

  이 모듈의 책임:
    - 지도 화면 위에 뜨는 "내정 팝업"의 렌더(draw)와 클릭 처리(consumeClick)를 담당.
    - 레이어(앞→뒤): 투자 서브 / 인재 탐색 서브  >  내정 허브.
  관계:
    - main.lua : 지도 draw 끝에서 DevPopup.draw(state),
                 mousepressed 에서 DevPopup.consumeClick(state,x,y) 호출(popup.lua 와 같은 패턴).
    - develop.lua : 내정 규칙(canInvest/applyInvest, canSearch/attemptSearch, canRecruit/attemptRecruit, DEV_ITEMS).
    - game_state.lua : 장수 상태/행동 규칙(STATE, canAct, byId).
    - ui.lua / config : 버튼 렌더·클릭, 상수.
  설계:
    - popup.lua 가 545줄이라 내정 UI 를 합치면 800줄(CLAUDE.md) 초과 → "한 모듈 한 책임"으로 분리.
    - 규칙(금 차감·수치 상승·확률 판정)은 develop 가 수행. 이 모듈은 결과를 state 에 반영만 한다.
    - draw 는 읽기만(상태 변경 X). 모든 계산/상태변경은 consumeClick 에서 develop/game_state 호출로만.

  state 의존 필드(주입):
    devOpen(허브 열림), devItem("flood"|"loyal"|"commerce"|"land" 투자 서브), searchOpen(탐색 서브),
    investAmount(슬라이더 투자금), devPerformerId(선택한 수행 장수 id), notice(결과/안내 문구),
    selectedId, officers, regions, scenario, playerFactionId, regionState, governors
--]]

local config = require("config")
local UI = require("ui")
local GameState = require("game_state")
local Develop = require("develop")

local DevPopup = {}

-- 빨간색 "비활성"(수행 완료) 버튼 스타일 (GDD 10장). border=빨강, 글자=옅은 빨강.
local DEV_DONE = { border = config.colors.devDone, text = { 0.85, 0.55, 0.55 } }
-- 회색 비활성(조건 미충족: 금 부족/수행 장수 없음 등).
local DISABLED = { text = { 0.5, 0.52, 0.58 }, border = { 0.3, 0.31, 0.36 } }

-- 투자 항목 키 → 그 지역 내부수치를 읽을 때 같이 쓰는 라벨(허브/서브 제목용).
--   Develop.DEV_ITEMS 가 순서·라벨의 단일 출처 → 여기선 key→label 룩업만 만든다.
local ITEM_LABEL = {}
for _, it in ipairs(Develop.DEV_ITEMS) do ITEM_LABEL[it.key] = it.label end

-- ── 공통 레이아웃(순수 좌표) ─────────────────────────────

--- 화면 중앙 팝업 사각형(스크린 좌표). popup.lua 와 동일 규격(config.popup).
local function popupRect()
  local sw, sh = love.graphics.getDimensions()
  local w, h = config.popup.width, config.popup.height
  return (sw - w) / 2, (sh - h) / 2, w, h
end

--- 우상단 X(닫기) 버튼.
local function closeButton(px, py, pw)
  local s = config.popup.closeSize
  return UI.newButton(px + pw - s - 10, py + 10, s, s, "X", "close")
end

-- ── 조회 헬퍼 ────────────────────────────────────────────

--- 선택된 지역 id(내정은 항상 선택 지역 대상). 없으면 nil.
local function regionId(state) return state.selectedId end

--- 선택 지역의 런타임 지역 레코드(금·내부수치·devDone/searchDone). 없으면 nil.
local function curRegion(state)
  local rid = regionId(state)
  return rid and state.regionState and state.regionState[rid] or nil
end

--- 이 지역의 active 장수 목록(수행 장수 후보). 소유 지역이면 전부 플레이어 세력 소속이다.
-- @return table  active 장수 배열
local function activeHere(state, rid)
  local out = {}
  for _, o in ipairs(state.officers or {}) do
    if o.region == rid and o.state == GameState.STATE.active then out[#out + 1] = o end
  end
  return out
end

--- 현재 선택된 "수행 장수"를 정한다.
--   ① state.devPerformerId 가 아직 이 지역 active 면 그 장수.
--   ② 없으면 태수(governor)가 이 지역 active 면 태수.
--   ③ 그래도 없으면 목록 첫 장수. (목록이 비면 nil)
-- 호출 위치: draw·consumeClick 양쪽(같은 결과 보장).
local function performerOf(state, rid)
  local list = activeHere(state, rid)
  if state.devPerformerId then
    for _, o in ipairs(list) do if o.id == state.devPerformerId then return o end end
  end
  local gid = state.governors and state.governors[rid]
  if gid then
    for _, o in ipairs(list) do if o.id == gid then return o end end
  end
  return list[1]
end

--- 투자금을 0~지역 금 범위로 클램프하고 정수화.
local function clampAmount(amount, maxCost)
  return math.floor(math.max(0, math.min(maxCost, amount or 0)))
end

-- ── 내정 허브 레이아웃 ───────────────────────────────────
--   5개 명령 버튼(치수/민충성/상업/토지 투자 + 인재 탐색) 세로 배치.

--- 허브 버튼 레이아웃을 만든다(draw·클릭 공유 단일 출처).
-- @return table { items = { {btn, key} ... }, search = btn, close = btn }
local function hubLayout(px, py, pw, ph)
  local pad, bh = config.popup.pad, config.popup.buttonHeight
  local x, w = px + pad, pw - pad * 2
  local y0 = py + pad + 50
  local gap = 12
  local items = {}
  for i, it in ipairs(Develop.DEV_ITEMS) do
    local b = UI.newButton(x, y0 + (i - 1) * (bh + gap), w, bh, it.label .. " 투자", it.key)
    items[i] = { btn = b, key = it.key }
  end
  -- 인재 탐색 버튼은 투자 4개 아래.
  local searchBtn = UI.newButton(x, y0 + #Develop.DEV_ITEMS * (bh + gap), w, bh, "인재 탐색", "search")
  return { items = items, search = searchBtn, close = closeButton(px, py, pw) }
end

--- 내정 허브 본문.
local function drawHub(state, px, py, pw, ph)
  local region = curRegion(state)
  if not region then return end
  local mx, my = love.mouse.getPosition()
  love.graphics.setColor(config.colors.text)
  love.graphics.print(region.name .. " 내정", px + config.popup.pad, py + config.popup.pad)

  local L = hubLayout(px, py, pw, ph)
  -- 투자 버튼: 이번 턴 이미 투자한 항목이면 빨간 비활성(GDD 10장).
  for _, item in ipairs(L.items) do
    if region.devDone[item.key] then
      item.btn.label = ITEM_LABEL[item.key] .. " 투자 (완료)"
      UI.draw(item.btn, DEV_DONE)
    else
      UI.draw(item.btn, { hovered = UI.hit(item.btn, mx, my), accent = config.colors.selectBorder })
    end
  end
  -- 인재 탐색 버튼: 이번 턴 이미 탐색했으면 빨간 비활성.
  if region.searchDone then
    L.search.label = "인재 탐색 (완료)"
    UI.draw(L.search, DEV_DONE)
  else
    UI.draw(L.search, { hovered = UI.hit(L.search, mx, my), accent = config.colors.selectBorder })
  end
  UI.draw(L.close, { hovered = UI.hit(L.close, mx, my), accent = config.colors.selectBorder })
end

-- ── 수행 장수 선택 행(투자/탐색 공용) ────────────────────

--- 수행 장수 선택 버튼 목록을 만든다. 선택된 장수는 강조, 행동 소진 장수는 표시.
-- @param startY number  첫 행 y
-- @return table rows( {btn, officer} ), number nextY  (다음 콘텐츠 시작 y)
local function performerRows(state, rid, px, pw, startY)
  local pad = config.popup.pad
  local x, w = px + pad, pw - pad * 2
  local rh, rg = 30, 4
  local rows, y = {}, startY
  for i, o in ipairs(activeHere(state, rid)) do
    -- 라벨: "이름 (정치 NN)" + 행동 소진이면 "[소진]".
    local label = string.format("%s (정치 %d)%s", o.name, o.pol or 0,
      GameState.canAct(o) and "" or "  [행동 소진]")
    rows[i] = { btn = UI.newButton(x, y, w, rh, label, o.id), officer = o }
    y = y + rh + rg
  end
  return rows, y
end

--- 수행 장수 선택 행을 그린다(선택된 장수는 노랑 강조 테두리).
local function drawPerformerRows(rows, performer)
  local mx, my = love.mouse.getPosition()
  for _, r in ipairs(rows) do
    local selected = performer and r.officer.id == performer.id
    -- 선택 = 항상 강조 테두리, 미선택 = hover 시 강조.
    UI.draw(r.btn, {
      hovered = selected or UI.hit(r.btn, mx, my),
      accent = config.colors.selectBorder,
      text = GameState.canAct(r.officer) and { 0.95, 0.95, 0.95 } or { 0.6, 0.62, 0.66 },
    })
  end
end

-- ── 투자 서브 레이아웃 ───────────────────────────────────

-- 투자 서브에서 수행 장수 행이 시작되는 y(제목·수치줄·안내줄 3줄 + 여백 아래).
--   draw 와 click 이 똑같이 계산하도록 한 곳에 둔다(레이아웃 단일 출처).
local function investPerfStartY(py)
  return py + config.popup.pad + config.popup.lineGap * 3 + 6
end

--- 투자 서브 팝업 전체 레이아웃(수행 장수 행 + 슬라이더·−/+·최대·확정). draw·클릭 공유.
-- @return table { performers={rows}, track, minus, plus, max, confirm, close }
local function investLayout(state, px, py, pw, ph)
  local pad, bh = config.popup.pad, config.popup.buttonHeight
  local x, w = px + pad, pw - pad * 2
  local performers = performerRows(state, regionId(state), px, pw, investPerfStartY(py))
  local confirm = UI.newButton(x, py + ph - pad - bh, w, bh, "확정", "confirm")
  -- −/+/최대 행은 확정 위.
  local rowY = confirm.y - 12 - bh
  local minus = UI.newButton(x, rowY, 64, bh, "−", "minus")
  local plus = UI.newButton(x + 76, rowY, 64, bh, "+", "plus")
  local maxBtn = UI.newButton(x + 152, rowY, 96, bh, "최대", "max")
  -- 슬라이더 트랙은 −/+ 행 위(여백 확보).
  local track = { x = x, y = rowY - 28 - 20, w = w, h = 20 }
  return { performers = performers, track = track, minus = minus, plus = plus,
           max = maxBtn, confirm = confirm, close = closeButton(px, py, pw) }
end

--- 투자 서브 본문(GDD 10장). 수행 장수 선택 + 슬라이더 + 예상 상승 미리보기.
local function drawInvest(state, px, py, pw, ph)
  local region = curRegion(state)
  if not region then return end
  local item = state.devItem
  local pad, gap = config.popup.pad, config.popup.lineGap
  local x, y = px + pad, py + pad
  -- 비용 자원(민충성=군량, 나머지=금) — 슬라이더 한도·라벨이 이 자원을 따른다(GDD 10장).
  local costField = Develop.investCostField(item)
  local costLabel = Develop.costLabel(item)
  local maxCost = region[costField]
  -- 수행 장수를 먼저 결정해야 costToReachMax 계산에 정치 반영 가능.
  local performer = performerOf(state, regionId(state))
  -- 슬라이더 눈금 상한: 수치를 100까지 올리는 데 필요한 최소 비용(performer 정치 반영).
  -- 이 값이 슬라이더 오른쪽 끝(= 내정 수치 100이 되는 지점)이 된다.
  local costToMax = Develop.costToReachMax(region, item, performer)
  -- 실제 투자 가능 상한: 100 목표 비용과 보유 자원 중 작은 값.
  -- 금이 부족하면 목표까지 투자할 수 없으므로 보유 자원으로 제한.
  local effectiveMax = math.min(costToMax, maxCost)
  local amount = clampAmount(state.investAmount, effectiveMax)

  love.graphics.setColor(config.colors.text)
  love.graphics.print(region.name .. " — " .. (ITEM_LABEL[item] or item) .. " 투자", x, y)
  y = y + gap + 4
  -- 현재 수치(/상한) + 지역 비용 자원 보유량.
  love.graphics.print(string.format("%s: %d / %d      지역 %s: %d",
    ITEM_LABEL[item] or item, region[item], config.develop.maxStat, costLabel, maxCost), x, y)
  y = y + gap + 2

  -- 수행 장수 선택(정치 높을수록 효율 ↑, GDD 10장).
  love.graphics.print("수행 장수 선택 (정치 높을수록 효율 ↑):", x, y); y = y + gap

  local B = investLayout(state, px, py, pw, ph)
  drawPerformerRows(B.performers, performer)
  local mx, my = love.mouse.getPosition()

  -- 투자량 + 예상 상승 미리보기.
  local gain = Develop.developGain(amount, performer)
  love.graphics.setColor(config.colors.text)
  love.graphics.print("투자 " .. costLabel .. ": " .. amount, B.track.x, B.track.y - 26)
  love.graphics.setColor(config.colors.panelValue)
  love.graphics.printf(string.format("예상 상승: %s +%d", ITEM_LABEL[item] or item, gain),
    B.track.x, B.track.y - 26, B.track.w, "right")

  -- 슬라이더 트랙: 배경 → 채운 비율 → 핸들.
  -- 비율은 costToMax 기준: 슬라이더 오른쪽 끝 = 수치 100 도달점.
  -- 금이 부족하면 thumb 이 오른쪽 끝까지 못 간다(effectiveMax < costToMax 이므로).
  local ratio = costToMax > 0 and (amount / costToMax) or 0
  love.graphics.setColor(0.20, 0.21, 0.25)
  love.graphics.rectangle("fill", B.track.x, B.track.y, B.track.w, B.track.h, 6, 6)
  love.graphics.setColor(config.colors.selectBorder)
  love.graphics.rectangle("fill", B.track.x, B.track.y, B.track.w * ratio, B.track.h, 6, 6)
  love.graphics.setColor(config.colors.text)
  local hx = B.track.x + B.track.w * ratio
  love.graphics.rectangle("fill", hx - 4, B.track.y - 4, 8, B.track.h + 8, 3, 3)

  -- −/+/최대.
  UI.draw(B.minus, { hovered = UI.hit(B.minus, mx, my) })
  UI.draw(B.plus, { hovered = UI.hit(B.plus, mx, my) })
  UI.draw(B.max, { hovered = UI.hit(B.max, mx, my), accent = config.colors.selectBorder })

  -- 확정: 수행 장수 행동 가능 + 투자 가능(금/턴1회)일 때만.
  local canActOk = performer and GameState.canAct(performer)
  local investOk = Develop.canInvest(region, item, amount)
  if canActOk and investOk then
    UI.draw(B.confirm, { hovered = UI.hit(B.confirm, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(B.confirm, DISABLED)
  end
  if state.notice then
    love.graphics.setColor(0.95, 0.7, 0.4)
    love.graphics.print(state.notice, x, B.confirm.y - 28)
  end

  UI.draw(B.close, { hovered = UI.hit(B.close, mx, my), accent = config.colors.selectBorder })
end

-- ── 인재 탐색/등용 서브 레이아웃 ─────────────────────────

--- 탐색/등용 서브 레이아웃. 탐색 버튼은 상단 고정, 수행 장수·발견 목록은 동적 스택.
-- @return table { searchBtn, performers={rows}, recruits={ {btn, officer} }, close, performer }
local function searchLayout(state, px, py, pw, ph)
  local pad, gap, bh = config.popup.pad, config.popup.lineGap, config.popup.buttonHeight
  local x, w = px + pad, pw - pad * 2
  local rid = regionId(state)
  local performer = performerOf(state, rid)

  local searchBtn = UI.newButton(x, py + pad + 40, w, bh, "탐색", "search")
  -- 수행 장수 행: 탐색 버튼 아래 [결과 문구 줄] + [장수 선택 라벨 줄] 두 줄을 비우고 시작.
  local perfStartY = searchBtn.y + bh + 6 + gap * 2
  local rows, afterPerf = performerRows(state, rid, px, pw, perfStartY)
  -- 발견된(discovered) 재야 장수 = 등용 시도 대상.
  local recruits = {}
  local y = afterPerf + 8 + gap -- "발견된 재야" 라벨 아래
  local rh, rg = 32, 4
  for _, o in ipairs(state.officers or {}) do
    if o.region == rid and o.state == GameState.STATE.free and o.discovered then
      local chance = math.floor(Develop.recruitChance(performer) * 100)
      local b = UI.newButton(x, y, w, rh, o.name .. "  등용 시도 (" .. chance .. "%)", o.id)
      recruits[#recruits + 1] = { btn = b, officer = o }
      y = y + rh + rg
    end
  end
  return { searchBtn = searchBtn, performers = rows, recruits = recruits,
           close = closeButton(px, py, pw), performer = performer, recruitLabelY = afterPerf + 8 }
end

--- 탐색/등용 서브 본문(GDD 10·14장).
local function drawSearch(state, px, py, pw, ph)
  local region = curRegion(state)
  if not region then return end
  local pad = config.popup.pad
  local x, y = px + pad, py + pad
  local mx, my = love.mouse.getPosition()
  local L = searchLayout(state, px, py, pw, ph)
  local performer = L.performer

  love.graphics.setColor(config.colors.text)
  love.graphics.print(region.name .. " — 인재 탐색", x, y)

  -- 탐색 버튼: 성공률(선택 장수 정치 반영) 라벨. searchDone 이면 빨간 비활성.
  local chance = math.floor(Develop.searchSuccessChance(performer) * 100)
  local okSearch, _ = Develop.canSearch(region, performer)
  if region.searchDone then
    L.searchBtn.label = "인재 탐색 (완료)"
    UI.draw(L.searchBtn, DEV_DONE)
  else
    L.searchBtn.label = "인재 탐색 (성공률 " .. chance .. "%)"
    if okSearch then
      UI.draw(L.searchBtn, { hovered = UI.hit(L.searchBtn, mx, my), accent = config.colors.selectBorder })
    else
      UI.draw(L.searchBtn, DISABLED)
    end
  end

  -- 결과/안내 문구(탐색 버튼 바로 아래 줄).
  local gap = config.popup.lineGap
  local lineA = L.searchBtn.y + config.popup.buttonHeight + 6
  if state.notice then
    love.graphics.setColor(0.95, 0.8, 0.4)
    love.graphics.print(state.notice, x, lineA)
  end

  -- 수행 장수 선택(탐색·등용 공용) — 결과 문구 줄 아래.
  love.graphics.setColor(config.colors.text)
  love.graphics.print("수행 장수 선택:", x, lineA + gap)
  drawPerformerRows(L.performers, performer)

  -- 발견된 재야 장수(등용 시도 대상).
  love.graphics.setColor(config.colors.text)
  love.graphics.print("발견된 재야 장수:", x, L.recruitLabelY - 4)
  if #L.recruits == 0 then
    love.graphics.setColor(0.7, 0.72, 0.78)
    love.graphics.print("(아직 없음 — 탐색으로 발견)", x + 150, L.recruitLabelY - 4)
  else
    -- 등용 버튼: 수행 장수 행동 가능해야 활성(없으면 회색).
    local canActOk = performer and GameState.canAct(performer)
    for _, r in ipairs(L.recruits) do
      if canActOk then
        UI.draw(r.btn, { hovered = UI.hit(r.btn, mx, my), accent = config.colors.selectBorder })
      else
        UI.draw(r.btn, DISABLED)
      end
    end
  end

  UI.draw(L.close, { hovered = UI.hit(L.close, mx, my), accent = config.colors.selectBorder })
end

-- ── 디스패치(렌더) ───────────────────────────────────────

--- 팝업 뒤 어둡게 까는 막(scrim) + 팝업 배경.
local function drawFrame()
  local sw, sh = love.graphics.getDimensions()
  love.graphics.setColor(config.popup.scrim)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  local px, py, pw, ph = popupRect()
  love.graphics.setColor(config.popup.bg)
  love.graphics.rectangle("fill", px, py, pw, ph, 10, 10)
  return px, py, pw, ph
end

--- 내정 팝업 디스패처(모달). 열린 게 없으면 아무것도 안 그림. (읽기 전용)
-- 레이어 우선순위: 투자 서브 / 탐색 서브  >  허브.
-- @param state table  main 의 게임/UI 상태
function DevPopup.draw(state)
  if not (state.devOpen or state.devItem or state.searchOpen) then return end
  local px, py, pw, ph = drawFrame()
  if state.devItem then
    drawInvest(state, px, py, pw, ph)
  elseif state.searchOpen then
    drawSearch(state, px, py, pw, ph)
  else
    drawHub(state, px, py, pw, ph)
  end
end

-- ── 입력 ─────────────────────────────────────────────────

--- 투자 서브 클릭 처리. X→허브 / 슬라이더·−/+·최대 / 장수 선택 / 확정.
local function clickInvest(state, x, y, px, py, pw, ph)
  local region = curRegion(state)
  if not region then state.devItem = nil; return end
  local item = state.devItem
  -- 비용 자원(민충성=군량/그 외=금) 보유량.
  local maxCost = region[Develop.investCostField(item)]
  -- draw 와 동일 계산: performer 정치를 반영한 100 목표 비용 → 실제 상한.
  local performer = performerOf(state, regionId(state))
  local costToMax = Develop.costToReachMax(region, item, performer)
  local effectiveMax = math.min(costToMax, maxCost)
  local B = investLayout(state, px, py, pw, ph)

  if UI.hit(B.close, x, y) then
    state.devItem = nil; state.notice = nil; return -- 허브로
  end
  -- 슬라이더 트랙 클릭 → 클릭 위치 비율(costToMax 기준)로 투자금 설정.
  -- costToMax 가 슬라이더 오른쪽 끝이므로 ratio * costToMax 로 역산.
  -- 금 부족이면 effectiveMax 로 클램프 → 오른쪽 끝까지 이동 불가.
  if x >= B.track.x and x <= B.track.x + B.track.w
     and y >= B.track.y - 12 and y <= B.track.y + B.track.h + 12 then
    local ratio = (x - B.track.x) / B.track.w
    state.investAmount = clampAmount(ratio * costToMax, effectiveMax)
    return
  end
  if UI.hit(B.minus, x, y) then
    state.investAmount = clampAmount(clampAmount(state.investAmount, effectiveMax) - config.develop.sliderStep, effectiveMax); return
  end
  if UI.hit(B.plus, x, y) then
    state.investAmount = clampAmount(clampAmount(state.investAmount, effectiveMax) + config.develop.sliderStep, effectiveMax); return
  end
  if UI.hit(B.max, x, y) then
    -- 최대 버튼: 수치 100 도달 비용(effectiveMax) 으로 설정.
    -- 금이 부족하면 effectiveMax < costToMax 이므로 오른쪽 끝까지는 못 감.
    state.investAmount = effectiveMax; return
  end
  -- 수행 장수 선택(투자 효율은 이 장수 정치 반영).
  for _, r in ipairs(B.performers) do
    if UI.hit(r.btn, x, y) then state.devPerformerId = r.officer.id; return end
  end
  -- 확정 → 투자 실행(규칙은 game_state). 성공 시 허브로 복귀(빨간 비활성 확인).
  if UI.hit(B.confirm, x, y) then
    local amount = clampAmount(state.investAmount, effectiveMax)
    local actOk = performer and GameState.canAct(performer)
    local ok, reason = Develop.canInvest(region, item, amount)
    if actOk and ok then
      Develop.applyInvest(region, item, amount, performer)
      state.devItem = nil; state.notice = nil
    else
      state.notice = (not actOk) and "수행 장수 행동 불가" or (reason or "투자 불가")
    end
  end
end

--- 탐색/등용 서브 클릭 처리. X→닫기 / 탐색 / 장수 선택 / 등용 시도.
local function clickSearch(state, x, y, px, py, pw, ph)
  local region = curRegion(state)
  if not region then state.searchOpen = false; return end
  local L = searchLayout(state, px, py, pw, ph)

  if UI.hit(L.close, x, y) then
    state.searchOpen = false; state.notice = nil; return
  end
  -- 수행 장수 선택.
  for _, r in ipairs(L.performers) do
    if UI.hit(r.btn, x, y) then state.devPerformerId = r.officer.id; return end
  end
  -- 탐색 실행(규칙은 game_state). 성공 시 발견 장수 안내.
  if UI.hit(L.searchBtn, x, y) then
    local performer = performerOf(state, regionId(state))
    local ok, reason = Develop.canSearch(region, performer)
    if ok then
      local found = Develop.attemptSearch(state.officers, regionId(state), region, performer, state.rng)
      state.notice = found and ("탐색 성공! " .. found.name .. " 발견") or "탐색 실패 — 이번 턴 종료"
    else
      state.notice = reason or "탐색 불가"
    end
    return
  end
  -- 등용 시도(규칙은 game_state). 발견된 재야 장수 행 클릭.
  for _, r in ipairs(L.recruits) do
    if UI.hit(r.btn, x, y) then
      local performer = performerOf(state, regionId(state))
      local ok, reason = Develop.canRecruit(r.officer, performer)
      if ok then
        local success = Develop.attemptRecruit(r.officer, performer, state.playerFactionId, state.rng)
        state.notice = success and (r.officer.name .. " 등용 성공! 세력 편입")
          or (r.officer.name .. " 등용 실패")
      else
        state.notice = reason or "등용 불가"
      end
      return
    end
  end
end

--- 허브 클릭 처리. X→닫기 / 투자 항목 → 서브 / 인재 탐색 → 서브.
local function clickHub(state, x, y, px, py, pw, ph)
  local region = curRegion(state)
  if not region then state.devOpen = false; return end
  local L = hubLayout(px, py, pw, ph)
  if UI.hit(L.close, x, y) then state.devOpen = false; return end
  for _, item in ipairs(L.items) do
    -- 이미 투자한 항목(devDone)은 비활성 → 무시.
    if not region.devDone[item.key] and UI.hit(item.btn, x, y) then
      state.devItem = item.key
      state.notice = nil
      state.devPerformerId = nil          -- 기본 수행 장수(태수)로 초기화
      state.investAmount = 0 -- 열 때 0 시작. 최대 버튼으로 한 번에 채울 수 있다.
      return
    end
  end
  -- 인재 탐색(searchDone 이면 비활성).
  if not region.searchDone and UI.hit(L.search, x, y) then
    state.searchOpen = true
    state.notice = nil
    state.devPerformerId = nil
    return
  end
end

--- 내정 팝업이 열려 있으면 클릭을 처리하고 true 를 돌려준다(모달).
-- 레이어 우선순위: 투자 서브 / 탐색 서브 > 허브.
-- 부작용: state 의 내정 필드 + (확정/탐색/등용 시) 규칙 적용 결과.
-- @return boolean  팝업이 열려 있었으면(=클릭 소비) true
function DevPopup.consumeClick(state, x, y)
  if not (state.devOpen or state.devItem or state.searchOpen) then return false end
  local px, py, pw, ph = popupRect()
  if state.devItem then
    clickInvest(state, x, y, px, py, pw, ph)
  elseif state.searchOpen then
    clickSearch(state, x, y, px, py, pw, ph)
  else
    clickHub(state, x, y, px, py, pw, ph)
  end
  return true
end

return DevPopup
