## smmu

```
//============================================================================
// Module      : smart_mmu  (Smart MMU Top)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Description : Flexible Shared SRAM Address Management Module 顶层。
//               以 256B cell 为粒度统一管理 2MB 共享数据 SRAM 的地址与链表,
//               提供入队(1 拍)地址分配、出队(1 拍)地址输出、报文发送后的地址
//               回收、链表组织、占用水位判决、满/快满反馈与 PAUSE/PFC 流控。
//               所有数据/控制接口对端均为 QM (MMU 是 QM 的地址管理子模块)。
//
//   核心约束:
//     1. 入队、出队均严格 1 拍 (T0 收请求, T1 返回结果, 背靠背 1 cell/cycle)。
//     2. 覆盖单播与组播 (组播一份 cell 多端口共享, 按 ref_count 回收)。
//     3. 占用水位 + 高水位无条件丢弃; PAUSE(802.3x) + PFC(802.1Qbb); WRED 在 QM。
//     4. 每队列/端口/全局 full 与 near_full 反馈 QM 做入队请求前置门控。
//     5. 链表指针用 SRAM (Next-Ptr SRAM, 1 拍读延迟), LLE 预取寄存器吸收读延迟。
//     6. 缓存管理: 静态预留池(每队列各自预留) + 动态共享池 双池架构。
//     7. CSR 不走 APB/AHB 总线: 配置 cfg_in_* 在 clk_core 域已 ready 直采。
//
//   ★ 位宽全部由 CELL_NUM/QUEUE_NUM/PORT_NUM 派生 (与各子模块 / occupancy_pool_mgr
//     同源), 顶层不再独立给 ADDR_W/QID_W/PORT_W/CNT_W 数值。
//
//   子模块:
//     - enqueue_ctrl        : 入队控制 (1 拍命令式, 含整帧丢弃 FSM)
//     - dequeue_ctrl        : 出队控制 (1 拍命令式, 含背压检查)
//     - recycle_ctrl        : 回收控制 (单播直接还链 / 组播 ref_count)
//     - lle                 : Link-List Engine, 唯一访问 Next-Ptr SRAM
//     - occupancy_pool_mgr  : 占用计数 + 双池判决 + 满/快满 + PAUSE + PFC
//     - mcast_refcount_mgr  : 组播引用计数
//     - csr_stats_init      : 外部 CSR 配置采样 + 上电初始化 FSM (无总线)
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module smart_mmu #(
    parameter int CELL_NUM   = 8192,  // 总 cell 数 (2MB/256B)
    parameter int PORT_NUM   = 4,     // 物理出端口数
    parameter int TC_NUM     = 8,     // 每端口 TC 数 (per-port traffic class)
    parameter int REF_W      = 3,     // 组播 ref_count 位宽 (0~4)
    parameter int STAT_W     = 32,    // 统计计数器位宽
    parameter int PKT_CELL_W = 4,     // enq_cell_num 位宽 (本包 cell 数)
    // ★ 队列数 = 端口数×每端口TC + 1 (仅 1 个多播专用队列; free 链在 LLE 内独立维护)
    //   索引: [0 .. PORT_NUM*TC_NUM-1] 单播(port,tc); [QUEUE_NUM-1] 多播专用队列
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,
    // 派生位宽 / 数量 (与各子模块同源)
    localparam int ADDR_W    = $clog2(CELL_NUM),
    localparam int QID_W     = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W    = $clog2(PORT_NUM-1)+1,
    localparam int CNT_W     = ADDR_W + 1
)(
    //------------------------------------------------------------------------
    // G1 - 时钟与复位
    //------------------------------------------------------------------------
    input  logic                  clk_core,        // 300MHz 主时钟
    input  logic                  rst_core_n,      // 异步复位, 低有效
    input  logic                  init_start,      // 上电链表初始化触发 (← CPU/CSR)
    output logic                  init_done,       // 初始化完成 (→ CPU/QM)

    //------------------------------------------------------------------------
    // G2 - 入队 / 地址分配接口 (QM ↔ MMU, 1 拍)
    //------------------------------------------------------------------------
    input  logic                  enq_req,             // 入队/分配请求有效
    input  logic [QID_W-1:0]      enq_queue_id,        // 目标队列号
    input  logic [PORT_W-1:0]     enq_egress_port,     // 出端口 ID
    input  logic [PKT_CELL_W-1:0] enq_cell_num,        // ★ 本包 cell 数(SOF 有效, 入队前预判用)
    input  logic                  enq_is_mcast,        // 组播标志
    input  logic [PORT_NUM-1:0]   enq_mcast_bitmap,    // 组播出端口位图
    input  logic [$clog2(TC_NUM)-1:0] enq_mcast_tc,    // ★ B2: 组播帧 TC (决定各端口承载队列)
    input  logic                  enq_sof,             // 报文首段
    input  logic                  enq_eof,             // 报文尾段
    output logic                  enq_ready,           // MMU 可接收入队请求
    output logic                  enq_predict_drop,    // ★ 入队前预判: 本包会否触发丢弃(组合当拍返回给 QM)
    output logic                  alloc_valid,         // 分配结果有效
    output logic [ADDR_W-1:0]     alloc_cell_addr,     // 分配的 cell 地址
    output logic                  alloc_drop_ind,      // 丢包指示(高水位/空闲池空兜底)
    output logic                  alloc_sram_flag,     // 内部 SRAM 存储标志
    output logic                  alloc_pkt_head,      // 报文头 (= enq_sof)
    output logic                  alloc_pkt_tail,      // 报文尾 (= enq_eof)
    output logic                  alloc_full_frame_drop, // 整帧丢弃指示
    output logic                  mcast_busy_drop,     // ★ B2: 多播槽占用, 新多播帧被丢弃

    //------------------------------------------------------------------------
    // G3 - 出队 / 地址读取接口 (QM ↔ MMU, 1 拍)
    //------------------------------------------------------------------------
    input  logic                  deq_req,             // 出队请求有效
    input  logic [QID_W-1:0]      deq_queue_id,        // 出队队列号
    input  logic [PORT_NUM-1:0]   deq_backpressure,    // 每端口背压
    output logic                  deq_ready,           // MMU 可接收出队请求
    output logic                  deq_cell_valid,      // 出队 cell 地址有效
    output logic [ADDR_W-1:0]     deq_cell_addr,       // 出队 cell 地址
    output logic                  deq_pkt_head,        // 报文头标志
    output logic                  deq_pkt_tail,        // 报文尾标志

    //------------------------------------------------------------------------
    // G4 - 地址回收 / 组播回收接口 (QM → MMU)
    //   ★ recycle_queue_id / mcast_recycle_queue_id: QM 提供被回收 cell 所属队列号
    //     (QM 有 descriptor)。透传给 recycle_ctrl → LLE → occupancy, 用于 per-queue
    //     /port 占用计数 --, 与 LLE free 事件同拍。
    //------------------------------------------------------------------------
    input  logic                  recycle_req,         // 单播 cell 回收请求
    input  logic [ADDR_W-1:0]     recycle_cell_addr,   // 待回收 cell 地址
    input  logic [QID_W-1:0]      recycle_queue_id,    // 单播回收 cell 所属队列号
    input  logic                  mcast_recycle_req,   // 组播回收通知
    input  logic [ADDR_W-1:0]     mcast_recycle_addr,  // 组播待回收 cell 地址
    input  logic [QID_W-1:0]      mcast_recycle_queue_id, // 组播回收 cell 所属队列号
    output logic                  recycle_ack,         // 回收完成应答

    //------------------------------------------------------------------------
    // G6 - 满 / 快满反馈接口 (MMU → QM)
    //------------------------------------------------------------------------
    // ★ B2: 32 条常规队列 empty 位图 (给 QM 调度; 多播计入各目的端口承载队列)
    output logic [PORT_NUM*TC_NUM-1:0] q_empty,
    output logic [QUEUE_NUM-1:0]  q_near_full,         // 每队列快满
    output logic [PORT_NUM-1:0]   port_near_full,      // 每出端口快满
    output logic                  global_near_full,    // 全局快满
    output logic [QUEUE_NUM-1:0]  q_full,              // 每队列满
    output logic [PORT_NUM-1:0]   port_full,           // 每出端口满
    output logic                  global_full,         // 全局满

    //------------------------------------------------------------------------
    // G5 - 流控 / 告警输出
    //------------------------------------------------------------------------
    output logic [PORT_NUM-1:0]             pause_req,   // 802.3x 端口级 PAUSE 请求 → MAC
    output logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_req,     // 802.1Qbb PFC 反压位图 → MAC
    output logic                            irq_alarm,   // 告警中断
    output logic                            irq_aging,   // 老化中断
    output logic                            overflow_alarm,  // cell 池溢出告警
    output logic                            underflow_alarm, // 空闲链下溢/链完整性错误

    //------------------------------------------------------------------------
    // G5 - 配置输入 (外部 CSR → MMU, clk_core 域已 ready, 直接采样, 无总线/无 CDC)
    //------------------------------------------------------------------------
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_in_queue_min_cell,    // 每队列静态预留
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_in_q_max_cell,        // 每队列高水位上限
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_in_q_full,            // 每队列满阈值
    input  logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_in_port_max,          // 每出端口高水位
    input  logic [CNT_W-1:0]                            cfg_in_global_high_wm,    // 全局高水位
    input  logic                                        cfg_in_pause_en,          // PAUSE 使能
    input  logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_in_port_pause_xoff,   // 每端口 PAUSE XOFF
    input  logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_in_port_pause_xon,    // 每端口 PAUSE XON
    input  logic [CNT_W-1:0]                            cfg_in_global_pause_xoff, // 全局 PAUSE XOFF
    input  logic [CNT_W-1:0]                            cfg_in_global_pause_xon,  // 全局 PAUSE XON
    input  logic                                        cfg_in_pfc_en,            // PFC 使能
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_in_pfc_xoff,          // 每 TC PFC XOFF
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_in_pfc_xon,           // 每 TC PFC XON
    //   ★ B2: 多播承载队列 TC 不再用 cfg (改由入队 enq_mcast_tc 携带), 见 G2。
    //------------------------------------------------------------------------
    // G5 - 统计输出 (MMU → 外部 CSR/CPU, clk_core 域直接输出, 无总线)
    //   注: 新版 occ 暂未产出统计, 以下由 csr_stats_init 置 0 占位。
    //------------------------------------------------------------------------
    output logic [CNT_W-1:0]                 st_out_global_used,
    output logic [CNT_W-1:0]                 st_out_free_count,
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]  st_out_q_static_used,
    output logic [PORT_NUM-1:0][CNT_W-1:0]   st_out_per_port_used,
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]  st_out_per_queue_used,
    output logic [QUEUE_NUM-1:0]             st_out_q_near_full_status,
    output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_out_tail_drop_cnt,
    output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_out_near_full_assert_cnt,
    output logic [PORT_NUM-1:0][STAT_W-1:0]  st_out_pause_tx_cnt
);

    //========================================================================
    // 内部互连信号
    //========================================================================
    // Enqueue Ctrl ↔ Occupancy (按当前入队队列/端口精确判决)
    logic                  occ_query_vld;
    logic [QID_W-1:0]      occ_query_queue_id;
    logic [PORT_W-1:0]     occ_query_egress_port;
    logic [PKT_CELL_W-1:0] occ_query_cell_num;    // 入队前预判: 本包 cell 数
    logic                  occ_accept, occ_drop, occ_use_static, occ_no_free;
    logic                  occ_predict_drop;      // 入队前预判结果

    // Enqueue Ctrl ↔ LLE
    logic [ADDR_W-1:0]     lle_free_head;
    logic                  lle_free_empty;
    logic                  lle_alloc_ready;
    logic                  lle_alloc_fire;
    logic [QID_W-1:0]      lle_alloc_queue_id;
    logic [ADDR_W-1:0]     lle_alloc_addr;
    logic                  lle_set_pkt_head, lle_set_pkt_tail;
    logic                  lle_alloc_is_mcast;
    logic [PORT_NUM-1:0]   lle_alloc_mcast_bitmap;   // ★ B2
    logic [$clog2(TC_NUM)-1:0] lle_alloc_mcast_tc;   // ★ B2 组播帧 TC → LLE
    logic                  mc_busy;                  // ★ B2

    // Dequeue Ctrl ↔ LLE
    logic [QID_W-1:0]      lle_deq_queue_id;
    logic [ADDR_W-1:0]     lle_qhead;
    logic                  lle_qhead_pkt_head, lle_qhead_pkt_tail;
    logic                  lle_q_empty;
    logic                  lle_deq_fire;

    // Recycle Ctrl ↔ LLE (还链 + 透传被回收 cell 的 queue_id)
    logic                  lle_free_req;
    logic [ADDR_W-1:0]     lle_free_addr;
    logic [QID_W-1:0]      lle_free_queue_id;
    logic                  lle_free_grant, lle_free_done;

    // ★ B2: Recycle Ctrl → LLE 多播逐端口回收 + LLE 多播回收下溢告警
    logic                  mc_rcy_vld;
    logic [PORT_W-1:0]     mc_rcy_port;
    logic                  mcast_underflow;

    // LLE ↔ Occupancy:
    //   alloc 事件: lle_alloc_evt + evt_queue_id/evt_egress_port (per-queue/port ++)
    //   free  事件: lle_free_evt  + evt_free_queue_id/evt_free_egress_port (--)
    //   ★ occ 的回收计数由 LLE free 事件驱动 (时序与 LLE free_cnt 一致),
    //     queue_id 由 recycle_ctrl 透传给 LLE, LLE 随 free 事件转发。
    logic                  lle_alloc_evt;
    logic [QID_W-1:0]      evt_queue_id;
    logic [PORT_W-1:0]     evt_egress_port;
    logic                  lle_free_evt;
    logic [QID_W-1:0]      evt_free_queue_id;
    logic [PORT_W-1:0]     evt_free_egress_port;

    // CSR ↔ Occupancy (配置下发)
    logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_queue_min_cell;
    logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_q_max_cell;
    logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_q_full;
    logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_max;
    logic [CNT_W-1:0]                            cfg_global_high_wm;
    logic                                        cfg_pause_en;
    logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_pause_xoff;
    logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_pause_xon;
    logic [CNT_W-1:0]                            cfg_global_pause_xoff;
    logic [CNT_W-1:0]                            cfg_global_pause_xon;
    logic                                        cfg_pfc_en;
    logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xoff;
    logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xon;

    // CSR ↔ Occupancy (统计汇聚 + 告警)
    logic [CNT_W-1:0]                 occ_st_global_used;
    logic [CNT_W-1:0]                 occ_st_free_count;
    logic [QUEUE_NUM-1:0][CNT_W-1:0]  occ_st_q_static_used;
    logic [PORT_NUM-1:0][CNT_W-1:0]   occ_st_per_port_used;
    logic [QUEUE_NUM-1:0][CNT_W-1:0]  occ_st_per_queue_used;
    logic [QUEUE_NUM-1:0]             occ_st_q_near_full_status;
    logic [QUEUE_NUM-1:0][STAT_W-1:0] occ_st_tail_drop_cnt;
    logic [QUEUE_NUM-1:0][STAT_W-1:0] occ_st_near_full_assert_cnt;
    logic [PORT_NUM-1:0][STAT_W-1:0]  occ_st_pause_tx_cnt;
    logic                             occ_overflow_alarm, occ_underflow_alarm;

    // Init FSM ↔ LLE / 各模块
    logic                  init_build_req, init_build_done;
    logic                  clr_ptr_cnt;

    // 顶层告警: occ 溢出/下溢 + 组播回收下溢, 一并汇入 (csr 内再聚成 irq)。
    assign overflow_alarm  = occ_overflow_alarm;
    assign underflow_alarm = occ_underflow_alarm | mcast_underflow;

    //========================================================================
    // 子模块例化
    //========================================================================

    // ---- Enqueue Ctrl ----
    enqueue_ctrl #(
        .CELL_NUM (CELL_NUM), .PORT_NUM (PORT_NUM),
        .TC_NUM (TC_NUM), .REF_W (REF_W), .PKT_CELL_W (PKT_CELL_W)
    ) u_enq (
        .clk_core              (clk_core),
        .rst_core_n            (rst_core_n),
        .init_done             (init_done),
        .enq_req               (enq_req),
        .enq_queue_id          (enq_queue_id),
        .enq_egress_port       (enq_egress_port),
        .enq_cell_num          (enq_cell_num),
        .enq_is_mcast          (enq_is_mcast),
        .enq_mcast_bitmap      (enq_mcast_bitmap),
        .enq_mcast_tc          (enq_mcast_tc),             // ★ B2
        .enq_sof               (enq_sof),
        .enq_eof               (enq_eof),
        .enq_ready             (enq_ready),
        .enq_predict_drop      (enq_predict_drop),
        .alloc_valid           (alloc_valid),
        .alloc_cell_addr       (alloc_cell_addr),
        .alloc_drop_ind        (alloc_drop_ind),
        .alloc_sram_flag       (alloc_sram_flag),
        .alloc_pkt_head        (alloc_pkt_head),
        .alloc_pkt_tail        (alloc_pkt_tail),
        .alloc_full_frame_drop (alloc_full_frame_drop),
        .occ_query_vld         (occ_query_vld),
        .occ_query_queue_id    (occ_query_queue_id),
        .occ_query_egress_port (occ_query_egress_port),
        .occ_query_cell_num    (occ_query_cell_num),
        .occ_accept            (occ_accept),
        .occ_drop              (occ_drop),
        .occ_use_static        (occ_use_static),
        .occ_no_free           (occ_no_free),
        .occ_predict_drop      (occ_predict_drop),
        .lle_free_head         (lle_free_head),
        .lle_free_empty        (lle_free_empty),
        .lle_alloc_ready       (lle_alloc_ready),
        .lle_alloc_fire        (lle_alloc_fire),
        .lle_alloc_queue_id    (lle_alloc_queue_id),
        .lle_alloc_addr        (lle_alloc_addr),
        .lle_set_pkt_head      (lle_set_pkt_head),
        .lle_set_pkt_tail      (lle_set_pkt_tail),
        .lle_alloc_is_mcast    (lle_alloc_is_mcast),
        .lle_alloc_mcast_bitmap(lle_alloc_mcast_bitmap),   // ★ B2
        .lle_alloc_mcast_tc    (lle_alloc_mcast_tc),       // ★ B2
        .mc_busy               (mc_busy),                  // ★ B2
        .mcast_busy_drop       (mcast_busy_drop)           // ★ B2
    );

    // ---- Dequeue Ctrl ----
    dequeue_ctrl #(
        .CELL_NUM (CELL_NUM), .PORT_NUM (PORT_NUM), .TC_NUM (TC_NUM)
    ) u_deq (
        .clk_core           (clk_core),
        .rst_core_n         (rst_core_n),
        .init_done          (init_done),
        .deq_req            (deq_req),
        .deq_queue_id       (deq_queue_id),
        .deq_backpressure   (deq_backpressure),
        .deq_ready          (deq_ready),
        .deq_cell_valid     (deq_cell_valid),
        .deq_cell_addr      (deq_cell_addr),
        .deq_pkt_head       (deq_pkt_head),
        .deq_pkt_tail       (deq_pkt_tail),
        .lle_qhead          (lle_qhead),
        .lle_qhead_pkt_head (lle_qhead_pkt_head),
        .lle_qhead_pkt_tail (lle_qhead_pkt_tail),
        .lle_q_empty        (lle_q_empty),
        .lle_deq_fire       (lle_deq_fire),
        .lle_deq_queue_id   (lle_deq_queue_id)
    );

    // ---- Recycle Ctrl (透传被回收 cell 的 queue_id 给 LLE, 不再直接驱动 occ) ----
    recycle_ctrl #(
        .CELL_NUM (CELL_NUM), .PORT_NUM (PORT_NUM), .TC_NUM (TC_NUM)
    ) u_rcy (
        .clk_core               (clk_core),
        .rst_core_n             (rst_core_n),
        .recycle_req            (recycle_req),
        .recycle_cell_addr      (recycle_cell_addr),
        .recycle_queue_id       (recycle_queue_id),
        .mcast_recycle_req      (mcast_recycle_req),
        .mcast_recycle_addr     (mcast_recycle_addr),
        .mcast_recycle_queue_id (mcast_recycle_queue_id),
        .recycle_ack            (recycle_ack),
        .lle_free_req           (lle_free_req),
        .lle_free_addr          (lle_free_addr),
        .lle_free_queue_id      (lle_free_queue_id),
        .lle_free_grant         (lle_free_grant),
        .lle_free_done          (lle_free_done),
        // ★ B2: 组播逐端口回收 → LLE
        .mc_rcy_vld             (mc_rcy_vld),
        .mc_rcy_port            (mc_rcy_port)
    );

    // ---- Link-List Engine (含内部 Next-Ptr SRAM) ----
    lle #(
        .CELL_NUM (CELL_NUM), .PORT_NUM (PORT_NUM),
        .TC_NUM (TC_NUM), .REF_W (REF_W)
    ) u_lle (
        .clk_core           (clk_core),
        .rst_core_n         (rst_core_n),
        .init_build_req     (init_build_req),
        .init_build_done    (init_build_done),
        .lle_free_head      (lle_free_head),
        .lle_free_empty     (lle_free_empty),
        .lle_alloc_ready    (lle_alloc_ready),
        .lle_alloc_fire     (lle_alloc_fire),
        .lle_alloc_queue_id (lle_alloc_queue_id),
        .lle_alloc_addr     (lle_alloc_addr),
        .lle_set_pkt_head   (lle_set_pkt_head),
        .lle_set_pkt_tail   (lle_set_pkt_tail),
        .lle_alloc_is_mcast (lle_alloc_is_mcast),
        .lle_alloc_mcast_bitmap (lle_alloc_mcast_bitmap),  // ★ B2
        .lle_alloc_mcast_tc (lle_alloc_mcast_tc),           // ★ B2 (定各端口承载队列)
        .mc_busy            (mc_busy),                      // ★ B2
        .lle_deq_queue_id   (lle_deq_queue_id),
        .lle_qhead          (lle_qhead),
        .lle_qhead_pkt_head (lle_qhead_pkt_head),
        .lle_qhead_pkt_tail (lle_qhead_pkt_tail),
        .lle_q_empty        (lle_q_empty),
        .lle_deq_fire       (lle_deq_fire),
        .q_empty_vec        (q_empty),                      // ★ B2: 32 条常规队列 empty → QM
        .lle_free_req       (lle_free_req),
        .lle_free_addr      (lle_free_addr),
        .lle_free_queue_id  (lle_free_queue_id),
        .lle_free_grant     (lle_free_grant),
        .lle_free_done      (lle_free_done),
        // ★ B2: 组播逐端口回收 + 下溢告警
        .mc_rcy_vld         (mc_rcy_vld),
        .mc_rcy_port        (mc_rcy_port),
        .mcast_underflow    (mcast_underflow),
        // alloc 事件 → occ (per-queue/port ++)
        .lle_alloc_evt      (lle_alloc_evt),
        .evt_queue_id       (evt_queue_id),
        .evt_egress_port    (evt_egress_port),
        // free 事件 → occ (per-queue/port --, 携带回收 cell 的 queue_id/port)
        .lle_free_evt          (lle_free_evt),
        .evt_free_queue_id     (evt_free_queue_id),
        .evt_free_egress_port  (evt_free_egress_port)
    );

    // ---- Occupancy & Pool Mgr (派生位宽; per-queue 判决+静态穿透; q/port/global
    //      full+near_full; PAUSE/PFC 双阈值迟滞; 统计 st_* + overflow/underflow) ----
    occupancy_pool_mgr #(
        .CELL_NUM (CELL_NUM), .PORT_NUM (PORT_NUM),
        .TC_NUM (TC_NUM), .STAT_W (STAT_W), .PKT_CELL_W (PKT_CELL_W)
    ) u_occ (
        .clk_core              (clk_core),
        .rst_core_n            (rst_core_n),
        // 与 Enqueue Ctrl (按当前入队队列/端口判决 + 入队前预判)
        .occ_query_vld         (occ_query_vld),
        .occ_query_queue_id    (occ_query_queue_id),
        .occ_query_egress_port (occ_query_egress_port),
        .occ_query_cell_num    (occ_query_cell_num),
        .occ_accept            (occ_accept),
        .occ_drop              (occ_drop),
        .occ_use_static        (occ_use_static),
        .occ_no_free           (occ_no_free),
        .occ_predict_drop      (occ_predict_drop),
        // 与 LLE (分配事件)
        .lle_alloc_evt         (lle_alloc_evt),
        .evt_queue_id          (evt_queue_id),
        .evt_egress_port       (evt_egress_port),
        // 回收事件 ← LLE free 事件 (与 LLE free_cnt 同拍, 携带回收 cell queue_id/port)
        .occ_free_vld          (lle_free_evt),
        .occ_free_queue_id     (evt_free_queue_id),
        .occ_free_egress_port  (evt_free_egress_port),
        // 流控 / 满 / 快满输出
        .pause_req             (pause_req),
        .pfc_req               (pfc_req),
        .q_near_full           (q_near_full),
        .port_near_full        (port_near_full),
        .global_near_full      (global_near_full),
        .q_full                (q_full),
        .port_full             (port_full),
        .global_full           (global_full),
        // 配置
        .cfg_queue_min_cell    (cfg_queue_min_cell),
        .cfg_q_max_cell        (cfg_q_max_cell),
        .cfg_port_max          (cfg_port_max),
        .cfg_global_high_wm    (cfg_global_high_wm),
        .cfg_q_full            (cfg_q_full),
        .cfg_pause_en          (cfg_pause_en),
        .cfg_port_pause_xoff   (cfg_port_pause_xoff),
        .cfg_port_pause_xon    (cfg_port_pause_xon),
        .cfg_global_pause_xoff (cfg_global_pause_xoff),
        .cfg_global_pause_xon  (cfg_global_pause_xon),
        .cfg_pfc_en            (cfg_pfc_en),
        .cfg_pfc_xoff          (cfg_pfc_xoff),
        .cfg_pfc_xon           (cfg_pfc_xon),
        // 统计 / 告警 → CSR
        .st_global_used          (occ_st_global_used),
        .st_free_count           (occ_st_free_count),
        .st_q_static_used        (occ_st_q_static_used),
        .st_per_port_used        (occ_st_per_port_used),
        .st_per_queue_used       (occ_st_per_queue_used),
        .st_q_near_full_status   (occ_st_q_near_full_status),
        .st_tail_drop_cnt        (occ_st_tail_drop_cnt),
        .st_near_full_assert_cnt (occ_st_near_full_assert_cnt),
        .st_pause_tx_cnt         (occ_st_pause_tx_cnt),
        .overflow_alarm          (occ_overflow_alarm),
        .underflow_alarm         (occ_underflow_alarm)
    );

    // ---- Multicast Ref-Count Mgr: ★ B2 已移除 ----
    //   B2 单槽模型用 LLE 内的 mc_rd_done/mc_rcy_done 位图取代 8192×3bit ref_count,
    //   mcast_refcount_mgr 不再例化 (源文件保留但未使用)。

    // ---- CSR / Stats + Init FSM (无总线; cfg_in_* 直采, 下发 occ; 统计置 0) ----
    csr_stats_init #(
        .CELL_NUM (CELL_NUM), .PORT_NUM (PORT_NUM),
        .TC_NUM (TC_NUM), .STAT_W (STAT_W)
    ) u_csr (
        .clk_core                 (clk_core),
        .rst_core_n               (rst_core_n),
        // 外部 CSR 配置输入 (顶层 cfg_in_*)
        .cfg_in_queue_min_cell    (cfg_in_queue_min_cell),
        .cfg_in_q_max_cell        (cfg_in_q_max_cell),
        .cfg_in_q_full            (cfg_in_q_full),
        .cfg_in_port_max          (cfg_in_port_max),
        .cfg_in_global_high_wm    (cfg_in_global_high_wm),
        .cfg_in_pause_en          (cfg_in_pause_en),
        .cfg_in_port_pause_xoff   (cfg_in_port_pause_xoff),
        .cfg_in_port_pause_xon    (cfg_in_port_pause_xon),
        .cfg_in_global_pause_xoff (cfg_in_global_pause_xoff),
        .cfg_in_global_pause_xon  (cfg_in_global_pause_xon),
        .cfg_in_pfc_en            (cfg_in_pfc_en),
        .cfg_in_pfc_xoff          (cfg_in_pfc_xoff),
        .cfg_in_pfc_xon           (cfg_in_pfc_xon),
        // 统计汇聚 ← Occupancy + 告警 ← Occupancy
        .st_global_used           (occ_st_global_used),
        .st_free_count            (occ_st_free_count),
        .st_q_static_used         (occ_st_q_static_used),
        .st_per_port_used         (occ_st_per_port_used),
        .st_per_queue_used        (occ_st_per_queue_used),
        .st_q_near_full_status    (occ_st_q_near_full_status),
        .st_tail_drop_cnt         (occ_st_tail_drop_cnt),
        .st_near_full_assert_cnt  (occ_st_near_full_assert_cnt),
        .st_pause_tx_cnt          (occ_st_pause_tx_cnt),
        .overflow_alarm           (occ_overflow_alarm),
        .underflow_alarm          (occ_underflow_alarm),
        // 初始化
        .init_start               (init_start),
        .init_done                (init_done),
        // 告警/中断
        .irq_alarm                (irq_alarm),
        .irq_aging                (irq_aging),
        // 配置下发 → Occupancy
        .cfg_queue_min_cell       (cfg_queue_min_cell),
        .cfg_q_max_cell           (cfg_q_max_cell),
        .cfg_q_full               (cfg_q_full),
        .cfg_port_max             (cfg_port_max),
        .cfg_global_high_wm       (cfg_global_high_wm),
        .cfg_pause_en             (cfg_pause_en),
        .cfg_port_pause_xoff      (cfg_port_pause_xoff),
        .cfg_port_pause_xon       (cfg_port_pause_xon),
        .cfg_global_pause_xoff    (cfg_global_pause_xoff),
        .cfg_global_pause_xon     (cfg_global_pause_xon),
        .cfg_pfc_en               (cfg_pfc_en),
        .cfg_pfc_xoff             (cfg_pfc_xoff),
        .cfg_pfc_xon              (cfg_pfc_xon),
        // 统计输出 → 顶层 st_out_* (置 0 占位)
        .st_out_global_used          (st_out_global_used),
        .st_out_free_count           (st_out_free_count),
        .st_out_q_static_used        (st_out_q_static_used),
        .st_out_per_port_used        (st_out_per_port_used),
        .st_out_per_queue_used       (st_out_per_queue_used),
        .st_out_q_near_full_status   (st_out_q_near_full_status),
        .st_out_tail_drop_cnt        (st_out_tail_drop_cnt),
        .st_out_near_full_assert_cnt (st_out_near_full_assert_cnt),
        .st_out_pause_tx_cnt         (st_out_pause_tx_cnt),
        // 与 LLE 建链
        .init_build_req           (init_build_req),
        .init_build_done          (init_build_done),
        // 初始化期清指针/计数
        .clr_ptr_cnt              (clr_ptr_cnt)
    );

    // 说明: 链表指针 lle 内部例化 next_ptr_sram (单片 SRAM, 1 拍读延迟)。
    //       CSR 不走 APB/AHB 总线: cfg_in_* 在 clk_core 域已 ready 直采。
    //       occ 的统计 st_* 与 overflow/underflow 告警经 csr 寄存直出/聚成 irq;
    //       占用计数下溢/溢出 + 组播 ref 下溢一并汇入顶层 overflow/underflow_alarm。
    //       u_csr 的 clr_ptr_cnt 在详细设计阶段连到各 Ctrl/Occupancy 的初始化清零口。

endmodule
```


## lle

```
//============================================================================
// Module      : lle  (Link-List Engine) —— B2 多播逻辑拼接版
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   LLE 是 MMU 的存储访问平面核心: 唯一访问 Next-Ptr SRAM (1R1W), 对 Enqueue /
//   Dequeue / Recycle 提供分配/出队/还链服务。
//
//   ── 链表组织 (34 chain, 全部在 Next-Ptr SRAM 中) ──
//     [0..31]  : per-(port,TC) 单播队列链
//     [32]     : 多播链 (MC_QID)。★ B2: chain33 是**真实的 SRAM 链表**, 与 32 条单播
//                链同构 —— enqueue 用 lle_alloc_queue_id=MC_QID 走同一挂链路径写 SRAM,
//                维护 q_head/tail/cnt[MC_QID]。QM 从不直接出队 MC_QID (只发 32 单播 qid),
//                故 chain33 的 SRAM 队头不推进, 被多端口共享读。
//                另有一份小寄存器镜像 mc_cells_q[] (≤MAX_MC_CELLS, 存本帧各 cell 地址,
//                报文序) **仅作逐端口读加速**: 出队时用 per-port 索引 O(1) 取地址, 不占
//                SRAM 读口、不改变 "SRAM 为权威链" 这一事实。
//     free 链  : 独立维护 (free_head/free_tail/free_cnt 寄存器)
//
//   ── B2 多播模型 (单槽 + 零复制 + 逐端口私有读指针 + 逻辑插入位置锚定) ──
//     1) 单槽: mc_valid=1 时拒收新多播 (enqueue_ctrl 靠 mc_busy 整帧 drop)。
//     2) 多播数据只存一份 (chain33 在 SRAM 里唯一一条; mc_cells_q[] 是其读加速镜像)。
//     3) 每目的端口私有读索引 mc_rd_idx_q[p] 独立遍历同一份 chain33 (只读, 不推进队头)。
//     4) 逻辑插入位置: 多播帧 SOF 到达时对每个目的端口快照“承载单播队列”当时在队
//        的真实单播完整包数 mc_pend_uni_q[p]; 出队每出完一个真实单播包(pkt_tail)-1;
//        减到 0 且多播未读完 → 该端口下一个包切多播 cell-list。
//     5) 回收: EPS 每端口发完 → mc_rcy_done_q[p]=1; 所有目的端口 rd_done & rcy_done
//        → 整帧 cell 逐个还回 free 链 (走 recycle FIFO, queue_id=MC_QID, occ 每 cell--),
//        还完清 mc_valid, 方可收下一条多播。
//     6) 双池按实际存入计: 多播 alloc/free 事件均用 MC_QID, global 只 ±M 一次。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module lle #(
    parameter  int CELL_NUM        = 8192,
    parameter  int PORT_NUM        = 4,
    parameter  int TC_NUM          = 8,      // 每端口 TC 数
    parameter  int REF_W           = 3,      // (兼容保留, 未用)
    parameter  int RCY_FIFO_DEPTH  = 8,
    parameter  int MAX_MC_CELLS    = 8,      // 多播帧最大 cell 数 (1522B/256B=6, 取 8 余量)
    // ★ 队列数 = 端口数×每端口TC + 1 (1 多播专用队列; free 链独立)
    localparam int QUEUE_NUM       = PORT_NUM*TC_NUM + 1,
    localparam int MC_QID          = QUEUE_NUM-1,        // 多播队列号 (=32)
    localparam int ADDR_W          = $clog2(CELL_NUM),
    localparam int QID_W           = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W          = $clog2(PORT_NUM-1)+1,
    localparam int CNT_W           = ADDR_W + 1,
    localparam int ENTRY_W         = ADDR_W + 2,         // entry = {next, ph, pt}
    localparam int PH_BIT          = 1,
    localparam int PT_BIT          = 0,
    localparam int Q_PER_PORT_LOG  = $clog2(TC_NUM),
    localparam int MC_IDX_W        = $clog2(MAX_MC_CELLS+1)
)(
    input  logic                  clk_core,
    input  logic                  rst_core_n,

    // Init FSM
    input  logic                  init_build_req,
    output logic                  init_build_done,

    // Enqueue Ctrl
    output logic [ADDR_W-1:0]     lle_free_head,
    output logic                  lle_free_empty,
    output logic                  lle_alloc_ready,
    input  logic                  lle_alloc_fire,
    input  logic [QID_W-1:0]      lle_alloc_queue_id,
    input  logic [ADDR_W-1:0]     lle_alloc_addr,
    input  logic                  lle_set_pkt_head,
    input  logic                  lle_set_pkt_tail,
    input  logic                  lle_alloc_is_mcast,
    input  logic [PORT_NUM-1:0]   lle_alloc_mcast_bitmap,
    input  logic [Q_PER_PORT_LOG-1:0] lle_alloc_mcast_tc,   // ★ 多播帧 TC (决定各端口承载队列)
    output logic                  mc_busy,

    // Dequeue Ctrl (含多播 splice)
    input  logic [QID_W-1:0]      lle_deq_queue_id,
    output logic [ADDR_W-1:0]     lle_qhead,
    output logic                  lle_qhead_pkt_head,
    output logic                  lle_qhead_pkt_tail,
    output logic                  lle_q_empty,
    input  logic                  lle_deq_fire,

    // ★ B2: 给 QM 的 32 条常规队列 empty 向量 (多播计入各目的端口承载队列)
    output logic [PORT_NUM*TC_NUM-1:0] q_empty_vec,

    // Recycle Ctrl (单播还链 + 多播逐端口回收)
    input  logic                  lle_free_req,
    input  logic [ADDR_W-1:0]     lle_free_addr,
    input  logic [QID_W-1:0]      lle_free_queue_id,
    output logic                  lle_free_grant,
    output logic                  lle_free_done,
    input  logic                  mc_rcy_vld,
    input  logic [PORT_W-1:0]     mc_rcy_port,
    output logic                  mcast_underflow,

    // Occupancy
    output logic                  lle_alloc_evt,
    output logic [QID_W-1:0]      evt_queue_id,
    output logic [PORT_W-1:0]     evt_egress_port,
    output logic                  lle_free_evt,
    output logic [QID_W-1:0]      evt_free_queue_id,
    output logic [PORT_W-1:0]     evt_free_egress_port
);

    //========================================================================
    // per-queue 链表寄存器 (两级预取, 仅单播队列使用; MC_QID 不走 SRAM)
    //========================================================================
    logic [ADDR_W-1:0]   q_head_q       [QUEUE_NUM];
    logic [ADDR_W-1:0]   q_tail_q       [QUEUE_NUM];
    logic [CNT_W-1:0]    q_cell_cnt_q   [QUEUE_NUM];
    logic                q_head_ph_q    [QUEUE_NUM];
    logic                q_head_pt_q    [QUEUE_NUM];
    logic [ADDR_W-1:0]   q_head_next_q    [QUEUE_NUM];
    logic                q_head_next_ph_q [QUEUE_NUM];
    logic                q_head_next_pt_q [QUEUE_NUM];
    logic [ADDR_W-1:0]   q_head_next2_q   [QUEUE_NUM];
    logic                q_tail_ph_q      [QUEUE_NUM];
    logic                q_tail_pt_q      [QUEUE_NUM];

    // ★ 每单播队列: 在队“真实单播完整包”计数
    logic [CNT_W-1:0]    q_uni_pkt_backlog_q [QUEUE_NUM];

    //========================================================================
    // free 链寄存器 (两级预取)
    //========================================================================
    logic [ADDR_W-1:0]   free_head_q;
    logic [ADDR_W-1:0]   free_tail_q;
    logic [CNT_W-1:0]    free_cnt_q;
    logic [ADDR_W-1:0]   free_head_next_q;
    logic [ADDR_W-1:0]   free_head_next2_q;

    assign lle_free_head  = free_head_q;
    assign lle_free_empty = (free_cnt_q == '0);

    //========================================================================
    // ★ B2 多播槽 (单槽)
    //========================================================================
    logic                mc_valid_q;
    logic [PORT_NUM-1:0]  mc_dst_bitmap_q;
    logic [QID_W-1:0]     mc_carry_qid_q  [PORT_NUM];   // 各端口承载单播 QID
    logic [ADDR_W-1:0]    mc_cells_q      [MAX_MC_CELLS];// 多播帧 cell 地址列表 (报文序)
    logic [MC_IDX_W-1:0]  mc_ncell_q;                    // 多播帧 cell 数
    logic [MC_IDX_W-1:0]  mc_wr_idx_q;                   // 入队写指针
    logic [MC_IDX_W-1:0]  mc_rd_idx_q     [PORT_NUM];    // 每端口读指针
    logic                 mc_rd_done_q    [PORT_NUM];
    logic                 mc_rcy_done_q   [PORT_NUM];
    logic [CNT_W-1:0]     mc_pend_uni_q   [PORT_NUM];    // 多播前面待出单播包数

    // 多播整帧还链 walk FSM
    logic                 mc_rel_active_q;
    logic [MC_IDX_W-1:0]  mc_rel_idx_q;

    assign mc_busy = mc_valid_q;

    // 各端口承载单播队列号 (组合): carry_qid[p] = p*TC_NUM + 多播帧TC
    //   ★ 多播帧只有一个 TC/优先级, 在每个目的端口都落到该 TC 的队列上 → 与 QM 调度一致。
    //     (QM 出队某端口的 该TC队列 → MMU 在此队列上 splice 出多播报文)
    logic [QID_W-1:0] carry_qid_c [PORT_NUM];
    genvar gp;
    generate
        for (gp = 0; gp < PORT_NUM; gp++) begin : g_carry_qid
            assign carry_qid_c[gp] = QID_W'(gp*TC_NUM) +
                                     QID_W'(lle_alloc_mcast_tc);
        end
    endgenerate

    //========================================================================
    // Recycle FIFO (还链 cell 缓冲)
    //========================================================================
    logic [ADDR_W-1:0]   rcy_fifo_mem [RCY_FIFO_DEPTH];
    logic [$clog2(RCY_FIFO_DEPTH+1)-1:0] rcy_fifo_cnt_q;
    logic [$clog2(RCY_FIFO_DEPTH)-1:0]   rcy_fifo_wptr_q, rcy_fifo_rptr_q;
    logic                rcy_fifo_full, rcy_fifo_empty;
    assign rcy_fifo_full  = (rcy_fifo_cnt_q == RCY_FIFO_DEPTH);
    assign rcy_fifo_empty = (rcy_fifo_cnt_q == '0);

    logic [ADDR_W-1:0]   rcy_cell;
    assign rcy_cell = rcy_fifo_mem[rcy_fifo_rptr_q];

    logic do_push, do_pop;

    //========================================================================
    // Next-Ptr SRAM (1R1W) 互连
    //========================================================================
    logic                npr_r_en;
    logic [ADDR_W-1:0]   npr_r_addr;
    logic [ENTRY_W-1:0]  npr_r_data;
    logic                npr_w_en;
    logic [ADDR_W-1:0]   npr_w_addr;
    logic [ENTRY_W-1:0]  npr_w_data;

    //========================================================================
    // 建链 FSM
    //========================================================================
    typedef enum logic [1:0] {ST_IDLE=2'b00, ST_BUILD=2'b01, ST_DONE=2'b10} build_st_e;
    build_st_e          build_st_q;
    logic [ADDR_W-1:0]  build_idx_q;
    logic               build_active;
    assign build_active = (build_st_q == ST_BUILD);

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            build_st_q      <= ST_IDLE;
            build_idx_q     <= '0;
            init_build_done <= 1'b0;
        end
        else begin
            case (build_st_q)
                ST_IDLE: begin
                    init_build_done <= 1'b0;
                    if (init_build_req) begin
                        build_st_q  <= ST_BUILD;
                        build_idx_q <= '0;
                    end
                end
                ST_BUILD: begin
                    if (build_idx_q == CELL_NUM-1) build_st_q <= ST_DONE;
                    build_idx_q <= build_idx_q + 1'b1;
                end
                ST_DONE: begin
                    init_build_done <= 1'b1;
                    build_st_q      <= ST_IDLE;
                end
                default: build_st_q <= ST_IDLE;
            endcase
        end
    end

    //========================================================================
    // 多播出队目标端口/承载判定 (对当前 lle_deq_queue_id, 组合)
    //========================================================================
    logic [QID_W-1:0]   deq_port_full;
    logic               deq_is_uni;
    logic [PORT_W-1:0]  deq_port;
    logic               is_carry_deq;
    logic               mc_take_deq;

    assign deq_port_full = lle_deq_queue_id >> Q_PER_PORT_LOG;
    assign deq_is_uni    = (lle_deq_queue_id < (PORT_NUM*TC_NUM));
    assign deq_port      = deq_is_uni ? deq_port_full[PORT_W-1:0] : '0;
    assign is_carry_deq  = deq_is_uni & mc_valid_q & mc_dst_bitmap_q[deq_port] &
                           ~mc_rd_done_q[deq_port] &
                           (lle_deq_queue_id == mc_carry_qid_q[deq_port]);
    assign mc_take_deq   = is_carry_deq & (mc_pend_uni_q[deq_port] == '0);

    //========================================================================
    // 事务请求信号
    //========================================================================
    logic enq_req_int, enq_is_uni;
    logic deq_req_int, deq_need_sram;
    logic rcy_req_int;

    assign enq_is_uni  = ~lle_alloc_is_mcast;
    assign enq_req_int = lle_alloc_fire & ~build_active & ~lle_free_empty;

    // deq: 多播 take 或单播队列非空
    assign deq_req_int   = lle_deq_fire & ~build_active &
                           (mc_take_deq | (q_cell_cnt_q[lle_deq_queue_id] != '0));
    // 仅单播走链且 cnt>=3 时需要 SRAM 读; 多播 take 不读 SRAM
    assign deq_need_sram = deq_req_int & ~mc_take_deq &
                           (q_cell_cnt_q[lle_deq_queue_id] >= 3);
    assign rcy_req_int   = ~rcy_fifo_empty & ~build_active;

    //========================================================================
    // 三选一仲裁: P0 deq > P1 enq > P2 rcy
    //========================================================================
    logic deq_grant, enq_grant, rcy_grant;
    assign deq_grant = deq_req_int;
    assign enq_grant = enq_req_int & ~build_active & ~deq_need_sram;
    assign rcy_grant = rcy_req_int & ~build_active & ~deq_need_sram & ~enq_grant;

    assign lle_alloc_ready = ~build_active & ~lle_free_empty & ~deq_need_sram;

    //========================================================================
    // 还链 push 源仲裁: 外部单播回收 优先; 多播整帧还链(walk) 让位
    //========================================================================
    logic               ext_free_push;   // 外部单播回收 push
    logic               mc_rel_push;      // 多播整帧还链 push
    logic [ADDR_W-1:0]  push_cell;
    logic [QID_W-1:0]   push_qid;

    assign ext_free_push = lle_free_req & ~rcy_fifo_full & ~build_active;
    assign mc_rel_push   = mc_rel_active_q & ~ext_free_push & ~rcy_fifo_full & ~build_active;

    assign push_cell = ext_free_push ? lle_free_addr : mc_cells_q[mc_rel_idx_q];
    assign push_qid  = ext_free_push ? lle_free_queue_id : MC_QID[QID_W-1:0];

    assign do_push = ext_free_push | mc_rel_push;
    assign do_pop  = rcy_grant;

    //========================================================================
    // SRAM 读写口驱动
    //========================================================================
    logic [ADDR_W-1:0]  build_addr;
    logic [ENTRY_W-1:0] build_wdata;
    assign build_addr  = build_idx_q;
    assign build_wdata = {(build_idx_q == CELL_NUM-1) ? build_idx_q : (build_idx_q + 1'b1),
                          1'b0, 1'b0};

    logic [ADDR_W-1:0] enq_cell;
    assign enq_cell = free_head_q;

    // pend 流水寄存器
    logic               deq_pend_q;
    logic [QID_W-1:0]   deq_pend_qid_q;
    logic               enq_pend_q;
    logic               deq_pend_tail_q;
    logic               deq_pend_tail_ph_q;
    logic               deq_pend_tail_pt_q;

    logic deq_pend_same_q;
    logic enq_bypass;
    assign deq_pend_same_q = deq_pend_q & deq_grant & ~mc_take_deq &
                             (deq_pend_qid_q == lle_deq_queue_id);
    assign enq_bypass      = enq_pend_q & enq_grant;

    logic [ADDR_W-1:0] enq_sram_rd_addr;
    assign enq_sram_rd_addr = enq_bypass ? npr_r_data[2 +: ADDR_W] : free_head_next2_q;

    logic [ADDR_W-1:0] deq_sram_rd_addr;
    assign deq_sram_rd_addr = deq_pend_same_q ? npr_r_data[2 +: ADDR_W]
                                              : q_head_next2_q[lle_deq_queue_id];

    always_comb begin
        npr_r_en   = 1'b0;
        npr_r_addr = '0;
        npr_w_en   = 1'b0;
        npr_w_addr = '0;
        npr_w_data = '0;

        if (build_active) begin
            npr_w_en   = 1'b1;
            npr_w_addr = build_addr;
            npr_w_data = build_wdata;
        end
        else if (deq_grant && deq_need_sram) begin
            npr_r_en   = 1'b1;
            npr_r_addr = deq_sram_rd_addr;
        end
        else if (enq_grant) begin
            npr_r_en   = 1'b1;
            npr_r_addr = enq_sram_rd_addr;
            // ★ relink: 写 OLD tail.next 指向新 cell。单播链 [0..31] 与多播链 [MC_QID]
            //   都是真实 SRAM 链, 走同一 relink (chain33 亦存 SRAM, 满足 spec)。
            if (q_cell_cnt_q[lle_alloc_queue_id] != '0) begin
                npr_w_en   = 1'b1;
                npr_w_addr = q_tail_q[lle_alloc_queue_id];
                npr_w_data = {enq_cell,
                              q_tail_ph_q[lle_alloc_queue_id],
                              q_tail_pt_q[lle_alloc_queue_id]};
            end
        end
        else if (rcy_grant) begin
            npr_w_en   = 1'b1;
            npr_w_addr = free_tail_q;
            npr_w_data = {rcy_cell, 1'b0, 1'b0};
        end
    end

    next_ptr_sram_1r1w #(.CELL_NUM(CELL_NUM), .DATA_W(ENTRY_W)) u_npr (
        .clk_core(clk_core), .rst_core_n(rst_core_n),
        .r_en(npr_r_en), .r_addr(npr_r_addr), .r_data(npr_r_data),
        .w_en(npr_w_en), .w_addr(npr_w_addr), .w_data(npr_w_data)
    );

    //========================================================================
    // Pend 流水寄存器
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            deq_pend_q     <= 1'b0;
            deq_pend_qid_q <= '0;
            enq_pend_q     <= 1'b0;
            deq_pend_tail_q    <= 1'b0;
            deq_pend_tail_ph_q <= 1'b0;
            deq_pend_tail_pt_q <= 1'b0;
        end
        else begin
            deq_pend_q     <= deq_grant & deq_need_sram;
            deq_pend_qid_q <= lle_deq_queue_id;
            enq_pend_q     <= enq_grant;
            deq_pend_tail_q    <= (deq_grant & deq_need_sram) &
                                  (deq_sram_rd_addr == q_tail_q[lle_deq_queue_id]);
            deq_pend_tail_ph_q <= q_tail_ph_q[lle_deq_queue_id];
            deq_pend_tail_pt_q <= q_tail_pt_q[lle_deq_queue_id];
        end
    end

    //========================================================================
    // 多播回收下溢检测 (对已完成端口重复回收)
    //========================================================================
    assign mcast_underflow = mc_rcy_vld & mc_valid_q & mc_rcy_done_q[mc_rcy_port];

    // 释放判决: 所有目的端口 rd_done & rcy_done
    logic all_read, all_recycled, mc_release_start;
    always_comb begin
        all_read     = 1'b1;
        all_recycled = 1'b1;
        for (int p = 0; p < PORT_NUM; p++) begin
            if (mc_dst_bitmap_q[p]) begin
                if (!mc_rd_done_q[p])  all_read     = 1'b0;
                if (!mc_rcy_done_q[p]) all_recycled = 1'b0;
            end
        end
    end
    // 启动整帧还链 walk (还未在还链中)
    assign mc_release_start = mc_valid_q & all_read & all_recycled & ~mc_rel_active_q;

    //========================================================================
    // 主状态更新
    //========================================================================
    integer q, i, pp;
    logic uni_pkt_tail_deq;    // 本拍出队的是一个真实单播包尾
    assign uni_pkt_tail_deq = deq_grant & ~mc_take_deq & q_head_pt_q[lle_deq_queue_id];

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (q = 0; q < QUEUE_NUM; q++) begin
                q_head_q[q]<='0; q_tail_q[q]<='0; q_cell_cnt_q[q]<='0;
                q_head_ph_q[q]<=1'b0; q_head_pt_q[q]<=1'b0;
                q_head_next_q[q]<='0; q_head_next_ph_q[q]<=1'b0; q_head_next_pt_q[q]<=1'b0;
                q_head_next2_q[q]<='0; q_tail_ph_q[q]<=1'b0; q_tail_pt_q[q]<=1'b0;
                q_uni_pkt_backlog_q[q]<='0;
            end
            free_head_q<='0; free_tail_q<='0; free_cnt_q<='0;
            free_head_next_q<='0; free_head_next2_q<='0;
            rcy_fifo_cnt_q<='0; rcy_fifo_wptr_q<='0; rcy_fifo_rptr_q<='0;
            for (i = 0; i < RCY_FIFO_DEPTH; i++) rcy_fifo_mem[i]<='0;
            // 多播槽复位
            mc_valid_q<=1'b0; mc_dst_bitmap_q<='0; mc_ncell_q<='0; mc_wr_idx_q<='0;
            mc_rel_active_q<=1'b0; mc_rel_idx_q<='0;
            for (pp = 0; pp < PORT_NUM; pp++) begin
                mc_carry_qid_q[pp]<='0; mc_rd_idx_q[pp]<='0;
                mc_rd_done_q[pp]<=1'b0; mc_rcy_done_q[pp]<=1'b0; mc_pend_uni_q[pp]<='0;
            end
            for (i = 0; i < MAX_MC_CELLS; i++) mc_cells_q[i]<='0;
        end
        else if (build_st_q == ST_DONE) begin
            for (q = 0; q < QUEUE_NUM; q++) begin
                q_head_q[q]<='0; q_tail_q[q]<='0; q_cell_cnt_q[q]<='0;
                q_head_ph_q[q]<=1'b0; q_head_pt_q[q]<=1'b0;
                q_head_next_q[q]<='0; q_head_next_ph_q[q]<=1'b0; q_head_next_pt_q[q]<=1'b0;
                q_head_next2_q[q]<='0; q_tail_ph_q[q]<=1'b0; q_tail_pt_q[q]<=1'b0;
                q_uni_pkt_backlog_q[q]<='0;
            end
            free_head_q       <= '0;
            free_head_next_q  <= {{(ADDR_W-1){1'b0}}, 1'b1};
            free_head_next2_q <= {{(ADDR_W-2){1'b0}}, 2'b10};
            free_tail_q       <= CELL_NUM[ADDR_W-1:0] - 1'b1;
            free_cnt_q        <= CELL_NUM[CNT_W-1:0];
            rcy_fifo_cnt_q<='0; rcy_fifo_wptr_q<='0; rcy_fifo_rptr_q<='0;
            mc_valid_q<=1'b0; mc_dst_bitmap_q<='0; mc_ncell_q<='0; mc_wr_idx_q<='0;
            mc_rel_active_q<=1'b0; mc_rel_idx_q<='0;
            for (pp = 0; pp < PORT_NUM; pp++) begin
                mc_carry_qid_q[pp]<='0; mc_rd_idx_q[pp]<='0;
                mc_rd_done_q[pp]<=1'b0; mc_rcy_done_q[pp]<=1'b0; mc_pend_uni_q[pp]<='0;
            end
        end
        else begin
            //================================================================
            // ENQ 落地
            //================================================================
            if (enq_grant) begin
                // free 链两级预取推进 (单播/多播都消耗 free)
                free_head_q <= free_head_next_q;
                if (enq_bypass) free_head_next_q <= npr_r_data[2 +: ADDR_W];
                else            free_head_next_q <= free_head_next2_q;

                //-------- 挂链 (单播链 [0..31] 与多播链 [MC_QID] 同构, 都写 SRAM) --------
                //   ★ B2: chain33 亦为真实 SRAM 链, 走同一挂链/预取逻辑 (满足 spec)。
                q_tail_q[lle_alloc_queue_id] <= enq_cell;
                if (q_cell_cnt_q[lle_alloc_queue_id] == '0) begin
                    q_head_q[lle_alloc_queue_id]         <= enq_cell;
                    q_head_ph_q[lle_alloc_queue_id]      <= lle_set_pkt_head;
                    q_head_pt_q[lle_alloc_queue_id]      <= lle_set_pkt_tail;
                    q_head_next_q[lle_alloc_queue_id]    <= free_head_next_q;
                    q_head_next_ph_q[lle_alloc_queue_id] <= 1'b0;
                    q_head_next_pt_q[lle_alloc_queue_id] <= 1'b0;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 1) begin
                    q_head_next_q[lle_alloc_queue_id]    <= enq_cell;
                    q_head_next_ph_q[lle_alloc_queue_id] <= lle_set_pkt_head;
                    q_head_next_pt_q[lle_alloc_queue_id] <= lle_set_pkt_tail;
                    q_head_next2_q[lle_alloc_queue_id]   <= free_head_next_q;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 2) begin
                    q_head_next2_q[lle_alloc_queue_id]   <= enq_cell;
                end
                q_tail_ph_q[lle_alloc_queue_id] <= lle_set_pkt_head;
                q_tail_pt_q[lle_alloc_queue_id] <= lle_set_pkt_tail;

                if (enq_is_uni) begin
                    // ★ 真实单播完整包在队计数: EOF 入队 +1
                    //   (若同队同拍还有 pkt_tail 出队, 下面出队分支 -1, 净变化合并)
                    if (lle_set_pkt_tail && !(uni_pkt_tail_deq && (lle_deq_queue_id == lle_alloc_queue_id)))
                        q_uni_pkt_backlog_q[lle_alloc_queue_id] <= q_uni_pkt_backlog_q[lle_alloc_queue_id] + 1'b1;
                end
                else begin
                    //-------- 多播: 额外写 cell-list 镜像 (读加速) + 建槽 --------
                    mc_cells_q[mc_wr_idx_q] <= enq_cell;
                    if (lle_set_pkt_head) begin
                        // SOF: 建槽 + 逐端口快照插入位置
                        mc_valid_q      <= 1'b1;
                        mc_dst_bitmap_q <= lle_alloc_mcast_bitmap;
                        mc_wr_idx_q     <= {{(MC_IDX_W-1){1'b0}}, 1'b1};
                        for (pp = 0; pp < PORT_NUM; pp++) begin
                            mc_rd_idx_q[pp]   <= '0;
                            mc_rd_done_q[pp]  <= ~lle_alloc_mcast_bitmap[pp]; // 非目的直接 done
                            mc_rcy_done_q[pp] <= ~lle_alloc_mcast_bitmap[pp];
                            // 承载单播队列号 = 端口*TC_NUM + 该端口多播承载 TC
                            mc_carry_qid_q[pp]<= carry_qid_c[pp];
                            // 快照: 该承载队列当前在队单播完整包数
                            mc_pend_uni_q[pp] <= q_uni_pkt_backlog_q[carry_qid_c[pp]];
                        end
                    end
                    else begin
                        mc_wr_idx_q <= mc_wr_idx_q + 1'b1;
                    end
                    if (lle_set_pkt_tail) begin
                        // EOF: 锁定 cell 数
                        mc_ncell_q <= lle_set_pkt_head ? {{(MC_IDX_W-1){1'b0}}, 1'b1}
                                                       : (mc_wr_idx_q + 1'b1);
                    end
                end
            end

            // enq_pend T+1: 回填 free_head_next2
            if (enq_pend_q) free_head_next2_q <= npr_r_data[2 +: ADDR_W];

            //================================================================
            // DEQ 落地
            //================================================================
            if (deq_grant) begin
                if (mc_take_deq) begin
                    //-------- 多播 take: 推进该端口读索引 --------
                    if ((mc_rd_idx_q[deq_port] + 1'b1) == mc_ncell_q)
                        mc_rd_done_q[deq_port] <= 1'b1;   // 读到最后一个 cell
                    mc_rd_idx_q[deq_port] <= mc_rd_idx_q[deq_port] + 1'b1;
                end
                else begin
                    //-------- 单播走链 (两级预取) --------
                    q_head_q[lle_deq_queue_id] <= q_head_next_q[lle_deq_queue_id];
                    if (deq_pend_same_q) begin
                        if (deq_pend_tail_q) begin
                            q_head_ph_q[lle_deq_queue_id] <= deq_pend_tail_ph_q;
                            q_head_pt_q[lle_deq_queue_id] <= deq_pend_tail_pt_q;
                        end
                        else begin
                            q_head_ph_q[lle_deq_queue_id] <= npr_r_data[PH_BIT];
                            q_head_pt_q[lle_deq_queue_id] <= npr_r_data[PT_BIT];
                        end
                        q_head_next_q[lle_deq_queue_id] <= npr_r_data[2 +: ADDR_W];
                    end
                    else begin
                        q_head_ph_q[lle_deq_queue_id] <= q_head_next_ph_q[lle_deq_queue_id];
                        q_head_pt_q[lle_deq_queue_id] <= q_head_next_pt_q[lle_deq_queue_id];
                        q_head_next_q[lle_deq_queue_id] <= q_head_next2_q[lle_deq_queue_id];
                    end

                    // ★ 出到真实单播包尾: backlog--, 若是承载队列 pend_uni--
                    if (uni_pkt_tail_deq &&
                        !(enq_grant && enq_is_uni && lle_set_pkt_tail && (lle_alloc_queue_id == lle_deq_queue_id)))
                        q_uni_pkt_backlog_q[lle_deq_queue_id] <= q_uni_pkt_backlog_q[lle_deq_queue_id] - 1'b1;
                    if (uni_pkt_tail_deq && is_carry_deq && (mc_pend_uni_q[deq_port] != '0))
                        mc_pend_uni_q[deq_port] <= mc_pend_uni_q[deq_port] - 1'b1;
                end
            end

            // deq_pend T+1: 回填 next_ph/pt 和 next2
            if (deq_pend_q) begin
                if (deq_pend_tail_q) begin
                    q_head_next_ph_q[deq_pend_qid_q] <= deq_pend_tail_ph_q;
                    q_head_next_pt_q[deq_pend_qid_q] <= deq_pend_tail_pt_q;
                end
                else begin
                    q_head_next_ph_q[deq_pend_qid_q] <= npr_r_data[PH_BIT];
                    q_head_next_pt_q[deq_pend_qid_q] <= npr_r_data[PT_BIT];
                    q_head_next2_q[deq_pend_qid_q]   <= npr_r_data[2 +: ADDR_W];
                end
            end

            //================================================================
            // q_cell_cnt: 入队 (单播链或多播链 MC_QID) +1; 出队 (仅真实单播走链) -1。
            //   多播出队 (mc_take) 不推进 MC_QID 队头、不减 MC_QID cnt (多端口共享读);
            //   MC_QID cnt 只在整帧还链完成时清 0 (见下面 release 分支)。
            //   注: 多播 alloc 到 MC_QID, 与单播 deq 到某单播 qid, 二者 qid 必不同 →
            //       无 "同 queue 同拍" 冲突; 仅单播自环 (alloc==deq) 需净不变处理。
            //================================================================
            if (enq_grant && enq_is_uni && deq_grant && ~mc_take_deq &&
                (lle_alloc_queue_id == lle_deq_queue_id)) begin
                // 同 (单播) queue 同拍入+出: 净不变
            end
            else begin
                if (enq_grant)                                    // 单播链或 MC_QID 均 +1
                    q_cell_cnt_q[lle_alloc_queue_id] <= q_cell_cnt_q[lle_alloc_queue_id] + 1'b1;
                if (deq_grant && ~mc_take_deq)                    // 仅真实单播出队 -1
                    q_cell_cnt_q[lle_deq_queue_id]   <= q_cell_cnt_q[lle_deq_queue_id]   - 1'b1;
            end

            //================================================================
            // 多播逐端口回收通知
            //================================================================
            if (mc_rcy_vld && mc_valid_q)
                mc_rcy_done_q[mc_rcy_port] <= 1'b1;

            //================================================================
            // 多播整帧还链 walk
            //================================================================
            if (mc_release_start) begin
                mc_rel_active_q <= 1'b1;
                mc_rel_idx_q    <= '0;
            end
            else if (mc_rel_active_q) begin
                if (mc_rel_push) begin
                    if ((mc_rel_idx_q + 1'b1) == mc_ncell_q) begin
                        // 最后一个 cell 已 push → 收槽
                        mc_rel_active_q <= 1'b0;
                        mc_valid_q      <= 1'b0;
                        mc_dst_bitmap_q <= '0;
                        mc_ncell_q      <= '0;
                        mc_wr_idx_q     <= '0;
                        // 清空 chain33 的 SRAM 链寄存器 (下条多播帧从空链重建)
                        q_head_q[MC_QID]    <= '0;
                        q_tail_q[MC_QID]    <= '0;
                        q_cell_cnt_q[MC_QID]<= '0;
                        q_tail_ph_q[MC_QID] <= 1'b0;
                        q_tail_pt_q[MC_QID] <= 1'b0;
                        for (pp = 0; pp < PORT_NUM; pp++) begin
                            mc_rd_done_q[pp]  <= 1'b0;
                            mc_rcy_done_q[pp] <= 1'b0;
                            mc_pend_uni_q[pp] <= '0;
                            mc_rd_idx_q[pp]   <= '0;
                        end
                    end
                    mc_rel_idx_q <= mc_rel_idx_q + 1'b1;
                end
            end

            //================================================================
            // Recycle FIFO push + pop
            //================================================================
            if (do_push) begin
                rcy_fifo_mem[rcy_fifo_wptr_q] <= push_cell;
                rcy_fifo_wptr_q <= rcy_fifo_wptr_q + 1'b1;
            end
            if (do_pop) begin
                rcy_fifo_rptr_q <= rcy_fifo_rptr_q + 1'b1;
                free_tail_q     <= rcy_cell;
            end

            unique case ({do_push, do_pop})
                2'b10:   rcy_fifo_cnt_q <= rcy_fifo_cnt_q + 1'b1;
                2'b01:   rcy_fifo_cnt_q <= rcy_fifo_cnt_q - 1'b1;
                default: ;
            endcase

            // free_cnt: enq -1 (含多播 cell), recycle push +1
            unique case ({enq_grant, do_push})
                2'b10:   free_cnt_q <= free_cnt_q - 1'b1;
                2'b01:   free_cnt_q <= free_cnt_q + 1'b1;
                default: ;
            endcase
        end
    end

    //========================================================================
    // 对外组合输出 (含多播 splice 覆盖)
    //========================================================================
    logic [ADDR_W-1:0] mc_cur_cell;
    logic              mc_cur_ph, mc_cur_pt;
    assign mc_cur_cell = mc_cells_q[mc_rd_idx_q[deq_port]];
    assign mc_cur_ph   = (mc_rd_idx_q[deq_port] == '0);
    assign mc_cur_pt   = ((mc_rd_idx_q[deq_port] + 1'b1) == mc_ncell_q);

    assign lle_qhead          = mc_take_deq ? mc_cur_cell : q_head_q[lle_deq_queue_id];
    assign lle_qhead_pkt_head = mc_take_deq ? mc_cur_ph   : q_head_ph_q[lle_deq_queue_id];
    assign lle_qhead_pkt_tail = mc_take_deq ? mc_cur_pt   : q_head_pt_q[lle_deq_queue_id];
    // 空: 多播 take 时非空; 否则看单播 cnt (承载队列 pend_uni>0 时必有单播 cell, cnt>0)
    assign lle_q_empty        = mc_take_deq ? 1'b0 : (q_cell_cnt_q[lle_deq_queue_id] == '0);

    //========================================================================
    // ★ B2: 32 条常规队列 empty 向量 (给 QM 调度用)
    //   q_empty[q] = ~( 实际单播 cnt[q]!=0  |  该 q 是某目的端口承载队列且多播未被该端口读完 )
    //   多播只计入【各目的端口的承载队列】(每端口 1 条), 不计入全部 32 条。
    //========================================================================
    always_comb begin
        for (int qq = 0; qq < PORT_NUM*TC_NUM; qq++) begin
            automatic int pq = qq >> Q_PER_PORT_LOG;
            automatic logic mc_here = mc_valid_q & mc_dst_bitmap_q[pq] &
                                      ~mc_rd_done_q[pq] &
                                      (QID_W'(qq) == mc_carry_qid_q[pq]);
            q_empty_vec[qq] = ~((q_cell_cnt_q[qq] != '0) | mc_here);
        end
    end

    assign lle_free_grant = lle_free_req & ~build_active & ~rcy_fifo_full;
    assign lle_free_done  = rcy_grant;

    localparam int Q_PP_LOG = $clog2(TC_NUM);

    // alloc 事件 (单播用 alloc_queue_id; 多播用 MC_QID → occ 只在 MC_QID 计一次/cell)
    assign lle_alloc_evt   = enq_grant;
    assign evt_queue_id    = lle_alloc_is_mcast ? MC_QID[QID_W-1:0] : lle_alloc_queue_id;
    assign evt_egress_port = lle_alloc_is_mcast ? '0
                             : (lle_alloc_queue_id >> Q_PP_LOG);

    // free 事件: push 那拍 (单播用其 qid; 多播还链用 MC_QID)
    assign lle_free_evt          = do_push;
    assign evt_free_queue_id     = push_qid;
    assign evt_free_egress_port  = (push_qid < (PORT_NUM*TC_NUM)) ? (push_qid >> Q_PP_LOG) : '0;

`ifdef SIM_BEHAVIOR_SRAM
    always_ff @(posedge clk_core) begin
        if (rst_core_n && lle_free_req && rcy_fifo_full && !build_active)
            $warning("[lle] recycle FIFO full: free request ignored");
    end
    always_ff @(posedge clk_core) begin
        if (rst_core_n && enq_grant && (free_cnt_q == '0))
            $error("[lle] free pool underflow: alloc when free_cnt==0");
    end
    always_ff @(posedge clk_core) begin
        if (rst_core_n && mcast_underflow)
            $error("[lle] mcast recycle underflow: port %0d already done", mc_rcy_port);
    end
    always_ff @(posedge clk_core) begin
        if (rst_core_n && enq_grant && lle_alloc_is_mcast && lle_set_pkt_head && mc_valid_q)
            $error("[lle] mcast enqueue while slot busy (should be gated by mc_busy)");
    end
`endif

endmodule


//============================================================================
// 1R1W Next-Ptr SRAM 行为模型 (综合时换 vendor 1R1W SRAM)
//   - 1 读口 + 1 写口, 同拍可并行; 同拍读写同一地址: read-first
//============================================================================
module next_ptr_sram_1r1w #(
    parameter int CELL_NUM = 8192,
    parameter int DATA_W   = 15,
    localparam int ADDR_W  = $clog2(CELL_NUM)
)(
    input  logic              clk_core,
    input  logic              rst_core_n,
    input  logic              r_en,
    input  logic [ADDR_W-1:0] r_addr,
    output logic [DATA_W-1:0] r_data,
    input  logic              w_en,
    input  logic [ADDR_W-1:0] w_addr,
    input  logic [DATA_W-1:0] w_data
);
    logic [DATA_W-1:0] mem [CELL_NUM];
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) r_data <= '0;
        else if (r_en)   r_data <= mem[r_addr];
    end
    always_ff @(posedge clk_core) begin
        if (w_en) mem[w_addr] <= w_data;
    end
endmodule
```


## enq

```
//============================================================================
// Module      : enqueue_ctrl  (Enqueue Control)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Description : 入队路径控制 (控制平面)。单拍命令式, 不直接访问指针存储。
//               T0: 收 QM 入队请求 → 组合查 Occupancy 占用判决(当拍返回) →
//                   接收则取 lle_free_head 作分配地址、发一拍 lle_alloc_fire 命令
//                   (挂链/计数/ref 由 LLE 流水) → 判决/地址/sof/eof 在末沿寄存。
//               T1: 输出 alloc_* 结果给 QM。
//               含整帧丢弃 FSM: 本帧某 cell 判丢即置 alloc_full_frame_drop,
//               本帧后续 cell 全丢。组播 ref_count 初值随命令下发, 单/组播同 1 拍。
//               不做 WRED (WRED 在 QM, QM 发请求前已完成)。
//               静态预留池按队列(queue_id)记账, egress_port 仅供端口级判决聚合。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module enqueue_ctrl #(
    parameter int CELL_NUM  = 8192,
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,     // 每端口 TC 数
    parameter int REF_W     = 3,
    parameter int PKT_CELL_W = 4,    // enq_cell_num 位宽 (本包 cell 数)
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,   // 单播 P*T + 多播 (free 链在 LLE 内)
    localparam int ADDR_W   = $clog2(CELL_NUM),
    localparam int QID_W    = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W   = $clog2(PORT_NUM-1)+1
)(
    //------------------------------------------------------------------------
    // 时钟复位 / 初始化 (公共)
    //------------------------------------------------------------------------
    input  logic                  clk_core,
    input  logic                  rst_core_n,
    input  logic                  init_done,           // =0 拒收 enq_req

    //------------------------------------------------------------------------
    // 与 QM 的接口 (外部, 经 MMU 顶层)
    //------------------------------------------------------------------------
    input  logic                  enq_req,             // 入队请求有效
    input  logic [QID_W-1:0]      enq_queue_id,        // 目标队列号
    input  logic [PORT_W-1:0]     enq_egress_port,     // 出端口 ID (=queue_id/8)
    input  logic [PKT_CELL_W-1:0] enq_cell_num,        // ★ 本包 cell 数(SOF 有效, 入队前预判用)
    input  logic                  enq_is_mcast,        // 组播标志
    input  logic [PORT_NUM-1:0]   enq_mcast_bitmap,    // 组播出端口位图
    input  logic [$clog2(TC_NUM)-1:0] enq_mcast_tc,    // ★ B2: 组播帧 TC (决定各端口承载队列)
    input  logic                  enq_sof,             // 报文首段
    input  logic                  enq_eof,             // 报文尾段
    output logic                  enq_ready,           // 可接请求(init_done 后恒高)
    output logic                  enq_predict_drop,    // ★ 入队前预判: 本包会否触发 alloc_drop(组合当拍返回)
    output logic                  alloc_valid,         // 结果有效
    output logic [ADDR_W-1:0]     alloc_cell_addr,     // 分配地址
    output logic                  alloc_drop_ind,      // 丢包指示(高水位/空闲池空兜底)
    output logic                  alloc_sram_flag,     // 内部 SRAM 存储标志
    output logic                  alloc_pkt_head,      // 报文头 (= enq_sof)
    output logic                  alloc_pkt_tail,      // 报文尾 (= enq_eof)
    output logic                  alloc_full_frame_drop, // 整帧丢弃指示

    //------------------------------------------------------------------------
    // 与 Occupancy & Pool Mgr 的接口 (内部, 组合返回支撑 1 拍)
    //   按【当前入队队列/端口】精确判决: 透传 queue_id/egress_port 给 occ,
    //   occ 据此判 该队列/端口 高水位 + 静态穿透, 组合返回。
    //------------------------------------------------------------------------
    output logic                  occ_query_vld,       // 发起占用判决查询
    output logic [QID_W-1:0]      occ_query_queue_id,  // 待判决队列号
    output logic [PORT_W-1:0]     occ_query_egress_port, // 待判决出端口
    output logic [PKT_CELL_W-1:0] occ_query_cell_num,  // 待预判本包 cell 数(透传 enq_cell_num)
    input  logic                  occ_accept,          // 判决=接收
    input  logic                  occ_drop,            // 判决=丢弃(高水位兜底)
    input  logic                  occ_use_static,      // 记静态池(=1)/动态池(=0)
    input  logic                  occ_no_free,         // 空闲池已空(强制丢弃)
    input  logic                  occ_predict_drop,    // occ 组合返回的入队前预判结果

    //------------------------------------------------------------------------
    // 与 Link-List Engine (LLE) 的接口 (内部, 单拍命令式分配+挂链)
    //   ★ lle_alloc_ready: LLE 本拍可受理 alloc。
    //     - LLE 仲裁中 deq 占 SRAM 时 = 0, 本模块当拍不发 fire, QM 自动等下拍;
    //     - build 期间 / free 池空时也 = 0。
    //------------------------------------------------------------------------
    input  logic [ADDR_W-1:0]     lle_free_head,       // 当前空闲链头(T0 当拍取)
    input  logic                  lle_free_empty,      // 空闲链空
    input  logic                  lle_alloc_ready,     // LLE 本拍可受理 alloc (含 ~deq 抢占 / ~build / ~free 空)
    input  logic                  mc_busy,             // ★ B2: 多播槽占用中 (LLE 提供), 置1时新多播整帧丢弃
    output logic                  lle_alloc_fire,      // 分配+挂链命令(一拍脉冲)
    output logic [QID_W-1:0]      lle_alloc_queue_id,  // 挂链目标队列
    output logic [ADDR_W-1:0]     lle_alloc_addr,      // 本次分配地址(=lle_free_head)
    output logic                  lle_set_pkt_head,    // 写 pkt_head (= enq_sof)
    output logic                  lle_set_pkt_tail,    // 写 pkt_tail (= enq_eof)
    output logic                  lle_alloc_is_mcast,  // 组播标志
    output logic [PORT_NUM-1:0]   lle_alloc_mcast_bitmap, // ★ B2: 组播目的端口位图 → LLE
    output logic [$clog2(TC_NUM)-1:0] lle_alloc_mcast_tc, // ★ B2: 组播帧 TC → LLE (定承载队列)
    output logic                  mcast_busy_drop      // ★ B2: 本拍因多播槽占用而丢弃多播帧
);

    //========================================================================
    // 握手: init_done 后, 还要看 LLE 本拍是否能受理 alloc (deq 抢占时 ready=0)
    //   - enq_ready 反馈给 QM: 0 时 QM 当拍不发 enq_req, 自动重试;
    //   - enq_fire 内部判: enq_req 且 init_done 且 lle 可受理。
    //========================================================================
    assign enq_ready = init_done & lle_alloc_ready;

    // 本拍是否有有效入队请求 (握手成立)
    logic enq_fire;
    assign enq_fire = enq_req & enq_ready;

    //========================================================================
    // 占用判决查询 (组合, 当拍返回): 透传 vld + 当前队列/端口给 Occupancy,
    //   occ_accept/occ_drop/occ_use_static/occ_no_free 组合返回。
    //========================================================================
    assign occ_query_vld         = enq_fire;
    assign occ_query_queue_id    = enq_queue_id;
    assign occ_query_egress_port = enq_egress_port;
    // ★ 入队前预判: 透传本包 cell 数给 occ, occ 组合返回预判结果直出给 QM。
    //   纯组合、与 enq_query 同拍, 不依赖 enq_fire (QM 在包首 presenting queue_id+cell_num 即可读)。
    assign occ_query_cell_num    = enq_cell_num;
    assign enq_predict_drop      = occ_predict_drop;

    //========================================================================
    // ★ B2 单槽门控: 多播帧到达 (SOF) 时若多播槽已占用 (mc_busy) → 整帧丢弃。
    //   mc_busy 由 LLE 提供 (mc_valid 寄存), T0 当拍可读。
    //   非 SOF 的多播后续 cell 靠 frame_drop_q 级联丢弃 (无需再看 mc_busy)。
    //========================================================================
    logic mcast_slot_block_c;
    assign mcast_slot_block_c = enq_fire & enq_is_mcast & enq_sof & mc_busy;

    //========================================================================
    // 整帧丢弃 FSM: 一帧 (sof~eof) 内任一 cell 判丢则置位并保持到 eof,
    //   本帧后续 cell 在 T0 直接判丢、不取地址、不发 fire。
    //   frame_drop_q: 当前帧已进入"整帧丢弃"状态 (sof 拍判丢后保持到 eof)。
    //========================================================================
    logic frame_drop_q;

    // 本 cell 的丢弃来源:
    //   - occ_drop / occ_no_free / lle_free_empty: 占用水位高水位无条件丢弃 + 空闲池空兜底
    //   - (enq_sof & enq_predict_drop): ★ 入队前预判命中 → 整包放不下, 从包首就整帧丢弃
    //   - frame_drop_q: 本帧此前已判丢 (整帧丢弃保持)
    logic cell_drop_c;       // 本 cell 是否丢弃
    logic full_frame_drop_c; // 本 cell 是否标整帧丢弃 (本 cell 起始的帧整帧丢)
    logic accept_c;          // 本 cell 是否真正接收(分配+挂链)

    always_comb begin
        // 默认
        cell_drop_c       = 1'b0;
        full_frame_drop_c = 1'b0;
        accept_c          = 1'b0;

        if (enq_fire) begin
            // 已处于整帧丢弃状态 (本帧前序 cell 判丢): 后续 cell 全丢
            if (frame_drop_q) begin
                cell_drop_c       = 1'b1;
                full_frame_drop_c = 1'b1;
            end
            // 本 cell 触发丢弃:
            //   - 逐 cell 高水位无条件丢弃 / 空闲池空;
            //   - ★ 入队前预判命中 (enq_predict_drop) 且为包首(SOF): occ 组合判定本包 N 个
            //     cell 整体放不下 → 从 SOF 起就整帧丢弃, 一个 cell 都不挂链 (避免"前几个
            //     cell 已挂链、到中途才丢"造成的部分挂链遗留)。predict 只在 SOF 采样,
            //     后续 cell 靠 frame_drop_q 级联丢弃。
            //   - ★ mcast_slot_block_c: 多播槽占用中, 新多播帧从 SOF 整帧丢弃。
            else if (occ_drop | occ_no_free | lle_free_empty | (enq_sof & enq_predict_drop) | mcast_slot_block_c) begin
                cell_drop_c       = 1'b1;
                full_frame_drop_c = 1'b1;
            end
            // 占用判决接收
            else if (occ_accept) begin
                accept_c = 1'b1;
            end
            // 兜底: 无 accept 也无明确 drop 视为丢弃 (保守)
            else begin
                cell_drop_c       = 1'b1;
                full_frame_drop_c = 1'b1;
            end
        end
    end

    // 整帧丢弃状态更新: 帧首 (sof) 判丢则置位; 帧尾 (eof) 帧结束则清除。
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            frame_drop_q <= 1'b0;
        end
        else if (!init_done) begin
            frame_drop_q <= 1'b0;
        end
        else if (enq_fire) begin
            if (frame_drop_q) begin
                // 整帧丢弃保持中, 到 eof 清除 (本帧结束)
                if (enq_eof) frame_drop_q <= 1'b0;
            end
            else if (cell_drop_c && !enq_eof) begin
                // 本 cell 判丢且帧未结束 → 进入整帧丢弃保持
                frame_drop_q <= 1'b1;
            end
            // 单 cell 帧 (sof&eof 同拍) 判丢: 不需保持, frame_drop_q 维持 0
        end
    end

    //========================================================================
    // LLE 分配+挂链命令 (一拍脉冲): 仅接收时拉高
    //========================================================================
    assign lle_alloc_fire         = accept_c;
    assign lle_alloc_queue_id     = enq_queue_id;
    assign lle_alloc_addr         = lle_free_head;       // T0 当拍即取
    assign lle_set_pkt_head       = enq_sof;
    assign lle_set_pkt_tail       = enq_eof;
    assign lle_alloc_is_mcast     = enq_is_mcast;
    assign lle_alloc_mcast_bitmap = enq_mcast_bitmap;    // ★ B2: 目的端口位图 → LLE 置 mc_dst_bitmap
    assign mcast_busy_drop        = mcast_slot_block_c;  // ★ B2: 本拍多播因槽占用被丢

    //========================================================================
    // T1 返回 (寄存一拍): 把 T0 的判决/地址/头尾在末沿寄存, 下一拍输出给 QM。
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            alloc_valid           <= 1'b0;
            alloc_cell_addr       <= '0;
            alloc_drop_ind        <= 1'b0;
            alloc_sram_flag       <= 1'b0;
            alloc_pkt_head        <= 1'b0;
            alloc_pkt_tail        <= 1'b0;
            alloc_full_frame_drop <= 1'b0;
        end
        else begin
            alloc_valid           <= enq_fire;            // 本拍有有效请求 → 下一拍结果有效
            alloc_cell_addr       <= lle_free_head;       // 接收时为分配地址; 丢弃时该字段无意义
            alloc_drop_ind        <= cell_drop_c;
            alloc_sram_flag       <= accept_c;            // 接收且写内部 SRAM
            alloc_pkt_head        <= enq_sof;
            alloc_pkt_tail        <= enq_eof;
            alloc_full_frame_drop <= full_frame_drop_c;
        end
    end

endmodule

```


## deq

```
//============================================================================
// Module      : dequeue_ctrl  (Dequeue Control)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Description : 出队路径控制 (控制平面)。单拍命令式, 不直接访问指针存储。
//               T0: 收 QM 出队请求、检查背压 → 取 lle_qhead(队头寄存器组合可读)
//                   作出队地址、发一拍 lle_deq_fire(队头推进+预取由 LLE 流水) →
//                   地址/头尾标志在末沿寄存。
//               T1: 输出 deq_cell_* 给 QM。背靠背 1 cell/cycle, 逐 cell 直到 pkt_tail。
//               deq_backpressure[port]=1 时暂停该端口对应队列出队。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module dequeue_ctrl #(
    parameter int CELL_NUM  = 8192,
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,     // 每端口 TC 数
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,   // 单播 P*T + 多播 (free 链在 LLE 内)
    localparam int ADDR_W   = $clog2(CELL_NUM),
    localparam int QID_W    = $clog2(QUEUE_NUM-1)+1
)(
    //------------------------------------------------------------------------
    // 时钟复位 / 初始化 (公共)
    //------------------------------------------------------------------------
    input  logic                  clk_core,
    input  logic                  rst_core_n,
    input  logic                  init_done,           // =0 拒收 deq_req

    //------------------------------------------------------------------------
    // 与 QM 的接口 (外部, 经 MMU 顶层)
    //------------------------------------------------------------------------
    input  logic                  deq_req,             // 出队请求有效
    input  logic [QID_W-1:0]      deq_queue_id,        // 出队队列号
    input  logic [PORT_NUM-1:0]   deq_backpressure,    // 每端口背压(EPS 经 QM)
    output logic                  deq_ready,           // 可接出队请求(init_done 后恒高)
    output logic                  deq_cell_valid,      // 出队地址有效
    output logic [ADDR_W-1:0]     deq_cell_addr,       // 出队 cell 地址
    output logic                  deq_pkt_head,        // 报文头标志
    output logic                  deq_pkt_tail,        // 报文尾标志

    //------------------------------------------------------------------------
    // 与 Link-List Engine (LLE) 的接口 (内部, 单拍命令式出队)
    //------------------------------------------------------------------------
    input  logic [ADDR_W-1:0]     lle_qhead,           // 出队地址(按 queue_id 选, 组合可读)
    input  logic                  lle_qhead_pkt_head,  // 队头 cell 头标志
    input  logic                  lle_qhead_pkt_tail,  // 队头 cell 尾标志
    input  logic                  lle_q_empty,         // 该队列空
    output logic                  lle_deq_fire,        // 出队命令(一拍脉冲, 推进队头+取新队头)
    output logic [QID_W-1:0]      lle_deq_queue_id     // 出队队列号
);

    //========================================================================
    // 握手: init_done 后恒高, 支持背靠背 1 cell/cycle
    //========================================================================
    assign deq_ready = init_done;

    //========================================================================
    // 出队队列 → 出端口映射: egress_port = queue_id >> $clog2(TC_NUM)。
    //   单播 queue_id = port*TC_NUM + tc; 截到 PORT_NUM 范围内 (越界视为 0,
    //   多播专用队列的出端口不参与此端口背压映射)。
    //========================================================================
    localparam int    Q_PER_PORT_LOG = $clog2(TC_NUM);
    logic [QID_W-1:0] egress_port_full;
    logic [QID_W-1:0] egress_port_idx;
    assign egress_port_full = deq_queue_id >> Q_PER_PORT_LOG;
    assign egress_port_idx  = (egress_port_full < PORT_NUM[QID_W-1:0])
                              ? egress_port_full : '0;

    // 该端口是否被背压
    logic port_bp;
    assign port_bp = deq_backpressure[egress_port_idx];

    //========================================================================
    // 本拍是否真正出队:
    //   - 握手成立 (deq_req & deq_ready)
    //   - 队列非空 (lle_q_empty=0)
    //   - 对应端口未被背压 (port_bp=0)
    //========================================================================
    logic deq_fire;
    assign deq_fire = deq_req & deq_ready & ~lle_q_empty & ~port_bp;

    //========================================================================
    // LLE 出队命令 (一拍脉冲): 推进队头 + 取新队头 entry 由 LLE 流水完成。
    //========================================================================
    assign lle_deq_fire     = deq_fire;
    assign lle_deq_queue_id = deq_queue_id;

    //========================================================================
    // T1 返回 (寄存一拍): 出队地址 = lle_qhead (T0 当拍组合可读),
    //   头尾标志取 lle_qhead_pkt_head/tail (队头描述符预取), 末沿寄存后下一拍输出。
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            deq_cell_valid <= 1'b0;
            deq_cell_addr  <= '0;
            deq_pkt_head   <= 1'b0;
            deq_pkt_tail   <= 1'b0;
        end
        else begin
            deq_cell_valid <= deq_fire;
            deq_cell_addr  <= lle_qhead;            // 队头地址 (当拍即给)
            deq_pkt_head   <= lle_qhead_pkt_head;   // 队头描述符 (预取, 当拍可给)
            deq_pkt_tail   <= lle_qhead_pkt_tail;
        end
    end

endmodule

```


## csr_stats_init

```
//============================================================================
// Module      : csr_stats_init  (CSR Sample / Stats + Init FSM)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Description : 配置平面。**不在 MMU 内部实现 APB/AHB 总线**: 配置寄存器由 MMU
//               外部 (SoC 顶层 CSR 块 / 寄存器文件) 维护, 配置值在外部已 ready
//               且稳定; 本模块用主时钟 clk_core 直接采样外部配置输入 cfg_in_*,
//               寄存一拍去毛刺后下发 cfg_* 给 Occupancy 等模块 (无总线握手、
//               无 CDC; 配置源与 MMU 同 clk_core 域, 或外部已做好同步)。
//               - Init FSM: init_start 触发 → 命 LLE 建空闲链(init_build_req) →
//                 清各 head/tail/计数器(clr_ptr_cnt) → init_done。
//               不含 WRED 参数 (WRED 在 QM)。
//
//   ★ 与新版 occupancy_pool_mgr 对齐:
//     - occ 占用判决/满判决用 cfg_q_full / cfg_q_max_cell / cfg_port_max /
//       cfg_global_high_wm; near_full 改由 occ 内部按 (阈值 - margin) 推导,
//       故删除 cfg_q_near_full_th / cfg_q_near_full_hyst。
//     - 新增 PAUSE 双阈值 (cfg_port/global_pause_xoff/xon) 与 PFC (cfg_pfc_en/xoff/xon)。
//     - occ 不再输出 st_* 统计与 overflow/underflow_alarm; 本模块统计输出保留
//       接口但置 0 (统计在详细设计阶段重新接入), 告警 irq 由顶层汇聚。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module csr_stats_init #(
    parameter int CELL_NUM   = 8192,
    parameter int PORT_NUM   = 4,
    parameter int TC_NUM     = 8,     // 每端口 TC 数
    parameter int STAT_W     = 32,
    // 派生位宽 / 数量 (与 occupancy_pool_mgr 同源)
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,   // 单播 P*T + 多播 (free 链在 LLE 内)
    localparam int CNT_W     = $clog2(CELL_NUM) + 1
)(
    //------------------------------------------------------------------------
    // 时钟复位 (core 域, 单时钟域)
    //------------------------------------------------------------------------
    input  logic                                        clk_core,
    input  logic                                        rst_core_n,

    //------------------------------------------------------------------------
    // 外部 CSR 配置输入 (clk_core 域已 ready, 直接采样, 无总线握手/无 CDC)
    //   由 MMU 外部 (SoC 顶层 CSR 块) 维护并驱动; 本模块寄存一拍后下发各子模块。
    //------------------------------------------------------------------------
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_in_queue_min_cell,    // 每队列静态预留(per-queue)
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_in_q_max_cell,        // 每队列高水位上限
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_in_q_full,            // 每队列满阈值
    input  logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_in_port_max,          // 每出端口高水位(端口级聚合)
    input  logic [CNT_W-1:0]                            cfg_in_global_high_wm,    // 全局高水位
    // PAUSE (802.3x) 双阈值
    input  logic                                        cfg_in_pause_en,          // PAUSE 使能
    input  logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_in_port_pause_xoff,   // 每端口 PAUSE XOFF
    input  logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_in_port_pause_xon,    // 每端口 PAUSE XON
    input  logic [CNT_W-1:0]                            cfg_in_global_pause_xoff, // 全局 PAUSE XOFF
    input  logic [CNT_W-1:0]                            cfg_in_global_pause_xon,  // 全局 PAUSE XON
    // PFC (802.1Qbb) 双阈值 (per-port × TC)
    input  logic                                        cfg_in_pfc_en,            // PFC 使能
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_in_pfc_xoff,          // 每 TC PFC XOFF
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_in_pfc_xon,           // 每 TC PFC XON

    //------------------------------------------------------------------------
    // 统计汇聚 (← Occupancy) + 告警 (← Occupancy)
    //------------------------------------------------------------------------
    input  logic [CNT_W-1:0]                            st_global_used,
    input  logic [CNT_W-1:0]                            st_free_count,
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             st_q_static_used,
    input  logic [PORT_NUM-1:0][CNT_W-1:0]              st_per_port_used,
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             st_per_queue_used,
    input  logic [QUEUE_NUM-1:0]                        st_q_near_full_status,
    input  logic [QUEUE_NUM-1:0][STAT_W-1:0]            st_tail_drop_cnt,
    input  logic [QUEUE_NUM-1:0][STAT_W-1:0]            st_near_full_assert_cnt,
    input  logic [PORT_NUM-1:0][STAT_W-1:0]             st_pause_tx_cnt,
    input  logic                                        overflow_alarm,      // ← Occupancy
    input  logic                                        underflow_alarm,     // ← Occupancy

    //------------------------------------------------------------------------
    // 上电初始化 (外部)
    //------------------------------------------------------------------------
    input  logic                                        init_start,          // 上电初始化触发(← CPU/CSR)
    output logic                                        init_done,           // 初始化完成(→ CPU/QM/各 Ctrl)

    //------------------------------------------------------------------------
    // 告警 / 中断输出
    //------------------------------------------------------------------------
    output logic                                        irq_alarm,           // 告警中断
    output logic                                        irq_aging,           // 老化中断

    //------------------------------------------------------------------------
    // 配置下发 (→ Occupancy 等) = 外部 cfg_in_* 经 clk_core 寄存一拍后的稳定版本
    //------------------------------------------------------------------------
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_queue_min_cell,
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_q_max_cell,
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_q_full,
    output logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_max,
    output logic [CNT_W-1:0]                            cfg_global_high_wm,
    output logic                                        cfg_pause_en,
    output logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_pause_xoff,
    output logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_pause_xon,
    output logic [CNT_W-1:0]                            cfg_global_pause_xoff,
    output logic [CNT_W-1:0]                            cfg_global_pause_xon,
    output logic                                        cfg_pfc_en,
    output logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xoff,
    output logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xon,

    //------------------------------------------------------------------------
    // 统计输出 (→ 外部 CSR/CPU, clk_core 域直接输出, 无总线)
    //   注: 新版 occ 暂未产出 st_* 统计, 此处置 0 占位 (详细设计阶段重新接入)。
    //------------------------------------------------------------------------
    output logic [CNT_W-1:0]                            st_out_global_used,
    output logic [CNT_W-1:0]                            st_out_free_count,
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]             st_out_q_static_used,
    output logic [PORT_NUM-1:0][CNT_W-1:0]              st_out_per_port_used,
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]             st_out_per_queue_used,
    output logic [QUEUE_NUM-1:0]                        st_out_q_near_full_status,
    output logic [QUEUE_NUM-1:0][STAT_W-1:0]            st_out_tail_drop_cnt,
    output logic [QUEUE_NUM-1:0][STAT_W-1:0]            st_out_near_full_assert_cnt,
    output logic [PORT_NUM-1:0][STAT_W-1:0]             st_out_pause_tx_cnt,

    //------------------------------------------------------------------------
    // 与 LLE 的接口 (上电建空闲链)
    //------------------------------------------------------------------------
    output logic                                        init_build_req,      // 触发建空闲链
    input  logic                                        init_build_done,     // 建链完成

    //------------------------------------------------------------------------
    // 初始化期清指针/计数 (→ 各 Ctrl / Occupancy)
    //------------------------------------------------------------------------
    output logic                                        clr_ptr_cnt          // 初始化期清 head/tail/计数器
);

    //========================================================================
    // 配置采样: 外部 cfg_in_* 在 clk_core 域已 ready, 寄存一拍去毛刺后下发。
    //   (配置源与 MMU 同 clk_core 域, 或外部已做好同步; 无需总线握手/CDC。)
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            cfg_queue_min_cell    <= '0;
            cfg_q_max_cell        <= '0;
            cfg_q_full            <= '0;
            cfg_port_max          <= '0;
            cfg_global_high_wm    <= '0;
            cfg_pause_en          <= 1'b0;
            cfg_port_pause_xoff   <= '0;
            cfg_port_pause_xon    <= '0;
            cfg_global_pause_xoff <= '0;
            cfg_global_pause_xon  <= '0;
            cfg_pfc_en            <= 1'b0;
            cfg_pfc_xoff          <= '0;
            cfg_pfc_xon           <= '0;
        end
        else begin
            cfg_queue_min_cell    <= cfg_in_queue_min_cell;
            cfg_q_max_cell        <= cfg_in_q_max_cell;
            cfg_q_full            <= cfg_in_q_full;
            cfg_port_max          <= cfg_in_port_max;
            cfg_global_high_wm    <= cfg_in_global_high_wm;
            cfg_pause_en          <= cfg_in_pause_en;
            cfg_port_pause_xoff   <= cfg_in_port_pause_xoff;
            cfg_port_pause_xon    <= cfg_in_port_pause_xon;
            cfg_global_pause_xoff <= cfg_in_global_pause_xoff;
            cfg_global_pause_xon  <= cfg_in_global_pause_xon;
            cfg_pfc_en            <= cfg_in_pfc_en;
            cfg_pfc_xoff          <= cfg_in_pfc_xoff;
            cfg_pfc_xon           <= cfg_in_pfc_xon;
        end
    end

    //========================================================================
    // 统计输出: 自 Occupancy 汇聚的 st_* 在 clk_core 域寄存一拍后直出给外部 CSR/CPU。
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            st_out_global_used          <= '0;
            st_out_free_count           <= '0;
            st_out_q_static_used        <= '0;
            st_out_per_port_used        <= '0;
            st_out_per_queue_used       <= '0;
            st_out_q_near_full_status   <= '0;
            st_out_tail_drop_cnt        <= '0;
            st_out_near_full_assert_cnt <= '0;
            st_out_pause_tx_cnt         <= '0;
        end
        else begin
            st_out_global_used          <= st_global_used;
            st_out_free_count           <= st_free_count;
            st_out_q_static_used        <= st_q_static_used;
            st_out_per_port_used        <= st_per_port_used;
            st_out_per_queue_used       <= st_per_queue_used;
            st_out_q_near_full_status   <= st_q_near_full_status;
            st_out_tail_drop_cnt        <= st_tail_drop_cnt;
            st_out_near_full_assert_cnt <= st_near_full_assert_cnt;
            st_out_pause_tx_cnt         <= st_pause_tx_cnt;
        end
    end

    //========================================================================
    // 告警中断聚合 (overflow/underflow → irq_alarm; 老化 irq_aging 预留)
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            irq_alarm <= 1'b0;
            irq_aging <= 1'b0;
        end
        else begin
            irq_alarm <= overflow_alarm | underflow_alarm;
            irq_aging <= 1'b0;   // 队列老化未启用时恒 0
        end
    end

    //========================================================================
    // Init FSM: IDLE → BUILD(命 LLE 建空闲链, 清指针/计数) → DONE
    //   init_start 触发 → 拉 init_build_req(脉冲) + clr_ptr_cnt → 等 LLE
    //   init_build_done → 置 init_done(并保持)。
    //========================================================================
    typedef enum logic [1:0] {
        IS_IDLE  = 2'b00,
        IS_BUILD = 2'b01,
        IS_DONE  = 2'b10
    } init_st_e;

    init_st_e init_st_q;

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            init_st_q      <= IS_IDLE;
            init_build_req <= 1'b0;
            clr_ptr_cnt    <= 1'b0;
            init_done      <= 1'b0;
        end
        else begin
            // 默认拉低脉冲
            init_build_req <= 1'b0;
            case (init_st_q)
                IS_IDLE: begin
                    init_done   <= 1'b0;
                    clr_ptr_cnt <= 1'b0;
                    if (init_start) begin
                        init_build_req <= 1'b1;   // 命 LLE 建空闲链 (脉冲 1 拍)
                        clr_ptr_cnt    <= 1'b1;    // 初始化期清指针/计数
                        init_st_q      <= IS_BUILD;
                    end
                end
                IS_BUILD: begin
                    // 等 LLE 建链完成
                    if (init_build_done) begin
                        clr_ptr_cnt <= 1'b0;
                        init_done   <= 1'b1;       // 初始化完成 (保持)
                        init_st_q   <= IS_DONE;
                    end
                end
                IS_DONE: begin
                    init_done <= 1'b1;             // 保持完成态
                    // 允许再次 init_start 重新初始化
                    if (init_start) begin
                        init_done      <= 1'b0;
                        init_build_req <= 1'b1;
                        clr_ptr_cnt    <= 1'b1;
                        init_st_q      <= IS_BUILD;
                    end
                end
                default: init_st_q <= IS_IDLE;
            endcase
        end
    end

endmodule

```


## occupancy_pool_mgr

```
`timescale 1ns/1ps

module occupancy_pool_mgr #(
    parameter int CELL_NUM  = 8192,
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,     // 每端口 TC 数 (per-port traffic class)
    parameter int STAT_W    = 32,    // 统计计数器位宽
    parameter int PKT_CELL_W = 4,    // enq_cell_num 位宽 (本包 cell 数, ≤ 单帧最大 cell)
    // near_full 端口/全局余量 (距高水位多少 cell 即视为快满); 队列用 cfg 滞回
    parameter int QUEUE_NF_MARGIN   = 2,
    parameter int PORT_NF_MARGIN    = 4,
    parameter int GLOBAL_NF_MARGIN = 8,
    // ★ 队列数 = 端口数×每端口TC + 1 (仅 1 个多播专用队列; free 链在 LLE 内独立维护)
    //   索引: [0 .. PORT_NUM*TC_NUM-1] 单播(port,tc); [QUEUE_NUM-1] 多播专用队列
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,
    localparam int ADDR_W    = $clog2(CELL_NUM),
    localparam int QID_W     = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W    = $clog2(PORT_NUM-1)+1,
    localparam int CNT_W     = ADDR_W+1     // 占用计数位宽 (0~CELL_NUM)
)(
    //------------------------------------------------------------------------
    // 时钟复位 (公共)
    //------------------------------------------------------------------------
    input  logic                       clk_core,
    input  logic                       rst_core_n,

    //------------------------------------------------------------------------
    // 与 Enqueue Ctrl 的接口 (占用判决查询, 组合返回支撑 1 拍)
    //------------------------------------------------------------------------
    input  logic                       occ_query_vld,        // 占用判决查询
    input  logic [QID_W-1:0]           occ_query_queue_id,   // 待判决队列号
    input  logic [PORT_W-1:0]          occ_query_egress_port,// 待判决出端口
    input  logic [PKT_CELL_W-1:0]      occ_query_cell_num,   // 本包 cell 数(SOF 有效, 入队前预判用)
    output logic                       occ_accept,           // 判决=接收
    output logic                       occ_drop,             // 判决=丢弃(高水位兜底)
    output logic                       occ_use_static,       // 记静态(=1)/动态(=0)
    output logic                       occ_no_free,          // 空闲池空(强制丢弃)
    output logic                       occ_predict_drop,     // ★ 入队前预判: 本包 N 个 cell 会否触发丢弃

    //------------------------------------------------------------------------
    // 与 LLE 的接口 (分配/回收事件, 计数 ++/--)
    //------------------------------------------------------------------------
    input  logic                       lle_alloc_evt,        // 分配事件
    input  logic [QID_W-1:0]           evt_queue_id,         // 事件所属队列(分配有效)
    input  logic [PORT_W-1:0]          evt_egress_port,      // 事件所属出端口(分配有效)

    //------------------------------------------------------------------------
    // 与 Recycle Ctrl 的接口 (回收计数 --)
    //------------------------------------------------------------------------
    input  logic                       occ_free_vld,         // 回收事件(计数--)
    input  logic [QID_W-1:0]           occ_free_queue_id,    // 回收所属队列
    input  logic [PORT_W-1:0]          occ_free_egress_port, // 回收所属出端口

    //------------------------------------------------------------------------
    // 流控 / 快满反馈输出
    //------------------------------------------------------------------------
    output logic [PORT_NUM-1:0]        pause_req,            // 高水位发 IEEE PAUSE
    output logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_req,            // 802.1Qbb PFC.每端口TC反压位图
    output logic [QUEUE_NUM-1:0]       q_near_full,          // 每队列快满(QM 门控+WRED 占用输入)
    output logic [PORT_NUM-1:0]        port_near_full,       // 每出端口快满
    output logic                       global_near_full,     // 全局快满
    output logic [QUEUE_NUM-1:0]       q_full,          // 每队列满(QM 门控+WRED 占用输入)
    output logic [PORT_NUM-1:0]        port_full,       // 每出端口满
    output logic                       global_full,     // 全局满

    //------------------------------------------------------------------------
    // 配置下发 (← CSR), 静态预留/水位/快满阈值均按队列(per-queue)
    //------------------------------------------------------------------------
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_queue_min_cell,  // 每队列静态预留(per-queue)
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_max_cell,      // 每队列高水位上限
    input  logic [PORT_NUM-1:0][CNT_W-1:0]  cfg_port_max,        // 每出端口高水位(端口级聚合)
    input  logic [CNT_W-1:0]                cfg_global_high_wm,  // 全局高水位
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_full,  // 每队列满阈值
    input  logic                            cfg_pause_en,        // PAUSE 使能
    input  logic [PORT_NUM-1:0][CNT_W-1:0]  cfg_port_pause_xoff, //每端口：占用>=此值触发PAUSE
    input  logic [PORT_NUM-1:0][CNT_W-1:0]  cfg_port_pause_xon,  //每端口：占用<此值撤销PAUSE
    input  logic [CNT_W-1:0]            cfg_global_pause_xoff, //全局：占用>=此值触发PAUSE
    input  logic [CNT_W-1:0]            cfg_global_pause_xon,  //全局：占用<此值撤销PAUSE
    input  logic                        cfg_pfc_en,             // PFC使能
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xoff, //每TC：占用>=此值触发PAUSE
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xon,   //每TC：占用>=此值触发PAUSE


    //------------------------------------------------------------------------
    // 统计上报 (→ CSR)
    //------------------------------------------------------------------------
    output logic [CNT_W-1:0]                st_global_used,      // 全局占用
    output logic [CNT_W-1:0]                st_free_count,       // 空闲计数
    output logic [QUEUE_NUM-1:0][CNT_W-1:0] st_q_static_used,    // 每队列静态池占用
    output logic [PORT_NUM-1:0][CNT_W-1:0]  st_per_port_used,    // 每端口占用(端口级聚合)
    output logic [QUEUE_NUM-1:0][CNT_W-1:0] st_per_queue_used,   // 每队列占用
    output logic [QUEUE_NUM-1:0]            st_q_near_full_status,// 快满状态镜像
    output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_tail_drop_cnt,   // 高水位无条件丢包计数
    output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_near_full_assert_cnt,// 快满置位次数
    output logic [PORT_NUM-1:0][STAT_W-1:0]  st_pause_tx_cnt,    // PAUSE 发送计数
    output logic                            overflow_alarm,      // cell 池溢出告警
    output logic                            underflow_alarm      // 守恒/下溢告警
);
    //========================================================================
    // 
    //========================================================================
    localparam Q_PER_PORT = $clog2(TC_NUM);

    //========================================================================
    // 
    //========================================================================
    logic [CNT_W-1:0]  free_count_q;                    //空闲数量
    logic [CNT_W-1:0]  global_used_q;                   //全局使用量 = 总cell数量-free_count_q
    logic [CNT_W-1:0]  q_cell_cnt_q     [QUEUE_NUM];    //每个队列使用量
    logic [CNT_W-1:0]  q_static_used_q  [QUEUE_NUM];    //每个队列静态使用量
    logic [CNT_W-1:0]  per_port_used_q  [PORT_NUM];     //每个port使用量

    logic [QUEUE_NUM-1:0] use_static_vec;

    logic                 alloc_allowed;
    logic                 free_allowed;
    logic                 same_queue_evt;
    logic                 same_port_evt;
    logic [PORT_W-1:0]    alloc_port;
    logic [PORT_W-1:0]    free_port;
    logic [QUEUE_NUM-1:0] q_cell_inc;
    logic [QUEUE_NUM-1:0] q_cell_dec;
    logic [QUEUE_NUM-1:0] q_static_inc;
    logic [QUEUE_NUM-1:0] q_static_dec;
    logic [PORT_NUM-1:0]  port_inc;
    logic [PORT_NUM-1:0]  port_dec;

    logic [PORT_NUM-1:0] pause_set;
    logic [PORT_NUM-1:0] pause_clr;
    logic                global_pause_xoff;
    logic                global_pause_xon;


    //function automatic logic [PORT_W-1:0] qid2port(input logic [QID_W-1:0] qid);
    //    qid2port = qid[QID_W-1 -: PORT_W];
    //endfunction

    always_comb begin
        alloc_allowed  = 1'b0;
        free_allowed   = 1'b0;
        // Fix5: 直接用 LLE 提供的端口号, 不再由 queue_id 重算 (去冗余)
        alloc_port     = evt_egress_port;
        free_port      = occ_free_egress_port;
        same_queue_evt = lle_alloc_evt && occ_free_vld && (evt_queue_id == occ_free_queue_id);
        same_port_evt  = lle_alloc_evt && occ_free_vld && (alloc_port == free_port);

        // free: 仅做防下溢校验 (该队列占用非 0), 这是 occ 自身记账边界
        for (int i = 0; i < QUEUE_NUM; i++) begin
            if (occ_free_vld && (occ_free_queue_id == i) && (q_cell_cnt_q[i] != '0)) begin
                free_allowed = 1'b1;
            end
        end

        // Fix6: alloc 信任 LLE 决策。lle_alloc_evt(=enq_grant) 已保证 free 池可用,
        //   occ 不再二次校验 free_count (避免与 LLE.free_cnt 时序失配导致计数发散),
        //   occ 仅做纯计数。
        alloc_allowed = lle_alloc_evt;

        q_cell_inc   = '0;
        q_cell_dec   = '0;
        q_static_inc = '0;
        q_static_dec = '0;
        for (int i = 0; i < QUEUE_NUM; i++) begin
            q_cell_inc[i]   = alloc_allowed && (evt_queue_id == i) &&
                              !(same_queue_evt && free_allowed);
            q_cell_dec[i]   = free_allowed && (occ_free_queue_id == i) &&
                              !(same_queue_evt && alloc_allowed);
            q_static_inc[i] = q_cell_inc[i] && use_static_vec[i];
            q_static_dec[i] = q_cell_dec[i] && (q_static_used_q[i] != '0);
        end

        port_inc = '0;
        port_dec = '0;
        for (int i = 0; i < PORT_NUM; i++) begin
            // ★ B2 (方案 b): 多播 cell 一份共享, 不归属任何物理端口 →
            //   evt_queue_id / occ_free_queue_id == MC_QID (>= PORT_NUM*TC_NUM) 时
            //   跳过 per-port 计数 (多播 buffer 压力仅体现在 global + MC_QID per-queue)。
            port_inc[i] = alloc_allowed && (evt_queue_id < QID_W'(PORT_NUM*TC_NUM)) &&
                          (alloc_port == i) &&
                          !(same_port_evt && free_allowed);
            port_dec[i] = free_allowed && (occ_free_queue_id < QID_W'(PORT_NUM*TC_NUM)) &&
                          (free_port == i) &&
                          (per_port_used_q[i] != '0) &&
                          !(same_port_evt && alloc_allowed);
        end
    end



    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                q_cell_cnt_q[i] <= '0;
            end
        end
        else begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                if (q_cell_inc[i] && !q_cell_dec[i])
                    q_cell_cnt_q[i] <= q_cell_cnt_q[i] + 1'b1;
                else if (!q_cell_inc[i] && q_cell_dec[i])
                    q_cell_cnt_q[i] <= q_cell_cnt_q[i] - 1'b1;
            end
        end
    end

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                q_static_used_q[i] <= '0;
            end
        end
        else begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                if (q_static_inc[i] && !q_static_dec[i])
                    q_static_used_q[i] <= q_static_used_q[i] + 1'b1;
                else if (!q_static_inc[i] && q_static_dec[i])
                    q_static_used_q[i] <= q_static_used_q[i] - 1'b1;
            end
        end
    end

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < PORT_NUM; i++) begin
                per_port_used_q[i] <= '0;
            end
        end
        else begin
            for (int i = 0; i < PORT_NUM; i++) begin
                if (port_inc[i] && !port_dec[i])
                    per_port_used_q[i] <= per_port_used_q[i] + 1'b1;
                else if (!port_inc[i] && port_dec[i])
                    per_port_used_q[i] <= per_port_used_q[i] - 1'b1;
            end
        end
    end

            


    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            free_count_q  <= CELL_NUM[CNT_W-1:0];
            global_used_q <= '0;
        end
        else begin
            case ({alloc_allowed, free_allowed})
                2'b10: if (free_count_q != '0) begin   // 仅分配
                    free_count_q  <= free_count_q  - 1'b1;
                    global_used_q <= global_used_q + 1'b1;
                end
                2'b01: if (global_used_q != '0) begin  // 仅回收
                    free_count_q  <= free_count_q  + 1'b1;
                    global_used_q <= global_used_q - 1'b1;
                end
                2'b11: begin // 同拍分配+回收: 净不变
                    free_count_q  <= free_count_q;
                    global_used_q <= global_used_q;
                end
                default: ; // 无事件
            endcase
        end
    end
    
    logic hi_wm_drop;
    logic [QUEUE_NUM-1:0] q_hi_wm_vec;     // >= cfg_q_max_cell (tail-drop 阈值)
    logic [PORT_NUM-1:0] port_hi_wm_vec; // per-port 高水位向量

    always_comb begin
        occ_no_free   = (free_count_q == '0);
        global_full     = (global_used_q >= cfg_global_high_wm);

        // 高水位无条件丢弃 (兜底) 或 空闲池空
        occ_drop      = occ_query_vld & (occ_no_free | (~occ_use_static & hi_wm_drop));
        occ_accept    = occ_query_vld & ~occ_drop;
        // ★ 判决基于【查询的队列/端口】(occ_query_*), 而非 alloc 事件 (evt_*)。
        //   occ_query 在 enqueue_ctrl 的 T0 组合发起, evt_* 是 LLE 在落地拍才有效,
        //   二者不同拍; 判决必须用当拍查询的 queue/port。
        // 双池: 该队列静态额度未用满 → 记静态账
        occ_use_static = use_static_vec[occ_query_queue_id];
        hi_wm_drop     = q_hi_wm_vec[occ_query_queue_id]
                       | port_hi_wm_vec[occ_query_egress_port]   // 端口向量按 port 索引
                       | global_full;
    end

    //========================================================================
    // ★ 入队前预判 (advisory, 纯组合): QM 在包首给本包 cell 数 occ_query_cell_num,
    //   根据 occ_query_queue_id/egress_port 判断这 N 个 cell 顺序放入后是否会触发
    //   alloc_drop (等价于逐 cell drop 的整包预判)。
    //   规则 (与逐 cell occ_drop 语义一致):
    //     - free 池必须 ≥ N (无条件, 不足则必丢);
    //     - 落在该队列静态额度内的 cell 绕过 q/port/global 高水位;
    //     - 超出静态额度的动态 cell 需整体不越 q/port/global 高水位。
    //   计数单调增、阈值固定, 故只需校验"最后一个 cell", 即比较总量 +N ≤ 阈值。
    //   前提: QM 单队列入队, 发包期间无其它队列消耗 global/free → 当拍快照即准确。
    //========================================================================
    logic [CNT_W-1:0] pred_cell_num;
    logic [CNT_W-1:0] pred_s_rem;      // 该队列静态额度剩余
    logic             pred_fit;
    always_comb begin
        pred_cell_num = {{(CNT_W-PKT_CELL_W){1'b0}}, occ_query_cell_num};  // 零扩展到 CNT_W
        if (q_static_used_q[occ_query_queue_id] < cfg_queue_min_cell[occ_query_queue_id])
            pred_s_rem = cfg_queue_min_cell[occ_query_queue_id] - q_static_used_q[occ_query_queue_id];
        else
            pred_s_rem = '0;
        pred_fit = (free_count_q >= pred_cell_num)
                && ( (pred_cell_num <= pred_s_rem)                                    // 全落静态额度 → 绕过高水位
                     || ( (q_cell_cnt_q[occ_query_queue_id]       + pred_cell_num <= cfg_q_max_cell[occ_query_queue_id])
                       && (per_port_used_q[occ_query_egress_port] + pred_cell_num <= cfg_port_max[occ_query_egress_port])
                       && (global_used_q                          + pred_cell_num <= cfg_global_high_wm) ) );
        occ_predict_drop = ~pred_fit;
    end

    always_comb begin
        for (int i = 0; i < QUEUE_NUM; i++) begin
            use_static_vec[i] = q_static_used_q[i] < cfg_queue_min_cell[i];
            q_full[i]         = q_cell_cnt_q[i]    >= cfg_q_full[i];
            q_hi_wm_vec[i]    = q_cell_cnt_q[i]    >= cfg_q_max_cell[i];
        end
    end
    always_comb begin
        for (int i = 0; i < PORT_NUM; i++) begin
            port_full[i]  = per_port_used_q[i]    >= cfg_port_max[i];
            port_hi_wm_vec[i] = per_port_used_q[i]    >= cfg_port_max[i];
        end
    end
    
    //============================================
    // near_full
    logic [QUEUE_NUM-1:0] q_near_full_set;
    always_comb begin
        for(int i=0;i<QUEUE_NUM;i++) begin
            q_near_full_set[i] = (q_cell_cnt_q[i] >= (cfg_q_max_cell[i]-QUEUE_NF_MARGIN)); 
        end
    end
    always_ff@(posedge clk_core, negedge rst_core_n) begin
        if(!rst_core_n) begin
            q_near_full <= '0;
        end
        else begin
            // Fix4: 按位赋值 (原写法 q_near_full<=1'b1 会把整个向量赋成最后一个 i 的结果)
            for(int i=0;i<QUEUE_NUM;i++)begin
                q_near_full[i] <= q_near_full_set[i];
            end
        end
    end
    // per-port near_full: 占用 >= (cfg_port_max - PORT_NF_MARGIN)
    logic [PORT_NUM-1:0] port_near_full_set;
    always_comb begin
        for(int i=0;i<PORT_NUM;i++) begin
            port_near_full_set[i] = (per_port_used_q[i] >= (cfg_port_max[i]-PORT_NF_MARGIN));
        end
    end
    always_ff@(posedge clk_core, negedge rst_core_n) begin
        if(!rst_core_n) begin
            port_near_full <= '0;
        end
        else begin
            for(int i=0;i<PORT_NUM;i++) begin
                port_near_full[i] <= port_near_full_set[i];
            end
        end
    end

    logic global_near_full_set;
    always_comb begin
        global_near_full_set = (global_used_q >= (cfg_global_high_wm-GLOBAL_NF_MARGIN));
    end
    always_ff@(posedge clk_core, negedge rst_core_n) begin
        if(!rst_core_n)
            global_near_full <= 1'b0;
        else if (global_near_full_set)
            global_near_full <= 1'b1;
        else
            global_near_full <= 1'b0;
    end



    //============================================
    //PAUSE
    assign  global_pause_xoff = (global_used_q >= cfg_global_pause_xoff);
    assign  global_pause_xon  = (global_used_q <  cfg_global_pause_xon);
    always_comb begin
        for(int i=0;i<PORT_NUM;i++) begin
            pause_set[i] = (per_port_used_q[i] >= cfg_port_pause_xoff[i] | global_pause_xoff); //端口或全局达到xoff
            pause_clr[i] = (per_port_used_q[i] <  cfg_port_pause_xon[i]  & global_pause_xon);  //端口且全局回落xon
        end
    end
    //寄存器迟滞
    always_ff@(posedge clk_core, negedge rst_core_n) begin
        if(!rst_core_n)
            pause_req    <= 1'b0;
        else begin
            for(int i=0;i<PORT_NUM;i++)begin
                if(!cfg_pause_en)
                    pause_req[i]    <= 1'b0;
                else if(pause_set[i])
                    pause_req[i]    <= 1'b1;
                else if(pause_clr[i])
                    pause_req[i]    <= 1'b0;
                // 中间区 保持原值，迟滞
            end
        end
    end

    //============================================
    //PFC
    logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0] per_tc_used;
    always_comb begin
        for(int i=0;i<PORT_NUM;i++) begin
            for(int j=0;j<TC_NUM;j++)begin
                per_tc_used[i][j] = q_cell_cnt_q[i*TC_NUM+j];
            end
        end
    end

    logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_set;
    logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_clr;
    always_comb begin
        for(int i=0;i<PORT_NUM;i++)begin
            for(int j=0;j<TC_NUM;j++)begin
                pfc_set[i][j] = per_tc_used[i][j] >= cfg_pfc_xoff[i][j];
                pfc_clr[i][j] = per_tc_used[i][j] <  cfg_pfc_xon[i][j];
            end
        end
    end

    //寄存器迟滞
    always_ff@(posedge clk_core, negedge rst_core_n) begin
        if(!rst_core_n)
            pfc_req    <= 1'b0;
        else begin
            for(int i=0;i<PORT_NUM;i++)begin
                for(int j=0;j<TC_NUM;j++)begin
                    if(!cfg_pfc_en)
                        pfc_req[i][j]    <= 1'b0;
                    else if(pfc_set[i][j])
                        pfc_req[i][j]    <= 1'b1;
                    else if(pfc_clr[i][j])
                        pfc_req[i][j]    <= 1'b0;
                // 中间区 保持原值，迟滞
                end
            end
        end
    end
    //========================================================================
    // 统计输出
    //========================================================================
    assign st_global_used        = global_used_q;
    assign st_free_count         = free_count_q;
    //assign st_q_near_full_status = q_near_full_q;
    //assign st_tail_drop_cnt      = tail_drop_cnt_q;
    //assign st_near_full_assert_cnt = near_full_assert_cnt_q;
    //assign st_pause_tx_cnt       = pause_tx_cnt_q;
    assign st_q_near_full_status = '0;
    assign st_tail_drop_cnt      = '0;
    assign st_near_full_assert_cnt = '0;
    assign st_pause_tx_cnt       = '0;
    always_comb begin
        for (int i = 0; i < QUEUE_NUM; i++) begin
            st_q_static_used[i]  = q_static_used_q[i];
            st_per_queue_used[i] = q_cell_cnt_q[i];
        end
        for (int i = 0; i < PORT_NUM; i++) begin 
            st_per_port_used[i]  = per_port_used_q[i];
        end
    end
    //========================================================================
    // 守恒 / 溢出 / 下溢 告警
    //========================================================================
    logic conserve_ok;
    assign conserve_ok = ((free_count_q + global_used_q) == CELL_NUM[CNT_W-1:0]);
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            overflow_alarm  <= 1'b0;
            underflow_alarm <= 1'b0;
        end
        else begin
            overflow_alarm  <= (global_used_q > CELL_NUM[CNT_W-1:0]);
            underflow_alarm <= ~conserve_ok
                               | (alloc_allowed & (free_count_q  == '0))
                               | (free_allowed  & (global_used_q == '0));
        end
    end


endmodule

```


## recycle_ctrl

```
//============================================================================
// Module      : recycle_ctrl  (Recycle Control) —— B2 版
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   回收路径控制 (控制平面)。B2 多播模型:
//     - 单播 (recycle_req): 报文发送完成, 该 cell 立即还链 → 直接向 LLE 发
//                           lle_free_req(接空闲链尾), 并透传 queue_id 供 occ 计数--。
//     - 组播 (mcast_recycle_req): 每收到一个出端口“发完一份”的通知, 反推该端口号
//                           (由 mcast_recycle_queue_id >> Q_PER_PORT_LOG), 直接
//                           转发给 LLE 的 mc_rcy_vld/mc_rcy_port —— LLE 内部记
//                           mc_rcy_done[port]; 当所有目的端口都读完+还链, LLE 自行
//                           整帧还链并清多播槽。recycle_ctrl 不再做 ref_count 递减。
//
//   仲裁: 单播还链走 lle_free_req; 组播还链由 LLE 内部 walk 完成 (走 LLE 内部
//         recycle FIFO), 不占用 recycle_ctrl 的 lle_free_req 口。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module recycle_ctrl #(
    parameter int CELL_NUM  = 8192,
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,     // 每端口 TC 数
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,
    localparam int ADDR_W   = $clog2(CELL_NUM),
    localparam int QID_W    = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W   = $clog2(PORT_NUM-1)+1,
    localparam int Q_PER_PORT_LOG = $clog2(TC_NUM)
)(
    //------------------------------------------------------------------------
    // 时钟复位 (公共)
    //------------------------------------------------------------------------
    input  logic                  clk_core,
    input  logic                  rst_core_n,

    //------------------------------------------------------------------------
    // 与 QM 的接口 (外部, 经 MMU 顶层)
    //------------------------------------------------------------------------
    input  logic                  recycle_req,         // 单播 cell 回收请求
    input  logic [ADDR_W-1:0]     recycle_cell_addr,   // 待回收 cell 地址
    input  logic [QID_W-1:0]      recycle_queue_id,    // 单播回收 cell 所属队列号
    input  logic                  mcast_recycle_req,   // 组播回收通知(某端口发完一份)
    input  logic [ADDR_W-1:0]     mcast_recycle_addr,  // 组播待回收 cell 地址 (B2 未用, 保留)
    input  logic [QID_W-1:0]      mcast_recycle_queue_id, // 组播回收所属承载队列号 (→ 反推端口)
    output logic                  recycle_ack,         // 回收完成应答

    //------------------------------------------------------------------------
    // 与 LLE 的接口 —— 单播还链 + 组播逐端口回收转发
    //------------------------------------------------------------------------
    output logic                  lle_free_req,        // 单播还链请求
    output logic [ADDR_W-1:0]     lle_free_addr,       // 待还 cell
    output logic [QID_W-1:0]      lle_free_queue_id,   // 待还 cell 所属队列号
    input  logic                  lle_free_grant,      // 仲裁通过
    input  logic                  lle_free_done,       // 还链完成
    // 组播逐端口回收 → LLE
    output logic                  mc_rcy_vld,          // 组播回收通知有效
    output logic [PORT_W-1:0]     mc_rcy_port          // 组播回收所属出端口
);

    //========================================================================
    // 单播还链: 直接透传 (B2 组播不再共用此口)
    //========================================================================
    assign lle_free_req      = recycle_req;
    assign lle_free_addr     = recycle_cell_addr;
    assign lle_free_queue_id = recycle_queue_id;

    //========================================================================
    // 组播逐端口回收转发: 反推端口号 = 承载队列号 >> Q_PER_PORT_LOG
    //========================================================================
    logic [QID_W-1:0] mc_port_full;
    assign mc_port_full = mcast_recycle_queue_id >> Q_PER_PORT_LOG;
    assign mc_rcy_vld   = mcast_recycle_req;
    assign mc_rcy_port  = (mc_port_full < PORT_NUM[QID_W-1:0])
                          ? mc_port_full[PORT_W-1:0] : '0;

    //========================================================================
    // 回收应答: 单播还链发起当拍应答; 组播收到通知当拍即应答。
    //========================================================================
    assign recycle_ack = recycle_req | mcast_recycle_req;

endmodule
```


## tb
```
//============================================================================
// Testbench : smart_mmu_tb  —— B2 多播逻辑拼接版
// Project   : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// 目标:
//   仿照 QM 行为, 通过寄存器输出激励 smart_mmu 的 input、读取 output (clk/rst 除外),
//   自检式 (self-checking) 覆盖:
//     C1  单队列挂链/走链/还链, free 链计数校验
//     C2  跨队列交叉挂链/走链, free 链/占用计数校验
//     C3  还链后 free 链恢复校验 (free_cnt / 守恒)
//     C4  ★ B2 多播: 单槽入队(建 chain33 SRAM 链) / 逐端口逻辑拼接出队(排头/排尾) /
//           逐端口回收(done 位图) / 全端口读完+还链后整帧释放 / 满槽 drop
//     C5  enq + deq 同拍仲裁 + 反压 (deq 占 SRAM → enq 等)
//     C6  deq + rcy 同拍仲裁与处理
//     C7  enq + deq + rcy 三者同拍仲裁与处理
//     C8  水线/满/快满 (q/port/global near_full + full) 触发与释放
//     C9  PAUSE 触发/释放
//     C10 压力测试 (混合 enq/deq/rcy, 守恒 + 无下溢/溢出)
//     C11 入队前预判 (predict-drop)
//
//   规模: CELL_NUM=64, QUEUE_NUM=9, PORT_NUM=2 (TC_NUM=4; q>>2 → port)
//         多播承载 TC = 0 (cfg_mcast_carry_tc[p]=0) → 承载 qid = p*4+0 = {0(port0), 4(port1)}
//============================================================================
`timescale 1ns/1ps

module smart_mmu_tb;

    //========================================================================
    // 参数
    //   PORT=2, TC=4 → QUEUE_NUM=9: 单播[0..7] (q0-3→port0, q4-7→port1), [8]=多播 MCAST_QID
    //========================================================================
    localparam int CELL_NUM  = 64;
    localparam int PORT_NUM  = 2;
    localparam int TC_NUM    = 4;
    localparam int REF_W     = 3;
    localparam int STAT_W    = 32;

    localparam int PKT_CELL_W = 4;
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1;    // 9
    localparam int MCAST_QID = QUEUE_NUM - 1;          // 8
    localparam int ADDR_W = $clog2(CELL_NUM);          // 6
    localparam int QID_W  = $clog2(QUEUE_NUM-1)+1;     // 4
    localparam int PORT_W = $clog2(PORT_NUM-1)+1;      // 1
    localparam int CNT_W  = ADDR_W + 1;                // 7
    localparam int QPP    = $clog2(TC_NUM);            // 2

    // ★ B2: 多播承载 TC = 0 → 承载 qid[port] = port*TC_NUM
    localparam int MC_CARRY_TC = 0;
    function automatic int carry_qid(input int port); carry_qid = port*TC_NUM + MC_CARRY_TC; endfunction

    function automatic int q2port(input int qid);
        q2port = qid >> QPP;
    endfunction

    //========================================================================
    // 时钟复位
    //========================================================================
    logic clk, rst_n;
    initial clk = 0;
    always #1.667 clk = ~clk;   // ~300MHz

    //========================================================================
    // DUT 输入寄存器
    //========================================================================
    logic                  init_start_r;
    logic                  enq_req_r;
    logic [QID_W-1:0]      enq_queue_id_r;
    logic [PORT_W-1:0]     enq_egress_port_r;
    logic [PKT_CELL_W-1:0] enq_cell_num_r;
    logic                  enq_is_mcast_r;
    logic [PORT_NUM-1:0]   enq_mcast_bitmap_r;
    logic [$clog2(TC_NUM)-1:0] enq_mcast_tc_r;   // ★ B2 组播帧 TC
    logic                  enq_sof_r, enq_eof_r;
    logic                  deq_req_r;
    logic [QID_W-1:0]      deq_queue_id_r;
    logic [PORT_NUM-1:0]   deq_backpressure_r;
    logic                  recycle_req_r;
    logic [ADDR_W-1:0]     recycle_cell_addr_r;
    logic [QID_W-1:0]      recycle_queue_id_r;
    logic                  mcast_recycle_req_r;
    logic [ADDR_W-1:0]     mcast_recycle_addr_r;
    logic [QID_W-1:0]      mcast_recycle_queue_id_r;

    //========================================================================
    // DUT 输出
    //========================================================================
    logic                  init_done;
    logic                  enq_ready;
    logic                  enq_predict_drop;
    logic                  alloc_valid;
    logic [ADDR_W-1:0]     alloc_cell_addr;
    logic                  alloc_drop_ind, alloc_sram_flag, alloc_pkt_head, alloc_pkt_tail;
    logic                  alloc_full_frame_drop;
    logic                  mcast_busy_drop;         // ★ B2
    logic                  deq_ready;
    logic                  deq_cell_valid;
    logic [ADDR_W-1:0]     deq_cell_addr;
    logic                  deq_pkt_head, deq_pkt_tail;
    logic                  recycle_ack;
    logic [PORT_NUM*TC_NUM-1:0] q_empty;             // ★ B2 32 条常规队列 empty
    logic [QUEUE_NUM-1:0]  q_near_full;
    logic [PORT_NUM-1:0]   port_near_full;
    logic                  global_near_full;
    logic [QUEUE_NUM-1:0]  q_full;
    logic [PORT_NUM-1:0]   port_full;
    logic                  global_full;
    logic [PORT_NUM-1:0]             pause_req;
    logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_req;
    logic                  irq_alarm, irq_aging, overflow_alarm, underflow_alarm;

    //========================================================================
    // 配置寄存器
    //========================================================================
    logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_queue_min_cell;
    logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_q_max_cell;
    logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_q_full;
    logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_max;
    logic [CNT_W-1:0]                            cfg_global_high_wm;
    logic                                        cfg_pause_en;
    logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_pause_xoff;
    logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_pause_xon;
    logic [CNT_W-1:0]                            cfg_global_pause_xoff;
    logic [CNT_W-1:0]                            cfg_global_pause_xon;
    logic                                        cfg_pfc_en;
    logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xoff;
    logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xon;
    // ★ B2: 每端口多播承载 TC
    logic [PORT_NUM-1:0][$clog2(TC_NUM)-1:0]     cfg_mcast_carry_tc;

    // stats out
    logic [CNT_W-1:0]                 st_out_global_used, st_out_free_count;
    logic [QUEUE_NUM-1:0][CNT_W-1:0]  st_out_q_static_used, st_out_per_queue_used;
    logic [PORT_NUM-1:0][CNT_W-1:0]   st_out_per_port_used;
    logic [QUEUE_NUM-1:0]             st_out_q_near_full_status;
    logic [QUEUE_NUM-1:0][STAT_W-1:0] st_out_tail_drop_cnt, st_out_near_full_assert_cnt;
    logic [PORT_NUM-1:0][STAT_W-1:0]  st_out_pause_tx_cnt;

    //========================================================================
    // DUT 例化
    //========================================================================
    smart_mmu #(
        .CELL_NUM (CELL_NUM), .PORT_NUM (PORT_NUM),
        .TC_NUM (TC_NUM), .REF_W (REF_W), .STAT_W (STAT_W), .PKT_CELL_W (PKT_CELL_W)
    ) u_dut (
        .clk_core (clk), .rst_core_n (rst_n),
        .init_start (init_start_r), .init_done (init_done),
        // enq
        .enq_req (enq_req_r), .enq_queue_id (enq_queue_id_r),
        .enq_egress_port (enq_egress_port_r), .enq_cell_num (enq_cell_num_r),
        .enq_is_mcast (enq_is_mcast_r),
        .enq_mcast_bitmap (enq_mcast_bitmap_r), .enq_mcast_tc (enq_mcast_tc_r),   // ★ B2
        .enq_sof (enq_sof_r), .enq_eof (enq_eof_r),
        .enq_ready (enq_ready), .enq_predict_drop (enq_predict_drop),
        .alloc_valid (alloc_valid),
        .alloc_cell_addr (alloc_cell_addr), .alloc_drop_ind (alloc_drop_ind),
        .alloc_sram_flag (alloc_sram_flag), .alloc_pkt_head (alloc_pkt_head),
        .alloc_pkt_tail (alloc_pkt_tail), .alloc_full_frame_drop (alloc_full_frame_drop),
        .mcast_busy_drop (mcast_busy_drop),          // ★ B2
        // deq
        .deq_req (deq_req_r), .deq_queue_id (deq_queue_id_r),
        .deq_backpressure (deq_backpressure_r), .deq_ready (deq_ready),
        .deq_cell_valid (deq_cell_valid), .deq_cell_addr (deq_cell_addr),
        .deq_pkt_head (deq_pkt_head), .deq_pkt_tail (deq_pkt_tail),
        // recycle
        .recycle_req (recycle_req_r), .recycle_cell_addr (recycle_cell_addr_r),
        .recycle_queue_id (recycle_queue_id_r),
        .mcast_recycle_req (mcast_recycle_req_r), .mcast_recycle_addr (mcast_recycle_addr_r),
        .mcast_recycle_queue_id (mcast_recycle_queue_id_r), .recycle_ack (recycle_ack),
        // full / near-full
        .q_empty (q_empty),                          // ★ B2
        .q_near_full (q_near_full), .port_near_full (port_near_full),
        .global_near_full (global_near_full), .q_full (q_full),
        .port_full (port_full), .global_full (global_full),
        // flow / alarm
        .pause_req (pause_req), .pfc_req (pfc_req),
        .irq_alarm (irq_alarm), .irq_aging (irq_aging),
        .overflow_alarm (overflow_alarm), .underflow_alarm (underflow_alarm),
        // cfg
        .cfg_in_queue_min_cell (cfg_queue_min_cell),
        .cfg_in_q_max_cell (cfg_q_max_cell),
        .cfg_in_q_full (cfg_q_full),
        .cfg_in_port_max (cfg_port_max),
        .cfg_in_global_high_wm (cfg_global_high_wm),
        .cfg_in_pause_en (cfg_pause_en),
        .cfg_in_port_pause_xoff (cfg_port_pause_xoff),
        .cfg_in_port_pause_xon (cfg_port_pause_xon),
        .cfg_in_global_pause_xoff (cfg_global_pause_xoff),
        .cfg_in_global_pause_xon (cfg_global_pause_xon),
        .cfg_in_pfc_en (cfg_pfc_en),
        .cfg_in_pfc_xoff (cfg_pfc_xoff),
        .cfg_in_pfc_xon (cfg_pfc_xon),
        // stats
        .st_out_global_used (st_out_global_used),
        .st_out_free_count (st_out_free_count),
        .st_out_q_static_used (st_out_q_static_used),
        .st_out_per_port_used (st_out_per_port_used),
        .st_out_per_queue_used (st_out_per_queue_used),
        .st_out_q_near_full_status (st_out_q_near_full_status),
        .st_out_tail_drop_cnt (st_out_tail_drop_cnt),
        .st_out_near_full_assert_cnt (st_out_near_full_assert_cnt),
        .st_out_pause_tx_cnt (st_out_pause_tx_cnt)
    );

    //========================================================================
    // 内部 DUT 信号引用
    //========================================================================
    wire [CNT_W-1:0]  lle_free_cnt   = u_dut.u_lle.free_cnt_q;
    wire [ADDR_W-1:0] lle_free_head  = u_dut.u_lle.free_head_q;
    wire [ADDR_W-1:0] lle_free_tail  = u_dut.u_lle.free_tail_q;
    wire [CNT_W-1:0]  occ_free_cnt   = u_dut.u_occ.free_count_q;
    wire [CNT_W-1:0]  occ_glob_used  = u_dut.u_occ.global_used_q;
    // ★ B2 多播槽状态
    wire              mc_valid       = u_dut.u_lle.mc_valid_q;
    wire [PORT_NUM-1:0] mc_bitmap    = u_dut.u_lle.mc_dst_bitmap_q;

    function automatic int unsigned lle_qcnt (input int qi); lle_qcnt = u_dut.u_lle.q_cell_cnt_q[qi]; endfunction
    function automatic int unsigned lle_qhead(input int qi); lle_qhead= u_dut.u_lle.q_head_q[qi];     endfunction
    function automatic int unsigned lle_qtail(input int qi); lle_qtail= u_dut.u_lle.q_tail_q[qi];     endfunction
    function automatic int unsigned occ_qcnt (input int qi); occ_qcnt = u_dut.u_occ.q_cell_cnt_q[qi]; endfunction
    function automatic int unsigned occ_qstat(input int qi); occ_qstat= u_dut.u_occ.q_static_used_q[qi]; endfunction
    function automatic int unsigned occ_pused(input int pi); occ_pused= u_dut.u_occ.per_port_used_q[pi]; endfunction
    // ★ B2 多播读/回收完成位图 + 待出单播包计数
    function automatic bit mc_rd_done (input int pi); mc_rd_done  = u_dut.u_lle.mc_rd_done_q[pi];  endfunction
    function automatic bit mc_rcy_done(input int pi); mc_rcy_done = u_dut.u_lle.mc_rcy_done_q[pi]; endfunction
    function automatic int unsigned mc_pend_uni(input int pi); mc_pend_uni = u_dut.u_lle.mc_pend_uni_q[pi]; endfunction
    function automatic int unsigned mc_ncell(); mc_ncell = u_dut.u_lle.mc_ncell_q; endfunction

    //========================================================================
    // Scoreboard
    //========================================================================
    typedef struct packed {
        logic [ADDR_W-1:0] addr;
        logic              ph;
        logic              pt;
        logic              drop;
    } alloc_ev_t;
    typedef struct packed {
        logic [ADDR_W-1:0] addr;
        logic              ph;
        logic              pt;
    } deq_ev_t;

    alloc_ev_t alloc_q[$];
    deq_ev_t   deq_q[$];
    int enq_fire_cnt;

    always @(posedge clk) begin
        if (rst_n) begin
            if (alloc_valid) begin
                alloc_q.push_back('{addr:alloc_cell_addr, ph:alloc_pkt_head,
                                    pt:alloc_pkt_tail, drop:alloc_drop_ind});
            end
            if (deq_cell_valid) begin
                deq_q.push_back('{addr:deq_cell_addr, ph:deq_pkt_head, pt:deq_pkt_tail});
            end
            if (enq_req_r & enq_ready) enq_fire_cnt <= enq_fire_cnt + 1;
        end
    end

    //========================================================================
    // 自检与计数
    //========================================================================
    int errors  = 0;
    int checks  = 0;
    string cur_case = "";

    task automatic chk(string nm, int got, int exp);
        checks++;
        if (got === exp) $display("    [PASS] %-30s got=%0d exp=%0d", nm, got, exp);
        else begin errors++; $display("    [FAIL] %-30s got=%0d exp=%0d  <<<<<<", nm, got, exp); end
    endtask

    task automatic chk_b(string nm, logic got, logic exp);
        checks++;
        if (got === exp) $display("    [PASS] %-30s got=%0b exp=%0b", nm, got, exp);
        else begin errors++; $display("    [FAIL] %-30s got=%0b exp=%0b  <<<<<<", nm, got, exp); end
    endtask

    task automatic case_begin(string nm);
        cur_case = nm;
        $display("\n================ CASE: %s ================", nm);
    endtask

    //========================================================================
    // 打印状态
    //========================================================================
    task automatic dump_state(string tag);
        int qi, pi;
        $display("  ---- [%0t] %s ----", $time, tag);
        $display("    LLE  free_cnt=%0d head=%0d tail=%0d | occ free=%0d glob_used=%0d | mc_valid=%0b bitmap=%b",
                 lle_free_cnt, lle_free_head, lle_free_tail, occ_free_cnt, occ_glob_used, mc_valid, mc_bitmap);
        for (qi=0; qi<QUEUE_NUM; qi++) begin
            if (lle_qcnt(qi)!=0 || occ_qcnt(qi)!=0)
                $display("    q[%0d] LLE: head=%0d tail=%0d cnt=%0d | occ: used=%0d static=%0d",
                         qi, lle_qhead(qi), lle_qtail(qi), lle_qcnt(qi), occ_qcnt(qi), occ_qstat(qi));
        end
        for (pi=0; pi<PORT_NUM; pi++)
            $display("    port[%0d] occ_used=%0d near_full=%0b full=%0b pause=%0b",
                     pi, occ_pused(pi), port_near_full[pi], port_full[pi], pause_req[pi]);
    endtask

    //========================================================================
    // 配置
    //========================================================================
    task automatic cfg_setup();
        int qi, pi, tj;
        for (qi=0; qi<QUEUE_NUM; qi++) begin
            cfg_queue_min_cell[qi] = 2;
            cfg_q_max_cell[qi]     = 10;
            cfg_q_full[qi]         = 12;
        end
        for (pi=0; pi<PORT_NUM; pi++) begin
            cfg_port_max[pi]        = 24;
            cfg_port_pause_xoff[pi] = 28;
            cfg_port_pause_xon[pi]  = 16;
            cfg_mcast_carry_tc[pi]  = MC_CARRY_TC[$clog2(TC_NUM)-1:0];   // ★ B2
            for (tj=0; tj<TC_NUM; tj++) begin
                cfg_pfc_xoff[pi][tj] = 9;
                cfg_pfc_xon[pi][tj]  = 4;
            end
        end
        cfg_global_high_wm    = 50;
        cfg_global_pause_xoff = 56;
        cfg_global_pause_xon  = 40;
        cfg_pause_en          = 1'b1;
        cfg_pfc_en            = 1'b1;
    endtask

    //========================================================================
    // 复位 + 初始化
    //========================================================================
    task automatic do_reset_init();
        rst_n = 0;
        init_start_r = 0;
        enq_req_r = 0; enq_queue_id_r=0; enq_egress_port_r=0; enq_cell_num_r=0; enq_is_mcast_r=0;
        enq_mcast_bitmap_r=0; enq_sof_r=0; enq_eof_r=0;
        deq_req_r=0; deq_queue_id_r=0; deq_backpressure_r=0;
        recycle_req_r=0; recycle_cell_addr_r=0; recycle_queue_id_r=0;
        mcast_recycle_req_r=0; mcast_recycle_addr_r=0; mcast_recycle_queue_id_r=0;
        cfg_setup();
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        @(negedge clk); init_start_r = 1;
        @(negedge clk); init_start_r = 0;
        while (!init_done) @(negedge clk);
        repeat (2) @(negedge clk);
        $display("[%0t] INIT done: free_cnt=%0d (expect %0d)", $time, lle_free_cnt, CELL_NUM);
    endtask

    //========================================================================
    // 入队一整包
    //========================================================================
    int                last_alloc_n;

    task automatic enqueue_pkt(input int qid, input int port, input int ncells,
                               input bit is_mcast, input [PORT_NUM-1:0] bitmap);
        int sent_idx;
        int got_before;
        sent_idx = 0;
        last_alloc_n = 0;
        got_before = alloc_q.size();
        $display("  >>> ENQ q%0d port%0d cells=%0d mcast=%0b bitmap=%b", qid, port, ncells, is_mcast, bitmap);
        while (sent_idx < ncells) begin
            @(negedge clk);
            if (enq_ready) begin
                enq_req_r          = 1'b1;
                enq_queue_id_r     = qid[QID_W-1:0];
                enq_egress_port_r  = port[PORT_W-1:0];
                enq_cell_num_r     = ncells[PKT_CELL_W-1:0];
                enq_is_mcast_r     = is_mcast;
                enq_mcast_bitmap_r = bitmap;
                enq_sof_r          = (sent_idx == 0);
                enq_eof_r          = (sent_idx == ncells-1);
                sent_idx++;
            end
            else enq_req_r = 1'b0;
        end
        @(negedge clk);
        enq_req_r = 1'b0; enq_sof_r=0; enq_eof_r=0; enq_cell_num_r=0; enq_is_mcast_r=0; enq_mcast_bitmap_r=0;
        repeat (3) @(negedge clk);
        last_alloc_n = alloc_q.size() - got_before;
    endtask

    //========================================================================
    // ★ 用【字面 qid】索引 DUT 寄存器计算 splice 判决 (避免读取依赖 deq_queue_id_r 的
    //   组合网 lle_q_empty/lle_qhead_pkt_tail 时的 delta 竞争: 刚 blocking 赋值
    //   deq_queue_id_r 后, 连续赋值 lle_deq_queue_id 尚未在本时间步传播, 直接读组合网
    //   会读到上一次 qid 的旧值)。这里复刻 LLE 的 splice 组合逻辑, 用常量 qid 索引。
    //========================================================================
    function automatic bit tb_mc_take(input int qid);
        int p; bit is_carry;
        p = qid >> QPP;
        is_carry = mc_valid && (qid < PORT_NUM*TC_NUM) &&
                   u_dut.u_lle.mc_dst_bitmap_q[p] &&
                   !u_dut.u_lle.mc_rd_done_q[p] &&
                   (qid == u_dut.u_lle.mc_carry_qid_q[p]);
        tb_mc_take = is_carry && (u_dut.u_lle.mc_pend_uni_q[p] == 0);
    endfunction

    function automatic bit tb_q_empty(input int qid);
        tb_q_empty = tb_mc_take(qid) ? 1'b0 : (u_dut.u_lle.q_cell_cnt_q[qid] == 0);
    endfunction

    function automatic bit tb_qhead_pt(input int qid);
        int p;
        p = qid >> QPP;
        if (tb_mc_take(qid))
            tb_qhead_pt = ((u_dut.u_lle.mc_rd_idx_q[p] + 1) == u_dut.u_lle.mc_ncell_q);
        else
            tb_qhead_pt = u_dut.u_lle.q_head_pt_q[qid];
    endfunction

    //========================================================================
    // 出队一整包 (背靠背, 直到该 QID 队头 pkt_tail)
    //   ★ B2: 用 tb_q_empty / tb_qhead_pt (字面 qid 索引, 含多播 splice) 判停,
    //     因为多播 take 时 q_cell_cnt[qid] 可能为 0 但仍有多播 cell 要出。
    //========================================================================
    int                last_deq_n;

    task automatic dequeue_pkt(input int qid, input [PORT_NUM-1:0] bp);
        int got_before;
        int guard;
        bit tail_fire;
        got_before = deq_q.size();
        guard = 0;
        $display("  >>> DEQ q%0d bp=%b", qid, bp);
        @(negedge clk);
        deq_queue_id_r     = qid[QID_W-1:0];
        deq_backpressure_r = bp;
        forever begin
            // q_empty (含多播 splice, 字面 qid 索引): 空则停
            if (tb_q_empty(qid)) begin
                deq_req_r = 1'b0;
                break;
            end
            deq_req_r = 1'b1;
            // 队头 pkt_tail (含多播 splice), 反映本 posedge 将出的 cell
            tail_fire = tb_qhead_pt(qid);
            @(negedge clk);
            if (tail_fire) begin
                deq_req_r = 1'b0;
                break;
            end
            guard++;
            if (guard > CELL_NUM*4) begin deq_req_r = 1'b0; break; end
        end
        repeat (3) @(negedge clk);
        last_deq_n = deq_q.size() - got_before;
    endtask

    //========================================================================
    // 单播还链
    //========================================================================
    task automatic recycle_cells(input int qid, input int cells[$]);
        int i;
        $display("  >>> RCY q%0d %0d cells", qid, cells.size());
        for (i=0; i<cells.size(); i++) begin
            @(negedge clk);
            recycle_req_r       = 1'b1;
            recycle_cell_addr_r = cells[i][ADDR_W-1:0];
            recycle_queue_id_r  = qid[QID_W-1:0];
        end
        @(negedge clk);
        recycle_req_r = 1'b0;
        repeat (cells.size()+4) @(negedge clk);
    endtask

    //========================================================================
    // ★ B2 组播逐端口回收: EPS 某端口发完一份 → 发一次 mcast_recycle_req,
    //   queue_id = 该端口承载 qid (MMU 反推端口)。一次即置 mc_rcy_done[port]。
    //========================================================================
    task automatic mcast_recycle_port(input int port);
        int cq;
        cq = carry_qid(port);
        $display("  >>> MCAST RCY port%0d (carry_qid=%0d)", port, cq);
        @(negedge clk);
        mcast_recycle_req_r      = 1'b1;
        mcast_recycle_addr_r     = '0;                       // B2 未用 addr
        mcast_recycle_queue_id_r = cq[QID_W-1:0];
        @(negedge clk);
        mcast_recycle_req_r = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    //========================================================================
    // 入队前预判探测
    //========================================================================
    task automatic probe_predict(input int qid, input int port, input int n, output bit pd);
        @(negedge clk);
        enq_req_r         = 1'b0;
        enq_queue_id_r    = qid[QID_W-1:0];
        enq_egress_port_r = port[PORT_W-1:0];
        enq_cell_num_r    = n[PKT_CELL_W-1:0];
        @(negedge clk);
        pd = enq_predict_drop;
        enq_cell_num_r    = 0;
    endtask

    //========================================================================
    // 主测试序列
    //========================================================================
    int base;
    initial begin
        do_reset_init();

        //====================================================================
        // C1: 单队列
        //====================================================================
        case_begin("C1 single-queue enq/deq/rcy + free_cnt");
        base = alloc_q.size();
        enqueue_pkt(0, q2port(0), 4, 0, '0);
        dump_state("after enq q0 4-cell");
        chk("C1 alloc_count",    last_alloc_n, 4);
        chk("C1 lle_q0_cnt",     lle_qcnt(0), 4);
        chk("C1 occ_q0_used",    occ_qcnt(0), 4);
        chk("C1 free_cnt",       lle_free_cnt, CELL_NUM-4);
        chk("C1 occ_free",       occ_free_cnt, CELL_NUM-4);
        chk("C1 occ_glob_used",  occ_glob_used, 4);
        base = deq_q.size();
        dequeue_pkt(0, '0);
        chk("C1 deq_count",      last_deq_n, 4);
        chk("C1 q0_cnt_after_deq", lle_qcnt(0), 0);
        chk("C1 occ_q0_after_deq", occ_qcnt(0), 4);
        chk("C1 free_after_deq",   lle_free_cnt, CELL_NUM-4);
        begin int rc[$]; rc='{0,1,2,3}; recycle_cells(0, rc); end
        dump_state("after rcy q0 4-cell");
        chk("C1 free_after_rcy",   lle_free_cnt, CELL_NUM);
        chk("C1 occ_q0_after_rcy", occ_qcnt(0), 0);
        chk("C1 occ_glob_after_rcy", occ_glob_used, 0);
        chk("C1 conserve", (lle_free_cnt==CELL_NUM)&&(occ_free_cnt==CELL_NUM), 1);

        //====================================================================
        // C2: 跨队列交叉
        //====================================================================
        case_begin("C2 cross-queue interleaved enq + deq");
        do_reset_init();
        enqueue_pkt(0, q2port(0), 3, 0, '0);   // q0: 0,1,2
        enqueue_pkt(1, q2port(1), 2, 0, '0);   // q1: 3,4
        enqueue_pkt(0, q2port(0), 2, 0, '0);   // q0: 5,6
        dump_state("after cross enq");
        chk("C2 lle_q0_cnt", lle_qcnt(0), 5);
        chk("C2 lle_q1_cnt", lle_qcnt(1), 2);
        chk("C2 free_cnt",   lle_free_cnt, CELL_NUM-7);
        chk("C2 q0_head",    lle_qhead(0), 0);
        chk("C2 q1_head",    lle_qhead(1), 3);
        base = deq_q.size();
        dequeue_pkt(0, '0);
        chk("C2 q0_deq1_count", last_deq_n, 3);
        chk("C2 q0_head_after", lle_qhead(0), 5);
        chk("C2 q0_cnt_after",  lle_qcnt(0), 2);
        dequeue_pkt(1, '0);
        chk("C2 q1_deq_count", last_deq_n, 2);
        chk("C2 q1_cnt_after", lle_qcnt(1), 0);
        dequeue_pkt(0, '0);
        chk("C2 q0_deq2_count", last_deq_n, 2);
        chk("C2 q0_cnt_final",  lle_qcnt(0), 0);
        begin int rc_q0[$]; int rc_q1[$];
            rc_q0='{0,1,2,5,6}; rc_q1='{3,4};
            recycle_cells(0, rc_q0); recycle_cells(1, rc_q1);
        end
        dump_state("after C2 recycle");
        chk("C2 free_restored",  lle_free_cnt, CELL_NUM);
        chk("C2 occ_glob_clear", occ_glob_used, 0);
        chk("C2 occ_q0_clear",   occ_qcnt(0), 0);
        chk("C2 occ_q1_clear",   occ_qcnt(1), 0);

        //====================================================================
        // C3: 还链恢复 + 守恒
        //====================================================================
        case_begin("C3 free-list restore + conservation");
        do_reset_init();
        enqueue_pkt(0, q2port(0), 2, 0, '0);   // 0,1
        enqueue_pkt(1, q2port(1), 3, 0, '0);   // 2,3,4
        enqueue_pkt(5, q2port(5), 4, 0, '0);   // 5,6,7,8
        dump_state("C3 after enq");
        chk("C3 free_after_enq", lle_free_cnt, CELL_NUM-9);
        chk("C3 glob_used",      occ_glob_used, 9);
        dequeue_pkt(0, '0);
        dequeue_pkt(1, '0);
        dequeue_pkt(5, '0);
        chk("C3 q0_empty", lle_qcnt(0), 0);
        chk("C3 q1_empty", lle_qcnt(1), 0);
        chk("C3 q5_empty", lle_qcnt(5), 0);
        chk("C3 free_unchanged_after_deq", lle_free_cnt, CELL_NUM-9);
        begin int r0[$]; int r1[$]; int r5[$];
            r0='{0,1}; r1='{2,3,4}; r5='{5,6,7,8};
            recycle_cells(0, r0); recycle_cells(1, r1); recycle_cells(5, r5);
        end
        dump_state("C3 after rcy");
        chk("C3 free_full",    lle_free_cnt, CELL_NUM);
        chk("C3 occ_free_full",occ_free_cnt, CELL_NUM);
        chk("C3 glob_zero",    occ_glob_used, 0);
        chk("C3 conserve",     (lle_free_cnt + occ_glob_used)==CELL_NUM, 1);
        chk_b("C3 no_overflow", overflow_alarm, 1'b0);
        chk_b("C3 no_underflow",underflow_alarm, 1'b0);

        //====================================================================
        // C4: ★ B2 多播 —— 单槽 / 逻辑拼接 / 逐端口回收 / 释放 / 满槽 drop
        //   规模: PORT=2, 承载 qid: port0→q0, port1→q4。
        //====================================================================
        case_begin("C4 B2 multicast: single-slot / splice deq / port recycle / release");
        do_reset_init();

        // ---- 场景铺垫: 让多播在 port0 排尾、port1 排头 ----
        // port0 承载队列 q0 先入 1 个单播包 A (2 cell: 0,1) → 多播对 q0 排在 A 之后
        enqueue_pkt(0, q2port(0), 2, 0, '0);         // A: cells 0,1
        chk("C4 q0_uni_backlog1", u_dut.u_lle.q_uni_pkt_backlog_q[0], 1);
        // 多播帧 3 cell 到 MCAST_QID, bitmap=2'b11 (port0+port1) → cells 2,3,4
        enqueue_pkt(MCAST_QID, 0, 3, 1, 2'b11);
        dump_state("C4 after mcast enq");
        chk("C4 mc_valid",        mc_valid, 1'b1);
        chk("C4 mcast_alloc_cnt", last_alloc_n, 3);
        chk("C4 mcast_ncell",     mc_ncell(), 3);
        chk("C4 mcastq_sram_cnt", lle_qcnt(MCAST_QID), 3);        // chain33 在 SRAM, cnt=3
        chk("C4 free_after_enq",  lle_free_cnt, CELL_NUM-5);      // A(2)+M(3)
        chk("C4 pend_uni_port0",  mc_pend_uni(0), 1);             // 排在 A 之后
        chk("C4 pend_uni_port1",  mc_pend_uni(1), 0);             // 排头
        // ★ empty 向量: q0(port0 承载) 有单播A → 非空; q4(port1 承载) 无单播但多播排头 → 非空
        chk_b("C4 q_empty_q0_uni",  q_empty[0], 1'b0);           // A 在, 非空
        chk_b("C4 q_empty_q4_mc",   q_empty[4], 1'b0);           // 多播排头 → mc_here 非空
        chk_b("C4 q_empty_q1_idle", q_empty[1], 1'b1);           // 无单播无多播 → 空
        // port1 承载队列 q4 之后再入单播包 C (2 cell: 5,6) → 多播对 q4 排头, C 在其后
        enqueue_pkt(4, q2port(4), 2, 0, '0);         // C: cells 5,6
        chk("C4 pend_uni_port1_still0", mc_pend_uni(1), 0);       // C 排在多播之后, 不改 pend

        // ---- port0 出队 (承载 q0): 应先出 A(2 cell) 再出多播(3 cell) ----
        base = deq_q.size();
        dequeue_pkt(0, '0);                          // 先 A
        chk("C4 p0_deqA_count", last_deq_n, 2);
        chk("C4 p0_pend_uni_0",  mc_pend_uni(0), 0);              // A 出完 → pend 归 0
        base = deq_q.size();
        dequeue_pkt(0, '0);                          // 再多播 M (splice)
        chk("C4 p0_deqM_count", last_deq_n, 3);
        chk("C4 p0_mc_rd_done", mc_rd_done(0), 1'b1);            // port0 读完多播
        chk("C4 free_after_p0",  lle_free_cnt, CELL_NUM-5);      // 出队不还链
        chk("C4 mc_valid_still",  mc_valid, 1'b1);               // 端口1 还没读, 槽不释放

        // ---- port1 出队 (承载 q4): 应先出多播(3 cell) 再出 C(2 cell) ----
        base = deq_q.size();
        dequeue_pkt(4, '0);                          // 先多播 M
        chk("C4 p1_deqM_count", last_deq_n, 3);
        chk("C4 p1_mc_rd_done", mc_rd_done(1), 1'b1);
        base = deq_q.size();
        dequeue_pkt(4, '0);                          // 再 C
        chk("C4 p1_deqC_count", last_deq_n, 2);

        // ---- 满槽 drop: 此时 mc_valid 仍为 1 (未回收完), 新多播应被 drop ----
        begin int ab; int dn; ab = alloc_q.size();
            enqueue_pkt(MCAST_QID, 0, 2, 1, 2'b01);  // 尝试入第 2 条多播
            dn = 0; for (int k=ab;k<alloc_q.size();k++) if (alloc_q[k].drop) dn++;
            chk("C4 mcast_busy_drop_all", dn, 2);    // 整帧被丢 (2 cell 全 drop)
        end
        chk("C4 mc_valid_after_drop", mc_valid, 1'b1);           // 槽未变 (仍是第一条)

        // ---- 逐端口回收: port0 发完 + port1 发完 → 全端口 rd&rcy done → 整帧释放 ----
        chk("C4 free_before_release", lle_free_cnt, CELL_NUM-5); // A+M 仍占 (A 单播还没回收, M 待释放)
        mcast_recycle_port(0);
        chk("C4 mc_valid_after_p0rcy", mc_valid, 1'b1);          // 只 port0 完成, 未释放
        mcast_recycle_port(1);
        repeat (8) @(negedge clk);                               // 等整帧 walk 还链落地
        dump_state("C4 after both port recycle");
        chk("C4 mc_valid_released", mc_valid, 1'b0);             // 全端口完成 → 释放
        // M 的 3 个 cell (2,3,4) 已还回 free; A(0,1)/C(5,6) 仍是单播未回收
        chk("C4 free_after_release", lle_free_cnt, CELL_NUM-4);  // 5 占用 - 3(M还链) = ... A(2)+C(2)=4 占用
        chk_b("C4 no_underflow", underflow_alarm, 1'b0);

        // ---- 清理单播 A(0,1) 与 C(5,6) ----
        begin int rA[$]; int rC[$]; rA='{0,1}; rC='{5,6};
              recycle_cells(0, rA); recycle_cells(4, rC); end
        dump_state("C4 after cleanup uni");
        chk("C4 free_full",  lle_free_cnt, CELL_NUM);
        chk("C4 glob_zero",  occ_glob_used, 0);

        // ---- 释放后可收新多播 ----
        enqueue_pkt(MCAST_QID, 0, 2, 1, 2'b11);
        chk("C4 new_mcast_accepted", mc_valid, 1'b1);
        chk("C4 new_mcast_ncell",    mc_ncell(), 2);
        // 收尾: 两端口读完+回收释放
        dequeue_pkt(0, '0);
        dequeue_pkt(4, '0);
        mcast_recycle_port(0);
        mcast_recycle_port(1);
        repeat (8) @(negedge clk);
        chk("C4 new_mcast_released", mc_valid, 1'b0);
        chk("C4 final_free_full",    lle_free_cnt, CELL_NUM);

        //====================================================================
        // C5~C11
        //====================================================================
        run_remaining_cases();

        repeat (10) @(negedge clk);
        $display("\n================ SUMMARY ================");
        $display("  Total checks = %0d, Errors = %0d", checks, errors);
        if (errors==0) $display("  >>>>>> ALL TESTS PASSED <<<<<<");
        else           $display("  >>>>>> %0d CHECK(S) FAILED <<<<<<", errors);
        $finish;
    end

    //========================================================================
    // C5~C11
    //========================================================================
    task automatic run_remaining_cases();
        int fire_base, ei, guard, dropn, i;
        int deq3_base;

        //--------------------------------------------------------------------
        // C5: enq + deq 同拍 + 反压
        //--------------------------------------------------------------------
        case_begin("C5 enq+deq concurrent + back-pressure");
        do_reset_init();
        enqueue_pkt(3, q2port(3), 6, 0, '0);
        chk("C5 prefill_q3_cnt", lle_qcnt(3), 6);
        fire_base = enq_fire_cnt;
        deq3_base = deq_q.size();
        guard = 0;
        @(negedge clk); deq_queue_id_r = 3; deq_backpressure_r = '0;
        while ( ((lle_qcnt(3) > 0) || ((enq_fire_cnt-fire_base) < 3)) && guard < 400 ) begin
            @(negedge clk);
            ei = enq_fire_cnt - fire_base;
            deq_req_r = (lle_qcnt(3) > 0);
            if (ei < 3) begin
                enq_req_r=1'b1; enq_queue_id_r=4; enq_egress_port_r=q2port(4);
                enq_is_mcast_r=1'b0; enq_mcast_bitmap_r='0;
                enq_sof_r=(ei==0); enq_eof_r=(ei==2);
            end else enq_req_r = 1'b0;
            guard++;
        end
        deq_req_r=0; enq_req_r=0; enq_sof_r=0; enq_eof_r=0;
        repeat (4) @(negedge clk);
        dump_state("C5 after concurrent enq+deq");
        chk("C5 q3_drained",    lle_qcnt(3), 0);
        chk("C5 q3_deq_count",  deq_q.size()-deq3_base, 6);
        chk("C5 q4_landed",     lle_qcnt(4), 3);
        chk("C5 enq_fire_3",    enq_fire_cnt-fire_base, 3);
        chk("C5 free_after",    lle_free_cnt, CELL_NUM-9);
        chk_b("C5 no_underflow",underflow_alarm, 1'b0);
        begin int r3[$]; int r4[$]; r3='{0,1,2,3,4,5}; r4='{6,7,8};
              recycle_cells(3, r3); recycle_cells(4, r4); end
        chk("C5 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C6: deq + rcy 同拍
        //--------------------------------------------------------------------
        case_begin("C6 deq + rcy concurrent");
        do_reset_init();
        enqueue_pkt(3, q2port(3), 6, 0, '0);
        enqueue_pkt(4, q2port(4), 3, 0, '0);
        dequeue_pkt(4, '0);
        chk("C6 q4_drained", lle_qcnt(4), 0);
        chk("C6 free_before_concurrent", lle_free_cnt, CELL_NUM-9);
        deq3_base = deq_q.size();
        guard = 0; i = 0;
        @(negedge clk); deq_queue_id_r = 3; deq_backpressure_r = '0;
        while ( ((lle_qcnt(3) > 0) || (i < 3)) && guard < 400 ) begin
            @(negedge clk);
            deq_req_r = (lle_qcnt(3) > 0);
            if (i < 3) begin
                recycle_req_r=1'b1; recycle_cell_addr_r=(6+i); recycle_queue_id_r=4; i++;
            end else recycle_req_r=1'b0;
            guard++;
        end
        deq_req_r=0; recycle_req_r=0;
        repeat (5) @(negedge clk);
        dump_state("C6 after concurrent deq+rcy");
        chk("C6 q3_drained",   lle_qcnt(3), 0);
        chk("C6 q3_deq_count", deq_q.size()-deq3_base, 6);
        chk("C6 free_after",   lle_free_cnt, CELL_NUM-6);
        chk("C6 occ_q4_dec",   occ_qcnt(4), 0);
        chk_b("C6 no_underflow", underflow_alarm, 1'b0);
        begin int r3[$]; r3='{0,1,2,3,4,5}; recycle_cells(3, r3); end
        chk("C6 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C7: enq + deq + rcy 三者同拍 (deq>enq>rcy)
        //--------------------------------------------------------------------
        case_begin("C7 enq+deq+rcy triple concurrent");
        do_reset_init();
        enqueue_pkt(3, q2port(3), 6, 0, '0);   // q3: 0..5
        enqueue_pkt(4, q2port(4), 3, 0, '0);   // q4: 6,7,8
        dequeue_pkt(4, '0);
        chk("C7 free_before", lle_free_cnt, CELL_NUM-9);
        fire_base = enq_fire_cnt;
        deq3_base = deq_q.size();
        guard = 0; i = 0;
        @(negedge clk); deq_queue_id_r = 3; deq_backpressure_r = '0;
        while ( ((lle_qcnt(3)>0) || ((enq_fire_cnt-fire_base)<2) || (i<3)) && guard<500 ) begin
            @(negedge clk);
            ei = enq_fire_cnt - fire_base;
            deq_req_r = (lle_qcnt(3) > 0);
            if (ei < 2) begin
                enq_req_r=1'b1; enq_queue_id_r=5; enq_egress_port_r=q2port(5);
                enq_is_mcast_r=1'b0; enq_mcast_bitmap_r='0;
                enq_sof_r=(ei==0); enq_eof_r=(ei==1);
            end else enq_req_r=1'b0;
            if (i < 3) begin
                recycle_req_r=1'b1; recycle_cell_addr_r=(6+i); recycle_queue_id_r=4; i++;
            end else recycle_req_r=1'b0;
            guard++;
        end
        deq_req_r=0; enq_req_r=0; recycle_req_r=0; enq_sof_r=0; enq_eof_r=0;
        repeat (6) @(negedge clk);
        dump_state("C7 after triple concurrent");
        chk("C7 q3_drained",   lle_qcnt(3), 0);
        chk("C7 q3_deq_count", deq_q.size()-deq3_base, 6);
        chk("C7 q5_landed",    lle_qcnt(5), 2);
        chk("C7 enq_fire_2",   enq_fire_cnt-fire_base, 2);
        chk("C7 free_after",   lle_free_cnt, CELL_NUM-8);
        chk_b("C7 no_underflow", underflow_alarm, 1'b0);
        begin int r3[$]; int r5[$];
              r3='{0,1,2,3,4,5};
              r5='{ int'(alloc_q[alloc_q.size()-2].addr),
                    int'(alloc_q[alloc_q.size()-1].addr) };
              recycle_cells(3, r3); recycle_cells(5, r5); end
        chk("C7 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C8: 水线/快满/满 + 高水位丢弃
        //--------------------------------------------------------------------
        case_begin("C8 watermark / near_full / hi-wm drop / release");
        do_reset_init();
        dropn = 0;
        begin int ab; ab = alloc_q.size();
            for (i=0;i<14;i++) enqueue_pkt(0, q2port(0), 1, 0, '0);
            for (i=ab;i<alloc_q.size();i++) if (alloc_q[i].drop) dropn++;
        end
        dump_state("C8 after burst enq q0");
        chk("C8 q0_cnt_cap",   lle_qcnt(0), 10);
        chk("C8 occ_q0",       occ_qcnt(0), 10);
        chk("C8 free_after",   lle_free_cnt, CELL_NUM-10);
        chk("C8 drop_count",   dropn, 4);
        chk_b("C8 q0_near_full_set", q_near_full[0], 1'b1);
        begin int r[$]; r='{0,1,2}; recycle_cells(0, r); end
        dump_state("C8 after release 3");
        chk("C8 occ_q0_after_rel", occ_qcnt(0), 7);
        chk_b("C8 q0_near_full_clr", q_near_full[0], 1'b0);

        //--------------------------------------------------------------------
        // C9: PAUSE 触发与释放
        //--------------------------------------------------------------------
        case_begin("C9 PAUSE assert / release (port aggregate)");
        do_reset_init();
        for (i=0;i<12;i++) enqueue_pkt(0, q2port(0), 1, 0, '0);
        for (i=0;i<12;i++) enqueue_pkt(1, q2port(1), 1, 0, '0);
        for (i=0;i<12;i++) enqueue_pkt(2, q2port(2), 1, 0, '0);
        dump_state("C9 after fill port0 ~30");
        chk("C9 port0_used",    occ_pused(0), 30);
        chk_b("C9 pause_set",   pause_req[0], 1'b1);
        begin int r0[$]; int r1[$];
              r0='{0,1,2,3,4,5,6,7,8,9};
              r1='{10,11,12,13,14};
              recycle_cells(0, r0); recycle_cells(1, r1); end
        dump_state("C9 after release to ~15");
        chk("C9 port0_used_rel", occ_pused(0), 15);
        chk_b("C9 pause_clr",    pause_req[0], 1'b0);

        //--------------------------------------------------------------------
        // C10: 压力测试
        //--------------------------------------------------------------------
        case_begin("C10 stress: fill / drain / recycle conservation");
        do_reset_init();
        for (i=0;i<6;i++) enqueue_pkt(i, q2port(i), 5, 0, '0);
        dump_state("C10 after fill 6x5");
        chk("C10 free_after_fill", lle_free_cnt, CELL_NUM-30);
        chk("C10 glob_used",       occ_glob_used, 30);
        for (i=0;i<6;i++) dequeue_pkt(i, '0);
        for (i=0;i<6;i++) chk($sformatf("C10 q%0d_drained",i), lle_qcnt(i), 0);
        chk("C10 free_unchanged_deq", lle_free_cnt, CELL_NUM-30);
        for (i=0;i<6;i++) begin
            int rr[$]; int k;
            rr.delete();
            for (k=0;k<5;k++) rr.push_back(i*5 + k);
            recycle_cells(i, rr);
        end
        dump_state("C10 after recycle all");
        chk("C10 free_full",   lle_free_cnt, CELL_NUM);
        chk("C10 glob_zero",   occ_glob_used, 0);
        chk("C10 conserve",    (lle_free_cnt+occ_glob_used)==CELL_NUM, 1);
        chk_b("C10 no_overflow",  overflow_alarm, 1'b0);
        chk_b("C10 no_underflow", underflow_alarm, 1'b0);

        //--------------------------------------------------------------------
        // C11: 入队前预判
        //--------------------------------------------------------------------
        case_begin("C11 pre-enq predict-drop (combinational)");
        do_reset_init();
        begin
            bit pd;
            probe_predict(0, q2port(0), 5, pd);
            chk_b("C11 empty_q0_n5_fit", pd, 1'b0);

            enqueue_pkt(0, q2port(0), 8, 0, '0);
            chk("C11 q0_cnt8", lle_qcnt(0), 8);

            probe_predict(0, q2port(0), 2, pd);
            chk_b("C11 q0_n2_fit",  pd, 1'b0);
            probe_predict(0, q2port(0), 3, pd);
            chk_b("C11 q0_n3_drop", pd, 1'b1);

            enqueue_pkt(0, q2port(0), 3, 0, '0);
            chk("C11 q0_n3_realdrop_cnt", lle_qcnt(0), 8);

            dequeue_pkt(0, '0);
            begin int r[$]; int k; r.delete(); for(k=0;k<8;k++) r.push_back(k);
                  recycle_cells(0, r); end
            chk("C11 q0_cleared",    lle_qcnt(0), 0);
            chk("C11 free_restored", lle_free_cnt, CELL_NUM);

            for (int qq=0; qq<4; qq++) enqueue_pkt(qq, q2port(qq), 10, 0, '0);
            enqueue_pkt(4, q2port(4), 8, 0, '0);
            chk("C11 glob_used_48", occ_glob_used, 48);
            probe_predict(5, q2port(5), 3, pd);
            chk_b("C11 q5_n3_global_drop", pd, 1'b1);
            probe_predict(5, q2port(5), 2, pd);
            chk_b("C11 q5_n2_global_fit",  pd, 1'b0);
        end
    endtask

    //========================================================================
    // 超时保护
    //========================================================================
    initial begin
        #2000000;
        $display("TIMEOUT! checks=%0d errors=%0d", checks, errors);
        $finish;
    end

endmodule
```