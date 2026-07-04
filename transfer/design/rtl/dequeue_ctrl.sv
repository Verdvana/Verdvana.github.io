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
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,     // 每端口 TC 数
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,   // 单播 P*T + 多播 (free 链在 LLE 内)
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
    // 出队队列 → 出端口映射: egress_port = queue_id >> $clog2(TC_NUM)。
    //   单播 queue_id = port*TC_NUM + tc; 截到 PORT_NUM 范围内 (越界视为 0,
    //   多播专用队列的出端口不参与此端口背压映射)。
    //========================================================================
    localparam int    Q_PER_PORT_LOG = $clog2(TC_NUM);
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
            deq_cell_valid <= #1 1'b0;
            deq_cell_addr  <= #1 '0;
            deq_pkt_head   <= #1 1'b0;
            deq_pkt_tail   <= #1 1'b0;
        end
        else begin
            deq_cell_valid <= #1 deq_fire;
            deq_cell_addr  <= #1 lle_qhead;            // 队头地址 (当拍即给)
            deq_pkt_head   <= #1 lle_qhead_pkt_head;   // 队头描述符 (预取, 当拍可给)
            deq_pkt_tail   <= #1 lle_qhead_pkt_tail;
        end
    end

endmodule