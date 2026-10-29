# Sukuna-RISC RTL and Coding Style Guide (style.md)
==================================================

This document specifies the unified coding standards, memory and arithmetic abstraction rules, and microarchitectural disciplines for the Sukuna-RISC repository.

The codebase is dual-targeted:
1. **ASIC Target**: Modern **5nm standard-cell process at 1.5 GHz** (base) with headroom for 2.0 GHz+ (boost).
2. **FPGA Prototyping Target**: **Xilinx Kintex-7 -2 (`xc7k325tffg900-2` / KC705)** at **200 MHz to 250 MHz**.

---

## 1. Verilog Language and Naming Standards

### 1.1 Language Standard
- **Verilog-2005 (IEEE 1364-2005)** only.
- Strict subset accepted by Icarus Verilog (`-g2005`), Verilator (`--lint-only -Wall`), and Vivado Synthesis.
- No SystemVerilog in `rtl/` or `bsp/`.
- Every source file begins with:
  ```verilog
  `timescale 1ns / 1ps
  `default_nettype none
  ```
  and terminates with:
  ```verilog
  `default_nettype wire
  ```

### 1.2 Module Organization and File Naming
- Exactly **one module per file**, with the filename matching the module name (`<module_name>.v`).
- Module prefixes:
  - `sukuna_`: Core processor blocks, pipeline stages, cache subsystems, MMU, interrupts, bus, and top-level (`sukuna_core`, `sukuna_stage_if1`, `sukuna_l1d_cache`, `sukuna_plic`, `sukuna_top`).
  - `sk_`: Reusable datapath cells, arithmetic units, memory macros, and synchronization primitives in `rtl/library/` (`sk_add`, `sk_mul`, `sk_ram_bram`, `sk_ram_dist`, `sk_ram_ff`, `sk_rst_sync`, `sk_shift`).
- Port declarations use **ANSI C style**:
  ```verilog
  module sukuna_example #(
    parameter XLEN = `XLEN
  )(
    input  wire            clk_i,
    input  wire            rst_ni,
    input  wire [XLEN-1:0] data_i,
    output reg  [XLEN-1:0] data_o
  );
  ```

### 1.3 Signal Naming Conventions
- `_i`: Input ports (`clk_i`, `rst_ni`, `req_valid_i`, `data_i`).
- `_o`: Output ports (`resp_valid_o`, `data_o`).
- `_q`: Sequential register outputs (flip-flops updated on `posedge clk_i`).
- `_d`: Combinational next-state signals driving a `_q` register.
- `_w`: Internal intermediate wires.

### 1.4 Clocking and Resets
- Standard reset is **asynchronous active-low (`rst_ni`)**.
- Clock domain crossings and external asynchronous resets must pass through `sk_rst_sync` (2-stage synchronizer).
- Sequential logic uses:
  ```verilog
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
    end else begin
      state_q <= state_d;
    end
  end
  ```
- Combinational logic uses `always @(*)` with blocking assignments (`=`) or continuous `assign` statements. Latches are strictly forbidden.

### 1.5 Parameter and Constant Hygiene
- Bare numerical literals must specify explicit bit width (e.g. `32'd0`, `64'h8000_0000`, `1'b1`).
- Global architecture constants (e.g. `XLEN`, `PADDR_WIDTH`, `CACHE_LINE_BITS`) must be referenced from `sukuna_defines.vh`.

---

## 2. Memory & Register Array Rules (Strict Synthesis Invariance)

### 2.1 Prohibition of Raw Arrays and Large Registers
To ensure portability between FPGA block/distributed RAMs and ASIC compiled SRAM/register-file macros, and to prevent accidental high-fanout multiplexer trees:
- **Raw unpacked array registers (`reg [...] mem [0:D-1];`) are strictly prohibited** in general RTL code.
- **Sequential registers wider than 128 bits (`reg [W-1:0]` where $W > 128$) are strictly prohibited**.
- All memories, FIFOs, register files, and large storage arrays must instantiate an explicit memory macro from `rtl/library/`:

| Memory Type | Macro Module | Read Latency & Timing | Primary Use Cases | FPGA Target | ASIC Target |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **BRAM** | `sk_ram_bram` | **Synchronous (1–2 cycles)**<br>Pipelined read only | L1I, L1D, and L2 Cache Data Arrays | Block RAM (RAMB36/18) | Single/Dual-Port SRAM Macro |
| **Distributed RAM** | `sk_ram_dist` | **Synchronous (1 cycle)**<br>Pipelined read only | Cache Tag Arrays (L1I/L1D/L2), TLB, BPU/branch tables, small queues | LUT RAM (SLICEM) | Latch Array / Standard-Cell Macro |
| **FF RAM** | `sk_ram_ff` | **Asynchronous (0 cycle)**<br>Combinational read | Integer/FP Register Files (GPR/FPR), multi-port holding buffers, pipeline isolation buffers | Individual Flip-Flops (D-FF) | Standard-Cell D-FF Array |

### 2.2 Mandatory Synthesis Directive for Registers <= 128 Bits
All scalar and vector registers of 128 bits or less (`reg [...] name_q;`) must append the identical block-comment directive at the end of their declaration line to prevent unwanted inferencing into Block RAM or Shift Register LUTs (SRL16/SRL32):

```verilog
/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
```

- **Example**:
  ```verilog
  reg [XLEN-1:0] pc_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0]     inst_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg            valid_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  ```
- **ASIC Migration**: For Synopsys Design Compiler or other ASIC toolchains, this string is replaced in batch via:
  ```bash
  sed -i 's|/\* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" \*/|/* synopsys preserve_sequential */|g' rtl/**/*.v
  ```

---

## 3. Arithmetic Cell Abstraction

To ensure that arithmetic operations map to dedicated FPGA DSP slices (DSP48E1) or ASIC high-performance data-path generators (e.g. Synopsys DesignWare `DW01_*`), raw arithmetic operators on variable signals (`+`, `-`, `*`, `/`, `%`, variable `<<`, `>>`, `>>>`) are **not written directly on fabric signals**. Modules instantiate the abstracted cells in `rtl/library/`:

- `sk_add`: Addition with configurable implementation (`IMPL = "CARRY" / "LOGIC" / "DSP"`).
- `sk_sub`: Subtraction with configurable borrow/carry.
- `sk_addsub`: Dynamic add/subtract selection.
- `sk_mul`: High-speed multiplier (DSP48E1 cascade on FPGA, parallel-prefix tree on ASIC), pipelined with latency $\ge 2$.
- `sk_div`: Multi-cycle integer division.
- `sk_fma`: Fused Multiply-Add ($A \times B + C$).
- `sk_shift`: Barrel shifter (SLL, SRL, SRA).
- `sk_msb`: Leading-zero counter / priority encoder.

*(Note: Constant additions like `pc + 4`, loop indices, and parameter calculations are exempt from this rule).*

---

## 4. High-Frequency ASIC Scaling (Target: 5nm 1.5 GHz)

### 4.1 Timing Budget Breakdown (1.5 GHz, $T_{\text{clk}} = 667\,\text{ps}$)
In modern 5nm FinFET processes, interconnect wire resistance and capacitance (RC) dominate delay, accounting for 40% to 50% of the clock period:
- **Clock Tree & Setup Overhead**: $T_{\text{cq}} + T_{\text{setup}} + \text{Clock Skew/Jitter} + \text{OCV Margin} \approx 150 - 180\,\text{ps}$.
- **Interconnect Wire RC Delay**: Chip-level and inter-cell routing parasitics $\approx 200 - 250\,\text{ps}$.
- **Net Usable Standard-Cell Logic Delay**: $\approx 250 - 310\,\text{ps}$.
- At an inverter FO4 delay of $\approx 10 - 12\,\text{ps}$ in 5nm, each clock cycle permits at most **20–25 FO4 delays (roughly 8–10 stages of NAND/NOR/AOI gates)**.

### 4.2 Structural Design Rules for 1.5 GHz

#### Rule 1: Logic Level & Adder Budget
- Pure random combinational paths must not exceed **3 LUT6 levels** (hard ceiling: 4 LUT6 levels).
- **64-bit Addition**: A 64-bit adder uses $\approx 180 - 200\,\text{ps}$ in 5nm. Therefore, 64-bit address generation (e.g., ADDR stage `base + offset`) must be allocated its **own dedicated pipeline cycle**. It must never be cascaded with TLB lookups or cache array indexing within the same cycle.

#### Rule 2: Fanout Limitation & Tree Buffering
- High fanout causes exponential transition and RC wire degradation in deep submicron nodes.
- High-fanout registers driving wide datapaths or control buses across multiple thread pipelines must be constrained to a target fanout of **$\le 16$** (hard ceiling: 24).
- Global control signals (`stall`, `flush`, `valid`, `ready`) spanning multiple execution units must use register replication or explicit tree buffering (`(* max_fanout = 16 *)`).

#### Rule 3: Flop-to-Flop Inter-Module Boundaries
- **Zero combinational feedthrough across module hierarchy boundaries**:
  Combinational logic must never pass through multiple hierarchical levels (e.g. L2 Cache $\to$ L1 Arbiter $\to$ L1D Cache $\to$ Core AGU).
- Every major inter-module interface (L2-to-L1, L1-to-Core, Core-to-Shared-EX) must be cleanly isolated by a registered interface at either the transmitting boundary (output register) or the receiving boundary (input register).

#### Rule 4: Clean Pipelined Memory Boundaries
- **Memory Address Inputs**: Address registers must drive memory macros cleanly.
- **Memory Data Outputs**: Memory macro read outputs must be registered into clean holding buffers before entering wide multiplexers, byte-alignment rotators, or sign-extension circuits. Data formatting is executed in the subsequent pipeline cycle.

#### Rule 5: Backpressure Decoupling (Skid Buffers)
- Handshake interfaces (`valid` / `ready`) must never permit reverse `ready` signals to ripple combinationally across multiple pipeline stages.
- When backpressure must be held, an elastic holding/skid register must decouple the upstream `valid` from the downstream `ready`.

---

## 5. Core Pipeline Invariance & Register Insertion Restrictions

### 5.1 Strict Invariance of Core Pipeline Depth
- **The number of stages in the core pipeline (IF1, IF2, ID1, ID2, ID3, EX, WB) is strictly invariant and must NOT be changed arbitrarily.**
- Arbitrarily splitting stages or altering the core pipeline depth impacts branch misprediction penalties, hazard detection, bypass networks, and ISA commit timings across the entire processor architecture.

### 5.2 Prohibition of Direct Register Insertion
- **Arbitrarily inserting flip-flops / pipeline registers into the core pipeline is strictly prohibited.**
- Adding registers alters the architectural latency between instruction issue, execution, forwarding paths, and retirement.
- If timing closure requires an additional cycle or pipeline stage insertion:
  1. **DO NOT insert registers directly or autonomously.**
  2. **You MUST consult the user first** with detailed timing breakdown, rationale, and proposed architectural impacts, and obtain explicit user approval before proceeding.

---

## 6. FPGA Verification Surrogate Metric

On the Xilinx Kintex-7 speedgrade -2 (`xc7k325tffg900-2` / KC705):
- Achieving **out-of-context (OOC) and top-level timing closure at 200 MHz to 250 MHz** ($T_{\text{clk}} = 4.0 - 5.0\,\text{ns}$ with Worst Negative Slack $\text{WNS} \ge 0.000\,\text{ns}$) while strictly conforming to these structural rules serves as the verified gate ensuring timing closure at **1.5 GHz on 5nm ASIC**.

---

## 7. Board, Clocking, and BSP Guidelines

- **No Logic Clock Dividers**: Clock division using fabric counters or toggling flip-flops is strictly prohibited. All internal clocks must originate from dedicated clock management tiles (MMCM / PLL) riding global clock networks (`BUFG`).
- **Differential Clock Input**: The KC705 board 200 MHz differential system clock (`sysclk_p`, `sysclk_n`) must be received via a dedicated `IBUFDS` primitive feeding an MMCM/PLL or `BUFG`.
- **Target BSP Localization**: All board-specific constraints and wrappers reside in `bsp/kc705/`.

---

## 8. Verification & Tooling Standards

- **Regression Simulation**: The testbench suite must compile and pass cleanly under Icarus Verilog (`make sim`).
- **Batch Synthesis**: Vivado batch scripts must set explicit multi-threading limits (`set_param general.maxThreads 2`) to ensure reproducible builds on shared compute nodes.
- **Build Artifacts**: Generated logs, checkpoints (`.dcp`), reports, and bitstreams are directed to `build/` directories and must never be committed to source control.
