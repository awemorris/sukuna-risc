Sukuna-RISC
===========

`Sukuna RISC` is an RTL CPU implementation.

The name `Sukuna` comes from `Sukunahikona`, literally meaning "Small Genius," with a double meaning of "reduced."

Overall Architecture:
- ISA: RISC-V RV64G (RV64IMAFD + Zicsr + Zifencei, pure 32-bit fixed-length instructions)
- Pipeline: In-order, Asymmetric Dual-issue, 3-SMT, 1-core/3-thread, 7-9 staged pipeline (IF1-IF2-ID1-ID2-ID3-EX-WB),
- Cache: L1I 48KB (16KB/thread), L1D 48KB (16KB/thread), shared L2 256KB
- Clock: 1.7GHz on 5nm ASIC, 450MHz on 16nm FPGA, 250MHz on 28nm FPGA
- Size: 30,000 LUTs for FPGAs

Threading Strategy:
- 1-thread for kernel: handles interrupts and devices
- 1-thread for foreground task: handles the main thread of the foreground app
- 1-thread for background tasks: background apps, services, secondary threads of the foreground app

Pipeline:
```
T1 Pipeline:  T1-IF1 --> T1-IF2 --> T1-ID1 --> T1-ID2 --> T1-ID3 --> [Shared EX] --> T1-WB
T2 Pipeline:  T2-IF1 --> T2-IF2 --> T2-ID1 --> T2-ID2 --> T2-ID3 --> [Shared EX] --> T2-WB
T3 Pipeline:  T3-IF1 --> T3-IF2 --> T3-ID1 --> T3-ID2 --> T3-ID3 --> [Shared EX] --> T3-WB

ID1: Instruction Decode 1 (Zero-mux register fetch request & basic decode)
ID2: Instruction Decode 2 (Parallel hazard check & swap determination)
ID3: Instruction Decode 3 (Bypass resolution & operand swap steering)

Issue Slot

  - Slot0: INT
  - Slot1: MA, FP, SIMD
  - INT + MA can be dual-issued when MA-EU is not stalled
  - FP and SIMD let the thread pipline stall until an EU gets available

  - Other pairs are not dual-issued

Shared EX Block: (variable-cycle)

  INT EUs: (1-cycle, no-crossbar, thread:EU=1:1)
    INT1 EU:  --> ALU1 -->
    INT2 EU:  --> ALU2 -->
    INT3 EU:  --> ALU3 -->

  FP EUs: (variable-cycle)
    FP-EU1:   --> FPU1 -->   (fixed latency)
    FMA-EU1:  --> FMA2 -->   (fixed latency)
    CFP-EU1:  --> CFPU1 -->  (complex fp function, variable latency)

  MA EUs: (2-cycle, no-crossbar, thread:EU=1:1, 1-bubble follows ld/st)
    MA-EU1:   --> ADDR1 -> MA1 --> T1-L1D --> L2
    MA-EU2:   --> ADDR2 -> MA2 --> T2-L1D --> L2
    MA-EU3:   --> ADDR3 -> MA3 --> T3-L1D --> L2

  SIMD EUs:
    SIMD-EU1: --> SIMD1 -->   (variable latency)

SIMD Unit:

  - Vector register file locates in the SIMD Unit.
  - This separates VR fetch from the main pipeline.
```

MMU
```
[ T1 Pipeline ] --> [ micro L1-TLB (8 ent) ] 
[ T2 Pipeline ] --> [ micro L1-TLB (8 ent) ] --> [ Shared L2-TLB 256 ent) ] --> [ Shared PTW ]
[ T3 Pipeline ] --> [ micro L1-TLB (8 ent) ] 
```

## Eliminating RVC

Instruction compression (RVC: 16-bit compressed instructions) is
inherently a trade-off technique designed to maximize instruction
cache hit rates and effective bandwidth in environments where memory
hierarchy bandwidth is severely constrained.

In a processor architecture with well-provisioned instruction cache,
L2 cache, and memory interconnect bandwidth, adopting RVC introduces
disproportionate hardware penalties:

- **Variable-length boundary detection**: Identifying variable 16-bit
    vs. 32-bit instructions at arbitrary 2-byte granularities.

- **Cross-boundary instruction reassembly**: Heavy multi-entry fetch
    buffers required to reconstruct instructions that straddle 64-bit
    cache line boundaries.

- **Dynamic shifting and speculative decompression for dual-issue**:
    The start position of the second instruction dynamically depends
    on the length of the first instruction, requiring parallel
    speculative decompression trees (C2 vs. C4 candidates) and wide
    multiplexing logic.

- **Instruction address misaligned exceptions**: Complex handling of
    non-4-byte-aligned branch targets and trap vectors.

These factors concentrate logic complexity and wiring congestion directly into the instruction fetch (IF) stages, unnecessarily bloating the logic footprint and becoming the primary bottleneck that degrades maximum operating frequency ($F_{\max}$).

By decisively committing to **RV64G (32-bit fixed-length instructions)
and dropping RVC ("C")**:

- The fetch-to-decode structure is dramatically streamlined.

- All instruction addresses and PC increments are strictly 4-byte (or
  8-byte) aligned. Dual-issue slot extraction becomes trivial, fixed
  wire slicing (`[31:0]` for slot 0, `[63:32]` for slot 1).

- The core eliminates all RVC decompressors and complicated dynamic
  buffer shifters, unleashing the true potential of an ultra-fast,
  lean, and clean RISC architecture.
