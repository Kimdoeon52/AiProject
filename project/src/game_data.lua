--[[
game_data.lua — 데이터 계층: 지역(헥스) + 시나리오(세력/소유)

  이 모듈의 책임:
    - 콘텐츠 데이터를 순수 테이블로 보관(규칙·표현 로직 없음).
    - regions  : 고정 헥스 지역 30개 (GDD 5장. 모든 시나리오 공유 — CLAUDE 지도규칙).
    - scenarios: 시나리오별 세력(factions)과 지역 소유(ownership) (GDD 4장).
  관계:
    - hex.lua  : q,r → 픽셀/꼭짓점.
    - region.lua : regions 주입받아 조회/인접/클릭.
    - main.lua : 선택된 시나리오의 ownership 으로 헥스를 세력색으로 칠한다.

  지역 레코드: { id, name(한글), q, r }  ← owner 없음. 소유는 시나리오가 가진다.
  시나리오 레코드:
    { id, name, year,
      factions = { [fid] = { name=한글, color={r,g,b} } },   -- 세력 정의(GDD 6장: 세력별 고유색)
      ownership = { [regionId] = fid } }                      -- 지역→세력. 없으면 중립(회색)

  배치 근거: 184/194/221 실제 군웅의 대략적 세력권을 30지역에 매핑(요약 고증).
  중립=회색은 config.colors.neutral 사용.
--]]

local game_data = {}

-- ── 고정 지역 30개 (행 r=북→남, 같은 행 q=서→동) ──────────
game_data.regions = {
  -- r0 북단
  { id = "jinyang",  name = "진양", q = 1, r = 0 },
  { id = "bohai",    name = "발해", q = 2, r = 0 },
  { id = "beiping",  name = "북평", q = 3, r = 0 },
  -- r1 하북
  { id = "wuwei",    name = "무위", q = 0, r = 1 },
  { id = "ye",       name = "업",   q = 1, r = 1 },
  { id = "pingyuan", name = "평원", q = 2, r = 1 },
  { id = "puyang",   name = "복양", q = 3, r = 1 },
  { id = "xiapi",    name = "하비", q = 4, r = 1 },
  -- r2 중원
  { id = "tianshui", name = "천수", q = -1, r = 2 },
  { id = "changan",  name = "장안", q = 0, r = 2 },
  { id = "hongnong", name = "홍농", q = 1, r = 2 },
  { id = "luoyang",  name = "낙양", q = 2, r = 2 },
  { id = "chenliu",  name = "진류", q = 3, r = 2 },
  { id = "xuchang",  name = "허창", q = 4, r = 2 },
  { id = "pengcheng",name = "팽성", q = 5, r = 2 },
  -- r3 형북·예남·강동북
  { id = "hanzhong", name = "한중", q = -1, r = 3 },
  { id = "xinye",    name = "신야", q = 0, r = 3 },
  { id = "xiangyang",name = "양양", q = 1, r = 3 },
  { id = "runan",    name = "여남", q = 2, r = 3 },
  { id = "jianye",   name = "건업", q = 3, r = 3 },
  { id = "guangling",name = "광릉", q = 4, r = 3 },
  -- r4 익주·형중·강동남
  { id = "chengdu",  name = "성도", q = -2, r = 4 },
  { id = "jiangling",name = "강릉", q = -1, r = 4 },
  { id = "chaisang", name = "시상", q = 0, r = 4 },
  { id = "wujun",    name = "오군", q = 1, r = 4 },
  { id = "kuaiji",   name = "회계", q = 2, r = 4 },
  -- r5 형남·익동
  { id = "jiangzhou",name = "강주", q = -2, r = 5 },
  { id = "wuling",   name = "무릉", q = -1, r = 5 },
  { id = "changsha", name = "장사", q = 0, r = 5 },
  -- r6 최남
  { id = "yunnan",   name = "운남", q = -2, r = 6 },
}

-- ── 시나리오 (배열 순서 = 선택 화면 표시 순서) ────────────
game_data.scenarios = {
  -- ① 184 황건의 난 — 한 관군 vs 황건적 + 변경 군벌
  {
    id = "yellow_turban", name = "황건의 난", year = 184,
    factions = {
      han          = { name = "한 관군",   color = { 0.88, 0.80, 0.42 } }, -- 한실 금황
      yellowturban = { name = "황건적",     color = { 0.78, 0.60, 0.16 } }, -- 황토
      dongzhuo     = { name = "동탁",       color = { 0.70, 0.22, 0.22 } }, -- 암적
      liuyan       = { name = "유언",       color = { 0.32, 0.66, 0.58 } }, -- 익주 청록
    },
    ownership = {
      -- 황건적 봉기지(기/청/연/예/형 일부)
      ye = "yellowturban", pingyuan = "yellowturban", puyang = "yellowturban",
      runan = "yellowturban", xinye = "yellowturban",
      -- 동탁(서량)
      tianshui = "dongzhuo", wuwei = "dongzhuo",
      -- 유언(익주)
      chengdu = "liuyan", jiangzhou = "liuyan", yunnan = "liuyan", hanzhong = "liuyan",
      -- 나머지는 한 관군
      jinyang = "han", bohai = "han", beiping = "han", changan = "han",
      hongnong = "han", luoyang = "han", chenliu = "han", xuchang = "han",
      pengcheng = "han", xiapi = "han", xiangyang = "han", jiangling = "han",
      wuling = "han", changsha = "han", jianye = "han", guangling = "han",
      wujun = "han", kuaiji = "han", chaisang = "han",
    },
  },

  -- ② 194 군웅할거 — 천하 분열, 군벌 11세력
  {
    id = "warlords", name = "군웅할거", year = 194,
    factions = {
      yuanshao   = { name = "원소",       color = { 0.55, 0.32, 0.72 } }, -- 보라
      gongsunzan = { name = "공손찬",     color = { 0.30, 0.68, 0.70 } }, -- 청록
      caocao     = { name = "조조",       color = { 0.20, 0.45, 0.90 } }, -- 파랑
      taoqian    = { name = "도겸·유비",  color = { 0.50, 0.55, 0.45 } }, -- 올리브
      licaoguo   = { name = "이각·곽사",  color = { 0.62, 0.50, 0.32 } }, -- 갈
      mateng     = { name = "마등·한수",  color = { 0.92, 0.58, 0.20 } }, -- 주황
      yuanshu    = { name = "원술",       color = { 0.80, 0.32, 0.55 } }, -- 자홍
      liubiao    = { name = "유표",       color = { 0.30, 0.58, 0.82 } }, -- 하늘
      sunce      = { name = "손책",       color = { 0.85, 0.25, 0.25 } }, -- 빨강
      liuzhang   = { name = "유장",       color = { 0.45, 0.72, 0.42 } }, -- 연두
      zhanglu    = { name = "장로",       color = { 0.85, 0.78, 0.30 } }, -- 노랑
    },
    ownership = {
      ye = "yuanshao", bohai = "yuanshao", pingyuan = "yuanshao", jinyang = "yuanshao",
      beiping = "gongsunzan",
      puyang = "caocao", chenliu = "caocao", xuchang = "caocao",
      xiapi = "taoqian", pengcheng = "taoqian", guangling = "taoqian",
      changan = "licaoguo", hongnong = "licaoguo", luoyang = "licaoguo",
      tianshui = "mateng", wuwei = "mateng",
      runan = "yuanshu",
      xinye = "liubiao", xiangyang = "liubiao", jiangling = "liubiao",
      wuling = "liubiao", changsha = "liubiao",
      jianye = "sunce", wujun = "sunce", kuaiji = "sunce", chaisang = "sunce",
      chengdu = "liuzhang", jiangzhou = "liuzhang", yunnan = "liuzhang",
      hanzhong = "zhanglu",
    },
  },

  -- ③ 221 삼국 정립 — 위·촉·오 (+ 변경 중립)
  {
    id = "three_kingdoms", name = "삼국 정립", year = 221,
    factions = {
      wei = { name = "위(조비)", color = { 0.20, 0.45, 0.90 } }, -- 파랑
      shu = { name = "촉(유비)", color = { 0.20, 0.70, 0.35 } }, -- 초록
      wu  = { name = "오(손권)", color = { 0.85, 0.25, 0.25 } }, -- 빨강
    },
    ownership = {
      -- 위: 북부·중원
      jinyang = "wei", bohai = "wei", beiping = "wei", ye = "wei", pingyuan = "wei",
      puyang = "wei", changan = "wei", hongnong = "wei", luoyang = "wei",
      chenliu = "wei", xuchang = "wei", runan = "wei",
      -- 촉: 익주·한중
      hanzhong = "shu", chengdu = "shu", jiangzhou = "shu", yunnan = "shu",
      -- 오: 강동
      jianye = "wu", chaisang = "wu", wujun = "wu", kuaiji = "wu",
      -- 나머지(무위·천수·하비·팽성·신야·양양·광릉·강릉·무릉·장사)는 중립(미기재)
    },
  },
}

return game_data
