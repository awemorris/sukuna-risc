#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // --------------------------------------------------------------------------
  // Test 1: LR.W and SC.W (Success)
  // --------------------------------------------------------------------------
  li  gp, 1
  la  s0, test_data_32
  li  t0, 1234
  sw  t0, 0(s0)

  lr.w a0, (s0)
  li   t0, 1234
  bne  a0, t0, test_fail

  li   t1, 5678
  sc.w a1, t1, (s0)
  bnez a1, test_fail    // SC must return 0 on success

  lw   a2, 0(s0)
  li   t0, 5678
  bne  a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 2: SC.W Failure (Intervening Store Clears Reservation)
  // --------------------------------------------------------------------------
  li   gp, 2
  lr.w a0, (s0)         // Reserve
  li   t0, 9999
  sw   t0, 0(s0)        // Store clears reservation

  li   t1, 1111
  sc.w a1, t1, (s0)     // Must fail
  beqz a1, test_fail    // SC must return non-zero (1) on failure

  lw   a2, 0(s0)
  li   t0, 9999         // Memory should remain 9999
  bne  a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 3: LR.D and SC.D (Success)
  // --------------------------------------------------------------------------
  li   gp, 3
  la   s1, test_data_64
  li   t0, 0x1122334455667788
  sd   t0, 0(s1)

  lr.d a0, (s1)
  li   t0, 0x1122334455667788
  bne  a0, t0, test_fail

  li   t1, 0x99aabbccddeeff00
  sc.d a1, t1, (s1)
  bnez a1, test_fail

  ld   a2, 0(s1)
  li   t0, 0x99aabbccddeeff00
  bne  a2, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 4: SC.D Failure (No Prior Reservation)
  // --------------------------------------------------------------------------
  li   gp, 4
  li   t1, 0x1234
  sc.d a1, t1, (s1)     // No LR was done
  beqz a1, test_fail    // Must fail

  // --------------------------------------------------------------------------
  // Test 5: AMOSWAP.W and AMOSWAP.D
  // --------------------------------------------------------------------------
  li   gp, 5
  li   t0, 42
  sw   t0, 0(s0)

  li   t1, 84
  amoswap.w a0, t1, (s0) // Returns 42, memory becomes 84
  li   t0, 42
  bne  a0, t0, test_fail
  lw   a1, 0(s0)
  li   t0, 84
  bne  a1, t0, test_fail

  li   t0, 0x0123456789abcdef
  sd   t0, 0(s1)
  li   t1, 0xfedcba9876543210
  amoswap.d a0, t1, (s1) // Returns original, memory becomes t1
  li   t0, 0x0123456789abcdef
  bne  a0, t0, test_fail
  ld   a1, 0(s1)
  li   t0, 0xfedcba9876543210
  bne  a1, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 6: AMOADD.W and AMOADD.D
  // --------------------------------------------------------------------------
  li   gp, 6
  li   t0, 100
  sw   t0, 0(s0)
  li   t1, 25
  amoadd.w a0, t1, (s0) // Returns 100, memory becomes 125
  li   t0, 100
  bne  a0, t0, test_fail
  lw   a1, 0(s0)
  li   t0, 125
  bne  a1, t0, test_fail

  li   t0, 0x100000000
  sd   t0, 0(s1)
  li   t1, 0x200000000
  amoadd.d a0, t1, (s1) // Returns 0x100000000, memory becomes 0x300000000
  li   t0, 0x100000000
  bne  a0, t0, test_fail
  ld   a1, 0(s1)
  li   t0, 0x300000000
  bne  a1, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 7: AMOAND.D, AMOOR.D, AMOXOR.D
  // --------------------------------------------------------------------------
  li   gp, 7
  li   t0, 0xff00ff00ff00ff00
  sd   t0, 0(s1)
  li   t1, 0x0f0f0f0f0f0f0f0f
  amoand.d a0, t1, (s1)
  li   t0, 0xff00ff00ff00ff00
  bne  a0, t0, test_fail
  ld   a1, 0(s1)
  li   t0, 0x0f000f000f000f00
  bne  a1, t0, test_fail

  li   t1, 0x00f000f000f000f0
  amoor.d a0, t1, (s1)
  li   t0, 0x0f000f000f000f00
  bne  a0, t0, test_fail
  ld   a1, 0(s1)
  li   t0, 0x0ff00ff00ff00ff0
  bne  a1, t0, test_fail

  li   t1, 0x00ff00ff00ff00ff
  amoxor.d a0, t1, (s1)
  li   t0, 0x0ff00ff00ff00ff0
  bne  a0, t0, test_fail
  ld   a1, 0(s1)
  li   t0, 0x0f0f0f0f0f0f0f0f
  bne  a1, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 8: AMOMIN.W, AMOMAX.W (Signed)
  // --------------------------------------------------------------------------
  li   gp, 8
  li   t0, -50
  sw   t0, 0(s0)
  li   t1, 10
  amomin.w a0, t1, (s0) // min(-50, 10) = -50
  li   t0, -50
  bne  a0, t0, test_fail
  lw   a1, 0(s0)
  li   t0, -50
  bne  a1, t0, test_fail

  li   t1, -100
  amomin.w a0, t1, (s0) // min(-50, -100) = -100
  li   t0, -50
  bne  a0, t0, test_fail
  lw   a1, 0(s0)
  li   t0, -100
  bne  a1, t0, test_fail

  li   t1, 50
  amomax.w a0, t1, (s0) // max(-100, 50) = 50
  li   t0, -100
  bne  a0, t0, test_fail
  lw   a1, 0(s0)
  li   t0, 50
  bne  a1, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 9: AMOMINU.D, AMOMAXU.D (Unsigned)
  // --------------------------------------------------------------------------
  li   gp, 9
  li   t0, 100
  sd   t0, 0(s1)
  li   t1, -1           // 0xffffffffffffffff (huge unsigned)
  amominu.d a0, t1, (s1) // minu(100, 0xff...) = 100
  li   t0, 100
  bne  a0, t0, test_fail
  ld   a1, 0(s1)
  li   t0, 100
  bne  a1, t0, test_fail

  amomaxu.d a0, t1, (s1) // maxu(100, 0xff...) = 0xff...
  li   t0, 100
  bne  a0, t0, test_fail
  ld   a1, 0(s1)
  li   t0, -1
  bne  a1, t0, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv   a0, gp
  RVTEST_FAIL

RVTEST_CODE_END

  .data
  .balign 64
test_data_32:
  .word 0
  .word 0
test_data_64:
  .dword 0
  .dword 0
