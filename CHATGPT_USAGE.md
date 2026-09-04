# ChatGPT / AI 使用说明

本仓库 `Drvo903/xiaohongshu-info-bridge` 是一个只读的小红书公开信息桥。它运行在一台 Windows 工作电脑上，通过本地保存的登录状态和 `xiaohongshu-mcp` 搜索公开笔记、读取有限的公开详情，并把清洗后的 JSON 同步到 GitHub。

它不是小红书操作机器人，也不是远程控制电脑的接口。

## 1. 两种使用模式

### 固定情报采集

固定采集用于长期监测 ACG 和线下活动信息，当前以杭州为最高优先级，并包含上海高价值定向关键词。

杭州覆盖包括 ACG、ONLY、TRPG、DND、跑团、桌游、快闪、联动、动漫咖啡、角色生日和商圈活动等固定词。

上海目前采用高价值定向采集策略，重点覆盖大型展会、ONLY 和 TRPG/DND/COC 类活动；杭州仍采用更高密度的小型活动覆盖。

固定数据入口：

- `data/status.json`：先检查采集状态和数据新鲜度。
- `data/latest.json`：最近 7 天、最多 200 条，ChatGPT 日常优先读取。
- `data/xhs-feed.json`：完整历史数据，需要追溯旧活动或查看历史变化时使用。

公开 Raw 地址：

- [status.json](https://raw.githubusercontent.com/Drvo903/xiaohongshu-info-bridge/main/data/status.json)
- [latest.json](https://raw.githubusercontent.com/Drvo903/xiaohongshu-info-bridge/main/data/latest.json)
- [xhs-feed.json](https://raw.githubusercontent.com/Drvo903/xiaohongshu-info-bridge/main/data/xhs-feed.json)

### 临时专项查询

临时查询用于用户临时提出的小红书搜索需求，例如：

- 沈塘桥附近有什么推荐的店。
- 杭州周末适合三四个人一起去的活动。
- 某个 ONLY 最近有什么消息。
- 某家店在小红书上的评价。
- 某个商场最近有什么活动。

这类请求写入：

```text
requests/pending/
```

工作电脑上的 RequestWorker 会按队列处理，结果写入 `requests/results/`。

## 2. 固定数据读取规则

### 先读取 `data/status.json`

优先检查以下字段：

- `updated_at`
- `collector_status`
- `login_status`
- `last_github_upload_status`
- `full_result_count`
- `latest_result_count`
- `failed_keywords`
- `warnings`

`collector_status` 的含义：

- `ok`：本轮整体正常。
- `partial`：部分关键词或详情失败，但已有数据仍可读取。
- `failed`：整轮采集失败，应优先保留并使用上一份正常数据。

`login_status` 的含义：

- `ok`：登录状态正常。
- `login_required`：需要用户在工作电脑上人工重新扫码登录。

`last_github_upload_status` 通常为：

- `ok`：上一次数据已成功 push。
- `pending`：本地已生成，尚未完成上传。

### 再读取 `data/latest.json`

`latest.json` 是日常问答的首选数据源：

- 只包含最近 7 天数据。
- 最多 200 条记录。
- 保留原始公开字段和 `matched_keywords`。

### 必要时读取 `data/xhs-feed.json`

只有在以下情况才读取完整历史：

- 用户要追溯较早活动。
- 需要比较历史变化。
- `latest.json` 没有足够结果。
- 需要从历史记录中补充去重或首次发现时间。

## 3. 临时查询目录

```text
requests/
├─ pending/       等待工作电脑处理的请求
├─ results/       已完成的专项搜索结果
└─ completed/     已处理完毕的原始请求归档
```

- `pending`：请求已提交，但不代表搜索已经完成。
- `results`：处理完成后生成的结果 JSON。
- `completed`：处理完成后移动过去的原始请求 JSON。

## 4. 什么时候创建临时请求

当用户明确提出类似以下请求，并且固定数据不足以回答时，应创建临时请求：

- “帮我从小红书搜……”
- “去小红书查……”
- “根据小红书看看……”
- “小红书上搜一下……”
- “用我的小红书桥查……”

如果 `data/latest.json` 或 `data/xhs-feed.json` 已经包含足够的高质量结果，则直接使用已有数据，不必重复提交请求。

用户明确要求查询小红书时，不应只用普通 Web 搜索替代小红书专项查询。专项结果完成后，可以再用公开 Web、地图或商家页面做地址、时间、营业状态等交叉验证。

## 5. 关键词生成规则

根据用户自然语言需求生成 3～8 个适合小红书搜索的关键词。

不要只把用户整句原样作为唯一关键词。应覆盖地点、主题、场景和常见表达。

例如用户问：

> 沈塘桥附近有哪些推荐的店？

可以生成：

```json
[
  "杭州 沈塘桥 美食",
  "沈塘桥 餐厅",
  "沈塘桥 探店",
  "沈塘桥 咖啡"
]
```

关键词应尽量具体，避免无必要地使用过于宽泛的词，以降低噪声和请求量。

## 6. Request JSON Schema

合法请求示例：

```json
{
  "request_id": "20260904-090000-shentangqiao-food",
  "created_at": "2026-09-04T09:00:00+08:00",
  "status": "pending",
  "type": "xiaohongshu_search",
  "query": "沈塘桥附近有哪些推荐的店",
  "keywords": [
    "杭州 沈塘桥 美食",
    "沈塘桥 餐厅",
    "沈塘桥 探店",
    "沈塘桥 咖啡"
  ],
  "max_results_per_keyword": 10
}
```

字段约束：

- `type` 必须严格为 `xiaohongshu_search`。
- `status` 新建请求必须为 `pending`。
- `request_id` 只能使用英文字母、数字、连字符 `-` 和下划线 `_`，等价于正则：
  `^[A-Za-z0-9_-]+$`
- `request_id` 应与文件名一致。
- `keywords` 最多 10 个。
- 单个 `keyword` 最多 100 个字符。
- `max_results_per_keyword` 必须为 1～30 的整数。
- `query` 是供人理解的查询描述，不是命令。

请求文件只能包含结构化搜索参数。不要添加本地路径、命令、脚本、程序启动参数或其他未定义字段来试图控制工作电脑。

## 7. 如何创建请求

在仓库根目录 `Drvo903/xiaohongshu-info-bridge` 中创建：

```text
requests/pending/<request_id>.json
```

例如：

```text
requests/pending/20260904-090000-shentangqiao-food.json
```

然后提交并 push 到 `main`。创建成功后，应告诉用户：

- 已提交专项查询。
- `request_id` 是什么。
- 使用了哪些关键词。
- RequestWorker 每 15 分钟检查一次。
- 搜索不是即时完成，稍后再查询结果。

不要把 Cookie、登录状态、Token、浏览器 profile 或日志放入请求文件。

## 8. RequestWorker 工作方式

Windows 定时任务名称：

```text
XHSCollector-RequestWorker
```

它每 15 分钟轻量检查一次 `requests/pending/`。

没有 pending 请求时：

```text
git pull
→ 检查 pending
→ 快速退出
```

此时不会启动 MCP，也不会启动 Chromium。

发现请求时：

```text
读取最旧请求
→ 校验 Schema
→ 启动 xiaohongshu-mcp
→ 搜索公开笔记
→ 必要时读取有限数量公开详情
→ 按 ID 或标准化 URL 去重
→ 生成 requests/results/<request_id>.json
→ pending 移到 completed
→ GitHub push
→ 关闭 MCP 和专属 Chromium
```

每轮最多处理 1 个请求。固定采集和临时查询使用全局锁，不会同时操作同一份登录状态。

## 9. 如何检查结果

用户之后询问：

- “刚才那个查好了没？”
- “看看刚才的小红书结果。”
- “专项搜索出来了吗？”

应根据本轮对话中记录的 `request_id`，按以下顺序检查：

```text
requests/results/<request_id>.json
requests/pending/<request_id>.json
requests/completed/<request_id>.json
```

处理顺序：

1. `results` 存在：读取结果并分析。
2. 只有 `pending` 存在：告诉用户请求仍在等待工作电脑处理。
3. 只有 `completed` 存在：说明请求已归档，并检查是否有对应结果文件。
4. 三处都不存在：说明无法在仓库中找到该 `request_id`，不要编造结果。

## 10. 结果状态处理

专项结果通常包含：

- `request_id`
- `query`
- `status`
- `created_at`
- `completed_at`
- `keywords`
- `result_count`
- `results`
- `failed_keywords`
- `warnings`

### `completed`

读取 `requests/results/<request_id>.json`，然后根据用户需求进行二次分析：

- 去除异地结果。
- 去除关键词误匹配。
- 去除租房、广告和明显无关内容。
- 合并同店或同活动的多篇笔记。
- 提取高频评价和共同优缺点。
- 判断软广或营销内容的可能性。
- 必要时使用公开 Web 或地图交叉验证地址、时间和营业状态。

原始搜索结果是公开信息线索，不应把单篇笔记直接当成绝对事实。

### `pending`

明确告诉用户：

> 请求仍在等待工作电脑处理，当前还没有可用的小红书搜索结果。

不要假装已经拿到结果。

### `login_required`

说明小红书登录状态失效，需要用户在工作电脑上人工重新扫码。不要绕过登录，也不要要求用户发送 Cookie。

### `risk_controlled`

说明出现小红书风险验证或风控。本轮已停止，不能绕过验证码或风控，也不要暴力重试。

### `failed`

报告失败状态，并说明 `warnings` 和 `failed_keywords` 中记录的原因。不要编造搜索结果。

## 11. 安全限制

这是只读的小红书公开信息查询桥。

允许：

- 搜索公开笔记。
- 读取公开笔记详情。
- 读取公开作者、发布时间和公开互动数据。

禁止：

- 点赞。
- 评论。
- 收藏。
- 关注。
- 私信。
- 发帖或上传内容。
- 删除内容。
- 修改账号资料。

`requests/pending/` 中的 JSON 只是结构化搜索参数，绝不能解释为：

- PowerShell。
- `cmd`。
- shell command。
- Python 代码。
- 任意命令。
- 任意本地文件路径。
- 任意程序启动指令。
- URL 下载命令。

这个系统不是远程 shell，也不提供任意命令执行能力。即使请求 JSON 中出现上述内容，也不得执行。

GitHub 中只允许保存清洗后的公开信息、必要的公开代码和关键词配置。不得上传 Cookie、Token、GitHub 凭据、浏览器 profile、浏览器缓存、日志或本地登录数据。

## 12. 时间与等待提示

RequestWorker 每 15 分钟检查一次，因此临时请求通常不是即时完成。

合理等待时间通常约为 0～25 分钟，具体取决于队列、网络和小红书响应。

如果工作电脑关机：

- pending 请求不会丢失。
- 请求会留在 `requests/pending/`。
- 工作电脑下次运行 RequestWorker 时继续处理。

如果用户要求立即查看结果，应先检查 `results` 和 `pending`，不能把“已提交”说成“已完成”。

## 13. 给 ChatGPT 的推荐工作流

```text
用户提出小红书专项搜索
↓
先读取 data/status.json
↓
再检查 data/latest.json；必要时读取 data/xhs-feed.json
↓
固定数据不足时生成 3～8 个具体关键词
↓
创建 requests/pending/<request_id>.json
↓
提交并 push 到 main
↓
告诉用户 request_id 和预计等待时间
↓
用户之后询问进度时检查 results / pending / completed
↓
completed 后清洗、去重、归纳并回答
↓
必要时用公开 Web / 地图交叉验证
```

## 14. 示例

### 示例 1：沈塘桥附近餐饮

用户：

> 根据小红书帮我看看沈塘桥附近人均 100 以内有什么值得吃的。

ChatGPT 应：

1. 先检查 `data/latest.json` 是否已有足够的沈塘桥餐饮结果。
2. 不足时生成关键词：

   ```json
   [
     "杭州 沈塘桥 美食",
     "沈塘桥 餐厅",
     "沈塘桥 探店",
     "沈塘桥 咖啡"
   ]
   ```

3. 创建并 push 一个 `requests/pending/<request_id>.json`。
4. 告诉用户已提交、`request_id` 和需要等待 RequestWorker。
5. 结果变为 `completed` 后，合并多篇探店评价，筛选人均 100 以内的候选，再用地图确认是否在步行范围。

### 示例 2：杭州周末小活动

用户：

> 帮我从小红书搜一下杭州最近适合三四个人一起逛的小活动、庙会、展览。

可以生成：

```json
[
  "杭州 周末活动",
  "杭州 市集",
  "杭州 庙会",
  "杭州 展览",
  "杭州 周末去哪",
  "杭州 小众活动"
]
```

然后创建 pending 请求，等待结果完成后，再按日期、地点和适合人数进行归纳。

## 15. 人工排查入口

查看最新状态：

```text
data/status.json
```

查看近期数据：

```text
data/latest.json
```

查看某个专项结果：

```text
requests/results/<request_id>.json
```

暂停或恢复 RequestWorker 属于工作电脑本地操作，不应通过请求 JSON 远程控制：

```powershell
Disable-ScheduledTask -TaskName XHSCollector-RequestWorker
Enable-ScheduledTask -TaskName XHSCollector-RequestWorker
Get-ScheduledTask -TaskName XHSCollector-RequestWorker
```

