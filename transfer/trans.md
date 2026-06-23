## sram
```verilog
//============================================================================
// Module      : next_ptr_sram  (Next-Ptr SRAM Wrapper)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Description : LLE 内部私有的链表指针存储, 用 SRAM 实现 (取代寄存器堆)。
//               本模块为 SRAM 包装器, 内部例化 vendor 提供的 2W2R SRAM 黑盒
//               `sram_2r2w_256x64` (每片 256 深 × 64 bit, 1 拍同步读, 双写口
//               WEA/WEB + 双读口 REC/RED, 含全字 WBE)。
//
//   实际容量需求: CELL_NUM=8192 cells × ENTRY_W=15 bit (=ADDR_W+2)。
//   单片 SRAM 容量: 256×64。 深度拼接 8192/256 = 32 片;
//   数据位宽: 15bit 取 64bit 字宽的低 15 位 (高位 0-pad), WBE 全 1 全字写。
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

module next_ptr_sram #(
    parameter int ADDR_W   = 13,                 // cell 地址位宽
    parameter int CELL_NUM = 8192,               // cell 总数
    parameter int ENTRY_W  = ADDR_W + 2          // {next_ptr, pkt_head, pkt_tail}
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
    output logic [ADDR_W-1:0]   ra_next_ptr,
    output logic                ra_pkt_head,
    output logic                ra_pkt_tail,

    //========================================================================
    // 读口 B (同步, 1 拍读延迟): q_head_entry 预取 / 出队读队头
    //========================================================================
    input  logic                rb_en,
    input  logic [ADDR_W-1:0]   rb_addr,
    output logic [ADDR_W-1:0]   rb_next_ptr,
    output logic                rb_pkt_head,
    output logic                rb_pkt_tail,

    //========================================================================
    // 写口 W0 (同步): 挂链写旧队尾 next / 还链写 free_tail next
    //========================================================================
    input  logic                w0_we,
    input  logic [ADDR_W-1:0]   w0_addr,
    input  logic [ADDR_W-1:0]   w0_next_ptr,
    input  logic                w0_pkt_head,
    input  logic                w0_pkt_tail,

    //========================================================================
    // 写口 W1 (同步): 入队写新分配 cell 自身 entry
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
    // 局部参数 (针对 sram_2r2w_256x64 拼接 8192×15)
    //========================================================================
    localparam int PH_BIT       = 1;             // pkt_head 在 entry 中的位
    localparam int PT_BIT       = 0;             // pkt_tail 在 entry 中的位
    localparam int SRAM_DEPTH   = 256;           // 单片 SRAM 深度
    localparam int SRAM_WIDTH   = 64;            // 单片 SRAM 字宽 (位)
    localparam int SRAM_AW      = 8;             // 单片地址位宽 = log2(256)
    localparam int N_BANK       = CELL_NUM/SRAM_DEPTH;  // 8192/256 = 32 片
    localparam int BANK_W       = $clog2(N_BANK);       // = 5

    //========================================================================
    // 写数据打包 (ENTRY_W=15bit) -> 0-pad 到 SRAM_WIDTH=64bit
    //========================================================================
    logic [ENTRY_W-1:0]   w0_entry;
    logic [ENTRY_W-1:0]   w1_entry;
    logic [ENTRY_W-1:0]   build_entry;
    logic [SRAM_WIDTH-1:0] w0_entry_pad;
    logic [SRAM_WIDTH-1:0] w1_entry_pad;
    logic [SRAM_WIDTH-1:0] build_entry_pad;

    assign w0_entry        = {w0_next_ptr,    w0_pkt_head,    w0_pkt_tail};
    assign w1_entry        = {w1_next_ptr,    w1_pkt_head,    w1_pkt_tail};
    assign build_entry     = {build_next_ptr, build_pkt_head, build_pkt_tail};
    assign w0_entry_pad    = {{(SRAM_WIDTH-ENTRY_W){1'b0}}, w0_entry};
    assign w1_entry_pad    = {{(SRAM_WIDTH-ENTRY_W){1'b0}}, w1_entry};
    assign build_entry_pad = {{(SRAM_WIDTH-ENTRY_W){1'b0}}, build_entry};

    //========================================================================
    // SRAM 物理写口聚合 (build 与 W0 互斥, 走 WEA; W1 走 WEB)
    //========================================================================
    logic                  sram_p0_we;
    logic [ADDR_W-1:0]     sram_p0_addr;
    logic [SRAM_WIDTH-1:0] sram_p0_wdata;

    logic                  sram_p1_we;
    logic [ADDR_W-1:0]     sram_p1_addr;
    logic [SRAM_WIDTH-1:0] sram_p1_wdata;

    always_comb begin
        if (build_we) begin
            sram_p0_we    = 1'b1;
            sram_p0_addr  = build_addr;
            sram_p0_wdata = build_entry_pad;
        end
        else begin
            sram_p0_we    = w0_we;
            sram_p0_addr  = w0_addr;
            sram_p0_wdata = w0_entry_pad;
        end

        sram_p1_we    = w1_we & ~build_we;
        sram_p1_addr  = w1_addr;
        sram_p1_wdata = w1_entry_pad;
    end

    //========================================================================
    // 深度方向 bank 选通: 高位 BANK_W 选片, 低位 SRAM_AW 作片内地址
    //========================================================================
    logic [BANK_W-1:0]    p0_bank,  p1_bank,  ra_bank,  rb_bank;
    logic [SRAM_AW-1:0]   p0_aw,    p1_aw,    ra_aw,    rb_aw;

    assign p0_bank = sram_p0_addr[ADDR_W-1 -: BANK_W];
    assign p0_aw   = sram_p0_addr[SRAM_AW-1:0];
    assign p1_bank = sram_p1_addr[ADDR_W-1 -: BANK_W];
    assign p1_aw   = sram_p1_addr[SRAM_AW-1:0];
    assign ra_bank = ra_addr[ADDR_W-1 -: BANK_W];
    assign ra_aw   = ra_addr[SRAM_AW-1:0];
    assign rb_bank = rb_addr[ADDR_W-1 -: BANK_W];
    assign rb_aw   = rb_addr[SRAM_AW-1:0];

    //========================================================================
    // 例化 N_BANK 片 sram_2r2w_256x64, 按 bank 选通 WE/RE
    //   每片 RDC/RDD 同步 1 拍输出。包装器把 N_BANK 片读数据按上一拍命中的
    //   bank 寄存再选通输出 (与 SRAM 1 拍延迟对齐)。
    //========================================================================
    logic [SRAM_WIDTH-1:0] sram_rdc [N_BANK];   // 每片读口 C (= 读口 A) 输出
    logic [SRAM_WIDTH-1:0] sram_rdd [N_BANK];   // 每片读口 D (= 读口 B) 输出

    genvar gi;
    generate
        for (gi = 0; gi < N_BANK; gi++) begin : g_bank
            logic                  bank_we_a;
            logic [SRAM_AW-1:0]    bank_addr_a;
            logic [SRAM_WIDTH-1:0] bank_wd_a;

            logic                  bank_we_b;
            logic [SRAM_AW-1:0]    bank_addr_b;
            logic [SRAM_WIDTH-1:0] bank_wd_b;

            logic                  bank_re_c;
            logic [SRAM_AW-1:0]    bank_addr_c;

            logic                  bank_re_d;
            logic [SRAM_AW-1:0]    bank_addr_d;

            // 写端口 A: build 或 W0
            assign bank_we_a   = sram_p0_we & (p0_bank == gi[BANK_W-1:0]);
            assign bank_addr_a = p0_aw;
            assign bank_wd_a   = sram_p0_wdata;

            // 写端口 B: W1
            assign bank_we_b   = sram_p1_we & (p1_bank == gi[BANK_W-1:0]);
            assign bank_addr_b = p1_aw;
            assign bank_wd_b   = sram_p1_wdata;

            // 读端口 C: 读口 A
            assign bank_re_c   = ra_en & (ra_bank == gi[BANK_W-1:0]);
            assign bank_addr_c = ra_aw;

            // 读端口 D: 读口 B
            assign bank_re_d   = rb_en & (rb_bank == gi[BANK_W-1:0]);
            assign bank_addr_d = rb_aw;

            sram_2r2w_256x64 u_rf (
                .CLK       (clk_core),

                .WEA       (bank_we_a),
                .WAA       (bank_addr_a),
                .WDA       (bank_wd_a),
                .WBEA      ({SRAM_WIDTH{1'b1}}),

                .WEB       (bank_we_b),
                .WAB       (bank_addr_b),
                .WDB       (bank_wd_b),
                .WBEB      ({SRAM_WIDTH{1'b1}}),

                .REC       (bank_re_c),
                .RAC       (bank_addr_c),
                .RDC       (sram_rdc[gi]),

                .RED       (bank_re_d),
                .RAD       (bank_addr_d),
                .RDD       (sram_rdd[gi]),

                .TEST_MODE (1'b0),
                .BIST_EN   (1'b0)
            );
        end
    endgenerate

    //========================================================================
    // 读 bank 选通: T 拍寄存读地址的 bank 选, T+1 拍据此选通 RDC/RDD 输出
    //========================================================================
    logic [BANK_W-1:0]     ra_bank_q;
    logic [BANK_W-1:0]     rb_bank_q;
    logic [SRAM_WIDTH-1:0] sram_ra_rdata;
    logic [SRAM_WIDTH-1:0] sram_rb_rdata;

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            ra_bank_q <= '0;
            rb_bank_q <= '0;
        end
        else begin
            if (ra_en) ra_bank_q <= ra_bank;
            if (rb_en) rb_bank_q <= rb_bank;
        end
    end

    assign sram_ra_rdata = sram_rdc[ra_bank_q];
    assign sram_rb_rdata = sram_rdd[rb_bank_q];

    //========================================================================
    // 写后立即读 bypass (1 拍): 若 T 拍读地址与 T 拍写地址命中,
    //   T+1 拍用寄存的写数据覆盖 SRAM 返回值。优先级: build > W0 > W1 > SRAM。
    //========================================================================
    logic               ra_hit_q;
    logic [ENTRY_W-1:0] ra_bypass_data_q;
    logic               rb_hit_q;
    logic [ENTRY_W-1:0] rb_bypass_data_q;

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            ra_hit_q         <= 1'b0;
            ra_bypass_data_q <= '0;
            rb_hit_q         <= 1'b0;
            rb_bypass_data_q <= '0;
        end
        else begin
            // 读口 A 命中判定 (T 拍读地址 vs T 拍写地址)
            ra_hit_q <= ra_en & ( (build_we & (ra_addr == build_addr))
                                | (w0_we    & ~build_we & (ra_addr == w0_addr))
                                | (w1_we    & ~build_we & (ra_addr == w1_addr)) );
            if (build_we && (ra_addr == build_addr))
                ra_bypass_data_q <= build_entry;
            else if (w0_we && (ra_addr == w0_addr))
                ra_bypass_data_q <= w0_entry;
            else if (w1_we && (ra_addr == w1_addr))
                ra_bypass_data_q <= w1_entry;

            // 读口 B
            rb_hit_q <= rb_en & ( (build_we & (rb_addr == build_addr))
                                | (w0_we    & ~build_we & (rb_addr == w0_addr))
                                | (w1_we    & ~build_we & (rb_addr == w1_addr)) );
            if (build_we && (rb_addr == build_addr))
                rb_bypass_data_q <= build_entry;
            else if (w0_we && (rb_addr == w0_addr))
                rb_bypass_data_q <= w0_entry;
            else if (w1_we && (rb_addr == w1_addr))
                rb_bypass_data_q <= w1_entry;
        end
    end

    //========================================================================
    // 读数据输出: 同地址写命中时用 bypass 寄存的写数据, 否则取 SRAM 返回的
    //   低 ENTRY_W 位 (写时高 (64-15) 位 0-pad, 读出忽略)。
    //========================================================================
    logic [ENTRY_W-1:0] ra_sram_entry;
    logic [ENTRY_W-1:0] rb_sram_entry;
    logic [ENTRY_W-1:0] ra_rdata_eff;
    logic [ENTRY_W-1:0] rb_rdata_eff;

    assign ra_sram_entry = sram_ra_rdata[ENTRY_W-1:0];
    assign rb_sram_entry = sram_rb_rdata[ENTRY_W-1:0];

    assign ra_rdata_eff  = ra_hit_q ? ra_bypass_data_q : ra_sram_entry;
    assign rb_rdata_eff  = rb_hit_q ? rb_bypass_data_q : rb_sram_entry;

    assign ra_next_ptr = ra_rdata_eff[ENTRY_W-1:2];
    assign ra_pkt_head = ra_rdata_eff[PH_BIT];
    assign ra_pkt_tail = ra_rdata_eff[PT_BIT];

    assign rb_next_ptr = rb_rdata_eff[ENTRY_W-1:2];
    assign rb_pkt_head = rb_rdata_eff[PH_BIT];
    assign rb_pkt_tail = rb_rdata_eff[PT_BIT];

endmodule


//============================================================================
// Module      : sram_2r2w_256x64  (Vendor SRAM Blackbox + Sim Behavior Model)
// Description : 工艺库提供的 2W2R SRAM (256 深 × 64 bit, 1 拍同步读, 含全字
//               WBE / TEST_MODE / BIST_EN 端口)。本文件默认仅作占位 (综合时
//               由 vendor 库链接实际实例); 仿真用编译宏 `+define+SIM_BEHAVIOR_SRAM`
//               打开内置行为模型, 让 testbench 可执行。
//
//   端口约定:
//     * CLK              : 时钟
//     * WEA/WAA/WDA/WBEA : 写口 A (上升沿写, WBEA 字节使能, 1=该 byte 写)
//     * WEB/WAB/WDB/WBEB : 写口 B (同上)
//     * REC/RAC/RDC      : 读口 C (1 拍同步读: T 拍 REC&RAC, T+1 拍 RDC)
//     * RED/RAD/RDD      : 读口 D (同上)
//     * TEST_MODE/BIST_EN: 测试/BIST 控制 (功能用时拉 0)
//     * 同地址 A/B 冲突 : A 优先 (W1 先写、W0 后写覆盖, 与上层包装器约定一致)
//============================================================================
module sram_2r2w_256x64 (
    input  logic         CLK,

    // 写口 A
    input  logic         WEA,
    input  logic [7:0]   WAA,
    input  logic [63:0]  WDA,
    input  logic [63:0]  WBEA,

    // 写口 B
    input  logic         WEB,
    input  logic [7:0]   WAB,
    input  logic [63:0]  WDB,
    input  logic [63:0]  WBEB,

    // 读口 C (1 拍同步读)
    input  logic         REC,
    input  logic [7:0]   RAC,
    output logic [63:0]  RDC,

    // 读口 D (1 拍同步读)
    input  logic         RED,
    input  logic [7:0]   RAD,
    output logic [63:0]  RDD,

    input  logic         TEST_MODE,
    input  logic         BIST_EN
);

`ifdef SIM_BEHAVIOR_SRAM
    //------------------------------------------------------------------------
    // 仿真用行为模型 (非综合, 仅供 testbench 跑通)
    //   - 存储: 256 × 64 bit
    //   - 同步写 (上升沿): A/B 各按 WBE 做位选写; 同地址 A 优先 (B 先 / A 后覆盖)
    //   - 同步读 (1 拍延迟): T 拍 RE&RA -> T+1 拍 RDC/RDD 有效
    //------------------------------------------------------------------------
    logic [63:0] mem [256];

    // 同步写: B 先 / A 后 (同地址 A 优先)
    always_ff @(posedge CLK) begin
        if (WEB) begin
            for (int b = 0; b < 64; b++)
                if (WBEB[b]) mem[WAB][b] <= WDB[b];
        end
        if (WEA) begin
            for (int b = 0; b < 64; b++)
                if (WBEA[b]) mem[WAA][b] <= WDA[b];
        end
    end

    // 同步读 (1 拍延迟)
    logic [63:0] rdc_q;
    logic [63:0] rdd_q;

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
```

## lle
```verilog
//============================================================================
// Module      : lle  (Link-List Engine)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Description : 链表引擎 (存储访问平面) —— 核心模块。唯一访问 Next-Ptr 存储
//               (用 SRAM 实现, next_ptr_sram, 1 拍读延迟)。对三个 Ctrl 提供
//               分配/出队/还链服务并裁决写口; 持有寄存器化的:
//                 free_head/free_tail、free_nxt 预取、q_head/q_tail[QUEUE_NUM]、
//                 q_head_entry[QUEUE_NUM] 队头描述符预取、q_cell_cnt[QUEUE_NUM]。
//
//   1 拍可见地址 + SRAM 1 拍读延迟的协同:
//     * 分配地址 = free_head (寄存器, 当拍即给); 出队地址 = q_head (寄存器, 当拍即给);
//       头尾标志 = q_head_entry (寄存器, 当拍即给) —— 这些寄存器吸收 SRAM 读延迟,
//       使入队/出队对外仍是 1 拍。
//     * free_nxt / q_head_entry 的"下一项"由 SRAM 读口在前一拍发地址、本拍取回更新
//       (预取流水)。背靠背操作下, 预取在每拍发起、每拍取回, 维持 1 cell/cycle。
//     * 写口 W0(挂链/还链) + W1(新 cell entry) 双写口, 支撑入队同拍两写。
//     * 同一队列同拍"进包+出包" hazard 分三情形 (非空/单 cell/空队列)。
//
//   注: 与寄存器堆版本的差异在于 next_ptr 的"下一项"不再当拍组合可得, 而是经
//       SRAM 1 拍读延迟; 故 free_nxt/q_head_entry 的更新滞后一拍, 由预取流水补偿。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module lle #(
    parameter int ADDR_W    = 13,        // cell 地址位宽
    parameter int CELL_NUM  = 8192,      // cell 总数
    parameter int QUEUE_NUM = 34,        // 队列(chain)数
    parameter int QID_W     = 6,         // queue_id 位宽
    parameter int PORT_W    = 2,         // egress_port 位宽
    parameter int REF_W     = 3,         // 组播 ref_count 位宽
    parameter int CNT_W     = 14         // 队列/空闲计数位宽 (0~CELL_NUM)
)(
    //========================================================================
    // 时钟与复位
    //========================================================================
    input  logic                  clk_core,            // 300MHz 核心时钟
    input  logic                  rst_core_n,          // 异步复位, 低有效

    //========================================================================
    // 初始化建链接口 (与 Init FSM)
    //========================================================================
    input  logic                  init_build_req,      // 触发建空闲链
    output logic                  init_build_done,     // 建链完成

    //========================================================================
    // 入队 / 分配接口 (与 Enqueue Ctrl, 1 拍命令)
    //========================================================================
    output logic [ADDR_W-1:0]     lle_free_head,       // 可分配地址(寄存器, 当拍即给)
    output logic                  lle_free_empty,      // 空闲链空
    input  logic                  lle_alloc_fire,      // 分配+挂链命令(一拍脉冲)
    input  logic [QID_W-1:0]      lle_alloc_queue_id,  // 挂链目标队列
    input  logic [ADDR_W-1:0]     lle_alloc_addr,      // 分配地址(=lle_free_head, 仅核对)
    input  logic                  lle_set_pkt_head,    // 写 pkt_head
    input  logic                  lle_set_pkt_tail,    // 写 pkt_tail
    input  logic                  lle_alloc_is_mcast,  // 组播标志(转发写 ref_count)
    input  logic [REF_W-1:0]      lle_alloc_ref_init,  // 组播 ref_count 初值

    //========================================================================
    // 出队接口 (与 Dequeue Ctrl, 1 拍命令)
    //========================================================================
    input  logic [QID_W-1:0]      lle_deq_queue_id,    // 出队队列号
    output logic [ADDR_W-1:0]     lle_qhead,           // 队头地址(寄存器, 当拍即给)
    output logic                  lle_qhead_pkt_head,  // 队头 cell 头标志
    output logic                  lle_qhead_pkt_tail,  // 队头 cell 尾标志
    output logic                  lle_q_empty,         // 该队列空
    input  logic                  lle_deq_fire,        // 出队命令(一拍)

    //========================================================================
    // 还链接口 (与 Recycle Ctrl)
    //========================================================================
    input  logic                  lle_free_req,        // 还链请求
    input  logic [ADDR_W-1:0]     lle_free_addr,       // 待还 cell
    output logic                  lle_free_grant,      // 仲裁通过
    output logic                  lle_free_done,       // 还链完成

    //========================================================================
    // 组播 ref_count 转发接口 (与 Multicast Ref-Count Mgr)
    //========================================================================
    output logic                  mc_set_req,          // 置 ref_count 初值请求
    output logic [ADDR_W-1:0]     mc_set_addr,         // 目标组播 cell
    output logic [REF_W-1:0]      mc_set_init,         // ref_count 初值
    input  logic                  mc_set_ack,          // 写完应答(本实现不阻塞)

    //========================================================================
    // 事件上报接口 (与 Occupancy & Pool Mgr)
    //========================================================================
    output logic                  lle_alloc_evt,       // 分配事件(计数++)
    output logic                  lle_free_evt,        // 回收事件(计数--)
    output logic [QID_W-1:0]      evt_queue_id,        // 事件所属队列
    output logic [PORT_W-1:0]     evt_egress_port      // 事件所属出端口
);

    //========================================================================
    // 局部参数
    //========================================================================
    localparam int                ENTRY_W  = ADDR_W + 2;   // {next, pkt_head, pkt_tail}
    localparam logic [ADDR_W-1:0] NULL_PTR = '0;           // 空指针(链尾, 用 0 表示)
    localparam int                PH_BIT   = 1;            // pkt_head 位
    localparam int                PT_BIT   = 0;            // pkt_tail 位

    //========================================================================
    // 内部状态寄存器 (吸收 SRAM 读延迟, 保证地址/头尾当拍可给)
    //========================================================================
    logic [ADDR_W-1:0]  free_head_q;                  // 空闲链头
    logic [ADDR_W-1:0]  free_nxt_q;                   // free_head 下一项(预取)
    logic               free_nxt_vld_q;               // free_nxt 有效
    logic [ADDR_W-1:0]  free_tail_q;                  // 空闲链尾
    logic [CNT_W-1:0]   free_cnt_q;                   // 空闲 cell 数

    logic [ADDR_W-1:0]  q_head_q      [QUEUE_NUM];    // 每队列队头
    logic [ADDR_W-1:0]  q_tail_q      [QUEUE_NUM];    // 每队列队尾
    logic [CNT_W-1:0]   q_cell_cnt_q  [QUEUE_NUM];    // 每队列 cell 数
    logic [ENTRY_W-1:0] q_head_entry_q[QUEUE_NUM];    // 每队列队头描述符预取

    //========================================================================
    // Next-Ptr SRAM 互连
    //========================================================================
    logic               npr_ra_en;
    logic [ADDR_W-1:0]  npr_ra_addr;
    logic [ADDR_W-1:0]  npr_ra_next_ptr;
    logic               npr_ra_pkt_head;
    logic               npr_ra_pkt_tail;

    logic               npr_rb_en;
    logic [ADDR_W-1:0]  npr_rb_addr;
    logic [ADDR_W-1:0]  npr_rb_next_ptr;
    logic               npr_rb_pkt_head;
    logic               npr_rb_pkt_tail;

    logic               npr_w0_we;
    logic [ADDR_W-1:0]  npr_w0_addr;
    logic [ADDR_W-1:0]  npr_w0_next_ptr;
    logic               npr_w0_pkt_head;
    logic               npr_w0_pkt_tail;

    logic               npr_w1_we;
    logic [ADDR_W-1:0]  npr_w1_addr;
    logic [ADDR_W-1:0]  npr_w1_next_ptr;
    logic               npr_w1_pkt_head;
    logic               npr_w1_pkt_tail;

    logic               npr_build_we;
    logic [ADDR_W-1:0]  npr_build_addr;
    logic [ADDR_W-1:0]  npr_build_next_ptr;
    logic               npr_build_pkt_head;
    logic               npr_build_pkt_tail;

    next_ptr_sram #(
        .ADDR_W   (ADDR_W),
        .CELL_NUM (CELL_NUM),
        .ENTRY_W  (ENTRY_W)
    ) u_next_ptr_sram (
        .clk_core        (clk_core),
        .rst_core_n      (rst_core_n),
        .ra_en           (npr_ra_en),
        .ra_addr         (npr_ra_addr),
        .ra_next_ptr     (npr_ra_next_ptr),
        .ra_pkt_head     (npr_ra_pkt_head),
        .ra_pkt_tail     (npr_ra_pkt_tail),
        .rb_en           (npr_rb_en),
        .rb_addr         (npr_rb_addr),
        .rb_next_ptr     (npr_rb_next_ptr),
        .rb_pkt_head     (npr_rb_pkt_head),
        .rb_pkt_tail     (npr_rb_pkt_tail),
        .w0_we           (npr_w0_we),
        .w0_addr         (npr_w0_addr),
        .w0_next_ptr     (npr_w0_next_ptr),
        .w0_pkt_head     (npr_w0_pkt_head),
        .w0_pkt_tail     (npr_w0_pkt_tail),
        .w1_we           (npr_w1_we),
        .w1_addr         (npr_w1_addr),
        .w1_next_ptr     (npr_w1_next_ptr),
        .w1_pkt_head     (npr_w1_pkt_head),
        .w1_pkt_tail     (npr_w1_pkt_tail),
        .build_we        (npr_build_we),
        .build_addr      (npr_build_addr),
        .build_next_ptr  (npr_build_next_ptr),
        .build_pkt_head  (npr_build_pkt_head),
        .build_pkt_tail  (npr_build_pkt_tail)
    );

    //========================================================================
    // 工具函数: 出端口 = queue_id 高位 (queue_id/8)
    //========================================================================
    function automatic logic [PORT_W-1:0] qid2port (input logic [QID_W-1:0] qid);
        qid2port = qid[QID_W-1 -: PORT_W];
    endfunction

    //========================================================================
    // 建链 FSM (上电初始化空闲链 0->1->...->CELL_NUM-1)
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

    // 建链写口: entry[idx] = {idx+1 (末项=NULL), 0, 0}
    always_comb begin
        npr_build_we       = build_active;
        npr_build_addr     = build_idx_q;
        npr_build_next_ptr = (build_idx_q == CELL_NUM-1) ? NULL_PTR
                                                         : (build_idx_q + 1'b1);
        npr_build_pkt_head = 1'b0;
        npr_build_pkt_tail = 1'b0;
    end

    //========================================================================
    // 命中判定
    //========================================================================
    logic alloc_hit;   // 本拍有效分配
    logic deq_hit;     // 本拍有效出队
    logic free_hit;    // 本拍有效还链
    logic same_q;      // 同一队列同拍 enq+deq

    assign alloc_hit = lle_alloc_fire & ~build_active & ~lle_free_empty;
    assign deq_hit   = lle_deq_fire   & ~build_active;
    assign free_hit  = lle_free_req   & ~build_active;
    assign same_q    = alloc_hit & deq_hit & (lle_alloc_queue_id == lle_deq_queue_id);

    //========================================================================
    // 对外组合输出 (1 拍: 地址/头尾取寄存器, 当拍即给)
    //========================================================================
    assign lle_free_head      = free_head_q;
    assign lle_free_empty     = (free_cnt_q == '0);

    assign lle_qhead          = q_head_q[lle_deq_queue_id];
    assign lle_qhead_pkt_head = q_head_entry_q[lle_deq_queue_id][PH_BIT];
    assign lle_qhead_pkt_tail = q_head_entry_q[lle_deq_queue_id][PT_BIT];
    assign lle_q_empty        = (q_cell_cnt_q[lle_deq_queue_id] == '0);

    assign lle_free_grant     = free_hit;
    assign lle_free_done      = free_hit;

    //========================================================================
    // 组播 ref_count 转发 (分配同拍, 组播时发)
    //========================================================================
    assign mc_set_req         = alloc_hit & lle_alloc_is_mcast;
    assign mc_set_addr        = free_head_q;
    assign mc_set_init        = lle_alloc_ref_init;

    //========================================================================
    // 事件上报 Occupancy
    //========================================================================
    assign lle_alloc_evt      = alloc_hit;
    assign lle_free_evt       = free_hit;
    assign evt_queue_id       = alloc_hit ? lle_alloc_queue_id : lle_deq_queue_id;
    assign evt_egress_port    = qid2port(evt_queue_id);

    //========================================================================
    // SRAM 读口地址/使能 (组合) —— 预取流水
    //   读口 A: 分配时预取 free_nxt 的下一项 (读 NextPtr[free_nxt]),
    //           T+1 拍数据 npr_ra_next_ptr 用来更新 free_nxt_q。
    //   读口 B: 出队/同拍 same_q 非空时预取新队头 entry (读 NextPtr[new_head]),
    //           T+1 拍数据 npr_rb_* 用来更新 q_head_entry_q。
    //========================================================================
    logic [ADDR_W-1:0]  deq_new_head;          // 出队后新队头地址 (= q_head_entry.next)

    // 读口 A: 分配命中拍发起对 free_nxt 的读 (取其 next 作为新的 free_nxt)
    assign npr_ra_en   = alloc_hit;
    assign npr_ra_addr = free_nxt_q;

    // 读口 B: (普通出队 或 same_q 非空) 命中拍发起对新队头的读
    assign deq_new_head = q_head_entry_q[lle_deq_queue_id][ENTRY_W-1:2];
    assign npr_rb_en   = deq_hit;
    assign npr_rb_addr = deq_new_head;

    // SRAM T+1 拍返回的数据 (本拍可用, 对应上一拍发起的读)
    logic [ENTRY_W-1:0] ra_rdata;
    logic [ENTRY_W-1:0] rb_rdata;
    assign ra_rdata = {npr_ra_next_ptr, npr_ra_pkt_head, npr_ra_pkt_tail};
    assign rb_rdata = {npr_rb_next_ptr, npr_rb_pkt_head, npr_rb_pkt_tail};

    // 记录上一拍发起的读类型, 用于本拍把返回数据写入对应预取寄存器
    logic               ra_pend_q;             // 上一拍发起读口 A (free_nxt 预取)
    logic               rb_pend_q;             // 上一拍发起读口 B (q_head_entry 预取)
    logic [QID_W-1:0]   rb_pend_qid_q;         // 上一拍读口 B 对应的队列

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            ra_pend_q     <= 1'b0;
            rb_pend_q     <= 1'b0;
            rb_pend_qid_q <= '0;
        end
        else begin
            ra_pend_q     <= npr_ra_en;
            rb_pend_q     <= npr_rb_en;
            rb_pend_qid_q <= lle_deq_queue_id;
        end
    end

    //========================================================================
    // 写口驱动 (组合)
    //   W0 (主写): 挂链写旧队尾 next / 还链写 free_tail next
    //   W1 (辅写): 入队写新分配 cell 自身 entry {NULL, sof, eof}
    //========================================================================
    always_comb begin
        npr_w0_we       = 1'b0;
        npr_w0_addr     = '0;
        npr_w0_next_ptr = '0;
        npr_w0_pkt_head = 1'b0;
        npr_w0_pkt_tail = 1'b0;

        npr_w1_we       = 1'b0;
        npr_w1_addr     = '0;
        npr_w1_next_ptr = '0;
        npr_w1_pkt_head = 1'b0;
        npr_w1_pkt_tail = 1'b0;

        // W1: 入队写新 cell entry (新 cell 总挂队尾, next=NULL)
        if (alloc_hit) begin
            npr_w1_we       = 1'b1;
            npr_w1_addr     = free_head_q;
            npr_w1_next_ptr = NULL_PTR;
            npr_w1_pkt_head = lle_set_pkt_head;
            npr_w1_pkt_tail = lle_set_pkt_tail;
        end

        // W0: 挂链写旧队尾 next (队列原非空时) 或 还链写 free_tail next
        if (alloc_hit && (q_cell_cnt_q[lle_alloc_queue_id] != '0)) begin
            npr_w0_we       = 1'b1;
            npr_w0_addr     = q_tail_q[lle_alloc_queue_id];
            npr_w0_next_ptr = free_head_q;
            npr_w0_pkt_head = 1'b0;     // 仅改 next 语义; 走链以 q_tail 与 next 为准
            npr_w0_pkt_tail = 1'b0;
        end
        else if (free_hit) begin
            npr_w0_we       = 1'b1;
            npr_w0_addr     = free_tail_q;
            npr_w0_next_ptr = lle_free_addr;
            npr_w0_pkt_head = 1'b0;
            npr_w0_pkt_tail = 1'b0;
        end
    end

    //========================================================================
    // 状态更新 (时序)
    //========================================================================
    integer q;
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            free_head_q    <= '0;
            free_nxt_q     <= '0;
            free_nxt_vld_q <= 1'b0;
            free_tail_q    <= '0;
            free_cnt_q     <= '0;
            for (q = 0; q < QUEUE_NUM; q++) begin
                q_head_q[q]       <= '0;
                q_tail_q[q]       <= '0;
                q_cell_cnt_q[q]   <= '0;
                q_head_entry_q[q] <= '0;
            end
        end
        else if (build_st_q == ST_DONE) begin
            // 建链完成: 初始化空闲链指针/计数, 清队列
            free_head_q    <= '0;
            free_nxt_q     <= {{(ADDR_W-1){1'b0}}, 1'b1};   // = 1
            free_nxt_vld_q <= 1'b1;
            free_tail_q    <= CELL_NUM-1;
            free_cnt_q     <= CELL_NUM[CNT_W-1:0];
            for (q = 0; q < QUEUE_NUM; q++) begin
                q_head_q[q]       <= '0;
                q_tail_q[q]       <= '0;
                q_cell_cnt_q[q]   <= '0;
                q_head_entry_q[q] <= '0;
            end
        end
        else begin
            //--------------------------------------------------------------
            // 空闲链头推进 (分配 / 同拍分配+还链)
            //   free_head <- free_nxt; free_nxt 由 SRAM 预取在下一拍取回 (ra_pend_q)
            //--------------------------------------------------------------
            if (alloc_hit) begin
                free_head_q    <= free_nxt_q;
                free_nxt_vld_q <= 1'b0;        // 预取在途, 取回前置无效
                if (!free_hit)
                    free_cnt_q <= free_cnt_q - 1'b1;
                // alloc_hit && free_hit: count 净不变
            end

            // free_nxt 预取取回 (上一拍读口 A 发起, 本拍 SRAM 返回)
            if (ra_pend_q) begin
                free_nxt_q     <= ra_rdata[ENTRY_W-1:2];
                free_nxt_vld_q <= 1'b1;
            end

            //--------------------------------------------------------------
            // 空闲链尾推进 (还链)
            //--------------------------------------------------------------
            if (free_hit) begin
                free_tail_q <= lle_free_addr;
                if (!alloc_hit)
                    free_cnt_q <= free_cnt_q + 1'b1;
                if (free_cnt_q == '0 && !alloc_hit) begin
                    // 空闲链原本空: 还链 cell 成为新 free_head
                    free_head_q    <= lle_free_addr;
                    free_nxt_q     <= lle_free_addr;
                    free_nxt_vld_q <= 1'b0;     // 需下一拍重新预取
                end
            end

            //--------------------------------------------------------------
            // 队列指针/描述符更新
            //--------------------------------------------------------------
            // 入队挂尾 (空队列时新 cell 同时成队头, bypass 写 q_head_entry)
            if (alloc_hit) begin
                q_tail_q[lle_alloc_queue_id] <= free_head_q;
                if (q_cell_cnt_q[lle_alloc_queue_id] == '0) begin
                    q_head_q[lle_alloc_queue_id]       <= free_head_q;
                    q_head_entry_q[lle_alloc_queue_id] <= {NULL_PTR,
                                                           lle_set_pkt_head,
                                                           lle_set_pkt_tail};
                end
            end

            // 普通出队 (非 same_q): 队头推进到 new_head;
            //   新队头 entry 由 SRAM 预取在下一拍取回 (rb_pend_q)
            if (deq_hit && !same_q) begin
                q_head_q[lle_deq_queue_id] <= deq_new_head;
            end

            // q_head_entry 预取取回 (上一拍读口 B 发起, 本拍 SRAM 返回)
            if (rb_pend_q) begin
                q_head_entry_q[rb_pend_qid_q] <= rb_rdata;
            end

            //--------------------------------------------------------------
            // q_cell_cnt 更新 (+alloc_hit -deq_hit 代数合并)
            //   same_q 三情形 (空/单cell/非空) 计数净不变
            //--------------------------------------------------------------
            if (same_q) begin
                if (q_cell_cnt_q[lle_alloc_queue_id] == '0) begin
                    // 情形③ 空队列直通: 不挂链, 计数维持 0
                    q_cell_cnt_q[lle_alloc_queue_id] <= '0;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 1) begin
                    // 情形② 单 cell: 旧队头出走, 新 cell 成新队头兼队尾
                    q_head_q[lle_alloc_queue_id]       <= free_head_q;
                    q_tail_q[lle_alloc_queue_id]       <= free_head_q;
                    q_head_entry_q[lle_alloc_queue_id] <= {NULL_PTR,
                                                           lle_set_pkt_head,
                                                           lle_set_pkt_tail};
                    q_cell_cnt_q[lle_alloc_queue_id]   <= 1;     // 净不变
                end
                else begin
                    // 情形① 非空(>=2): 队头推进 + 队尾挂新; 计数净不变
                    //   新队头 entry 由读口 B 预取在下一拍取回 (rb_pend_q)
                    q_head_q[lle_alloc_queue_id] <= deq_new_head;
                    q_tail_q[lle_alloc_queue_id] <= free_head_q;
                end
            end
            else begin
                // 不同队列 (或仅 alloc / 仅 deq): 各自独立更新计数
                if (alloc_hit)
                    q_cell_cnt_q[lle_alloc_queue_id] <= q_cell_cnt_q[lle_alloc_queue_id] + 1'b1;
                if (deq_hit)
                    q_cell_cnt_q[lle_deq_queue_id]   <= q_cell_cnt_q[lle_deq_queue_id]   - 1'b1;
            end
        end
    end

    //========================================================================
    // 说明:
    //  1) SRAM 1 拍读延迟由 free_nxt_q / q_head_entry_q 预取寄存器吸收: 分配/出队
    //     地址与头尾取这些寄存器当拍即给; 其"下一项"在命中拍向 SRAM 发读地址,
    //     下一拍取回更新预取寄存器 (ra_pend_q / rb_pend_q)。
    //  2) free_nxt_vld_q / 预取在途标志供上层在极端背靠背时做节流参考 (本实现假设
    //     上层 Enqueue/Dequeue Ctrl 在预取未就绪时不发背靠背命令, 或 SRAM 读延迟为 1
    //     拍时预取恰好赶上)。
    //  3) same_q 空队列直通 (情形③) 时 deq 输出取本拍 enq 数据, 由上层 Ctrl 协同。
    //========================================================================

endmodule
```

```verilog
//============================================================================
// Testbench   : lle_tb
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Description : 针对 Link-List Engine (lle) 的功能验证 testbench。
//               为缩短建链时间并便于观测, 用小参数覆写:
//                 ADDR_W=5, CELL_NUM=16, QUEUE_NUM=4, QID_W=2, PORT_W=2, REF_W=3, CNT_W=5
//               覆盖以下测试场景 (每个 task 前有中文场景说明):
//                 1.  上电建链 (Init build FSM) 与初始空闲链状态
//                 2.  单队列连续入队 (背靠背分配, free_count 递减, q_cell_cnt 递增)
//                 3.  单队列连续出队 (背靠背, 走链直到 pkt_tail)
//                 4.  多队列交替入队 (不同 queue_id 互不影响)
//                 5.  入队后回收 (还链, free_count 恢复)
//                 6.  组播入队 (mc_set_req / ref_init 转发)
//                 7.  同一队列同拍 进包+出包 —— 空队列 (情形③ 直通)
//                 8.  同一队列同拍 进包+出包 —— 单 cell 队列 (情形②)
//                 9.  同一队列同拍 进包+出包 —— 非空队列 (情形①)
//                 10. 同拍 分配 + 还链 (free 链 head 推进 + tail 接还链, count 净不变)
//                 11. 空闲链耗尽 (free_count→0, lle_free_empty 拉高, alloc 被抑制)
//                 12. 守恒检查 (free_count + 全部 q_cell_cnt == CELL_NUM)
//
// 说明: 由于 lle_qhead 等输出直接接内部 q_head/q_head_entry, 检查以 free_count /
//       q_cell_cnt / lle_free_head / lle_qhead 等可见行为为主。
//============================================================================
`timescale 1ns/1ps

module lle_tb;

    //------------------------------------------------------------------------
    // 参数 (小规模, 便于快速建链与观测)
    //------------------------------------------------------------------------
    localparam int ADDR_W    = 5;
    localparam int CELL_NUM  = 16;
    localparam int QUEUE_NUM = 4;
    localparam int QID_W     = 2;
    localparam int PORT_W    = 2;
    localparam int REF_W     = 3;
    localparam int CNT_W     = 5;

    localparam time CLK_PERIOD = 10ns;  // 100MHz (仿真用)

    //------------------------------------------------------------------------
    // DUT 信号
    //------------------------------------------------------------------------
    logic                  clk_core;
    logic                  rst_core_n;

    // Enqueue
    logic [ADDR_W-1:0]     lle_free_head;
    logic                  lle_free_empty;
    logic                  lle_alloc_fire;
    logic [QID_W-1:0]      lle_alloc_queue_id;
    logic [ADDR_W-1:0]     lle_alloc_addr;
    logic                  lle_set_pkt_head;
    logic                  lle_set_pkt_tail;
    logic                  lle_alloc_is_mcast;
    logic [REF_W-1:0]      lle_alloc_ref_init;

    // Dequeue
    logic [QID_W-1:0]      lle_deq_queue_id;
    logic [ADDR_W-1:0]     lle_qhead;
    logic                  lle_qhead_pkt_head;
    logic                  lle_qhead_pkt_tail;
    logic                  lle_q_empty;
    logic                  lle_deq_fire;

    // Recycle
    logic                  lle_free_req;
    logic [ADDR_W-1:0]     lle_free_addr;
    logic                  lle_free_grant;
    logic                  lle_free_done;

    // Mcast
    logic                  mc_set_req;
    logic [ADDR_W-1:0]     mc_set_addr;
    logic [REF_W-1:0]      mc_set_init;
    logic                  mc_set_ack;

    // Init
    logic                  init_build_req;
    logic                  init_build_done;

    // Event
    logic                  lle_alloc_evt;
    logic                  lle_free_evt;
    logic [QID_W-1:0]      evt_queue_id;
    logic [PORT_W-1:0]     evt_egress_port;

    //------------------------------------------------------------------------
    // 计分
    //------------------------------------------------------------------------
    int error_cnt = 0;
    int check_cnt = 0;

    task automatic chk(input bit cond, input string msg);
        check_cnt++;
        if (!cond) begin
            error_cnt++;
            $display("[%0t] [FAIL] %s", $time, msg);
        end
        else begin
            $display("[%0t] [PASS] %s", $time, msg);
        end
    endtask

    //------------------------------------------------------------------------
    // DUT 例化
    //------------------------------------------------------------------------
    lle #(
        .ADDR_W    (ADDR_W),
        .CELL_NUM  (CELL_NUM),
        .QUEUE_NUM (QUEUE_NUM),
        .QID_W     (QID_W),
        .PORT_W    (PORT_W),
        .REF_W     (REF_W),
        .CNT_W     (CNT_W)
    ) dut (
        .clk_core           (clk_core),
        .rst_core_n         (rst_core_n),
        .lle_free_head      (lle_free_head),
        .lle_free_empty     (lle_free_empty),
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
        .init_build_req     (init_build_req),
        .init_build_done    (init_build_done),
        .lle_alloc_evt      (lle_alloc_evt),
        .lle_free_evt       (lle_free_evt),
        .evt_queue_id       (evt_queue_id),
        .evt_egress_port    (evt_egress_port)
    );

    //------------------------------------------------------------------------
    // 时钟
    //------------------------------------------------------------------------
    initial clk_core = 1'b0;
    always #(CLK_PERIOD/2) clk_core = ~clk_core;

    //------------------------------------------------------------------------
    // 默认驱动复位
    //------------------------------------------------------------------------
    task automatic drive_idle();
        lle_alloc_fire     = 1'b0;
        lle_alloc_queue_id = '0;
        lle_alloc_addr     = '0;
        lle_set_pkt_head   = 1'b0;
        lle_set_pkt_tail   = 1'b0;
        lle_alloc_is_mcast = 1'b0;
        lle_alloc_ref_init = '0;
        lle_deq_queue_id   = '0;
        lle_deq_fire       = 1'b0;
        lle_free_req       = 1'b0;
        lle_free_addr      = '0;
        mc_set_ack         = 1'b1;  // 不阻塞
    endtask

    //------------------------------------------------------------------------
    // 单拍入队 (在时钟上升沿前建立, 一拍后释放)
    //------------------------------------------------------------------------
    task automatic do_enq(input logic [QID_W-1:0] qid,
                          input logic sof, input logic eof,
                          input logic is_mc, input logic [REF_W-1:0] ref_init);
        @(negedge clk_core);
        lle_alloc_fire     = 1'b1;
        lle_alloc_queue_id = qid;
        lle_alloc_addr     = lle_free_head;
        lle_set_pkt_head   = sof;
        lle_set_pkt_tail   = eof;
        lle_alloc_is_mcast = is_mc;
        lle_alloc_ref_init = ref_init;
        @(negedge clk_core);
        lle_alloc_fire     = 1'b0;
        lle_alloc_is_mcast = 1'b0;
    endtask

    //------------------------------------------------------------------------
    // 单拍出队
    //------------------------------------------------------------------------
    task automatic do_deq(input logic [QID_W-1:0] qid);
        @(negedge clk_core);
        lle_deq_queue_id = qid;
        lle_deq_fire     = 1'b1;
        @(negedge clk_core);
        lle_deq_fire     = 1'b0;
    endtask

    //------------------------------------------------------------------------
    // 单拍还链
    //------------------------------------------------------------------------
    task automatic do_free(input logic [ADDR_W-1:0] addr);
        @(negedge clk_core);
        lle_free_req  = 1'b1;
        lle_free_addr = addr;
        @(negedge clk_core);
        lle_free_req  = 1'b0;
    endtask

    //------------------------------------------------------------------------
    // 同拍 入队(qid_e) + 出队(qid_d)
    //------------------------------------------------------------------------
    task automatic do_enq_deq(input logic [QID_W-1:0] qid_e,
                              input logic [QID_W-1:0] qid_d,
                              input logic sof, input logic eof);
        @(negedge clk_core);
        lle_alloc_fire     = 1'b1;
        lle_alloc_queue_id = qid_e;
        lle_alloc_addr     = lle_free_head;
        lle_set_pkt_head   = sof;
        lle_set_pkt_tail   = eof;
        lle_deq_queue_id   = qid_d;
        lle_deq_fire       = 1'b1;
        @(negedge clk_core);
        lle_alloc_fire     = 1'b0;
        lle_deq_fire       = 1'b0;
    endtask

    //------------------------------------------------------------------------
    // 同拍 分配(入队 qid) + 还链(addr)
    //------------------------------------------------------------------------
    task automatic do_enq_free(input logic [QID_W-1:0] qid,
                               input logic [ADDR_W-1:0] free_addr);
        @(negedge clk_core);
        lle_alloc_fire     = 1'b1;
        lle_alloc_queue_id = qid;
        lle_alloc_addr     = lle_free_head;
        lle_set_pkt_head   = 1'b1;
        lle_set_pkt_tail   = 1'b1;
        lle_free_req       = 1'b1;
        lle_free_addr      = free_addr;
        @(negedge clk_core);
        lle_alloc_fire     = 1'b0;
        lle_free_req       = 1'b0;
    endtask

    //------------------------------------------------------------------------
    // 读取内部状态的便捷函数 (层次化引用 DUT 内部信号)
    //------------------------------------------------------------------------
    function automatic int unsigned get_free_count();
        get_free_count = dut.free_cnt_q;
    endfunction
    function automatic int unsigned get_qcnt(input int q);
        get_qcnt = dut.q_cell_cnt_q[q];
    endfunction

    //========================================================================
    // 主测试流程
    //========================================================================
    initial begin
        $display("==================================================");
        $display(" LLE Testbench 开始");
        $display("==================================================");

        //--------------------------------------------------------------------
        // 场景 1: 上电建链与复位
        //   预期: 复位后建链, init_build_done 拉高; 建链完成后
        //         free_count == CELL_NUM, free_head==0, lle_free_empty==0,
        //         所有队列 q_cell_cnt==0。
        //--------------------------------------------------------------------
        drive_idle();
        rst_core_n     = 1'b0;
        init_build_req = 1'b0;
        repeat (3) @(negedge clk_core);
        rst_core_n     = 1'b1;
        @(negedge clk_core);

        // 触发建链
        init_build_req = 1'b1;
        @(negedge clk_core);
        init_build_req = 1'b0;
        // 等待建链完成 (CELL_NUM 拍 + 余量)
        wait (init_build_done == 1'b1);
        @(negedge clk_core);

        $display("--- 场景1: 上电建链 ---");
        chk(get_free_count() == CELL_NUM, "建链后 free_count == CELL_NUM");
        chk(lle_free_head == 0,           "建链后 free_head == 0");
        chk(lle_free_empty == 1'b0,       "建链后空闲链非空");
        chk(get_qcnt(0)==0 && get_qcnt(1)==0 && get_qcnt(2)==0 && get_qcnt(3)==0,
            "建链后所有队列 q_cell_cnt == 0");

        //--------------------------------------------------------------------
        // 场景 2: 单队列连续入队 (背靠背分配)
        //   对 queue 0 连续入队 3 个 cell (sof, mid, eof)。
        //   预期: free_count 减 3, q_cell_cnt[0] == 3。
        //--------------------------------------------------------------------
        $display("--- 场景2: 单队列连续入队 ---");
        do_enq(0, 1'b1, 1'b0, 1'b0, '0);   // sof
        do_enq(0, 1'b0, 1'b0, 1'b0, '0);   // mid
        do_enq(0, 1'b0, 1'b1, 1'b0, '0);   // eof
        @(negedge clk_core);
        chk(get_qcnt(0) == 3,                 "queue0 入队 3 个 cell 后 q_cell_cnt==3");
        chk(get_free_count() == CELL_NUM-3,   "入队 3 个后 free_count 减 3");

        //--------------------------------------------------------------------
        // 场景 3: 单队列连续出队 (走链直到 pkt_tail)
        //   对 queue 0 连续出队 3 个 cell。
        //   预期: q_cell_cnt[0] 回到 0, lle_q_empty 拉高。
        //--------------------------------------------------------------------
        $display("--- 场景3: 单队列连续出队 ---");
        do_deq(0);
        do_deq(0);
        do_deq(0);
        @(negedge clk_core);
        chk(get_qcnt(0) == 0, "queue0 出队 3 个后 q_cell_cnt==0");
        lle_deq_queue_id = 0;
        #1;
        chk(lle_q_empty == 1'b1, "queue0 出空后 lle_q_empty==1");

        //--------------------------------------------------------------------
        // 场景 4: 多队列交替入队 (不同 queue_id 互不影响)
        //   queue1 入 2 个, queue2 入 1 个, queue3 入 1 个。
        //   预期: 各队列计数独立正确。
        //--------------------------------------------------------------------
        $display("--- 场景4: 多队列交替入队 ---");
        do_enq(1, 1'b1, 1'b1, 1'b0, '0);
        do_enq(1, 1'b1, 1'b1, 1'b0, '0);
        do_enq(2, 1'b1, 1'b1, 1'b0, '0);
        do_enq(3, 1'b1, 1'b1, 1'b0, '0);
        @(negedge clk_core);
        chk(get_qcnt(1) == 2, "queue1 == 2");
        chk(get_qcnt(2) == 1, "queue2 == 1");
        chk(get_qcnt(3) == 1, "queue3 == 1");

        //--------------------------------------------------------------------
        // 场景 5: 入队后回收 (还链)
        //   还链 2 个 cell (地址随便取已分配范围内的, 这里用 free_head 之外的旧地址)。
        //   预期: free_count 增加 2。
        //   注: 本场景只验证 free_count 计数, 不严格跟踪具体地址归属。
        //--------------------------------------------------------------------
        $display("--- 场景5: 回收还链 ---");
        begin
            int unsigned fc_before;
            fc_before = get_free_count();
            do_free(5'd1);   // 还链地址 1
            do_free(5'd2);   // 还链地址 2
            @(negedge clk_core);
            chk(get_free_count() == fc_before + 2, "回收 2 个 cell 后 free_count 增 2");
        end

        //--------------------------------------------------------------------
        // 场景 6: 组播入队 (mc_set_req / ref_init 转发)
        //   组播入队到 queue0, ref_init=3。
        //   预期: 入队当拍 mc_set_req 拉高, mc_set_init==3, mc_set_addr==分配地址。
        //--------------------------------------------------------------------
        $display("--- 场景6: 组播入队 ---");
        @(negedge clk_core);
        lle_alloc_fire     = 1'b1;
        lle_alloc_queue_id = 0;
        lle_alloc_addr     = lle_free_head;
        lle_set_pkt_head   = 1'b1;
        lle_set_pkt_tail   = 1'b1;
        lle_alloc_is_mcast = 1'b1;
        lle_alloc_ref_init = 3'd3;
        #1;  // 组合稳定
        chk(mc_set_req == 1'b1,        "组播入队当拍 mc_set_req==1");
        chk(mc_set_init == 3'd3,       "组播 mc_set_init==3");
        chk(mc_set_addr == lle_free_head, "组播 mc_set_addr==分配地址");
        @(negedge clk_core);
        lle_alloc_fire     = 1'b0;
        lle_alloc_is_mcast = 1'b0;

        //--------------------------------------------------------------------
        // 场景 7: 同一队列同拍 进包+出包 —— 空队列 (情形③ 直通)
        //   先把 queue1 出空, 再同拍对 queue1 enq+deq。
        //   预期: 空队列直通, q_cell_cnt[1] 维持 0 (进来又出去), free_count 减 1
        //         (新 cell 被分配但等价立即出走; 本实现分配会消耗 free, 计数净不变在队列侧)。
        //--------------------------------------------------------------------
        $display("--- 场景7: 同拍进出包-空队列(情形③) ---");
        // 先出空 queue1 (场景4 入了 2 个)
        do_deq(1);
        do_deq(1);
        @(negedge clk_core);
        chk(get_qcnt(1) == 0, "queue1 先出空, q_cell_cnt==0");
        begin
            int unsigned q1_before;
            q1_before = get_qcnt(1);
            do_enq_deq(1, 1, 1'b1, 1'b1);  // 同拍 enq+deq 到空 queue1
            @(negedge clk_core);
            chk(get_qcnt(1) == q1_before, "空队列同拍进出包: q_cell_cnt 维持 0 (净不变)");
        end

        //--------------------------------------------------------------------
        // 场景 8: 同一队列同拍 进包+出包 —— 单 cell 队列 (情形②)
        //   queue2 当前有 1 个 cell, 同拍 enq+deq。
        //   预期: 旧队头出走、新 cell 成新队头兼队尾, q_cell_cnt[2] 维持 1。
        //--------------------------------------------------------------------
        $display("--- 场景8: 同拍进出包-单cell(情形②) ---");
        chk(get_qcnt(2) == 1, "queue2 当前为单 cell");
        begin
            int unsigned q2_before;
            q2_before = get_qcnt(2);
            do_enq_deq(2, 2, 1'b1, 1'b1);
            @(negedge clk_core);
            chk(get_qcnt(2) == q2_before, "单cell队列同拍进出包: q_cell_cnt 维持 1");
        end

        //--------------------------------------------------------------------
        // 场景 9: 同一队列同拍 进包+出包 —— 非空队列 >=2 (情形①)
        //   先给 queue0 入 2 个 (使 >=2), 再同拍 enq+deq。
        //   预期: 队头推进 + 队尾挂新, q_cell_cnt[0] 净不变。
        //--------------------------------------------------------------------
        $display("--- 场景9: 同拍进出包-非空>=2(情形①) ---");
        do_enq(0, 1'b1, 1'b0, 1'b0, '0);
        do_enq(0, 1'b0, 1'b1, 1'b0, '0);
        @(negedge clk_core);
        begin
            int unsigned q0_before;
            q0_before = get_qcnt(0);
            chk(q0_before >= 2, "queue0 当前 >=2 个 cell");
            do_enq_deq(0, 0, 1'b1, 1'b1);
            @(negedge clk_core);
            chk(get_qcnt(0) == q0_before, "非空队列同拍进出包: q_cell_cnt 净不变");
        end

        //--------------------------------------------------------------------
        // 场景 10: 同拍 分配 + 还链
        //   同拍对 queue3 入队 + 还链一个地址。
        //   预期: free_count 净不变 (分配 -1, 还链 +1), q_cell_cnt[3] +1。
        //--------------------------------------------------------------------
        $display("--- 场景10: 同拍分配+还链 ---");
        begin
            int unsigned fc_before, q3_before;
            fc_before = get_free_count();
            q3_before = get_qcnt(3);
            do_enq_free(3, 5'd3);   // 入队 queue3 + 还链地址 3
            @(negedge clk_core);
            chk(get_free_count() == fc_before, "同拍分配+还链: free_count 净不变");
            chk(get_qcnt(3) == q3_before + 1,  "同拍分配+还链: queue3 +1");
        end

        //--------------------------------------------------------------------
        // 场景 11: 空闲链耗尽
        //   持续入队直到 free_count==0, 检查 lle_free_empty 拉高, 之后 alloc 被抑制。
        //--------------------------------------------------------------------
        $display("--- 场景11: 空闲链耗尽 ---");
        begin
            int guard;
            guard = 0;
            while (get_free_count() > 0 && guard < CELL_NUM*2) begin
                do_enq(0, 1'b1, 1'b1, 1'b0, '0);
                guard++;
            end
            @(negedge clk_core);
            chk(get_free_count() == 0,  "持续入队后 free_count==0");
            #1;
            chk(lle_free_empty == 1'b1, "空闲链耗尽 lle_free_empty==1");
            // 再尝试入队 (应被抑制: alloc_hit=0, q_cell_cnt 不增)
            begin
                int unsigned q0_before;
                q0_before = get_qcnt(0);
                do_enq(0, 1'b1, 1'b1, 1'b0, '0);
                @(negedge clk_core);
                chk(get_qcnt(0) == q0_before, "空闲链空时入队被抑制 (q_cell_cnt 不增)");
            end
        end

        //--------------------------------------------------------------------
        // 场景 12: 守恒严格检查 (重新建链后, 用可控序列保证守恒精确成立)
        //   前序场景 5/10 用了任意固定地址还链, 会在空闲链里引入重复 cell, 破坏
        //   "free_count + Σq_cell_cnt == CELL_NUM" 的严格守恒。因此本场景先复位
        //   重新建链, 在干净状态下只做"分配 + 出队 + 用出队返回的真实地址还链"的
        //   可控序列, 任意时刻校验:
        //       free_count + Σq_cell_cnt == CELL_NUM
        //--------------------------------------------------------------------
        $display("--- 场景12: 守恒严格检查 (复位重建链) ---");
        // 复位并重新建链
        drive_idle();
        rst_core_n = 1'b0;
        repeat (3) @(negedge clk_core);
        rst_core_n = 1'b1;
        @(negedge clk_core);
        init_build_req = 1'b1;
        @(negedge clk_core);
        init_build_req = 1'b0;
        wait (init_build_done == 1'b1);
        @(negedge clk_core);

        begin
            int unsigned total0;
            total0 = get_free_count() + get_qcnt(0) + get_qcnt(1)
                                      + get_qcnt(2) + get_qcnt(3);
            chk(total0 == CELL_NUM, "重建链后守恒: free_count + Σq_cell_cnt == CELL_NUM");
        end

        // 分配 4 个 cell 到 queue0 (记录每个分配地址)
        begin
            logic [ADDR_W-1:0] alloc_addr_log [4];
            int unsigned total1;
            for (int k = 0; k < 4; k++) begin
                @(negedge clk_core);
                alloc_addr_log[k]  = lle_free_head;     // 当拍即给的分配地址
                lle_alloc_fire     = 1'b1;
                lle_alloc_queue_id = 0;
                lle_alloc_addr     = lle_free_head;
                lle_set_pkt_head   = (k == 0);
                lle_set_pkt_tail   = (k == 3);
                @(negedge clk_core);
                lle_alloc_fire     = 1'b0;
            end
            @(negedge clk_core);
            total1 = get_free_count() + get_qcnt(0) + get_qcnt(1)
                                      + get_qcnt(2) + get_qcnt(3);
            chk(total1 == CELL_NUM, "分配 4 个后守恒仍成立");
            chk(get_qcnt(0) == 4,   "分配 4 个后 queue0 == 4");

            // 出队 4 个并把出队返回的真实地址还链 (净归还到空闲链)
            for (int k = 0; k < 4; k++) begin
                logic [ADDR_W-1:0] deq_addr;
                @(negedge clk_core);
                lle_deq_queue_id = 0;
                lle_deq_fire     = 1'b1;
                deq_addr         = lle_qhead;     // 当拍队头地址
                @(negedge clk_core);
                lle_deq_fire     = 1'b0;
                // 用真实出队地址还链 (单拍)
                @(negedge clk_core);
                lle_free_req  = 1'b1;
                lle_free_addr = deq_addr;
                @(negedge clk_core);
                lle_free_req  = 1'b0;
            end
            @(negedge clk_core);

            chk(get_qcnt(0) == 0, "出队+还链 4 个后 queue0 == 0");
            chk(get_free_count() == CELL_NUM,
                "出队+还链全部后 free_count 回到 CELL_NUM (严格守恒)");
        end

        //--------------------------------------------------------------------
        // 收尾
        //--------------------------------------------------------------------
        repeat (4) @(negedge clk_core);
        $display("==================================================");
        $display(" LLE Testbench 结束: 检查 %0d 项, 失败 %0d 项",
                 check_cnt, error_cnt);
        if (error_cnt == 0)
            $display(" 结果: 全部通过 (PASS)");
        else
            $display(" 结果: 存在失败 (FAIL)");
        $display("==================================================");
        $finish;
    end

    //------------------------------------------------------------------------
    // 超时保护
    //------------------------------------------------------------------------
    initial begin
        #50000ns;
        $display("[%0t] [TIMEOUT] 仿真超时, 强制结束", $time);
        $finish;
    end

endmodule
```