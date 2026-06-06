--[[
game_data.lua — 데이터 계층: 시나리오/지역/장수/건물/장비 데이터 소유

  이 모듈의 책임:
    - 게임 콘텐츠 데이터를 순수 테이블로 보관한다. (규칙·표현 로직 없음)
    - 현재 범위: 헥스 월드맵 지역 30개 (GDD 5장 명시 고정 목록).
  관계:
    - hex.lua 가 q,r 을 픽셀/꼭짓점으로 바꾼다.
    - region.lua 가 이 regions 를 주입받아 조회/인접/클릭을 판정한다.
    - main.lua 가 이 regions 로 헥스 채움/경계/이름을 그린다.

  지역 레코드 필드:
    id    : 고유 문자열 키
    name  : 화면 표시 한글 이름 (GDD 5장 명시 30개. 실제 후한말~삼국 중국 지명만)
    q, r  : axial 헥스 좌표 (벌집 위치). 픽셀은 hex.axialToPixel 로 산출.
    owner : 소유 세력 "wei"|"shu"|"wu"|"neutral" → 색상 (GDD 6장)

  배치 규칙 (CLAUDE.md 지도/지역 규칙):
    - 고정 30개. 추가/삭제 금지. 백제/신라/고구려/현대/가상명 금지.
    - q,r 는 오프셋(odd-r) 벌집을 대략 중국 지형으로 깔고 axial 로 변환한 값.
      (북=작은 r, 서=작은 q. 북부·중원=위, 익주=촉, 강동=오, 나머지=중립)
    - 헥스가 맞닿으면 인접(GDD: 헥스 인접=연결). 인접은 hex 좌표에서 코드가 산출.
    - owner 분배는 색상 시연용 초기값. 정식 시나리오 배치는 추후 GDD 4장.
--]]

local game_data = {}

-- 30 거점. 행(r) = 북→남. 같은 행 안에서 q 증가 = 서→동(벌집 전단 반영).
game_data.regions = {
  -- ── r0: 최북단 (서→동) ───────────────────────────────────
  { id = "wuwei",    name = "무위", q = 0, r = 0, owner = "neutral" }, -- 양주 서북
  { id = "jinyang",  name = "진양", q = 1, r = 0, owner = "wei" },
  { id = "pingyuan", name = "평원", q = 2, r = 0, owner = "wei" },
  { id = "bohai",    name = "발해", q = 3, r = 0, owner = "wei" },
  { id = "beiping",  name = "북평", q = 4, r = 0, owner = "wei" },     -- 동북 끝

  -- ── r1: 관중~하북 (서→동) ────────────────────────────────
  { id = "tianshui", name = "천수", q = 0, r = 1, owner = "neutral" },
  { id = "changan",  name = "장안", q = 1, r = 1, owner = "wei" },
  { id = "ye",       name = "업",   q = 2, r = 1, owner = "wei" },
  { id = "puyang",   name = "복양", q = 3, r = 1, owner = "wei" },
  { id = "xiapi",    name = "하비", q = 4, r = 1, owner = "neutral" },
  { id = "pengcheng",name = "팽성", q = 5, r = 1, owner = "neutral" },

  -- ── r2: 중원 (서→동) ─────────────────────────────────────
  { id = "hanzhong", name = "한중", q = -1, r = 2, owner = "shu" },
  { id = "luoyang",  name = "낙양", q = 0, r = 2, owner = "wei" },
  { id = "hongnong", name = "홍농", q = 1, r = 2, owner = "wei" },
  { id = "chenliu",  name = "진류", q = 2, r = 2, owner = "wei" },
  { id = "xuchang",  name = "허창", q = 3, r = 2, owner = "wei" },
  { id = "guangling",name = "광릉", q = 4, r = 2, owner = "neutral" }, -- 동남 해안

  -- ── r3: 형주 북~강동 (서→동) ─────────────────────────────
  { id = "chengdu",  name = "성도", q = -1, r = 3, owner = "shu" },
  { id = "runan",    name = "여남", q = 0, r = 3, owner = "wei" },
  { id = "xinye",    name = "신야", q = 1, r = 3, owner = "neutral" },
  { id = "xiangyang",name = "양양", q = 2, r = 3, owner = "neutral" },
  { id = "jianye",   name = "건업", q = 3, r = 3, owner = "wu" },
  { id = "wujun",    name = "오군", q = 4, r = 3, owner = "wu" },

  -- ── r4: 익주 남~강동 남 (서→동) ──────────────────────────
  { id = "jiangzhou",name = "강주", q = -2, r = 4, owner = "shu" },
  { id = "jiangling",name = "강릉", q = -1, r = 4, owner = "neutral" },
  { id = "wuling",   name = "무릉", q = 0, r = 4, owner = "neutral" },
  { id = "chaisang", name = "시상", q = 1, r = 4, owner = "wu" },
  { id = "kuaiji",   name = "회계", q = 2, r = 4, owner = "wu" },

  -- ── r5: 최남단 ───────────────────────────────────────────
  { id = "yunnan",   name = "운남", q = -1, r = 5, owner = "shu" },
  { id = "changsha", name = "장사", q = 0, r = 5, owner = "neutral" },
}

return game_data
