--[[
ui.lua — 버튼 렌더링 + 클릭 판정 (표현 보조)

  이 모듈의 책임:
    - 사각 버튼 데이터(위치/크기/라벨)를 만들고, 점-사각 클릭 판정(hit)을 제공한다.
    - 버튼을 그린다(draw). 그리기는 love.graphics 사용(표현 계층 보조).
  관계:
    - main.lua 가 시나리오 선택 화면 등에서 버튼 목록을 만들고 그린다.
  주의: hit 은 순수 함수(love 비의존)라 테스트 가능. draw 만 love 의존.
--]]

local UI = {}

--- 버튼 하나를 만든다.
-- @param x,y,w,h number  화면 좌표·크기(px)
-- @param label string    표시 문구
-- @param value any       이 버튼이 나타내는 값(클릭 결과로 쓰는 식별자 등)
-- @return table  버튼 레코드
function UI.newButton(x, y, w, h, label, value)
  return { x = x, y = y, w = w, h = h, label = label, value = value }
end

--- 점(mx,my)이 버튼 사각 안인지. (순수)
-- @param btn table
-- @param mx,my number  스크린 좌표
-- @return boolean
function UI.hit(btn, mx, my)
  return mx >= btn.x and mx <= btn.x + btn.w
     and my >= btn.y and my <= btn.y + btn.h
end

--- 버튼을 그린다. (love 의존)
-- @param btn table
-- @param opts table  { hovered, bg, border, text, accent } 색/상태
--   hovered=true 면 accent 테두리로 강조.
function UI.draw(btn, opts)
  opts = opts or {}
  local bg = opts.bg or { 0.18, 0.19, 0.23 }
  local border = (opts.hovered and (opts.accent or { 1, 0.85, 0.2 })) or (opts.border or { 0.4, 0.4, 0.45 })
  local text = opts.text or { 0.95, 0.95, 0.95 }

  -- 배경 채움 — love.graphics.rectangle("fill", x,y,w,h): 사각형 채우기.
  love.graphics.setColor(bg)
  love.graphics.rectangle("fill", btn.x, btn.y, btn.w, btn.h, 8, 8) -- 8 = 모서리 둥글기

  -- 테두리 — "line" 모드.
  love.graphics.setColor(border)
  love.graphics.setLineWidth(opts.hovered and 3 or 2)
  love.graphics.rectangle("line", btn.x, btn.y, btn.w, btn.h, 8, 8)

  -- 라벨 — 버튼 안 세로 가운데 정렬(printf 가운데).
  love.graphics.setColor(text)
  local font = love.graphics.getFont()
  local ty = btn.y + (btn.h - font:getHeight()) / 2
  love.graphics.printf(btn.label, btn.x + 12, ty, btn.w - 24, "center")
end

return UI
