# 安全问题

螺壳搜索读得到你选的文件夹和照片图库里的东西，所以安全问题我们会优先处理。如果你发现螺壳搜索的安全问题，比如索引里的内容或搜到的片段会离开本机、能被别的账户或程序读到、本机别的程序能经它的 socket 打开文件或改设置、凭证没被遮掉、读一个特制的文件就能让它出错或执行别的东西，请**不要在公开 issue 里写细节**，用 GitHub 的私密漏洞报告：

1. 打开本仓库的 **Security** 页；
2. 点 **Report a vulnerability**，写清楚影响哪个版本（螺壳里显示的螺壳搜索版本）、macOS 版本、怎么复现、可能的影响。

本仓库还没公开时，报到顶层仓库 [luokelabs/luoke](https://github.com/luokelabs/luoke/security) 就行。我们会尽快回复，修好以后在发布说明里注明。

请不要在报告里附上真实的文件、照片、搜索词或索引；需要样本时用编造的数据，用开发版加 `--index` 指定的临时索引复现。

---

If you find a security issue in Luoke Search (indexed content or passages leaving the Mac, readable by other accounts or apps, another app opening files or changing settings through its socket, credentials not masked, a crafted file making it crash or run something, and so on), please report it privately via **Security → Report a vulnerability** on this repository, or on [luokelabs/luoke](https://github.com/luokelabs/luoke/security) while this repository is private. Please don't include real files, photos, search terms or indexes in reports; reproduce with made-up data and a temporary index (`--index`).
