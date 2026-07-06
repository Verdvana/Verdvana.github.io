
#========================================
#Clock Constraint
#Clock clk - Main clock
set JITTER [expr 0.5 + 0 + 0.5]
set SETUP_UNCERTAINTY [expr $ct_budget(md.skew) + $ct_budget(md.noise) + $JITTER + (10 - $ct_budget(md.skew) - $ct_budget(md.noise) - $JITTER) * $SETUP_MARGIN]
set HOLD_UNCERTAINTY [expr $ct_budget(md.skew) + $ct_budget(md.noise) + $HOLD_MARGIN]
create_clock -name clk -period 10 [get_ports clk]
set_ideal_network [get_ports clk]
set_dont_touch_network [get_ports clk]
set_drive 0 [get_ports clk]
set_clock_uncertainty  -setup $SETUP_UNCERTAINTY [get_clocks clk]
set_clock_uncertainty  -hold $HOLD_UNCERTAINTY [get_clocks clk]
set_clock_transition  -max $ct_budget(md.trans.max) [get_clocks clk]
set_clock_transition  -min $ct_budget(md.trans.min) [get_clocks clk]
set_clock_latency -source -max $ct_budget(md.source_latency.max) [get_clocks clk]
set_clock_latency -source -min $ct_budget(md.source_latency.min) [get_clocks clk]
set_clock_latency -max $ct_budget(md.network_latency.max) [get_clocks clk]
if {$ct_budget(md.network_latency.min) ne "NA"} {
    set_clock_latency -min $ct_budget(md.network_latency.min) [get_clocks clk]
}
#Clock v_clk - Virtual clock of Main clock
#----------------------------------------
create_clock -name v_clk -period 10
#----------------------------------------
#Set var
#----------------------------------------
#Set clock groups
set_clock_groups -asynchronous  -group {clk v_clk}