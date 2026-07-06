
#========================================
#IO Constraint
set_input_delay -clock v_clk -max 5.0 [get_ports init_done]
set_input_delay -clock v_clk -max 5.0 [get_ports enq_req]
set_input_delay -clock v_clk -max 5.0 [get_ports enq_queue_id]
set_input_delay -clock v_clk -max 5.0 [get_ports enq_egress_port]
set_input_delay -clock v_clk -max 5.0 [get_ports enq_is_mcast]
set_input_delay -clock v_clk -max 5.0 [get_ports enq_color]
set_input_delay -clock v_clk -max 5.0 [get_ports enq_mcast_bitmap]
set_input_delay -clock v_clk -max 5.0 [get_ports enq_sof]
set_input_delay -clock v_clk -max 5.0 [get_ports enq_eof]
set_output_delay -clock v_clk -max 5.0 [get_ports enq_ready]
set_load -max 0.02 [get_ports enq_ready]
set_output_delay -clock v_clk -max 5.0 [get_ports alloc_valid]
set_load -max 0.02 [get_ports alloc_valid]
set_output_delay -clock v_clk -max 5.0 [get_ports alloc_cell_addr]
set_load -max 0.02 [get_ports alloc_cell_addr]
set_output_delay -clock v_clk -max 5.0 [get_ports allco_drop_ind]
set_load -max 0.02 [get_ports allco_drop_ind]
set_output_delay -clock v_clk -max 5.0 [get_ports alloc_sram_flag]
set_load -max 0.02 [get_ports alloc_sram_flag]
set_output_delay -clock v_clk -max 5.0 [get_ports alloc_pkt_head]
set_load -max 0.02 [get_ports alloc_pkt_head]
set_output_delay -clock v_clk -max 5.0 [get_ports alloc_pkt_tail]
set_load -max 0.02 [get_ports alloc_pkt_tail]
set_output_delay -clock v_clk -max 5.0 [get_ports alloc_full_frame_drop]
set_load -max 0.02 [get_ports alloc_full_frame_drop]
set_output_delay -clock v_clk -max 5.0 [get_ports occ_query_vld]
set_load -max 0.02 [get_ports occ_query_vld]
set_output_delay -clock v_clk -max 5.0 [get_ports occ_query_qid]
set_load -max 0.02 [get_ports occ_query_qid]
set_output_delay -clock v_clk -max 5.0 [get_ports occ_query_egress_port]
set_load -max 0.02 [get_ports occ_query_egress_port]
set_output_delay -clock v_clk -max 5.0 [get_ports occ_query_color]
set_load -max 0.02 [get_ports occ_query_color]
set_input_delay -clock v_clk -max 5.0 [get_ports occ_accept]
set_input_delay -clock v_clk -max 5.0 [get_ports occ_drop]
set_input_delay -clock v_clk -max 5.0 [get_ports occ_use_static]
set_input_delay -clock v_clk -max 5.0 [get_ports occ_no_free]
set_output_delay -clock v_clk -max 5.0 [get_ports lle_alloc_req]
set_load -max 0.02 [get_ports lle_alloc_req]
set_output_delay -clock v_clk -max 5.0 [get_ports lle_alloc_qid]
set_load -max 0.02 [get_ports lle_alloc_qid]
set_output_delay -clock v_clk -max 5.0 [get_ports lle_set_pkt_head]
set_load -max 0.02 [get_ports lle_set_pkt_head]
set_output_delay -clock v_clk -max 5.0 [get_ports lle_set_pkt_tail]
set_load -max 0.02 [get_ports lle_set_pkt_tail]
set_input_delay -clock v_clk -max 5.0 [get_ports lle_alloc_grant]
set_input_delay -clock v_clk -max 5.0 [get_ports lle_alloc_addr]
set_input_delay -clock v_clk -max 5.0 [get_ports lle_alloc_done]
set_output_delay -clock v_clk -max 5.0 [get_ports mcast_set_req]
set_load -max 0.02 [get_ports mcast_set_req]
set_output_delay -clock v_clk -max 5.0 [get_ports mcast_set_addr]
set_load -max 0.02 [get_ports mcast_set_addr]
set_output_delay -clock v_clk -max 5.0 [get_ports mcast_set_init]
set_load -max 0.02 [get_ports mcast_set_init]
set_input_delay -clock v_clk -max 5.0 [get_ports mcast_set_ack]
#----------------------------------------
#Set var
set NON_CLK_INPUT_PORTS [get_ports -quiet " init_done enq_req enq_queue_id enq_egress_port enq_is_mcast enq_color enq_mcast_bitmap enq_sof enq_eof occ_accept occ_drop occ_use_static occ_no_free lle_alloc_grant lle_alloc_addr lle_alloc_done mcast_set_ack"]
set NON_CLK_OUTPUT_PORTS [get_ports -quiet " enq_ready alloc_valid alloc_cell_addr allco_drop_ind alloc_sram_flag alloc_pkt_head alloc_pkt_tail alloc_full_frame_drop occ_query_vld occ_query_qid occ_query_egress_port occ_query_color lle_alloc_req lle_alloc_qid lle_set_pkt_head lle_set_pkt_tail mcast_set_req mcast_set_addr mcast_set_init"]
#----------------------------------------
#Set input
set_driving_cell -lib_cell ${SIGNAL_DRIVE_CELL} -pin ${SIGNAL_DRIVE_PIN} -library ${SIGNAL_LIB_NAME} ${NON_CLK_INPUT_PORTS}
#----------------------------------------
#Set output

#----------------------------------------
#Set false path
set_false_path -from ${NON_CLK_INPUT_PORTS} -thr ${NON_CLK_OUTPUT_PORTS}