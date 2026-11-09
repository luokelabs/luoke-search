# Luoke Search (螺壳搜索) luoke-search

[简体中文](README.md) | **English**

On-device search from Luoke Labs: it indexes the files and the Photos library on your Mac and finds them again by words and by meaning — documents, PDFs (scanned ones too), screenshots, pictures, videos, recordings and photos.

## What it is

Luoke Search is a component of [Luoke](https://github.com/luokelabs/luoke). For how the components fit together, see the [search page in the system docs](https://luokelabs.github.io/luoke-atlas/#search) (in Chinese).

- **No window of its own.** You ask in Luoke ("the whiteboard photo I took last month", "the page of the lease about the deposit"); Luoke calls Luoke Search and shows the results as cards: title, the passage that matched, where it is (which page, which second), and a click to open it. The global search in Luoke's window uses it too.
- **Everything stays on your Mac.** The index lives in `~/.luoke-search/` and is kept out of Time Machine. Vectors for search by meaning are computed by Luoke on the same Mac (luoke-core, task `luoke-search.embed`); Luoke Search ships no model of its own. Without Luoke it still searches by words, and the vectors are filled in later.
- **Two ways in, one codebase**: MCP for Luoke (`~/.luoke-search/run/agent.sock`, called by Luoke's background component luoke-agent following version 1 of its tool protocol), and the `luoke-search` command line.
- **What it reads**: txt, md, rtf, doc, docx, odt, html, xlsx, pptx, csv, tsv (text files in GBK too); PDFs page by page, with scanned pages read by the system's Vision text recognition; screenshots, recognized as such and with their text read; pictures, videos (key frames and the sound track) and recordings; the Photos library through PhotoKit. Source code is not searched.

## Status

- **Version 0.1.14, first released with Luoke beta 2** (closed beta).
- **Requirements**: macOS 26.2 or later. Search by meaning needs Luoke installed (Luoke itself needs a Mac with Apple silicon).
- Search by meaning for pictures, videos and recordings needs Luoke's model to take pictures and sound; without it they are found by file name and by the text recognized in pictures only.
- Search by meaning is weak for recordings: questions score noticeably lower against Chinese speech than against the same words as text. See the [evals](evals/README.md) (in Chinese).

## How to use it

Download Luoke from [luoke.ai](https://luoke.ai). Luoke installs and updates Luoke Search, which starts in the background when you log in and does not appear in the Dock. The first time, Luoke asks which folders to search (it suggests Desktop, Documents and Downloads). The Photos library is not searched by default; when you want it, Luoke has macOS ask you.

## Building from source

You need Xcode 26.2 or later (Swift 6.2). There are no third-party Swift packages.

```bash
swift build                     # → .build/debug/luoke-search
swift test                      # everything uses made-up files in temporary folders
```

To try it on a folder (a development build requires `--index` to say where the index goes, so it never touches the real `~/.luoke-search`):

```bash
.build/debug/luoke-search index <folder> --index .dev/try
.build/debug/luoke-search search "团队版怎么收费" --index .dev/try
.build/debug/luoke-search status --index .dev/try
```

Without `LUOKE_HUB_SOCKET` it does not connect to Luoke and searches by words only. To try the whole flow there is a stand-in for Luoke (its vectors are made up, so rankings mean nothing):

```bash
python3 -I scripts/fake_hub.py --socket /tmp/lsfake.sock --mode-file .dev/fake-hub-mode &
LUOKE_HUB_SOCKET=/tmp/lsfake.sock .build/debug/luoke-search index <folder> --index .dev/try --wait
```

To build the app: `sh scripts/build_app.sh` → `build.noindex/螺壳搜索.app` (how to run it during development and unregister it afterwards is at the top of the script). How to run the eval question sets and corpora is in [evals/README.md](evals/README.md) (in Chinese). The photos, recordings and videos of `testbed/zh` are macOS's own sample material and are not in the repository; make them on your Mac with `scripts/testbed/make_zh_media.sh` before an eval.

## Data and privacy

- **Luoke Search itself makes no network connections.** It talks only to Luoke's Unix socket on your Mac (for vectors), and luoke-agent talks to its socket. When you open a result, the app that opens it (a browser for an `.html` file, say) may go online, which is why opening always takes your click.
- **It only reads your files**: it never changes, moves or uploads them. Files that are only in iCloud and not on this Mac are not downloaded; they are read once they are back. In the Photos library, too, only what is already on this Mac is read.
- **Credentials**: files named like passwords, keys or certificates (`id_rsa`, `.env`, `*.pem`, `密码.txt`…) are skipped from the start, without reading them. Passwords or card numbers written inside other files are kept as written in the index on your Mac (so the full number still finds them); in the results, cards and passages that go out, passwords, one-time codes and keys are masked in full, and card and ID numbers keep only their last 4 digits.
- **Where data lives**: the index and settings are in `~/.luoke-search/`, which only your account can open (700) and which is kept out of Time Machine. Deleting that folder deletes the whole index. Its log lines hold only metadata (how many files, how long it took), never search terms, passages or file contents.
- **Changes need your click**: changing settings, opening a file or having macOS ask for a permission happens only after you click on a card in Luoke.
- It never reaches out on its own: no notifications and no pushed results. It tells you something, through Luoke, only when you need to pick folders, when it needs your permission to read, and when the first pass of indexing is done.

## Documentation

The documents are in Chinese.

- [Glossary](CONTEXT.md)
- [What the search page in Luoke's window takes from Luoke Search](docs/窗口接口.md)
- [Evals](evals/README.md): question sets, corpora and results on the real model; [reference vectors](Tests/Reference/README.md)

## Acknowledgements

Luoke Search was written from scratch. Its design draws on the open-source project [DigUp](https://github.com/ARahim3/DigUp) (Abdur Rahim, MIT License) and on Luoke's own revision of it: how to read the many file types, how to rank by words and meaning together, how to work with Luoke (luoke-core), and the synthetic test corpora and eval questions. Test material copied from there says so next to the files and keeps the original author's copyright notice:

> Copyright (c) 2026 Abdur Rahim — MIT License

## License

Copyright 2026 螺壳实验室 Luoke Labs. Released under the [Apache License 2.0](LICENSE). The name and icon are not licensed; for copyright, trademarks and acknowledgements (including DigUp's full MIT license), see [NOTICE](NOTICE).

To report a security issue, see [SECURITY.md](SECURITY.md). To contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).
