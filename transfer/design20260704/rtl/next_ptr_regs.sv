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
module next_ptr_regs #(
	parameter		NPTR_NUM		= 8192,			// Cell address width,
    parameter		ADDR_W			= $clog(NPTR_NUM),
	parameter		NPTR_W		    = 4				// Ptr width
)(
	// Clock and reset
	input	wire											clk,			// Clock
	input	wire											rst_n,			// Async reset
    // 
    input   wire                                            nptr_we,
    input   wire                                            nptr_ce,
    input   wire    [ADDR_W-1:0]                            nptr_addr,
    output  logic   [NPTR_W-1:0]                            nptr_wdata,
    input   wire    [NPTR_W-1:0]                            nptr_rdata
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
    logic   [NPTR_W-1:0]        nprt_regs [NPTR_NUM];

    //=========================================================================
	//
    always_ff@(posedge clk, negedge rst_n)begin
        if(!rst_n) begin
            for(int i = 0;i<NPTR_NUM;i++)
                nprt_regs[i]    <= #TCO '0;
        end
        else if(nptr_we && nptr_ce)begin
            nprt_regs[nptr_addr]    <= #TCO nptr_wdata;
        end
    end

    always_comb begin
        if(!nptr_we && nptr_ce)
            nptr_rdata  = nprt_regs[nptr_addr];
        else 
            nptr_rdata  = '0;
    end


endmodule
