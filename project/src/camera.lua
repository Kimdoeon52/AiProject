--[[
camera.lua — 카메라 좌표 변환 / 이동 / 줌 (순수 Lua, love 비의존)

  이 모듈의 책임:
    - 2D 카메라 상태(x, y, scale)를 들고, 스크린↔월드 좌표 변환을 제공한다.
    - 드래그 이동(move)과 커서 고정 줌(zoomAt)을 계산한다.
  관계:
    - 표현 계층(main.lua)이 이 변환 결과로 화면을 그리고 입력을 해석한다.
    - love.* 를 일절 부르지 않는다 → project/tests/ 에서 순수 단위 테스트 가능.
      (실제 화면 translate/scale 은 main.lua draw 가 cam 값으로 직접 수행한다.)

  좌표계 설명:
    - (cam.x, cam.y) = 현재 화면 좌상단(0,0)에 대응하는 월드 좌표.
    - cam.scale = 확대 배율. 1이면 1월드단위=1픽셀, 2면 2배 확대.
    - 변환식:
        screen = (world - cam.xy) * scale
        world  = screen / scale + cam.xy
--]]

local Camera = {}

--- 카메라를 새로 만든다.
-- @param opts table  { x, y, scale, minScale, maxScale } (일부 생략 가능)
-- @return table  카메라 상태 테이블
function Camera.new(opts)
  opts = opts or {}
  return {
    x = opts.x or 0,            -- 화면 좌상단의 월드 X
    y = opts.y or 0,            -- 화면 좌상단의 월드 Y
    scale = opts.scale or 1,    -- 현재 줌 배율
    minScale = opts.minScale or 0.1, -- 줌 하한(전체 지도 fit 배율)
    maxScale = opts.maxScale or 10,  -- 줌 상한
    bounds = opts.bounds,       -- { x0,y0,x1,y1 } 지도 월드 경계(클램프용). nil 이면 무제한
  }
end

--- 값을 [lo, hi] 범위로 자른다. (줌 배율 클램프용)
local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

--- 스크린 좌표 → 월드 좌표.
-- @param cam table
-- @param sx number  스크린 X (픽셀)
-- @param sy number  스크린 Y (픽셀)
-- @return number, number  월드 X, Y
function Camera.screenToWorld(cam, sx, sy)
  return sx / cam.scale + cam.x, sy / cam.scale + cam.y
end

--- 월드 좌표 → 스크린 좌표.
-- @param cam table
-- @param wx number  월드 X
-- @param wy number  월드 Y
-- @return number, number  스크린 X, Y
function Camera.worldToScreen(cam, wx, wy)
  return (wx - cam.x) * cam.scale, (wy - cam.y) * cam.scale
end

--- 카메라를 스크린 드래그량만큼 이동한다.
-- 드래그는 픽셀 단위라 scale 로 나눠 월드 이동량으로 환산한다.
-- (확대 상태일수록 같은 픽셀 드래그가 더 적은 월드 거리만 움직이게.)
-- @param cam table
-- @param dxScreen number  스크린 X 이동 픽셀
-- @param dyScreen number  스크린 Y 이동 픽셀
-- @return table  cam (체이닝 편의)
function Camera.move(cam, dxScreen, dyScreen)
  cam.x = cam.x + dxScreen / cam.scale
  cam.y = cam.y + dyScreen / cam.scale
  return cam
end

--- 커서(sx, sy)를 고정점으로 두고 줌한다.
-- 핵심: 줌 전/후에 "커서가 가리키는 월드 점"이 같은 화면 위치에 머물러야
--       자연스러운 휠 줌이 된다. 그래서
--       1) 줌 전 커서의 월드 좌표를 구하고
--       2) scale 을 factor 배 한 뒤 한계로 클램프하고
--       3) 그 월드 점이 다시 같은 스크린 위치에 오도록 cam.x/y 를 역산한다.
-- @param cam table
-- @param factor number  배율 (>1 확대, <1 축소)
-- @param sx number  커서 스크린 X
-- @param sy number  커서 스크린 Y
-- @return table  cam
function Camera.zoomAt(cam, factor, sx, sy)
  -- 1) 줌 전 커서가 가리키던 월드 좌표
  local wx, wy = Camera.screenToWorld(cam, sx, sy)

  -- 2) 배율 적용 + 한계 클램프
  cam.scale = clamp(cam.scale * factor, cam.minScale, cam.maxScale)

  -- 3) 같은 월드 점(wx,wy)이 같은 스크린 점(sx,sy)에 오도록 좌상단 재계산
  --    world = screen/scale + cam.xy  →  cam.xy = world - screen/scale
  cam.x = wx - sx / cam.scale
  cam.y = wy - sy / cam.scale
  return cam
end

--- 지도 경계와 화면 크기에 맞춰 줌 하한(minScale)을 다시 계산한다.
-- 줌아웃 바닥 = "전체 지도가 화면 안에 다 들어오는 배율"(fit). 더는 못 줄임.
--   fit = min(화면폭/지도폭, 화면높이/지도높이).
-- @param cam table  bounds 가 설정돼 있어야 함
-- @param sw,sh number  화면 픽셀 크기
-- @return number  계산된 fit 배율(= 새 minScale)
function Camera.fitScale(cam, sw, sh)
  local b = cam.bounds
  if not b then return cam.minScale end
  local bw, bh = b.x1 - b.x0, b.y1 - b.y0
  return math.min(sw / bw, sh / bh)
end

--- 카메라 위치를 지도 경계 안으로 가둔다 (팬 클램프).
-- 보이는 월드 영역 [x, x+vw] × [y, y+vh] 가 bounds 를 벗어나지 못하게 한다.
-- 보이는 영역이 지도보다 크면(축소 상태) 가운데 정렬해 한쪽으로 못 치우게 한다.
-- @param cam table  bounds 필요
-- @param sw,sh number  화면 픽셀 크기
-- @return table  cam
function Camera.clamp(cam, sw, sh)
  local b = cam.bounds
  if not b then return cam end
  local vw, vh = sw / cam.scale, sh / cam.scale -- 보이는 월드 폭/높이
  local bw, bh = b.x1 - b.x0, b.y1 - b.y0

  -- 가로: 지도보다 넓게 보이면 중앙 고정, 아니면 [x0, x1-vw] 로 클램프.
  if vw >= bw then
    cam.x = b.x0 - (vw - bw) / 2
  else
    cam.x = clamp(cam.x, b.x0, b.x1 - vw)
  end
  -- 세로: 동일 규칙.
  if vh >= bh then
    cam.y = b.y0 - (vh - bh) / 2
  else
    cam.y = clamp(cam.y, b.y0, b.y1 - vh)
  end
  return cam
end

return Camera
