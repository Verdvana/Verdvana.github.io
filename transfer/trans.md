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

    // 出队一整包: 逐 cell 发 deq_req, 用【组合】队头 pkt_tail (u_dut.u_lle.lle_qhead_pkt_tail,
    //   反映本 posedge 将被出队的队头) 决定何时停发, 避免依赖【寄存】输出 deq_pkt_tail
    //   导致的"看到尾拍时下一拍已多发一个 cell"过冲。
    //   语义: 发到并包含 pkt_tail 的那个 cell 后, 下一拍立即撤 deq_req。
    task automatic dequeue_pkt(input int qid, input [PORT_NUM-1:0] bp);
        int got_before;
        int guard;
        bit tail_fire;
        got_before = deq_q.size();
        guard = 0;
        $display("  >>> DEQ q%0d bp=%b", qid, bp);
        @(negedge clk);
        deq_queue_id_r     = qid[QID_W-1:0];
        deq_backpressure_r = bp;
        forever begin
            // 队空则停 (无 cell 可出)
            if (u_dut.u_lle.q_cell_cnt_q[qid] == 0) begin
                deq_req_r = 1'b0;
                break;
            end
            // 本拍发一个出队请求 (下一 posedge fire 当前队头)
            deq_req_r = 1'b1;
            // ★ 直接读该队列的队头 pkt_tail 寄存器 (negedge 稳定, 反映本 posedge 将
            //   被出队的队头; 避免读组合 mux lle_qhead_pkt_tail 的 delta 竞争)
            tail_fire = u_dut.u_lle.q_head_pt_q[qid];
            @(negedge clk);          // 经过 posedge: 当前队头已 fire
            if (tail_fire) begin     // 刚 fire 的是 pkt_tail → 停发, 不再多发
                deq_req_r = 1'b0;
                break;
            end
            guard++;
            if (guard > CELL_NUM*4) begin deq_req_r = 1'b0; break; end
        end
        // 等待最后 (含 tail) 出队 cell 经寄存输出被 monitor 捕获
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
