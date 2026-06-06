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

-- 지도 렌더 상수.
config.map = {
  fontSize = 18,           -- 지역 이름 폰트 크기
  hexSize = 64,            -- 헥스 반경(중심→꼭짓점, 월드 px)
  borderWidth = 2,         -- 헥스 경계선 두께(=인접)
  selectBorderWidth = 4,   -- 선택 헥스 강조 경계선 두께
  fillAlpha = 0.9,         -- 헥스 채움 불투명도
}

return config
