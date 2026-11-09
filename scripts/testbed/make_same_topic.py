"""Folders where documents and pictures are about the same things (evals/same-topic.json; evals/README.md).

    python3 -I scripts/testbed/make_same_topic.py .dev/testbed-same        (macOS: sips, swift)
    python3 -I scripts/testbed/make_same_topic.py .dev/testbed-same-few1 --folders 动物园,阳台花园,乐器课,沙漠徒步 --no-album
    python3 -I scripts/testbed/make_same_topic.py .dev/testbed-same-few2 --folders "Sports day,圣诞烘焙,家电发票,路由器,成都出差" --no-album

Nine folders as a person keeps them, each a document and the pictures that go with it: a zoo day's plan and photos of
the animals, a balcony garden's notes and photos of the flowers, a child's piano lessons and photos of instruments,
a company sports day (English) and photos of balls, a desert hike and photos of what's on the way, a gingerbread
recipe and photos of the baking, an invoice as a PDF and photographed, a router's manual and a screenshot of its admin
page, a business trip's itinerary and a photo of the boarding pass. The documents name some of what the pictures show
and not the rest (the questions ask about both kinds). Around them: 60 documents on other things (fixed seed) and a
folder of 17 other sample pictures. Pictures have neutral names (IMG_4101.jpg); the photos are macOS's sample pictures
(/Library/User Pictures), the papers and screens are drawn (scripts/testbed/same_render.swift). Everything is
generated; nothing is read from the user's files.
`--folders` makes only those folders (the 60 documents still), `--no-album` leaves the other pictures out: the two
"few" corpora above have 17 and 12 pictures, fewer than the 20 at which scoring A judges pictures among themselves
(`VectorMatrix.pooled`), where its weakness would show.
"""
import json
import os
import random
import subprocess
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else ".dev/testbed-same"
ONLY = sys.argv[sys.argv.index("--folders") + 1].split(",") if "--folders" in sys.argv else None
ALBUM = "--no-album" not in sys.argv
HERE = os.path.dirname(os.path.abspath(__file__))
PICTURES = "/Library/User Pictures"
rng = random.Random(20261022)

# Each folder: its documents (name -> text), its photos (name -> sample picture), its drawn papers and screens.
FOLDERS = {
    "动物园": {
        "docs": {"动物园一日游.md": "# 动物园一日游\n\n周六带孩子去野生动物园。园区早上 9 点开门，成人门票 120 元，儿童 60 元，网上预约便宜 10 元。"
                 "路线：先去企鹅馆看喂食（10:30），再沿湖边看斑马和长颈鹿，中午在园里的熊猫餐厅吃饭。"
                 "下午两点猛禽馆有猫头鹰和老鹰的飞行表演，四点前出园。北门停车场 15 元一小时。"},
        "photos": {"IMG_4101.jpg": "Animals/Penguin", "IMG_4102.jpg": "Animals/Zebra", "IMG_4103.jpg": "Animals/Owl",
                   "IMG_4104.jpg": "Animals/Parrot", "IMG_4105.jpg": "Animals/Eagle"},
    },
    "阳台花园": {
        "docs": {"阳台种花笔记.md": "# 阳台种花笔记\n\n向日葵三月底播种，种子先泡一夜，出芽以后每天要晒足六小时太阳。"
                 "玫瑰春秋两季每周浇两次水，夏天早晚各浇一次，花谢以后剪到第一片五叶的上面。"
                 "雏菊怕涝，盆底多垫一层陶粒。每月施一次缓释肥，十月以后停肥。"},
        "photos": {"IMG_4111.jpg": "Flowers/Sunflower", "IMG_4112.jpg": "Flowers/Red Rose", "IMG_4113.jpg": "Flowers/Lotus",
                   "IMG_4114.jpg": "Flowers/Yellow Daisy", "IMG_4115.jpg": "Flowers/Dandelion"},
    },
    "乐器课": {
        "docs": {"孩子的钢琴课.md": "# 孩子的钢琴课\n\n钢琴课每周六上午十点，在少年宫三楼，王老师上课，学费每节 200 元，一学期十六节。"
                 "每天至少练半小时，先弹音阶再弹练习曲。下学期还想报小提琴，要先去试一节课。"},
        "photos": {"IMG_4121.jpg": "Instruments/Piano", "IMG_4122.jpg": "Instruments/Violin",
                   "IMG_4123.jpg": "Instruments/Guitar", "IMG_4124.jpg": "Instruments/Drum"},
    },
    "Sports day": {
        "docs": {"Company sports day.md": "# Company sports day\n\nThe soccer match starts at 9 a.m. on the east field, "
                 "teams of seven, one team from each department. Basketball runs from 2 p.m. in the gym. Bring sneakers "
                 "and a water bottle; lunch is provided. The winning team gets a trophy and an extra day off."},
        "photos": {"IMG_4131.jpg": "Sports/Soccer", "IMG_4132.jpg": "Sports/Basketball", "IMG_4133.jpg": "Sports/Tennis",
                   "IMG_4134.jpg": "Sports/Golf", "IMG_4135.jpg": "Sports/Baseball"},
    },
    "沙漠徒步": {
        "docs": {"沙漠徒步计划.md": "# 沙漠徒步计划\n\n十一月去戈壁徒步两天。每人带 3 升水、头灯和防晒，路上有很多仙人掌，别用手碰。"
                 "第二天下午可能有雷暴，看到闪电就下撤到营地。营地在干河谷北侧的岩石后面。"},
        "photos": {"IMG_4141.jpg": "Nature/Cactus", "IMG_4142.jpg": "Nature/Lightning", "IMG_4143.jpg": "Nature/Nest"},
    },
    "圣诞烘焙": {
        "docs": {"姜饼人配方.md": "# 姜饼人配方\n\n面粉 300 克、红糖 100 克、黄油 80 克、蜂蜜两大勺、姜粉两小勺、肉桂粉一小勺。"
                 "面团冷藏一小时再擀开，用模具压出姜饼人，180 度烤 10 分钟。凉了以后用糖霜画眼睛和扣子。"},
        "photos": {"IMG_4151.jpg": "Fun/Gingerbread Man", "IMG_4152.jpg": "Fun/Fortune Cookie",
                   "IMG_4153.jpg": "Nature/Snowflake"},
    },
    "家电发票": {
        "drawn": [("空气净化器发票.pdf", "pdf"), ("IMG_4161.jpg", "paper")],
        "lines": ["北辰电器商行  销售发票", "日期  2026-09-28", "商品  空气净化器 AP-560  × 1", "金额  3,280.00 元",
                  "保修  两年，凭发票维修"],
    },
    "路由器": {
        "docs": {"路由器使用说明.md": "# 路由器使用说明\n\n管理地址 192.168.31.1，用浏览器打开。恢复出厂设置：通电状态下用针按住背面的 "
                 "Reset 键 10 秒，指示灯变黄以后松开。双频合一默认打开，想单独用 5G 就在 Wi-Fi 设置里关掉合并。固件每月自动检查更新。"},
        "drawn": [("Screenshot 2026-10-12 at 21.15.40.png", "screen")],
        "lines": ["路由器管理后台   192.168.31.1", "Wi-Fi 设置", "名称  Home-5G     频段  5GHz", "已连接设备  12 台",
                  "上传 2.1 MB/s    下载 18.6 MB/s"],
    },
    "成都出差": {
        "docs": {"成都三日行程.md": "# 成都三日行程\n\n10 月 26 日坐 CA4113 去成都，10:05 起飞。第一天下午去宽窄巷子，晚上吃火锅；"
                 "第二天上午拜访客户，下午去大熊猫基地；第三天上午自由活动，下午五点去机场。酒店订在春熙路附近。"},
        "drawn": [("IMG_4171.jpg", "paper")],
        "lines": ["登机牌  BOARDING PASS", "CA4113   北京首都 → 成都天府", "日期 26OCT    座位 32A",
                  "登机口 C12    登机时间 09:25"],
    },
}

# Other sample pictures, in a folder of their own: they compete with the photos above (a white rose, other balls).
OTHER_PICTURES = ["Flowers/Whiterose", "Flowers/Dahlia", "Flowers/Poppy", "Flowers/Flower", "Fun/Chalk", "Fun/Medal",
                  "Fun/Smack", "Fun/Yin-Yang", "Nature/Earth", "Nature/Leaf", "Nature/Sandollar", "Nature/Zen",
                  "Sports/Hockey", "Sports/Target", "Sports/8ball", "Sports/Football", "Instruments/Turntable"]

# Documents on other things, from fixed words: none of the questions' words.
ZH = ["季度", "报告", "预算", "客户", "会议", "排期", "项目", "评审", "交付", "合同", "续签", "付款", "培训", "审批", "制度",
      "办公室", "问卷", "上线", "风险", "总结", "保险", "租房", "个税", "收据", "保修", "维修", "学校", "体检"]
EN = ["quarterly", "report", "budget", "client", "meeting", "schedule", "project", "review", "delivery", "contract",
      "renewal", "payment", "training", "approval", "policy", "office", "survey", "release", "risk", "summary",
      "insurance", "lease", "receipt", "warranty", "repair", "school", "checkup"]


def filler(index):
    if index % 2:
        words = [rng.choice(EN) for _ in range(rng.randint(40, 90))]
        body = " ".join(words).capitalize() + "."
        return "notes %02d.md" % index, "# Notes %d\n\n%s\n" % (index, body)
    body = "".join(rng.choice(ZH) + ("，" if rng.random() < 0.2 else "") for _ in range(rng.randint(40, 90))) + "。"
    return "笔记 %02d.md" % index, "# 笔记 %d\n\n%s\n" % (index, body)


def jpeg(source, target):
    subprocess.run(["sips", "-s", "format", "jpeg", os.path.join(PICTURES, source + ".heic"), "--out", target],
                   check=True, stdout=subprocess.DEVNULL)


def main():
    if os.path.exists(OUT):
        sys.exit("%s already exists; delete it first" % OUT)
    spec = []
    for folder, content in FOLDERS.items():
        if ONLY is not None and folder not in ONLY:
            continue
        path = os.path.join(OUT, folder)
        os.makedirs(path)
        for name, text in content.get("docs", {}).items():
            with open(os.path.join(path, name), "w", encoding="utf-8") as f:
                f.write(text + "\n")
        for name, source in content.get("photos", {}).items():
            jpeg(source, os.path.join(path, name))
        for name, kind in content.get("drawn", []):
            spec.append({"path": os.path.abspath(os.path.join(path, name)), "kind": kind, "lines": content["lines"]})
    if ALBUM:
        others = os.path.join(OUT, "相册", "2026-08")
        os.makedirs(others)
        for index, source in enumerate(OTHER_PICTURES):
            jpeg(source, os.path.join(others, "IMG_%d.jpg" % (3801 + index)))
    notes = os.path.join(OUT, "笔记")
    os.makedirs(notes)
    for index in range(60):
        name, text = filler(index)
        with open(os.path.join(notes, name), "w", encoding="utf-8") as f:
            f.write(text)
    spec_file = os.path.join(OUT, ".render.json")
    with open(spec_file, "w", encoding="utf-8") as f:
        json.dump(spec, f, ensure_ascii=False)
    subprocess.run(["swift", os.path.join(HERE, "same_render.swift"), spec_file], check=True, stdout=subprocess.DEVNULL)
    os.remove(spec_file)
    total = sum(len(files) for _, _, files in os.walk(OUT))
    print("%d files in %s" % (total, OUT))


main()
