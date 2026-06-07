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

  -- 194 군웅할거는 전 지역 소유(중립 없음) — 11세력 분할 검증.
  local warlords
  for _, sc in ipairs(scenarios) do if sc.id == "warlords" then warlords = sc end end
  local owned = 0
  for _ in pairs(warlords.ownership) do owned = owned + 1 end
  check(owned == 30, "194 전 지역 소유 (실제=" .. owned .. ")")

  -- 184 황건의 난도 전 지역 분할(한 관군 제거, 군벌 배치). 'han' 세력 없어야.
  local yt
  for _, sc in ipairs(scenarios) do if sc.id == "yellow_turban" then yt = sc end end
  local owned184 = 0
  for _ in pairs(yt.ownership) do owned184 = owned184 + 1 end
  check(owned184 == 30, "184 전 지역 소유 (실제=" .. owned184 .. ")")
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

  -- 장비 선물은 이번 범위 밖(스텁) — 미구현 플래그 false.
  check(GameState.EQUIP_IMPLEMENTED == false, "장비 미구현 스텁 플래그")
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

-- ── 결과 ─────────────────────────────────────────────────
print(string.format("\n테스트 결과: %d 통과 / %d 실패", passed, failed))
os.exit(failed == 0 and 0 or 1)
