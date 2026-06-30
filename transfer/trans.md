```
//============================================================================
// Module      : recycle_ctrl  (Recycle Control)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   回收路径控制 (控制平面)。按 B1 多播模型 (见《MMU_多播处理分析.md》方案 B1):
//     - 单播 (recycle_req): 报文发送完成, 该 cell 立即还链 → 直接向 LLE 发
//                           lle_free_req(接空闲链尾), 并通知 Occupancy 计数--。
//     - 组播 (mcast_recycle_req): 每收到一个出端口"发完一份"的通知, 向
//                           Multicast Ref-Count Mgr 发 mc_dec_req 递减 ref_count;
//                           **只有递减后 ref 归零 (mc_ref_zero=1) 才向 LLE 发还链** ——
//                           即"多播 data cell 出队不摘链、回收完全由 ref_count 归零驱动"。
//                           ref 未归零时只递减、不还链、不通知 Occupancy 计数-- (该 cell
//                           仍被其它端口共享, 占用不变)。
//
//   仲裁: 单播与组播还链都走同一条 LLE 还链口 (lle_free_req)。本实现用一个轻量 FSM
//         串行化, 保证同一拍至多发一个 lle_free_req; 单播优先 (低延迟), 组播次之。
//
//   时序: Mcast Ref-Count Mgr 的 mc_dec_ack / mc_ref_zero 为同拍组合返回 (见
//         mcast_refcount_mgr.sv), 故组播递减判零可在收到 mcast_recycle_req 的当拍完成;
//         若归零, 下一拍发 lle_free_req 还链。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module recycle_ctrl #(
    parameter int CELL_NUM  = 8192,
    parameter int QUEUE_NUM = 34,
    parameter int PORT_NUM  = 4,
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
    localparam int ADDR_W   = $clog2(CELL_NUM),
    localparam int QID_W    = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W   = $clog2(PORT_NUM-1)+1
)(
    //------------------------------------------------------------------------
    // 时钟复位 (公共)
    //------------------------------------------------------------------------
    input  logic                  clk_core,
    input  logic                  rst_core_n,

    //------------------------------------------------------------------------
    // 与 QM 的接口 (外部, 经 MMU 顶层)
    //   ★ recycle_queue_id / mcast_recycle_queue_id: QM 提供被回收 cell 所属队列号
    //     (QM 有 descriptor, 知道 cell→queue 映射)。recycle_ctrl 将其透传给 LLE,
    //     由 LLE 随 free 事件 (lle_free_evt) 同拍转发给 occupancy 做 per-queue/port --。
    //------------------------------------------------------------------------
    input  logic                  recycle_req,         // 单播 cell 回收请求
    input  logic [ADDR_W-1:0]     recycle_cell_addr,   // 待回收 cell 地址
    input  logic [QID_W-1:0]      recycle_queue_id,    // 单播回收 cell 所属队列号
    input  logic                  mcast_recycle_req,   // 组播回收通知(某端口发完一份)
    input  logic [ADDR_W-1:0]     mcast_recycle_addr,  // 组播待回收 cell 地址
    input  logic [QID_W-1:0]      mcast_recycle_queue_id, // 组播回收 cell 所属队列号
    output logic                  recycle_ack,         // 回收完成应答

    //------------------------------------------------------------------------
    // 与 Multicast Ref-Count Mgr 的接口 (内部)
    //------------------------------------------------------------------------
    output logic                  mc_dec_req,          // 组播 ref_count-- 请求
    output logic [ADDR_W-1:0]     mc_dec_addr,         // 目标组播 cell
    input  logic                  mc_dec_ack,          // 递减完成 (同拍组合)
    input  logic                  mc_ref_zero,         // 递减后归零(允许真正还链)

    //------------------------------------------------------------------------
    // 与 Link-List Engine (LLE) 的接口 (内部, 还链)
    //   ★ lle_free_queue_id: 透传被回收 cell 所属队列号给 LLE, LLE 随 free 事件
    //     转发给 occupancy (occupancy 的回收计数由 LLE 的 lle_free_evt 驱动, 时序
    //     与 LLE free_cnt 一致, 不再由 recycle_ctrl 直接驱动 occ)。
    //------------------------------------------------------------------------
    output logic                  lle_free_req,        // 还链(接空闲链尾)请求
    output logic [ADDR_W-1:0]     lle_free_addr,       // 待还 cell
    output logic [QID_W-1:0]      lle_free_queue_id,   // 待还 cell 所属队列号
    input  logic                  lle_free_grant,      // 仲裁通过
    input  logic                  lle_free_done        // 还链完成
);

    //========================================================================
    // 组播递减: 收到 mcast_recycle_req 当拍向 Ref-Count Mgr 发递减。
    //   mc_dec_ack/mc_ref_zero 同拍返回。
    //   - 未归零: 只递减, 不还链 (该 cell 仍被其它端口共享)。
    //   - 归零  : 把该 cell 锁存, 下一拍发起还链 (mc_free_pending)。
    //========================================================================
    assign mc_dec_req  = mcast_recycle_req;
    assign mc_dec_addr = mcast_recycle_addr;

    // 归零待还链锁存 (组播 ref 归零, 等下一拍发 lle_free_req)
    logic              mc_free_pending_q;
    logic [ADDR_W-1:0] mc_free_addr_q;
    logic [QID_W-1:0]  mc_free_qid_q;       // 锁存组播待还 cell 的队列号

    //========================================================================
    // 还链口仲裁 (单拍至多一个 lle_free_req):
    //   优先级: 单播 recycle_req  >  组播归零待还链(mc_free_pending_q)
    //   - 单播: 直接用 recycle_cell_addr 还链, 当拍即可。
    //   - 组播: 用上一拍归零锁存的 mc_free_addr_q 还链。
    //========================================================================
    logic do_uni_free;     // 本拍发起单播还链
    logic do_mc_free;      // 本拍发起组播还链

    assign do_uni_free = recycle_req;
    assign do_mc_free  = mc_free_pending_q & ~recycle_req;   // 单播优先, 组播让一拍

    assign lle_free_req  = do_uni_free | do_mc_free;
    assign lle_free_addr = do_uni_free ? recycle_cell_addr : mc_free_addr_q;

    //========================================================================
    // 透传被回收 cell 所属队列号给 LLE:
    //   - 单播: 用 recycle_queue_id (QM 当拍提供)
    //   - 组播: 用上一拍归零锁存的 mc_free_qid_q
    //   LLE 会随 free 事件 (lle_free_evt) 把该 queue_id (及派生 port) 转发给
    //   occupancy 做 per-queue/port 占用 --, 时序与 LLE free_cnt 一致。
    //   (occupancy 回收计数不再由 recycle_ctrl 直接驱动, 改由 LLE free 事件驱动)
    //========================================================================
    assign lle_free_queue_id = do_uni_free ? recycle_queue_id : mc_free_qid_q;

    //========================================================================
    // 回收应答 recycle_ack:
    //   - 单播: 还链发起当拍应答 (recycle_req)。
    //   - 组播: 收到通知当拍即应答 (mcast_recycle_req, 无论是否归零, 通知已被接收)。
    //========================================================================
    assign recycle_ack = recycle_req | mcast_recycle_req;

    //========================================================================
    // 时序: 锁存组播归零待还链
    //   - 本拍组播递减且归零 → 置 mc_free_pending_q, 锁存 cell 地址。
    //   - 组播还链发起 (do_mc_free) → 清 pending。
    //   - 极端情形: 同拍既有新的组播归零、又在发上一笔组播还链 → 用单拍寄存器队列
    //     深度 1 简化; 若 QM 回收速率 > 1 归零/拍, 详细设计可加小 FIFO。本设计假设
    //     回收速率 ≤ 1 cell/拍 (与入队/出队 1 cell/拍对称)。
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            mc_free_pending_q <= 1'b0;
            mc_free_addr_q    <= '0;
            mc_free_qid_q     <= '0;
        end
        else begin
            // 先处理"本拍发起组播还链"→清 pending
            if (do_mc_free)
                mc_free_pending_q <= 1'b0;
            // 本拍组播递减归零 → 置 pending (锁存待还 cell + queue_id)
            if (mcast_recycle_req && mc_ref_zero) begin
                mc_free_pending_q <= 1'b1;
                mc_free_addr_q    <= mcast_recycle_addr;
                mc_free_qid_q     <= mcast_recycle_queue_id;
            end
        end
    end

`ifdef SIM_BEHAVIOR_SRAM
    //========================================================================
    // 仿真断言: pending 未及时清空又来新的归零 → 还链速率不足 (需加 FIFO)
    //========================================================================
    always_ff @(posedge clk_core) begin
        if (rst_core_n && mcast_recycle_req && mc_ref_zero &&
            mc_free_pending_q && ~do_mc_free) begin
            $error("[recycle_ctrl] mcast free backlog: new ref-zero while pending not drained " ,
                   "(consider a small free FIFO)");
        end
    end
`endif

endmodule
```

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
    //   ★ lle_free_queue_id: recycle_ctrl/QM 提供被回收 cell 所属队列号,
    //     LLE 透传给 occupancy (free 事件携带 queue_id, 供 per-queue 计数 --)。
    //========================================================================
    input  logic                  lle_free_req,
    input  logic [ADDR_W-1:0]     lle_free_addr,
    input  logic [QID_W-1:0]      lle_free_queue_id,
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
    //   alloc 事件: lle_alloc_evt + evt_queue_id/evt_egress_port (per-queue ++)
    //   free  事件: lle_free_evt  + evt_free_queue_id/evt_free_egress_port (--)
    //========================================================================
    output logic                  lle_alloc_evt,
    output logic [QID_W-1:0]      evt_queue_id,
    output logic [PORT_W-1:0]     evt_egress_port,
    output logic                  lle_free_evt,
    output logic [QID_W-1:0]      evt_free_queue_id,
    output logic [PORT_W-1:0]     evt_free_egress_port
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

    // 队尾的 ph/pt (标准链表 relink 用: 写 old_tail.entry 时保留其 flags)
    //   ★ tail cell 的 SRAM entry 尚未写 (无后继), 其 flags 只在此寄存器
    logic                q_tail_ph_q      [QUEUE_NUM];
    logic                q_tail_pt_q      [QUEUE_NUM];

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
    // deq 读的 cell 是否为 tail (其 SRAM entry 尚未 relink, 数据 stale)
    //   → 用捕获的 q_tail flags 覆盖 SRAM 取回值
    logic               deq_pend_tail_q;
    logic               deq_pend_tail_ph_q;
    logic               deq_pend_tail_pt_q;

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
            // P1 enq: 读 SRAM[free next2](回填 free 预取)
            npr_r_en   = 1'b1;
            npr_r_addr = enq_sram_rd_addr;
            // ★ 标准链表 relink: 写 OLD tail 的 entry, 使其 .next 指向新 cell,
            //   保留 old tail 自身的 ph/pt (来自 q_tail_ph/pt 寄存器)。
            //   这样每个 cell 的 SRAM .next 指向其在该队列中的真实后继,
            //   即使跨帧 (q0→q1→q0) 交织也正确。
            //   空队 (cnt==0): 新 cell 即队头=队尾, 无 old tail, 不写 (其 entry
            //   待后继入队时再写)。
            if (q_cell_cnt_q[lle_alloc_queue_id] != '0) begin
                npr_w_en   = 1'b1;
                npr_w_addr = q_tail_q[lle_alloc_queue_id];
                npr_w_data = {enq_cell,
                              q_tail_ph_q[lle_alloc_queue_id],
                              q_tail_pt_q[lle_alloc_queue_id]};
            end
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
            // 捕获: 本拍 deq 读的 cell (deq_sram_rd_addr) 是否为该队列 tail。
            //   若是, tail 的 SRAM entry 尚未 relink (stale), 下拍用 q_tail flags 覆盖。
            deq_pend_tail_q    <= (deq_grant & deq_need_sram) &
                                  (deq_sram_rd_addr == q_tail_q[lle_deq_queue_id]);
            deq_pend_tail_ph_q <= q_tail_ph_q[lle_deq_queue_id];
            deq_pend_tail_pt_q <= q_tail_pt_q[lle_deq_queue_id];
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
                q_tail_ph_q[q]      <= 1'b0;
                q_tail_pt_q[q]      <= 1'b0;
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
                q_tail_ph_q[q]      <= 1'b0;
                q_tail_pt_q[q]      <= 1'b0;
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

                // ---- 更新队尾 flags (新 cell 成为新 tail) ----
                //   注: 上面 comb relink 写 old tail 用的是更新前的 q_tail_ph/pt
                q_tail_ph_q[lle_alloc_queue_id] <= lle_set_pkt_head;
                q_tail_pt_q[lle_alloc_queue_id] <= lle_set_pkt_tail;
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
                    //   若上拍读的是 tail (SRAM stale), 用捕获的 q_tail flags 覆盖
                    if (deq_pend_tail_q) begin
                        q_head_ph_q[lle_deq_queue_id] <= deq_pend_tail_ph_q;
                        q_head_pt_q[lle_deq_queue_id] <= deq_pend_tail_pt_q;
                    end
                    else begin
                        q_head_ph_q[lle_deq_queue_id] <= npr_r_data[PH_BIT];
                        q_head_pt_q[lle_deq_queue_id] <= npr_r_data[PT_BIT];
                    end
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
            //   若上拍读的是 tail (SRAM stale), 用捕获的 q_tail flags 覆盖 next_ph/pt;
            //   tail 无后继, next2 不更新 (此时队列已近空, next2 不会被使用)。
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

    localparam int Q_PER_PORT_LOG = $clog2(QUEUE_NUM / PORT_NUM);

    // alloc 事件: enq 落地那拍, 携带 alloc 队列号/端口 (供 occ per-queue/port ++)
    assign lle_alloc_evt   = enq_grant;
    assign evt_queue_id    = lle_alloc_queue_id;
    assign evt_egress_port = lle_alloc_queue_id >> Q_PER_PORT_LOG;

    // free 事件: recycle 入 FIFO 那拍, 透传被回收 cell 所属队列号/端口
    //   (供 occ per-queue/port --, 与 free_cnt 入 FIFO 时序一致)
    assign lle_free_evt          = lle_free_grant;
    assign evt_free_queue_id     = lle_free_queue_id;
    assign evt_free_egress_port  = lle_free_queue_id >> Q_PER_PORT_LOG;

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
`timescale 1ns/1ps

module occupancy_pool_mgr #(
    parameter int CELL_NUM  = 8192,
    parameter int QUEUE_NUM = 34,
    parameter int PORT_NUM  = 4,
    parameter int STAT_W    = 32,    // 统计计数器位宽
    // near_full 端口/全局余量 (距高水位多少 cell 即视为快满); 队列用 cfg 滞回
    parameter int QUEUE_NF_MARGIN   = 2,
    parameter int PORT_NF_MARGIN    = 4,
    parameter int GLOBAL_NF_MARGIN = 8,
    localparam int ADDR_W    = $clog2(CELL_NUM),
    localparam int QID_W     = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W    = $clog2(PORT_NUM-1)+1,
    localparam int CNT_W     = ADDR_W+1,    // 占用计数位宽 (0~8192)
    localparam int TC_NUM   = QUEUE_NUM/PORT_NUM
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
    output logic                       occ_accept,           // 判决=接收
    output logic                       occ_drop,             // 判决=丢弃(高水位兜底)
    output logic                       occ_use_static,       // 记静态(=1)/动态(=0)
    output logic                       occ_no_free,          // 空闲池空(强制丢弃)

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
            port_inc[i] = alloc_allowed && (alloc_port == i) &&
                          !(same_port_evt && free_allowed);
            port_dec[i] = free_allowed && (free_port == i) &&
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
    parameter int QUEUE_NUM  = 34,    // 队列(chain)数 = 4*8 + 2 专用
    parameter int PORT_NUM   = 4,     // 物理出端口数
    parameter int REF_W      = 3,     // 组播 ref_count 位宽 (0~4)
    parameter int STAT_W     = 32,    // 统计计数器位宽
    // 派生位宽 / 数量 (与各子模块同源)
    localparam int ADDR_W    = $clog2(CELL_NUM),
    localparam int QID_W     = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W    = $clog2(PORT_NUM-1)+1,
    localparam int CNT_W     = ADDR_W + 1,
    localparam int TC_NUM    = QUEUE_NUM / PORT_NUM
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
    input  logic                  enq_is_mcast,        // 组播标志
    input  logic [PORT_NUM-1:0]   enq_mcast_bitmap,    // 组播出端口位图
    input  logic                  enq_sof,             // 报文首段
    input  logic                  enq_eof,             // 报文尾段
    output logic                  enq_ready,           // MMU 可接收入队请求
    output logic                  alloc_valid,         // 分配结果有效
    output logic [ADDR_W-1:0]     alloc_cell_addr,     // 分配的 cell 地址
    output logic                  alloc_drop_ind,      // 丢包指示(高水位/空闲池空兜底)
    output logic                  alloc_sram_flag,     // 内部 SRAM 存储标志
    output logic                  alloc_pkt_head,      // 报文头 (= enq_sof)
    output logic                  alloc_pkt_tail,      // 报文尾 (= enq_eof)
    output logic                  alloc_full_frame_drop, // 整帧丢弃指示

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
    logic                  occ_accept, occ_drop, occ_use_static, occ_no_free;

    // Enqueue Ctrl ↔ LLE
    logic [ADDR_W-1:0]     lle_free_head;
    logic                  lle_free_empty;
    logic                  lle_alloc_ready;
    logic                  lle_alloc_fire;
    logic [QID_W-1:0]      lle_alloc_queue_id;
    logic [ADDR_W-1:0]     lle_alloc_addr;
    logic                  lle_set_pkt_head, lle_set_pkt_tail;
    logic                  lle_alloc_is_mcast;
    logic [REF_W-1:0]      lle_alloc_ref_init;

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

    // LLE ↔ Mcast (置初值)
    logic                  mc_set_req;
    logic [ADDR_W-1:0]     mc_set_addr;
    logic [REF_W-1:0]      mc_set_init;
    logic                  mc_set_ack;

    // Recycle Ctrl ↔ Mcast (递减)
    logic                  mc_dec_req;
    logic [ADDR_W-1:0]     mc_dec_addr;
    logic                  mc_dec_ack, mc_ref_zero;
    logic                  mc_ref_underflow;

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

    // 顶层告警: occ 溢出/下溢 + 组播 ref 下溢, 一并汇入 (csr 内再聚成 irq)。
    assign overflow_alarm  = occ_overflow_alarm;
    assign underflow_alarm = occ_underflow_alarm | mc_ref_underflow;

    //========================================================================
    // 子模块例化
    //========================================================================

    // ---- Enqueue Ctrl ----
    enqueue_ctrl #(
        .CELL_NUM (CELL_NUM), .QUEUE_NUM (QUEUE_NUM),
        .PORT_NUM (PORT_NUM), .REF_W (REF_W)
    ) u_enq (
        .clk_core              (clk_core),
        .rst_core_n            (rst_core_n),
        .init_done             (init_done),
        .enq_req               (enq_req),
        .enq_queue_id          (enq_queue_id),
        .enq_egress_port       (enq_egress_port),
        .enq_is_mcast          (enq_is_mcast),
        .enq_mcast_bitmap      (enq_mcast_bitmap),
        .enq_sof               (enq_sof),
        .enq_eof               (enq_eof),
        .enq_ready             (enq_ready),
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
        .occ_accept            (occ_accept),
        .occ_drop              (occ_drop),
        .occ_use_static        (occ_use_static),
        .occ_no_free           (occ_no_free),
        .lle_free_head         (lle_free_head),
        .lle_free_empty        (lle_free_empty),
        .lle_alloc_ready       (lle_alloc_ready),
        .lle_alloc_fire        (lle_alloc_fire),
        .lle_alloc_queue_id    (lle_alloc_queue_id),
        .lle_alloc_addr        (lle_alloc_addr),
        .lle_set_pkt_head      (lle_set_pkt_head),
        .lle_set_pkt_tail      (lle_set_pkt_tail),
        .lle_alloc_is_mcast    (lle_alloc_is_mcast),
        .lle_alloc_ref_init    (lle_alloc_ref_init)
    );

    // ---- Dequeue Ctrl ----
    dequeue_ctrl #(
        .CELL_NUM (CELL_NUM), .QUEUE_NUM (QUEUE_NUM), .PORT_NUM (PORT_NUM)
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
        .CELL_NUM (CELL_NUM), .QUEUE_NUM (QUEUE_NUM), .PORT_NUM (PORT_NUM)
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
        .mc_dec_req             (mc_dec_req),
        .mc_dec_addr            (mc_dec_addr),
        .mc_dec_ack             (mc_dec_ack),
        .mc_ref_zero            (mc_ref_zero),
        .lle_free_req           (lle_free_req),
        .lle_free_addr          (lle_free_addr),
        .lle_free_queue_id      (lle_free_queue_id),
        .lle_free_grant         (lle_free_grant),
        .lle_free_done          (lle_free_done)
    );

    // ---- Link-List Engine (含内部 Next-Ptr SRAM) ----
    lle #(
        .CELL_NUM (CELL_NUM), .QUEUE_NUM (QUEUE_NUM),
        .PORT_NUM (PORT_NUM), .REF_W (REF_W)
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
        .lle_alloc_ref_init (lle_alloc_ref_init),
        .lle_deq_queue_id   (lle_deq_queue_id),
        .lle_qhead          (lle_qhead),
        .lle_qhead_pkt_head (lle_qhead_pkt_head),
        .lle_qhead_pkt_tail (lle_qhead_pkt_tail),
        .lle_q_empty        (lle_q_empty),
        .lle_deq_fire       (lle_deq_fire),
        .lle_free_req       (lle_free_req),
        .lle_free_addr      (lle_free_addr),
        .lle_free_queue_id  (lle_free_queue_id),
        .lle_free_grant     (lle_free_grant),
        .lle_free_done      (lle_free_done),
        .mc_set_req         (mc_set_req),
        .mc_set_addr        (mc_set_addr),
        .mc_set_init        (mc_set_init),
        .mc_set_ack         (mc_set_ack),
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
        .CELL_NUM (CELL_NUM), .QUEUE_NUM (QUEUE_NUM),
        .PORT_NUM (PORT_NUM), .STAT_W (STAT_W)
    ) u_occ (
        .clk_core              (clk_core),
        .rst_core_n            (rst_core_n),
        // 与 Enqueue Ctrl (按当前入队队列/端口判决)
        .occ_query_vld         (occ_query_vld),
        .occ_query_queue_id    (occ_query_queue_id),
        .occ_query_egress_port (occ_query_egress_port),
        .occ_accept            (occ_accept),
        .occ_drop              (occ_drop),
        .occ_use_static        (occ_use_static),
        .occ_no_free           (occ_no_free),
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

    // ---- Multicast Ref-Count Mgr ----
    mcast_refcount_mgr #(
        .ADDR_W (ADDR_W), .CELL_NUM (CELL_NUM), .REF_W (REF_W)
    ) u_mc (
        .clk_core         (clk_core),
        .rst_core_n       (rst_core_n),
        .mc_set_req       (mc_set_req),
        .mc_set_addr      (mc_set_addr),
        .mc_set_init      (mc_set_init),
        .mc_set_ack       (mc_set_ack),
        .mc_dec_req       (mc_dec_req),
        .mc_dec_addr      (mc_dec_addr),
        .mc_dec_ack       (mc_dec_ack),
        .mc_ref_zero      (mc_ref_zero),
        .mc_ref_underflow (mc_ref_underflow)
    );

    // ---- CSR / Stats + Init FSM (无总线; cfg_in_* 直采, 下发 occ; 统计置 0) ----
    csr_stats_init #(
        .CELL_NUM (CELL_NUM), .QUEUE_NUM (QUEUE_NUM),
        .PORT_NUM (PORT_NUM), .STAT_W (STAT_W)
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
    parameter int QUEUE_NUM = 34,
    parameter int PORT_NUM  = 4,
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
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
    // 出队队列 → 出端口映射: egress_port = queue_id >> $clog2(QUEUE_NUM/PORT_NUM)。
    //   截到 PORT_NUM 范围内 (越界端口视为 0, 实际不会发生)。
    //========================================================================
    localparam int    Q_PER_PORT_LOG = $clog2(QUEUE_NUM / PORT_NUM);
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
    parameter int QUEUE_NUM  = 34,
    parameter int PORT_NUM   = 4,
    parameter int STAT_W     = 32,
    // 派生位宽 / 数量 (与 occupancy_pool_mgr 同源)
    localparam int CNT_W     = $clog2(CELL_NUM) + 1,
    localparam int TC_NUM    = QUEUE_NUM / PORT_NUM
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
    parameter int QUEUE_NUM = 34,
    parameter int PORT_NUM  = 4,
    parameter int REF_W     = 3,
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
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
    input  logic                  enq_is_mcast,        // 组播标志
    input  logic [PORT_NUM-1:0]   enq_mcast_bitmap,    // 组播出端口位图
    input  logic                  enq_sof,             // 报文首段
    input  logic                  enq_eof,             // 报文尾段
    output logic                  enq_ready,           // 可接请求(init_done 后恒高)
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
    input  logic                  occ_accept,          // 判决=接收
    input  logic                  occ_drop,            // 判决=丢弃(高水位兜底)
    input  logic                  occ_use_static,      // 记静态池(=1)/动态池(=0)
    input  logic                  occ_no_free,         // 空闲池已空(强制丢弃)

    //------------------------------------------------------------------------
    // 与 Link-List Engine (LLE) 的接口 (内部, 单拍命令式分配+挂链)
    //   ★ lle_alloc_ready: LLE 本拍可受理 alloc。
    //     - LLE 仲裁中 deq 占 SRAM 时 = 0, 本模块当拍不发 fire, QM 自动等下拍;
    //     - build 期间 / free 池空时也 = 0。
    //------------------------------------------------------------------------
    input  logic [ADDR_W-1:0]     lle_free_head,       // 当前空闲链头(T0 当拍取)
    input  logic                  lle_free_empty,      // 空闲链空
    input  logic                  lle_alloc_ready,     // LLE 本拍可受理 alloc (含 ~deq 抢占 / ~build / ~free 空)
    output logic                  lle_alloc_fire,      // 分配+挂链命令(一拍脉冲)
    output logic [QID_W-1:0]      lle_alloc_queue_id,  // 挂链目标队列
    output logic [ADDR_W-1:0]     lle_alloc_addr,      // 本次分配地址(=lle_free_head)
    output logic                  lle_set_pkt_head,    // 写 pkt_head (= enq_sof)
    output logic                  lle_set_pkt_tail,    // 写 pkt_tail (= enq_eof)
    output logic                  lle_alloc_is_mcast,  // 组播标志
    output logic [REF_W-1:0]      lle_alloc_ref_init   // 组播 ref_count 初值=popcount
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

    //========================================================================
    // 组播 ref_count 初值 = popcount(enq_mcast_bitmap)
    //========================================================================
    logic [REF_W-1:0] ref_init_c;
    integer bi;
    always_comb begin
        ref_init_c = '0;
        for (bi = 0; bi < PORT_NUM; bi++)
            ref_init_c = ref_init_c + {{(REF_W-1){1'b0}}, enq_mcast_bitmap[bi]};
    end

    //========================================================================
    // 整帧丢弃 FSM: 一帧 (sof~eof) 内任一 cell 判丢则置位并保持到 eof,
    //   本帧后续 cell 在 T0 直接判丢、不取地址、不发 fire。
    //   frame_drop_q: 当前帧已进入"整帧丢弃"状态 (sof 拍判丢后保持到 eof)。
    //========================================================================
    logic frame_drop_q;

    // 本 cell 的丢弃来源:
    //   - occ_drop / occ_no_free / lle_free_empty: 占用水位高水位无条件丢弃 + 空闲池空兜底
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
            // 本 cell 触发丢弃 (高水位无条件丢弃 / 空闲池空)
            else if (occ_drop | occ_no_free | lle_free_empty) begin
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
    assign lle_alloc_fire     = accept_c;
    assign lle_alloc_queue_id = enq_queue_id;
    assign lle_alloc_addr     = lle_free_head;       // T0 当拍即取
    assign lle_set_pkt_head   = enq_sof;
    assign lle_set_pkt_tail   = enq_eof;
    assign lle_alloc_is_mcast = enq_is_mcast;
    assign lle_alloc_ref_init = ref_init_c;

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

```
//============================================================================
// Module      : mcast_refcount_mgr  (Multicast Ref-Count Manager)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   辅助平面。按 B1 多播模型 (见《MMU_多播处理分析.md》方案 B1) 实现:
//   每个组播 cell 维护 ref_count (4 端口 → 3bit, 0~4)。
//     - 入队(置初值): LLE 同拍转发 mc_set_* 把 ref_count[mc_set_addr] = mc_set_init
//                     ( = popcount(enq_mcast_bitmap), 即该多播 cell 要发往的端口数 )。
//     - 回收(递减)  : Recycle Ctrl 每收到一个端口的 mcast_recycle_req → 发 mc_dec_*,
//                     ref_count[mc_dec_addr]-- ; 减到 0 时拉 mc_ref_zero=1, 表示
//                     "所有目标端口都已发完, 该 cell 可以真正还链 (Recycle Ctrl 据此
//                     向 LLE 发 lle_free_req)"。
//   B1 关键语义: 多播 data cell 的回收 **完全由 ref_count 归零驱动**; 被某端口读取
//   (出队) 不会让 ref_count 变化, 也不会摘链/还链 —— 这是多播相对单播唯一的不同。
//
//   防护:
//     - 下溢检测: 对一个 ref_count 已为 0 的 cell 又收到 mc_dec_req → 视为 double-count
//       / EPS 重复通知错误, 拉 mc_ref_underflow 给上层汇成 underflow_alarm, 并把该 cell
//       ref 钳在 0 (不回绕)。
//     - mc_ref_zero 仅在 "本拍递减后恰好到 0" 时为 1 (脉冲), 供 Recycle Ctrl 当拍判定还链。
//
//   时序:
//     - mc_set / mc_dec 命中同拍写回 ref_count_q (组合算 next, 时序更新), ack 同拍拉高。
//     - mc_set 与 mc_dec 命中同一 cell 同拍属非法用法 (入队与回收不会同拍碰同一新分配
//       cell); 仿真断言捕获。若真同拍, set 优先 (按入队语义重置初值)。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module mcast_refcount_mgr #(
    parameter int ADDR_W    = 13,
    parameter int CELL_NUM  = 8192,
    parameter int REF_W     = 3
)(
    //------------------------------------------------------------------------
    // 时钟复位 (公共)
    //------------------------------------------------------------------------
    input  logic                  clk_core,
    input  logic                  rst_core_n,

    //------------------------------------------------------------------------
    // 与 LLE 的接口 (入队同拍置初值)
    //------------------------------------------------------------------------
    input  logic                  mc_set_req,          // 置 ref_count 初值请求
    input  logic [ADDR_W-1:0]     mc_set_addr,         // 目标组播 cell
    input  logic [REF_W-1:0]      mc_set_init,         // ref_count 初值=popcount(bitmap)
    output logic                  mc_set_ack,          // 写完应答

    //------------------------------------------------------------------------
    // 与 Recycle Ctrl 的接口 (回收递减)
    //------------------------------------------------------------------------
    input  logic                  mc_dec_req,          // ref_count-- 请求
    input  logic [ADDR_W-1:0]     mc_dec_addr,         // 目标组播 cell
    output logic                  mc_dec_ack,          // 递减完成
    output logic                  mc_ref_zero,         // 本拍递减后归零(允许真正还链)

    //------------------------------------------------------------------------
    // 防护输出 (汇入 underflow_alarm)
    //------------------------------------------------------------------------
    output logic                  mc_ref_underflow     // 对 ref=0 的 cell 再递减(double-count)
);

    //========================================================================
    // ref_count 存储 (全量 cell, 每 cell REF_W bit)。
    //   说明: 也可只对组播 cell 用小 RegFile/CAM 节面积; 此处用全量寄存器堆,
    //   8192×3bit ≈ 3KB 触发器, 面积可接受, 实现最简、读写当拍可达。
    //========================================================================
    logic [REF_W-1:0] ref_count_q [CELL_NUM];

    //========================================================================
    // 组合读出与 next 计算
    //========================================================================
    logic [REF_W-1:0] dec_cur;       // 递减目标当前值
    logic [REF_W-1:0] dec_next;      // 递减后值
    logic             dec_is_zero_in;// 递减前已为 0 (下溢)

    assign dec_cur        = ref_count_q[mc_dec_addr];
    assign dec_is_zero_in = (dec_cur == '0);
    // 递减: >0 时 -1; =0 时钳 0 (下溢, 不回绕)
    assign dec_next       = dec_is_zero_in ? '0 : (dec_cur - 1'b1);

    //========================================================================
    // 应答 / 归零 / 下溢 (组合, 当拍给)
    //   - mc_dec_ack : 收到递减请求即应答 (无阻塞)。
    //   - mc_ref_zero: 本拍递减后恰好到 0 (dec_cur==1 且非下溢) → 允许还链。
    //   - underflow  : 对 ref 已为 0 的 cell 又来递减。
    //========================================================================
    assign mc_set_ack      = mc_set_req;
    assign mc_dec_ack      = mc_dec_req;
    assign mc_ref_zero     = mc_dec_req & ~dec_is_zero_in & (dec_next == '0);
    assign mc_ref_underflow= mc_dec_req &  dec_is_zero_in;

    //========================================================================
    // 写回 ref_count_q
    //   - set 命中: ref[set_addr] = set_init   (入队置初值, 优先)
    //   - dec 命中: ref[dec_addr] = dec_next   (回收递减, 钳 0)
    //   - set 与 dec 同拍命中同一 cell: set 优先 (非法用法, 仿真断言)。
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < CELL_NUM; i++)
                ref_count_q[i] <= '0;
        end
        else begin
            // 递减先写 (若与 set 同 cell, 下面 set 覆盖, 实现 set 优先)
            if (mc_dec_req)
                ref_count_q[mc_dec_addr] <= dec_next;
            // 置初值 (优先级高于同拍同 cell 的 dec)
            if (mc_set_req)
                ref_count_q[mc_set_addr] <= mc_set_init;
        end
    end

`ifdef SIM_BEHAVIOR_SRAM
    //========================================================================
    // 仿真断言
    //========================================================================
    always_ff @(posedge clk_core) begin
        if (rst_core_n) begin
            // 1) double-count: 对 ref=0 的 cell 递减
            if (mc_ref_underflow)
                $error("[mcast_refcount_mgr] REF UNDERFLOW: dec on cell %0d whose ref_count==0",
                       mc_dec_addr);
            // 2) set/dec 同拍命中同一 cell (非法: 入队与回收不应同拍碰同一 cell)
            if (mc_set_req && mc_dec_req && (mc_set_addr == mc_dec_addr))
                $error("[mcast_refcount_mgr] set & dec same cell %0d in same cycle (illegal)",
                       mc_set_addr);
        end
    end
`endif

endmodule
```


```
//============================================================================
// Testbench : smart_mmu_tb
// Project   : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// 目标:
//   仿照 QM 行为, 通过寄存器输出激励 smart_mmu 的 input、读取 output (clk/rst 除外),
//   自检式 (self-checking) 覆盖:
//     C1  单队列挂链/走链/还链, free 链计数校验
//     C2  跨队列交叉挂链/走链, free 链/占用计数校验
//     C3  还链后 free 链恢复校验 (free_cnt / 守恒)
//     C4  多播链 挂链(置 ref) / 走链(不摘链) / 还链(ref 归零才还)
//     C5  enq + deq 同拍仲裁 + 反压 (deq 占 SRAM → enq 等)
//     C6  deq + rcy 同拍仲裁与处理
//     C7  enq + deq + rcy 三者同拍仲裁与处理
//     C8  水线/满/快满 (q/port/global near_full + full) 触发与释放
//     C9  PAUSE 触发/释放
//     C10 压力测试 (随机混合 enq/deq/rcy, 守恒 + 无下溢/溢出)
//
//   每个 case 打印相关寄存器/信号, 与期望值对比, 显示 PASS/FAIL。
//
//   驱动方式: 所有 DUT 输入在 negedge 用阻塞赋值驱动 (寄存器输出语义, 到 posedge
//             稳定); DUT 的 alloc_valid/deq_cell_valid 是寄存器输出, 用 monitor
//             在 posedge 捕获到 scoreboard 队列, 任务据此判定。
//
//   规模: CELL_NUM=64, QUEUE_NUM=8, PORT_NUM=2 (TC_NUM=4; q>>2 → port)
//============================================================================
`timescale 1ns/1ps

module smart_mmu_tb;

    //========================================================================
    // 参数 (缩小规模便于仿真与水线触发)
    //========================================================================
    localparam int CELL_NUM  = 64;
    localparam int QUEUE_NUM = 8;     // q0..q3→port0, q4..q7→port1
    localparam int PORT_NUM  = 2;
    localparam int REF_W     = 3;
    localparam int STAT_W    = 32;

    localparam int ADDR_W = $clog2(CELL_NUM);          // 6
    localparam int QID_W  = $clog2(QUEUE_NUM-1)+1;     // 4
    localparam int PORT_W = $clog2(PORT_NUM-1)+1;      // 1
    localparam int CNT_W  = ADDR_W + 1;                // 7
    localparam int TC_NUM = QUEUE_NUM / PORT_NUM;      // 4
    localparam int QPP    = $clog2(TC_NUM);            // 2 (queue→port 右移位数)

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
    // DUT 输入寄存器 (TB 在 negedge 驱动)
    //========================================================================
    logic                  init_start_r;
    // enq
    logic                  enq_req_r;
    logic [QID_W-1:0]      enq_queue_id_r;
    logic [PORT_W-1:0]     enq_egress_port_r;
    logic                  enq_is_mcast_r;
    logic [PORT_NUM-1:0]   enq_mcast_bitmap_r;
    logic                  enq_sof_r, enq_eof_r;
    // deq
    logic                  deq_req_r;
    logic [QID_W-1:0]      deq_queue_id_r;
    logic [PORT_NUM-1:0]   deq_backpressure_r;
    // recycle
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
    logic                  alloc_valid;
    logic [ADDR_W-1:0]     alloc_cell_addr;
    logic                  alloc_drop_ind, alloc_sram_flag, alloc_pkt_head, alloc_pkt_tail;
    logic                  alloc_full_frame_drop;
    logic                  deq_ready;
    logic                  deq_cell_valid;
    logic [ADDR_W-1:0]     deq_cell_addr;
    logic                  deq_pkt_head, deq_pkt_tail;
    logic                  recycle_ack;
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
    // 配置寄存器 (TB 驱动 cfg_in_*)
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

    // stats out (不校验, 仅接线)
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
        .CELL_NUM (CELL_NUM), .QUEUE_NUM (QUEUE_NUM),
        .PORT_NUM (PORT_NUM), .REF_W (REF_W), .STAT_W (STAT_W)
    ) u_dut (
        .clk_core (clk), .rst_core_n (rst_n),
        .init_start (init_start_r), .init_done (init_done),
        // enq
        .enq_req (enq_req_r), .enq_queue_id (enq_queue_id_r),
        .enq_egress_port (enq_egress_port_r), .enq_is_mcast (enq_is_mcast_r),
        .enq_mcast_bitmap (enq_mcast_bitmap_r), .enq_sof (enq_sof_r), .enq_eof (enq_eof_r),
        .enq_ready (enq_ready), .alloc_valid (alloc_valid),
        .alloc_cell_addr (alloc_cell_addr), .alloc_drop_ind (alloc_drop_ind),
        .alloc_sram_flag (alloc_sram_flag), .alloc_pkt_head (alloc_pkt_head),
        .alloc_pkt_tail (alloc_pkt_tail), .alloc_full_frame_drop (alloc_full_frame_drop),
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
    // 内部 DUT 信号引用 (用于自检与打印)
    //========================================================================
    // LLE
    wire [CNT_W-1:0]  lle_free_cnt   = u_dut.u_lle.free_cnt_q;
    wire [ADDR_W-1:0] lle_free_head  = u_dut.u_lle.free_head_q;
    wire [ADDR_W-1:0] lle_free_tail  = u_dut.u_lle.free_tail_q;
    // occ
    wire [CNT_W-1:0]  occ_free_cnt   = u_dut.u_occ.free_count_q;
    wire [CNT_W-1:0]  occ_glob_used  = u_dut.u_occ.global_used_q;

    function automatic int unsigned lle_qcnt (input int qi); lle_qcnt = u_dut.u_lle.q_cell_cnt_q[qi]; endfunction
    function automatic int unsigned lle_qhead(input int qi); lle_qhead= u_dut.u_lle.q_head_q[qi];     endfunction
    function automatic int unsigned lle_qtail(input int qi); lle_qtail= u_dut.u_lle.q_tail_q[qi];     endfunction
    function automatic int unsigned occ_qcnt (input int qi); occ_qcnt = u_dut.u_occ.q_cell_cnt_q[qi]; endfunction
    function automatic int unsigned occ_qstat(input int qi); occ_qstat= u_dut.u_occ.q_static_used_q[qi]; endfunction
    function automatic int unsigned occ_pused(input int pi); occ_pused= u_dut.u_occ.per_port_used_q[pi]; endfunction
    function automatic int unsigned mc_ref   (input int ci); mc_ref   = u_dut.u_mc.ref_count_q[ci];   endfunction

    //========================================================================
    // Scoreboard: monitor 捕获 alloc / deq 事件 (posedge 采样寄存器输出)
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

    // enq fire 计数 (enq_req 寄存器 & 组合 enq_ready 在 posedge 成立 = 真正 fire/alloc)
    //   用于并发场景下"按实际落地推进 cell 指针", 不丢/不重 cell。
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
        if (got === exp)
            $display("    [PASS] %-28s got=%0d exp=%0d", nm, got, exp);
        else begin
            errors++;
            $display("    [FAIL] %-28s got=%0d exp=%0d  <<<<<<", nm, got, exp);
        end
    endtask

    task automatic chk_b(string nm, logic got, logic exp);
        checks++;
        if (got === exp)
            $display("    [PASS] %-28s got=%0b exp=%0b", nm, got, exp);
        else begin
            errors++;
            $display("    [FAIL] %-28s got=%0b exp=%0b  <<<<<<", nm, got, exp);
        end
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
        $display("    LLE  free_cnt=%0d head=%0d tail=%0d | occ free=%0d glob_used=%0d",
                 lle_free_cnt, lle_free_head, lle_free_tail, occ_free_cnt, occ_glob_used);
        for (qi=0; qi<QUEUE_NUM; qi++) begin
            if (lle_qcnt(qi)!=0 || occ_qcnt(qi)!=0)
                $display("    q[%0d] LLE: head=%0d tail=%0d cnt=%0d | occ: used=%0d static=%0d",
                         qi, lle_qhead(qi), lle_qtail(qi), lle_qcnt(qi),
                         occ_qcnt(qi), occ_qstat(qi));
        end
        for (pi=0; pi<PORT_NUM; pi++)
            $display("    port[%0d] occ_used=%0d near_full=%0b full=%0b pause=%0b",
                     pi, occ_pused(pi), port_near_full[pi], port_full[pi], pause_req[pi]);
        $display("    q_near_full=%b q_full=%b global_near_full=%0b global_full=%0b",
                 q_near_full, q_full, global_near_full, global_full);
    endtask

    //========================================================================
    // 配置: 选取小阈值, 便于触发水线
    //========================================================================
    task automatic cfg_setup();
        int qi, pi, tj;
        for (qi=0; qi<QUEUE_NUM; qi++) begin
            cfg_queue_min_cell[qi] = 2;     // 每队列静态预留 2
            cfg_q_max_cell[qi]     = 10;    // 高水位 10 (near_full = 10-margin(2)=8)
            cfg_q_full[qi]         = 12;    // 满阈值 12
        end
        for (pi=0; pi<PORT_NUM; pi++) begin
            cfg_port_max[pi]        = 24;   // 端口高水位 24 (near_full=24-4=20)
            cfg_port_pause_xoff[pi] = 28;   // PAUSE xoff
            cfg_port_pause_xon[pi]  = 16;   // PAUSE xon
            for (tj=0; tj<TC_NUM; tj++) begin
                cfg_pfc_xoff[pi][tj] = 9;
                cfg_pfc_xon[pi][tj]  = 4;
            end
        end
        cfg_global_high_wm    = 50;        // 全局高水位 (global_near_full=50-8=42)
        cfg_global_pause_xoff = 56;
        cfg_global_pause_xon  = 40;
        cfg_pause_en          = 1'b1;
        cfg_pfc_en            = 1'b1;
    endtask

    //========================================================================
    // 复位 + 初始化 (建链)
    //========================================================================
    task automatic do_reset_init();
        rst_n = 0;
        init_start_r = 0;
        enq_req_r = 0; enq_queue_id_r=0; enq_egress_port_r=0; enq_is_mcast_r=0;
        enq_mcast_bitmap_r=0; enq_sof_r=0; enq_eof_r=0;
        deq_req_r=0; deq_queue_id_r=0; deq_backpressure_r=0;
        recycle_req_r=0; recycle_cell_addr_r=0; recycle_queue_id_r=0;
        mcast_recycle_req_r=0; mcast_recycle_addr_r=0; mcast_recycle_queue_id_r=0;
        cfg_setup();
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        // 触发初始化建链
        @(negedge clk); init_start_r = 1;
        @(negedge clk); init_start_r = 0;
        // 等 init_done (LLE 建链 CELL_NUM 拍 + FSM)
        while (!init_done) @(negedge clk);
        repeat (2) @(negedge clk);
        $display("[%0t] INIT done: free_cnt=%0d (expect %0d)", $time, lle_free_cnt, CELL_NUM);
    endtask

    //========================================================================
    // 入队一整包 (背靠背, 受 enq_ready 反压, 按实际 alloc 落地推进)
    //   返回: 分配到的 cell 地址写入 last_alloc[], last_alloc_n
    //========================================================================
    int                last_alloc_n;
    logic [ADDR_W-1:0] last_alloc [0:CELL_NUM-1];

    task automatic enqueue_pkt(input int qid, input int port, input int ncells,
                               input bit is_mcast, input [PORT_NUM-1:0] bitmap);
        int sent_idx;        // 已发出的 cell 序号 (基于实际落地推进)
        int got_before;
        sent_idx = 0;
        last_alloc_n = 0;
        got_before = alloc_q.size();
        $display("  >>> ENQ q%0d port%0d cells=%0d mcast=%0b", qid, port, ncells, is_mcast);
        while (sent_idx < ncells) begin
            @(negedge clk);
            if (enq_ready) begin
                enq_req_r          = 1'b1;
                enq_queue_id_r     = qid[QID_W-1:0];
                enq_egress_port_r  = port[PORT_W-1:0];
                enq_is_mcast_r     = is_mcast;
                enq_mcast_bitmap_r = bitmap;
                enq_sof_r          = (sent_idx == 0);
                enq_eof_r          = (sent_idx == ncells-1);
                sent_idx++;
            end
            else begin
                enq_req_r = 1'b0;   // 反压: 当拍不发
            end
        end
        @(negedge clk);
        enq_req_r = 1'b0; enq_sof_r=0; enq_eof_r=0;
        // 等待最后一个 alloc 落地 + occ 计数稳定
        repeat (3) @(negedge clk);
        // 收集本次分配的地址
        last_alloc_n = alloc_q.size() - got_before;
    endtask

    //========================================================================
    // 出队一整包 (背靠背, 直到 pkt_tail), 返回出队地址序列
    //========================================================================
    int                last_deq_n;
    logic [ADDR_W-1:0] last_deq [0:CELL_NUM-1];

    task automatic dequeue_pkt(input int qid, input [PORT_NUM-1:0] bp);
        int got_before;
        bit done;
        int guard;
        got_before = deq_q.size();
        done = 0; guard = 0;
        $display("  >>> DEQ q%0d bp=%b", qid, bp);
        @(negedge clk);
        deq_queue_id_r     = qid[QID_W-1:0];
        deq_backpressure_r = bp;
        deq_req_r          = 1'b1;
        // 持续 deq, 由 monitor 捕获出队 cell; 检测到 pkt_tail 落地后停止
        while (!done && guard < CELL_NUM*4) begin
            @(negedge clk);
            // 检查 monitor 最近捕获的是否 pkt_tail
            if (deq_q.size() > got_before) begin
                if (deq_q[deq_q.size()-1].pt) done = 1;
            end
            // 队列空 (无更多可出) 也停止
            if (u_dut.u_lle.q_cell_cnt_q[qid]==0 && deq_q.size()>got_before) done = 1;
            guard++;
        end
        deq_req_r = 1'b0;
        repeat (3) @(negedge clk);
        last_deq_n = deq_q.size() - got_before;
    endtask

    //========================================================================
    // 单播还链 N 个 cell (背靠背), 携带 queue_id
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
        repeat (cells.size()+4) @(negedge clk);   // 等 LLE FIFO 落地 + occ 计数
    endtask

    //========================================================================
    // 组播还链 (某端口发完一份) N 次, 携带 queue_id
    //========================================================================
    task automatic mcast_recycle_n(input int qid, input [ADDR_W-1:0] addr, input int times);
        int i;
        $display("  >>> MCAST RCY q%0d addr=%0d times=%0d", qid, addr, times);
        for (i=0; i<times; i++) begin
            @(negedge clk);
            mcast_recycle_req_r      = 1'b1;
            mcast_recycle_addr_r     = addr;
            mcast_recycle_queue_id_r = qid[QID_W-1:0];
            @(negedge clk);
            mcast_recycle_req_r = 1'b0;
            repeat (2) @(negedge clk);   // 让归零→还链落地
        end
        repeat (4) @(negedge clk);
    endtask

    //========================================================================
    // 检查出队序列是否等于期望地址序列
    //========================================================================
    task automatic chk_deq_seq(string nm, int base_idx, int exp_addr[$]);
        int i; int ok;
        ok = (last_deq_n == exp_addr.size());
        chk($sformatf("%s deq_count", nm), last_deq_n, exp_addr.size());
        if (ok) begin
            for (i=0; i<exp_addr.size(); i++) begin
                chk($sformatf("%s deq[%0d].addr", nm, i),
                    deq_q[base_idx+i].addr, exp_addr[i]);
            end
        end
    endtask

    //========================================================================
    // 主测试序列
    //========================================================================
    int base;
    initial begin
        do_reset_init();

        //====================================================================
        // C1: 单队列挂链/走链/还链 + free 链计数
        //====================================================================
        case_begin("C1 single-queue enq/deq/rcy + free_cnt");
        // q0 挂 4 cell (单包)
        base = alloc_q.size();
        enqueue_pkt(0, q2port(0), 4, 0, '0);
        dump_state("after enq q0 4-cell");
        chk("C1 alloc_count",    last_alloc_n, 4);
        chk("C1 lle_q0_cnt",     lle_qcnt(0), 4);
        chk("C1 occ_q0_used",    occ_qcnt(0), 4);
        chk("C1 free_cnt",       lle_free_cnt, CELL_NUM-4);
        chk("C1 occ_free",       occ_free_cnt, CELL_NUM-4);
        chk("C1 occ_glob_used",  occ_glob_used, 4);
        // 走链 q0 (出 4 cell), 期望出队地址 = 分配顺序 cell0..3
        base = deq_q.size();
        dequeue_pkt(0, '0);
        chk("C1 deq_count",      last_deq_n, 4);
        chk("C1 q0_cnt_after_deq", lle_qcnt(0), 0);
        // 注: 出队不还链, occ 占用不变 (store-and-forward)
        chk("C1 occ_q0_after_deq", occ_qcnt(0), 4);
        chk("C1 free_after_deq",   lle_free_cnt, CELL_NUM-4);
        // 还链刚才出的 4 个 cell (地址 0,1,2,3)
        begin
            int rc[$]; rc='{0,1,2,3};
            recycle_cells(0, rc);
        end
        dump_state("after rcy q0 4-cell");
        chk("C1 free_after_rcy",   lle_free_cnt, CELL_NUM);
        chk("C1 occ_q0_after_rcy", occ_qcnt(0), 0);
        chk("C1 occ_glob_after_rcy", occ_glob_used, 0);
        chk("C1 conserve", (lle_free_cnt==CELL_NUM)&&(occ_free_cnt==CELL_NUM), 1);

        //====================================================================
        // C2: 跨队列交叉挂链/走链 (q0,q1 交叉)
        //====================================================================
        case_begin("C2 cross-queue interleaved enq + deq");
        do_reset_init();   // 干净起点 (C1 回收已重排 free 链, 此处需重建保证地址可预期)
        enqueue_pkt(0, q2port(0), 3, 0, '0);   // q0: cells 0,1,2
        enqueue_pkt(1, q2port(1), 2, 0, '0);   // q1: cells 3,4
        enqueue_pkt(0, q2port(0), 2, 0, '0);   // q0 第二包: cells 5,6
        dump_state("after cross enq");
        chk("C2 lle_q0_cnt", lle_qcnt(0), 5);
        chk("C2 lle_q1_cnt", lle_qcnt(1), 2);
        chk("C2 free_cnt",   lle_free_cnt, CELL_NUM-7);
        chk("C2 q0_head",    lle_qhead(0), 0);
        chk("C2 q1_head",    lle_qhead(1), 3);
        // 走链 q0 第一包 (3 cell: 0,1,2), head 应推进到 5 (跨帧 relink 校验)
        base = deq_q.size();
        dequeue_pkt(0, '0);
        chk("C2 q0_deq1_count", last_deq_n, 3);
        chk("C2 q0_head_after", lle_qhead(0), 5);    // ★ 跨帧链接正确
        chk("C2 q0_cnt_after",  lle_qcnt(0), 2);
        // 走链 q1 (2 cell: 3,4)
        dequeue_pkt(1, '0);
        chk("C2 q1_deq_count", last_deq_n, 2);
        chk("C2 q1_cnt_after", lle_qcnt(1), 0);
        // 走链 q0 第二包 (2 cell: 5,6)
        dequeue_pkt(0, '0);
        chk("C2 q0_deq2_count", last_deq_n, 2);
        chk("C2 q0_cnt_final",  lle_qcnt(0), 0);
        // 全部还链 (按各自队列 queue_id 还, 保证 per-queue occ 计数正确)
        begin
            int rc_q0[$]; int rc_q1[$];
            rc_q0='{0,1,2,5,6};   // q0 的 cell
            rc_q1='{3,4};         // q1 的 cell
            recycle_cells(0, rc_q0);
            recycle_cells(1, rc_q1);
        end
        dump_state("after C2 recycle");
        chk("C2 free_restored",  lle_free_cnt, CELL_NUM);
        chk("C2 occ_glob_clear", occ_glob_used, 0);
        chk("C2 occ_q0_clear",   occ_qcnt(0), 0);
        chk("C2 occ_q1_clear",   occ_qcnt(1), 0);

        //====================================================================
        // C3: 还链后 free 链恢复 + 守恒 (多队列 enq → 全 deq → 全 rcy)
        //====================================================================
        case_begin("C3 free-list restore + conservation");
        do_reset_init();   // 干净起点
        // q0:2, q1:3, q5:4 (q5→port1)
        enqueue_pkt(0, q2port(0), 2, 0, '0);   // cells 0,1
        enqueue_pkt(1, q2port(1), 3, 0, '0);   // cells 2,3,4
        enqueue_pkt(5, q2port(5), 4, 0, '0);   // cells 5,6,7,8
        dump_state("C3 after enq");
        chk("C3 free_after_enq", lle_free_cnt, CELL_NUM-9);
        chk("C3 glob_used",      occ_glob_used, 9);
        // 全部走链
        dequeue_pkt(0, '0);
        dequeue_pkt(1, '0);
        dequeue_pkt(5, '0);
        chk("C3 q0_empty", lle_qcnt(0), 0);
        chk("C3 q1_empty", lle_qcnt(1), 0);
        chk("C3 q5_empty", lle_qcnt(5), 0);
        chk("C3 free_unchanged_after_deq", lle_free_cnt, CELL_NUM-9); // 出队不还链
        // 全部还链 (各队列)
        begin
            int r0[$]; int r1[$]; int r5[$];
            r0='{0,1}; r1='{2,3,4}; r5='{5,6,7,8};
            recycle_cells(0, r0);
            recycle_cells(1, r1);
            recycle_cells(5, r5);
        end
        dump_state("C3 after rcy");
        chk("C3 free_full",    lle_free_cnt, CELL_NUM);
        chk("C3 occ_free_full",occ_free_cnt, CELL_NUM);
        chk("C3 glob_zero",    occ_glob_used, 0);
        chk("C3 conserve",     (lle_free_cnt + occ_glob_used)==CELL_NUM, 1);
        chk_b("C3 no_overflow", overflow_alarm, 1'b0);
        chk_b("C3 no_underflow",underflow_alarm, 1'b0);

        //====================================================================
        // C4: 多播链 挂链(置 ref) / 走链(不摘链) / 还链(ref 归零才还)
        //====================================================================
        case_begin("C4 multicast set-ref / deq / ref-zero recycle");
        do_reset_init();
        // 组播包 3 cell 到 q2, bitmap=2'b11 → popcount=2 → 每 cell ref=2
        enqueue_pkt(2, q2port(2), 3, 1, 2'b11);
        dump_state("C4 after mcast enq");
        chk("C4 mcast_alloc_cnt", last_alloc_n, 3);
        chk("C4 q2_cnt",          lle_qcnt(2), 3);
        chk("C4 free_after_enq",  lle_free_cnt, CELL_NUM-3);
        chk("C4 ref_cell0", mc_ref(0), 2);
        chk("C4 ref_cell1", mc_ref(1), 2);
        chk("C4 ref_cell2", mc_ref(2), 2);
        // 走链 (出队一次, 不摘链/不还链): q_cell_cnt→0, free 不变
        dequeue_pkt(2, '0);
        chk("C4 q2_after_deq",   lle_qcnt(2), 0);
        chk("C4 free_after_deq", lle_free_cnt, CELL_NUM-3);   // 不还链
        chk("C4 ref_unchanged0", mc_ref(0), 2);              // 出队不改 ref
        // 组播回收: 每 cell 收 2 次端口完成通知 → ref 2→1→0 → 归零才还链
        // cell0: 第 1 次 → ref=1, 不还; 第 2 次 → ref=0, 还链
        mcast_recycle_n(2, 0, 1);
        chk("C4 cell0_ref_after1", mc_ref(0), 1);
        chk("C4 free_after1",      lle_free_cnt, CELL_NUM-3);  // 未归零, 不还
        mcast_recycle_n(2, 0, 1);
        chk("C4 cell0_ref_after2", mc_ref(0), 0);
        chk("C4 free_after2",      lle_free_cnt, CELL_NUM-2);  // 归零, 还 1 个
        // cell1, cell2 各还 2 次
        mcast_recycle_n(2, 1, 2);
        mcast_recycle_n(2, 2, 2);
        dump_state("C4 after all mcast recycle");
        chk("C4 free_full",   lle_free_cnt, CELL_NUM);
        chk("C4 ref_all_zero",(mc_ref(0)==0)&&(mc_ref(1)==0)&&(mc_ref(2)==0), 1);
        chk_b("C4 no_underflow", underflow_alarm, 1'b0);

        //====================================================================
        // 最终汇总
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
    // C5~C10
    //========================================================================
    task automatic run_remaining_cases();
        int fire_base, ei, guard, dropn, i;
        int deq3_base;

        //--------------------------------------------------------------------
        // C5: enq + deq 同拍仲裁 + 反压 (deq 占 SRAM → enq 等, 不丢 cell)
        //--------------------------------------------------------------------
        case_begin("C5 enq+deq concurrent + back-pressure");
        do_reset_init();
        // 预填 q3 6 cell (cells 0..5), 之后走链时 cnt>=3 → deq_need_sram=1 占读口
        enqueue_pkt(3, q2port(3), 6, 0, '0);
        chk("C5 prefill_q3_cnt", lle_qcnt(3), 6);
        // 并发: drain q3 (deq) + 向 q4 入队 3 cell (受反压, 按 fire 落地推进)
        fire_base = enq_fire_cnt;
        deq3_base = deq_q.size();
        guard = 0;
        @(negedge clk); deq_queue_id_r = 3; deq_backpressure_r = '0;
        while ( ((lle_qcnt(3) > 0) || ((enq_fire_cnt-fire_base) < 3)) && guard < 400 ) begin
            @(negedge clk);
            ei = enq_fire_cnt - fire_base;
            // deq 驱动 (q3 非空则发)
            deq_req_r = (lle_qcnt(3) > 0);
            // enq 驱动 q4 (按已 fire 数推进 sof/eof; 反压时保持当前 cell)
            if (ei < 3) begin
                enq_req_r          = 1'b1;
                enq_queue_id_r     = 4;
                enq_egress_port_r  = q2port(4);
                enq_is_mcast_r     = 1'b0;
                enq_mcast_bitmap_r = '0;
                enq_sof_r          = (ei == 0);
                enq_eof_r          = (ei == 2);
            end
            else enq_req_r = 1'b0;
            guard++;
        end
        deq_req_r = 1'b0; enq_req_r = 1'b0; enq_sof_r=0; enq_eof_r=0;
        repeat (4) @(negedge clk);
        dump_state("C5 after concurrent enq+deq");
        chk("C5 q3_drained",    lle_qcnt(3), 0);
        chk("C5 q3_deq_count",  deq_q.size()-deq3_base, 6);
        chk("C5 q4_landed",     lle_qcnt(4), 3);              // ★ 反压下无丢 cell
        chk("C5 enq_fire_3",    enq_fire_cnt-fire_base, 3);
        chk("C5 free_after",    lle_free_cnt, CELL_NUM-9);     // 6+3 alloc, deq 不还
        chk_b("C5 no_underflow",underflow_alarm, 1'b0);
        // 清理: 还 q3(0..5) + q4(6..8)
        begin int r3[$]; int r4[$]; r3='{0,1,2,3,4,5}; r4='{6,7,8};
              recycle_cells(3, r3); recycle_cells(4, r4); end
        chk("C5 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C6: deq + rcy 同拍仲裁 (deq 占读口, rcy 走写口/FIFO, 并行)
        //--------------------------------------------------------------------
        case_begin("C6 deq + rcy concurrent");
        do_reset_init();
        enqueue_pkt(3, q2port(3), 6, 0, '0);   // q3: 0..5
        enqueue_pkt(4, q2port(4), 3, 0, '0);   // q4: 6,7,8
        // 先把 q4 走链 (cells 6,7,8 出队, 可被回收)
        dequeue_pkt(4, '0);
        chk("C6 q4_drained", lle_qcnt(4), 0);
        chk("C6 free_before_concurrent", lle_free_cnt, CELL_NUM-9);
        // 并发: drain q3 (deq) + 回收 q4 的 6,7,8 (rcy)
        deq3_base = deq_q.size();
        guard = 0; i = 0;
        @(negedge clk); deq_queue_id_r = 3; deq_backpressure_r = '0;
        while ( ((lle_qcnt(3) > 0) || (i < 3)) && guard < 400 ) begin
            @(negedge clk);
            deq_req_r = (lle_qcnt(3) > 0);
            if (i < 3) begin
                recycle_req_r       = 1'b1;
                recycle_cell_addr_r = (6 + i);
                recycle_queue_id_r  = 4;
                i++;
            end
            else recycle_req_r = 1'b0;
            guard++;
        end
        deq_req_r = 1'b0; recycle_req_r = 1'b0;
        repeat (5) @(negedge clk);
        dump_state("C6 after concurrent deq+rcy");
        chk("C6 q3_drained",   lle_qcnt(3), 0);
        chk("C6 q3_deq_count", deq_q.size()-deq3_base, 6);
        // q4 的 3 个 cell 已回收 → free += 3 (相对并发前 CELL_NUM-9)
        chk("C6 free_after",   lle_free_cnt, CELL_NUM-6);
        chk("C6 occ_q4_dec",   occ_qcnt(4), 0);
        chk_b("C6 no_underflow", underflow_alarm, 1'b0);
        // 清理 q3 (0..5)
        begin int r3[$]; r3='{0,1,2,3,4,5}; recycle_cells(3, r3); end
        chk("C6 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C7: enq + deq + rcy 三者同拍仲裁 (deq>enq>rcy)
        //--------------------------------------------------------------------
        case_begin("C7 enq+deq+rcy triple concurrent");
        do_reset_init();
        enqueue_pkt(3, q2port(3), 6, 0, '0);   // q3: 0..5
        enqueue_pkt(4, q2port(4), 3, 0, '0);   // q4: 6,7,8
        dequeue_pkt(4, '0);                    // q4 出队 (6,7,8 可回收)
        chk("C7 free_before", lle_free_cnt, CELL_NUM-9);
        // 并发: deq q3(drain) + enq q5(2 cell) + rcy q4(6,7,8)
        fire_base = enq_fire_cnt;
        deq3_base = deq_q.size();
        guard = 0; i = 0;
        @(negedge clk); deq_queue_id_r = 3; deq_backpressure_r = '0;
        while ( ((lle_qcnt(3)>0) || ((enq_fire_cnt-fire_base)<2) || (i<3)) && guard<500 ) begin
            @(negedge clk);
            ei = enq_fire_cnt - fire_base;
            deq_req_r = (lle_qcnt(3) > 0);
            // enq q5
            if (ei < 2) begin
                enq_req_r=1'b1; enq_queue_id_r=5; enq_egress_port_r=q2port(5);
                enq_is_mcast_r=1'b0; enq_mcast_bitmap_r='0;
                enq_sof_r=(ei==0); enq_eof_r=(ei==1);
            end else enq_req_r=1'b0;
            // rcy q4 cells
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
        chk("C7 q5_landed",    lle_qcnt(5), 2);   // enq 无丢
        chk("C7 enq_fire_2",   enq_fire_cnt-fire_base, 2);
        // free: 并发前 CELL_NUM-9; rcy 还 3 (+3), enq 占 2 (-2) → CELL_NUM-8
        chk("C7 free_after",   lle_free_cnt, CELL_NUM-8);
        chk_b("C7 no_underflow", underflow_alarm, 1'b0);
        // 清理: q3(0..5), q5(新分配的 2 cell = 6,7 因 q4 已回收 6,7,8 → free 头回到 6)
        begin int r3[$]; int r5[$];
              r3='{0,1,2,3,4,5};
              // q5 的 2 个 cell 地址 = 本次 enq 分配地址, 从 alloc_q 取最后 2 个
              r5='{ int'(alloc_q[alloc_q.size()-2].addr),
                    int'(alloc_q[alloc_q.size()-1].addr) };
              recycle_cells(3, r3); recycle_cells(5, r5); end
        chk("C7 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C8: 水线/快满/满 + 高水位丢弃 触发与释放
        //--------------------------------------------------------------------
        case_begin("C8 watermark / near_full / hi-wm drop / release");
        do_reset_init();
        // 向 q0 连发 14 个单 cell 包: 静态 2 + 动态至 cnt=10, 之后 hi_wm drop
        dropn = 0;
        begin int ab; ab = alloc_q.size();
            for (i=0;i<14;i++) enqueue_pkt(0, q2port(0), 1, 0, '0);
            // 统计 drop 数
            for (i=ab;i<alloc_q.size();i++) if (alloc_q[i].drop) dropn++;
        end
        dump_state("C8 after burst enq q0");
        chk("C8 q0_cnt_cap",   lle_qcnt(0), 10);        // hi_wm 封顶 10
        chk("C8 occ_q0",       occ_qcnt(0), 10);
        chk("C8 free_after",   lle_free_cnt, CELL_NUM-10);
        chk("C8 drop_count",   dropn, 4);               // 11..14 被丢
        chk_b("C8 q0_near_full_set", q_near_full[0], 1'b1);   // cnt(10)>=8
        // 释放: 回收 3 个 q0 cell → occ q0=7 < 8 → near_full 撤销
        begin int r[$]; r='{0,1,2}; recycle_cells(0, r); end
        dump_state("C8 after release 3");
        chk("C8 occ_q0_after_rel", occ_qcnt(0), 7);
        chk_b("C8 q0_near_full_clr", q_near_full[0], 1'b0);   // 7<8 撤销

        //--------------------------------------------------------------------
        // C9: PAUSE 触发与释放 (端口聚合占用 >= xoff → pause; < xon → release)
        //--------------------------------------------------------------------
        case_begin("C9 PAUSE assert / release (port aggregate)");
        do_reset_init();
        // port0 = q0+q1+q2+q3. 每队列封顶 10. 发 q0,q1,q2 各 10 → port0 occ=30 >= xoff(28)
        for (i=0;i<12;i++) enqueue_pkt(0, q2port(0), 1, 0, '0); // q0 → 10 (2 drop)
        for (i=0;i<12;i++) enqueue_pkt(1, q2port(1), 1, 0, '0); // q1 → 10
        for (i=0;i<12;i++) enqueue_pkt(2, q2port(2), 1, 0, '0); // q2 → 10
        dump_state("C9 after fill port0 ~30");
        chk("C9 port0_used",    occ_pused(0), 30);
        chk_b("C9 pause_set",   pause_req[0], 1'b1);    // 30>=28
        // 释放: 回收 q0(10) + q1(5) → port0 occ = 30-15=15 < xon(16) → pause 撤销
        begin int r0[$]; int r1[$];
              r0='{0,1,2,3,4,5,6,7,8,9};
              r1='{10,11,12,13,14};   // q1 的前 5 个 cell (紧接 q0 之后分配)
              recycle_cells(0, r0); recycle_cells(1, r1); end
        dump_state("C9 after release to ~15");
        chk("C9 port0_used_rel", occ_pused(0), 15);
        chk_b("C9 pause_clr",    pause_req[0], 1'b0);   // 15<16 撤销

        //--------------------------------------------------------------------
        // C10: 压力测试 (多队列填充→全部走链→全部还链, 守恒 + 无告警)
        //--------------------------------------------------------------------
        case_begin("C10 stress: fill / drain / recycle conservation");
        do_reset_init();
        // 在 6 个单播队列各填一个 5-cell 包 (共 30 cell), 地址 0..29
        for (i=0;i<6;i++) enqueue_pkt(i, q2port(i), 5, 0, '0);
        dump_state("C10 after fill 6x5");
        chk("C10 free_after_fill", lle_free_cnt, CELL_NUM-30);
        chk("C10 glob_used",       occ_glob_used, 30);
        // 全部走链
        for (i=0;i<6;i++) dequeue_pkt(i, '0);
        for (i=0;i<6;i++) chk($sformatf("C10 q%0d_drained",i), lle_qcnt(i), 0);
        chk("C10 free_unchanged_deq", lle_free_cnt, CELL_NUM-30);
        // 全部还链 (按队列, 每队列 5 个连续 cell)
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


