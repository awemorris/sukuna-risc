#include "riscv_test.h"

RVTEST_CODE_BEGIN

  .option rvc

  // Test 1: C.LI and C.MV
  li  gp, 1
  li  a1, 15
  mv  a2, a1
  li  t0, 15
  bne a2, t0, test_fail

  // Test 2: C.ADDI and C.SUB
  li  gp, 2
  addi a1, a1, 10      // 15 + 10 = 25
  li   s1, 5
  sub  a1, a1, s1      // 25 - 5 = 20
  li   t0, 20
  bne  a1, t0, test_fail

  // Test 3: C.AND, C.OR, C.XOR
  li  gp, 3
  li  s0, 0x1f
  andi s0, s0, 0x0f    // 0x0f
  li  t0, 0x0f
  bne s0, t0, test_fail

  li  s1, 0x10
  or  s0, s0, s1       // 0x1f
  li  t0, 0x1f
  bne s0, t0, test_fail

  xor s0, s0, s1       // 0x0f
  li  t0, 0x0f
  bne s0, t0, test_fail

  // Test 4: C.SLLI, C.SRLI
  li  gp, 4
  li  a1, 4
  slli a1, a1, 2       // 16
  li  t0, 16
  bne a1, t0, test_fail

  srli a1, a1, 3       // 2
  li  t0, 2
  bne a1, t0, test_fail

  // Test 5: C.J, C.BEQZ, C.BNEZ
  li  gp, 5
  li  s0, 0
  beqz s0, 1f
  j test_fail
1:
  li  s0, 1
  bnez s0, 2f
  j test_fail
2:
  j 3f
  j test_fail
3:

  // Test 6: C.SW, C.LW, C.SD, C.LD (using prime registers s0, s1, a1)
  li  gp, 6
  la  s0, test_data_area
  li  s1, 42
  sw  s1, 0(s0)
  lw  a1, 0(s0)
  li  t0, 42
  bne a1, t0, test_fail

  li  t1, 0x12345678abcdef01
  sd  t1, 8(s0)
  ld  a1, 8(s0)
  bne a1, t1, test_fail

  // Test 7: C.ADDIW, C.ADDW, C.SUBW
  li  gp, 7
  li  a1, 10
  c.addiw a1, 5        // 15
  li  t0, 15
  bne a1, t0, test_fail

  li  s1, 20
  c.addw a1, s1        // 35
  li  t0, 35
  bne a1, t0, test_fail

  c.subw a1, s1        // 15
  bne a1, t0, 1f
  j test_fail
1:
  li  t0, 15
  bne a1, t0, test_fail

  // Test 8: C.SRAI
  li  gp, 8
  li  a1, -16
  c.srai a1, 2         // -4
  li  t0, -4
  bne a1, t0, test_fail

  // Test 9: C.LUI and C.NOP
  li  gp, 9
  c.nop
  c.lui a1, 0x12       // 0x12000
  li  t0, 0x12000
  bne a1, t0, test_fail

  // Test 10: C.ADD, C.JALR, C.JR
  li  gp, 10
  li  a1, 100
  li  s1, 50
  c.add a1, s1         // 150
  li  t0, 150
  bne a1, t0, test_fail

  la  t2, 2f
  c.jalr t2            // jumps to 2f, writes ra (x1)
  j test_fail
2:
  la  t2, 3f
  c.jr t2              // jumps to 3f
  j test_fail
3:

  // Test 11: C.SWSP, C.LWSP, C.SDSP, C.LDSP
  li  gp, 11
  la  sp, test_data_area + 256
  li  s1, 0x55aa55aa
  c.swsp s1, 0(sp)
  c.lwsp a1, 0(sp)
  li  t0, 0x55aa55aa
  bne a1, t0, test_fail

  li  t1, 0x0123456789abcdef
  c.sdsp t1, 8(sp)
  c.ldsp a1, 8(sp)
  bne a1, t1, test_fail

  // Test 12: C.ADDI16SP and C.ADDI4SPN
  li  gp, 12
  la  sp, test_data_area + 256
  addi sp, sp, 32       // C.ADDI16SP
  la  t0, test_data_area + 288
  bne sp, t0, test_fail

  addi a1, sp, 16       // C.ADDI4SPN
  la  t0, test_data_area + 304
  bne a1, t0, test_fail

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
