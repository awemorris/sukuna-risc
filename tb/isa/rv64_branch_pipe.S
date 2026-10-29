#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // --------------------------------------------------------------------------
  // Test 1: Unconditional JAL (squash fallthrough)
  // --------------------------------------------------------------------------
  li  gp, 1
  li  t0, 0
  jal x1, target_jal
  li  t0, 0xbad1
  j   test_fail

target_jal:
  // t0 should still be 0
  bnez t0, test_fail

  // --------------------------------------------------------------------------
  // Test 2: Indirect JALR (squash fallthrough)
  // --------------------------------------------------------------------------
  li  gp, 2
  li  t0, 0
  la  a0, target_jalr
  jalr x2, 0(a0)
  li  t0, 0xbad2
  j   test_fail

target_jalr:
  bnez t0, test_fail

  // --------------------------------------------------------------------------
  // Test 3: Conditional Branch Taken (BEQ taken -> squash fallthrough)
  // --------------------------------------------------------------------------
  li  gp, 3
  li  t0, 0
  li  a1, 42
  li  a2, 42
  beq a1, a2, target_beq_taken
  li  t0, 0xbad3
  j   test_fail

target_beq_taken:
  bnez t0, test_fail

  // --------------------------------------------------------------------------
  // Test 4: Conditional Branch Not Taken (BEQ fallthrough -> execute inline)
  // --------------------------------------------------------------------------
  li  gp, 4
  li  t0, 0
  li  a1, 42
  li  a2, 99
  beq a1, a2, test_fail
  li  t0, 0x1234
  li  t1, 0x1234
  bne t0, t1, test_fail

  // --------------------------------------------------------------------------
  // Test 5: Branch condition types (BLT, BGE, BLTU, BGEU)
  // --------------------------------------------------------------------------
  li  gp, 5
  li  a1, -10
  li  a2, 10
  // Signed comparison: -10 < 10
  blt a1, a2, 1f
  j   test_fail
1:
  bge a2, a1, 2f
  j   test_fail
2:
  // Unsigned comparison: -10 (0xFFFFFFFFFFFFFFF6) > 10
  bgeu a1, a2, 3f
  j   test_fail
3:
  bltu a2, a1, 4f
  j   test_fail
4:

  // --------------------------------------------------------------------------
  // Test 6: Dual-Issue Branch Interactions
  // Case 6a: Slot 0 ALU, Slot 1 Branch Taken (Squashes subsequent instructions)
  // --------------------------------------------------------------------------
  li  gp, 6
  li  s0, 0
  .align 3
  addi s0, s0, 10              // Slot 0: ALU
  beq  zero, zero, target_s1_br // Slot 1: Branch taken
  addi s0, s0, 100             // Squashed fallthrough!
  j    test_fail

target_s1_br:
  li   t2, 10
  bne  s0, t2, test_fail

  // --------------------------------------------------------------------------
  // Case 6b: Slot 0 Branch Taken (Squashes Slot 1 in the same pair!)
  // --------------------------------------------------------------------------
  li  gp, 7
  li  s1, 0
  .align 3
  beq  zero, zero, target_s0_br // Slot 0: Branch taken
  addi s1, s1, 100             // Slot 1: Must be squashed!
  addi s1, s1, 1000            // Squashed fallthrough!
  j    test_fail

target_s0_br:
  bnez s1, test_fail

  // --------------------------------------------------------------------------
  // Test 8: Multi-iteration loop (exercising branch resolution repeatedly)
  // --------------------------------------------------------------------------
  li  gp, 8
  li  s2, 10
  li  s3, 0

loop_countdown:
  addi s3, s3, 5
  addi s2, s2, -1
  bnez s2, loop_countdown

  li   t3, 50
  bne  s3, t3, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

RVTEST_CODE_END
