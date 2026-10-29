#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // Test 1: ANDI
  li  gp, 1
  li  a2, 0x123456789abcdef0
  andi a1, a2, 0x0f0
  li  t0, 0x0f0
  bne a1, t0, test_fail

  // Test 2: AND
  li  gp, 2
  li  a2, 0xff00ff00ff00ff00
  li  a3, 0x0f0f0f0f0f0f0f0f
  and a1, a2, a3
  li  t0, 0x0f000f000f000f00
  bne a1, t0, test_fail

  // Test 3: ORI
  li  gp, 3
  li  a2, 0x123456789abcdef0
  ori a1, a2, 0x00f
  li  t0, 0x123456789abcdef0 | 0x00f
  bne a1, t0, test_fail

  // Test 4: OR
  li  gp, 4
  li  a2, 0xff00ff00ff00ff00
  li  a3, 0x00ff00ff00ff00ff
  or  a1, a2, a3
  li  t0, 0xffffffffffffffff
  bne a1, t0, test_fail

  // Test 5: XORI
  li  gp, 5
  li  a2, 0x5555555555555555
  xori a1, a2, 0x555
  li  t0, 0x5555555555555000
  bne a1, t0, test_fail

  // Test 6: XOR
  li  gp, 6
  li  a2, 0xaaaaaaaaaaaaaaaa
  li  a3, 0x5555555555555555
  xor a1, a2, a3
  li  t0, 0xffffffffffffffff
  bne a1, t0, test_fail

  // Test 7: LUI
  li  gp, 7
  lui a1, 0x12345
  li  t0, 0x12345000
  bne a1, t0, test_fail

  // Test 8: LUI with sign extension
  li  gp, 8
  lui a1, 0x80000
  li  t0, 0xffffffff80000000
  bne a1, t0, test_fail

  // Test 9: AUIPC
  li  gp, 9
1:
  auipc a1, 0
  la  t0, 1b
  bne a1, t0, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END
