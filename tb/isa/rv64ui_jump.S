#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // Test 1: JAL forward and link
  li  gp, 1
  jal t0, target_jal1
  j   test_fail
target_jal1:
  // t0 should point to instruction immediately after jal (target_jal1 - 4)
  la  t1, target_jal1
  addi t1, t1, -4
  bne t0, t1, test_fail

  // Test 2: JAL backward and link
  li  gp, 2
  j   hop_forward
back_target:
  la  t1, hop_forward
  addi t1, t1, 4
  bne ra, t1, test_fail
  j   jal_done
hop_forward:
  jal ra, back_target
jal_done:

  // Test 3: JALR with zero offset
  li  gp, 3
  la  t2, target_jalr1
  jalr t0, t2, 0
  j   test_fail
target_jalr1:
  la  t1, target_jalr1
  addi t1, t1, -4
  bne t0, t1, test_fail

  // Test 4: JALR with positive offset
  li  gp, 4
  la  t2, target_jalr2 - 16
  jalr ra, t2, 16
  j   test_fail
target_jalr2:
  la  t1, target_jalr2
  addi t1, t1, -4
  bne ra, t1, test_fail

  // Test 5: JALR with negative offset
  li  gp, 5
  la  t2, target_jalr3 + 16
  jalr ra, t2, -16
  j   test_fail
target_jalr3:
  la  t1, target_jalr3
  addi t1, t1, -4
  bne ra, t1, test_fail

  // Test 6: JALR LSB bit 0 clearing (target = (base + imm) & ~1)
  li  gp, 6
  la  t2, target_jalr4
  addi t2, t2, 1 // Make target odd
  jalr zero, t2, 0
  j   test_fail
  .balign 4
target_jalr4:

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END
