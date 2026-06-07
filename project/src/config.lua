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
  text = { 0.97, 0.97, 0.97 },             -- 지역 이름 글자색
  textShadow = { 0.05, 0.05, 0.07 },       -- 이름 가독용 그림자
  background = { 0.12, 0.13, 0.16 },       -- 지도 배경(영토 밖)
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

-- 세력(군주) 상수 (GDD 9장). 플레이어 군주의 금 보유고 등.
config.faction = {
  -- 플레이어 군주 시작 금. (임시 placeholder — 매 턴 세수 수입(GDD 9장)이 도입되면
  --  그쪽으로 채워진다. 지금은 선물 차감을 시연/검증할 수 있게 상수로 둔다.)
  startGold = 500,
}

-- 선물 시스템 상수 (GDD 15장). 규칙 계층(game_state)이 읽어 쓴다.
--   매직넘버 금지(CLAUDE.md): 충성 환산·금 상한을 코드에 흩지 않고 여기 한 곳에.
config.gift = {
  goldGiftMax = 10,   -- 금 선물 1회 최대 금 (GDD 15장: "0~10금")
  loyaltyPerGold = 5, -- 1금당 충성 상승량 (GDD 15장: "1금 = 충성 +5")
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
