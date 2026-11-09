# 评测题库

`luoke-search eval <题库.json> --testbed <语料的上一级> --index .dev/<名字>` 跑一组有标准答案的题，出第一名、前五、前十命中率和 MRR，按题型分开列，列出没排第一的题。

格式（digup 的，原样能跑）：

```json
{"base": "~/DigUpTestbed/zh/corpus",
 "queries": [{"q": "租房合同里能不能养狗", "expect": ["pdf/租赁合同.pdf@2-2"], "tag": "pdf-page"}]}
```

- `base` 里的 `~/DigUpTestbed` 换成 `--testbed`（或 `LUOKE_SEARCH_TESTBED`）给的文件夹。
- `expect` 是 `base` 下的相对路径，任意一个排进前几都算；`@2-2` 是第 2–2 页（PDF、幻灯片），`@20-35` 是第 20–35 秒（录音、视频）。

| 题库 | 题数 | 语料 | 来源 |
|---|---|---|---|
| `zh.json` | 51 | `testbed/zh/corpus` | 螺壳内部的 DigUp 改版 `luoke/evals/zh.json`（b116b0f），螺壳写的 |
| `zh-office.json` | 11 | `testbed/zh/corpus` 加 `testbed/zh/office`（一起建索引，同 digup） | 螺壳内部的 DigUp 改版 `luoke/evals/zh-office.json`（a2f072e），螺壳写的 |
| `synthetic.json` | 37 | `.dev/testbed-en`（上游脚本生成，见下） | 上游 DigUp `evals/synthetic.json`（1b8671f），Copyright (c) 2026 Abdur Rahim，MIT |
| `multilingual.json` | 48 | 同上（孟加拉文、阿拉伯文） | 上游 DigUp `evals/multilingual.json`（1b8671f），同上 |
| `zh-noanswer.json` | 37 | `testbed/zh/corpus` 加 `office`、`receipts`（一起建索引） | 螺壳写的（2026-10-20）：语料里**没有答案**的题，`expect` 为空（近似题 12、不相干 6、查不到的编号 3、图片 7、截图 3、录音 2、视频 1、英文 3），逐题对着语料核过；和有答案的题库一起用 `eval --refusal` 量拒答门槛 |
| `en-noanswer.json` | 39 | `.dev/testbed-en` | 螺壳写的（2026-10-21）：英文语料里**没有答案**的题，核拒答门槛用的另一批题（门槛是在中文那批上挑的，这批只拿来核，不在上面重挑）：近似题 22（英文 15、孟加拉文 4、阿拉伯文 3）、不相干 4、查不到的编号 2、图片 7、录音 2、视频 1、长文件 1，逐题对着语料核过 |
| `en-answerable.json` | 36 | `.dev/testbed-en` | 螺壳写的（2026-10-21）：和上面配对的有答案的题（新问法，不重复 `synthetic.json`、`multilingual.json`），大多和一道近似题问同一个文件的相邻内容 |
| `few-img5.json`、`few-img10.json`、`few-img19.json`、`few-audio3.json` | 25、30、39、23 | `.dev/testbed-few/<同名>` | 螺壳写的（2026-10-21）：文档多、图或录音少的文件夹（200 篇文档加 5 / 10 / 19 张图，或加 3 段录音）。每份都有同样的 20 道文字题（问 20 篇手写的文档），再加问每张图或每段录音的题：图的名字是 `IMG_3101.jpg` 这种，图里基本没有字，只能按画面答；题里不说"照片""录音"。有 5 道图题问的是旧题问过的同一张示例图（说法不同） |
| `few-*-noanswer.json` | 20、20、16、17 | 同上 | 螺壳写的（2026-10-21）：没有答案的题。文字题 12 道（近似 8、不相干 4），四样哪里都没有的东西的图，img5、img10 再加大语料里有、这份里没有的图的原题，audio3 加 3 道录音里没有的和 2 道图 |
| `same-topic.json` | 45 | `.dev/testbed-same` | 螺壳写的（2026-10-22）：同一个主题既有文档又有图，量打分在"文档和图讲同一类东西"时排得对不对（见下）。题分六类（tag）：`img-named` 14（答案是图，同文件夹的文档点了图里东西的名字）、`img-unnamed` 11（答案是图，文档没点名）、`doc` 12（答案是文档，旁边有同主题的图）、`both` 3（文档和图都算对）、`paper` 3（答案是拍下来的纸：相机照片不做 OCR，只能靠图的向量）、`screen` 2（截图，有 OCR）。**不在 190 题的门槛题库里** |
| `same-topic-few1.json`、`same-topic-few2.json` | 23、22 | `.dev/testbed-same-few1`、`-few2` | 同上那 45 题按文件夹分成两半，各配一份**图少于 20 张**的语料（17、12 张，没有相册）。打分 A 要到一类有 20 条以上才按这一类自己比，图少时它的短板才会出来；第一次跑的语料有 46 条图的向量，A 和 D 算出来一样，量不到这个（审查 10-22 指出）。这两份是第一次跑完、审查以后加的，跑之前提交 |
| `audio-voices.json` | 7 | `.dev/testbed-voices`（`bash scripts/testbed/make_voices.sh .dev/testbed-voices`） | 螺壳写的（2026-10-21）：同一句话换声音、换语言读，给 `probe-audio` 做对照（"录音为什么弱"） |
| `audio-transcripts.json` | — | 各题库的语料 | 录音里说的话（照生成脚本抄的），`probe-audio --transcripts` 用；不是题库 |
| `zh-receipts.json` | 7 | `testbed/zh/corpus` 加 `testbed/zh/receipts`（一起建索引，同文档格式那组） | 螺壳写的（2026-10-20）：一张中英混排的扫描小票，`scripts/testbed/make_receipt.swift` 生成；考 OCR 读混排的字、英文问中文小票、名字和内容都对得上时指到页 |

`.dev/testbed-few`（不进 git）：`python3 -I scripts/testbed/make_few.py .dev/testbed-few`。200 篇文档从模板和固定的种子生成，另有 20 篇手写的（题问的就是它们）；图是系统自带的示例图片，录音用系统的语音读，都不碰用户的文件。文档里不点名图里的东西和录音说的事（近义的词有一些，见脚本开头）。

`.dev/testbed-same`（不进 git）：`python3 -I scripts/testbed/make_same_topic.py .dev/testbed-same`。九个文件夹，每个是一份文档和跟它同主题的图：动物园的安排和动物照片、阳台种花笔记和花的照片、钢琴课和乐器照片、公司运动会（英文）和球的照片、沙漠徒步和路上的东西、姜饼配方和烘焙照片、发票的 PDF 和拍下来的同一张、路由器说明和后台截图、出差行程和拍下来的登机牌。旁边另有 60 篇不相干的文档（固定种子）和一个放 17 张别的示例图片的相册（白玫瑰、别的球……，和题里的图抢）。照片是系统自带的示例图片，纸和屏幕是画出来的（`scripts/testbed/same_render.swift`），都不碰用户的文件。**跑之前定好的看法**：打分 A（默认）、B、C40（打分对比里挑出的 k）三种，在实验室主控上各跑一遍，报第一名、前五名，分 tag 看；主要看 `img-named`（文档的字和意思都跟图抢）和 `doc`（图跟文档抢）两类 A 比 B、C40 差多少。C10、C20、D 也列出来，只作参考。只报数，不换默认。

图少的两份（`--folders … --no-album`，命令见脚本开头）：第一次跑完后审查指出，A 在一类有 20 条以上时和 D 一样，量不到担心的情况。**跑之前定好的看法**同上：A、B、C40 在 few1、few2 上各跑一遍，两份加起来比，主要看 `img-named` 和 `doc`；C10、C20、D 只作参考。

`.dev/testbed-en`（不进 git）用上游 DigUp 1b8671f 自己的生成脚本做：`git -C <上游 DigUp 的克隆> archive 1b8671f scripts/testbed | tar -x -C <空文件夹>`，再 `bash scripts/testbed/make_en.sh <那个文件夹> .dev/testbed-en`。只做上游 `make-testbed.sh` 里的 `synthetic/` 和 `traps/`；它的 `real/`（抽用户自己的文件）和 `code/` 不做。全是合成的：系统自带的示例图片和语音、画出来的截图、ffmpeg 做的视频，约 30 MB。

`testbed/zh`（除了 `receipts/`）拷自螺壳内部的 DigUp 改版 `luoke/testbed/zh`（a2f072e）：Chrome 渲染的文档、系统自带图片做的照片、`say` 合成的录音、脚本生成的表格和幻灯片，全是合成的，不含个人数据。`_segments.json` 是播客录音里各段话题的起止秒数。

其中 `corpus/photos`、`corpus/audio`、`corpus/video` 是 macOS 自带的示例图片和语音做的，不能随代码分发，所以不进 git（2026-11-03 起）：在 `testbed/zh` 上评测之前先做一次 `bash scripts/testbed/make_zh_media.sh`（要 ffmpeg），照那份改版的做法在本机生成。照片和原来的一模一样；录音、视频在别的 macOS 版本上可能读得快慢不同，脚本会打印播客各段的起止秒数，和 `_segments.json` 差过 1 秒时会提醒（`zh.json` 的播客题按它标的范围）。2026-11-03 在这样生成的录音、视频上重跑 `zh.json`（实验室主控，打分 A，`testbed/zh` 整个建索引：语料加 office、receipts）：第一名 / 前五 / MRR 0.90 / 0.96 / 0.93，和 10-21 打分对比里 A 在同样的索引上的成绩一样（下面 10-20 的 0.92 / 0.98 是更早的另一次，那以后打分和主控的版本都改过）。

digup 在实验室主控（oMLX 0.7.1rc1，开了图片和声音）上的成绩是起点：中文 0.90 / 0.98，文档格式 0.73 / 0.91，英文 0.94 / 1.00，孟加拉文和阿拉伯文 0.93 / 0.98。只用合成数据；用真实文件的题库（`*.local.json`）不进 git。

**螺壳搜索在实验室主控上**（2026-10-20，luoke-core a9256aa + oMLX 0.7.1rc1，开了图片和声音，M3 Pro 测试机）：中文 **0.92 / 0.98**，文档格式 **1.00 / 1.00**，小票 **7/7**。审查修复以后（各模态分开算意思的分数，B-02）：中文 **0.86 / 0.98**，文档格式 1.00 / 1.00，小票 7/7；录音题偏弱：`probe-audio` 量了 22 道问录音的题，问题对中文录音的余弦比对同样的文字低约 0.2（英文只低 0.04），写成文字的话中文那 6 道都会排第一；切段和送法没问题。只量了系统 `say` 的合成声音，录音也少（中文 6 道题来自 4 段录音），真人说话没量。

**拒答门槛**（2026-10-21，同样的实验室主控，`zh-noanswer.json` 加三个有答案的题库，审查修复后的打分；还没开：有结果时答复里的 `confident` 是 `null`）：规则是"字词全中，或第一条的余弦过它那个模态的门槛"。

| 门槛（文字 / 图片 / 声音） | 没答案的拒掉（近似题） | 有答案、第一条对却被拒 | 有答案被拒 |
|---|---|---|---|
| 0.63 / 0.63 / 0.70 | 54%（33%） | 0% | 3% |
| 0.63 / 0.68 / 0.70 | 73%（33%） | 4% | 13% |
| 0.70 / 0.65 / 0.70 | 76%（58%） | 7% | 16% |
| **0.70 / 0.66 / 0.70**（起步建议） | **78%（58%）** | **7%** | **16%** |
| 0.72 / 0.67 / 0.72 | 89%（83%） | 9% | 17% |

只看分数分不开：分数 ≥ 3.0 拒掉 43%（近似题 8%），错拒 3%。门槛只对 `embeddinggemma-2/1` 的向量；声音几乎没有数据（没答案的题第一条已经没有录音），先照 0.70。

**英文和多语言**（2026-10-21，同样的实验室主控，`.dev/testbed-en`）：英文 **0.86 / 0.92**，孟加拉文和阿拉伯文 **0.75 / 0.94**，新写的有答案的那批 0.97 / 1.00。同样的索引换回 B-02 之前的打分（`eval --scoring a`，见下）是 0.97 / 1.00、0.92 / 0.98、0.94 / 1.00。上面 digup 的英文和多语言成绩只建了 `synthetic/`、只算答案都在 `synthetic/` 下的 31、43 题（螺壳内部的 DigUp 改版的 `luoke/scripts/en_eval.sh`）；同样那几题，螺壳搜索现在是 0.84 / 0.90、0.84 / 0.98，B-02 之前的打分是 0.97 / 1.00、0.93 / 0.98。

10-21 的打分对比以后，默认的打分换回了 A（B-02 之前那种）；上面"现在的打分"指 B。`eval --scoring a|b|d|c<k>` 可以换着比（D 见"文档多、图少"一节）。

答案标了范围的文本文件（如 `Team notes 2026.md@41-1000`）按文件算（审查 B-12：文字的段不核范围）。拒答门槛在 `en-noanswer.json` 上也核过。

量拒答门槛（只在真模型上算数）：

```bash
luoke-search eval evals/zh-noanswer.json evals/zh.json evals/zh-office.json evals/zh-receipts.json --refusal \
  --index .dev/<语料加 office、receipts 的索引> --testbed "$PWD/testbed"
```
