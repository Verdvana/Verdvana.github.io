//=============================================================================
// Module Name:						enqueue_ctrl
// Function Description:			Enqueue control logic
// Author:							Jinyin Yan
// Email:							jinyyan@qti.qualcomm.com
//-----------------------------------------------------------------------------
// Version 	Design		Coding		Simulate	Review		Rel date
// V1.0		Jinyyan		Jinyyan		Jinyyan		Jinyyan		2025-06-22				
//-----------------------------------------------------------------------------
// Version	Modified History
// V1.0		
//=============================================================================

// Include

// Define
//`define			FPGA_EMU

//Module
module enqueue_ctrl #(
	parameter		QID_W			= 8,			// Queue ID width
	parameter		PORT_W			= 4,			// Egress port width
	parameter		COLOR_W			= 2,			// Color width
	parameter		BMAP_W			= 16,			// Multicast bitmap width
	parameter		ADDR_W			= 16,			// Cell address width
	parameter		REFCNT_W		= 4				// Multicast ref-count width
)(
	// Clock and reset
	input	wire											clk,			// Clock
	input	wire											rst_n,			// Async reset
	input	wire											init_done,		// Init done
	// QM(TOP) to enqueue_ctrl
	input	wire											enq_req,		// Enqueue request
	input 	wire	[QID_W-1:0]								enq_queue_id,	// Enqueue queue id
	input	wire	[PORT_W-1:0]							enq_egress_port,// Enqueue egress port
	input	wire											enq_is_mcast,	// Enqueue is multicast
	input	wire 	[COLOR_W-1:0]							enq_color,		// Enqueue color
	input	wire	[BMAP_W-1:0]							enq_mcast_bitmap,	// Enqueue multicast bitmap
	input	wire	                                        enq_sof,			// Enqueue start of frame
	input	wire	                                        enq_eof,			// Enqueue end of frame
	// enqueue_ctrl to QM(TOP)
	output	logic											enq_ready,		// Enqueue ready
	output	logic	 										alloc_valid,	// Allocate valid
	output	logic	[ADDR_W-1:0]							alloc_cell_addr,// Allocate address
	output	logic											allco_drop_ind,	// Allocate drop indication
	output	logic											alloc_sram_flag,// Allocate sram flag
	output	logic											alloc_pkt_head,	// Allocate packet head
	output	logic											alloc_pkt_tail,	// Allocate packet tail
	output	logic											alloc_full_frame_drop,	// Allocate full frame drop
	// enqueue_ctrl <=> Occupancy & Pool Manager
	output	logic											occ_query_vld,	// Occupancy query valid
	output	logic	[QID_W-1:0]								occ_query_qid,	// Occupancy query queue id
	output	logic	[PORT_W-1:0]							occ_query_egress_port,	// Occupancy query port
	output	logic	[COLOR_W-1:0]							occ_query_color,	// Occupancy query color
	input	wire											occ_accept,		// Occupancy accept
	input	wire											occ_drop,		// Occupancy drop
	input	wire											occ_use_static,	// Occupancy use static; 0=static, 1=dynamic
	input	wire											occ_no_free,	// Occupancy no free
	// enqueue_ctrl <=> LLE
	output	logic											lle_alloc_req,	// LLE allocate request
	output	logic	[QID_W-1:0]								lle_alloc_qid,	// LLE allocate queue id
	output	logic											lle_set_pkt_head,	// LLE set packet head
	output	logic											lle_set_pkt_tail,	// LLE set packet tail
	//input	wire											lle_alloc_grant,	// LLE allocate grant
	input	wire	[ADDR_W-1:0]							lle_alloc_addr,	// LLE allocate address
	input	wire											lle_alloc_done,	// LLE allocate done
	// enqueue_ctrl <=> Multicast Ref-Count Manager
	output	logic											mcast_set_req,	// Multicast set request
	output	logic	[ADDR_W-1:0]							mcast_set_addr,	// Multicast set address
	output	logic	[REFCNT_W-1:0]							mcast_set_init,	// Multicast set initial ref-count
	input	wire											mcast_set_ack	// Multicast set acknowledge
);

	//=========================================================================
	// The time unit and precision of the internal declaration
	timeunit		1ns;
	timeprecision	1ps;


	//=========================================================================
	// Parameter
	localparam		TCO			= 0.06;										// Simulate the delay of the register

	//=========================================================================
	// Signal
	logic	[QID_W-1:0]								req_queue_id_q;		// Latched request queue id
	logic	[PORT_W-1:0]							req_egress_port_q;	// Latched request egress port
	logic	[COLOR_W-1:0]							req_color_q;		// Latched request color
	logic											req_is_mcast_q;		// Latched request is multicast
	logic	[BMAP_W-1:0]							req_mcast_bitmap_q;	// Latched request multicast bitmap
	logic											req_sof_q;			// Latched request start of frame
	logic											req_eof_q;			// Latched request end of frame

	logic	[ADDR_W-1:0]							alloc_addr_q;		// Latched allocate cell address
	logic											drop_ind_q;			// Latched drop indication
	logic											frame_drop_q;		// Latched frame drop indication
	logic	[REFCNT_W-1:0]							mcast_count_q;		// Latched multicast ref-count

	function automatic logic [REFCNT_W-1:0] count_ones(
		input logic [BMAP_W-1:0] bitmap
	);
		count_ones = '0;
		for(integer i = 0; i < BMAP_W; i = i + 1)
			count_ones = count_ones + bitmap[i];
	endfunction

	//=========================================================================
	// FSM
	//-------------------------------------------------------------------------
	// FSM: State definition
	enum logic [2:0] {
		S_IDLE,
        S_QUERY,
		S_ALLOC,
		S_MCSET,
		S_OUTOUT,
		S_DROP,
		S_X='x
	} curr_state, next_state;
	//-------------------------------------------------------------------------
	// FSM: State transition
	always_ff@(posedge clk or negedge rst_n) begin
		if(!rst_n)
			curr_state <= S_IDLE;
		else
			curr_state <= next_state;
	end
	//-------------------------------------------------------------------------
	// FSM: Next state logic
	always_comb begin
		next_state = curr_state;
		case(curr_state)
			S_IDLE: begin
				if(init_done && enq_req)	// Only accept request when init_done
					if(frame_drop_q)		// If the frame has been dropped, go to S_DROP state directly
						next_state = S_DROP;
					else
						next_state = S_QUERY;
			end
			S_QUERY: begin
				if(occ_accept && !occ_no_free && !occ_drop)	// If the occupancy query is accepted and there is free space, go to S_ALLOC state
					next_state = S_ALLOC;
				else
					next_state = S_DROP;
			end
			S_ALLOC: begin
				if(lle_alloc_done)	// If the LLE allocate is done, go to S_MCSET state if it is multicast, otherwise go to S_OUTOUT state
					if(req_is_mcast_q)
						next_state = S_MCSET;
					else
						next_state = S_OUTOUT;
			end
			S_MCSET: begin
				if(mcast_set_ack)	// If the multicast set is acknowledged, go to S_OUTOUT state
					next_state = S_OUTOUT;
			end
			S_OUTOUT: begin
				next_state = S_IDLE;
			end
			S_DROP: begin
				next_state = S_IDLE;
			end
			default: begin
				next_state = S_IDLE;
			end
		endcase
	end
	//=========================================================================
	// Latched QM request
	always_ff@(posedge clk, negedge rst_n) begin
		if(!rst_n) begin
			req_queue_id_q <= #TCO '0;
			req_egress_port_q <= #TCO '0;
			req_color_q <= #TCO '0;
			req_is_mcast_q <= #TCO 1'b0;
			req_mcast_bitmap_q <= #TCO '0;
			req_sof_q <= #TCO 1'b0;
			req_eof_q <= #TCO 1'b0;
		end
		else if(curr_state == S_IDLE && enq_req && init_done) begin	// Only latch the request when init_done
			req_queue_id_q <= #TCO enq_queue_id;
			req_egress_port_q <= #TCO enq_egress_port;
			req_color_q <= #TCO enq_color;
			req_is_mcast_q <= #TCO enq_is_mcast;
			req_mcast_bitmap_q <= #TCO enq_mcast_bitmap;
			req_sof_q <= #TCO enq_sof;
			req_eof_q <= #TCO enq_eof;
		end
	end
	// Count during S_QUERY and register the result before it is used in S_MCSET.
	always_ff@(posedge clk, negedge rst_n) begin
		if(!rst_n)
			mcast_count_q <= #TCO '0;
		else if(curr_state == S_QUERY)
			mcast_count_q <= #TCO count_ones(req_mcast_bitmap_q);
	end
	//=========================================================================
	// Latched allocate address
	always_ff@(posedge clk,negedge rst_n) begin
		if(!rst_n) begin
			alloc_addr_q <= #TCO '0;
		end
		else if(curr_state == S_ALLOC && lle_alloc_done) begin
			alloc_addr_q <= #TCO lle_alloc_addr;
		end
	end
	//=========================================================================
	// Latched drop indication
	always_ff@(posedge clk,negedge rst_n) begin
		if(!rst_n) begin
			drop_ind_q <= #TCO 1'b0;
		end
		else if(curr_state == S_IDLE && init_done && enq_req) begin
				drop_ind_q <= #TCO frame_drop_q;
		end
		else if(curr_state == S_QUERY) begin
				drop_ind_q <= #TCO (occ_drop || occ_no_free || !occ_accept);
		end
	end
	//=========================================================================
	// Latched frame drop indication
	always_ff@(posedge clk,negedge rst_n) begin
		if(!rst_n) begin
			frame_drop_q <= #TCO 1'b0;
		end
		else if(curr_state == S_IDLE && init_done && enq_req && enq_sof) begin
				frame_drop_q <= #TCO '0;
		end
		else if(curr_state == S_QUERY || occ_drop || occ_no_free || !occ_accept) begin
				frame_drop_q <= #TCO req_eof_q;
		end
		else if(curr_state == S_OUTOUT && req_eof_q) begin
				frame_drop_q <= #TCO '0;
		end
	end
	//=========================================================================
	// Output logic
	assign	occ_query_vld = (curr_state == S_QUERY);
	assign	occ_query_qid = req_queue_id_q;
	assign	occ_query_egress_port = req_egress_port_q;
	assign	occ_query_color = req_color_q;
	assign	lle_alloc_req = (curr_state == S_ALLOC);
	assign	lle_alloc_qid = req_queue_id_q;
	assign	lle_set_pkt_head = req_sof_q;
	assign	lle_set_pkt_tail = req_eof_q;
	assign	mcast_set_req = (curr_state == S_MCSET);
	assign	mcast_set_addr = alloc_addr_q;
	assign	mcast_set_init = mcast_count_q;
	assign	enq_ready = (curr_state == S_IDLE) && init_done;
	assign	alloc_valid = (curr_state == S_OUTOUT);
	assign	alloc_cell_addr = alloc_addr_q;
	assign	alloc_drop_ind = drop_ind_q && (curr_state == S_OUTOUT);
	assign	alloc_sram_flag	= (curr_state == S_OUTOUT) && !drop_ind_q;
	assign	alloc_pkt_head = req_sof_q && (curr_state == S_OUTOUT);
	assign	alloc_pkt_tail = req_eof_q && (curr_state == S_OUTOUT);
	assign	alloc_full_frame_drop = frame_drop_q && drop_ind_q && (curr_state == S_OUTOUT);

endmodule
