//============================================================================
// Module      : smmu  (Smart MMU Top)
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

module smmu #(
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
    input  logic [$clog2(TC_NUM)-1:0] enq_queue_id,    // ★ 目标 TC (0..TC_NUM-1); 完整队列={egress_port,queue_id}
    input  logic [PORT_W-1:0]     enq_egress_port,     // 出端口 ID
    input  logic [PKT_CELL_W-1:0] enq_cell_num,        // ★ 本包 cell 数(SOF 有效, 入队前预判用)
    input  logic                  enq_is_mcast,        // 组播标志
    input  logic [PORT_NUM-1:0]   enq_mcast_bitmap,    // 组播出端口位图 (多播承载 TC = enq_queue_id)
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