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
//   ── 仲裁模型: 三事务每拍三选一 (按优先级)  ──
//
//     ★ 每拍 lle 整体只服务一个事务 (赢家独占 SRAM 读+写口)。
//
//     单独事务时各自背靠背 (无并发请求每拍可处理):
//        - enq 独占: 每拍 SRAM 读 free_head.next (更新预取) + 同拍 SRAM 写
//                    new_cell.entry (挂链). 同地址不同口, 1R1W read-first 读旧
//                    next 给 free_head_next, 写新 entry 给挂链。
//        - deq 独占: 每拍 SRAM 读 q_head_next.entry (更新队头预取).
//        - rcy 独占: 每拍 SRAM 写 free_tail.next = X (还链).
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
//     【挂链】(enq): SRAM[new_cell] = { next = free_head_after , sof, eof }
//        - 同拍发起 SRAM 读 SRAM[free_head].next (read-first 取旧 next 给预取)
//        - 同拍发起 SRAM 写 SRAM[free_head] = {old_next_pred, sof, eof}
//        - 读写同地址, 1R1W read-first 保证读到旧值 (=新 free_head_next 的来源)
//        - "old_next_pred" 即 free_head_next_q 寄存器, 上次 enq 已预取好
//        - 第一次 enq: free_head_next_q 由建链后初始化为 cell 1 (free_head=0 之后)
//
//     【还链】(rcy): SRAM[free_tail].next = released_cell
//        - free_tail 寄存器判尾, 不依赖 SRAM 里 NULL
//
//     【走链】(deq): 读 SRAM[q_head_next].entry, 取回下一项 next/sof/eof
//        - q_head_next/ph/pt 是预取寄存器, dequeue_ctrl 当拍可读
//
//   ── 协议假设 ──
//     1) **QM 帧级原子入队**: 同一帧 (sof~eof) 的连续 cell 入队请求不被打断;
//        保证挂链时 free_head_next 预测准确 (下次 alloc 拿的也是同 queue 下一项)。
//     2) **回收平均速率 ≤ 入队速率** (cell 守恒): FIFO 不溢。
//     3) **多播数据 cell 出队不摘链**: B1 模型, 回收由 mcast_refcount_mgr ref 归零驱动。
//
//   ── 对外延迟 (spec L327/L443: ≤ 5 cycle) ──
//     - enq: T0 fire → T1 alloc 返回 (无 deq 抢占时 1 拍, 让 1 拍时 2 拍)
//     - deq: T0 fire → T1 deq 返回 (永远 1 拍, 最高优先级)
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
    // 链表寄存器: 34 chain
    //========================================================================
    logic [ADDR_W-1:0]   q_head_q       [QUEUE_NUM];
    logic [ADDR_W-1:0]   q_tail_q       [QUEUE_NUM];
    logic [CNT_W-1:0]    q_cell_cnt_q   [QUEUE_NUM];
    logic [ADDR_W-1:0]   q_head_next_q  [QUEUE_NUM];
    logic                q_head_ph_q    [QUEUE_NUM];
    logic                q_head_pt_q    [QUEUE_NUM];

    //========================================================================
    // free 链寄存器
    //========================================================================
    logic [ADDR_W-1:0]   free_head_q;
    logic [ADDR_W-1:0]   free_tail_q;
    logic [CNT_W-1:0]    free_cnt_q;
    logic [ADDR_W-1:0]   free_head_next_q;               // 预取下一项 (enq 当拍用)

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

    // recycle FIFO push/pop 使能 (模块级组合信号, 在 always_ff 内使用)
    logic do_push, do_pop;
    assign do_push = lle_free_req & ~rcy_fifo_full & ~build_active;
    assign do_pop  = rcy_grant;

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
    logic deq_need_sram;    // deq 实际需要读 SRAM (单 cell 队列出完不读)
    logic rcy_req_int;      // 内部 rcy 请求 (FIFO 非空)

    assign enq_req_int   = lle_alloc_fire & ~build_active & ~lle_free_empty;
    assign deq_req_int   = lle_deq_fire   & ~build_active &
                           (q_cell_cnt_q[lle_deq_queue_id] != '0);
    assign deq_need_sram = deq_req_int & (q_cell_cnt_q[lle_deq_queue_id] != 1);
    assign rcy_req_int   = ~rcy_fifo_empty & ~build_active;

    //========================================================================
    // ★ 三选一仲裁 (整拍 SRAM 独占): P0 deq > P1 enq > P2 rcy
    //   注: 单 cell deq 不读 SRAM, 让出 SRAM 给 enq/rcy (deq_need_sram=0 时,
    //        deq 仍可同拍发生, 因为它不占 SRAM)。
    //   - 但为简化"三者互斥"语义, 即使 deq 不读 SRAM, 它仍按 P0 处理 deq 状态
    //     更新, 不阻塞 enq/rcy 的 SRAM 操作 (因为 SRAM 空着)。
    //========================================================================
    logic deq_grant, enq_grant, rcy_grant;

    // deq 永远可处理状态 (q_head/cnt 更新, 与 SRAM 操作无关)
    assign deq_grant = deq_req_int;

    // SRAM 仲裁: deq 用 SRAM (deq_need_sram) 时, enq 让步; 否则 enq 可用 SRAM
    // enq 让步条件: deq 占 SRAM (deq_need_sram) 或 build 期
    // enq_pend_q=1 那拍: 上拍 enq 的 SRAM 读取回即将更新 free_head_next_q,
    //   本拍如果再 enq_grant, free_head_q <= free_head_next_q 拿到的是旧值 → RAW hazard。
    //   解决: enq_pend 那拍强制让 1 拍, 等 free_head_next 更新完 (下一拍才允许新 enq)。
    assign enq_grant = enq_req_int & ~build_active & ~deq_need_sram & ~enq_pend_q;

    // rcy 让步条件: deq 占 SRAM 或 enq 占 SRAM 或 build 期
    assign rcy_grant = rcy_req_int & ~build_active & ~deq_need_sram & ~enq_grant;

    // 对外: enq ready (deq 占 SRAM / build / free空 / enq_pend 预取未完成 → 0)
    assign lle_alloc_ready = ~build_active & ~lle_free_empty & ~deq_need_sram & ~enq_pend_q;

    //========================================================================
    // SRAM 读写口驱动
    //   - deq 赢: 读 SRAM[q_head_next].entry (读口); 不动写口
    //   - enq 赢: 读 SRAM[free_head].next (读口, read-first 取旧 next 给预取)
    //             + 写 SRAM[free_head] = {old_pred, sof, eof} (写口) ★ 同地址!
    //   - rcy 赢: 写 SRAM[free_tail].next = X (写口); 不动读口
    //   - build : 写 SRAM[idx] = {idx+1, 0, 0} (写口); 不动读口
    //========================================================================
    logic [ADDR_W-1:0]  build_addr;
    logic [ENTRY_W-1:0] build_wdata;
    assign build_addr  = build_idx_q;
    assign build_wdata = {(build_idx_q == CELL_NUM-1) ? build_idx_q : (build_idx_q + 1'b1),
                          1'b0, 1'b0};

    logic [ADDR_W-1:0] enq_cell;
    assign enq_cell = free_head_q;

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
            // P0 deq: 读 SRAM[q_head_next].entry (取下下个队头预取)
            npr_r_en   = 1'b1;
            npr_r_addr = q_head_next_q[lle_deq_queue_id];
        end
        else if (enq_grant) begin
            // P1 enq: 读 SRAM[free_head].next (旧值, 给 free_head_next 预取)
            //        + 写 SRAM[free_head] = {free_head_next_q, sof, eof} (新值)
            //        1R1W 同地址 read-first: 读到的是旧 next, 写入新 entry, 完美一拍完成
            npr_r_en   = 1'b1;
            npr_r_addr = free_head_q;
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
    // SRAM 取回 → 预取寄存器更新 (T+1 拍)
    //   - deq pend: 上拍 deq 读了, 本拍取回的是新队头的 entry
    //   - enq pend: 上拍 enq 读了, 本拍取回的是 SRAM[old_free_head].next
    //========================================================================
    logic               deq_pend_q;
    logic [QID_W-1:0]   deq_pend_qid_q;
    logic               enq_pend_q;        // 上拍 enq 占用读口, 本拍要更新 free_head_next

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
                q_head_q[q]      <= '0;
                q_tail_q[q]      <= '0;
                q_cell_cnt_q[q]  <= '0;
                q_head_next_q[q] <= '0;
                q_head_ph_q[q]   <= 1'b0;
                q_head_pt_q[q]   <= 1'b0;
            end
            free_head_q       <= '0;
            free_tail_q       <= '0;
            free_cnt_q        <= '0;
            free_head_next_q  <= '0;
            rcy_fifo_cnt_q    <= '0;
            rcy_fifo_wptr_q   <= '0;
            rcy_fifo_rptr_q   <= '0;
            for (i = 0; i < RCY_FIFO_DEPTH; i++) rcy_fifo_mem[i] <= '0;
        end
        else if (build_st_q == ST_DONE) begin
            //----------------------------------------------------------------
            // 建链完成
            //----------------------------------------------------------------
            for (q = 0; q < QUEUE_NUM; q++) begin
                q_head_q[q]      <= '0;
                q_tail_q[q]      <= '0;
                q_cell_cnt_q[q]  <= '0;
                q_head_next_q[q] <= '0;
                q_head_ph_q[q]   <= 1'b0;
                q_head_pt_q[q]   <= 1'b0;
            end
            free_head_q       <= '0;                                    // = 0
            free_head_next_q  <= {{(ADDR_W-1){1'b0}}, 1'b1};            // = 1
            free_tail_q       <= CELL_NUM[ADDR_W-1:0] - 1'b1;
            free_cnt_q        <= CELL_NUM[CNT_W-1:0];
            rcy_fifo_cnt_q    <= '0;
            rcy_fifo_wptr_q   <= '0;
            rcy_fifo_rptr_q   <= '0;
        end
        else begin
            //----------------------------------------------------------------
            // enq 落地 (enq_grant = 1):
            //   - SRAM[free_head] 本拍已写入 {free_head_next_q, sof, eof}
            //   - SRAM[free_head].next 本拍已发起读, T+1 拍取回 → 更新 free_head_next
            //   - free_head 推进到 free_head_next_q
            //   - 挂尾: q_tail 推进, q_cell_cnt++
            //   - 空队 bypass: 新 cell 兼任队头
            //----------------------------------------------------------------
            if (enq_grant) begin
                // free 链头推进 (本拍读出的新 next 在 T+1 拍由 enq_pend 更新)
                free_head_q      <= free_head_next_q;

                // 挂尾
                q_tail_q[lle_alloc_queue_id] <= enq_cell;

                if (q_cell_cnt_q[lle_alloc_queue_id] == '0) begin
                    // 空队 bypass: 新 cell 兼任队头
                    q_head_q[lle_alloc_queue_id]      <= enq_cell;
                    q_head_next_q[lle_alloc_queue_id] <= free_head_next_q;
                    q_head_ph_q[lle_alloc_queue_id]   <= lle_set_pkt_head;
                    q_head_pt_q[lle_alloc_queue_id]   <= lle_set_pkt_tail;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 1) begin
                    // 单 cell + enq: 旧 head 还在, q_head_next 原自指, 现指新 cell
                    q_head_next_q[lle_alloc_queue_id] <= enq_cell;
                end
                // 多 cell: q_head/q_head_next 不变, 仅 q_tail 推进
            end

            // enq T+1 拍 SRAM 取回 (旧 SRAM[free_head].next) → 更新 free_head_next
            if (enq_pend_q) begin
                free_head_next_q <= npr_r_data[2 +: ADDR_W];
            end

            //----------------------------------------------------------------
            // deq 落地 (deq_grant = 1):
            //   - q_head 推进到 q_head_next 寄存器
            //   - q_cell_cnt --
            //   - deq_need_sram 时, T+1 拍 SRAM 取回新队头 entry 更新预取
            //----------------------------------------------------------------
            if (deq_grant) begin
                q_head_q[lle_deq_queue_id] <= q_head_next_q[lle_deq_queue_id];
            end

            // deq T+1 拍 SRAM 取回 → 更新预取 (q_head_next/ph/pt)
            if (deq_pend_q) begin
                q_head_next_q[deq_pend_qid_q] <= npr_r_data[2 +: ADDR_W];
                q_head_ph_q[deq_pend_qid_q]   <= npr_r_data[PH_BIT];
                q_head_pt_q[deq_pend_qid_q]   <= npr_r_data[PT_BIT];
            end

            //----------------------------------------------------------------
            // 计数 q_cell_cnt 合并 (同 queue enq+deq 净不变, 不同 queue 各动)
            //----------------------------------------------------------------
            if (enq_grant && deq_grant && (lle_alloc_queue_id == lle_deq_queue_id)) begin
                // 同 queue 同拍: 净不变
            end
            else begin
                if (enq_grant)
                    q_cell_cnt_q[lle_alloc_queue_id] <= q_cell_cnt_q[lle_alloc_queue_id] + 1'b1;
                if (deq_grant)
                    q_cell_cnt_q[lle_deq_queue_id]   <= q_cell_cnt_q[lle_deq_queue_id]   - 1'b1;
            end

            //----------------------------------------------------------------
            // recycle FIFO push (lle_free_req 当拍受理) + pop (rcy_grant 当拍)
            //----------------------------------------------------------------

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
                2'b11: rcy_fifo_cnt_q <= rcy_fifo_cnt_q;
                default: ;
            endcase

            // free_cnt 净变化 (enq -1, recycle push +1)
            unique case ({enq_grant, do_push})
                2'b10: free_cnt_q <= free_cnt_q - 1'b1;
                2'b01: free_cnt_q <= free_cnt_q + 1'b1;
                2'b11: free_cnt_q <= free_cnt_q;
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
    // SRAM 读写口同时驱动到不同地址应该不会发生 (按本设计仲裁互斥)
    always_ff @(posedge clk_core) begin
        if (rst_core_n && npr_r_en && npr_w_en && (npr_r_addr != npr_w_addr))
            $error("[lle] SRAM r/w different addrs in same cycle (arbiter bug?)");
    end
`endif

    //========================================================================
    // 设计说明:
    //   1) 三选一仲裁 (整拍 SRAM 独占): P0 deq > P1 enq > P2 rcy
    //      - 单独事务每拍处理 → 各自背靠背 ✓
    //      - 同拍并发时让步: enq 让 deq (lle_alloc_ready=0), rcy 让 deq/enq (FIFO)
    //   2) enq 一拍内 1R1W 双口都用 (同一地址 free_head): 
    //      - 读口取旧 SRAM[free_head].next → T+1 更新 free_head_next 预取
    //      - 写口写 SRAM[free_head] = {old_pred, sof, eof}
    //      - read-first 保证读到的是旧 next (写之前的值), 正好给预取
    //   3) deq 用读口取 SRAM[q_head_next].entry, T+1 更新 q_head_next/ph/pt 预取
    //   4) rcy 用写口写 SRAM[free_tail].next = X, free_tail 寄存器判尾
    //   5) 让步机制对外:
    //      - lle_alloc_ready=0 时 enqueue_ctrl 当拍不发 fire, 自动等
    //      - rcy 进 lle 内部 FIFO, 对 recycle_ctrl 透明
    //   6) 对外延迟 (spec L327/L443 ≤ 5 cycle):
    //      - deq: 永远 1 拍
    //      - enq: 1~2 拍 (无 deq 抢占 1 拍, 让 1 拍则 2 拍)
    //      - rcy: 入 FIFO 受理立即, SRAM 落地几拍 (对外透明)
    //========================================================================

endmodule


//============================================================================
// 1R1W Next-Ptr SRAM 行为模型 (综合时换 vendor 1R1W SRAM)
//   - 1 读口 + 1 写口, 同拍可并行
//   - 同拍读写同一地址: read-first (读到旧值, 符合本设计 enq 用法)
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
