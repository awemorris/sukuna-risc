#include "riscv_test.h"

RVTEST_CODE_BEGIN

  la  s0, test_data_area
  addi s0, s0, 64   // Offset by 64 bytes so negative offsets are safely within buffer

  // Test 1: Negative offset store and load
  li  gp, 1
  li  t0, 0x12345678abcdef01
  sd  t0, -32(s0)
  ld  t1, -32(s0)
  bne t0, t1, test_fail

  // Test 2: Word store with positive and negative offsets
  li  gp, 2
  li  t0, 0x5a5a1234
  sw  t0, -16(s0)
  lw  t1, -16(s0)
  bne t0, t1, test_fail

  li  t0, 0x3c3c789a
  sw  t0, 16(s0)
  lw  t1, 16(s0)
  bne t0, t1, test_fail

  // Test 3: Byte offsets within doubleword (1, 2, 3, 5, 6, 7)
  li  gp, 3
  li  t0, 0x2a
  sb  t0, 1(s0)
  lb  t1, 1(s0)
  bne t0, t1, test_fail

  li  t0, 0x3b
  sb  t0, 3(s0)
  lb  t1, 3(s0)
  bne t0, t1, test_fail

  li  t0, 0x4c
  sb  t0, 5(s0)
  lb  t1, 5(s0)
  bne t0, t1, test_fail

  li  t0, 0x5d
  sb  t0, 7(s0)
  lb  t1, 7(s0)
  bne t0, t1, test_fail

  // Test 4: Overwriting word with halfword and bytes, verifying partial updates
  li  gp, 4
  li  t0, 0x1122334455667788
  sd  t0, 32(s0)

  li  t0, 0xaabb
  sh  t0, 34(s0) // Overwrite bytes 2 and 3 (0x5566 -> 0xaabb)

  lh  t1, 34(s0)
  li  t0, 0xffffffffffffaabb
  bne t0, t1, test_fail

  lhu t1, 34(s0)
  li  t0, 0x000000000000aabb
  bne t0, t1, test_fail

  // Verify full 64-bit word reflects partial update:
  // Expected: 0x11223344aabb7788 (little-endian: byte 0=0x88, byte 1=0x77, byte 2=0xbb, byte 3=0xaa, 4=0x44, 5=0x33, 6=0x22, 7=0x11)
  ld  t1, 32(s0)
  li  t0, 0x11223344aabb7788
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
