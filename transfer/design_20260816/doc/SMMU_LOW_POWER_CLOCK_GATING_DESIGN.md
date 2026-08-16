# SMMU 纯 RTL 低功耗时钟门控设计说明

## 1. 设计目标

SMMU 的主要动态功耗来自各控制模块、链表状态寄存器、占用计数器以及相关时钟树在空闲期间持续翻转。本设计在不实例化工艺专用时钟门控 cell 的前提下，通过纯 SystemVerilog RTL 生成门控时钟，使数据通路在无工作时停止时钟。

设计目标如下：

- 初始化、入队、出队、回收和老化冲刷期间正常运行；
- 队列为空时可以休眠；
- 队列非空但暂时没有请求时也可以休眠；
- 入队、出队、回收请求能够自动唤醒核心；
- 睡眠期间老化计时不能停止，老化超时后必须自动唤醒并冲刷；
- 不增加接口可见的请求处理周期，不降低背靠背吞吐率；
- 保留关闭门控的参数，便于功能对比和调试。

本方案属于时钟门控，只降低时钟及寄存器翻转造成的动态功耗，不切断电源，因此不能消除漏电功耗，所有寄存器状态在睡眠期间保持不变。

## 2. 总体架构

设计将 SMMU 划分为“门控核心”和“常开控制岛”两部分。

```text
                                      +-------------------------+
外部请求/配置变化 ------------------->| wake_req / 空闲控制逻辑 |
                                      +------------+------------+
                                                   |
clk_core ------------------------------------------+-------------------+
      |                                            |                   |
      |                                            v                   |
      |                              +---------------------------+      |
      |                              | 低电平透明 latch + AND    |      |
      |                              +-------------+-------------+      |
      |                                            |                    |
      |                                      smmu_core_clk              |
      |                                            |                    |
      |        +---------------+-------------------+----------------+   |
      |        |               |                   |                |   |
      |   enqueue_ctrl    dequeue_ctrl        recycle_ctrl         CSR  |
      |        |               |                   |                |   |
      |        +---------------+--------+----------+----------------+   |
      |                                 |                              |
      |                            LLE / Occupancy                     |
      |                                 |                              |
      |                       q_occupied / deq_fire                    |
      |                                 |                              |
      +-------------------------> aging_ctrl（常开）                   |
                                        |                              |
                                  age_flush_req -----------------------+
                                        （老化超时唤醒核心）
```

### 2.1 门控核心

以下模块改用 `smmu_core_clk`：

| 模块 | 主要功能 |
| --- | --- |
| `enqueue_ctrl` | 入队请求和分配控制 |
| `dequeue_ctrl` | 出队请求和地址返回 |
| `recycle_ctrl` | 单播/多播回收请求控制 |
| `lle` | free链、队列链、多播链以及Next-Ptr SRAM控制 |
| `occupancy_pool_mgr` | 队列、端口、全局占用计数及流控 |
| `csr_stats_init` | 配置采样、统计及初始化控制 |

这些模块休眠后寄存器不再接收时钟边沿，组合逻辑输入大部分保持稳定，从而降低动态功耗。

### 2.2 常开控制岛

以下逻辑继续使用原始 `clk_core`，或在核心时钟停止时仍保持组合可用：

- `aging_ctrl`：队列非空且核心睡眠时继续累计老化时间；
- 外部请求的组合唤醒逻辑；
- 外部配置值与已采样配置值的变化比较逻辑；
- `smmu_clock_gate_rtl` 中的门控使能锁存器和时钟与门。

`aging_ctrl` 保持常开的原因是：如果它也使用 `smmu_core_clk`，队列非空后核心一旦睡眠，老化计时器也会停止，队列将永远无法因老化超时自动唤醒。

## 3. RTL模块改动

### 3.1 `smmu.sv`

新增参数：

```systemverilog
parameter int CLK_GATING_EN = 1
```

- `CLK_GATING_EN != 0`：启用纯RTL时钟门控；
- `CLK_GATING_EN == 0`：`smmu_core_clk` 直接连接 `clk_core`，用于回归对比和调试。

新增低功耗控制逻辑，并将除 `aging_ctrl` 外的子模块时钟从 `clk_core` 改为 `smmu_core_clk`。

新增 `smmu_clock_gate_rtl` 模块。该模块不实例化工艺库特殊cell，而是使用低电平透明锁存器保存门控使能：

```systemverilog
always_latch begin
    if (!clk_in) begin
        if (!rst_n)
            enable_latched <= 1'b1;
        else
            enable_latched <= enable;
    end
end

assign clk_out = clk_in & enable_latched;
```

### 3.2 `lle.sv`

新增输出信号 `lle_busy`，集中表示LLE内部仍有必须完成或排空的操作：

```systemverilog
assign lle_busy = (build_st_q != ST_IDLE) |
                  enq_pkt_lock_q          |
                  deq_pend_q              |
                  enq_pend_q              |
                  ~rcy_fifo_empty         |
                  agf_active;
```

各项含义如下：

| 条件 | 不能休眠的原因 |
| --- | --- |
| `build_st_q != ST_IDLE` | 初始化free链仍在构建 |
| `enq_pkt_lock_q` | 一个连续报文仍处于挂链过程 |
| `deq_pend_q` | 出队SRAM返回或预取更新尚未完成 |
| `enq_pend_q` | 入队SRAM返回或预取更新尚未完成 |
| `~rcy_fifo_empty` | 回收FIFO中仍有cell需要接回free链 |
| `agf_active` | 老化整链拼接仍在执行 |

### 3.3 `aging_ctrl.sv`

`aging_ctrl` 内部功能没有改写，但顶层例化时，其时钟连接由门控后的 `smmu_core_clk` 改为原始 `clk_core`：

```systemverilog
.clk_core (clk_core)
```

因此老化时间仍以真实的300 MHz父时钟周期为单位，不会因为数据通路休眠而被拉长。

### 3.4 `smmu_tb.sv`

testbench新增 `CLK_GATING_EN=1`，并加入 `LP-001` 至 `LP-006` 低功耗测试。`LP-006` 完整覆盖初始化建链、6-cell挂链、6-cell走链、6-cell还链以及各阶段的持续休眠。

## 4. 新增和改动信号

| 信号 | 类型/来源 | 作用 |
| --- | --- | --- |
| `smmu_core_clk` | 顶层内部时钟 | 门控核心使用的工作时钟 |
| `cfg_change_req` | 组合信号 | 任一外部配置值与已采样配置不同则请求唤醒 |
| `wake_req` | 组合信号 | 汇总所有能够直接唤醒核心的事件 |
| `core_work_pending` | 组合信号 | 汇总核心内部尚未完成的工作，阻止过早关钟 |
| `idle_qual_q` | 1 bit寄存器 | 第一拍空闲确认 |
| `core_idle_q` | 1 bit寄存器 | 核心已经进入休眠的状态标志 |
| `clock_req` | 组合信号 | 送入门控锁存器的最终时钟请求 |
| `enable_latched` | 门控模块寄存状态 | 仅在父时钟低电平期间更新门控使能 |
| `lle_busy` | `lle`输出 | 表示LLE内部仍有建链、流水、回收或冲刷工作 |

`cfg_change_req` 当前检查以下标量配置：队列min/max、端口max、全局max、PAUSE使能及阈值、PFC使能及阈值、老化使能、老化超时值和软件强制老化。当前接口没有独立的 `cfg_update` 脉冲，因此使用外部值与CSR已采样值比较的方式检测配置变化。

## 5. 什么情况下关闭时钟

关闭时钟的基础条件是：连续两个 `smmu_core_clk` 有效上升沿上，`core_work_pending` 都为0。

```systemverilog
core_work_pending = wake_req       |
                    lle_busy       |
                    init_build_req |
                    clr_ptr_cnt    |
                    age_flush_req  |
                    age_flush_busy |
                    aging_notify   |
                    lle_alloc_evt  |
                    lle_free_evt   |
                    lle_deq_fire;
```

第一拍检测到无工作时，`idle_qual_q` 置1；第二拍仍然无工作时，`core_idle_q` 置1。随后：

```systemverilog
clock_req = ~core_idle_q | wake_req;
```

在父时钟低电平期间，门控锁存器采到 `clock_req=0`，下一次父时钟上升沿被抑制，`smmu_core_clk` 保持为0。

两拍空闲确认用于等待以下状态完全落地：

- 单拍 `valid/ack/event` 脉冲被下游采样；
- Next-Ptr SRAM一拍返回完成；
- 入队/出队预取寄存器完成更新；
- 占用计数和统计计数完成更新；
- 回收FIFO以及老化整链拼接排空。

### 5.1 队列非空是否阻止休眠

不会。`q_occupied_vec` 不属于 `core_work_pending`。

队列中可以保存一个或多个尚未出队的报文，只要当前没有入队、出队、回收、初始化、SRAM pending或老化冲刷等工作，核心仍可进入休眠。链表头尾、cell计数、packet计数和SRAM内容在时钟停止期间保持不变。

## 6. 什么情况下开启时钟

`wake_req` 定义如下：

```systemverilog
wake_req = init_start           |
           enq_req              |
           deq_req              |
           recycle_req          |
           age_flush_req        |
           cfg_in_age_force_all |
           cfg_change_req;
```

| 唤醒源 | 唤醒后的工作 |
| --- | --- |
| `init_start` | 初始化并构建完整free链 |
| `enq_req` | 地址分配和挂链 |
| `deq_req` | 读取队头并推进队列链 |
| `recycle_req` | 将cell接回free链或更新多播引用计数 |
| `age_flush_req` | 对超时队列执行老化整链冲刷 |
| `cfg_in_age_force_all` | 软件强制发起老化处理 |
| `cfg_change_req` | 唤醒CSR并采样新的配置值 |

任一唤醒源有效时，`clock_req` 立即变为1。门控锁存器在 `clk_core` 低电平阶段透明，因此可在下一个父时钟上升沿到来前打开时钟。

## 7. 老化期间的休眠和自动唤醒

队列非空并不保持数据通路时钟开启。老化流程如下：

1. LLE中的 `q_occupied_vec` 保持队列非空状态；
2. 门控核心无当前工作，连续空闲两拍后睡眠；
3. 常开的 `aging_ctrl` 继续增加该队列的 `age_timer_q`；
4. 计时达到 `cfg_aging_timeout` 后产生 `age_trig`；
5. 老化仲裁器产生 `age_flush_req`；
6. `age_flush_req` 进入 `wake_req`，门控核心自动恢复时钟；
7. LLE一次性将老化链拼接到free链；
8. `age_flush_done/aging_notify` 完成清账；
9. 所有冲刷状态排空后，核心再次进入休眠。

`aging_ctrl` 与门控核心使用同一个父时钟源，两者是同源同步关系，不是异步CDC。物理实现时仍必须在STA中正确描述 `smmu_core_clk` 与 `clk_core` 的生成时钟关系。

## 8. 为什么不改变原接口时序

### 8.1 唤醒不增加逻辑周期

门控使能只在 `clk_core` 低电平时更新。如果一个请求在低电平期间有效，`enable_latched` 会在下一上升沿之前置1，因此下一父时钟上升沿同时成为 `smmu_core_clk` 的上升沿，请求仍在原计划的采样边沿被接收。

对于由同一父时钟域上游寄存器在上升沿发出的请求，上游寄存器的新值在该上升沿之后才出现。未门控设计也只能由SMMU在下一个上升沿采到这个新值；门控锁存器会在两次上升沿之间的低电平阶段捕获唤醒请求，因此SMMU同样在下一个上升沿采样，不增加周期。

```text
父时钟上升沿 N       父时钟低电平区间       父时钟上升沿 N+1
上游寄存器发出req  -> 门控锁存器捕获req  -> SMMU正常采样req
```

### 8.2 不截断时钟脉冲

`enable_latched` 在 `clk_core` 高电平期间保持不变，因此：

- 不会在高电平中途关闭时钟；
- 不会产生窄高脉冲；
- 不会因为组合唤醒信号抖动而在高电平期间产生额外边沿；
- 关钟只会抑制完整的后续周期。

### 8.3 背靠背流量不产生气泡

连续入队、出队或回收期间，对应请求持续有效，`wake_req` 始终为1；即使请求间切换，内部 `lle_busy`、pending和event信号也会阻止 `core_idle_q` 置位。因此 `smmu_core_clk` 连续通过，原有1 cell/cycle吞吐率保持不变。

### 8.4 休眠前等待流水排空

`lle_busy` 与两拍空闲确认共同保证不会在SRAM返回、链表预取、连续报文挂链或回收FIFO处理中间关闭时钟。时钟停止时，核心处于可安全保持的边界状态。

需要注意：“接口逻辑周期不变”不等于物理时序自动满足300 MHz。综合和后端仍需检查唤醒组合路径、门控锁存器、生成时钟插入延迟以及门控后各寄存器的setup/hold。

## 9. 复位行为

复位期间：

- `core_idle_q` 清0；
- `idle_qual_q` 清0；
- 门控锁存器将 `enable_latched` 置1；
- 核心时钟默认打开。

这样可以保证复位释放后初始化控制逻辑能够正常运行，不会出现尚未初始化就因为默认休眠而无法启动的问题。

## 10. 验证覆盖

| Case | 验证内容 |
| --- | --- |
| `LP-001` | 空闲后 `core_idle_q=1` 且 `smmu_core_clk=0` |
| `LP-002` | 从睡眠唤醒后的第一个预期父时钟边沿接收入队请求 |
| `LP-003` | 睡眠唤醒后连续3-cell入队无气泡 |
| `LP-004` | 队列非空但无请求时仍可休眠 |
| `LP-005` | 睡眠期间老化超时、自动唤醒、完成冲刷并清空队列 |
| `LP-006` | 初始化建链、6-cell挂链、6-cell走链、6-cell还链全部成功，并分别持续休眠30/30/30/39周期 |

`LP-006` 不只检查最终休眠状态，还在每个休眠窗口的每个父时钟下降沿检查：

```systemverilog
core_idle_q   == 1'b1
smmu_core_clk == 1'b0
```

同时保存6个实际分配地址，走链时逐个核对地址、帧头和帧尾，最后使用走链得到的真实地址执行还链，并检查 `free_cnt_q` 恢复到 `CELL_NUM`。

## 11. 综合与STA注意事项

虽然RTL没有实例化工艺专用时钟门控cell，ASIC实现仍需要完成以下工作：

1. 将 `smmu_core_clk` 识别或约束为由 `clk_core` 派生的同频、同源生成时钟；
2. 对 `clk_core` 到 `smmu_core_clk` 的门控结构执行clock-gating check；
3. 检查 `wake_req -> enable_latched` 在父时钟低电平窗口内的时序；
4. 检查门控时钟插入延迟、偏斜、setup和hold；
5. 确认综合没有将低电平锁存器错误优化为高电平可变化的组合门控；
6. 使用门级仿真或形式等价检查确认门控前后功能一致；
7. 使用SAIF/VCD活动率进行功耗分析，比较 `CLK_GATING_EN=0/1` 两种配置。

若综合流程允许自动识别时钟门控结构，可以由综合工具映射为库中的等价门控结构；RTL本身仍不包含任何工艺相关cell名称。若工具不做自动映射，则必须由后端把锁存器与与门构成的时钟路径作为真实时钟网络处理。

## 12. 当前方案的边界

- 这是时钟门控，不是电源门控；
- `aging_ctrl` 保持常开，因此其时钟树和老化计时寄存器仍有动态功耗；
- 配置变化比较网络保持常开，但配置稳定时其数据翻转很少；
- 当前没有对外提供休眠状态输出或休眠周期统计计数器；
- 当前采用两拍空闲确认，没有额外的最短休眠驻留时间或频繁启停迟滞策略；
- 最终可实现频率和功耗收益需要以后端STA及门级功耗分析结果为准。

## 13. 相关文件

- `design/rtl/smmu.sv`：顶层低功耗控制、门控时钟模块以及子模块时钟分区；
- `design/rtl/lle.sv`：`lle_busy` 工作未完成指示；
- `design/rtl/aging_ctrl.sv`：常开老化计时与超时冲刷请求；
- `design/tb/smmu_tb.sv`：`LP-001` 至 `LP-006` 验证case。
