--[[
order_popup.lua — 부대 명령(이동/수송) 모달 팝업 (표현·입력 보조) — GDD 12·17장

  이 모듈의 책임:
    - 지도 화면 위에 뜨는 "부대 명령 팝업"의 렌더(draw)와 클릭 처리(consumeClick).
    - 종류(이동/수송) 선택 + 수행 장수 선택 + (수송이면) 군량 선택까지가 이 팝업의 일.
      "목적지 지정" 버튼을 누르면 팝업을 닫고 목적지 선택 모드(state.orderPicking)로 넘긴다 →
      실제 목적지 클릭·명령 확정·인접/소유 검증은 main 이 movement 규칙으로 수행한다.
  관계:
    - main.lua     : draw 끝에서 OrderPopup.draw(state), mousepressed 에서 consumeClick 호출(dev_popup 와 같은 패턴).
                     목적지 선택 모드 처리와 movement.issueOrder 호출은 main 쪽(지도 클릭·턴·인접 필요).
    - movement.lua : 명령 규칙(canMove/canTransport/issueOrder)은 main 이 부른다. 여기선 UI 상태만.
    - game_state.lua : 장수 조회/행동 가능 판정(officersInRegion, canAct, troopsCap).
    - ui.lua / config / region : 버튼 렌더·클릭, 상수, 지역 이름.
  설계:
    - popup.lua(773줄)·dev_popup.lua 에 더 얹으면 800줄(CLAUDE.md) 초과 → "한 모듈 한 책임"으로 분리.
    - draw 는 읽기만(상태 변경 X). 모든 상태 변경은 consumeClick 에서만.

  state 의존 필드(주입):
    orderOpen(팝업 열림), orderKind("move"|"transport"), orderOfficerId(수행 장수),
    orderGrain(수송 군량), orderPicking(목적지 선택 모드), notice(안내),
    selectedId, officers, regions, regionState, playerFactionId
--]]

local config = require("config")
local UI = require("ui")
local Region = require("region")
local GameState = require("game_state")
local Movement = require("movement")
local Battle = require("battle")

local OrderPopup = {}

-- 명령 종류 문자열: 이동/수송은 Movement.ORDER, 전쟁은 전투(battle)라 별도 "war".
--   (state.orderKind 가 이 셋 중 하나. 전쟁 확정은 main 이 battle 로 분기.)
local WAR = "war"
OrderPopup.WAR = WAR

-- 회색 비활성(조건 미충족: 행동 소진 장수 등).
local DISABLED = { text = { 0.5, 0.52, 0.58 }, border = { 0.3, 0.31, 0.36 } }

-- ── 공통 레이아웃(순수 좌표) ─────────────────────────────

--- 화면 중앙 팝업 사각형(스크린 좌표). 다른 팝업과 동일 규격(config.popup).
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

--- 선택 지역의 런타임 지역 레코드(군량 등). 없으면 nil.
local function curRegion(state)
  local rid = state.selectedId
  return rid and state.regionState and state.regionState[rid] or nil
end

--- 이 지역의 active 장수(부대 명령 후보). 소유 지역이면 전부 플레이어 세력 소속이다.
local function activeHere(state)
  local out = {}
  for _, o in ipairs(state.officers or {}) do
    if o.region == state.selectedId and o.state == GameState.STATE.active then out[#out + 1] = o end
  end
  return out
end

--- 현재 선택된 수행(이동/수송) 장수. orderOfficerId 가 유효하면 그 장수, 아니면 첫 행동가능 장수.
--   호출 위치: draw·consumeClick 양쪽(같은 결과 보장). 없으면 nil.
local function selectedOfficer(state)
  local list = activeHere(state)
  if state.orderOfficerId then
    for _, o in ipairs(list) do if o.id == state.orderOfficerId then return o end end
  end
  for _, o in ipairs(list) do if GameState.canAct(o) then return o end end
  return list[1]
end

--- 수송 군량을 0~지역 군량으로 클램프하고 정수화.
local function clampGrain(amount, maxGrain)
  return math.floor(math.max(0, math.min(maxGrain, amount or 0)))
end

-- ── 레이아웃(draw·click 공유 단일 출처) ──────────────────

--- 종류 토글 버튼(이동/수송) + 장수 행 + (수송)군량 −/+/최대 + 목적지 지정 + 닫기.
-- @return table 레이아웃 모음
local function layout(state, px, py, pw, ph)
  local pad, bh = config.popup.pad, config.popup.buttonHeight
  local x, w = px + pad, pw - pad * 2

  -- 종류 토글: 상단 3분할(이동/수송/전쟁).
  local w3 = (w - 24) / 3
  local y0 = py + pad + 40
  local moveBtn = UI.newButton(x, y0, w3, bh, "이동", "move")
  local transBtn = UI.newButton(x + w3 + 12, y0, w3, bh, "수송", "transport")
  local warBtn = UI.newButton(x + (w3 + 12) * 2, y0, w3, bh, "전쟁", WAR)

  -- 수행 장수 행: 토글 아래.
  local rh, rg = 34, 4
  local rowsY = y0 + bh + 14 + 22 -- "수행 장수" 라벨(22) 아래
  local rows = {}
  for i, o in ipairs(activeHere(state)) do
    local cap = GameState.troopsCap(o)
    local label = string.format("%s   병력 %d/%d   훈련 %d", o.name, o.troops, cap, math.floor(o.training))
    rows[i] = { btn = UI.newButton(x, rowsY + (i - 1) * (rh + rg), w, rh, label, o.id), officer = o }
  end

  -- 하단: 목적지 지정(전폭) 위에 / 수송이면 그 위에 군량 −/+/최대 줄.
  local pickBtn = UI.newButton(x, py + ph - pad - bh, w, bh, "목적지 지정", "pick")
  local grainRowY = pickBtn.y - 12 - bh
  local minus = UI.newButton(x, grainRowY, 64, bh, "−", "minus")
  local plus = UI.newButton(x + 76, grainRowY, 64, bh, "+", "plus")
  local maxBtn = UI.newButton(x + 152, grainRowY, 96, bh, "최대", "max")

  return {
    move = moveBtn, transport = transBtn, war = warBtn, rows = rows,
    minus = minus, plus = plus, max = maxBtn, pick = pickBtn,
    close = closeButton(px, py, pw),
    grainRowY = grainRowY,
  }
end

-- ── 렌더 ─────────────────────────────────────────────────

--- 종류 토글 버튼: 현재 선택된 종류는 강조 테두리, 아니면 hover 강조.
local function drawToggle(btn, active, mx, my)
  UI.draw(btn, {
    hovered = active or UI.hit(btn, mx, my),
    accent = config.colors.selectBorder,
  })
end

--- 부대 명령 팝업 본문.
local function drawBody(state, px, py, pw, ph)
  local region = curRegion(state)
  if not region then return end
  local pad, gap = config.popup.pad, config.popup.lineGap
  local x, y = px + pad, py + pad
  local mx, my = love.mouse.getPosition()
  local sel = Region.byId(state.regions, state.selectedId)
  local kind = state.orderKind or Movement.ORDER.move

  love.graphics.setColor(config.colors.text)
  love.graphics.print((sel and sel.name or "") .. " — 부대 명령", x, y)

  local L = layout(state, px, py, pw, ph)
  drawToggle(L.move, kind == Movement.ORDER.move, mx, my)
  drawToggle(L.transport, kind == Movement.ORDER.transport, mx, my)
  drawToggle(L.war, kind == WAR, mx, my)

  local labelY = L.move.y + config.popup.buttonHeight + 12
  local performer = selectedOfficer(state)

  -- 전쟁: 출진 장수(active + 병력>0) 전원 출전. 선택 없이 명단만 표시 후 조기 반환(GDD 13장).
  if kind == WAR then
    local marchers = Battle.marchers(state.officers, state.selectedId, state.playerFactionId)
    love.graphics.setColor(config.colors.text)
    love.graphics.print("출진 장수 (전원 출전):", x, labelY)
    local ly = labelY + 30
    if #marchers == 0 then
      love.graphics.setColor(0.7, 0.72, 0.78)
      love.graphics.print("출진할 병력 있는 장수가 없습니다.", x, ly)
    else
      for _, o in ipairs(marchers) do
        love.graphics.setColor(config.colors.text)
        love.graphics.print(string.format("· %s   병력 %d   무력 %d", o.name, o.troops,
          GameState.effectiveStat(o, "might")), x, ly)
        ly = ly + 28
      end
    end
    love.graphics.setColor(0.7, 0.72, 0.78)
    love.graphics.print("공격 대상 = 인접 적 소유 지역.", x, L.grainRowY - 26)
    L.pick.label = "공격 대상 지정"
    if #marchers > 0 then
      UI.draw(L.pick, { hovered = UI.hit(L.pick, mx, my), accent = config.colors.selectBorder })
    else
      UI.draw(L.pick, DISABLED)
    end
    if state.notice then
      love.graphics.setColor(0.95, 0.7, 0.4)
      love.graphics.print(state.notice, x, L.pick.y - 28)
    end
    UI.draw(L.close, { hovered = UI.hit(L.close, mx, my), accent = config.colors.selectBorder })
    return
  end

  -- 수행 장수 라벨 + 목록(선택 장수 강조, 행동 소진은 회색 비활성).
  love.graphics.setColor(config.colors.text)
  love.graphics.print("수행 장수 선택:", x, labelY)
  if #L.rows == 0 then
    love.graphics.setColor(0.7, 0.72, 0.78)
    love.graphics.print("이 지역에 명령할 장수가 없습니다.", x, labelY + 30)
  else
    for _, r in ipairs(L.rows) do
      local canAct = GameState.canAct(r.officer)
      local selected = performer and r.officer.id == performer.id
      if canAct then
        UI.draw(r.btn, {
          hovered = selected or UI.hit(r.btn, mx, my),
          accent = config.colors.selectBorder,
        })
      else
        r.btn.label = r.btn.label .. "  [행동 소진]"
        UI.draw(r.btn, DISABLED)
      end
    end
  end

  -- 수송이면: 군량 조절 줄 + 안내. 이동은 병력이 장수와 함께 가므로 추가 입력 없음.
  if kind == Movement.ORDER.transport then
    local maxGrain = region.grain
    local amount = clampGrain(state.orderGrain, maxGrain)
    love.graphics.setColor(config.colors.text)
    love.graphics.print("수송 군량: " .. amount .. "  (지역 군량 " .. maxGrain .. ")", x, L.grainRowY - 26)
    UI.draw(L.minus, { hovered = UI.hit(L.minus, mx, my) })
    UI.draw(L.plus, { hovered = UI.hit(L.plus, mx, my) })
    UI.draw(L.max, { hovered = UI.hit(L.max, mx, my), accent = config.colors.selectBorder })
  else
    love.graphics.setColor(0.7, 0.72, 0.78)
    love.graphics.print("이동: 병력은 선택 장수와 함께 이동합니다.", x, L.grainRowY - 26)
  end

  -- 목적지 지정 버튼: 수행 장수가 있고 행동 가능할 때만 활성.
  local ok = performer and GameState.canAct(performer)
  if kind == Movement.ORDER.transport then
    ok = ok and clampGrain(state.orderGrain, region.grain) > 0
  end
  if ok then
    UI.draw(L.pick, { hovered = UI.hit(L.pick, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(L.pick, DISABLED)
  end

  if state.notice then
    love.graphics.setColor(0.95, 0.7, 0.4)
    love.graphics.print(state.notice, x, L.pick.y - 28)
  end

  UI.draw(L.close, { hovered = UI.hit(L.close, mx, my), accent = config.colors.selectBorder })
end

--- 부대 명령 팝업 디스패처(모달). 열렸을 때만 그림. (읽기 전용)
-- @param state table
function OrderPopup.draw(state)
  if not state.orderOpen then return end
  -- scrim + 배경.
  local sw, sh = love.graphics.getDimensions()
  love.graphics.setColor(config.popup.scrim)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  local px, py, pw, ph = popupRect()
  love.graphics.setColor(config.popup.bg)
  love.graphics.rectangle("fill", px, py, pw, ph, 10, 10)
  drawBody(state, px, py, pw, ph)
end

-- ── 입력 ─────────────────────────────────────────────────

--- 부대 명령 팝업이 열려 있으면 클릭을 처리하고 true 를 돌려준다(모달).
-- 처리: X=닫기 / 종류 토글 / 장수 선택 / 군량 −/+/최대 / 목적지 지정(→ 목적지 선택 모드).
-- 부작용: state 의 order* 필드. 실제 명령 확정은 main 의 목적지 클릭에서.
-- @return boolean  팝업이 열려 있었으면 true
function OrderPopup.consumeClick(state, x, y)
  if not state.orderOpen then return false end
  local region = curRegion(state)
  local px, py, pw, ph = popupRect()
  local L = layout(state, px, py, pw, ph)

  if UI.hit(L.close, x, y) then
    state.orderOpen = false; state.notice = nil
    return true
  end

  -- 종류 토글.
  if UI.hit(L.move, x, y) then state.orderKind = Movement.ORDER.move; state.notice = nil; return true end
  if UI.hit(L.transport, x, y) then state.orderKind = Movement.ORDER.transport; state.notice = nil; return true end
  if UI.hit(L.war, x, y) then state.orderKind = WAR; state.notice = nil; return true end

  -- 전쟁: 공격 대상 지정 → 출진 장수 1명 이상이면 목적지 선택 모드(다음 지도 클릭 = 공격 대상). 검증은 main.
  if (state.orderKind == WAR) then
    if UI.hit(L.pick, x, y) then
      local marchers = Battle.marchers(state.officers, state.selectedId, state.playerFactionId)
      if #marchers > 0 then
        state.orderOpen = false
        state.orderPicking = true
        state.notice = nil
      end
    end
    return true -- 전쟁 모드에선 장수 선택/군량 없음 → 나머지 클릭 소비
  end

  -- 수행 장수 선택(행동 가능 장수만).
  for _, r in ipairs(L.rows) do
    if UI.hit(r.btn, x, y) and GameState.canAct(r.officer) then
      state.orderOfficerId = r.officer.id; state.notice = nil
      return true
    end
  end

  -- 군량 조절(수송 전용).
  if (state.orderKind or Movement.ORDER.move) == Movement.ORDER.transport and region then
    local maxGrain = region.grain
    local step = config.orders.grainStep
    if UI.hit(L.minus, x, y) then
      state.orderGrain = clampGrain(clampGrain(state.orderGrain, maxGrain) - step, maxGrain); return true
    end
    if UI.hit(L.plus, x, y) then
      state.orderGrain = clampGrain(clampGrain(state.orderGrain, maxGrain) + step, maxGrain); return true
    end
    if UI.hit(L.max, x, y) then state.orderGrain = maxGrain; return true end
  end

  -- 목적지 지정 → 팝업 닫고 목적지 선택 모드로(다음 지도 클릭이 목적지). 검증은 main.
  if UI.hit(L.pick, x, y) then
    local performer = selectedOfficer(state)
    if performer and GameState.canAct(performer) then
      state.orderOfficerId = performer.id -- 기본값으로 골린 장수도 확정
      state.orderOpen = false
      state.orderPicking = true
      state.notice = nil
    end
    return true
  end

  return true -- 모달: 바깥 클릭도 소비(지도로 안 넘김)
end

return OrderPopup
