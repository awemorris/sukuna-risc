# ============================================================================
# Vivado Batch P&R (Implementation) Script for KC705
# ============================================================================

set_param general.maxThreads 2
set out_dir "./build_kc705"

# Open synthesis checkpoint
open_checkpoint $out_dir/synth.dcp

# 1. Logic Optimization
opt_design

# 2. Placement
place_design

# 3. Post-Place Physical Optimization
phys_opt_design

# 4. Routing
route_design

# 5. Write Checkpoint and Reports
write_checkpoint -force $out_dir/route.dcp
report_utilization -file $out_dir/route_utilization.rpt -pb $out_dir/route_utilization.pb
report_timing_summary -file $out_dir/route_timing.rpt -max_paths 10

# 6. Extract Fmax
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
puts "Vivado KC705 P&R (Route) completed successfully."
puts "Fmax               : $fmax MHz (Slack: $wns ns, Data Path: $path_delay ns)"
puts "Utilization report : $out_dir/route_utilization.rpt"
puts "Timing report      : $out_dir/route_timing.rpt"
puts "===FINAL_ROUTE_RESULT: FMAX=$fmax : SLACK=$wns : DELAY=$path_delay ==="
puts "======================================================================"
