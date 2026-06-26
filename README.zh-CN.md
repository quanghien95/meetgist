# MeetGist · 记了吗

[English](README.md) | **中文**

**Get the gist. Skip the rest.** — *抓重点，去废话。*

**MeetGist 是一个开源的 Mac 原生会议录音 + AI 笔记应用。** 不用拉机器人进会:它在你本机运行，把你的**麦克风和通话里的系统声音分两条轨录下来**——Zoom、Google Meet、腾讯会议、Teams、Webex 都行——再把每场会整理成带时间戳的逐字稿、润色过的会议纪要、以及结构化摘要（一句话总结、决策、待办）。两条音轨做了时间对齐（`capture_timing.json` → `sync_map.json`），说话人区分更干净。已经录好的音频文件也能转。

> 这里是开源引擎（`meetgist`）。原生 Mac App + 官网在 **[meetgist.app](https://meetgist.app)**。

> **项目状态：** 个人的、免费的开源项目，按 AGPL-3.0 **以现状（as-is）提供**，**不含任何担保，也不提供商业支持**。它不是付费产品或服务。AI 用的是你自己申请的免费额度 API key。

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B%20(Apple%20Silicon)-lightgrey)

> 在你点下转录之前，所有数据都不会离开这台 Mac；真正上传时，音频也只发往你自己的 Gemini（或选配的 OpenAI）API key。无需注册账号，没有服务器，不做任何遥测。

---

## 原生 App（开发者预览）

仓库里自带一个 SwiftUI 原生 App——一个菜单栏录音器，外加一个窗口管理你的会议、逐字稿/纪要/摘要，还有一个填 API key 的设置面板。它复用同一套录音引擎和提示词，整条流水线都用 Swift 实现（不依赖 Python 或 ffmpeg）。

从 Xcode 运行：

```bash
open Package.swift          # 在 Xcode 里打开这个 package
# 在顶栏选择 “MeetGistApp” scheme，然后按 Run（⌘R）
```

或在终端里：`swift run MeetGistApp`。

首次运行时，macOS 会请求**屏幕录制**和**麦克风**权限。打开**设置**（齿轮图标），粘贴一个免费额度的 **Gemini API key**（`aistudio.google.com/apikey`）就能生成笔记——没有 key 它也照样录音。代码在 `Sources/MeetGistApp/`（界面）和 `Sources/MeetGistKit/`（引擎：录音器、提示词、Gemini 流水线）。*签名/公证后的 `.dmg` 分发暂时还没配置。*

---

## 你会得到什么

每开一次会（或转一个音频文件），meetgist 都会生成一个文件夹，里面包含：

| 文件 | 内容 |
|---|---|
| `transcript.md` | 逐字稿，每行带时间戳——`[MM:SS] 说话人：内容` |
| `polished.md` | 干净的纪要：去掉口头语，标注每位说话人的立场，分章节、摘金句、列待办 |
| `summary.md` | 一句话总结、关键决策、待办事项、待解决的问题 |
| `mic.m4a` / `system.m4a` | 原始的两条音轨 |

它会自动识别会议语言（中英文互切、中英夹杂都没问题），并用对应语言写笔记。

---

## 工作原理

```
快捷键 / ./meetgist-toggle.sh
        │
        ▼
meetgist（Swift 可执行文件）
   ├─ 系统声音  (ScreenCaptureKit → system.m4a)
   ├─ 麦克风    (AVFoundation    → mic.m4a)
   └─ 停止时：把两条音轨交给 postprocess.py
        │
        ▼
scripts/postprocess.py（Python venv）
   ├─ 用 Gemini 转写（超长音频改走 OpenAI）
   ├─ 用 Gemini 润色 + 摘要
   └─ 写出 transcript.md / polished.md / summary.md  +  macOS 通知
```

Swift 录音器只是一层很薄的采集层，所有 AI 相关的活都在 Python 脚本里，因此你以后可以随手换模型，甚至改成完全本地跑（比如 whisper）。

---

## 环境要求

- **macOS 14 以上，Apple Silicon 芯片**
- **Xcode 命令行工具**——`xcode-select --install`
- **Python 3.10 以上**
- **ffmpeg**（仅长音频切片时才需要）——`brew install ffmpeg`
- **一个 Gemini API key**——在 [Google AI Studio](https://aistudio.google.com/apikey) 免费申请

---

## 快速开始

```bash
git clone https://github.com/MeetGist/meetgist.git
cd meetgist
./setup.sh
```

`./setup.sh` 会帮你检查依赖、编译录音器、建好 Python 环境，并生成一份 `scripts/.env`。接着：

1. **填入 API key**——打开 `scripts/.env`，设置：
   ```
   GEMINI_API_KEY=你的-key
   ```
2. **录音**——运行一次开始，再运行一次停止并转录：
   ```bash
   ./meetgist-toggle.sh
   ```
   第一次运行时，macOS 会请求**屏幕录制**和**麦克风**权限（见 [权限设置](#macos-权限)）。

就这么简单。笔记会出现在 `~/Documents/meetgist/<时间戳>/` 里。

> **小提示：** 想用键盘快捷键开始/停止，把 `./meetgist-toggle.sh` 接到一个 macOS 快捷指令上即可，详见 [快捷键一键录音](#录音方式二快捷键一键录音)。

---

## 申请 API key

**Gemini（必需，有免费额度）。** 打开 [aistudio.google.com/apikey](https://aistudio.google.com/apikey) 创建一个 key，粘到 `scripts/.env` 里的 `GEMINI_API_KEY=...`。转写、润色、摘要全靠这一个 key。

**OpenAI（选配）。** 录音特别长时，可以把转写这一步交给 OpenAI（润色和摘要仍由 Gemini 完成）。在 `scripts/.env` 里加上 `OPENAI_API_KEY=...`；留空就全程用 Gemini。详见 [配置](#配置)。

---

## 转录已有的音频文件

不一定非要现场录——你手上任何音频都能转（语音备忘录、下载来的录音、采访、Zoom 导出的文件都行）。处理流程和现场会议完全一样，只是起点换成了你的文件。

**支持的格式：** `.m4a`、`.mp3`、`.wav`、`.mp4`

### 单个文件

```bash
scripts/transcribe_meeting.sh ~/Downloads/interview.mp3
```

文档会**就地生成**——直接放在音频旁边，并以它命名：`interview.transcript.md`、`interview.polished.md`、`interview.summary.md`。**原始文件不会被改动**，也不会往 meetgist 的输出目录里拷任何东西。

### 一次转多个文件

```bash
scripts/transcribe_file.py a.mp3 b.m4a c.wav
```

### 转整个文件夹

把它指向任意文件夹，里面每个音频文件都会被就地转录，文档就写在各自旁边：

```bash
scripts/transcribe_file.py ~/Downloads/voice-memos/
```

### 选项（单个文件）

```bash
scripts/transcribe_file.py ~/Downloads/interview.mp3 --title "候选人面试" --source mic
```

| 参数 | 默认值 | 含义 |
|---|---|---|
| `--title`、`-t` | 文件名 | 输出文件名前缀（仅单文件有效） |
| `--source` | `auto` | `mic` = 单说话人，标为「Me」；`system`/`auto` = 多说话人区分（Speaker 1、2…） |

> 如果一个**会议文件夹**里已经有 `mic.m4a` 和/或 `system.m4a`，可以直接传给 `scripts/transcribe_meeting.sh <文件夹>`，原地（重新）转录，不会产生拷贝。

### 在访达里右键 → 快速操作

只配置一次，以后在访达（Finder）里**右键音频文件**就能转，连终端都不用开：

1. 打开 **快捷指令 App（Shortcuts.app）** → 菜单 **文件 ▸ 新建快捷指令**。
2. 在右侧详情面板（ⓘ）勾选 **用作快速操作（Use as Quick Action）** 和 **访达（Finder）**。
3. 把快捷指令的输入设为 **接收 _文件和文件夹_**（编辑器顶部）。
4. 添加一个 **运行 Shell 脚本（Run Shell Script）** 动作并配置：
   - **Shell：** `/bin/bash`
   - **传递输入：** **作为参数**
   - **脚本**（把 `/path/to/meetgist` 换成你 clone 的位置）：
     ```
     /path/to/meetgist/scripts/transcribe_meeting.sh "$@"
     ```
5. 命名为「**用 meetgist 转录**」之类，保存。

现在在访达里右键任意 `.m4a` / `.mp3` / `.wav` / `.mp4` 文件——可以是会议文件夹，也可以是你随手丢了一两段录音进去的普通文件夹（比如手动拷进去的某个 `xxx.mp3`）——选 **快速操作 ▸ 用 meetgist 转录**。没有 `mic.m4a`/`system.m4a` 的文件夹会被当作导入音频处理：每个文件都**就地转录**，在旁边生成 `<名字>.transcript.md` / `.polished.md` / `.summary.md`，并按内容自动区分说话人（单人备忘录就保持单说话人，多人对话则拆成 Speaker 1 / Speaker 2…）。笔记就绪后会弹 macOS 通知。（这个包装脚本会把 Homebrew 加进 `PATH` 并把日志写到 `logs/`，所以在访达受限的运行环境里也能正常工作。）

录好的**会议文件夹**（含 `mic.m4a`/`system.m4a`）会在原文件夹里转录；导入的音频文件则把文档放在源文件旁边。（早先的现场录音流程不变，会话仍落在你配置的输出目录，默认 `~/Documents/meetgist`。）

---

## 录制会议

### 用终端命令

`./setup.sh` 会往你的 shell 配置（`~/.zshrc` 或 `~/.bashrc`）里装一组终端快捷命令。开一个新终端（或 `source ~/.zshrc`），就能用：

| 命令 | 作用 |
|---|---|
| `meetgist` | 开始录音；再运行一次就**停止并转录** |
| `gist-status` | 显示当前是录音中还是已停止 |
| `gist-open` | 打开笔记/输出目录 |
| `gist-last` | 打开最近一次的会话文件夹 |
| `gist-tx <文件\|文件夹>` | 转录已有的音频文件或会议文件夹 |

```bash
meetgist        # 开始录音（开始和停止都会弹通知）
gist-status     # ● 录音中  /  ■ 已停止录音
meetgist        # 再运行一次停止；约 30–120 秒后笔记就绪
```

不想用这些别名也行——每条命令都对应一个可以直接调用的脚本：`./meetgist-toggle.sh`、`./meetgist-toggle.sh status`、`./meetgist-toggle.sh open`、`scripts/transcribe_meeting.sh <文件>`。

### 录音方式二：快捷键一键录音

1. 打开 **快捷指令 App** → 新建快捷指令 → 添加 **运行 Shell 脚本**。
2. 把脚本设为 `meetgist-toggle.sh` 的绝对路径，例如 `/Users/你的用户名/meetgist/meetgist-toggle.sh`。
3. 在快捷指令设置里给它指定一个键盘快捷键（如 `⌃⌥⌘R`）。

之后按一次快捷键开始录音，再按一次停止并自动转录——全程不用切到终端。这个 toggle 脚本会从 `scripts/.env` 读取 `MEETGIST_OUTPUT_DIR`，所以无论是快捷键触发还是终端调用，行为都一致。

---

## 配置

所有设置都在 `scripts/.env` 里（从 `scripts/.env.example` 拷贝而来）。

| 变量 | 默认值 | 用途 |
|---|---|---|
| `GEMINI_API_KEY` | — | **必需。** 你的 Google AI Studio key。 |
| `MEETGIST_OUTPUT_DIR` | `~/Documents/meetgist` | 录音和笔记的存放位置。指到 Dropbox/iCloud 目录就能多设备同步。 |
| `GEMINI_MODEL` | `gemini-3.5-flash` | 用于转写/润色、支持音频的 Gemini 模型。 |
| `GEMINI_FALLBACK_MODEL` | `gemini-3.1-flash-lite` | 主 Gemini 调用失败时的备用模型。 |
| `TRANSCRIPT_PROVIDER` | `auto` | `auto`（Gemini，长音频走 OpenAI）、`gemini` 或 `openai`。 |
| `OPENAI_API_KEY` | — | 只有用到 OpenAI 转写时才需要。 |
| `OPENAI_TRANSCRIBE_MODEL` | `gpt-4o-mini-transcribe` | OpenAI 转写模型。 |

更细的切片/阈值开关（`OPENAI_CHUNK_SECONDS`、`GEMINI_CHUNK_SECONDS`、`GEMINI_AUDIO_REQUEST_MAX_MB`…）都在 `scripts/.env.example` 里有就地注释。

**行为小结：**
- 润色和摘要始终用 Gemini。
- `auto` 只有在最大那条音轨较大（约 16 MB 以上）且设了 `OPENAI_API_KEY` 时，才把转写交给 OpenAI；否则全程 Gemini，长音频会自动切片。
- `gemini` 彻底关掉 OpenAI；`openai` 则强制使用。

列出你的 key 能用哪些模型：

```bash
cd scripts && .venv/bin/python3 -c "
from google import genai; from dotenv import load_dotenv; import os
load_dotenv('.env')
for m in genai.Client(api_key=os.environ['GEMINI_API_KEY']).models.list(): print(m.name)"
```

---

## macOS 权限

只需授权一次，授给真正启动录音器的那个 App：

1. **屏幕录制**——让 ScreenCaptureKit 能采集系统声音。
2. **麦克风**——录你的声音。

- 从终端启动 → 把两项都授给你的终端 App。
- 用快捷键启动 → 把两项都授给 **快捷指令 App**。

它们在 **系统设置 → 隐私与安全性** 里。如果某条音轨出来几乎是空的（只有几 KB），八成是缺权限——授权后，退出并重新打开启动它的那个 App，再录一次。

meetgist 还会**快速失败**：启动几秒后它就检查系统声音是不是真的在进来，一旦发现缺屏幕录制权限，会立刻停下并弹通知，而不是整场会都在录一个无声文件。麦克风没声音只会警告（listen-only 的会议本来就这样），系统声音照录不误。

---

## 常见问题

| 现象 | 解决 |
|---|---|
| `mic.m4a` / `system.m4a` 只有约 1 KB | 权限问题——见 [权限设置](#macos-权限)。 |
| 录音几秒就停，弹「no system audio」通知 | 缺屏幕录制权限——去授权（见 [权限设置](#macos-权限)），重启启动它的 App，再试。 |
| 弹「Mic looks silent」通知 | 麦克风没权限或被静音——只是警告，系统声音照录。listen-only 的会忽略即可。 |
| `GEMINI_API_KEY not set` | 把它加进 `scripts/.env`（该行必须以 `GEMINI_API_KEY=` 开头）。 |
| `postprocess.log` 里出现 `404 ... models/... is not found` | 你的 key 看不到那个模型——把 `GEMINI_MODEL` 换成上面列模型命令返回的某个。 |
| 录音开始了却一直没有「就绪」通知 | 查看 `~/Library/Caches/meetgist/meetgist.log` 和该会话的 `postprocess.log`。 |
| 按快捷键没反应 | 快捷指令 App 可能需要辅助功能权限；确认「用作快速操作」已勾选。 |
| 崩溃后残留的锁导致无法启动 | `rm ~/Library/Caches/meetgist/meetgist.pid` |
| 不重录、直接重转已有音频 | `scripts/transcribe_meeting.sh "<会话文件夹>"` |

---

## 隐私与法律

- **本地优先。** 只有 `postprocess.py` 运行时才会上传音频，而且只发往*你自己的* API key。没有第三方服务器、账号或遥测。
- **录音知情同意。** 不少地方（比如加州）要求**双方同意**才能录音。有他人在场时，请明确告知你在录音。遵守适用于你的法律是你自己的责任。
- `scripts/.env` 里的 API key 是明文，已被 git 忽略——千万别提交上去。

---

## 费用说明

- Gemini 音频上传量约为每小时会议 30 MB（两条音轨合计）。文件走 Gemini Files API，调用后即删（并会在 48 小时后自动过期）。
- 大批量处理前，先看一眼当前的 [Google AI Studio 定价](https://ai.google.dev/pricing)。日常使用，免费额度足够。

---

## 参与贡献

欢迎贡献！请先读 [CONTRIBUTING.md](CONTRIBUTING.md) 和[贡献者许可协议（CLA）](CLA.md)——首次提 PR 时 CLA 会自动接受。

---

## 许可证

Copyright © 2026 Longfu Xu.

meetgist 是自由软件，依据 **GNU Affero 通用公共许可证 v3.0** 授权（见 [LICENSE](LICENSE)）。你可以使用、研究、分享和修改它；但如果你把修改后的版本作为网络服务运行，就必须向用户提供其源代码。

贡献按一份 [CLA](CLA.md) 接受，使本项目日后仍可重新授权或双重授权，从而保留单独提供**商业许可**的可能。商业授权事宜，请通过 [GitHub](https://github.com/longfuxu) 联系维护者。
