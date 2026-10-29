#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // Test 1: SLTI signed comparison
  li  gp, 1
  li  a2, -5
  slti a1, a2, 0
  li  t0, 1
  bne a1, t0, test_fail

  // Test 2: SLTI negative immediate
  li  gp, 2
  li  a2, -10
  slti a1, a2, -5
  li  t0, 1
  bne a1, t0, test_fail

  // Test 3: SLTI not less
  li  gp, 3
  li  a2, 5
  slti a1, a2, 0
  li  t0, 0
  bne a1, t0, test_fail

  // Test 4: SLT
  li  gp, 4
  li  a2, -100
  li  a3, 100
  slt a1, a2, a3
  li  t0, 1
  bne a1, t0, test_fail

  // Test 5: SLT equal
  li  gp, 5
  li  a2, 42
  li  a3, 42
  slt a1, a2, a3
  li  t0, 0
  bne a1, t0, test_fail

  // Test 6: SLTIU unsigned
  li  gp, 6
  li  a2, 5
  sltiu a1, a2, 10
  li  t0, 1
  bne a1, t0, test_fail

  // Test 7: SLTIU with negative number (large unsigned value)
  li  gp, 7
  li  a2, -1
  sltiu a1, a2, 10
  li  t0, 0
  bne a1, t0, test_fail

  // Test 8: SLTU
  li  gp, 8
  li  a2, 100
  li  a3, -1
  sltu a1, a2, a3
  li  t0, 1
  bne a1, t0, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END
