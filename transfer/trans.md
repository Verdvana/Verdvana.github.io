```
//============================================================================
// Testbench : lle_tb
// Description:
//   针对 lle 模块的功能验证 testbench。
//   ★ 统一在 @(negedge clk) 进行 采样 + 驱动:
//       - 采样: 读 DUT 输出 (上一个 posedge 的 NBA 已完成, 输出稳定)
//       - 驱动: 用阻塞赋值设置 DUT 输入 (在 negedge 变化, 到下一个 posedge
//               之前保持稳定, DUT 在该 posedge 正确采样)
//     这样彻底避免与 DUT always_ff@(posedge) 在同沿的竞争。
//     等效于"驱动该模块 input 的都是寄存器输出"的硬件行为。
//
//   参数: 2 port × 2 queue/port = 4 queue + 1 free + 1 multicast = 6 chain
//         CELL_NUM = 64
//============================================================================
`timescale 1ns/1ps

module lle_tb;

    //========================================================================
    // 参数
    //========================================================================
    localparam int CELL_NUM       = 64;
    localparam int QUEUE_NUM      = 6;
    localparam int PORT_NUM       = 2;
    localparam int REF_W          = 3;
    localparam int RCY_FIFO_DEPTH = 8;

    localparam int ADDR_W  = $clog2(CELL_NUM);
    localparam int QID_W   = $clog2(QUEUE_NUM-1)+1;
    localparam int PORT_W  = $clog2(PORT_NUM-1)+1;
    localparam int CNT_W   = ADDR_W + 1;
    localparam int ENTRY_W = ADDR_W + 2;

    //========================================================================
    // 时钟与复位
    //========================================================================
    logic clk, rst_n;
    initial clk = 0;
    always #1.667 clk = ~clk;   // ~300MHz

    //========================================================================
    // DUT 输入信号 (TB 在 negedge 驱动)
    //========================================================================
    logic                  init_build_req_r;
    logic                  lle_alloc_fire_r;
    logic [QID_W-1:0]     lle_alloc_queue_id_r;
    logic [ADDR_W-1:0]    lle_alloc_addr_r;
    logic                  lle_set_pkt_head_r;
    logic                  lle_set_pkt_tail_r;
    logic                  lle_alloc_is_mcast_r;
    logic [REF_W-1:0]     lle_alloc_ref_init_r;

    logic [QID_W-1:0]     lle_deq_queue_id_r;
    logic                  lle_deq_fire_r;

    logic                  lle_free_req_r;
    logic [ADDR_W-1:0]    lle_free_addr_r;

    //========================================================================
    // DUT 输出信号
    //========================================================================
    logic                  init_build_done;
    logic [ADDR_W-1:0]    lle_free_head;
    logic                  lle_free_empty;
    logic                  lle_alloc_ready;

    logic [ADDR_W-1:0]    lle_qhead;
    logic                  lle_qhead_pkt_head, lle_qhead_pkt_tail;
    logic                  lle_q_empty;

    logic                  lle_free_grant, lle_free_done;

    logic                  mc_set_req;
    logic [ADDR_W-1:0]    mc_set_addr;
    logic [REF_W-1:0]     mc_set_init;
    logic                  mc_set_ack;

    logic                  lle_alloc_evt, lle_free_evt;
    logic [QID_W-1:0]     evt_queue_id;
    logic [PORT_W-1:0]    evt_egress_port;

    assign mc_set_ack = 1'b1;

    //========================================================================
    // DUT 例化
    //========================================================================
    lle #(
        .CELL_NUM       (CELL_NUM),
        .QUEUE_NUM      (QUEUE_NUM),
        .PORT_NUM       (PORT_NUM),
        .REF_W          (REF_W),
        .RCY_FIFO_DEPTH (RCY_FIFO_DEPTH)
    ) u_dut (
        .clk_core           (clk),
        .rst_core_n         (rst_n),
        .init_build_req     (init_build_req_r),
        .init_build_done    (init_build_done),
        .lle_free_head      (lle_free_head),
        .lle_free_empty     (lle_free_empty),
        .lle_alloc_ready    (lle_alloc_ready),
        .lle_alloc_fire     (lle_alloc_fire_r),
        .lle_alloc_queue_id (lle_alloc_queue_id_r),
        .lle_alloc_addr     (lle_alloc_addr_r),
        .lle_set_pkt_head   (lle_set_pkt_head_r),
        .lle_set_pkt_tail   (lle_set_pkt_tail_r),
        .lle_alloc_is_mcast (lle_alloc_is_mcast_r),
        .lle_alloc_ref_init (lle_alloc_ref_init_r),
        .lle_deq_queue_id   (lle_deq_queue_id_r),
        .lle_qhead          (lle_qhead),
        .lle_qhead_pkt_head (lle_qhead_pkt_head),
        .lle_qhead_pkt_tail (lle_qhead_pkt_tail),
        .lle_q_empty        (lle_q_empty),
        .lle_deq_fire       (lle_deq_fire_r),
        .lle_free_req       (lle_free_req_r),
        .lle_free_addr      (lle_free_addr_r),
        .lle_free_grant     (lle_free_grant),
        .lle_free_done      (lle_free_done),
        .mc_set_req         (mc_set_req),
        .mc_set_addr        (mc_set_addr),
        .mc_set_init        (mc_set_init),
        .mc_set_ack         (mc_set_ack),
        .lle_alloc_evt      (lle_alloc_evt),
        .lle_free_evt       (lle_free_evt),
        .evt_queue_id       (evt_queue_id),
        .evt_egress_port    (evt_egress_port)
    );

    //========================================================================
    // 辅助 task: 打印状态
    //========================================================================
    task automatic print_status(string tag);
        integer qi;
        $display("──── [%0t] %s ────", $time, tag);
        $display("  free: head=%0d tail=%0d cnt=%0d empty=%0b",
                 u_dut.free_head_q, u_dut.free_tail_q, u_dut.free_cnt_q, lle_free_empty);
        $display("  free_head_next=%0d  free_head_next2=%0d",
                 u_dut.free_head_next_q, u_dut.free_head_next2_q);
        for (qi = 0; qi < QUEUE_NUM; qi++) begin
            if (u_dut.q_cell_cnt_q[qi] != 0)
                $display("  q[%0d]: head=%0d tail=%0d cnt=%0d next=%0d(ph=%0b,pt=%0b) next2=%0d  head_ph=%0b head_pt=%0b",
                         qi, u_dut.q_head_q[qi], u_dut.q_tail_q[qi], u_dut.q_cell_cnt_q[qi],
                         u_dut.q_head_next_q[qi], u_dut.q_head_next_ph_q[qi], u_dut.q_head_next_pt_q[qi],
                         u_dut.q_head_next2_q[qi],
                         u_dut.q_head_ph_q[qi], u_dut.q_head_pt_q[qi]);
        end
        $display("  rcy FIFO: cnt=%0d", u_dut.rcy_fifo_cnt_q);
        $display("");
    endtask

    //========================================================================
    // 辅助 task: 入队一整包
    //   全程在 negedge 操作: negedge 采样 ready, negedge 驱动 fire
    //========================================================================
    task automatic enqueue_pkt(input int qid, input int num_cells, input bit is_mcast, input int ref_init);
        integer i;
        int alloc_cnt;
        alloc_cnt = 0;
        $display("[%0t] >>> ENQ start: q=%0d cells=%0d mcast=%0b", $time, qid, num_cells, is_mcast);
        for (i = 0; i < num_cells; i++) begin
            @(negedge clk);
            while (!lle_alloc_ready) @(negedge clk);
            // negedge: 驱动 fire=1, 保持到下个 posedge (DUT 采样)
            lle_alloc_fire_r     = 1'b1;
            lle_alloc_queue_id_r = qid[QID_W-1:0];
            lle_alloc_addr_r     = lle_free_head;
            lle_set_pkt_head_r   = (i == 0);
            lle_set_pkt_tail_r   = (i == num_cells-1);
            lle_alloc_is_mcast_r = is_mcast;
            lle_alloc_ref_init_r = ref_init[REF_W-1:0];
            alloc_cnt++;
        end
        @(negedge clk);
        lle_alloc_fire_r = 1'b0;
        // 等 2 拍让 pend pipeline 完成
        repeat (2) @(negedge clk);
        $display("[%0t] <<< ENQ done: q=%0d cells=%0d (took %0d cycles fire)", $time, qid, num_cells, alloc_cnt);
        print_status($sformatf("after enq q%0d %0d-cell pkt", qid, num_cells));
    endtask

    //========================================================================
    // 辅助 task: 出队一整包 (背靠背, 每拍 1 cell, 直到 pkt_tail)
    //   ★ 关键: 出队的 cell = posedge 当拍的 lle_qhead (推进前的值),
    //     与 dequeue_ctrl 在 posedge 锁存 lle_qhead 的行为一致。
    //   时序:
    //     - negedge 驱动 fire/queue_id (寄存器输出, 到 posedge 稳定)
    //     - posedge Active 区采样 lle_qhead (NBA 推进前 = 本拍出队的 cell)
    //========================================================================
    task automatic dequeue_pkt(input int qid);
        integer cnt;
        cnt = 0;
        $display("[%0t] >>> DEQ start: q=%0d", $time, qid);

        // negedge: 驱动 queue_id, fire 暂 0
        @(negedge clk);
        lle_deq_queue_id_r = qid[QID_W-1:0];
        lle_deq_fire_r     = 1'b0;
        // 再等 1 个 negedge: queue_id 经过 posedge 生效, 输出稳定
        @(negedge clk);

        // 队列空则直接退出
        if (lle_q_empty) begin
            $display("[%0t]   DEQ: queue %0d empty, abort", $time, qid);
            lle_deq_fire_r = 1'b0;
            repeat (2) @(negedge clk);
            $display("[%0t] <<< DEQ done: q=%0d cells=0", $time, qid);
            return;
        end

        // negedge: 拉高 fire (寄存器输出, 到下个 posedge 稳定)
        lle_deq_fire_r = 1'b1;

        // 背靠背出队循环: 每个 posedge 出 1 个 cell
        forever begin
            @(posedge clk);   // DUT 在此 posedge 处理 deq
            // Active 区读 lle_qhead = 推进前的队头 = 本拍出队的 cell
            $display("[%0t]   DEQ cell: addr=%0d ph=%0b pt=%0b", $time,
                     lle_qhead, lle_qhead_pkt_head, lle_qhead_pkt_tail);
            cnt++;

            if (lle_qhead_pkt_tail) begin
                // 本拍是最后一个 cell, fire 已在本 posedge 完成最后 deq
                @(negedge clk);
                lle_deq_fire_r = 1'b0;
                break;
            end
            // fire 保持 1, 下个 posedge 继续出队
        end

        lle_deq_fire_r = 1'b0;
        // 等 2 拍让 pend pipeline 完成
        repeat (2) @(negedge clk);
        $display("[%0t] <<< DEQ done: q=%0d cells=%0d", $time, qid, cnt);
        print_status($sformatf("after deq q%0d", qid));
    endtask

    //========================================================================
    // 辅助 task: 还链 N 个 cell
    //========================================================================
    task automatic recycle_cells(input int cells[$]);
        integer i;
        $display("[%0t] >>> RCY start: %0d cells", $time, cells.size());
        for (i = 0; i < cells.size(); i++) begin
            @(negedge clk);
            lle_free_req_r  = 1'b1;
            lle_free_addr_r = cells[i][ADDR_W-1:0];
        end
        @(negedge clk);
        lle_free_req_r = 1'b0;
        repeat (cells.size() + 3) @(negedge clk);
        $display("[%0t] <<< RCY done: %0d cells", $time, cells.size());
        print_status($sformatf("after rcy %0d cells", cells.size()));
    endtask

    //========================================================================
    // 辅助 task: 同时入队 + 走链 (覆盖仲裁冲突)
    //========================================================================
    task automatic enq_and_deq_concurrent(input int enq_qid, input int enq_cells,
                                          input int deq_qid);
        integer ei;
        bit deq_done;
        ei = 0;
        deq_done = 0;
        $display("[%0t] >>> CONCURRENT: enq q%0d %0d cells + deq q%0d", $time, enq_qid, enq_cells, deq_qid);

        @(negedge clk);
        lle_deq_queue_id_r = deq_qid[QID_W-1:0];
        @(negedge clk);  // queue_id 生效

        while (ei < enq_cells || !deq_done) begin
            // 在 negedge: 先采样, 再驱动
            // enq 驱动
            if (ei < enq_cells && lle_alloc_ready) begin
                lle_alloc_fire_r     = 1'b1;
                lle_alloc_queue_id_r = enq_qid[QID_W-1:0];
                lle_alloc_addr_r     = lle_free_head;
                lle_set_pkt_head_r   = (ei == 0);
                lle_set_pkt_tail_r   = (ei == enq_cells-1);
                lle_alloc_is_mcast_r = 1'b0;
                lle_alloc_ref_init_r = '0;
                ei++;
            end
            else begin
                lle_alloc_fire_r = 1'b0;
            end

            // deq 驱动
            if (!deq_done && !lle_q_empty) begin
                lle_deq_fire_r = 1'b1;
                $display("[%0t]   CONC DEQ: addr=%0d pt=%0b | ENQ ei=%0d ready=%0b",
                         $time, lle_qhead, lle_qhead_pkt_tail, ei, lle_alloc_ready);
                if (lle_qhead_pkt_tail) deq_done = 1;
            end
            else begin
                lle_deq_fire_r = 1'b0;
                if (!deq_done && lle_q_empty) deq_done = 1;
            end

            @(negedge clk);  // 经过 posedge, DUT 处理, 到下个 negedge 采样
        end
        lle_alloc_fire_r = 1'b0;
        lle_deq_fire_r   = 1'b0;
        repeat (4) @(negedge clk);
        $display("[%0t] <<< CONCURRENT done", $time);
        print_status("after concurrent enq+deq");
    endtask

    //========================================================================
    // 主测试序列
    //========================================================================
    initial begin
        rst_n = 0;
        init_build_req_r     = 0;
        lle_alloc_fire_r     = 0;
        lle_alloc_queue_id_r = 0;
        lle_alloc_addr_r     = 0;
        lle_set_pkt_head_r   = 0;
        lle_set_pkt_tail_r   = 0;
        lle_alloc_is_mcast_r = 0;
        lle_alloc_ref_init_r = 0;
        lle_deq_queue_id_r   = 0;
        lle_deq_fire_r       = 0;
        lle_free_req_r       = 0;
        lle_free_addr_r      = 0;

        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        //---- 1. 建链 ----
        $display("\n========== BUILD FREE LIST ==========");
        @(negedge clk);
        init_build_req_r = 1'b1;
        @(negedge clk);
        init_build_req_r = 1'b0;
        while (!init_build_done) @(negedge clk);
        @(negedge clk);
        print_status("after build");

        //---- 2. q0 入队 4 cell ----
        enqueue_pkt(0, 4, 0, 0);

        //---- 3. q1 入队 5 cell ----
        enqueue_pkt(1, 5, 0, 0);

        //---- 4. q1 入队 6 cell ----
        enqueue_pkt(1, 6, 0, 0);

        //---- 5. q0 入队 2 cell ----
        enqueue_pkt(0, 2, 0, 0);

        //---- 6. q0 入队 7 cell ----
        enqueue_pkt(0, 7, 0, 0);

        //---- 7. q2 入队 10 cell (多播队列, qid=4, ref=2) ----
        enqueue_pkt(4, 10, 1, 2);

        //---- 8. q1 走链第一个包 (5 cell) ----
        dequeue_pkt(1);

        //---- 9. 还链 5 cell (cell 4~8, 即 q1 第一包) ----
        begin
            int rcy_cells[$];
            rcy_cells = '{4, 5, 6, 7, 8};
            recycle_cells(rcy_cells);
        end

        //---- 10. q3 入队 2 cell 同时 q0 走链 (4 cell 第一包) ----
        enq_and_deq_concurrent(3, 2, 0);

        //---- 11. 附加: 背靠背 deq q1 第二个包 (6 cell) ----
        dequeue_pkt(1);

        //---- 12. 附加: 背靠背 enq + rcy 同拍冲突 ----
        $display("\n========== ENQ + RCY CONFLICT ==========");
        fork
            enqueue_pkt(2, 3, 0, 0);
            begin
                int rcy2[$];
                rcy2 = '{0, 1, 2};
                recycle_cells(rcy2);
            end
        join
        print_status("after enq+rcy conflict test");

        //---- 13. 附加: 连续 deq 背靠背确认 ----
        $display("\n========== BACK-TO-BACK DEQ q0 ==========");
        dequeue_pkt(0);

        //---- 结束 ----
        repeat (10) @(negedge clk);
        $display("\n========== ALL TESTS DONE ==========");
        print_status("final state");
        $finish;
    end


```
