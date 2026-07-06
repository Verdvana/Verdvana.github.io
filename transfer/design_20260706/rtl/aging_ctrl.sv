//============================================================================
// Module      : aging_ctrl  (Queue/Port Aging Controller)  —— 候选一: MMU 自主老化
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   MMU 自主老化控制器。为每条队列维护一个老化计时器:
//     - 队列有占用 (q_occupied[q]=1) 但长时间未被出队服务 → 判定为"僵尸队列",
//       计时到 cfg_aging_timeout 后触发老化 (age_trig[q])。
//     - 喂狗: 该队列发生出队 fire (deq_fire_vec[q]) 或队列已空 (q_occupied=0) → 计时清零。
//     - 软件强制: cfg_age_force[q] 可无视计时直接触发某队列老化 (调试/软件兜底)。
//   触发后经 RR 仲裁, 一次只对一条队列发起 flush 请求 (age_flush_req + age_flush_qid),
//   等 LLE 回 age_flush_done 再服务下一条。老化完成后经 aging_notify 通知 QM 同步清账。
//
//   端口级老化: 由该端口下 TC_NUM 条队列的 age_trig 做 OR 聚合上报 (port_age_trig),
//   仅用于中断/状态可见性; 实际冲刷仍按队列粒度执行。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module aging_ctrl #(
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,
    parameter int AGE_TMR_W = 24,     // 老化计时器位宽 (覆盖 ms 级 @300MHz)
    // 派生
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,   // 32 单播 + 1 多播
    localparam int QID_W     = $clog2(QUEUE_NUM-1)+1,
    localparam int Q_PER_PORT_LOG = $clog2(TC_NUM)
)(
    input  logic                              clk_core,
    input  logic                              rst_core_n,
    input  logic                              clr_ptr_cnt,      // ★ 初始化期同步清 (来自 csr Init FSM)
    input  logic                              init_done,        // =0 时不老化

    //------------------------------------------------------------------------
    // 配置 (← csr_stats_init)
    //------------------------------------------------------------------------
    input  logic                              cfg_aging_en,       // 老化总使能
    input  logic [AGE_TMR_W-1:0]              cfg_aging_timeout,  // 超时阈值 (cycle 数)
    input  logic [QUEUE_NUM-1:0]              cfg_age_force,      // 软件强制某队列老化

    //------------------------------------------------------------------------
    // 队列状态 (← LLE)
    //------------------------------------------------------------------------
    input  logic [QUEUE_NUM-1:0]              q_occupied,         // 队列非空位图 (cnt!=0)
    input  logic                              deq_fire,           // 出队 fire (喂狗)
    input  logic [QID_W-1:0]                  deq_fire_qid,       // 出队 fire 的队列号

    //------------------------------------------------------------------------
    // 冲刷请求 / 应答 (↔ LLE)
    //------------------------------------------------------------------------
    output logic                              age_flush_req,      // 请求冲刷某队列
    output logic [QID_W-1:0]                  age_flush_qid,      // 待冲刷队列号
    input  logic                              age_flush_busy,     // LLE 正在冲刷
    input  logic                              age_flush_done,     // LLE 冲刷完成

    //------------------------------------------------------------------------
    // 老化通知 / 告警 (→ csr / QM)
    //------------------------------------------------------------------------
    output logic                              aging_notify,       // 一条队列老化完成脉冲 (→ QM 清账)
    output logic [QID_W-1:0]                  aging_notify_qid,   // 老化完成的队列号
    output logic [QUEUE_NUM-1:0]              age_trig,           // 各队列老化触发 (状态可见)
    output logic [PORT_NUM-1:0]               port_age_trig,      // 端口级老化聚合 (中断可见)
    output logic                              irq_aging           // 老化中断 (有队列老化即置)
);

    //========================================================================
    // 1) 每队列老化计时器
    //========================================================================
    logic [AGE_TMR_W-1:0] age_timer_q [QUEUE_NUM];
    logic [QUEUE_NUM-1:0] age_trig_q;

    // 喂狗: 本拍该队列发生出队 fire
    logic [QUEUE_NUM-1:0] feed_dog;
    always_comb begin
        feed_dog = '0;
        if (deq_fire) feed_dog[deq_fire_qid] = 1'b1;
    end

    integer qi;
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (qi = 0; qi < QUEUE_NUM; qi++) begin
                age_timer_q[qi] <= #1 '0;
                age_trig_q[qi]  <= #1 1'b0;
            end
        end
        else if (clr_ptr_cnt) begin              // ★ 初始化期同步清
            for (qi = 0; qi < QUEUE_NUM; qi++) begin
                age_timer_q[qi] <= #1 '0;
                age_trig_q[qi]  <= #1 1'b0;
            end
        end
        else begin
            for (qi = 0; qi < QUEUE_NUM; qi++) begin
                // 老化未使能 / 初始化未完成 / 队列空 / 喂狗 / 正在冲刷该队列 → 计时清零
                if (!cfg_aging_en || !init_done ||
                    !q_occupied[qi] || feed_dog[qi] ||
                    (age_flush_busy && (age_flush_qid == QID_W'(qi)))) begin
                    age_timer_q[qi] <= #1 '0;
                    age_trig_q[qi]  <= #1 1'b0;
                end
                // 已超时 → 保持触发 (直到被冲刷清零, 上面分支覆盖)
                else if (age_timer_q[qi] >= cfg_aging_timeout) begin
                    age_trig_q[qi] <= #1 1'b1;
                end
                // 计时递增
                else begin
                    age_timer_q[qi] <= #1 age_timer_q[qi] + 1'b1;
                end
            end
        end
    end

    // 触发 = 计时超时 或 软件强制 (使能且已初始化)
    always_comb begin
        for (int i = 0; i < QUEUE_NUM; i++)
            age_trig[i] = (cfg_aging_en && init_done) &
                          (age_trig_q[i] | cfg_age_force[i]);
    end

    //========================================================================
    // 2) RR 仲裁: 一次只冲刷一条 trig 队列
    //========================================================================
    typedef enum logic [1:0] {AG_IDLE, AG_FLUSH, AG_WAIT} age_st_e;
    age_st_e            age_st_q;
    logic [QID_W-1:0]   sel_qid_q;
    logic [QID_W-1:0]   rr_ptr_q;      // RR 起点

    // 从 rr_ptr_q 起找第一个 trig 的队列
    logic               found;
    logic [QID_W-1:0]   found_qid;
    always_comb begin
        found     = 1'b0;
        found_qid = '0;
        for (int k = 0; k < QUEUE_NUM; k++) begin
            automatic int idx = (rr_ptr_q + k) % QUEUE_NUM;
            if (!found && age_trig[idx]) begin
                found     = 1'b1;
                found_qid = QID_W'(idx);
            end
        end
    end

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            age_st_q         <= #1 AG_IDLE;
            sel_qid_q        <= #1 '0;
            rr_ptr_q         <= #1 '0;
            age_flush_req    <= #1 1'b0;
            aging_notify     <= #1 1'b0;
            aging_notify_qid <= #1 '0;
        end
        else if (clr_ptr_cnt) begin              // ★ 初始化期同步清
            age_st_q         <= #1 AG_IDLE;
            sel_qid_q        <= #1 '0;
            rr_ptr_q         <= #1 '0;
            age_flush_req    <= #1 1'b0;
            aging_notify     <= #1 1'b0;
            aging_notify_qid <= #1 '0;
        end
        else begin
            aging_notify <= #1 1'b0;   // 默认脉冲拉低
            case (age_st_q)
                AG_IDLE: begin
                    age_flush_req <= #1 1'b0;
                    if (found) begin
                        sel_qid_q     <= #1 found_qid;
                        age_flush_req <= #1 1'b1;
                        age_st_q      <= #1 AG_FLUSH;
                    end
                end
                AG_FLUSH: begin
                    // 保持 req 直到 LLE 接手 (busy) 或直接完成
                    age_flush_req <= #1 1'b1;
                    if (age_flush_busy) begin
                        age_flush_req <= #1 1'b0;
                        age_st_q      <= #1 AG_WAIT;
                    end
                    else if (age_flush_done) begin
                        age_flush_req    <= #1 1'b0;
                        aging_notify     <= #1 1'b1;
                        aging_notify_qid <= #1 sel_qid_q;
                        rr_ptr_q         <= #1 (sel_qid_q + 1'b1) % QUEUE_NUM;
                        age_st_q         <= #1 AG_IDLE;
                    end
                end
                AG_WAIT: begin
                    if (age_flush_done) begin
                        aging_notify     <= #1 1'b1;
                        aging_notify_qid <= #1 sel_qid_q;
                        rr_ptr_q         <= #1 (sel_qid_q + 1'b1) % QUEUE_NUM;
                        age_st_q         <= #1 AG_IDLE;
                    end
                end
                default: age_st_q <= #1 AG_IDLE;
            endcase
        end
    end

    assign age_flush_qid = sel_qid_q;

    //========================================================================
    // 3) 端口级聚合 + 中断
    //========================================================================
    always_comb begin
        for (int p = 0; p < PORT_NUM; p++) begin
            automatic logic acc = 1'b0;
            for (int t = 0; t < TC_NUM; t++)
                acc = acc | age_trig[p*TC_NUM + t];
            port_age_trig[p] = acc;
        end
    end

    assign irq_aging = |age_trig;

endmodule