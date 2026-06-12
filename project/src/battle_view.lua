--[[
battle_view.lua — 전투 화면(그리드/유닛/입력) (표현·입력 계층) — GDD 13·17장

  이 모듈의 책임:
    - 전투 씬의 렌더(draw)와 입력(mousepressed/keypressed)을 담당한다.
      그리드·양측 유닛·선택 유닛 강조·이동/공격 가능 칸·전투용 턴 종료·결과 팝업.
    - 모든 "판정·데미지·이동 검증·승패·결과 반영"은 battle.lua(규칙)가 한다. 여기선 그리기/클릭만.
  관계:
    - main.lua  : scene=="battle" 일 때 draw/입력을 이 모듈에 위임. 전투 상태는 state.battle.
    - battle.lua: 규칙(canMove/moveUnit/canAttack/attack/endPlayerTurn/resolve).
    - ui.lua / config / region : 버튼, 색·레이아웃 상수, 지역 이름.
  설계:
    - draw 는 읽기만. 상태 변경은 입력에서만(battle.lua 호출로).
    - 화면 좌표 ↔ 그리드 좌표 변환은 한 곳(cellRect/cellAtScreen)에서(레이아웃 단일 출처).

  state 의존 필드(주입):
    battle(전투 상태), battleSelId(선택 유닛 officerId), regions, scenario, rng
--]]

local config = require("config")
local UI = require("ui")
local Region = require("region")
local Battle = require("battle")

local BattleView = {}

-- ── 레이아웃(화면 ↔ 그리드 좌표) ─────────────────────────

--- 그리드 전체 픽셀 크기 + 좌상단 원점(화면 가운데 정렬). draw·클릭 공유 단일 출처.
-- @return number originX, originY, number step(칸+간격)
local function gridOrigin()
  local v = config.battleView
  local b = config.battle
  local step = v.cell + v.gap
  local gw = b.gridW * v.cell + (b.gridW - 1) * v.gap
  local gh = b.gridH * v.cell + (b.gridH - 1) * v.gap
  local sw, sh = love.graphics.getDimensions()
  local originX = (sw - gw) / 2
  -- 세로는 헤더(위)·턴버튼(아래) 자리를 위해 살짝 위로.
  local originY = (sh - gh) / 2 - 10
  return originX, originY, step
end

--- 그리드 좌표(cx,cy)의 화면 사각형.
-- @return number x,y,w,h
local function cellRect(cx, cy)
  local ox, oy, step = gridOrigin()
  return ox + cx * step, oy + cy * step, config.battleView.cell, config.battleView.cell
end

--- 화면 좌표(mx,my)가 속한 그리드 칸(없으면 nil,nil).
local function cellAtScreen(mx, my)
  local b = config.battle
  for cy = 0, b.gridH - 1 do
    for cx = 0, b.gridW - 1 do
      local x, y, w, h = cellRect(cx, cy)
      if mx >= x and mx <= x + w and my >= y and my <= y + h then return cx, cy end
    end
  end
  return nil, nil
end

--- 전투용 "턴 종료" 버튼(하단 가운데).
local function endTurnButton()
  local sw, sh = love.graphics.getDimensions()
  local w, h = 240, 56
  return UI.newButton((sw - w) / 2, sh - h - 24, w, h, "전투 턴 종료", "endturn")
end

--- 결과 팝업의 "확인" 버튼.
local function resultButton(px, py, pw, ph)
  local w, h = 200, 52
  return UI.newButton(px + (pw - w) / 2, py + ph - h - 20, w, h, "확인", "ok")
end

-- ── 조회 ─────────────────────────────────────────────────

--- 현재 선택된 유닛(state.battleSelId). 죽었거나 없으면 nil.
local function selectedUnit(state)
  local b = state.battle
  if not (b and state.battleSelId) then return nil end
  local u = Battle.unitById(b, state.battleSelId)
  if u and u.hp > 0 then return u end
  return nil
end

-- ── 렌더 ─────────────────────────────────────────────────

--- 유닛 한 개를 칸 안에 그린다(진영색 + 이름 + HP). 선택 유닛은 노랑 테두리.
local function drawUnit(u, selected)
  local v = config.battleView
  local x, y, w, h = cellRect(u.x, u.y)
  local col = (u.side == Battle.SIDE.atk) and v.atkColor or v.defColor
  love.graphics.setColor(col[1], col[2], col[3], 0.9)
  love.graphics.rectangle("fill", x + 6, y + 6, w - 12, h - 12, 8, 8)
  if selected then
    love.graphics.setColor(v.selBorder)
    love.graphics.setLineWidth(4)
    love.graphics.rectangle("line", x + 4, y + 4, w - 8, h - 8, 8, 8)
  end
  -- 이름 + HP/최대HP(병력 = 내구도). 가독 위해 가운데 정렬.
  love.graphics.setColor(0.05, 0.05, 0.07)
  love.graphics.printf(u.name, x, y + 18, w, "center")
  love.graphics.printf("HP " .. u.hp .. "/" .. u.maxHp, x, y + 18 + 26, w, "center")
  love.graphics.printf(string.format("공%d 방%d", u.atk, u.def), x, y + 18 + 52, w, "center")
end

--- 전투 화면 본문. (읽기 전용)
function BattleView.draw(state)
  local b = state.battle
  if not b then return end
  local v = config.battleView
  love.graphics.clear(config.colors.background)

  -- 헤더: 공략 지역명 + 턴/생존 수.
  local toName = (Region.byId(state.regions, b.to) or {}).name or b.to
  local fromName = (Region.byId(state.regions, b.from) or {}).name or b.from
  love.graphics.setColor(config.colors.text)
  love.graphics.print(string.format("전투 — %s → %s 공략", fromName, toName), 24, 20)
  local turnText = (b.turn == Battle.SIDE.atk) and "내 턴(공격)" or "적 턴(방어)"
  love.graphics.print("현재: " .. turnText .. "    파랑=공격측  빨강=방어측", 24, 48)

  -- 빈 칸 배경.
  for cy = 0, config.battle.gridH - 1 do
    for cx = 0, config.battle.gridW - 1 do
      local x, y, w, h = cellRect(cx, cy)
      love.graphics.setColor(v.cellBg)
      love.graphics.rectangle("fill", x, y, w, h, 6, 6)
    end
  end

  -- 선택 유닛이 있으면 이동/공격 가능 칸 하이라이트(읽기 전용 — 규칙은 battle 가 판정).
  local sel = selectedUnit(state)
  if sel and b.turn == Battle.SIDE.atk and not b.over then
    for cy = 0, config.battle.gridH - 1 do
      for cx = 0, config.battle.gridW - 1 do
        if Battle.canMove(b, sel, cx, cy) then
          local x, y, w, h = cellRect(cx, cy)
          love.graphics.setColor(v.moveCell)
          love.graphics.rectangle("fill", x, y, w, h, 6, 6)
        end
      end
    end
    -- 공격 가능한 적 유닛 칸.
    for _, u in ipairs(b.units) do
      if u.hp > 0 and Battle.canAttack(b, sel, u) then
        local x, y, w, h = cellRect(u.x, u.y)
        love.graphics.setColor(v.atkCell)
        love.graphics.rectangle("fill", x, y, w, h, 6, 6)
      end
    end
  end

  -- 유닛.
  for _, u in ipairs(b.units) do
    if u.hp > 0 then drawUnit(u, sel and sel.officerId == u.officerId) end
  end

  -- 전투 턴 종료 버튼(공격 턴 + 진행 중일 때만 활성).
  local mx, my = love.mouse.getPosition()
  local et = endTurnButton()
  if not b.over then
    UI.draw(et, { hovered = UI.hit(et, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(et, { text = { 0.5, 0.52, 0.58 }, border = { 0.3, 0.31, 0.36 } })
  end

  -- 결과 팝업(전멸로 종료 시).
  if b.over then
    local sw, sh = love.graphics.getDimensions()
    love.graphics.setColor(config.popup.scrim)
    love.graphics.rectangle("fill", 0, 0, sw, sh)
    local pw, ph = 460, 220
    local px, py = (sw - pw) / 2, (sh - ph) / 2
    love.graphics.setColor(config.popup.bg)
    love.graphics.rectangle("fill", px, py, pw, ph, 10, 10)
    love.graphics.setColor(config.colors.text)
    local win = (b.result == Battle.SIDE.atk)
    love.graphics.printf(win and "승리 — 점령!" or "패배 — 후퇴", px, py + 40, pw, "center")
    love.graphics.printf(win and (toName .. " 을(를) 점령했다.") or "공격 병력을 잃고 물러난다.",
      px, py + 90, pw, "center")
    local ok = resultButton(px, py, pw, ph)
    UI.draw(ok, { hovered = UI.hit(ok, mx, my), accent = config.colors.selectBorder })
  end
end

-- ── 입력 ─────────────────────────────────────────────────

--- 전투 화면 클릭 처리. 규칙은 battle 가 수행.
-- 흐름:
--   · 결과 팝업 열림: "확인" 클릭 → true 반환(main 이 resolve + 맵 복귀).
--   · 진행 중: 턴 종료 버튼 → endPlayerTurn. 빈/적/아군 칸 클릭 → 선택·이동·공격.
-- @return boolean exit  결과 확인(전투 종료 후 맵 복귀)을 원하면 true
function BattleView.mousepressed(state, x, y)
  local b = state.battle
  if not b then return false end

  -- 결과 팝업: 확인 누르면 전투 종료(main 이 resolve).
  if b.over then
    local sw, sh = love.graphics.getDimensions()
    local pw, ph = 460, 220
    local px, py = (sw - pw) / 2, (sh - ph) / 2
    if UI.hit(resultButton(px, py, pw, ph), x, y) then return true end
    return false
  end

  -- 턴 종료 → 적 AI 처리.
  if UI.hit(endTurnButton(), x, y) then
    Battle.endPlayerTurn(b, state.rng)
    state.battleSelId = nil
    return false
  end

  -- 그리드 클릭만 의미 있음.
  local cx, cy = cellAtScreen(x, y)
  if not cx then return false end

  local sel = selectedUnit(state)
  local clicked = Battle.unitAt(b, cx, cy)

  -- 1) 선택 유닛이 있고, 클릭이 공격 가능한 적 → 공격.
  if sel and clicked and Battle.canAttack(b, sel, clicked) then
    Battle.attack(b, sel, clicked)
    return false
  end
  -- 2) 선택 유닛이 있고, 빈 칸이며 이동 가능 → 이동.
  if sel and not clicked and Battle.canMove(b, sel, cx, cy) then
    Battle.moveUnit(b, sel, cx, cy)
    return false
  end
  -- 3) 내 진영(공격측) 유닛 클릭 → 선택 전환.
  if clicked and clicked.side == Battle.SIDE.atk then
    state.battleSelId = clicked.officerId
    return false
  end
  -- 4) 그 외(빈 칸/적 클릭) → 선택 해제.
  state.battleSelId = nil
  return false
end

--- 전투 중 키 입력. ESC 는 맵으로 바로 튀지 않게 처리(GDD 13장).
--   · 결과 팝업 상태에서 ESC → 전투 종료(확인과 동일).
--   · 진행 중 ESC → 선택 해제(후퇴 없음 — 전투 이탈 불가).
-- @return boolean exit  전투 종료를 원하면 true
function BattleView.keypressed(state, key)
  if key ~= "escape" then return false end
  local b = state.battle
  if b and b.over then return true end
  state.battleSelId = nil
  return false
end

return BattleView
