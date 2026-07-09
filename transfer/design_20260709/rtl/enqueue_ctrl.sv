//============================================================================
// Module      : enqueue_ctrl  (Enqueue Control)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
// Description : 入队路径控制 (控制平面)。单拍命令式, 不直接访问指针存储。
//               T0: 收 QM 入队请求 → 组合查 Occupancy 占用判决(当拍返回) →
//                   接收则取 lle_free_head 作分配地址、发一拍 lle_alloc_fire 命令
//                   (挂链/计数/ref 由 LLE 流水) → 判决/地址/sof/eof 在末沿寄存。
//               T1: 输出 alloc_* 结果给 QM。
//               含整帧丢弃 FSM: 本帧某 cell 判丢即置 alloc_drop_ind,
//               本帧后续 cell 全丢。组播 ref_count 初值随命令下发, 单/组播同 1 拍。
//               不做 WRED (WRED 在 QM, QM 发请求前已完成)。
//               静态预留池按队列(queue_id)记账, egress_port 仅供端口级判决聚合。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module enqueue_ctrl #(
    parameter int CELL_NUM  = 8192,
    parameter int PORT_NUM  = 4,
    parameter int TC_NUM    = 8,     // 每端口 TC 数
    parameter int REF_W     = 3,
    parameter int PKT_CELL_W = 4,    // enq_cell_num 位宽 (本包 cell 数)
    // 派生位宽 (与 occupancy_pool_mgr / lle 同源)
    localparam int QUEUE_NUM = PORT_NUM*TC_NUM + 1,   // 单播 P*T + 多播 (free 链在 LLE 内)
    localparam int MC_QID    = QUEUE_NUM-1,           // 多播队列号 (=P*T)
    localparam int ADDR_W   = $clog2(CELL_NUM),
    localparam int CNT_W     = ADDR_W+1,		     // 占用计数位宽 (0~CELL_NUM)
    localparam int QID_W    = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W   = $clog2(PORT_NUM-1)+1,
    localparam int TC_W     = $clog2(TC_NUM)          // enq_queue_id 位宽 (仅 TC)
)(
    //------------------------------------------------------------------------
    // 时钟复位 / 初始化 (公共)
    //------------------------------------------------------------------------
    input  logic                  clk_core,
    input  logic                  rst_core_n,
    input  logic                  init_done,           // =0 拒收 enq_req

    //------------------------------------------------------------------------
    // 与 QM 的接口 (外部, 经 MMU 顶层)
    //------------------------------------------------------------------------
    input  logic                  enq_req,             // 入队请求有效
    input  logic [TC_W-1:0]       enq_queue_id,        // ★ 目标 TC (0..TC_NUM-1); 完整队列={egress_port,queue_id}
    input  logic [PORT_W-1:0]     enq_egress_port,     // 出端口 ID
    input  logic [PKT_CELL_W-1:0] enq_cell_num,        // ★ 本包 cell 数(SOF 有效, 入队前预判用)
    input  logic                  enq_is_mcast,        // 组播标志
    input  logic [PORT_NUM-1:0]   enq_mcast_bitmap,    // 组播出端口位图
    input  logic                  enq_sof,             // 报文首段
    input  logic                  enq_eof,             // 报文尾段
    output logic                  enq_ready,           // 可接请求(init_done 后恒高)
    output logic                  enq_predict_drop,    // ★ 入队前预判: 本包会否触发 alloc_drop(组合当拍返回)
    output logic                  alloc_valid,         // 结果有效
    output logic [ADDR_W-1:0]     alloc_cell_addr,     // 分配地址
    output logic                  alloc_drop_ind,      // 丢包指示(高水位/空闲池空兜底)
    output logic                  alloc_sram_flag,     // 内部 SRAM 存储标志
    output logic                  alloc_pkt_head,      // 报文头 (= enq_sof)
    output logic                  alloc_pkt_tail,      // 报文尾 (= enq_eof)
	output logic [CNT_W-1:0]      enq_q_cell_cnt [QUEUE_NUM],   // 每队列当前占用 cell 数 (→ QM 统计)
    output logic [CNT_W-1:0]      enq_free_count,          // 当前空闲链表 cell 数 (→ QM 统计)

    //------------------------------------------------------------------------
    // 与 Occupancy & Pool Mgr 的接口 (内部, 组合返回支撑 1 拍)
    //   按【当前入队队列/端口】精确判决: 透传 queue_id/egress_port 给 occ,
    //   occ 据此判 该队列/端口 高水位 + 静态穿透, 组合返回。
    //------------------------------------------------------------------------
    output logic                  occ_query_vld,       // 发起占用判决查询
    output logic [QID_W-1:0]      occ_query_queue_id,  // 待判决队列号
    output logic [PORT_W-1:0]     occ_query_egress_port, // 待判决出端口
    output logic [PKT_CELL_W-1:0] occ_query_cell_num,  // 待预判本包 cell 数(透传 enq_cell_num)
    input  logic                  occ_accept,          // 判决=接收
    input  logic                  occ_drop,            // 判决=丢弃(高水位兜底)
    input  logic                  occ_use_static,      // 记静态池(=1)/动态池(=0)
    input  logic                  occ_no_free,         // 空闲池已空(强制丢弃)
    input  logic                  occ_predict_drop,    // occ 组合返回的入队前预判结果
	input  logic [CNT_W-1:0]      occ_free_count,       // 当前空闲池 cell 数 (→ QM 统计)
	input  logic [CNT_W-1:0]      occ_q_cell_cnt [QUEUE_NUM], // 每队列当前占用 cell 数 (→ QM 统计)

    //------------------------------------------------------------------------
    // 与 Link-List Engine (LLE) 的接口 (内部, 单拍命令式分配+挂链)
    //   ★ lle_alloc_ready: LLE 本拍可受理 alloc。
    //     - LLE 仲裁中 deq 占 SRAM 时 = 0, 本模块当拍不发 fire, QM 自动等下拍;
    //     - build 期间 / free 池空时也 = 0。
    //------------------------------------------------------------------------
    input  logic [ADDR_W-1:0]     lle_free_head,       // 当前空闲链头(T0 当拍取)
    input  logic                  lle_free_empty,      // 空闲链空
    input  logic                  lle_alloc_ready,     // LLE 本拍可受理 alloc (含 ~deq 抢占 / ~build / ~free 空)
    input  logic                  mc_busy,             // ★ B2: 多播槽占用中 (LLE 提供), 置1时新多播整帧丢弃
    output logic                  lle_alloc_fire,      // 分配+挂链命令(一拍脉冲)
    output logic [QID_W-1:0]      lle_alloc_queue_id,  // 挂链目标队列
    output logic                  lle_set_pkt_head,    // 写 pkt_head (= enq_sof)
    output logic                  lle_set_pkt_tail,    // 写 pkt_tail (= enq_eof)
    output logic                  lle_alloc_is_mcast,  // 组播标志
    output logic [PORT_NUM-1:0]   lle_alloc_mcast_bitmap, // ★ B2: 组播目的端口位图 → LLE
    output logic [$clog2(TC_NUM)-1:0] lle_alloc_mcast_tc // ★ B2: 组播帧 TC → LLE (定承载队列)
);

    //========================================================================
    // 握手: init_done 后, 还要看 LLE 本拍是否能受理 alloc (deq 抢占时 ready=0)
    //   - enq_ready 反馈给 QM: 0 时 QM 当拍不发 enq_req, 自动重试;
    //   - enq_fire 内部判: enq_req 且 init_done 且 lle 可受理。
    //========================================================================
    assign enq_ready = init_done & lle_alloc_ready;

    // 本拍是否有有效入队请求 (握手成立)
    logic enq_fire;
    assign enq_fire = enq_req & enq_ready;

    //========================================================================
    // ★ 完整队列号合成:
    //   - 单播: 完整队列 = {enq_egress_port, enq_queue_id} = egress_port*TC_NUM + TC
    //   - 多播: 物理挂 MC_QID (q[32]); 承载 TC = enq_queue_id, 目的端口 = enq_mcast_bitmap
    //           (LLE 用 mcast_tc + bitmap 算各端口承载队列, 反映到 QM 的 32 位 empty)
    //========================================================================
    logic [QID_W-1:0] uni_qid_c, full_qid_c;
    assign uni_qid_c  = (QID_W'(enq_egress_port) << TC_W) | QID_W'(enq_queue_id);
    assign full_qid_c = enq_is_mcast ? MC_QID[QID_W-1:0] : uni_qid_c;

    //========================================================================
    // 占用判决查询 (组合, 当拍返回): 透传 vld + 当前队列/端口给 Occupancy,
    //   occ_accept/occ_drop/occ_use_static/occ_no_free 组合返回。
    //========================================================================
    assign occ_query_vld         = enq_fire;
    assign occ_query_queue_id    = full_qid_c;           // ★ 完整队列号 (单播={port,tc}; 多播=MC_QID)
    assign occ_query_egress_port = enq_egress_port;
    // ★ 入队前预判: 透传本包 cell 数给 occ, occ 组合返回预判结果直出给 QM。
    //   纯组合、与 enq_query 同拍, 不依赖 enq_fire (QM 在包首 presenting queue_id+cell_num 即可读)。
    assign occ_query_cell_num    = enq_cell_num;
	assign enq_free_count        = occ_free_count;
	assign enq_q_cell_cnt        = occ_q_cell_cnt;

    //========================================================================
    // ★ B2 单槽门控: 多播帧到达 (SOF) 时若多播槽已占用 (mc_busy) → 整帧丢弃。
    //   mc_busy 由 LLE 提供 (mc_valid 寄存), T0 当拍可读。
    //   非 SOF 的多播后续 cell 靠 frame_drop_q 级联丢弃 (无需再看 mc_busy)。
    //========================================================================
    logic mcast_slot_busy_predict_c;
    assign mcast_slot_busy_predict_c = enq_is_mcast & enq_sof & mc_busy;
    assign enq_predict_drop   = occ_predict_drop | mcast_slot_busy_predict_c;

    //========================================================================
    // 整帧丢弃 FSM: 一帧 (sof~eof) 内任一 cell 判丢则置位并保持到 eof,
    //   本帧后续 cell 在 T0 直接判丢、不取地址、不发 fire。
    //   frame_drop_q: 当前帧已进入"整帧丢弃"状态 (sof 拍判丢后保持到 eof)。
    //========================================================================
    logic frame_drop_q;

    // 本 cell 的丢弃来源:
    //   - occ_drop / occ_no_free / lle_free_empty: 占用水位高水位无条件丢弃 + 空闲池空兜底
    //   - (enq_sof & enq_predict_drop): ★ 入队前预判命中 → 整包放不下, 从包首就整帧丢弃
    //   - frame_drop_q: 本帧此前已判丢 (整帧丢弃保持)
    logic cell_drop_c;       // 本 cell 是否丢弃
    logic accept_c;          // 本 cell 是否真正接收(分配+挂链)

    always_comb begin
        // 默认
        cell_drop_c = 1'b0;
        accept_c    = 1'b0;

        if (enq_fire) begin
            // 已处于整帧丢弃状态 (本帧前序 cell 判丢): 后续 cell 全丢
            if (frame_drop_q) begin
                cell_drop_c       = 1'b1;
            end
            // 本 cell 触发丢弃:
            //   - 逐 cell 高水位无条件丢弃 / 空闲池空;
            //   - ★ 入队前预判命中 (enq_predict_drop) 且为包首(SOF): occ 组合判定本包 N 个
            //     cell 整体放不下 → 从 SOF 起就整帧丢弃, 一个 cell 都不挂链 (避免"前几个
            //     cell 已挂链、到中途才丢"造成的部分挂链遗留)。predict 只在 SOF 采样,
            //     后续 cell 靠 frame_drop_q 级联丢弃。
            //   - 多播槽占用也已合入 enq_predict_drop, 新多播帧从 SOF 整帧丢弃。
            else if (occ_drop | occ_no_free | lle_free_empty | (enq_sof & enq_predict_drop)) begin
                cell_drop_c       = 1'b1;
            end
            // 占用判决接收
            else if (occ_accept) begin
                accept_c = 1'b1;
            end
            // 兜底: 无 accept 也无明确 drop 视为丢弃 (保守)
            else begin
                cell_drop_c       = 1'b1;
            end
        end
    end

    // 整帧丢弃状态更新: 帧首 (sof) 判丢则置位; 帧尾 (eof) 帧结束则清除。
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            frame_drop_q <= 1'b0;
        end
        else if (!init_done) begin
            frame_drop_q <= 1'b0;
        end
        else if (enq_fire) begin
            if (frame_drop_q) begin
                // 整帧丢弃保持中, 到 eof 清除 (本帧结束)
                if (enq_eof) frame_drop_q <= 1'b0;
            end
            else if (cell_drop_c && !enq_eof) begin
                // 本 cell 判丢且帧未结束 → 进入整帧丢弃保持
                frame_drop_q <= 1'b1;
            end
            // 单 cell 帧 (sof&eof 同拍) 判丢: 不需保持, frame_drop_q 维持 0
        end
    end

    //========================================================================
    // LLE 分配+挂链命令 (一拍脉冲): 仅接收时拉高
    //========================================================================
    assign lle_alloc_fire         = accept_c;
    assign lle_alloc_queue_id     = full_qid_c;          // ★ 完整队列号 (单播={port,tc}; 多播=MC_QID)
    assign lle_set_pkt_head       = enq_sof;
    assign lle_set_pkt_tail       = enq_eof;
    assign lle_alloc_is_mcast     = enq_is_mcast;
    assign lle_alloc_mcast_bitmap = enq_mcast_bitmap;    // ★ B2: 目的端口位图 → LLE 置 mc_dst_bitmap
    assign lle_alloc_mcast_tc     = enq_queue_id;        // ★ B2: 多播承载 TC = enq_queue_id

    //========================================================================
    // T1 返回 (寄存一拍): 把 T0 的判决/地址/头尾在末沿寄存, 下一拍输出给 QM。
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            alloc_valid           <= 1'b0;
            alloc_cell_addr       <= '0;
            alloc_drop_ind        <= 1'b0;
            alloc_sram_flag       <= 1'b0;
            alloc_pkt_head        <= 1'b0;
            alloc_pkt_tail        <= 1'b0;
        end
        else begin
            alloc_valid           <= enq_fire;            // 本拍有有效请求 → 下一拍结果有效
            alloc_cell_addr       <= lle_free_head;       // 接收时为分配地址; 丢弃时该字段无意义
            alloc_drop_ind        <= cell_drop_c;
            alloc_sram_flag       <= accept_c;            // 接收且写内部 SRAM
            alloc_pkt_head        <= enq_sof;
            alloc_pkt_tail        <= enq_eof;
        end
    end

endmodule
