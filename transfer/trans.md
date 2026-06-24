## sram
```verilog
//============================================================================
// Module      : next_ptr_regfile  (Next-Ptr Register File) —— 已废弃(DEPRECATED)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Note        : 本寄存器堆版本已被 next_ptr_sram.sv (SRAM 实现, 1 拍读延迟) 取代,
//               LLE 现例化 next_ptr_sram。本文件仅作历史参考保留, 不再使用。
// Description : LLE 内部私有的链表指针寄存器堆 (非独立可访问块, 仅由 LLE 例化驱动)。
//               每个 cell 存一条链表节点 entry:
//                   { next_ptr[ADDR_W-1:0], pkt_head, pkt_tail }  (ENTRY_W=ADDR_W+2)
//               用寄存器 (触发器阵列) 实现, 取代单口 SRAM, 以获得:
//                 * 多读口、当拍组合可读 (无读延迟) —— 直接支撑入队/出队各 1 拍;
//                 * 同拍写两个不同地址 (每 cell 为独立寄存器) —— 入队需同拍两写;
//                 * 读写同地址 bypass —— 同拍写后读取新值, 无 RMW hazard。
//
//   读口 (组合, 读时 bypass 同拍写):
//     - 端口 A : 通用读 (free_head.next 预取 / 走链读 next)
//     - 端口 B : 队头描述符读 (q_head_entry 预取 / 出队读队头)
//   写口 (同步, 上升沿):
//     - 端口 W0 (主写): 挂链写旧队尾 next / 还链写 free_tail next
//     - 端口 W1 (辅写): 入队写新分配 cell 自身 entry {NULL, sof, eof}
//     W0/W1 正常写不同地址; 罕见同地址冲突时以 W0 优先 (仅给确定性)。
//   建链 (build): build_we 期间由 LLE build FSM 顺序写, 建成空闲单链。
//
//   规模: CELL_NUM=8192, ENTRY_W=15 -> 约 120kbit 触发器; 规模变大再评估改 SRAM。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module next_ptr_regfile #(
    parameter int ADDR_W   = 13,                 // cell 地址位宽
    parameter int CELL_NUM = 8192,               // cell 总数
    parameter int ENTRY_W  = ADDR_W + 2          // {next_ptr, pkt_head, pkt_tail}
)(
    //========================================================================
    // 时钟与复位
    //========================================================================
    input  logic                clk_core,        // 300MHz 核心时钟
    input  logic                rst_core_n,       // 异步复位, 低有效

    //========================================================================
    // 读口 A (组合): free_head.next 预取 / 走链读 next
    //========================================================================
    input  logic [ADDR_W-1:0]   ra_addr,
    output logic [ADDR_W-1:0]   ra_next_ptr,
    output logic                ra_pkt_head,
    output logic                ra_pkt_tail,

    //========================================================================
    // 读口 B (组合): q_head_entry 预取 / 出队读队头
    //========================================================================
    input  logic [ADDR_W-1:0]   rb_addr,
    output logic [ADDR_W-1:0]   rb_next_ptr,
    output logic                rb_pkt_head,
    output logic                rb_pkt_tail,

    //========================================================================
    // 写口 W0 (主写): 挂链写旧队尾 next / 还链写 free_tail next
    //========================================================================
    input  logic                w0_we,
    input  logic [ADDR_W-1:0]   w0_addr,
    input  logic [ADDR_W-1:0]   w0_next_ptr,
    input  logic                w0_pkt_head,
    input  logic                w0_pkt_tail,

    //========================================================================
    // 写口 W1 (辅写): 入队写新分配 cell 自身 entry
    //   正常与 W0 写不同地址; 罕见同地址冲突时 W0 优先
    //========================================================================
    input  logic                w1_we,
    input  logic [ADDR_W-1:0]   w1_addr,
    input  logic [ADDR_W-1:0]   w1_next_ptr,
    input  logic                w1_pkt_head,
    input  logic                w1_pkt_tail,

    //========================================================================
    // 建链口 (上电建空闲链, LLE build FSM 顺序写)
    //========================================================================
    input  logic                build_we,
    input  logic [ADDR_W-1:0]   build_addr,
    input  logic [ADDR_W-1:0]   build_next_ptr,
    input  logic                build_pkt_head,
    input  logic                build_pkt_tail
);

    //========================================================================
    // 局部参数
    //========================================================================
    localparam int PH_BIT = 1;   // pkt_head 在 entry 中的位
    localparam int PT_BIT = 0;   // pkt_tail 在 entry 中的位

    //========================================================================
    // 寄存器堆
    //   entry = { next_ptr[ENTRY_W-1:2], pkt_head[1], pkt_tail[0] }
    //========================================================================
    logic [ENTRY_W-1:0] mem_q [CELL_NUM];

    //========================================================================
    // 写数据打包
    //========================================================================
    logic [ENTRY_W-1:0] w0_entry;
    logic [ENTRY_W-1:0] w1_entry;
    logic [ENTRY_W-1:0] build_entry;

    assign w0_entry    = {w0_next_ptr,    w0_pkt_head,    w0_pkt_tail};
    assign w1_entry    = {w1_next_ptr,    w1_pkt_head,    w1_pkt_tail};
    assign build_entry = {build_next_ptr, build_pkt_head, build_pkt_tail};

    //========================================================================
    // 逐 cell 写使能与写数据选择 (组合)
    //   优先级: build > W0 > W1。每个 cell 只被命中其地址的写口更新;
    //   build 与 W0/W1 互斥 (init_done 前不接受 enq/deq/recycle)。
    //========================================================================
    logic               cell_we   [CELL_NUM];
    logic [ENTRY_W-1:0] cell_wdata[CELL_NUM];

    always_comb begin
        for (int unsigned c = 0; c < CELL_NUM; c++) begin
            if (build_we && (build_addr == c[ADDR_W-1:0])) begin
                cell_we[c]    = 1'b1;
                cell_wdata[c] = build_entry;
            end
            else if (w0_we && (w0_addr == c[ADDR_W-1:0])) begin
                cell_we[c]    = 1'b1;
                cell_wdata[c] = w0_entry;
            end
            else if (w1_we && (w1_addr == c[ADDR_W-1:0])) begin
                cell_we[c]    = 1'b1;
                cell_wdata[c] = w1_entry;
            end
            else begin
                cell_we[c]    = 1'b0;
                cell_wdata[c] = '0;
            end
        end
    end

    //========================================================================
    // 时序写 (非阻塞): 每个 mem_q[c] 仅此一处赋值。
    //   整个寄存器堆不做复位 (初值由 build FSM 写入), 避免巨大复位扇出。
    //========================================================================
    always_ff @(posedge clk_core) begin
        for (int unsigned c = 0; c < CELL_NUM; c++) begin
            if (cell_we[c])
                mem_q[c] <= cell_wdata[c];
        end
    end

    //========================================================================
    // 组合读 + 同拍写 bypass
    //   优先级与写一致: build > W0 > W1 > 存储现值。
    //========================================================================
    function automatic logic [ENTRY_W-1:0] read_entry (input logic [ADDR_W-1:0] raddr);
        if (build_we && (build_addr == raddr))
            read_entry = build_entry;
        else if (w0_we && (w0_addr == raddr))
            read_entry = w0_entry;
        else if (w1_we && (w1_addr == raddr))
            read_entry = w1_entry;
        else
            read_entry = mem_q[raddr];
    endfunction

    logic [ENTRY_W-1:0] ra_entry;
    logic [ENTRY_W-1:0] rb_entry;

    assign ra_entry    = read_entry(ra_addr);
    assign rb_entry    = read_entry(rb_addr);

    assign ra_next_ptr = ra_entry[ENTRY_W-1:2];
    assign ra_pkt_head = ra_entry[PH_BIT];
    assign ra_pkt_tail = ra_entry[PT_BIT];

    assign rb_next_ptr = rb_entry[ENTRY_W-1:2];
    assign rb_pkt_head = rb_entry[PH_BIT];
    assign rb_pkt_tail = rb_entry[PT_BIT];

endmodule

```