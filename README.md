Sukuna-RISC
===========

`Sukuna RISC` is an RTL CPU implementation.

The name `Sukuna` comes from `Sukunahikona`, literally meaning "Small Genius," with a double meaning of "reduced."

Overall Architecture:
- ISA: RISC-V RV64GC
- Pipeline: In-order 3-SMT, Asymmetric Dual-issue, 1-core/3-thread
- Cache: L1I 48KB (16KB/thread), L1D 48KB (16KB/thread), shared L2 256KB

Threading Strategy:
- 1-thread for kernel: handles interrupts and devices
- 1-thread for foreground task: handles the main thread of the foreground app
- 1-thread for background tasks: background apps, services, secondary threads of the foreground app

Pipeline:
```
T1 Pipeline:  T1-IF1 --> T1-IF2 --> T1-ID --> T1-RF1 --> T1-RF2 --> [Shared EX] --> T1-WB
T2 Pipeline:  T2-IF1 --> T2-IF2 --> T2-ID --> T2-RF1 --> T2-RF2 --> [Shared EX] --> T2-WB
T3 Pipeline:  T3-IF1 --> T3-IF2 --> T3-ID --> T3-RF1 --> T3-RF2 --> [Shared EX] --> T3-WB

ID: Instruction Decode & Dual-issue check
RF: Register Fetch

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

MMU:
```
[ T1 Pipeline ] --> [ micro L1-TLB (8 ent) ] 
[ T2 Pipeline ] --> [ micro L1-TLB (8 ent) ] --> [ Shared L2-TLB 256 ent) ] --> [ Shared PTW ]
[ T3 Pipeline ] --> [ micro L1-TLB (8 ent) ] 
```

Design goal:
- Scale: 30,000 LUTs for FPGAs
- Synthesis: 500MHz on FPGAs and 1.5GHz for ASIC processes.
