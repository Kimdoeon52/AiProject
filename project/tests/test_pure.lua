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

-- ── 군주 소재 지역 + 금 선물 풀 (GDD 9·15장) ─────────────
do
  local sc = game_data.scenarios[3]
  local officers = GameState.buildOfficers(game_data, sc)
  local rs = GameState.buildRegions(game_data, sc)

  -- 위 군주(caopi)는 낙양에 위치 → lordRegionId = luoyang.
  local rid = GameState.lordRegionId(officers, "wei", sc)
  check(rid == "luoyang", "lordRegionId 위 군주 = 낙양")

  -- 금 선물이 그 지역 금 풀에서 차감되는 흐름(canGiftGold/applyGiftGold 숫자 in/out 유지).
  local pool = rs[rid]
  local target = nil
  for _, o in ipairs(officers) do
    if o.faction == "wei" and not o.isLord and o.state == GameState.STATE.active then target = o; break end
  end
  local before = pool.gold
  local ok = GameState.canGiftGold(pool.gold, target, 3)
  check(ok == true, "canGiftGold 군주 지역 금 충분")
  pool.gold = GameState.applyGiftGold(pool.gold, target, 3)
  check(pool.gold == before - 3, "applyGiftGold 군주 지역 금에서 차감")
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

-- ── 결과 ─────────────────────────────────────────────────
print(string.format("\n테스트 결과: %d 통과 / %d 실패", passed, failed))
os.exit(failed == 0 and 0 or 1)
