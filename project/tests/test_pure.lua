--[[
test_pure.lua — 순수 Lua 단위 테스트 (love 비의존)

  목적:
    - camera.lua / region.lua 의 순수 함수와 game_data 무결성을 love 없이 검증.
    - 표준 Lua 인터프리터로 실행 가능:  lua project/tests/test_pure.lua
      (프로젝트 루트에서 실행 가정. package.path 에 ../src 를 추가한다.)

  검증 항목:
    - camera: screenToWorld/worldToScreen 왕복, move, zoomAt 커서 고정.
    - region: byId, areAdjacent, hitTest, connections 중복 제거.
    - game_data: neighbors 양방향 일관성(A↔B), 지역 수 ~40.
--]]

-- src 모듈을 찾도록 경로 추가 (이 파일은 project/tests/ 에 있음).
package.path = "project/src/?.lua;" .. package.path

local Camera = require("camera")
local Region = require("region")
local Voronoi = require("voronoi")
local game_data = require("game_data")

local passed, failed = 0, 0

-- 간단한 단언 헬퍼. 조건 거짓이면 메시지 출력하고 실패 카운트.
local function check(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("  [FAIL] " .. msg)
  end
end

-- 부동소수 근사 비교 (좌표 변환 오차 허용).
local function approx(a, b)
  return math.abs(a - b) < 1e-6
end

-- ── camera ───────────────────────────────────────────────
do
  local cam = Camera.new({ x = 100, y = 50, scale = 2 })

  -- worldToScreen 후 screenToWorld 하면 제자리(왕복 항등).
  local sx, sy = Camera.worldToScreen(cam, 300, 200)
  local wx, wy = Camera.screenToWorld(cam, sx, sy)
  check(approx(wx, 300) and approx(wy, 200), "camera 왕복 변환 항등")

  -- screen=(world-cam)*scale 직접 검증: (300-100)*2 = 400
  check(approx(sx, 400) and approx(sy, 300), "worldToScreen 수식")

  -- move: 스크린 10px 이동은 scale=2 에서 월드 5 이동.
  local cam2 = Camera.new({ x = 0, y = 0, scale = 2 })
  Camera.move(cam2, 10, 20)
  check(approx(cam2.x, 5) and approx(cam2.y, 10), "move scale 보정")

  -- zoomAt: 커서 아래 월드 점이 줌 후에도 같은 화면 위치 유지.
  local cam3 = Camera.new({ x = 0, y = 0, scale = 1, minScale = 0.4, maxScale = 3 })
  local before = { Camera.screenToWorld(cam3, 400, 300) }
  Camera.zoomAt(cam3, 1.5, 400, 300)
  local after = { Camera.screenToWorld(cam3, 400, 300) }
  check(approx(before[1], after[1]) and approx(before[2], after[2]), "zoomAt 커서 고정")

  -- 줌 클램프: 큰 배율 반복해도 maxScale 초과 금지.
  Camera.zoomAt(cam3, 100, 400, 300)
  check(cam3.scale <= 3 + 1e-9, "zoomAt maxScale 클램프")
end

-- ── region ───────────────────────────────────────────────
do
  local regions = game_data.regions

  check(Region.byId(regions, "luoyang") ~= nil, "byId 낙양 조회")
  check(Region.byId(regions, "nope") == nil, "byId 미존재 nil")

  -- 데이터상 ye↔luoyang 인접.
  check(Region.areAdjacent(regions, "ye", "luoyang"), "areAdjacent ye-luoyang")
  check(not Region.areAdjacent(regions, "ye", "chengdu"), "비인접 ye-chengdu")

  -- hitTest: 낙양 중심 좌표 클릭 시 낙양 반환.
  local ly = Region.byId(regions, "luoyang")
  local hit = Region.hitTest(regions, ly.x, ly.y, 26)
  check(hit and hit.id == "luoyang", "hitTest 중심 명중")
  -- 멀리 떨어진 빈 좌표는 nil.
  check(Region.hitTest(regions, -9999, -9999, 26) == nil, "hitTest 빈 곳 nil")

  -- connections: 중복 없는 변 목록. 각 변은 4원소.
  local lines = Region.connections(regions)
  check(#lines > 0, "connections 비어있지 않음")
  check(#lines[1] == 4, "connection 원소 4개(x1,y1,x2,y2)")
end

-- ── game_data 무결성 ─────────────────────────────────────
do
  local regions = game_data.regions

  -- 지역 수 약 40.
  check(#regions == 40, "지역 수 40 (실제=" .. #regions .. ")")

  -- neighbors 양방향 일관: A가 B를 이웃이면 B도 A를 이웃이어야.
  local bad = 0
  for _, a in ipairs(regions) do
    for _, nid in ipairs(a.neighbors or {}) do
      if not Region.areAdjacent(regions, nid, a.id) then
        bad = bad + 1
        print(string.format("  [edge] %s -> %s 단방향", a.id, nid))
      end
    end
  end
  check(bad == 0, "neighbors 양방향 일관")

  -- owner 값은 정해진 4종 중 하나.
  local validOwner = { wei = true, shu = true, wu = true, neutral = true }
  local badOwner = 0
  for _, r in ipairs(regions) do
    if not validOwner[r.owner] then badOwner = badOwner + 1 end
  end
  check(badOwner == 0, "owner 값 유효")
end

-- ── voronoi (영토 분할) ──────────────────────────────────
do
  local regions = game_data.regions

  -- cellAt: 시드 좌표를 찍으면 그 자신 영토가 선택되어야 한다.
  --   (보로노이 셀 = 최근접 시드 영역이므로 시드 위치는 항상 자기 셀.)
  local selfHitOk = true
  for _, r in ipairs(regions) do
    local c = Region.cellAt(regions, r.x, r.y)
    if not c or c.id ~= r.id then selfHitOk = false end
  end
  check(selfHitOk, "cellAt 시드 위치는 자기 영토")

  -- 셀 개수 = 지역 수, 각 셀은 볼록 다각형(>=3 정점 = 6값).
  local bbox = Voronoi.boundsOf(regions, 140)
  local cells = Voronoi.computeCells(regions, bbox)
  check(#cells == #regions, "셀 개수 = 지역 수")

  local allConvexEnough = true
  for _, poly in ipairs(cells) do
    if #poly < 6 then allConvexEnough = false end
  end
  check(allConvexEnough, "모든 셀 >=3 정점")

  -- bbox 여백 적용: 시드 최소값보다 margin 만큼 더 바깥.
  check(bbox.x0 < 360 and bbox.y0 < 140, "boundsOf 여백 적용")
end

-- ── 결과 ─────────────────────────────────────────────────
print(string.format("\n테스트 결과: %d 통과 / %d 실패", passed, failed))
os.exit(failed == 0 and 0 or 1)
