--============================================================
-- victory.lua
--
-- 게임 종료 조건 판정 — 승리/패배 결정 논리 (GDD 18장).
-- love.* 비의존 순수 Lua → project/tests/ 에서 단위 테스트 가능.
--
-- 관계:
--   main.lua  : turnContext().onGameEnd 콜백에서 Victory.checkGameEnd 호출.
--               advanceTurn 훅(onGameEnd)이 발동하는 시점에 결과 판정.
--   game_state.lua : 직접 의존 없음.
--               advanceTurn 이 ctx.onGameEnd 훅만 발동 → main.lua 가 배선.
--   test_pure.lua  : Victory.checkGameEnd 를 직접 require 하여 단위 테스트.
--
-- 왜 분리했는가:
--   game_state.lua 의 800줄 경계 회피 + 단일 책임 원칙.
--   승패 논리는 game_state 의 내정·이동·전투 규칙과 독립적 판단 가능.
--============================================================

-- local Victory
-- C#의 static class 에 해당 — 인스턴스 없이 함수만 담는 테이블.
-- C++ 의 namespace 와 유사하게 쓰인다.
local Victory = {}

--- 게임 종료 조건을 검사해 결과를 반환한다 (GDD 18장).
---
--- 호출 위치:
---   main.lua turnContext().onGameEnd 콜백(advanceTurn 내부에서 발동).
---
--- 승리 조건 (GDD 18장):
---   플레이어 소유 지역 수 == 전체 지역 수(30개) → 천하 통일.
---
--- 패배 조건 1 (GDD 18장):
---   플레이어 소유 지역 0개 → 거점 없음 = 멸망.
---
--- 패배 조건 2 (GDD 18장):
---   플레이어 군주(isLord=true)의 state == "dead" → 후계 없음.
---
--- 한 턴 지연 (의도된 트레이드오프):
---   플레이어가 전투에서 마지막 적을 제거해도 결과 화면은 즉시 표시되지 않는다.
---   다음 advanceTurn 종료 시(onGameEnd 훅 발동) 판정된다.
---   이유: 검사 지점을 advanceTurn 단 한 곳으로 일원화해 버그 표면적을 줄인다.
---   exitBattle·이동 등 소유권 변동 지점에 분산하면 검사 누락 버그 위험이 높아진다.
---
--- C# 비교: GameManager.CheckWinLoseCondition() 메서드에 해당.
---   Lua 는 static 키워드 없이 모듈 테이블 함수로 노출한다(Victory.checkGameEnd).
---
--- @param ownership  table  런타임 소유 맵 { [regionId] = factionId }
--- @param playerFid  any    플레이어 세력 id
--- @param officers   table  런타임 장수 목록 전체(ipairs 순회)
--- @param regions    table  game_data.regions 배열 (전체 지역, 보통 30개)
--- @return string|nil  "victory" | "defeat" | nil (게임 진행 중)
function Victory.checkGameEnd(ownership, playerFid, officers, regions)
  -- ① 플레이어 소유 지역 수 계산.
  --   pairs(): C# Dictionary<K,V>.GetEnumerator() / C++ range-for(unordered_map) 에 해당.
  --   순서 보장 없지만 소유 수 집계에는 문제없다.
  local owned = 0
  for _, fid in pairs(ownership) do
    if fid == playerFid then owned = owned + 1 end
  end

  -- ② 패배 조건 1: 소유 지역 0개 → 거점 없음 = 멸망 (GDD 18장).
  if owned == 0 then return "defeat" end

  -- ③ 패배 조건 2: 플레이어 군주(isLord=true)가 dead → 후계 없음(GDD 18장).
  --   ipairs(): C# foreach(List) / C++ range-for(vector) — 인덱스 순서 보장 순회.
  --   "dead" 는 GameState.STATE.dead 의 문자열 값(game_state.lua:38).
  for _, o in ipairs(officers) do
    if o.isLord and o.faction == playerFid and o.state == "dead" then
      return "defeat"
    end
  end

  -- ④ 승리 조건: 소유 지역 수 >= 전체 지역 수(30개) → 천하 통일(GDD 18장).
  --   #regions: C# List.Count / C++ std::vector::size() 에 해당.
  --   >= 로 비교해 혹시 소유 수가 초과해도 안전하게 처리.
  if owned >= #regions then return "victory" end

  return nil -- 게임 진행 중 — C# 의 null 반환에 해당
end

return Victory
