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
local GameState = require("game_state")
local Develop = require("develop")
local Movement = require("movement")
local Battle = require("battle")
local Captive = require("captive")
local AI = require("ai")
local config = require("config")

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

-- ── 시나리오 무결성 ──────────────────────────────────────
do
  local scenarios = game_data.scenarios
  local regions = game_data.regions

  check(#scenarios == 3, "시나리오 3개 (184/194/221)")

  -- 유효한 region id 집합.
  local regSet = {}
  for _, r in ipairs(regions) do regSet[r.id] = true end

  local badOwnKey, badOwnVal, badFaction = 0, 0, 0
  for _, sc in ipairs(scenarios) do
    -- 각 세력은 이름 + 색(3채널) 필요.
    for fid, f in pairs(sc.factions) do
      if type(f.name) ~= "string" or type(f.color) ~= "table" or #f.color ~= 3 then
        badFaction = badFaction + 1
        print("  [faction] " .. sc.id .. "/" .. fid)
      end
    end
    -- ownership: 키=실재 region, 값=실재 faction id.
    for rid, fid in pairs(sc.ownership) do
      if not regSet[rid] then badOwnKey = badOwnKey + 1; print("  [own key] " .. sc.id .. "/" .. rid) end
      if not sc.factions[fid] then badOwnVal = badOwnVal + 1; print("  [own val] " .. sc.id .. "/" .. tostring(fid)) end
    end
  end
  check(badFaction == 0, "세력은 이름+색(3채널)")
  check(badOwnKey == 0, "ownership 키 = 실재 지역")
  check(badOwnVal == 0, "ownership 값 = 실재 세력")

  -- 소유 지역 수는 30 이하(배치 우선 정합성으로 일부는 중립 — GDD 6장).
  --   194 는 채울 인물이 많아 대부분 소유, 184 는 무명 시대라 중립이 더 많다.
  local warlords
  for _, sc in ipairs(scenarios) do if sc.id == "warlords" then warlords = sc end end
  local owned = 0
  for _ in pairs(warlords.ownership) do owned = owned + 1 end
  check(owned >= 1 and owned <= 30, "194 소유 지역 1~30 (실제=" .. owned .. ")")

  -- 184 황건의 난(한 관군 제거, 군벌 배치). 'han' 세력 없어야. 소유는 일부(나머지 중립).
  local yt
  for _, sc in ipairs(scenarios) do if sc.id == "yellow_turban" then yt = sc end end
  local owned184 = 0
  for _ in pairs(yt.ownership) do owned184 = owned184 + 1 end
  check(owned184 >= 1 and owned184 < 30, "184 일부 소유+일부 중립 (실제=" .. owned184 .. ")")
  check(yt.factions.han == nil, "184 한 관군 세력 제거됨")
end

-- ── 장수 베이스 풀 무결성 (GDD 7장) ──────────────────────
do
  local officers = game_data.officers

  -- 풀 규모 180~200 (GDD 7장).
  check(#officers >= 180 and #officers <= 200, "장수 풀 180~200 (실제=" .. #officers .. ")")

  -- id 중복 없음 + 필수 능력치 필드/범위 검증.
  local seen, dup, badField = {}, 0, 0
  for _, o in ipairs(officers) do
    if seen[o.id] then dup = dup + 1; print("  [dup officer] " .. o.id) end
    seen[o.id] = true
    -- 능력치는 0~100 숫자, appear 는 숫자여야.
    local function ok(v) return type(v) == "number" and v >= 0 and v <= 100 end
    if not (type(o.name) == "string"
        and ok(o.might) and ok(o.intel) and ok(o.pol) and ok(o.hp)
        and type(o.appear) == "number") then
      badField = badField + 1; print("  [officer field] " .. tostring(o.id))
    end
  end
  check(dup == 0, "장수 id 중복 없음")
  check(badField == 0, "장수 필수 필드/능력치 범위(0~100)")
end

-- ── 장수 규칙 함수 (game_state, GDD 7장) ─────────────────
do
  -- 병력 한도 = 무력 * config.officer.troopsPerMight.
  local dummy = { might = 90 }
  check(GameState.troopsCap(dummy) == 90 * config.officer.troopsPerMight, "병력 한도 = 무력 * 계수")

  -- 상태 enum 5종 존재.
  local S = GameState.STATE
  check(S.active and S.free and S.unrevealed and S.captured and S.dead, "상태 enum 5종")

  -- 미등장 판정: appear 가 연도보다 늦으면 unrevealed.
  check(GameState.isUnrevealed({ appear = 207 }, 184) == true, "isUnrevealed 미래 인물")
  check(GameState.isUnrevealed({ appear = 184 }, 194) == false, "isUnrevealed 과거 인물")

  -- 행동 완료 리셋/소진/판정.
  local roster = {
    { state = S.active, actionDone = true, moving = false },
    { state = S.active, actionDone = false, moving = false },
    { state = S.free, actionDone = false, moving = false },
  }
  GameState.resetActions(roster)
  check(roster[1].actionDone == false and roster[2].actionDone == false, "resetActions 전원 리셋")
  check(GameState.canAct(roster[2]) == true, "canAct active 미행동 가능")
  check(GameState.canAct(roster[3]) == false, "canAct 재야 불가")
  GameState.markActed(roster[2])
  check(GameState.canAct(roster[2]) == false, "markActed 후 행동 불가")
end

-- ── 징병/훈련 규칙 (game_state, GDD 11장) ────────────────
do
  local S = GameState.STATE
  -- 행동 가능한 더미 장수를 만든다(상태 active, 미행동).
  local function newOfficer(might, troops, training)
    return { state = S.active, actionDone = false, moving = false,
             might = might, troops = troops or 0, training = training or 0, name = "테스트" }
  end

  -- 1) 병력 한도 클램프: 무력20(한도100), 보유50 → 1회 징병이 한도(100)를 넘지 않는다.
  do
    local o = newOfficer(20, 50, 0)
    local region = { gold = 1000, pop = 50, loyal = 50 }
    local cap = GameState.troopsCap(o) -- 100
    local expectAdd = math.min(config.conscript.troopsPerAction, cap - 50)
    local add = GameState.applyRecruit(region, o)
    check(add == expectAdd, "징병 한도 클램프: 충원량 = min(배치, 여유)")
    check(o.troops == 50 + expectAdd and o.troops <= cap, "징병 후 병력 ≤ 무력*5 한도")
  end

  -- 2) 가중평균 훈련도: 기존 100병 훈련80 + 신규 100병(훈련0) → (100*80+100*0)/200 = 40.
  do
    local o = newOfficer(100, 100, 80) -- 한도 500, 여유 충분
    local region = { gold = 1000, pop = 80, loyal = 70 }
    local add = GameState.applyRecruit(region, o)
    check(add == config.conscript.troopsPerAction, "징병 충원량 = 배치량(여유 충분)")
    check(approx(o.training, (100 * 80 + add * 0) / (100 + add)), "징병 훈련도 가중평균 재계산")
  end

  -- 3) 훈련 상승 스케일: 무력100 → 1회 +10(무력*gainPerMight), 10회로 100 도달·상한 클램프.
  do
    local o = newOfficer(100, 50, 0)
    local gain = GameState.applyTrain(o)
    check(approx(gain, 100 * config.training.gainPerMight), "훈련 상승 = 무력 * 계수")
    check(approx(o.training, 100 * config.training.gainPerMight), "1회 훈련 후 훈련도")
    -- 상한 클램프: 훈련도 95에서 +10 시도 → 100 에서 멈춘다.
    local o2 = newOfficer(100, 50, 95)
    GameState.applyTrain(o2)
    check(o2.training == config.training.max, "훈련도 상한(100) 클램프")
  end

  -- 4) 자원 변화: 금70 차감 → 0, 인구·민충성 하락, 신규병 훈련도 0.
  do
    local o = newOfficer(50, 0, 0) -- 한도 250, 보유 0
    local region = { gold = config.conscript.goldCost, pop = 82, loyal = 60 }
    local add = GameState.applyRecruit(region, o)
    check(region.gold == 0, "징병 비용 차감(금 70 → 0)")
    check(region.pop == 82 - math.floor(add * config.conscript.popDrainPerTroop), "징병 인구 감소")
    check(region.loyal == 60 - config.conscript.loyaltyDropPerAction, "징병 민충성 하락")
    check(o.training == 0, "기존 병력 0 + 신규만 → 훈련도 0")
  end

  -- 5) 행동 게이팅: 한도 가득이면 징병 불가 / 병력 0이면 훈련 불가.
  do
    local full = newOfficer(40, 200, 0) -- 한도 200, 보유 200
    check((GameState.canRecruit({ gold = 1000 }, full)) == false, "한도 가득 → 징병 불가")
    local noTroop = newOfficer(40, 0, 0)
    check((GameState.canTrain(noTroop)) == false, "병력 0 → 훈련 불가")
  end
end

-- ── 시나리오별 장수 배치 정합성 (GDD 4·7장) ──────────────
do
  local regions = game_data.regions
  local baseById = {}
  for _, o in ipairs(game_data.officers) do baseById[o.id] = true end

  for _, sc in ipairs(game_data.scenarios) do
    -- 1) 모든 faction 에 lord 가 있고, 그 lord 가 실재 장수인지.
    local badLord = 0
    for fid, f in pairs(sc.factions) do
      if not f.lord or not baseById[f.lord] then
        badLord = badLord + 1; print("  [lord] " .. sc.id .. "/" .. fid)
      end
    end
    check(badLord == 0, sc.id .. ": 세력마다 실재 lord 존재")

    -- 배치가 있는 시나리오만 검사(officers 필드).
    check(type(sc.officers) == "table", sc.id .. ": officers 배치 존재")

    local officers = GameState.buildOfficers(game_data, sc)

    -- 2) 배치 id 가 모두 실재 베이스인지(buildOfficers 가 미존재는 건너뛰므로 직접 검사).
    local badId = 0
    for _, p in ipairs(sc.officers) do
      if not baseById[p.id] then badId = badId + 1; print("  [place id] " .. sc.id .. "/" .. tostring(p.id)) end
    end
    check(badId == 0, sc.id .. ": 배치 장수 id = 실재 베이스")

    -- 3) 배치된 모든 장수는 appear <= 연도 (unrevealed 미배치).
    local badYear = 0
    for _, o in ipairs(officers) do
      if o.appear > sc.year then badYear = badYear + 1; print("  [year] " .. sc.id .. "/" .. o.id .. " appear=" .. o.appear) end
    end
    check(badYear == 0, sc.id .. ": 배치 장수는 모두 등장연도<=시나리오연도")

    -- 4) active 장수의 위치는 반드시 그 세력 소유 지역(ownership) 이어야.
    local badPlace = 0
    for _, o in ipairs(officers) do
      if o.state == GameState.STATE.active then
        if sc.ownership[o.region] ~= o.faction then
          badPlace = badPlace + 1
          print("  [active region] " .. sc.id .. "/" .. o.id ..
                " @" .. tostring(o.region) .. " owner=" .. tostring(sc.ownership[o.region]) ..
                " faction=" .. tostring(o.faction))
        end
      end
    end
    check(badPlace == 0, sc.id .. ": active 장수는 자기 세력 소유 지역에 위치")

    -- 5) free 장수는 소속 세력이 없어야(재야).
    local badFree = 0
    for _, o in ipairs(officers) do
      if o.state == GameState.STATE.free and o.faction ~= nil then
        badFree = badFree + 1; print("  [free faction] " .. sc.id .. "/" .. o.id)
      end
    end
    check(badFree == 0, sc.id .. ": free 장수는 무소속")

    -- 6) 같은 장수 id 가 한 시나리오에 두 번 배치되지 않음.
    local seen, dupPlace = {}, 0
    for _, p in ipairs(sc.officers) do
      if seen[p.id] then dupPlace = dupPlace + 1; print("  [dup place] " .. sc.id .. "/" .. p.id) end
      seen[p.id] = true
    end
    check(dupPlace == 0, sc.id .. ": 시나리오 내 장수 중복 배치 없음")

    -- 7) lord 의 충성도는 '-' (loyaltyText), 일반 active 는 숫자.
    local lord = GameState.byId(officers, sc.factions[next(sc.factions)].lord)
    if lord then check(GameState.loyaltyText(lord) == "-", sc.id .. ": 군주 충성도 '-'") end

    -- (참고) 지역당 평균 장수 수 — GDD 7장 목표 약 6명. 시대별로 등장 인원이 달라
    --        실제값은 정보 출력만(검증 실패로 두지 않음).
    print(string.format("  [info] %s 배치 %d명 / 30지역 = 평균 %.1f명",
      sc.id, #officers, #officers / #regions))
  end
end

-- ── 턴/달력 (game_state, GDD 3·9장) ──────────────────────
do
  -- newTurn: 시나리오 시작 연/월을 그대로 가져온다.
  local sc = { year = 194, startMonth = 3 }
  local turn = GameState.newTurn(sc)
  check(turn.year == 194 and turn.month == 3 and turn.count == 1, "newTurn 시작 연/월/카운트")

  -- startMonth 없으면 1월 폴백.
  check(GameState.newTurn({ year = 200 }).month == 1, "newTurn startMonth 없으면 1월")

  -- 한 턴 진행 → 월 +1, 카운트 +1.
  local t = GameState.newTurn({ year = 184, startMonth = 2 })
  GameState.advanceTurn(t, {})
  check(t.year == 184 and t.month == 3 and t.count == 2, "advanceTurn 월 +1")

  -- 12월 → 다음 해 1월 롤오버.
  local t2 = { year = 200, month = 12, count = 5 }
  GameState.advanceTurn(t2, {})
  check(t2.year == 201 and t2.month == 1, "12월 → 다음 해 1월 롤오버")

  -- 11월에서 두 번 진행 → 12월 → 1월(연도 증가) 연속 확인.
  local t3 = { year = 190, month = 11, count = 1 }
  GameState.advanceTurn(t3, {}); GameState.advanceTurn(t3, {})
  check(t3.year == 191 and t3.month == 1, "11→12→1월 연속 롤오버")

  -- 수확 훅: 6월에서 진행해 7월 "진입" 시 호출. 5월→6월 진입 시엔 호출 안 됨.
  local harvested = 0
  local ctx = { onHarvest = function() harvested = harvested + 1 end }
  local tJun = { year = 200, month = 6, count = 1 }
  GameState.advanceTurn(tJun, ctx) -- 6→7월 진입 → 호출
  check(harvested == 1, "7월 진입 시 수확 훅 호출")
  local tMay = { year = 200, month = 5, count = 1 }
  GameState.advanceTurn(tMay, ctx) -- 5→6월 → 호출 안 함
  check(harvested == 1, "비수확월 진입 시 수확 훅 미호출")

  -- 12월에서 진행 시 1월이므로 수확 훅 호출 안 됨(롤오버와 무관).
  local tDec = { year = 200, month = 12, count = 1 }
  GameState.advanceTurn(tDec, ctx)
  check(harvested == 1, "롤오버(→1월) 시 수확 훅 미호출")

  -- 행동완료 리셋: ctx.officers 의 actionDone 이 턴 진행 후 전부 false.
  local roster = { { actionDone = true }, { actionDone = true } }
  GameState.advanceTurn({ year = 1, month = 1, count = 1 }, { officers = roster })
  check(roster[1].actionDone == false and roster[2].actionDone == false, "턴 진행 시 장수 행동완료 리셋")

  -- 처리 순서: 모든 훅이 정해진 순서로 호출되는지(턴종료→도착→성장→AI, 그 뒤 날짜·수확).
  local log = {}
  local ctx2 = {
    onTurnEnd  = function() log[#log+1] = "end" end,
    onArrivals = function() log[#log+1] = "arr" end,
    onGrowth   = function() log[#log+1] = "grow" end,
    onAI       = function() log[#log+1] = "ai" end,
  }
  GameState.advanceTurn({ year = 1, month = 1, count = 1 }, ctx2)
  check(log[1] == "end" and log[2] == "arr" and log[3] == "grow" and log[4] == "ai", "advanceTurn 훅 호출 순서")
end

-- ── 시나리오 시작 월 데이터 (GDD 4장) ────────────────────
do
  for _, sc in ipairs(game_data.scenarios) do
    check(type(sc.startMonth) == "number" and sc.startMonth >= 1 and sc.startMonth <= 12,
      sc.id .. ": startMonth 1~12 (실제=" .. tostring(sc.startMonth) .. ")")
  end
end

-- ── 선물 시스템 (game_state, GDD 15장) ───────────────────
do
  local S = GameState.STATE
  -- 선물 대상 판정: 플레이어 세력 active 비수장만.
  check(GameState.isGiftTarget({ faction = "wei", state = S.active, isLord = false }, "wei") == true,
    "isGiftTarget 플레이어 세력 장수")
  check(GameState.isGiftTarget({ faction = "wei", state = S.active, isLord = true }, "wei") == false,
    "isGiftTarget 수장 제외")
  check(GameState.isGiftTarget({ faction = "shu", state = S.active, isLord = false }, "wei") == false,
    "isGiftTarget 타 세력 제외")
  check(GameState.isGiftTarget({ faction = nil, state = S.free, isLord = false }, "wei") == false,
    "isGiftTarget 재야 제외")

  -- canGiftGold: 정상 / 수장 / 이미 선물 / 금액범위 / 금 부족.
  local off = { isLord = false, giftedGoldThisTurn = false, loyalty = 50 }
  check(GameState.canGiftGold(100, off, 5) == true, "canGiftGold 정상")
  check(GameState.canGiftGold(100, { isLord = true }, 5) == false, "canGiftGold 수장 불가")
  check(GameState.canGiftGold(100, { giftedGoldThisTurn = true }, 5) == false, "canGiftGold 이미 선물 불가")
  check(GameState.canGiftGold(100, off, 0) == false, "canGiftGold 0금 불가")
  check(GameState.canGiftGold(100, off, config.gift.goldGiftMax + 1) == false, "canGiftGold 상한 초과 불가")
  check(GameState.canGiftGold(3, off, 5) == false, "canGiftGold 금 부족 불가")

  -- applyGiftGold: 충성 +amount*5, 금 차감, 플래그 set.
  local o2 = { loyalty = 50, giftedGoldThisTurn = false }
  local newGold = GameState.applyGiftGold(100, o2, 4)
  check(newGold == 96, "applyGiftGold 금 차감(100-4=96)")
  check(o2.loyalty == 50 + 4 * config.gift.loyaltyPerGold, "applyGiftGold 충성 +amount*5")
  check(o2.giftedGoldThisTurn == true, "applyGiftGold 턴 플래그 set")

  -- 충성 상한 클램프(maxLoyalty 초과 금지).
  local o3 = { loyalty = 98, giftedGoldThisTurn = false }
  GameState.applyGiftGold(100, o3, 10) -- +50 이지만 상한에서 멈춤
  check(o3.loyalty == config.officer.maxLoyalty, "applyGiftGold 충성 상한 클램프")

  -- 선물 플래그도 행동완료 리셋 지점에서 함께 리셋(GDD 15장 턴 1회).
  local roster = { { giftedGoldThisTurn = true, giftedEquipThisTurn = true, actionDone = true } }
  GameState.resetActions(roster)
  check(roster[1].giftedGoldThisTurn == false and roster[1].giftedEquipThisTurn == false,
    "resetActions 선물 플래그 리셋")

  -- 장비 시스템 구현됨(이번 작업) — 플래그 true.
  check(GameState.EQUIP_IMPLEMENTED == true, "장비 시스템 구현 플래그")
end

-- ── buildOfficers 선물 플래그 초기화 ─────────────────────
do
  local sc = game_data.scenarios[3] -- three_kingdoms
  local officers = GameState.buildOfficers(game_data, sc)
  local allInit = true
  for _, o in ipairs(officers) do
    if o.giftedGoldThisTurn ~= false or o.giftedEquipThisTurn ~= false or o.equip ~= nil then
      allInit = false
    end
  end
  check(allInit, "buildOfficers 선물 플래그/장비 초기값")
end

-- ── 태수 자동 선정 (game_state, GDD 5장) ─────────────────
do
  local S = GameState.STATE
  local officers = {
    { id = "a", region = "r1", state = S.active, isLord = false, loyalty = 70 },
    { id = "b", region = "r1", state = S.active, isLord = false, loyalty = 90 },
    { id = "lord", region = "r1", state = S.active, isLord = true },          -- 수장
    { id = "d", region = "r2", state = S.active, isLord = false, loyalty = 50 },
    { id = "e", region = "r2", state = S.active, isLord = false, loyalty = 50 }, -- d 와 동률
    { id = "f", region = "r3", state = S.free, isLord = false, loyalty = 99 },  -- 재야(후보 아님)
  }
  -- 수장이 있으면 충성 무관하게 수장 고정.
  check(GameState.assignGovernor(officers, "r1") == "lord", "태수: 수장 고정")
  -- 수장 없는 지역(r2)은 동률 → rng 로 선택. rng=1 → d(먼저), rng=2 → e.
  check(GameState.assignGovernor(officers, "r2", function() return 1 end) == "d", "태수: 동률 rng=1 → d")
  check(GameState.assignGovernor(officers, "r2", function() return 2 end) == "e", "태수: 동률 rng=2 → e")
  -- 후보가 재야뿐인 지역 → nil.
  check(GameState.assignGovernor(officers, "r3") == nil, "태수: active 후보 0 → nil")
  -- 존재하지 않는 지역 → nil.
  check(GameState.assignGovernor(officers, "rX") == nil, "태수: 후보 없음 → nil")

  -- 수장 없고 단독 최고 충성 → 그 장수.
  local solo = {
    { id = "x", region = "r1", state = S.active, isLord = false, loyalty = 60 },
    { id = "y", region = "r1", state = S.active, isLord = false, loyalty = 80 },
  }
  check(GameState.assignGovernor(solo, "r1") == "y", "태수: 단독 최고 충성")

  -- governorRegionOf 역조회.
  local gov = { r1 = "lord", r2 = "d" }
  check(GameState.governorRegionOf(gov, "d") == "r2", "governorRegionOf 역조회")
  check(GameState.governorRegionOf(gov, "zzz") == nil, "governorRegionOf 없음 nil")

  -- canSetGovernor: 같은 지역 active 만.
  check(GameState.canSetGovernor({ region = "r1", state = S.active }, "r1") == true, "canSetGovernor 같은 지역")
  check(GameState.canSetGovernor({ region = "r2", state = S.active }, "r1") == false, "canSetGovernor 다른 지역 불가")
end

-- ── 장비 보너스/유효 능력치 (game_state, GDD 8장) ────────
do
  local o = { might = 70, intel = 60, pol = 50, hp = 80, equip = nil }
  -- 장비 없음: 보너스 0, 유효 = 기본.
  check(GameState.statBonus(o, "might") == 0, "장비없음 보너스 0")
  check(GameState.effectiveStat(o, "might") == 70, "장비없음 유효=기본")
  check(GameState.hasStatBonus(o, "might") == false, "장비없음 보너스 표시 X")

  -- 방천화극(force=20) 장착 → 무력 보너스 +20.
  o.equip = { id = "sky_piercer", name = "방천화극", force = 20, intelligence = 0, politics = 0, hp = 0 }
  check(GameState.statBonus(o, "might") == 20, "force→무력 보너스 매핑")
  check(GameState.effectiveStat(o, "might") == 90, "유효 무력 = 70+20")
  check(GameState.hasStatBonus(o, "might") == true, "무력 보너스 표시 O")
  check(GameState.hasStatBonus(o, "intel") == false, "지력 보너스 없음")

  -- 음수 보너스(패널티)는 hasStatBonus(+판별) false.
  o.equip = { force = 0, intelligence = -2, politics = 0, hp = 0 }
  check(GameState.statBonus(o, "intel") == -2, "패널티 보너스 음수")
  check(GameState.effectiveStat(o, "intel") == 58, "유효 지력 = 60-2")
  check(GameState.hasStatBonus(o, "intel") == false, "패널티는 +표시 아님")
end

-- ── 초기 장비 배치 + 장비 선물 이전 (GDD 8·15장) ─────────
do
  local S = GameState.STATE
  local sc = game_data.scenarios[3] -- three_kingdoms (wei/shu/wu)
  local officers = GameState.buildOfficers(game_data, sc)
  local inv = GameState.applyInitialEquipment(game_data, sc, officers)

  -- 221 위(caopi) 군주에게 bronze_sparrow(구리 참새)가 미장착으로 귀속.
  check(inv.wei and #inv.wei == 1, "초기 장비: 위 장비고 1개")
  check(inv.wei[1].name == "구리 참새", "초기 장비: 위 = 구리 참새")
  -- 미장착이므로 군주는 아직 장착 안 함.
  local caopi = GameState.byId(officers, "caopi")
  check(caopi.equip == nil, "초기 장비: 미장착(군주 equip 없음)")

  -- 장비 선물: 위 세력 비수장 장수에게 이전.
  local target = nil
  for _, o in ipairs(officers) do
    if o.faction == "wei" and not o.isLord and o.state == S.active then target = o; break end
  end
  check(target ~= nil, "위 세력 비수장 장수 존재")
  check(GameState.canGiftEquip(target) == true, "canGiftEquip 정상")

  local loy0 = target.loyalty or 0
  local item = inv.wei[1]
  GameState.applyGiftEquip(inv.wei, 1, target)
  check(#inv.wei == 0, "장비 선물: 장비고에서 제거")
  check(target.equip == item, "장비 선물: 대상에게 장착")
  check(target.loyalty == loy0 + config.gift.loyaltyPerEquip, "장비 선물: 충성 상승")
  check(target.giftedEquipThisTurn == true, "장비 선물: 턴 플래그 set")
  -- 이전 직후 유효 능력치에 보너스 반영(구리 참새 politics=12 → 정치 +12).
  check(GameState.statBonus(target, "pol") == 12, "장비 선물 후 정치 보너스 반영")
  check(GameState.hasStatBonus(target, "pol") == true, "장비 선물 후 정치 연두 판별")

  -- 이미 장착 → canGiftEquip 불가(1장수 1장착).
  check(GameState.canGiftEquip(target) == false, "이미 장착 → 장비 선물 불가")
  -- 수장 → 불가.
  check(GameState.canGiftEquip({ isLord = true }) == false, "수장 → 장비 선물 불가")
end

-- ── 지역 base 내부수치 무결성 (GDD 5장) ──────────────────
do
  local bad = 0
  for _, r in ipairs(game_data.regions) do
    local function num(v) return type(v) == "number" end
    if not (num(r.pop) and num(r.commerce) and num(r.land) and num(r.loyal)
        and num(r.flood) and num(r.gold) and num(r.grain)) then
      bad = bad + 1; print("  [region field] " .. tostring(r.id))
    end
  end
  check(bad == 0, "지역 base 내부수치(인구/상업/토지/민충성/치수/금/군량) 전부 존재")
end

-- ── buildRegions: base 복사 + regionInit override (GDD 5·9장) ──
do
  local sc = game_data.scenarios[3] -- three_kingdoms
  local rs = GameState.buildRegions(game_data, sc)

  -- 모든 지역상태가 생성되고 내부수치가 base 에서 복사됐는지(낙양 표본).
  local ly = rs.luoyang
  local base = Region.byId(game_data.regions, "luoyang")
  check(ly ~= nil and ly.commerce == base.commerce and ly.land == base.land, "buildRegions base 내부수치 복사")

  -- regionInit override 반영: 221 낙양 gold=1600, grain=4200.
  check(ly.gold == 1600 and ly.grain == 4200, "buildRegions regionInit override(낙양 금·군량)")

  -- override 없는 지역은 base 값(무위는 221 regionInit 미기재).
  local wuweiBase = Region.byId(game_data.regions, "wuwei")
  check(rs.wuwei.gold == wuweiBase.gold, "buildRegions override 없으면 base 금")

  -- 원본 불변: 런타임 gold 를 바꿔도 game_data.regions 의 base 는 그대로.
  rs.luoyang.gold = 0
  check(Region.byId(game_data.regions, "luoyang").gold == 1500, "buildRegions 원본 base 불변")
end

-- ── 세금/수확 공식 (game_state, GDD 9장) ─────────────────
do
  -- 통제된 지역으로 공식 검증(계수는 config.economy).
  local region = { commerce = 100, land = 100, loyal = 100, flood = 100, gold = 0, grain = 0 }
  local e = config.economy

  -- 세금(태수 없음) = (100*taxCommerce + 100*taxLand) * 1.0 * 1.0.
  local expectTaxNoGov = math.floor((100 * e.taxCommerce + 100 * e.taxLand) * 1.0 * 1.0)
  check(GameState.calcTax(region, nil) == expectTaxNoGov, "calcTax 태수없음")

  -- 태수 정치 반영 → 세금 증가(정치 100).
  local gov = { pol = 100 }
  local taxGov = GameState.calcTax(region, gov)
  check(taxGov > expectTaxNoGov, "calcTax 태수 정치 높을수록 ↑")
  check(taxGov == math.floor((100 * e.taxCommerce + 100 * e.taxLand) * 1.0 * (1 + 100 * e.taxPolBonus)),
    "calcTax 정치 배수 공식")

  -- 정수 반환.
  check(GameState.calcTax(region, nil) % 1 == 0, "calcTax 정수")

  -- 수확(태수없음) = (100*harvestLand + 100*harvestFlood) * 1.0.
  local expectHarvest = math.floor((100 * e.harvestLand + 100 * e.harvestFlood) * 1.0 * 1.0)
  check(GameState.calcHarvest(region, nil) == expectHarvest, "calcHarvest 태수없음")
  check(GameState.calcHarvest(region, gov) > expectHarvest, "calcHarvest 태수 정치 ↑")

  -- 민충성 낮으면 세금/수확 감소(0이면 0).
  local low = { commerce = 100, land = 100, loyal = 0, flood = 100 }
  check(GameState.calcTax(low, nil) == 0, "calcTax 민충성0 → 0")
  check(GameState.calcHarvest(low, nil) == 0, "calcHarvest 민충성0 → 0")
end

-- ── collectTaxes / harvestAll: 소유 지역만 가산 (GDD 9장) ──
do
  local sc = game_data.scenarios[3] -- three_kingdoms (변경 중립 다수)
  local rs = GameState.buildRegions(game_data, sc)
  local officers = GameState.buildOfficers(game_data, sc)
  local governors = GameState.assignGovernors(game_data.regions, officers, function() return 1 end)

  -- 소유 지역(낙양=위)과 중립 지역(무위) 표본의 징수 전 금.
  local luoyangBefore = rs.luoyang.gold
  local wuweiBefore = rs.wuwei.gold -- 221 무위는 중립(ownership 미기재)

  GameState.collectTaxes(rs, governors, officers, sc.ownership)

  check(rs.luoyang.gold > luoyangBefore, "collectTaxes 소유 지역 금 증가")
  check(rs.wuwei.gold == wuweiBefore, "collectTaxes 중립 지역 금 불변")

  -- 수확: 소유 지역 군량 증가, 중립 불변.
  local luoyangGrain = rs.luoyang.grain
  local wuweiGrain = rs.wuwei.grain
  GameState.harvestAll(rs, governors, officers, sc.ownership)
  check(rs.luoyang.grain > luoyangGrain, "harvestAll 소유 지역 군량 증가")
  check(rs.wuwei.grain == wuweiGrain, "harvestAll 중립 지역 군량 불변")
end

-- ── 적대치 조회 (game_state, GDD 6장 외교) ───────────────
do
  local tk = game_data.scenarios[3] -- 221: wei/shu/wu 상호 적대
  local H = config.hostility.tier

  -- 본인 소유 지역 → nil('-').
  check(GameState.getHostility(tk, "wei", "wei") == nil, "getHostility 본인 → nil")
  -- 중립(소유 nil) → nil('-').
  check(GameState.getHostility(tk, nil, "wei") == nil, "getHostility 중립 → nil")
  -- 적 세력 소유 → 단계 수치(위→촉 적대=hostile).
  check(GameState.getHostility(tk, "shu", "wei") == H.hostile, "getHostility 적 세력 → 적대 수치")

  -- 미기재 세력 쌍은 중립(184 황건적-동탁은 적대지만, 마등-유언은 미기재 → 중립).
  local yt = game_data.scenarios[1] -- yellow_turban
  check(GameState.getHostility(yt, "yellowturban", "dongzhuo") == H.hostile, "getHostility 184 황건적→동탁 적대")
  check(GameState.getHostility(yt, "mateng", "liuyan") == H.neutral, "getHostility 미기재 쌍 → 중립")
end

-- ── 금 선물 = 지역 금에서 차감 (GDD 9·15장 — 지역별 보유 단일) ───
do
  local sc = game_data.scenarios[3]
  local officers = GameState.buildOfficers(game_data, sc)
  local rs = GameState.buildRegions(game_data, sc)

  -- 금은 지역별 보유 단일 진실원본(GDD 9장) — "군주 소재 금" 개념 없음.
  --   선물은 명령 수행 지역(=장수가 있는 지역) 금에서 차감되는 흐름(canGiftGold/applyGiftGold 숫자 in/out).
  local target = nil
  for _, o in ipairs(officers) do
    if o.faction == "wei" and not o.isLord and o.state == GameState.STATE.active then target = o; break end
  end
  local pool = rs[target.region] -- 그 장수가 있는 지역의 금이 풀
  local before = pool.gold
  local ok = GameState.canGiftGold(pool.gold, target, 3)
  check(ok == true, "canGiftGold 지역 금 충분")
  pool.gold = GameState.applyGiftGold(pool.gold, target, 3)
  check(pool.gold == before - 3, "applyGiftGold 지역 금에서 차감")

  -- lordRegionId 는 폐기됨 — 더 이상 존재하지 않아야(군주 소재 금 개념 제거).
  check(GameState.lordRegionId == nil, "lordRegionId 폐기(군주 소재 금 개념 제거)")
end

-- ── 장수 풀 규모 (GDD 7장: 180~200) ─────────────────────
do
  local n = #game_data.officers
  check(n >= 180 and n <= 200, "장수 풀 180~200 범위 (현재 " .. n .. ")")
end

-- ── 소유↔배치 정합성: regionActiveCount (GDD 6장) ────────
do
  local sc = game_data.scenarios[3] -- 221
  local officers = GameState.buildOfficers(game_data, sc)
  -- 위 군주 조비가 낙양에 active → 낙양의 wei active ≥1.
  check(GameState.regionActiveCount(officers, "luoyang", "wei") >= 1, "regionActiveCount 위 낙양 ≥1")
  -- 운남은 221 에 아무도 배치 안 됨 → shu active 0.
  check(GameState.regionActiveCount(officers, "yunnan", "shu") == 0, "regionActiveCount 운남 shu 0")
  -- 세력이 다르면 카운트 안 됨(낙양의 shu active 는 0).
  check(GameState.regionActiveCount(officers, "luoyang", "shu") == 0, "regionActiveCount 타 세력 0")
end

-- ── normalizeOwnership: 강등 + 원본 불변 (GDD 6장) ───────
do
  -- 인위 시나리오: 한 지역(alpha)은 active 있음, 다른 지역(beta)은 소유인데 active 0.
  local fakeOfficers = {
    { id = "x", faction = "f1", region = "alpha", state = GameState.STATE.active },
  }
  local fakeScenario = { ownership = { alpha = "f1", beta = "f1" } }
  local own, demoted = GameState.normalizeOwnership(fakeScenario, fakeOfficers)
  check(own.alpha == "f1", "normalizeOwnership active 있는 소유 유지")
  check(own.beta == nil, "normalizeOwnership active 0 소유 → 중립 제거")
  check(#demoted == 1 and demoted[1].region == "beta" and demoted[1].faction == "f1",
        "normalizeOwnership 강등 목록 기록")
  -- 원본 ownership 은 그대로(복사본만 수정).
  check(fakeScenario.ownership.beta == "f1", "normalizeOwnership 원본 불변")

  -- 실제 시나리오 3개: 정규화 후 남은 소유 지역은 모두 그 세력 active ≥1 (0명 세력 지역 0건).
  for si, sc in ipairs(game_data.scenarios) do
    local officers = GameState.buildOfficers(game_data, sc)
    local own2 = GameState.normalizeOwnership(sc, officers)
    local allStaffed = true
    for regionId, fid in pairs(own2) do
      if GameState.regionActiveCount(officers, regionId, fid) < 1 then allStaffed = false end
    end
    check(allStaffed, "시나리오 " .. si .. " 정규화 후 소유 지역 active ≥1")

    -- 자기 세력 외 active 배치 0건: 모든 active 장수의 위치는 자기 세력 소유 지역.
    --   (정규화 후 own2 기준 — active 가 있으면 그 지역은 강등되지 않으므로 own2 에 남아 있어야 함)
    local noForeign = true
    for _, o in ipairs(officers) do
      if o.state == GameState.STATE.active and o.faction then
        if own2[o.region] ~= o.faction then noForeign = false end
      end
    end
    check(noForeign, "시나리오 " .. si .. " active 자기 세력 지역에만 배치")
  end
end

-- ── demoteIfVacant: 런타임 강등 + 태수 해제 (GDD 6장) ────
do
  -- gamma 지역에 f1 active 0명 → 강등되며 태수도 해제돼야 한다.
  local officers = {} -- gamma 에 아무도 없음
  local ownership = { gamma = "f1" }
  local governors = { gamma = "someone" }
  local changed = GameState.demoteIfVacant(ownership, governors, officers, "gamma")
  check(changed == true, "demoteIfVacant active 0 → 강등 true")
  check(ownership.gamma == nil, "demoteIfVacant 소유 해제(중립)")
  check(governors.gamma == nil, "demoteIfVacant 태수 해제")

  -- active 가 있으면 강등 안 함.
  local officers2 = { { id = "y", faction = "f1", region = "delta", state = GameState.STATE.active } }
  local ownership2 = { delta = "f1" }
  local governors2 = { delta = "y" }
  local changed2 = GameState.demoteIfVacant(ownership2, governors2, officers2, "delta")
  check(changed2 == false, "demoteIfVacant active 있으면 유지 false")
  check(ownership2.delta == "f1", "demoteIfVacant 유지 시 소유 보존")
end

-- ── 내정: 투자 4종 (game_state, GDD 10장) ────────────────
do
  local S = GameState.STATE
  local d = config.develop

  -- developGain: 정치 높을수록 상승량 ↑(같은 투자금). 공식 = floor(amount*perGold*(1+pol*polBonus)).
  local gainNoGov = Develop.developGain(200, nil)        -- 정치 0
  local gainLowPol = Develop.developGain(200, { pol = 40 })
  local gainHighPol = Develop.developGain(200, { pol = 100 })
  check(gainNoGov == math.floor(200 * d.perGold * 1.0), "developGain 정치없음 공식")
  check(gainHighPol > gainLowPol and gainLowPol > gainNoGov, "developGain 정치 높을수록 ↑")
  check(gainHighPol == math.floor(200 * d.perGold * (1 + 100 * d.polBonus)), "developGain 정치 배수 공식")

  -- 새 런타임 지역상태(투자 대상) — 금·군량 + devDone/searchDone 포함.
  local function freshRegion()
    return { id = "r1", name = "테스트", flood = 40, loyal = 50, commerce = 60, land = 70,
             gold = 1000, grain = 2000,
             devDone = { flood = false, loyal = false, commerce = false, land = false },
             searchDone = false }
  end

  -- 비용 자원(GDD 10장): 민충성=군량, 나머지=금.
  check(Develop.investCostField("loyal") == "grain", "investCostField 민충성=군량")
  check(Develop.investCostField("flood") == "gold", "investCostField 치수=금")
  check(Develop.investCostField("commerce") == "gold" and Develop.investCostField("land") == "gold",
    "investCostField 상업·토지=금")

  -- canInvest: 정상 / 0 / 알수없는 항목 / devDone / 자원부족.
  local region = freshRegion()
  check(Develop.canInvest(region, "flood", 100) == true, "canInvest 정상")
  check(Develop.canInvest(region, "flood", 0) == false, "canInvest 0 불가")
  check(Develop.canInvest(region, "xyz", 100) == false, "canInvest 잘못된 항목 불가")
  check(Develop.canInvest(region, "flood", 2000) == false, "canInvest 금부족 불가")
  region.devDone.flood = true
  check(Develop.canInvest(region, "flood", 100) == false, "canInvest devDone 항목 불가")
  check(Develop.canInvest(region, "loyal", 100) == true, "canInvest 다른 항목은 가능")

  -- applyInvest(금 항목): 금 차감 + 수치 상승 + devDone + 수행 장수 행동 소진.
  local r2 = freshRegion()
  local perf = { pol = 80, state = S.active, actionDone = false, moving = false }
  local gain = Develop.developGain(100, perf)
  local applied = Develop.applyInvest(r2, "flood", 100, perf)
  check(applied == gain, "applyInvest 반환 = 상승량")
  check(r2.flood == 40 + gain, "applyInvest 수치 상승")
  check(r2.gold == 900 and r2.grain == 2000, "applyInvest 금 항목은 금만 차감(군량 불변)")
  check(r2.devDone.flood == true, "applyInvest devDone set")
  check(perf.actionDone == true, "applyInvest 수행 장수 행동 소진")

  -- 민충성 투자 = 군량 소모(GDD 10장): 군량 차감, 금 불변.
  local r4 = freshRegion()
  local perf2 = { pol = 60, state = S.active, actionDone = false, moving = false }
  local g4 = Develop.developGain(300, perf2)
  Develop.applyInvest(r4, "loyal", 300, perf2)
  check(r4.loyal == 50 + g4, "민충성 투자 수치 상승")
  check(r4.grain == 1700 and r4.gold == 1000, "민충성 투자는 군량만 차감(금 불변)")

  -- 군량 부족이면 민충성 투자 불가(금은 충분해도).
  local r5 = freshRegion()
  r5.grain = 50
  check(Develop.canInvest(r5, "loyal", 300) == false, "민충성: 군량 부족 → 불가")
  check(Develop.canInvest(r5, "flood", 300) == true, "치수: 금 충분 → 가능(군량 무관)")

  -- 상한 클램프: 98에서 큰 투자 → 100 으로 멈추고 실제 상승분만 반환.
  local r3 = freshRegion()
  r3.commerce = 98
  local perfHi = { pol = 100, state = S.active, actionDone = false, moving = false }
  local realGain = Develop.applyInvest(r3, "commerce", 500, perfHi)
  check(r3.commerce == d.maxStat, "applyInvest 상한 클램프(100)")
  check(realGain == d.maxStat - 98, "applyInvest 클램프 후 실제 상승분 반환")
end

-- ── 내정: 인재 탐색 (game_state, GDD 10장) ───────────────
do
  local S = GameState.STATE
  local sc = config.search

  -- searchSuccessChance: 정치 높을수록 ↑, maxRate 클램프.
  check(Develop.searchSuccessChance({ pol = 100 }) > Develop.searchSuccessChance({ pol = 0 }),
    "searchSuccessChance 정치 ↑")
  check(Develop.searchSuccessChance({ pol = 0 }) == math.max(0, math.min(sc.maxRate, sc.base)),
    "searchSuccessChance 정치0 = base")
  check(Develop.searchSuccessChance({ pol = 100000 }) == sc.maxRate, "searchSuccessChance maxRate 클램프")

  -- undiscoveredFree: 같은 지역 free + 미발견만.
  local officers = {
    { id = "a", region = "r1", state = S.free, discovered = false },
    { id = "b", region = "r1", state = S.free, discovered = true },  -- 이미 발견
    { id = "c", region = "r2", state = S.free, discovered = false }, -- 다른 지역
    { id = "d", region = "r1", state = S.active, discovered = false },-- active
  }
  local pool = Develop.undiscoveredFree(officers, "r1")
  check(#pool == 1 and pool[1].id == "a", "undiscoveredFree 미발견 free 만")

  -- canSearch: 정상 / 장수없음 / 행동불가 / searchDone.
  local region = { searchDone = false }
  local perf = { state = S.active, actionDone = false, moving = false, pol = 50 }
  check(Develop.canSearch(region, perf) == true, "canSearch 정상")
  check(Develop.canSearch(region, nil) == false, "canSearch 수행 장수 없음 불가")
  check(Develop.canSearch(region, { state = S.active, actionDone = true }) == false, "canSearch 행동소진 불가")
  region.searchDone = true
  check(Develop.canSearch(region, perf) == false, "canSearch searchDone 불가")

  -- attemptSearch 성공(rng=0 → roll<chance): 첫 미발견 free discovered + searchDone + markActed + 반환.
  local off2 = {
    { id = "x", region = "r1", state = S.free, discovered = false },
    { id = "y", region = "r1", state = S.free, discovered = false },
  }
  local reg2 = { searchDone = false }
  local p2 = { state = S.active, actionDone = false, moving = false, pol = 100 }
  local found = Develop.attemptSearch(off2, "r1", reg2, p2, function() return 0 end)
  check(found ~= nil and found.discovered == true, "attemptSearch 성공 시 발견 + discovered")
  check(reg2.searchDone == true and p2.actionDone == true, "attemptSearch searchDone + 행동 소진")

  -- attemptSearch 실패(rng≈1 → roll>=chance): nil, 그래도 searchDone + markActed.
  local off3 = { { id = "z", region = "r1", state = S.free, discovered = false } }
  local reg3 = { searchDone = false }
  local p3 = { state = S.active, actionDone = false, moving = false, pol = 0 }
  local f3 = Develop.attemptSearch(off3, "r1", reg3, p3, function() return 0.999 end)
  check(f3 == nil, "attemptSearch 실패 → nil")
  check(reg3.searchDone == true and p3.actionDone == true and off3[1].discovered == false,
    "attemptSearch 실패해도 searchDone+소진, 발견 안 됨")

  -- 발견할 free 가 없으면 성공 굴림이어도 nil(빈손).
  local off4 = { { id = "w", region = "r1", state = S.active } }
  local reg4 = { searchDone = false }
  local p4 = { state = S.active, actionDone = false, moving = false, pol = 100 }
  check(Develop.attemptSearch(off4, "r1", reg4, p4, function() return 0 end) == nil,
    "attemptSearch 발견 대상 없으면 nil")
end

-- ── 내정: 등용 (game_state, GDD 14장 톤) ─────────────────
do
  local S = GameState.STATE
  local rc = config.recruit

  check(Develop.recruitChance({ pol = 100 }) > Develop.recruitChance({ pol = 0 }), "recruitChance 정치 ↑")
  check(Develop.recruitChance({ pol = 100000 }) == rc.maxRate, "recruitChance maxRate 클램프")

  -- canRecruit: 발견 free + 행동 가능 수행 장수.
  local perf = { state = S.active, actionDone = false, moving = false, pol = 80 }
  check(Develop.canRecruit({ state = S.free, discovered = true }, perf) == true, "canRecruit 정상")
  check(Develop.canRecruit({ state = S.free, discovered = false }, perf) == false, "canRecruit 미발견 불가")
  check(Develop.canRecruit({ state = S.active, discovered = true }, perf) == false, "canRecruit 재야 아님 불가")
  check(Develop.canRecruit({ state = S.free, discovered = true }, nil) == false, "canRecruit 수행 장수 없음 불가")

  -- attemptRecruit 성공(rng=0): active 편입 + faction + 초기 충성 + 발견 해제 + 행동 소진.
  local target = { id = "t", state = S.free, discovered = true, region = "r1", faction = nil }
  local p1 = { state = S.active, actionDone = false, moving = false, pol = 100 }
  local ok = Develop.attemptRecruit(target, p1, "wei", function() return 0 end)
  check(ok == true, "attemptRecruit 성공 true")
  check(target.state == S.active and target.faction == "wei", "attemptRecruit active+세력 편입")
  check(target.loyalty == rc.initLoyalty, "attemptRecruit 초기 충성도")
  check(target.discovered == nil and p1.actionDone == true, "attemptRecruit 발견 해제 + 행동 소진")

  -- attemptRecruit 실패(rng≈1): false, 대상 유지, 그래도 행동 소진(재시도 스팸 방지).
  local target2 = { id = "u", state = S.free, discovered = true, region = "r1" }
  local p2 = { state = S.active, actionDone = false, moving = false, pol = 0 }
  local ok2 = Develop.attemptRecruit(target2, p2, "wei", function() return 0.999 end)
  check(ok2 == false, "attemptRecruit 실패 false")
  check(target2.state == S.free and target2.discovered == true, "attemptRecruit 실패 시 대상 유지")
  check(p2.actionDone == true, "attemptRecruit 실패해도 행동 소진")
end

-- ── 내정: 턴 1회 플래그 리셋 (game_state, GDD 10장) ──────
do
  -- resetRegionActions: devDone/searchDone 전부 false 로.
  local rs = {
    r1 = { devDone = { flood = true, loyal = true, commerce = true, land = true }, searchDone = true },
    r2 = { devDone = { flood = false, loyal = true, commerce = false, land = false }, searchDone = false },
  }
  GameState.resetRegionActions(rs)
  check(rs.r1.devDone.flood == false and rs.r1.devDone.loyal == false
    and rs.r1.devDone.commerce == false and rs.r1.devDone.land == false and rs.r1.searchDone == false,
    "resetRegionActions r1 전부 false")
  check(rs.r2.devDone.loyal == false, "resetRegionActions r2 도 리셋")

  -- advanceTurn 에 regionState 넘기면 턴 진행 시 함께 리셋(GDD 10장 빨간 비활성 복구).
  local rs2 = { r1 = { devDone = { flood = true, loyal = false, commerce = false, land = false }, searchDone = true } }
  GameState.advanceTurn({ year = 1, month = 1, count = 1 }, { regionState = rs2 })
  check(rs2.r1.devDone.flood == false and rs2.r1.searchDone == false, "advanceTurn regionState 리셋")
end

-- ── 내정: build* 초기화 + 실제 시나리오 흐름 (GDD 5·10장) ──
do
  local sc = game_data.scenarios[3] -- three_kingdoms

  -- buildRegions: devDone(4항목 false) + searchDone false 초기화.
  local rs = GameState.buildRegions(game_data, sc)
  local ly = rs.luoyang
  check(ly.devDone and ly.devDone.flood == false and ly.devDone.loyal == false
    and ly.devDone.commerce == false and ly.devDone.land == false, "buildRegions devDone 초기화")
  check(ly.searchDone == false, "buildRegions searchDone 초기화")

  -- buildOfficers: discovered=false 초기화(전원).
  local officers = GameState.buildOfficers(game_data, sc)
  local allUndiscovered = true
  for _, o in ipairs(officers) do if o.discovered ~= false then allUndiscovered = false end end
  check(allUndiscovered, "buildOfficers discovered=false 초기화")

  -- 통합 흐름: 소유 지역(낙양) 태수로 투자 → 금 차감 + 수치 상승 + 빨간 비활성(devDone) → 리셋 복구.
  local governors = GameState.assignGovernors(game_data.regions, officers, function() return 1 end)
  local govId = governors.luoyang
  local gov = GameState.byId(officers, govId)
  local goldBefore, floodBefore = ly.gold, ly.flood
  check(Develop.canInvest(ly, "flood", 100) == true, "통합: 낙양 투자 가능")
  Develop.applyInvest(ly, "flood", 100, gov)
  check(ly.gold == goldBefore - 100 and ly.flood > floodBefore, "통합: 투자 후 금 차감 + 치수 상승")
  check(ly.devDone.flood == true and Develop.canInvest(ly, "flood", 100) == false, "통합: 재투자 불가(빨간 비활성)")
  GameState.resetRegionActions(rs)
  check(ly.devDone.flood == false, "통합: 턴 리셋 후 재투자 가능")
end

-- ── [버그회귀] 충성도 표기: 일반 장수는 수치, 수장만 '-' (GDD 7장) ──
do
  -- 3개 시나리오 전부: active 비수장은 numeric loyalty, 수장은 loyaltyText "-".
  --   (buildOfficers 의 isLord/loyalty 분기 함정 교정 + 데이터 누락 동시 방어)
  for si, sc in ipairs(game_data.scenarios) do
    local officers = GameState.buildOfficers(game_data, sc)
    local badNormal, badLord = 0, 0
    for _, o in ipairs(officers) do
      if o.state == GameState.STATE.active then
        if o.isLord then
          -- 수장: 충성도 표기는 반드시 "-".
          if GameState.loyaltyText(o) ~= "-" then badLord = badLord + 1; print("  [lord loyalty] " .. sc.id .. "/" .. o.id) end
        else
          -- 일반 active: 충성도는 숫자(loyaltyText 가 number 반환).
          if type(GameState.loyaltyText(o)) ~= "number" then
            badNormal = badNormal + 1; print("  [normal loyalty] " .. sc.id .. "/" .. o.id)
          end
        end
      end
    end
    check(badNormal == 0, "시나리오 " .. si .. " 일반 active 충성도 수치")
    check(badLord == 0, "시나리오 " .. si .. " 수장 충성도 '-'")
  end

  -- buildOfficers 분기: 수장은 loyalty=nil, 일반은 배치 loyalty 그대로(연산자 함정 회귀).
  local fakeData = { officers = {
    { id = "lordx", name = "군주X", might = 50, intel = 50, pol = 50, hp = 50, appear = 100 },
    { id = "genx",  name = "장수X", might = 50, intel = 50, pol = 50, hp = 50, appear = 100 },
  } }
  local fakeSc = {
    factions = { fx = { name = "에프", color = { 1, 1, 1 }, lord = "lordx" } },
    officers = {
      { id = "lordx", faction = "fx", region = "r", state = "active", loyalty = 77 }, -- 수장에 loyalty 가 있어도
      { id = "genx",  faction = "fx", region = "r", state = "active", loyalty = 64 },
    },
  }
  local built = GameState.buildOfficers(fakeData, fakeSc)
  local lordx = GameState.byId(built, "lordx")
  local genx = GameState.byId(built, "genx")
  check(lordx.isLord == true and lordx.loyalty == nil, "buildOfficers 수장 loyalty=nil(데이터에 있어도)")
  check(genx.isLord == false and genx.loyalty == 64, "buildOfficers 일반 loyalty=배치값")
end

-- ── 가중평균 합류 공식 (game_state.mergeTraining, GDD 11·12장 공용) ──
do
  -- 징병/이동 합류가 공유하는 공식: (oldT*oldTr + addT*addTr)/(oldT+addT).
  check(approx(GameState.mergeTraining(100, 80, 100, 0), 40), "mergeTraining (100*80+100*0)/200=40")
  check(approx(GameState.mergeTraining(0, 0, 50, 60), 60), "mergeTraining 기존0 → 합류 훈련도")
  check(GameState.mergeTraining(0, 0, 0, 0) == 0, "mergeTraining 0+0 → 0(나눗셈 가드)")
end

-- ── 이동/수송 명령 가능 판정 (movement.canMove/canTransport, GDD 12장) ──
do
  local M = Movement
  -- a,b = 내 소유 / n = 중립 / e = 적. 인접: a-n 만 인접(거리 무제한이라 a-b 인접 무관).
  local ownership = { a = "p", b = "p", e = "enemy" } -- n, far 는 키 없음 = 중립
  local function isAdj(x, y)
    return (x == "a" and y == "n") or (x == "n" and y == "a")
  end

  check((M.canMove(ownership, "a", "b", "p", isAdj)) == true, "canMove 내 소유끼리 거리 무제한")
  check((M.canMove(ownership, "a", "n", "p", isAdj)) == true, "canMove 인접 중립 점령 가능")
  check((M.canMove(ownership, "a", "far", "p", isAdj)) == false, "canMove 비인접 중립 불가")
  check((M.canMove(ownership, "a", "a", "p", isAdj)) == false, "canMove 같은 지역 불가")
  check((M.canMove(ownership, "a", "e", "p", isAdj)) == false, "canMove 적 지역 차단(전투 미구현)")
  check((M.canMove(ownership, "n", "a", "p", isAdj)) == false, "canMove 출발지 내 소유 아님")

  local rs = { a = { grain = 500 }, b = { grain = 100 } }
  check((M.canTransport(ownership, "a", "b", "p", 300, rs)) == true, "canTransport 정상")
  check((M.canTransport(ownership, "a", "n", "p", 300, rs)) == false, "canTransport 도착지 중립 불가")
  check((M.canTransport(ownership, "a", "b", "p", 0, rs)) == false, "canTransport 군량0 불가")
  check((M.canTransport(ownership, "a", "b", "p", 9999, rs)) == false, "canTransport 군량 부족 불가")
end

-- ── 이동 명령 생성 + 출발지 강등 + 도착 병력 합류 (movement, GDD 12·6장) ──
do
  local S = GameState.STATE
  local M = Movement
  -- 출발지 a(mover 단독), 도착지 b(수비대 garrison). 둘 다 내 소유.
  local mover = { id = "m", faction = "p", region = "a", state = S.active,
                  moving = false, actionDone = false, troops = 100, training = 80 }
  local garrison = { id = "g", faction = "p", region = "b", state = S.active,
                     moving = false, actionDone = false, troops = 100, training = 0 }
  local officers = { mover, garrison }
  local ownership = { a = "p", b = "p" }
  local governors = { a = "m", b = "g" }
  local orders = {}
  local rs = { a = { grain = 0 }, b = { grain = 0 } }
  local ctx = { regionState = rs, ownership = ownership, governors = governors, officers = officers }

  M.issueOrder(orders, M.ORDER.move, mover, "a", "b", 5, ctx)
  check(mover.moving == true and mover.actionDone == true and mover.region == nil,
    "issueOrder 이동중 + 행동 소진 + 출발지 분리")
  check(#orders == 1 and orders[1].arriveTurn == 5, "issueOrder 명령 목록 추가")
  -- 출발지 a 는 mover 가 유일 active → 떠나면 active 0 → 중립 강등 + 태수 해제(정합성 훅).
  check(ownership.a == nil and governors.a == nil, "issueOrder 출발지 active0 → 중립 강등 + 태수 해제")

  M.processArrival(orders[1], officers, rs, ownership, governors)
  check(mover.region == "b" and mover.moving == false, "도착 위치 갱신 + 이동중 해제")
  check(garrison.troops == 200, "도착 병력 합류 합산(100+100)")
  check(approx(garrison.training, (100 * 0 + 100 * 80) / 200), "도착 훈련도 가중평균(=40)")
  check(mover.troops == 0, "합류 후 이동 장수 병력 0(단일 부대 통합)")
end

-- ── 중립 무혈 입성 (movement, GDD 12장) ──
do
  local S = GameState.STATE
  local M = Movement
  local mover = { id = "m", faction = "p", region = "a", state = S.active,
                  moving = false, actionDone = false, troops = 120, training = 50 }
  local officers = { mover }
  local ownership = { a = "p" } -- b 는 중립(키 없음)
  local governors = { a = "m" }
  local orders = {}
  local rs = { a = { grain = 0 }, b = { grain = 0 } }
  local ctx = { regionState = rs, ownership = ownership, governors = governors, officers = officers }

  M.issueOrder(orders, M.ORDER.move, mover, "a", "b", 2, ctx)
  M.processArrival(orders[1], officers, rs, ownership, governors)
  check(ownership.b == "p", "무혈 입성: 중립 → 내 소유로 소유권 이전")
  check(mover.region == "b" and mover.troops == 120, "무혈 입성 후 장수 위치 + 병력 유지")
end

-- ── 수송 도착: 군량 이전 (movement, GDD 12장) ──
do
  local S = GameState.STATE
  local M = Movement
  -- 출발지 a 에 수송 장수 + 수비 장수(a 안 비게), 도착지 b.
  local mover = { id = "m", faction = "p", region = "a", state = S.active,
                  moving = false, actionDone = false, troops = 0, training = 0 }
  local keep = { id = "k", faction = "p", region = "a", state = S.active, troops = 50, training = 0 }
  local garrisonB = { id = "g", faction = "p", region = "b", state = S.active, troops = 0, training = 0 }
  local officers = { mover, keep, garrisonB }
  local ownership = { a = "p", b = "p" }
  local governors = { a = "k", b = "g" }
  local orders = {}
  local rs = { a = { grain = 500 }, b = { grain = 100 } }
  local ctx = { regionState = rs, ownership = ownership, governors = governors, officers = officers, grain = 300 }

  M.issueOrder(orders, M.ORDER.transport, mover, "a", "b", 3, ctx)
  check(rs.a.grain == 200, "수송 출발지 군량 즉시 차감(500-300)")
  check(ownership.a == "p", "수송: 출발지 수비 장수 있어 강등 안 됨")
  M.processArrival(orders[1], officers, rs, ownership, governors)
  check(rs.b.grain == 400, "수송 도착지 군량 가산(100+300)")
end

-- ── 도착 타이밍/제거 (movement.processArrivals, GDD 3·12장) ──
do
  local S = GameState.STATE
  local M = Movement
  local mover = { id = "m", faction = "p", region = nil, state = S.active, troops = 10, training = 0, moving = true }
  local g = { id = "g", faction = "p", region = "b", state = S.active, troops = 0, training = 0 }
  local officers = { mover, g }
  local ownership = { b = "p" }
  local governors = { b = "g" }
  local rs = { a = {}, b = {} }
  local orders = { { kind = M.ORDER.move, officerId = "m", from = "a", to = "b", arriveTurn = 5, troops = 10, training = 0 } }

  -- 도착 전 턴(arrivingCount=4 < 5) → 유지.
  M.processArrivals(orders, 4, officers, rs, ownership, governors)
  check(#orders == 1, "processArrivals 도착 전 명령 유지")
  -- 도착 턴(5) → 처리 + 제거.
  M.processArrivals(orders, 5, officers, rs, ownership, governors)
  check(#orders == 0, "processArrivals 도착 후 명령 제거")
  check(mover.region == "b" and g.troops == 10, "processArrivals 도착 처리 적용(병력 합류)")
end

-- ── 전투 시스템 (battle, GDD 13장, 시드 고정) ────────────
do
  local S = GameState.STATE
  local b = config.battle
  -- 전투용 더미 장수. equip=nil 이라 effectiveStat=기본 무력.
  local function off(id, faction, region, might, troops, training)
    return { id = id, name = id, faction = faction, region = region, state = S.active,
             might = might, intel = 50, pol = 50, hp = 50,
             troops = troops or 0, training = training or 0,
             moving = false, actionDone = false, equip = nil }
  end

  -- 1) 전쟁 진입 판정.
  do
    local officers = { off("a", "p", "r1", 80, 100, 0) } -- r1 출진 장수
    local ownership = { r1 = "p", r2 = "e", r3 = "p", r5 = "e" } -- r2 인접 적 / r3 내 / r5 비인접 적
    local function adj(x, y) return (x == "r1" and y == "r2") or (x == "r2" and y == "r1") end
    check((Battle.canDeclareWar(ownership, officers, "r1", "r2", "p", adj)) == true, "canDeclareWar 인접 적 지역")
    check((Battle.canDeclareWar(ownership, officers, "r1", "r3", "p", adj)) == false, "canDeclareWar 내 지역 불가")
    check((Battle.canDeclareWar(ownership, officers, "r1", "r4", "p", adj)) == false, "canDeclareWar 빈 땅 불가")
    check((Battle.canDeclareWar(ownership, officers, "r1", "r5", "p", adj)) == false, "canDeclareWar 비인접 적 불가")
    check((Battle.canDeclareWar(ownership, {}, "r1", "r2", "p", adj)) == false, "canDeclareWar 출진 장수 없음")
  end

  -- 2) 유닛 생성 + 스탯 공식.
  do
    local o = off("u1", "p", "r1", 80, 100, 50)
    local d = off("u2", "e", "r2", 10, 20, 0)
    local battle = Battle.create({ o, d }, "r1", "r2", "p", "e")
    check(#battle.units == 2, "유닛 수 = 양측 장수 수")
    local u = Battle.unitById(battle, "u1")
    check(u.hp == 100 * b.hpPerTroop, "유닛 HP = 병력 * hpPerTroop")
    check(u.atk == math.floor(b.atkBase + 80 * b.atkPerMight + 50 * b.atkPerTraining), "유닛 공격력 공식(무력+훈련도)")
    check(u.def == math.floor(b.defBase + 80 * b.defPerMight + 50 * b.defPerTraining), "유닛 방어력 공식")
    check(o.actionDone == true, "출진 공격 장수 행동 소진")
  end

  -- 3) 데미지 + 전멸 승패.
  do
    local atk = off("atk1", "p", "r1", 100, 200, 0)
    local def = off("def1", "e", "r2", 10, 20, 0)
    local battle = Battle.create({ atk, def }, "r1", "r2", "p", "e")
    local ua = Battle.unitById(battle, "atk1")
    local ud = Battle.unitById(battle, "def1")
    -- 인접 칸으로 옮겨 공격 가능하게(맨해튼 1).
    ua.x, ua.y = 1, 0; ud.x, ud.y = 2, 0
    check(Battle.canAttack(battle, ua, ud) == true, "사거리 내 공격 가능")
    local dmg = Battle.damageOf(ua, ud)
    check(dmg == math.max(b.minDamage, ua.atk - ud.def), "데미지 = max(min, 공격-방어)")
    Battle.attack(battle, ua, ud)
    check(ud.hp == 0, "데미지로 방어 유닛 HP 0(병력 20 < 데미지)")
    check(battle.over == true and battle.result == Battle.SIDE.atk, "한쪽 전멸 → 종료, 공격 승")
  end

  -- 4) 결과 반영 — 공격 승(소유권 이전 + 포획 훅 + 점령 입성 + 태수 재선정).
  do
    local a1 = off("a1", "p", "r1", 80, 100, 0)
    local d1 = off("d1", "e", "r2", 50, 80, 0)
    local officers = { a1, d1 }
    local ownership = { r1 = "p", r2 = "e" }
    local governors = { r1 = "a1", r2 = "d1" }
    local battle = {
      from = "r1", to = "r2", atkFaction = "p", defFaction = "e",
      over = true, result = Battle.SIDE.atk,
      units = {
        { officerId = "a1", side = Battle.SIDE.atk, hp = 60 }, -- 생존
        { officerId = "d1", side = Battle.SIDE.def, hp = 0 },  -- 전멸
      },
    }
    local captured
    Battle.resolve(battle, officers, ownership, governors,
      function() return 1 end, function(rid, fid, defs) captured = defs end)
    check(ownership.r2 == "p", "공격 승 → 소유권 이전")
    check(a1.region == "r2" and a1.troops == 60, "생존 공격 장수 점령 입성 + 잔여 병력")
    check(captured and #captured == 1 and captured[1].id == "d1", "포획 훅에 방어 장수 전달")
    check(d1.region == nil and d1.troops == 0, "방어 장수 보드에서 제거(포획 후보)")
    check(governors.r2 == "a1", "점령지 태수 재선정(공격 장수)")
    check(ownership.r1 == nil, "출발지 active 0명 → 중립 강등(정합성)")
  end

  -- 5) 결과 반영 — 공격 패(소유권 유지 + 공격 장수 출발지 복귀 + 병력 손실).
  do
    local a1 = off("a1", "p", "r1", 80, 100, 0)
    local d1 = off("d1", "e", "r2", 50, 80, 0)
    local officers = { a1, d1 }
    local ownership = { r1 = "p", r2 = "e" }
    local governors = { r1 = "a1", r2 = "d1" }
    local battle = {
      from = "r1", to = "r2", atkFaction = "p", defFaction = "e",
      over = true, result = Battle.SIDE.def,
      units = {
        { officerId = "a1", side = Battle.SIDE.atk, hp = 0 },  -- 공격 전멸
        { officerId = "d1", side = Battle.SIDE.def, hp = 30 }, -- 방어 생존
      },
    }
    Battle.resolve(battle, officers, ownership, governors, function() return 1 end, nil)
    check(ownership.r2 == "e", "공격 패 → 소유권 유지")
    check(a1.region == "r1" and a1.troops == 0, "공격 장수 출발지 복귀 + 병력 손실")
    check(d1.troops == 30, "방어 장수 잔여 병력 유지")
  end

  -- 6) 적 턴 휴리스틱(가장 가까운 적으로 이동 후 사거리 내면 공격).
  do
    local a1 = off("a1", "p", "r1", 100, 200, 80)
    local d1 = off("d1", "e", "r2", 50, 50, 0)
    local battle = Battle.create({ a1, d1 }, "r1", "r2", "p", "e")
    local ua = Battle.unitById(battle, "a1")
    local ud = Battle.unitById(battle, "d1")
    ua.x, ua.y = 3, 2; ud.x, ud.y = 5, 2 -- 거리 2: 이동력 2로 4,2 까지(공격 유닛에 막힘) 후 사거리 1 공격
    local hp0 = ua.hp
    Battle.aiTurn(battle, nil)
    check(ud.x == 4 and ud.y == 2, "AI 가장 가까운 적으로 이동")
    check(ua.hp < hp0, "AI 사거리 내면 공격")
  end
end

-- ── 포로/등용/처형 (captive, GDD 14장, 시드 고정) ────────
do
  local S = GameState.STATE
  local function off(id, faction, loyalty, equip)
    return { id = id, name = id, faction = faction, region = nil, state = S.active,
             might = 50, intel = 50, pol = 50, hp = 50, troops = 0, training = 0,
             loyalty = loyalty, isLord = false, equip = equip }
  end

  -- 1) 포획 판정: rng<0.5 → 포획(captured).
  do
    local d = off("d1", "e", 60)
    local ownership = { r2 = "p" } -- 잃은 지역 r2 는 공격자 소유, e 다른 지역 없음
    local captured = Captive.processDefeated({ d }, "p", "r2", ownership, function() return 0 end)
    check(#captured == 1 and d.state == S.captured, "포획 성공(rng<0.5) → captured")
  end

  -- 2) 도주: rng>=0.5 + 같은 세력 다른 지역 있음 → 도주(active 복귀, 그 지역으로).
  do
    local d = off("d2", "e", 60)
    local ownership = { r2 = "p", r3 = "e" } -- e 가 r3 보유 → 도주지 있음
    local captured = Captive.processDefeated({ d }, "p", "r2", ownership, function() return 0.9 end)
    check(#captured == 0, "도주 성공(rng>=0.5) → 포획 안 됨")
    check(d.state == S.active and d.region == "r3", "도주 → active 복귀 + 같은 세력 지역으로")
  end

  -- 3) 도주지 없음 → 전원 포획(rng>=0.5 여도).
  do
    local d = off("d3", "e", 60)
    local ownership = { r2 = "p" } -- e 의 다른 지역 없음
    local captured = Captive.processDefeated({ d }, "p", "r2", ownership, function() return 0.9 end)
    check(#captured == 1 and d.state == S.captured, "도주지 없으면 포획")
  end

  -- 4) 등용 확률: 충성 낮을수록 ↑, 상한 클램프.
  do
    local c = config.captive
    check(approx(Captive.recruitChance({ loyalty = 100 }), c.recruitBase), "등용률 충성100 = base")
    check(Captive.recruitChance({ loyalty = 0 }) == c.recruitMaxRate, "등용률 충성0 → maxRate 클램프")
    check(Captive.recruitChance({ loyalty = 30 }) > Captive.recruitChance({ loyalty = 80 }), "등용률 충성 낮을수록 ↑")
  end

  -- 5) 등용 성공(rng=0): 편입 + 장비 동반.
  do
    local item = { id = "sword", name = "검", force = 10 }
    local d = off("d4", "e", 20, item); d.state = S.captured
    local ok = Captive.attemptRecruit(d, "p", "r2", function() return 0 end)
    check(ok == true, "등용 성공(rng=0)")
    check(d.state == S.active and d.faction == "p" and d.region == "r2", "등용 → 세력 편입 + 배치")
    check(d.loyalty == config.captive.initLoyalty and d.isLord == false, "등용 후 초기 충성 + 군주 해제")
    check(d.equip == item, "등용 시 장비 동반")
  end

  -- 6) 등용 실패(rng=0.99): 포로 유지.
  do
    local d = off("d5", "e", 90); d.state = S.captured
    local ok = Captive.attemptRecruit(d, "p", "r2", function() return 0.99 end)
    check(ok == false and d.state == S.captured, "등용 실패 → 포로 유지")
  end

  -- 7) 처형: 사망 + 장비 군주 귀속.
  do
    local item = { id = "spear", name = "창", force = 8 }
    local d = off("d6", "e", 40, item); d.state = S.captured
    local inv = {}
    Captive.execute(d, inv)
    check(d.state == S.dead and d.region == nil, "처형 → 사망")
    check(#inv == 1 and inv[1] == item and d.equip == nil, "처형 시 장비 군주 장비고 귀속")
  end
end

-- ── 자동 전투 + 전략 AI (battle.autoBattle / ai, 시드 고정) ──
do
  local S = GameState.STATE
  local function off(id, faction, region, might, troops, training)
    return { id = id, name = id, faction = faction, region = region, state = S.active,
             might = might, intel = 50, pol = 50, hp = 50,
             troops = troops or 0, training = training or 0,
             moving = false, actionDone = false, equip = nil, loyalty = 70, isLord = false }
  end
  local function rng0() return 0 end
  local function rng1() return 1 end

  -- autoBattle: 강한 공격(전멸 승) → result atk.
  do
    local atk = off("a", "p", "r1", 100, 500, 80)
    local def = off("d", "e", "r2", 10, 30, 0)
    local battle = Battle.autoBattle({ atk, def }, "r1", "r2", "p", "e", rng0)
    check(battle.over == true and battle.result == Battle.SIDE.atk, "autoBattle 강한 공격 → 공격 승")
  end

  -- AI.run: 병력 부족 + 공격 후보 없음 → 징병.
  do
    local o = off("ai1", "e", "r1", 50, 10, 0) -- 병력 10(<minTroopsToAttack, <lowTroops)
    local officers = { o }
    local regions = { { id = "r1", q = 0, r = 0 } }
    local ownership = { r1 = "e" }
    local regionState = { r1 = { id = "r1", name = "R1", gold = 1000, pop = 80, loyal = 60,
      flood = 80, commerce = 80, land = 80,
      devDone = { flood = false, loyal = false, commerce = false, land = false }, searchDone = false } }
    local governors = { r1 = "ai1" }
    AI.run({ officers = officers, regions = regions, ownership = ownership, regionState = regionState,
      governors = governors, factionInventory = {}, playerFid = "p",
      isAdjacent = function() return false end, rng = rng0, rng1n = rng1 })
    check(o.troops > 10, "AI 병력 부족 → 징병(병력 증가)")
  end

  -- AI.run: 병력 충분 + 공격 후보 없음 + 내정 낮음 → 개발.
  do
    local o = off("ai2", "e", "r1", 50, 300, 100) -- 병력·훈련 충분 → 징병/훈련 스킵
    local officers = { o }
    local regions = { { id = "r1", q = 0, r = 0 } }
    local ownership = { r1 = "e" }
    local regionState = { r1 = { id = "r1", name = "R1", gold = 1000, pop = 80, loyal = 60,
      flood = 10, commerce = 10, land = 10, -- 치수 낮음 → 개발 대상
      devDone = { flood = false, loyal = false, commerce = false, land = false }, searchDone = false } }
    local governors = { r1 = "ai2" }
    local floodBefore = regionState.r1.flood
    AI.run({ officers = officers, regions = regions, ownership = ownership, regionState = regionState,
      governors = governors, factionInventory = {}, playerFid = "p",
      isAdjacent = function() return false end, rng = rng0, rng1n = rng1 })
    check(regionState.r1.flood > floodBefore, "AI 내정 낮음 → 개발(수치 상승)")
  end

  -- AI.run: 인접 플레이어 지역 + 충분히 유리 → 자동 전투로 점령(소유권 이전).
  do
    local aiGen = off("aiG", "e", "r1", 100, 500, 80)
    local plGen = off("plG", "p", "r2", 10, 20, 0)
    local officers = { aiGen, plGen }
    local regions = { { id = "r1" }, { id = "r2" } }
    local ownership = { r1 = "e", r2 = "p" }
    local regionState = {
      r1 = { id="r1", gold=0, pop=0, loyal=0, flood=99, commerce=99, land=99, devDone={flood=true,loyal=true,commerce=true,land=true}, searchDone=true },
      r2 = { id="r2", gold=0, pop=0, loyal=0, flood=99, commerce=99, land=99, devDone={flood=true,loyal=true,commerce=true,land=true}, searchDone=true },
    }
    local governors = { r1 = "aiG", r2 = "plG" }
    AI.run({ officers = officers, regions = regions, ownership = ownership, regionState = regionState,
      governors = governors, factionInventory = {}, playerFid = "p",
      isAdjacent = function(a, b) return (a=="r1" and b=="r2") or (a=="r2" and b=="r1") end,
      rng = rng0, rng1n = rng1 })
    check(ownership.r2 == "e", "AI 유리한 공격 → 플레이어 지역 점령(소유권 이전)")
  end
end

-- ── 결과 ─────────────────────────────────────────────────
print(string.format("\n테스트 결과: %d 통과 / %d 실패", passed, failed))
os.exit(failed == 0 and 0 or 1)
