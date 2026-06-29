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
    //   ★ lle_alloc_ready: deq 抢占 / build 中 / free 池空时 = 0,
    //     enqueue_ctrl 看到 ready=0 当拍不发 fire, 自动等下拍。
    //========================================================================
    output logic [ADDR_W-1:0]     lle_free_head,
    output logic                  lle_free_empty,
    output logic                  lle_alloc_ready,        // lle 可受理 alloc
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
    output logic                  lle_free_grant,         // = !fifo_full
    output logic                  lle_free_done,          // SRAM 写真正完成那拍

    //========================================================================
    // 与 Multicast Ref-Count Mgr 的接口 —— 组播 ref_count 初值转发
    //========================================================================
    output logic                  mc_set_req,
    output logic [ADDR_W-1:0]     mc_set_addr,
    output logic [REF_W-1:0]      mc_set_init,
    input  logic                  mc_set_ack,

    //========================================================================
    // 与 Occupancy & Pool Mgr 的接口 —— 分配/回收事件上报
    //   新版 occ 用 occ_query_vld&occ_accept 主计数源, 此 evt 保留供调试。
    //========================================================================
    output logic                  lle_alloc_evt,          // enq 落地那拍
    output logic                  lle_free_evt,           // recycle 入 FIFO 那拍
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
    logic                q_head_ph_q    [QUEUE_NUM];     // 当前队头的 pkt_head
    logic                q_head_pt_q    [QUEUE_NUM];     // 当前队头的 pkt_tail

    // Level 1: 下一个 (地址 + ph/pt 完整)
    logic [ADDR_W-1:0]   q_head_next_q    [QUEUE_NUM];
    logic                q_head_next_ph_q [QUEUE_NUM];   // next cell 的 pkt_head
    logic                q_head_next_pt_q [QUEUE_NUM];   // next cell 的 pkt_tail

    // Level 2: 下下个 (仅地址, ph/pt 在 promote 时由 SRAM 取回)
    logic [ADDR_W-1:0]   q_head_next2_q   [QUEUE_NUM];

    //========================================================================
    // free 链寄存器 (两级预取)
    //========================================================================
    logic [ADDR_W-1:0]   free_head_q;                    // 当前 free head
    logic [ADDR_W-1:0]   free_tail_q;
    logic [CNT_W-1:0]    free_cnt_q;
    logic [ADDR_W-1:0]   free_head_next_q;               // 一级预取 (下一个 free cell)
    logic [ADDR_W-1:0]   free_head_next2_q;              // 二级预取 (下下个 free cell)

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

    // do_push/do_pop 声明 (赋值在仲裁信号声明之后, 避免前向引用)
    logic do_push, do_pop;

    //========================================================================
    // Next-Ptr SRAM (1R1W) 互连
    //========================================================================
    logic                npr_r_en;
    logic [ADDR_W-1:0]   npr_r_addr;
    logic [ENTRY_W-1:0]  npr_r_data;       // T+1 拍有效

    logic                npr_w_en;
    logic [ADDR_W-1:0]   npr_w_addr;
    logic [ENTRY_W-1:0]  npr_w_data;

    //========================================================================
    // 建链 FSM (独占 SRAM 期间 enq/deq/rcy 全等)
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
    logic enq_req_int;      // 内部 enq 请求 (fire + free 非空)
    logic deq_req_int;      // 内部 deq 请求 (fire + 队列非空)
    logic deq_need_sram;    // deq 需要读 SRAM 回填 next 预取 (cnt >= 3)
    logic rcy_req_int;      // 内部 rcy 请求 (FIFO 非空)

    assign enq_req_int   = lle_alloc_fire & ~build_active & ~lle_free_empty;
    assign deq_req_int   = lle_deq_fire   & ~build_active &
                           (q_cell_cnt_q[lle_deq_queue_id] != '0);
    // 两级预取: cnt >= 3 时需要 SRAM 读取回填 (cnt==2 deq 后仅剩 1 cell, 不需预取)
    assign deq_need_sram = deq_req_int & (q_cell_cnt_q[lle_deq_queue_id] >= 3);
    assign rcy_req_int   = ~rcy_fifo_empty & ~build_active;

    //========================================================================
    // ★ 三选一仲裁 (整拍 SRAM 独占): P0 deq > P1 enq > P2 rcy
    //   - deq 需 SRAM (cnt>=3) 时占读口 → enq 让步
    //   - 单/双 cell deq (cnt<=2) 不读 SRAM → 不阻塞 enq
    //========================================================================
    logic deq_grant, enq_grant, rcy_grant;

    // deq 永远可处理状态 (q_head/cnt 更新, 与 SRAM 占用无关)
    assign deq_grant = deq_req_int;

    // SRAM 仲裁: deq 占 SRAM (deq_need_sram) 时, enq 让步
    assign enq_grant = enq_req_int & ~build_active & ~deq_need_sram;

    // rcy 让步条件: deq 占 SRAM 或 enq 占 SRAM 或 build 期
    assign rcy_grant = rcy_req_int & ~build_active & ~deq_need_sram & ~enq_grant;

    // 对外: enq ready (deq 占 SRAM / build / free空 → 0)
    assign lle_alloc_ready = ~build_active & ~lle_free_empty & ~deq_need_sram;

    // recycle FIFO push/pop 使能
    assign do_push = lle_free_req & ~rcy_fifo_full & ~build_active;
    assign do_pop  = rcy_grant;

    //========================================================================
    // SRAM 读写口驱动 (两级预取版本)
    //
    //   - deq 赢 (cnt>=3): 读 SRAM[q_head_next2] → 取回 next 的 ph/pt + 新 next2
    //   - enq 赢: 读 SRAM[free_head_next2] → 回填 next2 预取
    //             + 写 SRAM[free_head] = {free_head_next, sof, eof} (挂链)
    //   - rcy 赢: 写 SRAM[free_tail].next = X (还链)
    //   - build : 写 SRAM[idx] = {idx+1, 0, 0} (建链)
    //
    //   bypass 情况: 当 pend 和 grant 同拍时, SRAM 取回值 (npr_r_data) 可直接
    //   用作本拍 SRAM 读地址 (链式预取), 因为 npr_r_data 是寄存器输出, 拍头可用。
    //========================================================================
    logic [ADDR_W-1:0]  build_addr;
    logic [ENTRY_W-1:0] build_wdata;
    assign build_addr  = build_idx_q;
    assign build_wdata = {(build_idx_q == CELL_NUM-1) ? build_idx_q : (build_idx_q + 1'b1),
                          1'b0, 1'b0};

    logic [ADDR_W-1:0] enq_cell;
    assign enq_cell = free_head_q;

    // pend 信号 (声明, 赋值在后面时序块)
    logic               deq_pend_q;
    logic [QID_W-1:0]   deq_pend_qid_q;
    logic               enq_pend_q;

    // bypass 条件
    logic deq_pend_same_q;   // deq_pend 和 本拍 deq 是同一队列
    logic enq_bypass;        // enq_pend 和 本拍 enq_grant 同时有效

    assign deq_pend_same_q = deq_pend_q & deq_grant &
                             (deq_pend_qid_q == lle_deq_queue_id);
    assign enq_bypass      = enq_pend_q & enq_grant;

    // enq SRAM 读地址: 正常=next2, bypass=npr_r_data(刚取回的新 next2 值)
    logic [ADDR_W-1:0] enq_sram_rd_addr;
    assign enq_sram_rd_addr = enq_bypass ? npr_r_data[2 +: ADDR_W] : free_head_next2_q;

    // deq SRAM 读地址: 正常=next2[qid], bypass=npr_r_data.next(刚取回的新 next2)
    logic [ADDR_W-1:0] deq_sram_rd_addr;
    assign deq_sram_rd_addr = deq_pend_same_q ? npr_r_data[2 +: ADDR_W]
                                              : q_head_next2_q[lle_deq_queue_id];

    always_comb begin
        // 读口默认: 关
        npr_r_en   = 1'b0;
        npr_r_addr = '0;
        // 写口默认: 关
        npr_w_en   = 1'b0;
        npr_w_addr = '0;
        npr_w_data = '0;

        if (build_active) begin
            // build: 独占写口
            npr_w_en   = 1'b1;
            npr_w_addr = build_addr;
            npr_w_data = build_wdata;
        end
        else if (deq_grant && deq_need_sram) begin
            // P0 deq (cnt>=3): 读 SRAM[next2] 取回 {next3, next2_ph, next2_pt}
            npr_r_en   = 1'b1;
            npr_r_addr = deq_sram_rd_addr;
        end
        else if (enq_grant) begin
            // P1 enq: 读 SRAM[next2](回填二级预取) + 写 SRAM[head](挂链)
            // 读口: 读 next2 或 bypass 地址
            npr_r_en   = 1'b1;
            npr_r_addr = enq_sram_rd_addr;
            // 写口: 写当前分配的 cell 的 queue entry
            //   next 字段 = free_head_next_q (两级预取保证始终有效)
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
        // 读口
        .r_en       (npr_r_en),
        .r_addr     (npr_r_addr),
        .r_data     (npr_r_data),                                       // T+1 拍有效
        // 写口
        .w_en       (npr_w_en),
        .w_addr     (npr_w_addr),
        .w_data     (npr_w_data)
    );

    //========================================================================
    // SRAM 取回 → 预取寄存器更新 pipeline (T+1 拍)
    //   - deq_pend: 上拍 deq 读了 SRAM[next2], 本拍取回 {next3, next2_ph, next2_pt}
    //              → next_ph/pt 更新为取回的 next2 自身属性 (因为 next2 promote 成了 next)
    //              → next2 更新为取回的 .next 字段 (新 next2 地址)
    //   - enq_pend: 上拍 enq 读了 SRAM[next2], 本拍取回 {next3, -, -}
    //              → free_head_next2 更新为取回的 .next 字段
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
    // 主状态更新 (T0 末沿同拍完成)
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
            free_head_q       <= '0;                                    // cell 0
            free_head_next_q  <= {{(ADDR_W-1){1'b0}}, 1'b1};            // cell 1
            free_head_next2_q <= {{(ADDR_W-2){1'b0}}, 2'b10};           // cell 2
            free_tail_q       <= CELL_NUM[ADDR_W-1:0] - 1'b1;
            free_cnt_q        <= CELL_NUM[CNT_W-1:0];
            rcy_fifo_cnt_q    <= '0;
            rcy_fifo_wptr_q   <= '0;
            rcy_fifo_rptr_q   <= '0;
        end
        else begin
            //================================================================
            // ────── ENQ 落地 (enq_grant = 1) ──────
            //
            //   两级预取推进:
            //     head ← next (始终有效)
            //     next ← next2 (正常) 或 bypass(npr_r_data) (enq_pend 同拍)
            //     SRAM 读口已发出对 next2/bypass_addr 的读取, T+1 回填 next2
            //
            //   挂链:
            //     SRAM[head] = {next, sof, eof} (写口已在 comb 驱动)
            //     q_tail 推进, q_cell_cnt++
            //     空队 bypass: 新 cell 兼任队头
            //================================================================
            if (enq_grant) begin
                // ---- free 链两级预取推进 ----
                free_head_q <= free_head_next_q;          // head 推进到 next
                if (enq_bypass) begin
                    // bypass: 上拍读的 SRAM 刚取回 → 取回值即为新 next2
                    //   本拍 next ← 取回值 (因为 old next2 被 head←next 消耗后已过时)
                    free_head_next_q <= npr_r_data[2 +: ADDR_W];
                end
                else begin
                    free_head_next_q <= free_head_next2_q; // 正常: next ← next2
                end
                // next2 将由下拍 enq_pend 取回 SRAM 数据回填

                // ---- 挂尾 ----
                q_tail_q[lle_alloc_queue_id] <= enq_cell;

                // ---- 队列预取寄存器更新 (入队侧) ----
                if (q_cell_cnt_q[lle_alloc_queue_id] == '0) begin
                    // 空队: 新 cell 兼任队头, 设置 head 及 ph/pt
                    q_head_q[lle_alloc_queue_id]         <= enq_cell;
                    q_head_ph_q[lle_alloc_queue_id]      <= lle_set_pkt_head;
                    q_head_pt_q[lle_alloc_queue_id]      <= lle_set_pkt_tail;
                    // next 指向下一个将分配的 cell (=free_head_next)
                    q_head_next_q[lle_alloc_queue_id]    <= free_head_next_q;
                    q_head_next_ph_q[lle_alloc_queue_id] <= 1'b0;
                    q_head_next_pt_q[lle_alloc_queue_id] <= 1'b0;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 1) begin
                    // 单 cell → 双 cell: 设置 next 地址及其 ph/pt
                    q_head_next_q[lle_alloc_queue_id]    <= enq_cell;
                    q_head_next_ph_q[lle_alloc_queue_id] <= lle_set_pkt_head;
                    q_head_next_pt_q[lle_alloc_queue_id] <= lle_set_pkt_tail;
                    // next2 先指向下一个 free cell (若帧继续则会用到)
                    q_head_next2_q[lle_alloc_queue_id]   <= free_head_next_q;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 2) begin
                    // 双 cell → 三 cell: 设置 next2 地址
                    q_head_next2_q[lle_alloc_queue_id]   <= enq_cell;
                end
                // cnt >= 3: 仅 tail 推进, 预取不变 (后续由 deq SRAM 走链填充)
            end

            // ---- enq_pend T+1: SRAM 取回 → 回填 free_head_next2 ----
            if (enq_pend_q) begin
                free_head_next2_q <= npr_r_data[2 +: ADDR_W];
            end

            //================================================================
            // ────── DEQ 落地 (deq_grant = 1) ──────
            //
            //   两级预取推进:
            //     head ← next, head_ph/pt ← next_ph/pt
            //     next ← next2, next_ph/pt ← bypass(SRAM 取回) 或保持待 pend 填充
            //     next2 ← 由 deq_pend T+1 SRAM 取回回填
            //
            //   bypass: deq_pend 与本拍 deq 同队列同拍
            //     → next_ph/pt 直接从 npr_r_data 取
            //     → next2 从 npr_r_data.next 取
            //================================================================
            if (deq_grant) begin
                // head 推进
                q_head_q[lle_deq_queue_id] <= q_head_next_q[lle_deq_queue_id];

                // head_ph/pt ← next_ph/pt (两级预取: next 层始终有正确 ph/pt)
                if (deq_pend_same_q) begin
                    // bypass: SRAM 刚取回的是 old_next2 的 ph/pt
                    //   old_next2 在上拍 deq 时被 promote 成了 next
                    //   所以取回的 ph/pt 正是当前 next 的属性 → 赋给新 head
                    q_head_ph_q[lle_deq_queue_id] <= npr_r_data[PH_BIT];
                    q_head_pt_q[lle_deq_queue_id] <= npr_r_data[PT_BIT];
                end
                else begin
                    q_head_ph_q[lle_deq_queue_id] <= q_head_next_ph_q[lle_deq_queue_id];
                    q_head_pt_q[lle_deq_queue_id] <= q_head_next_pt_q[lle_deq_queue_id];
                end

                // next 推进 (level 1 ← level 2)
                if (deq_pend_same_q) begin
                    // bypass: next addr ← SRAM 取回的 .next 字段 (新 next2)
                    q_head_next_q[lle_deq_queue_id] <= npr_r_data[2 +: ADDR_W];
                    // next_ph/pt: 本拍无法得知 (要等下一拍 SRAM 取回), 先保持
                    // 但不影响功能: 下拍 deq_pend 会填充
                end
                else begin
                    q_head_next_q[lle_deq_queue_id]    <= q_head_next2_q[lle_deq_queue_id];
                    // next_ph/pt 暂保持 (由 deq_pend 下一拍回填, 或 bypass 填充)
                end
                // next2 将由下拍 deq_pend SRAM 取回回填
            end

            // ---- deq_pend T+1: SRAM 取回 → 回填 next_ph/pt 和 next2 ----
            if (deq_pend_q) begin
                // SRAM[old_next2] 返回 {next3, old_next2_ph, old_next2_pt}
                // old_next2 在上拍已 promote 为 next → 其 ph/pt 即为新 next 的属性
                q_head_next_ph_q[deq_pend_qid_q] <= npr_r_data[PH_BIT];
                q_head_next_pt_q[deq_pend_qid_q] <= npr_r_data[PT_BIT];
                // .next 字段 = next3 → 成为新 next2
                q_head_next2_q[deq_pend_qid_q]   <= npr_r_data[2 +: ADDR_W];
            end

            //================================================================
            // 计数 q_cell_cnt 合并 (同 queue enq+deq 净不变, 不同 queue 各动)
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
            // recycle FIFO push + pop
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
                2'b10: rcy_fifo_cnt_q <= rcy_fifo_cnt_q + 1'b1;
                2'b01: rcy_fifo_cnt_q <= rcy_fifo_cnt_q - 1'b1;
                2'b11: rcy_fifo_cnt_q <= rcy
```
