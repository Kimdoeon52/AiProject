--[[
test_pure.lua — 순수 Lua 단위 테스트 (love 비의존)

  목적:
    - camera / hex / region 순수 함수 + game_data 무결성을 love 없이 검증.
    - 실행:  lua project/tests/test_pure.lua  (프로젝트 루트 기준)

  검증:
    - camera: 왕복 변환, move, zoomAt 커서 고정/클램프.
    - hex: axial↔pixel 왕복, neighbors 6, corners 12값.
    - region: byId, areAdjacent(헥스), adjacent, cellAt 중심 명중.
    - game_data: 30지역, axial 중복 없음, owner 유효, GDD 명시 이름 일치, 금지지명 없음.
--]]

package.path = "project/src/?.lua;" .. package.path

local Camera = require("camera")
local Hex = require("hex")
local Region = require("region")
local game_data = require("game_data")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1
  else failed = failed + 1; print("  [FAIL] " .. msg) end
end
local function approx(a, b) return math.abs(a - b) < 1e-6 end

-- ── camera ───────────────────────────────────────────────
do
  local cam = Camera.new({ x = 100, y = 50, scale = 2 })
  local sx, sy = Camera.worldToScreen(cam, 300, 200)
  local wx, wy = Camera.screenToWorld(cam, sx, sy)
  check(approx(wx, 300) and approx(wy, 200), "camera 왕복 변환 항등")
  check(approx(sx, 400) and approx(sy, 300), "worldToScreen 수식")

  local cam2 = Camera.new({ x = 0, y = 0, scale = 2 })
  Camera.move(cam2, 10, 20)
  check(approx(cam2.x, 5) and approx(cam2.y, 10), "move scale 보정")

  local cam3 = Camera.new({ x = 0, y = 0, scale = 1, minScale = 0.4, maxScale = 3 })
  local b = { Camera.screenToWorld(cam3, 400, 300) }
  Camera.zoomAt(cam3, 1.5, 400, 300)
  local a = { Camera.screenToWorld(cam3, 400, 300) }
  check(approx(b[1], a[1]) and approx(b[2], a[2]), "zoomAt 커서 고정")
  Camera.zoomAt(cam3, 100, 400, 300)
  check(cam3.scale <= 3 + 1e-9, "zoomAt maxScale 클램프")
end

-- ── camera 경계/줌 클램프 ────────────────────────────────
do
  local b = { x0 = 0, y0 = 0, x1 = 1000, y1 = 500 }
  local cam = Camera.new({ bounds = b })

  -- fitScale = min(2000/1000, 1000/500) = 2
  check(approx(Camera.fitScale(cam, 2000, 1000), 2), "fitScale = 전체 fit")

  -- 줌아웃(scale=fit=2): 보이는 폭 vw=2000/2=1000=지도폭 → 중앙 고정(cam.x=0).
  cam.scale = 2
  Camera.clamp(cam, 2000, 1000)
  check(approx(cam.x, 0) and approx(cam.y, 0), "clamp 축소 시 중앙 고정")

  -- 줌인(scale=4): vw=500 < 1000. 왼쪽 밖(-100) → x0=0 으로, 오른쪽 밖(9999) → x1-vw=500.
  cam.scale = 4
  cam.x = -100; cam.y = -100
  Camera.clamp(cam, 2000, 1000)
  check(cam.x >= 0 - 1e-9, "clamp 좌측 경계")
  cam.x = 9999
  Camera.clamp(cam, 2000, 1000)
  check(approx(cam.x, 1000 - 500), "clamp 우측 경계")
end

-- ── hex ──────────────────────────────────────────────────
do
  local size = 64
  -- axial→pixel→axial 왕복(중심 픽셀은 그 헥스로 되돌아와야).
  local roundtripOk = true
  for _, qr in ipairs({ { 0, 0 }, { 2, 1 }, { -1, 3 }, { 4, 2 }, { -2, 4 } }) do
    local px, py = Hex.axialToPixel(qr[1], qr[2], size)
    local q, r = Hex.pixelToAxial(px, py, size)
    if q ~= qr[1] or r ~= qr[2] then roundtripOk = false end
  end
  check(roundtripOk, "hex axial↔pixel 왕복")

  local nb = Hex.neighbors(0, 0)
  check(#nb == 6, "hex 인접 6방향")

  local cor = Hex.corners(0, 0, size)
  check(#cor == 12, "hex 꼭짓점 6개(12값)")
end

-- ── region ───────────────────────────────────────────────
do
  local regions = game_data.regions
  local size = 64

  check(Region.byId(regions, "luoyang") ~= nil, "byId 낙양")
  check(Region.byId(regions, "nope") == nil, "byId 미존재 nil")

  -- 헥스 인접: 낙양(0,2) ↔ 홍농(1,2) 인접, 낙양 ↔ 북평(4,0) 비인접.
  check(Region.areAdjacent(regions, "luoyang", "hongnong"), "areAdjacent 낙양-홍농")
  check(not Region.areAdjacent(regions, "luoyang", "beiping"), "비인접 낙양-북평")

  -- adjacent 목록에 홍농 포함.
  local adj = Region.adjacent(regions, "luoyang")
  local hasHongnong = false
  for _, r in ipairs(adj) do if r.id == "hongnong" then hasHongnong = true end end
  check(hasHongnong, "adjacent 낙양 포함 홍농")

  -- cellAt: 낙양 중심 픽셀 클릭 → 낙양. (좌표는 데이터에서 읽어 q,r 변경에 견고)
  local ly = Region.byId(regions, "luoyang")
  local px, py = Hex.axialToPixel(ly.q, ly.r, size)
  local hit = Region.cellAt(regions, px, py, size)
  check(hit and hit.id == "luoyang", "cellAt 중심 명중")
end

-- ── game_data 무결성 ─────────────────────────────────────
do
  local regions = game_data.regions

  check(#regions == 30, "지역 수 30 (실제=" .. #regions .. ")")

  -- axial (q,r) 중복 없음.
  local seen, dup = {}, 0
  for _, r in ipairs(regions) do
    local k = r.q .. "," .. r.r
    if seen[k] then dup = dup + 1; print("  [dup] " .. k) end
    seen[k] = true
  end
  check(dup == 0, "axial 좌표 중복 없음")

  -- owner 유효.
  local valid = { wei = true, shu = true, wu = true, neutral = true }
  local badOwner = 0
  for _, r in ipairs(regions) do
    if not valid[r.owner] then badOwner = badOwner + 1 end
  end
  check(badOwner == 0, "owner 값 유효")

  -- GDD 5장 명시 30 이름과 정확히 일치.
  local expected = {
    "북평","발해","업","평원","진양","낙양","장안","홍농","복양","진류",
    "허창","여남","하비","팽성","광릉","신야","양양","강릉","장사","무릉",
    "건업","오군","회계","시상","성도","한중","강주","운남","천수","무위",
  }
  local expSet = {}
  for _, n in ipairs(expected) do expSet[n] = true end
  local nameSet = {}
  for _, r in ipairs(regions) do nameSet[r.name] = true end
  local missing = 0
  for _, n in ipairs(expected) do if not nameSet[n] then missing = missing + 1; print("  [missing] " .. n) end end
  local extra = 0
  for n in pairs(nameSet) do if not expSet[n] then extra = extra + 1; print("  [extra] " .. n) end end
  check(missing == 0 and extra == 0, "GDD 명시 30 이름 일치")

  -- 금지 지명 없음 (CLAUDE.md: 백제/신라/고구려 등).
  local banned = { ["백제"] = true, ["신라"] = true, ["고구려"] = true }
  local bad = 0
  for _, r in ipairs(regions) do if banned[r.name] then bad = bad + 1 end end
  check(bad == 0, "금지 지명 없음")
end

-- ── 결과 ─────────────────────────────────────────────────
print(string.format("\n테스트 결과: %d 통과 / %d 실패", passed, failed))
os.exit(failed == 0 and 0 or 1)
