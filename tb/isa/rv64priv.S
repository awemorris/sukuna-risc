#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // --------------------------------------------------------------------------
  // 1. CSR Register Read/Write Tests (mscratch)
  // --------------------------------------------------------------------------
  // Test 1: CSRRW (write new value, read old 0)
  li  gp, 1
  li  t0, 0x12345678abcdef01
  csrrw t1, mscratch, t0
  li  t2, 0
  bne t1, t2, test_fail

  // Test 2: CSRRS with x0 (read without modifying)
  li  gp, 2
  csrrs t1, mscratch, x0
  bne t1, t0, test_fail

  // Test 3: CSRRS (set bits)
  li  gp, 3
  li  t2, 0x00000000000000fe
  csrrs t1, mscratch, t2
  // Old value was 0x12345678abcdef01
  bne t1, t0, test_fail
  // New value is 0x12345678abcdef01 | 0xfe = 0x12345678abcdefff
  csrr t1, mscratch
  li  t3, 0x12345678abcdefff
  bne t1, t3, test_fail

  // Test 4: CSRRC (clear bits)
  li  gp, 4
  li  t2, 0x00000000000000ff
  csrrc t1, mscratch, t2
  // Old value was 0x12345678abcdefff
  bne t1, t3, test_fail
  // New value is 0x12345678abcdef00
  csrr t1, mscratch
  li  t0, 0x12345678abcdef00
  bne t1, t0, test_fail

  // Test 5: CSR Immediate variants (csrrwi, csrrsi, csrrci)
  li  gp, 5
  csrrwi t1, mscratch, 0x1f
  bne t1, t0, test_fail

  csrr t1, mscratch
  li  t0, 0x1f
  bne t1, t0, test_fail

  csrrsi t1, mscratch, 0x00
  bne t1, t0, test_fail

  // --------------------------------------------------------------------------
  // 2. Exception & MRET Return Test
  // --------------------------------------------------------------------------
  // Test 6: Setup mtvec to trap_handler, execute ecall, and mret back
  li  gp, 6
  la  t0, my_m_trap_handler
  csrw mtvec, t0

  li  t2, 0x55aa           // Marker before ecall
  ecall                    // Should vector to my_m_trap_handler
resume_point:
  // After mret: t2 should have been changed to 0xdeadbeef by handler
  li  t3, 0xdeadbeef
  bne t2, t3, test_fail

  // --------------------------------------------------------------------------
  // 3. EBREAK Exception Test
  // --------------------------------------------------------------------------
  li  gp, 7
  li  t2, 0
  ebreak                   // Should vector to my_m_trap_handler with mcause = 3
resume_ebreak:
  li  t3, 0xcafe
  bne t2, t3, test_fail

  // --------------------------------------------------------------------------
  // 4. Floating-Point CSRs (fcsr, frm, fflags) Test
  // --------------------------------------------------------------------------
  li  gp, 8
  // Write fflags = 0x1f
  li  t0, 0x1f
  csrw fflags, t0
  csrr t1, fflags
  bne t1, t0, test_fail

  // Write frm = 0x4
  li  t0, 0x4
  csrw frm, t0
  csrr t1, frm
  bne t1, t0, test_fail

  // Read fcsr: (0x4 << 5) | 0x1f = 0x9f
  csrr t1, fcsr
  li  t0, 0x9f
  bne t1, t0, test_fail

  // --------------------------------------------------------------------------
  // 5. FENCE and FENCE.I Test
  // --------------------------------------------------------------------------
  li  gp, 9
  fence rw, rw
  fence.i
  li  t0, 42
  bne t0, t0, test_fail

  // --------------------------------------------------------------------------
  // 6. WFI and SFENCE.VMA Test
  // --------------------------------------------------------------------------
  li  gp, 10
  sfence.vma x0, x0
  wfi

  // --------------------------------------------------------------------------
  // 7. S-Mode Trap Delegation & SRET Test
  // --------------------------------------------------------------------------
  li  gp, 11
  // Delegate Breakpoint (cause 3) to S-mode via medeleg bit 3
  li  t0, (1 << 3)
  csrw medeleg, t0

  // Set stvec to my_s_trap_handler
  la  t0, my_s_trap_handler
  csrw stvec, t0

  // Prepare to enter S-mode: set mstatus.MPP = 1 (S-mode = 01)
  li  t0, ~(3 << 11)
  csrr t1, mstatus
  and t1, t1, t0
  li  t0, (1 << 11)
  or  t1, t1, t0
  csrw mstatus, t1

  // Set mepc to s_mode_code
  la  t0, s_mode_code
  csrw mepc, t0

  // Enter S-mode via mret
  mret

s_mode_code:
  // Now running in S-mode! Execute ebreak -> delegated to my_s_trap_handler
  li  s1, 0x1111
  ebreak
s_resume_ebreak:
  // Handler changes s1 to 0x2222
  li  t0, 0x2222
  bne s1, t0, test_fail

  // Ecall in S-mode -> not delegated, traps to M-mode (cause 9 = EXC_ECALL_S)
  ecall

m_resumed_from_s:
  // S-mode test passed and returned to M-mode!
  csrw medeleg, x0

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

  // Custom Machine Trap Handler
  .align 4
my_m_trap_handler:
  csrr t4, mcause
  li   t5, 11              // Machine ECALL cause = 11
  beq  t4, t5, 1f
  li   t5, 3               // Breakpoint cause = 3
  beq  t4, t5, 2f
  li   t5, 9               // S-mode ECALL cause = 9
  beq  t4, t5, 3f
  j    test_fail

1: // Handled M-ECALL
  csrr t4, mepc
  addi t4, t4, 4
  csrw mepc, t4
  li   t2, 0xdeadbeef
  mret

2: // Handled M-EBREAK
  csrr t4, mepc
  addi t4, t4, 4
  csrw mepc, t4
  li   t2, 0xcafe
  mret

3: // Handled S-ECALL -> switch back to M-mode
  la   t4, m_resumed_from_s
  csrw mepc, t4
  // Set MPP = M (3 << 11)
  li   t4, (3 << 11)
  csrs mstatus, t4
  mret

  // Custom Supervisor Trap Handler
  .align 4
my_s_trap_handler:
  csrr s2, scause
  li   s3, 3               // Breakpoint cause = 3
  bne  s2, s3, test_fail
  csrr s2, sepc
  addi s2, s2, 4
  csrw sepc, s2
  li   s1, 0x2222
  sret

RVTEST_CODE_END
