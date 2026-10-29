#include "riscv_test.h"

RVTEST_CODE_BEGIN

  la  s0, test_data_area

  // Test 1: SD and LD
  li  gp, 1
  li  t0, 0x0123456789abcdef
  sd  t0, 0(s0)
  ld  t1, 0(s0)
  bne t0, t1, test_fail

  // Test 2: SW and LW (negative signed word)
  li  gp, 2
  li  t0, 0xffffffff80001234
  sw  t0, 8(s0)
  lw  t1, 8(s0)
  bne t0, t1, test_fail

  // Test 3: SW and LWU (unsigned word, upper 32 bits 0)
  li  gp, 3
  li  t0, 0x0000000080001234
  lwu t1, 8(s0)
  bne t0, t1, test_fail

  // Test 4: SH and LH (negative signed halfword)
  li  gp, 4
  li  t0, 0xffffffffffff8123
  sh  t0, 16(s0)
  lh  t1, 16(s0)
  bne t0, t1, test_fail

  // Test 5: SH and LHU (unsigned halfword)
  li  gp, 5
  li  t0, 0x0000000000008123
  lhu t1, 16(s0)
  bne t0, t1, test_fail

  // Test 6: SB and LB (negative signed byte)
  li  gp, 6
  li  t0, 0xffffffffffffff85
  sb  t0, 24(s0)
  lb  t1, 24(s0)
  bne t0, t1, test_fail

  // Test 7: SB and LBU (unsigned byte)
  li  gp, 7
  li  t0, 0x0000000000000085
  lbu t1, 24(s0)
  bne t0, t1, test_fail

  // Test 8: Byte offsets 0..7 across doubleword
  li  gp, 8
  li  t0, 0x11
  sb  t0, 32(s0)
  li  t0, 0x22
  sb  t0, 33(s0)
  li  t0, 0x33
  sb  t0, 34(s0)
  li  t0, 0x44
  sb  t0, 35(s0)
  li  t0, 0x55
  sb  t0, 36(s0)
  li  t0, 0x66
  sb  t0, 37(s0)
  li  t0, 0x77
  sb  t0, 38(s0)
  li  t0, 0x88
  sb  t0, 39(s0)

  // Verify full 64-bit load matches little-endian byte ordering
  li  t0, 0x8877665544332211
  ld  t1, 32(s0)
  bne t0, t1, test_fail

  // Test 9: Halfword offsets 0, 2, 4, 6
  li  gp, 9
  li  t0, 0x1234
  sh  t0, 40(s0)
  li  t0, 0x5678
  sh  t0, 42(s0)
  li  t0, 0x9abc
  sh  t0, 44(s0)
  li  t0, 0xdef0
  sh  t0, 46(s0)

  li  t0, 0xdef09abc56781234
  ld  t1, 40(s0)
  bne t0, t1, test_fail

  // Test 10: Word offsets 0, 4
  li  gp, 10
  li  t0, 0x12345678
  sw  t0, 48(s0)
  li  t0, 0x9abcdef0
  sw  t0, 52(s0)

  li  t0, 0x9abcdef012345678
  ld  t1, 48(s0)
  bne t0, t1, test_fail

  // Test 11: Negative offset with load and store
  li  gp, 11
  addi s1, s0, 64
  li   t0, 0xa5a5a5a55a5a5a5a
  sd   t0, -8(s1)
  ld   t1, 56(s0)
  bne  t0, t1, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END

  .data
  .balign 64
test_data_area:
  .fill 128, 1, 0x00
