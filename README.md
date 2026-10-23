Sukuna-RISC
===========

`Sukuna RISC` is a RTL CPU implementation.

Overall Architecture:
- In-order, 2-issue, 2-SMT, 2-core / 4-thread
- L1I 16KB, L1D 16KB, customizable shared L2
- RISC-V RV64GC
- 8-stage pipeline
    - IF1
    - IF2
    - ID1
    - ID2
    - EX
    - MEM1
    - MEM2 (and forwarded EX)
    - WB
- Around 22000-LUT plus BRAM
