# Smart MMU (SMMU) 设计模块讲解 — PPT 详细大纲

> 面向对象：以太网交换芯片 QM/MMU 团队、设计评审、验证同事
> 建议页数：约 30~34 页（含封面、目录、正文、总结）
> 说明：每页均含【标题】+【正文/要点】+【建议配图】+【建议表格】。整体视觉遵循文首"视觉风格规范"章节（配色、字体、版式统一）。
>
> ⚠️ 制作 PPTX 时注意：**成品 PPT 页面中不得出现任何品牌名称字样**（本大纲中的品牌相关名词仅供制作者内部参考对齐配色/字体，实际落到幻灯片上时一律隐去，只体现颜色值与视觉效果）。

---

# ★ 视觉风格规范 (先读，全 PPT 统一套用)

## 一、配色 (Brand Palette)

以 **深蓝 (主色)** 为核心色，辅以中性灰与少量强调色。建议在 PowerPoint 中新建"主题颜色"套用如下取值：

| 用途 | 颜色名 | HEX | RGB | 使用场景 |
|---|---|---|---|---|
| 主色 (Primary) | 主蓝 | `#3253DC` | 50,83,220 | 标题栏、封面底、主强调、Logo 区 |
| 主色深 | 深蓝 | `#1B1F6B` / `#0A0F5C` | 27,31,107 | 大标题文字、深色页背景 |
| 辅助蓝 | 天蓝 | `#6CA0F6` / `#A5C8FF` | 108,160,246 | 数据/存储面模块框、渐变 |
| 强调色 | 青色 | `#00C2DE` / `#12B6CE` | 0,194,222 | 关键信号/高亮、图表点缀 |
| 中性深灰 | Charcoal | `#2E2E38` | 46,46,56 | 正文文字 |
| 中性中灰 | Gray | `#6E6E7A` | 110,110,122 | 次要文字、表头填充 |
| 中性浅灰 | Light Gray | `#F2F4F8` | 242,244,248 | 页面/表格底纹 |
| 背景白 | White | `#FFFFFF` | 255,255,255 | 主背景 |
| 告警红 | Alert Red | `#E4002B` | 228,0,43 | 告警/溢出/drop (克制使用) |
| 通过绿 | Accent Green | `#3DBB6B` | 61,187,107 | 配置/正常/守恒 OK |

- **功能面配色映射**（本 PPT 框图统一约定，替换原"蓝橙绿"）：
  - 数据/存储面 → **主蓝 `#3253DC` / 天蓝 `#6CA0F6`**
  - 控制面 → **青色 `#00C2DE`**
  - 配置/统计面 → **Accent Green `#3DBB6B`**
  - 告警/丢弃 → **Alert Red `#E4002B`**
- **配色使用比例**：蓝系约 60%、中性灰约 30%、强调色(青/绿/红)约 10%。避免大面积高饱和色。

## 二、字体 (Typography)

优先使用团队指定品牌字体（内部资产库获取）。若无法获取，使用以下等效替代，保证观感一致：

| 层级 | 通用替代 (英文) | 中文替代 | 字号建议 |
|---|---|---|---|
| 大标题 / 封面主标题 | Arial Bold / Helvetica Neue Bold | 思源黑体 Heavy / 微软雅黑 Bold | 36~44 pt |
| 页面标题 (H1) | Arial Bold | 思源黑体 Bold / 微软雅黑 Bold | 28~32 pt |
| 小标题 (H2) | Arial | 思源黑体 Medium | 20~24 pt |
| 正文 / 要点 | Arial | 思源黑体 Regular / 微软雅黑 | 16~18 pt |
| 表格 / 图注 | Arial | 思源黑体 Regular | 12~14 pt |
| 代码 / 信号名 | Consolas / Courier New | Consolas | 12~14 pt |

- **字体原则**：全 PPT 仅用 1~2 种字族（无衬线为主），层级靠字重(Bold/Medium/Regular)与字号区分，不混用多种字体。
- **英文/信号名**：`enq_req`、`lle_alloc_fire` 等一律用等宽字体，与正文区分。

## 三、版式 (Layout)

- **母版**：顶部放一条主蓝色带（高约 10~12% 页高）承载页面标题；左上角或右下角放团队 Logo（遵循留白规范，Logo 四周留 = Logo 高度的间距）。
- **页脚**：左下角文档标题 (SMMU Design Review)、右下角页码，用中性中灰 12pt。
- **对齐**：内容统一左对齐，网格化排布；模块框圆角 4~8px，1~1.5px 描边。
- **图标**：优先用线性/细描边风格图标，颜色取主色或中性灰，风格统一。
- **封面 (第 1 页)**：深蓝渐变背景 (`#0A0F5C`→`#3253DC`)，白色大标题，右下角团队 Logo；不放过多元素。
- **章节分隔页**：整页主蓝底 + 白色章节标题 + 大号章节序号 (青色)。

## 四、图表风格 (全 PPT 配图统一)

- 柱状/水位图：主色 + 辅助蓝渐变，阈值线用告警红虚线；网格线浅灰。
- 时序波形：信号名等宽字体 (深灰)，波形线主色，跳变高亮用青色。
- 框图：功能面按上文配色映射；箭头用中性深灰，关键路径箭头加粗并用青色。
- **AI 生成配图统一风格锚点**（所有交给图像引擎的 prompt 都应包含此段，保证多张图观感一致）：
  > *Clean modern flat vector technical diagram, corporate slide style, deep blue (#3253DC) primary with sky blue (#6CA0F6) and cyan (#00C2DE) accents, alert red (#E4002B) for warnings and green (#3DBB6B) for OK/config, neutral gray (#2E2E38) text and dark-gray arrows, white background, thin rounded-rectangle blocks with 1px stroke, sans-serif labels, no photo, no 3D, no gradient-heavy bevel, minimalist, high contrast, 16:9.*

> 制作提示：可先在 PowerPoint「设计 → 变体 → 颜色 → 自定义颜色」中建立自定义主题色，再统一套用到所有页面与 SmartArt/图表，确保风格一致。

---

## 第 1 页：封面

- **主标题**：4 端口以太网交换芯片 —— Smart MMU (共享缓存地址管理单元) 设计讲解
- **副标题**：Flexible Shared SRAM Address Management Module
- **要点**：
  - 项目：4-Port 2.5G/1G/100M Ethernet Switch
  - 时钟域：clk_core 300 MHz 单时钟域，rst_core_n 异步复位低有效
  - 汇报人 / 日期 / 版本 (RTL 版本：B2 多播逻辑拼接版)
- **建议配图**：芯片报文处理主链路缩略框图，横向流水：
  `IPS → PPE → QM (En-Queue) → SMMU → QM (De-Queue) → EPS`
  其中 **SMMU** 高亮（主蓝填充白字），QM 出现两次（入队/出队两个阶段）分列 SMMU 两侧，直观体现 "QM 把入队/出队请求发给 SMMU、SMMU 只做地址管理" 的关系。
- **AI 配图 prompt（交给图像引擎生成 PNG，务必附文首"AI 生成配图统一风格锚点"）**：
  > *A clean flat-vector horizontal data-path pipeline diagram for an Ethernet switch chip, 6 rounded-rectangle blocks connected left-to-right by dark-gray arrows, labeled in order: "IPS", "PPE", "QM (En-Queue)", "SMMU", "QM (De-Queue)", "EPS". The center block "SMMU" is emphasized with solid deep-blue (#3253DC) fill and white bold label; the two "QM" blocks share the same sky-blue (#6CA0F6) fill to show they are the same unit at enqueue/dequeue stages; other blocks light-gray (#F2F4F8) with dark-gray text. White background, thin 1px stroke, sans-serif labels, minimalist corporate slide style, 16:9, no photo, no 3D.*

---

## 第 2 页：目录 (Agenda)

- **要点（列出章节）**：
  1. 设计背景与定位
  2. 顶层架构与子模块划分
  3. 核心数据结构 (Cell / 链表 / 双池)
  4. 六大工作流程 (初始化/入队/出队/回收/老化/流控)
  5. 关键子模块详解 (LLE / Occupancy / 各 Ctrl / CSR)
  6. 多播 B2 逻辑拼接机制
  7. 流控与告警 (PAUSE / PFC / Aging)
  8. 时序与性能 (1 拍命令式 / 背靠背)
  9. 参数化与可配置性
  10. 总结与展望
- **建议配图**：横向 flow 目录图标

---

## 第 3 页：设计背景 —— MMU 在交换芯片中的位置

- **正文要点**：
  - MMU 是 QM (Queue Manager) 的**地址管理子模块**，所有数据/控制接口对端均为 QM。
  - 职责：以 **256B cell** 为粒度，统一管理 **2MB 共享数据 SRAM** 的地址分配与链表组织。
  - 分工：报文数据由 QM/EPS 搬运；**MMU 只管地址 (指针)**，不搬运报文净荷。
- **建议配图**：数据面 vs 地址面拆分对比图（上下两条并行泳道）
  - **上半泳道（数据面 / Payload path）**：报文净荷从入口经 QM 写入 **2MB 共享数据 SRAM**、出队时由 QM 读出送 EPS；标注 "数据由 QM/EPS 搬运，SMMU 不碰净荷"。数据块用天蓝 `#6CA0F6`。
  - **下半泳道（地址面 / Address path）**：SMMU 分配 cell 地址 → 交 QM → 报文发送后 QM 逐 cell 还地址回 SMMU；标注 "SMMU 只管 256B cell 地址(指针) 的分配/回收/链表"。地址块用主蓝 `#3253DC`。
  - 中间用虚线把 "同一个 cell 的数据(上) 与其地址(下)" 对应起来，突出 "数据与地址分离管理" 的核心思想。
- **AI 配图 prompt（交给图像引擎生成 PNG，务必附文首"AI 生成配图统一风格锚点"）**：
  > *A clean flat-vector technical slide diagram showing "data plane vs address plane" separation of an Ethernet switch buffer manager, arranged as two parallel horizontal lanes. TOP lane (payload path): packet payload flows from ingress through a "QM" block into a large "2MB Shared Data SRAM" block and out to "EPS", drawn in sky-blue (#6CA0F6), labeled "Payload moved by QM/EPS". BOTTOM lane (address path): a "SMMU" block allocates 256B-cell addresses (pointers) to "QM", and recycled addresses return to "SMMU", drawn in deep-blue (#3253DC), labeled "SMMU manages only cell addresses / linked-list". Thin dashed vertical connectors link a data cell in the top lane to its address in the bottom lane. White background, dark-gray (#2E2E38) text and arrows, rounded rectangles with 1px stroke, sans-serif labels, minimalist corporate style, 16:9, no photo, no 3D.*
- **建议表格：容量派生**

  | 项目 | 数值 | 说明 |
  |---|---|---|
  | 共享数据 SRAM | 2 MB | 报文净荷缓存 |
  | Cell 粒度 | 256 B | 管理最小单位 |
  | Cell 总数 CELL_NUM | 8192 | 2MB / 256B |
  | 地址位宽 ADDR_W | 13 | $clog2(8192) |

---

## 第 4 页：核心设计约束 (7 条)

- **正文（逐条列出）**：
  1. 入队 / 出队均严格 **1 拍** (T0 收请求，T1 返回结果，背靠背 1 cell/cycle)。
  2. 同时覆盖**单播与组播** (组播一份 cell 多端口共享，按引用计数回收)。
  3. 占用水位 + 高水位无条件丢弃；PAUSE(802.3x) + PFC(802.1Qbb)；WRED 放在 QM。
  4. 每队列/端口/全局的 **max / near_full** 反馈给 QM 做入队前置门控。
  5. 链表指针存于 **Next-Ptr SRAM** (1 拍读延迟)，用**两级预取寄存器**吸收读延迟。
  6. 缓存双池：**静态预留池** (每队列保底) + **动态共享池**。
  7. CSR 不走 APB/AHB 总线：配置 cfg_in_* 在 clk_core 域已 ready，直接采样。
- **建议配图**：7 个约束图标卡片式排布
- **建议表格：接口分组 (G1~G6) 概览**

  | 组 | 名称 | 方向 | 用途 |
  |---|---|---|---|
  | G1 | 时钟/复位/初始化 | in/out | clk_core, rst_core_n, init_start/done |
  | G2 | 入队/地址分配 | QM↔MMU | enq_req → alloc_cell_addr |
  | G3 | 出队/地址读取 | QM↔MMU | deq_req → deq_cell_addr |
  | G4 | 地址回收 | QM→MMU | recycle_req/ack |
  | G5 | 流控/配置/统计/告警 | 双向 | PAUSE/PFC/CSR/IRQ |
  | G6 | 满/快满反馈 | MMU→QM | q_max_reached / empty |

---

## 第 5 页：顶层架构框图 (smmu.sv)

- **正文要点**：顶层例化 7 个子模块，中心是 LLE (唯一访问 Next-Ptr SRAM)。
- **建议配图（本 PPT 核心图，务必精绘）**：
  - 左侧 QM 接口块，引出 enq / deq / recycle / cfg 三组箭头。
  - 中间 5 大功能块（配色遵循文首视觉风格规范）：
    - `enqueue_ctrl` (青色 `#00C2DE`, 控制面)
    - `dequeue_ctrl` (青色 `#00C2DE`)
    - `recycle_ctrl` (青色 `#00C2DE`)
    - `lle` + 内嵌 `next_ptr_sram_1r1w` (主蓝 `#3253DC`, 存储面，中心)
    - `occupancy_pool_mgr` (天蓝 `#6CA0F6`, 计数+判决)
  - 辅助块：`aging_ctrl` (Accent Green `#3DBB6B`)、`csr_stats_init` (Accent Green `#3DBB6B`, 含 Init FSM)。
  - 标注关键互连信号：occ_query_*、lle_alloc_fire、lle_alloc_evt、lle_free_evt、age_flush_req 等。
- **AI 配图 prompt（交给图像引擎生成 PNG，须与其它配图风格统一，务必附文首"AI 生成配图统一风格锚点"）**：
  > *A clean flat-vector block diagram of a hardware buffer-manager top module ("SMMU") for a slide, corporate minimalist style. Left side: a tall "QM interface" block with three arrow groups labeled "enqueue", "dequeue", "recycle" and a "config" arrow, pointing into the module. Center-right contains 7 rounded-rectangle sub-blocks: a large central block "LLE (Link-List Engine)" in deep-blue (#3253DC) with a small embedded block "Next-Ptr SRAM 1R1W" inside it; three control blocks "enqueue_ctrl", "dequeue_ctrl", "recycle_ctrl" in cyan (#00C2DE); a block "occupancy_pool_mgr" in sky-blue (#6CA0F6); two helper blocks "aging_ctrl" and "csr_stats_init (Init FSM)" in green (#3DBB6B). Draw labeled dark-gray connector arrows between blocks (e.g., alloc_fire from enqueue_ctrl to LLE, alloc_evt/free_evt from LLE to occupancy_pool_mgr, age_flush from aging_ctrl to LLE). White background, thin 1px strokes, sans-serif monospace-style signal labels, high contrast, 16:9, no photo, no 3D, no heavy gradients.*
- **建议表格：子模块职责一句话**

  | 子模块 | 平面 | 职责 |
  |---|---|---|
  | enqueue_ctrl | 控制 | 入队 1 拍命令，整帧丢弃 FSM |
  | dequeue_ctrl | 控制 | 出队 1 拍命令，背压检查 |
  | recycle_ctrl | 控制 | 还链薄透传 |
  | lle | 存储 | 链表引擎，唯一访问 Next-Ptr SRAM |
  | occupancy_pool_mgr | 计数 | 占用计数+双池判决+PAUSE/PFC |
  | aging_ctrl | 控制 | 队列老化冲刷 |
  | csr_stats_init | 配置 | 配置采样+初始化 FSM |

---

## 第 6 页：参数化设计 (Parameterization)

- **正文要点**：所有位宽由 CELL_NUM/PORT_NUM/TC_NUM 派生，各子模块同源，保证一致。
- **建议表格：顶层参数**

  | 参数 | 默认值 | 含义 |
  |---|---|---|
  | CELL_NUM | 8192 | 总 cell 数 (2MB/256B) |
  | PORT_NUM | 4 | 物理出端口数 |
  | TC_NUM | 8 | 每端口 TC 数 |
  | REF_W | 3 | 组播 ref_count 位宽 |
  | STAT_W | 32 | 统计计数器位宽 |
  | PKT_CELL_W | 4 | 本包 cell 数位宽 |

- **建议表格：派生 localparam**

  | 派生量 | 表达式 | 值 (默认) | 含义 |
  |---|---|---|---|
  | QUEUE_NUM | PORT_NUM*TC_NUM+1 | 33 | 32 单播 + 1 多播队列 |
  | ADDR_W | $clog2(CELL_NUM) | 13 | cell 地址位宽 |
  | QID_W | $clog2(QUEUE_NUM-1)+1 | 6 | 队列号位宽 |
  | PORT_W | $clog2(PORT_NUM-1)+1 | 2 | 端口号位宽 |
  | TC_W | $clog2(TC_NUM) | 3 | TC 位宽 |
  | CNT_W | ADDR_W+1 | 14 | 占用计数位宽 |

- **建议配图**：位宽派生依赖关系树 (CELL_NUM → ADDR_W → CNT_W ...)

---

## 第 7 页：为什么用链表？(链表 vs 静态分区) 与链表结构

- **正文要点 —— 为什么必须用链表**：
  - **共享缓存 + 多队列的根本矛盾**：2MB / 256B = 8192 个 cell 要被 33 条队列 (32 单播 + 1 多播) 动态共享；每条队列的长度随流量实时剧烈变化，无法预知。
  - **若用静态分区 (每队列固定一段地址)**：
    - 空间利用率低——某队列空闲的 cell 无法借给拥塞队列，突发流量下大量丢包而缓存却没用满。
    - 不灵活——队列数/配额一旦改动就要重新划分地址。
  - **若用连续 ring buffer**：一段报文必须占连续地址，碎片化后无法利用零散空闲 cell，且组播共享困难。
  - **链表方案的优势**：
    1. **任意 cell 可挂到任意队列**——空闲 cell 组织成一条 free 链，谁要谁取，天然实现"全共享 + 双池"，利用率接近 100%。
    2. **入队/出队都是 O(1)**——只动头尾指针，与队列长度无关，满足背靠背 1 cell/cycle。
    3. **零外部碎片**——cell 定长 256B，回收即回 free 链，永不产生碎片。
    4. **组播零复制友好**——同一条 cell 链可被多端口私有读指针共享遍历 (见多播章节)。
    5. **可扩展**——队列数/容量变化只改参数，链表机制不变。
- **正文要点 —— 链表结构**：
  - 每个 cell 在 **Next-Ptr SRAM** 里有一个 entry：`{next_ptr(13b), pkt_head, pkt_tail}`，即"单向链表节点"。
  - **33 条业务链 + 1 条 free 链**：业务链把同队列报文的 cell 按到达序串起来；free 链把所有空闲 cell 串起来。
  - 入队 = 从 free 链头摘一个 cell 挂到目标队列链尾 (relink 写 old tail.next)；出队 = 从队列链头取 cell 并前进 head；回收 = 把 cell 挂回 free 链尾。
  - 头尾指针 + 计数器 (head/tail/cnt) 全部用寄存器维护，**只有 next 指针存 SRAM**，故访问 SRAM 的只有 LLE。
- **建议配图**：左右对比图
  - 左：静态分区 (固定 8 段地址，部分段满溢丢包、部分段大量空闲) — 打叉/告警红标注"利用率低"。
  - 右：链表共享 (一个 free 链池 + 多条队列链从池中动态取还) — 打勾/绿色标注"全共享 O(1)"。
- **AI 配图 prompt（交给图像引擎生成 PNG，须与其它配图风格统一，务必附文首"AI 生成配图统一风格锚点"）**：
  > *A clean flat-vector comparison slide diagram, two side-by-side panels. LEFT panel titled "Static Partition": a memory bar split into 8 fixed colored segments, two segments overflowing (marked with a small red #E4002B warning) while others are mostly empty (hatched gray), caption "low utilization, inflexible". RIGHT panel titled "Linked-List Sharing": a central pool box labeled "Free List (8192 cells)" in sky-blue (#6CA0F6), with several small chains of connected rounded cells (each cell an arrow to the next) pulled out toward queue labels "Q0..Q31" in deep-blue (#3253DC), a green (#3DBB6B) check mark and caption "full sharing, O(1) enqueue/dequeue". White background, dark-gray (#2E2E38) text and arrows, thin 1px stroke, sans-serif labels, minimalist corporate style, 16:9, no photo, no 3D.*
- **建议表格：链表 vs 其他方案**

  | 方案 | 空间利用率 | 入/出队复杂度 | 碎片 | 组播共享 | 灵活性 |
  |---|---|---|---|---|---|
  | 静态分区 | 低 | O(1) | 无(但浪费) | 难 | 差 |
  | 连续 ring | 中 | O(1) | 有外部碎片 | 难 | 中 |
  | **链表(本设计)** | **高(全共享)** | **O(1)** | **无** | **易** | **好** |

---

## 第 8 页：核心数据结构 (2) —— Cell 与链表组织

- **正文要点**：
  - 全部管理对象是 8192 个 256B cell 的地址。
  - Next-Ptr SRAM 存放每个 cell 的 entry = `{next_ptr(13b), pkt_head(1b), pkt_tail(1b)}` = ENTRY_W = 15 bit。
  - 共 **34 条链** (spec)：
    - `[0..31]` per-(port,TC) 单播队列链 (32 条)
    - `[32] = MC_QID` 多播链
    - `free 链`：独立用寄存器维护 (free_head/tail/cnt)
- **建议配图**：链表节点串联图 (cell A→B→C→NULL，节点标注 ph/pt 位)
- **建议表格：Entry 字段**

  | 字段 | 位宽 | 含义 |
  |---|---|---|
  | next | ADDR_W=13 | 下一 cell 地址 |
  | pkt_head (PH) | 1 | 报文首 cell 标志 |
  | pkt_tail (PT) | 1 | 报文尾 cell 标志 |

---

## 第 9 页：核心数据结构 (3) —— 双池架构

- **正文要点**：
  - **静态预留池**：每队列保底 `cfg_q_min_cell` (guaranteed)，穿透 max 上限。
  - **动态共享池**：超出保底部分落入共享池，受 `cfg_shared_limit` + q/port/global max 约束。
  - 精确记账：`total_static_used = Σ q_static_used`；`shared_used = global_used − total_static_used`。
- **建议配图**：双池水位示意 (配色遵循文首视觉风格规范)
  - 每队列一根柱：下段 Accent Green `#3DBB6B`(静态保底 min)，上段 主蓝 `#3253DC`(共享池占用)，顶部 Alert Red `#E4002B` 虚线(max)。
  - 右侧全局共享池水位 + shared_limit 红色虚线。
- **AI 配图 prompt（交给图像引擎生成 PNG，须与其它配图风格统一，务必附文首"AI 生成配图统一风格锚点"）**：
  > *A clean flat-vector "dual-pool buffer occupancy" bar chart slide diagram. Several vertical bars (one per queue, e.g. Q0..Q5) each split into two stacked segments: lower segment green (#3DBB6B) labeled "static reserved (guaranteed min)", upper segment deep-blue (#3253DC) labeled "dynamic shared pool"; a dashed red (#E4002B) horizontal line across the top of each bar marks the "max" limit, with one bar touching it. On the right, a single tall bar labeled "Global Shared Pool" with a dashed red line marking "shared_limit". Light-gray (#F2F4F8) gridlines, white background, dark-gray (#2E2E38) axis labels, sans-serif, minimalist corporate style, 16:9, no photo, no 3D.*
- **建议表格：判决相关阈值**

  | 阈值 | 配置项 | 语义 |
  |---|---|---|
  | guaranteed | cfg_q_min_cell | 每队列静态保底 |
  | queue max | cfg_q_max_cell | 每队列上限 |
  | port max | cfg_port_max | 每端口上限 |
  | global max | cfg_global_max | 全局上限 |
  | shared limit | cfg_pool_shared_limit | 动态共享池总额度 |

---

## 第 10 页：核心数据结构 (4) —— 队列编号映射

- **正文要点**：
  - 完整队列号 = `egress_port * TC_NUM + tc`。
  - 单播：`full_qid = {enq_egress_port, enq_queue_id}`，范围 0~31。
  - 多播：物理挂 `MC_QID=32`；承载 TC = enq_queue_id，目的端口 = enq_mcast_bitmap。
- **建议配图**：队列编号矩阵 (4 端口 × 8 TC = 32 格 + 1 个 MC 格)
- **建议表格：编号示例**

  | port | tc | full_qid |
  |---|---|---|
  | 0 | 0 | 0 |
  | 0 | 7 | 7 |
  | 1 | 0 | 8 |
  | 3 | 7 | 31 |
  | (多播) | — | 32 (MC_QID) |

---

## 第 11 页：六大工作流程总览

- **正文要点**：一图串起初始化→入队→出队→回收→老化→流控的时间/因果关系。
- **建议配图**：泳道流程图 (纵向泳道：QM / enq / lle / occ / deq / recycle / aging)
  - 时间轴从左到右，标出各流程触发时机与信号交互。
- **建议表格：流程与主责模块**

  | 流程 | 主责模块 | 触发信号 |
  |---|---|---|
  | 初始化建链 | csr_stats_init + lle | init_start |
  | 入队分配 | enqueue_ctrl + occ + lle | enq_req |
  | 出队读取 | dequeue_ctrl + lle | deq_req |
  | 地址回收 | recycle_ctrl + lle + occ | recycle_req |
  | 队列老化 | aging_ctrl + lle | 超时/强制 |
  | 流控告警 | occ + csr | 占用水位 |

---

## 第 12 页：流程 (1) —— 上电初始化 (Init FSM)

- **正文要点** (csr_stats_init)：
  - Init FSM 三态：`IS_IDLE → IS_BUILD → IS_DONE`。
  - init_start 上升沿 → 拉 `init_build_req` (脉冲) + `clr_ptr_cnt` → 命 LLE 建空闲链。
  - LLE 建链 FSM (`ST_IDLE→ST_BUILD→ST_DONE`)：逐 cell 写 `next = idx+1`，最后一 cell next 自指。
  - 建链完成 `init_build_done` → `init_done=1` (保持)，各 Ctrl 才接收请求。
- **建议配图 1**：两个状态机联动图 (CSR Init FSM ↔ LLE Build FSM)，标注 init_build_req / done 握手。
- **建议配图 2（寄存器 + SRAM 值变化举例，交给 AI 生成 PNG，须附文首"AI 生成配图统一风格锚点"）**：
  展示建链过程中 Next-Ptr SRAM 与 free 链寄存器如何被逐 cell 写成一条顺序链。
  > *A clean flat-vector "linked-list build" state illustration for a slide. LEFT: a vertical table titled "Next-Ptr SRAM" with 8 rows addressed 0..7, each row a box showing field "next"; during build each cell's next is written to (addr+1), i.e. row0.next=1, row1.next=2, ... row6.next=7, and the last row7.next=7 (self-loop, highlighted). RIGHT: three small register boxes labeled "free_head_q = 0", "free_head_next_q = 1", "free_head_next2_q = 2", plus "free_tail_q = 7", "free_cnt_q = 8". A downward "build index" pointer sweeps rows 0→7 in deep-blue (#3253DC); written rows filled sky-blue (#6CA0F6), current row highlighted cyan (#00C2DE), the self-loop last row marked with a small red (#E4002B) loop arrow. Caption: "power-up: every cell.next = next cell, free chain 0→1→…→7". White background, dark-gray (#2E2E38) labels and arrows, thin 1px rounded boxes, sans-serif, monospace for signal names, minimalist corporate style, 16:9, no photo, no 3D.*
- **建议表格：初始状态 (以 CELL_NUM=8 举例)**

  | 寄存器 | 初值 (示例) | 说明 |
  |---|---|---|
  | free_head_q | 0 | 空闲链头 (下一个要分配的 cell) |
  | free_head_next_q | 1 | 预取第 2 个空闲 cell |
  | free_head_next2_q | 2 | 预取第 3 个空闲 cell |
  | free_tail_q | 7 (=CELL_NUM-1) | 空闲链尾 |
  | free_cnt_q | 8 (=CELL_NUM) | 全部空闲 |
  | q_head/tail/cnt[*] | 0 | 各队列清空 |
  | SRAM[i].next | i+1 (末 cell 自指) | 建链结果, 顺序串成一条 free 链 |

---

## 第 13 页：流程 (2) —— 入队 / 地址分配 (1 拍命令式)

- **正文要点** (enqueue_ctrl + occ + lle)：
  - **T0**：收 QM `enq_req` → 合成 full_qid → 组合查 Occupancy (occ_query_vld) 当拍返回判决 → 若接收，取 `lle_free_head` 作分配地址、发 1 拍 `lle_alloc_fire`。
  - **T1**：寄存输出 `alloc_valid / alloc_cell_addr / alloc_drop_ind / alloc_pkt_head/tail`。
  - 握手：`enq_ready = init_done & lle_alloc_ready`；deq 抢占 SRAM 时 ready=0，QM 自动重试。
- **建议配图 1**：T0/T1 两拍时序波形
  - 信号：clk, enq_req, occ_query_vld, occ_accept, lle_alloc_fire, alloc_valid, alloc_cell_addr。
- **建议配图 2（挂链时寄存器 + SRAM 值变化举例，交给 AI 生成 PNG，须附文首"AI 生成配图统一风格锚点"）**：
  只针对**一条队列 Q5** 与 **free 链**（不画其它队列）。以"向 Q5 连续挂 3 个 cell A、B、C"为例，用**四列**展示：第 1 列为"入队前初始状态"，后 3 列分别为 Cycle 1/2/3 挂 A/B/C 后的状态。每列展示 Q5 的链寄存器 (head/tail/cnt)、free 链头寄存器 (free_head)、以及 Next-Ptr SRAM 相关行的值。突出 **tail 不在当拍写 SRAM、而是暂存在 `q_tail_q` 寄存器，relink 推迟到下一个 cell 入队那拍**。
  > *A clean flat-vector state-evolution table diagram titled "Enqueue: hanging cells A,B,C onto ONE queue Q5 (and the free chain)", corporate slide style, arranged as FOUR columns left-to-right: Column0 "Init (before enqueue)", Column1 "Cycle1: enqueue A", Column2 "Cycle2: enqueue B", Column3 "Cycle3: enqueue C". Only queue Q5 and the free chain are shown — do NOT draw any other queue. Each column shows the same three grouped items stacked vertically: (a) Q5 link registers box = { q_head_q, q_tail_q, q_cell_cnt_q }; (b) free-chain register box = { free_head_q }; (c) a small "Next-Ptr SRAM" mini-table listing only the relevant rows (A, B, C) with their "next" field. Values per column: Init → Q5 empty (q_head_q=-, q_tail_q=-, cnt=0), free_head_q=A, SRAM rows A/B/C.next all unwritten. Cycle1 (enqueue A, empty queue) → q_head_q=A, q_tail_q=A, cnt=1, free_head_q advances to B, and NO SRAM write this cycle (put a green (#3DBB6B) callout "empty queue: no old tail → nothing written to SRAM"). Cycle2 (enqueue B) → q_tail_q updates A→B (in register only), cnt=2, free_head_q advances to C, and NOW write SRAM row A.next=B (relink previous tail, highlight this write). Cycle3 (enqueue C) → q_tail_q updates B→C, cnt=3, and write SRAM row B.next=C. Use deep-blue (#3253DC) for the SRAM table, sky-blue (#6CA0F6) for register boxes, cyan (#00C2DE) to highlight the just-changed value/row in each column, a persistent green (#3DBB6B) note at the bottom "tail is kept in register q_tail_q; the SRAM relink (old_tail.next = new_cell) is deferred to the NEXT enqueue cycle". White background, dark-gray (#2E2E38) text and arrows, thin 1px rounded boxes, monospace signal names, minimalist corporate style, 16:9, no photo, no 3D.*
- **正文补充 —— 为什么 tail 不在当拍写 SRAM (放专用寄存器 q_tail_q)**：
  - 挂链要做两件事：把新 cell 记为队尾、并把"旧队尾的 next"指向新 cell (relink)。
  - 旧队尾的 next 要写进 SRAM，但**当拍分配新 cell 时并不知道再下一个 cell 是谁**，而且 SRAM 每拍只有 1 个写口，还要留给别的事务。
  - 做法：队尾地址 `q_tail_q`、尾部头尾标志 `q_tail_ph_q/pt_q` 全部**先存寄存器**；真正的 relink (写 `SRAM[旧tail].next = 新cell`) 推迟到**下一个 cell 入队那一拍**顺便完成 (`npr_w_addr = q_tail_q`)。
  - 好处：① 空队列挂第 1 个 cell 时根本不用写 SRAM (没有旧 tail)；② 每拍最多一次 SRAM 写，避免写口冲突；③ tail 在寄存器里组合可读，出队/统计都能当拍拿到，无需读 SRAM。
- **建议表格：入队判决输入/输出**

  | 信号 | 方向 | 含义 |
  |---|---|---|
  | enq_req/sof/eof | in | 请求与报文边界 |
  | enq_cell_num | in | 本包 cell 数(预判用) |
  | enq_predict_drop | out | 入队前整包预判 |
  | alloc_cell_addr | out | 分配地址 |
  | alloc_drop_ind | out | 丢包指示 |

- **建议表格：挂链到 Q5 的寄存器/SRAM 值演进 (初始 + A→B→C，共四列对应配图)**

  | 状态 | 动作 | q_head_q | q_tail_q | q_cell_cnt | free_head_q | 本拍 SRAM 写 |
  |---|---|---|---|---|---|---|
  | 初始 | 入队前 (空队列) | — | — | 0 | A | — |
  | Cycle 1 | 挂 A (空队列) | A | A | 1 | B | 无 (无旧 tail) |
  | Cycle 2 | 挂 B | A | B | 2 | C | SRAM[A].next=B |
  | Cycle 3 | 挂 C | A | C | 3 | D | SRAM[B].next=C |

---

## 第 14 页：流程 (2 续) —— 整帧丢弃 FSM 与入队前预判

- **正文要点**：
  - **入队前整包预判** (occ_predict_drop)：SOF 拍给本包 cell 数，占位判断整包能否放下 (free 够 + 静态额度或 max 满足 + 共享池够)。
  - **整帧丢弃 FSM** (frame_drop_q)：帧内任一 cell 判丢 → 置位保持到 EOF，本帧后续 cell 全丢，避免"半挂链遗留"。
  - 丢弃来源：occ_drop / occ_no_free / lle_free_empty / (SOF & predict_drop) / 多播槽占用。
- **建议配图**：帧级丢弃状态图 (SOF 判丢 → 保持 → EOF 清除)
- **建议表格：cell_drop_c 判定优先级**

  | 优先级 | 条件 | 动作 |
  |---|---|---|
  | 1 | frame_drop_q=1 | 后续全丢 |
  | 2 | occ_drop/no_free/free_empty | 丢 |
  | 3 | SOF & predict_drop | 整帧丢 |
  | 4 | occ_accept | 接收挂链 |
  | 5 | 兜底(无明确) | 保守丢 |

---

## 第 15 页：流程 (3) —— 出队 / 地址读取

- **正文要点** (dequeue_ctrl + lle)：
  - **T0**：收 `deq_req` + 背压检查 → 取 `lle_qhead` (队头寄存器组合可读) 作出队地址、发 1 拍 `lle_deq_fire`。
  - **T1**：输出 `deq_cell_valid / deq_cell_addr / deq_pkt_head/tail`。
  - `deq_fire = deq_req & deq_ready & ~lle_q_empty & ~port_bp`。
  - 队头推进 + 预取由 LLE 流水完成；`deq_backpressure[port]` 暂停该端口对应队列。
- **建议配图 1**：出队两拍时序 + 队头前进示意 (head→next)
- **建议配图 2（出队时寄存器 + SRAM 值变化举例，交给 AI 生成 PNG，须附文首"AI 生成配图统一风格锚点"）**：
  以"队列 Q5 链为 A→B→C→D (cnt=4)，连续出队"为例，分帧展示队头三级预取寄存器 (head/head_next/head_next2) 如何滑动、以及后台读 SRAM 回填最远一级。突出"队头在寄存器里，出队地址当拍即给，不等 SRAM"。
  > *A clean flat-vector 3-frame step diagram titled "Dequeue: advancing head on queue Q5 (chain A→B→C→D)", corporate slide style, left-to-right frames. In each frame show a register group { q_head_q, q_head_next_q, q_head_next2_q, q_cell_cnt_q } and a small "Next-Ptr SRAM" read box. Frame1 (before): head=A, next=B, next2=C, cnt=4; a background SRAM read of C.next is issued. Frame2 "pop A": head=B, next=C, next2=D (D just came back from SRAM), cnt=3, output deq_addr=A; new background read D.next issued. Frame3 "pop B": head=C, next=D, next2=? (chain end soon), cnt=2, output deq_addr=B. Use sky-blue (#6CA0F6) for the three prefetch registers, cyan (#00C2DE) to highlight the sliding value each frame, deep-blue (#3253DC) for SRAM read, a green (#3DBB6B) callout "head is in a register → dequeue address available same cycle, SRAM read only refills the far level in background". White background, dark-gray (#2E2E38) text/arrows, thin 1px rounded boxes, monospace signal names, minimalist, 16:9, no photo, no 3D.*
- **建议表格：出队握手条件**

  | 条件 | 说明 |
  |---|---|
  | deq_req & deq_ready | 请求有效且已初始化 |
  | ~lle_q_empty | 队列非空 |
  | ~port_bp | 该端口未背压 |

- **建议表格：Q5 连续出队的队头预取寄存器演进 (链 A→B→C→D)**

  | 拍 | 动作 | q_head_q | q_head_next_q | q_head_next2_q | 后台 SRAM 读 | deq_addr(T1) |
  |---|---|---|---|---|---|---|
  | 1 | 出 A | A | B | C | 读 C.next(→D) | — |
  | 2 | 出 B | B | C | D | 读 D.next | A |
  | 3 | 出 C | C | D | (链尾) | — | B |

---

## 第 16 页：流程 (4) —— 地址回收 (统一还链)

- **正文要点** (recycle_ctrl + lle + occ)：
  - QM 逐 cell 还链，统一接口不区分单播/多播 (`recycle_req/cell_addr/queue_id/is_mcast`)。
  - recycle_ctrl 只做**薄透传**：合成 full_qid 后送 LLE。
  - 单播：直接 push 回 free 链，occ 用其 queue_id `--`。
  - 多播：按 cell 引用计数 (ref-count)，每次还链 `--`，减到 0 才真正 push，occ 用 MC_QID。
  - occupancy 的 free 事件由 LLE 在真正 push 那拍产生 (与 free_cnt 同拍)。
- **建议配图 1**：单播还链 vs 多播 ref-count 还链对比图
- **建议配图 2（还链时寄存器 + SRAM 值变化举例，交给 AI 生成 PNG，须附文首"AI 生成配图统一风格锚点"）**：
  以"把 cell X 还回 free 链"为例，展示两阶段：① X 先进 recycle FIFO；② FIFO pop 时写 `SRAM[旧free_tail].next = X`、并把 `free_tail_q` 更新为 X。与入队"tail 暂存寄存器、下拍 relink"完全对称。
  > *A clean flat-vector 2-stage step diagram titled "Recycle: returning cell X to the free chain", corporate slide style, left-to-right. Stage1 "accept": a "recycle FIFO" (depth-8 boxes) receives cell X into its tail; register "free_tail_q = T" unchanged yet; a note "free_cnt++ on push (counts as available immediately)". Stage2 "append to free tail": FIFO head X popped; a "Next-Ptr SRAM" row shows write SRAM[T].next = X (relink old free tail), and register free_tail_q updates T→X. Use sky-blue (#6CA0F6) for FIFO and registers, deep-blue (#3253DC) for SRAM, cyan (#00C2DE) to highlight the changed values (free_tail_q T→X and SRAM[T].next=X), a green (#3DBB6B) callout "symmetric to enqueue: old tail kept in register, SRAM relink deferred to the append cycle". White background, dark-gray (#2E2E38) text/arrows, thin 1px rounded boxes, monospace signal names, minimalist, 16:9, no photo, no 3D.*
- **正文补充 —— 还链与入队对称的 tail 寄存器处理**：
  - free 链的尾 `free_tail_q` 同样存在寄存器里；还链 pop 那拍才写 `SRAM[free_tail_q].next = X` 并更新 `free_tail_q ← X`。
  - 这和入队侧"队尾 relink 推迟到下一拍"是同一手法：**tail 放寄存器、SRAM 写延迟到确有后继那拍**，保证每拍至多一次 SRAM 写、且空链追加时无需读旧 tail 的 SRAM。
- **建议表格：还链路径**

  | 类型 | ref 处理 | push 时机 | occ 计数 |
  |---|---|---|---|
  | 单播 | 无 | 立即 | queue_id |
  | 多播 | 每次 -1 | 减到 0 | MC_QID |

- **建议表格：还 cell X 的两阶段寄存器/SRAM 演进 (原 free_tail=T)**

  | 阶段 | 动作 | recycle FIFO | free_tail_q | SRAM 写 |
  |---|---|---|---|---|
  | 1 接收 | X 入 FIFO, free_cnt++ | 尾部压入 X | T (不变) | 无 |
  | 2 落链 | FIFO pop X | 弹出 X | T → X | SRAM[T].next=X |

---

## 第 17 页：关键子模块 (1) —— LLE 链表引擎 (架构)

- **正文要点** (lle.sv, ~1100 行，核心)：
  - MMU **存储访问平面核心**：唯一访问 Next-Ptr SRAM (1R1W)。
  - 服务三方：Enqueue (分配挂链) / Dequeue (出队推进) / Recycle (还链)。
  - **两级预取寄存器**：q_head, q_head_next, q_head_next2 (以及 free 链同构)，吸收 SRAM 1 拍读延迟，保证背靠背 1 cell/cycle。
  - **Recycle FIFO** (RCY_FIFO_DEPTH=8)：缓冲还链 cell，串行 push 回 free 链尾。
- **建议配图**：LLE 内部框图
  - Next-Ptr SRAM + 三级预取寄存器 + free 链寄存器 + Recycle FIFO + 多播槽 + 3 个 FSM (build/agf/主更新)。
- **建议表格：LLE 主要寄存器组**

  | 寄存器组 | 作用 |
  |---|---|
  | q_head/tail/cnt[QUEUE_NUM] | 各队列链表头尾与计数 |
  | q_head_next/next2 | 两级预取 |
  | free_head/tail/cnt | 空闲链 |
  | mc_* (多播槽) | 单槽多播状态 |
  | rcy_fifo_* | 还链缓冲 |

---

## 第 18 页：关键子模块 (1 续) —— LLE 三选一仲裁与 SRAM 读写

- **正文要点**：
  - SRAM 读写口在 deq / enq / rcy / build / age-flush 间仲裁。
  - 优先级：空闲时 **deq > enq > rcy**；一旦 enq 被 grant 且报文未到 EOF，**锁住该 packet** (enq_pkt_lock_q) 直到 EOF，期间 deq/rcy 不打断。
  - age-flush 读 next 最低优先级 (仅在正常 deq/enq 不占读口的空拍推进)。
  - relink：enq 时写 OLD tail.next 指向新 cell (单播链与多播链同构，都写 SRAM)。
- **建议配图**：仲裁优先级树 + SRAM 读写口时分复用时序
- **建议表格：仲裁 grant 条件**

  | 事务 | grant 条件 |
  |---|---|
  | deq_grant | deq_req_int & ~enq_pkt_lock |
  | enq_grant | enq_req_int & ~build & ~deq_need_sram |
  | rcy_grant | rcy_req_int & ~build & ~deq_need_sram & ~enq_grant |
  | agf_rd_gnt | AGF_RD & 读口空闲 |

---

## 第 19 页：关键子模块 (1 续) —— 两级预取吸收 SRAM 读延迟

- **正文要点**：
  - Next-Ptr SRAM 有 1 拍读延迟，若每次出队都读 SRAM 拿 next，无法背靠背。
  - 方案：队头维护 head / head_next / head_next2 三级；出队时 head←head_next，同时用空拍读 SRAM 回填 next2。
  - `deq_need_sram` 仅当 cnt≥3 时置位 (前两级已在预取寄存器)。
  - pend 流水寄存器 (deq_pend_q / enq_pend_q) 处理 T+1 回填与同队列连续出队的 bypass。
- **建议配图**：出队时预取寄存器滑动窗口动画式 3 帧图 (cycle N / N+1 / N+2)
- **建议表格：预取寄存器状态转移** (以连续出队为例，列出 head/next/next2 每拍值)

---

## 第 20 页：关键子模块 (2) —— Occupancy & Pool Manager

- **正文要点** (occupancy_pool_mgr.sv)：
  - 维护计数：free_count / global_used / q_cell_cnt[q] / q_static_used[q] / per_port_used[p]。
  - 事件驱动：LLE alloc 事件 `++`，LLE free 事件 `--`；同拍 alloc+free 净不变处理。
  - **Drop 判决核心**：`occ_drop = 空闲池空 | (非静态穿透 & 命中任一 max)`；max = q/port/global/shared 任一命中。
  - 双池精确记账：`shared_used = global_used − Σ q_static_used`。
- **建议配图**：占用计数与判决数据流图 (alloc/free 事件 → 计数器 → 阈值比较 → drop/max_reached/pause/pfc)
- **建议表格：计数器与守恒**

  | 计数器 | 增 | 减 | 守恒关系 |
  |---|---|---|---|
  | free_count | recycle push | alloc | free+global_used=CELL_NUM |
  | global_used | alloc | recycle | 同上 |
  | q_cell_cnt[q] | alloc(q) | free(q) | Σ ≈ global_used |
  | q_static_used[q] | alloc且穿静态 | free且静态非空 | ≤ q_min_cell |

---

## 第 21 页：关键子模块 (2 续) —— PAUSE / PFC 双阈值迟滞

- **正文要点**：
  - **PAUSE (802.3x)** 端口级：`pause_set = 端口占用≥XOFF | 全局≥XOFF`；`pause_clr = 端口<XON & 全局<XON`；中间区保持 (迟滞)。
  - **PFC (802.1Qbb)** per-(port,TC)：`per_tc_used = q_cell_cnt[port*TC+tc]`；同样 XOFF/XON 双阈值迟滞。
  - 使能位 cfg_pause_en / cfg_pfc_en 关断时强制清 0。
- **建议配图**：迟滞回环曲线 (X 轴占用, Y 轴 pause_req, XON/XOFF 之间保持)
- **建议表格：流控阈值**

  | 机制 | XOFF (触发) | XON (撤销) | 粒度 |
  |---|---|---|---|
  | PAUSE 端口 | cfg_port_pause_xoff | cfg_port_pause_xon | port |
  | PAUSE 全局 | cfg_global_pause_xoff | cfg_global_pause_xon | global |
  | PFC | cfg_pfc_xoff | cfg_pfc_xon | port×TC |

---

## 第 22 页：多播 B2 逻辑拼接 (1) —— 模型概述

- **正文要点** (lle.sv B2 多播模型)：
  - **单槽**：mc_valid=1 时拒收新多播 (enqueue_ctrl 靠 mc_busy 整帧 drop)。
  - **零复制**：多播数据只存一份 (chain33 在 SRAM 唯一一条链)；`mc_cells_q[]` 是读加速镜像。
  - **逐端口私有读指针**：每目的端口 `mc_rd_idx_q[p]` 独立遍历同一份 chain33 (只读，不推进队头)。
  - **逻辑插入位置锚定**：SOF 到达时快照各目的端口"承载单播队列"的完整包 backlog `mc_pend_uni_q[p]`；出完一个前序单播包 -1；减到 0 且多播未读完 → 该端口下一个包切多播 cell-list。
- **建议配图**：多播单槽 + 4 端口私有读指针共享一条 chain33 的示意
- **建议表格：多播槽状态寄存器**

  | 寄存器 | 含义 |
  |---|---|
  | mc_valid_q | 槽占用 |
  | mc_dst_bitmap_q | 目的端口位图 |
  | mc_carry_qid_q[p] | 各端口承载单播 QID |
  | mc_cells_q[] | cell 地址列表(报文序) |
  | mc_rd_idx_q[p] | 各端口读指针 |
  | mc_pend_uni_q[p] | 前序待出单播包数 |
  | mc_ref_cnt_q[i] | 各 cell 待还端口数 |

---

## 第 23 页：多播 B2 逻辑拼接 (2) —— 承载队列与出队拼接

- **正文要点**：
  - 承载队列号：`carry_qid[p] = p*TC_NUM + mcast_tc` (多播帧只有一个 TC，在每个目的端口落到该 TC 队列)。
  - 出队判定：`mc_take_deq = is_carry_deq & (mc_ncell≠0) & (mc_pend_uni[deq_port]==0)`。
  - 多播 take 出队：只推进该端口 `mc_rd_idx_q[p]`，不减 MC_QID 的 cnt (多端口共享读)。
  - QM 视角：始终只对 32 条单播队列发出队，MMU 在承载队列上"拼接"出多播报文。
- **建议配图**：某端口出队序列 (前序单播包... → pend_uni 减到 0 → 拼接多播 cell 序列 → 恢复单播)
- **建议表格：单播 vs 多播出队差异**

  | 项目 | 单播出队 | 多播 take |
  |---|---|---|
  | 队头推进 | 是 | 否 |
  | cnt-- | 是 | 否 |
  | 读指针 | q_head 链 | mc_rd_idx[p] |
  | 数据副本 | 各自一份 | 共享一份 |

---

## 第 24 页：多播 B2 逻辑拼接 (3) —— 引用计数回收与整帧释放

- **正文要点**：
  - 每 cell 引用计数初值 = 目的端口数 N (= popcount(bitmap))。
  - QM 逐 cell 还链，地址匹配命中某 slot 且 ref>0 → 该 slot `ref--`；减到 0 (mc_rcy_last) 才真正 push 回 free 链。
  - 整帧全部 cell ref=0 (mc_all_freed) → 清多播槽，允许收下一条多播。
  - `mcast_underflow` 告警：声称多播但地址未命中任何 ref>0 slot。
- **建议配图**：ref-count 递减 → 归零 push → 整帧释放 时序图
- **建议表格：多播回收关键信号**

  | 信号 | 含义 |
  |---|---|
  | mc_rcy_hit | 命中多播 cell |
  | mc_rcy_last | 命中 slot 递减后归 0 |
  | mc_all_freed | 整帧全部 cell 已还 |
  | mcast_underflow | 未命中的多播还链告警 |

---

## 第 25 页：流程 (5) —— 队列老化 (Aging)

- **正文要点** (aging_ctrl + lle age-flush)：
  - 每队列一个老化计时器：队列有占用但长时间未被出队服务 → 判为"僵尸队列"，超时 `cfg_aging_timeout` 触发老化。
  - 喂狗：该队列出队 fire (deq_fire) 或队列已空 → 计时清零；软件强制 cfg_age_force 可直接触发。
  - RR 仲裁一次只冲刷一条队列 (age_flush_req + qid)；等 LLE `age_flush_done` 再服务下一条。
  - LLE age-flush walk FSM (`AGF_IDLE→RD→PUSH→DONE`)：逐 cell 摘链还回 free；冲刷 MC_QID 额外清多播槽。
  - 老化完成 aging_notify 通知 QM 同步清账。
- **建议配图**：老化计时器 + RR 仲裁 + LLE flush FSM 联动图
- **建议表格：aging_ctrl 状态机**

  | 状态 | 动作 |
  |---|---|
  | AG_IDLE | 找到 trig 队列→AG_FLUSH |
  | AG_FLUSH | 发 flush_req，等 busy/done |
  | AG_WAIT | 等 flush_done→notify |

---

## 第 26 页：流程 (6) —— 满/快满反馈与告警

- **正文要点**：
  - **满/快满反馈** (MMU→QM)：q_max_reached[33] / port_max_reached[4] / global_max_reached；q_empty[32] / q_pkt_empty[32] 供 QM 调度。
  - **告警**：overflow_alarm (cell 池溢出) / underflow_alarm (守恒破坏或下溢 + 多播 ref 下溢)；irq_alarm / irq_aging 由 csr 聚合。
  - 守恒校验：`free_count + global_used == CELL_NUM`，破坏即 underflow。
- **建议配图**：反馈/告警信号汇聚图 (occ → csr → IRQ / QM)
- **建议表格：告警来源**

  | 告警 | 来源 | 触发条件 |
  |---|---|---|
  | overflow_alarm | occ | global_used > CELL_NUM |
  | underflow_alarm | occ + lle | 守恒破坏/下溢/mcast_underflow |
  | irq_alarm | csr | overflow \| underflow |
  | irq_aging | aging_ctrl | 有队列老化 |

---

## 第 27 页：配置平面 (CSR) —— 无总线直采

- **正文要点** (csr_stats_init.sv)：
  - **不实现 APB/AHB 总线**：配置寄存器由外部 SoC 顶层维护，cfg_in_* 在 clk_core 域已 ready，本模块寄存一拍去毛刺后下发。
  - 顶层标量配置 → 数组 fanout：全片各队列/端口/TC 共用同一套阈值 (顶层用标量端口，内部 fanout 成数组)。
  - 统计输出经寄存一拍直出 (当前部分统计由 occ 产出，其余置 0 占位)。
- **建议配图**：配置流 (外部 CSR → cfg_in_* → 寄存一拍 → fanout → occ/aging)
- **建议表格：主要配置项分类**

  | 类别 | 配置项 |
  |---|---|
  | 缓存阈值 | q_min/q_max/port_max/global_max/shared_limit |
  | PAUSE | pause_en/port_xoff/xon/global_xoff/xon |
  | PFC | pfc_en/pfc_xoff/pfc_xon |
  | 老化 | aging_en/aging_timeout/age_force |

---

## 第 28 页：时序与性能

- **正文要点**：
  - 全模块 clk_core 300 MHz 单时钟域，无 CDC。
  - 入队/出队严格 1 拍命令式 (T0 收/判，T1 输出)，背靠背 1 cell/cycle 吞吐。
  - 两级预取寄存器 + pend 流水 + SRAM 时分复用仲裁保证不停顿 (deq 优先，enq packet 锁定)。
  - 关键路径：occ 组合判决 (T0 当拍返回) 需注意时序收敛。
- **建议配图**：满负载背靠背入队+出队+回收同时进行的综合时序波形
- **建议表格：性能指标**

  | 指标 | 值 |
  |---|---|
  | 时钟频率 | 300 MHz |
  | 入队吞吐 | 1 cell/cycle |
  | 出队吞吐 | 1 cell/cycle |
  | 入队延迟 | 1 拍 (T0→T1) |
  | SRAM 读延迟 | 1 拍 (预取吸收) |

---

## 第 29 页：设计亮点总结

- **正文要点 (Bullet)**：
  1. **1 拍命令式** 入队/出队，背靠背满吞吐。
  2. **两级预取** 完美吸收 Next-Ptr SRAM 读延迟。
  3. **双池架构** (静态保底 + 动态共享)，兼顾公平与利用率。
  4. **B2 多播逻辑拼接**：单槽 + 零复制 + 逐端口私有读指针 + ref-count 回收，节省 SRAM。
  5. **完善流控**：PAUSE/PFC 双阈值迟滞 + 入队前整包预判 + 整帧丢弃 FSM。
  6. **自主老化** 防僵尸队列。
  7. **全参数化**，位宽同源派生。
  8. **无总线配置平面**，简化集成。
- **建议配图**：8 个亮点雷达图/卡片

---

## 第 30 页：验证与展望 (可选)

- **正文要点**：
  - 已有 testbench：`tb/smmu_tb.sv` (可展示覆盖场景：初始化、单播入队出队、多播、回收、老化、流控、守恒断言)。
  - 待完善：部分统计计数器占位、mcast_refcount_mgr 已被 B2 单槽模型取代。
  - 后续：多播多槽扩展、更细的 WRED 联动 (QM 侧)、DFT/DFV 覆盖率。
- **建议表格：验证场景清单**

  | 场景 | 关注点 |
  |---|---|
  | 上电初始化 | free 链构建、init_done |
  | 单播满负载 | 背靠背 1 cell/cycle |
  | 多播拼接 | 逐端口读、ref 回收 |
  | 高水位丢弃 | max/predict/整帧 drop |
  | 队列老化 | 超时 flush、清账 |
  | 守恒断言 | free+used=CELL_NUM |

---

## 第 31 页：Q&A / 结束

- **要点**：谢谢 + 联系方式 + 附录索引 (RTL 文件清单)
- **建议表格：RTL 文件清单**

  | 文件 | 行数 | 说明 |
  |---|---|---|
  | smmu.sv | ~626 | 顶层 |
  | lle.sv | ~1113 | 链表引擎 (核心) |
  | occupancy_pool_mgr.sv | ~570 | 占用/双池/流控 |
  | enqueue_ctrl.sv | ~240 | 入队控制 |
  | dequeue_ctrl.sv | ~108 | 出队控制 |
  | recycle_ctrl.sv | ~82 | 回收控制 |
  | aging_ctrl.sv | ~244 | 老化控制 |
  | csr_stats_init.sv | ~297 | 配置/初始化 |

---

# 附：绘图与制作建议

- **配色约定 (视觉风格规范)**：数据/存储面 = 主蓝 `#3253DC` / 天蓝 `#6CA0F6`，控制面 = 青色 `#00C2DE`，配置/统计面 = Accent Green `#3DBB6B`，告警/丢弃 = Alert Red `#E4002B`；正文文字用中性深灰 `#2E2E38`，底纹用浅灰 `#F2F4F8`。字体见文首"视觉风格规范"(标题 Arial Bold/思源黑体 Bold，正文 Regular，信号名用等宽 Consolas)。**注意成品 PPT 不出现任何品牌名称字样。**
- **需要 AI 生成 PNG 的配图**：第 1 页(主链路)、第 3 页(数据面/地址面)、第 5 页(顶层框图)、第 7 页(链表 vs 分区)、第 9 页(双池水位)——各页已附独立 prompt，且都须拼接文首"AI 生成配图统一风格锚点"以保证多张图风格统一。
- **必绘核心图 (优先级)**：
  1. 第 5 页 顶层架构框图 (最重要)
  2. 第 7 页 为什么用链表 (对比图)
  3. LLE 内部 + 仲裁 + 两级预取
  4. 多播 B2 三张图
  5. 入队/出队两拍时序、第 9 页双池水位图
- **动画建议**：入队/出队时序、预取寄存器滑窗、多播拼接可用逐步出现动画分步讲解。
- **讲解节奏**：背景(3~5min) → 架构(5min) → 流程(10min) → LLE 深挖(8min) → 多播(6min) → 流控/老化(5min) → 总结(3min)。