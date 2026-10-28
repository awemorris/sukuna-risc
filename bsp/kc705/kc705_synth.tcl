# ============================================================================
# Vivado Synthesis & Implementation Script for KC705
# ============================================================================

set project_name "sukuna_kc705"
set part "xc7k325tffg900-2"

create_project -force $project_name ./build_kc705 -part $part

# Add RTL source files
add_files -fileset sources_1 [glob ../../rtl/include/*.vh]
add_files -fileset sources_1 [glob ../../rtl/library/*.v]
add_files -fileset sources_1 [glob ../../rtl/interrupt/*.v]
add_files -fileset sources_1 [glob ../../rtl/mmu/*.v]
add_files -fileset sources_1 [glob ../../rtl/shared_ex/*.v]
add_files -fileset sources_1 [glob ../../rtl/cache/*.v]
add_files -fileset sources_1 [glob ../../rtl/core/*.v]
add_files -fileset sources_1 [glob ../../rtl/bus/*.v]
add_files -fileset sources_1 ../../rtl/sukuna_top.v
add_files -fileset sources_1 ./sukuna_kc705_top.v

# Add Constraints
add_files -fileset constrs_1 ./kc705.xdc

set_property include_dirs [list ../../rtl/include ../../rtl/library] [get_filesets sources_1]
set_property verilog_define [list SYNTH_KINTEX7=1] [get_filesets sources_1]
set_property top sukuna_kc705_top [current_fileset]

# Synthesis
synth_design -top sukuna_kc705_top -part $part
write_checkpoint -force synth.dcp
report_utilization -file synth_utilization.rpt
report_timing_summary -file synth_timing.rpt
