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
