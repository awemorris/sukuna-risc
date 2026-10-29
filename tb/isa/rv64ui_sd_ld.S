#include "riscv_test.h"

RVTEST_CODE_BEGIN

  la  s0, test_data_area

  // Test 1: SD and LD basic positive pattern
  li  gp, 1
  li  t0, 0x0123456789abcdef
  sd  t0, 0(s0)
  ld  t1, 0(s0)
  bne t0, t1, test_fail

  // Test 2: SD and LD negative pattern (sign bit set)
  li  gp, 2
  li  t0, 0xfedcba9876543210
  sd  t0, 8(s0)
  ld  t1, 8(s0)
  bne t0, t1, test_fail

  // Test 3: SD and LD all-ones
  li  gp, 3
  li  t0, 0xffffffffffffffff
  sd  t0, 16(s0)
  ld  t1, 16(s0)
  bne t0, t1, test_fail

  // Test 4: SD and LD alternating bit pattern
  li  gp, 4
  li  t0, 0xaaaaaaaa55555555
  sd  t0, 24(s0)
  ld  t1, 24(s0)
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
  .fill 128, 1, 0x00
