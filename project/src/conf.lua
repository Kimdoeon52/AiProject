--[[
conf.lua — LÖVE2D 설정 진입점

  이 모듈의 책임:
    - LÖVE 가 게임을 켜기 직전 호출하는 love.conf(t) 콜백을 정의한다.
    - 창 크기/제목/콘솔/vsync 등 런타임 옵션을 지정한다.
  관계:
    - 창 수치는 config.lua(단일 출처)에서 읽어온다. 여기 직접 박지 않는다.

  주의: love.conf 는 main.lua 의 love.load 보다 먼저, 창이 만들어지기 전에
        실행된다. 그래서 여기서 require 한 config 의 window 값으로 창을 잡는다.
--]]

local config = require("config")

-- LÖVE 진입 설정 콜백.
-- @param t table  LÖVE 가 넘겨주는 기본 설정 테이블. 필요한 필드만 덮어쓴다.
function love.conf(t)
  t.window.title = config.window.title
  t.window.width = config.window.width   -- 1920 (Full HD)
  t.window.height = config.window.height -- 1080
  t.window.resizable = true              -- 창 크기 조절 허용
  t.window.vsync = 1                      -- 수직동기화 ON (화면 찢김 방지)

  t.console = true -- Windows 콘솔 출력 창 (print 디버그용)
end
