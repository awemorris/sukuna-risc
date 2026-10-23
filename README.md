Sukuna-RISC
===========

`Sukuna RISC` is an RTL CPU implementation.

The name `Sukuna` comes from `Sukunahikona`, literally meaning "Small Genius," with a double meaning of "reduced."

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

Synthesis goal is 200MHz on KC705 board and 1.5GHz for ASIC processes.
