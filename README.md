# 螺壳搜索 luoke-search

**简体中文** | [English](README.en.md)

螺壳实验室的本机搜索：给 Mac 上的文件和照片图库建索引，按字词和按意思找回来——文档、PDF（含扫描件）、截图、图片、视频、录音、照片。

> **Luoke Search** indexes the files and Photos library on your Mac and finds them again by words and by meaning: documents, PDFs (scanned ones too), screenshots, pictures, videos, recordings and photos. It has no window of its own: you ask in Luoke, and Luoke shows the results as cards, with the page or the moment that matched. Everything stays on your Mac; the vectors for search by meaning come from Luoke on the same Mac. Full English version: [README.en.md](README.en.md).

## 它是什么

螺壳搜索是[螺壳](https://github.com/luokelabs/luoke)的一个组件。各组件怎么分工，见[系统文档里的螺壳搜索一页](https://luokelabs.github.io/luoke-atlas/#search)。

- **没有自己的界面**。在螺壳里问一句（"上个月拍的那张白板照片""合同里写押金的那页"），螺壳调螺壳搜索，把结果画成卡片：标题、命中的片段、出处（第几页、第几秒），点一下打开。螺壳窗口里的全局搜索也用它。
- **都在本机**。索引在 `~/.luoke-search/`，不进 Time Machine；按意思搜的向量由本机的螺壳（luoke-core）算（任务 `luoke-search.embed`），螺壳搜索自己不带模型。螺壳不在时照样能按字词搜，向量以后补。
- **两个入口、同一套代码**：给螺壳的 MCP（`~/.luoke-search/run/agent.sock`，螺壳的后台组件 luoke-agent 照它的工具协议版本 1 来调）和命令行 `luoke-search`。
- **读什么**：txt、md、rtf、doc、docx、odt、html、xlsx、pptx、csv、tsv（含 GBK 编码的文字文件）；PDF 一页一页读，扫描页用系统的 Vision 认字；截图认出来并读里面的字；图片、视频（关键帧和音轨）、录音；照片图库经 PhotoKit 读。不搜代码。

## 现状

- **版本 0.1.21，随螺壳 beta 2 第一次发布**（封闭测试）。
- **系统要求**：macOS 26.2 及以上；按意思搜要装螺壳（螺壳本身要 Apple 芯片的 Mac）。
- 图片、视频、录音按意思搜，要螺壳那边的模型收图片和声音；收不了时只按文件名和图里认出的字找。
- 录音按意思搜偏弱：问题对中文录音的分数比对同样意思的文字低不少，详见[评测](evals/README.md)。

## 怎么用

到 [luoke.ai](https://luoke.ai) 下载螺壳。螺壳搜索装在螺壳.app 里面，跟螺壳一起更新；在螺壳里开启后，由螺壳在后台启动，不出现在程序坞。默认搜你的个人文件夹和 iCloud 云盘，不用挑；不想搜的，在螺壳搜索的页面上去掉或跳过。开启时 macOS 会逐个问你让不让读桌面、文稿、下载和 iCloud 云盘。外接盘、照片图库默认不搜，要你点了才搜。

## 从源码构建

要 Xcode 26.2 或更新（Swift 6.2）。不用第三方 Swift 包。

```bash
swift build                     # → .build/debug/luoke-search
swift test                      # 全部用临时文件夹里的合成文件
```

对着一个文件夹试（开发版必须用 `--index` 指定索引放哪，不碰正式的 `~/.luoke-search`）：

```bash
.build/debug/luoke-search index <文件夹> --index .dev/try
.build/debug/luoke-search search "团队版怎么收费" --index .dev/try
.build/debug/luoke-search status --index .dev/try
```

没设 `LUOKE_HUB_SOCKET` 时不连螺壳，只按字词搜。只测流程可以用假的螺壳（向量是编的，排名没有意义）：

```bash
python3 -I scripts/fake_hub.py --socket /tmp/lsfake.sock --mode-file .dev/fake-hub-mode &
LUOKE_HUB_SOCKET=/tmp/lsfake.sock .build/debug/luoke-search index <文件夹> --index .dev/try --wait
```

螺壳里带的是 `LUOKE_OUT=<文件夹> sh scripts/build_helper.sh` 编的程序，螺壳打包时放进螺壳.app（见脚本开头）。`sh scripts/build_app.sh` → `build.noindex/螺壳搜索.app` 只用来开发时单独试（怎么起、测完怎么注销，见脚本开头）。评测题库和语料怎么跑，见 [evals/README.md](evals/README.md)；`testbed/zh` 的照片、录音和视频是 macOS 自带的素材，不在仓库里，评测前用 `scripts/testbed/make_zh_media.sh` 在本机生成。

## 数据和隐私

- **螺壳搜索自己不联网**。它只连本机螺壳的 Unix socket（算向量）、螺壳 agent 连它的 socket，和螺壳启动它时给的描述符 3（`LUOKE_HOST_FD`：认出是螺壳起的，告诉螺壳已经起好，以及请螺壳从某一秒开始放音视频）。螺壳.app 里的这份只由螺壳起：在终端里直接跑，除了 `status` 都会被拒；它的 socket 只答带着螺壳这次给的口令的请求。打开搜到的文件时，打开它的程序（比如打开 `.html` 的浏览器）可能会联网，所以打开一律要你点。
- **搜哪些地方**：默认是你的个人文件夹和 iCloud 云盘，可以去掉。不进的：隐藏的文件夹、「资源库」（除了 iCloud 云盘；聊天记录、邮件、缓存都在这里）、「音乐」、个人文件夹里装工具的文件夹（Applications、miniconda3、go、opt、虚拟机这些）、代码项目里的代码，以及 Dropbox、OneDrive 这类云盘。不搜整个硬盘，开了完全磁盘访问也一样。外接盘、照片图库要你点了才搜；外接盘按盘的编号记，换一块同名的盘不算。
- **只读你的文件**：不改、不移动、不上传。只在 iCloud 里、不在这台 Mac 上的文件不下载，回到本机后再读；照片图库也只读本机已有的。
- **没允许读照片时**：开了照片图库、但在螺壳里还没允许或收回了读照片的许可时，在螺壳里搜不到照片：搜索结果、「找相似的」和按来源的条数都不算照片；读过的记录留在本机索引里，再允许不用重建。在终端里直接用命令行搜时不看这个许可，读过的照片照样搜得到。在系统设置里拒绝的，以前读过的照片照样搜得到，只是不再跟着图库更新。
- **凭证**：名字像密码、密钥、证书的文件（`id_rsa`、`.env`、`*.pem`、`密码.txt`……）一开始就跳过，不读内容。别的文件里写着的密码、卡号，照原文存在本机的索引里（拿完整的号码也搜得到）；出去的结果、卡片和片段里，密码、验证码、密钥整串遮掉，卡号、证件号只留后 4 位。
- **数据放在哪**：索引和设置都在 `~/.luoke-search/`，只有你的账户能打开（700），不进 Time Machine 备份。删掉这个文件夹就删掉了全部索引。运行记录只写元数据（几个文件、花了多久），不写搜索词、片段和文件内容。
- **改东西要你点**：改设置、打开文件、请 macOS 问权限，只在你在螺壳的卡片上点了以后才做。
- 不主动找你：不弹通知、不推搜索结果；只在还没开始搜、要你允许读、第一遍建完时，经螺壳告诉你。

## 文档

- [术语](CONTEXT.md)
- [螺壳窗口的搜索页从螺壳搜索拿什么](docs/窗口接口.md)
- [评测](evals/README.md)：题库、语料和在真模型上的成绩；[参考向量集](Tests/Reference/README.md)

## 致谢

螺壳搜索从头写，设计上参考了开源项目 [DigUp](https://github.com/ARahim3/DigUp)（Abdur Rahim，MIT 许可）和螺壳在它基础上的改版：怎么读各种文件、按字词和按意思混合排序、和螺壳（luoke-core）对接的做法，以及合成的测试语料和评测题。从那里拷来的测试资料在文件旁边注明来源，并保留原作者的版权声明：

> Copyright (c) 2026 Abdur Rahim — MIT License

## 许可

Copyright 2026 螺壳实验室 Luoke Labs。以 [Apache License 2.0](LICENSE) 发布；名称和图标不随许可授予，版权、品牌和致谢（含 DigUp 的 MIT 许可全文）见 [NOTICE](NOTICE)。

报告安全问题见 [SECURITY.md](SECURITY.md)，参与开发见 [CONTRIBUTING.md](CONTRIBUTING.md)。
