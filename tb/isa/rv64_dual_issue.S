#include "riscv_test.h"

RVTEST_CODE_BEGIN

  la  s0, test_data_area

  // --------------------------------------------------------------------------
  // Test 1: Basic Dual-Issue [INT + MA]
  // Lane 0: ADDI, Lane 1: SW (independent registers)
  // --------------------------------------------------------------------------
  li  gp, 1
  li  t0, 0x11223344
  li  t1, 0x55667788
  sw  t1, 0(s0)

  .align 3  // Align to 8-byte boundary for clean dual-fetch
  addi t2, x0, 0x7f      // Lane 0: INT
  sw   t0, 8(s0)         // Lane 1: MA (independent)

  // Verify both Lane 0 and Lane 1 committed correctly
  li  t3, 0x7f
  bne t2, t3, test_fail
  lw  t4, 8(s0)
  bne t4, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 2: Dual-Issue [INT + MA] Load with Forwarding
  // Lane 0: ADDI, Lane 1: LW (independent)
  // --------------------------------------------------------------------------
  li  gp, 2
  .align 3
  addi t5, x0, 100       // Lane 0: INT
  lw   t6, 0(s0)         // Lane 1: MA (reads 0x55667788 from Test 1)

  li  t3, 100
  bne t5, t3, test_fail
  li  t3, 0x55667788
  bne t6, t3, test_fail

  // --------------------------------------------------------------------------
  // Test 3: RAW Hazard within Pair (Lane 1 depends on Lane 0)
  // Must serialize safely without data corruption
  // --------------------------------------------------------------------------
  li  gp, 3
  .align 3
  addi t0, x0, 0x33      // Lane 0: writes t0
  sw   t0, 16(s0)        // Lane 1: reads t0 (RAW hazard!)

  lw   t1, 16(s0)
  li   t2, 0x33
  bne  t1, t2, test_fail

  // --------------------------------------------------------------------------
  // Test 4: Back-to-Back Dual-Issue Pairs with Cross-Cycle Forwarding
  // Pair A [INT, MA] writes registers, Pair B [INT, MA] consumes them
  // --------------------------------------------------------------------------
  li  gp, 4
  li  t0, 0x100
  sw  t0, 24(s0)

  .align 3
  // Pair A:
  addi a1, x0, 0x42      // Lane 0: writes a1 = 0x42
  lw   a2, 24(s0)        // Lane 1: writes a2 = 0x100

  // Pair B (immediately following Pair A):
  addi a3, a1, 1         // Lane 0: reads a1 from Pair A (should be 0x43)
  sw   a2, 32(s0)        // Lane 1: reads a2 from Pair A (stores 0x100)

  li  t3, 0x43
  bne a3, t3, test_fail
  lw  t4, 32(s0)
  li  t3, 0x100
  bne t4, t3, test_fail

  // --------------------------------------------------------------------------
  // Test 5: Non-8-Byte Aligned (Odd 4-Byte Offset) Fetch & Non-Shifting Pairing
  // Starts on odd 4-byte offset: first instruction is single-issued,
  // then following instructions align and dual-issue smoothly.
  // --------------------------------------------------------------------------
  li  gp, 5
  .align 3
  nop                    // Pad 4 bytes to push next instruction to odd boundary (offset 4)
  addi s1, x0, 1         // At offset 4 (single-issue)
  // Now at offset 0 of next 8-byte block:
  addi s2, x0, 2         // Lane 0
  sw   s1, 40(s0)        // Lane 1

  li  t3, 1
  bne s1, t3, test_fail
  li  t3, 2
  bne s2, t3, test_fail
  lw  t4, 40(s0)
  bne t4, s1, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END

  .data
  .align 4
test_data_area:
  .dword 0, 0, 0, 0, 0, 0, 0, 0
