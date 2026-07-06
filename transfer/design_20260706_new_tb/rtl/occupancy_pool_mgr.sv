`timescale 1ns/1ps

//============================================================================
// Module      : occupancy_pool_mgr  (Occupancy & Pool Manager)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   占用计数 + 双池判决 + max 反馈 + PAUSE/PFC 迟滞 + 统计与告警。
//   Spec (QM design requirement) 只用两个概念:
//     - guaranteed buffer occupancy  → cfg_q_min_cell (per-queue 静态预留)
//     - maximum  buffer occupancy   → cfg_q_max_cell / cfg_port_max / cfg_global_max
//   命名统一为 "min / max" (以及 "near_max" 与阈值-余量对应), 不再混用
//   full / high_wm 等别名。所有队列/端口/TC 共用同一套阈值(由顶层 fanout)。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================

module occupancy_pool_mgr #(
    parameter int CELL_NUM  = 8192,
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,     // 每端口 TC 数 (per-port traffic class)
    parameter int STAT_W    = 32,    // 统计计数器位宽
    parameter int PKT_CELL_W = 4,    // enq_cell_num 位宽 (本包 cell 数, ≤ 单帧最大 cell)
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
    input  logic                       clr_ptr_cnt,          // ★ 初始化期同步清 (来自 csr Init FSM)

    //------------------------------------------------------------------------
    // 与 Enqueue Ctrl 的接口 (占用判决查询, 组合返回支撑 1 拍)
    //------------------------------------------------------------------------
    input  logic                       occ_query_vld,        // 占用判决查询
    input  logic [QID_W-1:0]           occ_query_queue_id,   // 待判决队列号
    input  logic [PORT_W-1:0]          occ_query_egress_port,// 待判决出端口
    input  logic [PKT_CELL_W-1:0]      occ_query_cell_num,   // 本包 cell 数(SOF 有效, 入队前预判用)
    output logic                       occ_accept,           // 判决=接收
    output logic                       occ_drop,             // 判决=丢弃 (命中 max 兜底 / 空闲池空)
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
    // 流控 / max 反馈输出 (spec: maximum buffer occupancy)
    //------------------------------------------------------------------------
    output logic [PORT_NUM-1:0]        pause_req,            // 端口占用越 XOFF 时发 IEEE PAUSE
    output logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_req,         // 802.1Qbb PFC. 每端口TC反压位图
    output logic [QUEUE_NUM-1:0]       q_max_reached,        // 每队列已到 max (QM 前置门控)
    output logic [PORT_NUM-1:0]        port_max_reached,     // 每出端口已到 max
    output logic                       global_max_reached,   // 全局已到 max

    //------------------------------------------------------------------------
    // 配置下发 (← CSR). 统一命名: cfg_q_min_cell (guaranteed) /
    //   cfg_q_max_cell / cfg_port_max / cfg_global_max (spec: maximum)。
    //------------------------------------------------------------------------
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_min_cell,  // 每队列静态预留 (guaranteed)
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_max_cell,  // 每队列最大占用上限
    input  logic [PORT_NUM-1:0][CNT_W-1:0]  cfg_port_max,    // 每出端口最大占用上限
    input  logic [CNT_W-1:0]                cfg_global_max,  // 全局最大占用上限

    input  logic                            cfg_pause_en,        // PAUSE 使能
    input  logic [PORT_NUM-1:0][CNT_W-1:0]  cfg_port_pause_xoff, // 每端口: 占用>=此值触发 PAUSE
    input  logic [PORT_NUM-1:0][CNT_W-1:0]  cfg_port_pause_xon,  // 每端口: 占用< 此值撤销 PAUSE
    input  logic [CNT_W-1:0]                cfg_global_pause_xoff, // 全局: 占用>=此值触发 PAUSE
    input  logic [CNT_W-1:0]                cfg_global_pause_xon,  // 全局: 占用< 此值撤销 PAUSE

    input  logic                            cfg_pfc_en,      // PFC 使能
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0] cfg_pfc_xoff, // 每 TC: 占用>=此值触发 PFC
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0] cfg_pfc_xon,  // 每 TC: 占用< 此值撤销 PFC

    //------------------------------------------------------------------------
    // 统计上报 (→ CSR)
    //------------------------------------------------------------------------
    output logic [CNT_W-1:0]                st_global_used,      // 全局占用
    output logic [CNT_W-1:0]                st_free_count,       // 空闲计数
    output logic [QUEUE_NUM-1:0][CNT_W-1:0] st_q_static_used,    // 每队列静态池占用
    output logic [PORT_NUM-1:0][CNT_W-1:0]  st_per_port_used,    // 每端口占用(端口级聚合)
    output logic [QUEUE_NUM-1:0][CNT_W-1:0] st_per_queue_used,   // 每队列占用
    output logic [QUEUE_NUM-1:0]            st_q_max_reached_status, // 到 max 状态镜像
    output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_tail_drop_cnt,   // 命中 max/池空 丢包计数
    output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_q_max_assert_cnt,// 队列 max 置位次数
    output logic [PORT_NUM-1:0][STAT_W-1:0]  st_pause_tx_cnt,    // PAUSE 发送计数
    output logic                            overflow_alarm,      // cell 池溢出告警
    output logic                            underflow_alarm      // 守恒/下溢告警
);
    //========================================================================
    // 内部状态寄存器
    //========================================================================
    logic [CNT_W-1:0]  free_count_q;                    // 空闲数量
    logic [CNT_W-1:0]  global_used_q;                   // 全局使用量 = CELL_NUM - free_count_q
    logic [CNT_W-1:0]  q_cell_cnt_q     [QUEUE_NUM];    // 每队列使用量
    logic [CNT_W-1:0]  q_static_used_q  [QUEUE_NUM];    // 每队列静态使用量
    logic [CNT_W-1:0]  per_port_used_q  [PORT_NUM];     // 每端口使用量

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

    //========================================================================
    // 事件仲裁 / inc-dec 生成 (纯组合)
    //========================================================================
    always_comb begin
        alloc_allowed  = 1'b0;
        free_allowed   = 1'b0;
        alloc_port     = evt_egress_port;
        free_port      = occ_free_egress_port;
        same_queue_evt = lle_alloc_evt && occ_free_vld && (evt_queue_id == occ_free_queue_id);
        same_port_evt  = lle_alloc_evt && occ_free_vld && (alloc_port == free_port);

        // free: 仅做防下溢校验 (该队列占用非 0)
        for (int i = 0; i < QUEUE_NUM; i++) begin
            if (occ_free_vld && (occ_free_queue_id == i) && (q_cell_cnt_q[i] != '0))
                free_allowed = 1'b1;
        end

        // alloc: 信任 LLE 决策 (lle_alloc_evt = enq_grant 已保证 free 池可用)
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
            // ★ B2: 多播 cell 一份共享, 不归属任何物理端口 →
            //   evt_queue_id == MC_QID (>= PORT_NUM*TC_NUM) 时跳过 per-port 计数。
            port_inc[i] = alloc_allowed && (evt_queue_id < QID_W'(PORT_NUM*TC_NUM)) &&
                          (alloc_port == i) &&
                          !(same_port_evt && free_allowed);
            port_dec[i] = free_allowed && (occ_free_queue_id < QID_W'(PORT_NUM*TC_NUM)) &&
                          (free_port == i) &&
                          (per_port_used_q[i] != '0) &&
                          !(same_port_evt && alloc_allowed);
        end
    end

    //========================================================================
    // per-queue cell 计数
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < QUEUE_NUM; i++) q_cell_cnt_q[i] <= #1 '0;
        end
        else if (clr_ptr_cnt) begin              // ★ 初始化期同步清
            for (int i = 0; i < QUEUE_NUM; i++) q_cell_cnt_q[i] <= #1 '0;
        end
        else begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                if (q_cell_inc[i] && !q_cell_dec[i])
                    q_cell_cnt_q[i] <= #1 q_cell_cnt_q[i] + 1'b1;
                else if (!q_cell_inc[i] && q_cell_dec[i])
                    q_cell_cnt_q[i] <= #1 q_cell_cnt_q[i] - 1'b1;
            end
        end
    end

    //========================================================================
    // per-queue 静态池计数
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < QUEUE_NUM; i++) q_static_used_q[i] <= #1 '0;
        end
        else if (clr_ptr_cnt) begin              // ★ 初始化期同步清
            for (int i = 0; i < QUEUE_NUM; i++) q_static_used_q[i] <= #1 '0;
        end
        else begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                if (q_static_inc[i] && !q_static_dec[i])
                    q_static_used_q[i] <= #1 q_static_used_q[i] + 1'b1;
                else if (!q_static_inc[i] && q_static_dec[i])
                    q_static_used_q[i] <= #1 q_static_used_q[i] - 1'b1;
            end
        end
    end

    //========================================================================
    // per-port 聚合计数
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < PORT_NUM; i++) per_port_used_q[i] <= #1 '0;
        end
        else if (clr_ptr_cnt) begin              // ★ 初始化期同步清
            for (int i = 0; i < PORT_NUM; i++) per_port_used_q[i] <= #1 '0;
        end
        else begin
            for (int i = 0; i < PORT_NUM; i++) begin
                if (port_inc[i] && !port_dec[i])
                    per_port_used_q[i] <= #1 per_port_used_q[i] + 1'b1;
                else if (!port_inc[i] && port_dec[i])
                    per_port_used_q[i] <= #1 per_port_used_q[i] - 1'b1;
            end
        end
    end

    //========================================================================
    // free / global 计数
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            free_count_q  <= #1 CELL_NUM[CNT_W-1:0];
            global_used_q <= #1 '0;
        end
        else if (clr_ptr_cnt) begin              // ★ 初始化期同步清
            free_count_q  <= #1 CELL_NUM[CNT_W-1:0];
            global_used_q <= #1 '0;
        end
        else begin
            case ({alloc_allowed, free_allowed})
                2'b10: if (free_count_q != '0) begin   // 仅分配
                    free_count_q  <= #1 free_count_q  - 1'b1;
                    global_used_q <= #1 global_used_q + 1'b1;
                end
                2'b01: if (global_used_q != '0) begin  // 仅回收
                    free_count_q  <= #1 free_count_q  + 1'b1;
                    global_used_q <= #1 global_used_q - 1'b1;
                end
                2'b11: begin                           // 同拍分配+回收: 净不变
                    free_count_q  <= #1 free_count_q;
                    global_used_q <= #1 global_used_q;
                end
                default: ;
            endcase
        end
    end

    //========================================================================
    // ★ Drop 判决 (核心)
    //   命中"最大占用上限" (max) 或 空闲池空 → 丢弃。
    //   spec 术语统一: q_max_hit / port_max_hit / global_max_reached, 内部综合位
    //   max_hit_drop 参与判决, 同时对外输出 q_max_reached / port_max_reached。
    //========================================================================
    logic                 max_hit_drop;      // 命中任一 max (队列 或 端口 或 全局)
    logic [QUEUE_NUM-1:0] q_max_hit;         // q_cell_cnt_q[q] >= cfg_q_max_cell[q]
    logic [PORT_NUM-1:0]  port_max_hit;      // per_port_used_q[p] >= cfg_port_max[p]

    always_comb begin
        occ_no_free        = (free_count_q == '0);
        global_max_reached = (global_used_q >= cfg_global_max);

        // Drop 判决: 空闲池空(硬兜底) 或 (非静态穿透 且 命中任一 max)
        occ_drop      = occ_query_vld & (occ_no_free | (~occ_use_static & max_hit_drop));
        occ_accept    = occ_query_vld & ~occ_drop;
        // ★ 判决基于【查询的队列/端口】(occ_query_*), 而非 alloc 事件 (evt_*)。
        //   occ_query 在 enqueue_ctrl 的 T0 组合发起, evt_* 是 LLE 在落地拍才有效,
        //   二者不同拍; 判决必须用当拍查询的 queue/port。
        // 双池: 该队列静态额度未用满 → 记静态账 (可绕过 max)
        occ_use_static = use_static_vec[occ_query_queue_id];
        max_hit_drop   = q_max_hit[occ_query_queue_id]
                       | port_max_hit[occ_query_egress_port]
                       | global_max_reached;
    end

    //========================================================================
    // ★ 入队前整包预判 (advisory, 纯组合)
    //   QM 在 SOF 拍给本包 cell 数 occ_query_cell_num, 判整包能否放下 (等价逐 cell
    //   drop 的整包预判)。规则与 occ_drop 一致 (max 而非 full 语义)。
    //========================================================================
    logic [CNT_W-1:0] pred_cell_num;
    logic [CNT_W-1:0] pred_s_rem;      // 该队列静态额度剩余
    logic             pred_fit;
    always_comb begin
        pred_cell_num = {{(CNT_W-PKT_CELL_W){1'b0}}, occ_query_cell_num};
        if (q_static_used_q[occ_query_queue_id] < cfg_q_min_cell[occ_query_queue_id])
            pred_s_rem = cfg_q_min_cell[occ_query_queue_id] - q_static_used_q[occ_query_queue_id];
        else
            pred_s_rem = '0;
        pred_fit = (free_count_q >= pred_cell_num)
                && ( (pred_cell_num <= pred_s_rem)                                          // 全落静态额度 → 绕过 max
                     || ( (q_cell_cnt_q[occ_query_queue_id]       + pred_cell_num <= cfg_q_max_cell[occ_query_queue_id])
                       && (per_port_used_q[occ_query_egress_port] + pred_cell_num <= cfg_port_max[occ_query_egress_port])
                       && (global_used_q                          + pred_cell_num <= cfg_global_max) ) );
        occ_predict_drop = ~pred_fit;
    end

    //========================================================================
    // max 命中向量 (内部) + 对外 max_reached 输出 (同表达式)
    //========================================================================
    always_comb begin
        for (int i = 0; i < QUEUE_NUM; i++) begin
            use_static_vec[i] = q_static_used_q[i] < cfg_q_min_cell[i];
            q_max_hit[i]      = q_cell_cnt_q[i]    >= cfg_q_max_cell[i];
            q_max_reached[i]  = q_max_hit[i];
        end
    end
    always_comb begin
        for (int i = 0; i < PORT_NUM; i++) begin
            port_max_hit[i]     = per_port_used_q[i] >= cfg_port_max[i];
            port_max_reached[i] = port_max_hit[i];
        end
    end

    //============================================
    // PAUSE (802.3x) 端口聚合 XOFF/XON 双阈值迟滞
    //============================================
    assign global_pause_xoff = (global_used_q >= cfg_global_pause_xoff);
    assign global_pause_xon  = (global_used_q <  cfg_global_pause_xon);
    always_comb begin
        for (int i = 0; i < PORT_NUM; i++) begin
            pause_set[i] = (per_port_used_q[i] >= cfg_port_pause_xoff[i]) | global_pause_xoff; // 端口或全局达到 xoff
            pause_clr[i] = (per_port_used_q[i] <  cfg_port_pause_xon[i])  & global_pause_xon;  // 端口且全局回落 xon
        end
    end
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n)
            pause_req <= #1 '0;
        else if (clr_ptr_cnt)
            pause_req <= #1 '0;                  // ★ 初始化期同步清
        else begin
            for (int i = 0; i < PORT_NUM; i++) begin
                if      (!cfg_pause_en)    pause_req[i] <= #1 1'b0;
                else if ( pause_set[i])    pause_req[i] <= #1 1'b1;
                else if ( pause_clr[i])    pause_req[i] <= #1 1'b0;
                // 中间区保持原值, 迟滞
            end
        end
    end

    //============================================
    // PFC (802.1Qbb) per-TC XOFF/XON 双阈值迟滞
    //============================================
    logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0] per_tc_used;
    always_comb begin
        for (int i = 0; i < PORT_NUM; i++)
            for (int j = 0; j < TC_NUM; j++)
                per_tc_used[i][j] = q_cell_cnt_q[i*TC_NUM+j];
    end

    logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_set;
    logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_clr;
    always_comb begin
        for (int i = 0; i < PORT_NUM; i++)
            for (int j = 0; j < TC_NUM; j++) begin
                pfc_set[i][j] = per_tc_used[i][j] >= cfg_pfc_xoff[i][j];
                pfc_clr[i][j] = per_tc_used[i][j] <  cfg_pfc_xon[i][j];
            end
    end

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n)
            pfc_req <= #1 '0;
        else if (clr_ptr_cnt)
            pfc_req <= #1 '0;                    // ★ 初始化期同步清
        else begin
            for (int i = 0; i < PORT_NUM; i++)
                for (int j = 0; j < TC_NUM; j++) begin
                    if      (!cfg_pfc_en)      pfc_req[i][j] <= #1 1'b0;
                    else if ( pfc_set[i][j])   pfc_req[i][j] <= #1 1'b1;
                    else if ( pfc_clr[i][j])   pfc_req[i][j] <= #1 1'b0;
                    // 中间区保持原值, 迟滞
                end
        end
    end

    //========================================================================
    // 事件累加计数器 (drop / pause / q_max 置位 次数)
    //   - tail_drop_cnt      : 每队列被判丢 (occ_drop) 次数 (按 cell 计, 饱和)
    //   - pause_tx_cnt       : 每端口 PAUSE 发送次数 (pause_req 上升沿 +1)
    //   - q_max_assert_cnt   : 每队列 q_max_reached 置位次数 (0→1 +1)
    //========================================================================
    logic [QUEUE_NUM-1:0][STAT_W-1:0] tail_drop_cnt_q;
    logic [QUEUE_NUM-1:0][STAT_W-1:0] q_max_assert_cnt_q;
    logic [PORT_NUM-1:0][STAT_W-1:0]  pause_tx_cnt_q;

    // 上升沿检测用的上一拍状态
    logic [QUEUE_NUM-1:0] q_max_reached_d;
    logic [PORT_NUM-1:0]  pause_req_d;

    // 本拍丢包事件: 判决查询有效且判丢 → 命中 occ_query_queue_id 队列
    logic                 tail_drop_evt;
    assign tail_drop_evt = occ_query_vld & occ_drop;

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                tail_drop_cnt_q[i]    <= #1 '0;
                q_max_assert_cnt_q[i] <= #1 '0;
            end
            for (int i = 0; i < PORT_NUM; i++)
                pause_tx_cnt_q[i]     <= #1 '0;
            q_max_reached_d <= #1 '0;
            pause_req_d     <= #1 '0;
        end
        else if (clr_ptr_cnt) begin              // ★ 初始化期同步清
            for (int i = 0; i < QUEUE_NUM; i++) begin
                tail_drop_cnt_q[i]    <= #1 '0;
                q_max_assert_cnt_q[i] <= #1 '0;
            end
            for (int i = 0; i < PORT_NUM; i++)
                pause_tx_cnt_q[i]     <= #1 '0;
            q_max_reached_d <= #1 '0;
            pause_req_d     <= #1 '0;
        end
        else begin
            // 记录上一拍状态 (做上升沿检测)
            q_max_reached_d <= #1 q_max_reached;
            pause_req_d     <= #1 pause_req;

            // tail_drop: 命中 occ_query_queue_id 队列 +1 (饱和)
            for (int i = 0; i < QUEUE_NUM; i++) begin
                if (tail_drop_evt && (occ_query_queue_id == QID_W'(i)) &&
                    (tail_drop_cnt_q[i] != '1))
                    tail_drop_cnt_q[i] <= #1 tail_drop_cnt_q[i] + 1'b1;
            end

            // q_max_assert: q_max_reached 由 0→1 +1 (饱和)
            for (int i = 0; i < QUEUE_NUM; i++) begin
                if (q_max_reached[i] && !q_max_reached_d[i] &&
                    (q_max_assert_cnt_q[i] != '1))
                    q_max_assert_cnt_q[i] <= #1 q_max_assert_cnt_q[i] + 1'b1;
            end

            // pause_tx: pause_req 由 0→1 +1 (饱和)
            for (int i = 0; i < PORT_NUM; i++) begin
                if (pause_req[i] && !pause_req_d[i] &&
                    (pause_tx_cnt_q[i] != '1))
                    pause_tx_cnt_q[i] <= #1 pause_tx_cnt_q[i] + 1'b1;
            end
        end
    end

    //========================================================================
    // 统计输出
    //========================================================================
    assign st_global_used            = global_used_q;
    assign st_free_count             = free_count_q;
    assign st_q_max_reached_status   = q_max_reached;
    assign st_tail_drop_cnt          = tail_drop_cnt_q;
    assign st_q_max_assert_cnt       = q_max_assert_cnt_q;
    assign st_pause_tx_cnt           = pause_tx_cnt_q;
    always_comb begin
        for (int i = 0; i < QUEUE_NUM; i++) begin
            st_q_static_used[i]  = q_static_used_q[i];
            st_per_queue_used[i] = q_cell_cnt_q[i];
        end
        for (int i = 0; i < PORT_NUM; i++)
            st_per_port_used[i]  = per_port_used_q[i];
    end

    //========================================================================
    // 守恒 / 溢出 / 下溢 告警
    //========================================================================
    logic conserve_ok;
    assign conserve_ok = ((free_count_q + global_used_q) == CELL_NUM[CNT_W-1:0]);
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            overflow_alarm  <= #1 1'b0;
            underflow_alarm <= #1 1'b0;
        end
        else if (clr_ptr_cnt) begin              // ★ 初始化期同步清
            overflow_alarm  <= #1 1'b0;
            underflow_alarm <= #1 1'b0;
        end
        else begin
            overflow_alarm  <= #1 (global_used_q > CELL_NUM[CNT_W-1:0]);
            underflow_alarm <= #1 ~conserve_ok
                               | (alloc_allowed & (free_count_q  == '0))
                               | (free_allowed  & (global_used_q == '0));
        end
    end

endmodule