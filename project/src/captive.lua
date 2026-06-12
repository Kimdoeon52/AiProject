--[[
captive.lua — 포로/등용/처형 규칙 (순수 Lua, love 비의존) — GDD 14장

  이 모듈의 책임:
    - 점령 시 패배한 적 장수의 처리 규칙을 순수 Lua 로 제공한다.
      · 포획/도주 판정(processDefeated): 50% 포획, 실패 시 같은 세력 다른 지역 도주, 도주지 없으면 포획.
      · 포로 등용(attemptRecruit): 충성도 낮을수록 성공률 ↑ → 성공 시 점령 세력 편입(장비 동반).
      · 처형(execute): 장수 사망 처리 + 장비는 군주(점령 세력) 귀속.
    - love.* 가 전혀 없어 project/tests/ 에서 시드 고정 단위 테스트 가능(CLAUDE.md 결정 3).
  관계:
    - battle.lua     : 전투 승리 후 resolve 가 패배 방어 장수 명단을 onCaptured 훅으로 넘김 →
                       main(플레이어 점령) 또는 ai(AI 점령)가 이 모듈로 처리.
    - game_state.lua : 장수 상태(STATE) 재사용.
    - config.lua     : 포획/등용 확률 계수(매직넘버 금지).
    - captive_popup.lua : 플레이어 포로 팝업이 canRecruit/attemptRecruit/execute 를 호출(표현·입력).

  핵심 규칙(GDD 14장):
    - 점령 시 적 장수 50% 확률 포획. 실패 = 같은 세력 다른 지역으로 도주(active 유지).
      도주할 지역(같은 세력 소유)이 없으면 그 장수도 포획(→ "도주지 없으면 전원 포획").
    - 등용 확률 = 충성도 낮을수록 높음(옛 주군에 미련 적은 자가 잘 귀순).
    - 장비: 등용 시 동반(그대로 장착), 처형 시 장비는 점령 군주 장비고로 귀속.

  랜덤(rng): [0,1) 실수 주입(없으면 math.random). 주입하면 시드 고정 테스트 가능.
--]]

local GameState = require("game_state")
local config = require("config")

local Captive = {}

--- [0,1) 실수 난수 1개(주입 rng 우선). 확률 판정용.
local function rollFloat(rng)
  if rng then return rng() end
  return math.random() -- 인자 없는 math.random(): [0,1) 실수
end

-- ── 포획/도주 판정 ───────────────────────────────────────

--- 그 세력이 도주할 수 있는 다른 소유 지역을 찾는다(내부 헬퍼).
-- 도주지 = 그 세력이 아직 소유한 지역 중 잃은 지역이 아닌 곳. 없으면 nil.
--   (잃은 지역 lostRegion 은 이미 점령 세력으로 소유 이전된 상태라 보통 후보에서 제외됨.)
-- @param ownership table  런타임 소유 맵
-- @param fid any          도주하는(패배) 세력 id
-- @param lostRegion string 방금 잃은 지역(제외)
-- @return string|nil  도주 지역 id
local function escapeRegion(ownership, fid, lostRegion)
  for regionId, owner in pairs(ownership) do
    if owner == fid and regionId ~= lostRegion then return regionId end
  end
  return nil
end

--- 패배한 방어 장수들을 포획/도주 처리한다 (GDD 14장). 상태 변경 함수.
-- 각 장수마다: 50% 포획 판정 → 포획이면 state=captured(보드에서 내려진 상태 유지),
--   실패면 같은 세력 다른 지역으로 도주(region=그 지역, state=active 복귀).
--   도주지가 없으면 그 장수도 포획(→ 도주지 없으면 전원 포획).
-- 부작용: 각 장수의 state/region 변경. (병력은 battle.resolve 가 이미 0 으로 만든 상태)
-- @param defenders table   패배 방어 장수 배열(battle.resolve 가 넘김; region=nil, troops=0)
-- @param attackerFid any   점령(공격) 세력 id (현재 미사용 — 등용 시 attemptRecruit 가 받음)
-- @param lostRegion string 점령당한 지역 id
-- @param ownership table   런타임 소유 맵(도주지 탐색용)
-- @param rng function|nil  [0,1) 실수
-- @return table  실제 포획된 장수 배열(포로 — 등용/처형 대상)
function Captive.processDefeated(defenders, attackerFid, lostRegion, ownership, rng)
  local captured = {}
  for _, o in ipairs(defenders) do
    -- 포획 판정: 굴린 값이 포획 확률보다 작으면 포획.
    local caught = rollFloat(rng) < config.captive.captureChance
    if not caught then
      -- 도주 시도: 같은 세력 다른 소유 지역으로. 있으면 그리로(active 복귀), 없으면 포획.
      local dest = escapeRegion(ownership, o.faction, lostRegion)
      if dest then
        o.region = dest
        o.state = GameState.STATE.active
      else
        caught = true -- 도주지 없음 → 포획(GDD 14장: 도주지 없으면 전원 포획)
      end
    end
    if caught then
      o.state = GameState.STATE.captured
      captured[#captured + 1] = o
    end
  end
  return captured
end

-- ── 등용 ─────────────────────────────────────────────────

--- 포로 등용 성공 확률 (GDD 14장). 충성도 낮을수록 ↑.
-- 공식: clamp(base + (maxLoyalty - 충성) * perLowLoyalty, 0, maxRate).
--   충성 100 → base, 충성 0 → base + 100*perLowLoyalty(최대치 근처).
-- @param officer table  포로 장수(loyalty 보유; 군주였다면 nil → 0 취급)
-- @return number  0~maxRate 확률
function Captive.recruitChance(officer)
  local c = config.captive
  local loyalty = officer.loyalty or 0
  local low = config.officer.maxLoyalty - loyalty
  return math.max(0, math.min(c.recruitMaxRate, c.recruitBase + low * c.recruitPerLowLoyalty))
end

--- 이 장수가 등용 대상(포로)인지. 순수.
-- @param officer table
-- @return boolean
function Captive.canRecruit(officer)
  return officer ~= nil and officer.state == GameState.STATE.captured
end

--- 포로 등용을 시도한다 (GDD 14장). 상태 변경 함수.
-- 성공: 점령 세력 active 로 편입(faction/region/충성 initLoyalty), 장비는 그대로 동반(equip 유지).
-- 실패: 포로 상태 유지(다시 등용 시도 또는 처형 가능).
-- 부작용: 성공 시 officer 의 state/faction/region/loyalty/isLord 변경. canRecruit 통과 가정.
--   ── isLord: 적 군주를 등용하면 더 이상 군주 아님(우리 세력 일반 장수) → isLord=false.
-- @param officer table        포로 장수(변경됨)
-- @param newFid any           편입할 세력 id(점령 세력)
-- @param regionId string      배치 지역(점령 지역)
-- @param rng function|nil     [0,1) 실수
-- @return boolean 성공 여부
function Captive.attemptRecruit(officer, newFid, regionId, rng)
  if rollFloat(rng) >= Captive.recruitChance(officer) then
    return false -- 등용 실패(포로 유지)
  end
  officer.state = GameState.STATE.active
  officer.faction = newFid
  officer.region = regionId
  officer.isLord = false -- 적 군주를 흡수해도 우리 세력 군주는 아님
  officer.loyalty = config.captive.initLoyalty
  -- 장비(equip)는 건드리지 않음 → 등용 시 그대로 동반(GDD 14장).
  return true
end

-- ── 처형 ─────────────────────────────────────────────────

--- 포로를 처형한다 (GDD 14장). 상태 변경 함수.
-- 장수 사망 처리 + 장비 보유 시 점령 군주 장비고로 귀속(officer.equip → inventory).
-- 부작용: officer.state=dead, region=nil. 장비 있으면 inventory 에 push 후 officer.equip=nil.
-- @param officer table     포로 장수(변경됨)
-- @param inventory table|nil  점령 세력 미장착 장비고(장비 귀속처). 없으면 장비 소멸.
function Captive.execute(officer, inventory)
  if officer.equip then
    if inventory then inventory[#inventory + 1] = officer.equip end -- 군주 귀속(GDD 14장)
    officer.equip = nil
  end
  officer.state = GameState.STATE.dead
  officer.region = nil
end

return Captive
