//============================================================================
// Module      : recycle_ctrl  (Recycle Control) —— 统一还链接口版
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   回收路径控制 (控制平面)。统一还链接口:
//     QM 逐 cell 还链, 每次只给一个 cell 地址, 不区分单播/多播。
//       - recycle_req        : 还链请求
//       - recycle_cell_addr  : 待还 cell 地址
//       - recycle_queue_id   : 该 cell 所属队列号 (单播 occ 计数用; 多播命中时忽略)
//       - recycle_is_mcast   : 该 cell 是否为多播 (提示位; LLE 内部亦可靠地址匹配自判)
//       - recycle_ack        : 还链应答 (当拍组合)
//
//   多播 (零拷贝, 单槽): 一个多播 cell 发往 N 个目的端口, QM 会对该地址还链 N 次。
//     MMU 内部按 cell 做引用计数 (ref_count), 每次还链 --, 减到 0 才真正还回 free 链。
//     ref_count 逻辑在 LLE 内部实现 (复用多播槽的 mc_cells_q[]/mc_ncell_q,
//     一帧最多 MAX_MC_CELLS 个 cell, 单槽保证同一时刻只有一帧多播在飞)。
//
//   本模块只做"薄透传": 把统一还链请求直接送给 LLE, 由 LLE 判命中多播槽 / 走单播还链。
//   occupancy 的 free 事件由 LLE 在真正 push 那拍产生 (单播用其 queue_id, 多播用 MC_QID)。
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
    localparam int QID_W    = $clog2(QUEUE_NUM-1)+1
)(
    //------------------------------------------------------------------------
    // 时钟复位 (公共)
    //------------------------------------------------------------------------
    input  logic                  clk_core,
    input  logic                  rst_core_n,

    //------------------------------------------------------------------------
    // 与 QM 的统一还链接口 (外部, 经 MMU 顶层)
    //------------------------------------------------------------------------
    input  logic                  recycle_req,         // 还链请求 (单/多播统一)
    input  logic [ADDR_W-1:0]     recycle_cell_addr,   // 待回收 cell 地址
    input  logic [QID_W-1:0]      recycle_queue_id,    // 单播回收 cell 所属队列号 (多播命中时忽略)
    input  logic                  recycle_is_mcast,    // 该 cell 是否为多播 (提示位)
    output logic                  recycle_ack,         // 回收完成应答

    //------------------------------------------------------------------------
    // 与 LLE 的还链接口 (统一; ref-count 由 LLE 内部完成)
    //------------------------------------------------------------------------
    output logic                  lle_free_req,        // 还链请求
    output logic [ADDR_W-1:0]     lle_free_addr,       // 待还 cell 地址
    output logic [QID_W-1:0]      lle_free_queue_id,   // 待还 cell 所属队列号 (单播)
    output logic                  lle_free_is_mcast,   // 是否多播 (提示位)
    input  logic                  lle_free_grant,      // 仲裁通过
    input  logic                  lle_free_done        // 还链完成 (真正 push 或多播计数)
);

    //========================================================================
    // 统一还链: 直接透传给 LLE。单播/多播的区分与 ref-count 在 LLE 内部处理。
    //========================================================================
    assign lle_free_req      = recycle_req;
    assign lle_free_addr     = recycle_cell_addr;
    assign lle_free_queue_id = recycle_queue_id;
    assign lle_free_is_mcast = recycle_is_mcast;

    //========================================================================
    // 回收应答: 还链请求发起当拍即应答 (LLE 保证受理; 满时由 LLE 背压, 见 lle_free_grant)。
    //   与原设计一致: 请求当拍组合应答, 不引入额外时序。
    //========================================================================
    assign recycle_ack = recycle_req & lle_free_grant;

endmodule
