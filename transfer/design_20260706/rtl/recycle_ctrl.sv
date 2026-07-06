//============================================================================
// Module      : recycle_ctrl  (Recycle Control) —— B2 版
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   回收路径控制 (控制平面)。B2 多播模型:
//     - 单播 (recycle_req): 报文发送完成, 该 cell 立即还链 → 直接向 LLE 发
//                           lle_free_req(接空闲链尾), 并透传 queue_id 供 occ 计数--。
//     - 组播 (mcast_recycle_req): 每收到一个出端口“发完一份”的通知, 反推该端口号
//                           (由 mcast_recycle_queue_id >> Q_PER_PORT_LOG), 直接
//                           转发给 LLE 的 mc_rcy_vld/mc_rcy_port —— LLE 内部记
//                           mc_rcy_done[port]; 当所有目的端口都读完+还链, LLE 自行
//                           整帧还链并清多播槽。recycle_ctrl 不再做 ref_count 递减。
//
//   仲裁: 单播还链走 lle_free_req; 组播还链由 LLE 内部 walk 完成 (走 LLE 内部
//         recycle FIFO), 不占用 recycle_ctrl 的 lle_free_req 口。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module recycle_ctrl #(
    parameter int CELL_NUM  = 8192,
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,     // 每端口 TC 数
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,
    localparam int ADDR_W   = $clog2(CELL_NUM),
    localparam int QID_W    = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W   = $clog2(PORT_NUM-1)+1,
    localparam int Q_PER_PORT_LOG = $clog2(TC_NUM)
)(
    //------------------------------------------------------------------------
    // 时钟复位 (公共)
    //------------------------------------------------------------------------
    input  logic                  clk_core,
    input  logic                  rst_core_n,

    //------------------------------------------------------------------------
    // 与 QM 的接口 (外部, 经 MMU 顶层)
    //------------------------------------------------------------------------
    input  logic                  recycle_req,         // 单播 cell 回收请求
    input  logic [ADDR_W-1:0]     recycle_cell_addr,   // 待回收 cell 地址
    input  logic [QID_W-1:0]      recycle_queue_id,    // 单播回收 cell 所属队列号
    input  logic                  mcast_recycle_req,   // 组播回收通知(某端口发完一份)
    input  logic [ADDR_W-1:0]     mcast_recycle_addr,  // 组播待回收 cell 地址 (B2 未用, 保留)
    input  logic [QID_W-1:0]      mcast_recycle_queue_id, // 组播回收所属承载队列号 (→ 反推端口)
    output logic                  recycle_ack,         // 回收完成应答

    //------------------------------------------------------------------------
    // 与 LLE 的接口 —— 单播还链 + 组播逐端口回收转发
    //------------------------------------------------------------------------
    output logic                  lle_free_req,        // 单播还链请求
    output logic [ADDR_W-1:0]     lle_free_addr,       // 待还 cell
    output logic [QID_W-1:0]      lle_free_queue_id,   // 待还 cell 所属队列号
    input  logic                  lle_free_grant,      // 仲裁通过
    input  logic                  lle_free_done,       // 还链完成
    // 组播逐端口回收 → LLE
    output logic                  mc_rcy_vld,          // 组播回收通知有效
    output logic [PORT_W-1:0]     mc_rcy_port          // 组播回收所属出端口
);

    //========================================================================
    // 单播还链: 直接透传 (B2 组播不再共用此口)
    //========================================================================
    assign lle_free_req      = recycle_req;
    assign lle_free_addr     = recycle_cell_addr;
    assign lle_free_queue_id = recycle_queue_id;

    //========================================================================
    // 组播逐端口回收转发: 反推端口号 = 承载队列号 >> Q_PER_PORT_LOG
    //========================================================================
    logic [QID_W-1:0] mc_port_full;
    assign mc_port_full = mcast_recycle_queue_id >> Q_PER_PORT_LOG;
    assign mc_rcy_vld   = mcast_recycle_req;
    assign mc_rcy_port  = (mc_port_full < PORT_NUM[QID_W-1:0])
                          ? mc_port_full[PORT_W-1:0] : '0;

    //========================================================================
    // 回收应答: 单播还链发起当拍应答; 组播收到通知当拍即应答。
    //========================================================================
    assign recycle_ack = recycle_req | mcast_recycle_req;

endmodule