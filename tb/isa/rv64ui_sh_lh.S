#include "riscv_test.h"

RVTEST_CODE_BEGIN

  la  s0, test_data_area

  // Test 1: SH and LH (positive signed halfword)
  li  gp, 1
  li  t0, 0x1234
  sh  t0, 0(s0)
  lh  t1, 0(s0)
  bne t0, t1, test_fail

  // Test 2: SH and LH (negative signed halfword, sign-extended to 64-bit)
  li  gp, 2
  li  t0, 0xffffffffffff8123
  sh  t0, 8(s0)
  lh  t1, 8(s0)
  bne t0, t1, test_fail

  // Test 3: SH and LHU (unsigned halfword, zero-extended to 64-bit)
  li  gp, 3
  li  t0, 0x0000000000008123
  lhu t1, 8(s0)
  bne t0, t1, test_fail

  // Test 4: SH at unaligned / offset 2, 4, 6 within doubleword
  li  gp, 4
  li  t0, 0x5a5a
  sh  t0, 2(s0)
  lh  t1, 2(s0)
  bne t0, t1, test_fail

  li  gp, 5
  li  t0, 0x3c3c
  sh  t0, 6(s0)
  lh  t1, 6(s0)
  bne t0, t1, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END

  .data
  .balign 64
test_data_area:
  .fill 64, 1, 0x00
