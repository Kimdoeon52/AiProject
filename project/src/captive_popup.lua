--[[
captive_popup.lua — 포로 처리(등용/처형) 모달 팝업 (표현·입력) — GDD 14·17장

  이 모듈의 책임:
    - 플레이어가 점령으로 포로를 얻었을 때 뜨는 모달의 렌더(draw)·클릭(consumeClick).
    - 포로마다 [등용][처형] 두 버튼. 처리된 포로는 목록에서 빠지고, 다 처리하면 닫힌다.
    - 규칙(등용 확률·편입·처형·장비 귀속)은 captive.lua 가 수행. 여기선 호출·표시만.
  관계:
    - main.lua    : 전투 승리 후 포로가 생기면 state.captives/captiveRegion 채우고 captivesOpen=true.
                    draw 에서 CaptivePopup.draw(state), mousepressed 에서 consumeClick(state,x,y).
    - captive.lua : recruitChance / attemptRecruit / execute.
    - game_state / config / region : 상태, 상수, 지역 이름.
  설계: draw 읽기 전용. 상태 변경은 consumeClick 에서만.

  state 의존 필드(주입):
    captivesOpen, captives(포로 장수 배열), captiveRegion(점령 지역 id), notice,
    playerFactionId, factionInventory, scenario, regions, rng
--]]

local config = require("config")
local UI = require("ui")
local Region = require("region")
local Captive = require("captive")

local CaptivePopup = {}

--- 화면 중앙 팝업 사각형(스크린 좌표). 다른 팝업과 동일 규격.
local function popupRect()
  local sw, sh = love.graphics.getDimensions()
  local w, h = config.popup.width, config.popup.height
  return (sw - w) / 2, (sh - h) / 2, w, h
end

--- 포로 행 레이아웃(이름/정보 + 등용·처형 버튼). draw·클릭 공유 단일 출처.
-- @return table  { {officer, y, recruit=btn, execute=btn}, ... }
local function rows(state, px, py, pw)
  local out = {}
  local pad, bh = config.popup.pad, config.popup.buttonHeight
  local x, w = px + pad, pw - pad * 2
  local y = py + pad + 50
  local rowH = bh + 30 -- 정보 한 줄 + 버튼 줄
  for i, o in ipairs(state.captives or {}) do
    local bw = (w - 12) / 2
    local by = y + 28 -- 버튼은 정보 줄 아래
    out[i] = {
      officer = o, y = y,
      recruit = UI.newButton(x, by, bw, bh, "등용", "recruit"),
      execute = UI.newButton(x + bw + 12, by, bw, bh, "처형", "execute"),
    }
    y = y + rowH + 14
  end
  return out
end

--- 포로 처리 팝업 본문. (읽기 전용)
function CaptivePopup.draw(state)
  if not state.captivesOpen then return end
  local sw, sh = love.graphics.getDimensions()
  love.graphics.setColor(config.popup.scrim)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  local px, py, pw, ph = popupRect()
  love.graphics.setColor(config.popup.bg)
  love.graphics.rectangle("fill", px, py, pw, ph, 10, 10)

  local pad = config.popup.pad
  local reg = state.captiveRegion and Region.byId(state.regions, state.captiveRegion)
  love.graphics.setColor(config.colors.text)
  love.graphics.print((reg and reg.name or "") .. " 포로 처리", px + pad, py + pad)

  local mx, my = love.mouse.getPosition()
  for _, r in ipairs(rows(state, px, py, pw)) do
    local o = r.officer
    -- 등용 확률은 충성 낮을수록 높음(GDD 14장). %.0f = 정수 표시.
    love.graphics.setColor(config.colors.text)
    love.graphics.print(string.format("%s   충성 %s   등용 성공률 %.0f%%",
      o.name, tostring(o.loyalty or 0), Captive.recruitChance(o) * 100), px + pad, r.y)
    UI.draw(r.recruit, { hovered = UI.hit(r.recruit, mx, my), accent = config.colors.selectBorder })
    UI.draw(r.execute, { hovered = UI.hit(r.execute, mx, my), accent = config.colors.statPenalty })
  end

  if state.notice then
    love.graphics.setColor(config.colors.panelValue)
    love.graphics.print(state.notice, px + pad, py + ph - 36)
  end
end

--- 처리한 포로를 목록에서 제거하고, 다 처리했으면 팝업을 닫는다(내부).
local function removeCaptive(state, officer)
  for i, o in ipairs(state.captives) do
    if o == officer then table.remove(state.captives, i); break end
  end
  if #state.captives == 0 then
    state.captivesOpen = false
    state.captiveRegion = nil
    state.notice = nil
  end
end

--- 포로 팝업 클릭 처리(모달). 등용/처형 per 포로. 규칙은 captive 가 수행.
-- @return boolean  팝업 열려 있었으면 true(클릭 소비)
function CaptivePopup.consumeClick(state, x, y)
  if not state.captivesOpen then return false end
  local px, py, pw = popupRect()
  for _, r in ipairs(rows(state, px, py, pw)) do
    local o = r.officer
    if UI.hit(r.recruit, x, y) then
      -- 등용 시도(충성 낮을수록 ↑). 성공 → 우리 세력 편입(목록에서 제거), 실패 → 포로 유지.
      if Captive.attemptRecruit(o, state.playerFactionId, state.captiveRegion, state.rng) then
        state.notice = o.name .. " 등용 성공 — 세력 편입"
        removeCaptive(state, o)
      else
        state.notice = o.name .. " 등용 실패(다시 시도 또는 처형)"
      end
      return true
    end
    if UI.hit(r.execute, x, y) then
      -- 처형: 사망 + 장비는 군주(플레이어 세력) 장비고로 귀속(GDD 14장).
      state.factionInventory[state.playerFactionId] = state.factionInventory[state.playerFactionId] or {}
      Captive.execute(o, state.factionInventory[state.playerFactionId])
      state.notice = o.name .. " 처형"
      removeCaptive(state, o)
      return true
    end
  end
  return true -- 모달: 바깥 클릭도 소비(다 처리할 때까지 닫히지 않음)
end

return CaptivePopup
