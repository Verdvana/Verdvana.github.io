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
//   ★ 命名统一 (对齐 spec "guaranteed / maximum"):
//     - cfg_q_min_cell  = guaranteed buffer occupancy (每队列静态预留)
//     - cfg_q_max_cell / cfg_port_max / cfg_global_max = maximum buffer occupancy
//     - 输出 max_reached / max_assert 系列, 不再混用 full / high_wm 别名
//     - 删除冗余 cfg_q_full (与 cfg_q_max_cell 语义重复)
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
    // guaranteed / maximum buffer occupancy (spec)
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_in_q_min_cell,        // 每队列静态预留 (guaranteed)
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_in_q_max_cell,        // 每队列最大占用上限
    input  logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_in_port_max,          // 每出端口最大占用上限
    input  logic [CNT_W-1:0]                            cfg_in_global_max,        // 全局最大占用上限
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
    // ★ 老化机制配置 (队列/端口 aging)
    input  logic                                        cfg_in_aging_en,          // 老化总使能
    input  logic [23:0]                                 cfg_in_aging_timeout,     // 老化超时阈值 (cycle)
    input  logic [QUEUE_NUM-1:0]                        cfg_in_age_force,         // 软件强制某队列老化

    //------------------------------------------------------------------------
    // 统计汇聚 (← Occupancy) + 告警 (← Occupancy)
    //------------------------------------------------------------------------
    input  logic [CNT_W-1:0]                            st_global_used,
    input  logic [CNT_W-1:0]                            st_free_count,
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             st_q_static_used,
    input  logic [PORT_NUM-1:0][CNT_W-1:0]              st_per_port_used,
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0]             st_per_queue_used,
    input  logic [QUEUE_NUM-1:0]                        st_q_max_reached_status,  // ★ 到 max 状态镜像
    input  logic [QUEUE_NUM-1:0][STAT_W-1:0]            st_tail_drop_cnt,
    input  logic [QUEUE_NUM-1:0][STAT_W-1:0]            st_q_max_assert_cnt,      // ★ 队列 max 置位次数
    input  logic [PORT_NUM-1:0][STAT_W-1:0]             st_pause_tx_cnt,
    input  logic                                        overflow_alarm,      // ← Occupancy
    input  logic                                        underflow_alarm,     // ← Occupancy
    input  logic                                        aging_irq_in,        // ← aging_ctrl (有队列老化)

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
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_q_min_cell,
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]             cfg_q_max_cell,
    output logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_max,
    output logic [CNT_W-1:0]                            cfg_global_max,
    output logic                                        cfg_pause_en,
    output logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_pause_xoff,
    output logic [PORT_NUM-1:0][CNT_W-1:0]              cfg_port_pause_xon,
    output logic [CNT_W-1:0]                            cfg_global_pause_xoff,
    output logic [CNT_W-1:0]                            cfg_global_pause_xon,
    output logic                                        cfg_pfc_en,
    output logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xoff,
    output logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xon,
    // ★ 老化配置下发 (→ aging_ctrl)
    output logic                                        cfg_aging_en,
    output logic [23:0]                                 cfg_aging_timeout,
    output logic [QUEUE_NUM-1:0]                        cfg_age_force,

    //------------------------------------------------------------------------
    // 统计输出 (→ 外部 CSR/CPU, clk_core 域直接输出, 无总线)
    //------------------------------------------------------------------------
    output logic [CNT_W-1:0]                            st_out_global_used,
    output logic [CNT_W-1:0]                            st_out_free_count,
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]             st_out_q_static_used,
    output logic [PORT_NUM-1:0][CNT_W-1:0]              st_out_per_port_used,
    output logic [QUEUE_NUM-1:0][CNT_W-1:0]             st_out_per_queue_used,
    output logic [QUEUE_NUM-1:0]                        st_out_q_max_reached_status, // ★ 改名
    output logic [QUEUE_NUM-1:0][STAT_W-1:0]            st_out_tail_drop_cnt,
    output logic [QUEUE_NUM-1:0][STAT_W-1:0]            st_out_q_max_assert_cnt,     // ★ 改名
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
    // Signal
    logic [1:0] init_start_q;
    logic       init_start_edge;
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) init_start_q <= #1 2'b00;
        else             init_start_q <= #1 {init_start_q[0], init_start};
    end
    assign init_start_edge = init_start_q[0] & ~init_start_q[1];   // 上升沿触发

    //========================================================================
    // 配置采样: 外部 cfg_in_* 在 clk_core 域已 ready, 寄存一拍去毛刺后下发。
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            cfg_q_min_cell        <= #1 '0;
            cfg_q_max_cell        <= #1 '0;
            cfg_port_max          <= #1 '0;
            cfg_global_max        <= #1 '0;
            cfg_pause_en          <= #1 1'b0;
            cfg_port_pause_xoff   <= #1 '0;
            cfg_port_pause_xon    <= #1 '0;
            cfg_global_pause_xoff <= #1 '0;
            cfg_global_pause_xon  <= #1 '0;
            cfg_pfc_en            <= #1 1'b0;
            cfg_pfc_xoff          <= #1 '0;
            cfg_pfc_xon           <= #1 '0;
            cfg_aging_en          <= #1 1'b0;
            cfg_aging_timeout     <= #1 '0;
            cfg_age_force         <= #1 '0;
        end
        else begin
            cfg_q_min_cell        <= #1 cfg_in_q_min_cell;
            cfg_q_max_cell        <= #1 cfg_in_q_max_cell;
            cfg_port_max          <= #1 cfg_in_port_max;
            cfg_global_max        <= #1 cfg_in_global_max;
            cfg_pause_en          <= #1 cfg_in_pause_en;
            cfg_port_pause_xoff   <= #1 cfg_in_port_pause_xoff;
            cfg_port_pause_xon    <= #1 cfg_in_port_pause_xon;
            cfg_global_pause_xoff <= #1 cfg_in_global_pause_xoff;
            cfg_global_pause_xon  <= #1 cfg_in_global_pause_xon;
            cfg_pfc_en            <= #1 cfg_in_pfc_en;
            cfg_pfc_xoff          <= #1 cfg_in_pfc_xoff;
            cfg_pfc_xon           <= #1 cfg_in_pfc_xon;
            cfg_aging_en          <= #1 cfg_in_aging_en;
            cfg_aging_timeout     <= #1 cfg_in_aging_timeout;
            cfg_age_force         <= #1 cfg_in_age_force;
        end
    end

    //========================================================================
    // 统计输出: 自 Occupancy 汇聚的 st_* 在 clk_core 域寄存一拍后直出给外部 CSR/CPU。
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            st_out_global_used            <= #1 '0;
            st_out_free_count             <= #1 '0;
            st_out_q_static_used          <= #1 '0;
            st_out_per_port_used          <= #1 '0;
            st_out_per_queue_used         <= #1 '0;
            st_out_q_max_reached_status   <= #1 '0;
            st_out_tail_drop_cnt          <= #1 '0;
            st_out_q_max_assert_cnt       <= #1 '0;
            st_out_pause_tx_cnt           <= #1 '0;
        end
        else begin
            st_out_global_used            <= #1 st_global_used;
            st_out_free_count             <= #1 st_free_count;
            st_out_q_static_used          <= #1 st_q_static_used;
            st_out_per_port_used          <= #1 st_per_port_used;
            st_out_per_queue_used         <= #1 st_per_queue_used;
            st_out_q_max_reached_status   <= #1 st_q_max_reached_status;
            st_out_tail_drop_cnt          <= #1 st_tail_drop_cnt;
            st_out_q_max_assert_cnt       <= #1 st_q_max_assert_cnt;
            st_out_pause_tx_cnt           <= #1 st_pause_tx_cnt;
        end
    end

    //========================================================================
    // 告警中断聚合 (overflow/underflow → irq_alarm; aging_irq_in → irq_aging)
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            irq_alarm <= #1 1'b0;
            irq_aging <= #1 1'b0;
        end
        else begin
            irq_alarm <= #1 overflow_alarm | underflow_alarm;
            irq_aging <= #1 aging_irq_in;   // ★ 来自 aging_ctrl (有队列被老化即置)
        end
    end

    //========================================================================
    // Init FSM: IDLE → BUILD(命 LLE 建空闲链, 清指针/计数) → DONE
    //   init_start 触发 → 拉 init_build_req(脉冲) + clr_ptr_cnt → 等 LLE
    //   init_build_done → 置 init_done(并保持)。
    //   两段式: state_curr (时序) + state_next (组合); 输出 (init_build_req / clr_ptr_cnt
    //   / init_done) 由第三段时序块生成。
    //========================================================================
    typedef enum logic [1:0] {
        IS_IDLE  = 2'b00,
        IS_BUILD = 2'b01,
        IS_DONE  = 2'b10
    } init_st_e;

    init_st_e state_curr, state_next;

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) state_curr <= #1 IS_IDLE;
        else             state_curr <= #1 state_next;
    end

    always_comb begin
        case (state_curr)
            IS_IDLE : state_next = init_start_edge ? IS_BUILD : IS_IDLE;
            IS_BUILD: state_next = init_build_done ? IS_DONE  : IS_BUILD;
            IS_DONE : state_next = init_start_edge ? IS_BUILD : IS_DONE;
            default : state_next = IS_IDLE;
        endcase
    end

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            init_build_req <= #1 1'b0;
            clr_ptr_cnt    <= #1 1'b0;
            init_done      <= #1 1'b0;
        end
        else begin
            init_build_req <= #1 1'b0;   // 默认拉低脉冲
            case (state_curr)
                IS_IDLE: begin
                    init_done   <= #1 1'b0;
                    clr_ptr_cnt <= #1 1'b0;
                    if (init_start_edge) begin
                        init_build_req <= #1 1'b1;   // 命 LLE 建空闲链 (脉冲 1 拍)
                        clr_ptr_cnt    <= #1 1'b1;   // 初始化期清指针/计数
                    end
                end
                IS_BUILD: begin
                    if (init_build_done) begin
                        clr_ptr_cnt <= #1 1'b0;
                        init_done   <= #1 1'b1;      // 初始化完成 (保持)
                    end
                end
                IS_DONE: begin
                    init_done <= #1 1'b1;            // 保持完成态
                    if (init_start_edge) begin            // 允许再次 init_start 重新初始化
                        init_done      <= #1 1'b0;
                        init_build_req <= #1 1'b1;
                        clr_ptr_cnt    <= #1 1'b1;
                    end
                end
                default: ;
            endcase
        end
    end

endmodule