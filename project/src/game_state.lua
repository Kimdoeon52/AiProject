--[[
game_state.lua — 규칙 계층: 장수 시스템 규칙 + 런타임 상태 구성 (love 비의존)

  이 모듈의 책임:
    - 장수 관련 "규칙"을 순수 Lua 로 제공한다. love.* 를 부르지 않으므로
      project/tests/ 에서 단위 테스트할 수 있다(CLAUDE.md 아키텍처 결정 3).
    - 시나리오 데이터(정적 베이스 + 배치)를 합쳐 "런타임 장수 레코드"를 만든다.
  관계:
    - game_data.lua : 장수 베이스(officers) + 시나리오 배치(scenario.officers) 데이터 소유.
    - config.lua    : 병력 한도 계수 등 수치 상수(매직넘버 금지).
    - main.lua      : 이 모듈로 런타임 장수를 만들고, 조회/행동 함수를 호출(표현·입력).

  계층 원칙(CLAUDE.md): 데이터는 game_data, 규칙은 여기, 표현·입력은 main.
    이 파일엔 love.* / 좌표 / 렌더가 전혀 없어야 한다.

  용어:
    - 베이스 장수(base)   : id·이름·능력치·등장연도 등 시나리오 무관 정적 값.
    - 런타임 장수(officer): 베이스 + 배치(소속/위치/충성/상태) + 진행 중 값
                            (보유 병력·이동중·행동완료). 게임 진행 중 변한다.
--]]

-- require()
--   C# 의 using 과 달리, 모듈 파일을 1회 실행하고 그 반환 테이블을 가져온다.
--   config 는 순수 상수 테이블이라 love 비의존 — 테스트에서도 안전.
local config = require("config")

local GameState = {}

-- ── 장수 상태 enum (GDD 7장) ─────────────────────────────
--   Lua 엔 enum 키워드가 없다. C# 의 enum / C++ 의 enum class 대신
--   "문자열 상수를 담은 테이블"로 흉내 낸다. (값 == 키 문자열)
--   이렇게 두면 비교는 GameState.STATE.active 처럼 오타에 안전하게 쓸 수 있다.
GameState.STATE = {
  active     = "active",     -- 세력에 소속된 장수
  free       = "free",       -- 재야 장수(인재 탐색으로 발견·등용)
  unrevealed = "unrevealed", -- 아직 등장하지 않음(시대 이전 인물)
  captured   = "captured",   -- 포로
  dead       = "dead",       -- 사망
}

-- ── 병력 한도 (GDD 7장) ──────────────────────────────────

--- 장수의 병력 수용 한도를 계산한다 (GDD 7장).
-- 공식: 한도 = 무력 * troopsPerMight.
--   "왜 무력 기반인가" — 무력이 높은 장수일수록 더 큰 부대를 통솔한다는 규칙.
--   계수(=5)는 매직넘버 금지 원칙에 따라 config.officer.troopsPerMight 한 곳에 둔다.
-- @param officer table  무력(might)을 가진 장수(베이스 또는 런타임 모두 가능)
-- @return number 이 장수가 가질 수 있는 최대 병력 수
function GameState.troopsCap(officer)
  return officer.might * config.officer.troopsPerMight
end

-- ── 등장 판정 (GDD 7장: unrevealed) ──────────────────────

--- 베이스 장수가 해당 연도에 "아직 미등장(unrevealed)" 인지.
-- 등장연도(appear)가 시나리오 연도보다 늦으면 그 시대엔 등장하지 않은 인물이다.
--   예: 제갈량(appear 207)은 184/194 시나리오에선 unrevealed → 배치되지 않는다.
-- @param base table   베이스 장수(appear 필드 보유)
-- @param year number  시나리오 연도
-- @return boolean true 면 미등장
function GameState.isUnrevealed(base, year)
  return base.appear > year
end

-- ── 런타임 장수 구성 ─────────────────────────────────────

--- 베이스 장수 배열을 id 로 빠르게 찾도록 인덱싱한다(내부 헬퍼).
-- C# 의 Dictionary<string, Officer> / C++ 의 std::unordered_map 과 같은 용도.
-- @param baseList table  game_data.officers
-- @return table  { [id] = base }
local function indexById(baseList)
  local map = {}
  -- ipairs(): 배열(1..n)을 순서대로 순회. C# foreach / C++ range-for 와 유사.
  for _, base in ipairs(baseList) do
    map[base.id] = base
  end
  return map
end

--- 시나리오 배치를 베이스와 합쳐 "런타임 장수" 배열을 만든다 (GDD 4·7장).
-- 흐름:
--   game_data.officers(정적) + scenario.officers(배치) → 런타임 레코드 1명씩 생성.
--   scenario.officers 에 없는 인물은 그 시나리오에 등장하지 않음(미배치).
-- 부작용: 없음(새 테이블만 반환). game_data 원본을 변형하지 않는다.
-- @param gameData table  game_data 모듈(officers 보유)
-- @param scenario table  선택된 시나리오(factions, officers 배치 보유)
-- @return table  런타임 장수 배열
function GameState.buildOfficers(gameData, scenario)
  local baseById = indexById(gameData.officers)
  local out = {}

  for _, place in ipairs(scenario.officers) do
    local base = baseById[place.id]
    -- 배치 데이터가 실재 베이스를 가리키는지 방어(데이터 오타 시 건너뜀).
    if base then
      -- 소속 세력 정의(있다면). 재야(free)는 faction 이 없다.
      local faction = place.faction and scenario.factions[place.faction] or nil
      -- 군주(lord) 여부: 그 세력의 lord 가 이 장수면 충성도는 '-'(GDD 7장).
      local isLord = faction ~= nil and faction.lord == place.id

      out[#out + 1] = {
        -- 베이스에서 복사하는 정적 값
        id = base.id, name = base.name,
        might = base.might, intel = base.intel, pol = base.pol, hp = base.hp,
        appear = base.appear,
        -- 배치에서 오는 값
        faction = place.faction,   -- 소속 세력 id (재야면 nil)
        region = place.region,     -- 현재 위치 지역 id
        state = place.state,       -- GameState.STATE.* 중 하나
        isLord = isLord,           -- 군주면 true → 충성도 '-' 표기
        -- 충성도: 군주는 '-'(nil), 그 외엔 배치값(재야는 보통 nil).
        loyalty = isLord and nil or place.loyalty,
        -- 런타임 진행 값(초기치). 게임 중 변한다.
        troops = 0,          -- 현재 보유 병력
        equip = nil,         -- 장착 장비(GDD 8장). 미구현 → 항상 nil(스텁)
        moving = false,      -- 이동/수송 중 여부
        actionDone = false,  -- 이번 턴 주요 행동을 이미 했는지(행동 제한)
        -- 이번 턴 선물 수령 여부(턴 1회 제한, GDD 15장). 턴 시작 시 리셋.
        giftedGoldThisTurn = false,
        giftedEquipThisTurn = false,
      }
    end
  end

  return out
end

-- ── 조회 함수 (GDD 7·10장) ───────────────────────────────

--- id 로 런타임 장수를 찾는다.
-- @param officers table  런타임 장수 배열
-- @param id string
-- @return table|nil
function GameState.byId(officers, id)
  for _, o in ipairs(officers) do
    if o.id == id then return o end
  end
  return nil
end

--- 특정 지역에 있는 장수 목록.
-- 용도: 우측 패널의 "이 지역 장수" 표시, 내정/훈련 수행 장수 선택 등.
-- @param officers table
-- @param regionId string
-- @return table  해당 지역 장수 배열(0개 이상)
function GameState.officersInRegion(officers, regionId)
  local out = {}
  for _, o in ipairs(officers) do
    if o.region == regionId then out[#out + 1] = o end
  end
  return out
end

--- 특정 세력 소속(active) 장수 목록.
-- @param officers table
-- @param factionId string
-- @return table
function GameState.officersOfFaction(officers, factionId)
  local out = {}
  for _, o in ipairs(officers) do
    -- 소속이 같고 상태가 active 인 장수만(포로/사망 제외).
    if o.faction == factionId and o.state == GameState.STATE.active then
      out[#out + 1] = o
    end
  end
  return out
end

--- 재야(free) 장수 목록 — 인재 탐색 대상(GDD 10장).
-- @param officers table
-- @return table
function GameState.freeOfficers(officers)
  local out = {}
  for _, o in ipairs(officers) do
    if o.state == GameState.STATE.free then out[#out + 1] = o end
  end
  return out
end

-- ── 행동 완료 플래그 (GDD 7·10·11장) ─────────────────────
--   장수는 같은 턴에 주요 행동(이동·수송·훈련·내정 등)을 반복할 수 없다.
--   actionDone 으로 표시하고, 턴 시작 시 모두 리셋한다.

--- 모든 장수의 행동 완료 + 선물 수령 플래그를 리셋한다(턴 시작 시 호출).
-- 부작용: 각 officer.actionDone / giftedGoldThisTurn / giftedEquipThisTurn 을 false 로.
--   GDD 15장: 선물은 장수당 턴 1회 → 행동완료와 같은 지점(턴 시작)에서 함께 리셋.
-- @param officers table
function GameState.resetActions(officers)
  for _, o in ipairs(officers) do
    o.actionDone = false
    o.giftedGoldThisTurn = false
    o.giftedEquipThisTurn = false
  end
end

--- 이 장수가 이번 턴에 주요 행동을 할 수 있는지.
-- 조건: 소속(active) 장수이고 아직 행동하지 않았을 것.
--   재야/포로/사망/이동중 장수는 명령 수행 불가.
-- @param o table  런타임 장수
-- @return boolean
function GameState.canAct(o)
  return o.state == GameState.STATE.active
    and not o.actionDone
    and not o.moving
end

--- 장수의 이번 턴 행동을 소진 처리한다.
-- 부작용: officer.actionDone = true.
-- @param o table
function GameState.markActed(o)
  o.actionDone = true
end

--- 충성도 표시 문자열. 군주는 충성도 대신 '-' (GDD 7장).
-- 표현 계층(main)이 패널에 그릴 때 사용. 규칙엔 영향 없음(표시용).
-- @param o table
-- @return string|number  군주면 "-", 그 외엔 충성도 숫자(없으면 "-")
function GameState.loyaltyText(o)
  if o.isLord or o.loyalty == nil then return "-" end
  return o.loyalty
end

-- ── 선물 시스템 (GDD 15장) ───────────────────────────────
--   선물은 충성도를 올리는 수단. 장수당 턴 1회.
--   금 선물: 0~10금, 1금 = 충성 +5 (수치는 config.gift 상수).
--   금은 플레이어 군주(세력)의 금 보유고에서 차감한다.

--- 이 장수가 플레이어 세력의 "선물 가능" 대상인지.
-- 조건: 플레이어 세력 소속 + active + 군주(수장)가 아님.
--   수장은 충성도가 '-' 라 선물(충성 상승)이 의미 없으므로 제외.
-- @param o table             런타임 장수
-- @param playerFactionId any 플레이어 세력 id
-- @return boolean
function GameState.isGiftTarget(o, playerFactionId)
  return o.faction == playerFactionId
    and o.state == GameState.STATE.active
    and not o.isLord
end

--- 금 선물이 가능한지 검사한다(버튼 활성/실행 전 판정). 순수 함수.
-- @param gold number    플레이어 군주 보유 금
-- @param officer table  대상 장수
-- @param amount number  선물 금액
-- @return boolean ok, string|nil reason  불가 시 사유 문자열
function GameState.canGiftGold(gold, officer, amount)
  if officer.isLord then return false, "수장은 선물 대상 아님" end
  if officer.giftedGoldThisTurn then return false, "이번 턴 이미 금 선물함" end
  -- 금액 범위: 1~goldGiftMax (0금은 선물 의미 없음).
  if amount < 1 or amount > config.gift.goldGiftMax then return false, "금액 범위(1~" .. config.gift.goldGiftMax .. ")" end
  if gold < amount then return false, "금 부족" end
  return true, nil
end

--- 금 선물을 적용한다. (충성 상승 + 군주 금 차감 + 턴 플래그)
-- 충성 = 기존 + amount * loyaltyPerGold, 단 상한(config.officer.maxLoyalty)으로 클램프.
--   왜 클램프: 충성도는 범위(~100) 안 값이라 상한을 넘기지 않게(GDD 7장).
-- 부작용: officer.loyalty / officer.giftedGoldThisTurn 변경. (금은 숫자라 반환으로 돌려줌)
--   ── Lua 인자 전달: 테이블(officer)은 참조라 함수 안 변경이 밖에 반영(C# 참조형/C++ 참조와 유사),
--      숫자(gold)는 값 복사라 변경이 안 보임 → 새 금액을 return 으로 돌려준다.
-- @param gold number    선물 전 군주 금
-- @param officer table  대상 장수(변경됨)
-- @param amount number  선물 금액(canGiftGold 로 사전 검증되었다고 가정)
-- @return number  선물 후 군주 금
function GameState.applyGiftGold(gold, officer, amount)
  local gain = amount * config.gift.loyaltyPerGold
  local cur = officer.loyalty or 0
  -- math.min(a,b): 둘 중 작은 값. 상한 클램프에 사용.
  officer.loyalty = math.min(config.officer.maxLoyalty, cur + gain)
  officer.giftedGoldThisTurn = true
  return gold - amount
end

-- 장비 선물(GDD 8·15장)은 이번 범위 밖(스텁). 장비 데이터가 생기면 구현.
--   UI 는 이 플래그를 보고 장비 선물 버튼을 비활성으로 둔다.
GameState.EQUIP_IMPLEMENTED = false

-- ── 턴/달력 (GDD 3·9장) ──────────────────────────────────
--   1턴 = 1개월. 12월 다음은 다음 해 1월.
--   턴 상태(turn)는 { year, month, count } 테이블로 들고 다닌다(런타임 값).
--     · year  : 현재 연도
--     · month : 현재 월(1~12)
--     · count : 시작부터 누적 턴 수(1부터). 통계/디버그용.

--- 시나리오의 시작 연/월로 턴 상태를 만든다.
-- 호출 시점: 시나리오를 골라 지도로 진입할 때(main.startScenario).
-- @param scenario table  시작 연도(year)·시작 월(startMonth) 보유
-- @return table  { year, month, count }
function GameState.newTurn(scenario)
  return {
    year = scenario.year,
    -- startMonth 가 없으면 1월로(방어). GDD 4장: 시나리오 데이터가 시작 월을 가진다.
    month = scenario.startMonth or 1,
    count = 1,
  }
end

--- 한 턴(=1개월)을 진행한다 (GDD 3장 흐름).
-- 처리 순서(아직 없는 시스템은 ctx 훅이 없으면 그냥 건너뜀 = 빈 스텁):
--   1. 턴 종료 처리                 → ctx.onTurnEnd
--   2. 이동·수송 도착 처리          → ctx.onArrivals (GDD 12장, 미구현)
--   3. 세금·군량·인구 성장 처리     → ctx.onGrowth   (GDD 9장, 미구현)
--   4. AI 세력 행동 처리            → ctx.onAI       (GDD 16장, 미구현)
--   5. 날짜 진행: 월 +1, 12월 넘으면 연도 +1·월=1
--   (5-b) 수확월(7월) 진입 시 수확 훅 → ctx.onHarvest (GDD 9장, 미구현)
--   6. 장수 행동완료 플래그 리셋(어제 작업과 연결) → resetActions
--
-- "훅(hook)" 패턴: ctx 에 해당 콜백이 있으면 부르고, 없으면 아무 일도 안 한다.
--   덕분에 호출 순서·시그니처는 지금 확정하고(미완성 인터페이스 먼저 잡기, CLAUDE.md),
--   실제 계산은 시스템이 생길 때 콜백만 끼우면 된다.
--   콜백 시그니처는 모두 function(turn, ctx) 로 통일.
--   (Lua 의 함수는 1급 값 — C# 의 delegate/Action, C++ 의 std::function 과 비슷.)
--
-- 부작용: turn 테이블(year/month/count)을 직접 변경. ctx.officers 의 actionDone 리셋.
-- @param turn table  GameState.newTurn 으로 만든 턴 상태(직접 변경됨)
-- @param ctx  table|nil  { officers?, onTurnEnd?, onArrivals?, onGrowth?, onAI?, onHarvest? }
-- @return table  진행 후의 turn(편의상 반환)
function GameState.advanceTurn(turn, ctx)
  ctx = ctx or {}

  -- 1. 턴 종료 처리
  if ctx.onTurnEnd then ctx.onTurnEnd(turn, ctx) end
  -- 2. 이동·수송 도착 처리 (스텁)
  if ctx.onArrivals then ctx.onArrivals(turn, ctx) end
  -- 3. 세금·군량·인구 성장 처리 (스텁)
  if ctx.onGrowth then ctx.onGrowth(turn, ctx) end
  -- 4. AI 세력 행동 처리 (스텁)
  if ctx.onAI then ctx.onAI(turn, ctx) end

  -- 5. 날짜 진행 — 월 +1, 12월(=monthsPerYear) 넘으면 해 바뀜.
  turn.month = turn.month + 1
  if turn.month > config.turn.monthsPerYear then
    turn.month = 1
    turn.year = turn.year + 1
  end
  turn.count = turn.count + 1

  -- 5-b. 수확월(7월) "진입" 시 수확 훅. 날짜 진행 후의 새 달 기준으로 판정.
  if turn.month == config.turn.harvestMonth and ctx.onHarvest then
    ctx.onHarvest(turn, ctx)
  end

  -- 6. 장수 행동완료 리셋 — 새 턴이니 모든 장수가 다시 행동 가능.
  if ctx.officers then GameState.resetActions(ctx.officers) end

  return turn
end

return GameState
