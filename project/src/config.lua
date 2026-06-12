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
