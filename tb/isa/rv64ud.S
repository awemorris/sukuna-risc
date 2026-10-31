#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // --------------------------------------------------------------------------
  // Test 1: FMV.D.X and FMV.X.D (Double-Precision Move between GPR and FPR)
  // --------------------------------------------------------------------------
  li  gp, 1
  li  a0, 0x3ff0000000000000        // 1.0d in IEEE-754 double precision
  fmv.d.x f1, a0
  fmv.x.d a1, f1
  bne a0, a1, test_fail

  // Test negative double move
  li  gp, 2
  li  a0, 0xbff0000000000000        // -1.0d
  fmv.d.x f1, a0
  fmv.x.d a1, f1
  bne a0, a1, test_fail

  // --------------------------------------------------------------------------
  // Test 3: FLD and FSD (Double-Precision Load and Store)
  // --------------------------------------------------------------------------
  li  gp, 3
  la  s0, test_data_area
  li  a0, 0x4008000000000000        // 3.0d
  sd  a0, 0(s0)
  fld f2, 0(s0)
  fsd f2, 8(s0)
  ld  a1, 8(s0)
  bne a0, a1, test_fail

  // --------------------------------------------------------------------------
  // Test 4: FSGNJ.D, FSGNJN.D, FSGNJX.D
  // --------------------------------------------------------------------------
  li  gp, 4
  li  a0, 0x3ff0000000000000        // +1.0d
  li  a1, 0xbff0000000000000        // -1.0d
  fmv.d.x f1, a0
  fmv.d.x f2, a1

  // FSGNJ: f3 gets magnitude of f1, sign of f2 -> -1.0d
  fsgnj.d f3, f1, f2
  fmv.x.d a2, f3
  li  t0, 0xbff0000000000000
  bne a2, t0, test_fail

  // FSGNJN: f3 gets magnitude of f1, inverted sign of f2 -> +1.0d
  fsgnjn.d f3, f1, f2
  fmv.x.d a2, f3
  li  t0, 0x3ff0000000000000
  bne a2, t0, test_fail

  // FSGNJX: f3 gets magnitude of f1, XOR signs (+ ^ - = -) -> -1.0d
  fsgnjx.d f3, f1, f2
  fmv.x.d a2, f3
  li  t0, 0xbff0000000000000
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 5: FEQ.D, FLT.D, FLE.D
  // --------------------------------------------------------------------------
  li  gp, 5
  li  a0, 0x3ff0000000000000        // 1.0d
  li  a1, 0x4000000000000000        // 2.0d
  fmv.d.x f1, a0
  fmv.d.x f2, a1

  feq.d a2, f1, f2                  // 1.0 == 2.0 -> 0
  bnez a2, test_fail

  feq.d a2, f1, f1                  // 1.0 == 1.0 -> 1
  li  t0, 1
  bne a2, t0, test_fail

  flt.d a2, f1, f2                  // 1.0 < 2.0 -> 1
  bne a2, t0, test_fail

  flt.d a2, f2, f1                  // 2.0 < 1.0 -> 0
  bnez a2, test_fail

  fle.d a2, f1, f2                  // 1.0 <= 2.0 -> 1
  bne a2, t0, test_fail

  fle.d a2, f1, f1                  // 1.0 <= 1.0 -> 1
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 6: FMIN.D and FMAX.D
  // --------------------------------------------------------------------------
  li  gp, 6
  fmin.d f3, f1, f2                 // min(1.0, 2.0) -> 1.0
  fmv.x.d a2, f3
  li  t0, 0x3ff0000000000000
  bne a2, t0, test_fail

  fmax.d f3, f1, f2                 // max(1.0, 2.0) -> 2.0
  fmv.x.d a2, f3
  li  t0, 0x4000000000000000
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 7: FCLASS.D
  // --------------------------------------------------------------------------
  li  gp, 7
  fclass.d a2, f1                   // positive normal number -> bit 6 = 1 (0x040)
  li  t0, 0x040
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 8: FADD.D, FSUB.D, FMUL.D, FDIV.D
  // --------------------------------------------------------------------------
  li  gp, 8
  // 1.5d + 2.25d = 3.75d (0x400e000000000000)
  li  a0, 0x3ff8000000000000        // 1.5d
  li  a1, 0x4002000000000000        // 2.25d
  fmv.d.x f1, a0
  fmv.d.x f2, a1

  fadd.d f3, f1, f2
  fmv.x.d a2, f3
  li  t0, 0x400e000000000000        // 3.75d
  bne a2, t0, test_fail

  // 2.25d - 1.5d = 0.75d (0x3fe8000000000000)
  li  gp, 9
  fsub.d f3, f2, f1
  fmv.x.d a2, f3
  li  t0, 0x3fe8000000000000        // 0.75d
  bne a2, t0, test_fail

  // 1.5d * 2.0d = 3.0d (0x4008000000000000)
  li  gp, 10
  li  a3, 0x4000000000000000        // 2.0d
  fmv.d.x f4, a3
  fmul.d f5, f1, f4
  fmv.x.d a2, f5
  li  t0, 0x4008000000000000        // 3.0d
  bne a2, t0, test_fail

  // 3.0d / 1.5d = 2.0d (0x4000000000000000)
  li  gp, 11
  fdiv.d f6, f5, f1
  fmv.x.d a2, f6
  li  t0, 0x4000000000000000        // 2.0d
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 12: FCVT Float <-> Integer (DP)
  // --------------------------------------------------------------------------
  li  gp, 12
  // fcvt.w.d: 3.0d -> 3
  fcvt.w.d a2, f5
  li  t0, 3
  bne a2, t0, test_fail

  // fcvt.l.d: 3.0d -> 3
  li  gp, 13
  fcvt.l.d a2, f5
  li  t0, 3
  bne a2, t0, test_fail

  // fcvt.d.w: 5 -> 5.0d (0x4014000000000000)
  li  gp, 14
  li  a4, 5
  fcvt.d.w f7, a4
  fmv.x.d a2, f7
  li  t0, 0x4014000000000000
  bne a2, t0, test_fail

  // fcvt.d.l: 5 -> 5.0d (0x4014000000000000)
  li  gp, 15
  fcvt.d.l f8, a4
  fmv.x.d a2, f8
  li  t0, 0x4014000000000000
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 16: FCVT.S.D and FCVT.D.S (Float-Float Conversion)
  // --------------------------------------------------------------------------
  li  gp, 16
  // Convert 1.5d (f1) to single precision -> 1.5f (0x3fc00000)
  fcvt.s.d f9, f1
  fmv.x.w a2, f9
  li  t0, 0x3fc00000
  bne a2, t0, test_fail

  // Convert 1.5f (f9) back to double precision -> 1.5d (0x3ff8000000000000)
  li  gp, 17
  fcvt.d.s f10, f9
  fmv.x.d a2, f10
  li  t0, 0x3ff8000000000000
  bne a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 18: Double-Precision Offset Load/Store (fld, fsd)
  // --------------------------------------------------------------------------
  li  gp, 18
  la  s1, test_data_area
  li  a0, 0x400e000000000000        // 3.75d
  sd  a0, 16(s1)
  fld fs0, 16(s1)
  fsd fs0, 24(s1)
  ld  a1, 24(s1)
  bne a0, a1, test_fail

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
  .dword 0
  .dword 0

RVTEST_CODE_END
