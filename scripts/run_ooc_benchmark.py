#!/usr/bin/env python3
# ============================================================================
# Sukuna-RISC Out-Of-Context (OOC) Synthesis & Timing Benchmark Runner
# ============================================================================

import os
import sys
import glob
import re
import json
import time
import subprocess
from concurrent.futures import ProcessPoolExecutor, as_completed

MODULE_CATEGORIES = {
    # 1. Core Pipeline & Units
    "sk_rvc_dec": "Core Pipeline",
    "sukuna_hazard_unit": "Core Pipeline",
    "sukuna_regfile": "Core Pipeline",
    "sukuna_fregfile": "Core Pipeline",
    "sukuna_stage_if1": "Core Pipeline",
    "sukuna_stage_if2": "Core Pipeline",
    "sukuna_stage_id1": "Core Pipeline",
    "sukuna_stage_id2": "Core Pipeline",
    "sukuna_stage_id3": "Core Pipeline",
    "sukuna_stage_ex": "Core Pipeline",
    "sukuna_stage_wb": "Core Pipeline",
    "sukuna_int_eu": "Execution Units",
    "sukuna_agu_eu": "Execution Units",
    "sukuna_fp_unit": "Execution Units",
    "sukuna_csr_unit": "Core Pipeline",
    "sukuna_thread_pipe": "Core Pipeline",
    "sukuna_core": "Top Core",

    # 2. Shared Execution
    "sukuna_shared_arbiter": "Shared Execution",
    "sukuna_fma_eu": "Shared Execution",
    "sukuna_fp_eu": "Shared Execution",
    "sukuna_cfp_eu": "Shared Execution",
    "sukuna_simd_eu": "Shared Execution",
    "sukuna_shared_ex": "Shared Execution",

    # 3. Cache & Memory Subsystem
    "sukuna_l1i_cache": "Memory & Cache",
    "sukuna_l1d_cache": "Memory & Cache",
    "sukuna_l1d_coherence": "Memory & Cache",
    "sukuna_l1_subsys": "Memory & Cache",
    "sukuna_l2_cache": "Memory & Cache",
    "sukuna_l2_arbiter": "Memory & Cache",

    # 4. MMU
    "sukuna_l1_tlb": "MMU",
    "sukuna_l2_tlb": "MMU",
    "sukuna_ptw": "MMU",
    "sukuna_mmu": "MMU",

    # 5. Interrupts & Bus
    "sukuna_clint": "Interrupt & Bus",
    "sukuna_plic": "Interrupt & Bus",
    "sukuna_interrupt_subsys": "Interrupt & Bus",
    "sukuna_biu_axi4": "Interrupt & Bus",

    # 6. Library Math & Primitives
    "sk_add": "Library Macro",
    "sk_addsub": "Library Macro",
    "sk_sub": "Library Macro",
    "sk_mul": "Library Macro",
    "sk_div": "Library Macro",
    "sk_shift": "Library Macro",
    "sk_fma": "Library Macro",
    "sk_msb": "Library Macro",
    "sk_ram_dist": "Library Macro",
    "sk_ram_bram": "Library Macro",
    "sk_ram_ff": "Library Macro",
    "sk_rst_sync": "Library Macro",

    # 7. Sukuna Top
    "sukuna_top": "Top SoC",
}

ROOT_DIR = "/home/awe/sukuna-risc"
BUILD_DIR = os.path.join(ROOT_DIR, "build", "ooc")
VIVADO_SETTINGS = "/home/awe/opt/amd/2026.1/Vivado/settings64.sh"
VIVADO_UBUNTU_LIB = "/home/awe/opt/amd/2026.1/Vivado/lib/lnx64.o/Ubuntu/24"

def run_single_ooc(mod_name):
    mod_dir = os.path.join(BUILD_DIR, mod_name)
    os.makedirs(mod_dir, exist_ok=True)
    tcl_file = os.path.join(mod_dir, "run_synth.tcl")
    log_file = os.path.join(mod_dir, "vivado.log")
    util_file = os.path.join(mod_dir, "util.rpt")
    timing_file = os.path.join(mod_dir, "timing.rpt")

    tcl_script = f"""
set_param general.maxThreads 2
set part "xc7k325tffg900-2"
set top  "{mod_name}"
set out_dir "{mod_dir}"

# Read RTL files (excluding sk_dsp48e1_sim.v to use native Xilinx DSP primitives)
foreach f [glob -nocomplain {ROOT_DIR}/rtl/library/*.v] {{
    if {{[file tail $f] ne "sk_dsp48e1_sim.v"}} {{
        read_verilog $f
    }}
}}
read_verilog [glob -nocomplain {ROOT_DIR}/rtl/interrupt/*.v]
read_verilog [glob -nocomplain {ROOT_DIR}/rtl/mmu/*.v]
read_verilog [glob -nocomplain {ROOT_DIR}/rtl/shared_ex/*.v]
read_verilog [glob -nocomplain {ROOT_DIR}/rtl/cache/*.v]
read_verilog [glob -nocomplain {ROOT_DIR}/rtl/core/*.v]
read_verilog [glob -nocomplain {ROOT_DIR}/rtl/bus/*.v]
read_verilog {ROOT_DIR}/rtl/sukuna_top.v

synth_design -mode out_of_context -top $top -part $part \\
  -include_dirs [list {ROOT_DIR}/rtl/include {ROOT_DIR}/rtl/library] \\
  -verilog_define [list SYNTH_KINTEX7=1 PADDR_WIDTH=40 L1I_WAYS=4 L1D_WAYS=4 L2_WAYS=8 L1I_SIZE_BYTES=16384 L1D_SIZE_BYTES=16384 L2_SIZE_BYTES=262144]

set clk_ports [get_ports -quiet -filter {{NAME =~ "*clk*"}}]
set is_clocked 0
if {{[llength $clk_ports] > 0}} {{
    set is_clocked 1
    create_clock -period 5.000 -name clk [lindex $clk_ports 0]
}}

report_utilization -file $out_dir/util.rpt
report_timing_summary -file $out_dir/timing.rpt -max_paths 1

set wns "N/A"
set fmax "N/A"
set path_delay "N/A"
set src "N/A"
set dst "N/A"

set paths [get_timing_paths -max_paths 1]
if {{[llength $paths] > 0}} {{
    set p [lindex $paths 0]
    set wns [get_property -quiet SLACK $p]
    set path_delay [get_property -quiet DATAPATH_DELAY $p]
    set src [get_property -quiet STARTPOINT_PIN $p]
    set dst [get_property -quiet ENDPOINT_PIN $p]
    if {{$wns ne ""}} {{
        set period [expr {{5.000 - $wns}}]
        if {{$period > 0}} {{
            set fmax [format "%.2f" [expr {{1000.0 / $period}}]]
        }}
    }} elseif {{$path_delay ne ""}} {{
        if {{$path_delay > 0}} {{
            set fmax [format "%.2f" [expr {{1000.0 / $path_delay}}]]
        }}
    }}
}}

puts "===SUMMARY_JSON: {mod_name} : [format "%s" $fmax] : [format "%s" $path_delay] : [format "%s" $wns] : [format "%s" $src] : [format "%s" $dst] : $is_clocked ==="
exit
"""
    with open(tcl_file, "w") as fp:
        fp.write(tcl_script)

    cmd = (
        f"source {VIVADO_SETTINGS} && "
        f"LD_LIBRARY_PATH={VIVADO_UBUNTU_LIB}:$LD_LIBRARY_PATH "
        f"vivado -mode batch -source {tcl_file} -log {log_file} -jou {mod_dir}/vivado.jou"
    )

    t0 = time.time()
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    elapsed = time.time() - t0

    # Parse JSON output and util.rpt
    fmax = "N/A"
    delay = "N/A"
    wns = "N/A"
    src = "N/A"
    dst = "N/A"
    is_clocked = 0

    stdout_str = res.stdout + "\n" + res.stderr
    m = re.search(r"===SUMMARY_JSON:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*===", stdout_str)
    if m:
        _, fmax, delay, wns, src, dst, is_clk_str = m.groups()
        is_clocked = int(is_clk_str)

    # Parse util.rpt
    luts = 0
    ffs = 0
    brams = 0
    dsps = 0
    if os.path.exists(util_file):
        with open(util_file) as fp:
            ucontent = fp.read()
        mLUT = re.search(r"\|\s*Slice LUTs\s*\*?\s*\|\s*(\d+)", ucontent)
        if mLUT: luts = int(mLUT.group(1))
        mFF = re.search(r"\|\s*Slice Registers\s*\|\s*(\d+)", ucontent)
        if mFF: ffs = int(mFF.group(1))
        mBRAM = re.search(r"\|\s*Block RAM Tile\s*\|\s*(\d+)", ucontent)
        if mBRAM: brams = int(mBRAM.group(1))
        mDSP = re.search(r"\|\s*DSPs\s*\|\s*(\d+)", ucontent)
        if mDSP: dsps = int(mDSP.group(1))

    return {
        "module": mod_name,
        "category": MODULE_CATEGORIES.get(mod_name, "Other"),
        "success": (res.returncode == 0 and fmax != "N/A"),
        "fmax": fmax,
        "delay": delay,
        "wns": wns,
        "src": src,
        "dst": dst,
        "is_clocked": is_clocked,
        "luts": luts,
        "ffs": ffs,
        "brams": brams,
        "dsps": dsps,
        "elapsed_sec": round(elapsed, 1)
    }

def main():
    modules = list(MODULE_CATEGORIES.keys())
    print(f"[*] Starting Out-of-Context (OOC) Synthesis for {len(modules)} modules...")
    print(f"[*] Vivado location: {VIVADO_SETTINGS}")
    print(f"[*] Output directory: {BUILD_DIR}")

    # Use 6 parallel Vivado processes (each gets ~8-10 cores out of 64)
    results = []
    t_start = time.time()
    with ProcessPoolExecutor(max_workers=6) as executor:
        futures = {executor.submit(run_single_ooc, mod): mod for mod in modules}
        for future in as_completed(futures):
            mod = futures[future]
            try:
                res = future.result()
                results.append(res)
                fmax_str = f"{res['fmax']} MHz" if res['fmax'] != "N/A" else "Failed/Comb"
                clk_str = "Seq" if res['is_clocked'] else "Comb"
                print(f"[+] [{len(results)}/{len(modules)}] {mod:<24s} | {clk_str:4s} | Fmax: {fmax_str:<12s} | LUT: {res['luts']:<6d} | FF: {res['ffs']:<6d} | DSP: {res['dsps']:<3d} | ({res['elapsed_sec']}s)")
            except Exception as e:
                print(f"[-] Error on {mod}: {e}")

    total_time = round(time.time() - t_start, 1)
    print(f"\n[*] All {len(modules)} modules synthesized in {total_time}s.")

    # Save raw json
    results_json = os.path.join(BUILD_DIR, "ooc_results.json")
    with open(results_json, "w") as fp:
        json.dump(results, fp, indent=2)

    # Sort results by category, then Fmax descending
    def sort_key(r):
        cat_order = [
            "Top SoC", "Top Core", "Core Pipeline", "Execution Units",
            "Shared Execution", "Memory & Cache", "MMU",
            "Interrupt & Bus", "Library Macro"
        ]
        cat_idx = cat_order.index(r['category']) if r['category'] in cat_order else 99
        try:
            fm = float(r['fmax'])
        except:
            fm = 0.0
        return (cat_idx, -fm)

    sorted_results = sorted(results, key=sort_key)

    # Generate Markdown Summary
    md_file = os.path.join(BUILD_DIR, "ooc_summary.md")
    with open(md_file, "w") as fp:
        fp.write("# Sukuna-RISC Out-Of-Context (OOC) Synthesis & Timing Benchmark\n\n")
        fp.write(f"- **Target FPGA Device**: AMD/Xilinx Kintex-7 KC705 (`xc7k325tffg900-2`)\n")
        fp.write(f"- **Synthesis Tool**: Vivado 2026.1 Batch OOC Synthesis\n")
        fp.write(f"- **Reference Clock Target**: 200.00 MHz (Period: 5.000 ns)\n\n")
        fp.write("| Category | Module Name | Type | Fmax (MHz) | Delay (ns) | Slack (ns) | Slice LUTs | Slice FFs | BRAM | DSP | Critical Path (Src -> Dst) |\n")
        fp.write("|:---|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---|\n")

        for r in sorted_results:
            clk_type = "Seq" if r['is_clocked'] else "Comb"
            fmax_val = f"**{r['fmax']}**" if r['fmax'] != "N/A" and float(r['fmax']) >= 200 else f"{r['fmax']}"
            cpath = f"`{r['src']}` -> `{r['dst']}`" if r['src'] != "N/A" else "-"
            fp.write(f"| {r['category']} | `{r['module']}` | {clk_type} | {fmax_val} | {r['delay']} | {r['wns']} | {r['luts']} | {r['ffs']} | {r['brams']} | {r['dsps']} | {cpath} |\n")

    print(f"[*] Summary generated at: {md_file}")

if __name__ == "__main__":
    main()
