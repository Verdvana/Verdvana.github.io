//============================================================================
// Module      : next_ptr_sram  (Next-Ptr SRAM Wrapper)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Description : LLE 内部私有的链表指针存储, 用单片 SRAM 实现 (取代寄存器堆)。
//               本模块为 SRAM 包装器, 内部例化 vendor 提供的 2W2R SRAM 黑盒
//               `sram_2r2w_8192x16` (8192 深 × 16 bit, 1 拍同步读, 双写口
//               WEA/WEB + 双读口 REC/RED, 含全字 WBE)。
//
//   容量匹配: CELL_NUM=8192 cells × ENTRY_W=16 bit。
//              entry = {next_ptr(NPTR_W=ADDR_W+1),pkt_head,pkt_tail} = ADDR_W+3。
//             SRAM 字宽取 16 bit (2 的幂, 便于工艺库; entry 15 bit 占低 15 位,
//             高 1 位 是留给NULL非法地址)。深度 8192 = SRAM 深度, 不需深度方向拼接。
//
//   存储/接口约定 (与 LLE 配套):
//     * Entry 宽度 ENTRY_W = ADDR_W + 2, 内容 = {next_ptr, pkt_head, pkt_tail}。
//     * 同步读 (REC/RED, 1 拍读延迟): T 拍给 ra_en/ra_addr (或 rb_en/rb_addr),
//       T+1 拍数据 ra_next_ptr/... 有效。
//     * 同步写 (WEA/WEB, 上升沿): 两个独立写口 W0/W1, 建链口 build 与 W0/W1 互斥
//       (build 走 W0 物理口)。
//     * 读后写 bypass: 若 T 拍读地址与 T 拍写地址命中, 由本包装器在 T+1 拍用
//       寄存的写数据覆盖 SRAM 返回值, 保证读到当拍最新写值 (写后立即读, 无
//       RMW hazard)。优先级: build > W0 > W1 > SRAM。
//     * 同地址 W0/W1 冲突: 包装器内部及 SRAM 内部均以 W0 优先 (调用方应避免)。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

// 仿真宏: 在本文件内 define, 确保不论上层文件/工具的编译单元如何划分,
// 下方 sram_2r2w_8192x16 内的行为模型 (always_ff/mem 存储) 总能被激活,
// 让 testbench 跑得起来。综合时把此 define 注释掉即可由 vendor SRAM 库
// 链接实际实例 (此 ifdef 块下没有 vendor 库需要的逻辑)。
`define SIM_BEHAVIOR_SRAM

module next_ptr_sram #(
    parameter int CELL_NUM = 8192,               // cell 总数 (= 1 << ADDR_W)
    localparam int ADDR_W     = $clog2(CELL_NUM),// pkt_head 在 entry 中的位
    localparam int NPTR_W     = ADDR_W + 1,      // next_ptr 位宽
    localparam int ENTRY_W    = NPTR_W + 2      // {next_ptr,pkt_head,pkt_tail}
)(
    //========================================================================
    // 时钟与复位
    //========================================================================
    input  logic                clk_core,        // 300MHz 核心时钟
    input  logic                rst_core_n,      // 异步复位, 低有效

    //========================================================================
    // 读口 A (同步, 1 拍读延迟): free_head.next 预取 / 走链读 next
    //========================================================================
    input  logic                ra_en,
    input  logic [ADDR_W-1:0]   ra_addr,
    output logic [NPTR_W-1:0]   ra_next_ptr,
    output logic                ra_pkt_head,
    output logic                ra_pkt_tail,

    //========================================================================
    // 读口 B (同步, 1 拍读延迟): q_head_entry 预取 / 出队读队头
    //========================================================================
    input  logic                rb_en,
    input  logic [ADDR_W-1:0]   rb_addr,
    output logic [NPTR_W-1:0]   rb_next_ptr,
    output logic                rb_pkt_head,
    output logic                rb_pkt_tail,

    //========================================================================
    // 写口 W0 (同步): 挂链写旧队尾 next / 还链写 free_tail next
    //========================================================================
    input  logic                w0_we,
    input  logic [ENTRY_W-1:0]  w0_wbe, //mask of entry
    input  logic [ADDR_W-1:0]   w0_addr,
    input  logic [NPTR_W-1:0]   w0_next_ptr,
    input  logic                w0_pkt_head,
    input  logic                w0_pkt_tail,

    //========================================================================
    // 写口 W1 (同步): 入队写新分配 cell 自身 entry
    //========================================================================
    input  logic                w1_we,
    input  logic [ENTRY_W-1:0]  w1_wbe, //mask of entry
    input  logic [ADDR_W-1:0]   w1_addr,
    input  logic [NPTR_W-1:0]   w1_next_ptr,
    input  logic                w1_pkt_head,
    input  logic                w1_pkt_tail,

    //========================================================================
    // 建链口 (上电建空闲链, LLE build FSM 顺序写)
    //========================================================================
    input  logic                build_we,
    input  logic [ENTRY_W-1:0]  build_wbe, //mask of entry
    input  logic [ADDR_W-1:0]   build_addr,
    input  logic [NPTR_W-1:0]   build_next_ptr,
    input  logic                build_pkt_head,
    input  logic                build_pkt_tail
);

    //========================================================================
    // 局部参数
    //========================================================================
    localparam int PH_BIT     = 1;               // pkt_head 在 entry 中的位
    localparam int PT_BIT     = 0;               // pkt_tail 在 entry 中的位
    localparam int SRAM_WIDTH = ENTRY_W;         // SRAM 字宽 (≥ ENTRY_W, 取 2 的幂)

    //========================================================================
    // 写数据打包 (ENTRY_W)
    //========================================================================
    logic [SRAM_WIDTH-1:0]    w0_entry;
    logic [SRAM_WIDTH-1:0]    w1_entry;
    logic [SRAM_WIDTH-1:0]    build_entry;
    //logic [SRAM_WIDTH-1:0] w0_entry_pad;
    //logic [SRAM_WIDTH-1:0] w1_entry_pad;
    //logic [SRAM_WIDTH-1:0] build_entry_pad;

    assign w0_entry        = {w0_next_ptr,    w0_pkt_head,    w0_pkt_tail};
    assign w1_entry        = {w1_next_ptr,    w1_pkt_head,    w1_pkt_tail};
    assign build_entry     = {build_next_ptr, build_pkt_head, build_pkt_tail};
    //assign w0_entry_pad    = {{(SRAM_WIDTH-ENTRY_W){1'b0}}, w0_entry};
    //assign w1_entry_pad    = {{(SRAM_WIDTH-ENTRY_W){1'b0}}, w1_entry};
    //assign build_entry_pad = {{(SRAM_WIDTH-ENTRY_W){1'b0}}, build_entry};

    //========================================================================
    // SRAM 物理写口聚合 (build 与 W0 互斥, 走 WEA; W1 走 WEB)
    //========================================================================
    logic                  sram_p0_we;
    logic [ADDR_W-1:0]     sram_p0_addr;
    logic [SRAM_WIDTH-1:0] sram_p0_wdata;
    logic [ENTRY_W-1:0]    sram_p0_wbe; //mask of entry

    logic                  sram_p1_we;
    logic [ADDR_W-1:0]     sram_p1_addr;
    logic [SRAM_WIDTH-1:0] sram_p1_wdata;
    logic [ENTRY_W-1:0]    sram_p1_wbe; //mask of entry

    always_comb begin
        if (build_we) begin
            sram_p0_we    = 1'b1;
            sram_p0_addr  = build_addr;
            sram_p0_wdata = build_entry;
            sram_p0_wbe   = build_wbe;
        end
        else begin
            sram_p0_we    = w0_we;
            sram_p0_addr  = w0_addr;
            sram_p0_wdata = w0_entry;
            sram_p0_wbe   = w0_wbe;
        end

        sram_p1_we    = w1_we & ~build_we;
        sram_p1_addr  = w1_addr;
        sram_p1_wdata = w1_entry;
        sram_p1_wbe   = w1_wbe;
    end

    //========================================================================
    // SRAM 例化 (2R + 2W, 1 拍同步读, 单片 CELL_NUM × SRAM_WIDTH)
    //   vendor 工艺库/Memory Compiler 提供具体实现; 本文件仅做端口连线。
    //========================================================================
    logic [SRAM_WIDTH-1:0] sram_ra_rdata;
    logic [SRAM_WIDTH-1:0] sram_rb_rdata;

    sram_2r2w_8192x16 #(
        .ADDR_W (ADDR_W),
        .DATA_W (SRAM_WIDTH)
    ) u_sram (
        .CLK       (clk_core),

        .WEA       (sram_p0_we),
        .WAA       (sram_p0_addr),
        .WDA       (sram_p0_wdata),
        .WBEA      (sram_p0_wbe),

        .WEB       (sram_p1_we),
        .WAB       (sram_p1_addr),
        .WDB       (sram_p1_wdata),
        .WBEB      (sram_p1_wbe),

        .REC       (ra_en),
        .RAC       (ra_addr),
        .RDC       (sram_ra_rdata),

        .RED       (rb_en),
        .RAD       (rb_addr),
        .RDD       (sram_rb_rdata),

        .TEST_MODE (1'b0),
        .BIST_EN   (1'b0)
    );

    //========================================================================
    // 写后立即读 bypass (1 拍): 若 T 拍读地址与 T 拍写地址命中,
    //   T+1 拍用寄存的写数据覆盖 SRAM 返回值。优先级: build > W0 > W1 > SRAM。
    //========================================================================
    //logic               ra_hit_q;
    //logic [ENTRY_W-1:0] ra_bypass_data_q;
    //logic               rb_hit_q;
    //logic [ENTRY_W-1:0] rb_bypass_data_q;
//
    //always_ff @(posedge clk_core or negedge rst_core_n) begin
    //    if (!rst_core_n) begin
    //        ra_hit_q         <= 1'b0;
    //        ra_bypass_data_q <= '0;
    //        rb_hit_q         <= 1'b0;
    //        rb_bypass_data_q <= '0;
    //    end
    //    else begin
    //        // 读口 A 命中判定 (T 拍读地址 vs T 拍写地址)
    //        ra_hit_q <= ra_en & ( (build_we & (ra_addr == build_addr))
    //                            | (w0_we    & ~build_we & (ra_addr == w0_addr))
    //                            | (w1_we    & ~build_we & (ra_addr == w1_addr)) );
    //        if (build_we && (ra_addr == build_addr))
    //            ra_bypass_data_q <= build_entry;
    //        else if (w0_we && (ra_addr == w0_addr))
    //            ra_bypass_data_q <= w0_entry;
    //        else if (w1_we && (ra_addr == w1_addr))
    //            ra_bypass_data_q <= w1_entry;
//
    //        // 读口 B
    //        rb_hit_q <= rb_en & ( (build_we & (rb_addr == build_addr))
    //                            | (w0_we    & ~build_we & (rb_addr == w0_addr))
    //                            | (w1_we    & ~build_we & (rb_addr == w1_addr)) );
    //        if (build_we && (rb_addr == build_addr))
    //            rb_bypass_data_q <= build_entry;
    //        else if (w0_we && (rb_addr == w0_addr))
    //            rb_bypass_data_q <= w0_entry;
    //        else if (w1_we && (rb_addr == w1_addr))
    //            rb_bypass_data_q <= w1_entry;
    //    end
    //end
//
    ////========================================================================
    //// 读数据输出: 同地址写命中时用 bypass 寄存的写数据, 否则取 SRAM 返回的
    ////   低 ENTRY_W 位 (写时高 (SRAM_WIDTH-ENTRY_W)=1 位 0-pad, 读出忽略)。
    ////========================================================================
    //logic [ENTRY_W-1:0] ra_sram_entry;
    //logic [ENTRY_W-1:0] rb_sram_entry;
    //logic [ENTRY_W-1:0] ra_rdata_eff;
    //logic [ENTRY_W-1:0] rb_rdata_eff;
//
    //assign ra_sram_entry = sram_ra_rdata[ENTRY_W-1:0];
    //assign rb_sram_entry = sram_rb_rdata[ENTRY_W-1:0];
//
    //assign ra_rdata_eff  = ra_hit_q ? ra_bypass_data_q : ra_sram_entry;
    //assign rb_rdata_eff  = rb_hit_q ? rb_bypass_data_q : rb_sram_entry;
//
    //assign ra_next_ptr = ra_rdata_eff[ENTRY_W-1:2];
    //assign ra_pkt_head = ra_rdata_eff[PH_BIT];
    //assign ra_pkt_tail = ra_rdata_eff[PT_BIT];
//
    //assign rb_next_ptr = rb_rdata_eff[ENTRY_W-1:2];
    //assign rb_pkt_head = rb_rdata_eff[PH_BIT];
    //assign rb_pkt_tail = rb_rdata_eff[PT_BIT];

    //========================================================================
    // 读数据输出：直接取SRAM返回的数据，不作写后读bypass
    //========================================================================
    assign ra_next_ptr = sram_ra_rdata[2+:NPTR_W];
    assign ra_pkt_head = sram_ra_rdata[PH_BIT];
    assign ra_pkt_tail = sram_ra_rdata[PT_BIT];
    assign rb_next_ptr = sram_rb_rdata[2+:NPTR_W];
    assign rb_pkt_head = sram_rb_rdata[PH_BIT];
    assign rb_pkt_tail = sram_rb_rdata[PT_BIT];


endmodule


//============================================================================
// Module      : sram_2r2w_8192x16  (Vendor SRAM Blackbox + Sim Behavior Model)
// Description : 工艺库提供的 2W2R SRAM (8192 深 × 16 bit, 1 拍同步读, 含
//               全字 WBE / TEST_MODE / BIST_EN 端口)。综合时由 vendor 库链接
//               实际实例; 仿真用编译宏 `+define+SIM_BEHAVIOR_SRAM` 打开内置
//               行为模型, 让 testbench 可执行。
//
//   参数: ADDR_W / DEPTH / DATA_W 可被例化方覆写以适配小规模仿真 (例如
//         testbench 用 ADDR_W=5/DEPTH=16); 综合时使用默认值 13/8192/16。
//
//   端口约定:
//     * CLK              : 时钟
//     * WEA/WAA/WDA/WBEA : 写口 A (上升沿写, WBEA 位选使能, 1=该 bit 写)
//     * WEB/WAB/WDB/WBEB : 写口 B (同上)
//     * REC/RAC/RDC      : 读口 C (1 拍同步读: T 拍 REC&RAC, T+1 拍 RDC)
//     * RED/RAD/RDD      : 读口 D (同上)
//     * TEST_MODE/BIST_EN: 测试/BIST 控制 (功能用时拉 0)
//     * 同地址 A/B 冲突 : A 优先 (B 先写、A 后写覆盖)
//============================================================================
module sram_2r2w_8192x16 #(
    parameter int ADDR_W = 13,
    parameter int DATA_W = 16,
    localparam int DEPTH  = 1 << ADDR_W
)(
    input  logic                CLK,

    // 写口 A
    input  logic                WEA,
    input  logic [ADDR_W-1:0]   WAA,
    input  logic [DATA_W-1:0]   WDA,
    input  logic [DATA_W-1:0]   WBEA,

    // 写口 B
    input  logic                WEB,
    input  logic [ADDR_W-1:0]   WAB,
    input  logic [DATA_W-1:0]   WDB,
    input  logic [DATA_W-1:0]   WBEB,

    // 读口 C (1 拍同步读)
    input  logic                REC,
    input  logic [ADDR_W-1:0]   RAC,
    output logic [DATA_W-1:0]   RDC,

    // 读口 D (1 拍同步读)
    input  logic                RED,
    input  logic [ADDR_W-1:0]   RAD,
    output logic [DATA_W-1:0]   RDD,

    input  logic                TEST_MODE,
    input  logic                BIST_EN
);

`ifdef SIM_BEHAVIOR_SRAM
    //------------------------------------------------------------------------
    // 仿真用行为模型 (非综合, 仅供 testbench 跑通)
    //   - 存储: DEPTH × DATA_W bit
    //   - 同步写 (上升沿): A/B 各按 WBE 做位选写; 同地址 A 优先 (B 先 / A 后覆盖)
    //   - 同步读 (1 拍延迟): T 拍 RE&RA -> T+1 拍 RDC/RDD 有效
    //------------------------------------------------------------------------
    logic [DATA_W-1:0] mem [DEPTH];

    // 同步写: B 先 / A 后 (同地址 A 优先)
    always_ff @(posedge CLK) begin
        if (WEB) begin
            for (int b = 0; b < DATA_W; b++)
                if (WBEB[b]) mem[WAB][b] <= WDB[b];
        end
        if (WEA) begin
            for (int b = 0; b < DATA_W; b++)
                if (WBEA[b]) mem[WAA][b] <= WDA[b];
        end
    end

    // 同步读 (1 拍延迟)
    logic [DATA_W-1:0] rdc_q;
    logic [DATA_W-1:0] rdd_q;

    always_ff @(posedge CLK) begin
        if (REC) rdc_q <= mem[RAC];
        if (RED) rdd_q <= mem[RAD];
    end

    assign RDC = rdc_q;
    assign RDD = rdd_q;
`else
    // 综合占位: 由 vendor 库/Memory Compiler 链接实际 SRAM 实例。
    // 仿真未开 SIM_BEHAVIOR_SRAM 宏时, 读数据为 X (黑盒)。
`endif

endmodule