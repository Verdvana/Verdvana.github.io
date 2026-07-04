//============================================================================
// Module      : mcast_refcount_mgr  (Multicast Ref-Count Manager)
// Project     : 4-Port 2.5/1G/100M Ethernet Switch - Smart MMU
//
// Description :
//   辅助平面。按 B1 多播模型 (见《MMU_多播处理分析.md》方案 B1) 实现:
//   每个组播 cell 维护 ref_count (4 端口 → 3bit, 0~4)。
//     - 入队(置初值): LLE 同拍转发 mc_set_* 把 ref_count[mc_set_addr] = mc_set_init
//                     ( = popcount(enq_mcast_bitmap), 即该多播 cell 要发往的端口数 )。
//     - 回收(递减)  : Recycle Ctrl 每收到一个端口的 mcast_recycle_req → 发 mc_dec_*,
//                     ref_count[mc_dec_addr]-- ; 减到 0 时拉 mc_ref_zero=1, 表示
//                     "所有目标端口都已发完, 该 cell 可以真正还链 (Recycle Ctrl 据此
//                     向 LLE 发 lle_free_req)"。
//   B1 关键语义: 多播 data cell 的回收 **完全由 ref_count 归零驱动**; 被某端口读取
//   (出队) 不会让 ref_count 变化, 也不会摘链/还链 —— 这是多播相对单播唯一的不同。
//
//   防护:
//     - 下溢检测: 对一个 ref_count 已为 0 的 cell 又收到 mc_dec_req → 视为 double-count
//       / EPS 重复通知错误, 拉 mc_ref_underflow 给上层汇成 underflow_alarm, 并把该 cell
//       ref 钳在 0 (不回绕)。
//     - mc_ref_zero 仅在 "本拍递减后恰好到 0" 时为 1 (脉冲), 供 Recycle Ctrl 当拍判定还链。
//
//   时序:
//     - mc_set / mc_dec 命中同拍写回 ref_count_q (组合算 next, 时序更新), ack 同拍拉高。
//     - mc_set 与 mc_dec 命中同一 cell 同拍属非法用法 (入队与回收不会同拍碰同一新分配
//       cell); 仿真断言捕获。若真同拍, set 优先 (按入队语义重置初值)。
//
// Clock/Reset : clk_core (300MHz, 单时钟域) / rst_core_n (异步复位低有效)
//============================================================================
`timescale 1ns/1ps

module mcast_refcount_mgr #(
    parameter int ADDR_W    = 13,
    parameter int CELL_NUM  = 8192,
    parameter int REF_W     = 3
)(
    //------------------------------------------------------------------------
    // 时钟复位 (公共)
    //------------------------------------------------------------------------
    input  logic                  clk_core,
    input  logic                  rst_core_n,

    //------------------------------------------------------------------------
    // 与 LLE 的接口 (入队同拍置初值)
    //------------------------------------------------------------------------
    input  logic                  mc_set_req,          // 置 ref_count 初值请求
    input  logic [ADDR_W-1:0]     mc_set_addr,         // 目标组播 cell
    input  logic [REF_W-1:0]      mc_set_init,         // ref_count 初值=popcount(bitmap)
    output logic                  mc_set_ack,          // 写完应答

    //------------------------------------------------------------------------
    // 与 Recycle Ctrl 的接口 (回收递减)
    //------------------------------------------------------------------------
    input  logic                  mc_dec_req,          // ref_count-- 请求
    input  logic [ADDR_W-1:0]     mc_dec_addr,         // 目标组播 cell
    output logic                  mc_dec_ack,          // 递减完成
    output logic                  mc_ref_zero,         // 本拍递减后归零(允许真正还链)

    //------------------------------------------------------------------------
    // 防护输出 (汇入 underflow_alarm)
    //------------------------------------------------------------------------
    output logic                  mc_ref_underflow     // 对 ref=0 的 cell 再递减(double-count)
);

    //========================================================================
    // ref_count 存储 (全量 cell, 每 cell REF_W bit)。
    //   说明: 也可只对组播 cell 用小 RegFile/CAM 节面积; 此处用全量寄存器堆,
    //   8192×3bit ≈ 3KB 触发器, 面积可接受, 实现最简、读写当拍可达。
    //========================================================================
    logic [REF_W-1:0] ref_count_q [CELL_NUM];

    //========================================================================
    // 组合读出与 next 计算
    //========================================================================
    logic [REF_W-1:0] dec_cur;       // 递减目标当前值
    logic [REF_W-1:0] dec_next;      // 递减后值
    logic             dec_is_zero_in;// 递减前已为 0 (下溢)

    assign dec_cur        = ref_count_q[mc_dec_addr];
    assign dec_is_zero_in = (dec_cur == '0);
    // 递减: >0 时 -1; =0 时钳 0 (下溢, 不回绕)
    assign dec_next       = dec_is_zero_in ? '0 : (dec_cur - 1'b1);

    //========================================================================
    // 应答 / 归零 / 下溢 (组合, 当拍给)
    //   - mc_dec_ack : 收到递减请求即应答 (无阻塞)。
    //   - mc_ref_zero: 本拍递减后恰好到 0 (dec_cur==1 且非下溢) → 允许还链。
    //   - underflow  : 对 ref 已为 0 的 cell 又来递减。
    //========================================================================
    assign mc_set_ack      = mc_set_req;
    assign mc_dec_ack      = mc_dec_req;
    assign mc_ref_zero     = mc_dec_req & ~dec_is_zero_in & (dec_next == '0);
    assign mc_ref_underflow= mc_dec_req &  dec_is_zero_in;

    //========================================================================
    // 写回 ref_count_q
    //   - set 命中: ref[set_addr] = set_init   (入队置初值, 优先)
    //   - dec 命中: ref[dec_addr] = dec_next   (回收递减, 钳 0)
    //   - set 与 dec 同拍命中同一 cell: set 优先 (非法用法, 仿真断言)。
    //========================================================================
    always_ff @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            for (int i = 0; i < CELL_NUM; i++)
                ref_count_q[i] <= #1 '0;
        end
        else begin
            // 递减先写 (若与 set 同 cell, 下面 set 覆盖, 实现 set 优先)
            if (mc_dec_req)
                ref_count_q[mc_dec_addr] <= #1 dec_next;
            // 置初值 (优先级高于同拍同 cell 的 dec)
            if (mc_set_req)
                ref_count_q[mc_set_addr] <= #1 mc_set_init;
        end
    end

`ifdef SIM_BEHAVIOR_SRAM
    //========================================================================
    // 仿真断言
    //========================================================================
    always_ff @(posedge clk_core) begin
        if (rst_core_n) begin
            // 1) double-count: 对 ref=0 的 cell 递减
            if (mc_ref_underflow)
                $error("[mcast_refcount_mgr] REF UNDERFLOW: dec on cell %0d whose ref_count==0",
                       mc_dec_addr);
            // 2) set/dec 同拍命中同一 cell (非法: 入队与回收不应同拍碰同一 cell)
            if (mc_set_req && mc_dec_req && (mc_set_addr == mc_dec_addr))
                $error("[mcast_refcount_mgr] set & dec same cell %0d in same cycle (illegal)",
                       mc_set_addr);
        end
    end
`endif

endmodule