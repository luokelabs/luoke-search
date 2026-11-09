"""Folders as a real Mac has many of: lots of documents, a few pictures or recordings (evals/few-*.json).

    python3 -I scripts/testbed/make_few.py .dev/testbed-few        (macOS: sips, say, ffmpeg)

Makes four corpora that share the same 200 documents (100 Chinese, 100 English, written from templates with a fixed
seed, plus 20 written out by hand that the questions are about):
    img5/  img10/  img19/   the documents and 5, 10 or 19 of macOS's sample pictures (/Library/User Pictures)
    audio3/                 the documents and 3 short recordings in macOS's voices
Pictures and recordings have neutral names (IMG_3101.jpg, 20261012 091530.wav): what's asked about them can only be
found by what they show or say. The documents never name what the pictures show or what the recordings say (some
related words do appear: museum, train tickets, 证件照, eggs, a fridge's frost, a choir); each question's answer is only
in its own file.
Everything is generated; nothing is read from the user's files.
"""
import os
import random
import shutil
import subprocess
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else ".dev/testbed-few"
rng = random.Random(20261021)

# MARK: Pictures and recordings

# In the order they're added: img5 has the first 5, img10 the first 10, img19 all of them.
PICTURES = [
    ("Animals", "Owl"), ("Flowers", "Lotus"), ("Instruments", "Piano"), ("Nature", "Cactus"), ("Sports", "Bowling"),
    ("Animals", "Zebra"), ("Flowers", "Sunflower"), ("Fun", "Fortune Cookie"), ("Nature", "Snowflake"),
    ("Instruments", "Violin"),
    ("Animals", "Parrot"), ("Animals", "Penguin"), ("Flowers", "Red Rose"), ("Fun", "Gingerbread Man"),
    ("Fun", "Yin-Yang"), ("Instruments", "Turntable"), ("Nature", "Earth"), ("Nature", "Nest"), ("Sports", "Tennis"),
]
PICTURE_NAMES = ["IMG_%d.jpg" % (3101 + 7 * i) for i in range(len(PICTURES))]

RECORDINGS = [
    ("20261012 091530.wav", "Flo (Chinese (China mainland))", "明天上午十点去社区医院拿体检报告，记得带上身份证和医保卡。"),
    ("20261014 183002.wav", "Samantha", "Reminder: the plumber is coming on Thursday at nine to fix the leaking kitchen tap."),
    ("20261017 101245.wav", "Flo (Chinese (China mainland))", "周末带孩子去科技馆，门票要在小程序上提前预约，十二岁以下免费。"),
]

# MARK: The documents the questions are about

STANDOUT_EN = {
    "Lease renewal.md": "# Lease renewal\n\nThe landlord sent the renewal for the apartment on Alder Street. The rent goes up by 4 percent and the new lease starts on March 1. Parking space B-17 stays with us at no extra cost. We have to sign and return it before February 10.",
    "Kitchen renovation quote.txt": "Kitchen renovation quote from Harbor Woodworks: walnut cabinets, soft-close drawers and a quartz worktop, 18,400 in total including installation. Delivery takes about six weeks after the deposit is paid.",
    "Food bank volunteering.md": "# Food bank volunteering\n\nShifts are on Saturdays from 8 to 11 in the morning. Most of the work is sorting canned goods and packing boxes for families. The coordinator is Dana; text her if you can't make it.",
    "Laptop battery.txt": "The laptop battery is swelling and the trackpad no longer clicks. Booked a repair appointment at the store for October 30 at 2 pm. The serial number ends in 7QX. Back up everything before handing it in.",
    "Toast for Mei and Jonas.md": "# Toast for Mei and Jonas\n\nMy cousin Mei met Jonas in a second-hand bookshop when they reached for the same atlas. Start with that story, thank both families, keep it under three minutes and finish by raising a glass to the two of them.",
    "Tax notes 2026.txt": "Tax notes: the home office deduction is 12 percent of the rent, because the study takes 12 percent of the floor area. All receipts are scanned into the folder named 2026 taxes. Ask the accountant about the new laptop.",
    "Drip irrigation.md": "# Drip irrigation\n\nThe timer on the tomato beds runs the drip lines in three zones at 6 in the morning, 20 minutes each. Clean the filter every month and drain the lines before the first frost.",
    "Car insurance claim.txt": "Car insurance claim after the scrape in the supermarket parking lot: claim number CLM-55821, the deductible is 500. The adjuster wants two quotes from body shops and photos of the rear bumper.",
    "Japanese study plan.md": "# Japanese study plan\n\nGoal: pass the JLPT N4 exam in December. Thirty minutes of flashcards every morning, one chapter of the grammar book each week, and a conversation lesson online on Wednesday evenings.",
    "Database migration runbook.md": "# Database migration runbook\n\nMove the orders database to the new host on Saturday at 2 a.m. Put the app in read-only mode first, copy the data, check the row counts, then switch the connection string. Rollback: point the app back at the old host; it stays untouched for a week.",
}
STANDOUT_ZH = {
    "客厅刷墙报价.txt": "客厅刷乳胶漆，师傅老周报价 3200 元，含一遍底漆两遍面漆，家具由他们负责挪开盖好，工期三天。",
    "疫苗接种时间表.md": "# 疫苗接种\n\n下一针是 11 月 18 日打流脑疫苗，在街道卫生服务中心二楼，要带接种本。打完留观半小时。",
    "年会节目分工.md": "# 年会节目分工\n\n财务部出一个小品，研发部合唱，主持人是小林。第一次彩排在 1 月 10 日下午，地点在三楼大会议室。",
    "搬家清单.txt": "搬家清单：周六上午 8 点搬家公司到楼下，书装三只大纸箱，冰箱要提前一天断电化霜，钥匙交给物业前先抄好水电表。",
    "读书笔记 长夜的灯塔.md": "# 《长夜的灯塔》读书笔记\n\n第三章写守塔人在暴风雨里爬上塔顶修灯，手被铁栏杆划破也没停。作者想说的是：没人看见的坚持才最难。",
    "宽带续费.txt": "家里宽带是电信 500 兆，年费 1080 元，12 月 31 日到期。续费前问一下能不能免费升到千兆。",
    "半马训练计划.md": "# 半程马拉松训练\n\n十一月比赛，目标 2 小时 10 分完赛，配速 6 分 10 秒。周二间歇跑，周四节奏跑，周日长距离慢跑。",
    "日本签证材料.txt": "日本旅游签证材料：近六个月的银行流水、在职证明、护照首页复印件，还有两张白底两寸证件照。交给旅行社代办。",
    "路由器断线.md": "# 路由器断线\n\n家里路由器每天晚上 11 点左右断线，后来把 2.4G 的信道改成 6，再也没断过。",
    "支付模块复盘.md": "# 支付模块复盘\n\n支付模块上线延期了两周，主要原因是第三方接口文档不全、联调环境不稳定。下次接口要先拿到沙箱账号再排期。",
}

# MARK: Templated documents (filler: ordinary notes that the questions are not about)

EN_PEOPLE = ["Alex", "Priya", "Sam", "Ana", "Ben", "Marta", "Tom", "Lena", "Omar", "Grace", "Ivan", "Nora"]
EN_CITIES = ["Porto", "Vienna", "Seoul", "Denver", "Krakow", "Lyon", "Osaka", "Austin", "Ghent", "Hanoi"]
EN_PROJECTS = ["billing revamp", "mobile onboarding", "search latency", "data export", "admin dashboard", "SSO rollout"]
EN_TOPICS = ["recursion", "hash maps", "SQL joins", "unit testing", "HTTP caching", "regular expressions", "async code"]
EN_DISHES = [("lentil soup", "lentils, carrots, cumin and stock"), ("tomato pasta", "tomatoes, garlic, olive oil and basil"),
             ("fried rice", "day-old rice, eggs, scallions and soy sauce"), ("chicken curry", "chicken, onions, ginger and coconut milk"),
             ("mushroom risotto", "arborio rice, mushrooms, parmesan and stock")]
EN_REPAIRS = ["repainted the hallway", "replaced the doorbell battery", "cleaned the roof gutters", "reset the wifi router",
              "fixed the squeaky wardrobe door", "changed the smoke alarm battery"]


def en_doc(i):
    kind = i % 9
    who = rng.sample(EN_PEOPLE, 2)
    day = rng.randint(1, 28)
    month = rng.choice(["January", "March", "April", "June", "August", "September", "November"])
    if kind == 0:
        p = rng.choice(EN_PROJECTS)
        return "Meeting notes %d.md" % i, "# Meeting notes\n\nWe went through the %s. %s will update the plan by %s %d; %s takes the follow-up with finance. Open questions: scope for the next sprint and who reviews the design." % (p, who[0], month, day, who[1])
    if kind == 1:
        c = rng.choice(EN_CITIES)
        return "Trip to %s %d.md" % (c, i), "# Trip to %s\n\nFlight out on %s %d, back four days later. Hotel near the old town, breakfast included. Visit the market on the first morning and the museum on the second; buy a transit card at the airport." % (c, month, day)
    if kind == 2:
        a = rng.randint(40, 900)
        return "Expenses %d.txt" % i, "Expense report for %s: taxi %d, train tickets %d, client dinner %d. Receipts attached; submit before the end of the month. Approved by %s." % (month, a % 60 + 15, a // 3, a, who[0])
    if kind == 3:
        t = rng.choice(EN_TOPICS)
        return "Study notes %d.md" % i, "# Study notes: %s\n\nKey idea: keep the simple case first, then build up. Wrote three small exercises and one longer one; review the mistakes on Friday. Next topic after %s: practice problems from chapter %d." % (t, t, rng.randint(2, 12))
    if kind == 4:
        r = rng.choice(EN_REPAIRS)
        return "House log %d.txt" % i, "House log, %s %d: %s. Took about an hour; bought the parts at the hardware store for %d. Next: check the window seals before winter." % (month, day, r, rng.randint(8, 60))
    if kind == 5:
        km = rng.randint(30, 90) * 1000
        return "Car service %d.txt" % i, "Car service at %d km: oil and filter changed, tire pressure checked, brake pads at 60 percent. Next service due in a year or another 15,000 km. Paid %d." % (km, rng.randint(120, 480))
    if kind == 6:
        title = rng.choice(["The Quiet Harbor", "Lines of Salt", "A Year of Small Roads", "The Last Timetable", "Paper Cities"])
        return "Book notes %d.md" % i, "# Book notes: %s\n\nRead chapters %d to %d this week. The pacing slows in the middle, but the ending of the part about the brothers is strong. Quote to remember: the long way is also a way." % (title, rng.randint(1, 5), rng.randint(6, 12))
    if kind == 7:
        p = rng.choice(EN_PROJECTS)
        return "Status %d.md" % i, "# Weekly status\n\n%s: %d of %d tasks done. Blocked on a review from %s. Risk: the release date may slip by a few days if testing finds more issues." % (p, rng.randint(3, 9), rng.randint(10, 14), who[0])
    dish, parts = rng.choice(EN_DISHES)
    return "Recipe %d.md" % i, "# %s\n\nYou need %s. Cook on medium heat for %d minutes, season at the end and serve warm. Keeps two days in the fridge." % (dish.capitalize(), parts, rng.randint(15, 40))


ZH_PEOPLE = ["小王", "小李", "老张", "阿梅", "小陈", "老刘", "小周", "阿杰", "小赵", "阿芳"]
ZH_CITIES = ["成都", "杭州", "厦门", "西安", "青岛", "昆明", "南京", "长沙", "大连", "苏州"]
ZH_PROJECTS = ["会员系统", "订单导出", "客服工单", "首页改版", "权限管理", "消息推送"]
ZH_TOPICS = ["递归", "哈希表", "SQL 连接查询", "单元测试", "HTTP 缓存", "正则表达式", "异步编程"]
ZH_DISHES = [("番茄蛋汤", "番茄、鸡蛋、葱花"), ("红烧茄子", "茄子、蒜、生抽、老抽"), ("葱油拌面", "细面、小葱、生抽、白糖"),
             ("土豆炖牛肉", "牛腩、土豆、八角、姜"), ("酸辣土豆丝", "土豆、干辣椒、醋")]
ZH_REPAIRS = ["换了门口的感应灯", "把阳台的晾衣杆修好了", "重新打了卫生间的玻璃胶", "清理了油烟机滤网", "换了门锁电池", "补了墙上的钉子洞"]


def zh_doc(i):
    kind = i % 9
    who = rng.sample(ZH_PEOPLE, 2)
    m, d = rng.randint(1, 12), rng.randint(1, 28)
    if kind == 0:
        p = rng.choice(ZH_PROJECTS)
        return "会议纪要 %d.md" % i, "# 会议纪要\n\n讨论了%s的进度。%s负责在 %d 月 %d 日前更新排期，%s跟财务对接预算。遗留问题：下个迭代的范围和设计评审由谁来做。" % (p, who[0], m, d, who[1])
    if kind == 1:
        c = rng.choice(ZH_CITIES)
        return "%s出差 %d.md" % (c, i), "# %s出差\n\n%d 月 %d 日出发，住在客户公司附近的酒店，含早餐。第一天上午拜访客户，下午开评审会；第二天回程，高铁票提前一周买。" % (c, m, d)
    if kind == 2:
        a = rng.randint(80, 2000)
        return "报销 %d.txt" % i, "%d 月报销：打车 %d 元，火车票 %d 元，客户餐费 %d 元。发票已贴好，月底前交财务，审批人%s。" % (m, a % 90 + 20, a // 3, a, who[0])
    if kind == 3:
        t = rng.choice(ZH_TOPICS)
        return "学习笔记 %d.md" % i, "# 学习笔记：%s\n\n先把最简单的情况想清楚，再一步步加。做了三道小题和一道大题，周五复盘错题。下一个主题是第 %d 章的练习。" % (t, rng.randint(2, 12))
    if kind == 4:
        r = rng.choice(ZH_REPAIRS)
        return "家务记录 %d.txt" % i, "%d 月 %d 日：%s，花了一个小时左右，五金店买配件花了 %d 元。下一步：入冬前检查窗户密封条。" % (m, d, r, rng.randint(8, 80))
    if kind == 5:
        km = rng.randint(3, 9) * 10000
        return "保养记录 %d.txt" % i, "车辆保养，里程 %d 公里：换机油机滤，检查胎压，刹车片还剩六成。下次保养一年后或再开一万五千公里，花了 %d 元。" % (km, rng.randint(400, 1500))
    if kind == 6:
        title = rng.choice(["《安静的港口》", "《盐的纹路》", "《一年的小路》", "《最后一班车》", "《纸做的城市》"])
        return "读书笔记 %d.md" % i, "# %s读书笔记\n\n这周读了第 %d 到第 %d 章。中间节奏有点慢，但兄弟俩那一段的结尾写得很好。记一句：远路也是路。" % (title, rng.randint(1, 5), rng.randint(6, 12))
    if kind == 7:
        p = rng.choice(ZH_PROJECTS)
        return "周报 %d.md" % i, "# 周报\n\n%s：完成 %d / %d 个任务，卡在%s的评审。风险：测试如果再发现问题，上线可能推迟几天。" % (p, rng.randint(3, 9), rng.randint(10, 14), who[0])
    dish, parts = rng.choice(ZH_DISHES)
    return "菜谱 %d.md" % i, "# %s\n\n材料：%s。中火做 %d 分钟左右，最后调味，趁热吃，冰箱能放两天。" % (dish, parts, rng.randint(10, 40))


def documents():
    docs = dict(STANDOUT_EN)
    docs.update(STANDOUT_ZH)
    i = 0
    while len(docs) < 200:
        i += 1
        for make in (en_doc, zh_doc):
            name, text = make(i)
            if name not in docs and len(docs) < 200:
                docs[name] = text
    return docs


def main():
    if os.path.exists(OUT):
        sys.exit("%s already exists; delete it first" % OUT)
    docs = documents()
    words = ["owl", "lotus", "piano", "cactus", "bowling", "zebra", "sunflower", "fortune", "snow", "violin", "parrot",
             "penguin", "rose", "gingerbread", "yin", "turntable", "earth", "nest", "tennis", "plumber", "kitchen tap",
             "猫头鹰", "荷花", "钢琴", "仙人掌", "保龄球", "斑马", "向日葵", "饼干", "雪", "小提琴", "鹦鹉", "企鹅", "玫瑰",
             "太极", "唱片", "地球", "鸟窝", "网球", "体检", "科技馆", "水龙头"]
    for name, text in docs.items():
        for word in words:
            assert word not in text.lower(), (name, word)
    stage = os.path.join(OUT, ".docs")
    os.makedirs(stage)
    for name, text in docs.items():
        with open(os.path.join(stage, name), "w", encoding="utf-8") as f:
            f.write(text + "\n")
    pictures = os.path.join(OUT, ".pictures")
    os.makedirs(pictures)
    for (folder, name), out in zip(PICTURES, PICTURE_NAMES):
        subprocess.run(["sips", "-s", "format", "jpeg", "-Z", "1024", "/Library/User Pictures/%s/%s.heic" % (folder, name),
                        "--out", os.path.join(pictures, out)], check=True, stdout=subprocess.DEVNULL)
    for corpus, count in [("img5", 5), ("img10", 10), ("img19", 19), ("audio3", 0)]:
        shutil.copytree(stage, os.path.join(OUT, corpus, "notes"))
        if count:
            os.makedirs(os.path.join(OUT, corpus, "camera"))
            for out in PICTURE_NAMES[:count]:
                shutil.copy(os.path.join(pictures, out), os.path.join(OUT, corpus, "camera", out))
    os.makedirs(os.path.join(OUT, "audio3", "memos"))
    for name, voice, text in RECORDINGS:
        tmp = os.path.join(OUT, ".say.aiff")
        subprocess.run(["say", "-v", voice, "-o", tmp, text], check=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", tmp, "-ac", "1", "-ar", "16000",
                        os.path.join(OUT, "audio3", "memos", name)], check=True)
        os.remove(tmp)
    shutil.rmtree(stage)
    shutil.rmtree(pictures)
    print("corpora in %s: 200 documents each; %s" % (OUT, ", ".join(PICTURE_NAMES)))


main()
