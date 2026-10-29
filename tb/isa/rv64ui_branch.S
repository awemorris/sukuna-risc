#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // Test 1: BEQ taken
  li  gp, 1
  li  t0, 42
  li  t1, 42
  beq t0, t1, 1f
  j   test_fail
1:

  // Test 2: BEQ not taken
  li  gp, 2
  li  t0, 42
  li  t1, 43
  beq t0, t1, test_fail

  // Test 3: BNE taken
  li  gp, 3
  li  t0, 10
  li  t1, 20
  bne t0, t1, 2f
  j   test_fail
2:

  // Test 4: BNE not taken
  li  gp, 4
  li  t0, 99
  li  t1, 99
  bne t0, t1, test_fail

  // Test 5: BLT taken (positive < positive)
  li  gp, 5
  li  t0, -5
  li  t1, 5
  blt t0, t1, 3f
  j   test_fail
3:

  // Test 6: BLT not taken (-5 not < -10)
  li  gp, 6
  li  t0, -5
  li  t1, -10
  blt t0, t1, test_fail

  // Test 7: BGE taken (5 >= -5)
  li  gp, 7
  li  t0, 5
  li  t1, -5
  bge t0, t1, 4f
  j   test_fail
4:

  // Test 8: BGE taken (equal: 7 >= 7)
  li  gp, 8
  li  t0, 7
  li  t1, 7
  bge t0, t1, 5f
  j   test_fail
5:

  // Test 9: BGE not taken (-10 not >= -5)
  li  gp, 9
  li  t0, -10
  li  t1, -5
  bge t0, t1, test_fail

  // Test 10: BLTU taken (unsigned: 5 < -5 which is 0xfffffffffffffffb)
  li  gp, 10
  li  t0, 5
  li  t1, -5
  bltu t0, t1, 6f
  j   test_fail
6:

  // Test 11: BLTU not taken (-5 not < 5 unsigned)
  li  gp, 11
  li  t0, -5
  li  t1, 5
  bltu t0, t1, test_fail

  // Test 12: BGEU taken (-5 >= 5 unsigned)
  li  gp, 12
  li  t0, -5
  li  t1, 5
  bgeu t0, t1, 7f
  j   test_fail
7:

  // Test 13: BGEU taken (equal: 100 >= 100)
  li  gp, 13
  li  t0, 100
  li  t1, 100
  bgeu t0, t1, 8f
  j   test_fail
8:

  // Test 14: BGEU not taken (5 not >= -5 unsigned)
  li  gp, 14
  li  t0, 5
  li  t1, -5
  bgeu t0, t1, test_fail

  // Test 15: Backward branch
  li  gp, 15
  li  t0, 0
  li  t1, 5
backward_loop:
  addi t0, t0, 1
  blt  t0, t1, backward_loop
  li   t2, 5
  bne  t0, t2, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END
