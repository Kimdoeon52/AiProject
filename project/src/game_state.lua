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

-- ── 장비 시스템 (GDD 8장) ────────────────────────────────
--   장비(game_data.items)는 정적 베이스. 런타임 상태:
--     · officer.equip = 장착한 장비 레코드(없으면 nil). 1장수 1장착.
--     · 군주 보유 "미장착" 장비고 = 세력별 리스트(선물 대상).
--   장비 보너스 필드 키(force/intelligence/politics/hp)는 장수 능력치 키와 달라 매핑한다.
GameState.EQUIP_IMPLEMENTED = true

-- 장수 능력치 키 → 장비 보너스 필드 키 매핑(데이터가 서로 다른 이름을 써서 변환).
--   (Lua 테이블 상수 = C# 의 const Dictionary 같은 룩업표)
local STAT_TO_ITEM = { might = "force", intel = "intelligence", pol = "politics", hp = "hp" }

--- 장착 장비가 특정 능력치에 주는 보너스(없으면 0). 음수면 패널티.
-- @param officer table   런타임 장수(officer.equip 참조)
-- @param statKey string  "might"|"intel"|"pol"|"hp"
-- @return number
function GameState.statBonus(officer, statKey)
  local e = officer.equip
  if not e then return 0 end
  local itemKey = STAT_TO_ITEM[statKey]
  return e[itemKey] or 0
end

--- 유효 능력치 = 기본 + 장비 보너스 (표시·계산에 이 값을 쓴다, GDD 8장).
-- @param officer table
-- @param statKey string
-- @return number
function GameState.effectiveStat(officer, statKey)
  return (officer[statKey] or 0) + GameState.statBonus(officer, statKey)
end

--- 그 능력치에 "양(+)의 장비 보너스"가 붙었는지(연두색 표시 판별용). 표시 전용.
-- @return boolean
function GameState.hasStatBonus(officer, statKey)
  return GameState.statBonus(officer, statKey) > 0
end

--- 시나리오 초기 장비를 적용한다 (GDD 8장).
-- 흐름: scenario.equipment{ id, owner, equipped? } → items 베이스 조회 →
--   equipped 면 군주(owner)에게 장착(officer.equip), 아니면 그 세력 "미장착 장비고"에 적재.
-- 부작용: 해당 owner 장수의 equip 설정(장착분). 새 장비고 테이블 반환(원본 불변).
-- @param gameData table  items 보유
-- @param scenario table  equipment 배치 + factions
-- @param officers table  런타임 장수(buildOfficers 결과; owner 의 faction 확인용)
-- @return table  factionInventory = { [factionId] = { 장비레코드, ... } }  (미장착·선물용)
function GameState.applyInitialEquipment(gameData, scenario, officers)
  local itemById = {}
  for _, it in ipairs(gameData.items) do itemById[it.id] = it end
  local offById = {}
  for _, o in ipairs(officers) do offById[o.id] = o end

  local inventory = {}
  for _, place in ipairs(scenario.equipment or {}) do
    local base = itemById[place.id]
    local owner = offById[place.owner]
    if base and owner then
      -- 장비 인스턴스(베이스의 얕은 복사) — 같은 베이스로 여러 자루가 생겨도 서로 독립.
      local rec = { id = base.id, name = base.name,
                    hp = base.hp, force = base.force,
                    intelligence = base.intelligence, politics = base.politics }
      if place.equipped then
        owner.equip = rec
      else
        local fid = owner.faction
        inventory[fid] = inventory[fid] or {}
        table.insert(inventory[fid], rec)
      end
    end
  end
  return inventory
end

--- 장비 선물이 가능한지(버튼 활성/실행 전 판정). 순수 함수.
-- 조건: 수장 아님 / 이번 턴 장비 선물 안 함 / 빈 장착칸(1장수 1장착, GDD 8장).
-- @param officer table
-- @return boolean ok, string|nil reason
function GameState.canGiftEquip(officer)
  if officer.isLord then return false, "수장은 선물 대상 아님" end
  if officer.giftedEquipThisTurn then return false, "이번 턴 이미 장비 선물함" end
  if officer.equip then return false, "이미 장비 장착 중(1장수 1장착)" end
  return true, nil
end

--- 군주 장비고의 한 장비를 대상 장수에게 이전(장착)한다 (GDD 8·15장).
-- 보너스 이전 = 장비를 officer.equip 에 꽂으면 유효 능력치에 자동 반영(effectiveStat).
-- 부작용: inventory 에서 제거, officer.equip 설정, 충성 상승(클램프), 턴 플래그.
-- @param inventory table  군주 미장착 장비고(이 리스트에서 제거)
-- @param index number     선물할 장비의 인덱스
-- @param officer table    대상 장수(변경됨; canGiftEquip 통과 가정)
-- @return table  이전된 장비 레코드
function GameState.applyGiftEquip(inventory, index, officer)
  -- table.remove(t, i): i 번째 요소 제거하고 반환. C# List.RemoveAt + 반환.
  local rec = table.remove(inventory, index)
  officer.equip = rec
  local cur = officer.loyalty or 0
  officer.loyalty = math.min(config.officer.maxLoyalty, cur + config.gift.loyaltyPerEquip)
  officer.giftedEquipThisTurn = true
  return rec
end

-- 포로 동반/처형 귀속(GDD 8·14장)은 이번 범위 밖 → 훅만(미구현).
--   TODO: 포획 시 장비 동반, 처형 시 장비는 군주 장비고로 귀속.

-- ── 태수 (GDD 5·10·11장) ─────────────────────────────────
--   지역마다 담당 장수(태수) 1명. 내정·훈련 수행 장수의 기본 후보.
--   자동 선정: 수장 고정 → 없으면 최고 충성도 → 동률이면 랜덤(주입 rng 로 테스트 가능).

--- 랜덤 1..n 정수를 돌려준다(주입 rng 우선, 없으면 math.random).
--   love.* 비의존: rng 를 주입하면 시드 고정 테스트 가능(love.math.random 도 주입 가능).
local function pick(rng, n)
  if rng then return rng(n) end
  return math.random(n) -- math.random(n): 1..n 정수 (C 의 rand()%n+1 과 유사)
end

--- 한 지역의 태수를 자동 선정한다 (GDD 5장 태수 필드).
-- 규칙(왜 이렇게):
--   1) 후보 = 그 지역에 있는 active 장수. (포로/재야/이동중 제외)
--   2) 수장(군주)이 있으면 무조건 그 수장 — 세력의 주인이 곧 거점의 장(고정).
--   3) 수장이 없으면 충성도 최고 — 가장 믿을 장수에게 맡긴다.
--   4) 최고 충성 동률이 여럿이면 그 그룹에서 랜덤 1명.
--   5) 후보 0명이면 태수 없음(nil).
-- @param officers table   런타임 장수 전체
-- @param regionId string  대상 지역
-- @param rng function|nil 1..n 정수 반환(테스트 주입). 없으면 math.random.
-- @return string|nil  태수 장수 id (없으면 nil)
function GameState.assignGovernor(officers, regionId, rng)
  local bestLoyalty, ties = -1, {}
  for _, o in ipairs(officers) do
    if o.region == regionId and o.state == GameState.STATE.active then
      if o.isLord then
        return o.id -- 수장 발견 → 즉시 고정(2번 규칙)
      end
      local loy = o.loyalty or 0
      if loy > bestLoyalty then
        bestLoyalty = loy
        ties = { o.id }       -- 새 최고 → 동률 그룹 초기화
      elseif loy == bestLoyalty then
        ties[#ties + 1] = o.id -- 동률 누적
      end
    end
  end
  if #ties == 0 then return nil end       -- 후보 0명
  if #ties == 1 then return ties[1] end   -- 단독 최고
  return ties[pick(rng, #ties)]           -- 동률 랜덤(4번 규칙)
end

--- 모든 지역의 태수를 한 번에 자동 선정한다(시나리오 초기 1회).
-- @param regions table   지역 목록(각 .id)
-- @param officers table  런타임 장수
-- @param rng function|nil
-- @return table  { [regionId] = officerId|nil }  (governors 맵)
function GameState.assignGovernors(regions, officers, rng)
  local governors = {}
  for _, r in ipairs(regions) do
    governors[r.id] = GameState.assignGovernor(officers, r.id, rng)
  end
  return governors
end

--- 이 장수가 태수로 있는 지역 id 를 찾는다(상세 표시용 역조회).
-- @param governors table  { [regionId]=officerId }
-- @param officerId string
-- @return string|nil  지역 id
function GameState.governorRegionOf(governors, officerId)
  for regionId, oid in pairs(governors) do
    if oid == officerId then return regionId end
  end
  return nil
end

--- 수동 태수 지정이 가능한지(같은 지역 active 장수만).
-- @param officer table     대상 장수
-- @param regionId string   지정하려는 지역
-- @return boolean
function GameState.canSetGovernor(officer, regionId)
  return officer.region == regionId and officer.state == GameState.STATE.active
end

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
