#include "riscv_test.h"

  .section .text.init
  .align  4
  .globl _start
_start:
  csrr  s11, mhartid
  li    t0, 1
  beq   s11, t0, hart1_entry
  li    t0, 2
  beq   s11, t0, hart2_entry

// ============================================================================
// HART 0 ENTRY
// ============================================================================
hart0_entry:
  // --------------------------------------------------------------------------
  // Test 1: Non-Blocking Store-Allocate (MSHR) & Hit-Under-Miss
  // --------------------------------------------------------------------------
  li    gp, 1
  la    s0, hit_line
  la    s1, miss_line

  // Prime hit_line into L1D
  ld    a0, 0(s0)
  li    t0, 0x123456789ABCDEF0
  bne   a0, t0, test_fail

  // Store Miss to miss_line (pushed to Store Buffer + MSHR), immediately
  // followed by Hit-Under-Miss Loads to hit_line!
  li    t1, 0xCAFEBABE87654321
  sd    t1, 0(s1)
  ld    a1, 0(s0)
  ld    a2, 8(s0)
  bne   a1, t0, test_fail
  li    t2, 0x0FEDCBA987654321
  bne   a2, t2, test_fail

  // Delay loop to let Store Buffer drain and MSHR background refill complete
  li    t3, 16
1:
  addi  t3, t3, -1
  bnez  t3, 1b

  // Load from miss_line (should hit on the MSHR-allocated L1D line)
  ld    a3, 0(s1)
  bne   a3, t1, test_fail

  // --------------------------------------------------------------------------
  // Test 2: Prime shared_line into Hart 0 L1D, then release Harts 1 & 2
  // --------------------------------------------------------------------------
  li    gp, 2
  la    s2, shared_line
  ld    t0, 0(s2)

  la    s3, start_barrier
  li    t0, 1
  sd    t0, 0(s3)
  fence rw, rw

  // False-sharing concurrent writes to shared_line (offset +0 and byte +24)
  li    t1, 0x1111222233334444
  sd    t1, 0(s2)
  li    t2, 0xA5
  sb    t2, 24(s2)
  fence rw, rw

  // --------------------------------------------------------------------------
  // Test 3: Multi-Hart Atomic Contention (AMOADD.D and LR.D/SC.D)
  // --------------------------------------------------------------------------
  li    gp, 3
  la    s4, amo_counter
  la    s5, lrsc_counter
  li    t3, 4
  li    t4, 1
h0_atomic_loop:
  amoadd.d zero, t4, (s4)
h0_cas_retry:
  lr.d  t5, (s5)
  addi  t5, t5, 1
  sc.d  t6, t5, (s5)
  bnez  t6, h0_cas_retry
  addi  t3, t3, -1
  bnez  t3, h0_atomic_loop

  fence rw, rw

  // Wait for Hart 1 and Hart 2 to finish
  la    s6, hart1_done
  la    s7, hart2_done
wait_harts:
  ld    t0, 0(s6)
  ld    t1, 0(s7)
  and   t0, t0, t1
  beqz  t0, wait_harts

  fence rw, rw

  // Verify false-sharing writes on shared_line across all 3 Harts
  li    gp, 4
  ld    a0, 0(s2)
  li    t0, 0x1111222233334444
  bne   a0, t0, test_fail

  li    gp, 5
  ld    a1, 8(s2)
  li    t0, 0x5555666677778888
  bne   a1, t0, test_fail

  li    gp, 6
  ld    a2, 16(s2)
  li    t0, 0x9999AAAABBBBCCCC
  bne   a2, t0, test_fail

  li    gp, 7
  lwura:
  lwu   a3, 24(s2)
  li    t0, 0xBEEF5AA5
  bne   a3, t0, test_fail

  // Verify cross-Hart message passing payload from Hart 1 and Hart 2
  li    gp, 8
  la    t2, msg_data_h1
  ld    a4, 0(t2)
  li    t0, 0xDEAD1111BEEF2222
  bne   a4, t0, test_fail

  li    gp, 9
  la    t2, msg_data_h2
  ld    a5, 0(t2)
  li    t0, 0xCAFE3333BABE4444
  bne   a5, t0, test_fail

  // Verify multi-Hart AMOADD.D counter == 12
  li    gp, 10
  ld    a6, 0(s4)
  li    t0, 12
  bne   a6, t0, test_fail

  // Verify multi-Hart LR.D/SC.D counter == 12
  li    gp, 11
  ld    a7, 0(s5)
  li    t0, 12
  bne   a7, t0, test_fail

test_pass:
  RVTEST_PASS

test_fail:
  mv    a0, gp
  RVTEST_FAIL

// ============================================================================
// HART 1 ENTRY
// ============================================================================
hart1_entry:
  la    s2, shared_line
  ld    t0, 0(s2)         // Prime shared_line into Hart 1 L1D

  la    s3, start_barrier
h1_wait_start:
  ld    t0, 0(s3)
  beqz  t0, h1_wait_start
  fence rw, rw

  // False-sharing concurrent writes to shared_line (offset +8 and byte +25)
  li    t1, 0x5555666677778888
  sd    t1, 8(s2)
  li    t2, 0x5A
  sb    t2, 25(s2)

  // Message passing payload from Hart 1
  la    t3, msg_data_h1
  li    t4, 0xDEAD1111BEEF2222
  sd    t4, 0(t3)
  fence rw, rw

  // Multi-Hart Atomic Contention (4x AMOADD.D + 4x LR.D/SC.D)
  la    s4, amo_counter
  la    s5, lrsc_counter
  li    t3, 4
  li    t4, 1
h1_atomic_loop:
  amoadd.d zero, t4, (s4)
h1_cas_retry:
  lr.d  t5, (s5)
  addi  t5, t5, 1
  sc.d  t6, t5, (s5)
  bnez  t6, h1_cas_retry
  addi  t3, t3, -1
  bnez  t3, h1_atomic_loop

  fence rw, rw
  la    s6, hart1_done
  li    t0, 1
  sd    t0, 0(s6)
  fence rw, rw
h1_sleep:
  wfi
  j     h1_sleep

// ============================================================================
// HART 2 ENTRY
// ============================================================================
hart2_entry:
  la    s2, shared_line
  ld    t0, 0(s2)         // Prime shared_line into Hart 2 L1D

  la    s3, start_barrier
h2_wait_start:
  ld    t0, 0(s3)
  beqz  t0, h2_wait_start
  fence rw, rw

  // False-sharing concurrent writes to shared_line (offset +16 and halfword +26)
  li    t1, 0x9999AAAABBBBCCCC
  sd    t1, 16(s2)
  li    t2, 0xBEEF
  sh    t2, 26(s2)

  // Message passing payload from Hart 2
  la    t3, msg_data_h2
  li    t4, 0xCAFE3333BABE4444
  sd    t4, 0(t3)
  fence rw, rw

  // Multi-Hart Atomic Contention (4x AMOADD.D + 4x LR.D/SC.D)
  la    s4, amo_counter
  la    s5, lrsc_counter
  li    t3, 4
  li    t4, 1
h2_atomic_loop:
  amoadd.d zero, t4, (s4)
h2_cas_retry:
  lr.d  t5, (s5)
  addi  t5, t5, 1
  sc.d  t6, t5, (s5)
  bnez  t6, h2_cas_retry
  addi  t3, t3, -1
  bnez  t3, h2_atomic_loop

  fence rw, rw
  la    s7, hart2_done
  li    t0, 1
  sd    t0, 0(s7)
  fence rw, rw
h2_sleep:
  wfi
  j     h2_sleep

  .data
  .balign 64
hit_line:
  .dword 0x123456789ABCDEF0
  .dword 0x0FEDCBA987654321
  .space 48

  .balign 64
miss_line:
  .dword 0
  .space 56

  .balign 64
shared_line:
  .dword 0
  .dword 0
  .dword 0
  .dword 0
  .space 32

  .balign 64
start_barrier:
  .dword 0
  .space 56

  .balign 64
hart1_done:
  .dword 0
  .space 56

  .balign 64
hart2_done:
  .dword 0
  .space 56

  .balign 64
msg_data_h1:
  .dword 0
  .space 56

  .balign 64
msg_data_h2:
  .dword 0
  .space 56

  .balign 64
amo_counter:
  .dword 0
  .space 56

  .balign 64
lrsc_counter:
  .dword 0
  .space 56
