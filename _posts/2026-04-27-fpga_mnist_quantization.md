---
layout: post
title:  "从浮点到定点：FPGA 神经网络量化实战与 PYNQ-Z2 资源博弈"
date:   2026-04-27 12:00:00 +0800
tags: 
  - Neural Networks
  - Quantization
  - FPGA
  - PYNQ
---

## 1 前言：逃离浮点的“舒适区”

在上一阶段中，我们通过 PyTorch 成功训练出了一个 MNIST 全连接神经网络，并导出了模型的权重参数。打开导出的 `.txt` 文件，你会看到满屏的 `0.0234`, `-1.109` 这样的 32位浮点数 (float32)。

在 CPU 和 GPU 架构中，计算 IEEE 754 标准的浮点数是非常基础且高效的操作。但在 FPGA 的底层数字逻辑中，如果我们要用纯逻辑单元（LUTs）强行拼凑出一个浮点乘累加器，不仅会消耗极其庞大的逻辑资源，更会严重拖慢系统的时序，让整个流水线变得异常臃肿。

因此，**将浮点数转换为定点数（Fixed-point）或纯整数（Integer），是 AI 算法真正落地到 FPGA 硬件的必经之路。** 这一步被称为**模型量化（Quantization）**。今天，我们将聚焦于第三阶段的核心：如何将这些参数转化为 FPGA 能够高效吞吐的数据，以及我们为什么在 PYNQ-Z2 开发板上做出了坚定的位宽选择。

---

## 2 定点数表示与 Q 格式

在 FPGA 内部，我们最强大的算术计算资源是 **DSP Slice**（如 Xilinx 的 DSP48E1）。它们是处理定点数和整数乘加运算的核心单元。

为了在整数计算器上表示小数，工程上通常使用 **Q 格式 (Q-Format)**。
比如 **Q4.12 格式**，表示总共 16 位宽，其中：
- 1 位符号位 (Sign bit)
- 3 位整数部分 (Integer bits)
- 12 位小数部分 (Fractional bits)

**转换原理相对直观**：
将浮点数乘以 $2^{12} (4096)$，然后四舍五入取整。
* `0.165 (float)` $\rightarrow 0.165 \times 4096 = 675.84 \rightarrow 676 \rightarrow$ `0x02A4`
* `-0.5 (float)` $\rightarrow -0.5 \times 4096 = -2048 \rightarrow$ `0xF800` (二进制补码)

虽然操作看似仅为乘法与截断，但其中涉及关键的精度权衡。强行截断必然引入误差，若小数位宽过窄（例如仅 4 位），累积误差将导致 MNIST 识别准确率大幅下降。

---

## 3 直觉陷阱：为什么不选 8-bit (INT8) 量化？

在深度学习的工业界，INT8 量化几乎是标配。直觉上，8 位数据比 16 位更窄，省寄存器、省布线，为什么我在这个项目中强烈推荐大家（尤其是 FPGA 初学者）**首选 16-bit 定点数量化**呢？

这是一个极其敏锐且直击痛点的问题。答案在于：**硬件数据宽度确实变小了，但算法补偿和数据通路控制的代价却呈指数级上升。**

### 3.1 算法侧的挣扎：256 个格子的世界
16-bit 有 65536 个离散的台阶，你可以从容地进行“乘常数截断”，精度几乎零损失。而 8-bit 只有 256 个台阶，强行把复杂的权重分布塞进去会产生巨大的量化噪声。为了挽救精度，算法端被迫引入了非对称量化、动态 Scale、Zero-point，甚至必须进行量化感知训练 (QAT)。这大大增加了算法端的设计复杂度。

### 3.2 RTL 侧的挑战：数据通路的交叉项
在 16-bit 固定小数点下（如 Q4.12），你的乘累加 (MAC) 就是极简的 `Sum = Sum + (X * W)`。
但在标准的 INT8 仿射量化下，真实的数学值是 $Scale \times (Value_{int8} - ZeroPoint)$。
展开后，硬件里的一个 MAC 操作变成了包含交叉乘法项和偏置补偿的复杂逻辑：
$Sum = \sum (X_q \cdot W_q) - Z_w \sum X_q - Z_x \sum W_q + N \cdot Z_x \cdot Z_w$
原本一个乘法器的事，现在硬件里凭空多出了一堆补偿逻辑。

### 3.3 Re-quantization 卡脖子
INT8 算完累加后会变成一个 32 位的中间值。为了送到下一层，你必须除以一个浮点数的 Scale 重新映射回 INT8。这需要在 RTL 里设计复杂的动态移位和乘法来模拟浮点除法，数据流控制器设计难度极高。

综上所述，**16-bit 定点是算法和硬件友好的“甜点区”**，它极简的控制逻辑能让你把主要精力放在时序和流水线架构上。

---

## 4 结合 PYNQ-Z2 的芯片级考量

我们不仅要懂理论，还要懂手里的这块硅片。PYNQ-Z2 搭载的是 Zynq-7000 系列的 **XC7Z020** SoC。分析这颗芯片的资源，16-bit 的选择更是堪称完美：

1. **DSP48E1 的完美契合**：
   XC7Z020 内部的 DSP48E1 包含一个 **25 × 18 bit** 的有符号乘法器。如果你做 16-bit (16x16) 的乘法，它完美地嵌进了一个 DSP 中，时序极佳。如果你强行用 8-bit，标准的写法同样会消耗一整个 25x18 乘法器，除非你使用非常高级的 SIMD bit-packing 技巧（一个 DSP 算两组 8x8），否则 8-bit 在计算资源上并没有省下什么。
2. **BRAM 资源绰绰有余**：
   芯片内有 140 个 36Kb 的 BRAM，总计约 600 KB。我们这个 784->128->64->10 的 MNIST 网络，总计约 10 万个参数。用 16-bit 存储，总体积约 200 KB。**这就意味着，整个神经网络的所有权重都可以全内置在片上 BRAM 中！** 这避免了设计复杂的 DDR 读写控制器，实现了片内全缓冲，从而大幅降低推理延迟。

---

## 5 实战：Python 16-bit 量化脚本

理论分析完毕，下面是我们编写的 Python 脚本。它将我们第二阶段导出的浮点数 `.txt` 转换为 16-bit Q4.12 格式的 `.hex` 文件，这些文件将会在下一阶段直接被 Vivado 中的 `$readmemh` 指令读取并烧入 BRAM。

```python
import numpy as np
import os

def quantize_to_hex(float_val, bits=16, frac_bits=12):
    # 第一步：缩放 (Multiply by 2^frac_bits)
    scaled = float_val * (2**frac_bits)
    # 第二步：四舍五入取整
    quantized = int(round(scaled))
    
    # 第三步：饱和截断逻辑 (防溢出保护)
    max_val = (2**(bits-1)) - 1
    min_val = -(2**(bits-1))
    if quantized > max_val:
        quantized = max_val
    if quantized < min_val:
        quantized = min_val
    
    # 第四步：处理 2 的补码，并格式化为 Hex
    if quantized < 0:
        quantized = (1 << bits) + quantized
        
    fmt_str = '0' + str(bits//4) + 'x'
    return format(quantized, fmt_str)

def process_file(input_path, output_path, bits=16, frac_bits=12):
    data = np.loadtxt(input_path)
    with open(output_path, 'w') as f:
        if data.ndim == 0: # 处理只有单个数值的情况（如 bias）
            f.write(quantize_to_hex(data, bits, frac_bits) + "\n")
        else:
            for val in data.flatten(): # 矩阵展平
                f.write(quantize_to_hex(val, bits, frac_bits) + "\n")
    print(f"Quantized {input_path} -> {output_path} (Hex)")

def main():
    param_dir = "params"
    hex_dir = "params_hex"
    if not os.path.exists(hex_dir):
        os.makedirs(hex_dir)
        
    files = [f for f in os.listdir(param_dir) if f.endswith('.txt')]
    
    # 使用 16-bit Q4.12 格式
    BITS = 16
    FRAC_BITS = 12
    
    # 计算量化所能表示的真实浮点数范围
    max_val_f = (2**(BITS-1) - 1) / (2**FRAC_BITS)
    min_val_f = -(2**(BITS-1)) / (2**FRAC_BITS)
    print(f"Starting Quantization: BITS={BITS}, FRAC_BITS={FRAC_BITS} (Range: [{min_val_f}, {max_val_f}])")
    
    for f in files:
        input_path = os.path.join(param_dir, f)
        output_path = os.path.join(hex_dir, f.replace('.txt', '.hex'))
        process_file(input_path, output_path, BITS, FRAC_BITS)
        
    print("\nQuantization complete. Hex files are in 'params_hex/'.")
    print("These files can be loaded in Verilog using $readmemh.")

if __name__ == "__main__":
    main()
```

运行输出：
```text
Starting Quantization: BITS=16, FRAC_BITS=12 (Range: [-8.0, 7.999755859375])
Quantized params/fc1_weight.txt -> params_hex/fc1_weight.hex (Hex)
...
Quantization complete. Hex files are in 'params_hex/'.
```

## 6 结语与下一步行动

至此，数据侧的准备工作彻底收官。我们拿到了可以在 FPGA 内部快速流转的 16 位纯净版参数包（以 2的补码十六进制表示）。例如导出的 `02a4`，代表十进制的 `676`，对应真实的浮点权重就是 `676 / 4096 ≈ 0.165`。

从下一阶段开始，我们将正式步入 **硬件架构设计 (Phase 4)**。我们将亲手写下第一行 Verilog，利用这些 Hex 数据设计底层的 MAC 计算核心，并搭建起时序控制的骨架。

欢迎大家在评论区探讨硬件资源配置策略！
