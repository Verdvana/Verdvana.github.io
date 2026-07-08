
#========================================
#Reset Constraint
set_ideal_network [get_port rst_n]
set_dont_touch_network [get_port rst_n]
set_drive 0 [get_port rst_n]
set_false_path -from [get_port rst_n]