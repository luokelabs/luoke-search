# 参考向量集

主控算的向量要和这里的标准向量一致：每条余弦 ≥ 0.999 是 `luoke-search.embed` 的及格线（顶层 ADR 0018）。luoke-core 的 `tools/embed_parity.py` 和本仓库的 `HubParityTests` 都读这里。

**下面这四个文件一个字节都不改**；要改，先告诉 luoke-core 和负责人。后来加的文字在 `texts.json`、`vectors-extra.json` 里，见"后来加的"。

| 文件 | sha256 | 内容 |
|---|---|---|
| `vectors.json` | `0ec9336aa53fb0d5bafa074cd56122e2fd914cb73f080b4f98332872089f6dd8` | 9 条参考向量，768 维：文字 5 条（query、query-bn、query-ar、document、document-long），图片 3 条（screen-280、photo-140、frame-70），声音 1 条（speech）；`made_with` "llama.cpp b11461"，`vector_version` 1 |
| `screen.png` | `a8a0c831fe4746d00c95e3ab436d53e4cc9046a774fe4f0f6edb73d1a7d55f9b` | 合成的截图，1440 × 900 |
| `photo.jpg` | `243df6bca3dfce7888ba872d9a774b7d030f5f6d4c5f92bd11d0f3402c026133` | 合成的照片 |
| `speech.wav` | `bfbc029af6c0bacdbaccfa6c695d6772373453249386fa6a62a7b02a31d33e1f` | 合成的声音，16 kHz 单声道 16 位，4 s |

## 来源

- 原样拷自上游 DigUp `1b8671f`（2026-10-09，它的第一个提交）的 `Tests/LlamaRuntimeTests/Reference/`；螺壳内部的 DigUp 改版从那以后没改过这几个文件。上游 DigUp：<https://github.com/ARahim3/DigUp>，Copyright (c) 2026 Abdur Rahim，MIT 许可。
- 生成方法（digup 的记录）：llama.cpp b11461，模型 ggml-org/embeddinggemma-2-GGUF @ `bfcd298` 的 Q8_0；三个输入文件由上游的 `scripts/testbed/make_reference_inputs.py` 生成，全是合成的，不含个人数据。
- 已知结果（luoke-core 的 mlx bf16）：文字 5 条最低 0.99977；图片和声音 4 条在 oMLX 0.7.1rc1 上最低 0.99959。

## 后来加的（2026-11-03）

原来的 5 条文字没有中文，也没有超过 2048 token 的。补了 7 条，向量用和原来一样的做法另存一份，原来的四个文件不动。

| 文件 | 内容 |
|---|---|
| `texts.json` | 全部 12 条文字输入，逐字：`name`、`prompt`（`query` 或 `document`）、`title`、`text`，和送给主控的 `input`（已带前缀）。前 5 条就是原来的 5 条，和 digup 的一字不差。`HubParityTests` 从这里读；luoke-core 的 `embed_parity.py` 现在还写着原来的 5 条，改成读这个文件以后就不用两边各抄一份。 |
| `vectors-extra.json` | 后来加的 7 条的参考向量，768 维，`made_with`、`vector_version` 和 `vectors.json` 一样。 |

后来加的 7 条全是编的，不含个人数据：

- `query-zh`、`query-zh-law`、`query-zh-bank`：中文查询，带专有名词和全角标点；
- `document-zh`：中文文档；
- `document-zh-long`：中文长文档，3036 个 token，超过 2048，走截断那条路；
- `document-mixed`：中英混排；
- `document-code`：代码片段，带中文注释，有换行。

做法：`python3 -I scripts/make_reference_vectors.py --bin <llama.cpp 的 build/bin> --model <embeddinggemma-2-Q8_0.gguf> --check --write Tests/Reference/vectors-extra.json --names …`

- llama.cpp b11461（commit `4d756bc`）：`llama-embedding`，均值池化，L2 归一化，上下文 2048；
- 模型：ggml-org/embeddinggemma-2-GGUF @ `bfcd298` 的 Q8_0，sha256 `2188ac1d…`。
- `--check` 先把原来的 5 条重算一遍，和 `vectors.json` 比：5 条余弦都是 1.000000，所以做法和原来的一样。
- 超过 2048 token 的照主控的截法截（transformers `truncation=True, max_length=2048`）：留 `<bos>`、开头 2046 个 token、`<eos>`。截下来的文字再分一次词，逐个对得上，才算它的向量。
  - 前提是主控的分词器和 llama.cpp 一样在结尾加 `<eos>`、截的时候给它留位置。
- 主控上核过（2026-11-03）：实验室主控用 oMLX 0.7.2 和 0.7.1rc1 各跑一次 `HubParityTests`，新 7 条余弦 0.99985–0.99991（截断那条 0.99985），每条查询单独送和成批送比 ≥ 0.99994。

**它量的还是"和 llama.cpp 一样"，不是"和用户已建的索引一样"**：用户索引里的向量是当时发布的主控引擎算的。和发布引擎比的锚点另做。

## 怎么送

- 文字 12 条：`texts.json` 的 `input` 原样送。`HubParityTests` 12 条一批送，另外每条查询再单独送一次，和成批那次比（≥ 0.9999）。
- 图片和声音原样送：`screen.png` 预算 280，`photo.jpg` 预算 140 和 70（视频帧），`speech.wav` 整段。图片和声音的客户端在第 3 块。
