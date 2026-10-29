#include "riscv_test.h"

RVTEST_CODE_BEGIN

  la  s0, test_data_area

  // Test 1: SW and LW (positive signed word)
  li  gp, 1
  li  t0, 0x12345678
  sw  t0, 0(s0)
  lw  t1, 0(s0)
  bne t0, t1, test_fail

  // Test 2: SW and LW (negative signed word, sign-extended to 64-bit)
  li  gp, 2
  li  t0, 0xffffffff80001234
  sw  t0, 8(s0)
  lw  t1, 8(s0)
  bne t0, t1, test_fail

  // Test 3: SW and LWU (unsigned word, zero-extended to 64-bit)
  li  gp, 3
  li  t0, 0x0000000080001234
  lwu t1, 8(s0)
  bne t0, t1, test_fail

  // Test 4: SW and LW at 4-byte offset
  li  gp, 4
  li  t0, 0xdeadbeef
  sw  t0, 4(s0)
  lw  t1, 4(s0)
  li  t2, 0xffffffffdeadbeef
  bne t1, t2, test_fail

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
