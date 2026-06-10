--[[
develop.lua — 내정(투자/인재 탐색·등용) 규칙 (love 비의존, 순수)

  이 모듈의 책임:
    - GDD 10·14장 내정 규칙을 순수 Lua 로 제공한다(love.* 없음 → tests 가능).
    - 소유 지역에 금을 투자해 내정 수치(치수/민충성/상업/토지)를 올리고,
      수행 장수로 재야(free) 장수를 탐색·발견하고 등용한다.
  관계:
    - game_state.lua : 장수 상태/행동 규칙(STATE, canAct, markActed)을 빌려 쓴다(단방향 의존).
                       game_state 는 develop 를 require 하지 않는다(순환 없음).
                       단, 턴 1회 플래그 리셋(resetRegionActions)과 지역/장수 레코드의
                       devDone/searchDone/discovered 필드 초기화는 game_state 가 소유한다.
    - config.lua     : 투자 효율·탐색/등용 확률 계수(매직넘버 금지).
    - dev_popup.lua  : 이 규칙을 호출해 내정 UI 를 구성(표현·입력).

  계층 원칙(CLAUDE.md): 규칙은 여기, 표현·입력은 dev_popup/main, 데이터는 game_data/config.
    game_state.lua 가 800줄을 넘어, "내정 규칙"이라는 한 책임을 이 모듈로 분리했다.

  랜덤(rng): 확률 판정은 주입 rng() (→ [0,1) 실수)를 쓴다. 주입하면 시드 고정 테스트 가능.
--]]

local config = require("config")
local GameState = require("game_state")

local Develop = {}

-- 투자 항목 정의 (GDD 10장). 화면 표시 순서를 가진 배열.
--   key 는 곧 지역 내부수치 필드명과 같다(flood/loyal/commerce/land) → region[key] 로 직접 갱신.
--   cost 는 비용 자원 필드명: 민충성만 "grain"(군량), 나머지는 "gold"(금) — GDD 10장.
--   (Lua 배열 of table = C# 의 List<(string,string,string)>, C++ 의 vector<struct> 느낌)
Develop.DEV_ITEMS = {
  { key = "flood",    label = "치수",   cost = "gold"  },
  { key = "loyal",    label = "민충성", cost = "grain" }, -- 민심 안정 = 곡식을 푼다 → 군량 소모
  { key = "commerce", label = "상업",   cost = "gold"  },
  { key = "land",     label = "토지",   cost = "gold"  },
}

-- 유효한 투자 항목 키 → 비용 자원 필드 룩업(빠른 검증·비용 조회용). C# Dictionary 와 같은 용도.
local DEV_COST = {}
for _, it in ipairs(Develop.DEV_ITEMS) do DEV_COST[it.key] = it.cost end

--- 이 투자 항목의 비용 자원 필드명을 돌려준다 (GDD 10장). "gold" | "grain".
--   민충성(loyal)=군량, 나머지=금. 알 수 없는 항목은 nil.
-- @param item string  투자 항목 키
-- @return string|nil  "gold" | "grain"
function Develop.investCostField(item)
  return DEV_COST[item]
end

-- 비용 자원 표시명(UI 안내·사유 문구). field("gold"|"grain") → 한글.
local COST_LABEL = { gold = "금", grain = "군량" }
function Develop.costLabel(item)
  return COST_LABEL[DEV_COST[item]] or "자원"
end

--- [0,1) 실수 난수 1개(주입 rng 우선). 확률 판정용.
--   love.math.random() / math.random() 는 인자 없이 부르면 [0,1) 실수를 준다.
--   주입하면 시드 고정 테스트 가능(love 비의존).
local function rollFloat(rng)
  if rng then return rng() end
  return math.random() -- 인자 없는 math.random(): [0,1) 실수 (C 의 rand()/RAND_MAX 비슷)
end

--- [0,1) 실수를 1..n 정수 인덱스로 변환(주입 rng 우선). 발견 대상 random 선택용.
--   floor(r*n)+1: r∈[0,1) 이므로 결과는 항상 1..n. (n명 중 1명 균등 선택)
local function pickIndexFloat(rng, n)
  return math.floor(rollFloat(rng) * n) + 1
end

-- ── 투자 4종 (GDD 10장) ──────────────────────────────────

--- 투자 1회의 내정 수치 상승량을 계산한다 (GDD 10장).
-- 공식: floor(투자금 * perGold * (1 + 수행정치 * polBonus)).
--   왜 이렇게: 투자금이 클수록·수행 장수 정치가 높을수록 더 많이 오른다(효율).
--   수행 장수 없으면 정치 0(기본 효율). 계수는 config.develop(매직넘버 금지).
-- @param amount number       투자 금액
-- @param performer table|nil 수행 장수(정치 pol). 없으면 정치 0 취급.
-- @return number 이번 투자로 오를 수치(정수, 클램프 전)
function Develop.developGain(amount, performer)
  local c = config.develop
  local pol = performer and performer.pol or 0
  return math.floor(amount * c.perGold * (1 + pol * c.polBonus))
end

--- 투자가 가능한지 검사한다(버튼 활성/실행 전 판정). 순수 함수.
-- 조건: 유효 항목 / 그 지역 그 항목 이번 턴 미투자 / 금액 1 이상 / 비용 자원 충분.
--   비용 자원은 항목별로 다르다(GDD 10장): 민충성=군량, 나머지=금. region[costField] 로 검사.
-- @param region table  런타임 지역(gold, grain, devDone 보유)
-- @param item string   투자 항목 키(flood/loyal/commerce/land)
-- @param amount number 투자량
-- @return boolean ok, string|nil reason
function Develop.canInvest(region, item, amount)
  local costField = Develop.investCostField(item)
  if not costField then return false, "알 수 없는 투자 항목" end
  -- 지역당 같은 항목 한 턴 1회(GDD 10장).
  if region.devDone[item] then return false, "이번 턴 이미 투자함" end
  if amount < 1 then return false, "투자량 1 이상" end
  if region[costField] < amount then return false, "지역 " .. Develop.costLabel(item) .. " 부족" end
  return true, nil
end

--- 투자를 적용한다 (GDD 10장). 비용 자원 차감 + 수치 상승(상한 클램프) + 턴 1회 플래그 + 수행 장수 행동 소진.
-- 부작용: region[item] 증가(maxStat 클램프), region[costField] 차감(민충성=군량/그 외=금),
--         region.devDone[item]=true, performer.actionDone=true(있으면). canInvest 통과 가정.
--   ── 왜 둘 다 막나: devDone 은 "지역당 항목 1회", actionDone 은 "같은 장수 같은 턴 중복 수행 제한"(GDD 10장).
-- @param region table       런타임 지역(변경됨)
-- @param item string        투자 항목 키
-- @param amount number      투자량
-- @param performer table|nil 수행 장수(정치 반영 + 행동 소진)
-- @return number 실제 오른 수치(클램프 반영)
function Develop.applyInvest(region, item, amount, performer)
  local costField = Develop.investCostField(item)
  local before = region[item]
  local gain = Develop.developGain(amount, performer)
  -- math.min 으로 상한(maxStat) 클램프 — 내정 수치는 0~100 범위(GDD 5장).
  region[item] = math.min(config.develop.maxStat, before + gain)
  region[costField] = region[costField] - amount -- 민충성=군량, 그 외=금 차감(GDD 10장)
  region.devDone[item] = true
  if performer then GameState.markActed(performer) end
  return region[item] - before -- 클램프 후 실제 상승분
end

-- ── 인재 탐색 (GDD 10장) ─────────────────────────────────

--- 인재 탐색 성공 확률 (GDD 10장). 정치 높을수록 ↑.
-- 공식: clamp(base + 수행정치 * polBonus, 0, maxRate).
--   왜 정치인가: 행정·안목이 높은 장수가 숨은 인재를 잘 찾아낸다는 규칙.
-- @param performer table|nil 수행 장수(정치 pol)
-- @return number 0~maxRate 확률
function Develop.searchSuccessChance(performer)
  local c = config.search
  local pol = performer and performer.pol or 0
  return math.max(0, math.min(c.maxRate, c.base + pol * c.polBonus))
end

--- 그 지역의 "아직 발견되지 않은" 재야(free) 장수 목록 — 탐색으로 드러낼 후보.
-- @param officers table   런타임 장수
-- @param regionId string
-- @return table  free + not discovered 장수 배열
function Develop.undiscoveredFree(officers, regionId)
  local out = {}
  for _, o in ipairs(officers) do
    if o.region == regionId and o.state == GameState.STATE.free and not o.discovered then
      out[#out + 1] = o
    end
  end
  return out
end

--- 인재 탐색이 가능한지(버튼 활성/실행 전 판정). 순수 함수.
-- 조건: 수행 장수 있음 + 그 장수 행동 가능 + 그 지역 이번 턴 미탐색.
-- @param region table        런타임 지역(searchDone 보유)
-- @param performer table|nil 수행 장수
-- @return boolean ok, string|nil reason
function Develop.canSearch(region, performer)
  if not performer then return false, "수행 장수 필요" end
  if not GameState.canAct(performer) then return false, "행동 가능한 장수 아님" end
  if region.searchDone then return false, "이번 턴 이미 탐색함" end -- 지역당 턴 1회(GDD 10장)
  return true, nil
end

--- 인재 탐색을 시도한다 (GDD 10장). 지역당 턴 1회 + 수행 장수 행동 소진.
-- 흐름: searchDone=true, 수행 장수 행동 소진 → 성공 확률 판정.
--   성공: 그 지역 미발견 free 1명을 random 선택해 discovered=true 로 드러내고 반환.
--   실패(또는 발견할 free 없음): nil 반환(이번 턴 그 지역 탐색 종료).
-- 부작용: region.searchDone=true, performer.actionDone=true, (성공 시) 그 free.discovered=true.
--   canSearch 통과 가정. 랜덤은 주입 rng(없으면 math.random) → 시드 고정 테스트 가능.
-- @param officers table    런타임 장수
-- @param regionId string   탐색 지역
-- @param region table      런타임 지역(searchDone 변경)
-- @param performer table   수행 장수(정치 반영 + 행동 소진)
-- @param rng function|nil  [0,1) 실수 반환(테스트 주입)
-- @return table|nil  발견된 free 장수(성공) / nil(실패)
function Develop.attemptSearch(officers, regionId, region, performer, rng)
  region.searchDone = true
  GameState.markActed(performer)
  -- 성공 판정: 굴린 값이 성공 확률보다 작으면 성공.
  if rollFloat(rng) >= Develop.searchSuccessChance(performer) then
    return nil -- 실패 → 이번 턴 그 지역 탐색 종료
  end
  local pool = Develop.undiscoveredFree(officers, regionId)
  if #pool == 0 then return nil end -- 더 드러낼 재야가 없음(성공이어도 빈손)
  local found = pool[pickIndexFloat(rng, #pool)]
  found.discovered = true
  return found
end

-- ── 등용 (GDD 14장 톤 — 포로 로직과 분리) ────────────────
--   발견된 재야(free) 장수를 수행 장수가 등용 시도. 정치 높을수록 성공률 ↑.
--   포로(captured) 등용 로직과는 완전히 분리(이번 범위는 재야 등용만).

--- 등용 성공 확률 (GDD 14장 톤). 정치 높을수록 ↑.
-- 공식: clamp(base + 수행정치 * polBonus, 0, maxRate).
-- @param performer table|nil 수행 장수(정치 pol)
-- @return number 0~maxRate 확률
function Develop.recruitChance(performer)
  local c = config.recruit
  local pol = performer and performer.pol or 0
  return math.max(0, math.min(c.maxRate, c.base + pol * c.polBonus))
end

--- 등용이 가능한지(버튼 활성/실행 전 판정). 순수 함수.
-- 조건: 대상이 발견된 재야 / 수행 장수 있음 + 행동 가능.
-- @param target table|nil    등용 대상(발견된 free)
-- @param performer table|nil 수행 장수
-- @return boolean ok, string|nil reason
function Develop.canRecruit(target, performer)
  if not target or target.state ~= GameState.STATE.free then return false, "재야 장수 아님" end
  if not target.discovered then return false, "발견되지 않은 장수" end
  if not performer then return false, "수행 장수 필요" end
  if not GameState.canAct(performer) then return false, "행동 가능한 장수 아님" end
  return true, nil
end

--- 등용을 시도한다 (GDD 14장 톤). 수행 장수 행동 소진(성공/실패 무관 1회).
-- 부작용: performer.actionDone=true. 성공 시 target 을 플레이어 세력 active 로 편입
--         (state/faction/loyalty 설정, discovered 해제). canRecruit 통과 가정.
--   ── 왜 행동 소진: 매 클릭 재시도(스팸)를 막아 1턴 1시도로 제한.
--   ── 정합성(GDD 6장): 탐색은 "소유 지역에서"만 하므로 그 지역은 이미 플레이어 소유 →
--      active 1명 추가는 정합성을 자동으로 만족(별도 소유 갱신 불필요).
-- @param target table         등용 대상(변경됨)
-- @param performer table      수행 장수(행동 소진)
-- @param playerFactionId any  플레이어 세력 id(편입 소속)
-- @param rng function|nil     [0,1) 실수 반환(테스트 주입)
-- @return boolean 성공 여부
function Develop.attemptRecruit(target, performer, playerFactionId, rng)
  GameState.markActed(performer)
  if rollFloat(rng) >= Develop.recruitChance(performer) then
    return false -- 등용 실패(대상은 발견 상태 유지 → 다음 턴 재시도 가능)
  end
  target.state = GameState.STATE.active
  target.faction = playerFactionId
  target.loyalty = config.recruit.initLoyalty
  target.discovered = nil -- 더 이상 재야 발견 대상 아님
  return true
end

return Develop
