#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // --------------------------------------------------------------------------
  // 1. Multiplication tests
  // --------------------------------------------------------------------------
  // Test 1: MUL (basic)
  li  gp, 1
  li  a1, 20
  li  a2, 5
  mul a3, a1, a2
  li  t0, 100
  bne a3, t0, test_fail

  // Test 2: MUL with negative operand
  li  gp, 2
  li  a1, -20
  li  a2, 5
  mul a3, a1, a2
  li  t0, -100
  bne a3, t0, test_fail

  // Test 3: MULW (32-bit product sign-extended)
  li  gp, 3
  li  a1, 0x12345
  li  a2, 0x10000
  mulw a3, a1, a2
  li  t0, 0x0000000023450000
  bne a3, t0, test_fail

  // Test 4: MULH (signed x signed high 64 bits)
  li  gp, 4
  li  a1, 0x123456789abcdef0
  li  a2, 2
  mulh a3, a1, a2
  li  t0, 0
  bne a3, t0, test_fail

  // Test 5: MULHU (unsigned x unsigned high 64 bits)
  li  gp, 5
  li  a1, 0x8000000000000000
  li  a2, 2
  mulhu a3, a1, a2
  li  t0, 1
  bne a3, t0, test_fail

  // --------------------------------------------------------------------------
  // 2. Division & Remainder tests
  // --------------------------------------------------------------------------
  // Test 6: DIV (basic positive)
  li  gp, 6
  li  a1, 100
  li  a2, 5
  div a3, a1, a2
  li  t0, 20
  bne a3, t0, test_fail

  // Test 7: DIV (signed negative)
  li  gp, 7
  li  a1, -100
  li  a2, 5
  div a3, a1, a2
  li  t0, -20
  bne a3, t0, test_fail

  // Test 8: REM (basic remainder)
  li  gp, 8
  li  a1, 103
  li  a2, 5
  rem a3, a1, a2
  li  t0, 3
  bne a3, t0, test_fail

  // Test 9: DIVU / REMU (unsigned)
  li  gp, 9
  li  a1, 0xffffffffffffffff
  li  a2, 2
  divu a3, a1, a2
  li  t0, 0x7fffffffffffffff
  bne a3, t0, test_fail

  remu a4, a1, a2
  li  t0, 1
  bne a4, t0, test_fail

  // Test 10: DIVW / REMW (32-bit word operations)
  li  gp, 10
  li  a1, 100
  li  a2, 7
  divw a3, a1, a2
  li  t0, 14
  bne a3, t0, test_fail

  remw a4, a1, a2
  li  t0, 2
  bne a4, t0, test_fail

  // Test 11: Division by zero (RISC-V spec: div by zero returns -1, rem returns dividend)
  li  gp, 11
  li  a1, 42
  li  a2, 0
  div a3, a1, a2
  li  t0, -1
  bne a3, t0, test_fail

  rem a4, a1, a2
  li  t0, 42
  bne a4, t0, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END
