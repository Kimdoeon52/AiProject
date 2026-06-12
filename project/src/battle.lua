--[[
battle.lua — 전투 규칙 (순수 Lua, love 비의존) — GDD 13장

  이 모듈의 책임:
    - 그리드 전술 전투의 "규칙"을 순수 Lua 로 제공한다.
      · 진입 판정(canDeclareWar): 인접 적 소유 + 출발지 장수≥1·병력>0.
      · 전투 생성(create): 양측 장수 수만큼 유닛 생성, 좌/우 진영 배치, 스탯 계산.
      · 진행(canMove/moveUnit, canAttack/attack): 플레이어가 직접 이동·공격.
      · 적 턴 휴리스틱(aiTurn): 가장 가까운 적으로 이동 후 사거리 내면 공격(정교화 금지).
      · 승패(checkOver) 전멸 기준 + 결과 반영(resolve): 소유권 이전·병력 손실·포획 훅·정합성.
    - love.* 가 전혀 없어 project/tests/ 에서 시드 고정 단위 테스트 가능(CLAUDE.md 결정 3).
  관계:
    - game_state.lua : 장수 상태(STATE)·조회(byId)·유효능력치(effectiveStat)·정합성(demoteIfVacant)·태수(assignGovernor) 재사용.
    - config.lua     : 전투 계수(그리드/이동력/사거리/스탯·데미지) 단일 출처(매직넘버 금지).
    - region.lua     : 인접 판정은 main 이 Region.areAdjacent 로 isAdjacent 함수로 주입(battle 은 지도 모름).
    - main.lua       : 전투 씬 상태(state.battle)를 들고 이 모듈 함수를 호출(표현·입력은 battle_view).

  핵심 모델 결정(왜 이렇게):
    - 유닛 = 장수 1명(그 장수의 병력). "데려간 장수 수만큼 유닛"(GDD 13장).
    - 병력 = 유닛 HP(내구도), 무력+훈련도 = 공격/방어 품질(GDD 13장 '무력+병력+훈련도').
      병력을 HP 로 두어 '투입 병력'이 전투 지속력으로 작동한다(스탯 이중계산 방지).
    - 승패는 전멸로만(GDD 정정). 후퇴 없음.
    - 전투는 즉시 해결(전략 턴과 별개의 전투 턴 루프). 플레이어 턴 ↔ 적 턴 교대.

  다른 언어 비교:
    - units 배열 = C# List<Unit> / C++ std::vector<Unit>.
    - isAdjacent/onCaptured 처럼 함수를 인자로 받음 = C# delegate / C++ std::function 주입(의존성 역전).
--]]

local GameState = require("game_state")
local config = require("config")

local Battle = {}

Battle.SIDE = { atk = "atk", def = "def" }

-- ── 좌표 헬퍼 ────────────────────────────────────────────

--- 두 칸의 맨해튼 거리(|dx|+|dy|). 사거리·이동력 판정에 쓴다.
--   왜 맨해튼: 격자에서 상하좌우 이동 기준 거리(대각 비허용). C 의 abs 합과 동일.
local function manhattan(ax, ay, bx, by)
  return math.abs(ax - bx) + math.abs(ay - by)
end

-- ── 진입 판정 ────────────────────────────────────────────

--- 전쟁(전투 진입)이 가능한지 검사한다 (GDD 13장). 순수 함수.
-- 규칙: 출발지=플레이어 소유 / 목적지=인접 + 적(타 세력) 소유 / 출발지에 병력>0 장수 1명 이상.
--   (중립·빈 땅은 전투 아님 — 이동(12장) 무혈 입성 소관.)
-- @param ownership table   런타임 소유 맵 { [regionId]=factionId }
-- @param officers table    런타임 장수 전체(출발지 출진 가능 장수 확인)
-- @param fromId,toId string
-- @param playerFid any     플레이어 세력 id
-- @param isAdjacent fun(a,b):boolean  인접 판정(main 이 Region.areAdjacent 주입)
-- @return boolean ok, string|nil reason
function Battle.canDeclareWar(ownership, officers, fromId, toId, playerFid, isAdjacent)
  if not toId or fromId == toId then return false, "같은 지역" end
  if ownership[fromId] ~= playerFid then return false, "출발지가 내 소유 아님" end
  local destOwner = ownership[toId]
  if destOwner == nil then return false, "빈 땅은 이동(무혈 입성) 대상" end
  if destOwner == playerFid then return false, "내 지역은 공격 대상 아님" end
  if not (isAdjacent and isAdjacent(fromId, toId)) then return false, "인접 지역만 공격 가능" end
  -- 출진 가능 장수(active + 병력>0)가 있어야 공격 성립.
  if #Battle.marchers(officers, fromId, playerFid) == 0 then
    return false, "출진할 병력 있는 장수 없음"
  end
  return true
end

--- 한 지역에서 출진(전투 투입) 가능한 장수 목록 = 같은 세력 + active + 병력>0.
-- 공격측·방어측 유닛 생성에 공통으로 쓴다. (병력 0 장수는 유닛이 안 됨 — 싸울 병사 없음)
-- @return table  장수 배열
function Battle.marchers(officers, regionId, factionId)
  local out = {}
  for _, o in ipairs(officers) do
    if o.region == regionId and o.faction == factionId
       and o.state == GameState.STATE.active and (o.troops or 0) > 0 then
      out[#out + 1] = o
    end
  end
  return out
end

-- ── 유닛 생성 ────────────────────────────────────────────

--- 장수 1명으로 전투 유닛 1개를 만든다(스탯 계산). 내부 헬퍼.
-- 스탯 공식(GDD 13장, 계수는 config.battle):
--   HP   = 병력 * hpPerTroop                               (투입 병력 = 내구도)
--   공격 = atkBase + 유효무력*atkPerMight + 훈련도*atkPerTraining
--   방어 = defBase + 유효무력*defPerMight + 훈련도*defPerTraining
--   유효무력 = effectiveStat(장수,"might") = 기본 무력 + 장비 보너스(GDD 8장).
-- @param officer table  런타임 장수
-- @param side string    Battle.SIDE.atk | .def
-- @param x,y number     초기 그리드 좌표
-- @return table  유닛
local function makeUnit(officer, side, x, y)
  local b = config.battle
  local might = GameState.effectiveStat(officer, "might")
  local training = officer.training or 0
  local troops = officer.troops or 0
  local hp = troops * b.hpPerTroop
  return {
    officerId = officer.id,
    name = officer.name,
    side = side,
    x = x, y = y,
    hp = hp, maxHp = hp,
    troops = troops,
    -- math.floor: 소수 버림(정수 스탯). C 의 (int) 캐스트와 유사.
    atk = math.floor(b.atkBase + might * b.atkPerMight + training * b.atkPerTraining),
    def = math.floor(b.defBase + might * b.defPerMight + training * b.defPerTraining),
    moved = false,    -- 이번 전투턴 이동했는지
    attacked = false, -- 이번 전투턴 공격했는지
  }
end

--- 한 진영 유닛들을 세로로 가운데 정렬해 배치한다(내부 헬퍼).
-- @param list table   장수 배열
-- @param side string
-- @param colX number  이 진영의 열(공격=0, 방어=gridW-1)
-- @return table  유닛 배열
local function placeSide(list, side, colX)
  local b = config.battle
  local n = #list
  -- 세로 가운데 정렬 시작 행. n 이 gridH 보다 크면 0 부터(겹치지 않게 클램프).
  local startY = math.max(0, math.floor((b.gridH - n) / 2))
  local out = {}
  for i, o in ipairs(list) do
    local y = math.min(b.gridH - 1, startY + (i - 1))
    out[i] = makeUnit(o, side, colX, y)
  end
  return out
end

--- 전투를 생성한다 (GDD 13장). 양측 장수 수만큼 유닛 + 좌/우 배치.
-- 부작용: 공격측 장수는 이번 전략 턴 행동 소진(actionDone=true) — 전투에 나선 셈.
-- @param officers table     런타임 장수 전체
-- @param fromId,toId string 출발지(공격)·목적지(방어=공격 대상)
-- @param atkFaction any     공격 세력 id
-- @param defFaction any     방어 세력 id(= ownership[toId])
-- @return table  battle 상태
function Battle.create(officers, fromId, toId, atkFaction, defFaction)
  local b = config.battle
  local atkList = Battle.marchers(officers, fromId, atkFaction)
  local defList = Battle.marchers(officers, toId, defFaction)

  local units = {}
  for _, u in ipairs(placeSide(atkList, Battle.SIDE.atk, 0)) do units[#units + 1] = u end
  for _, u in ipairs(placeSide(defList, Battle.SIDE.def, b.gridW - 1)) do units[#units + 1] = u end

  -- 공격측 장수: 전투 출진 = 이번 턴 행동 소진(중복 명령 방지).
  for _, o in ipairs(atkList) do o.actionDone = true end

  local battle = {
    from = fromId, to = toId,
    atkFaction = atkFaction, defFaction = defFaction,
    units = units,
    turn = Battle.SIDE.atk, -- 공격측(플레이어)부터
    over = false, result = nil, -- result: "atk" | "def"
  }
  -- 한쪽이 유닛 0이면(병력 없는 수비 등) 즉시 승패 결정.
  Battle.checkOver(battle)
  return battle
end

-- ── 조회 ─────────────────────────────────────────────────

--- 살아있는 유닛만(hp>0) 필터. 여러 판정의 기준.
local function aliveUnits(battle, side)
  local out = {}
  for _, u in ipairs(battle.units) do
    if u.hp > 0 and (not side or u.side == side) then out[#out + 1] = u end
  end
  return out
end

--- 특정 칸(x,y)에 있는 살아있는 유닛(없으면 nil). 점유 판정·클릭 선택에 쓴다.
function Battle.unitAt(battle, x, y)
  for _, u in ipairs(battle.units) do
    if u.hp > 0 and u.x == x and u.y == y then return u end
  end
  return nil
end

--- id 로 유닛 조회(없으면 nil).
function Battle.unitById(battle, id)
  for _, u in ipairs(battle.units) do if u.officerId == id then return u end end
  return nil
end

-- ── 이동 ─────────────────────────────────────────────────

--- 유닛이 (x,y)로 이동 가능한지. 순수.
-- 조건: 전투 안 끝남 / 이번 턴 미이동 / 그리드 안 / 이동력 내 / 빈 칸.
-- @return boolean
function Battle.canMove(battle, unit, x, y)
  if battle.over or unit.hp <= 0 or unit.moved then return false end
  local b = config.battle
  if x < 0 or x >= b.gridW or y < 0 or y >= b.gridH then return false end
  if manhattan(unit.x, unit.y, x, y) > b.moveRange then return false end
  if Battle.unitAt(battle, x, y) then return false end -- 점유 칸 불가
  return true
end

--- 유닛을 이동시킨다(canMove 통과 가정). 부작용: 유닛 좌표 + moved=true.
function Battle.moveUnit(battle, unit, x, y)
  unit.x, unit.y = x, y
  unit.moved = true
end

-- ── 공격 ─────────────────────────────────────────────────

--- attacker 가 target 을 공격 가능한지. 순수.
-- 조건: 전투 안 끝남 / 미공격 / 적군 / 살아있음 / 사거리 내.
-- @return boolean
function Battle.canAttack(battle, attacker, target)
  if battle.over or attacker.hp <= 0 or attacker.attacked then return false end
  if not target or target.hp <= 0 or target.side == attacker.side then return false end
  return manhattan(attacker.x, attacker.y, target.x, target.y) <= config.battle.attackRange
end

--- 데미지 계산 = max(minDamage, floor(공격 - 방어)) (GDD 13장, 계수 config.battle).
--   왜 차감식: 방어가 높을수록 데미지 감소, 단 최소 데미지로 교착(0 데미지) 방지.
-- @return number
function Battle.damageOf(attacker, target)
  local b = config.battle
  return math.max(b.minDamage, math.floor(attacker.atk - target.def))
end

--- 공격을 실행한다(canAttack 통과 가정). HP 차감 → 0 이하면 유닛 제거 → 승패 갱신.
-- 부작용: target.hp/troops 감소(제거 시 hp=0), attacker.attacked=true, battle.over/result 갱신.
-- @return number  입힌 데미지
function Battle.attack(battle, attacker, target)
  local dmg = Battle.damageOf(attacker, target)
  target.hp = target.hp - dmg
  if target.hp < 0 then target.hp = 0 end
  -- 병력도 HP 비율로 동기화(표시·전투 후 손실 반영). hp 0 → 병력 0(유닛 제거 = 그 장수 패주/포획 후보).
  target.troops = math.max(0, target.hp)
  attacker.attacked = true
  Battle.checkOver(battle)
  return dmg
end

-- ── 승패 ─────────────────────────────────────────────────

--- 한쪽 전멸이면 battle.over=true + result 설정 (GDD 13장 전멸 기준). 부작용: battle.over/result.
-- @return boolean over
function Battle.checkOver(battle)
  if battle.over then return true end
  local atkAlive = #aliveUnits(battle, Battle.SIDE.atk)
  local defAlive = #aliveUnits(battle, Battle.SIDE.def)
  if atkAlive == 0 or defAlive == 0 then
    battle.over = true
    -- 양측 0 동시(이론상)면 방어 우세 처리(공격 실패). 보통은 한쪽만 0.
    battle.result = (atkAlive > 0) and Battle.SIDE.atk or Battle.SIDE.def
  end
  return battle.over
end

-- ── 적(방어) 턴 휴리스틱 ─────────────────────────────────
--   GDD 16(전략 AI)과 별개의 최소 전술 AI: 가장 가까운 적으로 이동 후 사거리 내면 공격.
--   정교화 금지(스코프 락). 결정적 동작이라 시드 없이도 재현 — rng 는 동률 흔들기용(선택).

--- 한 칸씩 target 방향으로 이동력만큼 다가간다(점유/그리드 밖 회피). 내부 헬퍼.
-- 큰 축(dx vs dy)부터 한 칸 줄이며 빈 칸이면 전진, 막히면 다른 축 시도. C# 의 그리디 추적과 동일.
-- @return number,number  최종 x,y
local function stepToward(battle, unit, tx, ty)
  local b = config.battle
  local x, y = unit.x, unit.y
  for _ = 1, b.moveRange do
    local dx, dy = tx - x, ty - y
    if dx == 0 and dy == 0 then break end
    -- 후보 한 칸(큰 축 우선). sign: 양수 +1, 음수 -1.
    local cands = {}
    if math.abs(dx) >= math.abs(dy) then
      if dx ~= 0 then cands[#cands + 1] = { x + (dx > 0 and 1 or -1), y } end
      if dy ~= 0 then cands[#cands + 1] = { x, y + (dy > 0 and 1 or -1) } end
    else
      if dy ~= 0 then cands[#cands + 1] = { x, y + (dy > 0 and 1 or -1) } end
      if dx ~= 0 then cands[#cands + 1] = { x + (dx > 0 and 1 or -1), y } end
    end
    local moved = false
    for _, c in ipairs(cands) do
      local cx, cy = c[1], c[2]
      if cx >= 0 and cx < b.gridW and cy >= 0 and cy < b.gridH and not Battle.unitAt(battle, cx, cy) then
        x, y = cx, cy
        moved = true
        break
      end
    end
    if not moved then break end -- 다 막힘 → 정지
  end
  return x, y
end

--- 가장 가까운 적 유닛을 찾는다(맨해튼 최소, 동률은 먼저 등장). 내부 헬퍼.
-- @param enemySide string  적으로 칠 진영(공격 유닛이면 def, 방어 유닛이면 atk)
local function nearestEnemy(battle, unit, enemySide)
  local best, bestD
  for _, e in ipairs(aliveUnits(battle, enemySide)) do
    local d = manhattan(unit.x, unit.y, e.x, e.y)
    if not bestD or d < bestD then best, bestD = e, d end
  end
  return best
end

--- 한 진영(side) 전체의 전술 휴리스틱 턴: 각 유닛이 가장 가까운 적으로 이동 후 사거리 내면 공격.
-- 방어 AI(플레이어 전투)와 자동 전투(autoBattle) 양쪽이 공유하는 한 진영 처리(중복 구현 금지).
-- 부작용: 그 진영 유닛 좌표·공격(데미지)·battle.over 갱신. 시작 시 그 진영 행동 플래그 리셋.
-- @param battle table
-- @param side string      처리할 진영(Battle.SIDE.atk | .def)
-- @param rng function|nil
function Battle.sideTurn(battle, side, rng)
  if battle.over then return end
  local enemySide = (side == Battle.SIDE.atk) and Battle.SIDE.def or Battle.SIDE.atk
  -- 이 진영 행동 플래그 리셋(이번 진영 턴에 다시 이동/공격 가능).
  for _, u in ipairs(aliveUnits(battle, side)) do u.moved = false; u.attacked = false end
  for _, u in ipairs(aliveUnits(battle, side)) do
    if not battle.over and u.hp > 0 then
      local target = nearestEnemy(battle, u, enemySide)
      if target then
        -- 사거리 밖이면 한 발짝 다가간다.
        if manhattan(u.x, u.y, target.x, target.y) > config.battle.attackRange then
          local nx, ny = stepToward(battle, u, target.x, target.y)
          u.x, u.y = nx, ny
        end
        if Battle.canAttack(battle, u, target) then Battle.attack(battle, u, target) end
      end
    end
  end
end

--- 방어측 AI 턴(플레이어 전투에서 호출) — sideTurn(def) 위임 (GDD 13장).
function Battle.aiTurn(battle, rng)
  Battle.sideTurn(battle, Battle.SIDE.def, rng)
end

--- 플레이어(공격측) 턴을 마치고 방어 AI 를 처리한 뒤, 끝나지 않았으면 다시 공격측 턴으로.
-- 부작용: aiTurn 수행 + 모든 유닛 moved/attacked 리셋(새 전투턴).
function Battle.endPlayerTurn(battle, rng)
  if battle.over then return end
  battle.turn = Battle.SIDE.def
  Battle.aiTurn(battle, rng)
  if battle.over then return end
  -- 새 전투턴: 행동 플래그 리셋, 공격측 차례.
  for _, u in ipairs(battle.units) do u.moved = false; u.attacked = false end
  battle.turn = Battle.SIDE.atk
end

--- AI/비플레이어 전투를 그리드 UI 없이 자동 해결한다 (GDD 13·16장).
-- 양 진영이 같은 전술 휴리스틱(sideTurn)으로 교대 → 한쪽 전멸까지. 상한 라운드 초과 시
-- 잔여 HP 합이 큰 쪽 승(교착 안전망). 호출자가 이후 Battle.resolve 로 전략 상태에 반영한다.
-- @param officers table     런타임 장수 전체
-- @param fromId,toId string 출발지(공격)·목적지(방어)
-- @param atkFaction,defFaction any
-- @param rng function|nil
-- @return table  battle(over=true, result 설정됨)
function Battle.autoBattle(officers, fromId, toId, atkFaction, defFaction, rng)
  local battle = Battle.create(officers, fromId, toId, atkFaction, defFaction)
  local rounds = 0
  while not battle.over and rounds < config.battle.autoMaxRounds do
    Battle.sideTurn(battle, Battle.SIDE.atk, rng)
    if battle.over then break end
    Battle.sideTurn(battle, Battle.SIDE.def, rng)
    rounds = rounds + 1
  end
  -- 상한 도달(교착) 안전망: 잔여 HP 합이 큰 쪽 승. 동률은 방어 우세(공격 실패).
  if not battle.over then
    local atkHp, defHp = 0, 0
    for _, u in ipairs(battle.units) do
      if u.side == Battle.SIDE.atk then atkHp = atkHp + u.hp else defHp = defHp + u.hp end
    end
    battle.over = true
    battle.result = (atkHp > defHp) and Battle.SIDE.atk or Battle.SIDE.def
  end
  return battle
end

-- ── 결과 반영 (전략 상태로) ───────────────────────────────

--- 전투 결과를 전략 상태에 반영한다 (GDD 13장). battle.over 후 main 이 1회 호출.
-- 처리:
--   · 모든 유닛의 잔여 HP → 그 장수 병력(troops)으로 기록(전투 손실 반영).
--   · 공격 승: 목적지 소유권을 공격 세력으로 이전. 생존 공격 장수는 목적지 점령(이동),
--     전멸한 공격 장수는 출발지로 복귀(병력 0). 방어 장수는 보드에서 내려 포획 훅으로 넘김(D4).
--   · 공격 패: 공격 장수 전원 출발지 복귀(병력 손실 반영). 방어 장수는 목적지 유지.
--   · 양 지역 태수 재선정 + 정합성(active 0명 지역 중립 강등) — game_state 훅 재사용.
-- 부작용: officers(troops/region/state), ownership, governors 변경. onCaptured 훅 호출.
-- @param battle table
-- @param officers table
-- @param ownership table
-- @param governors table
-- @param rng function|nil   태수 재선정 동률용
-- @param onCaptured fun(regionId, attackerFid, defenderGenerals)|nil  포획 판정 훅(D4 — 여기선 호출만)
function Battle.resolve(battle, officers, ownership, governors, rng, onCaptured)
  if not battle.over then return end

  if battle.result == Battle.SIDE.atk then
    -- 공격 승: 소유권 이전.
    ownership[battle.to] = battle.atkFaction
    local capturedDefenders = {}
    for _, u in ipairs(battle.units) do
      local o = GameState.byId(officers, u.officerId)
      if o then
        o.troops = math.max(0, u.hp)
        if u.side == Battle.SIDE.atk then
          -- 생존 = 목적지 점령 입성, 전멸 = 출발지로 패주(병력 0).
          o.region = (u.hp > 0) and battle.to or battle.from
        else
          -- 방어 장수: 지역을 잃음 → 보드에서 내려(region=nil) 포획 후보로.
          --   전멸 승이라 방어 유닛은 모두 hp 0(부대 소멸)이지만 장수 본인은 패주/포획 대상 →
          --   유닛 생존 여부와 무관하게 "패배한 방어 장수 전원"을 훅으로 넘긴다(GDD 14장: 점령 시 포획).
          --   실제 포획(50%)·도주·등용/처형은 D4. 여기선 명단만 전달(TODO).
          capturedDefenders[#capturedDefenders + 1] = o
          o.region = nil
          o.troops = 0
        end
      end
    end
    -- 포획 판정 훅(D4 — TODO: 실제 포획/도주/등용/처형). 지금은 호출(로그)만.
    if onCaptured then onCaptured(battle.to, battle.atkFaction, capturedDefenders) end
  else
    -- 공격 패: 공격 장수 전원 출발지 복귀(병력 손실 반영). 방어 장수는 목적지 유지.
    for _, u in ipairs(battle.units) do
      local o = GameState.byId(officers, u.officerId)
      if o then
        o.troops = math.max(0, u.hp)
        if u.side == Battle.SIDE.atk then o.region = battle.from end
      end
    end
  end

  -- 정합성(GDD 6장): 두 지역 모두 active 0명이면 중립 강등 + 태수 해제.
  GameState.demoteIfVacant(ownership, governors, officers, battle.from)
  GameState.demoteIfVacant(ownership, governors, officers, battle.to)
  -- 태수 재선정: 아직 소유 중인 지역만(점령으로 장수 구성이 바뀜).
  if ownership[battle.to] then governors[battle.to] = GameState.assignGovernor(officers, battle.to, rng) end
  if ownership[battle.from] then governors[battle.from] = GameState.assignGovernor(officers, battle.from, rng) end
end

return Battle
