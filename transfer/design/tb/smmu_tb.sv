//============================================================================
// Testbench : smmu_tb
// Project   : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Case list:
// C1  Single queue enqueue/dequeue/recycle and free-count checks.
// C2  Cross-queue interleaved enqueue/dequeue ordering.
// C3  Free-list restoration and conservation checks.
// C4  B2 multicast flow: carry queue, splice dequeue, busy drop and release.
// C5  Enqueue + dequeue concurrency with back-pressure.
// C6  Dequeue + recycle concurrency.
// C7  Enqueue + dequeue + recycle triple concurrency.
// C8  Queue watermark, near-full, high-watermark drop and release.
// C9  PAUSE assert/release from port aggregate occupancy.
// C10 Stress fill/drain/recycle conservation.
// C11 Pre-enqueue combinational predict-drop behavior.
// C12 Predict-drop boundary when one queue slot remains.
// C13 Predict-drop boundary when seven queue slots remain.
// C14-C17 q_pkt_empty and free-pool boundary coverage.
//============================================================================
`timescale 1ns/1ps

module smmu_tb;

    //========================================================================
    // Parameters
    //========================================================================
    localparam int CELL_NUM  = 64;
    localparam int PORT_NUM  = 2;
    localparam int TC_NUM    = 4;
    localparam int REF_W     = 3;
    localparam int STAT_W    = 32;

    localparam int PKT_CELL_W = 4;
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1;    // 9
    localparam int MCAST_QID = QUEUE_NUM - 1;          // 8
    localparam int ADDR_W = $clog2(CELL_NUM);          // 6
    localparam int QID_W  = $clog2(QUEUE_NUM-1)+1;     // 4
    localparam int PORT_W = $clog2(PORT_NUM-1)+1;      // 1
    localparam int CNT_W  = ADDR_W + 1;                // 7
    localparam int QPP    = $clog2(TC_NUM);            // 2

    localparam int MC_CARRY_TC = 0;
    // Multicast carry queues use TC0 by default: qid = port*TC_NUM + TC0.
    function automatic int carry_qid(input int port); carry_qid = port*TC_NUM + MC_CARRY_TC; endfunction

    function automatic int q2port(input int qid);
        q2port = qid >> QPP;
    endfunction

    //========================================================================
    // Clock / reset
    //========================================================================
    logic clk, rst_n;
    initial clk = 0;
    always #1.667 clk = ~clk;   // ~300MHz

    //========================================================================
    // DUT stimulus signals
    //========================================================================
    logic                  init_start_r;
    logic                  enq_req_r;
    logic [QPP-1:0]        enq_queue_id_r;
    logic [PORT_W-1:0]     enq_egress_port_r;
    logic [PKT_CELL_W-1:0] enq_cell_num_r;
    logic                  enq_is_mcast_r;
    logic [PORT_NUM-1:0]   enq_mcast_bitmap_r;
    logic                  enq_sof_r, enq_eof_r;
    logic                  deq_req_r;
    logic [QID_W-1:0]      deq_queue_id_r;
    logic [PORT_NUM-1:0]   deq_backpressure_r;
    logic                  recycle_req_r;
    logic [ADDR_W-1:0]     recycle_cell_addr_r;
    logic [QID_W-1:0]      recycle_queue_id_r;
    logic                  mcast_recycle_req_r;
    logic [ADDR_W-1:0]     mcast_recycle_addr_r;
    logic [QID_W-1:0]      mcast_recycle_queue_id_r;

    //========================================================================
    // DUT observed outputs
    //========================================================================
    logic                  init_done;
    logic                  enq_ready;
    logic                  enq_predict_drop;
    logic                  alloc_valid;
    logic [ADDR_W-1:0]     alloc_cell_addr;
    logic                  alloc_drop_ind, alloc_sram_flag, alloc_pkt_head, alloc_pkt_tail;
    logic                  alloc_full_frame_drop;
    logic                  mcast_busy_drop;
    logic                  deq_ready;
    logic                  deq_cell_valid;
    logic [ADDR_W-1:0]     deq_cell_addr;
    logic                  deq_pkt_head, deq_pkt_tail;
    logic                  recycle_ack;
    logic [PORT_NUM*TC_NUM-1:0] q_empty;
    logic [PORT_NUM*TC_NUM-1:0] q_pkt_empty;         // regular queue pkt-count==0 bitmap
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
    // DUT configuration inputs
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

    logic [PORT_NUM-1:0][$clog2(TC_NUM)-1:0]     cfg_mcast_carry_tc;

    // Statistics outputs
    logic [CNT_W-1:0]                 st_out_global_used, st_out_free_count;
    logic [QUEUE_NUM-1:0][CNT_W-1:0]  st_out_q_static_used, st_out_per_queue_used;
    logic [PORT_NUM-1:0][CNT_W-1:0]   st_out_per_port_used;
    logic [QUEUE_NUM-1:0]             st_out_q_near_full_status;
    logic [QUEUE_NUM-1:0][STAT_W-1:0] st_out_tail_drop_cnt, st_out_near_full_assert_cnt;
    logic [PORT_NUM-1:0][STAT_W-1:0]  st_out_pause_tx_cnt;

    //========================================================================
    // DUT instance
    //========================================================================
    smmu #(
        .CELL_NUM (CELL_NUM), .PORT_NUM (PORT_NUM),
        .TC_NUM (TC_NUM), .REF_W (REF_W), .STAT_W (STAT_W), .PKT_CELL_W (PKT_CELL_W)
    ) u_dut (
        .clk_core (clk), .rst_core_n (rst_n),
        .init_start (init_start_r), .init_done (init_done),
        // enq
        .enq_req (enq_req_r), .enq_queue_id (enq_queue_id_r),
        .enq_egress_port (enq_egress_port_r), .enq_cell_num (enq_cell_num_r),
        .enq_is_mcast (enq_is_mcast_r),
        .enq_mcast_bitmap (enq_mcast_bitmap_r),
        .enq_sof (enq_sof_r), .enq_eof (enq_eof_r),
        .enq_ready (enq_ready), .enq_predict_drop (enq_predict_drop),
        .alloc_valid (alloc_valid),
        .alloc_cell_addr (alloc_cell_addr), .alloc_drop_ind (alloc_drop_ind),
        .alloc_sram_flag (alloc_sram_flag), .alloc_pkt_head (alloc_pkt_head),
        .alloc_pkt_tail (alloc_pkt_tail), .alloc_full_frame_drop (alloc_full_frame_drop),
        .mcast_busy_drop (mcast_busy_drop),
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
        .q_empty (q_empty),
        .q_pkt_empty (q_pkt_empty),                  // pkt-empty bitmap (whole-packet granularity)
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
    // Internal DUT probes used by the self-checks
    //========================================================================
    wire [CNT_W-1:0]  lle_free_cnt   = u_dut.u_lle.free_cnt_q;
    wire [ADDR_W-1:0] lle_free_head  = u_dut.u_lle.free_head_q;
    wire [ADDR_W-1:0] lle_free_tail  = u_dut.u_lle.free_tail_q;
    wire [CNT_W-1:0]  occ_free_cnt   = u_dut.u_occ.free_count_q;
    wire [CNT_W-1:0]  occ_glob_used  = u_dut.u_occ.global_used_q;

    wire              mc_valid       = u_dut.u_lle.mc_valid_q;
    wire [PORT_NUM-1:0] mc_bitmap    = u_dut.u_lle.mc_dst_bitmap_q;

    function automatic int unsigned lle_qcnt (input int qi); lle_qcnt = u_dut.u_lle.q_cell_cnt_q[qi]; endfunction
    function automatic int unsigned lle_qhead(input int qi); lle_qhead= u_dut.u_lle.q_head_q[qi];     endfunction
    function automatic int unsigned lle_qtail(input int qi); lle_qtail= u_dut.u_lle.q_tail_q[qi];     endfunction
    function automatic int unsigned occ_qcnt (input int qi); occ_qcnt = u_dut.u_occ.q_cell_cnt_q[qi]; endfunction
    function automatic int unsigned occ_qstat(input int qi); occ_qstat= u_dut.u_occ.q_static_used_q[qi]; endfunction
    function automatic int unsigned occ_pused(input int pi); occ_pused= u_dut.u_occ.per_port_used_q[pi]; endfunction

    function automatic bit mc_rd_done (input int pi); mc_rd_done  = u_dut.u_lle.mc_rd_done_q[pi];  endfunction
    function automatic bit mc_rcy_done(input int pi); mc_rcy_done = u_dut.u_lle.mc_rcy_done_q[pi]; endfunction
    function automatic int unsigned mc_pend_uni(input int pi); mc_pend_uni = u_dut.u_lle.mc_pend_uni_q[pi]; endfunction
    function automatic int unsigned mc_ncell(); mc_ncell = u_dut.u_lle.mc_ncell_q; endfunction

    //========================================================================
    // Scoreboard: capture allocation and dequeue events at DUT output pins.
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
    // Common check helpers
    //========================================================================
    int errors  = 0;
    int checks  = 0;
    string cur_case = "";

    task automatic chk(string nm, int got, int exp);
        checks++;
        if (got === exp) $display("    [PASS] %-30s got=%0d exp=%0d", nm, got, exp);
        else begin errors++; $display("    [FAIL] %-30s got=%0d exp=%0d  <<<<<<", nm, got, exp); end
    endtask

    task automatic chk_b(string nm, logic got, logic exp);
        checks++;
        if (got === exp) $display("    [PASS] %-30s got=%0b exp=%0b", nm, got, exp);
        else begin errors++; $display("    [FAIL] %-30s got=%0b exp=%0b  <<<<<<", nm, got, exp); end
    endtask

    task automatic case_begin(string nm);
        cur_case = nm;
        $display("\n================ CASE: %s ================", nm);
    endtask

    //========================================================================
    // Debug dump helper
    //========================================================================
    task automatic dump_state(string tag);
        int qi, pi;
        $display("  ---- [%0t] %s ----", $time, tag);
        $display("    LLE  free_cnt=%0d head=%0d tail=%0d | occ free=%0d glob_used=%0d | mc_valid=%0b bitmap=%b",
                 lle_free_cnt, lle_free_head, lle_free_tail, occ_free_cnt, occ_glob_used, mc_valid, mc_bitmap);
        for (qi=0; qi<QUEUE_NUM; qi++) begin
            if (lle_qcnt(qi)!=0 || occ_qcnt(qi)!=0)
                $display("    q[%0d] LLE: head=%0d tail=%0d cnt=%0d | occ: used=%0d static=%0d",
                         qi, lle_qhead(qi), lle_qtail(qi), lle_qcnt(qi), occ_qcnt(qi), occ_qstat(qi));
        end
        for (pi=0; pi<PORT_NUM; pi++)
            $display("    port[%0d] occ_used=%0d near_full=%0b full=%0b pause=%0b",
                     pi, occ_pused(pi), port_near_full[pi], port_full[pi], pause_req[pi]);
    endtask

    //========================================================================
    // Default configuration
    //========================================================================
    task automatic cfg_setup();
        int qi, pi, tj;
        for (qi=0; qi<QUEUE_NUM; qi++) begin
            cfg_queue_min_cell[qi] = 2;
            cfg_q_max_cell[qi]     = 10;
            cfg_q_full[qi]         = 12;
        end
        for (pi=0; pi<PORT_NUM; pi++) begin
            cfg_port_max[pi]        = 24;
            cfg_port_pause_xoff[pi] = 28;
            cfg_port_pause_xon[pi]  = 16;
            cfg_mcast_carry_tc[pi]  = MC_CARRY_TC[$clog2(TC_NUM)-1:0];
            for (tj=0; tj<TC_NUM; tj++) begin
                cfg_pfc_xoff[pi][tj] = 9;
                cfg_pfc_xon[pi][tj]  = 4;
            end
        end
        cfg_global_high_wm    = 50;
        cfg_global_pause_xoff = 56;
        cfg_global_pause_xon  = 40;
        cfg_pause_en          = 1'b1;
        cfg_pfc_en            = 1'b1;
    endtask

    //========================================================================
    // Reset DUT, build the LLE free list, then wait for init_done.
    //========================================================================
    task automatic do_reset_init();
        rst_n = 0;
        init_start_r = 0;
        enq_req_r = 0; enq_queue_id_r=0; enq_egress_port_r=0; enq_cell_num_r=0; enq_is_mcast_r=0;
        enq_mcast_bitmap_r=0; enq_sof_r=0; enq_eof_r=0;
        deq_req_r=0; deq_queue_id_r=0; deq_backpressure_r=0;
        recycle_req_r=0; recycle_cell_addr_r=0; recycle_queue_id_r=0;
        mcast_recycle_req_r=0; mcast_recycle_addr_r=0; mcast_recycle_queue_id_r=0;
        cfg_setup();
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        @(negedge clk); init_start_r = 1;
        @(negedge clk); init_start_r = 0;
        while (!init_done) @(negedge clk);
        repeat (2) @(negedge clk);
        $display("[%0t] INIT done: free_cnt=%0d (expect %0d)", $time, lle_free_cnt, CELL_NUM);
    endtask

    //========================================================================
    // Enqueue one packet. last_alloc_n records allocated cells for the packet.
    // For unicast queues, enq_queue_id carries TC and enq_egress_port carries
    // the egress port; full qid reconstruction is done inside the DUT.
    //========================================================================
    int                last_alloc_n;

    task automatic enqueue_pkt(input int qid, input int port, input int ncells,
                               input bit is_mcast, input [PORT_NUM-1:0] bitmap);
        int sent_idx;
        int got_before;
        sent_idx = 0;
        last_alloc_n = 0;
        got_before = alloc_q.size();
        $display("  >>> ENQ q%0d port%0d cells=%0d mcast=%0b bitmap=%b", qid, port, ncells, is_mcast, bitmap);
        while (sent_idx < ncells) begin
            @(negedge clk);
            if (enq_ready) begin
                enq_req_r          = 1'b1;
                enq_queue_id_r     = qid[QPP-1:0];
                enq_egress_port_r  = port[PORT_W-1:0];
                enq_cell_num_r     = ncells[PKT_CELL_W-1:0];
                enq_is_mcast_r     = is_mcast;
                enq_mcast_bitmap_r = bitmap;
                enq_sof_r          = (sent_idx == 0);
                enq_eof_r          = (sent_idx == ncells-1);
                sent_idx++;
            end
            else enq_req_r = 1'b0;
        end
        @(negedge clk);
        enq_req_r = 1'b0; enq_sof_r=0; enq_eof_r=0; enq_cell_num_r=0; enq_is_mcast_r=0; enq_mcast_bitmap_r=0;
        repeat (3) @(negedge clk);
        last_alloc_n = alloc_q.size() - got_before;
    endtask

    //========================================================================
    // Multicast-aware empty/head-tail helpers. These mirror the DUT behavior
    // where a multicast frame can be read from a per-port carry queue.
    //========================================================================
    function automatic bit tb_mc_take(input int qid);
        int p; bit is_carry;
        p = qid >> QPP;
        is_carry = mc_valid && (qid < PORT_NUM*TC_NUM) &&
                   u_dut.u_lle.mc_dst_bitmap_q[p] &&
                   !u_dut.u_lle.mc_rd_done_q[p] &&
                   (qid == u_dut.u_lle.mc_carry_qid_q[p]);
        tb_mc_take = is_carry && (u_dut.u_lle.mc_pend_uni_q[p] == 0);
    endfunction

    function automatic bit tb_q_empty(input int qid);
        tb_q_empty = tb_mc_take(qid) ? 1'b0 : (u_dut.u_lle.q_cell_cnt_q[qid] == 0);
    endfunction

    function automatic bit tb_qhead_pt(input int qid);
        int p;
        p = qid >> QPP;
        if (tb_mc_take(qid))
            tb_qhead_pt = ((u_dut.u_lle.mc_rd_idx_q[p] + 1) == u_dut.u_lle.mc_ncell_q);
        else
            tb_qhead_pt = u_dut.u_lle.q_head_pt_q[qid];
    endfunction

    //========================================================================
    // Dequeue one packet from a unicast queue or multicast carry queue.
    //========================================================================
    int                last_deq_n;

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

            if (tb_q_empty(qid)) begin
                deq_req_r = 1'b0;
                break;
            end
            deq_req_r = 1'b1;

            tail_fire = tb_qhead_pt(qid);
            @(negedge clk);
            if (tail_fire) begin
                deq_req_r = 1'b0;
                break;
            end
            guard++;
            if (guard > CELL_NUM*4) begin deq_req_r = 1'b0; break; end
        end
        repeat (3) @(negedge clk);
        last_deq_n = deq_q.size() - got_before;
    endtask

    //========================================================================
    // Recycle cells that have completed egress.
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
        repeat (cells.size()+4) @(negedge clk);
    endtask

    //========================================================================
    // Notify the multicast release path that one output port has recycled.
    //========================================================================
    task automatic mcast_recycle_port(input int port);
        int cq;
        cq = carry_qid(port);
        $display("  >>> MCAST RCY port%0d (carry_qid=%0d)", port, cq);
        @(negedge clk);
        mcast_recycle_req_r      = 1'b1;
        mcast_recycle_addr_r     = '0;
        mcast_recycle_queue_id_r = cq[QID_W-1:0];
        @(negedge clk);
        mcast_recycle_req_r = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    //========================================================================
    // Drive packet metadata without asserting enq_req, then sample predict_drop.
    //========================================================================
    task automatic probe_predict(input int qid, input int port, input int n, output bit pd);
        @(negedge clk);
        enq_req_r         = 1'b0;
        enq_queue_id_r    = qid[QPP-1:0];
        enq_egress_port_r = port[PORT_W-1:0];
        enq_cell_num_r    = n[PKT_CELL_W-1:0];
        @(negedge clk);
        pd = enq_predict_drop;
        enq_cell_num_r    = 0;
    endtask

    //========================================================================

    //========================================================================
    int base;
    initial begin
        do_reset_init();

        //====================================================================
        // C1:
        //====================================================================
        case_begin("C1 single-queue enq/deq/rcy + free_cnt");
        base = alloc_q.size();
        enqueue_pkt(0, q2port(0), 4, 0, '0);
        dump_state("after enq q0 4-cell");
        chk("C1 alloc_count",    last_alloc_n, 4);
        chk("C1 lle_q0_cnt",     lle_qcnt(0), 4);
        chk("C1 occ_q0_used",    occ_qcnt(0), 4);
        chk("C1 free_cnt",       lle_free_cnt, CELL_NUM-4);
        chk("C1 occ_free",       occ_free_cnt, CELL_NUM-4);
        chk("C1 occ_glob_used",  occ_glob_used, 4);
        base = deq_q.size();
        dequeue_pkt(0, '0);
        chk("C1 deq_count",      last_deq_n, 4);
        chk("C1 q0_cnt_after_deq", lle_qcnt(0), 0);
        chk("C1 occ_q0_after_deq", occ_qcnt(0), 4);
        chk("C1 free_after_deq",   lle_free_cnt, CELL_NUM-4);
        begin int rc[$]; rc='{0,1,2,3}; recycle_cells(0, rc); end
        dump_state("after rcy q0 4-cell");
        chk("C1 free_after_rcy",   lle_free_cnt, CELL_NUM);
        chk("C1 occ_q0_after_rcy", occ_qcnt(0), 0);
        chk("C1 occ_glob_after_rcy", occ_glob_used, 0);
        chk("C1 conserve", (lle_free_cnt==CELL_NUM)&&(occ_free_cnt==CELL_NUM), 1);

        //====================================================================
        // C2:
        //====================================================================
        case_begin("C2 cross-queue interleaved enq + deq");
        do_reset_init();
        enqueue_pkt(0, q2port(0), 3, 0, '0);   // q0: 0,1,2
        enqueue_pkt(1, q2port(1), 2, 0, '0);   // q1: 3,4
        enqueue_pkt(0, q2port(0), 2, 0, '0);   // q0: 5,6
        dump_state("after cross enq");
        chk("C2 lle_q0_cnt", lle_qcnt(0), 5);
        chk("C2 lle_q1_cnt", lle_qcnt(1), 2);
        chk("C2 free_cnt",   lle_free_cnt, CELL_NUM-7);
        chk("C2 q0_head",    lle_qhead(0), 0);
        chk("C2 q1_head",    lle_qhead(1), 3);
        base = deq_q.size();
        dequeue_pkt(0, '0);
        chk("C2 q0_deq1_count", last_deq_n, 3);
        chk("C2 q0_head_after", lle_qhead(0), 5);
        chk("C2 q0_cnt_after",  lle_qcnt(0), 2);
        dequeue_pkt(1, '0);
        chk("C2 q1_deq_count", last_deq_n, 2);
        chk("C2 q1_cnt_after", lle_qcnt(1), 0);
        dequeue_pkt(0, '0);
        chk("C2 q0_deq2_count", last_deq_n, 2);
        chk("C2 q0_cnt_final",  lle_qcnt(0), 0);
        begin int rc_q0[$]; int rc_q1[$];
            rc_q0='{0,1,2,5,6}; rc_q1='{3,4};
            recycle_cells(0, rc_q0); recycle_cells(1, rc_q1);
        end
        dump_state("after C2 recycle");
        chk("C2 free_restored",  lle_free_cnt, CELL_NUM);
        chk("C2 occ_glob_clear", occ_glob_used, 0);
        chk("C2 occ_q0_clear",   occ_qcnt(0), 0);
        chk("C2 occ_q1_clear",   occ_qcnt(1), 0);

        //====================================================================
        // C3: free-list restore + conservation
        //====================================================================
        case_begin("C3 free-list restore + conservation");
        do_reset_init();
        enqueue_pkt(0, q2port(0), 2, 0, '0);   // 0,1
        enqueue_pkt(1, q2port(1), 3, 0, '0);   // 2,3,4
        enqueue_pkt(5, q2port(5), 4, 0, '0);   // 5,6,7,8
        dump_state("C3 after enq");
        chk("C3 free_after_enq", lle_free_cnt, CELL_NUM-9);
        chk("C3 glob_used",      occ_glob_used, 9);
        dequeue_pkt(0, '0);
        dequeue_pkt(1, '0);
        dequeue_pkt(5, '0);
        chk("C3 q0_empty", lle_qcnt(0), 0);
        chk("C3 q1_empty", lle_qcnt(1), 0);
        chk("C3 q5_empty", lle_qcnt(5), 0);
        chk("C3 free_unchanged_after_deq", lle_free_cnt, CELL_NUM-9);
        begin int r0[$]; int r1[$]; int r5[$];
            r0='{0,1}; r1='{2,3,4}; r5='{5,6,7,8};
            recycle_cells(0, r0); recycle_cells(1, r1); recycle_cells(5, r5);
        end
        dump_state("C3 after rcy");
        chk("C3 free_full",    lle_free_cnt, CELL_NUM);
        chk("C3 occ_free_full",occ_free_cnt, CELL_NUM);
        chk("C3 glob_zero",    occ_glob_used, 0);
        chk("C3 conserve",     (lle_free_cnt + occ_glob_used)==CELL_NUM, 1);
        chk_b("C3 no_overflow", overflow_alarm, 1'b0);
        chk_b("C3 no_underflow",underflow_alarm, 1'b0);

        //====================================================================
        // C4:

        //====================================================================
        case_begin("C4 B2 multicast: single-slot / splice deq / port recycle / release");
        do_reset_init();



        enqueue_pkt(0, q2port(0), 2, 0, '0);         // A: cells 0,1
        chk("C4 q0_uni_backlog1", u_dut.u_lle.q_uni_pkt_backlog_q[0], 1);

        enqueue_pkt(MCAST_QID, 0, 3, 1, 2'b11);
        dump_state("C4 after mcast enq");
        chk("C4 mc_valid",        mc_valid, 1'b1);
        chk("C4 mcast_alloc_cnt", last_alloc_n, 3);
        chk("C4 mcast_ncell",     mc_ncell(), 3);
        chk("C4 mcastq_sram_cnt", lle_qcnt(MCAST_QID), 3); // chain33 SRAM, cnt=3
        chk("C4 free_after_enq",  lle_free_cnt, CELL_NUM-5);      // A(2)+M(3)
        chk("C4 pend_uni_port0",  mc_pend_uni(0), 1);
        chk("C4 pend_uni_port1",  mc_pend_uni(1), 0);

        chk_b("C4 q_empty_q0_uni",  q_empty[0], 1'b0);
        chk_b("C4 q_empty_q4_mc",   q_empty[4], 1'b0);
        chk_b("C4 q_empty_q1_idle", q_empty[1], 1'b1);

        enqueue_pkt(4, q2port(4), 2, 0, '0);         // C: cells 5,6
        chk("C4 pend_uni_port1_still0", mc_pend_uni(1), 0); // C is unicast; port1 multicast pend stays clear.


        base = deq_q.size();
        dequeue_pkt(0, '0);
        chk("C4 p0_deqA_count", last_deq_n, 2);
        chk("C4 p0_pend_uni_0",  mc_pend_uni(0), 0); // A pend 0
        base = deq_q.size();
        dequeue_pkt(0, '0); // M (splice)
        chk("C4 p0_deqM_count", last_deq_n, 3);
        chk("C4 p0_mc_rd_done", mc_rd_done(0), 1'b1);
        chk("C4 free_after_p0",  lle_free_cnt, CELL_NUM-7); // A(2)+M(3)+C(2) are still allocated.
        chk("C4 mc_valid_still",  mc_valid, 1'b1);


        base = deq_q.size();
        dequeue_pkt(4, '0);
        chk("C4 p1_deqM_count", last_deq_n, 3);
        chk("C4 p1_mc_rd_done", mc_rd_done(1), 1'b1);
        base = deq_q.size();
        dequeue_pkt(4, '0);
        chk("C4 p1_deqC_count", last_deq_n, 2);


        begin int ab; int dn; ab = alloc_q.size();
            enqueue_pkt(MCAST_QID, 0, 2, 1, 2'b01);
            dn = 0; for (int k=ab;k<alloc_q.size();k++) if (alloc_q[k].drop) dn++;
            chk("C4 mcast_busy_drop_all", dn, 2);
        end
        chk("C4 mc_valid_after_drop", mc_valid, 1'b1);


        chk("C4 free_before_release", lle_free_cnt, CELL_NUM-7); // A+C not recycled; M not released yet.
        mcast_recycle_port(0);
        chk("C4 mc_valid_after_p0rcy", mc_valid, 1'b1);
        mcast_recycle_port(1);
        repeat (8) @(negedge clk);
        dump_state("C4 after both port recycle");
        chk("C4 mc_valid_released", mc_valid, 1'b0);

        chk("C4 free_after_release", lle_free_cnt, CELL_NUM-4); // M released; A(2)+C(2) still allocated.
        chk_b("C4 no_underflow", underflow_alarm, 1'b0);


        begin int rA[$]; int rC[$]; rA='{0,1}; rC='{5,6};
              recycle_cells(0, rA); recycle_cells(4, rC); end
        dump_state("C4 after cleanup uni");
        chk("C4 free_full",  lle_free_cnt, CELL_NUM);
        chk("C4 glob_zero",  occ_glob_used, 0);


        enqueue_pkt(MCAST_QID, 0, 2, 1, 2'b11);
        chk("C4 new_mcast_accepted", mc_valid, 1'b1);
        chk("C4 new_mcast_ncell",    mc_ncell(), 2);

        dequeue_pkt(0, '0);
        dequeue_pkt(4, '0);
        mcast_recycle_port(0);
        mcast_recycle_port(1);
        repeat (8) @(negedge clk);
        chk("C4 new_mcast_released", mc_valid, 1'b0);
        chk("C4 final_free_full",    lle_free_cnt, CELL_NUM);

        //====================================================================
        // C5~C17
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
    // C5~C17
    //========================================================================
    task automatic run_remaining_cases();
        int fire_base, ei, guard, dropn, i;
        int deq3_base;

        //--------------------------------------------------------------------
        // C5: enq + deq +
        //--------------------------------------------------------------------
        case_begin("C5 enq+deq concurrent + back-pressure");
        do_reset_init();
        enqueue_pkt(3, q2port(3), 6, 0, '0);
        chk("C5 prefill_q3_cnt", lle_qcnt(3), 6);
        fire_base = enq_fire_cnt;
        deq3_base = deq_q.size();
        guard = 0;
        @(negedge clk); deq_queue_id_r = 3; deq_backpressure_r = '0;
        while ( ((lle_qcnt(3) > 0) || ((enq_fire_cnt-fire_base) < 3)) && guard < 400 ) begin
            @(negedge clk);
            ei = enq_fire_cnt - fire_base;
            deq_req_r = (lle_qcnt(3) > 0);
            if (ei < 3) begin
                enq_req_r=1'b1; enq_queue_id_r=0; enq_egress_port_r=q2port(4); // =q4 (port1,tc0)
                enq_is_mcast_r=1'b0; enq_mcast_bitmap_r='0;
                enq_sof_r=(ei==0); enq_eof_r=(ei==2);
            end else enq_req_r = 1'b0;
            guard++;
        end
        deq_req_r=0; enq_req_r=0; enq_sof_r=0; enq_eof_r=0;
        repeat (4) @(negedge clk);
        dump_state("C5 after concurrent enq+deq");
        chk("C5 q3_drained",    lle_qcnt(3), 0);
        chk("C5 q3_deq_count",  deq_q.size()-deq3_base, 6);
        chk("C5 q4_landed",     lle_qcnt(4), 3);
        chk("C5 enq_fire_3",    enq_fire_cnt-fire_base, 3);
        chk("C5 free_after",    lle_free_cnt, CELL_NUM-9);
        chk_b("C5 no_underflow",underflow_alarm, 1'b0);
        begin int r3[$]; int r4[$]; r3='{0,1,2,3,4,5}; r4='{6,7,8};
              recycle_cells(3, r3); recycle_cells(4, r4); end
        chk("C5 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C6: deq + rcy
        //--------------------------------------------------------------------
        case_begin("C6 deq + rcy concurrent");
        do_reset_init();
        enqueue_pkt(3, q2port(3), 6, 0, '0);
        enqueue_pkt(4, q2port(4), 3, 0, '0);
        dequeue_pkt(4, '0);
        chk("C6 q4_drained", lle_qcnt(4), 0);
        chk("C6 free_before_concurrent", lle_free_cnt, CELL_NUM-9);
        deq3_base = deq_q.size();
        guard = 0; i = 0;
        @(negedge clk); deq_queue_id_r = 3; deq_backpressure_r = '0;
        while ( ((lle_qcnt(3) > 0) || (i < 3)) && guard < 400 ) begin
            @(negedge clk);
            deq_req_r = (lle_qcnt(3) > 0);
            if (i < 3) begin
                recycle_req_r=1'b1; recycle_cell_addr_r=(6+i); recycle_queue_id_r=4; i++;
            end else recycle_req_r=1'b0;
            guard++;
        end
        deq_req_r=0; recycle_req_r=0;
        repeat (5) @(negedge clk);
        dump_state("C6 after concurrent deq+rcy");
        chk("C6 q3_drained",   lle_qcnt(3), 0);
        chk("C6 q3_deq_count", deq_q.size()-deq3_base, 6);
        chk("C6 free_after",   lle_free_cnt, CELL_NUM-6);
        chk("C6 occ_q4_dec",   occ_qcnt(4), 0);
        chk_b("C6 no_underflow", underflow_alarm, 1'b0);
        begin int r3[$]; r3='{0,1,2,3,4,5}; recycle_cells(3, r3); end
        chk("C6 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C7: enq + deq + rcy
        //--------------------------------------------------------------------
        case_begin("C7 enq+deq+rcy triple concurrent");
        do_reset_init();
        enqueue_pkt(3, q2port(3), 6, 0, '0);   // q3: 0..5
        enqueue_pkt(4, q2port(4), 3, 0, '0);   // q4: 6,7,8
        dequeue_pkt(4, '0);
        chk("C7 free_before", lle_free_cnt, CELL_NUM-9);
        fire_base = enq_fire_cnt;
        deq3_base = deq_q.size();
        guard = 0; i = 0;
        @(negedge clk); deq_queue_id_r = 3; deq_backpressure_r = '0;
        while ( ((lle_qcnt(3)>0) || ((enq_fire_cnt-fire_base)<2) || (i<3)) && guard<500 ) begin
            @(negedge clk);
            ei = enq_fire_cnt - fire_base;
            deq_req_r = (lle_qcnt(3) > 0);
            if (ei < 2) begin
                enq_req_r=1'b1; enq_queue_id_r=1; enq_egress_port_r=q2port(5); // =q5 (port1,tc1)
                enq_is_mcast_r=1'b0; enq_mcast_bitmap_r='0;
                enq_sof_r=(ei==0); enq_eof_r=(ei==1);
            end else enq_req_r=1'b0;
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
        chk("C7 q5_landed",    lle_qcnt(5), 2);
        chk("C7 enq_fire_2",   enq_fire_cnt-fire_base, 2);
        chk("C7 free_after",   lle_free_cnt, CELL_NUM-8);
        chk_b("C7 no_underflow", underflow_alarm, 1'b0);
        begin int r3[$]; int r5[$];
              r3='{0,1,2,3,4,5};
              r5='{ int'(alloc_q[alloc_q.size()-2].addr),
                    int'(alloc_q[alloc_q.size()-1].addr) };
              recycle_cells(3, r3); recycle_cells(5, r5); end
        chk("C7 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C8: queue/port/global watermark and drop behavior
        //--------------------------------------------------------------------
        case_begin("C8 watermark / near_full / hi-wm drop / release");
        do_reset_init();
        dropn = 0;
        begin int ab; ab = alloc_q.size();
            for (i=0;i<14;i++) enqueue_pkt(0, q2port(0), 1, 0, '0);
            for (i=ab;i<alloc_q.size();i++) if (alloc_q[i].drop) dropn++;
        end
        dump_state("C8 after burst enq q0");
        chk("C8 q0_cnt_cap",   lle_qcnt(0), 10);
        chk("C8 occ_q0",       occ_qcnt(0), 10);
        chk("C8 free_after",   lle_free_cnt, CELL_NUM-10);
        chk("C8 drop_count",   dropn, 4);
        chk_b("C8 q0_near_full_set", q_near_full[0], 1'b1);
        begin int r[$]; r='{0,1,2}; recycle_cells(0, r); end
        dump_state("C8 after release 3");
        chk("C8 occ_q0_after_rel", occ_qcnt(0), 7);
        chk_b("C8 q0_near_full_clr", q_near_full[0], 1'b0);

        //--------------------------------------------------------------------
        // C9: PAUSE
        //--------------------------------------------------------------------
        case_begin("C9 PAUSE assert / release (port aggregate)");
        do_reset_init();
        cfg_port_max[0] = 32; // C9 PAUSE: port drop pause xoff(28)
        for (i=0;i<12;i++) enqueue_pkt(0, q2port(0), 1, 0, '0);
        for (i=0;i<12;i++) enqueue_pkt(1, q2port(1), 1, 0, '0);
        for (i=0;i<12;i++) enqueue_pkt(2, q2port(2), 1, 0, '0);
        dump_state("C9 after fill port0 ~30");
        chk("C9 port0_used",    occ_pused(0), 30);
        chk_b("C9 pause_set",   pause_req[0], 1'b1);
        begin int r0[$]; int r1[$];
              r0='{0,1,2,3,4,5,6,7,8,9};
              r1='{10,11,12,13,14};
              recycle_cells(0, r0); recycle_cells(1, r1); end
        dump_state("C9 after release to ~15");
        chk("C9 port0_used_rel", occ_pused(0), 15);
        chk_b("C9 pause_clr",    pause_req[0], 1'b0);

        //--------------------------------------------------------------------
        // C10:
        //--------------------------------------------------------------------
        case_begin("C10 stress: fill / drain / recycle conservation");
        do_reset_init();
        for (i=0;i<6;i++) enqueue_pkt(i, q2port(i), 5, 0, '0);
        dump_state("C10 after fill 6x5");
        chk("C10 free_after_fill", lle_free_cnt, CELL_NUM-30);
        chk("C10 glob_used",       occ_glob_used, 30);
        for (i=0;i<6;i++) dequeue_pkt(i, '0);
        for (i=0;i<6;i++) chk($sformatf("C10 q%0d_drained",i), lle_qcnt(i), 0);
        chk("C10 free_unchanged_deq", lle_free_cnt, CELL_NUM-30);
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

        //--------------------------------------------------------------------
        // C11:
        //--------------------------------------------------------------------
        case_begin("C11 pre-enq predict-drop (combinational)");
        do_reset_init();
        begin
            bit pd;
            probe_predict(0, q2port(0), 5, pd);
            chk_b("C11 empty_q0_n5_fit", pd, 1'b0);

            enqueue_pkt(0, q2port(0), 8, 0, '0);
            chk("C11 q0_cnt8", lle_qcnt(0), 8);

            probe_predict(0, q2port(0), 2, pd);
            chk_b("C11 q0_n2_fit",  pd, 1'b0);
            probe_predict(0, q2port(0), 3, pd);
            chk_b("C11 q0_n3_drop", pd, 1'b1);

            enqueue_pkt(0, q2port(0), 3, 0, '0);
            chk("C11 q0_n3_realdrop_cnt", lle_qcnt(0), 8);

            dequeue_pkt(0, '0);
            begin int r[$]; int k; r.delete(); for(k=0;k<8;k++) r.push_back(k);
                  recycle_cells(0, r); end
            chk("C11 q0_cleared",    lle_qcnt(0), 0);
            chk("C11 free_restored", lle_free_cnt, CELL_NUM);

            for (int qq=0; qq<4; qq++) enqueue_pkt(qq, q2port(qq), 10, 0, '0);
            enqueue_pkt(4, q2port(4), 8, 0, '0);
            chk("C11 glob_used_48", occ_glob_used, 28);
            probe_predict(5, q2port(5), 3, pd);
            chk_b("C11 q5_n3_global_drop", pd, 1'b0);
            probe_predict(5, q2port(5), 2, pd);
            chk_b("C11 q5_n2_global_fit",  pd, 1'b0);
        end

        //--------------------------------------------------------------------
        // C12: q0 1 cell , 1-cell pkt ; 1-cell pkt
        //--------------------------------------------------------------------
        case_begin("C12 predict-drop q has one slot left");
        do_reset_init();
        begin
            bit pd;
            int ab;
            int dn;

            enqueue_pkt(0, q2port(0), 9, 0, '0);
            chk("C12 q0_prefill9", lle_qcnt(0), 9);
            chk("C12 free_prefill9", lle_free_cnt, CELL_NUM-9);

            probe_predict(0, q2port(0), 1, pd);
            chk_b("C12 q0_n1_fit", pd, 1'b0);
            ab = alloc_q.size();
            enqueue_pkt(0, q2port(0), 1, 0, '0);
            dn = 0; for (int k=ab; k<alloc_q.size(); k++) if (alloc_q[k].drop) dn++;
            chk("C12 first_n1_drop_cnt", dn, 0);
            chk("C12 q0_after_first_n1", lle_qcnt(0), 10);
            chk("C12 free_after_first_n1", lle_free_cnt, CELL_NUM-10);

            probe_predict(0, q2port(0), 1, pd);
            chk_b("C12 q0_n1_drop", pd, 1'b1);
            ab = alloc_q.size();
            enqueue_pkt(0, q2port(0), 1, 0, '0);
            dn = 0; for (int k=ab; k<alloc_q.size(); k++) if (alloc_q[k].drop) dn++;
            chk("C12 second_n1_drop_cnt", dn, 1);
            chk("C12 q0_after_second_n1", lle_qcnt(0), 10);
            chk("C12 free_after_second_n1", lle_free_cnt, CELL_NUM-10);
        end

        //--------------------------------------------------------------------
        // C13: q0 7 cell , 5-cell pkt ; 5-cell pkt
        //--------------------------------------------------------------------
        case_begin("C13 predict-drop q has seven slots left");
        do_reset_init();
        begin
            bit pd;
            int ab;
            int dn;

            enqueue_pkt(0, q2port(0), 3, 0, '0);
            chk("C13 q0_prefill3", lle_qcnt(0), 3);
            chk("C13 free_prefill3", lle_free_cnt, CELL_NUM-3);

            probe_predict(0, q2port(0), 5, pd);
            chk_b("C13 first_n5_fit", pd, 1'b0);
            ab = alloc_q.size();
            enqueue_pkt(0, q2port(0), 5, 0, '0);
            dn = 0; for (int k=ab; k<alloc_q.size(); k++) if (alloc_q[k].drop) dn++;
            chk("C13 first_n5_drop_cnt", dn, 0);
            chk("C13 q0_after_first_n5", lle_qcnt(0), 8);
            chk("C13 free_after_first_n5", lle_free_cnt, CELL_NUM-8);

            probe_predict(0, q2port(0), 5, pd);
            chk_b("C13 second_n5_drop", pd, 1'b1);
            ab = alloc_q.size();
            enqueue_pkt(0, q2port(0), 5, 0, '0);
            dn = 0; for (int k=ab; k<alloc_q.size(); k++) if (alloc_q[k].drop) dn++;
            chk("C13 second_n5_drop_cnt", dn, 5);
            chk("C13 q0_after_second_n5", lle_qcnt(0), 8);
            chk("C13 free_after_second_n5", lle_free_cnt, CELL_NUM-8);
        end

        //--------------------------------------------------------------------
        // C14: q_pkt_empty vs q_empty (packet-count vs cell-count granularity)
        //   Enqueue a 3-cell single unicast packet. During enqueue (before EOF
        //   lands), q_empty (cell) already de-asserts, but q_pkt_empty (packet)
        //   stays asserted until the whole packet (EOF) is committed. After a
        //   full packet is in queue both are non-empty. Drain the packet: both
        //   return to empty.
        //--------------------------------------------------------------------
        case_begin("C14 q_pkt_empty vs q_empty granularity (unicast)");
        do_reset_init();
        // idle: both empty
        chk_b("C14 q0_empty_idle",     q_empty[0],     1'b1);
        chk_b("C14 q0_pkt_empty_idle", q_pkt_empty[0], 1'b1);
        // one full 3-cell packet into q0
        enqueue_pkt(0, q2port(0), 3, 0, '0);
        dump_state("C14 after 3-cell pkt");
        chk("C14 q0_cell_cnt",         lle_qcnt(0), 3);
        chk("C14 q0_uni_pkt_backlog",  u_dut.u_lle.q_uni_pkt_backlog_q[0], 1);
        chk_b("C14 q0_empty_after",     q_empty[0],     1'b0);   // has cells
        chk_b("C14 q0_pkt_empty_after", q_pkt_empty[0], 1'b0);   // has 1 whole pkt
        // drain
        dequeue_pkt(0, '0);
        repeat (2) @(negedge clk);
        chk("C14 q0_cnt_drained",       lle_qcnt(0), 0);
        chk("C14 q0_pktcnt_drained",    u_dut.u_lle.q_uni_pkt_backlog_q[0], 0);
        chk_b("C14 q0_empty_final",      q_empty[0],     1'b1);
        chk_b("C14 q0_pkt_empty_final",  q_pkt_empty[0], 1'b1);
        begin int r[$]; r='{0,1,2}; recycle_cells(0, r); end
        chk("C14 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C15: q_pkt_empty multi-packet counting on one queue.
        //   Two packets (2-cell + 1-cell) into q1 => pkt backlog=2 => pkt_empty=0.
        //   Deq first packet => backlog=1 => still pkt_empty=0.
        //   Deq second packet => backlog=0 => pkt_empty=1.
        //--------------------------------------------------------------------
        case_begin("C15 q_pkt_empty multi-packet drain");
        do_reset_init();
        enqueue_pkt(1, q2port(1), 2, 0, '0);       // pkt#1 (2 cell)
        enqueue_pkt(1, q2port(1), 1, 0, '0);       // pkt#2 (1 cell)
        dump_state("C15 after 2 pkts on q1");
        chk("C15 q1_cell_cnt",     lle_qcnt(1), 3);
        chk("C15 q1_pkt_backlog2", u_dut.u_lle.q_uni_pkt_backlog_q[1], 2);
        chk_b("C15 q1_pkt_empty0",  q_pkt_empty[1], 1'b0);
        // deq first packet (2 cells)
        base = deq_q.size();
        dequeue_pkt(1, '0);
        repeat (2) @(negedge clk);
        chk("C15 q1_pkt_backlog1", u_dut.u_lle.q_uni_pkt_backlog_q[1], 1);
        chk_b("C15 q1_pkt_empty_still0", q_pkt_empty[1], 1'b0);
        chk_b("C15 q1_cell_empty_still0", q_empty[1], 1'b0);
        // deq second packet (1 cell)
        dequeue_pkt(1, '0);
        repeat (2) @(negedge clk);
        chk("C15 q1_pkt_backlog0", u_dut.u_lle.q_uni_pkt_backlog_q[1], 0);
        chk_b("C15 q1_pkt_empty1",  q_pkt_empty[1], 1'b1);
        chk_b("C15 q1_cell_empty1", q_empty[1], 1'b1);
        begin int r[$]; r='{0,1,2}; recycle_cells(1, r); end
        chk("C15 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C16: q_pkt_empty multicast mapping (extreme). A multicast frame maps
        //   1 logical packet into EACH destination port's carry queue. So both
        //   q0 (port0 carry) and q4 (port1 carry) must show pkt_empty=0 while the
        //   frame is un-read by that port, even though there is no unicast pkt.
        //   Non-destination carry queues stay pkt_empty=1.
        //--------------------------------------------------------------------
        case_begin("C16 q_pkt_empty multicast carry-queue mapping");
        do_reset_init();
        // multicast frame 2-cell, dst bitmap 2'b11 (port0+port1), carry tc=0 => q0,q4
        enqueue_pkt(MCAST_QID, 0, 2, 1, 2'b11);
        dump_state("C16 after mcast enq");
        chk("C16 mc_valid", mc_valid, 1'b1);
        // both carry queues report a pending pkt (mapped), non-empty
        chk_b("C16 q0_pkt_empty_mc",  q_pkt_empty[0], 1'b0);   // port0 carry has mc pkt
        chk_b("C16 q4_pkt_empty_mc",  q_pkt_empty[4], 1'b0);   // port1 carry has mc pkt
        // a non-destination carry queue on some other tc stays empty
        chk_b("C16 q1_pkt_empty_idle", q_pkt_empty[1], 1'b1);
        chk_b("C16 q5_pkt_empty_idle", q_pkt_empty[5], 1'b1);
        // port0 reads out the multicast -> its carry queue pkt_empty back to 1;
        // port1 not yet read -> still non-empty.
        dequeue_pkt(0, '0);
        repeat (2) @(negedge clk);
        chk_b("C16 p0_rd_done",        mc_rd_done(0), 1'b1);
        chk_b("C16 q0_pkt_empty_after_p0", q_pkt_empty[0], 1'b1);  // port0 done
        chk_b("C16 q4_pkt_empty_still0",   q_pkt_empty[4], 1'b0);  // port1 pending
        // port1 reads out -> its carry queue empty too
        dequeue_pkt(4, '0);
        repeat (2) @(negedge clk);
        chk_b("C16 q4_pkt_empty_after_p1", q_pkt_empty[4], 1'b1);
        // release the frame
        mcast_recycle_port(0);
        mcast_recycle_port(1);
        repeat (8) @(negedge clk);
        chk("C16 mc_released", mc_valid, 1'b0);
        chk("C16 free_restored", lle_free_cnt, CELL_NUM);

        //--------------------------------------------------------------------
        // C17: extreme - fill the free pool exactly to empty. The last free
        //   cell must still be accepted; once free_cnt reaches 0, the next
        //   packet is rejected at the ready/predict boundary.
        //--------------------------------------------------------------------
        case_begin("C17 free-pool exhaustion boundary");
        do_reset_init();
        begin
            int ab; int dn; int total;
            bit pd;
            // widen per-queue / global limits so free-pool (CELL_NUM=64) is the binding constraint
            for (int qq=0; qq<QUEUE_NUM; qq++) begin
                cfg_q_max_cell[qq] = CNT_W'(CELL_NUM);
                cfg_q_full[qq]     = CNT_W'(CELL_NUM);
            end
            for (int pp=0; pp<PORT_NUM; pp++) cfg_port_max[pp] = CNT_W'(CELL_NUM);
            cfg_global_high_wm = CNT_W'(CELL_NUM);
            repeat (2) @(negedge clk);
            // spread single-cell packets across 8 unicast queues to avoid per-q cap,
            // draining the free pool toward 0.
            ab = alloc_q.size();
            for (int n=0; n<CELL_NUM; n++)
                enqueue_pkt(n % (PORT_NUM*TC_NUM), q2port(n % (PORT_NUM*TC_NUM)), 1, 0, '0);
            dn = 0; total = 0;
            for (int k=ab; k<alloc_q.size(); k++) begin
                total++;
                if (alloc_q[k].drop) dn++;
            end
            dump_state("C17 after free-pool exhaustion attempt");
            chk("C17 alloc_count_to_empty", total, CELL_NUM);
            chk("C17 drop_count_to_empty", dn, 0);
            chk("C17 free_pool_zero", lle_free_cnt, 0);
            chk("C17 glob_used_full", occ_glob_used, CELL_NUM);
            probe_predict(0, q2port(0), 1, pd);
            chk_b("C17 next_n1_predict_drop", pd, 1'b1);
            chk_b("C17 ready_low_when_empty", enq_ready, 1'b0);
            chk_b("C17 no_underflow", underflow_alarm, 1'b0);
            chk_b("C17 no_overflow",  overflow_alarm,  1'b0);
        end
    endtask
   //========================================
    //VCS Simulation
    `ifdef VCS_SIM
        // VCS simulation hooks
        initial begin
            $vcdpluson();
            $fsdbDumpfile("/home/verdvana/Project/IC/project/cores/smmu/simulation/sim/smmu.fsdb");
            $fsdbDumpvars("+all");
            $vcdplusmemon();
        end

        `ifdef POST_SIM
        //back annotate the SDF file
        initial begin
            $sdf_annotate("/home/verdvana/Project/IC/project/cores/smmu/synthesis/mapped/smmu.sdf",
                          smmu_tb.u_smmu,,,
                          "TYPICAL",
                          "1:1:1",
                          "FROM_MTM");
            $display("\033[31;5m back annotate [0m",`__FILE__,`__LINE__);
        end
        `endif
    `endif
    //========================================================================

    //========================================================================
    initial begin
        #3000000;
        $display("TIMEOUT! checks=%0d errors=%0d", checks, errors);
        $finish;
    end

endmodule
