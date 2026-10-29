#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // --------------------------------------------------------------------------
  // 1. CSR Register Read/Write Tests (mscratch)
  // --------------------------------------------------------------------------
  // Test 1: CSRRW (write new value, read old 0)
  li  gp, 1
  li  t0, 0x12345678abcdef01
  csrrw t1, mscratch, t0
  li  t2, 0
  bne t1, t2, test_fail

  // Test 2: CSRRS with x0 (read without modifying)
  li  gp, 2
  csrrs t1, mscratch, x0
  bne t1, t0, test_fail

  // Test 3: CSRRS (set bits)
  li  gp, 3
  li  t2, 0x00000000000000fe
  csrrs t1, mscratch, t2
  // Old value was 0x12345678abcdef01
  bne t1, t0, test_fail
  // New value is 0x12345678abcdef01 | 0xfe = 0x12345678abcdefff
  csrr t1, mscratch
  li  t3, 0x12345678abcdefff
  bne t1, t3, test_fail

  // Test 4: CSRRC (clear bits)
  li  gp, 4
  li  t2, 0x00000000000000ff
  csrrc t1, mscratch, t2
  // Old value was 0x12345678abcdefff
  bne t1, t3, test_fail
  // New value is 0x12345678abcdef00
  csrr t1, mscratch
  li  t0, 0x12345678abcdef00
  bne t1, t0, test_fail

  // Test 5: CSR Immediate variants (csrrwi, csrrsi, csrrci)
  li  gp, 5
  csrrwi t1, mscratch, 0x1f
  bne t1, t0, test_fail

  csrr t1, mscratch
  li  t0, 0x1f
  bne t1, t0, test_fail

  csrrsi t1, mscratch, 0x00
  bne t1, t0, test_fail

  // --------------------------------------------------------------------------
  // 2. Exception & MRET Return Test
  // --------------------------------------------------------------------------
  // Test 6: Setup mtvec to trap_handler, execute ecall, and mret back
  li  gp, 6
  la  t0, my_trap_handler
  csrw mtvec, t0

  li  t2, 0x55aa           // Marker before ecall
  ecall                    // Should vector to my_trap_handler
resume_point:
  // After mret: t2 should have been changed to 0xdeadbeef by handler
  li  t3, 0xdeadbeef
  bne t2, t3, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

  // Custom Machine Trap Handler
  .align 4
my_trap_handler:
  csrr t4, mcause
  li   t5, 11              // Machine ECALL cause = 11
  bne  t4, t5, test_fail

  // Increment mepc by 4 to resume after the ecall
  csrr t4, mepc
  addi t4, t4, 4
  csrw mepc, t4

  // Set marker to confirm handler ran
  li   t2, 0xdeadbeef

  mret

RVTEST_CODE_END
