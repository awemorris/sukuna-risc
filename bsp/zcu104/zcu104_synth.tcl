# ============================================================================
# Vivado Synthesis & Implementation Script for ZCU104
# ============================================================================

set project_name "sukuna_zcu104"
set part "xczu7ev-ffvc1156-2-e"

create_project -force $project_name ./build_zcu104 -part $part

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
add_files -fileset sources_1 ./sukuna_zcu104_top.v

# Add Constraints
add_files -fileset constrs_1 ./zcu104.xdc

set_property include_dirs [list ../../rtl/include ../../rtl/library] [get_filesets sources_1]
set_property top sukuna_zcu104_top [current_fileset]

# Synthesis
synth_design -top sukuna_zcu104_top -part $part
write_checkpoint -force synth.dcp
report_utilization -file synth_utilization.rpt
report_timing_summary -file synth_timing.rpt
