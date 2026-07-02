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