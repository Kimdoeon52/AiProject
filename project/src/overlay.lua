--[[
overlay.lua — 게임 흐름 오버레이 팝업 (군주 선택 / ESC 메뉴) (표현·입력 보조)

  이 모듈의 책임:
    - 지도 위에 뜨는 "흐름 제어 모달"의 렌더(draw)와 클릭 처리(consumeClick)를 담당.
    - ① 군주(세력) 선택 팝업: 시나리오 진입 후 지도가 보이는 상태에서 군주를 고른다(GDD 3·17장).
    - ② ESC 게임 메뉴 팝업: [계속 진행] / [메인 화면으로] (GDD 17장).
  관계:
    - main.lua : 지도 draw 끝에서 Overlay.draw(state), mousepressed 최우선에서 Overlay.consumeClick(state,x,y).
                 군주 후보 강조(지도 영지)는 main.drawHexMap 이 state.factionPending 을 읽어 그린다.
    - game_data : 군주(lord) 이름 표시용 베이스 조회.
    - ui.lua / config : 버튼 렌더·클릭, 색/레이아웃 상수.
  설계:
    - main.lua 800줄 방지를 위해 "흐름 오버레이"라는 한 책임을 이 모듈로 분리(CLAUDE.md).
    - 규칙/게임상태 변경은 최소(군주 확정 = playerFactionId 설정, 메뉴 = 플래그). draw 는 읽기만.

  state 의존/주입 필드:
    factionSelectOpen(군주 선택 열림), factionPending(고른 후보 세력 id — 지도 강조 대상),
    menuOpen(ESC 메뉴 열림), menuExitToMain(메인 화면 복귀 요청 — main 이 처리),
    scenario, playerFactionId, selectedId
--]]

local config = require("config")
local UI = require("ui")
local game_data = require("game_data")

local Overlay = {}

-- ── 공통 ─────────────────────────────────────────────────

--- 장수 베이스에서 id 로 이름을 찾는다(군주 이름 표시용).
local function officerBaseName(id)
  for _, o in ipairs(game_data.officers) do
    if o.id == id then return o.name end
  end
  return id
end

--- 시나리오 세력을 id 기준 안정 정렬한 배열로(순회 순서 비결정 → 매번 같은 순서).
-- @return table { {id=, faction=}, ... }
local function sortedFactions(scenario)
  local list = {}
  for fid, f in pairs(scenario.factions) do
    list[#list + 1] = { id = fid, faction = f }
  end
  table.sort(list, function(a, b) return a.id < b.id end) -- C# List.Sort / C++ std::sort 와 같은 비교 정렬
  return list
end

--- 팝업 뒤 어둡게 까는 막(scrim) — 모달 강조.
local function drawScrim()
  local sw, sh = love.graphics.getDimensions()
  love.graphics.setColor(config.popup.scrim)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
end

-- 비활성(조건 미충족) 버튼 스타일.
local DISABLED = { text = { 0.5, 0.52, 0.58 }, border = { 0.3, 0.31, 0.36 } }

-- ── 군주(세력) 선택 ──────────────────────────────────────

--- 군주 선택 팝업 레이아웃(draw·클릭 공유 단일 출처). 세력 수에 맞춰 세로 가변 높이.
-- @return table { px,py,pw,ph, items={ {btn, fid, faction} }, confirm, headY }
local function factionLayout(state)
  local sw, sh = love.graphics.getDimensions()
  local list = sortedFactions(state.scenario)
  local bw, bh, gap = 560, 48, 10
  local headH, confirmH, padV = 56, 56, 24
  local n = #list
  local ph = padV + headH + n * (bh + gap) + confirmH + padV
  local pw = bw + 40
  local px, py = (sw - pw) / 2, (sh - ph) / 2
  local x = px + 20
  local y0 = py + padV + headH
  local items = {}
  for i, item in ipairs(list) do
    local label = string.format("%s   —   군주: %s", item.faction.name, officerBaseName(item.faction.lord))
    items[i] = { btn = UI.newButton(x, y0 + (i - 1) * (bh + gap), bw, bh, label, item.id),
                 fid = item.id, faction = item.faction }
  end
  local confirm = UI.newButton(x, y0 + n * (bh + gap) + 8, bw, confirmH, "이 세력으로 시작", "confirm")
  return { px = px, py = py, pw = pw, ph = ph, items = items, confirm = confirm, headY = py + padV }
end

--- 군주 선택 팝업 본문. (읽기 전용)
local function drawFactionSelect(state)
  drawScrim()
  local L = factionLayout(state)
  love.graphics.setColor(config.popup.bg)
  love.graphics.rectangle("fill", L.px, L.py, L.pw, L.ph, 10, 10)

  love.graphics.setColor(config.colors.text)
  love.graphics.printf("군주(세력) 선택 — 후보를 고르면 지도에 그 세력 영지가 강조됩니다",
    L.px, L.headY, L.pw, "center")

  local mx, my = love.mouse.getPosition()
  for _, it in ipairs(L.items) do
    -- 고른 후보(factionPending)는 항상 강조, 그 외엔 hover 강조.
    local selected = state.factionPending == it.fid
    UI.draw(it.btn, { hovered = selected or UI.hit(it.btn, mx, my), accent = config.colors.selectBorder })
    -- 세력색 견본(GDD 6장).
    love.graphics.setColor(it.faction.color)
    love.graphics.rectangle("fill", it.btn.x + 8, it.btn.y + it.btn.h / 2 - 9, 18, 18, 3, 3)
  end

  -- 확정 버튼: 후보를 골랐을 때만 활성.
  if state.factionPending then
    UI.draw(L.confirm, { hovered = UI.hit(L.confirm, mx, my), accent = config.colors.selectBorder })
  else
    UI.draw(L.confirm, DISABLED)
  end
end

--- 군주 선택 클릭 처리. 후보 클릭 = 강조 대상 지정 / 확정 = 게임 시작.
-- 부작용: state.factionPending(후보) 또는 playerFactionId 설정 + 팝업 닫기.
local function clickFactionSelect(state, x, y)
  local L = factionLayout(state)
  for _, it in ipairs(L.items) do
    if UI.hit(it.btn, x, y) then
      state.factionPending = it.fid -- 후보 지정(아직 확정 아님) → 지도 강조
      return
    end
  end
  if state.factionPending and UI.hit(L.confirm, x, y) then
    -- 군주 확정 = 그 세력으로 게임 시작(GDD 3장 흐름). 금은 지역별 보유라 별도 설정 없음(GDD 9장).
    state.playerFactionId = state.factionPending
    state.factionSelectOpen = false
    state.factionPending = nil
    state.selectedId = nil
  end
end

-- ── ESC 게임 메뉴 ────────────────────────────────────────

--- 메뉴 팝업 레이아웃(draw·클릭 공유).
-- @return table { px,py,pw,ph, cont, main, headY }
local function menuLayout()
  local sw, sh = love.graphics.getDimensions()
  local bw, bh, gap = 360, 56, 14
  local headH, padV = 40, 24
  local pw = bw + 48
  local ph = padV + headH + bh * 2 + gap + padV
  local px, py = (sw - pw) / 2, (sh - ph) / 2
  local x = px + 24
  local y0 = py + padV + headH
  local cont = UI.newButton(x, y0, bw, bh, "계속 진행", "continue")
  local main = UI.newButton(x, y0 + bh + gap, bw, bh, "메인 화면으로", "main")
  return { px = px, py = py, pw = pw, ph = ph, cont = cont, main = main, headY = py + padV }
end

--- ESC 메뉴 팝업 본문. (읽기 전용)
local function drawMenu()
  drawScrim()
  local L = menuLayout()
  love.graphics.setColor(config.popup.bg)
  love.graphics.rectangle("fill", L.px, L.py, L.pw, L.ph, 10, 10)
  love.graphics.setColor(config.colors.text)
  love.graphics.printf("게임 메뉴", L.px, L.headY, L.pw, "center")
  local mx, my = love.mouse.getPosition()
  UI.draw(L.cont, { hovered = UI.hit(L.cont, mx, my), accent = config.colors.selectBorder })
  UI.draw(L.main, { hovered = UI.hit(L.main, mx, my), accent = config.colors.selectBorder })
end

--- 메뉴 클릭 처리. [계속]=닫기 / [메인]=메인 복귀 요청(main 이 리셋 수행).
local function clickMenu(state, x, y)
  local L = menuLayout()
  if UI.hit(L.cont, x, y) then
    state.menuOpen = false
  elseif UI.hit(L.main, x, y) then
    state.menuOpen = false
    state.menuExitToMain = true -- main.mousepressed 가 이 플래그를 보고 시나리오 선택으로 리셋
  end
end

-- ── 디스패치 ─────────────────────────────────────────────

--- 오버레이를 그린다(모달). 열린 게 없으면 아무것도 안 그림. (읽기 전용)
function Overlay.draw(state)
  if state.factionSelectOpen then
    drawFactionSelect(state)
  elseif state.menuOpen then
    drawMenu()
  end
end

--- 오버레이가 열려 있으면 클릭을 처리하고 true(클릭 소비)를 돌려준다(모달).
-- @return boolean  열려 있었으면 true(지도/패널로 클릭 안 넘김)
function Overlay.consumeClick(state, x, y)
  if state.factionSelectOpen then
    clickFactionSelect(state, x, y); return true
  elseif state.menuOpen then
    clickMenu(state, x, y); return true
  end
  return false
end

--- 지도가 군주 후보 영지를 강조해야 하는지(있으면 강조 대상 세력 id). main.drawHexMap 이 사용.
-- @return string|nil  강조할 세력 id(군주 선택 중 + 후보 지정됨), 아니면 nil
function Overlay.highlightFaction(state)
  if state.factionSelectOpen then return state.factionPending end
  return nil
end

return Overlay
