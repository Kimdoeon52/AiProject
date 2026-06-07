--[[
popup.lua — 장수 팝업(목록/상세) + 선물 서브팝업 (표현·입력 보조)

  이 모듈의 책임:
    - 지도 화면 위에 뜨는 "모달 팝업"의 렌더(draw)와 클릭 처리(consumeClick)를 담당.
    - 레이어(앞→뒤): 금 선물 서브팝업 > 장수 상세 > 장수 목록.
  관계:
    - main.lua : 지도 draw 끝에서 Popup.draw(state), mousepressed 에서 Popup.consumeClick(state,x,y) 호출.
    - game_state.lua : 조회/선물 규칙(officersInRegion, isGiftTarget, canGiftGold, applyGiftGold).
    - ui.lua / config / region : 버튼 렌더·클릭, 상수, 지역 이름 조회.
  설계:
    - 규칙(충성/금 변경)은 game_state 가 수행. 이 모듈은 그 결과를 state 에 반영만 한다.
    - 팝업 상태(state.listOpen/detailId/sub/giftAmount/notice)는 입력에서만 변경, draw 는 읽기만.
    - 800줄 규칙(CLAUDE.md)에 따라 main 에서 팝업 책임을 떼어낸 모듈.

  state 의존 필드(주입):
    listOpen, detailId, sub("gold"), giftAmount, notice,
    selectedId, officers, regions, scenario, playerFactionId, gold
--]]

local config = require("config")
local UI = require("ui")
local Region = require("region")
local GameState = require("game_state")

local Popup = {}

-- 상태 enum → 한글 표기(표시용).
local STATE_KR = {
  active = "소속", free = "재야", unrevealed = "미등장", captured = "포로", dead = "사망",
}

-- ── 레이아웃(순수 좌표 계산) ─────────────────────────────

--- 화면 중앙 팝업 사각형(스크린 좌표).
local function popupRect()
  -- love.graphics.getDimensions(): 현재 창 크기. 중앙 정렬 계산에 사용.
  local sw, sh = love.graphics.getDimensions()
  local w, h = config.popup.width, config.popup.height
  return (sw - w) / 2, (sh - h) / 2, w, h
end

--- 우상단 X(닫기) 버튼. 어느 레이어든 공통으로 1개만 둔다.
local function closeButton(px, py, pw)
  local s = config.popup.closeSize
  return UI.newButton(px + pw - s - 10, py + 10, s, s, "X", "close")
end

--- 장수 목록 팝업의 각 줄(장수 1명) 버튼. draw·클릭 공유 레이아웃.
-- @return table  UI 버튼 배열(value = 장수 id)
local function officerRows(state, px, py, pw)
  local rows = {}
  if not (state.selectedId and state.officers) then return rows end
  local here = GameState.officersInRegion(state.officers, state.selectedId)
  local pad, rh, rg = config.popup.pad, config.popup.rowHeight, config.popup.rowGap
  local x = px + pad
  local y0 = py + pad + 46 -- 제목 아래
  local w = pw - pad * 2
  for i, o in ipairs(here) do
    rows[i] = UI.newButton(x, y0 + (i - 1) * (rh + rg), w, rh, o.name, o.id)
  end
  return rows
end

--- 장수 상세의 액션 버튼(금 선물 / 장비 선물). 팝업 하단 2분할.
-- @return table goldBtn, table equipBtn
local function detailButtons(px, py, pw, ph)
  local pad, bh = config.popup.pad, config.popup.buttonHeight
  local y = py + ph - pad - bh
  local w = (pw - pad * 2 - 12) / 2
  local goldBtn = UI.newButton(px + pad, y, w, bh, "금 선물", "gold")
  local equipBtn = UI.newButton(px + pad + w + 12, y, w, bh, "장비 선물 (미구현)", "equip")
  return goldBtn, equipBtn
end

--- 금 선물 서브팝업의 버튼(−, +, 확정).
-- @return table minus, table plus, table confirm
local function goldButtons(px, py, pw, ph)
  local pad, bh = config.popup.pad, config.popup.buttonHeight
  local sy = py + 170 -- 금액 조절 줄 y
  local minus = UI.newButton(px + pad, sy, 64, bh, "−", "minus")
  local plus = UI.newButton(px + pad + 64 + 220, sy, 64, bh, "+", "plus")
  local confirm = UI.newButton(px + pad, py + ph - pad - bh, pw - pad * 2, bh, "확정", "confirm")
  return minus, plus, confirm
end

-- ── 조회 헬퍼 ────────────────────────────────────────────

--- 상세를 보고 있는 런타임 장수(없으면 nil).
local function detailOfficer(state)
  return state.detailId and GameState.byId(state.officers, state.detailId) or nil
end

--- 장수의 소속 세력 표시 이름(재야면 "재야").
local function officerFactionName(state, o)
  if not o.faction then return "재야" end
  local f = state.scenario.factions[o.faction]
  return f and f.name or o.faction
end

-- ── 렌더 ─────────────────────────────────────────────────

--- 팝업 뒤를 어둡게 까는 막(scrim) — 모달 강조.
local function drawScrim()
  local sw, sh = love.graphics.getDimensions()
  love.graphics.setColor(config.popup.scrim)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
end

--- 장수 목록 팝업 본문.
local function drawOfficerList(state, px, py, pw)
  local pad = config.popup.pad
  local sel = state.selectedId and Region.byId(state.regions, state.selectedId)
  love.graphics.setColor(config.colors.text)
  love.graphics.print((sel and sel.name or "") .. " 장수", px + pad, py + pad)

  local mx, my = love.mouse.getPosition()
  local rows = officerRows(state, px, py, pw)
  if #rows == 0 then
    love.graphics.setColor(0.7, 0.72, 0.78)
    love.graphics.print("이 지역에 장수가 없습니다.", px + pad, py + pad + 50)
    return
  end
  for _, btn in ipairs(rows) do
    UI.draw(btn, { hovered = UI.hit(btn, mx, my), accent = config.colors.selectBorder })
  end
end

--- 장수 상세 팝업 본문(GDD 7·8장 표시 항목).
local function drawOfficerDetail(state, px, py, pw, ph)
  local o = detailOfficer(state)
  if not o then return end
  local pad, gap = config.popup.pad, config.popup.lineGap
  local x, y = px + pad, py + pad

  love.graphics.setColor(config.colors.text)
  love.graphics.print(o.name .. (o.isLord and "  (군주)" or ""), x, y); y = y + gap + 4

  -- GDD 7장 능력치/상태.
  love.graphics.print(string.format("무력 %d   지력 %d   정치 %d   체력 %d",
    o.might, o.intel, o.pol, o.hp), x, y); y = y + gap
  love.graphics.print("충성도: " .. tostring(GameState.loyaltyText(o)), x, y); y = y + gap
  love.graphics.print("보유 병력: " .. (o.troops or 0), x, y); y = y + gap
  love.graphics.print("소속 세력: " .. officerFactionName(state, o), x, y); y = y + gap
  local r = o.region and Region.byId(state.regions, o.region)
  love.graphics.print("위치 지역: " .. (r and r.name or "-"), x, y); y = y + gap
  love.graphics.print("상태: " .. (STATE_KR[o.state] or o.state), x, y); y = y + gap + 6

  -- GDD 8장 장비(미구현 스텁).
  love.graphics.print("보유 장비: " .. (o.equip and o.equip.name or "없음"), x, y); y = y + gap

  -- 선물 버튼: 플레이어 세력 소속 장수에게만 노출(GDD 15장).
  if GameState.isGiftTarget(o, state.playerFactionId) then
    local mx, my = love.mouse.getPosition()
    local goldBtn, equipBtn = detailButtons(px, py, pw, ph)
    -- 금 선물: 이번 턴 이미 선물했으면 비활성.
    if o.giftedGoldThisTurn then
      UI.draw(goldBtn, { text = { 0.5, 0.52, 0.58 }, border = { 0.3, 0.31, 0.36 } })
    else
      UI.draw(goldBtn, { hovered = UI.hit(goldBtn, mx, my), accent = config.colors.selectBorder })
    end
    -- 장비 선물: 항상 비활성(장비 미구현, GameState.EQUIP_IMPLEMENTED=false).
    UI.draw(equipBtn, { text = { 0.5, 0.52, 0.58 }, border = { 0.3, 0.31, 0.36 } })
  else
    love.graphics.setColor(0.7, 0.72, 0.78)
    love.graphics.print("(플레이어 세력 장수만 선물 가능)", x, py + ph - pad - 24)
  end
end

--- 금 선물 서브팝업 본문(GDD 15장).
local function drawGiftGold(state, px, py, pw, ph)
  local o = detailOfficer(state)
  if not o then return end
  local pad, gap = config.popup.pad, config.popup.lineGap
  local x, y = px + pad, py + pad

  love.graphics.setColor(config.colors.text)
  love.graphics.print("금 선물 — " .. o.name, x, y); y = y + gap + 4
  love.graphics.print("군주 금: " .. state.gold, x, y); y = y + gap
  -- 1금 = 충성 +5(GDD 15장). 선물 후 충성 미리보기(상한 클램프).
  local after = math.min(config.officer.maxLoyalty,
    (o.loyalty or 0) + state.giftAmount * config.gift.loyaltyPerGold)
  love.graphics.print(string.format("충성: %s → %d  (1금 = +%d)",
    tostring(o.loyalty or 0), after, config.gift.loyaltyPerGold), x, y)

  -- 금액 조절(−/+) + 가운데 숫자.
  local mx, my = love.mouse.getPosition()
  local minus, plus, confirm = goldButtons(px, py, pw, ph)
  UI.draw(minus, { hovered = UI.hit(minus, mx, my) })
  UI.draw(plus, { hovered = UI.hit(plus, mx, my) })
  love.graphics.setColor(config.colors.text)
  love.graphics.printf(state.giftAmount .. " 금", minus.x + minus.w, minus.y + 12, 220, "center")

  -- 확정(금 부족이면 비활성).
  local ok = GameState.canGiftGold(state.gold, o, state.giftAmount)
  if ok then
    UI.draw(confirm, { hovered = UI.hit(confirm, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(confirm, { text = { 0.5, 0.52, 0.58 }, border = { 0.3, 0.31, 0.36 } })
  end
  if state.notice then
    love.graphics.setColor(0.95, 0.7, 0.4)
    love.graphics.print(state.notice, x, confirm.y - 30)
  end
end

--- 팝업 디스패처(모달). 열린 게 없으면 아무것도 안 그림. (읽기 전용)
-- @param state table  main 의 게임/UI 상태
function Popup.draw(state)
  if not (state.listOpen or state.detailId or state.sub) then return end
  drawScrim()
  local px, py, pw, ph = popupRect()
  love.graphics.setColor(config.popup.bg)
  love.graphics.rectangle("fill", px, py, pw, ph, 10, 10)

  if state.sub == "gold" then
    drawGiftGold(state, px, py, pw, ph)
  elseif state.detailId then
    drawOfficerDetail(state, px, py, pw, ph)
  else
    drawOfficerList(state, px, py, pw)
  end

  -- 공통 X 버튼(동작은 현재 레이어 기준 — consumeClick 에서 분기).
  local mx, my = love.mouse.getPosition()
  local cb = closeButton(px, py, pw)
  UI.draw(cb, { hovered = UI.hit(cb, mx, my), accent = config.colors.selectBorder })
end

-- ── 입력 ─────────────────────────────────────────────────

--- 팝업이 열려 있으면 클릭을 처리하고 true 를 돌려준다(모달 — 지도로 안 넘김).
-- 레이어 우선순위: 금 선물 서브팝업 > 장수 상세 > 장수 목록.
-- 부작용: state 의 팝업 필드 + (선물 확정 시) gold/officer 변경.
-- @return boolean  팝업이 열려 있었으면(=클릭 소비) true
function Popup.consumeClick(state, x, y)
  if not (state.listOpen or state.detailId or state.sub) then return false end

  local px, py, pw, ph = popupRect()
  local cb = closeButton(px, py, pw)

  if state.sub == "gold" then
    -- 금 선물 서브팝업: X=서브 닫기 / − + 조절 / 확정 = 선물 실행.
    local minus, plus, confirm = goldButtons(px, py, pw, ph)
    if UI.hit(cb, x, y) then
      state.sub = nil; state.notice = nil
    elseif UI.hit(minus, x, y) then
      state.giftAmount = math.max(1, state.giftAmount - 1)
    elseif UI.hit(plus, x, y) then
      state.giftAmount = math.min(config.gift.goldGiftMax, state.giftAmount + 1)
    elseif UI.hit(confirm, x, y) then
      local o = detailOfficer(state)
      local ok, reason = GameState.canGiftGold(state.gold, o, state.giftAmount)
      if ok then
        -- 규칙은 game_state 가 수행(충성 상승 + 금 차감). 여기선 결과만 반영.
        state.gold = GameState.applyGiftGold(state.gold, o, state.giftAmount)
        state.sub = nil
        state.notice = nil
      else
        state.notice = reason -- 예: "금 부족"
      end
    end
    return true
  end

  if state.detailId then
    -- 장수 상세: X=목록으로 / 금 선물 버튼 = 서브팝업 열기.
    if UI.hit(cb, x, y) then
      state.detailId = nil
    else
      local o = detailOfficer(state)
      if o and GameState.isGiftTarget(o, state.playerFactionId) and not o.giftedGoldThisTurn then
        local goldBtn = detailButtons(px, py, pw, ph)
        if UI.hit(goldBtn, x, y) then
          state.sub = "gold"; state.giftAmount = 1; state.notice = nil
        end
      end
      -- 장비 선물 버튼은 비활성(미구현) → 클릭 무시.
    end
    return true
  end

  -- 장수 목록: X=목록 닫기 / 항목 클릭 = 상세 열기.
  if UI.hit(cb, x, y) then
    state.listOpen = false
  else
    for _, btn in ipairs(officerRows(state, px, py, pw)) do
      if UI.hit(btn, x, y) then state.detailId = btn.value; break end
    end
  end
  return true
end

return Popup
