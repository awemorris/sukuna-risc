#include "riscv_test.h"

RVTEST_CODE_BEGIN

  la  s0, test_data_area

  // Test 1: SB and LB (positive byte)
  li  gp, 1
  li  t0, 0x5a
  sb  t0, 0(s0)
  lb  t1, 0(s0)
  bne t0, t1, test_fail

  // Test 2: SB and LB (negative signed byte, sign-extended to 64-bit)
  li  gp, 2
  li  t0, 0xffffffffffffff81
  sb  t0, 1(s0)
  lb  t1, 1(s0)
  bne t0, t1, test_fail

  // Test 3: SB and LBU (unsigned byte, zero-extended to 64-bit)
  li  gp, 3
  li  t0, 0x0000000000000081
  lbu t1, 1(s0)
  bne t0, t1, test_fail

  // Test 4: Consecutive byte stores across an 8-byte word
  li  gp, 4
  li  t0, 0x11
  sb  t0, 8(s0)
  li  t0, 0x22
  sb  t0, 9(s0)
  li  t0, 0x33
  sb  t0, 10(s0)
  li  t0, 0x44
  sb  t0, 11(s0)
  li  t0, 0x55
  sb  t0, 12(s0)
  li  t0, 0x66
  sb  t0, 13(s0)
  li  t0, 0x77
  sb  t0, 14(s0)
  li  t0, 0x88
  sb  t0, 15(s0)

  // Verify byte by byte
  lb  t1, 8(s0)
  li  t0, 0x11
  bne t0, t1, test_fail

  lb  t1, 11(s0)
  li  t0, 0x44
  bne t0, t1, test_fail

  lbu t1, 15(s0)
  li  t0, 0x88
  bne t0, t1, test_fail

  // Read back as 64-bit doubleword (little endian)
  ld  t1, 8(s0)
  li  t0, 0x8877665544332211
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
  .zero 1024
