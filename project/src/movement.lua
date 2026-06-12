--[[
movement.lua — 이동/수송 규칙 (순수 Lua, love 비의존) — GDD 12장

  이 모듈의 책임:
    - 부대 명령(이동/수송)의 "규칙"을 순수 Lua 로 제공한다.
      · 명령 생성(issueOrder): 장수를 이동 중으로, 행동 소진, 출발지에서 분리, 출발지 정합성 훅.
      · 도착 처리(processArrival/processArrivals): 병력 합류·무혈 입성·군량 이전·위치 갱신.
      · 명령 가능 판정(canMove/canTransport): UI 버튼 활성·확정 전 검사.
    - love.* 가 전혀 없어 project/tests/ 에서 단위 테스트할 수 있다(CLAUDE.md 결정 3).
  관계:
    - game_state.lua : 장수 상태(STATE)·조회(byId)·가중평균(mergeTraining)·정합성(demoteIfVacant) 재사용.
    - region.lua     : 인접 판정은 main 이 Region.areAdjacent 로 만들어 isAdjacent 함수로 "주입"한다
                       (movement 는 좌표/지도를 모름 — love·hex 비의존 유지).
    - main.lua       : 진행 중 명령 목록(state.orders)을 들고, 이 모듈 함수를 호출한다(표현·입력).
    - order_popup.lua: 부대 명령 팝업 UI — 장수·종류·군량 고른 뒤 이 모듈로 명령을 만든다.

  핵심 모델 결정(왜 이렇게):
    - 병력·훈련도는 "장수 단위"다(game_state 주석 참조). 그래서 부대 = 장수 1명 + 그 장수의 병력.
      이동은 곧 "장수를 옮기는 것"이고, 병력은 장수와 함께 따라간다.
    - 이동 중 장수는 출발지에서 분리한다(region = nil). 그래야 출발지 active 카운트에서 빠지고
      "출발지 장수 0명 → 중립 강등(정합성 훅)" 이 자연히 작동한다. 도착 시 region 을 목적지로 갱신.
    - "남은 병력 0 해산"(GDD 12장): 병력은 장수에 붙어 있으므로, 장수가 모두 떠나면 그 지역 병력은
      자동으로 0 이 된다(따로 버릴 병력이 없다). 그래서 별도 해산 처리 코드가 필요 없다.
    - 도착 병력 합류(GDD 12장): 도착지에 친군(같은 세력) 수비 지휘관이 있으면 그쪽으로 병력을
      합산하고 훈련도는 가중평균(징병과 같은 공식, mergeTraining 재사용)한다 → 지역 병력은 한 부대로.
      친군이 없는 중립 지역이면 합류 대상이 없으므로 도착 장수가 병력을 쥔 채 무혈 입성(소유권 이전).

  다른 언어 비교:
    - issueOrder/processArrival 은 C# 의 "명령 객체(Command 패턴)" 생성·실행과 비슷하다.
    - isAdjacent 처럼 함수를 인자로 받는 것 = C# delegate / C++ std::function 주입(의존성 역전).
--]]

local GameState = require("game_state")

local Movement = {}

-- ── 명령 종류 enum (GDD 12장) ────────────────────────────
--   Lua 엔 enum 키워드가 없어 "문자열 상수 테이블"로 흉내(값 == 키). game_state.STATE 와 같은 방식.
Movement.ORDER = {
  move      = "move",      -- 이동(부대를 다른 지역으로). 중립 인접지면 점령(무혈 입성).
  transport = "transport", -- 수송(장수가 군량을 들고 소유 지역으로).
}

-- ── 명령 가능 판정 (UI 게이팅 + 확정 전 검사) ────────────

--- 이동 명령이 가능한지 검사한다 (GDD 12장). 순수 함수.
-- 규칙:
--   · 출발지는 플레이어 소유. 같은 지역으로는 불가.
--   · 목적지가 플레이어 소유 → 거리 무제한 허용(경유 없이 직접 지정). (GDD 12장 "거리 무제한")
--   · 목적지가 중립 → 인접해야 이동/점령 가능(무혈 입성 대상).
--   · 목적지가 타 세력 소유(적 지역) → 전투(GDD 13장, 미구현) → 이번 범위에선 차단.
-- @param ownership table   런타임 소유 맵 { [regionId]=factionId } (중립이면 키 없음)
-- @param fromId string     출발지 지역 id
-- @param toId string       목적지 지역 id
-- @param playerFid any     플레이어 세력 id
-- @param isAdjacent fun(a,b):boolean  인접 판정 함수(main 이 Region.areAdjacent 로 주입)
-- @return boolean ok, string|nil reason  불가 시 사유
function Movement.canMove(ownership, fromId, toId, playerFid, isAdjacent)
  if not toId or fromId == toId then return false, "같은 지역" end
  if ownership[fromId] ~= playerFid then return false, "출발지가 내 소유 아님" end
  local destOwner = ownership[toId]
  if destOwner == playerFid then
    return true -- 내 소유끼리 → 거리 무제한
  end
  if destOwner == nil then
    -- 중립: 인접해야 진입(점령) 가능.
    if isAdjacent and isAdjacent(fromId, toId) then return true end
    return false, "중립은 인접 지역만 이동/점령 가능"
  end
  -- 타 세력 소유 = 적 지역 → 전투 미구현이라 막아둔다(GDD 13장 다음 작업).
  return false, "적 지역 — 전투 미구현"
end

--- 수송 명령이 가능한지 검사한다 (GDD 12장). 순수 함수.
-- 규칙: 출발지·도착지 모두 플레이어 소유, 같은 지역 불가, 군량 1 이상, 출발지 군량 충분.
-- @param ownership table
-- @param fromId,toId string
-- @param playerFid any
-- @param grainAmount number   보낼 군량
-- @param regionState table    런타임 지역상태 맵(출발지 군량 확인)
-- @return boolean ok, string|nil reason
function Movement.canTransport(ownership, fromId, toId, playerFid, grainAmount, regionState)
  if not toId or fromId == toId then return false, "같은 지역" end
  if ownership[fromId] ~= playerFid then return false, "출발지가 내 소유 아님" end
  if ownership[toId] ~= playerFid then return false, "수송 도착지는 내 소유 지역만" end
  if not grainAmount or grainAmount <= 0 then return false, "군량 0" end
  local src = regionState and regionState[fromId]
  if not src or src.grain < grainAmount then return false, "군량 부족" end
  return true
end

-- ── 명령 생성 ────────────────────────────────────────────

--- 부대 명령을 만들어 명령 목록에 추가한다 (GDD 12장). 상태 변경 함수.
-- 흐름:
--   1) 명령 레코드 생성(출발/목적/장수/병력·훈련도 스냅샷/종류/도착 턴).
--   2) 장수를 이동 중 + 이번 턴 행동 소진(같은 턴 중복 명령 방지). 출발지에서 분리(region=nil).
--   3) 수송이면 출발지 군량을 즉시 차감(도착 시 목적지에 가산).
--   4) 출발지 정합성: active 0명이면 중립 강등 + 태수 해제(demoteIfVacant 재사용 — GDD 6장).
-- @param orders table        진행 중 명령 목록(직접 추가됨)
-- @param kind string         Movement.ORDER.move | .transport
-- @param officer table       명령을 받는 장수(상태 변경됨, canAct 통과 가정)
-- @param fromId string       출발지 지역 id
-- @param toId string         목적지 지역 id
-- @param arriveTurn number   도착 예정 누적 턴(보통 현재 turn.count + 1 = 다음 턴)
-- @param ctx table           { regionState, ownership, governors, officers, grain }
--   grain : 수송 군량(이동이면 무시). 정합성 훅엔 ownership/governors/officers 필요.
-- @return table  생성된 명령 레코드
function Movement.issueOrder(orders, kind, officer, fromId, toId, arriveTurn, ctx)
  ctx = ctx or {}
  local order = {
    kind = kind,
    officerId = officer.id,
    from = fromId,
    to = toId,
    arriveTurn = arriveTurn,
    -- 병력·훈련도 스냅샷(표시/로그용 — 실제 병력은 장수에 붙어 함께 이동).
    troops = officer.troops,
    training = officer.training,
  }

  -- 장수 상태: 이동 중 + 행동 소진. 출발지에서 분리(이동 중엔 어느 지역에도 없음).
  officer.moving = true
  officer.actionDone = true
  officer.region = nil

  if kind == Movement.ORDER.transport then
    order.grain = ctx.grain or 0
    -- 출발지 군량 즉시 차감(군량이 두 곳에 동시에 존재하지 않게). 음수 방지로 max.
    local src = ctx.regionState and ctx.regionState[fromId]
    if src then src.grain = math.max(0, src.grain - order.grain) end
  end

  orders[#orders + 1] = order

  -- 출발지 정합성(GDD 6장): 떠난 직후 그 지역 active 가 0명이면 중립 강등 + 태수 해제.
  --   officer.region 을 이미 nil 로 바꿨으므로 regionActiveCount(from) 에서 이 장수는 빠진다.
  if ctx.ownership and ctx.officers then
    GameState.demoteIfVacant(ctx.ownership, ctx.governors, ctx.officers, fromId)
  end

  return order
end

-- ── 도착 처리 ────────────────────────────────────────────

--- 도착지의 "친군(같은 세력) active 수비 지휘관"을 찾는다(병력 합류 대상). 내부 헬퍼.
-- 태수(governor)를 우선하고, 없으면 그 지역 첫 친군 active 장수. 이동해 온 장수(mover)는 제외.
-- @return table|nil
local function mergeTarget(officers, governors, toId, mover)
  local govId = governors and governors[toId]
  if govId and govId ~= mover.id then
    local g = GameState.byId(officers, govId)
    if g and g.state == GameState.STATE.active and g.faction == mover.faction and g.region == toId then
      return g
    end
  end
  for _, o in ipairs(officers) do
    if o.id ~= mover.id and o.region == toId
       and o.state == GameState.STATE.active and o.faction == mover.faction then
      return o
    end
  end
  return nil
end

--- 명령 하나의 도착을 처리한다 (GDD 12장). 상태 변경 함수.
-- 처리:
--   1) 이동해 온 장수의 위치를 목적지로, 이동 중 해제.
--   2) 병력 합류: 도착지에 친군 수비 지휘관(target)이 있으면 그쪽에 병력 합산 + 훈련도 가중평균
--      (mergeTraining 재사용). 합류 후 mover 병력은 0(지역 병력은 한 부대로 통합).
--   3) 친군이 없으면(중립 도착) → 무혈 입성: 소유권을 mover 세력으로 이전(mover 가 병력 보유).
--   4) 수송이면 목적지 군량에 가산(출발지 차감은 명령 생성 시 끝남).
-- @param order table        도착 처리할 명령
-- @param officers table     런타임 장수 전체
-- @param regionState table  런타임 지역상태(수송 군량 가산용)
-- @param ownership table    런타임 소유 맵(무혈 입성 시 변경)
-- @param governors table    태수 맵(합류 대상 태수 우선 조회)
function Movement.processArrival(order, officers, regionState, ownership, governors)
  local mover = GameState.byId(officers, order.officerId)
  if not mover then return end -- 명령 후 장수가 사라진 방어(포로/사망 등)

  mover.region = order.to
  mover.moving = false

  local target = mergeTarget(officers, governors, order.to, mover)
  if target then
    -- 병력 합류(GDD 12장): 기존 병력과 합산, 훈련도 가중평균(징병과 동일 공식 재사용).
    target.training = GameState.mergeTraining(target.troops, target.training, mover.troops, mover.training)
    target.troops = target.troops + mover.troops
    -- 통합 후 이동해 온 장수는 병력 0(부대는 수비 지휘관에게 합쳐졌다).
    mover.troops = 0
    mover.training = 0
  elseif ownership and not ownership[order.to] then
    -- 합류할 친군이 없고 목적지가 중립 → 무혈 입성(소유권 이전). mover 가 병력을 쥔 채 점령.
    ownership[order.to] = mover.faction
  end

  -- 수송 도착: 목적지 군량에 가산(GDD 12장).
  if order.kind == Movement.ORDER.transport and regionState and regionState[order.to] then
    regionState[order.to].grain = regionState[order.to].grain + (order.grain or 0)
  end
end

--- 이번에 도착할 명령을 모두 처리하고 목록에서 제거한다 (GDD 3장 2번 도착 단계).
-- advanceTurn 의 onArrivals 훅에서 호출. arrivingCount = "이제 진입하는 턴"의 누적 턴 수.
--   (onArrivals 는 날짜 진행 전에 불리므로 main 이 turn.count + 1 을 넘긴다 — 다음 턴 도착 의미.)
-- 뒤에서 앞으로 순회(table.remove 로 인덱스가 당겨져도 안전). C# 의 for(i=n;i>=0;i--) 와 동일 이유.
-- @param orders table         진행 중 명령 목록(도착분 제거됨)
-- @param arrivingCount number  이제 진입하는 턴의 누적 턴 수
-- @param officers table
-- @param regionState table
-- @param ownership table
-- @param governors table
function Movement.processArrivals(orders, arrivingCount, officers, regionState, ownership, governors)
  for i = #orders, 1, -1 do
    if orders[i].arriveTurn <= arrivingCount then
      Movement.processArrival(orders[i], officers, regionState, ownership, governors)
      table.remove(orders, i) -- table.remove(t,i): i번째 제거(이후 요소 앞으로 당김). C# List.RemoveAt.
    end
  end
end

return Movement
