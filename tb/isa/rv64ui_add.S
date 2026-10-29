#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // Test 1: Simple ADDI
  li  gp, 1
  addi a1, x0, 10
  li  t0, 10
  bne a1, t0, test_fail

  // Test 2: Negative ADDI
  li  gp, 2
  addi a1, x0, -15
  li  t0, -15
  bne a1, t0, test_fail

  // Test 3: Basic ADD
  li  gp, 3
  li  a2, 100
  li  a3, 250
  add a1, a2, a3
  li  t0, 350
  bne a1, t0, test_fail

  // Test 4: ADD with negative operand
  li  gp, 4
  li  a2, 100
  li  a3, -30
  add a1, a2, a3
  li  t0, 70
  bne a1, t0, test_fail

  // Test 5: SUB
  li  gp, 5
  li  a2, 200
  li  a3, 75
  sub a1, a2, a3
  li  t0, 125
  bne a1, t0, test_fail

  // Test 6: 32-bit ADDIW (sign-extends 32-bit result to 64-bit)
  li  gp, 6
  li  a2, 0x7FFFFFFF
  addiw a1, a2, 1
  // 0x7FFFFFFF + 1 = 0x80000000 -> sign-extended to 64-bit is 0xFFFFFFFF80000000
  li  t0, 0xFFFFFFFF80000000
  bne a1, t0, test_fail

  // Test 7: 32-bit ADDW
  li  gp, 7
  li  a2, 0x100000001
  li  a3, 0x200000002
  addw a1, a2, a3
  li  t0, 3
  bne a1, t0, test_fail

  // Test 8: 32-bit SUBW
  li  gp, 8
  li  a2, 10
  li  a3, 20
  subw a1, a2, a3
  li  t0, -10
  bne a1, t0, test_fail

  // All tests passed!
test_pass:
  RVTEST_PASS

test_fail:
  // Move failing test number in gp to a0 for test harness reporting
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END
