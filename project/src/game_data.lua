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

-- ── 장수 베이스 데이터 (GDD 7장) ─────────────────────────
--   "정적" 데이터만 둔다. 시나리오·런타임에 따라 변하는 값은 여기 없다.
--     · 베이스에 두는 것 : id, 이름, 무력/지력/정치/체력, 등장연도(appear)
--     · 베이스에 두지 않는 것(시나리오 배치 또는 런타임) :
--         충성도 / 보유 병력 / 위치 지역 / 소속 세력 / 상태 / 이동중 / 행동완료
--   appear(등장연도): 그 인물이 "장수로 활동 가능"해지는 대략 연도.
--     시나리오 연도보다 appear 가 늦으면 unrevealed(미등장) → 그 시나리오엔 배치 안 함.
--
--   능력치 척도: 0~100. 정사·연의 인지도를 반영한 합리적 분포(절대 고증값 아님).
--     might=무력, intel=지력, pol=정치, hp=체력.
--   필드 키를 영문으로 둔 이유: 코드(게임 규칙)에서 참조하므로 region.id 등과 일관.
--
--   table 리터럴: C#의 객체 초기화자 / C++ 의 집합 초기화와 비슷. 각 줄이 장수 1명.
game_data.officers = {
  -- 위(조조) 진영 인물군 ─ 조씨·하후씨 일족 + 모사·맹장
  { id = "caocao",     name = "조조",   might = 72, intel = 91, pol = 94, hp = 82, appear = 184 },
  { id = "xiahoudun",  name = "하후돈", might = 90, intel = 62, pol = 72, hp = 80, appear = 184 },
  { id = "xiahouyuan", name = "하후연", might = 91, intel = 66, pol = 46, hp = 80, appear = 189 },
  { id = "caoren",     name = "조인",   might = 86, intel = 72, pol = 62, hp = 82, appear = 190 },
  { id = "caohong",    name = "조홍",   might = 84, intel = 45, pol = 42, hp = 80, appear = 190 },
  { id = "caochun",    name = "조순",   might = 79, intel = 74, pol = 66, hp = 75, appear = 200 },
  { id = "dianwei",    name = "전위",   might = 97, intel = 36, pol = 20, hp = 88, appear = 194 },
  { id = "xuchu",      name = "허저",   might = 96, intel = 40, pol = 26, hp = 90, appear = 197 },
  { id = "zhangliao",  name = "장료",   might = 92, intel = 78, pol = 58, hp = 84, appear = 184 },
  { id = "yuejin",     name = "악진",   might = 85, intel = 58, pol = 46, hp = 78, appear = 190 },
  { id = "yujin",      name = "우금",   might = 82, intel = 68, pol = 58, hp = 78, appear = 192 },
  { id = "lidian",     name = "이전",   might = 79, intel = 80, pol = 72, hp = 74, appear = 190 },
  { id = "xuhuang",    name = "서황",   might = 90, intel = 77, pol = 56, hp = 82, appear = 192 },
  { id = "zhanghe",    name = "장합",   might = 89, intel = 80, pol = 54, hp = 82, appear = 189 },
  { id = "pangde",     name = "방덕",   might = 92, intel = 72, pol = 45, hp = 84, appear = 200 },
  { id = "wenpin",     name = "문빙",   might = 85, intel = 68, pol = 60, hp = 80, appear = 200 },
  { id = "guojia",     name = "곽가",   might = 15, intel = 98, pol = 78, hp = 55, appear = 196 },
  { id = "xunyu",      name = "순욱",   might = 13, intel = 95, pol = 98, hp = 60, appear = 189 },
  { id = "xunyou",     name = "순유",   might = 16, intel = 94, pol = 88, hp = 62, appear = 192 },
  { id = "chengyu",    name = "정욱",   might = 40, intel = 90, pol = 84, hp = 70, appear = 192 },
  { id = "jiaxu",      name = "가후",   might = 25, intel = 97, pol = 82, hp = 72, appear = 189 },
  { id = "manchong",   name = "만총",   might = 62, intel = 84, pol = 82, hp = 76, appear = 192 },
  { id = "zhongyou",   name = "종요",   might = 15, intel = 85, pol = 92, hp = 70, appear = 190 },
  { id = "huaxin",     name = "화흠",   might = 20, intel = 80, pol = 88, hp = 70, appear = 194 },
  { id = "wanglang",   name = "왕랑",   might = 22, intel = 78, pol = 86, hp = 68, appear = 192 },
  { id = "chenqun",    name = "진군",   might = 13, intel = 83, pol = 92, hp = 68, appear = 194 },
  { id = "simayi",     name = "사마의", might = 63, intel = 97, pol = 94, hp = 78, appear = 201 },
  { id = "caopi",      name = "조비",   might = 70, intel = 82, pol = 88, hp = 76, appear = 211 },
  { id = "caozhi",     name = "조식",   might = 30, intel = 88, pol = 80, hp = 64, appear = 211 },
  { id = "dengai",     name = "등애",   might = 88, intel = 93, pol = 82, hp = 80, appear = 240 },
  { id = "zhonghui",   name = "종회",   might = 68, intel = 94, pol = 80, hp = 72, appear = 250 },
  { id = "guohuai",    name = "곽회",   might = 80, intel = 86, pol = 72, hp = 78, appear = 215 },
  { id = "caoxiu",     name = "조휴",   might = 82, intel = 70, pol = 60, hp = 78, appear = 200 },
  { id = "caozhen",    name = "조진",   might = 83, intel = 78, pol = 66, hp = 78, appear = 211 },
  { id = "hanhao",     name = "한호",   might = 70, intel = 66, pol = 70, hp = 72, appear = 194 },
  { id = "tianyu",     name = "전예",   might = 80, intel = 80, pol = 74, hp = 78, appear = 193 },
  { id = "zhuling",    name = "주령",   might = 82, intel = 62, pol = 52, hp = 78, appear = 194 },
  { id = "liuye",      name = "유엽",   might = 30, intel = 90, pol = 80, hp = 66, appear = 196 },
  { id = "dongzhao",   name = "동소",   might = 30, intel = 88, pol = 82, hp = 68, appear = 196 },
  { id = "jiakui",     name = "가규",   might = 55, intel = 82, pol = 80, hp = 74, appear = 211 },

  -- 촉(유비) 진영 인물군 ─ 도원 형제 + 와룡봉추 + 익주계
  { id = "liubei",     name = "유비",   might = 73, intel = 78, pol = 80, hp = 84, appear = 184 },
  { id = "guanyu",     name = "관우",   might = 97, intel = 76, pol = 64, hp = 88, appear = 184 },
  { id = "zhangfei",   name = "장비",   might = 98, intel = 45, pol = 30, hp = 88, appear = 184 },
  { id = "zhaoyun",    name = "조운",   might = 96, intel = 76, pol = 65, hp = 86, appear = 191 },
  { id = "machao",     name = "마초",   might = 97, intel = 44, pol = 42, hp = 88, appear = 205 },
  { id = "huangzhong", name = "황충",   might = 95, intel = 62, pol = 43, hp = 82, appear = 192 },
  { id = "zhugeliang", name = "제갈량", might = 38, intel = 100, pol = 96, hp = 72, appear = 207 },
  { id = "pangtong",   name = "방통",   might = 34, intel = 97, pol = 75, hp = 64, appear = 209 },
  { id = "fazheng",    name = "법정",   might = 40, intel = 94, pol = 80, hp = 64, appear = 211 },
  { id = "weiyan",     name = "위연",   might = 92, intel = 69, pol = 50, hp = 84, appear = 211 },
  { id = "jiangwei",   name = "강유",   might = 91, intel = 94, pol = 80, hp = 82, appear = 228 },
  { id = "masu",       name = "마속",   might = 45, intel = 80, pol = 70, hp = 66, appear = 211 },
  { id = "maliang",    name = "마량",   might = 30, intel = 86, pol = 85, hp = 66, appear = 211 },
  { id = "mizhu",      name = "미축",   might = 20, intel = 60, pol = 82, hp = 64, appear = 190 },
  { id = "mifang",     name = "미방",   might = 55, intel = 45, pol = 50, hp = 66, appear = 190 },
  { id = "sunqian",    name = "손건",   might = 25, intel = 72, pol = 78, hp = 66, appear = 190 },
  { id = "jianyong",   name = "간옹",   might = 22, intel = 74, pol = 78, hp = 64, appear = 184 },
  { id = "guanping",   name = "관평",   might = 86, intel = 60, pol = 48, hp = 80, appear = 211 },
  { id = "guanxing",   name = "관흥",   might = 84, intel = 62, pol = 52, hp = 80, appear = 218 },
  { id = "zhouchang",  name = "주창",   might = 84, intel = 35, pol = 25, hp = 80, appear = 200 },
  { id = "liaohua",    name = "요화",   might = 80, intel = 55, pol = 45, hp = 78, appear = 211 },
  { id = "liufeng",    name = "유봉",   might = 82, intel = 55, pol = 48, hp = 80, appear = 211 },
  { id = "huangquan",  name = "황권",   might = 60, intel = 86, pol = 80, hp = 74, appear = 211 },
  { id = "yanyan",     name = "엄안",   might = 85, intel = 70, pol = 60, hp = 80, appear = 194 },
  { id = "zhangren",   name = "장임",   might = 88, intel = 76, pol = 56, hp = 82, appear = 194 },
  { id = "wuyi",       name = "오의",   might = 78, intel = 68, pol = 66, hp = 76, appear = 211 },
  { id = "chenzhen",   name = "진진",   might = 20, intel = 78, pol = 82, hp = 64, appear = 211 },
  { id = "jiangwan",   name = "장완",   might = 20, intel = 85, pol = 90, hp = 66, appear = 211 },
  { id = "feiyi",      name = "비의",   might = 25, intel = 88, pol = 90, hp = 66, appear = 221 },
  { id = "dongyun",    name = "동윤",   might = 15, intel = 80, pol = 86, hp = 64, appear = 221 },

  -- 오(손씨) 진영 인물군 ─ 손씨 일족 + 강동 사대도독 + 강표 명사
  { id = "sunjian",    name = "손견",   might = 90, intel = 70, pol = 60, hp = 84, appear = 184 },
  { id = "sunce",      name = "손책",   might = 92, intel = 72, pol = 68, hp = 84, appear = 194 },
  { id = "sunquan",    name = "손권",   might = 68, intel = 80, pol = 90, hp = 80, appear = 200 },
  { id = "sunjing",    name = "손정",   might = 72, intel = 60, pol = 58, hp = 76, appear = 190 },
  { id = "zhouyu",     name = "주유",   might = 72, intel = 96, pol = 88, hp = 78, appear = 195 },
  { id = "lusu",       name = "노숙",   might = 40, intel = 93, pol = 90, hp = 72, appear = 200 },
  { id = "lvmeng",     name = "여몽",   might = 87, intel = 88, pol = 75, hp = 80, appear = 198 },
  { id = "luxun",      name = "육손",   might = 75, intel = 96, pol = 88, hp = 76, appear = 215 },
  { id = "taishici",   name = "태사자", might = 93, intel = 65, pol = 58, hp = 84, appear = 193 },
  { id = "huanggai",   name = "황개",   might = 84, intel = 72, pol = 66, hp = 80, appear = 184 },
  { id = "hanang",     name = "한당",   might = 82, intel = 58, pol = 50, hp = 80, appear = 184 },
  { id = "zhoutai",    name = "주태",   might = 88, intel = 55, pol = 45, hp = 84, appear = 195 },
  { id = "ganning",    name = "감녕",   might = 94, intel = 70, pol = 45, hp = 84, appear = 200 },
  { id = "lingtong",   name = "능통",   might = 87, intel = 62, pol = 52, hp = 80, appear = 204 },
  { id = "chengpu",    name = "정보",   might = 83, intel = 74, pol = 68, hp = 80, appear = 184 },
  { id = "zhugejin",   name = "제갈근", might = 25, intel = 82, pol = 86, hp = 68, appear = 200 },
  { id = "zhangzhao",  name = "장소",   might = 15, intel = 85, pol = 93, hp = 68, appear = 195 },
  { id = "zhanghong",  name = "장굉",   might = 18, intel = 84, pol = 88, hp = 66, appear = 195 },
  { id = "zhuran",     name = "주연",   might = 82, intel = 72, pol = 60, hp = 78, appear = 204 },
  { id = "xusheng",    name = "서성",   might = 85, intel = 70, pol = 56, hp = 80, appear = 204 },
  { id = "dingfeng",   name = "정봉",   might = 86, intel = 66, pol = 48, hp = 82, appear = 215 },
  { id = "panzhang",   name = "반장",   might = 83, intel = 55, pol = 45, hp = 78, appear = 204 },
  { id = "jiangqin",   name = "장흠",   might = 82, intel = 58, pol = 50, hp = 78, appear = 195 },
  { id = "chenwu",     name = "진무",   might = 84, intel = 52, pol = 45, hp = 80, appear = 195 },
  { id = "dongxi",     name = "동습",   might = 80, intel = 55, pol = 48, hp = 78, appear = 195 },
  { id = "ganze",      name = "감택",   might = 15, intel = 84, pol = 82, hp = 64, appear = 210 },
  { id = "buzhi",      name = "보즐",   might = 20, intel = 82, pol = 84, hp = 66, appear = 210 },
  { id = "guyong",     name = "고옹",   might = 13, intel = 82, pol = 90, hp = 66, appear = 200 },

  -- 동탁·여포 진영 인물군 ─ 서량 군벌 + 여포 휘하
  { id = "dongzhuo",   name = "동탁",   might = 87, intel = 62, pol = 40, hp = 82, appear = 184 },
  { id = "lvbu",       name = "여포",   might = 100, intel = 32, pol = 23, hp = 92, appear = 184 },
  { id = "liru",       name = "이유",   might = 30, intel = 90, pol = 70, hp = 66, appear = 189 },
  { id = "huaxiong",   name = "화웅",   might = 89, intel = 32, pol = 22, hp = 84, appear = 189 },
  { id = "lijue",      name = "이각",   might = 84, intel = 52, pol = 35, hp = 80, appear = 189 },
  { id = "guosi",      name = "곽사",   might = 82, intel = 44, pol = 30, hp = 78, appear = 189 },
  { id = "zhangji",    name = "장제",   might = 76, intel = 50, pol = 42, hp = 76, appear = 189 },
  { id = "fanchou",    name = "번조",   might = 78, intel = 40, pol = 30, hp = 76, appear = 189 },
  { id = "niufu",      name = "우보",   might = 78, intel = 42, pol = 35, hp = 76, appear = 189 },
  { id = "zhangxiu",   name = "장수",   might = 85, intel = 60, pol = 48, hp = 80, appear = 197 },
  { id = "chengong",   name = "진궁",   might = 40, intel = 90, pol = 75, hp = 70, appear = 189 },
  { id = "gaoshun",    name = "고순",   might = 88, intel = 66, pol = 48, hp = 82, appear = 189 },
  { id = "songxian",   name = "송헌",   might = 74, intel = 40, pol = 35, hp = 74, appear = 194 },
  { id = "weixu",      name = "위속",   might = 72, intel = 40, pol = 35, hp = 72, appear = 194 },
  { id = "houcheng",   name = "후성",   might = 73, intel = 42, pol = 38, hp = 72, appear = 194 },
  { id = "zangba",     name = "장패",   might = 84, intel = 62, pol = 55, hp = 80, appear = 194 },

  -- 원소 진영 인물군 ─ 하북 명문 + 하북 사대명장·모사
  { id = "yuanshao",   name = "원소",   might = 68, intel = 75, pol = 80, hp = 80, appear = 184 },
  { id = "yanliang",   name = "안량",   might = 93, intel = 32, pol = 25, hp = 84, appear = 195 },
  { id = "wenchou",    name = "문추",   might = 92, intel = 30, pol = 24, hp = 84, appear = 195 },
  { id = "juju",       name = "저수",   might = 30, intel = 93, pol = 85, hp = 66, appear = 191 },
  { id = "tianfeng",   name = "전풍",   might = 25, intel = 94, pol = 80, hp = 64, appear = 191 },
  { id = "guotu",      name = "곽도",   might = 30, intel = 80, pol = 62, hp = 66, appear = 191 },
  { id = "shenpei",    name = "심배",   might = 42, intel = 82, pol = 78, hp = 72, appear = 191 },
  { id = "fengji",     name = "봉기",   might = 30, intel = 78, pol = 65, hp = 64, appear = 191 },
  { id = "gaolan",     name = "고람",   might = 84, intel = 50, pol = 40, hp = 80, appear = 195 },
  { id = "chunyuqiong",name = "순우경", might = 75, intel = 45, pol = 40, hp = 78, appear = 184 },
  { id = "xunchen",    name = "순심",   might = 20, intel = 85, pol = 78, hp = 64, appear = 191 },
  { id = "xinping",    name = "신평",   might = 30, intel = 76, pol = 70, hp = 64, appear = 191 },
  { id = "yuantan",    name = "원담",   might = 76, intel = 58, pol = 55, hp = 76, appear = 195 },
  { id = "yuanshang",  name = "원상",   might = 74, intel = 58, pol = 56, hp = 76, appear = 200 },
  { id = "yuanxi",     name = "원희",   might = 65, intel = 55, pol = 55, hp = 72, appear = 200 },
  { id = "gaogan",     name = "고간",   might = 74, intel = 60, pol = 56, hp = 76, appear = 195 },

  -- 원술 진영 인물군
  { id = "yuanshu",    name = "원술",   might = 55, intel = 58, pol = 50, hp = 76, appear = 184 },
  { id = "jiling",     name = "기령",   might = 86, intel = 55, pol = 45, hp = 82, appear = 193 },
  { id = "liuxun",     name = "유훈",   might = 72, intel = 55, pol = 50, hp = 74, appear = 197 },

  -- 유표 진영 인물군 ─ 형주 호족
  { id = "liubiao",    name = "유표",   might = 45, intel = 74, pol = 82, hp = 76, appear = 184 },
  { id = "huangzu",    name = "황조",   might = 72, intel = 45, pol = 45, hp = 76, appear = 190 },
  { id = "caimao",     name = "채모",   might = 68, intel = 60, pol = 65, hp = 74, appear = 192 },
  { id = "kuailiang",  name = "괴량",   might = 25, intel = 86, pol = 82, hp = 64, appear = 190 },
  { id = "kuaiyue",    name = "괴월",   might = 30, intel = 88, pol = 84, hp = 66, appear = 190 },
  { id = "zhangyun",   name = "장윤",   might = 60, intel = 55, pol = 55, hp = 70, appear = 195 },
  { id = "liupan",     name = "유반",   might = 70, intel = 58, pol = 55, hp = 74, appear = 200 },

  -- 마등(서량) 진영 인물군
  { id = "mateng",     name = "마등",   might = 85, intel = 50, pol = 50, hp = 82, appear = 184 },
  { id = "hansui",     name = "한수",   might = 78, intel = 72, pol = 60, hp = 78, appear = 184 },
  { id = "chengyi",    name = "성의",   might = 70, intel = 45, pol = 40, hp = 74, appear = 200 },

  -- 공손찬·유주 진영 인물군
  { id = "gongsunzan", name = "공손찬", might = 82, intel = 58, pol = 50, hp = 82, appear = 184 },
  { id = "liuyu",      name = "유우",   might = 20, intel = 76, pol = 88, hp = 64, appear = 184 },
  { id = "tianchou",   name = "전주",   might = 50, intel = 82, pol = 80, hp = 70, appear = 190 },

  -- 그 외 184 군웅·관료 ─ 시대 초기 거점 세력 및 조정 명사
  { id = "dingyuan",   name = "정원",   might = 72, intel = 55, pol = 50, hp = 78, appear = 184 },
  { id = "hejin",      name = "하진",   might = 50, intel = 40, pol = 45, hp = 76, appear = 184 },
  { id = "liuyan",     name = "유언",   might = 40, intel = 72, pol = 78, hp = 74, appear = 184 },
  { id = "liuzhang",   name = "유장",   might = 30, intel = 50, pol = 55, hp = 70, appear = 194 },
  { id = "zhanglu",    name = "장로",   might = 40, intel = 62, pol = 65, hp = 72, appear = 194 },
  { id = "yangsong",   name = "양송",   might = 15, intel = 50, pol = 40, hp = 62, appear = 194 },
  { id = "yangren",    name = "양임",   might = 76, intel = 55, pol = 45, hp = 76, appear = 200 },
  { id = "taoqian",    name = "도겸",   might = 40, intel = 60, pol = 66, hp = 70, appear = 184 },
  { id = "zhangmiao",  name = "장막",   might = 40, intel = 62, pol = 60, hp = 70, appear = 184 },
  { id = "kongrong",   name = "공융",   might = 20, intel = 80, pol = 78, hp = 64, appear = 184 },
  { id = "baoxin",     name = "포신",   might = 74, intel = 60, pol = 55, hp = 76, appear = 184 },
  { id = "wangkuang",  name = "왕광",   might = 68, intel = 50, pol = 50, hp = 72, appear = 184 },
  { id = "liudai",     name = "유대",   might = 55, intel = 52, pol = 55, hp = 70, appear = 184 },
  { id = "zhangyang",  name = "장양",   might = 70, intel = 52, pol = 50, hp = 74, appear = 184 },
  { id = "yangfeng",   name = "양봉",   might = 76, intel = 48, pol = 42, hp = 76, appear = 189 },
  { id = "hanxian",    name = "한섬",   might = 72, intel = 45, pol = 40, hp = 74, appear = 189 },

  -- 황건적·흑산적 인물군 (GDD 4장 184 시나리오 핵심 세력)
  { id = "zhangjiao",  name = "장각",   might = 40, intel = 80, pol = 72, hp = 70, appear = 184 },
  { id = "zhangbao",   name = "장보",   might = 72, intel = 60, pol = 40, hp = 78, appear = 184 },
  { id = "zhangliang", name = "장량",   might = 73, intel = 58, pol = 38, hp = 78, appear = 184 },
  { id = "bocai",      name = "파재",   might = 68, intel = 55, pol = 30, hp = 76, appear = 184 },
  { id = "zhangyan",   name = "장연",   might = 80, intel = 60, pol = 45, hp = 80, appear = 188 },
  { id = "peiyuanshao",name = "배원소", might = 74, intel = 45, pol = 35, hp = 76, appear = 188 },

  -- 명사·재야·기타 ─ 학자/의원/사도 등 등용 대상 인재 (GDD 10장 인재 탐색)
  { id = "huatuo",     name = "화타",   might = 10, intel = 85, pol = 50, hp = 70, appear = 184 },
  { id = "zuoci",      name = "좌자",   might = 20, intel = 88, pol = 40, hp = 66, appear = 184 },
  { id = "simahui",    name = "사마휘", might = 10, intel = 92, pol = 70, hp = 64, appear = 184 },
  { id = "xushu",      name = "서서",   might = 60, intel = 90, pol = 72, hp = 72, appear = 200 },
  { id = "chenden",    name = "진등",   might = 55, intel = 85, pol = 82, hp = 70, appear = 190 },
  { id = "chengui",    name = "진규",   might = 30, intel = 80, pol = 80, hp = 66, appear = 184 },
  { id = "huangfusong",name = "황보숭", might = 80, intel = 80, pol = 72, hp = 78, appear = 184 },
  { id = "zhujun",     name = "주준",   might = 76, intel = 76, pol = 70, hp = 76, appear = 184 },
  { id = "lvzhi",      name = "노식",   might = 70, intel = 82, pol = 80, hp = 74, appear = 184 },
  { id = "caiyong",    name = "채옹",   might = 10, intel = 88, pol = 82, hp = 62, appear = 184 },
  { id = "wangyun",    name = "왕윤",   might = 30, intel = 82, pol = 80, hp = 66, appear = 184 },
  { id = "dongcheng",  name = "동승",   might = 55, intel = 55, pol = 55, hp = 70, appear = 189 },
  { id = "cuiyan",     name = "최염",   might = 30, intel = 78, pol = 86, hp = 68, appear = 200 },
  { id = "xinpi",      name = "신비",   might = 25, intel = 82, pol = 80, hp = 66, appear = 200 },
  { id = "yangxiu",    name = "양수",   might = 20, intel = 88, pol = 72, hp = 62, appear = 211 },
  { id = "wangcan",    name = "왕찬",   might = 15, intel = 82, pol = 76, hp = 60, appear = 200 },
}

-- ── 시나리오 (배열 순서 = 선택 화면 표시 순서) ────────────
game_data.scenarios = {
  -- ① 184 황건의 난 — 황건적 vs 각지 군벌(게임적 허용으로 군웅 배치, 한 관군 제외)
  {
    id = "yellow_turban", name = "황건의 난", year = 184, startMonth = 2, -- 184년 봄 거병
    --   factions[*].lord = 그 세력의 군주 장수 id (충성도 '-' 대상, GDD 7장).
    factions = {
      yellowturban = { name = "황건적",     color = { 0.78, 0.60, 0.16 }, lord = "zhangjiao"  }, -- 황토
      dongzhuo     = { name = "동탁",       color = { 0.70, 0.22, 0.22 }, lord = "dongzhuo"   }, -- 암적
      mateng       = { name = "마등",       color = { 0.92, 0.58, 0.20 }, lord = "mateng"     }, -- 서량 주황
      liuyan       = { name = "유언",       color = { 0.32, 0.66, 0.58 }, lord = "liuyan"     }, -- 익주 청록
      hejin        = { name = "하진",       color = { 0.86, 0.74, 0.45 }, lord = "hejin"      }, -- 한실 외척 금황
      dingyuan     = { name = "정원",       color = { 0.55, 0.60, 0.35 }, lord = "dingyuan"   }, -- 병주 올리브
      gongsunzan   = { name = "공손찬",     color = { 0.30, 0.68, 0.70 }, lord = "gongsunzan" }, -- 유주 청록
      sunjian      = { name = "손견",       color = { 0.85, 0.25, 0.25 }, lord = "sunjian"    }, -- 손씨 빨강
    },
    ownership = {
      -- 황건적 봉기지(기/청/연/예/형/서 일부)
      ye = "yellowturban", pingyuan = "yellowturban", puyang = "yellowturban",
      runan = "yellowturban", xinye = "yellowturban",
      pengcheng = "yellowturban", xiapi = "yellowturban", guangling = "yellowturban",
      -- 동탁(서량 동부·관중)
      wuwei = "dongzhuo", changan = "dongzhuo",
      -- 마등(서량 천수)
      tianshui = "mateng",
      -- 유언(익주)
      chengdu = "liuyan", jiangzhou = "liuyan", yunnan = "liuyan", hanzhong = "liuyan",
      -- 하진(대장군, 낙양 중앙·예주)
      luoyang = "hejin", hongnong = "hejin", chenliu = "hejin", xuchang = "hejin",
      -- 정원(병주)
      jinyang = "dingyuan",
      -- 공손찬(유주)
      beiping = "gongsunzan", bohai = "gongsunzan",
      -- 손견(강동 부춘 출신 + 형남)
      changsha = "sunjian", wuling = "sunjian", jiangling = "sunjian", xiangyang = "sunjian",
      jianye = "sunjian", wujun = "sunjian", kuaiji = "sunjian", chaisang = "sunjian",
    },
    -- 장수 초기 배치 (GDD 4·7장). 각 항목: 장수 id → 소속/위치/충성/상태.
    --   state="active": 세력 소속 → region 은 반드시 그 faction 소유 지역(위 ownership).
    --   state="free"  : 재야 → 임의 지역에 숨음(인재 탐색으로 발견, GDD 10장). faction 없음.
    --   lord(군주)은 loyalty 생략(충성도 '-'); faction.lord 로 식별.
    --   184 는 영웅 다수가 아직 무명 → 재야(free)로 흩어져 있음(시대 고증).
    officers = {
      -- 황건적
      { id = "zhangjiao",  faction = "yellowturban", region = "ye",       state = "active" },
      { id = "zhangbao",   faction = "yellowturban", region = "pingyuan", state = "active", loyalty = 90 },
      { id = "zhangliang", faction = "yellowturban", region = "puyang",   state = "active", loyalty = 88 },
      { id = "bocai",      faction = "yellowturban", region = "runan",    state = "active", loyalty = 70 },
      -- 동탁
      { id = "dongzhuo",   faction = "dongzhuo",     region = "changan",  state = "active" },
      -- 마등
      { id = "mateng",     faction = "mateng",       region = "tianshui", state = "active" },
      { id = "hansui",     faction = "mateng",       region = "tianshui", state = "active", loyalty = 75 },
      -- 유언
      { id = "liuyan",     faction = "liuyan",       region = "chengdu",  state = "active" },
      -- 하진(대장군) + 조정 명사
      { id = "hejin",      faction = "hejin",        region = "luoyang",  state = "active" },
      { id = "huangfusong",faction = "hejin",        region = "luoyang",  state = "active", loyalty = 70 },
      { id = "zhujun",     faction = "hejin",        region = "hongnong", state = "active", loyalty = 72 },
      { id = "lvzhi",      faction = "hejin",        region = "chenliu",  state = "active", loyalty = 75 },
      { id = "wangyun",    faction = "hejin",        region = "xuchang",  state = "active", loyalty = 80 },
      { id = "caiyong",    faction = "hejin",        region = "luoyang",  state = "active", loyalty = 68 },
      -- 정원(병주) — 여포·장료가 휘하
      { id = "dingyuan",   faction = "dingyuan",     region = "jinyang",  state = "active" },
      { id = "lvbu",       faction = "dingyuan",     region = "jinyang",  state = "active", loyalty = 60 },
      { id = "zhangliao",  faction = "dingyuan",     region = "jinyang",  state = "active", loyalty = 78 },
      -- 공손찬
      { id = "gongsunzan", faction = "gongsunzan",   region = "beiping",  state = "active" },
      -- 손견(강동·형남)
      { id = "sunjian",    faction = "sunjian",      region = "changsha", state = "active" },
      { id = "huanggai",   faction = "sunjian",      region = "wuling",   state = "active", loyalty = 90 },
      { id = "hanang",     faction = "sunjian",      region = "jiangling",state = "active", loyalty = 85 },
      { id = "chengpu",    faction = "sunjian",      region = "xiangyang",state = "active", loyalty = 82 },

      -- 재야(free) — 훗날의 군웅·맹장이 아직 무명으로 흩어져 있다.
      { id = "caocao",     region = "chenliu",   state = "free" },
      { id = "xiahoudun",  region = "chenliu",   state = "free" },
      { id = "liubei",     region = "pingyuan",  state = "free" },
      { id = "guanyu",     region = "pingyuan",  state = "free" },
      { id = "zhangfei",   region = "pingyuan",  state = "free" },
      { id = "jianyong",   region = "pingyuan",  state = "free" },
      { id = "yuanshao",   region = "luoyang",   state = "free" },
      { id = "chunyuqiong",region = "luoyang",   state = "free" },
      { id = "yuanshu",    region = "luoyang",   state = "free" },
      { id = "liubiao",    region = "xiangyang", state = "free" },
      { id = "taoqian",    region = "xiapi",     state = "free" },
      { id = "zhangmiao",  region = "chenliu",   state = "free" },
      { id = "kongrong",   region = "pingyuan",  state = "free" },
      { id = "baoxin",     region = "puyang",    state = "free" },
      { id = "wangkuang",  region = "ye",        state = "free" },
      { id = "liudai",     region = "puyang",    state = "free" },
      { id = "zhangyang",  region = "jinyang",   state = "free" },
      { id = "huatuo",     region = "xiapi",     state = "free" },
      { id = "zuoci",      region = "luoyang",   state = "free" },
      { id = "simahui",    region = "xiangyang", state = "free" },
      { id = "chengui",    region = "xiapi",     state = "free" },
      { id = "liuyu",      region = "beiping",   state = "free" },
    },
  },

  -- ② 194 군웅할거 — 천하 분열, 군벌 11세력
  {
    id = "warlords", name = "군웅할거", year = 194, startMonth = 1,
    factions = {
      yuanshao   = { name = "원소",       color = { 0.55, 0.32, 0.72 }, lord = "yuanshao"   }, -- 보라
      gongsunzan = { name = "공손찬",     color = { 0.30, 0.68, 0.70 }, lord = "gongsunzan" }, -- 청록
      caocao     = { name = "조조",       color = { 0.20, 0.45, 0.90 }, lord = "caocao"     }, -- 파랑
      taoqian    = { name = "도겸·유비",  color = { 0.50, 0.55, 0.45 }, lord = "liubei"     }, -- 올리브(도겸 사후 유비 인수)
      licaoguo   = { name = "이각·곽사",  color = { 0.62, 0.50, 0.32 }, lord = "lijue"      }, -- 갈
      mateng     = { name = "마등·한수",  color = { 0.92, 0.58, 0.20 }, lord = "mateng"     }, -- 주황
      yuanshu    = { name = "원술",       color = { 0.80, 0.32, 0.55 }, lord = "yuanshu"    }, -- 자홍
      liubiao    = { name = "유표",       color = { 0.30, 0.58, 0.82 }, lord = "liubiao"    }, -- 하늘
      sunce      = { name = "손책",       color = { 0.85, 0.25, 0.25 }, lord = "sunce"      }, -- 빨강
      liuzhang   = { name = "유장",       color = { 0.45, 0.72, 0.42 }, lord = "liuzhang"   }, -- 연두
      zhanglu    = { name = "장로",       color = { 0.85, 0.78, 0.30 }, lord = "zhanglu"    }, -- 노랑
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
    -- 장수 초기 배치 (GDD 4·7장). 184 의 무명 영웅들이 이제 각 세력에 자리잡았다.
    officers = {
      -- 원소(하북)
      { id = "yuanshao",   faction = "yuanshao",   region = "ye",       state = "active" },
      { id = "juju",       faction = "yuanshao",   region = "ye",       state = "active", loyalty = 88 },
      { id = "tianfeng",   faction = "yuanshao",   region = "ye",       state = "active", loyalty = 85 },
      { id = "shenpei",    faction = "yuanshao",   region = "bohai",    state = "active", loyalty = 88 },
      { id = "fengji",     faction = "yuanshao",   region = "pingyuan", state = "active", loyalty = 80 },
      { id = "guotu",      faction = "yuanshao",   region = "ye",       state = "active", loyalty = 75 },
      { id = "xunchen",    faction = "yuanshao",   region = "bohai",    state = "active", loyalty = 82 },
      { id = "xinping",    faction = "yuanshao",   region = "pingyuan", state = "active", loyalty = 78 },
      { id = "zhanghe",    faction = "yuanshao",   region = "ye",       state = "active", loyalty = 85 },
      { id = "chunyuqiong",faction = "yuanshao",   region = "ye",       state = "active", loyalty = 80 },
      -- 공손찬(유주)
      { id = "gongsunzan", faction = "gongsunzan", region = "beiping",  state = "active" },
      { id = "zhaoyun",    faction = "gongsunzan", region = "beiping",  state = "active", loyalty = 70 },
      -- 조조(연주·예주)
      { id = "caocao",     faction = "caocao",     region = "puyang",   state = "active" },
      { id = "xiahoudun",  faction = "caocao",     region = "puyang",   state = "active", loyalty = 95 },
      { id = "xiahouyuan", faction = "caocao",     region = "puyang",   state = "active", loyalty = 92 },
      { id = "caoren",     faction = "caocao",     region = "chenliu",  state = "active", loyalty = 93 },
      { id = "caohong",    faction = "caocao",     region = "chenliu",  state = "active", loyalty = 90 },
      { id = "dianwei",    faction = "caocao",     region = "puyang",   state = "active", loyalty = 88 },
      { id = "xunyu",      faction = "caocao",     region = "xuchang",  state = "active", loyalty = 92 },
      { id = "xunyou",     faction = "caocao",     region = "xuchang",  state = "active", loyalty = 88 },
      { id = "chengyu",    faction = "caocao",     region = "puyang",   state = "active", loyalty = 85 },
      { id = "yuejin",     faction = "caocao",     region = "chenliu",  state = "active", loyalty = 80 },
      { id = "lidian",     faction = "caocao",     region = "chenliu",  state = "active", loyalty = 78 },
      { id = "yujin",      faction = "caocao",     region = "xuchang",  state = "active", loyalty = 78 },
      { id = "manchong",   faction = "caocao",     region = "xuchang",  state = "active", loyalty = 78 },
      { id = "hanhao",     faction = "caocao",     region = "puyang",   state = "active", loyalty = 72 },
      { id = "zhuling",    faction = "caocao",     region = "chenliu",  state = "active", loyalty = 72 },
      -- 도겸·유비(서주)
      { id = "liubei",     faction = "taoqian",    region = "xiapi",    state = "active" },
      { id = "guanyu",     faction = "taoqian",    region = "xiapi",    state = "active", loyalty = 95 },
      { id = "zhangfei",   faction = "taoqian",    region = "pengcheng",state = "active", loyalty = 95 },
      { id = "jianyong",   faction = "taoqian",    region = "xiapi",    state = "active", loyalty = 85 },
      { id = "mizhu",      faction = "taoqian",    region = "xiapi",    state = "active", loyalty = 80 },
      { id = "mifang",     faction = "taoqian",    region = "pengcheng",state = "active", loyalty = 75 },
      { id = "sunqian",    faction = "taoqian",    region = "xiapi",    state = "active", loyalty = 82 },
      { id = "taoqian",    faction = "taoqian",    region = "pengcheng",state = "active", loyalty = 70 },
      { id = "chenden",    faction = "taoqian",    region = "xiapi",    state = "active", loyalty = 72 },
      { id = "chengui",    faction = "taoqian",    region = "pengcheng",state = "active", loyalty = 72 },
      { id = "kongrong",   faction = "taoqian",    region = "guangling",state = "active", loyalty = 60 },
      -- 이각·곽사(관중)
      { id = "lijue",      faction = "licaoguo",   region = "changan",  state = "active" },
      { id = "guosi",      faction = "licaoguo",   region = "changan",  state = "active", loyalty = 80 },
      { id = "zhangji",    faction = "licaoguo",   region = "hongnong", state = "active", loyalty = 70 },
      { id = "fanchou",    faction = "licaoguo",   region = "changan",  state = "active", loyalty = 65 },
      { id = "niufu",      faction = "licaoguo",   region = "hongnong", state = "active", loyalty = 65 },
      { id = "liru",       faction = "licaoguo",   region = "changan",  state = "active", loyalty = 80 },
      { id = "jiaxu",      faction = "licaoguo",   region = "changan",  state = "active", loyalty = 60 },
      -- 마등·한수(서량)
      { id = "mateng",     faction = "mateng",     region = "tianshui", state = "active" },
      { id = "hansui",     faction = "mateng",     region = "wuwei",    state = "active", loyalty = 70 },
      -- 원술(회남·여남)
      { id = "yuanshu",    faction = "yuanshu",    region = "runan",    state = "active" },
      { id = "jiling",     faction = "yuanshu",    region = "runan",    state = "active", loyalty = 82 },
      -- 유표(형주)
      { id = "liubiao",    faction = "liubiao",    region = "xiangyang",state = "active" },
      { id = "huangzu",    faction = "liubiao",    region = "jiangling",state = "active", loyalty = 80 },
      { id = "caimao",     faction = "liubiao",    region = "xiangyang",state = "active", loyalty = 75 },
      { id = "kuailiang",  faction = "liubiao",    region = "xiangyang",state = "active", loyalty = 82 },
      { id = "kuaiyue",    faction = "liubiao",    region = "xiangyang",state = "active", loyalty = 84 },
      { id = "huangzhong", faction = "liubiao",    region = "changsha", state = "active", loyalty = 80 },
      -- 손책(강동)
      { id = "sunce",      faction = "sunce",      region = "jianye",   state = "active" },
      { id = "huanggai",   faction = "sunce",      region = "wujun",    state = "active", loyalty = 90 },
      { id = "hanang",     faction = "sunce",      region = "kuaiji",   state = "active", loyalty = 85 },
      { id = "chengpu",    faction = "sunce",      region = "chaisang", state = "active", loyalty = 85 },
      { id = "sunjing",    faction = "sunce",      region = "wujun",    state = "active", loyalty = 80 },
      -- 유장(익주)
      { id = "liuzhang",   faction = "liuzhang",   region = "chengdu",  state = "active" },
      { id = "yanyan",     faction = "liuzhang",   region = "jiangzhou",state = "active", loyalty = 75 },
      { id = "zhangren",   faction = "liuzhang",   region = "chengdu",  state = "active", loyalty = 80 },
      -- 장로(한중)
      { id = "zhanglu",    faction = "zhanglu",    region = "hanzhong", state = "active" },
      { id = "yangsong",   faction = "zhanglu",    region = "hanzhong", state = "active", loyalty = 60 },

      -- 재야(free) — 여포 일당은 연주를 침범해 떠돌고, 명사들은 곳곳에 숨어 있다.
      { id = "lvbu",       region = "puyang",    state = "free" },
      { id = "chengong",   region = "puyang",    state = "free" },
      { id = "gaoshun",    region = "puyang",    state = "free" },
      { id = "zangba",     region = "pengcheng", state = "free" },
      { id = "songxian",   region = "puyang",    state = "free" },
      { id = "weixu",      region = "puyang",    state = "free" },
      { id = "houcheng",   region = "puyang",    state = "free" },
      { id = "xuhuang",    region = "luoyang",   state = "free" },
      { id = "taishici",   region = "jianye",    state = "free" },
      { id = "huaxin",     region = "kuaiji",    state = "free" },
      { id = "wanglang",   region = "kuaiji",    state = "free" },
      { id = "chenqun",    region = "xiapi",     state = "free" },
      { id = "zhongyou",   region = "changan",   state = "free" },
      { id = "huatuo",     region = "xiapi",     state = "free" },
      { id = "zuoci",      region = "luoyang",   state = "free" },
      { id = "simahui",    region = "xiangyang", state = "free" },
      { id = "huangfusong",region = "changan",   state = "free" },
      { id = "zhujun",     region = "luoyang",   state = "free" },
      { id = "tianchou",   region = "beiping",   state = "free" },
    },
  },

  -- ③ 221 삼국 정립 — 위·촉·오 (+ 변경 중립)
  {
    id = "three_kingdoms", name = "삼국 정립", year = 221, startMonth = 1,
    factions = {
      wei = { name = "위(조비)", color = { 0.20, 0.45, 0.90 }, lord = "caopi"   }, -- 파랑
      shu = { name = "촉(유비)", color = { 0.20, 0.70, 0.35 }, lord = "liubei"  }, -- 초록
      wu  = { name = "오(손권)", color = { 0.85, 0.25, 0.25 }, lord = "sunquan" }, -- 빨강
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
    -- 장수 초기 배치 (GDD 4·7장). 삼국 정립기 — 1세대 군웅은 떠나고 위·촉·오 3국이 굳었다.
    --   변경 중립 지역(무위·천수·하비 등)은 장수 없이 비어 있을 수 있다(GDD: 지역 0명 허용).
    officers = {
      -- 위(조비) — 북부·중원
      { id = "caopi",      faction = "wei", region = "luoyang",  state = "active" },
      { id = "caoren",     faction = "wei", region = "xuchang",  state = "active", loyalty = 88 },
      { id = "caohong",    faction = "wei", region = "chenliu",  state = "active", loyalty = 82 },
      { id = "caozhen",    faction = "wei", region = "changan",  state = "active", loyalty = 85 },
      { id = "caoxiu",     faction = "wei", region = "runan",    state = "active", loyalty = 82 },
      { id = "caochun",    faction = "wei", region = "ye",       state = "active", loyalty = 80 },
      { id = "zhanghe",    faction = "wei", region = "changan",  state = "active", loyalty = 82 },
      { id = "xuhuang",    faction = "wei", region = "luoyang",  state = "active", loyalty = 84 },
      { id = "zhangliao",  faction = "wei", region = "xuchang",  state = "active", loyalty = 85 },
      { id = "yujin",      faction = "wei", region = "luoyang",  state = "active", loyalty = 60 },
      { id = "wenpin",     faction = "wei", region = "runan",    state = "active", loyalty = 80 },
      { id = "guohuai",    faction = "wei", region = "changan",  state = "active", loyalty = 80 },
      { id = "jiaxu",      faction = "wei", region = "luoyang",  state = "active", loyalty = 78 },
      { id = "simayi",     faction = "wei", region = "luoyang",  state = "active", loyalty = 80 },
      { id = "jiakui",     faction = "wei", region = "chenliu",  state = "active", loyalty = 82 },
      { id = "manchong",   faction = "wei", region = "xuchang",  state = "active", loyalty = 80 },
      { id = "tianyu",     faction = "wei", region = "beiping",  state = "active", loyalty = 78 },
      { id = "dongzhao",   faction = "wei", region = "luoyang",  state = "active", loyalty = 80 },
      { id = "liuye",      faction = "wei", region = "luoyang",  state = "active", loyalty = 82 },
      { id = "chenqun",    faction = "wei", region = "luoyang",  state = "active", loyalty = 85 },
      { id = "huaxin",     faction = "wei", region = "luoyang",  state = "active", loyalty = 82 },
      { id = "wanglang",   faction = "wei", region = "luoyang",  state = "active", loyalty = 82 },
      { id = "zhongyou",   faction = "wei", region = "changan",  state = "active", loyalty = 84 },
      { id = "caozhi",     faction = "wei", region = "ye",       state = "active", loyalty = 70 },
      { id = "xinpi",      faction = "wei", region = "ye",       state = "active", loyalty = 80 },
      { id = "zangba",     faction = "wei", region = "xuchang",  state = "active", loyalty = 70 },
      { id = "hanhao",     faction = "wei", region = "puyang",   state = "active", loyalty = 72 },
      -- 촉(유비) — 익주·한중
      { id = "liubei",     faction = "shu", region = "chengdu",  state = "active" },
      { id = "zhugeliang", faction = "shu", region = "chengdu",  state = "active", loyalty = 98 },
      { id = "zhaoyun",    faction = "shu", region = "chengdu",  state = "active", loyalty = 92 },
      { id = "machao",     faction = "shu", region = "hanzhong", state = "active", loyalty = 80 },
      { id = "weiyan",     faction = "shu", region = "hanzhong", state = "active", loyalty = 78 },
      { id = "masu",       faction = "shu", region = "chengdu",  state = "active", loyalty = 82 },
      { id = "maliang",    faction = "shu", region = "chengdu",  state = "active", loyalty = 88 },
      { id = "jiangwan",   faction = "shu", region = "chengdu",  state = "active", loyalty = 88 },
      { id = "feiyi",      faction = "shu", region = "chengdu",  state = "active", loyalty = 85 },
      { id = "dongyun",    faction = "shu", region = "chengdu",  state = "active", loyalty = 85 },
      { id = "huangquan",  faction = "shu", region = "jiangzhou",state = "active", loyalty = 78 },
      { id = "wuyi",       faction = "shu", region = "hanzhong", state = "active", loyalty = 75 },
      { id = "liaohua",    faction = "shu", region = "hanzhong", state = "active", loyalty = 80 },
      { id = "guanxing",   faction = "shu", region = "chengdu",  state = "active", loyalty = 88 },
      { id = "jianyong",   faction = "shu", region = "chengdu",  state = "active", loyalty = 85 },
      { id = "chenzhen",   faction = "shu", region = "chengdu",  state = "active", loyalty = 82 },
      { id = "yanyan",     faction = "shu", region = "jiangzhou",state = "active", loyalty = 75 },
      -- 오(손권) — 강동
      { id = "sunquan",    faction = "wu",  region = "jianye",   state = "active" },
      { id = "luxun",      faction = "wu",  region = "jianye",   state = "active", loyalty = 88 },
      { id = "zhuran",     faction = "wu",  region = "jianye",   state = "active", loyalty = 82 },
      { id = "xusheng",    faction = "wu",  region = "jianye",   state = "active", loyalty = 80 },
      { id = "dingfeng",   faction = "wu",  region = "wujun",    state = "active", loyalty = 78 },
      { id = "panzhang",   faction = "wu",  region = "chaisang", state = "active", loyalty = 72 },
      { id = "zhoutai",    faction = "wu",  region = "wujun",    state = "active", loyalty = 85 },
      { id = "hanang",     faction = "wu",  region = "kuaiji",   state = "active", loyalty = 88 },
      { id = "zhugejin",   faction = "wu",  region = "jianye",   state = "active", loyalty = 88 },
      { id = "zhangzhao",  faction = "wu",  region = "jianye",   state = "active", loyalty = 85 },
      { id = "guyong",     faction = "wu",  region = "jianye",   state = "active", loyalty = 85 },
      { id = "ganze",      faction = "wu",  region = "jianye",   state = "active", loyalty = 80 },
      { id = "buzhi",      faction = "wu",  region = "jianye",   state = "active", loyalty = 80 },
      { id = "mifang",     faction = "wu",  region = "jianye",   state = "active", loyalty = 50 }, -- 형주 함락 때 오에 투항

      -- 재야(free) — 변경에 숨은 방랑 인물.
      { id = "zuoci",      region = "tianshui", state = "free" },
      { id = "chengyi",    region = "wuwei",    state = "free" },
    },
  },
}

return game_data
