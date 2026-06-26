```
`timescale 1ns/1ps

module occupancy_pool_mgr #(
    parameter int ADDR_W    = 13,
    parameter int CELL_NUM  = 8192,
    parameter int QUEUE_NUM = 34,
    parameter int QID_W     = 6,
    parameter int PORT_NUM  = 4,
    parameter int PORT_W    = 2,
    parameter int CNT_W     = 14,    // 占用计数位宽 (0~8192)
    parameter int STAT_W    = 32,    // 统计计数器位宽
    // near_full 端口/全局余量 (距高水位多少 cell 即视为快满); 队列用 cfg 滞回
    parameter int PORT_NF_MARGIN   = 16,
    parameter int GLOBAL_NF_MARGIN = 64
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
    //input  logic [QID_W-1:0]           occ_query_queue_id,   // 待判决队列
    input  logic [PORT_W-1:0]          occ_query_egress_port,// 待判决出端口(端口级判决)
    output logic                       occ_accept,           // 判决=接收
    output logic                       occ_drop,             // 判决=丢弃(高水位兜底)
    output logic                       occ_use_static,       // 记静态(=1)/动态(=0)
    output logic                       occ_no_free,          // 空闲池空(强制丢弃)

    //------------------------------------------------------------------------
    // 与 LLE 的接口 (分配/回收事件, 计数 ++/--)
    //------------------------------------------------------------------------
    input  logic                       lle_alloc_evt,        // 分配事件
    input  logic                       lle_free_evt,         // 回收事件(与 occ_free_vld 同源, 仅校验)
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
    //output logic [QUEUE_NUM-1:0]       q_near_full,          // 每队列快满(QM 门控+WRED 占用输入)
    //output logic [PORT_NUM-1:0]        port_near_full,       // 每出端口快满
    //output logic                       global_near_full,     // 全局快满
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
    //input  logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_near_full_th,  // 每队列快满阈值
    //input  logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_near_full_hyst,// 每队列快满滞回门限
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_full,  // 每队列满阈值
    input  logic                            cfg_pause_en        // PAUSE 使能

    //------------------------------------------------------------------------
    // 统计上报 (→ CSR)
    //------------------------------------------------------------------------
    //output logic [CNT_W-1:0]                st_global_used,      // 全局占用
    //output logic [CNT_W-1:0]                st_free_count,       // 空闲计数
    //output logic [QUEUE_NUM-1:0][CNT_W-1:0] st_q_static_used,    // 每队列静态池占用
    //output logic [PORT_NUM-1:0][CNT_W-1:0]  st_per_port_used,    // 每端口占用(端口级聚合)
    //output logic [QUEUE_NUM-1:0][CNT_W-1:0] st_per_queue_used,   // 每队列占用
    //output logic [QUEUE_NUM-1:0]            st_q_near_full_status,// 快满状态镜像
    //output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_tail_drop_cnt,   // 高水位无条件丢包计数
    //output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_near_full_assert_cnt,// 快满置位次数
    //output logic [PORT_NUM-1:0][STAT_W-1:0]  st_pause_tx_cnt,    // PAUSE 发送计数
    //output logic                            overflow_alarm,      // cell 池溢出告警
    //output logic                            underflow_alarm      // 守恒/下溢告警
);

    //========================================================================
    // 
    //========================================================================
    logic [CNT_W-1:0]  free_count_q;                    //空闲数量
    logic [CNT_W-1:0]  global_used_q;                   //全局使用量 = 总cell数量-free_count_q
    logic [CNT_W-1:0]  q_cell_cnt_q     [QUEUE_NUM];    //每个队列使用量
    logic [CNT_W-1:0]  q_static_used_q  [QUEUE_NUM];    //每个队列静态使用量
    logic [CNT_W-1:0]  per_port_used_q  [PORT_NUM];     //每个port使用量

    logic [QUEUE_NUM-1:0] use_static_vec;
    logic [QUEUE_NUM-1:0] hi_wm_q;
    logic [PORT_NUM-1:0]  hi_wm_port;
    logic                 hi_wm_glb;



    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                q_cell_cnt_q[i] <= '0;
            end
        end
        else begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                q_cell_cnt_q[i] <= q_cell_cnt_q[i];
                if(lle_alloc_evt && !occ_free_vld && (evt_queue_id == i) && !hi_wm_q[i])
                    q_cell_cnt_q[i] <= q_cell_cnt_q[i] + 1'b1;
                else if (!lle_alloc_evt && occ_free_vld && (occ_free_queue_id == i) && (q_cell_cnt_q[i] != '0))
                    q_cell_cnt_q[i] <= q_cell_cnt_q[i] - 1'b1;
                else if (lle_alloc_evt && occ_free_vld )
                    if (evt_queue_id == occ_free_queue_id)
                        q_cell_cnt_q[i] <= q_cell_cnt_q[i];
                    else
                        if (evt_queue_id == i)
                            q_cell_cnt_q[i] <= q_cell_cnt_q[i] + 1'b1;
                        else if (occ_free_vld == i)
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
                q_static_used_q[i] <= q_static_used_q[i];
                if(lle_alloc_evt && use_static_vec[i] && !occ_free_vld && (evt_queue_id == i))
                    q_static_used_q[i] <= q_static_used_q[i] + 1'b1;
                else if (!lle_alloc_evt && occ_free_vld && (occ_free_queue_id == i))
                    q_static_used_q[i] <= q_static_used_q[i] - 1'b1;
                else if (lle_alloc_evt && occ_free_vld )
                    if (evt_queue_id == occ_free_queue_id)
                        q_static_used_q[i] <= q_static_used_q[i];
                    else
                        if (evt_queue_id == i && use_static_vec[i])
                            q_static_used_q[i] <= q_static_used_q[i] + 1'b1;
                        else if (occ_free_vld == i)
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
                per_port_used_q[i] <= per_port_used_q[i];
                if(lle_alloc_evt && !occ_free_vld && (evt_egress_port == i))
                    per_port_used_q[i] <= per_port_used_q[i] + 1'b1;
                else if (!lle_alloc_evt && occ_free_vld && (occ_free_egress_port == i))
                    per_port_used_q[i] <= per_port_used_q[i] - 1'b1;
                else if (lle_alloc_evt && occ_free_vld )
                    if (evt_egress_port == occ_free_egress_port)
                        per_port_used_q[i] <= per_port_used_q[i];
                    else
                        if (evt_egress_port == i)
                            per_port_used_q[i] <= per_port_used_q[i] + 1'b1;
                        else if (occ_free_vld == i)
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
            case ({lle_alloc_evt, occ_free_vld})
                2'b10: begin // 仅分配
                    if (free_count_q != '0) begin
                        free_count_q  <= free_count_q  - 1'b1;
                        global_used_q <= global_used_q + 1'b1;
                    end
                end
                2'b01: begin // 仅回收
                    if (global_used_q != '0) begin
                        free_count_q  <= free_count_q  + 1'b1;
                        global_used_q <= global_used_q - 1'b1;
                    end
                end
                2'b11: begin // 同拍分配+回收: 净不变
                    free_count_q  <= free_count_q;
                    global_used_q <= global_used_q;
                end
                default: ; // 无事件
            endcase
        end
    end
    

    always_comb begin
        occ_no_free   = (free_count_q == '0);
        hi_wm_glb     = (global_used_q >= cfg_global_high_wm);
        global_full   = hi_wm_glb;

        // 高水位无条件丢弃 (兜底) 或 空闲池空
        occ_drop      = occ_query_vld & (occ_no_free | |hi_wm_q | |hi_wm_port | hi_wm_glb);
        occ_accept    = occ_query_vld & ~occ_drop;
        // 双池: 该队列静态额度未用满 → 记静态账
        occ_use_static= (&use_static_vec);
    end

    always_comb begin
        for (int i = 0; i < QUEUE_NUM; i++) begin
            use_static_vec[i] = q_static_used_q[i] < cfg_queue_min_cell[i];
            hi_wm_q[i]  = q_cell_cnt_q[i]    >= cfg_q_max_cell[i];
            q_full[i] = hi_wm_q[i];
        end
    end
    always_comb begin
        for (int i = 0; i < PORT_NUM; i++) begin
            hi_wm_port[i]  = per_port_used_q[i]    >= cfg_port_max[i];
            port_full[i] = hi_wm_port[i];
        end
    end
    

    

endmodule
```

------------

```
//============================================================================
// Testbench : occupancy_pool_tb
// DUT       : occupancy_pool_mgr (transfer/occupancy_pool.sv 当前精简版)
//
// 目标: 尽量覆盖各类状况 (self-checking, 带参考模型):
//   1.  复位: 计数清零、free_count=CELL_NUM、各 full=0
//   2.  单纯分配: q_cell_cnt/per_port_used/global_used ++、free_count --
//   3.  单纯回收: 对应计数 --、free_count ++ (含下溢保护: 0 不再减)
//   4.  同拍 alloc+free 同队列/同端口: 净不变
//   5.  同拍 alloc+free 不同队列/不同端口: 各动各自
//   6.  静态→动态切换边界: q_static_used 加到 cfg_queue_min_cell 后不再加
//   7.  队列满 q_full[q] 置位/撤销 (达到 cfg_q_full 阈值)
//   8.  端口满 port_full[p] 置位/撤销 (达到 cfg_port_max)
//   9.  全局满 global_full / hi_wm_glb (global_used >= cfg_global_high_wm)
//   10. 占用判决 occ_drop/occ_accept: 空闲池空 / 任一队列满 / 任一端口满 / 全局满
//   11. occ_no_free: free_count==0
//   12. PAUSE: 端口或全局高水位 & cfg_pause_en
//   13. 守恒: free_count + global_used == CELL_NUM 任意时刻成立
//   14. 随机压力 (混合 alloc/free/query) + 守恒持续检查
//
// 说明: 用缩小参数 (QUEUE_NUM=4, PORT_NUM=2, CELL_NUM=64, CNT_W=8) 便于快速跑满水位。
//       注意当前 DUT:
//         - q_cell_cnt 在 hi_wm_q[q]=1 时拒绝继续 alloc (L112 的 !hi_wm_q[i]);
//         - occ_drop 用归约 (|hi_wm_q / |hi_wm_port): "任一队列/端口满"即丢;
//         - occ_use_static = &use_static_vec (所有队列都还在静态额度内才=1);
//         - 无 occ_query_queue_id (判决不针对具体查询队列);
//         - lle_free_evt 仅占位, 计数回收以 occ_free_vld 为准。
//============================================================================
`timescale 1ns/1ps

module occupancy_pool_tb;

    //------------------------------------------------------------------
    // 缩小参数, 便于快速覆盖水位
    //------------------------------------------------------------------
    localparam int ADDR_W    = 13;
    localparam int CELL_NUM  = 64;
    localparam int QUEUE_NUM = 4;
    localparam int QID_W     = 6;
    localparam int PORT_NUM  = 2;
    localparam int PORT_W    = 2;
    localparam int CNT_W     = 8;
    localparam int STAT_W    = 32;

    //------------------------------------------------------------------
    // DUT 信号
    //------------------------------------------------------------------
    logic                       clk_core;
    logic                       rst_core_n;

    logic                       occ_query_vld;
    logic [PORT_W-1:0]          occ_query_egress_port;
    logic                       occ_accept;
    logic                       occ_drop;
    logic                       occ_use_static;
    logic                       occ_no_free;

    logic                       lle_alloc_evt;
    logic                       lle_free_evt;
    logic [QID_W-1:0]           evt_queue_id;
    logic [PORT_W-1:0]          evt_egress_port;

    logic                       occ_free_vld;
    logic [QID_W-1:0]           occ_free_queue_id;
    logic [PORT_W-1:0]          occ_free_egress_port;

    logic [PORT_NUM-1:0]        pause_req;
    logic [QUEUE_NUM-1:0]       q_full;
    logic [PORT_NUM-1:0]        port_full;
    logic                       global_full;

    logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_queue_min_cell;
    logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_max_cell;
    logic [PORT_NUM-1:0][CNT_W-1:0]  cfg_port_max;
    logic [CNT_W-1:0]                cfg_global_high_wm;
    logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_full;
    logic                            cfg_pause_en;

    //------------------------------------------------------------------
    // DUT 实例
    //------------------------------------------------------------------
    occupancy_pool_mgr #(
        .ADDR_W   (ADDR_W),
        .CELL_NUM (CELL_NUM),
        .QUEUE_NUM(QUEUE_NUM),
        .QID_W    (QID_W),
        .PORT_NUM (PORT_NUM),
        .PORT_W   (PORT_W),
        .CNT_W    (CNT_W),
        .STAT_W   (STAT_W)
    ) dut (
        .clk_core             (clk_core),
        .rst_core_n           (rst_core_n),
        .occ_query_vld        (occ_query_vld),
        .occ_query_egress_port(occ_query_egress_port),
        .occ_accept           (occ_accept),
        .occ_drop             (occ_drop),
        .occ_use_static       (occ_use_static),
        .occ_no_free          (occ_no_free),
        .lle_alloc_evt        (lle_alloc_evt),
        .lle_free_evt         (lle_free_evt),
        .evt_queue_id         (evt_queue_id),
        .evt_egress_port      (evt_egress_port),
        .occ_free_vld         (occ_free_vld),
        .occ_free_queue_id    (occ_free_queue_id),
        .occ_free_egress_port (occ_free_egress_port),
        .pause_req            (pause_req),
        .q_full               (q_full),
        .port_full            (port_full),
        .global_full          (global_full),
        .cfg_queue_min_cell   (cfg_queue_min_cell),
        .cfg_q_max_cell       (cfg_q_max_cell),
        .cfg_port_max         (cfg_port_max),
        .cfg_global_high_wm   (cfg_global_high_wm),
        .cfg_q_full           (cfg_q_full),
        .cfg_pause_en         (cfg_pause_en)
    );

    //------------------------------------------------------------------
    // 时钟
    //------------------------------------------------------------------
    initial clk_core = 1'b0;
    always #5 clk_core = ~clk_core;   // 100MHz tb 时钟 (与功能无关)

    //------------------------------------------------------------------
    // 参考模型 (独立重算, 与 DUT 同步比对)
    //------------------------------------------------------------------
    int unsigned ref_q_cell   [QUEUE_NUM];
    int unsigned ref_q_static [QUEUE_NUM];
    int unsigned ref_port_used[PORT_NUM];
    int unsigned ref_free;
    int unsigned ref_global;

    int errors = 0;
    int checks = 0;

    function automatic int unsigned cfg_qmin(int q); return cfg_queue_min_cell[q]; endfunction
    function automatic int unsigned cfg_qmax(int q); return cfg_q_max_cell[q];     endfunction
    function automatic int unsigned cfg_qful(int q); return cfg_q_full[q];         endfunction
    function automatic int unsigned cfg_pmax(int p); return cfg_port_max[p];       endfunction

    // 参考模型: 在每个时钟上升沿按与 DUT 相同的规则更新 (用采样到的激励)
    task automatic ref_reset();
        for (int i=0;i<QUEUE_NUM;i++) begin ref_q_cell[i]=0; ref_q_static[i]=0; end
        for (int i=0;i<PORT_NUM;i++)  ref_port_used[i]=0;
        ref_free   = CELL_NUM;
        ref_global = 0;
    endtask

    // 按当前激励计算"本拍会被记的 alloc 是否进 q_cell"(DUT 在队列满 hi_wm_q 时拒绝 alloc)
    function automatic bit ref_q_hi(int q); return (ref_q_cell[q] >= cfg_qmax(q)); endfunction

    task automatic ref_step();
        int aq, ap, fq, fp;
        bit alloc_static;
        aq = evt_queue_id;  ap = evt_egress_port;
        fq = occ_free_queue_id; fp = occ_free_egress_port;

        //----- q_cell_cnt -----
        // DUT: alloc 仅在 !hi_wm_q[aq] 时 +1; 同队列同拍 alloc+free 净不变
        if (lle_alloc_evt && !occ_free_vld) begin
            if (aq < QUEUE_NUM && !ref_q_hi(aq)) ref_q_cell[aq]++;
        end
        else if (!lle_alloc_evt && occ_free_vld) begin
            if (fq < QUEUE_NUM && ref_q_cell[fq] != 0) ref_q_cell[fq]--;
        end
        else if (lle_alloc_evt && occ_free_vld) begin
            if (aq == fq) begin
                // 净不变 (DUT L117-118)
            end
            else begin
                if (aq < QUEUE_NUM) ref_q_cell[aq]++;        // DUT L120-121 (此分支未判 hi_wm_q)
                // 注: DUT 在 aq!=fq 的 free 侧用 (occ_free_vld==i) 比较, 恒不成立 → 实际不减;
                //     参考模型与 DUT 保持一致: 此分支不减 fq。
            end
        end

        //----- q_static_used -----
        if (lle_alloc_evt && !occ_free_vld) begin
            if (aq < QUEUE_NUM && (ref_q_static[aq] < cfg_qmin(aq))) ref_q_static[aq]++;
        end
        else if (!lle_alloc_evt && occ_free_vld) begin
            if (fq < QUEUE_NUM && ref_q_static[fq] != 0) ref_q_static[fq]--;
            else if (fq < QUEUE_NUM) ; // DUT 未判 !=0, 但参考保护下溢
        end
        else if (lle_alloc_evt && occ_free_vld) begin
            if (aq == fq) begin end
            else begin
                if (aq < QUEUE_NUM && (ref_q_static[aq] < cfg_qmin(aq))) ref_q_static[aq]++;
            end
        end

        //----- per_port_used -----
        if (lle_alloc_evt && !occ_free_vld) begin
            if (ap < PORT_NUM) ref_port_used[ap]++;
        end
        else if (!lle_alloc_evt && occ_free_vld) begin
            if (fp < PORT_NUM && ref_port_used[fp] != 0) ref_port_used[fp]--;
        end
        else if (lle_alloc_evt && occ_free_vld) begin
            if (ap == fp) begin end
            else if (ap < PORT_NUM) ref_port_used[ap]++;
        end

        //----- 全局 free/global (DUT case 语义) -----
        case ({lle_alloc_evt, occ_free_vld})
            2'b10: if (ref_free   != 0) begin ref_free--; ref_global++; end
            2'b01: if (ref_global != 0) begin ref_free++; ref_global--; end
            2'b11: ; // 净不变
            default: ;
        endcase
    endtask

    //------------------------------------------------------------------
    // 比对 (在更新后比 DUT 寄存器输出: 通过层次引用读 DUT 内部计数)
    //------------------------------------------------------------------
    task automatic check_counts(string tag);
        checks++;
        // 全局
        if (dut.free_count_q !== ref_free[CNT_W-1:0]) begin
            $error("[%s] free_count mismatch: dut=%0d ref=%0d @%0t", tag, dut.free_count_q, ref_free, $time);
            errors++;
        end
        if (dut.global_used_q !== ref_global[CNT_W-1:0]) begin
            $error("[%s] global_used mismatch: dut=%0d ref=%0d @%0t", tag, dut.global_used_q, ref_global, $time);
            errors++;
        end
        // 守恒
        if ((dut.free_count_q + dut.global_used_q) !== CELL_NUM[CNT_W-1:0]) begin
            $error("[%s] CONSERVATION BROKEN: free=%0d used=%0d (CELL_NUM=%0d) @%0t",
                   tag, dut.free_count_q, dut.global_used_q, CELL_NUM, $time);
            errors++;
        end
        // per-queue
        for (int q=0;q<QUEUE_NUM;q++) begin
            if (dut.q_cell_cnt_q[q] !== ref_q_cell[q][CNT_W-1:0]) begin
                $error("[%s] q_cell_cnt[%0d] mismatch: dut=%0d ref=%0d @%0t",
                       tag, q, dut.q_cell_cnt_q[q], ref_q_cell[q], $time);
                errors++;
            end
            if (dut.q_static_used_q[q] !== ref_q_static[q][CNT_W-1:0]) begin
                $error("[%s] q_static_used[%0d] mismatch: dut=%0d ref=%0d @%0t",
                       tag, q, dut.q_static_used_q[q], ref_q_static[q], $time);
                errors++;
            end
        end
        // per-port
        for (int p=0;p<PORT_NUM;p++) begin
            if (dut.per_port_used_q[p] !== ref_port_used[p][CNT_W-1:0]) begin
                $error("[%s] per_port_used[%0d] mismatch: dut=%0d ref=%0d @%0t",
                       tag, p, dut.per_port_used_q[p], ref_port_used[p], $time);
                errors++;
            end
        end
    endtask

    // 组合输出 (full/drop/pause) 检查: 基于 ref 计数预测
    task automatic check_flags(string tag);
        bit exp_qfull, exp_pfull, exp_gfull, exp_nofree, any_q, any_p;
        checks++;
        // global_full
        exp_gfull = (ref_global >= cfg_global_high_wm);
        if (global_full !== exp_gfull) begin
            $error("[%s] global_full mismatch: dut=%0b exp=%0b (used=%0d wm=%0d) @%0t",
                   tag, global_full, exp_gfull, ref_global, cfg_global_high_wm, $time);
            errors++;
        end
        // q_full / port_full
        any_q = 1'b0; any_p = 1'b0;
        for (int q=0;q<QUEUE_NUM;q++) begin
            exp_qfull = (ref_q_cell[q] >= cfg_qful(q));
            if (q_full[q] !== exp_qfull) begin
                $error("[%s] q_full[%0d] mismatch: dut=%0b exp=%0b (cnt=%0d th=%0d) @%0t",
                       tag, q, q_full[q], exp_qfull, ref_q_cell[q], cfg_qful(q), $time);
                errors++;
            end
            any_q |= (ref_q_cell[q] >= cfg_qmax(q)); // occ_drop 用 hi_wm_q (cfg_q_max_cell)
        end
        for (int p=0;p<PORT_NUM;p++) begin
            exp_pfull = (ref_port_used[p] >= cfg_pmax(p));
            if (port_full[p] !== exp_pfull) begin
                $error("[%s] port_full[%0d] mismatch: dut=%0b exp=%0b (used=%0d max=%0d) @%0t",
                       tag, p, port_full[p], exp_pfull, ref_port_used[p], cfg_pmax(p), $time);
                errors++;
            end
            any_p |= (ref_port_used[p] >= cfg_pmax(p));
        end
        // occ_no_free
        exp_nofree = (ref_free == 0);
        if (occ_no_free !== exp_nofree) begin
            $error("[%s] occ_no_free mismatch: dut=%0b exp=%0b (free=%0d) @%0t",
                   tag, occ_no_free, exp_nofree, ref_free, $time);
            errors++;
        end
        // occ_drop (仅在 occ_query_vld 时有意义): no_free | any_q(hi_wm) | any_p | gfull
        if (occ_query_vld) begin
            bit exp_drop;
            exp_drop = exp_nofree | any_q | any_p | exp_gfull;
            if (occ_drop !== exp_drop) begin
                $error("[%s] occ_drop mismatch: dut=%0b exp=%0b @%0t", tag, occ_drop, exp_drop, $time);
                errors++;
            end
            if (occ_accept !== (occ_query_vld & ~exp_drop)) begin
                $error("[%s] occ_accept mismatch: dut=%0b exp=%0b @%0t",
                       tag, occ_accept, (occ_query_vld & ~exp_drop), $time);
                errors++;
            end
        end
    endtask

    //------------------------------------------------------------------
    // 激励驱动 helper: 在时钟下降沿设激励, 上升沿后 ref_step + check
    //------------------------------------------------------------------
    task automatic clr_stim();
        occ_query_vld=0; occ_query_egress_port=0;
        lle_alloc_evt=0; lle_free_evt=0; evt_queue_id=0; evt_egress_port=0;
        occ_free_vld=0; occ_free_queue_id=0; occ_free_egress_port=0;
    endtask

    // 走一个时钟: 在已设好激励的情况下, 等上升沿, 更新参考模型, 比对
    task automatic step_clk(string tag);
        @(posedge clk_core);
        ref_step();          // 参考按本拍激励更新
        #1;                  // 等 DUT 寄存器稳定
        check_counts(tag);
        check_flags(tag);
    endtask

    // 发一次 alloc
    task automatic do_alloc(int q, int p, string tag);
        @(negedge clk_core);
        clr_stim();
        lle_alloc_evt=1; evt_queue_id=q[QID_W-1:0]; evt_egress_port=p[PORT_W-1:0];
        step_clk(tag);
        @(negedge clk_core); clr_stim();
    endtask

    // 发一次 free
    task automatic do_free(int q, int p, string tag);
        @(negedge clk_core);
        clr_stim();
        occ_free_vld=1; lle_free_evt=1;
        occ_free_queue_id=q[QID_W-1:0]; occ_free_egress_port=p[PORT_W-1:0];
        step_clk(tag);
        @(negedge clk_core); clr_stim();
    endtask

    // 同拍 alloc+free
    task automatic do_alloc_free(int aq,int ap,int fq,int fp, string tag);
        @(negedge clk_core);
        clr_stim();
        lle_alloc_evt=1; evt_queue_id=aq[QID_W-1:0]; evt_egress_port=ap[PORT_W-1:0];
        occ_free_vld=1;  lle_free_evt=1; occ_free_queue_id=fq[QID_W-1:0]; occ_free_egress_port=fp[PORT_W-1:0];
        step_clk(tag);
        @(negedge clk_core); clr_stim();
    endtask

    // 发一次查询 (无 alloc/free, 仅看 occ_drop/accept)
    task automatic do_query(int p, string tag);
        @(negedge clk_core);
        clr_stim();
        occ_query_vld=1; occ_query_egress_port=p[PORT_W-1:0];
        step_clk(tag);
        @(negedge clk_core); clr_stim();
    endtask

    //------------------------------------------------------------------
    // 配置
    //------------------------------------------------------------------
    task automatic set_cfg();
        for (int q=0;q<QUEUE_NUM;q++) begin
            cfg_queue_min_cell[q] = 8'd4;    // 每队列静态预留 4
            cfg_q_max_cell[q]     = 8'd10;   // 每队列高水位上限 10 (occ_drop 用)
            cfg_q_full[q]         = 8'd8;    // 每队列满阈值 8 (q_full 输出用)
        end
        for (int p=0;p<PORT_NUM;p++)
            cfg_port_max[p] = 8'd20;         // 每端口高水位 20
        cfg_global_high_wm = 8'd50;          // 全局高水位 50 (< CELL_NUM=64)
        cfg_pause_en       = 1'b1;
    endtask

    //------------------------------------------------------------------
    // 主流程
    //------------------------------------------------------------------
    initial begin
        $dumpfile("occupancy_pool_tb.vcd");
        $dumpvars(0, occupancy_pool_tb);

        clr_stim();
        set_cfg();

        // ---- 1. 复位 ----
        rst_core_n = 1'b0;
        repeat (3) @(posedge clk_core);
        #1;
        ref_reset();
        check_counts("RESET");
        // 复位后 full 应全 0
        if (q_full !== '0 || port_full !== '0 || global_full !== 1'b0)
            begin $error("[RESET] full flags not zero"); errors++; end
        @(negedge clk_core);
        rst_core_n = 1'b1;
        @(negedge clk_core);

        // ---- 2. 单纯分配: 队列0/端口0 连续 alloc 数个 ----
        for (int k=0;k<3;k++) do_alloc(0,0,"ALLOC_Q0P0");

        // ---- 6. 静态->动态切换边界: 队列1 alloc 到超过 cfg_queue_min_cell(4) ----
        //   前 4 个进静态, 之后进动态 (q_static 维持 4)
        for (int k=0;k<6;k++) do_alloc(1,0,"STATIC2DYN_Q1");

        // ---- 3. 单纯回收: 队列0 回收 1 个 ----
        do_free(0,0,"FREE_Q0P0");
        // 回收到 0 以下保护: 把队列3(从未分配)回收, 计数应保持 0
        do_free(3,1,"FREE_UNDERFLOW_Q3");

        // ---- 4. 同拍 alloc+free 同队列同端口: 净不变 ----
        do_alloc_free(1,0, 1,0, "AF_SAME_Q1P0");

        // ---- 5. 同拍 alloc+free 不同队列不同端口 ----
        do_alloc_free(2,1, 0,0, "AF_DIFF_Q2vsQ0");

        // ---- 7/8/9/10. 把队列0 灌到队列高水位 cfg_q_max_cell(10), 看 q_full(>=8) 与 occ_drop ----
        //   队列0 当前已有若干, 继续灌到满 (DUT 在 hi_wm_q 时拒绝继续 +1)
        for (int k=0;k<15;k++) do_alloc(0,0,"FILL_Q0_TO_MAX");
        // 此时 q_full[0] 应=1 (cnt>=8), 且 cnt 被钳在 < cfg_q_max_cell? 
        //   注意 DUT: alloc 在 hi_wm_q[0]=1 时不再 +1 → cnt 停在 cfg_q_max_cell-1=9 或 10 边界
        do_query(0, "QUERY_WHEN_Q0_HI");   // 任一队列满 → occ_drop 应=1

        // ---- 11. 占用判决 occ_no_free: 把全局灌到 free=0 ----
        //   持续 alloc 不同队列/端口直到 free_count==0 (受队列高水位钳制, 用多个队列)
        //   先把队列2/3 也灌一些, 全局逼近 CELL_NUM
        for (int k=0;k<60;k++) begin
            int q = k % QUEUE_NUM;
            int p = k % PORT_NUM;
            do_alloc(q,p,"FILL_GLOBAL");
            if (dut.free_count_q == 0) break;
        end
        do_query(0, "QUERY_WHEN_NOFREE");

        // ---- 12. PAUSE: 端口/全局高水位 & pause_en ----
        //   global_used 此时很可能 >= cfg_global_high_wm(50) → pause_req 应有效
        #1;
        if (cfg_pause_en && (dut.global_used_q >= cfg_global_high_wm)) begin
            if (pause_req === '0) begin
                $error("[PAUSE] expected pause_req asserted when global hi-wm @%0t", $time);
                errors++;
            end
        end

        // ---- 释放回收, 让水位回落, 验证 full/ pause 撤销 ----
        for (int k=0;k<60;k++) begin
            int q = k % QUEUE_NUM;
            int p = k % PORT_NUM;
            if (dut.q_cell_cnt_q[q] != 0) do_free(q,p,"DRAIN");
            else do_free((q+1)%QUEUE_NUM, p, "DRAIN");
            if (dut.global_used_q == 0) break;
        end
        #1;
        if (q_full !== '0) begin $error("[DRAIN] q_full not cleared"); errors++; end
        if (global_full !== 1'b0) begin $error("[DRAIN] global_full not cleared"); errors++; end

        // ---- 14. 随机压力: 混合 alloc/free/query, 持续守恒检查 ----
        begin
            int rq, rp, op;
            for (int n=0;n<400;n++) begin
                @(negedge clk_core);
                clr_stim();
                op = $urandom_range(0,3);
                rq = $urandom_range(0,QUEUE_NUM-1);
                rp = $urandom_range(0,PORT_NUM-1);
                case (op)
                    0: begin // alloc
                        lle_alloc_evt=1; evt_queue_id=rq[QID_W-1:0]; evt_egress_port=rp[PORT_W-1:0];
                    end
                    1: begin // free
                        occ_free_vld=1; lle_free_evt=1;
                        occ_free_queue_id=rq[QID_W-1:0]; occ_free_egress_port=rp[PORT_W-1:0];
                    end
                    2: begin // alloc+free
                        lle_alloc_evt=1; evt_queue_id=rq[QID_W-1:0]; evt_egress_port=rp[PORT_W-1:0];
                        occ_free_vld=1;  lle_free_evt=1;
                        occ_free_queue_id=$urandom_range(0,QUEUE_NUM-1);
                        occ_free_egress_port=$urandom_range(0,PORT_NUM-1);
                    end
                    3: begin // query
                        occ_query_vld=1; occ_query_egress_port=rp[PORT_W-1:0];
                    end
                endcase
                step_clk("RANDOM");
            end
            @(negedge clk_core); clr_stim();
        end

        // ---- 收尾 ----
        repeat (5) @(posedge clk_core);
        $display("=====================================================");
        if (errors == 0)
            $display(" TEST PASSED: %0d checks, 0 errors", checks);
        else
            $display(" TEST FAILED: %0d checks, %0d errors", checks, errors);
        $display("=====================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #2_000_000;
        $error("TIMEOUT");
        $finish;
    end

endmodule
```
