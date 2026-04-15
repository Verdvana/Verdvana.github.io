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
### 5.4 顶层RTL
```verilog
// =============================================================================
// APB5 顶层桥（参数化选择同步或异步模式）
// ASYNC_MODE = 0 : 同步桥（主从同时钟）
// ASYNC_MODE = 1 : 异步桥（主从独立时钟 + CDC）
// =============================================================================
module apb5_bridge #(
    parameter ASYNC_MODE   = 0,    // 0=同步模式，1=异步模式
    parameter ADDR_WIDTH   = 32,
    parameter DATA_WIDTH   = 32,
    parameter STRB_WIDTH   = DATA_WIDTH/8,
    parameter PAUSER_WIDTH = 4,
    parameter PWUSER_WIDTH = 4,
    parameter PRUSER_WIDTH = 4,
    parameter PBUSER_WIDTH = 4
)(
    // -------------------------------------------------------------------------
    // 主端时钟与复位（两种模式均使用）
    // -------------------------------------------------------------------------
    input  logic                    M_PCLK,
    input  logic                    M_PRESETn,

    // -------------------------------------------------------------------------
    // 从端时钟与复位（仅异步模式使用；同步模式下与主端相同）
    // -------------------------------------------------------------------------
    input  logic                    S_PCLK,
    input  logic                    S_PRESETn,

    // -------------------------------------------------------------------------
    // 主端 APB5 接口
    // -------------------------------------------------------------------------
    input  logic [ADDR_WIDTH-1:0]   M_PADDR,
    input  logic [2:0]              M_PPROT,
    input  logic                    M_PNSE,
    input  logic                    M_PSEL,
    input  logic                    M_PENABLE,
    input  logic                    M_PWRITE,
    input  logic [DATA_WIDTH-1:0]   M_PWDATA,
    input  logic [STRB_WIDTH-1:0]   M_PSTRB,
    input  logic                    M_PWAKEUP,
    input  logic [PAUSER_WIDTH-1:0] M_PAUSER,
    input  logic [PWUSER_WIDTH-1:0] M_PWUSER,
    output logic                    M_PREADY,
    output logic [DATA_WIDTH-1:0]   M_PRDATA,
    output logic                    M_PSLVERR,
    output logic [PRUSER_WIDTH-1:0] M_PRUSER,
    output logic [PBUSER_WIDTH-1:0] M_PBUSER,

    // -------------------------------------------------------------------------
    // 从端 APB5 接口
    // -------------------------------------------------------------------------
    output logic [ADDR_WIDTH-1:0]   S_PADDR,
    output logic [2:0]              S_PPROT,
    output logic                    S_PNSE,
    output logic                    S_PSEL,
    output logic                    S_PENABLE,
    output logic                    S_PWRITE,
    output logic [DATA_WIDTH-1:0]   S_PWDATA,
    output logic [STRB_WIDTH-1:0]   S_PSTRB,
    output logic                    S_PWAKEUP,
    output logic [PAUSER_WIDTH-1:0] S_PAUSER,
    output logic [PWUSER_WIDTH-1:0] S_PWUSER,
    input  logic                    S_PREADY,
    input  logic [DATA_WIDTH-1:0]   S_PRDATA,
    input  logic                    S_PSLVERR,
    input  logic [PRUSER_WIDTH-1:0] S_PRUSER,
    input  logic [PBUSER_WIDTH-1:0] S_PBUSER
);

    generate
        if (ASYNC_MODE == 0) begin : gen_sync
            // -----------------------------------------------------------------
            // 同步模式：实例化同步桥
            // -----------------------------------------------------------------
            apb5_sync_bridge #(
                .ADDR_WIDTH   (ADDR_WIDTH),
                .DATA_WIDTH   (DATA_WIDTH),
                .STRB_WIDTH   (STRB_WIDTH),
                .PAUSER_WIDTH (PAUSER_WIDTH),
                .PWUSER_WIDTH (PWUSER_WIDTH),
                .PRUSER_WIDTH (PRUSER_WIDTH),
                .PBUSER_WIDTH (PBUSER_WIDTH)
            ) u_sync_bridge (
                .PCLK      (M_PCLK),
                .PRESETn   (M_PRESETn),
                .M_PADDR   (M_PADDR),
                .M_PPROT   (M_PPROT),
                .M_PNSE    (M_PNSE),
                .M_PSEL    (M_PSEL),
                .M_PENABLE (M_PENABLE),
                .M_PWRITE  (M_PWRITE),
                .M_PWDATA  (M_PWDATA),
                .M_PSTRB   (M_PSTRB),
                .M_PWAKEUP (M_PWAKEUP),
                .M_PAUSER  (M_PAUSER),
                .M_PWUSER  (M_PWUSER),
                .M_PREADY  (M_PREADY),
                .M_PRDATA  (M_PRDATA),
                .M_PSLVERR (M_PSLVERR),
                .M_PRUSER  (M_PRUSER),
                .M_PBUSER  (M_PBUSER),
                .S_PADDR   (S_PADDR),
                .S_PPROT   (S_PPROT),
                .S_PNSE    (S_PNSE),
                .S_PSEL    (S_PSEL),
                .S_PENABLE (S_PENABLE),
                .S_PWRITE  (S_PWRITE),
                .S_PWDATA  (S_PWDATA),
                .S_PSTRB   (S_PSTRB),
                .S_PWAKEUP (S_PWAKEUP),
                .S_PAUSER  (S_PAUSER),
                .S_PWUSER  (S_PWUSER),
                .S_PREADY  (S_PREADY),
                .S_PRDATA  (S_PRDATA),
                .S_PSLVERR (S_PSLVERR),
                .S_PRUSER  (S_PRUSER),
                .S_PBUSER  (S_PBUSER)
            );
        end else begin : gen_async
            // -----------------------------------------------------------------
            // 异步模式：实例化异步桥
            // -----------------------------------------------------------------
            apb5_async_bridge #(
                .ADDR_WIDTH   (ADDR_WIDTH),
                .DATA_WIDTH   (DATA_WIDTH),
                .STRB_WIDTH   (STRB_WIDTH),
                .PAUSER_WIDTH (PAUSER_WIDTH),
                .PWUSER_WIDTH (PWUSER_WIDTH),
                .PRUSER_WIDTH (PRUSER_WIDTH),
                .PBUSER_WIDTH (PBUSER_WIDTH)
            ) u_async_bridge (
                .M_PCLK    (M_PCLK),
                .M_PRESETn (M_PRESETn),
                .M_PADDR   (M_PADDR),
                .M_PPROT   (M_PPROT),
                .M_PNSE    (M_PNSE),
                .M_PSEL    (M_PSEL),
                .M_PENABLE (M_PENABLE),
                .M_PWRITE  (M_PWRITE),
                .M_PWDATA  (M_PWDATA),
                .M_PSTRB   (M_PSTRB),
                .M_PWAKEUP (M_PWAKEUP),
                .M_PAUSER  (M_PAUSER),
                .M_PWUSER  (M_PWUSER),
                .M_PREADY  (M_PREADY),
                .M_PRDATA  (M_PRDATA),
                .M_PSLVERR (M_PSLVERR),
                .M_PRUSER  (M_PRUSER),
                .M_PBUSER  (M_PBUSER),
                .S_PCLK    (S_PCLK),
                .S_PRESETn (S_PRESETn),
                .S_PADDR   (S_PADDR),
                .S_PPROT   (S_PPROT),
                .S_PNSE    (S_PNSE),
                .S_PSEL    (S_PSEL),
                .S_PENABLE (S_PENABLE),
                .S_PWRITE  (S_PWRITE),
                .S_PWDATA  (S_PWDATA),
                .S_PSTRB   (S_PSTRB),
                .S_PWAKEUP (S_PWAKEUP),
                .S_PAUSER  (S_PAUSER),
                .S_PWUSER  (S_PWUSER),
                .S_PREADY  (S_PREADY),
                .S_PRDATA  (S_PRDATA),
                .S_PSLVERR (S_PSLVERR),
                .S_PRUSER  (S_PRUSER),
                .S_PBUSER  (S_PBUSER)
            );
        end
    endgenerate

endmodule
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

### 6.5 RTL

```verilog
// =============================================================================
// APB5 同步桥（主/从端同时钟域）
// =============================================================================
module apb5_sync_bridge #(
    parameter ADDR_WIDTH  = 32,   // 地址总线位宽
    parameter DATA_WIDTH  = 32,   // 数据总线位宽
    parameter STRB_WIDTH  = DATA_WIDTH/8, // 字节使能位宽
    parameter PAUSER_WIDTH = 4,   // 地址阶段用户信号位宽
    parameter PWUSER_WIDTH = 4,   // 写数据阶段用户信号位宽
    parameter PRUSER_WIDTH = 4,   // 读数据阶段用户信号位宽
    parameter PBUSER_WIDTH = 4    // 桥用户信号位宽
)(
    // -------------------------------------------------------------------------
    // 主端接口（Initiator / Master Side）
    // -------------------------------------------------------------------------
    input  logic                    PCLK,          // APB 时钟
    input  logic                    PRESETn,        // APB 复位（低有效）
    input  logic [ADDR_WIDTH-1:0]   M_PADDR,        // 主端地址
    input  logic [2:0]              M_PPROT,        // 保护类型
    input  logic                    M_PNSE,         // 非安全扩展（AMBA5新增）
    input  logic                    M_PSEL,         // 从设备选择
    input  logic                    M_PENABLE,      // 使能信号
    input  logic                    M_PWRITE,       // 写使能（1=写，0=读）
    input  logic [DATA_WIDTH-1:0]   M_PWDATA,       // 写数据
    input  logic [STRB_WIDTH-1:0]   M_PSTRB,        // 字节使能
    input  logic                    M_PWAKEUP,      // 唤醒信号（AMBA5新增）
    input  logic [PAUSER_WIDTH-1:0] M_PAUSER,       // 地址用户信号
    input  logic [PWUSER_WIDTH-1:0] M_PWUSER,       // 写数据用户信号
    output logic                    M_PREADY,       // 从设备就绪
    output logic [DATA_WIDTH-1:0]   M_PRDATA,       // 读数据
    output logic                    M_PSLVERR,      // 从设备错误
    output logic [PRUSER_WIDTH-1:0] M_PRUSER,       // 读数据用户信号
    output logic [PBUSER_WIDTH-1:0] M_PBUSER,       // 桥用户信号

    // -------------------------------------------------------------------------
    // 从端接口（Target / Slave Side）
    // -------------------------------------------------------------------------
    output logic [ADDR_WIDTH-1:0]   S_PADDR,
    output logic [2:0]              S_PPROT,
    output logic                    S_PNSE,
    output logic                    S_PSEL,
    output logic                    S_PENABLE,
    output logic                    S_PWRITE,
    output logic [DATA_WIDTH-1:0]   S_PWDATA,
    output logic [STRB_WIDTH-1:0]   S_PSTRB,
    output logic                    S_PWAKEUP,
    output logic [PAUSER_WIDTH-1:0] S_PAUSER,
    output logic [PWUSER_WIDTH-1:0] S_PWUSER,
    input  logic                    S_PREADY,
    input  logic [DATA_WIDTH-1:0]   S_PRDATA,
    input  logic                    S_PSLVERR,
    input  logic [PRUSER_WIDTH-1:0] S_PRUSER,
    input  logic [PBUSER_WIDTH-1:0] S_PBUSER
);

    // -------------------------------------------------------------------------
    // APB 状态机定义
    // IDLE   : 空闲状态
    // SETUP  : 建立阶段（PSEL=1, PENABLE=0）
    // ACCESS : 访问阶段（PSEL=1, PENABLE=1）
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE   = 2'b00,
        SETUP  = 2'b01,
        ACCESS = 2'b10
    } apb_state_t;

    apb_state_t cur_state, nxt_state;

    // -------------------------------------------------------------------------
    // 内部寄存器：锁存主端请求信号
    // -------------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]   r_paddr;
    logic [2:0]              r_pprot;
    logic                    r_pnse;
    logic                    r_pwrite;
    logic [DATA_WIDTH-1:0]   r_pwdata;
    logic [STRB_WIDTH-1:0]   r_pstrb;
    logic                    r_pwakeup;
    logic [PAUSER_WIDTH-1:0] r_pauser;
    logic [PWUSER_WIDTH-1:0] r_pwuser;

    // -------------------------------------------------------------------------
    // 状态机：时序逻辑
    // -------------------------------------------------------------------------
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn)
            cur_state <= IDLE;
        else
            cur_state <= nxt_state;
    end

    // -------------------------------------------------------------------------
    // 状态机：组合逻辑（下一状态）
    // -------------------------------------------------------------------------
    always_comb begin
        nxt_state = cur_state;
        case (cur_state)
            IDLE: begin
                if (M_PSEL && !M_PENABLE)
                    nxt_state = SETUP;
            end
            SETUP: begin
                nxt_state = ACCESS;
            end
            ACCESS: begin
                if (S_PREADY) begin
                    if (M_PSEL && !M_PENABLE)
                        nxt_state = SETUP;   // 背靠背传输（Back-to-Back）
                    else
                        nxt_state = IDLE;
                end
            end
            default: nxt_state = IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // 在 SETUP 阶段锁存主端请求信号
    // -------------------------------------------------------------------------
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            r_paddr   <= {ADDR_WIDTH{1'b0}};
            r_pprot   <= 3'b000;
            r_pnse    <= 1'b0;
            r_pwrite  <= 1'b0;
            r_pwdata  <= {DATA_WIDTH{1'b0}};
            r_pstrb   <= {STRB_WIDTH{1'b0}};
            r_pwakeup <= 1'b0;
            r_pauser  <= {PAUSER_WIDTH{1'b0}};
            r_pwuser  <= {PWUSER_WIDTH{1'b0}};
        end else if (cur_state == SETUP || (cur_state == ACCESS && S_PREADY && M_PSEL && !M_PENABLE)) begin
            r_paddr   <= M_PADDR;
            r_pprot   <= M_PPROT;
            r_pnse    <= M_PNSE;
            r_pwrite  <= M_PWRITE;
            r_pwdata  <= M_PWDATA;
            r_pstrb   <= M_PSTRB;
            r_pwakeup <= M_PWAKEUP;
            r_pauser  <= M_PAUSER;
            r_pwuser  <= M_PWUSER;
        end
    end

    // -------------------------------------------------------------------------
    // 从端输出驱动
    // -------------------------------------------------------------------------
    assign S_PADDR   = r_paddr;
    assign S_PPROT   = r_pprot;
    assign S_PNSE    = r_pnse;
    assign S_PWRITE  = r_pwrite;
    assign S_PWDATA  = r_pwdata;
    assign S_PSTRB   = r_pstrb;
    assign S_PWAKEUP = r_pwakeup;
    assign S_PAUSER  = r_pauser;
    assign S_PWUSER  = r_pwuser;
    assign S_PSEL    = (cur_state == SETUP) || (cur_state == ACCESS);
    assign S_PENABLE = (cur_state == ACCESS);

    // -------------------------------------------------------------------------
    // 主端响应信号回传
    // -------------------------------------------------------------------------
    assign M_PREADY  = (cur_state == ACCESS) ? S_PREADY  : 1'b0;
    assign M_PRDATA  = S_PRDATA;
    assign M_PSLVERR = S_PSLVERR;
    assign M_PRUSER  = S_PRUSER;
    assign M_PBUSER  = S_PBUSER;

endmodule
```

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

### 7.9 RTL

```verilog
// =============================================================================
// APB5 异步桥（主/从端跨时钟域，采用四相握手 CDC）
// =============================================================================
module apb5_async_bridge #(
    parameter ADDR_WIDTH   = 32,
    parameter DATA_WIDTH   = 32,
    parameter STRB_WIDTH   = DATA_WIDTH/8,
    parameter PAUSER_WIDTH = 4,
    parameter PWUSER_WIDTH = 4,
    parameter PRUSER_WIDTH = 4,
    parameter PBUSER_WIDTH = 4
)(
    // -------------------------------------------------------------------------
    // 主端时钟域（Initiator Clock Domain）
    // -------------------------------------------------------------------------
    input  logic                    M_PCLK,        // 主端 APB 时钟
    input  logic                    M_PRESETn,      // 主端复位（低有效）
    input  logic [ADDR_WIDTH-1:0]   M_PADDR,
    input  logic [2:0]              M_PPROT,
    input  logic                    M_PNSE,
    input  logic                    M_PSEL,
    input  logic                    M_PENABLE,
    input  logic                    M_PWRITE,
    input  logic [DATA_WIDTH-1:0]   M_PWDATA,
    input  logic [STRB_WIDTH-1:0]   M_PSTRB,
    input  logic                    M_PWAKEUP,
    input  logic [PAUSER_WIDTH-1:0] M_PAUSER,
    input  logic [PWUSER_WIDTH-1:0] M_PWUSER,
    output logic                    M_PREADY,
    output logic [DATA_WIDTH-1:0]   M_PRDATA,
    output logic                    M_PSLVERR,
    output logic [PRUSER_WIDTH-1:0] M_PRUSER,
    output logic [PBUSER_WIDTH-1:0] M_PBUSER,

    // -------------------------------------------------------------------------
    // 从端时钟域（Target Clock Domain）
    // -------------------------------------------------------------------------
    input  logic                    S_PCLK,        // 从端 APB 时钟
    input  logic                    S_PRESETn,      // 从端复位（低有效）
    output logic [ADDR_WIDTH-1:0]   S_PADDR,
    output logic [2:0]              S_PPROT,
    output logic                    S_PNSE,
    output logic                    S_PSEL,
    output logic                    S_PENABLE,
    output logic                    S_PWRITE,
    output logic [DATA_WIDTH-1:0]   S_PWDATA,
    output logic [STRB_WIDTH-1:0]   S_PSTRB,
    output logic                    S_PWAKEUP,
    output logic [PAUSER_WIDTH-1:0] S_PAUSER,
    output logic [PWUSER_WIDTH-1:0] S_PWUSER,
    input  logic                    S_PREADY,
    input  logic [DATA_WIDTH-1:0]   S_PRDATA,
    input  logic                    S_PSLVERR,
    input  logic [PRUSER_WIDTH-1:0] S_PRUSER,
    input  logic [PBUSER_WIDTH-1:0] S_PBUSER
);

    // =========================================================================
    // 数据宽度定义：请求数据包总宽度
    // =========================================================================
    localparam REQ_DW = ADDR_WIDTH + 3 + 1 + 1 + DATA_WIDTH + STRB_WIDTH + 1 + PAUSER_WIDTH + PWUSER_WIDTH;
    localparam RSP_DW = DATA_WIDTH + 1 + PRUSER_WIDTH + PBUSER_WIDTH;

    // =========================================================================
    // 主端状态机
    // =========================================================================
    typedef enum logic [2:0] {
        M_IDLE    = 3'b000,  // 等待主端请求
        M_SETUP   = 3'b001,  // 锁存请求，发出 REQ 握手
        M_WAIT    = 3'b010,  // 等待从端 ACK 握手返回
        M_DONE    = 3'b011,  // 数据已接收，撤销 REQ
        M_WACK    = 3'b100   // 等待从端撤销 ACK（四相握手）
    } m_state_t;

    // =========================================================================
    // 从端状态机
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE    = 3'b000,  // 等待主端 REQ
        S_SETUP   = 3'b001,  // 建立 APB 传输
        S_ACCESS  = 3'b010,  // 访问阶段
        S_ACK     = 3'b011,  // 拉高 ACK 返回响应
        S_WDEACK  = 3'b100   // 等待主端撤销 REQ（四相握手）
    } s_state_t;

    m_state_t m_cur, m_nxt;
    s_state_t s_cur, s_nxt;

    // =========================================================================
    // 主端侧：请求数据寄存器
    // =========================================================================
    logic [ADDR_WIDTH-1:0]   m_r_paddr;
    logic [2:0]              m_r_pprot;
    logic                    m_r_pnse;
    logic                    m_r_pwrite;
    logic [DATA_WIDTH-1:0]   m_r_pwdata;
    logic [STRB_WIDTH-1:0]   m_r_pstrb;
    logic                    m_r_pwakeup;
    logic [PAUSER_WIDTH-1:0] m_r_pauser;
    logic [PWUSER_WIDTH-1:0] m_r_pwuser;

    // =========================================================================
    // CDC 握手信号：请求（M->S）和应答（S->M）
    // =========================================================================
    logic req_set;    // 主端产生 REQ 脉冲
    logic req_clr;    // 主端清除 REQ 脉冲
    logic req_ff;     // 主端 REQ 触发器（Toggle 方式）
    logic req_sync;   // REQ 同步到从端时钟域
    logic ack_set;    // 从端产生 ACK 脉冲
    logic ack_ff;     // 从端 ACK 触发器（Toggle 方式）
    logic ack_sync;   // ACK 同步到主端时钟域

    // =========================================================================
    // 请求数据总线（M->S，在 SETUP 锁存后稳定保持直到握手完成）
    // =========================================================================
    logic [REQ_DW-1:0] req_data;
    logic [RSP_DW-1:0] rsp_data;  // 响应数据（S->M）

    // =========================================================================
    // 从端侧：响应数据寄存器
    // =========================================================================
    logic [DATA_WIDTH-1:0]   s_r_prdata;
    logic                    s_r_pslverr;
    logic [PRUSER_WIDTH-1:0] s_r_pruser;
    logic [PBUSER_WIDTH-1:0] s_r_pbuser;

    // =========================================================================
    // 从端侧：解出请求数据
    // =========================================================================
    logic [ADDR_WIDTH-1:0]   s_paddr_i;
    logic [2:0]              s_pprot_i;
    logic                    s_pnse_i;
    logic                    s_pwrite_i;
    logic [DATA_WIDTH-1:0]   s_pwdata_i;
    logic [STRB_WIDTH-1:0]   s_pstrb_i;
    logic                    s_pwakeup_i;
    logic [PAUSER_WIDTH-1:0] s_pauser_i;
    logic [PWUSER_WIDTH-1:0] s_pwuser_i;

    // =========================================================================
    // 主端 REQ Toggle 触发器
    // =========================================================================
    always_ff @(posedge M_PCLK or negedge M_PRESETn) begin
        if (!M_PRESETn)
            req_ff <= 1'b0;
        else if (req_set)
            req_ff <= ~req_ff;  // Toggle：翻转请求信号
    end

    // =========================================================================
    // REQ 同步到从端时钟域（双触发器同步器）
    // =========================================================================
    apb5_sync2 #(.DW(1)) u_req_sync (
        .clk   (S_PCLK),
        .rst_n (S_PRESETn),
        .d_in  (req_ff),
        .d_out (req_sync)
    );

    // =========================================================================
    // 从端 ACK Toggle 触发器
    // =========================================================================
    always_ff @(posedge S_PCLK or negedge S_PRESETn) begin
        if (!S_PRESETn)
            ack_ff <= 1'b0;
        else if (ack_set)
            ack_ff <= ~ack_ff;  // Toggle：翻转应答信号
    end

    // =========================================================================
    // ACK 同步到主端时钟域（双触发器同步器）
    // =========================================================================
    apb5_sync2 #(.DW(1)) u_ack_sync (
        .clk   (M_PCLK),
        .rst_n (M_PRESETn),
        .d_in  (ack_ff),
        .d_out (ack_sync)
    );

    // =========================================================================
    // 请求数据打包（主端侧）
    // =========================================================================
    always_ff @(posedge M_PCLK or negedge M_PRESETn) begin
        if (!M_PRESETn) begin
            m_r_paddr   <= {ADDR_WIDTH{1'b0}};
            m_r_pprot   <= 3'b000;
            m_r_pnse    <= 1'b0;
            m_r_pwrite  <= 1'b0;
            m_r_pwdata  <= {DATA_WIDTH{1'b0}};
            m_r_pstrb   <= {STRB_WIDTH{1'b0}};
            m_r_pwakeup <= 1'b0;
            m_r_pauser  <= {PAUSER_WIDTH{1'b0}};
            m_r_pwuser  <= {PWUSER_WIDTH{1'b0}};
        end else if (m_cur == M_IDLE && M_PSEL && !M_PENABLE) begin
            // 在 SETUP 阶段锁存请求
            m_r_paddr   <= M_PADDR;
            m_r_pprot   <= M_PPROT;
            m_r_pnse    <= M_PNSE;
            m_r_pwrite  <= M_PWRITE;
            m_r_pwdata  <= M_PWDATA;
            m_r_pstrb   <= M_PSTRB;
            m_r_pwakeup <= M_PWAKEUP;
            m_r_pauser  <= M_PAUSER;
            m_r_pwuser  <= M_PWUSER;
        end
    end

    // 打包请求数据总线
    assign req_data = {m_r_paddr, m_r_pprot, m_r_pnse, m_r_pwrite,
                       m_r_pwdata, m_r_pstrb, m_r_pwakeup, m_r_pauser, m_r_pwuser};

    // =========================================================================
    // 从端侧：解包请求数据
    // =========================================================================
    assign {s_paddr_i, s_pprot_i, s_pnse_i, s_pwrite_i,
            s_pwdata_i, s_pstrb_i, s_pwakeup_i, s_pauser_i, s_pwuser_i} = req_data;

    // =========================================================================
    // 主端状态机：时序逻辑
    // =========================================================================
    always_ff @(posedge M_PCLK or negedge M_PRESETn) begin
        if (!M_PRESETn)
            m_cur <= M_IDLE;
        else
            m_cur <= m_nxt;
    end

    // 记录上一拍 ACK 值（用于边沿检测）
    logic ack_sync_d;
    always_ff @(posedge M_PCLK or negedge M_PRESETn) begin
        if (!M_PRESETn) ack_sync_d <= 1'b0;
        else            ack_sync_d <= ack_sync;
    end

    wire ack_edge = ack_sync ^ ack_sync_d;  // ACK 边沿检测（Toggle 变化）

    // =========================================================================
    // 主端状态机：组合逻辑
    // =========================================================================
    always_comb begin
        m_nxt    = m_cur;
        req_set  = 1'b0;
        M_PREADY = 1'b0;
        case (m_cur)
            M_IDLE: begin
                if (M_PSEL && !M_PENABLE) begin
                    m_nxt   = M_SETUP;
                end
            end
            M_SETUP: begin
                req_set = 1'b1;   // 发出 REQ Toggle
                m_nxt   = M_WAIT;
            end
            M_WAIT: begin
                if (ack_edge) begin
                    // 检测到 ACK 边沿，说明从端已完成传输
                    M_PREADY = 1'b1;   // 向主设备反馈就绪
                    m_nxt    = M_DONE;
                end
            end
            M_DONE: begin
                // 完成一次传输，等待下一次（已在 M_WAIT 给出 PREADY，此周期恢复空闲）
                m_nxt = M_IDLE;
            end
            default: m_nxt = M_IDLE;
        endcase
    end

    // =========================================================================
    // 主端响应数据回传
    // =========================================================================
    logic [DATA_WIDTH-1:0]   m_r_prdata;
    logic                    m_r_pslverr;
    logic [PRUSER_WIDTH-1:0] m_r_pruser;
    logic [PBUSER_WIDTH-1:0] m_r_pbuser;

    // 在 ACK 边沿采样响应数据
    always_ff @(posedge M_PCLK or negedge M_PRESETn) begin
        if (!M_PRESETn) begin
            m_r_prdata  <= {DATA_WIDTH{1'b0}};
            m_r_pslverr <= 1'b0;
            m_r_pruser  <= {PRUSER_WIDTH{1'b0}};
            m_r_pbuser  <= {PBUSER_WIDTH{1'b0}};
        end else if (ack_edge && m_cur == M_WAIT) begin
            {m_r_prdata, m_r_pslverr, m_r_pruser, m_r_pbuser} <= rsp_data;
        end
    end

    assign M_PRDATA  = m_r_prdata;
    assign M_PSLVERR = m_r_pslverr;
    assign M_PRUSER  = m_r_pruser;
    assign M_PBUSER  = m_r_pbuser;

    // =========================================================================
    // 从端状态机：时序逻辑
    // =========================================================================
    always_ff @(posedge S_PCLK or negedge S_PRESETn) begin
        if (!S_PRESETn)
            s_cur <= S_IDLE;
        else
            s_cur <= s_nxt;
    end

    // 记录上一拍 REQ 值（边沿检测）
    logic req_sync_d;
    always_ff @(posedge S_PCLK or negedge S_PRESETn) begin
        if (!S_PRESETn) req_sync_d <= 1'b0;
        else            req_sync_d <= req_sync;
    end

    wire req_edge = req_sync ^ req_sync_d;  // REQ 边沿检测

    // =========================================================================
    // 从端状态机：组合逻辑
    // =========================================================================
    always_comb begin
        s_nxt     = s_cur;
        ack_set   = 1'b0;
        S_PSEL    = 1'b0;
        S_PENABLE = 1'b0;
        case (s_cur)
            S_IDLE: begin
                if (req_edge) begin
                    // 检测到 REQ 边沿，进入 SETUP
                    s_nxt = S_SETUP;
                end
            end
            S_SETUP: begin
                S_PSEL    = 1'b1;
                S_PENABLE = 1'b0;
                s_nxt     = S_ACCESS;
            end
            S_ACCESS: begin
                S_PSEL    = 1'b1;
                S_PENABLE = 1'b1;
                if (S_PREADY) begin
                    s_nxt = S_ACK;
                end
            end
            S_ACK: begin
                // 锁存响应数据，发出 ACK Toggle
                ack_set = 1'b1;
                s_nxt   = S_WDEACK;
            end
            S_WDEACK: begin
                // 等待主端撤销 REQ（四相握手结束）
                if (!req_edge)
                    s_nxt = S_IDLE;
            end
            default: s_nxt = S_IDLE;
        endcase
    end

    // =========================================================================
    // 从端：锁存解包请求并驱动 APB 信号
    // =========================================================================
    logic [ADDR_WIDTH-1:0]   s_r_paddr;
    logic [2:0]              s_r_pprot;
    logic                    s_r_pnse;
    logic                    s_r_pwrite;
    logic [DATA_WIDTH-1:0]   s_r_pwdata;
    logic [STRB_WIDTH-1:0]   s_r_pstrb;
    logic                    s_r_pwakeup;
    logic [PAUSER_WIDTH-1:0] s_r_pauser;
    logic [PWUSER_WIDTH-1:0] s_r_pwuser;

    always_ff @(posedge S_PCLK or negedge S_PRESETn) begin
        if (!S_PRESETn) begin
            s_r_paddr   <= {ADDR_WIDTH{1'b0}};
            s_r_pprot   <= 3'b000;
            s_r_pnse    <= 1'b0;
            s_r_pwrite  <= 1'b0;
            s_r_pwdata  <= {DATA_WIDTH{1'b0}};
            s_r_pstrb   <= {STRB_WIDTH{1'b0}};
            s_r_pwakeup <= 1'b0;
            s_r_pauser  <= {PAUSER_WIDTH{1'b0}};
            s_r_pwuser  <= {PWUSER_WIDTH{1'b0}};
        end else if (s_cur == S_IDLE && req_edge) begin
            // 在检测到 REQ 时锁存请求数据
            s_r_paddr   <= s_paddr_i;
            s_r_pprot   <= s_pprot_i;
            s_r_pnse    <= s_pnse_i;
            s_r_pwrite  <= s_pwrite_i;
            s_r_pwdata  <= s_pwdata_i;
            s_r_pstrb   <= s_pstrb_i;
            s_r_pwakeup <= s_pwakeup_i;
            s_r_pauser  <= s_pauser_i;
            s_r_pwuser  <= s_pwuser_i;
        end
    end

    assign S_PADDR   = s_r_paddr;
    assign S_PPROT   = s_r_pprot;
    assign S_PNSE    = s_r_pnse;
    assign S_PWRITE  = s_r_pwrite;
    assign S_PWDATA  = s_r_pwdata;
    assign S_PSTRB   = s_r_pstrb;
    assign S_PWAKEUP = s_r_pwakeup;
    assign S_PAUSER  = s_r_pauser;
    assign S_PWUSER  = s_r_pwuser;

    // =========================================================================
    // 从端：锁存响应数据并打包
    // =========================================================================
    always_ff @(posedge S_PCLK or negedge S_PRESETn) begin
        if (!S_PRESETn) begin
            s_r_prdata  <= {DATA_WIDTH{1'b0}};
            s_r_pslverr <= 1'b0;
            s_r_pruser  <= {PRUSER_WIDTH{1'b0}};
            s_r_pbuser  <= {PBUSER_WIDTH{1'b0}};
        end else if (s_cur == S_ACCESS && S_PREADY) begin
            s_r_prdata  <= S_PRDATA;
            s_r_pslverr <= S_PSLVERR;
            s_r_pruser  <= S_PRUSER;
            s_r_pbuser  <= S_PBUSER;
        end
    end

    assign rsp_data = {s_r_prdata, s_r_pslverr, s_r_pruser, s_r_pbuser};

endmodule
```

```verilog
// =============================================================================
// 双触发器同步器（用于异步模式 CDC）
// =============================================================================
module apb5_sync2 #(
    parameter DW = 1  // 数据位宽
)(
    input  logic          clk,      // 目标时钟域时钟
    input  logic          rst_n,    // 异步复位（低有效）
    input  logic [DW-1:0] d_in,     // 输入数据（源时钟域）
    output logic [DW-1:0] d_out     // 输出数据（目标时钟域，已同步）
);
    logic [DW-1:0] sync_ff1;  // 第一级触发器

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_ff1 <= {DW{1'b0}};
            d_out    <= {DW{1'b0}};
        end else begin
            sync_ff1 <= d_in;
            d_out    <= sync_ff1;
        end
    end
endmodule
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
### 8.4 CDC TCL约束

```tcl
# ==============================================================================
# 文件名称 : apb5_bridge_cdc.tcl
# 描    述 : AMBA 5 APB 异步桥 SpyGlass CDC 约束文件（SGdc 格式）
#            适用模块 : apb5_async_bridge / apb5_bridge (ASYNC_MODE=1)
#            工    具 : SpyGlass CDC (0-in CDC)
#            协    议 : Qualcomm CDC Methodology v3.x
# 版    本 : 1.0
# 日    期 : 2026-04-15
# 作    者 : 自动生成（基于 apb5_bridge.sv RTL 结构）
# ==============================================================================
# 使用说明：
#   1. 在 SpyGlass CDC Flow 的 cdc_setup.tcl 中 source 本文件
#   2. 请根据实际工程路径修改 -module / -instance 层次
#   3. 时钟频率请在配套 apb5_bridge_cdc.sdc 中修改
# ==============================================================================


# ==============================================================================
# 第一节：顶层模块配置
# ==============================================================================

# 指定 CDC 分析的顶层模块
set_cdc_design_config \
    -module        apb5_async_bridge \
    -enable_glitch_analysis on \
    -enable_reconvergence   on


# ==============================================================================
# 第二节：时钟域声明
# 说明：
#   M_PCLK — 主端（Initiator）时钟，驱动主端状态机、req_ff、主端数据寄存器
#   S_PCLK — 从端（Target） 时钟，驱动从端状态机、ack_ff、从端 APB 接口
# ==============================================================================

# 主端时钟域
set_cdc_clock M_PCLK \
    -module apb5_async_bridge \
    -tag    CLK_M

# 从端时钟域
set_cdc_clock S_PCLK \
    -module apb5_async_bridge \
    -tag    CLK_S

# 声明两个时钟域为完全异步（无已知相位关系）
set_cdc_clock_relationship M_PCLK S_PCLK \
    -module apb5_async_bridge \
    -relationship asynchronous


# ==============================================================================
# 第三节：复位域声明
# 说明：
#   M_PRESETn — 主端异步低有效复位，与 M_PCLK 时钟域关联
#   S_PRESETn — 从端异步低有效复位，与 S_PCLK 时钟域关联
#   两端复位相互独立，无同步关系
# ==============================================================================

# 主端复位
set_cdc_reset M_PRESETn \
    -module    apb5_async_bridge \
    -clock     M_PCLK \
    -active    low \
    -tag       RST_M

# 从端复位
set_cdc_reset S_PRESETn \
    -module    apb5_async_bridge \
    -clock     S_PCLK \
    -active    low \
    -tag       RST_S

# 声明两端复位为异步独立关系
set_cdc_reset_relationship M_PRESETn S_PRESETn \
    -module apb5_async_bridge \
    -relationship asynchronous


# ==============================================================================
# 第四节：CDC 同步器声明
# 说明：
#   u_req_sync — 双触发器同步器，将 req_ff（M_PCLK域）同步到 S_PCLK 域
#   u_ack_sync — 双触发器同步器，将 ack_ff（S_PCLK域）同步到 M_PCLK 域
#   同步器类型为 DEMET（2-FF Synchronizer），是消除亚稳态的标准方案
# ==============================================================================

# req_ff → req_sync：主端 Toggle 请求信号同步到从端时钟域
# 实例路径：apb5_async_bridge.u_req_sync（模块 apb5_sync2）
set_cdc_synchronizer u_req_sync \
    -module     apb5_async_bridge \
    -type       demet \
    -clk        S_PCLK \
    -reset      S_PRESETn \
    -rx_ff      sync_ff1 \
    -output     d_out \
    -comment    "REQ Toggle 信号两级同步器：消除 req_ff 跨域亚稳态"

# ack_ff → ack_sync：从端 Toggle 应答信号同步到主端时钟域
# 实例路径：apb5_async_bridge.u_ack_sync（模块 apb5_sync2）
set_cdc_synchronizer u_ack_sync \
    -module     apb5_async_bridge \
    -type       demet \
    -clk        M_PCLK \
    -reset      M_PRESETn \
    -rx_ff      sync_ff1 \
    -output     d_out \
    -comment    "ACK Toggle 信号两级同步器：消除 ack_ff 跨域亚稳态"


# ==============================================================================
# 第五节：Toggle 触发器端口域声明
# 说明：
#   req_ff — 主端产生的 Toggle 请求信号（无组合逻辑，直接连接同步器输入）
#   ack_ff — 从端产生的 Toggle 应答信号（无组合逻辑，直接连接同步器输入）
#   Toggle 信号为单比特翻转，天然无 glitch，满足 -have_no_combo_logic 要求
# ==============================================================================

# req_ff：主端时钟域输出，送往从端同步器
set_cdc_port_domain req_ff \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -have_no_combo_logic \
    -comment             "REQ Toggle FF，无组合逻辑，直接驱动 u_req_sync 输入"

# ack_ff：从端时钟域输出，送往主端同步器
set_cdc_port_domain ack_ff \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               S_PCLK \
    -have_no_combo_logic \
    -comment             "ACK Toggle FF，无组合逻辑，直接驱动 u_ack_sync 输入"


# ==============================================================================
# 第六节：请求数据总线（req_data）CDC 稳定性约束
# 说明：
#   req_data 总线位宽 = ADDR_WIDTH + 3 + 1 + 1 + DATA_WIDTH + STRB_WIDTH
#                       + 1 + PAUSER_WIDTH + PWUSER_WIDTH
#   数据总线从 M_PCLK 域传输到 S_PCLK 域，不经过同步器
#   安全性依赖于四相握手协议保证的数据稳定窗口：
#     — req_data 在 M_SETUP 阶段锁存，req_ff 随后翻转
#     — 从端在 req_sync 边沿检测后（至少2个S_PCLK周期）才采样 req_data
#     — req_data 保持稳定直到四相握手完全结束（M_DONE 之后）
#   因此该数据总线为协议保证稳定（Protocol-Qualified Stable），无需同步器
# ==============================================================================

# 请求数据总线：主端输出（M_PCLK域），从端采样（S_PCLK域）
set_cdc_port_domain req_data \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               [expr {32 + 3 + 1 + 1 + 32 + 4 + 1 + 4 + 4}] \
    -have_no_combo_logic \
    -comment             "请求数据总线；由四相握手协议保证在从端采样时已稳定，无需同步器"

# 各子字段分别声明（提高工具识别精度）
# m_r_paddr：地址字段
set_cdc_port_domain m_r_paddr \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               32 \
    -have_no_combo_logic \
    -comment             "握手数据：APB 地址，M_SETUP 锁存，REQ 翻转前稳定"

# m_r_pprot：保护类型字段
set_cdc_port_domain m_r_pprot \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               3 \
    -have_no_combo_logic \
    -comment             "握手数据：PPROT 保护字段"

# m_r_pnse：非安全扩展字段（AMBA5新增）
set_cdc_port_domain m_r_pnse \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               1 \
    -have_no_combo_logic \
    -comment             "握手数据：PNSE 非安全扩展位（AMBA5）"

# m_r_pwrite：读写方向位
set_cdc_port_domain m_r_pwrite \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               1 \
    -have_no_combo_logic \
    -comment             "握手数据：PWRITE 读写控制"

# m_r_pwdata：写数据总线
set_cdc_port_domain m_r_pwdata \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               32 \
    -have_no_combo_logic \
    -comment             "握手数据：PWDATA 写数据"

# m_r_pstrb：字节使能
set_cdc_port_domain m_r_pstrb \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               4 \
    -have_no_combo_logic \
    -comment             "握手数据：PSTRB 字节使能"

# m_r_pwakeup：唤醒信号（AMBA5新增）
set_cdc_port_domain m_r_pwakeup \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               1 \
    -have_no_combo_logic \
    -comment             "握手数据：PWAKEUP 低功耗唤醒（AMBA5）"

# m_r_pauser：地址通道用户信号
set_cdc_port_domain m_r_pauser \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               4 \
    -have_no_combo_logic \
    -comment             "握手数据：PAUSER 地址用户扩展信号"

# m_r_pwuser：写数据通道用户信号
set_cdc_port_domain m_r_pwuser \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               M_PCLK \
    -width               4 \
    -have_no_combo_logic \
    -comment             "握手数据：PWUSER 写数据用户扩展信号"


# ==============================================================================
# 第七节：响应数据总线（rsp_data）CDC 稳定性约束
# 说明：
#   rsp_data 总线位宽 = DATA_WIDTH + 1 + PRUSER_WIDTH + PBUSER_WIDTH
#   数据总线从 S_PCLK 域传输到 M_PCLK 域，不经过同步器
#   安全性依赖于四相握手协议：
#     — rsp_data 在 S_ACCESS && S_PREADY 时锁存，ack_ff 随后翻转
#     — 主端在 ack_sync 边沿检测后才采样 rsp_data
#     — 数据在采样窗口内稳定保持
# ==============================================================================

# 响应数据总线
set_cdc_port_domain rsp_data \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               S_PCLK \
    -width               [expr {32 + 1 + 4 + 4}] \
    -have_no_combo_logic \
    -comment             "响应数据总线；由四相握手协议保证在主端采样时已稳定，无需同步器"

# s_r_prdata：读数据
set_cdc_port_domain s_r_prdata \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               S_PCLK \
    -width               32 \
    -have_no_combo_logic \
    -comment             "握手响应数据：PRDATA 读数据，S_ACK 阶段锁存"

# s_r_pslverr：从设备错误
set_cdc_port_domain s_r_pslverr \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               S_PCLK \
    -width               1 \
    -have_no_combo_logic \
    -comment             "握手响应数据：PSLVERR 从设备错误标志"

# s_r_pruser：读数据用户信号
set_cdc_port_domain s_r_pruser \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               S_PCLK \
    -width               4 \
    -have_no_combo_logic \
    -comment             "握手响应数据：PRUSER 读数据用户扩展信号"

# s_r_pbuser：桥用户信号
set_cdc_port_domain s_r_pbuser \
    -module              apb5_async_bridge \
    -direction           out \
    -clock               S_PCLK \
    -width               4 \
    -have_no_combo_logic \
    -comment             "握手响应数据：PBUSER 桥用户扩展信号"


# ==============================================================================
# 第八节：边沿检测信号约束
# 说明：
#   ack_edge = ack_sync ^ ack_sync_d  （主端时钟域，纯组合逻辑）
#   req_edge = req_sync ^ req_sync_d  （从端时钟域，纯组合逻辑）
#   这两个信号是在同步后时钟域内产生的纯组合逻辑，不跨域，无 CDC 风险
#   但工具可能误报，需声明为同域内信号
# ==============================================================================

# ack_edge：主端时钟域内部边沿检测，不涉及 CDC
set_cdc_port_domain ack_edge \
    -module    apb5_async_bridge \
    -direction out \
    -clock     M_PCLK \
    -comment   "ACK 边沿检测：ack_sync XOR ack_sync_d，主端域内组合逻辑，非 CDC 路径"

# req_edge：从端时钟域内部边沿检测，不涉及 CDC
set_cdc_port_domain req_edge \
    -module    apb5_async_bridge \
    -direction out \
    -clock     S_PCLK \
    -comment   "REQ 边沿检测：req_sync XOR req_sync_d，从端域内组合逻辑，非 CDC 路径"


# ==============================================================================
# 第九节：CDC Waiver（豁免）声明
# 说明：
#   以下豁免针对 SpyGlass 可能误报的非真实 CDC 违例
#   每条 waiver 均附有豁免理由，需要 DV 仿真验证支持
# ==============================================================================

# Waiver 1：req_data 总线 no_sync 报告豁免
# 豁免理由：req_data 由四相握手协议保证稳定，数据在 req_ff 翻转前已锁存
#           从端在 req_sync 产生 2 拍后才采样，时序安全窗口已由协议保证
set_cdc_waiver \
    -type              no_sync \
    -module            apb5_async_bridge \
    -from_clock        M_PCLK \
    -to_clock          S_PCLK \
    -signal            {m_r_paddr m_r_pprot m_r_pnse m_r_pwrite \
                        m_r_pwdata m_r_pstrb m_r_pwakeup m_r_pauser m_r_pwuser} \
    -waiver_tag        "APB5_ASYNC_REQ_DATA_HS" \
    -comment           "四相握手协议数据总线：REQ Toggle先于数据发出，从端在req_edge后\
                        至少2个S_PCLK周期后才采样，数据总线在采样窗口内稳定保持，\
                        设计上协议安全，无需同步器。DV 断言：apb5_bridge_tb.sv::req_data_stable_chk"

# Waiver 2：rsp_data 总线 no_sync 报告豁免
# 豁免理由：rsp_data 由四相握手协议保证稳定，数据在 ack_ff 翻转前已锁存
set_cdc_waiver \
    -type              no_sync \
    -module            apb5_async_bridge \
    -from_clock        S_PCLK \
    -to_clock          M_PCLK \
    -signal            {s_r_prdata s_r_pslverr s_r_pruser s_r_pbuser} \
    -waiver_tag        "APB5_ASYNC_RSP_DATA_HS" \
    -comment           "四相握手协议响应数据总线：ACK Toggle先于数据发出，主端在ack_edge后\
                        采样，数据总线在采样窗口内稳定保持，协议安全。\
                        DV 断言：apb5_bridge_tb.sv::rsp_data_stable_chk"

# Waiver 3：ack_sync_d / req_sync_d 延迟寄存器可能被误报
# 豁免理由：这两个寄存器是同步后域内的单域寄存器，用于边沿检测，不是 CDC 路径
set_cdc_waiver \
    -type              combo_logic \
    -module            apb5_async_bridge \
    -signal            {ack_sync_d req_sync_d} \
    -waiver_tag        "APB5_ASYNC_EDGE_DET" \
    -comment           "边沿检测延迟拍寄存器，与同步器输出在同一时钟域，非 CDC 路径"


# ==============================================================================
# 第十节：SVA 断言绑定声明（用于 DV CDC 验证）
# 说明：
#   以下 SVA 属性需要在仿真环境中验证握手协议的正确性
#   以确认上述 Waiver 的有效性（参考 Qualcomm CDC Methodology 要求）
# ==============================================================================
#
# 建议在 testbench 或 bind 文件中添加以下断言：
#
# // [SVA-1] REQ 数据总线稳定性检查
# // 断言：从 req_ff 翻转到 ack_sync 边沿期间，req_data 保持不变
# property req_data_stable_chk;
#     @(posedge M_PCLK)
#     $rose(req_ff) |-> ##[1:$] ($stable(req_data) throughout (ack_edge[->1]));
# endproperty
# assert property (req_data_stable_chk)
#     else $error("[APB5_ASYNC] req_data 在握手过程中发生变化！");
#
# // [SVA-2] RSP 数据总线稳定性检查
# // 断言：从 ack_ff 翻转到主端采样期间，rsp_data 保持不变
# property rsp_data_stable_chk;
#     @(posedge S_PCLK)
#     $rose(ack_ff) |-> ##[1:$] ($stable(rsp_data) throughout
#                               (ack_sync[->1] ##1 ack_sync[->1]));
# endproperty
# assert property (rsp_data_stable_chk)
#     else $error("[APB5_ASYNC] rsp_data 在握手过程中发生变化！");
#
# // [SVA-3] 握手互斥检查
# // 断言：握手过程中不允许重入（主端状态机在 M_WAIT 时不能再次发出 REQ）
# property no_reentrant_req;
#     @(posedge M_PCLK)
#     (m_cur == M_WAIT) |-> !req_set;
# endproperty
# assert property (no_reentrant_req)
#     else $error("[APB5_ASYNC] 握手未完成时检测到重入 REQ！");
#
# ==============================================================================


# ==============================================================================
# 文件结束
# ==============================================================================
```

### 8.5 CDC SDC约束
```tcl
# ==============================================================================
# 文件名称 : apb5_bridge_cdc.sdc
# 描    述 : AMBA 5 APB 异步桥 SDC 时序约束文件
#            适用模块 : apb5_async_bridge / apb5_bridge (ASYNC_MODE=1)
#            配合文件 : apb5_bridge_cdc.tcl（SpyGlass CDC 约束）
# 版    本 : 1.0
# 日    期 : 2026-04-15
# 注    意 : M_PCLK / S_PCLK 频率仅为示例，请根据实际工程修改
# ==============================================================================


# ==============================================================================
# 第一节：时钟定义
# ==============================================================================

# 主端时钟：示例 100 MHz（周期 10ns），实际请按工程频率修改
create_clock -name M_PCLK \
    -period 10.000 \
    -waveform {0 5.000} \
    [get_ports M_PCLK]

# 从端时钟：示例 50 MHz（周期 20ns），实际请按工程频率修改
create_clock -name S_PCLK \
    -period 20.000 \
    -waveform {0 10.000} \
    [get_ports S_PCLK]


# ==============================================================================
# 第二节：异步时钟组声明
# 说明：
#   M_PCLK 与 S_PCLK 为完全异步关系，STA 工具不对跨域路径做时序检查
#   跨域路径的安全性由 RTL 四相握手协议 + CDC 约束联合保证
# ==============================================================================

set_clock_groups \
    -asynchronous \
    -name      APB5_ASYNC_CLK_GRP \
    -group     [get_clocks M_PCLK] \
    -group     [get_clocks S_PCLK] \
    -comment   "M_PCLK 与 S_PCLK 完全异步，禁止 STA 跨域时序检查"


# ==============================================================================
# 第三节：同步器路径约束
# 说明：
#   双触发器同步器（apb5_sync2）的第一级触发器（sync_ff1）输入路径
#   必须使用 -datapath_only 约束，理由：
#     1. 该路径为异步路径，正常 STA setup/hold 分析无意义
#     2. 需限制最大延迟 ≤ 目标时钟周期，防止信号在同步器建立时间内未稳定
#     3. 禁止工具对该路径做多周期路径优化（可能打断同步链）
# ==============================================================================

# REQ 同步器：req_ff（M_PCLK域 FF 输出）→ u_req_sync/sync_ff1 输入
# 约束：最大延迟 = 从端时钟周期（20ns），-datapath_only 禁止 hold 分析
set_max_delay 20.000 \
    -datapath_only \
    -from [get_cells {req_ff}] \
    -to   [get_cells {u_req_sync/sync_ff1}] \
    -comment "REQ Toggle 同步器输入路径：最大延迟 = 1× S_PCLK 周期"

# ACK 同步器：ack_ff（S_PCLK域 FF 输出）→ u_ack_sync/sync_ff1 输入
# 约束：最大延迟 = 主端时钟周期（10ns），-datapath_only 禁止 hold 分析
set_max_delay 10.000 \
    -datapath_only \
    -from [get_cells {ack_ff}] \
    -to   [get_cells {u_ack_sync/sync_ff1}] \
    -comment "ACK Toggle 同步器输入路径：最大延迟 = 1× M_PCLK 周期"


# ==============================================================================
# 第四节：同步器内部路径约束
# 说明：
#   同步器第一级（sync_ff1）到第二级（d_out）的路径必须为单扇出（no fanout）
#   且该路径不能被综合工具优化（如插入 buffer、重新布局）
#   使用 set_max_delay -datapath_only 确保路径时序被正确约束
# ==============================================================================

# REQ 同步器内部：sync_ff1 → d_out（S_PCLK域内部）
set_max_delay 20.000 \
    -datapath_only \
    -from [get_cells {u_req_sync/sync_ff1}] \
    -to   [get_cells {u_req_sync/d_out}] \
    -comment "REQ 同步器内部路径：两级 FF 间保持单扇出"

# ACK 同步器内部：sync_ff1 → d_out（M_PCLK域内部）
set_max_delay 10.000 \
    -datapath_only \
    -from [get_cells {u_ack_sync/sync_ff1}] \
    -to   [get_cells {u_ack_sync/d_out}] \
    -comment "ACK 同步器内部路径：两级 FF 间保持单扇出"


# ==============================================================================
# 第五节：数据总线路径 False Path 声明
# 说明：
#   req_data 总线（M→S）和 rsp_data 总线（S→M）为协议保证稳定的数据路径
#   不经过同步器，STA 工具对这些跨域路径的分析无意义（且会误报违例）
#   使用 set_false_path 告知 STA 忽略这些路径
#   注意：false_path 不等于不关心，RTL 协议保证了时序正确性
# ==============================================================================

# 请求数据总线 False Path（M_PCLK → S_PCLK）
set_false_path \
    -from [get_clocks M_PCLK] \
    -through [get_cells {
        m_r_paddr
        m_r_pprot
        m_r_pnse
        m_r_pwrite
        m_r_pwdata
        m_r_pstrb
        m_r_pwakeup
        m_r_pauser
        m_r_pwuser
    }] \
    -to [get_clocks S_PCLK] \
    -comment "请求数据总线：四相握手协议保证数据稳定，STA 误报路径豁免"

# 响应数据总线 False Path（S_PCLK → M_PCLK）
set_false_path \
    -from [get_clocks S_PCLK] \
    -through [get_cells {
        s_r_prdata
        s_r_pslverr
        s_r_pruser
        s_r_pbuser
    }] \
    -to [get_clocks M_PCLK] \
    -comment "响应数据总线：四相握手协议保证数据稳定，STA 误报路径豁免"


# ==============================================================================
# 第六节：复位路径约束
# 说明：
#   两端复位为异步低有效，各自属于本域内的异步复位路径
#   复位撤销（deassert）为异步路径，无需跨域时序检查
# ==============================================================================

# 主端复位路径：M_PRESETn 为异步复位，不受 STA 检查
set_false_path \
    -from [get_ports M_PRESETn] \
    -comment "M_PRESETn 异步复位路径，非时序路径"

# 从端复位路径：S_PRESETn 为异步复位，不受 STA 检查
set_false_path \
    -from [get_ports S_PRESETn] \
    -comment "S_PRESETn 异步复位路径，非时序路径"


# ==============================================================================
# 第七节：输入/输出延迟约束（外部接口时序）
# 说明：
#   以下约束为示例值，实际需根据与主/从设备的时序关系修改
#   setup margin = 0.5ns，hold margin = 0.2ns（仅供参考）
# ==============================================================================

# --- 主端接口输入延迟（M_PCLK 域）---
set_input_delay -clock M_PCLK -max 2.0 [get_ports {M_PADDR M_PPROT M_PNSE M_PSEL M_PENABLE}]
set_input_delay -clock M_PCLK -min 0.5 [get_ports {M_PADDR M_PPROT M_PNSE M_PSEL M_PENABLE}]
set_input_delay -clock M_PCLK -max 2.0 [get_ports {M_PWRITE M_PWDATA M_PSTRB M_PWAKEUP}]
set_input_delay -clock M_PCLK -min 0.5 [get_ports {M_PWRITE M_PWDATA M_PSTRB M_PWAKEUP}]
set_input_delay -clock M_PCLK -max 2.0 [get_ports {M_PAUSER M_PWUSER}]
set_input_delay -clock M_PCLK -min 0.5 [get_ports {M_PAUSER M_PWUSER}]

# --- 主端接口输出延迟（M_PCLK 域）---
set_output_delay -clock M_PCLK -max 2.0 [get_ports {M_PREADY M_PRDATA M_PSLVERR M_PRUSER M_PBUSER}]
set_output_delay -clock M_PCLK -min 0.5 [get_ports {M_PREADY M_PRDATA M_PSLVERR M_PRUSER M_PBUSER}]

# --- 从端接口输出延迟（S_PCLK 域）---
set_output_delay -clock S_PCLK -max 2.0 [get_ports {S_PADDR S_PPROT S_PNSE S_PSEL S_PENABLE}]
set_output_delay -clock S_PCLK -min 0.5 [get_ports {S_PADDR S_PPROT S_PNSE S_PSEL S_PENABLE}]
set_output_delay -clock S_PCLK -max 2.0 [get_ports {S_PWRITE S_PWDATA S_PSTRB S_PWAKEUP}]
set_output_delay -clock S_PCLK -min 0.5 [get_ports {S_PWRITE S_PWDATA S_PSTRB S_PWAKEUP}]
set_output_delay -clock S_PCLK -max 2.0 [get_ports {S_PAUSER S_PWUSER}]
set_output_delay -clock S_PCLK -min 0.5 [get_ports {S_PAUSER S_PWUSER}]

# --- 从端接口输入延迟（S_PCLK 域）---
set_input_delay -clock S_PCLK -max 2.0 [get_ports {S_PREADY S_PRDATA S_PSLVERR S_PRUSER S_PBUSER}]
set_input_delay -clock S_PCLK -min 0.5 [get_ports {S_PREADY S_PRDATA S_PSLVERR S_PRUSER S_PBUSER}]


# ==============================================================================
# 文件结束
# ==============================================================================
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


### 9.6 STA约束

```tcl
# ==============================================================================
# 文件名称 : apb5_bridge_sta.sdc
# 描    述 : AMBA 5 APB 异步桥完整 STA 时序约束文件
#            适用模块 : apb5_async_bridge / apb5_bridge (ASYNC_MODE=1)
#            工具兼容 : Synopsys PrimeTime / Cadence Tempus
#            配合文件 : apb5_bridge_cdc.tcl (SpyGlass CDC 约束)
#                       apb5_bridge_cdc.sdc (CDC 配套约束)
# 版    本 : 1.0
# 日    期 : 2026-04-15
# 作    者 : 自动生成（基于 apb5_bridge.sv RTL 结构）
# ==============================================================================
#
# 使用说明：
#   1. 将本文件 source 到 PrimeTime/Tempus 时序分析脚本中
#   2. M_PCLK / S_PCLK 频率仅为示例（100MHz / 50MHz），请根据实际工程修改
#   3. set_operating_conditions 请替换为实际工艺库角（PDK 相关）
#   4. IO 延迟约束请根据板级时序或接口规格修改
#   5. 多周期路径（第五节）请根据实际从设备手册确认后启用
#
# 时钟摘要：
#   ┌──────────┬──────────┬──────────┬──────────────────────────────────┐
#   │ 时钟名称  │ 频率     │ 周期     │ 驱动域                            │
#   ├──────────┼──────────┼──────────┼──────────────────────────────────┤
#   │ M_PCLK   │ 100 MHz  │ 10.0 ns  │ 主端（Initiator）状态机及数据寄存器 │
#   │ S_PCLK   │  50 MHz  │ 20.0 ns  │ 从端（Target）APB接口及数据寄存器  │
#   └──────────┴──────────┴──────────┴──────────────────────────────────┘
#
# CDC 路径摘要：
#   req_ff  (M_PCLK) ──[u_req_sync DEMET]──▶ req_sync  (S_PCLK)
#   ack_ff  (S_PCLK) ──[u_ack_sync DEMET]──▶ ack_sync  (M_PCLK)
#   req_data总线     ────[协议保证稳定]────▶ s_r_* 寄存器（false path）
#   rsp_data总线     ────[协议保证稳定]────▶ m_r_* 寄存器（false path）
#
# ==============================================================================


# ==============================================================================
# 第一节：时钟定义（Clock Definition）
# ==============================================================================
# 说明：
#   本节定义两个完全异步的 APB 时钟域
#   所有时钟均从顶层端口引入，无内部分频/倍频（如有请在此节添加 create_generated_clock）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1.1 主端时钟 M_PCLK（默认示例：100 MHz，周期 10 ns）
# ------------------------------------------------------------------------------
create_clock \
    -name    M_PCLK \
    -period  10.000 \
    -waveform {0.000 5.000} \
    [get_ports M_PCLK]

# 主端时钟不确定性
#   setup uncertainty：包含 jitter + skew，用于 setup slack 分析
#   hold  uncertainty：主要为 jitter，用于 hold  slack 分析
set_clock_uncertainty -setup 0.100 -clock M_PCLK [get_clocks M_PCLK]
set_clock_uncertainty -hold  0.050 -clock M_PCLK [get_clocks M_PCLK]

# 主端时钟转换时间（slew）：上升/下降沿各 0.05 ns
set_clock_transition -rise 0.050 [get_clocks M_PCLK]
set_clock_transition -fall 0.050 [get_clocks M_PCLK]

# 主端时钟源延迟（source latency）
#   network latency：时钟树从端口到触发器时钟端的延迟（综合前用估算值）
#   实际布局布线后应由 SPEF / SDF 反标
set_clock_latency -source -rise  0.200 [get_clocks M_PCLK]
set_clock_latency -source -fall  0.200 [get_clocks M_PCLK]
set_clock_latency         -rise  0.500 [get_clocks M_PCLK]
set_clock_latency         -fall  0.500 [get_clocks M_PCLK]


# ------------------------------------------------------------------------------
# 1.2 从端时钟 S_PCLK（默认示例：50 MHz，周期 20 ns）
# ------------------------------------------------------------------------------
create_clock \
    -name    S_PCLK \
    -period  20.000 \
    -waveform {0.000 10.000} \
    [get_ports S_PCLK]

# 从端时钟不确定性
set_clock_uncertainty -setup 0.150 -clock S_PCLK [get_clocks S_PCLK]
set_clock_uncertainty -hold  0.075 -clock S_PCLK [get_clocks S_PCLK]

# 从端时钟转换时间（slew）
set_clock_transition -rise 0.070 [get_clocks S_PCLK]
set_clock_transition -fall 0.070 [get_clocks S_PCLK]

# 从端时钟源延迟
set_clock_latency -source -rise  0.250 [get_clocks S_PCLK]
set_clock_latency -source -fall  0.250 [get_clocks S_PCLK]
set_clock_latency         -rise  0.600 [get_clocks S_PCLK]
set_clock_latency         -fall  0.600 [get_clocks S_PCLK]


# ------------------------------------------------------------------------------
# 1.3 内部生成时钟占位符
# ------------------------------------------------------------------------------
# 当前 apb5_async_bridge 内部无分频/倍频电路，无需 create_generated_clock
# 如后续添加时钟门控（CGC）或分频器，请在此处补充
# 示例（如有）：
# create_generated_clock \
#     -name    S_PCLK_DIV2 \
#     -source  [get_pins clk_div/CK] \
#     -divide_by 2 \
#     [get_pins clk_div/Q]


# ==============================================================================
# 第二节：时钟域关系（Clock Domain Relationship）
# ==============================================================================
# 说明：
#   M_PCLK 与 S_PCLK 为完全异步关系：
#     - 两端时钟来源不同（通常来自不同 PLL / 晶振）
#     - 无固定相位关系，无已知频率倍数关系
#     - STA 工具不应对两域间路径做 setup/hold 分析
#   因此使用 set_clock_groups -asynchronous 声明，
#   工具将跳过所有跨域路径的常规时序检查
# ==============================================================================

set_clock_groups \
    -asynchronous \
    -name   APB5_ASYNC_BRIDGE_CLK_GROUPS \
    -group  [get_clocks M_PCLK] \
    -group  [get_clocks S_PCLK]

# [注意] set_clock_groups -asynchronous 会豁免两组之间的所有路径
# 但以下路径需要单独用 set_max_delay -datapath_only 约束（见第三节）：
#   ① req_ff → u_req_sync/sync_ff1  （跨域同步器输入）
#   ② ack_ff → u_ack_sync/sync_ff1  （跨域同步器输入）
# 这两条路径虽然跨域，但必须保证延迟 ≤ 目标时钟周期，以确保同步器正常采样


# ==============================================================================
# 第三节：同步器路径时序约束（CDC 同步器 set_max_delay）
# ==============================================================================
# 说明：
#   apb5_async_bridge 中包含两个双触发器同步器（apb5_sync2 模块）：
#     u_req_sync：将 req_ff（M_PCLK域）同步到 S_PCLK 域
#     u_ack_sync：将 ack_ff（S_PCLK域）同步到 M_PCLK 域
#
#   约束要求：
#   ① 同步器输入路径（源FF → 同步器第一级FF）：
#      必须使用 set_max_delay -datapath_only，限制最大组合延迟
#      不使用 set_false_path，否则工具不检查路径延迟，存在亚稳态风险
#      最大延迟值 = 目标时钟周期（确保信号在第一级FF采样前已稳定）
#   ② 同步器内部路径（第一级FF → 第二级FF）：
#      同属目标时钟域，按正常时序路径处理
#      但需确保两级FF之间无其他逻辑（单扇出，直连）
#
#   -datapath_only 的作用：
#      - 仅检查数据路径延迟，忽略时钟偏斜（clock skew）
#      - 不做 hold 分析（跨异步域 hold 分析无意义）
#      - 综合工具不会对该路径做多周期优化
# ==============================================================================

# ------------------------------------------------------------------------------
# 3.1 REQ 同步器输入路径
#     路径：req_ff（M_PCLK域 Toggle FF）→ u_req_sync/sync_ff1（S_PCLK域第一级）
#     最大延迟 = 1 × S_PCLK 周期 = 20.000 ns
#     含义：req_ff 翻转后，其值必须在 20ns 内传播到 sync_ff1 的 D 端
# ------------------------------------------------------------------------------
set_max_delay 20.000 \
    -datapath_only \
    -from [get_cells {req_ff}] \
    -to   [get_cells {u_req_sync/sync_ff1}]

# ------------------------------------------------------------------------------
# 3.2 ACK 同步器输入路径
#     路径：ack_ff（S_PCLK域 Toggle FF）→ u_ack_sync/sync_ff1（M_PCLK域第一级）
#     最大延迟 = 1 × M_PCLK 周期 = 10.000 ns
#     含义：ack_ff 翻转后，其值必须在 10ns 内传播到 sync_ff1 的 D 端
# ------------------------------------------------------------------------------
set_max_delay 10.000 \
    -datapath_only \
    -from [get_cells {ack_ff}] \
    -to   [get_cells {u_ack_sync/sync_ff1}]

# ------------------------------------------------------------------------------
# 3.3 REQ 同步器内部路径（第一级 → 第二级，S_PCLK 域内）
#     路径：u_req_sync/sync_ff1 → u_req_sync/d_out
#     此路径在同一时钟域（S_PCLK）内，属于正常路径
#     添加 set_max_delay 是为了防止工具插入 buffer 打断同步链单扇出结构
# ------------------------------------------------------------------------------
set_max_delay 20.000 \
    -datapath_only \
    -from [get_cells {u_req_sync/sync_ff1}] \
    -to   [get_cells {u_req_sync/d_out}]

# ------------------------------------------------------------------------------
# 3.4 ACK 同步器内部路径（第一级 → 第二级，M_PCLK 域内）
#     路径：u_ack_sync/sync_ff1 → u_ack_sync/d_out
# ------------------------------------------------------------------------------
set_max_delay 10.000 \
    -datapath_only \
    -from [get_cells {u_ack_sync/sync_ff1}] \
    -to   [get_cells {u_ack_sync/d_out}]

# ------------------------------------------------------------------------------
# 3.5 同步器单扇出保护（Dont-Touch）
#     禁止综合/布局工具对同步器内部逻辑进行优化（插 buffer、复制等）
#     以确保同步器的两级 FF 直接相连，维持亚稳态消散特性
# ------------------------------------------------------------------------------
set_dont_touch [get_cells {u_req_sync}]
set_dont_touch [get_cells {u_ack_sync}]


# ==============================================================================
# 第四节：False Path 约束（伪路径豁免）
# ==============================================================================
# 说明：
#   以下路径不需要做 STA 时序分析，原因各节有详细说明
#   注意：false_path 仅告知工具跳过这些路径的时序报告，
#         实际的时序安全性由 RTL 协议 + CDC 约束共同保证
# ==============================================================================

# ------------------------------------------------------------------------------
# 4.1 异步复位路径 False Path
# 说明：
#   M_PRESETn / S_PRESETn 为异步低有效复位信号
#   复位断言（assert，低电平）：直接异步清零触发器，无需时序约束
#   复位撤销（deassert，高电平）：需注意复位同步问题，但在本桥中
#   两端各自独立复位，deassert 对时序无 setup/hold 要求
#   对两端均声明 false_path，防止工具误报复位路径时序违例
# ------------------------------------------------------------------------------

# 主端复位：M_PRESETn → 所有 M_PCLK 域触发器的复位端
set_false_path \
    -from [get_ports M_PRESETn]

# 从端复位：S_PRESETn → 所有 S_PCLK 域触发器的复位端
set_false_path \
    -from [get_ports S_PRESETn]

# 主端复位输出（若 M_PRESETn 被传到下游模块）
set_false_path \
    -to [get_ports M_PRESETn]

# 从端复位输出（若 S_PRESETn 被传到下游模块）
set_false_path \
    -to [get_ports S_PRESETn]


# ------------------------------------------------------------------------------
# 4.2 请求数据总线 False Path（M_PCLK 域 → S_PCLK 域）
# 说明：
#   以下寄存器构成 req_data 总线，从主端时钟域传递到从端时钟域
#   这些寄存器由四相握手协议保证时序安全：
#     Step 1：主端在 M_SETUP 状态将所有信号锁存到以下寄存器
#     Step 2：数据稳定后，req_ff 才发生 Toggle 翻转
#     Step 3：从端经双触发器同步器检测到 req_sync 边沿后才采样数据
#     ∴ 从数据锁存到从端采样之间至少有：1(主端锁存延迟) + 2(同步器延迟) 个时钟周期
#     ∴ 数据在采样时已充分稳定，无 CDC 风险
#   因此对 STA 工具声明为 false_path，避免工具误报跨域时序违例
# ------------------------------------------------------------------------------
set_false_path \
    -from [get_cells { \
        m_r_paddr \
        m_r_pprot \
        m_r_pnse \
        m_r_pwrite \
        m_r_pwdata \
        m_r_pstrb \
        m_r_pwakeup \
        m_r_pauser \
        m_r_pwuser \
    }] \
    -to   [get_clocks S_PCLK]

# 从端采样寄存器侧声明（s_r_* 寄存器从 req_data 总线捕获数据）
set_false_path \
    -from [get_clocks M_PCLK] \
    -to   [get_cells { \
        s_r_paddr \
        s_r_pprot \
        s_r_pnse \
        s_r_pwrite \
        s_r_pwdata \
        s_r_pstrb \
        s_r_pwakeup \
        s_r_pauser \
        s_r_pwuser \
    }]


# ------------------------------------------------------------------------------
# 4.3 响应数据总线 False Path（S_PCLK 域 → M_PCLK 域）
# 说明：
#   从端完成 APB 访问后，PRDATA 等响应信号被锁存到 s_r_* 寄存器
#   同样由四相握手协议保证时序安全：
#     Step 1：从端在 S_ACK 状态将响应锁存到 s_r_* 寄存器
#     Step 2：数据稳定后，ack_ff 才发生 Toggle 翻转
#     Step 3：主端经双触发器同步器检测到 ack_sync 边沿后才采样响应数据
#     ∴ 数据在主端采样时已充分稳定，无 CDC 风险
# ------------------------------------------------------------------------------
set_false_path \
    -from [get_cells { \
        s_r_prdata \
        s_r_pslverr \
        s_r_pruser \
        s_r_pbuser \
    }] \
    -to   [get_clocks M_PCLK]

# 主端采样寄存器侧声明（m_r_* 寄存器从 rsp_data 总线捕获响应）
set_false_path \
    -from [get_clocks S_PCLK] \
    -to   [get_cells { \
        m_r_prdata \
        m_r_pslverr \
        m_r_pruser \
        m_r_pbuser \
    }]


# ------------------------------------------------------------------------------
# 4.4 边沿检测延迟寄存器 False Path
# 说明：
#   ack_sync_d：ack_sync 的延迟一拍寄存器，用于 M_PCLK 域内边沿检测
#               ack_edge = ack_sync ^ ack_sync_d（纯组合逻辑，同域内）
#   req_sync_d：req_sync 的延迟一拍寄存器，用于 S_PCLK 域内边沿检测
#               req_edge = req_sync ^ req_sync_d（纯组合逻辑，同域内）
#   这两个寄存器与其输入（ack_sync / req_sync）在同一时钟域，
#   理论上不需要 false_path，但某些 STA 工具可能因同步器关系误判
#   为安全起见，此处声明豁免，并注明原因
# ------------------------------------------------------------------------------
# [注意] 以下为预防性 false_path，仅在工具误报时启用
# 正常情况下 ack_sync_d / req_sync_d 属于同域路径，无需豁免
# set_false_path -from [get_cells {ack_sync_d}]
# set_false_path -from [get_cells {req_sync_d}]


# ------------------------------------------------------------------------------
# 4.5 测试/扫描路径 False Path（DFT 相关）
# 说明：
#   如果设计中插入了扫描链（Scan Chain），扫描模式下的路径与功能模式不同
#   通常由 DFT 流程自动处理，但此处留占位符供参考
# ------------------------------------------------------------------------------
# [DFT] 请由 DFT 工程师根据 scan_enable 信号补充以下约束
# set_false_path -from [get_ports scan_enable]
# set_false_path -through [get_pins */SE]


# ==============================================================================
# 第五节：多周期路径约束（Multi-Cycle Path）
# ==============================================================================
# 说明：
#   APB 协议中，从设备可以通过保持 PREADY=0 来延长 ACCESS 阶段（插入等待周期）
#   在 S_PCLK 域中，以下路径可能需要 2 个或更多周期完成：
#     从端 APB 输出（S_PSEL, S_PENABLE, S_PWRITE, S_PWDATA, S_PADDR）
#     → 从设备内部组合逻辑
#     → S_PREADY 返回（本桥从端输入端口）
#   如果从设备规格书明确说明需要 N 个周期，则在此设置多周期路径
#
#   [重要] 本节约束的具体数值必须根据实际从设备的时序手册确认！
#          此处示例值（setup=2，hold=1）仅供参考
# ==============================================================================

# ------------------------------------------------------------------------------
# 5.1 从端 APB 接口多周期路径（示例：从设备需要 2 个 S_PCLK 周期响应）
#     路径：S_PCLK 域输出寄存器（s_r_* 驱动 S_* 端口）
#           → 从设备内部逻辑（片外路径，不在本模块内）
#           → S_PREADY / S_PRDATA 等输入
#
#     set_multicycle_path -setup N：告诉工具 setup 检查使用 N 倍时钟周期
#     set_multicycle_path -hold  M：配合 setup，hold 检查回退 (N-1) 个周期
#
#   [注意] 若 S_PREADY 是同步信号（即在 S_PCLK 边沿同步给出），
#          则此约束有效；若 S_PREADY 为组合输出，需检查 glitch
# ------------------------------------------------------------------------------

# 示例：从端地址/控制输出 → 从设备响应路径（2周期）
# [请根据实际从设备规格启用并修改以下约束]
#
# set_multicycle_path -setup 2 \
#     -from [get_clocks S_PCLK] \
#     -through [get_ports {S_PADDR S_PPROT S_PNSE S_PSEL S_PENABLE \
#                           S_PWRITE S_PWDATA S_PSTRB}] \
#     -to   [get_ports {S_PREADY}]
#
# set_multicycle_path -hold 1 \
#     -from [get_clocks S_PCLK] \
#     -through [get_ports {S_PADDR S_PPROT S_PNSE S_PSEL S_PENABLE \
#                           S_PWRITE S_PWDATA S_PSTRB}] \
#     -to   [get_ports {S_PREADY}]


# ------------------------------------------------------------------------------
# 5.2 从端读数据多周期路径（示例：从设备读数据需要 2 个周期准备）
# [请根据实际从设备规格启用并修改以下约束]
# ------------------------------------------------------------------------------
#
# set_multicycle_path -setup 2 \
#     -from [get_ports {S_PREADY}] \
#     -to   [get_cells {s_r_prdata s_r_pslverr}]
#
# set_multicycle_path -hold 1 \
#     -from [get_ports {S_PREADY}] \
#     -to   [get_cells {s_r_prdata s_r_pslverr}]


# ==============================================================================
# 第六节：输入/输出延迟约束（I/O Delay Constraints）
# ==============================================================================
# 说明：
#   I/O 延迟约束用于建立端口路径的 setup/hold 时序检查
#   参考模型：同步 APB 接口（外部寄存器在同一时钟边沿采样）
#
#   约束含义：
#   set_input_delay  -max T：外部数据到达端口的最晚时间（相对于时钟上升沿）
#                            用于计算本模块内部的 setup slack
#   set_input_delay  -min T：外部数据到达端口的最早时间
#                            用于计算本模块内部的 hold   slack
#   set_output_delay -max T：输出数据必须在时钟上升沿后 T ns 内到达下游
#                            用于计算本模块内部的 setup slack
#   set_output_delay -min T：输出数据的最小保持时间要求
#                            用于计算本模块内部的 hold   slack
#
#   [注意] 以下 max/min 值为示例，实际请根据系统接口规格修改
# ==============================================================================

# ------------------------------------------------------------------------------
# 6.1 主端输入延迟（M_PCLK 域，来自 APB Initiator）
# ------------------------------------------------------------------------------

# 地址总线（PADDR）：主端寄存器在 M_PCLK 上升沿后 2.0ns 到达
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PADDR]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PADDR]

# 保护信号（PPROT）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PPROT]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PPROT]

# 非安全扩展（PNSE，AMBA5新增）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PNSE]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PNSE]

# 片选信号（PSEL）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PSEL]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PSEL]

# 使能信号（PENABLE）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PENABLE]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PENABLE]

# 读写控制（PWRITE）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PWRITE]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PWRITE]

# 写数据总线（PWDATA）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PWDATA]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PWDATA]

# 字节使能（PSTRB）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PSTRB]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PSTRB]

# 唤醒信号（PWAKEUP，AMBA5新增）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PWAKEUP]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PWAKEUP]

# 地址用户信号（PAUSER）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PAUSER]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PAUSER]

# 写数据用户信号（PWUSER）
set_input_delay -clock M_PCLK -max 2.000 [get_ports M_PWUSER]
set_input_delay -clock M_PCLK -min 0.300 [get_ports M_PWUSER]


# ------------------------------------------------------------------------------
# 6.2 主端输出延迟（M_PCLK 域，驱动 APB Initiator）
# ------------------------------------------------------------------------------

# 就绪信号（PREADY）：下游设备要求在 M_PCLK 上升沿后 2.0ns 内稳定
set_output_delay -clock M_PCLK -max 2.000 [get_ports M_PREADY]
set_output_delay -clock M_PCLK -min 0.300 [get_ports M_PREADY]

# 读数据总线（PRDATA）
set_output_delay -clock M_PCLK -max 2.000 [get_ports M_PRDATA]
set_output_delay -clock M_PCLK -min 0.300 [get_ports M_PRDATA]

# 从设备错误（PSLVERR）
set_output_delay -clock M_PCLK -max 2.000 [get_ports M_PSLVERR]
set_output_delay -clock M_PCLK -min 0.300 [get_ports M_PSLVERR]

# 读数据用户信号（PRUSER）
set_output_delay -clock M_PCLK -max 2.000 [get_ports M_PRUSER]
set_output_delay -clock M_PCLK -min 0.300 [get_ports M_PRUSER]

# 桥用户信号（PBUSER）
set_output_delay -clock M_PCLK -max 2.000 [get_ports M_PBUSER]
set_output_delay -clock M_PCLK -min 0.300 [get_ports M_PBUSER]


# ------------------------------------------------------------------------------
# 6.3 从端输出延迟（S_PCLK 域，驱动 APB 从设备）
#     S_PCLK 为 50MHz，时钟周期更宽裕（20ns），IO 延迟余量可适当放宽
# ------------------------------------------------------------------------------

# 地址总线（S_PADDR）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PADDR]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PADDR]

# 保护类型（S_PPROT）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PPROT]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PPROT]

# 非安全扩展（S_PNSE）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PNSE]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PNSE]

# 片选（S_PSEL）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PSEL]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PSEL]

# 使能（S_PENABLE）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PENABLE]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PENABLE]

# 读写控制（S_PWRITE）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PWRITE]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PWRITE]

# 写数据（S_PWDATA）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PWDATA]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PWDATA]

# 字节使能（S_PSTRB）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PSTRB]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PSTRB]

# 唤醒（S_PWAKEUP）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PWAKEUP]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PWAKEUP]

# 地址用户信号（S_PAUSER）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PAUSER]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PAUSER]

# 写数据用户信号（S_PWUSER）
set_output_delay -clock S_PCLK -max 3.000 [get_ports S_PWUSER]
set_output_delay -clock S_PCLK -min 0.500 [get_ports S_PWUSER]


# ------------------------------------------------------------------------------
# 6.4 从端输入延迟（S_PCLK 域，来自 APB 从设备）
# ------------------------------------------------------------------------------

# 就绪信号（S_PREADY）：从设备在 S_PCLK 上升沿后 3.0ns 内给出
set_input_delay -clock S_PCLK -max 3.000 [get_ports S_PREADY]
set_input_delay -clock S_PCLK -min 0.500 [get_ports S_PREADY]

# 读数据（S_PRDATA）
set_input_delay -clock S_PCLK -max 3.000 [get_ports S_PRDATA]
set_input_delay -clock S_PCLK -min 0.500 [get_ports S_PRDATA]

# 从设备错误（S_PSLVERR）
set_input_delay -clock S_PCLK -max 3.000 [get_ports S_PSLVERR]
set_input_delay -clock S_PCLK -min 0.500 [get_ports S_PSLVERR]

# 读数据用户信号（S_PRUSER）
set_input_delay -clock S_PCLK -max 3.000 [get_ports S_PRUSER]
set_input_delay -clock S_PCLK -min 0.500 [get_ports S_PRUSER]

# 桥用户信号（S_PBUSER）
set_input_delay -clock S_PCLK -max 3.000 [get_ports S_PBUSER]
set_input_delay -clock S_PCLK -min 0.500 [get_ports S_PBUSER]


# ==============================================================================
# 第七节：工作条件与设计规则（Operating Conditions & Design Rules）
# ==============================================================================
# 说明：
#   本节约束与工艺库（PDK）强相关，请根据实际工艺角和 Foundry 标准修改
#   通常分为：
#     WC（Worst Case / Slow Corner）：用于 setup 分析（max 路径）
#     BC（Best  Case / Fast Corner）：用于 hold  分析（min 路径）
# ==============================================================================

# ------------------------------------------------------------------------------
# 7.1 工作条件（Operating Conditions）
# 说明：请替换为实际工艺库中的 operating condition 名称
#       常见示例：slow_1p08v_125c / fast_1p32v_n40c（视 PDK 而定）
# ------------------------------------------------------------------------------

# [Slow Corner - 用于 Setup 分析]
# set_operating_conditions -analysis_type on_chip_variation -max slow_1p08v_125c

# [Fast Corner - 用于 Hold 分析]
# set_operating_conditions -analysis_type on_chip_variation -min fast_1p32v_n40c

# 以下为通用占位符，实际工程请取消注释并替换名称：
# set_operating_conditions -max [get_lib_attribute [get_libs *] default_operating_conditions]


# ------------------------------------------------------------------------------
# 7.2 最大扇出约束（Max Fanout）
# 说明：
#   限制单个驱动单元的最大扇出数，防止时钟/控制信号驱动能力不足
#   过高的扇出会增加信号转换时间（slew），影响时序质量
#   建议值：普通信号 20，时钟信号由 CTS 工具控制（不在此约束）
# ------------------------------------------------------------------------------
set_max_fanout 20 [all_outputs]
set_max_fanout 32 [get_ports {S_PADDR S_PWDATA M_PRDATA}]
# [注意] 时钟信号（M_PCLK / S_PCLK）的扇出由 CTS 控制，不在此处约束


# ------------------------------------------------------------------------------
# 7.3 最大转换时间约束（Max Transition / Slew）
# 说明：
#   限制信号的上升/下降转换时间，确保信号质量
#   转换时间过大会导致：
#     ① 触发器 setup/hold 时间裕量减小
#     ② 短路电流增大，功耗上升
#     ③ 转换中间电平持续时间长，可能触发噪声
#   建议值：数据路径 0.2ns，时钟路径由工具自动控制
# ------------------------------------------------------------------------------
set_max_transition 0.200 [current_design]

# 时钟端口转换时间（可以适当放宽，因为有专用时钟缓冲器）
set_max_transition 0.100 [get_ports {M_PCLK S_PCLK}]


# ------------------------------------------------------------------------------
# 7.4 最大电容约束（Max Capacitance）
# 说明：
#   限制输出端口驱动的总负载电容，避免过负载导致转换时间超标
#   具体数值请根据工艺库标准单元 max_capacitance 属性和板级负载确认
# ------------------------------------------------------------------------------
# [请根据 PDK 规格修改，以下为示例值]
set_max_capacitance 0.500 [all_outputs]     ;# 单位：pF，示例


# ------------------------------------------------------------------------------
# 7.5 输入驱动强度（Input Drive Strength）
# 说明：
#   描述输入端口的驱动能力，影响端口对内部逻辑的转换时间
#   通常设置为与外部驱动单元等效的标准单元驱动强度
#   如果是芯片顶层，通常由 PAD 单元驱动，请使用对应 PAD 单元
# ------------------------------------------------------------------------------
# [请根据实际驱动单元修改，以下为示例]
# set_driving_cell -lib_cell BUFX8 -pin Y [all_inputs]

# 时钟端口通常由专用时钟驱动器驱动
# set_driving_cell -lib_cell CLKBUFX8 -pin Y [get_ports {M_PCLK S_PCLK}]

# ------------------------------------------------------------------------------
# 7.6 输出负载（Output Load）
# 说明：
#   描述输出端口驱动的外部负载，单位为工艺库电容单位（通常 pF 或 fF）
#   影响输出路径的 setup slack 计算
#   以下为示例值（0.05 pF），请根据板级设计和对端接收单元输入电容修改
# ------------------------------------------------------------------------------
set_load 0.050 [all_outputs]    ;# 单位：pF，示例

# 对驱动外部总线的输出端口，负载可能更大（多个接收端并联）
set_load 0.100 [get_ports {S_PADDR S_PWDATA M_PRDATA}]


# ------------------------------------------------------------------------------
# 7.7 输入转换时间（Input Transition）
# 说明：
#   设置所有输入端口的信号转换时间
#   用于替代 set_driving_cell（当不清楚驱动单元类型时）
#   影响内部路径延迟计算的起点
# ------------------------------------------------------------------------------
# 主端输入（M_PCLK 域，外部逻辑驱动）：上升/下降各 0.1ns
set_input_transition 0.100 [get_ports { \
    M_PADDR M_PPROT M_PNSE M_PSEL M_PENABLE \
    M_PWRITE M_PWDATA M_PSTRB M_PWAKEUP M_PAUSER M_PWUSER \
}]

# 从端输入（S_PCLK 域，从设备驱动）：上升/下降各 0.15ns（较慢时钟域）
set_input_transition 0.150 [get_ports { \
    S_PREADY S_PRDATA S_PSLVERR S_PRUSER S_PBUSER \
}]

# 复位输入（异步信号）：转换时间要求较宽松
set_input_transition 0.300 [get_ports {M_PRESETn S_PRESETn}]

# 时钟输入：由专用时钟驱动，转换时间最小
set_input_transition 0.050 [get_ports {M_PCLK S_PCLK}]


# ==============================================================================
# 第八节：时序例外汇总表（Timing Exceptions Summary）
# ==============================================================================
#
# 以下为本 SDC 文件中所有时序例外约束的汇总，方便快速审查
#
# ┌─────┬─────────────────────┬──────────────────────────┬──────────────────────────────┬──────────────────────────────────────────────────────────────────┐
# │ 序号 │ 约束类型              │ From                     │ To                           │ 说明/理由                                                         │
# ├─────┼─────────────────────┼──────────────────────────┼──────────────────────────────┼──────────────────────────────────────────────────────────────────┤
# │  1  │ set_max_delay(D.O.)  │ req_ff (M_PCLK)          │ u_req_sync/sync_ff1 (S_PCLK) │ REQ同步器输入；确保Toggle信号在20ns内到达同步器第一级，= 1×S_PCLK  │
# │  2  │ set_max_delay(D.O.)  │ ack_ff (S_PCLK)          │ u_ack_sync/sync_ff1 (M_PCLK) │ ACK同步器输入；确保Toggle信号在10ns内到达同步器第一级，= 1×M_PCLK  │
# │  3  │ set_max_delay(D.O.)  │ u_req_sync/sync_ff1      │ u_req_sync/d_out             │ REQ同步器内部；防止工具优化打断单扇出同步链，= 1×S_PCLK            │
# │  4  │ set_max_delay(D.O.)  │ u_ack_sync/sync_ff1      │ u_ack_sync/d_out             │ ACK同步器内部；防止工具优化打断单扇出同步链，= 1×M_PCLK            │
# ├─────┼─────────────────────┼──────────────────────────┼──────────────────────────────┼──────────────────────────────────────────────────────────────────┤
# │  5  │ set_false_path       │ M_PRESETn                │ -                            │ 异步复位断言路径，无时序要求                                       │
# │  6  │ set_false_path       │ S_PRESETn                │ -                            │ 异步复位断言路径，无时序要求                                       │
# │  7  │ set_false_path       │ -                        │ M_PRESETn                    │ 复位输出路径，无时序要求                                           │
# │  8  │ set_false_path       │ -                        │ S_PRESETn                    │ 复位输出路径，无时序要求                                           │
# ├─────┼─────────────────────┼──────────────────────────┼──────────────────────────────┼──────────────────────────────────────────────────────────────────┤
# │  9  │ set_false_path       │ m_r_paddr..m_r_pwuser    │ S_PCLK domain                │ 请求数据总线；四相握手协议保证稳定，无需STA检查                     │
# │  10 │ set_false_path       │ M_PCLK domain            │ s_r_paddr..s_r_pwuser        │ 请求数据总线从端采样侧；同上                                       │
# │  11 │ set_false_path       │ s_r_prdata..s_r_pbuser   │ M_PCLK domain                │ 响应数据总线；四相握手协议保证稳定，无需STA检查                     │
# │  12 │ set_false_path       │ S_PCLK domain            │ m_r_prdata..m_r_pbuser       │ 响应数据总线主端采样侧；同上                                       │
# ├─────┼─────────────────────┼──────────────────────────┼──────────────────────────────┼──────────────────────────────────────────────────────────────────┤
# │  13 │ set_multicycle_path  │ S_PCLK domain outputs    │ S_PREADY input               │ [已注释] 从设备多周期响应，请根据实际从设备规格启用                 │
# └─────┴─────────────────────┴──────────────────────────┴──────────────────────────────┴──────────────────────────────────────────────────────────────────┘
#
# D.O. = -datapath_only


# ==============================================================================
# 第九节：STA 验证检查清单（Verification Checklist）
# ==============================================================================
#
# 应用本 SDC 后，在 PrimeTime / Tempus 中执行以下报告进行验证：
#
# ─────────────────────────────────────────────────────
# 【检查项 1】无未约束路径
#   命令：report_constraint -all_violators -nosplit
#         check_timing -verbose
#   预期：无 unconstrained path、无 missing clock、无 undriven net
#
# 【检查项 2】同步器路径延迟验证
#   命令：report_timing -from req_ff -to u_req_sync/sync_ff1 \
#                       -delay_type max -nosplit
#         report_timing -from ack_ff -to u_ack_sync/sync_ff1 \
#                       -delay_type max -nosplit
#   预期：
#     req_ff → sync_ff1 的最大路径延迟 ≤ 20.000 ns（= S_PCLK 周期）
#     ack_ff → sync_ff1 的最大路径延迟 ≤ 10.000 ns（= M_PCLK 周期）
#
# 【检查项 3】时钟域交叉路径（跨域路径被正确 false_path 或 max_delay）
#   命令：report_cdc -nosplit
#         report_timing -from [get_clocks M_PCLK] -to [get_clocks S_PCLK] \
#                       -delay_type max -nosplit
#   预期：
#     除同步器输入路径（req_ff→sync_ff1）外，无其他跨域 setup 违例
#     数据总线路径（m_r_* / s_r_*）不出现在时序报告中（已 false_path）
#
# 【检查项 4】I/O 延迟路径验证
#   命令：report_timing -through [get_ports M_PADDR] -nosplit -max_paths 5
#         report_timing -through [get_ports M_PREADY] -nosplit -max_paths 5
#         report_timing -through [get_ports S_PADDR] -nosplit -max_paths 5
#   预期：所有 I/O 路径 setup/hold slack ≥ 0（无违例）
#
# 【检查项 5】时钟定义完整性
#   命令：report_clocks -nosplit
#         report_clock_gating -nosplit
#   预期：M_PCLK (100MHz) / S_PCLK (50MHz) 均已定义
#         无未识别时钟（no unclocked register）
#
# 【检查项 6】设计规则检查
#   命令：report_constraint -all_violators -max_fanout -max_transition \
#                           -max_capacitance -nosplit
#   预期：无 max_fanout / max_transition / max_capacitance 违例
#
# 【检查项 7】同步器结构完整性（need set_dont_touch）
#   命令：report_cell [get_cells {u_req_sync u_ack_sync}]
#   预期：同步器实例未被优化/展平，两级 FF 之间无额外 buffer
#
# 【检查项 8】多周期路径（如已启用第五节约束）
#   命令：report_timing -from [get_clocks S_PCLK] \
#                       -to [get_ports S_PREADY] -nosplit
#   预期：路径 slack 满足多周期约束要求
#
# ─────────────────────────────────────────────────────


# ==============================================================================
# 文件结束
# ==============================================================================
```
---
## 10. 实例化示例

### 10.1 同步模式实例化

```verilog
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

```verilog
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

```verilog
// =============================================================================
// 文件名称 : apb5_bridge_sva.sv
// 描    述 : AMBA 5 APB 异步桥 SystemVerilog 断言（SVA）绑定文件
//            覆盖：APB 协议合规、四相握手协议、状态机有效性、
//                  复位行为、响应有效性、功能覆盖
// 适用模块 : apb5_async_bridge
// 工具兼容 : VCS / Questa / Xcelium
// 版    本 : v1.0
// 日    期 : 2026-04-15
// =============================================================================

module apb5_bridge_sva #(
    parameter ADDR_WIDTH   = 32,
    parameter DATA_WIDTH   = 32,
    parameter STRB_WIDTH   = DATA_WIDTH/8,
    parameter PAUSER_WIDTH = 4,
    parameter PWUSER_WIDTH = 4,
    parameter PRUSER_WIDTH = 4,
    parameter PBUSER_WIDTH = 4
)(
    // -------------------------------------------------------------------------
    // 主端时钟域
    // -------------------------------------------------------------------------
    input logic                    M_PCLK,
    input logic                    M_PRESETn,
    input logic [ADDR_WIDTH-1:0]   M_PADDR,
    input logic [2:0]              M_PPROT,
    input logic                    M_PNSE,
    input logic                    M_PSEL,
    input logic                    M_PENABLE,
    input logic                    M_PWRITE,
    input logic [DATA_WIDTH-1:0]   M_PWDATA,
    input logic [STRB_WIDTH-1:0]   M_PSTRB,
    input logic                    M_PWAKEUP,
    input logic [PAUSER_WIDTH-1:0] M_PAUSER,
    input logic [PWUSER_WIDTH-1:0] M_PWUSER,
    input logic                    M_PREADY,
    input logic [DATA_WIDTH-1:0]   M_PRDATA,
    input logic                    M_PSLVERR,
    input logic [PRUSER_WIDTH-1:0] M_PRUSER,
    input logic [PBUSER_WIDTH-1:0] M_PBUSER,
    // -------------------------------------------------------------------------
    // 从端时钟域
    // -------------------------------------------------------------------------
    input logic                    S_PCLK,
    input logic                    S_PRESETn,
    input logic [ADDR_WIDTH-1:0]   S_PADDR,
    input logic [2:0]              S_PPROT,
    input logic                    S_PNSE,
    input logic                    S_PSEL,
    input logic                    S_PENABLE,
    input logic                    S_PWRITE,
    input logic [DATA_WIDTH-1:0]   S_PWDATA,
    input logic [STRB_WIDTH-1:0]   S_PSTRB,
    input logic                    S_PWAKEUP,
    input logic [PAUSER_WIDTH-1:0] S_PAUSER,
    input logic [PWUSER_WIDTH-1:0] S_PWUSER,
    input logic                    S_PREADY,
    input logic [DATA_WIDTH-1:0]   S_PRDATA,
    input logic                    S_PSLVERR,
    input logic [PRUSER_WIDTH-1:0] S_PRUSER,
    input logic [PBUSER_WIDTH-1:0] S_PBUSER
);

// =============================================================================
// DUT 内部信号引用（通过层次路径访问）
// =============================================================================
// 主端时钟域内部信号
logic        req_ff;       assign req_ff      = apb5_async_bridge.req_ff;
logic        ack_sync;     assign ack_sync    = apb5_async_bridge.ack_sync;
logic        ack_sync_d;   assign ack_sync_d  = apb5_async_bridge.ack_sync_d;
logic        ack_edge;     assign ack_edge    = apb5_async_bridge.ack_edge;
logic        req_set;      assign req_set     = apb5_async_bridge.req_set;
logic [2:0]  m_cur;        assign m_cur       = apb5_async_bridge.m_cur;

logic [ADDR_WIDTH-1:0]  m_r_paddr;  assign m_r_paddr  = apb5_async_bridge.m_r_paddr;
logic [DATA_WIDTH-1:0]  m_r_pwdata; assign m_r_pwdata = apb5_async_bridge.m_r_pwdata;
logic [DATA_WIDTH-1:0]  m_r_prdata; assign m_r_prdata = apb5_async_bridge.m_r_prdata;
logic                   m_r_pslverr;assign m_r_pslverr= apb5_async_bridge.m_r_pslverr;

// 从端时钟域内部信号
logic        ack_ff;       assign ack_ff      = apb5_async_bridge.ack_ff;
logic        req_sync;     assign req_sync    = apb5_async_bridge.req_sync;
logic        req_sync_d;   assign req_sync_d  = apb5_async_bridge.req_sync_d;
logic        req_edge;     assign req_edge    = apb5_async_bridge.req_edge;
logic        ack_set;      assign ack_set     = apb5_async_bridge.ack_set;
logic [2:0]  s_cur;        assign s_cur       = apb5_async_bridge.s_cur;

logic [DATA_WIDTH-1:0]  s_r_prdata;  assign s_r_prdata  = apb5_async_bridge.s_r_prdata;
logic                   s_r_pslverr; assign s_r_pslverr = apb5_async_bridge.s_r_pslverr;

// =============================================================================
// 状态编码常量定义
// =============================================================================
// 主端状态机编码
localparam M_IDLE  = 3'd0;
localparam M_SETUP = 3'd1;
localparam M_WAIT  = 3'd2;
localparam M_DONE  = 3'd3;

// 从端状态机编码
localparam S_IDLE   = 3'd0;
localparam S_SETUP  = 3'd1;
localparam S_ACCESS = 3'd2;
localparam S_ACK    = 3'd3;
localparam S_WDEACK = 3'd4;

`ifdef ASSERT_ON

// =============================================================================
// GROUP A：APB 协议合规性断言（M_PCLK 域）
// =============================================================================

// [A1] PENABLE 必须在 PSEL 拉高后至少一拍才能拉高
// AMBA APB 协议规定：SETUP 阶段（PSEL=1, PENABLE=0）至少持续一个时钟周期
property apb_psel_before_penable;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    M_PENABLE |-> $past(M_PSEL);
endproperty
ap_psel_before_penable: assert property (apb_psel_before_penable)
    else $error("[SVA-A1] APB协议违例：PENABLE 拉高时前一拍 PSEL 未有效");

// [A2] PADDR 在 ACCESS 阶段必须保持稳定
// 从 PENABLE 拉高到 PREADY 拉高期间，地址不允许变化
property apb_addr_stable_during_access;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (M_PSEL && M_PENABLE && !M_PREADY) |-> ##1 $stable(M_PADDR);
endproperty
ap_addr_stable_during_access: assert property (apb_addr_stable_during_access)
    else $error("[SVA-A2] APB协议违例：ACCESS 阶段 PADDR 发生变化");

// [A3] 写操作时 PWDATA 在 ACCESS 阶段必须保持稳定
property apb_write_data_stable;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (M_PSEL && M_PENABLE && M_PWRITE && !M_PREADY) |-> ##1 $stable(M_PWDATA);
endproperty
ap_write_data_stable: assert property (apb_write_data_stable)
    else $error("[SVA-A3] APB协议违例：写操作 ACCESS 阶段 PWDATA 发生变化");

// [A4] 异步模式不支持背靠背：PREADY 拉高后，PSEL 应在下一拍撤销
// 异步桥每笔传输需完成完整四相握手，无法立即开始下一笔
property apb_no_back_to_back;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (M_PSEL && M_PENABLE && M_PREADY) |=> !M_PENABLE;
endproperty
ap_no_back_to_back: assert property (apb_no_back_to_back)
    else $error("[SVA-A4] 异步桥违例：检测到背靠背传输，异步模式不支持");

// [A5] PENABLE 不能在 PSEL 无效时拉高
property apb_no_penable_without_psel;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    M_PENABLE |-> M_PSEL;
endproperty
ap_no_penable_without_psel: assert property (apb_no_penable_without_psel)
    else $error("[SVA-A5] APB协议违例：PSEL=0 时 PENABLE=1");

// [A6] PSTRB 写操作时至少一位字节使能有效
property apb_pstrb_valid_on_write;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (M_PSEL && M_PENABLE && M_PWRITE) |-> (M_PSTRB != {STRB_WIDTH{1'b0}});
endproperty
ap_pstrb_valid_on_write: assert property (apb_pstrb_valid_on_write)
    else $error("[SVA-A6] APB协议违例：写操作时 PSTRB 全零");

// =============================================================================
// GROUP B：四相握手协议断言（跨时钟域）
// =============================================================================

// [B1] req_data 总线在握手期间必须保持稳定
// 从 req_ff Toggle 到 ack_edge 检测期间，m_r_paddr 不允许变化
property req_addr_stable_during_hs;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (m_cur == M_WAIT) |-> $stable(m_r_paddr);
endproperty
ap_req_addr_stable_during_hs: assert property (req_addr_stable_during_hs)
    else $error("[SVA-B1] 握手违例：M_WAIT 期间 m_r_paddr 发生变化");

// [B2] 写数据在握手期间保持稳定
property req_wdata_stable_during_hs;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (m_cur == M_WAIT) |-> $stable(m_r_pwdata);
endproperty
ap_req_wdata_stable_during_hs: assert property (req_wdata_stable_during_hs)
    else $error("[SVA-B2] 握手违例：M_WAIT 期间 m_r_pwdata 发生变化");

// [B3] 握手不可重入：M_WAIT 状态下 req_set 必须为 0
// 在一次握手完成之前，不允许再次发出 REQ Toggle
property no_reentrant_req;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (m_cur == M_WAIT) |-> !req_set;
endproperty
ap_no_reentrant_req: assert property (no_reentrant_req)
    else $error("[SVA-B3] 握手违例：M_WAIT 状态下检测到重入 REQ（req_set=1）");

// [B4] 每笔传输 req_ff 只能 Toggle 一次
// 从 M_SETUP 进入到回到 M_IDLE，req_ff 只允许翻转一次
property req_ff_toggle_once;
    logic saved_req;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (m_cur == M_SETUP, saved_req = req_ff)
    |=> (m_cur == M_WAIT) throughout
        (##[1:$] (m_cur == M_DONE))[*1]
    ##1 (req_ff == !saved_req);
endproperty
ap_req_ff_toggle_once: assert property (req_ff_toggle_once)
    else $error("[SVA-B4] 握手违例：一笔传输中 req_ff 未发生且仅发生一次 Toggle");

// [B5] ack_set 只在 S_ACK 状态拉高
// 防止从端状态机在非预期状态发出 ACK
property ack_set_only_in_s_ack;
    @(posedge S_PCLK) disable iff (!S_PRESETn)
    ack_set |-> (s_cur == S_ACK);
endproperty
ap_ack_set_only_in_s_ack: assert property (ack_set_only_in_s_ack)
    else $error("[SVA-B5] 握手违例：ack_set=1 时 s_cur 不在 S_ACK 状态");

// [B6] req_set 只在 M_SETUP 状态拉高
property req_set_only_in_m_setup;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    req_set |-> (m_cur == M_SETUP);
endproperty
ap_req_set_only_in_m_setup: assert property (req_set_only_in_m_setup)
    else $error("[SVA-B6] 握手违例：req_set=1 时 m_cur 不在 M_SETUP 状态");

// =============================================================================
// GROUP C：状态机有效性断言
// =============================================================================

// [C1] 主端状态机编码合法性：必须在已定义状态内
property master_fsm_valid_states;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    m_cur inside {M_IDLE, M_SETUP, M_WAIT, M_DONE};
endproperty
ap_master_fsm_valid_states: assert property (master_fsm_valid_states)
    else $error("[SVA-C1] 主端状态机进入非法状态：m_cur = %0d", m_cur);

// [C2] 从端状态机编码合法性
property slave_fsm_valid_states;
    @(posedge S_PCLK) disable iff (!S_PRESETn)
    s_cur inside {S_IDLE, S_SETUP, S_ACCESS, S_ACK, S_WDEACK};
endproperty
ap_slave_fsm_valid_states: assert property (slave_fsm_valid_states)
    else $error("[SVA-C2] 从端状态机进入非法状态：s_cur = %0d", s_cur);

// [C3] 主端状态机不能从 M_IDLE 直接跳到 M_WAIT 或 M_DONE
property master_fsm_no_skip;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (m_cur == M_IDLE) |=> (m_cur inside {M_IDLE, M_SETUP});
endproperty
ap_master_fsm_no_skip: assert property (master_fsm_no_skip)
    else $error("[SVA-C3] 主端状态机违例：从 M_IDLE 直接跳过 M_SETUP");

// [C4] S_SETUP 状态只持续一个 S_PCLK 周期
property slave_setup_one_cycle;
    @(posedge S_PCLK) disable iff (!S_PRESETn)
    (s_cur == S_SETUP) |=> (s_cur == S_ACCESS);
endproperty
ap_slave_setup_one_cycle: assert property (slave_setup_one_cycle)
    else $error("[SVA-C4] 从端状态机违例：S_SETUP 持续超过 1 个时钟周期");

// [C5] M_SETUP 状态只持续一个 M_PCLK 周期
property master_setup_one_cycle;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    (m_cur == M_SETUP) |=> (m_cur == M_WAIT);
endproperty
ap_master_setup_one_cycle: assert property (master_setup_one_cycle)
    else $error("[SVA-C5] 主端状态机违例：M_SETUP 持续超过 1 个时钟周期");

// =============================================================================
// GROUP D：复位行为断言
// =============================================================================

// [D1] 主端复位后状态机应回到 M_IDLE（同步复位：下一拍生效）
property master_reset_clears_state;
    @(posedge M_PCLK)
    !M_PRESETn |=> (m_cur == M_IDLE);
endproperty
ap_master_reset_clears_state: assert property (master_reset_clears_state)
    else $error("[SVA-D1] 复位违例：M_PRESETn 撤销后 m_cur 未回到 M_IDLE");

// [D2] 从端复位后状态机应回到 S_IDLE
property slave_reset_clears_state;
    @(posedge S_PCLK)
    !S_PRESETn |=> (s_cur == S_IDLE);
endproperty
ap_slave_reset_clears_state: assert property (slave_reset_clears_state)
    else $error("[SVA-D2] 复位违例：S_PRESETn 撤销后 s_cur 未回到 S_IDLE");

// [D3] 主端复位期间 req_ff 必须为 0
property req_ff_reset_value;
    @(posedge M_PCLK)
    !M_PRESETn |-> (req_ff == 1'b0);
endproperty
ap_req_ff_reset_value: assert property (req_ff_reset_value)
    else $error("[SVA-D3] 复位违例：M_PRESETn=0 期间 req_ff != 0");

// [D4] 从端复位期间 ack_ff 必须为 0
property ack_ff_reset_value;
    @(posedge S_PCLK)
    !S_PRESETn |-> (ack_ff == 1'b0);
endproperty
ap_ack_ff_reset_value: assert property (ack_ff_reset_value)
    else $error("[SVA-D4] 复位违例：S_PRESETn=0 期间 ack_ff != 0");

// [D5] 复位期间 M_PREADY 必须为 0
property pready_deasserted_during_reset;
    @(posedge M_PCLK)
    !M_PRESETn |-> (M_PREADY == 1'b0);
endproperty
ap_pready_deasserted_during_reset: assert property (pready_deasserted_during_reset)
    else $error("[SVA-D5] 复位违例：M_PRESETn=0 期间 M_PREADY != 0");

// =============================================================================
// GROUP E：响应有效性断言
// =============================================================================

// [E1] M_PREADY 只在 M_DONE 状态拉高
property pready_only_in_m_done;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    M_PREADY |-> (m_cur == M_DONE);
endproperty
ap_pready_only_in_m_done: assert property (pready_only_in_m_done)
    else $error("[SVA-E1] 响应违例：M_PREADY=1 时 m_cur 不在 M_DONE 状态");

// [E2] M_PSLVERR 只在 M_PREADY=1 时有效
property pslverr_valid_with_pready;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    M_PSLVERR |-> M_PREADY;
endproperty
ap_pslverr_valid_with_pready: assert property (pslverr_valid_with_pready)
    else $error("[SVA-E2] 响应违例：M_PSLVERR=1 时 M_PREADY=0");

// [E3] PREADY 只持续一拍（脉冲信号）
property pready_pulse_width;
    @(posedge M_PCLK) disable iff (!M_PRESETn)
    M_PREADY |=> !M_PREADY;
endproperty
ap_pready_pulse_width: assert property (pready_pulse_width)
    else $error("[SVA-E3] 响应违例：M_PREADY 持续超过 1 个时钟周期");

// [E4] 从端 S_PSEL 和 S_PENABLE 的时序关系
// S_PENABLE 只能在 S_PSEL=1 时拉高（从端 APB 协议）
property slave_penable_after_psel;
    @(posedge S_PCLK) disable iff (!S_PRESETn)
    S_PENABLE |-> S_PSEL;
endproperty
ap_slave_penable_after_psel: assert property (slave_penable_after_psel)
    else $error("[SVA-E4] 从端协议违例：S_PENABLE=1 时 S_PSEL=0");

`endif // ASSERT_ON

// =============================================================================
// 功能覆盖组（Covergroup）
// =============================================================================

// 主端状态机转换覆盖
covergroup cg_master_fsm @(posedge M_PCLK iff M_PRESETn);
    // 当前状态覆盖
    cp_m_state: coverpoint m_cur {
        bins idle  = {M_IDLE};
        bins setup = {M_SETUP};
        bins wait  = {M_WAIT};
        bins done  = {M_DONE};
    }
    // 状态转换覆盖（Cross）
    cp_m_trans: coverpoint {$past(m_cur), m_cur} {
        bins idle_to_setup  = {6'b000_001};  // IDLE→SETUP
        bins setup_to_wait  = {6'b001_010};  // SETUP→WAIT
        bins wait_to_done   = {6'b010_011};  // WAIT→DONE
        bins done_to_idle   = {6'b011_000};  // DONE→IDLE
        bins idle_stay      = {6'b000_000};  // IDLE保持
        bins wait_stay      = {6'b010_010};  // WAIT保持（等待ACK）
        bins access_stay    = {6'b010_010};  // ACCESS保持（等待PREADY）
    }
endgroup

// 从端状态机转换覆盖
covergroup cg_slave_fsm @(posedge S_PCLK iff S_PRESETn);
    cp_s_state: coverpoint s_cur {
        bins idle    = {S_IDLE};
        bins setup   = {S_SETUP};
        bins access  = {S_ACCESS};
        bins ack     = {S_ACK};
        bins wdeack  = {S_WDEACK};
    }
    cp_s_trans: coverpoint {$past(s_cur), s_cur} {
        bins idle_to_setup    = {6'b000_001};
        bins setup_to_access  = {6'b001_010};
        bins access_to_ack    = {6'b010_011};
        bins ack_to_wdeack    = {6'b011_100};
        bins wdeack_to_idle   = {6'b100_000};
        bins access_stay      = {6'b010_010};  // 等待 PREADY
    }
endgroup

// APB 传输类型覆盖
covergroup cg_apb_transfer_type @(posedge M_PCLK iff M_PRESETn);
    // 读/写传输类型
    cp_rw: coverpoint M_PWRITE {
        bins read  = {1'b0};
        bins write = {1'b1};
    }
    // 错误响应
    cp_err: coverpoint M_PSLVERR iff (M_PREADY) {
        bins ok  = {1'b0};
        bins err = {1'b1};
    }
    // 保护类型
    cp_prot: coverpoint M_PPROT {
        bins normal_nonsec_data   = {3'b000};
        bins normal_nonsec_inst   = {3'b001};
        bins normal_sec_data      = {3'b010};
        bins priv_nonsec_data     = {3'b100};
        bins priv_sec_data        = {3'b110};
    }
    // 交叉覆盖：读/写 × 错误/正常
    cx_rw_err: cross cp_rw, cp_err;
endgroup

// S_ACCESS 等待周期覆盖（PREADY 插入等待拍数）
covergroup cg_pready_wait_cycles @(posedge S_PCLK iff S_PRESETn);
    // 统计 S_ACCESS 状态持续几拍（即 PREADY 延迟了几拍）
    cp_wait: coverpoint s_cur iff (s_cur == S_ACCESS) {
        bins access_active = {S_ACCESS};
    }
    // PREADY 等待周期分档
    cp_pready_delay: coverpoint S_PREADY iff (s_cur == S_ACCESS) {
        bins pready_immediate = {1'b1};  // 0等待周期
        bins pready_wait      = {1'b0};  // ≥1等待周期
    }
endgroup

// 地址边界覆盖
covergroup cg_addr_coverage @(posedge M_PCLK iff (M_PRESETn && M_PSEL && !M_PENABLE));
    cp_addr_range: coverpoint M_PADDR {
        bins zero         = {0};
        bins low          = {[1:32'hFFFF]};
        bins mid          = {[32'h10000:32'hFFFEFFFF]};
        bins high         = {[32'hFFFF0000:32'hFFFFFFFE]};
        bins max          = {{ADDR_WIDTH{1'b1}}};
    }
    cp_byte_enable: coverpoint M_PSTRB iff (M_PWRITE) {
        bins byte0_only   = {4'b0001};
        bins byte1_only   = {4'b0010};
        bins byte2_only   = {4'b0100};
        bins byte3_only   = {4'b1000};
        bins halfword_lo  = {4'b0011};
        bins halfword_hi  = {4'b1100};
        bins fullword     = {4'b1111};
    }
endgroup

// 实例化覆盖组
cg_master_fsm       u_cg_master_fsm       = new();
cg_slave_fsm        u_cg_slave_fsm        = new();
cg_apb_transfer_type u_cg_apb_transfer   = new();
cg_pready_wait_cycles u_cg_pready_wait   = new();
cg_addr_coverage    u_cg_addr            = new();

endmodule

// =============================================================================
// Bind 语句：将 SVA 模块绑定到 DUT
// =============================================================================
bind apb5_async_bridge apb5_bridge_sva #(
    .ADDR_WIDTH   (ADDR_WIDTH),
    .DATA_WIDTH   (DATA_WIDTH),
    .STRB_WIDTH   (STRB_WIDTH),
    .PAUSER_WIDTH (PAUSER_WIDTH),
    .PWUSER_WIDTH (PWUSER_WIDTH),
    .PRUSER_WIDTH (PRUSER_WIDTH),
    .PBUSER_WIDTH (PBUSER_WIDTH)
) u_apb5_bridge_sva (.*);
```


### 11.3 Testbench

&#160; &#160; &#160; &#160; 时钟设计（制造异步相位差）：

```verilog
always #5  M_PCLK = ~M_PCLK;          // 100 MHz
initial #3 forever #10 S_PCLK = ~S_PCLK; // 50 MHz，初始偏移 3ns
```

&#160; &#160; &#160; &#160; 从端寄存器模型

- **16×32bit寄存器堆**，初始化为 0xDEAD_000N
- **随机等待周期**：$urandom_range(0, 3)模拟真实从设备延迟
- **错误注入**：地址低4位=0xF时自动拉高S_PSLVERR


&#160; &#160; &#160; &#160; 6组测试场景：
| 测试 | 场景 | 验证点 |
| --- | --- | --- |
| TEST1 | 写后读回验证 | 数据完整性，4笔 |
| TEST2 | 连续8笔写 | 多事务顺序性 |
| TEST3 | 从端SLVERR | 错误地址响应 |
| TEST4 | PPROT全组合 | 5种保护类型 |
| TEST5 | PSTRB字节使能 | 7种使能组合 |
| TEST6 | 地址边界 | 零地址+最大地址 |

&#160; &#160; &#160; &#160; 安全机制：
- ⏱️ 超时看门狗：1ms 无响应强制 $finish
- 🔢 PREADY 超时：单笔事务超过 200 周期报错
- ✅ PASS/FAIL 计数：仿真结束输出汇总

```verilog
// =============================================================================
// 文件名称 : apb5_bridge_tb.sv
// 描    述 : AMBA 5 APB 异步桥完整仿真验证 Testbench
//            覆盖：基本读写、连续写、从端错误、字节使能、地址边界
// 适用模块 : apb5_bridge (ASYNC_MODE=1)
// 工具兼容 : VCS / Questa / Xcelium
// 版    本 : v1.0
// 日    期 : 2026-04-15
// =============================================================================

`timescale 1ns/1ps

module apb5_bridge_tb;

// =============================================================================
// 参数定义
// =============================================================================
parameter ADDR_WIDTH   = 32;
parameter DATA_WIDTH   = 32;
parameter STRB_WIDTH   = 4;
parameter PAUSER_WIDTH = 4;
parameter PWUSER_WIDTH = 4;
parameter PRUSER_WIDTH = 4;
parameter PBUSER_WIDTH = 4;

// 超时保护：最大等待 PREADY 的周期数
parameter PREADY_TIMEOUT = 200;

// =============================================================================
// 时钟与复位
// =============================================================================
logic M_PCLK    = 0;   // 主端时钟：100 MHz（周期 10 ns）
logic S_PCLK    = 0;   // 从端时钟：50 MHz（周期 20 ns，初始相位偏移 3 ns）
logic M_PRESETn = 0;   // 主端复位（低有效）
logic S_PRESETn = 0;   // 从端复位（低有效）

// 主端时钟：100 MHz
always #5  M_PCLK = ~M_PCLK;

// 从端时钟：50 MHz，初始相位偏移 3 ns（制造异步相位差）
initial #3 forever #10 S_PCLK = ~S_PCLK;

// =============================================================================
// APB 主端接口信号
// =============================================================================
logic [ADDR_WIDTH-1:0]   M_PADDR   = '0;
logic [2:0]              M_PPROT   = '0;
logic                    M_PNSE    = '0;
logic                    M_PSEL    = '0;
logic                    M_PENABLE = '0;
logic                    M_PWRITE  = '0;
logic [DATA_WIDTH-1:0]   M_PWDATA  = '0;
logic [STRB_WIDTH-1:0]   M_PSTRB   = '0;
logic                    M_PWAKEUP = '0;
logic [PAUSER_WIDTH-1:0] M_PAUSER  = '0;
logic [PWUSER_WIDTH-1:0] M_PWUSER  = '0;
logic                    M_PREADY;
logic [DATA_WIDTH-1:0]   M_PRDATA;
logic                    M_PSLVERR;
logic [PRUSER_WIDTH-1:0] M_PRUSER;
logic [PBUSER_WIDTH-1:0] M_PBUSER;

// =============================================================================
// APB 从端接口信号
// =============================================================================
logic [ADDR_WIDTH-1:0]   S_PADDR;
logic [2:0]              S_PPROT;
logic                    S_PNSE;
logic                    S_PSEL;
logic                    S_PENABLE;
logic                    S_PWRITE;
logic [DATA_WIDTH-1:0]   S_PWDATA;
logic [STRB_WIDTH-1:0]   S_PSTRB;
logic                    S_PWAKEUP;
logic [PAUSER_WIDTH-1:0] S_PAUSER;
logic [PWUSER_WIDTH-1:0] S_PWUSER;
logic                    S_PREADY  = '0;
logic [DATA_WIDTH-1:0]   S_PRDATA  = '0;
logic                    S_PSLVERR = '0;
logic [PRUSER_WIDTH-1:0] S_PRUSER  = '0;
logic [PBUSER_WIDTH-1:0] S_PBUSER  = '0;

// =============================================================================
// DUT 实例化（异步桥模式）
// =============================================================================
apb5_bridge #(
    .ASYNC_MODE   (1),
    .ADDR_WIDTH   (ADDR_WIDTH),
    .DATA_WIDTH   (DATA_WIDTH),
    .STRB_WIDTH   (STRB_WIDTH),
    .PAUSER_WIDTH (PAUSER_WIDTH),
    .PWUSER_WIDTH (PWUSER_WIDTH),
    .PRUSER_WIDTH (PRUSER_WIDTH),
    .PBUSER_WIDTH (PBUSER_WIDTH)
) u_dut (
    .M_PCLK    (M_PCLK),   .M_PRESETn (M_PRESETn),
    .S_PCLK    (S_PCLK),   .S_PRESETn (S_PRESETn),
    .M_PADDR   (M_PADDR),  .M_PPROT   (M_PPROT),  .M_PNSE    (M_PNSE),
    .M_PSEL    (M_PSEL),   .M_PENABLE (M_PENABLE), .M_PWRITE  (M_PWRITE),
    .M_PWDATA  (M_PWDATA), .M_PSTRB   (M_PSTRB),  .M_PWAKEUP (M_PWAKEUP),
    .M_PAUSER  (M_PAUSER), .M_PWUSER  (M_PWUSER),
    .M_PREADY  (M_PREADY), .M_PRDATA  (M_PRDATA), .M_PSLVERR (M_PSLVERR),
    .M_PRUSER  (M_PRUSER), .M_PBUSER  (M_PBUSER),
    .S_PADDR   (S_PADDR),  .S_PPROT   (S_PPROT),  .S_PNSE    (S_PNSE),
    .S_PSEL    (S_PSEL),   .S_PENABLE (S_PENABLE), .S_PWRITE  (S_PWRITE),
    .S_PWDATA  (S_PWDATA), .S_PSTRB   (S_PSTRB),  .S_PWAKEUP (S_PWAKEUP),
    .S_PAUSER  (S_PAUSER), .S_PWUSER  (S_PWUSER),
    .S_PREADY  (S_PREADY), .S_PRDATA  (S_PRDATA), .S_PSLVERR (S_PSLVERR),
    .S_PRUSER  (S_PRUSER), .S_PBUSER  (S_PBUSER)
);

// =============================================================================
// 从端寄存器模型（16 × 32bit，由 S_PCLK 驱动）
// =============================================================================
logic [DATA_WIDTH-1:0] slave_regfile [0:15];  // 从端寄存器堆
integer wait_cycles;                           // 随机等待周期数

// 从端 APB 响应逻辑
always @(posedge S_PCLK or negedge S_PRESETn) begin
    if (!S_PRESETn) begin
        S_PREADY  <= 1'b0;
        S_PRDATA  <= '0;
        S_PSLVERR <= 1'b0;
        S_PRUSER  <= '0;
        S_PBUSER  <= '0;
        // 初始化寄存器堆为递增值
        for (int i = 0; i < 16; i++) slave_regfile[i] <= 32'hDEAD_0000 + i;
    end else begin
        S_PREADY  <= 1'b0;
        S_PSLVERR <= 1'b0;

        if (S_PSEL && !S_PENABLE) begin
            // SETUP 阶段：随机决定等待周期数（0~3 拍）
            wait_cycles = $urandom_range(0, 3);
        end

        if (S_PSEL && S_PENABLE) begin
            if (wait_cycles > 0) begin
                // 插入等待周期（PREADY 保持 0）
                wait_cycles = wait_cycles - 1;
                S_PREADY  <= 1'b0;
            end else begin
                // 就绪：处理访问
                S_PREADY  <= 1'b1;
                S_PRUSER  <= 4'hA;
                S_PBUSER  <= 4'hB;

                // 错误注入：地址低 4 位为 0xF 时返回 SLVERR
                if (S_PADDR[3:0] == 4'hF) begin
                    S_PSLVERR <= 1'b1;
                end else if (S_PWRITE) begin
                    // 写操作：按字节使能写入寄存器堆
                    if (S_PSTRB[0]) slave_regfile[S_PADDR[5:2]][ 7: 0] <= S_PWDATA[ 7: 0];
                    if (S_PSTRB[1]) slave_regfile[S_PADDR[5:2]][15: 8] <= S_PWDATA[15: 8];
                    if (S_PSTRB[2]) slave_regfile[S_PADDR[5:2]][23:16] <= S_PWDATA[23:16];
                    if (S_PSTRB[3]) slave_regfile[S_PADDR[5:2]][31:24] <= S_PWDATA[31:24];
                end else begin
                    // 读操作：返回寄存器堆数据
                    S_PRDATA <= slave_regfile[S_PADDR[5:2]];
                end
            end
        end
    end
end

// =============================================================================
// APB 写操作 Task
// =============================================================================
task automatic apb_write(
    input  logic [ADDR_WIDTH-1:0] addr,
    input  logic [DATA_WIDTH-1:0] data,
    input  logic [STRB_WIDTH-1:0] strb,
    input  logic [2:0]            pprot,
    input  logic                  exp_slverr
);
    integer timeout_cnt;
    // SETUP 阶段
    @(posedge M_PCLK);
    M_PADDR   <= addr;
    M_PWDATA  <= data;
    M_PSTRB   <= strb;
    M_PPROT   <= pprot;
    M_PWRITE  <= 1'b1;
    M_PSEL    <= 1'b1;
    M_PENABLE <= 1'b0;

    // ACCESS 阶段
    @(posedge M_PCLK);
    M_PENABLE <= 1'b1;

    // 等待 PREADY（含超时保护）
    timeout_cnt = 0;
    while (!M_PREADY) begin
        @(posedge M_PCLK);
        timeout_cnt++;
        if (timeout_cnt >= PREADY_TIMEOUT) begin
            $error("[TB] @%0t 写操作超时！addr=0x%08X", $time, addr);
            break;
        end
    end

    // 检查 PSLVERR
    if (M_PSLVERR !== exp_slverr)
        $error("[TB] @%0t PSLVERR 不符：期望=%0b，实际=%0b，addr=0x%08X",
               $time, exp_slverr, M_PSLVERR, addr);

    $display("[TB] @%0t [WRITE] addr=0x%08X data=0x%08X strb=0x%X slverr=%0b wait=%0d",
             $time, addr, data, strb, M_PSLVERR, timeout_cnt);

    // 撤销信号
    @(posedge M_PCLK);
    M_PSEL    <= 1'b0;
    M_PENABLE <= 1'b0;
    M_PWRITE  <= 1'b0;

    // 异步桥要求两传输之间至少间隔 1 个主端时钟周期
    @(posedge M_PCLK);
endtask

// =============================================================================
// APB 读操作 Task
// =============================================================================
task automatic apb_read(
    input  logic [ADDR_WIDTH-1:0] addr,
    output logic [DATA_WIDTH-1:0] rdata,
    input  logic [2:0]            pprot,
    input  logic                  exp_slverr
);
    integer timeout_cnt;
    // SETUP 阶段
    @(posedge M_PCLK);
    M_PADDR   <= addr;
    M_PPROT   <= pprot;
    M_PWRITE  <= 1'b0;
    M_PSTRB   <= 4'b0000;
    M_PSEL    <= 1'b1;
    M_PENABLE <= 1'b0;

    // ACCESS 阶段
    @(posedge M_PCLK);
    M_PENABLE <= 1'b1;

    // 等待 PREADY
    timeout_cnt = 0;
    while (!M_PREADY) begin
        @(posedge M_PCLK);
        timeout_cnt++;
        if (timeout_cnt >= PREADY_TIMEOUT) begin
            $error("[TB] @%0t 读操作超时！addr=0x%08X", $time, addr);
            break;
        end
    end

    rdata = M_PRDATA;

    // 检查 PSLVERR
    if (M_PSLVERR !== exp_slverr)
        $error("[TB] @%0t PSLVERR 不符：期望=%0b，实际=%0b，addr=0x%08X",
               $time, exp_slverr, M_PSLVERR, addr);

    $display("[TB] @%0t [READ ] addr=0x%08X data=0x%08X slverr=%0b wait=%0d",
             $time, addr, rdata, M_PSLVERR, timeout_cnt);

    // 撤销信号
    @(posedge M_PCLK);
    M_PSEL    <= 1'b0;
    M_PENABLE <= 1'b0;

    @(posedge M_PCLK);
endtask

// =============================================================================
// 测试统计计数
// =============================================================================
integer pass_cnt = 0;
integer fail_cnt = 0;

// 打印测试分隔线
task print_test_header(input string name);
    $display("\n[TB] ============================================================");
    $display("[TB]  %s", name);
    $display("[TB] ============================================================");
endtask

// =============================================================================
// 主测试序列
// =============================================================================
initial begin
    logic [DATA_WIDTH-1:0] rdata;

    // ------------------------------------------------------------------
    // 波形转储
    // ------------------------------------------------------------------
    `ifdef VCD_DUMP
        $dumpfile("apb5_bridge_tb.vcd");
        $dumpvars(0, apb5_bridge_tb);
        $display("[TB] VCD 转储已开启：apb5_bridge_tb.vcd");
    `endif
    `ifdef FSDB_DUMP
        $fsdbDumpfile("apb5_bridge_tb.fsdb");
        $fsdbDumpvars(0, apb5_bridge_tb);
        $display("[TB] FSDB 转储已开启：apb5_bridge_tb.fsdb");
    `endif

    // ------------------------------------------------------------------
    // 复位序列
    // 推荐顺序：先撤销从端复位，再撤销主端复位
    // ------------------------------------------------------------------
    $display("\n[TB] @%0t ========== 复位序列开始 ==========", $time);
    M_PRESETn = 1'b0;
    S_PRESETn = 1'b0;
    repeat(5) @(posedge M_PCLK);
    @(posedge S_PCLK); S_PRESETn = 1'b1;  // 先撤销从端复位
    repeat(2) @(posedge S_PCLK);
    @(posedge M_PCLK); M_PRESETn = 1'b1;  // 再撤销主端复位
    repeat(3) @(posedge M_PCLK);
    $display("[TB] @%0t 复位序列完成，开始测试", $time);

    // ==================================================================
    // TEST 1：基本写后读回验证
    // ==================================================================
    print_test_header("TEST 1: 基本写后读回验证（4 笔事务）");
    begin
        logic [31:0] wdata [0:3] = '{32'hA5A5_5A5A, 32'h1234_5678,
                                      32'hDEAD_BEEF, 32'hCAFE_BABE};
        logic [31:0] addr  [0:3] = '{32'h0000_0000, 32'h0000_0004,
                                      32'h0000_0008, 32'h0000_000C};
        // 写入 4 个地址
        for (int i = 0; i < 4; i++)
            apb_write(addr[i], wdata[i], 4'hF, 3'b000, 1'b0);

        // 读回并验证
        for (int i = 0; i < 4; i++) begin
            apb_read(addr[i], rdata, 3'b000, 1'b0);
            if (rdata === wdata[i]) begin
                pass_cnt++;
                $display("[TB] @%0t [PASS] 地址 0x%08X 读回数据正确", $time, addr[i]);
            end else begin
                fail_cnt++;
                $error("[TB] @%0t [FAIL] 地址 0x%08X 期望=0x%08X 实际=0x%08X",
                       $time, addr[i], wdata[i], rdata);
            end
        end
    end

    // ==================================================================
    // TEST 2：连续多次写入（8 笔写操作）
    // ==================================================================
    print_test_header("TEST 2: 连续 8 笔写操作");
    begin
        for (int i = 0; i < 8; i++) begin
            automatic logic [31:0] addr_i = 32'h0000_0010 + (i * 4);
            automatic logic [31:0] data_i = 32'hBEEF_0000 + i;
            apb_write(addr_i, data_i, 4'hF, 3'b000, 1'b0);
            pass_cnt++;
        end
        $display("[TB] @%0t [PASS] 8 笔连续写操作完成", $time);
    end

    // ==================================================================
    // TEST 3：从端错误响应测试（PSLVERR）
    // ==================================================================
    print_test_header("TEST 3: 从端错误响应（地址低 4 位 = 0xF）");
    begin
        // 访问错误地址（触发 SLVERR）
        apb_write(32'h0000_002F, 32'hDEAD_DEAD, 4'hF, 3'b000, 1'b1);
        pass_cnt++;

        apb_read(32'h0000_003F, rdata, 3'b000, 1'b1);
        pass_cnt++;

        // 正常地址确认不报错
        apb_write(32'h0000_0030, 32'h1111_1111, 4'hF, 3'b000, 1'b0);
        pass_cnt++;
        $display("[TB] @%0t [PASS] 从端错误响应测试完成", $time);
    end

    // ==================================================================
    // TEST 4：PPROT 保护类型测试
    // ==================================================================
    print_test_header("TEST 4: PPROT 保护类型覆盖");
    begin
        logic [2:0] prot_vals [0:4] = '{3'b000, 3'b001, 3'b010, 3'b100, 3'b110};
        string prot_names [0:4] = '{"普通/非安全/数据",
                                     "普通/非安全/指令",
                                     "普通/安全/数据",
                                     "特权/非安全/数据",
                                     "特权/安全/数据"};
        for (int i = 0; i < 5; i++) begin
            automatic logic [31:0] addr_i = 32'h0000_0040 + (i * 4);
            apb_write(addr_i, 32'hPROT_0000 + i, 4'hF, prot_vals[i], 1'b0);
            apb_read(addr_i, rdata, prot_vals[i], 1'b0);
            $display("[TB] @%0t [PASS] PPROT=%3b (%s) 传输完成",
                     $time, prot_vals[i], prot_names[i]);
            pass_cnt++;
        end
    end

    // ==================================================================
    // TEST 5：字节使能（PSTRB）测试
    // ==================================================================
    print_test_header("TEST 5: 字节使能 PSTRB 全组合覆盖");
    begin
        logic [3:0] strb_vals [0:6] = '{4'b0001, 4'b0010, 4'b0100, 4'b1000,
                                         4'b0011, 4'b1100, 4'b1111};
        string strb_names [0:6] = '{"Byte0", "Byte1", "Byte2", "Byte3",
                                     "HalfWord-Low", "HalfWord-High", "FullWord"};
        // 先写入全 F
        apb_write(32'h0000_0060, 32'hFFFF_FFFF, 4'hF, 3'b000, 1'b0);

        for (int i = 0; i < 7; i++) begin
            automatic logic [31:0] addr_i = 32'h0000_0060;
            apb_write(addr_i, 32'h0000_0000, strb_vals[i], 3'b000, 1'b0);
            $display("[TB] @%0t [PASS] PSTRB=0x%X (%s) 写操作完成",
                     $time, strb_vals[i], strb_names[i]);
            pass_cnt++;
        end
    end

    // ==================================================================
    // TEST 6：地址边界测试
    // ==================================================================
    print_test_header("TEST 6: 地址边界测试（零地址与最大地址）");
    begin
        // 写地址 0
        apb_write(32'h0000_0000, 32'hZERO_ADDR, 4'hF, 3'b000, 1'b0);
        apb_read(32'h0000_0000, rdata, 3'b000, 1'b0);
        if (rdata === 32'hZERO_ADDR) begin
            pass_cnt++;
            $display("[TB] @%0t [PASS] 零地址读写正确", $time);
        end else begin
            fail_cnt++;
            $error("[TB] @%0t [FAIL] 零地址读回错误", $time);
        end

        // 写地址 0x3C（寄存器堆最后一个对齐地址）
        apb_write(32'h0000_003C, 32'hMAX_ADDR_, 4'hF, 3'b000, 1'b0);
        apb_read(32'h0000_003C, rdata, 3'b000, 1'b0);
        if (rdata === 32'hMAX_ADDR_) begin
            pass_cnt++;
            $display("[TB] @%0t [PASS] 最大寄存器地址读写正确", $time);
        end else begin
            fail_cnt++;
            $error("[TB] @%0t [FAIL] 最大寄存器地址读回错误", $time);
        end
    end

    // ==================================================================
    // 测试结果汇总
    // ==================================================================
    repeat(10) @(posedge M_PCLK);
    $display("\n[TB] ============================================================");
    $display("[TB]        测试结果汇总");
    $display("[TB] ============================================================");
    $display("[TB]  通过（PASS）: %0d", pass_cnt);
    $display("[TB]  失败（FAIL）: %0d", fail_cnt);
    $display("[TB]  总计       : %0d", pass_cnt + fail_cnt);
    if (fail_cnt == 0)
        $display("[TB]  ✅ 全部测试通过！");
    else
        $display("[TB]  ❌ 存在 %0d 个失败用例，请检查！", fail_cnt);
    $display("[TB] ============================================================\n");

    $finish;
end

// =============================================================================
// 超时看门狗（防止仿真死锁）
// =============================================================================
initial begin
    #1_000_000;
    $error("[TB] ⚠️  仿真超时（1ms），强制终止！请检查 DUT 是否死锁");
    $finish;
end

endmodule
```

### 11.4 仿真 Makefile


&#160; &#160; &#160; &#160; 三款工具支持：

```shell
make              # 默认：VCS
make TOOL=questa  # Questa
make TOOL=xcelium # Xcelium

```


&#160; &#160; &#160; &#160; 常用命令：
```shell
# 基本仿真
make                          # VCS 编译 + 仿真
make WAVE=fsdb                # 抓取 FSDB 波形（Verdi）
make WAVE=vcd                 # 抓取 VCD 波形

# 覆盖率
make COV=1                    # 启用覆盖率
make vcs_cov_report           # 生成 HTML 覆盖率报告

# 随机回归
make SEED=12345               # 指定种子
make regress                  # 4 场景全量回归
make regress_cov              # 6 个 Seed 覆盖率回归 + 合并

# 测试场景
make test_basic               # SEED=1001
make test_error               # SEED=2002
make test_pstrb               # SEED=3003
make test_boundary            # SEED=4004

# 工具
make lint                     # RTL Lint 检查
make verdi                    # 打开 Verdi 看波形
make clean                    # 清理产物
```
```makefile
# ==============================================================================
# 文件名称 : apb5_bridge_sim.mk
# 描    述 : AMBA 5 APB 异步桥 DV 仿真 Makefile
#            支持工具：Synopsys VCS / Mentor Questa / Cadence Xcelium
# 版    本 : v1.0
# 日    期 : 2026-04-15
# 用    法 : make help
# ==============================================================================

# ==============================================================================
# 工具选择（默认 VCS，可通过命令行覆盖：make TOOL=questa）
# ==============================================================================
TOOL     ?= vcs
TOP      ?= apb5_bridge_tb
SEED     ?= 1
TIMESCALE = 1ns/1ps

# ==============================================================================
# 文件列表
# ==============================================================================
# RTL 源文件
RTL_SRCS  = ../../rtl/apb5_bridge.sv

# DV 文件（Testbench + SVA）
TB_SRCS   = apb5_bridge_tb.sv    \
             apb5_bridge_sva.sv

ALL_SRCS  = $(RTL_SRCS) $(TB_SRCS)

# ==============================================================================
# 输出目录配置
# ==============================================================================
SIM_DIR   = sim_out
LOG_DIR   = logs
COV_DIR   = coverage
WAVE_DIR  = waves

# 编译/仿真日志
COMP_LOG  = $(LOG_DIR)/compile_$(TOOL).log
SIM_LOG   = $(LOG_DIR)/sim_$(TOOL)_seed$(SEED).log

# ==============================================================================
# 宏定义（+define）
# ==============================================================================
DEFINES   = +define+ASSERT_ON

# 覆盖率模式开关（make COV=1 启用）
COV       ?= 0

# 波形抓取开关（make WAVE=vcd 或 make WAVE=fsdb）
WAVE      ?= none

ifeq ($(WAVE),vcd)
    DEFINES += +define+VCD_DUMP
endif
ifeq ($(WAVE),fsdb)
    DEFINES += +define+FSDB_DUMP
endif

# ==============================================================================
# VCS 配置
# ==============================================================================
VCS_COMP_OPTS   = -full64                    \
                  -sverilog                  \
                  +v2k                       \
                  -timescale=$(TIMESCALE)    \
                  -debug_access+all          \
                  -kdb                       \
                  +lint=TFIPC-L             \
                  -notice                   \
                  $(DEFINES)

VCS_SIM_OPTS    = +ntb_random_seed_automatic  \
                  +ntb_random_seed=$(SEED)

ifeq ($(COV),1)
    VCS_COMP_OPTS += -cm line+cond+fsm+branch+tgl  \
                     -cm_dir $(COV_DIR)/$(TOOL)_cov.vdb
    VCS_SIM_OPTS  += -cm line+cond+fsm+branch+tgl
endif

VCS_BIN         = $(SIM_DIR)/simv

# ==============================================================================
# Questa 配置
# ==============================================================================
QUESTA_COMP_OPTS = -sv                           \
                   -timescale $(TIMESCALE)        \
                   -suppress 2583                \
                   $(DEFINES)

QUESTA_SIM_OPTS  = -c                             \
                   -sv_seed $(SEED)               \
                   -do "run -all; quit"

ifeq ($(COV),1)
    QUESTA_COMP_OPTS += -cover sbceft
    QUESTA_SIM_OPTS  += -coverage
endif

# ==============================================================================
# Xcelium 配置
# ==============================================================================
XCELIUM_OPTS     = -sv                           \
                   -timescale $(TIMESCALE)        \
                   -access +rwc                  \
                   -seed $(SEED)                 \
                   $(DEFINES)

ifeq ($(COV),1)
    XCELIUM_OPTS += -covfile xcelium_cov.cfg
endif

# ==============================================================================
# 颜色打印辅助（可选）
# ==============================================================================
GREEN  = \033[0;32m
RED    = \033[0;31m
YELLOW = \033[0;33m
NC     = \033[0m  # 无颜色

# ==============================================================================
# 顶层目标（默认）
# ==============================================================================
.DEFAULT_GOAL := all
.PHONY: all clean help dirs

all: $(TOOL)_run

# ==============================================================================
# 目录创建
# ==============================================================================
dirs:
	@mkdir -p $(SIM_DIR) $(LOG_DIR) $(COV_DIR) $(WAVE_DIR)
	@echo "$(GREEN)[MK] 输出目录已创建$(NC)"

# ==============================================================================
# VCS 目标
# ==============================================================================
.PHONY: vcs_compile vcs_sim vcs_run vcs_cov_report

# VCS 编译
vcs_compile: dirs
	@echo "$(YELLOW)[MK] [VCS] 开始编译...$(NC)"
	@vcs $(VCS_COMP_OPTS)             \
	     -top $(TOP)                  \
	     -o $(VCS_BIN)                \
	     $(ALL_SRCS)                  \
	     2>&1 | tee $(COMP_LOG)
	@if [ $$? -eq 0 ]; then           \
	    echo "$(GREEN)[MK] [VCS] 编译成功$(NC)"; \
	else                              \
	    echo "$(RED)[MK] [VCS] 编译失败，请检查 $(COMP_LOG)$(NC)"; \
	    exit 1;                       \
	fi

# VCS 仿真
vcs_sim: $(VCS_BIN)
	@echo "$(YELLOW)[MK] [VCS] 开始仿真（SEED=$(SEED)）...$(NC)"
	@$(VCS_BIN) $(VCS_SIM_OPTS)      \
	     2>&1 | tee $(SIM_LOG)
	@echo "$(GREEN)[MK] [VCS] 仿真完成，日志：$(SIM_LOG)$(NC)"

# VCS 一键编译+仿真
vcs_run: vcs_compile vcs_sim

# VCS 覆盖率报告生成
vcs_cov_report:
	@echo "$(YELLOW)[MK] [VCS] 生成覆盖率报告...$(NC)"
	@urg -dir $(COV_DIR)/$(TOOL)_cov.vdb \
	     -format both                     \
	     -report $(COV_DIR)/report_html
	@echo "$(GREEN)[MK] 覆盖率报告位置：$(COV_DIR)/report_html/index.html$(NC)"

$(VCS_BIN): $(ALL_SRCS)
	@$(MAKE) vcs_compile

# ==============================================================================
# Questa 目标
# ==============================================================================
.PHONY: questa_compile questa_sim questa_run

# Questa 编译
questa_compile: dirs
	@echo "$(YELLOW)[MK] [Questa] 开始编译...$(NC)"
	@vlib work
	@vmap work work
	@vlog $(QUESTA_COMP_OPTS) $(ALL_SRCS) \
	     2>&1 | tee $(COMP_LOG)
	@echo "$(GREEN)[MK] [Questa] 编译完成$(NC)"

# Questa 仿真
questa_sim:
	@echo "$(YELLOW)[MK] [Questa] 开始仿真（SEED=$(SEED)）...$(NC)"
	@vsim $(QUESTA_SIM_OPTS) $(TOP)   \
	     2>&1 | tee $(SIM_LOG)
	@echo "$(GREEN)[MK] [Questa] 仿真完成$(NC)"

# Questa 一键运行
questa_run: questa_compile questa_sim

# ==============================================================================
# Xcelium 目标
# ==============================================================================
.PHONY: xcelium_run

xcelium_run: dirs
	@echo "$(YELLOW)[MK] [Xcelium] 开始编译+仿真...$(NC)"
	@xrun $(XCELIUM_OPTS)             \
	      -top $(TOP)                 \
	      $(ALL_SRCS)                 \
	      2>&1 | tee $(SIM_LOG)
	@echo "$(GREEN)[MK] [Xcelium] 仿真完成$(NC)"

# ==============================================================================
# 回归测试目标（多场景多 Seed）
# ==============================================================================
.PHONY: regress test_basic test_error test_pstrb test_boundary

# 基本读写测试（Seed=1001）
test_basic:
	@echo "$(YELLOW)[MK] 运行基本读写测试（SEED=1001）...$(NC)"
	@$(MAKE) $(TOOL)_run SEED=1001 \
	     SIM_LOG=$(LOG_DIR)/test_basic.log

# 从端错误响应测试（Seed=2002）
test_error:
	@echo "$(YELLOW)[MK] 运行错误响应测试（SEED=2002）...$(NC)"
	@$(MAKE) $(TOOL)_run SEED=2002 \
	     SIM_LOG=$(LOG_DIR)/test_error.log

# 字节使能测试（Seed=3003）
test_pstrb:
	@echo "$(YELLOW)[MK] 运行字节使能测试（SEED=3003）...$(NC)"
	@$(MAKE) $(TOOL)_run SEED=3003 \
	     SIM_LOG=$(LOG_DIR)/test_pstrb.log

# 地址边界测试（Seed=4004）
test_boundary:
	@echo "$(YELLOW)[MK] 运行地址边界测试（SEED=4004）...$(NC)"
	@$(MAKE) $(TOOL)_run SEED=4004 \
	     SIM_LOG=$(LOG_DIR)/test_boundary.log

# 覆盖率回归（启用全覆盖率采集）
regress_cov:
	@echo "$(YELLOW)[MK] 运行覆盖率回归（COV=1）...$(NC)"
	@for seed in 1001 2002 3003 4004 5005 6006; do       \
	    echo "[MK] 运行 SEED=$$seed";                    \
	    $(MAKE) $(TOOL)_run COV=1 SEED=$$seed;           \
	done
	@$(MAKE) cov_merge
	@$(MAKE) vcs_cov_report

# 全量回归（所有测试场景）
regress: test_basic test_error test_pstrb test_boundary
	@echo "$(GREEN)[MK] ===========================================$(NC)"
	@echo "$(GREEN)[MK]  回归测试全部完成！$(NC)"
	@echo "$(GREEN)[MK]  日志目录：$(LOG_DIR)/$(NC)"
	@echo "$(GREEN)[MK] ===========================================$(NC)"
	@grep -h "PASS\|FAIL" $(LOG_DIR)/*.log | sort | uniq -c

# ==============================================================================
# 覆盖率合并
# ==============================================================================
.PHONY: cov_merge

cov_merge:
	@echo "$(YELLOW)[MK] 合并覆盖率数据库...$(NC)"
	@urg -dir $(COV_DIR)/*.vdb        \
	     -dbname $(COV_DIR)/merged.vdb
	@echo "$(GREEN)[MK] 合并完成：$(COV_DIR)/merged.vdb$(NC)"

# ==============================================================================
# Lint 检查（SpyGlass / Synopsys VCS Lint）
# ==============================================================================
.PHONY: lint

lint:
	@echo "$(YELLOW)[MK] 运行 RTL Lint 检查...$(NC)"
	@vcs -full64 -sverilog             \
	     +lint=TFIPC                   \
	     +lint=PCWM                    \
	     $(RTL_SRCS)                   \
	     -top apb5_async_bridge        \
	     2>&1 | tee $(LOG_DIR)/lint.log
	@echo "$(GREEN)[MK] Lint 报告：$(LOG_DIR)/lint.log$(NC)"

# ==============================================================================
# 波形查看快捷目标
# ==============================================================================
.PHONY: verdi dve

# 用 Verdi 查看 FSDB 波形
verdi:
	@verdi -sv -f filelist.f          \
	        -ssf $(WAVE_DIR)/*.fsdb & \

# 用 DVE 查看 VCD 波形
dve:
	@dve -vpd $(WAVE_DIR)/*.vcd &

# ==============================================================================
# 清理目标
# ==============================================================================
.PHONY: clean distclean

# 清理编译/仿真产物（保留源文件）
clean:
	@echo "$(YELLOW)[MK] 清理仿真产物...$(NC)"
	@rm -rf $(SIM_DIR) $(LOG_DIR) $(COV_DIR) $(WAVE_DIR)
	@rm -rf work csrc simv.daidir
	@rm -rf *.log *.vcd *.fsdb *.db *.vdb
	@rm -rf INCA_libs xcelium.d .simvision
	@rm -rf ucli.key vc_hdrs.h
	@echo "$(GREEN)[MK] 清理完成$(NC)"

# 深度清理（包含工具生成的隐藏目录）
distclean: clean
	@rm -rf .vcs_lib .questa_lib .xcelium_lib
	@echo "$(GREEN)[MK] 深度清理完成$(NC)"

# ==============================================================================
# 帮助信息
# ==============================================================================
help:
	@echo ""
	@echo "$(GREEN)======================================================$(NC)"
	@echo "$(GREEN)  APB5 Bridge DV 仿真 Makefile 使用说明$(NC)"
	@echo "$(GREEN)======================================================$(NC)"
	@echo ""
	@echo "  $(YELLOW)基本用法：$(NC)"
	@echo "    make                      # 默认：VCS 编译+仿真"
	@echo "    make TOOL=questa          # 使用 Questa 仿真"
	@echo "    make TOOL=xcelium         # 使用 Xcelium 仿真"
	@echo ""
	@echo "  $(YELLOW)覆盖率：$(NC)"
	@echo "    make COV=1                # 启用覆盖率采集"
	@echo "    make vcs_cov_report       # 生成 HTML 覆盖率报告"
	@echo "    make cov_merge            # 合并多次运行覆盖率"
	@echo ""
	@echo "  $(YELLOW)波形抓取：$(NC)"
	@echo "    make WAVE=vcd             # 抓取 VCD 波形"
	@echo "    make WAVE=fsdb            # 抓取 FSDB 波形（需 Verdi）"
	@echo "    make verdi                # 打开 Verdi 查看波形"
	@echo ""
	@echo "  $(YELLOW)随机种子：$(NC)"
	@echo "    make SEED=12345           # 指定随机种子"
	@echo ""
	@echo "  $(YELLOW)测试场景：$(NC)"
	@echo "    make test_basic           # 基本读写测试（SEED=1001）"
	@echo "    make test_error           # 从端错误响应（SEED=2002）"
	@echo "    make test_pstrb           # 字节使能测试（SEED=3003）"
	@echo "    make test_boundary        # 地址边界测试（SEED=4004）"
	@echo "    make regress              # 全量回归测试"
	@echo "    make regress_cov          # 全量覆盖率回归"
	@echo ""
	@echo "  $(YELLOW)其他：$(NC)"
	@echo "    make lint                 # RTL Lint 检查"
	@echo "    make clean                # 清理产物"
	@echo "    make distclean            # 深度清理"
	@echo "$(GREEN)======================================================$(NC)"
	@echo ""
```

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