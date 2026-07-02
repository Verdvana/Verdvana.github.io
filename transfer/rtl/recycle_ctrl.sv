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
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,     // 每端口 TC 数
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,   // 单播 P*T + 多播 (free 链在 LLE 内)
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