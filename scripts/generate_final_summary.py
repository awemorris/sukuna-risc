#!/usr/bin/env python3
import os
import sys
import re
import json

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

def parse_module(mod_name):
    mod_dir = os.path.join(BUILD_DIR, mod_name)
    timing_file = os.path.join(mod_dir, "timing.rpt")
    util_file = os.path.join(mod_dir, "util.rpt")
    log_file = os.path.join(mod_dir, "vivado.log")

    fmax = "N/A"
    wns = "N/A"
    delay = "N/A"
    src = "N/A"
    dst = "N/A"
    is_clocked = 0

    # Parse timing.rpt
    if os.path.exists(timing_file):
        with open(timing_file) as fp:
            tcontent = fp.read()

        # Check if clocked: looks for clk constraint or Slack
        mWNS = re.search(r"Slack\s*\(([A-Z]+)\)\s*:\s*(-?[\d\.]+)\s*ns", tcontent)
        if mWNS:
            wns_val = float(mWNS.group(2))
            wns = f"{wns_val:+.3f}"
            is_clocked = 1
            period = 5.000 - wns_val
            if period > 0:
                fmax = f"{1000.0 / period:.2f}"
        
        mDelay = re.search(r"Data Path Delay:\s*([\d\.]+)ns", tcontent)
        if mDelay:
            delay = f"{float(mDelay.group(1)):.3f}"
            if fmax == "N/A" and float(delay) > 0:
                fmax = f"{1000.0 / float(delay):.2f}"

        mSrc = re.search(r"Source:\s*(\S+)", tcontent)
        if mSrc:
            src = mSrc.group(1)
        mDst = re.search(r"Destination:\s*(\S+)", tcontent)
        if mDst:
            dst = mDst.group(1)

    # Fallback to vivado.log SUMMARY_JSON
    if (fmax == "N/A" or delay == "N/A") and os.path.exists(log_file):
        with open(log_file) as fp:
            lcontent = fp.read()
        m = re.search(r"===SUMMARY_JSON:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*:\s*(\S+)\s*===", lcontent)
        if m:
            _, fmax_s, delay_s, wns_s, src_s, dst_s, is_clk_s = m.groups()
            if fmax == "N/A" and fmax_s != "N/A": fmax = fmax_s
            if delay == "N/A" and delay_s != "N/A": delay = delay_s
            if wns == "N/A" and wns_s != "N/A": wns = wns_s
            if src == "N/A" and src_s != "N/A": src = src_s
            if dst == "N/A" and dst_s != "N/A": dst = dst_s
            if is_clk_s in ["0", "1"]: is_clocked = int(is_clk_s)

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
        "success": (fmax != "N/A"),
        "fmax": fmax,
        "delay": delay,
        "wns": wns,
        "src": src,
        "dst": dst,
        "is_clocked": is_clocked,
        "luts": luts,
        "ffs": ffs,
        "brams": brams,
        "dsps": dsps
    }

def main():
    results = []
    for mod in MODULE_CATEGORIES:
        r = parse_module(mod)
        results.append(r)

    json_path = os.path.join(BUILD_DIR, "ooc_results.json")
    with open(json_path, "w") as fp:
        json.dump(results, fp, indent=2)

    cat_order = [
        "Top SoC", "Top Core", "Core Pipeline", "Execution Units",
        "Shared Execution", "Memory & Cache", "MMU",
        "Interrupt & Bus", "Library Macro"
    ]

    def sort_key(r):
        cat_idx = cat_order.index(r['category']) if r['category'] in cat_order else 99
        try:
            fm = float(r['fmax'])
        except:
            fm = 0.0
        return (cat_idx, -fm)

    sorted_results = sorted(results, key=sort_key)

    md_file = os.path.join(BUILD_DIR, "ooc_summary.md")
    with open(md_file, "w") as fp:
        fp.write("# Sukuna-RISC Out-Of-Context (OOC) Synthesis & Timing Benchmark\n\n")
        fp.write("- **Target FPGA Device**: AMD/Xilinx Kintex-7 KC705 (`xc7k325tffg900-2`)\n")
        fp.write("- **Synthesis Tool**: Vivado 2026.1 Batch OOC Logic Synthesis (P&R omitted)\n")
        fp.write("- **Reference Clock Target**: 200.00 MHz (Period: 5.000 ns)\n\n")
        fp.write("| # | Category | Module Name | Type | Fmax (MHz) | Delay (ns) | Slack (ns) | Slice LUTs | Slice FFs | BRAM | DSP | Status |\n")
        fp.write("|:---:|:---|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|\n")

        passed_count = 0
        total_count = len(sorted_results)

        for i, r in enumerate(sorted_results, start=1):
            clk_type = "Seq" if r['is_clocked'] else "Comb"
            try:
                fm_float = float(r['fmax'])
                if fm_float >= 200.0:
                    status = "✅ PASS"
                    fmax_val = f"**{r['fmax']}**"
                    passed_count += 1
                else:
                    status = "❌ FAIL"
                    fmax_val = f"{r['fmax']}"
            except:
                status = "⚠️ N/A"
                fmax_val = f"{r['fmax']}"

            fp.write(f"| {i} | {r['category']} | `{r['module']}` | {clk_type} | {fmax_val} | {r['delay']} | {r['wns']} | {r['luts']} | {r['ffs']} | {r['brams']} | {r['dsps']} | {status} |\n")

        fp.write(f"\n**Total Modules**: {total_count} | **Passed (>= 200MHz)**: {passed_count}/{total_count} ({passed_count/total_count*100:.1f}%)\n")

    print(f"[*] Processed {len(results)} modules. Summary written to {md_file}")

if __name__ == "__main__":
    main()
