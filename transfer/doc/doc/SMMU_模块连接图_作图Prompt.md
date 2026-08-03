# SMMU 模块连接图 — 作图 Prompt

> 用途：把下面这段完整 prompt 复制给作图 AI（如 GPT-4o / Nano Banana / Mermaid / draw.io AI / Excalidraw AI 等），生成一张 **SMMU（Smart MMU）模块连接框图**。
> 说明文字用中文写给你看，但**图片内部所有文字、模块名、信号名一律使用英文**。

---

## 一、给作图 AI 的完整 Prompt（可直接整段复制）

```
Please draw a clean, professional block-connection diagram of a hardware module named "SMMU (Smart MMU)" for a 4-port Ethernet switch. 

ALL TEXT INSIDE THE IMAGE MUST BE IN ENGLISH (module names, signal names, group labels, arrows). Do NOT use any Chinese characters inside the picture.

=== OVERALL LAYOUT ===
Draw a large rounded rectangle titled "SMMU (Smart MMU) — Shared SRAM Address Management" as the top-level boundary.
Outside on the LEFT side put two external actor blocks:
  - "QM (Queue Manager)"  -> connects to enqueue_ctrl and dequeue_ctrl
  - "EPS (Egress Packet Scheduler)" -> connects to recycle_ctrl
Outside on the RIGHT-BOTTOM put an external actor block "MAC".
The CSR/config/statistics/interrupt signals do NOT connect to a separate external block; draw them going directly to the TOP-LEVEL boundary edge of SMMU (i.e. top-level ports of the SMMU module).
Inside the big boundary, place 7 sub-module boxes and connect them with directional arrows.

=== 7 INTERNAL SUB-MODULES (boxes) ===
1. enqueue_ctrl   (label: "Enqueue Ctrl — 1-cycle alloc + drop FSM")
2. dequeue_ctrl   (label: "Dequeue Ctrl — 1-cycle read + backpressure")
3. recycle_ctrl   (label: "Recycle Ctrl — unicast free / mcast ref-count")
4. lle            (label: "LLE — Link-List Engine (owns Next-Ptr SRAM)")
5. occupancy_pool_mgr (label: "Occupancy & Pool Mgr — dual-pool + PAUSE/PFC")
6. aging_ctrl     (label: "Aging Ctrl — timeout flush")
7. csr_stats_init (label: "CSR / Stats / Init FSM — no bus, direct sample")

Suggested internal placement:
- Left column (top→bottom): enqueue_ctrl, dequeue_ctrl, recycle_ctrl
- Center: lle  (this is the hub, make it slightly larger)
- Right-top: occupancy_pool_mgr
- Right-bottom: aging_ctrl
- Bottom: csr_stats_init (spanning the config/stats connections)

=== EXTERNAL INTERFACE ARROWS (QM / EPS / MAC / SMMU top-level ports) ===
QM --> enqueue_ctrl : "enq_req / enq_queue_id / enq_egress_port / enq_cell_num / enq_is_mcast / enq_mcast_bitmap / enq_sof / enq_eof"
enqueue_ctrl --> QM : "enq_ready / enq_predict_drop / alloc_valid / alloc_cell_addr / alloc_drop_ind / alloc_pkt_head / alloc_pkt_tail / enq_q_cell_cnt / enq_free_count"
QM --> dequeue_ctrl : "deq_req / deq_queue_id / deq_egress_port / deq_backpressure"
dequeue_ctrl --> QM : "deq_ready / deq_cell_valid / deq_cell_addr / deq_pkt_head / deq_pkt_tail"
EPS --> recycle_ctrl : "recycle_req / recycle_cell_addr / recycle_queue_id / recycle_egress_port / recycle_is_mcast"
recycle_ctrl --> EPS : "recycle_ack"
occupancy_pool_mgr --> QM : "q_max_reached / port_max_reached / global_max_reached"
lle --> QM : "q_empty / q_pkt_empty"
occupancy_pool_mgr --> MAC : "pause_req (802.3x) / pfc_req (802.1Qbb)"
[SMMU top-level ports] --> csr_stats_init : "init_start / cfg_in_* (thresholds, PAUSE/PFC/aging config)"
csr_stats_init --> [SMMU top-level ports] : "init_done / irq_alarm / irq_aging / st_out_* (statistics)"
(Note: CSR-related signals are top-level ports of SMMU — route them straight to the SMMU boundary edge, NOT to a separate external block.)

=== INTERNAL INTER-MODULE ARROWS (with signal names + direction) ===
[enqueue_ctrl <-> occupancy_pool_mgr]
enqueue_ctrl --> occupancy_pool_mgr : "occ_query_vld / occ_query_queue_id / occ_query_egress_port / occ_query_cell_num"
occupancy_pool_mgr --> enqueue_ctrl : "occ_accept / occ_drop / occ_use_static / occ_no_free / occ_predict_drop / occ_free_count / occ_q_cell_cnt"

[enqueue_ctrl <-> lle]  (allocation)
lle --> enqueue_ctrl : "lle_free_head / lle_free_empty / lle_alloc_ready / mc_busy"
enqueue_ctrl --> lle : "lle_alloc_fire / lle_alloc_queue_id / lle_set_pkt_head / lle_set_pkt_tail / lle_alloc_is_mcast / lle_alloc_mcast_bitmap / lle_alloc_mcast_tc"

[dequeue_ctrl <-> lle]  (read/dequeue)
dequeue_ctrl --> lle : "lle_deq_queue_id / lle_deq_fire"
lle --> dequeue_ctrl : "lle_qhead / lle_qhead_pkt_head / lle_qhead_pkt_tail / lle_q_empty"

[recycle_ctrl <-> lle]  (free / return to list)
recycle_ctrl --> lle : "lle_free_req / lle_free_addr / lle_free_queue_id / lle_free_is_mcast"
lle --> recycle_ctrl : "lle_free_grant / lle_free_done"

[lle -> occupancy_pool_mgr]  (occupancy events)
lle --> occupancy_pool_mgr : "lle_alloc_evt / evt_queue_id / evt_egress_port  (per-queue/port ++)"
lle --> occupancy_pool_mgr : "lle_free_evt / evt_free_queue_id / evt_free_egress_port  (per-queue/port --)"

[lle <-> aging_ctrl]  (aging flush)
lle --> aging_ctrl : "q_occupied_vec / deq_fire_evt / deq_fire_qid"
aging_ctrl --> lle : "age_flush_req / age_flush_qid"
lle --> aging_ctrl : "age_flush_busy / age_flush_done"

[csr_stats_init -> occupancy_pool_mgr]  (config fanout)
csr_stats_init --> occupancy_pool_mgr : "cfg_q_min_cell / cfg_q_max_cell / cfg_port_max / cfg_global_max / cfg_pause_en / cfg_pfc_* / cfg_*_pause_*"
occupancy_pool_mgr --> csr_stats_init : "st_* statistics / overflow_alarm / underflow_alarm"

[csr_stats_init -> aging_ctrl]
csr_stats_init --> aging_ctrl : "cfg_aging_en / cfg_aging_timeout / cfg_age_force"
aging_ctrl --> csr_stats_init : "aging_irq"

[csr_stats_init -> lle]  (init build)
csr_stats_init --> lle : "init_build_req / clr_ptr_cnt"
lle --> csr_stats_init : "init_build_done"

Also show a small internal SRAM icon inside "lle" labeled "Next-Ptr SRAM (1-cycle read)".

=== COLOR SCHEME (use these exact hues, gradient/flat both OK) ===
Use a modern blue palette (matching the reference swatches):
- Primary deep blue  : #2A5BE0  (top-level boundary title bar, main module headers)
- Cyan-blue accent    : #17B8E0  (data-path arrows: enqueue/dequeue/alloc/free)
- Light blue          : #6B9BF2  (control/config arrows, sub-module fill)
- Background          : white or very light gray #F5F8FF
- Text                : dark navy #0A1F44 for readability
Datapath signals (alloc/dequeue/free/cell address) => use cyan-blue accent arrows.
Config/statistics/interrupt signals => use light-blue arrows.
Keep line labels small but legible; group parallel signals with "/" separators as shown.

=== STYLE ===
Flat, clean, engineering block-diagram style (like a datasheet architecture figure). 
Rounded rectangles, orthogonal (right-angle) connector lines, arrowheads clearly show direction.
Add a small legend at bottom-right: 
  - cyan-blue line = "Datapath (address/cell)"
  - light-blue line = "Config / Stats / Control"
16:9 landscape orientation, high resolution.
```

---

## 二、配色速查（供你核对，图内用英文标注）

| 用途 | 颜色 | HEX |
|------|------|-----|
| 顶层边框标题 / 主模块头 | 深蓝 (Primary deep blue) | `#2A5BE0` |
| 数据通路箭头 (alloc/deq/free/cell addr) | 青蓝 (Cyan-blue accent) | `#17B8E0` |
| 控制/配置箭头 + 子模块填充 | 浅蓝 (Light blue) | `#6B9BF2` |
| 背景 | 极浅蓝灰 | `#F5F8FF` |
| 文字 | 深藏青 | `#0A1F44` |

---

## 三、模块关系一句话总览（帮你理解图，不进图片）

- **QM** 通过 `enqueue_ctrl`（分配地址）与 `dequeue_ctrl`（读地址）两条 1 拍接口交互；**EPS** 通过 `recycle_ctrl`（还地址）接口逐 cell 回收。
- **CSR 相关信号**（`init_start` / `cfg_in_*` / `init_done` / `irq_*` / `st_out_*`）不接独立外部块，直接连到 **SMMU 顶层端口**。
- **LLE** 是核心枢纽：独占 Next-Ptr SRAM，处理链表 alloc/dequeue/free，并向 `occupancy_pool_mgr` 发 alloc/free 事件做占用计数。
- **occupancy_pool_mgr** 做双池水位判决，回吐 accept/drop 给 enqueue，并对外产生 `q/port/global_max_reached` 与 `pause_req/pfc_req`。
- **aging_ctrl** 监控队列占用超时，触发 `age_flush_req` 让 LLE 冲刷老化队列。
- **csr_stats_init** 无总线，直采 `cfg_in_*` 配置 fanout 给 occ/aging，管理上电初始化建链，并聚合统计与中断。

> 若作图工具是 **Mermaid**，可把上面 Prompt 里的连接关系直接转成 `flowchart LR`；若是图像生成 AI（Nano Banana / GPT-Image），直接整段贴入即可。