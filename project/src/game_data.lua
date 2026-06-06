--[[
game_data.lua — 데이터 계층: 시나리오/지역/장수/건물/장비 데이터 소유

  이 모듈의 책임:
    - 게임 콘텐츠 데이터를 순수 테이블로 보관한다. (규칙·표현 로직 없음)
    - Day1 범위: 월드맵 지역(거점) 40개만. 장수/건물/장비는 추후 추가.
  관계:
    - region.lua 가 이 regions 를 주입받아 조회/인접/클릭을 판정한다.
    - main.lua 가 이 regions 로 노드/이름/인접선을 그린다.

  지역 레코드 필드 (GDD 5장 골격 중 Day1 렌더 필수분):
    id        : 고유 문자열 키 (neighbors 참조 대상)
    name      : 화면 표시 한글 이름
    x, y      : 월드 좌표 (대략 중국 지리 배치 — 위=북, 아래=남, 왼=서, 오=동)
    owner     : 소유 세력 "wei"|"shu"|"wu"|"neutral" → 색상 결정 (GDD 6장)
    neighbors : 인접 지역 id 목록. 반드시 양방향 일관 (A가 B면 B도 A).

  주의: 콘텐츠 추가/수정은 이 파일만 고친다 (데이터 주도 — CLAUDE.md 원칙).
        owner 분배는 Day1 색상 시연용 초기값. 정식 시나리오 배치는 추후 4장 기반.
--]]

local game_data = {}

-- 40개 거점. 북부(위·파랑) / 서부(촉·초록) / 동남(오·빨강) / 형주·남방(중립·회색).
game_data.regions = {
  -- ── 북부·중원 (위/조조 계열) ─────────────────────────────
  { id = "ye",       name = "업",   x = 940, y = 280, owner = "wei",
    neighbors = { "jinyang", "nanpi", "luoyang", "puyang" } },
  { id = "luoyang",  name = "낙양", x = 820, y = 360, owner = "wei",
    neighbors = { "ye", "chenliu", "changan", "xuchang", "nanyang" } },
  { id = "changan",  name = "장안", x = 640, y = 360, owner = "wei",
    neighbors = { "luoyang", "anding", "hanzhong" } },
  { id = "xuchang",  name = "허창", x = 920, y = 505, owner = "wei",
    neighbors = { "chenliu", "luoyang", "xiaopei", "nanyang" } },
  { id = "jinyang",  name = "진양", x = 860, y = 200, owner = "wei",
    neighbors = { "ye", "ji" } },
  { id = "beiping",  name = "북평", x = 1160, y = 140, owner = "wei",
    neighbors = { "ji", "nanpi" } },
  { id = "ji",       name = "계",   x = 1040, y = 200, owner = "wei",
    neighbors = { "jinyang", "beiping", "nanpi" } },
  { id = "nanpi",    name = "남피", x = 1010, y = 280, owner = "wei",
    neighbors = { "ji", "ye", "puyang", "beiping" } },
  { id = "puyang",   name = "복양", x = 960, y = 360, owner = "wei",
    neighbors = { "ye", "chenliu", "nanpi" } },
  { id = "chenliu",  name = "진류", x = 890, y = 400, owner = "wei",
    neighbors = { "puyang", "xuchang", "luoyang" } },
  { id = "anding",   name = "안정", x = 540, y = 300, owner = "wei",
    neighbors = { "changan", "tianshui", "wuwei" } },

  -- ── 서량·관중 변경 (중립) ────────────────────────────────
  { id = "tianshui", name = "천수", x = 460, y = 380, owner = "neutral",
    neighbors = { "anding", "wuwei" } },
  { id = "wuwei",    name = "무위", x = 360, y = 300, owner = "neutral",
    neighbors = { "tianshui", "anding" } },
  { id = "xiaopei",  name = "소패", x = 1010, y = 460, owner = "neutral",
    neighbors = { "xuchang", "xiapi" } },
  { id = "xiapi",    name = "하비", x = 1085, y = 395, owner = "neutral",
    neighbors = { "xiaopei", "lujiang" } },

  -- ── 서부 (촉/유비 계열) ──────────────────────────────────
  { id = "hanzhong", name = "한중", x = 560, y = 480, owner = "shu",
    neighbors = { "changan", "zitong", "baidi" } },
  { id = "chengdu",  name = "성도", x = 380, y = 620, owner = "shu",
    neighbors = { "zitong", "jiangzhou", "yunnan" } },
  { id = "zitong",   name = "재동", x = 450, y = 560, owner = "shu",
    neighbors = { "hanzhong", "chengdu" } },
  { id = "jiangzhou",name = "강주", x = 480, y = 700, owner = "shu",
    neighbors = { "chengdu", "yunnan", "baidi" } },
  { id = "yunnan",   name = "운남", x = 380, y = 820, owner = "shu",
    neighbors = { "jiangzhou", "chengdu" } },
  { id = "baidi",    name = "백제", x = 600, y = 620, owner = "shu",
    neighbors = { "hanzhong", "jiangzhou", "jiangling", "wuling" } },

  -- ── 형주·남방 (중립, 쟁탈지) ─────────────────────────────
  { id = "nanyang",  name = "완",   x = 820, y = 440, owner = "neutral",
    neighbors = { "xuchang", "luoyang", "xinye" } },
  { id = "xinye",    name = "신야", x = 772, y = 502, owner = "neutral",
    neighbors = { "nanyang", "xiangyang" } },
  { id = "xiangyang",name = "양양", x = 830, y = 540, owner = "neutral",
    neighbors = { "xinye", "jiangling", "jiangxia" } },
  { id = "jiangling",name = "강릉", x = 800, y = 620, owner = "neutral",
    neighbors = { "baidi", "xiangyang", "wuling", "changsha" } },
  { id = "jiangxia", name = "강하", x = 950, y = 600, owner = "neutral",
    neighbors = { "xiangyang", "changsha", "chaisang" } },
  { id = "changsha", name = "장사", x = 880, y = 730, owner = "neutral",
    neighbors = { "jiangling", "jiangxia", "lingling", "guiyang" } },
  { id = "wuling",   name = "무릉", x = 700, y = 720, owner = "neutral",
    neighbors = { "baidi", "jiangling", "lingling" } },
  { id = "lingling", name = "영릉", x = 790, y = 820, owner = "neutral",
    neighbors = { "changsha", "guiyang", "wuling", "jiaozhi" } },
  { id = "guiyang",  name = "계양", x = 880, y = 840, owner = "neutral",
    neighbors = { "changsha", "lingling", "hepu", "nanhai" } },

  -- ── 동남 (오/손씨 계열) ──────────────────────────────────
  { id = "lujiang",  name = "여강", x = 1080, y = 500, owner = "wu",
    neighbors = { "xiapi", "jianye", "chaisang" } },
  { id = "jianye",   name = "건업", x = 1190, y = 520, owner = "wu",
    neighbors = { "lujiang", "wu", "poyang" } },
  { id = "wu",       name = "오",   x = 1260, y = 560, owner = "wu",
    neighbors = { "jianye", "kuaiji" } },
  { id = "kuaiji",   name = "회계", x = 1250, y = 680, owner = "wu",
    neighbors = { "wu", "jianan" } },
  { id = "chaisang", name = "시상", x = 1080, y = 610, owner = "wu",
    neighbors = { "lujiang", "poyang", "jiangxia" } },
  { id = "poyang",   name = "파양", x = 1140, y = 690, owner = "wu",
    neighbors = { "jianye", "chaisang", "jianan" } },
  { id = "jianan",   name = "건안", x = 1190, y = 800, owner = "wu",
    neighbors = { "poyang", "kuaiji" } },

  -- ── 최남단 (중립) ────────────────────────────────────────
  { id = "jiaozhi",  name = "교지", x = 740, y = 960, owner = "neutral",
    neighbors = { "lingling", "hepu" } },
  { id = "nanhai",   name = "남해", x = 980, y = 930, owner = "neutral",
    neighbors = { "hepu", "guiyang" } },
  { id = "hepu",     name = "합포", x = 860, y = 930, owner = "neutral",
    neighbors = { "guiyang", "nanhai", "jiaozhi" } },
}

return game_data
