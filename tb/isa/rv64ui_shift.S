#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // Test 1: SLLI
  li  gp, 1
  li  a2, 0x123456789abcdef0
  slli a1, a2, 4
  li  t0, 0x23456789abcdef00
  bne a1, t0, test_fail

  // Test 2: SLL
  li  gp, 2
  li  a2, 0x1
  li  a3, 63
  sll a1, a2, a3
  li  t0, 0x8000000000000000
  bne a1, t0, test_fail

  // Test 3: SRLI
  li  gp, 3
  li  a2, 0x8000000000000000
  srli a1, a2, 1
  li  t0, 0x4000000000000000
  bne a1, t0, test_fail

  // Test 4: SRL
  li  gp, 4
  li  a2, 0xffffffffffffffff
  li  a3, 60
  srl a1, a2, a3
  li  t0, 0xf
  bne a1, t0, test_fail

  // Test 5: SRAI
  li  gp, 5
  li  a2, 0x8000000000000000
  srai a1, a2, 4
  li  t0, 0xf800000000000000
  bne a1, t0, test_fail

  // Test 6: SRA
  li  gp, 6
  li  a2, 0x8000000000000000
  li  a3, 63
  sra a1, a2, a3
  li  t0, 0xffffffffffffffff
  bne a1, t0, test_fail

  // Test 7: SLLIW
  li  gp, 7
  li  a2, 0x1234567812345678
  slliw a1, a2, 4
  li  t0, 0x0000000023456780
  bne a1, t0, test_fail

  // Test 8: SLLW
  li  gp, 8
  li  a2, 0x1
  li  a3, 31
  sllw a1, a2, a3
  li  t0, 0xffffffff80000000 // sign-extended 32-bit msb
  bne a1, t0, test_fail

  // Test 9: SRLIW
  li  gp, 9
  li  a2, 0xffffffff80000000
  srliw a1, a2, 1
  li  t0, 0x0000000040000000
  bne a1, t0, test_fail

  // Test 10: SRLW
  li  gp, 10
  li  a2, 0xffffffffffffffff
  li  a3, 28
  srlw a1, a2, a3
  li  t0, 0xf
  bne a1, t0, test_fail

  // Test 11: SRAIW
  li  gp, 11
  li  a2, 0x0000000080000000
  sraiw a1, a2, 4
  li  t0, 0xfffffffff8000000
  bne a1, t0, test_fail

  // Test 12: SRAW
  li  gp, 12
  li  a2, 0x0000000080000000
  li  a3, 31
  sraw a1, a2, a3
  li  t0, 0xffffffffffffffff
  bne a1, t0, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END
