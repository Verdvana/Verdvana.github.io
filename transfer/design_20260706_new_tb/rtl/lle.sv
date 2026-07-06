//============================================================================
// Module      : lle  (Link-List Engine) —— B2 多播逻辑拼接版
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   LLE 是 MMU 的存储访问平面核心: 唯一访问 Next-Ptr SRAM (1R1W), 对 Enqueue /
//   Dequeue / Recycle 提供分配/出队/还链服务。
//
//   ── 链表组织 (34 chain, 全部在 Next-Ptr SRAM 中) ──
//     [0..31]  : per-(port,TC) 单播队列链
//     [32]     : 多播链 (MC_QID)。★ B2: chain33 是**真实的 SRAM 链表**, 与 32 条单播
//                链同构 —— enqueue 用 lle_alloc_queue_id=MC_QID 走同一挂链路径写 SRAM,
//                维护 q_head/tail/cnt[MC_QID]。QM 从不直接出队 MC_QID (只发 32 单播 qid),
//                故 chain33 的 SRAM 队头不推进, 被多端口共享读。
//                另有一份小寄存器镜像 mc_cells_q[] (≤MAX_MC_CELLS, 存本帧各 cell 地址,
//                报文序) **仅作逐端口读加速**: 出队时用 per-port 索引 O(1) 取地址, 不占
//                SRAM 读口、不改变 "SRAM 为权威链" 这一事实。
//     free 链  : 独立维护 (free_head/free_tail/free_cnt 寄存器)
//
//   ── B2 多播模型 (单槽 + 零复制 + 逐端口私有读指针 + 逻辑插入位置锚定) ──
//     1) 单槽: mc_valid=1 时拒收新多播 (enqueue_ctrl 靠 mc_busy 整帧 drop)。
//     2) 多播数据只存一份 (chain33 在 SRAM 里唯一一条; mc_cells_q[] 是其读加速镜像)。
//     3) 每目的端口私有读索引 mc_rd_idx_q[p] 独立遍历同一份 chain33 (只读, 不推进队头)。
//     4) 逻辑插入位置: 多播帧 SOF 到达时对每个目的端口快照“承载单播队列”当时在队
//        的真实单播完整包数 mc_pend_uni_q[p]; 出队每出完一个真实单播包(pkt_tail)-1;
//        减到 0 且多播未读完 → 该端口下一个包切多播 cell-list。
//     5) 回收: EPS 每端口发完 → mc_rcy_done_q[p]=1; 所有目的端口 rd_done & rcy_done
//        → 整帧 cell 逐个还回 free 链 (走 recycle FIFO, queue_id=MC_QID, occ 每 cell--),
//        还完清 mc_valid, 方可收下一条多播。
//     6) 双池按实际存入计: 多播 alloc/free 事件均用 MC_QID, global 只 ±M 一次。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module lle #(
    parameter  int CELL_NUM        = 8192,
    parameter  int PORT_NUM        = 4,
    parameter  int TC_NUM          = 8,      // 每端口 TC 数
    parameter  int REF_W           = 3,      // (兼容保留, 未用)
    parameter  int RCY_FIFO_DEPTH  = 8,
    parameter  int MAX_MC_CELLS    = 8,      // 多播帧最大 cell 数 (1522B/256B=6, 取 8 余量)
    // ★ 队列数 = 端口数×每端口TC + 1 (1 多播专用队列; free 链独立)
    localparam int QUEUE_NUM       = PORT_NUM*TC_NUM + 1,
    localparam int MC_QID          = QUEUE_NUM-1,        // 多播队列号 (=32)
    localparam int ADDR_W          = $clog2(CELL_NUM),
    localparam int QID_W           = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W          = $clog2(PORT_NUM-1)+1,
    localparam int CNT_W           = ADDR_W + 1,
    localparam int ENTRY_W         = ADDR_W + 2,         // entry = {next, ph, pt}
    localparam int PH_BIT          = 1,
    localparam int PT_BIT          = 0,
    localparam int Q_PER_PORT_LOG  = $clog2(TC_NUM),
    localparam int MC_IDX_W        = $clog2(MAX_MC_CELLS+1)
)(
    input  logic                  clk_core,
    input  logic                  rst_core_n,

    // Init FSM
    input  logic                  init_build_req,
    output logic                  init_build_done,

    // Enqueue Ctrl
    output logic [ADDR_W-1:0]     lle_free_head,
    output logic                  lle_free_empty,
    output logic                  lle_alloc_ready,
    input  logic                  lle_alloc_fire,
    input  logic [QID_W-1:0]      lle_alloc_queue_id,
    input  logic                  lle_set_pkt_head,
    input  logic                  lle_set_pkt_tail,
    input  logic                  lle_alloc_is_mcast,
    input  logic [PORT_NUM-1:0]   lle_alloc_mcast_bitmap,
    input  logic [Q_PER_PORT_LOG-1:0] lle_alloc_mcast_tc,   // ★ 多播帧 TC (决定各端口承载队列)
    output logic                  mc_busy,

    // Dequeue Ctrl (含多播 splice)
    input  logic [QID_W-1:0]      lle_deq_queue_id,
    output logic [ADDR_W-1:0]     lle_qhead,
    output logic                  lle_qhead_pkt_head,
    output logic                  lle_qhead_pkt_tail,
    output logic                  lle_q_empty,
    input  logic                  lle_deq_fire,

    // ★ B2: 给 QM 的 32 条常规队列 empty 向量 (多播计入各目的端口承载队列)
    output logic [PORT_NUM*TC_NUM-1:0] q_empty_vec,

    // ★ 给 QM 的 32 条常规队列 "pkt 数为 0" 向量 (完整包粒度; 多播计入各目的端口承载队列)
    //   与 q_empty_vec 位宽/索引一致, 但以 "在队真实完整包数" 而非 cell 数判空。
    output logic [PORT_NUM*TC_NUM-1:0] q_pkt_empty_vec,

    // Recycle Ctrl (单播还链 + 多播逐端口回收)
    input  logic                  lle_free_req,
    input  logic [ADDR_W-1:0]     lle_free_addr,
    input  logic [QID_W-1:0]      lle_free_queue_id,
    output logic                  lle_free_grant,
    output logic                  lle_free_done,
    input  logic                  mc_rcy_vld,
    input  logic [PORT_W-1:0]     mc_rcy_port,
    output logic                  mcast_underflow,

    // ★ 老化冲刷 (aging_ctrl ↔ LLE): 把某队列链逐 cell 还回 free 链
    input  logic                  age_flush_req,      // 请求冲刷某队列
    input  logic [QID_W-1:0]      age_flush_qid,      // 待冲刷队列号
    output logic                  age_flush_busy,     // 正在冲刷
    output logic                  age_flush_done,     // 冲刷完成 (队列已空)
    // ★ 老化用: 队列非空位图 + 出队 fire 喂狗信号 (→ aging_ctrl)
    //   位宽 QUEUE_NUM (=32 单播 + 1 多播), 高位 MC_QID 位表示多播槽占用
    output logic [QUEUE_NUM-1:0]  q_occupied_vec,
    output logic                  deq_fire_evt,
    output logic [QID_W-1:0]      deq_fire_qid,

    // Occupancy
    output logic                  lle_alloc_evt,
    output logic [QID_W-1:0]      evt_queue_id,
    output logic [PORT_W-1:0]     evt_egress_port,
    output logic                  lle_free_evt,
    output logic [QID_W-1:0]      evt_free_queue_id,
    output logic [PORT_W-1:0]     evt_free_egress_port
);

    //========================================================================
    // per-queue 链表寄存器 (两级预取, 仅单播队列使用; MC_QID 不走 SRAM)
    //========================================================================
    logic [ADDR_W-1:0]   q_head_q       [QUEUE_NUM];
    logic [ADDR_W-1:0]   q_tail_q       [QUEUE_NUM];
    logic [CNT_W-1:0]    q_cell_cnt_q   [QUEUE_NUM];
    logic                q_head_ph_q    [QUEUE_NUM];
    logic                q_head_pt_q    [QUEUE_NUM];
    logic [ADDR_W-1:0]   q_head_next_q    [QUEUE_NUM];
    logic                q_head_next_ph_q [QUEUE_NUM];
    logic                q_head_next_pt_q [QUEUE_NUM];
    logic [ADDR_W-1:0]   q_head_next2_q   [QUEUE_NUM];
    logic                q_tail_ph_q      [QUEUE_NUM];
    logic                q_tail_pt_q      [QUEUE_NUM];

    // ★ 每单播队列: 在队“真实单播完整包”计数
    logic [CNT_W-1:0]    q_uni_pkt_backlog_q [QUEUE_NUM];

    //========================================================================
    // free 链寄存器 (两级预取)
    //========================================================================
    logic [ADDR_W-1:0]   free_head_q;
    logic [ADDR_W-1:0]   free_tail_q;
    logic [CNT_W-1:0]    free_cnt_q;
    logic [ADDR_W-1:0]   free_head_next_q;
    logic [ADDR_W-1:0]   free_head_next2_q;

    assign lle_free_head  = free_head_q;
    assign lle_free_empty = (free_cnt_q == '0);

    //========================================================================
    // ★ B2 多播槽 (单槽)
    //========================================================================
    logic                mc_valid_q;
    logic [PORT_NUM-1:0]  mc_dst_bitmap_q;
    logic [QID_W-1:0]     mc_carry_qid_q  [PORT_NUM];   // 各端口承载单播 QID
    logic [ADDR_W-1:0]    mc_cells_q      [MAX_MC_CELLS];// 多播帧 cell 地址列表 (报文序)
    logic [MC_IDX_W-1:0]  mc_ncell_q;                    // 多播帧 cell 数
    logic [MC_IDX_W-1:0]  mc_wr_idx_q;                   // 入队写指针
    logic [MC_IDX_W-1:0]  mc_rd_idx_q     [PORT_NUM];    // 每端口读指针
    logic                 mc_rd_done_q    [PORT_NUM];
    logic                 mc_rcy_done_q   [PORT_NUM];
    logic [CNT_W-1:0]     mc_pend_uni_q   [PORT_NUM];    // 多播前面待出单播包数

    // 多播整帧还链 walk FSM
    logic                 mc_rel_active_q;
    logic [MC_IDX_W-1:0]  mc_rel_idx_q;

    assign mc_busy = mc_valid_q;

    // 各端口承载单播队列号 (组合): carry_qid[p] = p*TC_NUM + 多播帧TC
    //   ★ 多播帧只有一个 TC/优先级, 在每个目的端口都落到该 TC 的队列上 → 与 QM 调度一致。
    //     (QM 出队某端口的 该TC队列 → MMU 在此队列上 splice 出多播报文)
    logic [QID_W-1:0] carry_qid_c [PORT_NUM];

    always_comb begin
        for (int i = 0; i < PORT_NUM; i++) begin : g_carry_qid
            carry_qid_c[i] = QID_W'(i*TC_NUM) + QID_W'(lle_alloc_mcast_tc);
        end
    end

    //========================================================================
    // Recycle FIFO (还链 cell 缓冲)
    //========================================================================
    logic [ADDR_W-1:0]   rcy_fifo_mem [RCY_FIFO_DEPTH];
    logic [$clog2(RCY_FIFO_DEPTH+1)-1:0] rcy_fifo_cnt_q;
    logic [$clog2(RCY_FIFO_DEPTH)-1:0]   rcy_fifo_wptr_q, rcy_fifo_rptr_q;
    logic                rcy_fifo_full, rcy_fifo_empty;
    assign rcy_fifo_full  = (rcy_fifo_cnt_q == RCY_FIFO_DEPTH);
    assign rcy_fifo_empty = (rcy_fifo_cnt_q == '0);

    logic [ADDR_W-1:0]   rcy_cell;
    assign rcy_cell = rcy_fifo_mem[rcy_fifo_rptr_q];

    logic do_push, do_pop;

    //========================================================================
    // Next-Ptr SRAM (1R1W) 互连
    //========================================================================
    logic                npr_r_en;
    logic [ADDR_W-1:0]   npr_r_addr;
    logic [ENTRY_W-1:0]  npr_r_data;
    logic                npr_w_en;
    logic [ADDR_W-1:0]   npr_w_addr;
    logic [ENTRY_W-1:0]  npr_w_data;

    //========================================================================
    // 建链 FSM
    //========================================================================
    typedef enum logic [1:0] {ST_IDLE=2'b00, ST_BUILD=2'b01, ST_DONE=2'b10} build_st_e;
    build_st_e          build_st_q;
    logic [ADDR_W-1:0]  build_idx_q;
    logic               build_active;
    assign build_active = (build_st_q == ST_BUILD);

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            build_st_q      <= #1 ST_IDLE;
            build_idx_q     <= #1 '0;
            init_build_done <= #1 1'b0;
        end
        else begin
            case (build_st_q)
                ST_IDLE: begin
                    init_build_done <= #1 1'b0;
                    if (init_build_req) begin
                        build_st_q  <= #1 ST_BUILD;
                        build_idx_q <= #1 '0;
                    end
                end
                ST_BUILD: begin
                    if (build_idx_q == CELL_NUM-1) build_st_q <= #1 ST_DONE;
                    build_idx_q <= #1 build_idx_q + 1'b1;
                end
                ST_DONE: begin
                    init_build_done <= #1 1'b1;
                    build_st_q      <= #1 ST_IDLE;
                end
                default: build_st_q <= #1 ST_IDLE;
            endcase
        end
    end

    //========================================================================
    // 多播出队目标端口/承载判定 (对当前 lle_deq_queue_id, 组合)
    //========================================================================
    logic [QID_W-1:0]   deq_port_full;
    logic               deq_is_uni;
    logic [PORT_W-1:0]  deq_port;
    logic               is_carry_deq;
    logic               mc_take_deq;

    assign deq_port_full = lle_deq_queue_id >> Q_PER_PORT_LOG;
    assign deq_is_uni    = (lle_deq_queue_id < (PORT_NUM*TC_NUM));
    assign deq_port      = deq_is_uni ? deq_port_full[PORT_W-1:0] : '0;
    assign is_carry_deq  = deq_is_uni & mc_valid_q & mc_dst_bitmap_q[deq_port] &
                           ~mc_rd_done_q[deq_port] &
                           (lle_deq_queue_id == mc_carry_qid_q[deq_port]);
    assign mc_take_deq   = is_carry_deq & (mc_pend_uni_q[deq_port] == '0);

    //========================================================================
    // 事务请求信号
    //========================================================================
    logic enq_req_int, enq_is_uni;
    logic deq_req_int, deq_need_sram;
    logic rcy_req_int;

    assign enq_is_uni  = ~lle_alloc_is_mcast;
    assign enq_req_int = lle_alloc_fire & ~build_active & ~lle_free_empty;

    // deq: 多播 take 或单播队列非空
    assign deq_req_int   = lle_deq_fire & ~build_active &
                           (mc_take_deq | (q_cell_cnt_q[lle_deq_queue_id] != '0));
    // 仅单播走链且 cnt>=3 时需要 SRAM 读; 多播 take 不读 SRAM
    assign deq_need_sram = deq_req_int & ~mc_take_deq &
                           (q_cell_cnt_q[lle_deq_queue_id] >= 3);
    assign rcy_req_int   = ~rcy_fifo_empty & ~build_active;

    //========================================================================
    // 三选一仲裁: P0 deq > P1 enq > P2 rcy
    //========================================================================
    logic deq_grant, enq_grant, rcy_grant;
    assign deq_grant = deq_req_int;
    assign enq_grant = enq_req_int & ~build_active & ~deq_need_sram;
    assign rcy_grant = rcy_req_int & ~build_active & ~deq_need_sram & ~enq_grant;

    assign lle_alloc_ready = ~build_active & ~lle_free_empty & ~deq_need_sram;

    //========================================================================
    // ★ 老化冲刷 (age flush) walk: 把 age_flush_qid 队列链逐 cell 还回 free 链。
    //   - 独立读 SRAM 拿 next 指针 (最低优先级, 仅在正常 deq/enq 不占读口的空拍推进);
    //   - 每步 push 当前队头 cell 进 recycle FIFO (走现有 free 事件通路, occ 自动 --);
    //   - 队列 cnt 减到 0 → age_flush_done, 收尾清 head/tail/cnt。
    //   - MC_QID 冲刷: 额外清多播槽状态。
    //========================================================================
    typedef enum logic [1:0] {AGF_IDLE, AGF_RD, AGF_PUSH, AGF_DONE} agf_st_e;
    agf_st_e            agf_st_q;
    logic [QID_W-1:0]   agf_qid_q;        // 正在冲刷的队列
    logic [ADDR_W-1:0]  agf_cur_q;        // 当前待 push 的 cell (队头)
    logic [ADDR_W-1:0]  agf_next_q;       // 当前 cell 的 next (SRAM 读回)
    logic [CNT_W-1:0]   agf_remain_q;     // 剩余待还 cell 数

    logic               agf_active;
    assign agf_active = (agf_st_q != AGF_IDLE);
    assign age_flush_busy = agf_active;

    // flush 读请求: AGF_RD 态且 SRAM 读口空闲 (正常 deq/enq 都不读)
    logic               agf_rd_gnt;
    // (下面 SRAM 读口驱动里给最低优先级; 此处先声明, 赋值见 SRAM 驱动段后)

    //========================================================================
    // 还链 push 源仲裁: 外部单播回收 优先; 多播整帧还链(walk); 老化冲刷 最低
    //========================================================================
    logic               ext_free_push;   // 外部单播回收 push
    logic               mc_rel_push;      // 多播整帧还链 push
    logic               agf_push;         // ★ 老化冲刷 push
    logic [ADDR_W-1:0]  push_cell;
    logic [QID_W-1:0]   push_qid;

    assign ext_free_push = lle_free_req & ~rcy_fifo_full & ~build_active;
    assign mc_rel_push   = mc_rel_active_q & ~ext_free_push & ~rcy_fifo_full & ~build_active;
    assign agf_push      = (agf_st_q == AGF_PUSH) & ~ext_free_push & ~mc_rel_push &
                           ~rcy_fifo_full & ~build_active;

    assign push_cell = ext_free_push ? lle_free_addr :
                       mc_rel_push   ? mc_cells_q[mc_rel_idx_q] :
                                       agf_cur_q;
    assign push_qid  = ext_free_push ? lle_free_queue_id :
                       mc_rel_push   ? MC_QID[QID_W-1:0] :
                                       agf_qid_q;

    assign do_push = ext_free_push | mc_rel_push | agf_push;
    assign do_pop  = rcy_grant;

    //========================================================================
    // SRAM 读写口驱动
    //========================================================================
    logic [ADDR_W-1:0]  build_addr;
    logic [ENTRY_W-1:0] build_wdata;
    assign build_addr  = build_idx_q;
    assign build_wdata = {(build_idx_q == CELL_NUM-1) ? build_idx_q : (build_idx_q + 1'b1),
                          1'b0, 1'b0};

    logic [ADDR_W-1:0] enq_cell;
    assign enq_cell = free_head_q;

    // pend 流水寄存器
    logic               deq_pend_q;
    logic [QID_W-1:0]   deq_pend_qid_q;
    logic               enq_pend_q;
    logic               deq_pend_tail_q;
    logic               deq_pend_tail_ph_q;
    logic               deq_pend_tail_pt_q;

    logic deq_pend_same_q;
    logic enq_bypass;
    assign deq_pend_same_q = deq_pend_q & deq_grant & ~mc_take_deq &
                             (deq_pend_qid_q == lle_deq_queue_id);
    assign enq_bypass      = enq_pend_q & enq_grant;

    logic [ADDR_W-1:0] enq_sram_rd_addr;
    assign enq_sram_rd_addr = enq_bypass ? npr_r_data[2 +: ADDR_W] : free_head_next2_q;

    logic [ADDR_W-1:0] deq_sram_rd_addr;
    assign deq_sram_rd_addr = deq_pend_same_q ? npr_r_data[2 +: ADDR_W]
                                              : q_head_next2_q[lle_deq_queue_id];

    always_comb begin
        npr_r_en   = 1'b0;
        npr_r_addr = '0;
        npr_w_en   = 1'b0;
        npr_w_addr = '0;
        npr_w_data = '0;

        if (build_active) begin
            npr_w_en   = 1'b1;
            npr_w_addr = build_addr;
            npr_w_data = build_wdata;
        end
        else if (deq_grant && deq_need_sram) begin
            npr_r_en   = 1'b1;
            npr_r_addr = deq_sram_rd_addr;
        end
        else if (enq_grant) begin
            npr_r_en   = 1'b1;
            npr_r_addr = enq_sram_rd_addr;
            // ★ relink: 写 OLD tail.next 指向新 cell。单播链 [0..31] 与多播链 [MC_QID]
            //   都是真实 SRAM 链, 走同一 relink (chain33 亦存 SRAM, 满足 spec)。
            if (q_cell_cnt_q[lle_alloc_queue_id] != '0) begin
                npr_w_en   = 1'b1;
                npr_w_addr = q_tail_q[lle_alloc_queue_id];
                npr_w_data = {enq_cell,
                              q_tail_ph_q[lle_alloc_queue_id],
                              q_tail_pt_q[lle_alloc_queue_id]};
            end
        end
        else if (rcy_grant) begin
            npr_w_en   = 1'b1;
            npr_w_addr = free_tail_q;
            npr_w_data = {rcy_cell, 1'b0, 1'b0};
        end

        // ★ 老化冲刷读 next: 最低优先级, 仅在 build/deq/enq 都不占读口时
        //   (rcy 只用写口, 与 flush 读口不冲突, 故 flush 读可与 rcy 写同拍)
        if (agf_rd_gnt) begin
            npr_r_en   = 1'b1;
            npr_r_addr = agf_cur_q;
        end
    end

    // flush 读授权: AGF_RD 态 且 本拍 SRAM 读口未被 deq/enq 占用 且 非 build
    assign agf_rd_gnt = (agf_st_q == AGF_RD) & ~build_active &
                        ~(deq_grant & deq_need_sram) & ~enq_grant;

    next_ptr_sram_1r1w #(.CELL_NUM(CELL_NUM), .DATA_W(ENTRY_W)) u_npr (
        .clk_core(clk_core), .rst_core_n(rst_core_n),
        .r_en(npr_r_en), .r_addr(npr_r_addr), .r_data(npr_r_data),
        .w_en(npr_w_en), .w_addr(npr_w_addr), .w_data(npr_w_data)
    );

    //========================================================================
    // Pend 流水寄存器
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            deq_pend_q     <= #1 1'b0;
            deq_pend_qid_q <= #1 '0;
            enq_pend_q     <= #1 1'b0;
            deq_pend_tail_q    <= #1 1'b0;
            deq_pend_tail_ph_q <= #1 1'b0;
            deq_pend_tail_pt_q <= #1 1'b0;
        end
        else begin
            deq_pend_q     <= #1 deq_grant & deq_need_sram;
            deq_pend_qid_q <= #1 lle_deq_queue_id;
            enq_pend_q     <= #1 enq_grant;
            deq_pend_tail_q    <= #1 (deq_grant & deq_need_sram) &
                                  (deq_sram_rd_addr == q_tail_q[lle_deq_queue_id]);
            deq_pend_tail_ph_q <= #1 q_tail_ph_q[lle_deq_queue_id];
            deq_pend_tail_pt_q <= #1 q_tail_pt_q[lle_deq_queue_id];
        end
    end

    //========================================================================
    // 多播回收下溢检测 (对已完成端口重复回收)
    //========================================================================
    assign mcast_underflow = mc_rcy_vld & mc_valid_q & mc_rcy_done_q[mc_rcy_port];

    // 释放判决: 所有目的端口 rd_done & rcy_done
    logic all_read, all_recycled, mc_release_start;
    always_comb begin
        all_read     = 1'b1;
        all_recycled = 1'b1;
        for (int p = 0; p < PORT_NUM; p++) begin
            if (mc_dst_bitmap_q[p]) begin
                if (!mc_rd_done_q[p])  all_read     = 1'b0;
                if (!mc_rcy_done_q[p]) all_recycled = 1'b0;
            end
        end
    end
    // 启动整帧还链 walk (还未在还链中)
    assign mc_release_start = mc_valid_q & all_read & all_recycled & ~mc_rel_active_q;

    //========================================================================
    // ★ 老化冲刷 walk FSM (独立状态机, 逐 cell 摘链还 free)
    //   AGF_IDLE : 等 age_flush_req。收到→锁 qid, 取该队列当前 head/cnt, 进 AGF_RD。
    //   AGF_RD   : 发 SRAM 读 (agf_cur_q.next), 得到读授权后下一拍进 AGF_PUSH。
    //   AGF_PUSH : 把 agf_cur_q push 进 recycle FIFO (agf_push, 最低优先级);
    //              push 成功→ cur=next(上一拍读回), remain--; remain 到 0→AGF_DONE, 否则回 AGF_RD。
    //   AGF_DONE : 收尾 (清 head/tail/cnt; MC_QID 额外清多播槽), 拉 age_flush_done, 回 IDLE。
    //   注: q_head/q_cell_cnt 的实际清零在 AGF_DONE 由本 FSM 直接写 (被冲刷队列此时 QM 应已停发)。
    //========================================================================
    logic agf_rd_done_q;         // AGF_RD 已完成一次读 (npr_r_data 为 agf_cur_q.next)

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            agf_st_q      <= #1 AGF_IDLE;
            agf_qid_q     <= #1 '0;
            agf_cur_q     <= #1 '0;
            agf_next_q    <= #1 '0;
            agf_remain_q  <= #1 '0;
            agf_rd_done_q <= #1 1'b0;
            age_flush_done <= #1 1'b0;
        end
        else begin
            age_flush_done <= #1 1'b0;   // 默认脉冲拉低
            case (agf_st_q)
                AGF_IDLE: begin
                    agf_rd_done_q <= #1 1'b0;
                    if (age_flush_req && (q_cell_cnt_q[age_flush_qid] != '0)) begin
                        agf_qid_q    <= #1 age_flush_qid;
                        agf_cur_q    <= #1 q_head_q[age_flush_qid];
                        agf_remain_q <= #1 q_cell_cnt_q[age_flush_qid];
                        agf_st_q     <= #1 AGF_RD;
                    end
                    else if (age_flush_req) begin
                        // 队列已空: 直接完成
                        age_flush_done <= #1 1'b1;
                    end
                end
                AGF_RD: begin
                    // 若只剩 1 个 cell, 无需读 next, 直接去 PUSH
                    if (agf_remain_q == 1) begin
                        agf_rd_done_q <= #1 1'b1;
                        agf_st_q      <= #1 AGF_PUSH;
                    end
                    else if (agf_rd_gnt) begin
                        // 本拍发出读, 下一拍 npr_r_data 有效
                        agf_rd_done_q <= #1 1'b1;
                        agf_st_q      <= #1 AGF_PUSH;
                    end
                end
                AGF_PUSH: begin
                    // 上一拍读回的 next (若有效)
                    if (agf_rd_done_q && (agf_remain_q != 1))
                        agf_next_q <= #1 npr_r_data[2 +: ADDR_W];
                    if (agf_push) begin
                        agf_rd_done_q <= #1 1'b0;
                        if (agf_remain_q == 1) begin
                            agf_st_q <= #1 AGF_DONE;
                        end
                        else begin
                            agf_cur_q    <= #1 (agf_remain_q == 1) ? agf_cur_q : npr_r_data[2 +: ADDR_W];
                            agf_remain_q <= #1 agf_remain_q - 1'b1;
                            agf_st_q     <= #1 AGF_RD;
                        end
                    end
                end
                AGF_DONE: begin
                    age_flush_done <= #1 1'b1;
                    agf_st_q       <= #1 AGF_IDLE;
                end
                default: agf_st_q <= #1 AGF_IDLE;
            endcase
        end
    end

    //========================================================================
    // 主状态更新
    //========================================================================
    integer q, i, pp;
    logic uni_pkt_tail_deq;    // 本拍出队的是一个真实单播包尾
    assign uni_pkt_tail_deq = deq_grant & ~mc_take_deq & q_head_pt_q[lle_deq_queue_id];

    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (q = 0; q < QUEUE_NUM; q++) begin
                q_head_q[q]<= #1'0; q_tail_q[q]<= #1'0; q_cell_cnt_q[q]<= #1'0;
                q_head_ph_q[q]<= #11'b0; q_head_pt_q[q]<= #11'b0;
                q_head_next_q[q]<= #1'0; q_head_next_ph_q[q]<= #11'b0; q_head_next_pt_q[q]<= #11'b0;
                q_head_next2_q[q]<= #1'0; q_tail_ph_q[q]<= #11'b0; q_tail_pt_q[q]<= #11'b0;
                q_uni_pkt_backlog_q[q]<= #1'0;
            end
            free_head_q<= #1'0; free_tail_q<= #1'0; free_cnt_q<= #1'0;
            free_head_next_q<= #1'0; free_head_next2_q<= #1'0;
            rcy_fifo_cnt_q<= #1'0; rcy_fifo_wptr_q<= #1'0; rcy_fifo_rptr_q<= #1'0;
            for (i = 0; i < RCY_FIFO_DEPTH; i++) rcy_fifo_mem[i]<= #1'0;
            // 多播槽复位
            mc_valid_q<= #11'b0; mc_dst_bitmap_q<= #1'0; mc_ncell_q<= #1'0; mc_wr_idx_q<= #1'0;
            mc_rel_active_q<= #11'b0; mc_rel_idx_q<= #1'0;
            for (pp = 0; pp < PORT_NUM; pp++) begin
                mc_carry_qid_q[pp]<= #1'0; mc_rd_idx_q[pp]<= #1'0;
                mc_rd_done_q[pp]<= #11'b0; mc_rcy_done_q[pp]<= #11'b0; mc_pend_uni_q[pp]<= #1'0;
            end
            for (i = 0; i < MAX_MC_CELLS; i++) mc_cells_q[i]<= #1'0;
        end
        else if (build_st_q == ST_DONE) begin
            for (q = 0; q < QUEUE_NUM; q++) begin
                q_head_q[q]<= #1'0; q_tail_q[q]<= #1'0; q_cell_cnt_q[q]<= #1'0;
                q_head_ph_q[q]<= #11'b0; q_head_pt_q[q]<= #11'b0;
                q_head_next_q[q]<= #1'0; q_head_next_ph_q[q]<= #11'b0; q_head_next_pt_q[q]<= #11'b0;
                q_head_next2_q[q]<= #1'0; q_tail_ph_q[q]<= #11'b0; q_tail_pt_q[q]<= #11'b0;
                q_uni_pkt_backlog_q[q]<= #1'0;
            end
            free_head_q       <= #1 '0;
            free_head_next_q  <= #1 {{(ADDR_W-1){1'b0}}, 1'b1};
            free_head_next2_q <= #1 {{(ADDR_W-2){1'b0}}, 2'b10};
            free_tail_q       <= #1 CELL_NUM[ADDR_W-1:0] - 1'b1;
            free_cnt_q        <= #1 CELL_NUM[CNT_W-1:0];
            rcy_fifo_cnt_q<= #1'0; rcy_fifo_wptr_q<= #1'0; rcy_fifo_rptr_q<= #1'0;
            mc_valid_q<= #11'b0; mc_dst_bitmap_q<= #1'0; mc_ncell_q<= #1'0; mc_wr_idx_q<= #1'0;
            mc_rel_active_q<= #11'b0; mc_rel_idx_q<= #1'0;
            for (pp = 0; pp < PORT_NUM; pp++) begin
                mc_carry_qid_q[pp]<= #1'0; mc_rd_idx_q[pp]<= #1'0;
                mc_rd_done_q[pp]<= #11'b0; mc_rcy_done_q[pp]<= #11'b0; mc_pend_uni_q[pp]<= #1'0;
            end
        end
        else begin
            //================================================================
            // ENQ 落地
            //================================================================
            if (enq_grant) begin
                // free 链两级预取推进 (单播/多播都消耗 free)
                free_head_q <= #1 free_head_next_q;
                if (enq_bypass) free_head_next_q <= #1 npr_r_data[2 +: ADDR_W];
                else            free_head_next_q <= #1 free_head_next2_q;

                //-------- 挂链 (单播链 [0..31] 与多播链 [MC_QID] 同构, 都写 SRAM) --------
                //   ★ B2: chain33 亦为真实 SRAM 链, 走同一挂链/预取逻辑 (满足 spec)。
                q_tail_q[lle_alloc_queue_id] <= #1 enq_cell;
                if (q_cell_cnt_q[lle_alloc_queue_id] == '0) begin
                    q_head_q[lle_alloc_queue_id]         <= #1 enq_cell;
                    q_head_ph_q[lle_alloc_queue_id]      <= #1 lle_set_pkt_head;
                    q_head_pt_q[lle_alloc_queue_id]      <= #1 lle_set_pkt_tail;
                    q_head_next_q[lle_alloc_queue_id]    <= #1 free_head_next_q;
                    q_head_next_ph_q[lle_alloc_queue_id] <= #1 1'b0;
                    q_head_next_pt_q[lle_alloc_queue_id] <= #1 1'b0;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 1) begin
                    q_head_next_q[lle_alloc_queue_id]    <= #1 enq_cell;
                    q_head_next_ph_q[lle_alloc_queue_id] <= #1 lle_set_pkt_head;
                    q_head_next_pt_q[lle_alloc_queue_id] <= #1 lle_set_pkt_tail;
                    q_head_next2_q[lle_alloc_queue_id]   <= #1 free_head_next_q;
                end
                else if (q_cell_cnt_q[lle_alloc_queue_id] == 2) begin
                    q_head_next2_q[lle_alloc_queue_id]   <= #1 enq_cell;
                end
                q_tail_ph_q[lle_alloc_queue_id] <= #1 lle_set_pkt_head;
                q_tail_pt_q[lle_alloc_queue_id] <= #1 lle_set_pkt_tail;

                if (enq_is_uni) begin
                    // ★ 真实单播完整包在队计数: EOF 入队 +1
                    //   (若同队同拍还有 pkt_tail 出队, 下面出队分支 -1, 净变化合并)
                    if (lle_set_pkt_tail && !(uni_pkt_tail_deq && (lle_deq_queue_id == lle_alloc_queue_id)))
                        q_uni_pkt_backlog_q[lle_alloc_queue_id] <= #1 q_uni_pkt_backlog_q[lle_alloc_queue_id] + 1'b1;
                end
                else begin
                    //-------- 多播: 额外写 cell-list 镜像 (读加速) + 建槽 --------
                    mc_cells_q[mc_wr_idx_q] <= #1 enq_cell;
                    if (lle_set_pkt_head) begin
                        // SOF: 建槽 + 逐端口快照插入位置
                        mc_valid_q      <= #1 1'b1;
                        mc_dst_bitmap_q <= #1 lle_alloc_mcast_bitmap;
                        mc_wr_idx_q     <= #1 {{(MC_IDX_W-1){1'b0}}, 1'b1};
                        for (pp = 0; pp < PORT_NUM; pp++) begin
                            mc_rd_idx_q[pp]   <= #1 '0;
                            mc_rd_done_q[pp]  <= #1 ~lle_alloc_mcast_bitmap[pp]; // 非目的直接 done
                            mc_rcy_done_q[pp] <= #1 ~lle_alloc_mcast_bitmap[pp];
                            // 承载单播队列号 = 端口*TC_NUM + 该端口多播承载 TC
                            mc_carry_qid_q[pp]<= #1 carry_qid_c[pp];
                            // 快照: 该承载队列当前在队单播完整包数
                            mc_pend_uni_q[pp] <= #1 q_uni_pkt_backlog_q[carry_qid_c[pp]];
                        end
                    end
                    else begin
                        mc_wr_idx_q <= #1 mc_wr_idx_q + 1'b1;
                    end
                    if (lle_set_pkt_tail) begin
                        // EOF: 锁定 cell 数
                        mc_ncell_q <= #1 lle_set_pkt_head ? {{(MC_IDX_W-1){1'b0}}, 1'b1}
                                                       : (mc_wr_idx_q + 1'b1);
                    end
                end
            end

            // enq_pend T+1: 回填 free_head_next2
            if (enq_pend_q) free_head_next2_q <= #1 npr_r_data[2 +: ADDR_W];

            //================================================================
            // DEQ 落地
            //================================================================
            if (deq_grant) begin
                if (mc_take_deq) begin
                    //-------- 多播 take: 推进该端口读索引 --------
                    if ((mc_rd_idx_q[deq_port] + 1'b1) == mc_ncell_q)
                        mc_rd_done_q[deq_port] <= #1 1'b1;   // 读到最后一个 cell
                    mc_rd_idx_q[deq_port] <= #1 mc_rd_idx_q[deq_port] + 1'b1;
                end
                else begin
                    //-------- 单播走链 (两级预取) --------
                    q_head_q[lle_deq_queue_id] <= #1 q_head_next_q[lle_deq_queue_id];
                    if (deq_pend_same_q) begin
                        if (deq_pend_tail_q) begin
                            q_head_ph_q[lle_deq_queue_id] <= #1 deq_pend_tail_ph_q;
                            q_head_pt_q[lle_deq_queue_id] <= #1 deq_pend_tail_pt_q;
                        end
                        else begin
                            q_head_ph_q[lle_deq_queue_id] <= #1 npr_r_data[PH_BIT];
                            q_head_pt_q[lle_deq_queue_id] <= #1 npr_r_data[PT_BIT];
                        end
                        q_head_next_q[lle_deq_queue_id] <= #1 npr_r_data[2 +: ADDR_W];
                    end
                    else begin
                        q_head_ph_q[lle_deq_queue_id] <= #1 q_head_next_ph_q[lle_deq_queue_id];
                        q_head_pt_q[lle_deq_queue_id] <= #1 q_head_next_pt_q[lle_deq_queue_id];
                        q_head_next_q[lle_deq_queue_id] <= #1 q_head_next2_q[lle_deq_queue_id];
                    end

                    // ★ 出到真实单播包尾: backlog--, 若是承载队列 pend_uni--
                    if (uni_pkt_tail_deq &&
                        !(enq_grant && enq_is_uni && lle_set_pkt_tail && (lle_alloc_queue_id == lle_deq_queue_id)))
                        q_uni_pkt_backlog_q[lle_deq_queue_id] <= #1 q_uni_pkt_backlog_q[lle_deq_queue_id] - 1'b1;
                    if (uni_pkt_tail_deq && is_carry_deq && (mc_pend_uni_q[deq_port] != '0))
                        mc_pend_uni_q[deq_port] <= #1 mc_pend_uni_q[deq_port] - 1'b1;
                end
            end

            // deq_pend T+1: 回填 next_ph/pt 和 next2
            if (deq_pend_q) begin
                if (deq_pend_tail_q) begin
                    q_head_next_ph_q[deq_pend_qid_q] <= #1 deq_pend_tail_ph_q;
                    q_head_next_pt_q[deq_pend_qid_q] <= #1 deq_pend_tail_pt_q;
                end
                else begin
                    q_head_next_ph_q[deq_pend_qid_q] <= #1 npr_r_data[PH_BIT];
                    q_head_next_pt_q[deq_pend_qid_q] <= #1 npr_r_data[PT_BIT];
                    q_head_next2_q[deq_pend_qid_q]   <= #1 npr_r_data[2 +: ADDR_W];
                end
            end

            //================================================================
            // q_cell_cnt: 入队 (单播链或多播链 MC_QID) +1; 出队 (仅真实单播走链) -1。
            //   多播出队 (mc_take) 不推进 MC_QID 队头、不减 MC_QID cnt (多端口共享读);
            //   MC_QID cnt 只在整帧还链完成时清 0 (见下面 release 分支)。
            //   注: 多播 alloc 到 MC_QID, 与单播 deq 到某单播 qid, 二者 qid 必不同 →
            //       无 "同 queue 同拍" 冲突; 仅单播自环 (alloc==deq) 需净不变处理。
            //================================================================
            if (enq_grant && enq_is_uni && deq_grant && ~mc_take_deq &&
                (lle_alloc_queue_id == lle_deq_queue_id)) begin
                // 同 (单播) queue 同拍入+出: 净不变
            end
            else begin
                if (enq_grant)                                    // 单播链或 MC_QID 均 +1
                    q_cell_cnt_q[lle_alloc_queue_id] <= #1 q_cell_cnt_q[lle_alloc_queue_id] + 1'b1;
                if (deq_grant && ~mc_take_deq)                    // 仅真实单播出队 -1
                    q_cell_cnt_q[lle_deq_queue_id]   <= #1 q_cell_cnt_q[lle_deq_queue_id]   - 1'b1;
            end

            //================================================================
            // 多播逐端口回收通知
            //================================================================
            if (mc_rcy_vld && mc_valid_q)
                mc_rcy_done_q[mc_rcy_port] <= #1 1'b1;

            //================================================================
            // 多播整帧还链 walk
            //================================================================
            if (mc_release_start) begin
                mc_rel_active_q <= #1 1'b1;
                mc_rel_idx_q    <= #1 '0;
            end
            else if (mc_rel_active_q) begin
                if (mc_rel_push) begin
                    if ((mc_rel_idx_q + 1'b1) == mc_ncell_q) begin
                        // 最后一个 cell 已 push → 收槽
                        mc_rel_active_q <= #1 1'b0;
                        mc_valid_q      <= #1 1'b0;
                        mc_dst_bitmap_q <= #1 '0;
                        mc_ncell_q      <= #1 '0;
                        mc_wr_idx_q     <= #1 '0;
                        // 清空 chain33 的 SRAM 链寄存器 (下条多播帧从空链重建)
                        q_head_q[MC_QID]    <= #1 '0;
                        q_tail_q[MC_QID]    <= #1 '0;
                        q_cell_cnt_q[MC_QID]<= #1 '0;
                        q_tail_ph_q[MC_QID] <= #1 1'b0;
                        q_tail_pt_q[MC_QID] <= #1 1'b0;
                        for (pp = 0; pp < PORT_NUM; pp++) begin
                            mc_rd_done_q[pp]  <= #1 1'b0;
                            mc_rcy_done_q[pp] <= #1 1'b0;
                            mc_pend_uni_q[pp] <= #1 '0;
                            mc_rd_idx_q[pp]   <= #1 '0;
                        end
                    end
                    mc_rel_idx_q <= #1 mc_rel_idx_q + 1'b1;
                end
            end

            //================================================================
            // Recycle FIFO push + pop
            //================================================================
            if (do_push) begin
                rcy_fifo_mem[rcy_fifo_wptr_q] <= #1 push_cell;
                rcy_fifo_wptr_q <= #1 rcy_fifo_wptr_q + 1'b1;
            end
            if (do_pop) begin
                rcy_fifo_rptr_q <= #1 rcy_fifo_rptr_q + 1'b1;
                free_tail_q     <= #1 rcy_cell;
            end

            unique case ({do_push, do_pop})
                2'b10:   rcy_fifo_cnt_q <= #1 rcy_fifo_cnt_q + 1'b1;
                2'b01:   rcy_fifo_cnt_q <= #1 rcy_fifo_cnt_q - 1'b1;
                default: ;
            endcase

            // free_cnt: enq -1 (含多播 cell), recycle push +1
            unique case ({enq_grant, do_push})
                2'b10:   free_cnt_q <= #1 free_cnt_q - 1'b1;
                2'b01:   free_cnt_q <= #1 free_cnt_q + 1'b1;
                default: ;
            endcase

            //================================================================
            // ★ 老化冲刷: 每 push 一个 cell, 被冲刷队列 cnt -1;
            //   冲刷结束 (最后一 cell push) 清该队列 head/tail/pkt_backlog;
            //   若冲刷的是 MC_QID, 额外清多播槽状态。
            //   假设: 被冲刷队列在冲刷期间 QM 已停发出队/入队 (无同拍冲突)。
            //================================================================
            if (agf_push) begin
                if (q_cell_cnt_q[agf_qid_q] != '0)
                    q_cell_cnt_q[agf_qid_q] <= #1 q_cell_cnt_q[agf_qid_q] - 1'b1;
                // 最后一个 cell (remain==1) push → 收尾清链
                if (agf_remain_q == 1) begin
                    q_head_q[agf_qid_q]            <= #1 '0;
                    q_tail_q[agf_qid_q]            <= #1 '0;
                    q_head_ph_q[agf_qid_q]         <= #1 1'b0;
                    q_head_pt_q[agf_qid_q]         <= #1 1'b0;
                    q_tail_ph_q[agf_qid_q]         <= #1 1'b0;
                    q_tail_pt_q[agf_qid_q]         <= #1 1'b0;
                    q_uni_pkt_backlog_q[agf_qid_q] <= #1 '0;
                    // 冲刷多播专用队列: 清多播槽
                    if (agf_qid_q == MC_QID[QID_W-1:0]) begin
                        mc_valid_q      <= #1 1'b0;
                        mc_dst_bitmap_q <= #1 '0;
                        mc_ncell_q      <= #1 '0;
                        mc_wr_idx_q     <= #1 '0;
                        for (pp = 0; pp < PORT_NUM; pp++) begin
                            mc_rd_done_q[pp]  <= #1 1'b0;
                            mc_rcy_done_q[pp] <= #1 1'b0;
                            mc_pend_uni_q[pp] <= #1 '0;
                            mc_rd_idx_q[pp]   <= #1 '0;
                        end
                    end
                end
                else begin
                    // 队头前进到 next (下一拍继续冲刷)
                    q_head_q[agf_qid_q] <= #1 npr_r_data[2 +: ADDR_W];
                end
            end
        end
    end

    //========================================================================
    // ★ 老化用输出: 队列非空位图 + 出队 fire 喂狗
    //   位宽 QUEUE_NUM (=PORT_NUM*TC_NUM 单播 + 1 多播)
    //   [0..PORT_NUM*TC_NUM-1] : 单播队列 cell 占用 (q_cell_cnt_q[q]!=0)
    //   [MC_QID = QUEUE_NUM-1] : 多播槽占用 (mc_valid_q 或 chain33 SRAM cnt!=0)
    //   用一个覆盖全部 QUEUE_NUM 位的 for 循环, 确保最高位 MC_QID 也被明确赋值。
    //========================================================================
    always_comb begin
        for (int oc = 0; oc < QUEUE_NUM; oc++) begin
            if (oc == MC_QID)
                q_occupied_vec[oc] = mc_valid_q | (q_cell_cnt_q[oc] != '0);
            else
                q_occupied_vec[oc] = (q_cell_cnt_q[oc] != '0);
        end
    end
    assign deq_fire_evt = deq_grant & ~mc_take_deq;   // 真实单播出队 fire (喂狗)
    assign deq_fire_qid = lle_deq_queue_id;

    //========================================================================
    // 对外组合输出 (含多播 splice 覆盖)
    //========================================================================
    logic [ADDR_W-1:0] mc_cur_cell;
    logic              mc_cur_ph, mc_cur_pt;
    assign mc_cur_cell = mc_cells_q[mc_rd_idx_q[deq_port]];
    assign mc_cur_ph   = (mc_rd_idx_q[deq_port] == '0);
    assign mc_cur_pt   = ((mc_rd_idx_q[deq_port] + 1'b1) == mc_ncell_q);

    assign lle_qhead          = mc_take_deq ? mc_cur_cell : q_head_q[lle_deq_queue_id];
    assign lle_qhead_pkt_head = mc_take_deq ? mc_cur_ph   : q_head_ph_q[lle_deq_queue_id];
    assign lle_qhead_pkt_tail = mc_take_deq ? mc_cur_pt   : q_head_pt_q[lle_deq_queue_id];
    // 空: 多播 take 时非空; 否则看单播 cnt (承载队列 pend_uni>0 时必有单播 cell, cnt>0)
    assign lle_q_empty        = mc_take_deq ? 1'b0 : (q_cell_cnt_q[lle_deq_queue_id] == '0);

    //========================================================================
    // ★ B2: 32 条常规队列 empty 向量 (给 QM 调度用)
    //   q_empty[q] = ~( 实际单播 cnt[q]!=0  |  该 q 是某目的端口承载队列且多播未被该端口读完 )
    //   多播只计入【各目的端口的承载队列】(每端口 1 条), 不计入全部 32 条。
    //========================================================================
    always_comb begin
        for (int qq = 0; qq < PORT_NUM*TC_NUM; qq++) begin
            automatic int pq = qq >> Q_PER_PORT_LOG;
            automatic logic mc_here = mc_valid_q & mc_dst_bitmap_q[pq] &
                                      ~mc_rd_done_q[pq] &
                                      (QID_W'(qq) == mc_carry_qid_q[pq]);
            q_empty_vec[qq] = ~((q_cell_cnt_q[qq] != '0) | mc_here);
        end
    end

    //========================================================================
    // ★ 32 条常规队列 "pkt 数为 0" 向量 (给 QM 调度用; 完整包粒度)
    //   q_pkt_empty[q] = ~( 该队列在队真实单播完整包数!=0  |  该 q 是某目的端口承载
    //                       队列且该端口尚未读完多播帧 )
    //   多播是一份帧被多端口共享读, 对每个目的端口而言逻辑上是【1 个完整包】,
    //   故多播的 pkt 数只计入【各目的端口的承载队列】(每端口 1 条), 与 q_empty_vec
    //   的多播计入口径一致。多播未被某端口读完 → 该端口承载队列 pkt 数 +1 → 非空。
    //========================================================================
    always_comb begin
        for (int qq = 0; qq < PORT_NUM*TC_NUM; qq++) begin
            automatic int pq = qq >> Q_PER_PORT_LOG;
            automatic logic mc_pkt_here = mc_valid_q & mc_dst_bitmap_q[pq] &
                                          ~mc_rd_done_q[pq] &
                                          (QID_W'(qq) == mc_carry_qid_q[pq]);
            q_pkt_empty_vec[qq] = ~((q_uni_pkt_backlog_q[qq] != '0) | mc_pkt_here);
        end
    end

    assign lle_free_grant = lle_free_req & ~build_active & ~rcy_fifo_full;
    assign lle_free_done  = rcy_grant;

    localparam int Q_PP_LOG = $clog2(TC_NUM);

    // alloc 事件 (单播用 alloc_queue_id; 多播用 MC_QID → occ 只在 MC_QID 计一次/cell)
    assign lle_alloc_evt   = enq_grant;
    assign evt_queue_id    = lle_alloc_is_mcast ? MC_QID[QID_W-1:0] : lle_alloc_queue_id;
    assign evt_egress_port = lle_alloc_is_mcast ? '0
                             : (lle_alloc_queue_id >> Q_PP_LOG);

    // free 事件: push 那拍 (单播用其 qid; 多播还链用 MC_QID)
    assign lle_free_evt          = do_push;
    assign evt_free_queue_id     = push_qid;
    assign evt_free_egress_port  = (push_qid < (PORT_NUM*TC_NUM)) ? (push_qid >> Q_PP_LOG) : '0;

`ifdef SIM_BEHAVIOR_SRAM
    always_ff @(posedge clk_core) begin
        if (rst_core_n && lle_free_req && rcy_fifo_full && !build_active)
            $warning("[lle] recycle FIFO full: free request ignored");
    end
    always_ff @(posedge clk_core) begin
        if (rst_core_n && enq_grant && (free_cnt_q == '0))
            $error("[lle] free pool underflow: alloc when free_cnt==0");
    end
    always_ff @(posedge clk_core) begin
        if (rst_core_n && mcast_underflow)
            $error("[lle] mcast recycle underflow: port %0d already done", mc_rcy_port);
    end
    always_ff @(posedge clk_core) begin
        if (rst_core_n && enq_grant && lle_alloc_is_mcast && lle_set_pkt_head && mc_valid_q)
            $error("[lle] mcast enqueue while slot busy (should be gated by mc_busy)");
    end
`endif

endmodule


//============================================================================
// 1R1W Next-Ptr SRAM 行为模型 (综合时换 vendor 1R1W SRAM)
//   - 1 读口 + 1 写口, 同拍可并行; 同拍读写同一地址: read-first
//============================================================================
module next_ptr_sram_1r1w #(
    parameter int CELL_NUM = 8192,
    parameter int DATA_W   = 15,
    localparam int ADDR_W  = $clog2(CELL_NUM)
)(
    input  logic              clk_core,
    input  logic              rst_core_n,
    input  logic              r_en,
    input  logic [ADDR_W-1:0] r_addr,
    output logic [DATA_W-1:0] r_data,
    input  logic              w_en,
    input  logic [ADDR_W-1:0] w_addr,
    input  logic [DATA_W-1:0] w_data
);
    logic [DATA_W-1:0] mem [CELL_NUM];
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) r_data <= #1 '0;
        else if (r_en)   r_data <= #1 mem[r_addr];
    end
    always_ff @(posedge clk_core) begin
        if (w_en) mem[w_addr] <= #1 w_data;
    end
endmodule