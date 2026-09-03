# XHSCollector

Windows 上的只读小红书公开信息采集器。它通过官方 `xiaohongshu-mcp` 搜索公开笔记、读取公开详情，去重后生成 JSON；不发帖、不评论、不点赞、不收藏、不关注、不私信，也不修改账号资料。

## 目录结构

```text
D:\XHSCollector\
├─ bin\                         官方 Windows x64 程序（本地敏感/运行文件，不上传）
├─ config\keywords.json         搜索关键词（可修改）
├─ data\
│  ├─ xhs-feed.json             可公开数据镜像（GitHub 上传此文件）
│  ├─ latest.json               最近 7 天、最多 200 条（GitHub 上传此文件）
│  ├─ status.json               采集状态和数据新鲜度（GitHub 上传此文件）
│  ├─ cookies.json              小红书登录状态（敏感，不上传）
│  ├─ home\, config\, appdata\  运行配置（敏感，不上传）
│  ├─ localappdata\             隔离的内置 Chromium（不上传）
│  └─ tmp\                      每次运行临时目录（不上传）
├─ output\xhs-feed.json         本地历史主文件（不上传）
├─ logs\                        采集、MCP、GitHub 和登录日志（不上传）
└─ scripts\
   ├─ collector.py              只读 MCP 采集器
   ├─ login.ps1                 手动扫码登录/重新登录
   ├─ run_collector.ps1         启动 MCP、采集、上传、清理进程
   ├─ sync_github.ps1           校验并上传 data\xhs-feed.json
   └─ install_task.ps1          创建/更新 Windows 定时任务
```

所有 Cookie、浏览器 profile、缓存、临时目录均应位于 `D:\XHSCollector\data\`。GitHub 只保存清洗后的公开数据、必要的公开脚本和关键词配置，不保存 Cookie、token、日志或浏览器文件。

## 手动运行

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File D:\XHSCollector\scripts\run_collector.ps1
```

测试小规模运行：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File D:\XHSCollector\scripts\run_collector.ps1 `
  -SkipGit -PerKeywordLimit 3 -MaxTotal 3 -MaxDetails 3 -DetailTimeout 45
```

任务结束后，MCP 和本轮 Chromium 会自动关闭；清理只按本轮 MCP 进程树和本轮临时目录识别，不会结束日常 Chrome/Edge。

## 重新扫码登录

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File D:\XHSCollector\scripts\login.ps1
```

登录窗口出现后，用手机小红书 App 扫码。不要复制、查看或发送 `data\cookies.json` 内容。

## 修改关键词

编辑：

```text
D:\XHSCollector\config\keywords.json
```

文件必须是字符串数组。采集器默认每个关键词最多取 10 条，本轮最多处理 80 条，详情请求最多 20 条，单次详情请求超时 45 秒，并在关键词和详情请求之间等待。详情超时只记录日志，不覆盖已有成功数据。

## 查看日志和手动触发

```powershell
Get-Content D:\XHSCollector\logs\collector.log -Tail 80
Get-Content D:\XHSCollector\logs\run.log -Tail 80
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File D:\XHSCollector\scripts\run_collector.ps1
```

日志不会记录 Cookie、token、session 或内部请求参数。

## 暂停/恢复定时任务

定时任务名称为 `XHSCollector-Workday`：

```powershell
Disable-ScheduledTask -TaskName XHSCollector-Workday
Enable-ScheduledTask -TaskName XHSCollector-Workday
Get-ScheduledTask -TaskName XHSCollector-Workday
```

安装或更新定时任务：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File D:\XHSCollector\scripts\install_task.ps1
```

任务使用当前 Windows 登录用户、默认本地时区，在工作日 09:30、13:30、16:30 触发；不唤醒关机电脑、不补跑错过的任务、不允许并发实例，失败最多延迟重试一次。

## GitHub 数据地址

远程仓库配置完成后，公开 JSON 地址为：

```text
https://raw.githubusercontent.com/Drvo903/xiaohongshu-info-bridge/main/data/xhs-feed.json
https://raw.githubusercontent.com/Drvo903/xiaohongshu-info-bridge/main/data/latest.json
https://raw.githubusercontent.com/Drvo903/xiaohongshu-info-bridge/main/data/status.json
```

`xhs-feed.json` 是完整历史，`latest.json` 是最近 7 天、最多 200 条，`status.json` 用于快速检查采集时间和状态。`status.json` 使用 `last_github_upload_status` 表示上一次 push 状态，避免为了把 pending 改成 ok 而额外制造递归提交。

本地同步会先校验三个 JSON 合法、字段一致且没有超过最新数据上限，再只提交实际变化的公开文件；push 失败会保留本地数据，下一轮可继续重试。不会把 PAT 写入脚本。

## 常见故障

- `LOGIN_REQUIRED` / 退出码 20：停止本轮，运行 `scripts\login.ps1` 重新扫码。
- `RISK_CONTROL_TRIGGERED` / 退出码 21：停止本轮，不绕过验证码或风控，也不暴力重试。
- `MCP_FAILED` / 退出码 22：查看 `logs\mcp-*.stderr.log`；上一份成功 JSON 不会被覆盖。
- `GITHUB_UPLOAD_FAILED` / 退出码 30：检查 GitHub 登录/远程仓库权限；本地采集结果会保留。
- 端口 18060 被占用：采集器会拒绝触碰不属于本项目的进程。
- 登录窗口无法启动：确认 `data\localappdata\` 中的隔离浏览器完整，再查看 `logs\login-*.stderr.log`。

## 数据字段

`output\xhs-feed.json` 和公开镜像包含 `id`、`keyword`、`matched_keywords`、`title`、`author`、`published_at`、公开 URL、摘要、点赞/评论/收藏数、位置以及首次/最近发现时间。搜索期间使用的访问令牌只保留在内存中，不写入 JSON、日志或 Git。
