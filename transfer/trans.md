```
//============================================================================
// Module      : lle  (Link-List Engine)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   LLE 是 MMU 的存储访问平面核心: 唯一访问 Next-Ptr SRAM (1R1W, 一拍可同时
//   1 读 + 1 写并行), 对 Enqueue / Dequeue / Recycle 三个控制模块提供分配 /
//   出队 / 还链服务。
//
//   ── 链表组织 (34 chain, 全部 head/tail/cnt 寄存器化) ──
//     [0..31]  : per-(port,TC) 单播队列链 (4 ports × 8 TC, spec 要求)
//     [32]     : 保留 (按 queue_id 索引)
//     [33]     : 多播专用数据链 (B1 模型: 多播数据 cell 一份)
//     free 链  : 独立维护 (free_head/free_tail/free_cnt 寄存器), 共享给所有 cell
//
//   ── 两级预取模型 (Two-Level Prefetch) ──
//
//     ★ free 链 (enq 路径): free_head / free_head_next / free_head_next2
//        - enq 当拍: head ← next, next ← next2(或 bypass), 读 SRAM 回填 next2
//        - 消除 enq_pend RAW hazard, 实现真正无气泡背靠背 alloc
//
//     ★ 队列链 (deq 路径): q_head(+ph/pt) / q_head_next(+ph/pt) / q_head_next2(addr)
//        - deq 当拍: head ← next, ph/pt ← next_ph/pt, next ← next2
//                    next_ph/pt 由 deq_pend SRAM 取回填充(或 bypass)
//        - 消除 deq back-to-back 同队列 ph/pt 失效, 实现无气泡走链
//
//   ── 仲裁模型: 三事务每拍三选一 (按优先级)  ──
//
//     ★ 每拍 lle 整体只服务一个事务 (赢家独占 SRAM 读+写口)。
//
//     单独事务时各自背靠背 (无并发请求每拍可处理):
//        - enq 独占: 每拍 SRAM 写 new_cell.entry + 读 next2 回填预取
//        - deq 独占: 每拍 SRAM 读 next2 → 回填 next_ph/pt + next2_addr
//        - rcy 独占: 每拍 SRAM 写 free_tail.next = X (还链)
//
//     同拍多请求时按优先级二/三选一, 让步者等下拍:
//        - P0 deq  最高: 走链, 出端口在线发包关键路径, 不能 underrun
//        - P1 enq  中  : 挂链, 上游 IPS 有 DATA BUFFER 缓冲 20G burst
//        - P2 rcy  最低: 还链, 不在数据路径, recycle 让 1 拍后进 FIFO 等
//
//     反压机制:
//        - lle_alloc_ready: enq 让 deq 时 =0, enqueue_ctrl 自动等下拍
//        - rcy 走 lle 内部 FIFO 缓冲, 对 recycle_ctrl 透明 (FIFO 不满恒 grant)
//
//   ── 关键写策略 (每事务 1 次 SRAM 写) ──
//
//     【挂链】(enq): SRAM[free_head] = { free_head_next, sof, eof }
//        - free_head_next 两级预取始终有效 (不依赖 SRAM 刚取回)
//        - 同拍读 SRAM[next2] 回填 next2 预取 (准备下下次 alloc)
//
//     【还链】(rcy): SRAM[free_tail].next = released_cell
//        - free_tail 寄存器判尾, 不依赖 SRAM 里 NULL
//
//     【走链】(deq): 读 SRAM[next2] → 取回 {next3, next2_ph, next2_pt}
//        - next2_ph/pt 回填 next_ph/pt (promote), next3 回填 next2
//
//   ── 协议假设 ──
//     1) **QM 帧级原子入队**: 同一帧 (sof~eof) 的连续 cell 入队请求不被打断;
//        保证挂链时 free_head_next 预测准确 (下次 alloc 拿的也是同 queue 下一项)。
//     2) **回收平均速率 ≤ 入队速率** (cell 守恒): FIFO 不溢。
//     3) **多播数据 cell 出队不摘链**: B1 模型, 回收由 mcast_refcount_mgr ref 归零驱动。
//
//   ── 对外延迟 (spec L327/L443: ≤ 5 cycle) ──
//     - enq: T0 fire → T0 alloc 落地 (两级预取无气泡, 每拍 1 cell)
//     - deq: T0 fire → T0 deq 落地 (两级预取无气泡, 每拍 1 cell)
//     - rcy: T0 入 FIFO 即受理, SRAM 落地由仲裁决定 (透明, 平均 1~几拍)
//     - 三者都远在 5 cycle 预算内。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module lle #(
    parameter  int CELL_NUM        = 8192,
    parameter  int QUEUE_NUM       = 34,
    parameter  int PORT_NUM        = 4,
    parameter  int REF_W           = 3,
    parameter  int RCY_FIFO_DEPTH  = 8,
    // 派生位宽:
    localparam int ADDR_W          = $clog2(CELL_NUM),
    localparam int QID_W           = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W          = $clog2(PORT_NUM-1)+1,
    localparam int CNT_W           = ADDR_W + 1,
    localparam int ENTRY_W         = ADDR_W + 2,         // entry = {next, ph, pt}
    localparam int PH_BIT          = 1,
    localparam int PT_BIT          = 0
)(
    //========================================================================
    // 时钟与复位 (公共)
    //========================================================================
    input  logic                  clk_core,
    input  logic                  rst_core_n,

    //========================================================================
    // 与 Init FSM (csr_stats_init) 的接口 —— 上电建链
    //========================================================================
    input  logic                  init_build_req,
    output logic                  init_build_done,

    //========================================================================
    // 与 Enqueue Ctrl 的接口 —— 入队 / 分配
    //========================================================================
    output logic [ADDR_W-1:0]     lle_free_head,
    output logic                  lle_free_empty,
    output logic                  lle_alloc_ready,
    input  logic                  lle_alloc_fire,
    input  logic [QID_W-1:0]      lle_alloc_queue_id,
    input  logic [ADDR_W-1:0]     lle_alloc_addr,
    input  logic                  lle_set_pkt_head,
    input  logic                  lle_set_pkt_tail,
    input  logic                  lle_alloc_is_mcast,
    input  logic [REF_W-1:0]      lle_alloc_ref_init,

    //========================================================================
    // 与 Dequeue Ctrl 的接口 —— 出队 (最高优先级, 永不被阻塞)
    //========================================================================
    input  logic [QID_W-1:0]      lle_deq_queue_id,
    output logic [ADDR_W-1:0]     lle_qhead,
    output logic                  lle_qhead_pkt_head,
    output logic                  lle_qhead_pkt_tail,
    output logic                  lle_q_empty,
    input  logic                  lle_deq_fire,

    //========================================================================
    // 与 Recycle Ctrl 的接口 —— 还链 (入 FIFO, 异步写 SRAM)
    //========================================================================
    input  logic                  lle_free_req,
    input  logic [ADDR_W-1:0]     lle_free_addr,
    output logic                  lle_free_grant,
    output logic                  lle_free_done,

    //========================================================================
    // 与 Multicast Ref-Count Mgr 的接口
    //========================================================================
    output logic                  mc_set_req,
    output logic [ADDR_W-1:0]     mc_set_addr,
    output logic [REF_W-1:0]      mc_set_init,
    input  logic                  mc_set_ack,

    //========================================================================
    // 与 Occupancy & Pool Mgr 的接口 —— 分配/回收事件上报
    //========================================================================
    output logic                  lle_alloc_evt,
    output logic                  lle_free_evt,
    output logic [QID_W-1:0]      evt_queue_id,
    output logic [PORT_W-1:0]     evt_egress_port
);

    //========================================================================
    // 链表寄存器: 34 chain (两级预取)
    //========================================================================
    // Level 0: 当前队头
    logic [ADDR_W-1:0]   q_head_q       [QUEUE_NUM];
    logic [ADDR_W-1:0]   q_tail_q       [QUEUE_NUM];
    logic [CNT_W-1:0]    q_cell_cnt_q   [QUEUE_NUM];
    logic                q_head_ph_q    [QUEUE_NUM];
    logic                q_head_pt_q    [QUEUE_NUM];

    // Level 1: 下一个 (地址 + ph/pt 完整预取)
    logic [ADDR_W-1:0]   q_head_next_q    [QUEUE_NUM];
    logic                q_head_next_ph_q [QUEUE_NUM];
    logic                q_head_next_pt_q [QUEUE_NUM];

    // Level 2: 下下个 (仅地址, ph/pt 在 promote 时由 SRAM 取回)
    logic [ADDR_W-1:0]   q_head_next2_q   [QUEUE_NUM];

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
    // Recycle FIFO
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
    typedef enum logic [1:0] {
        ST_IDLE  = 2'b00,
        ST_BUILD = 2'b01,
        ST_DONE  = 2'b10
    } build_st_e;

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
                    if (build_idx_q == CELL_NUM-1)
                        build_st_q <= ST_DONE;
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
    // 事务请求信号 (T0 当拍判定)
    //========================================================================
    logic enq_req_int;
    logic deq_req_int;
    logic deq_need_sram;
    logic rcy_req_int;

    assign enq_req_int   = lle_alloc_fire & ~build_active & ~lle_free_empty;
    assign deq_req_int   = lle_deq_fire   & ~build_active &
                           (q_cell_cnt_q[lle_deq_queue_id] != '0);
    // 两级预取: cnt >= 3 时需要 SRAM 读取回填 next_ph/pt + next2
    assign deq_need_sram = deq_req_int & (q_cell_cnt_q[lle_deq_queue_id] >= 3);
    assign rcy_req_int   = ~rcy_fifo_empty & ~build_active;

    //========================================================================
    // ★ 三选一仲裁: P0 deq > P1 enq > P2 rcy
    //========================================================================
    logic deq_grant, enq_grant, rcy_grant;

    assign deq_grant = deq_req_int;
    assign enq_grant = enq_req_int & ~build_active & ~deq_need_sram;
    assign rcy_grant = rcy_req_int & ~build_active & ~deq_need_sram & ~enq_grant;

    assign lle_alloc_ready = ~build_active & ~lle_free_empty & ~deq_need_sram;

    assign do_push = lle_free_req & ~rcy_fifo_full & ~build_active;
    assign do_pop  = rcy_grant;

    //========================================================================
    // SRAM 读写口驱动 (两级预取版本)
    //========================================================================
    logic [ADDR_W-1:0]  build_addr;
    logic [ENTRY_W-1:0] build_wdata;
    assign build_addr  = build_idx_q;
    assign build_wdata = {(build_idx_q == CELL_NUM-1) ? build_idx_q : (build_idx_q + 1'b1),
                          1'b0, 1'b0};

    logic [ADDR_W-1:0] enq_cell;
    assign enq_cell = free_head_q;

    // ---- pend 流水寄存器 ----
    logic               deq_pend_q;
    logic [QID_W-1:0]   deq_pend_qid_q;
    logic               enq_pend_q;

    // ---- bypass 条件 ----
    logic deq_pend_same_q;
    logic enq_bypass;

    assign deq_pend_same_q = deq_pend_q & deq_grant &
                             (deq_pend_qid_q == lle_deq_queue_id);
    assign enq_bypass      = enq_pend_q & enq_grant;

    // enq SRAM 读地址: 正常=next2, bypass=npr_r_data.next (刚取回的新 next2)
    logic [ADDR_W-1:0] enq_sram_rd_addr;
    assign enq_sram_rd_addr = enq_bypass ? npr_r_data[2 +: ADDR_W] : free_head_next2_q;

    // deq SRAM 读地址: 正常=next2[qid], bypass=npr_r_data.next (刚取回的新 next2)
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
            // P0 deq: 读 SRAM[next2] → {next3, next2_ph, next2_pt}
            npr_r_en   = 1'b1;
            npr_r_addr = deq_sram_rd_addr;
        end
        else if (enq_grant) begin
            // P1 enq: 读 SRAM[next2](回填) + 写 SRAM[head](挂链)
            npr_r_en   = 1'b1;
            npr_r_addr = enq_sram_rd_addr;
            npr_w_en   = 1'b1;
            npr_w_addr = free_head_q;
            npr_w_data = {free_head_next_q, lle_set_pkt_head, lle_set_pkt_tail};
        end
        else if (rcy_grant) begin
            // P2 rcy: 写 SRAM[free_tail].next = rcy_cell
            npr_w_en   = 1'b1;
            npr_w_addr = free_tail_q;
            npr_w_data = {rcy_cell, 1'b0, 1'b0};
        end
    end

    next_ptr_sram_1r1w #(
        .CELL_NUM(CELL_NUM),
        .DATA_W  (ENTRY_W)
    ) u_npr (
        .clk_core   (clk_core),
        .rst_core_n (rst_core_n),
        .r_en       (npr_r_en),
        .r_addr     (npr_r_addr),
        .r_data     (npr_r_data),
        .w_en       (npr_w_en),
        .w_addr     (npr_w_addr),
        .w_data     (npr_w_data)
    );

    //========================================================================
    // Pend 流水寄存器
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            deq_pend_q     <= 1'b0;
            deq_pend_qid_q <= '0;
            enq_pend_q     <= 1'b0;
        end
        else begin
            deq_pend_q     <= deq_grant & deq_need_sram;
            deq_pend_qid_q <= lle_deq_queue_id;
            enq_pend_q     <= enq_grant;
        end
    end

    //========================================================================
    // 主状态更新
    //========================================================================
    integer q, i;
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (q = 0; q < QUEUE_NUM; q++) begin
                q_head_q[q]         <= '0;
                q_tail_q[q]         <= '0;
                q_cell_cnt_q[q]     <= '0;
                q_head_ph_q[q]      <= 1'b0;
                q_head_pt_q[q]      <= 1'b0;
                q_head_next_q[q]    <= '0;
                q_head_next_ph_q[q] <= 1'b0;
                q_head_next_pt_q[q] <= 1'b0;
                q_head_next2_q[q]   <= '0;
            end
            free_head_q       <= '0;
            free_tail_q       <= '0;
            free_cnt_q        <= '0;
            free_head_next_q  <= '0;
            free_head_next2_q <= '0;
            rcy_fifo_cnt_q    <= '0;
            rcy_fifo_wptr_q   <= '0;
            rcy_fifo_rptr_q   <= '0;
            for (i = 0; i < RCY_FIFO_DEPTH; i++) rcy_fifo_mem[i] <= '0;
        end
        else if (build_st_q == ST_DONE) begin
            //----------------------------------------------------------------
            // 建链完成: free 链 0→1→2→...→(N-1), 全队列清空
            //----------------------------------------------------------------
            for (q = 0; q < QUEUE_NUM; q++) begin
                q_head_q[q]         <= '0;
                q_tail_q[q]         <= '0;
                q_cell_cnt_q[q]     <= '0;
                q_head_ph_q[q]      <= 1'b0;
                q_head_pt_q[q]      <= 1'b0;
                q_head_next_q[q]    <= '0;
                q_head_next_ph_q[q] <= 1'b0;
                q_head_next_pt_q[q] <= 1'b0;
                q_head_next2_q[q]   <= '0;
            end
            free_head_q       <= '0;                                     // cell 0
            free_head_next_q  <= {{(ADDR_W-1){1'b0}}, 1'b1};             // cell 1
            free_head_next2_q <= {{(ADDR_W-2){1'b0}}, 2'b10};            // cell 2
            free_tail_q       <= CELL_NUM[ADDR_W-1:0] - 1'b1;
            free_cnt_q        <= CELL_NUM[CNT_W-1:0];
            rcy_fifo_cnt_q    <= '0;
            rcy_fifo_wptr_q   <= '0;
            rcy_fifo_rptr_q   <= '0;
        end
        else begin

            //================================================================
            // ────── ENQ 落地 (enq_grant = 1) ──────
            //================================================================
            if (enq_grant) begin
                // ---- free 链两级预取推进 ----
                free_head_q <= free_head_next_q;
                if (enq_bypass)
                    free_head_next_q <= npr_r_data[2 +: ADDR_W]; // bypass
                else
                    free_head_next_q <= free_head_next2_q;        // 正常 promote

                // ---- 挂尾 ----
                q_tail_q[lle_alloc_queue_id] <= enq_cell;

                // ---- 队列预取寄存器更新 (入队侧) ----
                if (q_cell_cnt_q[lle_alloc_queue_id] == '0) begin
                    // 空队: 新 cell 兼任队头
                    q_head_q[lle_alloc_queue_id]         <= enq_cell;
                    q_head_ph_q[lle_alloc_queue_id]      <= lle_set_pkt_head;
                    q_head_pt_q[lle_alloc_queue_id]      <= lle_set_pkt_tail;
                    q_head_next_q[lle_alloc_queue_id]    <= free_head_next_q;
                    q_head_next_ph_q[lle_alloc_queue_id] <= 1'b0;
                    q_head_next_pt_q[lle_alloc_queue_id] <= 1'b0;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 1) begin
                    // 单→双: 设置 next 及其 ph/pt
                    q_head_next_q[lle_alloc_queue_id]    <= enq_cell;
                    q_head_next_ph_q[lle_alloc_queue_id] <= lle_set_pkt_head;
                    q_head_next_pt_q[lle_alloc_queue_id] <= lle_set_pkt_tail;
                    q_head_next2_q[lle_alloc_queue_id]   <= free_head_next_q;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 2) begin
                    // 双→三: 设置 next2 地址
                    q_head_next2_q[lle_alloc_queue_id]   <= enq_cell;
                end
                // cnt >= 3: 仅 tail 推进, 预取不变
            end

            // ---- enq_pend T+1: SRAM 取回 → 回填 free_head_next2 ----
            if (enq_pend_q) begin
                free_head_next2_q <= npr_r_data[2 +: ADDR_W];
            end

            //================================================================
            // ────── DEQ 落地 (deq_grant = 1) ──────
            //================================================================
            if (deq_grant) begin
                // head 推进到 next
                q_head_q[lle_deq_queue_id] <= q_head_next_q[lle_deq_queue_id];

                // head_ph/pt ← next_ph/pt (或 bypass)
                if (deq_pend_same_q) begin
                    // bypass: SRAM 取回的 ph/pt = old_next2(现为 next) 的属性
                    q_head_ph_q[lle_deq_queue_id] <= npr_r_data[PH_BIT];
                    q_head_pt_q[lle_deq_queue_id] <= npr_r_data[PT_BIT];
                end
                else begin
                    q_head_ph_q[lle_deq_queue_id] <= q_head_next_ph_q[lle_deq_queue_id];
                    q_head_pt_q[lle_deq_queue_id] <= q_head_next_pt_q[lle_deq_queue_id];
                end

                // next 推进 (level 1 ← level 2)
                if (deq_pend_same_q) begin
                    // bypass: next ← SRAM 取回的 .next 字段
                    q_head_next_q[lle_deq_queue_id] <= npr_r_data[2 +: ADDR_W];
                end
                else begin
                    q_head_next_q[lle_deq_queue_id] <= q_head_next2_q[lle_deq_queue_id];
                end
            end

            // ---- deq_pend T+1: SRAM 取回 → 回填 next_ph/pt 和 next2 ----
            if (deq_pend_q) begin
                q_head_next_ph_q[deq_pend_qid_q] <= npr_r_data[PH_BIT];
                q_head_next_pt_q[deq_pend_qid_q] <= npr_r_data[PT_BIT];
                q_head_next2_q[deq_pend_qid_q]   <= npr_r_data[2 +: ADDR_W];
            end

            //================================================================
            // 计数 q_cell_cnt
            //================================================================
            if (enq_grant && deq_grant && (lle_alloc_queue_id == lle_deq_queue_id)) begin
                // 同 queue 同拍: 净不变
            end
            else begin
                if (enq_grant)
                    q_cell_cnt_q[lle_alloc_queue_id] <= q_cell_cnt_q[lle_alloc_queue_id] + 1'b1;
                if (deq_grant)
                    q_cell_cnt_q[lle_deq_queue_id]   <= q_cell_cnt_q[lle_deq_queue_id]   - 1'b1;
            end

            //================================================================
            // Recycle FIFO push + pop
            //================================================================
            if (do_push) begin
                rcy_fifo_mem[rcy_fifo_wptr_q] <= lle_free_addr;
                rcy_fifo_wptr_q <= rcy_fifo_wptr_q + 1'b1;
            end
            if (do_pop) begin
                rcy_fifo_rptr_q <= rcy_fifo_rptr_q + 1'b1;
                free_tail_q     <= rcy_cell;
            end

            // FIFO cnt 净变化
            unique case ({do_push, do_pop})
                2'b10:   rcy_fifo_cnt_q <= rcy_fifo_cnt_q + 1'b1;
                2'b01:   rcy_fifo_cnt_q <= rcy_fifo_cnt_q - 1'b1;
                2'b11:   rcy_fifo_cnt_q <= rcy_fifo_cnt_q;
                default: ;
            endcase

            // free_cnt 净变化 (enq -1, recycle push +1)
            unique case ({enq_grant, do_push})
                2'b10:   free_cnt_q <= free_cnt_q - 1'b1;
                2'b01:   free_cnt_q <= free_cnt_q + 1'b1;
                2'b11:   free_cnt_q <= free_cnt_q;
                default: ;
            endcase
        end
    end

    //========================================================================
    // 对外组合输出
    //========================================================================
    assign lle_qhead          = q_head_q[lle_deq_queue_id];
    assign lle_qhead_pkt_head = q_head_ph_q[lle_deq_queue_id];
    assign lle_qhead_pkt_tail = q_head_pt_q[lle_deq_queue_id];
    assign lle_q_empty        = (q_cell_cnt_q[lle_deq_queue_id] == '0);

    assign lle_free_grant = lle_free_req & ~build_active & ~rcy_fifo_full;
    assign lle_free_done  = rcy_grant;

    assign mc_set_req  = enq_grant & lle_alloc_is_mcast;
    assign mc_set_addr = enq_cell;
    assign mc_set_init = lle_alloc_ref_init;

    assign lle_alloc_evt = enq_grant;
    assign lle_free_evt  = lle_free_grant;
    assign evt_queue_id  = enq_grant ? lle_alloc_queue_id : lle_deq_queue_id;

    localparam int Q_PER_PORT_LOG = $clog2(QUEUE_NUM / PORT_NUM);
    assign evt_egress_port = evt_queue_id >> Q_PER_PORT_LOG;

`ifdef SIM_BEHAVIOR_SRAM
    //========================================================================
    // 仿真断言
    //========================================================================
    always_ff @(posedge clk_core) begin
        if (rst_core_n && lle_free_req && rcy_fifo_full && !build_active)
            $warning("[lle] recycle FIFO full: free request ignored");
    end
    always_ff @(posedge clk_core) begin
        if (rst_core_n && enq_grant && (free_cnt_q == '0))
            $error("[lle] free pool underflow: alloc when free_cnt==0");
    end
    always_ff @(posedge clk_core) begin
        if (rst_core_n && npr_r_en && npr_w_en && (npr_r_addr == npr_w_addr))
            $warning("[lle] SRAM r/w same addr in same cycle (enq read-first OK)");
    end
`endif

endmodule


//============================================================================
// 1R1W Next-Ptr SRAM 行为模型 (综合时换 vendor 1R1W SRAM)
//   - 1 读口 + 1 写口, 同拍可并行
//   - 同拍读写同一地址: read-first (读到旧值)
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

    // read-first: 读到的是写之前的旧值
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) r_data <= '0;
        else if (r_en)   r_data <= mem[r_addr];
    end

    always_ff @(posedge clk_core) begin
        if (w_en) mem[w_addr] <= w_data;
    end
endmodule
```

```
//============================================================================
// Testbench : lle_tb
// Description:
//   针对 lle 模块的功能验证 testbench。
//   参数: 2 port × 2 queue/port = 4 queue + 1 free + 1 multicast = 6 chain
//         CELL_NUM = 64
//
//   测试序列:
//     1. 建链 (init_build)
//     2. q0 入队 1 包 4 cell
//     3. q1 入队 1 包 5 cell
//     4. q1 入队 1 包 6 cell
//     5. q0 入队 1 包 2 cell
//     6. q0 入队 1 包 7 cell
//     7. q2 入队 1 包 10 cell (多播队列)
//     8. q1 走链第一个包 (5 cell)
//     9. 还链 5 cell
//    10. q3 入队 2 cell 同时 q0 走链一包 (4 cell) → 仲裁冲突覆盖
//    11. 附加场景: 背靠背 deq 连续 / enq+deq 同拍冲突 / rcy burst 等
//
//   每次整包操作后打印:
//     - 各队列 head/tail/cnt
//     - free 链 head/tail/cnt
//     - 验证背靠背时序 (每拍消耗/输出)
//============================================================================
`timescale 1ns/1ps

module lle_tb;

    //========================================================================
    // 参数 (缩小规模便于仿真)
    //========================================================================
    localparam int CELL_NUM       = 64;
    localparam int QUEUE_NUM      = 6;    // q0,q1 (port0); q2,q3 (port1); q4=free概念; q5=mcast
    localparam int PORT_NUM       = 2;
    localparam int REF_W          = 3;
    localparam int RCY_FIFO_DEPTH = 8;

    localparam int ADDR_W  = $clog2(CELL_NUM);
    localparam int QID_W   = $clog2(QUEUE_NUM-1)+1;
    localparam int PORT_W  = $clog2(PORT_NUM-1)+1;
    localparam int CNT_W   = ADDR_W + 1;
    localparam int ENTRY_W = ADDR_W + 2;

    //========================================================================
    // 时钟与复位
    //========================================================================
    logic clk, rst_n;
    initial clk = 0;
    always #1.667 clk = ~clk;   // ~300MHz

    //========================================================================
    // DUT 信号
    //========================================================================
    logic                  init_build_req, init_build_done;
    logic [ADDR_W-1:0]    lle_free_head;
    logic                  lle_free_empty;
    logic                  lle_alloc_ready;
    logic                  lle_alloc_fire;
    logic [QID_W-1:0]     lle_alloc_queue_id;
    logic [ADDR_W-1:0]    lle_alloc_addr;
    logic                  lle_set_pkt_head, lle_set_pkt_tail;
    logic                  lle_alloc_is_mcast;
    logic [REF_W-1:0]     lle_alloc_ref_init;

    logic [QID_W-1:0]     lle_deq_queue_id;
    logic [ADDR_W-1:0]    lle_qhead;
    logic                  lle_qhead_pkt_head, lle_qhead_pkt_tail;
    logic                  lle_q_empty;
    logic                  lle_deq_fire;

    logic                  lle_free_req;
    logic [ADDR_W-1:0]    lle_free_addr;
    logic                  lle_free_grant, lle_free_done;

    logic                  mc_set_req;
    logic [ADDR_W-1:0]    mc_set_addr;
    logic [REF_W-1:0]     mc_set_init;
    logic                  mc_set_ack;

    logic                  lle_alloc_evt, lle_free_evt;
    logic [QID_W-1:0]     evt_queue_id;
    logic [PORT_W-1:0]    evt_egress_port;

    assign mc_set_ack = 1'b1;

    //========================================================================
    // DUT 例化
    //========================================================================
    lle #(
        .CELL_NUM       (CELL_NUM),
        .QUEUE_NUM      (QUEUE_NUM),
        .PORT_NUM       (PORT_NUM),
        .REF_W          (REF_W),
        .RCY_FIFO_DEPTH (RCY_FIFO_DEPTH)
    ) u_dut (
        .clk_core           (clk),
        .rst_core_n         (rst_n),
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
        .lle_alloc_ref_init (lle_alloc_ref_init),
        .lle_deq_queue_id   (lle_deq_queue_id),
        .lle_qhead          (lle_qhead),
        .lle_qhead_pkt_head (lle_qhead_pkt_head),
        .lle_qhead_pkt_tail (lle_qhead_pkt_tail),
        .lle_q_empty        (lle_q_empty),
        .lle_deq_fire       (lle_deq_fire),
        .lle_free_req       (lle_free_req),
        .lle_free_addr      (lle_free_addr),
        .lle_free_grant     (lle_free_grant),
        .lle_free_done      (lle_free_done),
        .mc_set_req         (mc_set_req),
        .mc_set_addr        (mc_set_addr),
        .mc_set_init        (mc_set_init),
        .mc_set_ack         (mc_set_ack),
        .lle_alloc_evt      (lle_alloc_evt),
        .lle_free_evt       (lle_free_evt),
        .evt_queue_id       (evt_queue_id),
        .evt_egress_port    (evt_egress_port)
    );

    //========================================================================
    // 辅助 task: 打印状态
    //========================================================================
    task automatic print_status(string tag);
        integer qi;
        $display("──── [%0t] %s ────", $time, tag);
        $display("  free: head=%0d tail=%0d cnt=%0d empty=%0b",
                 u_dut.free_head_q, u_dut.free_tail_q, u_dut.free_cnt_q, lle_free_empty);
        $display("  free_head_next=%0d  free_head_next2=%0d",
                 u_dut.free_head_next_q, u_dut.free_head_next2_q);
        for (qi = 0; qi < QUEUE_NUM; qi++) begin
            if (u_dut.q_cell_cnt_q[qi] != 0)
                $display("  q[%0d]: head=%0d tail=%0d cnt=%0d next=%0d(ph=%0b,pt=%0b) next2=%0d  head_ph=%0b head_pt=%0b",
                         qi, u_dut.q_head_q[qi], u_dut.q_tail_q[qi], u_dut.q_cell_cnt_q[qi],
                         u_dut.q_head_next_q[qi], u_dut.q_head_next_ph_q[qi], u_dut.q_head_next_pt_q[qi],
                         u_dut.q_head_next2_q[qi],
                         u_dut.q_head_ph_q[qi], u_dut.q_head_pt_q[qi]);
        end
        $display("  rcy FIFO: cnt=%0d", u_dut.rcy_fifo_cnt_q);
        $display("");
    endtask

    //========================================================================
    // 辅助 task: 入队一整包 (背靠背, 每拍 1 cell)
    //========================================================================
    task automatic enqueue_pkt(input int qid, input int num_cells, input bit is_mcast, input int ref_init);
        integer i;
        int alloc_cnt;
        alloc_cnt = 0;
        $display("[%0t] >>> ENQ start: q=%0d cells=%0d mcast=%0b", $time, qid, num_cells, is_mcast);
        for (i = 0; i < num_cells; i++) begin
            // 等 lle_alloc_ready
            while (!lle_alloc_ready) @(posedge clk);
            lle_alloc_fire     = 1'b1;
            lle_alloc_queue_id = qid[QID_W-1:0];
            lle_alloc_addr     = lle_free_head;
            lle_set_pkt_head   = (i == 0);
            lle_set_pkt_tail   = (i == num_cells-1);
            lle_alloc_is_mcast = is_mcast;
            lle_alloc_ref_init = ref_init[REF_W-1:0];
            @(posedge clk);
            alloc_cnt++;
        end
        lle_alloc_fire = 1'b0;
        // 等 1 拍让 SRAM 取回完成 (free_head_next 更新)
        @(posedge clk);
        $display("[%0t] <<< ENQ done: q=%0d cells=%0d (took %0d cycles fire)", $time, qid, num_cells, alloc_cnt);
        print_status($sformatf("after enq q%0d %0d-cell pkt", qid, num_cells));
    endtask

    //========================================================================
    // 辅助 task: 出队一整包 (背靠背, 每拍 1 cell, 直到 pkt_tail)
    //========================================================================
    task automatic dequeue_pkt(input int qid);
        integer cnt;
        cnt = 0;
        $display("[%0t] >>> DEQ start: q=%0d", $time, qid);
        lle_deq_queue_id = qid[QID_W-1:0];
        while (1) begin
            if (lle_q_empty) begin
                $display("[%0t]   DEQ: queue %0d empty, abort", $time, qid);
                break;
            end
            lle_deq_fire = 1'b1;
            $display("[%0t]   DEQ cell: addr=%0d ph=%0b pt=%0b", $time,
                     lle_qhead, lle_qhead_pkt_head, lle_qhead_pkt_tail);
            cnt++;
            if (lle_qhead_pkt_tail) begin
                @(posedge clk);
                lle_deq_fire = 1'b0;
                break;
            end
            @(posedge clk);
        end
        lle_deq_fire = 1'b0;
        // 等 1 拍让 SRAM 取回
        @(posedge clk);
        $display("[%0t] <<< DEQ done: q=%0d cells=%0d", $time, qid, cnt);
        print_status($sformatf("after deq q%0d", qid));
    endtask

    //========================================================================
    // 辅助 task: 还链 N 个 cell (背靠背发 req, 每拍 1 个)
    //========================================================================
    task automatic recycle_cells(input int cells[$]);
        integer i;
        $display("[%0t] >>> RCY start: %0d cells", $time, cells.size());
        for (i = 0; i < cells.size(); i++) begin
            lle_free_req  = 1'b1;
            lle_free_addr = cells[i][ADDR_W-1:0];
            @(posedge clk);
            if (!lle_free_grant)
                $display("[%0t]   RCY: grant=0 for cell %0d (FIFO full?)", $time, cells[i]);
        end
        lle_free_req = 1'b0;
        // 等几拍让 rcy_grant 有机会写 SRAM
        repeat (cells.size() + 2) @(posedge clk);
        $display("[%0t] <<< RCY done: %0d cells", $time, cells.size());
        print_status($sformatf("after rcy %0d cells", cells.size()));
    endtask

    //========================================================================
    // 辅助 task: 同时入队 + 走链 (覆盖仲裁冲突)
    //========================================================================
    task automatic enq_and_deq_concurrent(input int enq_qid, input int enq_cells,
                                          input int deq_qid);
        integer ei, di;
        bit deq_done;
        ei = 0;
        di = 0;
        deq_done = 0;
        $display("[%0t] >>> CONCURRENT: enq q%0d %0d cells + deq q%0d", $time, enq_qid, enq_cells, deq_qid);
        lle_deq_queue_id = deq_qid[QID_W-1:0];
        while (ei < enq_cells || !deq_done) begin
            // enq
            if (ei < enq_cells && lle_alloc_ready) begin
                lle_alloc_fire     = 1'b1;
                lle_alloc_queue_id = enq_qid[QID_W-1:0];
                lle_alloc_addr     = lle_free_head;
                lle_set_pkt_head   = (ei == 0);
                lle_set_pkt_tail   = (ei == enq_cells-1);
                lle_alloc_is_mcast = 1'b0;
                lle_alloc_ref_init = '0;
                ei++;
            end
            else begin
                lle_alloc_fire = 1'b0;
            end
            // deq
            if (!deq_done && !lle_q_empty) begin
                lle_deq_fire = 1'b1;
                $display("[%0t]   CONC DEQ: addr=%0d pt=%0b | ENQ fire=%0b ready=%0b",
                         $time, lle_qhead, lle_qhead_pkt_tail, lle_alloc_fire, lle_alloc_ready);
                if (lle_qhead_pkt_tail) deq_done = 1;
            end
            else begin
                lle_deq_fire = 1'b0;
                if (!deq_done && lle_q_empty) deq_done = 1;
            end
            @(posedge clk);
        end
        lle_alloc_fire = 1'b0;
        lle_deq_fire   = 1'b0;
        repeat (3) @(posedge clk);
        $display("[%0t] <<< CONCURRENT done", $time);
        print_status("after concurrent enq+deq");
    endtask

    //========================================================================
    // 主测试序列
    //========================================================================
    initial begin
        // 初始化
        rst_n = 0;
        init_build_req     = 0;
        lle_alloc_fire     = 0;
        lle_alloc_queue_id = 0;
        lle_alloc_addr     = 0;
        lle_set_pkt_head   = 0;
        lle_set_pkt_tail   = 0;
        lle_alloc_is_mcast = 0;
        lle_alloc_ref_init = 0;
        lle_deq_queue_id   = 0;
        lle_deq_fire       = 0;
        lle_free_req       = 0;
        lle_free_addr      = 0;

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        //---- 1. 建链 ----
        $display("\n========== BUILD FREE LIST ==========");
        init_build_req = 1;
        @(posedge clk);
        init_build_req = 0;
        // 轮询等 init_build_done (只拉高 1 拍, 用 posedge 捕获避免 race)
        while (!init_build_done) @(posedge clk);
        @(posedge clk);
        print_status("after build");

        //---- 2. q0 入队 4 cell ----
        enqueue_pkt(0, 4, 0, 0);

        //---- 3. q1 入队 5 cell ----
        enqueue_pkt(1, 5, 0, 0);

        //---- 4. q1 入队 6 cell ----
        enqueue_pkt(1, 6, 0, 0);

        //---- 5. q0 入队 2 cell ----
        enqueue_pkt(0, 2, 0, 0);

        //---- 6. q0 入队 7 cell ----
        enqueue_pkt(0, 7, 0, 0);

        //---- 7. q2 入队 10 cell (多播队列, 假设 qid=4 为多播专用, ref=2) ----
        enqueue_pkt(4, 10, 1, 2);

        //---- 8. q1 走链第一个包 (5 cell) ----
        dequeue_pkt(1);

        //---- 9. 还链 5 cell (cell 4~8, 即 q1 第一包) ----
        begin
            int rcy_cells[$];
            rcy_cells = '{4, 5, 6, 7, 8};
            recycle_cells(rcy_cells);
        end

        //---- 10. q3 入队 2 cell 同时 q0 走链 (4 cell 第一包) ----
        enq_and_deq_concurrent(3, 2, 0);

        //---- 11. 附加: 背靠背 deq q1 第二个包 (6 cell) ----
        dequeue_pkt(1);

        //---- 12. 附加: 背靠背 enq + rcy 同拍冲突 ----
        $display("\n========== ENQ + RCY CONFLICT ==========");
        fork
            enqueue_pkt(2, 3, 0, 0);     // q2 入队 3 cell (非 mcast, 普通 queue)
            begin
                int rcy2[$];
                rcy2 = '{0, 1, 2};        // 还 3 个 cell (q0 第一包前 3 个)
                recycle_cells(rcy2);
            end
        join
        print_status("after enq+rcy conflict test");

        //---- 13. 附加: 连续 deq 背靠背确认 ----
        $display("\n========== BACK-TO-BACK DEQ q0 ==========");
        dequeue_pkt(0);  // q0 还有 2+7=9 cell 分两包, 先出第二包 (2 cell)

        //---- 结束 ----
        repeat (10) @(posedge clk);
        $display("\n========== ALL TESTS DONE ==========");
        print_status("final state");
        $finish;
    end

    //========================================================================
    // 超时保护
    //========================================================================
    initial begin
        #100000;
        $display("TIMEOUT!");
        $finish;
    end

endmodule
```
