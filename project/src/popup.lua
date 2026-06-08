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

-- 장비 보너스 필드(force/intelligence/politics/hp) → 한글 능력치 라벨.
--   data 의 키 이름과 표시 라벨을 한 곳에서 매핑(매직 문자열 분산 방지).
local ITEM_FIELDS = {
  { f = "force", label = "무력" }, { f = "intelligence", label = "지력" },
  { f = "politics", label = "정치" }, { f = "hp", label = "체력" },
}

--- 장비의 보너스 내역 문자열(예: "무력 +18, 지력 +4"). 0 은 생략, 음수는 그대로.
local function itemBonusText(item)
  local parts = {}
  for _, e in ipairs(ITEM_FIELDS) do
    local v = item[e.f] or 0
    if v ~= 0 then
      parts[#parts + 1] = e.label .. (v > 0 and (" +" .. v) or (" " .. v))
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or "보너스 없음"
end

--- 능력치 표시 색: 장비 보너스 +면 연두, −면 빨강, 없으면 기본(GDD 8장).
--   draw 는 "조회"만(계산은 game_state.statBonus). 색 선택만 표현 계층 책임.
local function statColor(o, statKey)
  local b = GameState.statBonus(o, statKey)
  if b > 0 then return config.colors.statBonus end
  if b < 0 then return config.colors.statPenalty end
  return config.colors.text
end

--- 장수 상세의 액션 버튼(태수 지정/해제, 금 선물, 장비 선물).
-- 하단: [태수](전폭) 위에 / [금 선물][장비 선물](2분할). 라벨은 draw 에서 상태 따라 덮어씀.
-- @return table govBtn, table goldBtn, table equipBtn
local function detailButtons(px, py, pw, ph)
  local pad, bh = config.popup.pad, config.popup.buttonHeight
  local w2 = (pw - pad * 2 - 12) / 2
  local yGifts = py + ph - pad - bh
  local yGov = yGifts - bh - 8
  local govBtn = UI.newButton(px + pad, yGov, pw - pad * 2, bh, "태수 지정", "gov")
  local goldBtn = UI.newButton(px + pad, yGifts, w2, bh, "금 선물", "gold")
  local equipBtn = UI.newButton(px + pad + w2 + 12, yGifts, w2, bh, "장비 선물", "equip")
  return govBtn, goldBtn, equipBtn
end

--- 장비 선물 서브팝업의 장비 목록(군주 미장착 장비고). draw·클릭 공유.
-- @return table  UI 버튼 배열(value = 장비고 인덱스)
local function equipRows(state, px, py, pw)
  local rows = {}
  local inv = state.factionInventory and state.factionInventory[state.playerFactionId]
  if not inv then return rows end
  local pad, rh, rg = config.popup.pad, config.popup.rowHeight, config.popup.rowGap
  local x, y0, w = px + pad, py + pad + 46, pw - pad * 2
  for i, it in ipairs(inv) do
    rows[i] = UI.newButton(x, y0 + (i - 1) * (rh + rg), w, rh,
      it.name .. "  (" .. itemBonusText(it) .. ")", i)
  end
  return rows
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

-- 능력치 표시용(키 + 라벨). 무력/지력/정치/체력.
local STAT_VIEW = {
  { k = "might", label = "무력" }, { k = "intel", label = "지력" },
  { k = "pol", label = "정치" }, { k = "hp", label = "체력" },
}

local DISABLED = { text = { 0.5, 0.52, 0.58 }, border = { 0.3, 0.31, 0.36 } }

--- 장수 상세 팝업 본문(GDD 7·8장 표시 항목).
local function drawOfficerDetail(state, px, py, pw, ph)
  local o = detailOfficer(state)
  if not o then return end
  local pad, gap = config.popup.pad, config.popup.lineGap
  local x, y = px + pad, py + pad
  local mx, my = love.mouse.getPosition()

  love.graphics.setColor(config.colors.text)
  love.graphics.print(o.name .. (o.isLord and "  (군주)" or ""), x, y); y = y + gap + 4

  -- GDD 7·8장: 능력치는 유효치(기본+장비). 보너스 붙은 스탯만 색 강조.
  --   스탯마다 색이 달라 한 칸씩(열) 따로 그린다. love.graphics.print 는 setColor 직전 색을 쓴다.
  local colW = 130
  for i, s in ipairs(STAT_VIEW) do
    love.graphics.setColor(statColor(o, s.k))
    love.graphics.print(s.label .. " " .. GameState.effectiveStat(o, s.k), x + (i - 1) * colW, y)
  end
  love.graphics.setColor(config.colors.text)
  y = y + gap

  love.graphics.print("충성도: " .. tostring(GameState.loyaltyText(o)), x, y); y = y + gap
  love.graphics.print("보유 병력: " .. (o.troops or 0), x, y); y = y + gap
  love.graphics.print("소속 세력: " .. officerFactionName(state, o), x, y); y = y + gap
  local r = o.region and Region.byId(state.regions, o.region)
  love.graphics.print("위치 지역: " .. (r and r.name or "-"), x, y); y = y + gap
  love.graphics.print("상태: " .. (STATE_KR[o.state] or o.state), x, y); y = y + gap

  -- 태수 여부(GDD 5장): 이 장수가 태수로 있는 지역 역조회.
  local govRegion = state.governors and GameState.governorRegionOf(state.governors, o.id)
  local govReg = govRegion and Region.byId(state.regions, govRegion)
  love.graphics.print("태수: " .. (govReg and govReg.name or "—"), x, y); y = y + gap + 6

  -- GDD 8장 장비: 장비명 + 보너스 내역(없으면 "없음").
  if o.equip then
    love.graphics.print("보유 장비: " .. o.equip.name .. "  (" .. itemBonusText(o.equip) .. ")", x, y)
  else
    love.graphics.print("보유 장비: 없음", x, y)
  end
  y = y + gap

  -- 액션 버튼: 플레이어 세력 active 장수에게만 노출(GDD 8·15장).
  local isPlayer = (o.faction == state.playerFactionId) and (o.state == GameState.STATE.active)
  if not isPlayer then
    love.graphics.setColor(0.7, 0.72, 0.78)
    love.graphics.print("(플레이어 세력 장수만 태수/선물 가능)", x, py + ph - pad - 24)
    return
  end

  local govBtn, goldBtn, equipBtn = detailButtons(px, py, pw, ph)

  -- 태수 지정/해제: 이미 이 지역 태수면 "해제", 아니면 "지정".
  local isGovHere = state.governors and state.governors[o.region] == o.id
  govBtn.label = isGovHere and "태수 해제" or "태수 지정"
  UI.draw(govBtn, { hovered = UI.hit(govBtn, mx, my), accent = config.colors.selectBorder })

  -- 금 선물(수장 제외 / 턴 1회).
  if GameState.isGiftTarget(o, state.playerFactionId) and not o.giftedGoldThisTurn then
    UI.draw(goldBtn, { hovered = UI.hit(goldBtn, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(goldBtn, DISABLED)
  end

  -- 장비 선물(수장 제외 / 빈 장착칸 / 턴 1회 / 군주 장비고 비어있지 않음).
  local inv = state.factionInventory and state.factionInventory[state.playerFactionId]
  local equipOk = GameState.canGiftEquip(o) and inv and #inv > 0
  if equipOk then
    UI.draw(equipBtn, { hovered = UI.hit(equipBtn, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(equipBtn, DISABLED)
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

--- 장비 선물 서브팝업 본문(GDD 8·15장). 군주 장비고에서 골라 클릭하면 이전.
local function drawGiftEquip(state, px, py, pw)
  local o = detailOfficer(state)
  if not o then return end
  local pad = config.popup.pad
  love.graphics.setColor(config.colors.text)
  love.graphics.print("장비 선물 — " .. o.name, px + pad, py + pad)

  local mx, my = love.mouse.getPosition()
  local rows = equipRows(state, px, py, pw)
  if #rows == 0 then
    love.graphics.setColor(0.7, 0.72, 0.78)
    love.graphics.print("군주 보유(미장착) 장비가 없습니다.", px + pad, py + pad + 50)
    return
  end
  for _, btn in ipairs(rows) do
    UI.draw(btn, { hovered = UI.hit(btn, mx, my), accent = config.colors.selectBorder })
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
  elseif state.sub == "equip" then
    drawGiftEquip(state, px, py, pw)
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

  if state.sub == "equip" then
    -- 장비 선물 서브팝업: X=서브 닫기 / 장비 클릭 = 그 장비 이전(장착).
    if UI.hit(cb, x, y) then
      state.sub = nil
    else
      local o = detailOfficer(state)
      local inv = state.factionInventory and state.factionInventory[state.playerFactionId]
      if o and inv and GameState.canGiftEquip(o) then
        for _, btn in ipairs(equipRows(state, px, py, pw)) do
          if UI.hit(btn, x, y) then
            -- 규칙은 game_state(장비 이전 + 충성 상승). btn.value = 장비고 인덱스.
            GameState.applyGiftEquip(inv, btn.value, o)
            state.sub = nil
            break
          end
        end
      end
    end
    return true
  end

  if state.detailId then
    -- 장수 상세: X=목록으로 / 태수 지정·해제 / 금·장비 선물 서브팝업 열기.
    if UI.hit(cb, x, y) then
      state.detailId = nil
      return true
    end
    local o = detailOfficer(state)
    local isPlayer = o and (o.faction == state.playerFactionId) and (o.state == GameState.STATE.active)
    if isPlayer then
      local govBtn, goldBtn, equipBtn = detailButtons(px, py, pw, ph)
      if UI.hit(govBtn, x, y) then
        -- 태수 토글: 이미 이 지역 태수면 해제, 아니면 지정(같은 지역 active 만).
        if GameState.canSetGovernor(o, o.region) then
          if state.governors[o.region] == o.id then
            state.governors[o.region] = nil
          else
            state.governors[o.region] = o.id
          end
        end
      elseif UI.hit(goldBtn, x, y) then
        if GameState.isGiftTarget(o, state.playerFactionId) and not o.giftedGoldThisTurn then
          state.sub = "gold"; state.giftAmount = 1; state.notice = nil
        end
      elseif UI.hit(equipBtn, x, y) then
        local inv = state.factionInventory and state.factionInventory[state.playerFactionId]
        if GameState.canGiftEquip(o) and inv and #inv > 0 then
          state.sub = "equip"; state.notice = nil
        end
      end
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
