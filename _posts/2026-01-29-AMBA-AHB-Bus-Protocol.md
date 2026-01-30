---
layout: post
title: "AMBA AHB 总线协议详解：从 AHB 2.0 到 AHB5-Lite"
date: 2026-01-29 16:30:00 +0800
categories: [数字IC, 总线协议]
tags: [AMBA, AHB, AHB-Lite, WaveDrom]
---

# AMBA AHB 总线协议详解

本文旨在介绍 AMBA 高级高性能总线（Advanced High-performance Bus, AHB）的架构、接口、协议及传输方式。内容参考了 ARM 官方文档：AMBA 2 AHB、AMBA 3 AHB-Lite 以及 AMBA 5 AHB-Lite。

## 1. 架构概述

AHB 总线是一种高性能、高时钟频率的系统总线，主要用于高性能、流水线设计的片上系统（SoC）。

### AHB (AMBA 2)
传统的 AHB 设计支持多主设备（Multi-Master）架构，包含以下组件：
*   **AHB Master**: 发起读写传输。
*   **AHB Slave**: 响应传输。
*   **AHB Arbiter**: 确保只有一个 Master 在总线上发起传输。
*   **AHB Decoder**: 对 Master 的地址进行译码，产生 Slave 选择信号（HSELx）。

### AHB-Lite (AMBA 3/5)
AHB-Lite 是 AHB 的简化版本，专为单主设备设计，不再需要 Arbiter，简化了设计复杂度。AMBA 5 AHB 则引入了更多特性如扩展内存类型支持和多层互连。

---

## 2. 接口信号

| 信号名 | 方向 | 描述 |
| :--- | :--- | :--- |
| **HCLK** | 全局 | 时钟信号，所有传输都在上升沿采样。 |
| **HRESETn** | 全局 | 复位信号，低电平有效。 |
| **HADDR** | M -> S | 32位系统地址总线。 |
| **HTRANS** | M -> S | 传输类型：IDLE, BUSY, NONSEQ, SEQ。 |
| **HWRITE** | M -> S | 1表示写，0表示读。 |
| **HSIZE** | M -> S | 传输大小：Byte, Halfword, Word等。 |
| **HBURST** | M -> S | 突发传输类型：SINGLE, INCR, WRAP4/8/16。 |
| **HWDATA** | M -> S | 写数据总线。 |
| **HSELx** | Decoder -> S | Slave 选择信号。 |
| **HREADY** | S -> M | 传输就绪信号。当为低时，表示 Slave 需要延长传输周期。 |
| **HRESP** | S -> M | 传输响应：OKAY, ERROR。 |
| **HRDATA** | S -> M | 读数据总线。 |

---

## 3. 传输方式与协议

AHB 传输有两个主要阶段：**地址阶段（Address Phase）**和**数据阶段（Data Phase）**。由于支持流水线操作，当前传输的地址阶段通常与上一次传输的数据阶段重叠。

### 3.1 传输类型 (HTRANS)
*   **IDLE (00)**: 无传输需求。
*   **BUSY (01)**: Master 仍在突发传输中，但由于某些原因无法立即提供下一个数据。
*   **NONSEQ (10)**: 一次突发传输的首个周期或单词传输。
*   **SEQ (11)**: 突发传输中的后续连续传输。

### 3.2 基本读写传输

#### 零等待传输 (Zero Wait States)
这是最基础的 AHB 传输。

```wavedrom
{ "signal": [
  { "name": "HCLK",    "wave": "p........." },
  { "name": "HADDR",   "wave": "x.3.4.x...", "data": ["A1", "A2"] },
  { "name": "HWRITE",  "wave": "x.5.x.....", "data": ["1 (Write)"] },
  { "name": "HTRANS",  "wave": "x.3.3.0...", "data": ["NONSEQ", "NONSEQ"] },
  { "name": "HWDATA",  "wave": "x...3.4.x.", "data": ["D1", "D2"] },
  { "name": "HREADY",  "wave": "1........." },
  { "name": "HRESP",   "wave": "0........." }
],
  "head": { "text": "AHB Write Transfer (Zero Wait)" }
}
```

#### 带等待状态的传输 (Wait States)
当 Slave 无法立即处理数据时，会将 `HREADY` 拉低。

```wavedrom
{ "signal": [
  { "name": "HCLK",    "wave": "p........." },
  { "name": "HADDR",   "wave": "x.3.x.....", "data": ["A"] },
  { "name": "HTRANS",  "wave": "x.3.0.....", "data": ["NONSEQ"] },
  { "name": "HREADY",  "wave": "1.0...1..." },
  { "name": "HWDATA",  "wave": "x.....3.x.", "data": ["D"] }
],
  "head": { "text": "AHB Write with Wait States" }
}
```

### 3.3 突发传输 (Burst Transfers)
AHB 支持 4、8、16 拍的增量（INCR）或回环（WRAP）传输。

*   **INCR**: 地址线性增加。
*   **WRAP**: 地址在到达边界后回环。例如 WRAP4 传输 Word (4-byte)，地址 0x0C 之后将回到 0x00。

#### 4-beat Incrementing Burst (INCR4)

```wavedrom
{ "signal": [
  { "name": "HCLK",    "wave": "p........." },
  { "name": "HADDR",   "wave": "x.3.3.3.3.x.", "data": ["A", "A+4", "A+8", "A+12"] },
  { "name": "HTRANS",  "wave": "x.3.4.4.4.0.", "data": ["NONSEQ", "SEQ", "SEQ", "SEQ"] },
  { "name": "HREADY",  "wave": "1..........." },
  { "name": "HWDATA",  "wave": "x...3.3.3.3.x", "data": ["D0", "D1", "D2", "D3"] }
],
  "head": { "text": "AHB INCR4 Burst Write" }
}
```

---

## 4. AHB5 的增强特性

在 AMBA 5 AHB 中，协议进行了进一步增强：
*   **Extended Memory Types**: 支持更细粒度的内存属性定义。
*   **Secure/Non-secure**: 增加了 `HNONSEC` 信号以支持 TrustZone。
*   **Exclusive Access**: 支持硬件原子操作。
*   **User Signals**: `HUSER` 允许在互连中传递自定义元数据。

---

## 5. 总结

AHB 总线通过流水线化的地址/数据阶段实现了极高的带宽。对于现代高性能 SoC，AHB-Lite 通常作为二级总线或外设互连的首选，而复杂的片上互连则多采用 AXI。

---
*参考文档：*
* *ARM IHI 0011A: AMBA 2 AHB*
* *ARM IHI 0033A: AMBA 3 AHB-Lite*
* *ARM IHI 0033C: AMBA 5 AHB-Lite*

```
verdvana/.clawdbot> clawdbot gateway status

🦞 Clawdbot 2026.1.24-3 (885167d) — The UNIX philosophy meets your DMs.

│
◇  
Service: systemd (enabled)
File logs: /tmp/clawdbot/clawdbot-2026-01-30.log
Command: /home/verdvana/.nvm/versions/node/v22.22.0/bin/node /home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/entry.js gateway --port 18789
Service file: ~/.config/systemd/user/clawdbot-gateway.service
Service env: CLAWDBOT_GATEWAY_PORT=18789

Service config looks out of date or non-standard.
Service config issue: Gateway service uses Node from a version manager; it can break after upgrades. (/home/verdvana/.nvm/versions/node/v22.22.0/bin/node)
Recommendation: run "clawdbot doctor" (or "clawdbot doctor --repair").
Config (cli): ~/.clawdbot/clawdbot.json
Config (service): ~/.clawdbot/clawdbot.json

Gateway: bind=loopback (127.0.0.1), port=18789 (service args)
Probe target: ws://127.0.0.1:18789
Dashboard: http://127.0.0.1:18789/
Probe note: Loopback-only gateway; only local clients can connect.

Runtime: running (pid 21366, state active, sub running, last exit 0, reason 0)
RPC probe: ok

Listening: 127.0.0.1:18789
Troubles: run clawdbot status
Troubleshooting: https://docs.clawd.bot/troubleshooting

verdvana/.clawdbot> clawdbot doctor

🦞 Clawdbot 2026.1.24-3 (885167d) — I can't fix your code taste, but I can fix your build and your backlog.

░████░█░░░░░█████░█░░░█░███░░████░░████░░▀█▀
█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░░█░█░░░█░░█░
█░░░░░█░░░░░█████░█░█░█░█░░█░████░░█░░░█░░█░
█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░█░░█░░░█░░█░
░████░█████░█░░░█░░█░█░░███░░████░░░███░░░█░
              🦞 FRESH DAILY 🦞┌  Clawdbot doctor
│
◇  Update ──────────────────────────────────────────────────────────────────────────────────╮
│                                                                                           │
│  This install is not a git checkout.                                                      │
│  Run `clawdbot update` to update via your package manager (npm/pnpm), then rerun doctor.  │
│                                                                                           │
├───────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Refresh expiring OAuth tokens now? (static tokens need re-auth)
│  Yes
│
◇  Model auth ───────────────────────────────────────────────────────────────────────────────╮
│                                                                                            │
│  - google-gemini-cli:verdvana@gmail.com: expiring (6m) — Re-auth via `clawdbot configure`  │
│    or `clawdbot onboard`.                                                                  │
│                                                                                            │
├────────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Gateway runtime ───────────────────────────────────────────────────────────────────────╮
│                                                                                         │
│  System Node unknown at /usr/bin/node is below the required Node 22+. Install Node 22+  │
│  from nodejs.org or Homebrew.                                                           │
│                                                                                         │
├─────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Gateway runtime ───────────────────────────────────────────────────────────────────────╮
│                                                                                         │
│  System Node 22+ not found. Install via Homebrew/apt/choco and rerun doctor to migrate  │
│  off Bun/version managers.                                                              │
│                                                                                         │
├─────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Gateway runtime ──────────────────────────────────────────────────────────────────────╮
│                                                                                        │
│  System Node unknown at /usr/bin/node is below the required Node 22+. Using            │
│  /home/verdvana/.nvm/versions/node/v22.22.0/bin/node for the daemon. Install Node 22+  │
│  from nodejs.org or Homebrew.                                                          │
│                                                                                        │
├────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Gateway service config ───────────────────────────────────────────────────────────╮
│                                                                                    │
│  - Gateway service uses Node from a version manager; it can break after upgrades.  │
│    (/home/verdvana/.nvm/versions/node/v22.22.0/bin/node)                           │
│                                                                                    │
├────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Update gateway service config to the recommended defaults now?
│  Yes

Installed systemd service: /home/verdvana/.config/systemd/user/clawdbot-gateway.service
│
◇  Security ─────────────────────────────────╮
│                                            │
│  - No channel security warnings detected.  │
│  - Run: clawdbot security audit --deep     │
│                                            │
├────────────────────────────────────────────╯
│
◇  Skills status ────────────╮
│                            │
│  Eligible: 10              │
│  Missing requirements: 39  │
│  Blocked by allowlist: 0   │
│                            │
├────────────────────────────╯
│
◇  Plugins ──────╮
│                │
│  Loaded: 3     │
│  Disabled: 25  │
│  Errors: 0     │
│                │
├────────────────╯
│
◇  
│
◇  Gateway ──────────────╮
│                        │
│  Gateway not running.  │
│                        │
├────────────────────────╯
│
◇  Gateway connection ─────────────────────────────╮
│                                                  │
│  Gateway target: ws://127.0.0.1:18789            │
│  Source: local loopback                          │
│  Config: /home/verdvana/.clawdbot/clawdbot.json  │
│  Bind: loopback                                  │
│                                                  │
├──────────────────────────────────────────────────╯
│
◇  Gateway ────────────────────────────────────────────────────────────────────────╮
│                                                                                  │
│  Runtime: running (pid 23961, state active, sub running, last exit 0, reason 0)  │
│                                                                                  │
├──────────────────────────────────────────────────────────────────────────────────╯
│
◇  Restart gateway service now?
│  Yes
Restarted systemd service: clawdbot-gateway.service
│
◇  
│
◇  Gateway ──────────────╮
│                        │
│  Gateway not running.  │
│                        │
├────────────────────────╯
│
◇  Gateway connection ─────────────────────────────╮
│                                                  │
│  Gateway target: ws://127.0.0.1:18789            │
│  Source: local loopback                          │
│  Config: /home/verdvana/.clawdbot/clawdbot.json  │
│  Bind: loopback                                  │
│                                                  │
├──────────────────────────────────────────────────╯
Run "clawdbot doctor --fix" to apply changes.
│
└  Doctor complete.


verdvana/.clawdbot> clawdbot logs --limit 200

🦞 Clawdbot 2026.1.24-3 (885167d) — I keep secrets like a vault... unless you print them in debug logs again.

│
◇  
Log file: /tmp/clawdbot/clawdbot-2026-01-30.log
05:43:00 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=session:agent:main:main durationMs=14389 active=0 queued=0
05:47:19 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 112ms conn=365622d3…e69f id=3c1ac7cf…31f0
05:48:55 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 69ms conn=45d7a447…7373 id=5fb5bed7…0b74
05:49:53 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 57ms conn=6d135958…fb5f id=383535df…9cd0
05:58:13 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=session:agent:main:main queueSize=1
05:58:13 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=session:agent:main:main waitMs=11 queueSize=0
05:58:13 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=main queueSize=1
05:58:13 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=main waitMs=1 queueSize=0
05:58:13 debug agent/embedded {"subsystem":"agent/embedded"} embedded run start: runId=409fb883-325c-48ba-b25b-8b449ea8f04b sessionId=723a039e-df19-430d-9f6c-7f0f8456f4a8 provider=google-gemini-cli model=gemini-3-pro-preview thinking=low messageChannel=telegram
05:58:13 info agent/embedded {"subsystem":"agent/embedded"} {"provider":"google-gemini-cli","toolCount":23,"tools":["0:read","1:edit","2:write","3:exec","4:process","5:browser","6:canvas","7:nodes","8:cron","9:message","10:tts","11:gateway","12:agents_list","13:sessions_list","14:sessions_history","15:sessions_send","16:sessions_spawn","17:session_status","18:web_search","19:web_fetch","20:image","21:memory_search","22:memory_get"]} google tool schema snapshot
05:58:13 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=723a039e-df19-430d-9f6c-7f0f8456f4a8 sessionKey=unknown prev=idle new=processing reason="run_started" queueDepth=0
05:58:13 debug diagnostic {"subsystem":"diagnostic"} run registered: sessionId=723a039e-df19-430d-9f6c-7f0f8456f4a8 totalActive=1
05:58:13 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt start: runId=409fb883-325c-48ba-b25b-8b449ea8f04b sessionId=723a039e-df19-430d-9f6c-7f0f8456f4a8
05:58:13 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent start: runId=409fb883-325c-48ba-b25b-8b449ea8f04b
05:58:20 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ chat.send 57ms runId=d76d1563-be7d-4b2b-a959-63bcc45f307c conn=6b7377d6…eb7c id=64691e50…975e
05:58:21 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=session:agent:main:main queueSize=2
05:58:29 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent end: runId=409fb883-325c-48ba-b25b-8b449ea8f04b
05:58:29 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt end: runId=409fb883-325c-48ba-b25b-8b449ea8f04b sessionId=723a039e-df19-430d-9f6c-7f0f8456f4a8 durationMs=15700
05:58:29 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=723a039e-df19-430d-9f6c-7f0f8456f4a8 sessionKey=unknown prev=processing new=idle reason="run_completed" queueDepth=0
05:58:29 debug diagnostic {"subsystem":"diagnostic"} run cleared: sessionId=723a039e-df19-430d-9f6c-7f0f8456f4a8 totalActive=0
05:58:29 debug agent/embedded {"subsystem":"agent/embedded"} embedded run done: runId=409fb883-325c-48ba-b25b-8b449ea8f04b sessionId=723a039e-df19-430d-9f6c-7f0f8456f4a8 durationMs=15758 aborted=false
05:58:29 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=main durationMs=15767 active=0 queued=0
05:58:29 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=session:agent:main:main durationMs=15770 active=0 queued=1
05:58:29 warn diagnostic {"subsystem":"diagnostic"} lane wait exceeded: lane=session:agent:main:main waitedMs=8552 queueAhead=0
05:58:29 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=session:agent:main:main waitMs=8552 queueSize=0
05:58:29 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=main queueSize=1
05:58:29 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=main waitMs=1 queueSize=0
05:58:29 debug agent/embedded {"subsystem":"agent/embedded"} embedded run start: runId=d76d1563-be7d-4b2b-a959-63bcc45f307c sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 provider=google-gemini-cli model=gemini-3-pro-preview thinking=low messageChannel=webchat
05:58:29 info agent/embedded {"subsystem":"agent/embedded"} {"provider":"google-gemini-cli","toolCount":23,"tools":["0:read","1:edit","2:write","3:exec","4:process","5:browser","6:canvas","7:nodes","8:cron","9:message","10:tts","11:gateway","12:agents_list","13:sessions_list","14:sessions_history","15:sessions_send","16:sessions_spawn","17:session_status","18:web_search","19:web_fetch","20:image","21:memory_search","22:memory_get"]} google tool schema snapshot
05:58:29 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 sessionKey=unknown prev=idle new=processing reason="run_started" queueDepth=0
05:58:29 debug diagnostic {"subsystem":"diagnostic"} run registered: sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 totalActive=1
05:58:29 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt start: runId=d76d1563-be7d-4b2b-a959-63bcc45f307c sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56
05:58:29 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent start: runId=d76d1563-be7d-4b2b-a959-63bcc45f307c
05:58:41 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent end: runId=d76d1563-be7d-4b2b-a959-63bcc45f307c
05:58:41 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt end: runId=d76d1563-be7d-4b2b-a959-63bcc45f307c sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 durationMs=11305
05:58:41 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 sessionKey=unknown prev=processing new=idle reason="run_completed" queueDepth=0
05:58:41 debug diagnostic {"subsystem":"diagnostic"} run cleared: sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 totalActive=0
05:58:41 debug agent/embedded {"subsystem":"agent/embedded"} embedded run done: runId=d76d1563-be7d-4b2b-a959-63bcc45f307c sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 durationMs=11402 aborted=false
05:58:41 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=main durationMs=11413 active=0 queued=0
05:58:41 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=session:agent:main:main durationMs=11418 active=0 queued=0
06:03:13 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ config.schema 220ms conn=6b7377d6…eb7c id=8a9dd15d…6e18
06:03:17 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ channels.status 3612ms conn=6b7377d6…eb7c id=76940f4e…6bac
06:05:16 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ chat.history 99ms conn=6b7377d6…eb7c id=920bbd85…381d
06:05:21 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=session:agent:main:main queueSize=1
06:05:21 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=session:agent:main:main waitMs=16 queueSize=0
06:05:21 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=main queueSize=1
06:05:21 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=main waitMs=2 queueSize=0
06:05:21 debug agent/embedded {"subsystem":"agent/embedded"} embedded run start: runId=b6ee4918-be4f-4a9b-a4cc-1951917a6590 sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 provider=google-gemini-cli model=gemini-3-pro-preview thinking=low messageChannel=webchat
06:05:21 info agent/embedded {"subsystem":"agent/embedded"} {"provider":"google-gemini-cli","toolCount":23,"tools":["0:read","1:edit","2:write","3:exec","4:process","5:browser","6:canvas","7:nodes","8:cron","9:message","10:tts","11:gateway","12:agents_list","13:sessions_list","14:sessions_history","15:sessions_send","16:sessions_spawn","17:session_status","18:web_search","19:web_fetch","20:image","21:memory_search","22:memory_get"]} google tool schema snapshot
06:05:21 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 sessionKey=unknown prev=idle new=processing reason="run_started" queueDepth=0
06:05:21 debug diagnostic {"subsystem":"diagnostic"} run registered: sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 totalActive=1
06:05:21 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt start: runId=b6ee4918-be4f-4a9b-a4cc-1951917a6590 sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56
06:05:21 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent start: runId=b6ee4918-be4f-4a9b-a4cc-1951917a6590
06:05:33 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent end: runId=b6ee4918-be4f-4a9b-a4cc-1951917a6590
06:05:33 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt end: runId=b6ee4918-be4f-4a9b-a4cc-1951917a6590 sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 durationMs=12376
06:05:33 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 sessionKey=unknown prev=processing new=idle reason="run_completed" queueDepth=0
06:05:33 debug diagnostic {"subsystem":"diagnostic"} run cleared: sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 totalActive=0
06:05:33 debug agent/embedded {"subsystem":"agent/embedded"} embedded run done: runId=b6ee4918-be4f-4a9b-a4cc-1951917a6590 sessionId=444d43b8-71d8-4b2d-b688-acfb4fb77d56 durationMs=12453 aborted=false
06:05:33 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=main durationMs=12462 active=0 queued=0
06:05:33 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=session:agent:main:main durationMs=12468 active=0 queued=0
06:05:43 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=session:agent:main:main queueSize=1
06:05:43 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=session:agent:main:main waitMs=19 queueSize=0
06:05:43 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=main queueSize=1
06:05:43 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=main waitMs=2 queueSize=0
06:05:43 debug agent/embedded {"subsystem":"agent/embedded"} embedded run start: runId=7d54fcbd-03e9-4ce2-9b87-898c638ecabe sessionId=c5d46930-774d-4af9-b8e0-328f4b93ecdf provider=google-gemini-cli model=gemini-3-pro-preview thinking=low messageChannel=webchat
06:05:43 info agent/embedded {"subsystem":"agent/embedded"} {"provider":"google-gemini-cli","toolCount":23,"tools":["0:read","1:edit","2:write","3:exec","4:process","5:browser","6:canvas","7:nodes","8:cron","9:message","10:tts","11:gateway","12:agents_list","13:sessions_list","14:sessions_history","15:sessions_send","16:sessions_spawn","17:session_status","18:web_search","19:web_fetch","20:image","21:memory_search","22:memory_get"]} google tool schema snapshot
06:05:43 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=c5d46930-774d-4af9-b8e0-328f4b93ecdf sessionKey=unknown prev=idle new=processing reason="run_started" queueDepth=0
06:05:43 debug diagnostic {"subsystem":"diagnostic"} run registered: sessionId=c5d46930-774d-4af9-b8e0-328f4b93ecdf totalActive=1
06:05:43 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt start: runId=7d54fcbd-03e9-4ce2-9b87-898c638ecabe sessionId=c5d46930-774d-4af9-b8e0-328f4b93ecdf
06:05:43 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent start: runId=7d54fcbd-03e9-4ce2-9b87-898c638ecabe
06:05:56 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent end: runId=7d54fcbd-03e9-4ce2-9b87-898c638ecabe
06:05:56 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt end: runId=7d54fcbd-03e9-4ce2-9b87-898c638ecabe sessionId=c5d46930-774d-4af9-b8e0-328f4b93ecdf durationMs=12208
06:05:56 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=c5d46930-774d-4af9-b8e0-328f4b93ecdf sessionKey=unknown prev=processing new=idle reason="run_completed" queueDepth=0
06:05:56 debug diagnostic {"subsystem":"diagnostic"} run cleared: sessionId=c5d46930-774d-4af9-b8e0-328f4b93ecdf totalActive=0
06:05:56 debug agent/embedded {"subsystem":"agent/embedded"} embedded run done: runId=7d54fcbd-03e9-4ce2-9b87-898c638ecabe sessionId=c5d46930-774d-4af9-b8e0-328f4b93ecdf durationMs=12311 aborted=false
06:05:56 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=main durationMs=12341 active=0 queued=0
06:05:56 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=session:agent:main:main durationMs=12346 active=0 queued=0
06:08:57 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 63ms conn=f63ea0c4…8143 id=a67f69dc…0d75
06:09:03 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 115ms conn=f55db1c1…d75f id=0a24bd5b…6e4c
06:09:21 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 73ms conn=99adf8ab…d3db id=5833b1c7…0737
06:10:08 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=session:agent:main:main queueSize=1
06:10:08 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=session:agent:main:main waitMs=13 queueSize=0
06:10:08 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=main queueSize=1
06:10:08 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=main waitMs=2 queueSize=0
06:10:08 debug agent/embedded {"subsystem":"agent/embedded"} embedded run start: runId=0f249b30-5607-43ef-ab18-8975f3d4962d sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 provider=google-gemini-cli model=gemini-3-pro-preview thinking=low messageChannel=webchat
06:10:08 info agent/embedded {"subsystem":"agent/embedded"} {"provider":"google-gemini-cli","toolCount":23,"tools":["0:read","1:edit","2:write","3:exec","4:process","5:browser","6:canvas","7:nodes","8:cron","9:message","10:tts","11:gateway","12:agents_list","13:sessions_list","14:sessions_history","15:sessions_send","16:sessions_spawn","17:session_status","18:web_search","19:web_fetch","20:image","21:memory_search","22:memory_get"]} google tool schema snapshot
06:10:08 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 sessionKey=unknown prev=idle new=processing reason="run_started" queueDepth=0
06:10:08 debug diagnostic {"subsystem":"diagnostic"} run registered: sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 totalActive=1
06:10:08 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt start: runId=0f249b30-5607-43ef-ab18-8975f3d4962d sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356
06:10:08 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent start: runId=0f249b30-5607-43ef-ab18-8975f3d4962d
06:10:20 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent end: runId=0f249b30-5607-43ef-ab18-8975f3d4962d
06:10:20 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt end: runId=0f249b30-5607-43ef-ab18-8975f3d4962d sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 durationMs=11870
06:10:20 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 sessionKey=unknown prev=processing new=idle reason="run_completed" queueDepth=0
06:10:20 debug diagnostic {"subsystem":"diagnostic"} run cleared: sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 totalActive=0
06:10:20 debug agent/embedded {"subsystem":"agent/embedded"} embedded run done: runId=0f249b30-5607-43ef-ab18-8975f3d4962d sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 durationMs=11946 aborted=false
06:10:20 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=main durationMs=11952 active=0 queued=0
06:10:20 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=session:agent:main:main durationMs=11956 active=0 queued=0
06:10:29 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=session:agent:main:main queueSize=1
06:10:29 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=session:agent:main:main waitMs=14 queueSize=0
06:10:29 debug diagnostic {"subsystem":"diagnostic"} lane enqueue: lane=main queueSize=1
06:10:29 debug diagnostic {"subsystem":"diagnostic"} lane dequeue: lane=main waitMs=1 queueSize=0
06:10:29 debug agent/embedded {"subsystem":"agent/embedded"} embedded run start: runId=f82a8677-807b-4f0b-a8e1-980fda585262 sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 provider=google-gemini-cli model=gemini-3-pro-preview thinking=low messageChannel=webchat
06:10:29 info agent/embedded {"subsystem":"agent/embedded"} {"provider":"google-gemini-cli","toolCount":23,"tools":["0:read","1:edit","2:write","3:exec","4:process","5:browser","6:canvas","7:nodes","8:cron","9:message","10:tts","11:gateway","12:agents_list","13:sessions_list","14:sessions_history","15:sessions_send","16:sessions_spawn","17:session_status","18:web_search","19:web_fetch","20:image","21:memory_search","22:memory_get"]} google tool schema snapshot
06:10:29 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 sessionKey=unknown prev=idle new=processing reason="run_started" queueDepth=0
06:10:29 debug diagnostic {"subsystem":"diagnostic"} run registered: sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 totalActive=1
06:10:29 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt start: runId=f82a8677-807b-4f0b-a8e1-980fda585262 sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356
06:10:29 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent start: runId=f82a8677-807b-4f0b-a8e1-980fda585262
06:10:41 debug agent/embedded {"subsystem":"agent/embedded"} embedded run agent end: runId=f82a8677-807b-4f0b-a8e1-980fda585262
06:10:41 debug agent/embedded {"subsystem":"agent/embedded"} embedded run prompt end: runId=f82a8677-807b-4f0b-a8e1-980fda585262 sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 durationMs=12344
06:10:41 debug diagnostic {"subsystem":"diagnostic"} session state: sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 sessionKey=unknown prev=processing new=idle reason="run_completed" queueDepth=0
06:10:41 debug diagnostic {"subsystem":"diagnostic"} run cleared: sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 totalActive=0
06:10:41 debug agent/embedded {"subsystem":"agent/embedded"} embedded run done: runId=f82a8677-807b-4f0b-a8e1-980fda585262 sessionId=fb713608-a81a-4f1a-b29a-9c5724d9a356 durationMs=12410 aborted=false
06:10:41 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=main durationMs=12430 active=0 queued=0
06:10:41 debug diagnostic {"subsystem":"diagnostic"} lane task done: lane=session:agent:main:main durationMs=12435 active=0 queued=0
06:11:09 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 63ms conn=560d03e2…053e id=6e3899e8…39b9
06:12:50 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 51ms conn=b87973a5…52da id=1c1342f5…12aa
06:15:03 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 50ms conn=8d3f897c…7cda id=0dcb2f8c…92e2
06:16:50 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ logs.tail 55ms conn=91db1be8…2652 id=15644364…be2d
06:19:04 info ░████░█░░░░░█████░█░░░█░███░░████░░████░░▀█▀
█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░░█░█░░░█░░█░
█░░░░░█░░░░░█████░█░█░█░█░░█░████░░█░░░█░░█░
█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░█░░█░░░█░░█░
░████░█████░█░░░█░░█░█░░███░░████░░░███░░░█░
              🦞 FRESH DAILY 🦞06:19:28 info Telegram: ok (@verdvana_bot) (3449ms)
06:19:28 info Agents: main (default)
06:19:28 info Heartbeat interval: 30m (main)
06:19:28 info Session store (main): /home/verdvana/.clawdbot/agents/main/sessions/sessions.json (1 entries)
06:19:28 info - agent:main:main (9m ago)
06:19:31 info Run "clawdbot doctor --fix" to apply changes.
06:19:31 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ channels.status 3158ms conn=a1b0f223…fa68 id=73c4fa05…20f7
06:21:33 info 2026.1.24-3
06:24:52 info Service: systemd (enabled)
06:24:52 info File logs: /tmp/clawdbot/clawdbot-2026-01-30.log
06:24:52 info Command: /home/verdvana/.nvm/versions/node/v22.22.0/bin/node /home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/entry.js gateway --port 18789
06:24:52 info Service file: ~/.config/systemd/user/clawdbot-gateway.service
06:24:52 info Service env: CLAWDBOT_GATEWAY_PORT=18789
06:24:52 info {"0":"","_meta":{"runtime":"node","runtimeVersion":"22.22.0","hostname":"localhost.localdomain","name":"clawdbot","date":"2026-01-30T06:24:52.773Z","logLevelId":3,"logLevelName":"INFO","path":{"fullFilePath":"file:///home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js:181:32","fileName":"console.js","fileNameWithLine":"console.js:181","fileColumn":"32","fileLine":"181","filePath":"/home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js","filePathWithLine":"/home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js:181","method":"console.log"}},"time":"2026-01-30T06:24:52.774Z"}
06:24:52 error Service config looks out of date or non-standard.
06:24:52 error Service config issue: Gateway service uses Node from a version manager; it can break after upgrades. (/home/verdvana/.nvm/versions/node/v22.22.0/bin/node)
06:24:52 error Recommendation: run "clawdbot doctor" (or "clawdbot doctor --repair").
06:24:52 info Config (cli): ~/.clawdbot/clawdbot.json
06:24:52 info Config (service): ~/.clawdbot/clawdbot.json
06:24:52 info {"0":"","_meta":{"runtime":"node","runtimeVersion":"22.22.0","hostname":"localhost.localdomain","name":"clawdbot","date":"2026-01-30T06:24:52.782Z","logLevelId":3,"logLevelName":"INFO","path":{"fullFilePath":"file:///home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js:181:32","fileName":"console.js","fileNameWithLine":"console.js:181","fileColumn":"32","fileLine":"181","filePath":"/home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js","filePathWithLine":"/home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js:181","method":"console.log"}},"time":"2026-01-30T06:24:52.782Z"}
06:24:52 info Gateway: bind=loopback (127.0.0.1), port=18789 (service args)
06:24:52 info Probe target: ws://127.0.0.1:18789
06:24:52 info Dashboard: http://127.0.0.1:18789/
06:24:52 info Probe note: Loopback-only gateway; only local clients can connect.
06:24:52 info {"0":"","_meta":{"runtime":"node","runtimeVersion":"22.22.0","hostname":"localhost.localdomain","name":"clawdbot","date":"2026-01-30T06:24:52.787Z","logLevelId":3,"logLevelName":"INFO","path":{"fullFilePath":"file:///home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js:181:32","fileName":"console.js","fileNameWithLine":"console.js:181","fileColumn":"32","fileLine":"181","filePath":"/home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js","filePathWithLine":"/home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js:181","method":"console.log"}},"time":"2026-01-30T06:24:52.788Z"}
06:24:52 info Runtime: running (pid 21366, state active, sub running, last exit 0, reason 0)
06:24:52 info RPC probe: ok
06:24:52 info {"0":"","_meta":{"runtime":"node","runtimeVersion":"22.22.0","hostname":"localhost.localdomain","name":"clawdbot","date":"2026-01-30T06:24:52.790Z","logLevelId":3,"logLevelName":"INFO","path":{"fullFilePath":"file:///home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js:181:32","fileName":"console.js","fileNameWithLine":"console.js:181","fileColumn":"32","fileLine":"181","filePath":"/home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js","filePathWithLine":"/home/verdvana/.nvm/versions/node/v22.22.0/lib/node_modules/clawdbot/dist/logging/console.js:181","method":"console.log"}},"time":"2026-01-30T06:24:52.791Z"}
06:24:52 info Listening: 127.0.0.1:18789
06:24:52 info Troubles: run clawdbot status
06:24:52 info Troubleshooting: https://docs.clawd.bot/troubleshooting
06:25:47 error [clawdbot] Unhandled promise rejection: TypeError: fetch failed
    at node:internal/deps/undici/undici:14902:13
    at processTicksAndRejections (node:internal/process/task_queues:105:5)
06:26:06 info gateway/canvas {"subsystem":"gateway/canvas"} canvas host mounted at http://127.0.0.1:18789/__clawdbot__/canvas/ (root /home/verdvana/clawd/canvas)
06:26:06 info ░████░█░░░░░█████░█░░░█░███░░████░░████░░▀█▀
█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░░█░█░░░█░░█░
█░░░░░█░░░░░█████░█░█░█░█░░█░████░░█░░░█░░█░
█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░█░░█░░░█░░█░
░████░█████░█░░░█░░█░█░░███░░████░░░███░░░█░
              🦞 FRESH DAILY 🦞06:26:07 info gateway/heartbeat {"subsystem":"gateway/heartbeat"} {"intervalMs":1800000} heartbeat: started
06:26:07 info gateway {"subsystem":"gateway"} agent model: google-gemini-cli/gemini-3-pro-preview
06:26:07 info gateway {"subsystem":"gateway"} listening on ws://127.0.0.1:18789 (PID 23902)
06:26:07 info gateway {"subsystem":"gateway"} listening on ws://[::1]:18789
06:26:07 info gateway {"subsystem":"gateway"} log file: /tmp/clawdbot/clawdbot-2026-01-30.log
06:26:07 info browser/server {"subsystem":"browser/server"} Browser control listening on http://127.0.0.1:18791/
06:26:07 info cron {"module":"cron","storePath":"/home/verdvana/.clawdbot/cron/jobs.json"} {"enabled":true,"jobs":0,"nextWakeAtMs":null} cron: started
06:26:08 info bonjour: advertised gateway fqdn=localhost.localdomain (Clawdbot)._clawdbot-gw._tcp.local. host=localhost.local. port=18789 state=announcing
06:26:09 info gateway/channels/telegram {"subsystem":"gateway/channels/telegram"} [default] starting provider
06:26:09 debug skills {"subsystem":"skills"} {"rawName":"openai-image-gen","sanitized":"/openai_image_gen"} Sanitized skill command name "openai-image-gen" to "/openai_image_gen".
06:26:09 debug skills {"subsystem":"skills"} {"rawName":"openai-whisper-api","sanitized":"/openai_whisper_api"} Sanitized skill command name "openai-whisper-api" to "/openai_whisper_api".
06:26:09 debug skills {"subsystem":"skills"} {"rawName":"skill-creator","sanitized":"/skill_creator"} Sanitized skill command name "skill-creator" to "/skill_creator".
06:26:14 error gateway/channels/telegram {"subsystem":"gateway/channels/telegram"} telegram setMyCommands failed: HttpError: Network request for 'setMyCommands' failed!
06:26:14 error [clawdbot] Unhandled promise rejection: TypeError: fetch failed
    at node:internal/deps/undici/undici:14902:13
    at processTicksAndRejections (node:internal/process/task_queues:105:5)
06:26:32 info gateway {"subsystem":"gateway"} signal SIGTERM received
06:26:32 info gateway {"subsystem":"gateway"} received SIGTERM; shutting down
06:26:34 info Run "clawdbot doctor --fix" to apply changes.
06:26:46 info gateway/canvas {"subsystem":"gateway/canvas"} canvas host mounted at http://127.0.0.1:18789/__clawdbot__/canvas/ (root /home/verdvana/clawd/canvas)
06:26:47 info gateway/heartbeat {"subsystem":"gateway/heartbeat"} {"intervalMs":1800000} heartbeat: started
06:26:47 info gateway {"subsystem":"gateway"} agent model: google-gemini-cli/gemini-3-pro-preview
06:26:47 info gateway {"subsystem":"gateway"} listening on ws://127.0.0.1:18789 (PID 24001)
06:26:47 info gateway {"subsystem":"gateway"} listening on ws://[::1]:18789
06:26:47 info gateway {"subsystem":"gateway"} log file: /tmp/clawdbot/clawdbot-2026-01-30.log
06:26:47 info browser/server {"subsystem":"browser/server"} Browser control listening on http://127.0.0.1:18791/
06:26:47 info cron {"module":"cron","storePath":"/home/verdvana/.clawdbot/cron/jobs.json"} {"enabled":true,"jobs":0,"nextWakeAtMs":null} cron: started
06:26:48 info bonjour: advertised gateway fqdn=localhost.localdomain (Clawdbot)._clawdbot-gw._tcp.local. host=localhost.local. port=18789 state=announcing
06:26:49 info gateway/ws {"subsystem":"gateway/ws"} webchat connected conn=d335eaed-f87f-4c63-b374-b57462cf6985 remote=127.0.0.1 client=clawdbot-control-ui webchat vdev
06:26:49 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ node.list 93ms conn=d335eaed…6985 id=db90f5e1…eddc
06:26:49 info gateway/ws {"subsystem":"gateway/ws"} ⇄ res ✓ device.pair.list 117ms conn=d335eaed…6985 id=c1f4974a…1fe0
06:26:52 info gateway/channels/telegram {"subsystem":"gateway/channels/telegram"} [default] starting provider (@verdvana_bot)
06:26:52 debug skills {"subsystem":"skills"} {"rawName":"openai-image-gen","sanitized":"/openai_image_gen"} Sanitized skill command name "openai-image-gen" to "/openai_image_gen".
06:26:52 debug skills {"subsystem":"skills"} {"rawName":"openai-whisper-api","sanitized":"/openai_whisper_api"} Sanitized skill command name "openai-whisper-api" to "/openai_whisper_api".
06:26:52 debug skills {"subsystem":"skills"} {"rawName":"skill-creator","sanitized":"/skill_creator"} Sanitized skill command name "skill-creator" to "/skill_creator".
06:26:57 error [clawdbot] Unhandled promise rejection: TypeError: fetch failed
    at node:internal/deps/undici/undici:14902:13
    at processTicksAndRejections (node:internal/process/task_queues:105:5)
06:27:15 info gateway/canvas {"subsystem":"gateway/canvas"} canvas host mounted at http://127.0.0.1:18789/__clawdbot__/canvas/ (root /home/verdvana/clawd/canvas)
06:27:15 info gateway/heartbeat {"subsystem":"gateway/heartbeat"} {"intervalMs":1800000} heartbeat: started
06:27:15 info gateway {"subsystem":"gateway"} agent model: google-gemini-cli/gemini-3-pro-preview
06:27:15 info gateway {"subsystem":"gateway"} listening on ws://127.0.0.1:18789 (PID 24029)
06:27:15 info gateway {"subsystem":"gateway"} listening on ws://[::1]:18789
06:27:15 info gateway {"subsystem":"gateway"} log file: /tmp/clawdbot/clawdbot-2026-01-30.log
06:27:15 info browser/server {"subsystem":"browser/server"} Browser control listening on http://127.0.0.1:18791/
06:27:15 info cron {"module":"cron","storePath":"/home/verdvana/.clawdbot/cron/jobs.json"} {"enabled":true,"jobs":0,"nextWakeAtMs":null} cron: started
06:27:16 info bonjour: advertised gateway fqdn=localhost.localdomain (Clawdbot)._clawdbot-gw._tcp.local. host=localhost.local. port=18789 state=announcing
06:27:18 info gateway/channels/telegram {"subsystem":"gateway/channels/telegram"} [default] starting provider
06:27:18 debug skills {"subsystem":"skills"} {"rawName":"openai-image-gen","sanitized":"/openai_image_gen"} Sanitized skill command name "openai-image-gen" to "/openai_image_gen".
06:27:18 debug skills {"subsystem":"skills"} {"rawName":"openai-whisper-api","sanitized":"/openai_whisper_api"} Sanitized skill command name "openai-whisper-api" to "/openai_whisper_api".
06:27:18 debug skills {"subsystem":"skills"} {"rawName":"skill-creator","sanitized":"/skill_creator"} Sanitized skill command name "skill-creator" to "/skill_creator".
Log tail truncated (increase --max-bytes).


verdvana/.clawdbot> clawdbot plugins list | egrep 'google-gemini-cli-auth|google-antigravity-autj'
│ Gemini CLI   │ gemini-  │          │ extensions/google-gemini-cli-auth/index.ts                         │           │
verdvana/.clawdbot> clawdbot plugins list | egrep 'google-gemini-cli-auth|google-antigravity-auth'
│ google-      │ antigrav │          │ extensions/google-antigravity-auth/index.ts                        │           │
│ Gemini CLI   │ gemini-  │          │ extensions/google-gemini-cli-auth/index.ts                         │           │
verdvana/.clawdbot> clawdbot models status

🦞 Clawdbot 2026.1.24-3 (885167d) — Your config is valid, your assumptions are not.

Config        : ~/.clawdbot/clawdbot.json
Agent dir     : ~/.clawdbot/agents/main/agent
Default       : google-gemini-cli/gemini-3-pro-preview
Fallbacks (0) : -
Image model   : -
Image fallbacks (0): -
Aliases (0)   : -
Configured models (1): google-gemini-cli/gemini-3-pro-preview

Auth overview
Auth store    : ~/.clawdbot/agents/main/agent/auth-profiles.json
Shell env     : off
Providers w/ OAuth/tokens (1): google-gemini-cli (1)
- google effective=profiles:~/.clawdbot/agents/main/agent/auth-profiles.json | profiles=1 (oauth=0, token=0, api_key=1) | google:default=AIzaSyAY...3JjRXRA8 | env=AIzaSyAY...3JjRXRA8 | source=env: GEMINI_API_KEY
- google-gemini-cli effective=profiles:~/.clawdbot/agents/main/agent/auth-profiles.json | profiles=1 (oauth=1, token=0, api_key=0) | google-gemini-cli:verdvana@gmail.com=OAuth (verdvana@gmail.com)
- openai effective=env:sk-proj-...QLZHTAsA | env=sk-proj-...QLZHTAsA | source=env: OPENAI_API_KEY

OAuth/token status
- google-gemini-cli
  - google-gemini-cli:verdvana@gmail.com (verdvana@gmail.com) expiring expires in 2m
verdvana/.clawdbot> clawdbot models list | head -n 80
Model                                      Input      Ctx      Local Auth  Tags
google-gemini-cli/gemini-3-pro-preview     text+image 1024k    no    yes   default,configured
verdvana/.clawdbot> clawdbot config get agents.defaults.model.primary

🦞 Clawdbot 2026.1.24-3 (885167d) — Works on Android. Crazy concept, we know.

google-gemini-cli/gemini-3-pro-preview
verdvana/.clawdbot> clawdbot config get agents.defaults.model

🦞 Clawdbot 2026.1.24-3 (885167d) — I keep secrets like a vault... unless you print them in debug logs again.

{
  "primary": "google-gemini-cli/gemini-3-pro-preview"
}

verdvana/.clawdbot> systemctl --user status clawdbot
Unit clawdbot.service could not be found.
verdvana/.clawdbot> journalctl --user -u clawdbot -n 120 --no-pager
Hint: You are currently not seeing messages from the system.
      Users in the 'systemd-journal' group can see all messages. Pass -q to
      turn off this notice.
No journal files were opened due to insufficient permissions.
verdvana/.clawdbot> sudo systemctl --user status clawdbot
[sudo] password for root: 
Failed to connect to bus: $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined (consider using --machine=<user>@.host --user to connect to bus of other user)
verdvana/.clawdbot> sudo journalctl --user -u clawdbot -n 120 --no-pager
No journal files were found.
-- No entries --

```