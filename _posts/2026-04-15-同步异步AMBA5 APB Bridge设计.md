---
layout: post
title:  "同步异步AMBA5 APB Bridge设计"
date:   2026-04-15 11:15:00 +0700
tags: 
  - Bus
  - RTL
  - Verilog HDL
  - IC
  - FPGA
---

![SPI_Intro][SPI_Intro]

-------

## 1 前言

&#160; &#160; &#160; &#160; 在现代 SoC 设计中，APB（Advanced Peripheral Bus）总线被广泛用于连接低速外设（CSR 寄存器、GPIO、UART 等）。随着多时钟域设计的普及，APB 主端（Initiator）与从端（Target）往往工作在不同频率的时钟域下，直接互连会引入**亚稳态（Metastability）**，导致功能错误甚至硅片 Bug。


&#160; &#160; &#160; &#160; 本模块（`apb5_bridge`）实现了一个完整的 **AMBA5 APB 协议桥**，支持：
- **同步模式**：主从端工作在同一时钟域，直通转发，面积最小
- **异步模式**：主从端工作在不同时钟域，通过四相握手（4-Phase Handshake）+ 双触发器同步器保证 CDC 安全

&#160; &#160; &#160; &#160; 设计目标：

| 目标             | 说明                                                         |
|------------------|--------------------------------------------------------------|
| 协议合规         | 完整支持 AMBA 5 APB 规范，包括 PNSE、PWAKEUP、用户信号扩展 |
| CDC 安全         | 异步模式采用四相握手 + DEMET 同步器，通过 SpyGlass CDC 检查  |
| 完全参数化       | 数据/地址/用户信号位宽均可配置                               |
| 可综合           | 全部 RTL 使用标准 SystemVerilog 语法，无不可综合结构         |
| STA 可签核       | 提供完整 SDC 约束，支持 PrimeTime / Tempus 时序签核          |

&#160; &#160; &#160; &#160; 交付文件清单：

| 文件名                      | 类型         | 说明                                   |
|-----------------------------|--------------|----------------------------------------|
| `apb5_bridge.sv`            | RTL          | 模块主体，含同步桥、异步桥、同步器      |
| `apb5_bridge_cdc.tcl`       | CDC 约束     | SpyGlass SGdc 格式，共 10 节 409 行     |
| `apb5_bridge_cdc.sdc`       | CDC SDC      | CDC 配套时序约束，185 行               |
| `apb5_bridge_sta.sdc`       | STA SDC      | 完整 STA 时序约束，777 行              |
| `apb5_bridge_tb.sv`         | Testbench    | 仿真文件                                 |

-------

## 2 功能描述

### 2.1 总体功能


&#160; &#160; &#160; &#160; `apb5_bridge` 是一个**单事务（Single Outstanding Transaction）APB 协议桥**，将来自主端的 APB5 传输请求转发到从端，并将从端响应回传给主端。

```
APB Initiator                                  APB Target
(M_PCLK 域)         apb5_bridge               (S_PCLK 域)
   PSEL    ─────▶  ┌─────────────┐  ─────▶    PSEL
   PENABLE ─────▶  │ 同步/异步桥  │  ─────▶    PENABLE
   PADDR   ─────▶  │             │  ─────▶    PADDR
   PWDATA  ─────▶  │ ASYNC_MODE  │  ─────▶    PWDATA
   PREADY  ◀─────  │  0=同步     │  ◀─────    PREADY
   PRDATA  ◀─────  │  1=异步     │  ◀─────    PRDATA
           ...      └─────────────┘            ...
```


### 2.2 工作模式

#### 2.2.1 同步模式（ASYNC_MODE = 0）



- 主从端共用同一时钟（`M_PCLK`，`S_PCLK` 端口悬空或接同一时钟）
- 桥内部实现标准三态 APB FSM（IDLE → SETUP → ACCESS）
- 支持**背靠背（Back-to-Back）传输**：当前传输完成时若已有新请求，直接进入下一 SETUP
- 面积开销极小，延迟为 0 个额外时钟周期


#### 2.2.2 异步模式（ASYNC_MODE = 1）

- 主从端使用独立时钟（`M_PCLK` 和 `S_PCLK`），频率/相位无要求
- 采用 **Toggle + 双触发器同步器 + 四相握手** 机制保证 CDC 安全
- 每笔传输额外延迟 ≥ 2×`S_PCLK` + 2×`M_PCLK` 周期
- 同一时刻只支持**一笔在途事务**（Single Inflight Transaction）

### 2.3 AMBA 5 APB 新增信号支持

| 信号      | AMBA 版本 | 功能                                  |
|-----------|-----------|---------------------------------------|
| `PNSE`    | AMBA 5    | Non-Secure Extension，标识非安全访问  |
| `PWAKEUP` | AMBA 5    | 低功耗唤醒信号，在传输前拉高通知从端  |
| `PAUSER`  | AMBA 5    | 地址阶段用户自定义扩展信号            |
| `PWUSER`  | AMBA 5    | 写数据阶段用户自定义扩展信号          |
| `PRUSER`  | AMBA 5    | 读数据阶段用户自定义扩展信号          |
| `PBUSER`  | AMBA 5    | 桥响应阶段用户自定义扩展信号          |

### 2.4 已知限制

| 限制                             | 说明                                        |
|----------------------------------|---------------------------------------------|
| 异步模式不支持背靠背传输         | 每笔传输需完成完整四相握手后才能发起下一笔  |
| 单事务在途                       | 不支持流水线或乱序                          |
| 用户信号位宽参数需两端一致       | PAUSER/PWUSER 等位宽由顶层参数统一控制      |
| 异步复位撤销无同步               | 两端复位撤销时序需系统级保证               |

---
## 3. 接口描述

### 3.1 时钟与复位

| 信号名       | 方向 | 位宽 | 时钟域  | 描述                                      |
|--------------|------|------|---------|-------------------------------------------|
| `M_PCLK`     | 输入 | 1    | —       | 主端 APB 时钟                             |
| `M_PRESETn`  | 输入 | 1    | M_PCLK  | 主端同步复位，低有效                      |
| `S_PCLK`     | 输入 | 1    | —       | 从端 APB 时钟（同步模式与 M_PCLK 相同）  |
| `S_PRESETn`  | 输入 | 1    | S_PCLK  | 从端同步复位，低有效                      |

### 3.2 主端控制信号（APB Initiator → Bridge）

| 信号名       | 方向 | 位宽          | 时钟域 | 描述                              |
|--------------|------|---------------|--------|-----------------------------------|
| `M_PADDR`    | 输入 | ADDR_WIDTH    | M_PCLK | APB 地址总线                      |
| `M_PPROT`    | 输入 | 3             | M_PCLK | 保护类型（特权/安全/指令）        |
| `M_PNSE`     | 输入 | 1             | M_PCLK | 非安全扩展位（AMBA5）             |
| `M_PSEL`     | 输入 | 1             | M_PCLK | 从设备片选，高有效                |
| `M_PENABLE`  | 输入 | 1             | M_PCLK | 访问使能（SETUP=0，ACCESS=1）     |
| `M_PWRITE`   | 输入 | 1             | M_PCLK | 传输方向（1=写，0=读）            |
| `M_PSTRB`    | 输入 | STRB_WIDTH    | M_PCLK | 字节使能，每位对应一字节          |
| `M_PWAKEUP`  | 输入 | 1             | M_PCLK | 低功耗唤醒信号（AMBA5）           |
| `M_PAUSER`   | 输入 | PAUSER_WIDTH  | M_PCLK | 地址阶段用户扩展信号              |

### 3.3 主端数据信号

| 信号名       | 方向 | 位宽          | 时钟域 | 描述             |
|--------------|------|---------------|--------|------------------|
| `M_PWDATA`   | 输入 | DATA_WIDTH    | M_PCLK | 写数据总线       |
| `M_PWUSER`   | 输入 | PWUSER_WIDTH  | M_PCLK | 写数据用户扩展   |

### 3.4 主端响应信号（Bridge → APB Initiator）

| 信号名       | 方向 | 位宽          | 时钟域 | 描述                          |
|--------------|------|---------------|--------|-------------------------------|
| `M_PREADY`   | 输出 | 1             | M_PCLK | 从端就绪，高有效              |
| `M_PRDATA`   | 输出 | DATA_WIDTH    | M_PCLK | 读数据总线                    |
| `M_PSLVERR`  | 输出 | 1             | M_PCLK | 从端错误标志，高有效          |
| `M_PRUSER`   | 输出 | PRUSER_WIDTH  | M_PCLK | 读数据用户扩展信号            |
| `M_PBUSER`   | 输出 | PBUSER_WIDTH  | M_PCLK | 桥响应用户扩展信号            |

### 3.5 从端控制信号（Bridge → APB Target）

| 信号名       | 方向 | 位宽          | 时钟域 | 描述                      |
|--------------|------|---------------|--------|---------------------------|
| `S_PADDR`    | 输出 | ADDR_WIDTH    | S_PCLK | APB 从端地址总线          |
| `S_PPROT`    | 输出 | 3             | S_PCLK | 保护类型                  |
| `S_PNSE`     | 输出 | 1             | S_PCLK | 非安全扩展位              |
| `S_PSEL`     | 输出 | 1             | S_PCLK | 片选信号                  |
| `S_PENABLE`  | 输出 | 1             | S_PCLK | 访问使能                  |
| `S_PWRITE`   | 输出 | 1             | S_PCLK | 传输方向                  |
| `S_PSTRB`    | 输出 | STRB_WIDTH    | S_PCLK | 字节使能                  |
| `S_PWAKEUP`  | 输出 | 1             | S_PCLK | 低功耗唤醒                |
| `S_PAUSER`   | 输出 | PAUSER_WIDTH  | S_PCLK | 地址用户扩展              |

### 3.6 从端数据与响应信号

| 信号名       | 方向 | 位宽          | 时钟域 | 描述                      |
|--------------|------|---------------|--------|---------------------------|
| `S_PWDATA`   | 输出 | DATA_WIDTH    | S_PCLK | 写数据总线                |
| `S_PWUSER`   | 输出 | PWUSER_WIDTH  | S_PCLK | 写数据用户扩展            |
| `S_PREADY`   | 输入 | 1             | S_PCLK | 从端就绪                  |
| `S_PRDATA`   | 输入 | DATA_WIDTH    | S_PCLK | 读数据总线                |
| `S_PSLVERR`  | 输入 | 1             | S_PCLK | 从端错误标志              |
| `S_PRUSER`   | 输入 | PRUSER_WIDTH  | S_PCLK | 读数据用户扩展            |
| `S_PBUSER`   | 输入 | PBUSER_WIDTH  | S_PCLK | 桥响应用户扩展            |

---
## 4. 参数说明

| 参数名          | 默认值 | 取值范围  | 说明                                                    |
|-----------------|--------|-----------|---------------------------------------------------------|
| `ASYNC_MODE`    | 0      | 0 / 1     | 0 = 同步桥，1 = 异步桥（跨时钟域）                     |
| `ADDR_WIDTH`    | 32     | 8 ~ 64    | APB 地址总线位宽（bit）                                 |
| `DATA_WIDTH`    | 32     | 8 / 16 / 32 | APB 数据总线位宽（bit），建议为 8 的整数倍             |
| `STRB_WIDTH`    | 4      | DATA_WIDTH/8 | 字节使能位宽，通常由 DATA_WIDTH 决定，无需手动设置   |
| `PAUSER_WIDTH`  | 4      | 1 ~ 32    | 地址阶段用户信号位宽（AMBA5 扩展）                     |
| `PWUSER_WIDTH`  | 4      | 1 ~ 32    | 写数据阶段用户信号位宽                                  |
| `PRUSER_WIDTH`  | 4      | 1 ~ 32    | 读数据阶段用户信号位宽                                  |
| `PBUSER_WIDTH`  | 4      | 1 ~ 32    | 桥响应阶段用户信号位宽                                  |

> **注意**：`STRB_WIDTH` 在模块内部通过 `DATA_WIDTH/8` 自动推导，实例化时无需单独设置。
> 主从端所有用户信号位宽参数必须保持一致。

---
## 5. 模块架构

### 5.1 模块层次结构

```
apb5_bridge  (顶层，参数化选择同步/异步模式)
│
├── [ASYNC_MODE=0]  gen_sync
│   └── apb5_sync_bridge          同步桥模块
│         内部逻辑：APB FSM
│         状态：IDLE → SETUP → ACCESS
│
└── [ASYNC_MODE=1]  gen_async
    └── apb5_async_bridge         异步桥模块
          │
          ├── apb5_sync2 u_req_sync   REQ 双触发器同步器（M_PCLK → S_PCLK）
          └── apb5_sync2 u_ack_sync   ACK 双触发器同步器（S_PCLK → M_PCLK）
```

### 5.2 子模块职责说明

| 子模块                | 实例名          | 职责                                                              |
|-----------------------|-----------------|-------------------------------------------------------------------|
| `apb5_bridge`         | 顶层            | 参数化选择，通过 `generate` 决定实例化同步桥或异步桥              |
| `apb5_sync_bridge`    | `gen_sync`      | 同步模式下的 APB 协议桥，三态 FSM，支持背靠背传输                 |
| `apb5_async_bridge`   | `gen_async`     | 异步模式下的 APB 协议桥，主/从双 FSM + 四相握手 CDC               |
| `apb5_sync2`          | `u_req_sync`    | 将 `req_ff`（M_PCLK域）同步到 S_PCLK 域，DEMET 双触发器结构      |
| `apb5_sync2`          | `u_ack_sync`    | 将 `ack_ff`（S_PCLK域）同步到 M_PCLK 域，DEMET 双触发器结构      |

### 5.3 数据流向示意

```
主端 (M_PCLK)               桥内部                  从端 (S_PCLK)
─────────────               ──────                  ──────────────
M_PADDR  ──────────▶  [主端寄存器]                        
M_PWDATA ──────────▶  m_r_paddr          ──────────▶  S_PADDR
M_PSEL   ──────────▶  m_r_pwdata         ──────────▶  S_PWDATA
                       ...                            S_PSEL

                      req_ff ─[u_req_sync]─▶ req_sync
                      ack_ff ◀─[u_ack_sync]─ ack_ff

                                          ◀──────────  S_PRDATA
M_PRDATA ◀─────────  m_r_prdata          ◀──────────  S_PREADY
M_PREADY ◀─────────  (FSM)               ◀──────────  S_PSLVERR
```

---
## 6. 同步桥设计（apb5_sync_bridge）

### 6.1 APB 状态机

同步桥实现标准三态 APB FSM：

```
        M_PSEL & !M_PENABLE
 IDLE  ─────────────────────────▶  SETUP
  ▲                                   │
  │                                   │ 下一拍
  │                                   ▼
  │   S_PREADY & !M_PSEL          ACCESS
  └───────────────────────────────────┤
                                      │ S_PREADY & M_PSEL (背靠背)
                                      │
                                    SETUP  (下一笔传输)
```

| 当前状态 | 条件                        | 下一状态 | 关键动作                        |
|----------|-----------------------------|----------|---------------------------------|
| `IDLE`   | `M_PSEL & !M_PENABLE`       | `SETUP`  | 锁存所有主端信号                |
| `SETUP`  | 无条件                      | `ACCESS` | 驱动 `S_PSEL=1, S_PENABLE=0`   |
| `ACCESS` | `S_PREADY = 1`，无新请求    | `IDLE`   | `M_PREADY=1`，完成传输          |
| `ACCESS` | `S_PREADY = 1`，有新请求    | `SETUP`  | 背靠背：立即开始下一笔          |
| `ACCESS` | `S_PREADY = 0`              | `ACCESS` | 保持等待（插入等待周期）         |

### 6.2 标准传输时序

```
        1     2     3     4     5
PCLK  _/‾\_/‾\_/‾\_/‾\_/‾\_/‾      IDLE  SETUP ACCESS IDLE
PSEL        ‾‾‾‾‾‾‾‾‾‾‾‾‾
PENABLE           ‾‾‾‾‾‾
PREADY            ___/‾‾‾\      ← S_PREADY 在 ACCESS 第2拍拉高
PADDR       ═══════════════
PWDATA      ═══════════════
```

### 6.3 背靠背传输时序

```
        1     2     3     4     5     6
PCLK  _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾      IDLE SETUP1 ACC1 SETUP2 ACC2 IDLE
PSEL        ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
PENABLE           ‾‾‾‾‾      ‾‾‾‾‾
PREADY            ‾‾‾‾‾      ‾‾‾‾‾   ← 两笔传输之间无空闲周期
PADDR[0]    ═════════════
PADDR[1]                ═══════════
```

### 6.4 信号锁存策略

所有主端请求信号在 `SETUP` 阶段（或背靠背传输检测到新请求时）锁存到内部寄存器：

```
r_paddr, r_pprot, r_pnse, r_pwrite,
r_pwdata, r_pstrb, r_pwakeup, r_pauser, r_pwuser
```

锁存后这些寄存器驱动从端 `S_*` 输出，直到下一次锁存。

---
## 7. 异步桥设计（apb5_async_bridge）

### 7.1 四相握手协议

异步桥采用 **Toggle + 双触发器同步器** 实现四相握手，流程如下：

```
阶段   主端 (M_PCLK)                从端 (S_PCLK)
────   ──────────────               ──────────────
 ①    锁存请求数据
       req_ff: 0 → 1 (Toggle)
              ──────────────────────▶
                         ②          检测 req_sync 边沿
                                     SETUP: PSEL=1, PENABLE=0
                                     ACCESS: PSEL=1, PENABLE=1
                                     等待 S_PREADY
                                     锁存响应数据
                                     ack_ff: 0 → 1 (Toggle)
              ◀──────────────────────
 ③    检测 ack_sync 边沿
       M_PREADY = 1
       采样响应数据
       回到 M_IDLE
                         ④          req_sync 恢复稳定
                                     S_WDEACK → S_IDLE
```

### 7.2 握手时序波形

```
时间轴 ──────────────────────────────────────────────────────▶

req_ff   ____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\________
数据稳定      │◀────────── 稳定保持 ─────────────▶│
req_sync ________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\__________
                  │◀── S端传输 ──▶│
ack_ff   ______________________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\________
ack_sync ____________________________/‾‾‾‾‾‾‾‾‾‾‾‾\______
                                      │
                                 M_PREADY = 1（采样响应）
```

### 7.3 主端状态机（M_PCLK 域）

| 状态       | 进入条件                  | 关键动作                    | 离开条件       |
|------------|---------------------------|---------------------------|-----------------------------|
| `M_IDLE`   | 复位/传输完成后            | 无                       | `M_PSEL & !M_PENABLE`       |
| `M_SETUP`  | 检测到主端请求             | 锁存请求，触发 `req_ff` Toggle | 无条件（下一拍）           |
| `M_WAIT`   | REQ 已发出                 | `M_PREADY=0`，等待 ACK    | `ack_edge = 1`              |
| `M_DONE`   | 检测到 ACK 边沿            | `M_PREADY=1`，采样响应    | 无条件（下一拍）            |

### 7.4 从端状态机（S_PCLK 域）

| 状态        | 进入条件            | 关键动作                          | 离开条件              |
|-------------|---------------------|-----------------------------------|-----------------------|
| `S_IDLE`    | 复位/握手完成后      | 等待 REQ 边沿                    | `req_edge = 1`        |
| `S_SETUP`   | 检测到 REQ 边沿     | 锁存解包请求，`S_PSEL=1`          | 无条件（下一拍）      |
| `S_ACCESS`  | SETUP 完成          | `S_PSEL=1, S_PENABLE=1`          | `S_PREADY = 1`        |
| `S_ACK`     | 从设备就绪          | 锁存响应，触发 `ack_ff` Toggle    | 无条件（下一拍）      |
| `S_WDEACK`  | ACK 已发出          | 等待 REQ 恢复稳定                 | `req_sync` 稳定后     |

### 7.5 Toggle 机制说明

使用 Toggle 而非电平/脉冲的原因：

| 方案       | 问题                                                   |
|------------|--------------------------------------------------------|
| 直接电平   | 目标域时钟可能多次采样，产生多次误触发                  |
| 单周期脉冲 | 若目标时钟更慢，脉冲可能整个被错过                     |
| **Toggle** | 任意时钟比例下，翻转事件**必然**可被双触发器同步器捕获 ✅ |

### 7.6 数据总线 CDC 安全性

请求数据总线（`req_data`）和响应数据总线（`rsp_data`）**不经过同步器**，
其安全性由握手协议数据稳定窗口保证：

```
数据稳定窗口（REQ 方向）：
  [M_SETUP 锁存] ──▶ [req_ff Toggle] ──▶ [2个S_PCLK同步] ──▶ [S_IDLE采样]
   数据已稳定            控制信号发出         至少2拍后              才采数据
   
   ∴ 从数据写入到被读取，之间至少有 1个M_PCLK + 2个S_PCLK 的间隔
   ∴ 数据总线在采样时绝对稳定，无 CDC 风险
```

### 7.7 性能分析

| 参数            | 公式                                               | 示例（M=100MHz，S=50MHz） |
|-----------------|----------------------------------------------------|--------------------------|
| 最小单次延迟    | 2×T(S) + 2×T(M) + T(APB)                         | 2×20 + 2×10 + 40 = 100 ns |
| APB 最小延迟    | 2×T(S)（SETUP + ACCESS 最少2拍）                  | 40 ns                    |
| 最大吞吐量      | 1 / (最小延迟)                                     | 10 Mtransactions/s       |

> 异步桥适合低速 CSR 寄存器访问（< 10 Mtps），不适合高带宽数据通道。

### 7.8 复位策略

```
推荐复位顺序：
  Step 1：系统复位，同时拉低 M_PRESETn 和 S_PRESETn
  Step 2：先撤销 S_PRESETn（从端就绪）
  Step 3：再撤销 M_PRESETn（主端就绪，开始发令请求）

原理：避免主端在从端仍处于复位状态时发出 REQ Toggle，
      导致从端错过握手无法响应。
```

---
## 8. CDC 分析

### 8.1 CDC 路径汇总

| 路径编号 | 信号         | 源时钟域 | 目标时钟域 | 类型             | 处理方式                         |
|----------|--------------|----------|------------|------------------|----------------------------------|
| CDC-1    | `req_ff`     | M_PCLK   | S_PCLK     | Toggle 控制信号  | DEMET 双触发器同步器 (`u_req_sync`) |
| CDC-2    | `ack_ff`     | S_PCLK   | M_PCLK     | Toggle 控制信号  | DEMET 双触发器同步器 (`u_ack_sync`) |
| CDC-3    | `req_data`   | M_PCLK   | S_PCLK     | 多比特数据总线   | 协议稳定窗口保证，无需同步器        |
| CDC-4    | `rsp_data`   | S_PCLK   | M_PCLK     | 多比特数据总线   | 协议稳定窗口保证，无需同步器        |

### 8.2 双触发器同步器（apb5_sync2）

```
源时钟域                         目标时钟域
d_in ──────▶ [FF1: sync_ff1] ──▶ [FF2: d_out] ──▶ 同步后信号
（可能亚稳）   第一级，亚稳可能在此消散   第二级，稳定输出
```

- **FF1（sync_ff1）**：可能进入亚稳态，不直接使用其输出
- **FF2（d_out）**：亚稳态在 FF1→FF2 之间的时间窗口内消散，输出稳定
- **MTBF（平均无故障时间）**：与目标时钟频率、数据翻转频率、工艺参数有关：

  `MTBF = exp(T_resolve / τ) / (f_clk × f_data × C1)`

> 设计中所有跨域单比特控制信号均使用此同步器结构。

### 8.3 `apb5_bridge_cdc.tcl` 文件说明

该文件为 SpyGlass CDC 约束文件（SGdc 格式），共**10节，409行**：

| 节次 | 命令                    | 说明                                              |
|------|-------------------------|---------------------------------------------------|
| §1   | `set_cdc_design_config` | 开启 glitch 分析和全局重汇聚（reconvergence）检查  |
| §2   | `set_cdc_clock`         | 声明 M_PCLK / S_PCLK 为两个异步时钟域             |
| §3   | `set_cdc_reset`         | 声明两端独立复位域，关系为 asynchronous            |
| §4   | `set_cdc_synchronizer`  | 声明 `u_req_sync` / `u_ack_sync` 为 DEMET 类型同步器 |
| §5   | `set_cdc_port_domain`   | 声明 `req_ff` / `ack_ff` Toggle FF 的时钟域       |
| §6   | `set_cdc_port_domain`   | 请求数据总线 9 个字段稳定性声明（`-have_no_combo_logic`） |
| §7   | `set_cdc_port_domain`   | 响应数据总线 4 个字段稳定性声明                   |
| §8   | `set_cdc_port_domain`   | `ack_edge` / `req_edge` 边沿检测信号（同域，防误报）|
| §9   | `set_cdc_waiver`        | 3 条 Waiver：请求数据总线、响应数据总线、边沿寄存器 |
| §10  | 注释 SVA                 | 3 条断言模板，用于 DV 仿真验证 Waiver 有效性       |

#### Waiver 说明

| Waiver 标签                  | 豁免类型   | 豁免信号                     | 豁免理由                           |
|------------------------------|------------|------------------------------|------------------------------------|
| `APB5_ASYNC_REQ_DATA_HS`     | `no_sync`  | `m_r_paddr` 等 9 个寄存器    | 四相握手协议保证，REQ Toggle 先于数据 |
| `APB5_ASYNC_RSP_DATA_HS`     | `no_sync`  | `s_r_prdata` 等 4 个寄存器   | 四相握手协议保证，ACK Toggle 先于数据 |
| `APB5_ASYNC_EDGE_DET`        | `combo_logic` | `ack_sync_d` / `req_sync_d` | 同域延迟寄存器，非 CDC 路径          |

#### SVA 断言模板（DV 验证用）

```systemverilog
// 断言1：REQ 数据总线在握手期间保持稳定
property req_data_stable_chk;
    @(posedge M_PCLK)
    $rose(req_ff) |-> ##[1:$] ($stable(req_data) throughout (ack_edge[->1]));
endproperty
assert property (req_data_stable_chk)
    else $error("[APB5_ASYNC] req_data 握手期间发生变化！");

// 断言2：握手不可重入
property no_reentrant_req;
    @(posedge M_PCLK)
    (m_cur == M_WAIT) |-> !req_set;
endproperty
assert property (no_reentrant_req);
```

---
## 9. STA 约束说明

### 9.1 时钟配置

| 参数                | M_PCLK               | S_PCLK               |
|---------------------|----------------------|----------------------|
| 示例频率            | 100 MHz              | 50 MHz               |
| 时钟周期            | 10.000 ns            | 20.000 ns            |
| Setup Uncertainty   | 0.100 ns             | 0.150 ns             |
| Hold Uncertainty    | 0.050 ns             | 0.075 ns             |
| Clock Transition    | 0.050 ns             | 0.070 ns             |
| Source Latency      | 0.200 ns             | 0.250 ns             |
| Network Latency     | 0.500 ns             | 0.600 ns             |

> ⚠️ 以上值均为示例，**必须根据实际工程频率和时钟树测量值修改**。

### 9.2 同步器路径约束（核心）

```sdc
# 同步器输入路径：必须使用 -datapath_only，不能用 set_false_path
set_max_delay 20.000 -datapath_only              -from [get_cells req_ff]                     -to   [get_cells u_req_sync/sync_ff1]

set_max_delay 10.000 -datapath_only              -from [get_cells ack_ff]                     -to   [get_cells u_ack_sync/sync_ff1]
```

| 约束类型              | 为什么不能用 set_false_path？                            |
|-----------------------|---------------------------------------------------------|
| `set_false_path`      | 工具完全忽略路径，不检查延迟，存在信号来不及稳定的风险   |
| `set_max_delay -D.O.` | 工具检查组合延迟 ≤ 指定值，**确保信号在下一时钟周期稳定**|

```sdc
# 同步器禁止工具优化（保护单扇出结构）
set_dont_touch [get_cells u_req_sync]
set_dont_touch [get_cells u_ack_sync]
```

### 9.3 False Path 分类

| 类别               | 路径描述                            | 理由                             |
|--------------------|-------------------------------------|----------------------------------|
| 异步复位路径       | `M_PRESETn` / `S_PRESETn` → FF     | 异步信号，无时序关系             |
| 请求数据总线       | `m_r_*` → S_PCLK 域                | 握手稳定窗口保证，STA 无意义     |
| 响应数据总线       | `s_r_*` → M_PCLK 域                | 握手稳定窗口保证，STA 无意义     |

### 9.4 CDC SDC 与 STA SDC 文件对比

| 维度           | `apb5_bridge_cdc.sdc`         | `apb5_bridge_sta.sdc`              |
|----------------|-------------------------------|------------------------------------|
| 主要用途       | 配合 SpyGlass CDC 分析        | PrimeTime / Tempus 时序签核        |
| 行数           | 185 行                        | 777 行                             |
| 时钟定义       | ✅ 基础定义                   | ✅ 含 uncertainty / latency / slew |
| IO 延迟        | ✅ 基础约束                   | ✅ 含 max / min 双侧约束           |
| 设计规则       | ❌                             | ✅ max_fanout / max_transition 等  |
| 多周期路径     | ❌                             | ✅ 注释模板（需根据从设备确认）    |
| 验证检查清单   | ❌                             | ✅ 8 项 PrimeTime 命令             |
| 汇总表         | ❌                             | ✅ 13 条时序例外 ASCII 表格        |

### 9.5 STA 验证检查清单

在 PrimeTime 中执行以下命令验证约束正确性：

| 检查项 | PrimeTime 命令                                                    | 预期结果                           |
|--------|-------------------------------------------------------------------|------------------------------------|
| 1      | `check_timing -verbose`                                           | 无 unconstrained path / missing clock |
| 2      | `report_timing -from req_ff -to u_req_sync/sync_ff1 -delay max`  | 路径延迟 ≤ 20 ns                   |
| 3      | `report_timing -from ack_ff -to u_ack_sync/sync_ff1 -delay max`  | 路径延迟 ≤ 10 ns                   |
| 4      | `report_cdc -nosplit`                                             | 无未处理跨域违例                   |
| 5      | `report_timing -through [get_ports M_PADDR] -max_paths 5`        | IO 路径 slack ≥ 0                  |
| 6      | `report_clocks -nosplit`                                          | M_PCLK / S_PCLK 均已定义          |
| 7      | `report_constraint -all_violators -max_fanout -max_transition`    | 无设计规则违例                     |
| 8      | `report_cell [get_cells {u_req_sync u_ack_sync}]`                 | 同步器实例未被综合优化             |

---
## 10. 实例化示例

### 10.1 同步模式实例化

```systemverilog
// 同步模式（主从端共用一个时钟）
apb5_bridge #(
    .ASYNC_MODE   (0),    // 同步桥
    .ADDR_WIDTH   (32),
    .DATA_WIDTH   (32),
    .PAUSER_WIDTH (4),
    .PWUSER_WIDTH (4),
    .PRUSER_WIDTH (4),
    .PBUSER_WIDTH (4)
) u_apb5_sync_bridge (
    // 时钟与复位（同步模式：S_PCLK 接同一时钟）
    .M_PCLK     (apb_clk),
    .M_PRESETn  (apb_resetn),
    .S_PCLK     (apb_clk),     // 同步模式：从端接相同时钟
    .S_PRESETn  (apb_resetn),
    // 主端接口
    .M_PADDR    (m_paddr),
    .M_PPROT    (m_pprot),
    .M_PNSE     (m_pnse),
    .M_PSEL     (m_psel),
    .M_PENABLE  (m_penable),
    .M_PWRITE   (m_pwrite),
    .M_PWDATA   (m_pwdata),
    .M_PSTRB    (m_pstrb),
    .M_PWAKEUP  (m_pwakeup),
    .M_PAUSER   (m_pauser),
    .M_PWUSER   (m_pwuser),
    .M_PREADY   (m_pready),
    .M_PRDATA   (m_prdata),
    .M_PSLVERR  (m_pslverr),
    .M_PRUSER   (m_pruser),
    .M_PBUSER   (m_pbuser),
    // 从端接口
    .S_PADDR    (s_paddr),
    .S_PPROT    (s_pprot),
    .S_PNSE     (s_pnse),
    .S_PSEL     (s_psel),
    .S_PENABLE  (s_penable),
    .S_PWRITE   (s_pwrite),
    .S_PWDATA   (s_pwdata),
    .S_PSTRB    (s_pstrb),
    .S_PWAKEUP  (s_pwakeup),
    .S_PAUSER   (s_pauser),
    .S_PWUSER   (s_pwuser),
    .S_PREADY   (s_pready),
    .S_PRDATA   (s_prdata),
    .S_PSLVERR  (s_pslverr),
    .S_PRUSER   (s_pruser),
    .S_PBUSER   (s_pbuser)
);
```

### 10.2 异步模式实例化

```systemverilog
// 异步模式（主从端各自独立时钟，跨时钟域 CDC）
apb5_bridge #(
    .ASYNC_MODE   (1),    // 异步桥
    .ADDR_WIDTH   (32),
    .DATA_WIDTH   (32),
    .PAUSER_WIDTH (8),    // 用户信号位宽可自定义
    .PWUSER_WIDTH (8),
    .PRUSER_WIDTH (8),
    .PBUSER_WIDTH (8)
) u_apb5_async_bridge (
    // 主端时钟域（例如：100 MHz PCNOC 总线时钟）
    .M_PCLK     (pcnoc_clk_100m),
    .M_PRESETn  (pcnoc_resetn),
    // 从端时钟域（例如：50 MHz 外设时钟）
    .S_PCLK     (periph_clk_50m),
    .S_PRESETn  (periph_resetn),
    // 主端/从端信号连接（同同步模式）
    .M_PADDR    (m_paddr),
    // ... 其余信号省略（参考同步模式示例）
    .S_PBUSER   (s_pbuser)
);
```

### 10.3 自定义位宽示例

```systemverilog
// 64位地址，32位数据，无用户扩展信号
apb5_bridge #(
    .ASYNC_MODE   (1),
    .ADDR_WIDTH   (64),   // 64位地址
    .DATA_WIDTH   (32),
    .PAUSER_WIDTH (1),    // 最小用户信号位宽
    .PWUSER_WIDTH (1),
    .PRUSER_WIDTH (1),
    .PBUSER_WIDTH (1)
) u_apb5_bridge_64b (...);
```
----

## 11 DV验证套件

### 11.1 文件总览

|文件|行数|核心内容|
| ------------------ | ------ | ----------------------------------- |
| apb5_bridge_sva.sv | 473 行 | 26 条 SVA 断言 + 5 个功能覆盖组       |
| apb5_bridge_tb.sv  | 476 行 | 从端寄存器模型 + 2 个 Task + 6 组测试 |
| apb5_bridge_sim.mk | 362 行 | VCS/Questa/Xcelium 三工具支持        |

### 11.2 SVA断言绑定



&#160; &#160; &#160; &#160; 通过bind apb5_async_bridge自动绑定，无需修改 DUT。26条断言分5组：

|组|数量|覆盖内容|
| --- | --- | --- |
| A - APB 协议合规 | 6条 | PSEL/PENABLE时序、PADDR/PWDATA稳定、PSTRB合法性 |
| B - 四相握手协议 | 6条 | req_data稳定性、握手不可重入、req_set/ack_set合法性 |
| C - 状态机有效性 | 5条 | 编码合法、不能跳状态、SETUP只持续1拍 |
| D - 复位行为 | 5条 | 复位后回IDLE、req_ff/ack_ff复位为0、PREADY复位为0 |
| E - 响应有效性 | 4条 | PREADY只在 M_DONE 拉高、PSLVERR 配合 PREADY、PREADY宽度1拍 |

&#160; &#160; &#160; &#160; 5个功能覆盖组：

```
cg_master_fsm        主端状态转换（4个状态 × 7条迁移路径）
cg_slave_fsm         从端状态转换（5个状态 × 6条迁移路径）
cg_apb_transfer_type 传输类型（读/写 × 正常/错误 交叉覆盖）
cg_pready_wait_cycles PREADY 等待周期覆盖（0拍/≥1拍）
cg_addr_coverage     地址范围 + 字节使能组合覆盖
```

### 11.3 Testbench




---
## 12 设计约束与限制

### 12.1 功能限制

| 限制项                       | 描述                                                        | 建议                                    |
|------------------------------|-------------------------------------------------------------|-----------------------------------------|
| 单事务在途                   | 异步模式每次只处理一笔请求，不支持流水线                    | 用于低频 CSR 访问，不建议高吞吐场景使用 |
| 异步模式无背靠背             | 每笔传输需等待四相握手完全结束                              | 如需高吞吐，建议使用异步 FIFO桥方案     |
| 无协议错误检测               | 对违反 APB 协议的主端行为不做检查或报错                     | 建议在仿真中使用 APB VIP 验证主端行为   |
| 用户信号两端宽度需一致       | PAUSER/PWUSER/PRUSER/PBUSER 宽度由同一参数控制              | 如需差异化，需修改 RTL                  |
| PWAKEUP 不做协议检查         | PWAKEUP 信号直接透传，不检查与 PSEL 的时序关系              | 由系统级设计保证                        |

### 12.2 性能对比

| 指标                 | 同步模式                  | 异步模式                               |
|----------------------|---------------------------|----------------------------------------|
| 传输延迟             | 2 个 PCLK 周期（最少）    | ≥ 2×T(S) + 2×T(M) + T(APB)           |
| 背靠背传输           | ✅ 支持                   | ❌ 不支持                             |
| 吞吐量（示例）        | 50 Mtps @ 100MHz          | ~10 Mtps（M=100MHz，S=50MHz）         |
| 面积开销             | 小                        | 中（含同步器+握手逻辑）               |
| 功耗开销             | 低                        | 中                                    |
| CDC 安全性            | N/A（同域）               | ✅ 经 SpyGlass CDC 验证               |

### 12.3 使用建议

1. **时钟频率选择**：异步桥两端时钟比例无限制，但目标时钟越快，REQ 同步延迟越小，性能越好
2. **复位时序**：建议先撤销从端复位（`S_PRESETn`），再撤销主端复位（`M_PRESETn`）
3. **SpyGlass CDC**：在流片前必须对 `apb5_async_bridge` 运行 P3 级别 CDC 检查
4. **STA 约束修改**：`apb5_bridge_sta.sdc` 中时钟频率和 IO 延迟为示例值，**必须根据实际工程修改**
5. **DV 覆盖率**：建议在仿真中添加 §8.3 中的 SVA 断言，验证数据总线 Waiver 的有效性

---
## 13. 版本历史

| 版本  | 日期       | 作者     | 修改内容                                         |
|-------|------------|----------|--------------------------------------------------|
| v1.0  | 2026-04-15 | Auto-Gen | 初始版本，包含同步桥、异步桥、同步器完整实现      |
|       |            |          | 支持 AMBA 5 APB：PNSE、PWAKEUP、PAUSER/PWUSER 等 |
|       |            |          | 提供完整 CDC 约束（409行）和 STA 约束（777行）    |

---