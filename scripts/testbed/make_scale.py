"""A home folder of made-up files at the size of a real Mac's, to see how far luoke-search scales.

    swiftc -O scripts/testbed/scale_render.swift -o .dev/scale_render
    python3 -I scripts/testbed/make_scale.py 10k .dev/scale/10k        (or 50k; macOS: sips, say, ffmpeg)

Documents (txt, md, a few docx), PDFs (some only pictures of text: scans), screenshots, photos (camera names, at most
200 a folder), a few videos and recordings, spread over Documents, Desktop, Downloads, Pictures, Movies and Music.
Every document and PDF has its own text (seeded, the same every run); photos are macOS's sample pictures at a few
sizes, cloned (APFS: no extra space); videos and recordings are a handful made with ffmpeg and macOS's voices, cloned.
Nothing is read from the user's files.
"""
import os
import random
import shutil
import subprocess
import sys
import zipfile

TIERS = {
    "10k": dict(docs=6000, pdfs=1200, scans=300, shots=800, photos=1600, videos=20, recordings=80),
    "50k": dict(docs=31000, pdfs=6000, scans=1500, shots=3000, photos=8000, videos=100, recordings=400),
}
tier, OUT = sys.argv[1], sys.argv[2]
counts = TIERS[tier]
RENDER = os.environ.get("SCALE_RENDER", ".dev/scale_render")
rng = random.Random(20261021)

EN = ["quarterly", "report", "budget", "client", "meeting", "invoice", "schedule", "project", "review", "update",
      "delivery", "contract", "renewal", "payment", "travel", "hotel", "flight", "summary", "decision", "risk",
      "release", "testing", "support", "customer", "survey", "training", "office", "policy", "approval", "plan",
      "kitchen", "garden", "insurance", "lease", "tax", "receipt", "warranty", "repair", "school", "doctor"]
ZH = ["季度", "报告", "预算", "客户", "会议", "发票", "排期", "项目", "评审", "更新", "交付", "合同", "续签", "付款", "出差",
      "酒店", "航班", "总结", "决定", "风险", "上线", "测试", "客服", "问卷", "培训", "办公室", "制度", "审批", "厨房", "花园",
      "保险", "租房", "个税", "收据", "保修", "维修", "学校", "医生"]
NAMES = ["Alex", "Priya", "Sam", "Ana", "Ben", "Marta", "Tom", "Lena", "小王", "小李", "老张", "阿梅", "小陈", "老刘"]
AREAS = ["Work", "Home", "Finance", "Travel", "Study", "Health", "工作", "家里", "财务", "学习"]


def sentence():
    if rng.random() < 0.5:
        words = [rng.choice(EN) for _ in range(rng.randint(8, 16))]
        return " ".join(words).capitalize() + " (%s, %d)." % (rng.choice(NAMES), rng.randint(1, 9999))
    return "".join(rng.choice(ZH) for _ in range(rng.randint(6, 14))) + "，%s，%d 元。" % (rng.choice(NAMES), rng.randint(1, 99999))


def text(sentences):
    return "\n".join(" ".join(sentence() for _ in range(rng.randint(2, 5))) for _ in range(max(1, sentences // 3)))


def docx(path, body):
    paragraphs = "".join("<w:p><w:r><w:t>%s</w:t></w:r></w:p>" % line.replace("&", "&amp;").replace("<", "&lt;")
                         for line in body.split("\n"))
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        z.writestr("word/document.xml", '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>%s</w:body></w:document>' % paragraphs)


def folders(root, count, size):
    """Paths for `count` files under `root`, at most `size` a folder."""
    out = []
    for index in range(count):
        out.append(os.path.join(root, "%s %02d" % (rng.choice(AREAS), index // size)))
    return out


def render(kind, count, into, size, seed):
    """`count` rendered files spread over folders of `size` under `into`."""
    stage = os.path.join(OUT, ".stage-" + kind)
    subprocess.run([RENDER, stage, kind, str(count), str(seed)], check=True, stdout=subprocess.DEVNULL)
    for index, name in enumerate(sorted(os.listdir(stage))):
        folder = os.path.join(into, "%02d" % (index // size))
        os.makedirs(folder, exist_ok=True)
        os.rename(os.path.join(stage, name), os.path.join(folder, name))
    os.rmdir(stage)


def clone(source, target):
    subprocess.run(["cp", "-c", source, target], check=True)


def main():
    if os.path.exists(OUT):
        sys.exit("%s already exists; delete it first" % OUT)
    os.makedirs(OUT)
    # Documents: own text each, 1 in 20 a docx; a few long ones.
    for index, folder in enumerate(folders(os.path.join(OUT, "Documents"), counts["docs"], 250)):
        os.makedirs(folder, exist_ok=True)
        body = text(rng.choice([3, 6, 9, 12, 30, 90]) if index % 50 else 600)
        kind = "docx" if index % 20 == 0 else rng.choice(["txt", "md"])
        path = os.path.join(folder, "%s %d.%s" % (rng.choice(EN + ZH), index, kind))
        if kind == "docx":
            docx(path, body)
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write(body + "\n")
    render("pdf", counts["pdfs"], os.path.join(OUT, "Documents", "PDF"), 250, 11)
    render("scan", counts["scans"], os.path.join(OUT, "Downloads", "Scans"), 250, 12)
    render("shot", counts["shots"], os.path.join(OUT, "Desktop", "Screenshots"), 250, 13)
    # Photos: the sample pictures at three sizes, cloned under camera names.
    sources = os.path.join(OUT, ".sources")
    os.makedirs(sources)
    pictures = []
    for group in sorted(os.listdir("/Library/User Pictures")):
        folder = os.path.join("/Library/User Pictures", group)
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".heic"):
                continue
            for size in (1024, 2048, 3024):
                out = os.path.join(sources, "%s-%s-%d.jpg" % (group, name[:-5], size))
                subprocess.run(["sips", "-s", "format", "jpeg", "-Z", str(size), os.path.join(folder, name), "--out", out],
                               check=True, stdout=subprocess.DEVNULL)
                pictures.append(out)
    for index in range(counts["photos"]):
        folder = os.path.join(OUT, "Pictures", "%d" % (2020 + index // 2000), "%02d" % (index // 200 % 10 + 1))
        os.makedirs(folder, exist_ok=True)
        clone(rng.choice(pictures), os.path.join(folder, "IMG_%04d.JPG" % (index % 10000)))
    # Videos: five made from the pictures, cloned.
    made = []
    for index in range(5):
        out = os.path.join(sources, "video-%d.mp4" % index)
        inputs = []
        for picture in rng.sample(pictures, 3):
            inputs += ["-loop", "1", "-t", "6", "-i", picture]
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y"] + inputs + [
            "-filter_complex", "[0:v]scale=768:768,setsar=1[a];[1:v]scale=768:768,setsar=1[b];"
            "[2:v]scale=768:768,setsar=1[c];[a][b][c]concat=n=3:v=1:a=0,format=yuv420p", "-r", "24", out], check=True)
        made.append(out)
    os.makedirs(os.path.join(OUT, "Movies"))
    for index in range(counts["videos"]):
        clone(made[index % len(made)], os.path.join(OUT, "Movies", "VID_%04d.mp4" % index))
    # Recordings: twenty in macOS's voices, cloned.
    voices = [("Samantha", "Reminder: %s at %d o'clock, bring the %s and the %s."),
              ("Flo (Chinese (China mainland))", "提醒一下，%s，%d 点，带上%s和%s。")]
    spoken = []
    for index in range(20):
        voice, line = voices[index % 2]
        words = EN if index % 2 == 0 else ZH
        aiff = os.path.join(sources, "say.aiff")
        subprocess.run(["say", "-v", voice, "-o", aiff, line % (rng.choice(words), rng.randint(1, 12), rng.choice(words),
                                                                 rng.choice(words))], check=True)
        out = os.path.join(sources, "memo-%d.m4a" % index)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", aiff, "-ac", "1", out], check=True)
        spoken.append(out)
    os.makedirs(os.path.join(OUT, "Music", "Recordings"))
    for index in range(counts["recordings"]):
        clone(spoken[index % len(spoken)], os.path.join(OUT, "Music", "Recordings", "New Recording %d.m4a" % index))
    shutil.rmtree(sources)
    total = sum(len(files) for _, _, files in os.walk(OUT))
    print("%s: %d files in %s" % (tier, total, OUT))


main()
