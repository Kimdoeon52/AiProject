--[[
ai.lua — 전략 AI (순수 Lua, love 비의존) — GDD 16장

  이 모듈의 책임:
    - AI 세력의 턴 종료 후 행동을 결정·수행한다. 각 소유 지역을 순회하며 우선순위대로 한 행동:
      1. 유리한 목표 공격(중립 무혈 점령 / 적·플레이어 지역 전투) → 2. 병력 부족 시 징병
      → 3. 훈련도 낮으면 훈련 → 4. 내정 수치 낮으면 개발. (GDD 16장 우선순위)
    - love.* 가 전혀 없어 project/tests/ 에서 시드 고정 단위 테스트 가능(CLAUDE.md 결정 3).
  관계:
    - game_state.lua : 장수/지역 규칙(징병·훈련·태수·정합성) 재사용.
    - battle.lua     : AI 전투는 그리드 UI 없이 autoBattle 로 자동 해결 후 resolve.
    - captive.lua    : 점령 시 포로 자동 처리(등용 시도 → 실패 시 처형).
    - develop.lua    : 내정 투자.
    - region.lua     : 인접 판정은 main 이 Region.areAdjacent 를 isAdjacent 로 주입(ai 는 지도 모름).
    - main.lua       : advanceTurn 의 onAI 훅에서 AI.run(ctx) 호출.

  스코프 락(CLAUDE.md): GDD 16장 "단순 우선순위"만. 전술/전략 정교화 금지(임계값 기반 휴리스틱).
  랜덤(rng): [0,1) 실수 주입 → 전투/포로 판정 시드 고정 테스트.
--]]

local GameState = require("game_state")
local Battle = require("battle")
local Captive = require("captive")
local Develop = require("develop")
local config = require("config")

local AI = {}

-- ── 조회 헬퍼 ────────────────────────────────────────────

--- 한 지역의 특정 세력 active 장수 목록.
local function activesIn(officers, regionId, fid)
  local out = {}
  for _, o in ipairs(officers) do
    if o.region == regionId and o.faction == fid and o.state == GameState.STATE.active then
      out[#out + 1] = o
    end
  end
  return out
end

--- 한 지역의 특정 세력 총 병력(active 장수 troops 합).
local function regionTroops(officers, regionId, fid)
  local n = 0
  for _, o in ipairs(activesIn(officers, regionId, fid)) do n = n + (o.troops or 0) end
  return n
end

--- 그 지역의 행동할 AI 장수(태수 우선, 없으면 첫 active). 모두 행동 소진이면 nil.
local function actingOfficer(ctx, regionId, fid)
  local list = activesIn(ctx.officers, regionId, fid)
  local govId = ctx.governors and ctx.governors[regionId]
  if govId then
    for _, o in ipairs(list) do if o.id == govId and GameState.canAct(o) then return o end end
  end
  for _, o in ipairs(list) do if GameState.canAct(o) then return o end end
  return nil
end

-- ── 목표 선택 ────────────────────────────────────────────

--- 인접한 최선의 공격/점령 목표를 고른다 (GDD 16장 공격 판단). 내부 헬퍼.
-- 후보: 인접한 비(非)자기 지역.
--   · 중립(소유 없음) → 무혈 점령(전투 없음). 가장 유리 → 최고 점수.
--   · 적/플레이어 소유 → 공격 병력 ≥ 방어 병력 * attackAdvantage 일 때만. 플레이어 지역 가중.
-- @return table|nil  { id, owner(nil=중립), kind="occupy"|"battle" }
local function chooseTarget(ctx, regionId, fid)
  local atk = regionTroops(ctx.officers, regionId, fid)
  if atk < config.ai.minTroopsToAttack then return nil end -- 병력 일정 이상만 공격(GDD 16)
  local best, bestScore = nil, -1
  for _, adj in ipairs(ctx.regions) do
    if adj.id ~= regionId and ctx.isAdjacent(regionId, adj.id) then
      local owner = ctx.ownership[adj.id]
      if owner == nil then
        -- 중립 → 무혈 점령. 가장 적극(GDD 16 "중립 더 적극") → 높은 점수.
        if 2.0 > bestScore then best, bestScore = { id = adj.id, owner = nil, kind = "occupy" }, 2.0 end
      elseif owner ~= fid then
        -- 적/플레이어 → 병력 충분히 유리할 때만.
        local defT = regionTroops(ctx.officers, adj.id, owner)
        if atk >= defT * config.ai.attackAdvantage then
          local score = (owner == ctx.playerFid) and config.ai.playerWeight or 1.0
          if score > bestScore then
            best, bestScore = { id = adj.id, owner = owner, kind = "battle" }, score
          end
        end
      end
    end
  end
  return best
end

-- ── 행동 수행 ────────────────────────────────────────────

--- 중립 지역 무혈 점령: 여분 장수 1명을 옮겨 소유권을 가져온다(출발지 비우지 않음).
-- 출발지에 active 장수가 2명 이상일 때만(1명뿐이면 옮기면 출발지가 비어 중립 강등 → 무의미).
-- @return boolean  점령했으면 true
local function tryOccupy(ctx, regionId, fid, target)
  local list = activesIn(ctx.officers, regionId, fid)
  if #list < 2 then return false end -- 여분 없음 → 점령 보류
  -- 옮길 장수: 행동 가능한 첫 장수(태수는 출발지에 남기는 편이 단순).
  local mover
  for _, o in ipairs(list) do if GameState.canAct(o) then mover = o; break end end
  if not mover then return false end
  mover.region = target.id
  GameState.markActed(mover)
  ctx.ownership[target.id] = fid
  -- 태수 재선정: 새 점령지 + (장수 빠진) 출발지.
  ctx.governors[target.id] = GameState.assignGovernor(ctx.officers, target.id, ctx.rng1n)
  ctx.governors[regionId] = GameState.assignGovernor(ctx.officers, regionId, ctx.rng1n)
  return true
end

--- AI 가 점령 시 포로 자동 처리(등용 시도 → 실패면 처형). captive 규칙 재사용.
local function aiCaptureHandler(ctx, fid)
  return function(capturedRegion, atkFid, defenders)
    local captured = Captive.processDefeated(defenders, atkFid, capturedRegion, ctx.ownership, ctx.rng)
    for _, cap in ipairs(captured) do
      -- AI 는 등용 우선(병력원 확보), 실패 시 처형(장비는 AI 군주 장비고로).
      if not Captive.attemptRecruit(cap, atkFid, capturedRegion, ctx.rng) then
        ctx.factionInventory[atkFid] = ctx.factionInventory[atkFid] or {}
        Captive.execute(cap, ctx.factionInventory[atkFid])
      end
    end
  end
end

--- 적/플레이어 지역 공격: AI 최소 1명 수비 잔류 후 자동 전투 해결 + 결과 반영. (GDD 13·16장)
--
-- AI 출진 규칙(GDD 13장): 출발지에 항상 ≥1명을 남겨 과확장 방지.
--   · active 장수 N명 → 최대 N-1명 출진.
--   · 1명뿐이면 출진 포기(이 지역에서 공격 안 함) → false 반환.
--
-- C# 비교: 이 함수 = bool TryAttack(...) { if (!canLaunch) return false; ... return true; }
-- @return boolean  출진 성공 여부(false = 1명만 있어 포기)
local function tryAttack(ctx, regionId, fid, target)
  -- Battle.marchers: active + 병력>0 필터 — 출진 가능 장수 전체.
  local allMarchers = Battle.marchers(ctx.officers, regionId, fid)
  -- 1명뿐이면 출진 시 출발지가 비어 중립 강등 → 과확장. 포기.
  if #allMarchers <= 1 then return false end

  -- 출진 장수: 무력(effectiveStat "might" = 기본 무력 + 장비 보너스, GDD 8·13장) 내림차순 정렬.
  -- 상위 N-1명 출진, 최하위 1명은 수비 잔류.
  -- 정교한 전술 판단(진형·집중공격 등)은 스코프 락 — 단순 무력순만.
  -- table.sort: C# List.Sort() / C++ std::sort() 와 동일. 비교 함수(comparator) 방식.
  table.sort(allMarchers, function(a, b)
    return (GameState.effectiveStat(a, "might") or 0) > (GameState.effectiveStat(b, "might") or 0)
  end)
  local atkList = {}
  for i = 1, #allMarchers - 1 do
    atkList[#atkList + 1] = allMarchers[i]
  end

  -- atkList 를 Battle.autoBattle 에 주입 → N-1명만 유닛으로 전투 참여.
  -- 잔류 1명(atkList 에 없는 장수)은 유닛 미생성 → 전투 후에도 fromId 유지(GDD 13장).
  local battle = Battle.autoBattle(ctx.officers, regionId, target.id, fid, target.owner, ctx.rng, atkList)
  Battle.resolve(battle, ctx.officers, ctx.ownership, ctx.governors, ctx.rng1n, aiCaptureHandler(ctx, fid))
  return true
end

--- 한 지역에서 AI 가 한 행동을 결정·수행한다 (GDD 16장 우선순위). 내부.
local function actRegion(ctx, regionId, fid)
  local officer = actingOfficer(ctx, regionId, fid)
  if not officer then return end -- 행동 가능 장수 없음
  local region = ctx.regionState[regionId]

  -- 1) 공격/점령(가장 유리한 인접 목표).
  local target = chooseTarget(ctx, regionId, fid)
  if target then
    if target.kind == "occupy" then
      if tryOccupy(ctx, regionId, fid, target) then return end
      -- 점령 보류(여분 없음)면 아래 내정으로 진행.
    else
      -- 공격: 최소 1명 잔류 규칙으로 포기(1명뿐)면 내정으로 진행.
      -- C# 비교: if (TryAttack(...)) return; else { ... 내정 ... }
      if tryAttack(ctx, regionId, fid, target) then return end
    end
  end

  -- 2) 병력 부족 → 징병.
  if (officer.troops or 0) < config.ai.lowTroops and (GameState.canRecruit(region, officer)) then
    GameState.applyRecruit(region, officer)
    return
  end
  -- 3) 훈련도 낮음 → 훈련.
  if (officer.troops or 0) > 0 and (officer.training or 0) < config.ai.lowTraining
     and (GameState.canTrain(officer)) then
    GameState.applyTrain(officer)
    return
  end
  -- 4) 내정 수치 낮음 → 개발(가장 낮은 항목 1개).
  for _, it in ipairs(Develop.DEV_ITEMS) do
    if (region[it.key] or 0) < config.ai.lowStat
       and (Develop.canInvest(region, it.key, config.ai.investAmount)) then
      Develop.applyInvest(region, it.key, config.ai.investAmount, officer)
      return
    end
  end
end

--- AI 세력 전체의 턴을 수행한다 (GDD 16장). advanceTurn 의 onAI 훅에서 호출.
-- 각 지역을 순회(고정 region 순서 — 결정적)하며 소유 세력이 AI(=플레이어 아님)면 한 행동.
--   순회 중 점령/강등으로 소유가 바뀌면 ownership 재확인으로 건너뛴다.
-- 부작용: officers/ownership/governors/regionState/factionInventory 변경(규칙 모듈 통해).
-- @param ctx table  {
--   officers, regions, ownership, regionState, governors, factionInventory,
--   playerFid, isAdjacent(a,b)->bool, rng()->[0,1), rng1n(n)->1..n }
function AI.run(ctx)
  ctx.factionInventory = ctx.factionInventory or {}
  for _, r in ipairs(ctx.regions) do
    local fid = ctx.ownership[r.id]
    -- 소유 세력이 있고 플레이어가 아니면 = AI 세력 지역 → 한 행동.
    if fid and fid ~= ctx.playerFid then
      actRegion(ctx, r.id, fid)
    end
  end
end

return AI
