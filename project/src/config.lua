--[[
config.lua — 창/색상/지도 상수 모음 (매직넘버 집중 출처)

  이 모듈의 책임:
    - 게임 전반에서 쓰는 수치/색상 상수를 한 곳에 모은다.
    - 표현 계층(main.lua)·진입 설정(conf.lua)이 이 값을 읽어 쓴다.
  관계:
    - conf.lua 가 window 값을 읽어 LÖVE 창을 만든다.
    - main.lua 가 colors/camera/map 값을 읽어 렌더·입력에 쓴다.

  주의: 디자인 수치의 원본은 GDD다. 여기 값은 GDD를 코드로 옮긴 것.
        (색상 규칙 = GDD 6장, 지도 = GDD 5장)
--]]

local config = {}

-- 창 설정 — Full HD. conf.lua 에서 사용.
config.window = {
  width = 1920,
  height = 1080,
  title = "삼국 패권",
}

-- 공용 색상 (GDD 6장). LÖVE setColor 규약대로 0~1 정규화 RGB.
--   세력별 고유색은 시나리오 데이터(game_data.scenarios[*].factions)에 둔다.
--   여기엔 세력 무관 공용 색만.
config.colors = {
  neutral = { 0.55, 0.55, 0.55 },          -- 미소유(중립) — 회색

  playerBorder = { 1.00, 1.00, 1.00 },     -- 플레이어 소유 흰 테두리 (GDD 6장)
  selectBorder = { 1.00, 0.85, 0.20 },     -- 선택 영토 강조 테두리 — 노랑
  territoryBorder = { 0.08, 0.09, 0.11 },  -- 영토 경계선(=인접) 색
  text = { 0.97, 0.97, 0.97 },             -- 지역 이름 글자색 / 능력치 기본 색
  textShadow = { 0.05, 0.05, 0.07 },       -- 이름 가독용 그림자
  background = { 0.12, 0.13, 0.16 },       -- 지도 배경(영토 밖)
  statBonus = { 0.55, 0.90, 0.45 },        -- 장비 보너스(+)가 붙은 능력치 색 — 연두 (GDD 8장)
  statPenalty = { 0.95, 0.45, 0.40 },      -- 장비 패널티(−)가 붙은 능력치 색 — 빨강
  panelValue = { 0.85, 0.90, 1.00 },       -- 지역 정보 패널의 수치 강조색 — 옅은 하늘 (GDD 17장)
  hostile = { 0.95, 0.45, 0.40 },          -- 적대치 수치 강조색 — 빨강 (GDD 6장 외교)
  devDone = { 0.62, 0.24, 0.24 },          -- 내정 수행 후 "빨간색 비활성" 버튼색 (GDD 10장)
}

-- 카메라 줌 배율/한계. main.lua wheelmoved·load 에서 사용.
--   줌아웃 바닥(minScale)은 화면 크기에 따라 동적 계산(전체 지도 fit) → 여기 고정 안 둠.
config.camera = {
  zoomStep = 1.1,      -- 휠 1눈금당 배율 (1.1배씩)
  maxZoomFactor = 4.0, -- 최대 확대 = fit 배율 × 이 값 (지도 fit 대비 몇 배까지 확대)
}

-- 입력 동작 상수.
config.input = {
  dragThreshold = 8, -- 누른 뒤 이동량(px)이 이 값 미만이면 클릭, 이상이면 드래그(팬)
}

-- 장수 시스템 상수 (GDD 7장). 규칙 계수의 단일 출처 — game_state.lua 가 읽어 쓴다.
--   매직넘버 금지(CLAUDE.md): 병력 한도 계수를 코드에 흩지 않고 여기 한 곳에 둔다.
config.officer = {
  -- 병력 한도 = 무력 * troopsPerMight  (GDD 7장: "장수 병력 한도 = 무력 * 5")
  --   무력이 높은 장수일수록 더 많은 병력을 지휘할 수 있다는 규칙.
  troopsPerMight = 5,

  -- 충성도 범위 상한 (GDD 7·15장: 선물로 충성 상승, 상한 필요).
  --   수장(군주)은 충성도 대신 '-' 로 표기하므로 이 범위와 무관.
  maxLoyalty = 100,
}

-- 경제 계수 (GDD 9장). 세금·수확 공식의 계수 단일 출처(매직넘버 금지).
--   GDD 9장은 "어떤 값에 영향받는지"만 정하고 구체 계수는 코드에 둔다(밸런싱 대상).
--   규칙 계층(game_state)의 calcTax/calcHarvest 가 읽어 쓴다.
config.economy = {
  -- 세금 = (상업*taxCommerce + 토지*taxLand) * (민충성/100) * (1 + 태수정치*taxPolBonus)
  --   상업이 토지보다 세수 기여 큼(taxCommerce>taxLand). 민충성 비율이 전체를 깎거나 키움.
  taxCommerce = 2.0,   -- 상업 1당 세금 기여
  taxLand     = 1.0,   -- 토지가치 1당 세금 기여
  taxPolBonus = 0.005, -- 태수 정치 1당 세금 배수 가산 (정치 80 → +40%)

  -- 수확 = (토지*harvestLand + 치수*harvestFlood) * (민충성/100) * (1 + 태수정치*harvestPolBonus)
  --   군량은 금보다 단위 수가 커 계수도 크게. 치수(관개)가 토지와 함께 수확을 키운다.
  harvestLand     = 5.0,
  harvestFlood    = 3.0,
  harvestPolBonus = 0.005,
}

-- 외교/적대치 상수 (GDD 6장 외교). 세력 쌍 적대 수준(0~100, 높을수록 적대).
--   시나리오 데이터는 "단계 문자열"만 두고, 단계→수치 변환은 여기 한 곳에서(데이터 분산 방지).
config.hostility = {
  -- 단계 → 수치. 동맹(0) < 우호(20) < 중립(50) < 적대(85).
  tier = { ally = 0, friendly = 20, neutral = 50, hostile = 85 },
  defaultTier = "neutral", -- 시나리오에 미기재된 세력 쌍의 기본 단계
  maxValue = 100,          -- 적대치 상한(추후 동적 상승 시 클램프용)
}

-- 선물 시스템 상수 (GDD 15장). 규칙 계층(game_state)이 읽어 쓴다.
--   매직넘버 금지(CLAUDE.md): 충성 환산·금 상한을 코드에 흩지 않고 여기 한 곳에.
config.gift = {
  goldGiftMax = 10,    -- 금 선물 1회 최대 금 (GDD 15장: "0~10금")
  loyaltyPerGold = 5,  -- 1금당 충성 상승량 (GDD 15장: "1금 = 충성 +5")
  -- 장비 선물 시 충성 상승량 (GDD 15장은 "충성 상승"만 명시, 수치 미정 → 임시 상수).
  loyaltyPerEquip = 10,
}

-- 내정 시스템 상수 (GDD 10·14장). 규칙 계층(game_state)이 읽어 쓴다.
--   매직넘버 금지(CLAUDE.md): 투자 효율·탐색/등용 확률 계수를 코드에 흩지 않고 여기 한 곳에.
--   GDD 10·14장은 "무엇에 영향받는지"만 정하고 구체 계수는 코드에 둔다(밸런싱 대상).

-- 투자(개발) 계수 (GDD 10장).
--   상승량 = floor(투자금 * perGold * (1 + 수행정치 * polBonus)), 상한 maxStat.
--   왜 이렇게: 투자금이 클수록·수행 장수 정치가 높을수록 내정 수치가 더 오른다.
config.develop = {
  perGold    = 0.05, -- 투자금 1당 기본 상승량 (100금 ≈ +5)
  polBonus   = 0.01, -- 수행 정치 1당 효율 배수 가산 (정치 100 → 2배)
  maxStat    = 100,  -- 내정 수치(치수/민충성/상업/토지) 상한 (0~100)
  sliderStep = 10,   -- 투자금 −/+ 미세조정 1클릭당 금액(슬라이더 보조)
}

-- 인재 탐색 확률 계수 (GDD 10장).
--   성공률 = clamp(base + 수행정치 * polBonus, 0, maxRate).
--   왜 이렇게: 정치(=행정/안목)가 높은 장수일수록 재야 인재를 잘 찾아낸다.
config.search = {
  base     = 0.20,  -- 기본 성공률(정치 0일 때)
  polBonus = 0.005, -- 정치 1당 성공률 가산 (정치 100 → +0.5 = +50%p)
  maxRate  = 0.95,  -- 성공률 상한(항상 100%는 막는다)
}

-- 등용 확률 계수 (GDD 14장 톤 — 충성/안목 기반, 포로 로직과 분리).
--   등용률 = clamp(base + 수행정치 * polBonus, 0, maxRate). 성공 시 초기 충성 initLoyalty.
config.recruit = {
  base        = 0.30,  -- 기본 등용 성공률
  polBonus    = 0.004, -- 정치 1당 등용률 가산 (정치 100 → +0.4)
  maxRate     = 0.95,  -- 등용률 상한
  initLoyalty = 70,    -- 등용 직후 충성도(GDD 7장 충성 범위 안)
}

-- 징병 상수 (GDD 11장). 규칙 계층(game_state)이 읽어 쓴다. 매직넘버 금지(CLAUDE.md).
--   ※ config.recruit(등용=장수 영입, GDD 14장)과 구분 — 이쪽은 병사 징집(conscription).
--   GDD 11장은 "금70 소모 / 인구·민충성 하락 / 한도 초과 불가"만 정하고,
--   구체 계수(병력량·감소율)는 코드에 둔다(밸런싱 대상 — config.economy 와 같은 선례).
config.conscript = {
  goldCost = 70,             -- 1회 징병 비용 금 (GDD 11장 명시값)
  troopsPerAction = 100,     -- 1회 징병 병력(고정 배치). 무력*5 한도까지만 클램프 (밸런싱)
  popDrainPerTroop = 0.02,   -- 병력 1당 인구 감소(추상 만단위). 100명 징병 → 인구 -2 (밸런싱)
  loyaltyDropPerAction = 3,  -- 1회 징병당 민충성 하락 (밸런싱)
}

-- 훈련 상수 (GDD 11장). 규칙 계층(game_state)이 읽어 쓴다.
config.training = {
  min = 0,             -- 훈련도 하한 (GDD 11장: "0~100")
  max = 100,           -- 훈련도 상한 (GDD 11장: 전투력에 반영)
  -- 무력 1당 훈련도 상승량. 무력100 → +10/회 → 10회로 100 도달 (GDD 11장: "무력 100급 ≈ 10회로 100").
  gainPerMight = 0.1,
}

-- 이동/수송 시스템 상수 (GDD 12장). 규칙 계층(movement)·표현 계층(main)이 읽어 쓴다.
--   매직넘버 금지(CLAUDE.md): 경로 화살표 색·점선 길이를 코드에 흩지 않고 여기 한 곳에.
--   GDD 12장: "이동 경로 점선 화살표 / 수송은 다른 색 점선 화살표".
config.orders = {
  moveColor      = { 0.35, 0.75, 1.00 }, -- 이동 경로 점선 색(하늘)
  transportColor = { 1.00, 0.75, 0.25 }, -- 수송 경로 점선 색(주황) — 이동과 시각 구분
  lineWidth = 3,   -- 경로 점선 두께(월드 px)
  dashLen   = 18,  -- 점선 한 칸 길이(월드 px)
  gapLen    = 12,  -- 점선 사이 빈칸 길이(월드 px)
  headLen   = 24,  -- 화살촉 길이(월드 px) — 진행 방향(목적지) 표시
  grainStep = 50,  -- 수송 군량 −/+ 1클릭당 증감량
}

-- 전투 시스템 상수 (GDD 13장). 규칙 계층(battle)·표현 계층(battle_view)이 읽어 쓴다.
--   매직넘버 금지(CLAUDE.md): 그리드 크기·이동력·사거리·스탯/데미지 계수를 여기 한 곳에.
--   GDD 13장은 "유닛 스탯 = 무력+병력+훈련도 기반"만 정하고 구체 계수는 미정 → 튜닝 상수로 둔다
--   (config.economy/conscript 와 같은 선례). 추후 GDD 13장에 수치 한 줄 추가 권장.
config.battle = {
  gridW = 7,           -- 전투 그리드 가로 칸 수
  gridH = 5,           -- 전투 그리드 세로 칸 수
  moveRange = 2,       -- 유닛 1 전투턴 이동 칸(맨해튼 거리)
  attackRange = 1,     -- 공격 사거리(맨해튼 거리). 1 = 인접 칸만 타격.

  -- HP(내구도) = 투입 병력 * hpPerTroop. "병력 많을수록 오래 버틴다"(GDD 13장 '투입 병력' 반영).
  hpPerTroop = 1,

  -- 공격력 = atkBase + 유효무력*atkPerMight + 훈련도*atkPerTraining (GDD 13장 무력·훈련도 반영).
  --   유효무력 = 기본 무력 + 장비 보너스(GDD 8장, effectiveStat).
  atkBase = 10, atkPerMight = 0.5, atkPerTraining = 0.3,
  -- 방어력 = defBase + 유효무력*defPerMight + 훈련도*defPerTraining.
  defBase = 5, defPerMight = 0.3, defPerTraining = 0.2,
  -- 데미지 = max(minDamage, floor(공격력 - 대상 방어력)). 방어가 더 높아도 최소 데미지는 들어간다.
  minDamage = 1,
  -- AI vs AI(또는 플레이어 미관여) 전투의 헤드리스 자동 해결 최대 라운드(무한 루프 방지).
  --   교착(서로 데미지 0 불가 — minDamage 보장)이라 보통 훨씬 전에 끝나지만 안전 상한.
  autoMaxRounds = 50,
}

-- 포로/등용/처형 상수 (GDD 14장). 규칙 계층(captive)이 읽어 쓴다. 매직넘버 금지(CLAUDE.md).
--   GDD 14장: "점령 시 50% 포획 / 등용은 충성도 낮을수록 높음".
config.captive = {
  captureChance = 0.5,          -- 점령 시 적 장수 포획 확률(GDD 14장 명시값)
  -- 등용 성공률 = clamp(base + (maxLoyalty - 충성) * perLowLoyalty, 0, maxRate).
  --   왜 충성 낮을수록 ↑: 옛 주군에 충성 낮은 포로일수록 쉽게 귀순(GDD 14장).
  recruitBase = 0.20,           -- 충성 최대(100)일 때 기본 등용률
  recruitPerLowLoyalty = 0.008, -- 충성이 1 낮을수록 가산(충성0 → +0.8)
  recruitMaxRate = 0.95,        -- 등용률 상한
  initLoyalty = 50,             -- 등용 직후 충성(갓 항복 → 낮게)
}

-- 전략 AI 상수 (GDD 16장). 규칙 계층(ai)이 읽어 쓴다. "정교화 금지"(스코프 락) — 단순 임계값.
config.ai = {
  minTroopsToAttack = 50,    -- 공격 후보가 되는 출발지 최소 병력(GDD 16 "병력 일정 이상")
  attackAdvantage = 1.3,     -- 공격 병력 ≥ 방어 병력 * 이 값일 때만 공격(GDD 16 "충분히 유리")
  playerWeight = 1.15,       -- 플레이어 지역 공격 추가 가중(우선 선택, GDD 16)
  lowTroops = 50,            -- 이 미만이면 징병 우선(GDD 16 3순위)
  lowTraining = 40,          -- 이 미만이면 훈련(GDD 16 4순위)
  lowStat = 40,              -- 내정 수치 이 미만이면 개발(GDD 16 5순위)
  investAmount = 100,        -- AI 1회 내정 투자 금액
}

-- 전투 화면 레이아웃/색 상수 (GDD 13·17장). 표현 계층(battle_view)만 읽는다.
config.battleView = {
  cell = 120,          -- 그리드 한 칸 한 변(px)
  gap = 4,             -- 칸 사이 간격(px)
  atkColor = { 0.40, 0.60, 0.95 }, -- 공격측 유닛 색(파랑)
  defColor = { 0.90, 0.45, 0.40 }, -- 방어측 유닛 색(빨강)
  cellBg   = { 0.16, 0.17, 0.21 }, -- 빈 칸 배경
  moveCell = { 0.30, 0.55, 0.35, 0.55 }, -- 이동 가능 칸 하이라이트(연두, 반투명)
  atkCell  = { 0.80, 0.30, 0.30, 0.55 }, -- 공격 가능 칸 하이라이트(빨강, 반투명)
  selBorder = { 1.00, 0.85, 0.20 },      -- 선택 유닛 강조 테두리(노랑)
}

-- 팝업(장수 목록/상세/선물) 레이아웃 상수 (GDD 17장 팝업). main 이 읽어 배치.
config.popup = {
  width = 600,         -- 팝업 기본 폭(px)
  height = 680,        -- 팝업 기본 높이(px). 지역당 장수 10명+ 도 들어가게 넉넉히.
  pad = 20,            -- 팝업 내부 여백(px)
  lineGap = 28,        -- 텍스트 줄 간격(px)
  rowHeight = 36,      -- 장수 목록 한 줄(버튼) 높이(px)
  rowGap = 4,          -- 목록 줄 사이 간격(px)
  closeSize = 32,      -- 우상단 X 버튼 한 변(px)
  buttonHeight = 48,   -- 상세/선물 액션 버튼 높이(px)
  bg = { 0.12, 0.13, 0.17, 0.98 },     -- 팝업 배경(거의 불투명)
  scrim = { 0.0, 0.0, 0.0, 0.55 },     -- 팝업 뒤 어둡게 까는 막(scrim)
}

-- 턴/달력 상수 (GDD 3·9장). 1턴 = 1개월 진행. 규칙 계층(game_state)이 읽어 쓴다.
--   매직넘버 금지(CLAUDE.md): 12개월·수확월을 코드에 흩지 않고 여기 한 곳에.
config.turn = {
  monthsPerYear = 12, -- 1년 = 12개월. 12월 다음은 다음 해 1월 (GDD 3장 흐름)
  harvestMonth = 7,   -- 군량 수확월 — 7월 (GDD 9장: "특정 월(7월) 수확")
}

-- 우측 정보 패널 + 턴 버튼 레이아웃 상수 (GDD 17장: 우측 선택 지역 정보 패널).
--   표현 계층(main)·UI(ui)가 읽어 패널/버튼을 배치한다.
config.panel = {
  width = 320,         -- 우측 패널 폭(px). 화면 오른쪽에 세로로 고정.
  pad = 16,            -- 패널 내부 여백(px)
  lineGap = 26,        -- 텍스트 줄 간격(px)
  buttonHeight = 56,   -- 최하단 턴 버튼 높이(px)
  buttonMargin = 16,   -- 턴 버튼 바깥 여백(패널 좌우·하단에서)
  bg = { 0.10, 0.11, 0.14, 0.92 }, -- 패널 배경(반투명 어두운 색). 4번째=알파
}

-- 지도 렌더 상수.
config.map = {
  fontSize = 18,           -- 지역 이름 폰트 크기
  hexSize = 64,            -- 헥스 반경(중심→꼭짓점, 월드 px)
  borderWidth = 2,         -- 헥스 경계선 두께(=인접)
  selectBorderWidth = 4,   -- 선택 헥스 강조 경계선 두께
  fillAlpha = 0.9,         -- 헥스 채움 불투명도
}

return config
