# ============================================================================
# Vivado Batch Synthesis Script for KC705 (Kintex-7 xc7k325tffg900-2)
# ============================================================================

set_param general.maxThreads 2
set part "xc7k325tffg900-2"
set top  "sukuna_kc705_top"
set out_dir "./build_kc705"

file mkdir $out_dir

# 1. Read Design Sources
foreach f [glob -nocomplain ../../rtl/library/*.v] {
    if {[file tail $f] ne "sk_dsp48e1_sim.v" && [file tail $f] ne "sk_designware_sim.v"} {
        read_verilog $f
    }
}
read_verilog [glob -nocomplain ../../rtl/interrupt/*.v]
read_verilog [glob -nocomplain ../../rtl/mmu/*.v]
read_verilog [glob -nocomplain ../../rtl/shared_ex/*.v]
read_verilog [glob -nocomplain ../../rtl/cache/*.v]
read_verilog [glob -nocomplain ../../rtl/core/*.v]
read_verilog [glob -nocomplain ../../rtl/bus/*.v]
read_verilog ../../rtl/sukuna_top.v
read_verilog ./sukuna_kc705_top.v

# 2. Read Timing and Physical Constraints
read_xdc ./kc705.xdc

# 3. Run Synthesis
synth_design -top $top -part $part \
  -include_dirs [list ../../rtl/include ../../rtl/library] \
  -verilog_define [list SYNTH_KINTEX7=1 SYNTH_VIVADO=1 PADDR_WIDTH=40 L1I_WAYS=4 L1D_WAYS=4 L2_WAYS=8 L1I_SIZE_BYTES=16384 L1D_SIZE_BYTES=16384 L2_SIZE_BYTES=262144]

# 4. Write Checkpoint and Reports
write_checkpoint -force $out_dir/synth.dcp
report_utilization -file $out_dir/synth_utilization.rpt -pb $out_dir/synth_utilization.pb
report_timing_summary -file $out_dir/synth_timing.rpt -max_paths 10

# 5. Extract Fmax
set wns "N/A"
set fmax "N/A"
set path_delay "N/A"
set paths [get_timing_paths -max_paths 1]
if {[llength $paths] > 0} {
    set p [lindex $paths 0]
    set wns [get_property -quiet SLACK $p]
    set path_delay [get_property -quiet DATAPATH_DELAY $p]
    if {$wns ne ""} {
        set period [expr {5.000 - $wns}]
        if {$period > 0} {
            set fmax [format "%.2f" [expr {1000.0 / $period}]]
        }
    } elseif {$path_delay ne ""} {
        if {$path_delay > 0} {
            set fmax [format "%.2f" [expr {1000.0 / $path_delay}]]
        }
    }
}

puts "======================================================================"
puts "Vivado KC705 synthesis completed successfully."
puts "Fmax               : $fmax MHz (Slack: $wns ns, Data Path: $path_delay ns)"
puts "Utilization report : $out_dir/synth_utilization.rpt"
puts "Timing report      : $out_dir/synth_timing.rpt"
puts "===FINAL_TOP_RESULT: FMAX=$fmax : SLACK=$wns : DELAY=$path_delay ==="
puts "======================================================================"
