`timescale 1ns/1ps

module occupancy_pool_mgr #(
    parameter int CELL_NUM  = 8192,
    parameter int QUEUE_NUM = 34,
    parameter int PORT_NUM  = 4,
    parameter int STAT_W    = 32,    // 统计计数器位宽
    // near_full 端口/全局余量 (距高水位多少 cell 即视为快满); 队列用 cfg 滞回
    parameter int QUEUE_NF_MARGIN   = 2,
    //parameter int PORT_NF_MARGIN   = 4,
    parameter int GLOBAL_NF_MARGIN = 8,
    localparam int ADDR_W    = $clog2(CELL_NUM),
    localparam int QID_W     = $clog2(QUEUE_NUM-1)+1,
    localparam int PORT_W    = $clog2(PORT_NUM-1)+1,
    localparam int CNT_W     = ADDR_W+1,    // 占用计数位宽 (0~8192)
    localparam int TC_NUM   = QUEUE_NUM/PORT_NUM
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
    output logic                       occ_accept,           // 判决=接收
    output logic                       occ_drop,             // 判决=丢弃(高水位兜底)
    output logic                       occ_use_static,       // 记静态(=1)/动态(=0)
    output logic                       occ_no_free,          // 空闲池空(强制丢弃)

    //------------------------------------------------------------------------
    // 与 LLE 的接口 (分配/回收事件, 计数 ++/--)
    //------------------------------------------------------------------------
    input  logic                       lle_alloc_evt,        // 分配事件
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
    output logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_req,            // 802.1Qbb PFC.每端口TC反压位图
    output logic [QUEUE_NUM-1:0]       q_near_full,          // 每队列快满(QM 门控+WRED 占用输入)
    //output logic [PORT_NUM-1:0]        port_near_full,       // 每出端口快满
    output logic                       global_near_full,     // 全局快满
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
    input  logic [QUEUE_NUM-1:0][CNT_W-1:0] cfg_q_full,  // 每队列满阈值
    input  logic                            cfg_pause_en,        // PAUSE 使能
    input  logic [PORT_NUM-1:0][CNT_W-1:0]  cfg_port_pause_xoff, //每端口：占用>=此值触发PAUSE
    input  logic [PORT_NUM-1:0][CNT_W-1:0]  cfg_port_pause_xon,  //每端口：占用<此值撤销PAUSE
    input  logic [CNT_W-1:0]            cfg_global_pause_xoff, //全局：占用>=此值触发PAUSE
    input  logic [CNT_W-1:0]            cfg_global_pause_xon,  //全局：占用<此值撤销PAUSE
    input  logic                        cfg_pfc_en,             // PFC使能
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xoff, //每TC：占用>=此值触发PAUSE
    input  logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0]  cfg_pfc_xon,   //每TC：占用>=此值触发PAUSE


    //------------------------------------------------------------------------
    // 统计上报 (→ CSR)
    //------------------------------------------------------------------------
    output logic [CNT_W-1:0]                st_global_used,      // 全局占用
    output logic [CNT_W-1:0]                st_free_count,       // 空闲计数
    output logic [QUEUE_NUM-1:0][CNT_W-1:0] st_q_static_used,    // 每队列静态池占用
    output logic [PORT_NUM-1:0][CNT_W-1:0]  st_per_port_used,    // 每端口占用(端口级聚合)
    output logic [QUEUE_NUM-1:0][CNT_W-1:0] st_per_queue_used,   // 每队列占用
    output logic [QUEUE_NUM-1:0]            st_q_near_full_status,// 快满状态镜像
    output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_tail_drop_cnt,   // 高水位无条件丢包计数
    output logic [QUEUE_NUM-1:0][STAT_W-1:0] st_near_full_assert_cnt,// 快满置位次数
    output logic [PORT_NUM-1:0][STAT_W-1:0]  st_pause_tx_cnt,    // PAUSE 发送计数
    output logic                            overflow_alarm,      // cell 池溢出告警
    output logic                            underflow_alarm      // 守恒/下溢告警
);
    //========================================================================
    // 
    //========================================================================
    localparam Q_PER_PORT = $clog2(TC_NUM);

    //========================================================================
    // 
    //========================================================================
    logic [CNT_W-1:0]  free_count_q;                    //空闲数量
    logic [CNT_W-1:0]  global_used_q;                   //全局使用量 = 总cell数量-free_count_q
    logic [CNT_W-1:0]  q_cell_cnt_q     [QUEUE_NUM];    //每个队列使用量
    logic [CNT_W-1:0]  q_static_used_q  [QUEUE_NUM];    //每个队列静态使用量
    logic [CNT_W-1:0]  per_port_used_q  [PORT_NUM];     //每个port使用量

    logic [QUEUE_NUM-1:0] use_static_vec;

    logic                 alloc_allowed;
    logic                 free_allowed;
    logic                 same_queue_evt;
    logic                 same_port_evt;
    logic [PORT_W-1:0]    alloc_port;
    logic [PORT_W-1:0]    free_port;
    logic [QUEUE_NUM-1:0] q_cell_inc;
    logic [QUEUE_NUM-1:0] q_cell_dec;
    logic [QUEUE_NUM-1:0] q_static_inc;
    logic [QUEUE_NUM-1:0] q_static_dec;
    logic [PORT_NUM-1:0]  port_inc;
    logic [PORT_NUM-1:0]  port_dec;

    logic [PORT_NUM-1:0] pause_set;
    logic [PORT_NUM-1:0] pause_clr;
    logic                global_pause_xoff;
    logic                global_pause_xon;


    //function automatic logic [PORT_W-1:0] qid2port(input logic [QID_W-1:0] qid);
    //    qid2port = qid[QID_W-1 -: PORT_W];
    //endfunction

    always_comb begin
        alloc_allowed  = 1'b0;
        free_allowed   = 1'b0;
        alloc_port     = evt_queue_id >> Q_PER_PORT;
        free_port      = occ_free_queue_id >> Q_PER_PORT;
        same_queue_evt = lle_alloc_evt && occ_free_vld && (evt_queue_id == occ_free_queue_id);
        same_port_evt  = lle_alloc_evt && occ_free_vld && (alloc_port == free_port);

        for (int i = 0; i < QUEUE_NUM; i++) begin
            if (occ_free_vld && (occ_free_queue_id == i) && (q_cell_cnt_q[i] != '0)) begin
                free_allowed = 1'b1;
            end
        end

        for (int i = 0; i < QUEUE_NUM; i++) begin
            if (lle_alloc_evt && (evt_queue_id == i) &&
                ((free_count_q != '0) || free_allowed)) begin
                alloc_allowed = 1'b1;
            end
        end

        q_cell_inc   = '0;
        q_cell_dec   = '0;
        q_static_inc = '0;
        q_static_dec = '0;
        for (int i = 0; i < QUEUE_NUM; i++) begin
            q_cell_inc[i]   = alloc_allowed && (evt_queue_id == i) &&
                              !(same_queue_evt && free_allowed);
            q_cell_dec[i]   = free_allowed && (occ_free_queue_id == i) &&
                              !(same_queue_evt && alloc_allowed);
            q_static_inc[i] = q_cell_inc[i] && use_static_vec[i];
            q_static_dec[i] = q_cell_dec[i] && (q_static_used_q[i] != '0);
        end

        port_inc = '0;
        port_dec = '0;
        for (int i = 0; i < PORT_NUM; i++) begin
            port_inc[i] = alloc_allowed && (alloc_port == i) &&
                          !(same_port_evt && free_allowed);
            port_dec[i] = free_allowed && (free_port == i) &&
                          (per_port_used_q[i] != '0) &&
                          !(same_port_evt && alloc_allowed);
        end
    end



    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                q_cell_cnt_q[i] <= '0;
            end
        end
        else begin
            for (int i = 0; i < QUEUE_NUM; i++) begin
                if (q_cell_inc[i] && !q_cell_dec[i])
                    q_cell_cnt_q[i] <= q_cell_cnt_q[i] + 1'b1;
                else if (!q_cell_inc[i] && q_cell_dec[i])
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
                if (q_static_inc[i] && !q_static_dec[i])
                    q_static_used_q[i] <= q_static_used_q[i] + 1'b1;
                else if (!q_static_inc[i] && q_static_dec[i])
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
                if (port_inc[i] && !port_dec[i])
                    per_port_used_q[i] <= per_port_used_q[i] + 1'b1;
                else if (!port_inc[i] && port_dec[i])
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
            case ({alloc_allowed, free_allowed})
                2'b10: if (free_count_q != '0) begin   // 仅分配
                    free_count_q  <= free_count_q  - 1'b1;
                    global_used_q <= global_used_q + 1'b1;
                end
                2'b01: if (global_used_q != '0) begin  // 仅回收
                    free_count_q  <= free_count_q  + 1'b1;
                    global_used_q <= global_used_q - 1'b1;
                end
                2'b11: begin // 同拍分配+回收: 净不变
                    free_count_q  <= free_count_q;
                    global_used_q <= global_used_q;
                end
                default: ; // 无事件
            endcase
        end
    end
    
    logic hi_wm_drop;
    logic [QUEUE_NUM-1:0] q_hi_wm_vec;     // >= cfg_q_max_cell (tail-drop 阈值)
    logic [PORT_NUM-1:0] port_hi_wm_vec; // per-port 高水位向量

    always_comb begin
        occ_no_free   = (free_count_q == '0);
        global_full     = (global_used_q >= cfg_global_high_wm);

        // 高水位无条件丢弃 (兜底) 或 空闲池空
        occ_drop      = occ_query_vld & (occ_no_free | (~occ_use_static & ));
        occ_accept    = occ_query_vld & ~occ_drop;
        // 双池: 该队列静态额度未用满 → 记静态账
        occ_use_static= use_static_vec[evt_queue_id];
        hi_wm_drop = q_hi_wm_vec[evt_queue_id] | port_hi_wm_vec[evt_queue_id] | global_full;
    end

    always_comb begin
        for (int i = 0; i < QUEUE_NUM; i++) begin
            use_static_vec[i] = q_static_used_q[i] < cfg_queue_min_cell[i];
            q_full[i]         = q_cell_cnt_q[i]    >= cfg_q_full[i];
            q_hi_wm_vec[i]    = q_cell_cnt_q[i]    >= cfg_q_max_cell[i];
        end
    end
    always_comb begin
        for (int i = 0; i < PORT_NUM; i++) begin
            port_full[i]  = per_port_used_q[i]    >= cfg_port_max[i];
            port_hi_wm_vec = = per_port_used_q[i]    >= cfg_port_max[i];
        end
    end
    
    //============================================
    // near_full
    logic [QUEUE_NUM-1:0] q_near_full_set;
    always_comb begin
        for(int i=0;i<QUEUE_NUM;i++) begin
            q_near_full_set[i] = (q_cell_cnt_q[i] >= (cfg_q_max_cell[i]-QUEUE_NF_MARGIN)); 
        end
    end
    always_ff@(posedge clk_core, negedge rst_core_n) begin
        if(!rst_core_n) begin
            q_near_full <= '0;
        end
        else begin
            for(int i=0;i<QUEUE_NUM;i++)begin
                if(q_near_full_set[i])
                    q_near_full <= 1'b1;
                else 
                    q_near_full <= 1'b0;
            end
        end
    end
    logic global_near_full_set;
    always_comb begin
        global_near_full_set = (global_used_q >= (cfg_global_high_wm-GLOBAL_NF_MARGIN));
    end
    always_ff@(posedge clk_core, negedge rst_core_n) begin
        if(!rst_core_n)
            global_near_full <= 1'b0;
        else if (global_near_full_set)
            global_near_full <= 1'b1;
        else
            global_near_full <= 1'b0;
    end



    //============================================
    //PAUSE
    assign  global_pause_xoff = (global_used_q >= cfg_global_pause_xoff);
    assign  global_pause_xon  = (global_used_q <  cfg_global_pause_xon);
    always_comb begin
        for(int i=0;i<PORT_NUM;i++) begin
            pause_set[i] = (per_port_used_q[i] >= cfg_port_pause_xoff[i] | global_pause_xoff); //端口或全局达到xoff
            pause_clr[i] = (per_port_used_q[i] <  cfg_port_pause_xon[i]  & global_pause_xon);  //端口且全局回落xon
        end
    end
    //寄存器迟滞
    always_ff@(posedge clk_core, negedge rst_core_n) begin
        if(!rst_core_n)
            pause_req    <= 1'b0;
        else begin
            for(int i=0;i<PORT_NUM;i++)begin
                if(!cfg_pause_en)
                    pause_req[i]    <= 1'b0;
                else if(pause_set[i])
                    pause_req[i]    <= 1'b1;
                else if(pause_clr[i])
                    pause_req[i]    <= 1'b0;
                // 中间区 保持原值，迟滞
            end
        end
    end

    //============================================
    //PFC
    logic [PORT_NUM-1:0][TC_NUM-1:0][CNT_W-1:0] per_tc_used;
    always_comb begin
        for(int i=0;i<PORT_NUM;i++) begin
            for(int j=0;j<TC_NUM;j++)begin
                per_tc_used[i][j] = q_cell_cnt_q[i*TC_NUM+j];
            end
        end
    end

    logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_set;
    logic [PORT_NUM-1:0][TC_NUM-1:0] pfc_clr;
    always_comb begin
        for(int i=0;i<PORT_NUM;i++)begin
            for(int j=0;j<TC_NUM;j++)begin
                pfc_set[i][j] = per_tc_used[i][j] >= cfg_pfc_xoff[i][j];
                pfc_clr[i][j] = per_tc_used[i][j] <  cfg_pfc_xon[i][j];
            end
        end
    end

    //寄存器迟滞
    always_ff@(posedge clk_core, negedge rst_core_n) begin
        if(!rst_core_n)
            pfc_req    <= 1'b0;
        else begin
            for(int i=0;i<PORT_NUM;i++)begin
                for(int j=0;j<TC_NUM;j++)begin
                    if(!cfg_pfc_en)
                        pfc_req[i][j]    <= 1'b0;
                    else if(pfc_set[i][j])
                        pfc_req[i][j]    <= 1'b1;
                    else if(pfc_clr[i][j])
                        pfc_req[i][j]    <= 1'b0;
                // 中间区 保持原值，迟滞
                end
            end
        end
    end
    //========================================================================
    // 统计输出
    //========================================================================
    assign st_global_used        = global_used_q;
    assign st_free_count         = free_count_q;
    //assign st_q_near_full_status = q_near_full_q;
    //assign st_tail_drop_cnt      = tail_drop_cnt_q;
    //assign st_near_full_assert_cnt = near_full_assert_cnt_q;
    //assign st_pause_tx_cnt       = pause_tx_cnt_q;
    assign st_q_near_full_status = '0;
    assign st_tail_drop_cnt      = '0;
    assign st_near_full_assert_cnt = '0;
    assign st_pause_tx_cnt       = '0;
    always_comb begin
        for (int i = 0; i < QUEUE_NUM; i++) begin
            assign st_q_static_used[i]  = q_static_used_q[i];
            assign st_per_queue_used[i] = q_cell_cnt_q[i];
        end
        for (int i = 0; i < PORT_NUM; i++) begin 
            assign st_per_port_used[i]  = per_port_used_q[i];
        end
    endgenerate
    //========================================================================
    // 守恒 / 溢出 / 下溢 告警
    //========================================================================
    logic conserve_ok;
    assign conserve_ok = ((free_count_q + global_used_q) == CELL_NUM[CNT_W-1:0]);
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            overflow_alarm  <= 1'b0;
            underflow_alarm <= 1'b0;
        end
        else begin
            overflow_alarm  <= (global_used_q > CELL_NUM[CNT_W-1:0]);
            underflow_alarm <= ~conserve_ok
                               | (alloc_allowed & (free_count_q  == '0))
                               | (free_allowed  & (global_used_q == '0));
        end
    end


endmodule
