#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // --------------------------------------------------------------------------
  // Test 1: FMV.W.X and FMV.X.W (Single-Precision Move between GPR and FPR)
  // --------------------------------------------------------------------------
  li  gp, 1
  li  a0, 0x3f800000        // 1.0f in IEEE-754 single precision
  fmv.w.x f1, a0
  fmv.x.w a1, f1
  bne a0, a1, test_fail

  // Test sign extension on FMV.X.W with negative number
  li  gp, 2
  li  a0, 0xbf800000        // -1.0f (sign bit is 1)
  fmv.w.x f1, a0
  fmv.x.w a1, f1
  li  t0, 0xffffffffbf800000 // sign-extended to 64-bit
  bne a1, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 3: FLW and FSW (Single-Precision Load and Store)
  // --------------------------------------------------------------------------
  li  gp, 3
  la  s0, test_data_area
  li  a0, 0x40400000        // 3.0f
  sw  a0, 0(s0)
  flw f2, 0(s0)
  fsw f2, 4(s0)
  lw  a1, 4(s0)
  bne a0, a1, test_fail

  // --------------------------------------------------------------------------
  // Test 4: FSGNJ.S, FSGNJN.S, FSGNJX.S
  // --------------------------------------------------------------------------
  li  gp, 4
  li  a0, 0x3f800000        // +1.0f
  li  a1, 0xbf800000        // -1.0f
  fmv.w.x f1, a0
  fmv.w.x f2, a1

  // FSGNJ: f3 gets magnitude of f1, sign of f2 -> -1.0f
  fsgnj.s f3, f1, f2
  fmv.x.w a2, f3
  li  t0, 0xffffffffbf800000
  bne a2, t0, test_fail

  // FSGNJN: f3 gets magnitude of f1, inverted sign of f2 -> +1.0f
  fsgnjn.s f3, f1, f2
  fmv.x.w a2, f3
  li  t0, 0x3f800000
  bne a2, t0, test_fail

  // FSGNJX: f3 gets magnitude of f1, XOR signs (+ ^ - = -) -> -1.0f
  fsgnjx.s f3, f1, f2
  fmv.x.w a2, f3
  li  t0, 0xffffffffbf800000
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 5: FEQ.S, FLT.S, FLE.S
  // --------------------------------------------------------------------------
  li  gp, 5
  li  a0, 0x3f800000        // 1.0f
  li  a1, 0x40000000        // 2.0f
  fmv.w.x f1, a0
  fmv.w.x f2, a1

  feq.s a2, f1, f2          // 1.0 == 2.0 -> 0
  bnez a2, test_fail

  feq.s a2, f1, f1          // 1.0 == 1.0 -> 1
  li  t0, 1
  bne a2, t0, test_fail

  flt.s a2, f1, f2          // 1.0 < 2.0 -> 1
  bne a2, t0, test_fail

  flt.s a2, f2, f1          // 2.0 < 1.0 -> 0
  bnez a2, test_fail

  fle.s a2, f1, f2          // 1.0 <= 2.0 -> 1
  bne a2, t0, test_fail

  fle.s a2, f1, f1          // 1.0 <= 1.0 -> 1
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 6: FMIN.S and FMAX.S
  // --------------------------------------------------------------------------
  li  gp, 6
  fmin.s f3, f1, f2         // min(1.0, 2.0) -> 1.0
  fmv.x.w a2, f3
  li  t0, 0x3f800000
  bne a2, t0, test_fail

  fmax.s f3, f1, f2         // max(1.0, 2.0) -> 2.0
  fmv.x.w a2, f3
  li  t0, 0x40000000
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 7: FCLASS.S
  // --------------------------------------------------------------------------
  li  gp, 7
  fclass.s a2, f1           // positive normal number -> bit 6 = 1 (0x040)
  li  t0, 0x040
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 8: FADD.S, FSUB.S, FMUL.S
  // --------------------------------------------------------------------------
  li  gp, 8
  // 1.5f + 2.25f = 3.75f (0x40700000)
  li  a0, 0x3fc00000        // 1.5f
  li  a1, 0x40100000        // 2.25f
  fmv.w.x f1, a0
  fmv.w.x f2, a1

  fadd.s f3, f1, f2
  fmv.x.w a2, f3
  li  t0, 0x40700000        // 3.75f
  bne a2, t0, test_fail

  // 2.25f - 1.5f = 0.75f (0x3f400000)
  fsub.s f3, f2, f1
  fmv.x.w a2, f3
  li  t0, 0x3f400000        // 0.75f
  bne a2, t0, test_fail

  // 1.5f * 2.0f = 3.0f (0x40400000)
  li  gp, 9
  li  a3, 0x40000000        // 2.0f
  fmv.w.x f4, a3
  fmul.s f5, f1, f4
  fmv.x.w a2, f5
  li  t0, 0x40400000        // 3.0f
  bne a2, t0, test_fail

  // 3.0f / 1.5f = 2.0f (0x40000000)
  li  gp, 10
  fdiv.s f6, f5, f1
  fmv.x.w a2, f6
  li  t0, 0x40000000        // 2.0f
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 11: FCVT Float <-> Integer
  // --------------------------------------------------------------------------
  li  gp, 11
  // fcvt.w.s: 3.0f -> 3
  fcvt.w.s a2, f5
  li  t0, 3
  bne a2, t0, test_fail

  // fcvt.l.s: 3.0f -> 3
  li  gp, 12
  fcvt.l.s a2, f5
  li  t0, 3
  bne a2, t0, test_fail

  // fcvt.s.w: 5 -> 5.0f (0x40a00000)
  li  gp, 13
  li  a4, 5
  fcvt.s.w f7, a4
  fmv.x.w a2, f7
  li  t0, 0x40a00000
  bne a2, t0, test_fail

  // fcvt.s.l: 5 -> 5.0f (0x40a00000)
  li  gp, 14
  fcvt.s.l f8, a4
  fmv.x.w a2, f8
  li  t0, 0x40a00000
  bne a2, t0, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

  .data
  .align 4
test_data_area:
  .dword 0
  .dword 0
  .dword 0
  .dword 0

RVTEST_CODE_END
