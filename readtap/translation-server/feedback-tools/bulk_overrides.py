#!/usr/bin/env python3
"""Bulk-insert curated overrides for common English words that Wiktionary
underserves. These are high-confidence, canonical translations hand-
written by a native Korean speaker — NOT user-reported feedback.

Run once to seed, or re-run after editing the CURATED list below.
Idempotent via UNIQUE(word, lang_pair, pos, meaning) + INSERT OR IGNORE.
"""
import subprocess
import sys

# Format: (word, pos, [korean_meanings...])
# Keep meanings concise (1-4 chars ideally, match popup display style).
# Order: most common meaning first.
CURATED = [
    # Spatial / directional
    ("back", "adverb", ["뒤로", "되돌아"]),
    ("back", "noun", ["등", "뒷면"]),
    ("back", "adjective", ["뒤의", "뒤쪽의"]),
    ("front", "noun", ["앞", "앞면", "전면"]),
    ("front", "adjective", ["앞의", "전방의"]),
    ("side", "noun", ["측면", "옆", "쪽"]),
    ("top", "noun", ["꼭대기", "맨 위", "상단"]),
    ("top", "adjective", ["최고의", "맨 위의"]),
    ("bottom", "noun", ["바닥", "밑", "아래쪽"]),
    ("up", "adverb", ["위로", "위쪽으로"]),
    ("down", "adverb", ["아래로", "아래쪽으로"]),
    ("left", "noun", ["왼쪽"]),
    ("right", "adjective", ["오른쪽의", "옳은", "맞는"]),
    ("middle", "noun", ["중간", "가운데"]),
    ("near", "adjective", ["가까운", "근처의"]),
    ("far", "adverb", ["멀리", "훨씬"]),
    ("inside", "noun", ["안쪽", "내부"]),
    ("outside", "noun", ["바깥쪽", "외부"]),

    # High-frequency verbs
    ("look", "verb", ["보다", "바라보다", "쳐다보다"]),
    ("think", "verb", ["생각하다", "여기다"]),
    ("see", "verb", ["보다", "만나다", "이해하다"]),
    ("feel", "verb", ["느끼다", "만지다"]),
    ("find", "verb", ["찾다", "발견하다"]),
    ("get", "verb", ["얻다", "받다", "가져오다"]),
    ("give", "verb", ["주다", "제공하다"]),
    ("take", "verb", ["가지다", "취하다", "데려가다"]),
    ("make", "verb", ["만들다", "하다", "~하게 하다"]),
    ("have", "verb", ["가지다", "있다", "먹다"]),
    ("go", "verb", ["가다"]),
    ("come", "verb", ["오다"]),
    ("bring", "verb", ["가져오다", "데려오다"]),
    ("keep", "verb", ["유지하다", "지키다", "계속하다"]),
    ("put", "verb", ["놓다", "두다"]),
    ("help", "verb", ["돕다", "도와주다"]),
    ("work", "verb", ["일하다", "작동하다"]),
    ("start", "verb", ["시작하다"]),
    ("stop", "verb", ["멈추다", "중단하다"]),
    ("wait", "verb", ["기다리다"]),
    ("talk", "verb", ["말하다", "이야기하다"]),
    ("say", "verb", ["말하다"]),
    ("tell", "verb", ["말하다", "알리다"]),
    ("ask", "verb", ["묻다", "부탁하다"]),
    ("answer", "verb", ["대답하다", "답하다"]),
    ("open", "verb", ["열다"]),
    ("close", "verb", ["닫다", "마치다"]),
    ("show", "verb", ["보여주다", "나타내다"]),
    ("move", "verb", ["움직이다", "이동하다"]),
    ("turn", "verb", ["돌리다", "바뀌다"]),
    ("run", "verb", ["달리다", "운영하다"]),
    ("walk", "verb", ["걷다"]),
    ("sit", "verb", ["앉다"]),
    ("stand", "verb", ["서다", "서있다"]),
    ("hold", "verb", ["잡다", "쥐다"]),
    ("need", "verb", ["필요하다", "요구하다"]),
    ("want", "verb", ["원하다", "바라다"]),
    ("love", "verb", ["사랑하다"]),
    ("like", "verb", ["좋아하다"]),
    ("know", "verb", ["알다"]),
    ("believe", "verb", ["믿다"]),
    ("remember", "verb", ["기억하다"]),
    ("forget", "verb", ["잊다"]),
    ("learn", "verb", ["배우다", "학습하다"]),
    ("read", "verb", ["읽다"]),
    ("write", "verb", ["쓰다", "적다"]),
    ("understand", "verb", ["이해하다"]),
    ("try", "verb", ["시도하다", "노력하다"]),
    ("use", "verb", ["사용하다", "쓰다"]),
    ("change", "verb", ["바꾸다", "변화하다"]),
    ("meet", "verb", ["만나다"]),
    ("leave", "verb", ["떠나다", "남기다"]),
    ("arrive", "verb", ["도착하다"]),
    ("live", "verb", ["살다", "거주하다"]),
    ("eat", "verb", ["먹다"]),
    ("drink", "verb", ["마시다"]),
    ("sleep", "verb", ["자다", "잠자다"]),

    # High-frequency adjectives
    ("good", "adjective", ["좋은", "훌륭한"]),
    ("bad", "adjective", ["나쁜", "좋지 않은"]),
    ("big", "adjective", ["큰", "커다란"]),
    ("small", "adjective", ["작은", "조그만"]),
    ("long", "adjective", ["긴", "오랜"]),
    ("short", "adjective", ["짧은", "키 작은"]),
    ("high", "adjective", ["높은"]),
    ("low", "adjective", ["낮은"]),
    ("hot", "adjective", ["뜨거운", "더운"]),
    ("cold", "adjective", ["차가운", "추운"]),
    ("new", "adjective", ["새로운", "새"]),
    ("old", "adjective", ["오래된", "늙은", "낡은"]),
    ("young", "adjective", ["젊은", "어린"]),
    ("fast", "adjective", ["빠른"]),
    ("slow", "adjective", ["느린"]),
    ("easy", "adjective", ["쉬운"]),
    ("hard", "adjective", ["어려운", "단단한", "힘든"]),
    ("difficult", "adjective", ["어려운", "힘든"]),
    ("simple", "adjective", ["간단한", "단순한"]),
    ("important", "adjective", ["중요한"]),
    ("beautiful", "adjective", ["아름다운", "예쁜"]),
    ("happy", "adjective", ["행복한", "기쁜"]),
    ("sad", "adjective", ["슬픈"]),
    ("angry", "adjective", ["화난", "성난"]),
    ("tired", "adjective", ["피곤한", "지친"]),
    ("busy", "adjective", ["바쁜"]),
    ("free", "adjective", ["자유로운", "무료의"]),
    ("safe", "adjective", ["안전한"]),
    ("true", "adjective", ["사실인", "참된"]),
    ("false", "adjective", ["거짓의", "틀린"]),
    ("right", "adverb", ["바로", "정확히"]),
    ("wrong", "adjective", ["틀린", "잘못된"]),

    # Position / order
    ("first", "adjective", ["첫 번째의", "최초의"]),
    ("last", "adjective", ["마지막의", "지난"]),
    ("next", "adjective", ["다음의"]),
    ("previous", "adjective", ["이전의", "앞의"]),
    ("main", "adjective", ["주된", "주요한"]),
    ("only", "adjective", ["유일한", "단 하나의"]),

    # Time
    ("today", "noun", ["오늘"]),
    ("yesterday", "noun", ["어제"]),
    ("tomorrow", "noun", ["내일"]),
    ("morning", "noun", ["아침", "오전"]),
    ("afternoon", "noun", ["오후"]),
    ("evening", "noun", ["저녁"]),
    ("night", "noun", ["밤"]),
    ("week", "noun", ["주", "일주일"]),
    ("month", "noun", ["달", "월"]),
    ("year", "noun", ["년", "해"]),
    ("time", "noun", ["시간", "때"]),
    ("now", "adverb", ["지금", "이제"]),
    ("soon", "adverb", ["곧", "머지않아"]),
    ("later", "adverb", ["나중에", "이후에"]),
    ("before", "preposition", ["~전에"]),
    ("after", "preposition", ["~후에"]),
    ("always", "adverb", ["항상", "언제나"]),
    ("never", "adverb", ["결코 ~않다", "절대"]),
    ("sometimes", "adverb", ["때때로", "가끔"]),
    ("often", "adverb", ["자주", "종종"]),

    # Quantity
    ("all", "determiner", ["모든", "전부의"]),
    ("some", "determiner", ["몇몇의", "약간의"]),
    ("many", "determiner", ["많은"]),
    ("few", "determiner", ["거의 없는", "소수의"]),
    ("most", "determiner", ["대부분의", "가장"]),
    ("every", "determiner", ["모든", "매~"]),
    ("each", "determiner", ["각각의", "각자의"]),
    ("both", "determiner", ["둘 다", "양쪽의"]),
    ("enough", "adjective", ["충분한"]),
    ("more", "adjective", ["더 많은", "더"]),
    ("less", "adjective", ["더 적은"]),

    # People / relationships
    ("person", "noun", ["사람"]),
    ("people", "noun", ["사람들"]),
    ("man", "noun", ["남자", "사람"]),
    ("woman", "noun", ["여자"]),
    ("child", "noun", ["아이", "어린이"]),
    ("boy", "noun", ["소년", "남자아이"]),
    ("girl", "noun", ["소녀", "여자아이"]),
    ("family", "noun", ["가족"]),
    ("friend", "noun", ["친구"]),
    ("parent", "noun", ["부모"]),
    ("father", "noun", ["아버지", "아빠"]),
    ("mother", "noun", ["어머니", "엄마"]),
    ("brother", "noun", ["형", "오빠", "남동생"]),
    ("sister", "noun", ["누나", "언니", "여동생"]),

    # Body
    ("head", "noun", ["머리"]),
    ("face", "noun", ["얼굴"]),
    ("eye", "noun", ["눈"]),
    ("ear", "noun", ["귀"]),
    ("nose", "noun", ["코"]),
    ("mouth", "noun", ["입"]),
    ("hand", "noun", ["손"]),
    ("foot", "noun", ["발"]),
    ("arm", "noun", ["팔"]),
    ("leg", "noun", ["다리"]),

    # Core nouns
    ("day", "noun", ["날", "하루"]),
    ("thing", "noun", ["것", "물건"]),
    ("way", "noun", ["방법", "길"]),
    ("life", "noun", ["삶", "생명", "생활"]),
    ("world", "noun", ["세계", "세상"]),
    ("place", "noun", ["장소", "곳"]),
    ("home", "noun", ["집", "가정"]),
    ("house", "noun", ["집"]),
    ("school", "noun", ["학교"]),
    ("job", "noun", ["직업", "일"]),
    ("money", "noun", ["돈"]),
    ("food", "noun", ["음식"]),
    ("water", "noun", ["물"]),
    ("book", "noun", ["책"]),
    ("car", "noun", ["자동차", "차"]),
    ("city", "noun", ["도시"]),
    ("country", "noun", ["나라", "국가", "시골"]),

    # WH-words / question words. Most had partial seed coverage but with
    # weird artifacts (-지만, 하처, 아무튼). Overrides lead, cleaning up
    # what users see.
    ("where", "adverb", ["어디", "어디에"]),
    ("where", "conjunction", ["~하는 곳"]),
    ("which", "determiner", ["어느", "어떤"]),
    ("which", "pronoun", ["어느 것"]),
    ("what", "pronoun", ["무엇", "뭐"]),
    ("what", "determiner", ["어떤"]),
    ("that", "determiner", ["그", "저"]),
    ("that", "pronoun", ["그것"]),
    ("whom", "pronoun", ["누구를", "누구에게"]),
    ("these", "pronoun", ["이것들"]),
    ("these", "determiner", ["이", "이러한"]),
    ("those", "pronoun", ["그것들", "저것들"]),
    ("those", "determiner", ["그"]),
    ("so", "conjunction", ["그래서", "그러므로"]),
    ("so", "adverb", ["그렇게"]),
    ("yes", "interjection", ["네", "예"]),
    ("no", "interjection", ["아니요", "아니"]),
    ("no", "determiner", ["~없는"]),

    # Personal pronouns — obvious gap since Wiktionary rarely fills
    # single-letter or very short entries well.
    ("i", "pronoun", ["나", "저"]),
    ("you", "pronoun", ["너", "당신"]),
    ("he", "pronoun", ["그"]),
    ("she", "pronoun", ["그녀"]),
    ("it", "pronoun", ["그것"]),
    ("we", "pronoun", ["우리"]),
    ("they", "pronoun", ["그들"]),

    # Prepositions. Kaikki seed had multiple of these wrong
    # (`about → 거꾸로`, `over → 나누기`) — override leads.
    ("into", "preposition", ["~안으로", "~속으로"]),
    ("onto", "preposition", ["~위로"]),
    ("beyond", "preposition", ["~너머", "~을 넘어"]),
    ("about", "preposition", ["~에 관하여", "~에 대해"]),
    ("about", "adverb", ["약", "대략"]),
    ("over", "preposition", ["~위에", "~을 넘어"]),
    ("over", "adjective", ["끝난"]),
    ("across", "preposition", ["~을 가로질러", "~건너편에"]),
    ("toward", "preposition", ["~쪽으로", "~을 향해"]),

    # Conjunctions
    ("whereas", "conjunction", ["~인 반면", "한편"]),
    ("though", "conjunction", ["~이지만", "비록 ~이더라도"]),
    ("nor", "conjunction", ["~도 아니다"]),

    # Common adverbs with wrong/narrow seed senses
    ("just", "adverb", ["단지", "그냥", "방금", "막"]),
    ("even", "adverb", ["~조차", "심지어"]),
    ("even", "adjective", ["평평한"]),
    ("meanwhile", "adverb", ["한편", "그사이에"]),
    ("otherwise", "adverb", ["그렇지 않으면", "다르게"]),

    # Modal verbs. Seed has noun/letter senses as top
    # (can → 깡통/캔, may → 오월, might → 위력).
    ("can", "verb", ["~할 수 있다", "~해도 된다"]),
    ("could", "verb", ["~할 수 있었다", "~할 수 있을 것이다"]),
    ("may", "verb", ["~일지 모른다", "~해도 된다"]),
    ("might", "verb", ["~일지도 모른다"]),
    ("would", "verb", ["~일 것이다", "~하곤 했다"]),
    ("should", "verb", ["~해야 한다", "~하는 것이 좋다"]),
    ("must", "verb", ["~해야 한다", "~임에 틀림없다"]),
    ("will", "verb", ["~일 것이다", "~하겠다"]),
    ("ought", "verb", ["~해야 한다"]),

    # Articles. `the → -을수록` was embarrassing.
    ("a", "article", ["하나의", "어떤"]),
    ("an", "article", ["하나의", "어떤"]),
    ("the", "article", ["그", "해당"]),

    # Numbers — canonical form first
    ("one", "numeral", ["하나", "일"]),
    ("two", "numeral", ["둘"]),
    ("three", "numeral", ["셋"]),
    ("four", "numeral", ["넷"]),
    ("five", "numeral", ["다섯"]),
    ("six", "numeral", ["여섯"]),
    ("seven", "numeral", ["일곱"]),
    ("eight", "numeral", ["여덟"]),
    ("nine", "numeral", ["아홉"]),
    ("ten", "numeral", ["열"]),
    ("hundred", "numeral", ["백"]),
    ("thousand", "numeral", ["천"]),
    ("million", "numeral", ["백만"]),

    # Days of week (strip -에 locative suffix)
    ("monday", "noun", ["월요일"]),
    ("tuesday", "noun", ["화요일"]),
    ("wednesday", "noun", ["수요일"]),
    ("thursday", "noun", ["목요일"]),
    ("friday", "noun", ["금요일"]),
    ("saturday", "noun", ["토요일"]),
    ("sunday", "noun", ["일요일"]),

    # Months (march seed had only the verb sense; forced numeric form)
    ("january", "noun", ["1월"]),
    ("february", "noun", ["2월"]),
    ("march", "noun", ["3월"]),
    ("march", "verb", ["행진하다"]),
    ("april", "noun", ["4월"]),
    ("may", "noun", ["5월"]),
    ("june", "noun", ["6월"]),
    ("july", "noun", ["7월"]),
    ("august", "noun", ["8월"]),
    ("september", "noun", ["9월"]),
    ("october", "noun", ["10월"]),
    ("november", "noun", ["11월"]),
    ("december", "noun", ["12월"]),

    # Colors. Yellow especially had the "cowardly" sense as top — wrong
    # default for a reading-assist app.
    ("red", "adjective", ["빨간"]),
    ("red", "noun", ["빨강"]),
    ("blue", "adjective", ["파란"]),
    ("blue", "noun", ["파랑"]),
    ("green", "adjective", ["초록의"]),
    ("green", "noun", ["초록"]),
    ("yellow", "adjective", ["노란"]),
    ("yellow", "noun", ["노랑"]),
    ("black", "adjective", ["검은"]),
    ("black", "noun", ["검정"]),
    ("white", "adjective", ["흰"]),
    ("white", "noun", ["하양"]),
    ("brown", "adjective", ["갈색의"]),
    ("orange", "noun", ["오렌지"]),
    ("orange", "adjective", ["주황색의"]),
    ("purple", "adjective", ["보라색의"]),
    ("pink", "adjective", ["분홍색의"]),
    ("gray", "adjective", ["회색의"]),

    # Verbs with wrong narrow senses
    ("cook", "verb", ["요리하다"]),
    ("save", "verb", ["저장하다", "절약하다", "구하다"]),
    ("break", "verb", ["깨다", "부러뜨리다"]),
    ("break", "noun", ["휴식"]),
    ("clean", "adjective", ["깨끗한"]),
    ("clean", "verb", ["청소하다"]),
    ("phone", "noun", ["전화", "전화기"]),

    # Nature (fix wind = 숨, add moon/sun/cloud canonicals)
    ("wind", "noun", ["바람"]),
    ("sun", "noun", ["태양", "해"]),
    ("moon", "noun", ["달"]),
    ("cloud", "noun", ["구름"]),
    ("rain", "noun", ["비"]),
    ("snow", "noun", ["눈"]),

    # Food (fix 살/젖/커피콩)
    ("meat", "noun", ["고기"]),
    ("milk", "noun", ["우유"]),
    ("coffee", "noun", ["커피"]),
    ("tea", "noun", ["차"]),
    ("fish", "noun", ["물고기", "생선"]),
    ("egg", "noun", ["달걀"]),
    ("bread", "noun", ["빵"]),
    ("rice", "noun", ["쌀", "밥"]),

    # Clothing (shoes was missing)
    ("shoes", "noun", ["신발"]),
    ("hat", "noun", ["모자"]),

    # Places (office → 의식/예배; store → 창고 only)
    ("office", "noun", ["사무실", "사무소"]),
    ("store", "noun", ["가게", "상점"]),
    ("store", "verb", ["저장하다"]),
    ("hospital", "noun", ["병원"]),
    ("park", "noun", ["공원"]),
    ("room", "noun", ["방", "공간"]),

    # Tech
    ("computer", "noun", ["컴퓨터"]),
    ("internet", "noun", ["인터넷"]),
    ("email", "noun", ["이메일"]),
    ("message", "noun", ["메시지"]),
]


def escape(s):
    return "'" + str(s).replace("'", "''") + "'"


def main():
    rows = []
    for word, pos, meanings in CURATED:
        for meaning in meanings:
            rows.append(
                f"(strftime('%s','now'), {escape(word)}, 'en-ko', {escape(pos)}, "
                f"{escape(meaning)}, 'curated-common', 'yun', NULL)"
            )

    print(f"preparing to INSERT {len(rows)} override rows "
          f"({len(CURATED)} unique (word, pos) pairs)",
          file=sys.stderr)

    # Chunk into batches of 200 to keep the SQL payload under wrangler's
    # command-length limit.
    BATCH = 200
    for i in range(0, len(rows), BATCH):
        chunk = rows[i:i+BATCH]
        sql = ("INSERT OR IGNORE INTO overrides "
               "(created_at, word, lang_pair, pos, meaning, source, "
               " approved_by, feedback_ids) VALUES\n  "
               + ",\n  ".join(chunk))
        print(f"[batch {i//BATCH + 1}] {len(chunk)} rows", file=sys.stderr)
        result = subprocess.run(
            ["npx", "wrangler", "d1", "execute", "readtap-dictionary",
             "--remote", "--json", "--command", sql],
            capture_output=True, text=True,
            cwd="/Users/yunminchae/Desktop/read_tap/readtap/translation-server",
            timeout=120,
        )
        if result.returncode != 0:
            print(f"[error] batch {i//BATCH + 1} failed:\n{result.stderr}",
                  file=sys.stderr)
            sys.exit(1)

    print(f"[done] inserted up to {len(rows)} override rows "
          f"(duplicates ignored)", file=sys.stderr)


if __name__ == "__main__":
    main()
