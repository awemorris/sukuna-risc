#include "riscv_test.h"

RVTEST_CODE_BEGIN

  // --------------------------------------------------------------------------
  // Test 1: Active Interrupt Delivery, Handler Execution, and MRET
  // --------------------------------------------------------------------------
  li  gp, 1

  // Set trap handler address in mtvec (Direct Mode: bottom 2 bits = 0)
  la  t0, trap_handler
  csrw mtvec, t0

  // Enable Machine Software Interrupt in mie (bit 3)
  li  t0, (1 << 3)
  csrw mie, t0

  // Globally enable interrupts in mstatus (MIE, bit 3)
  li  t0, (1 << 3)
  csrs mstatus, t0

  // Setup verification registers
  li  s4, 0
  li  s5, 0

  // Trigger MSIP by writing 1 to CLINT msip register for Hart 0 (0x02000000)
  li  a0, 0x02000000
  li  a1, 1
  sw  a1, 0(a0)

  // Wait loop: interrupt should preempt this loop
wait_irq:
  addi s5, s5, 1
  li   t1, 1000
  blt  s5, t1, wait_irq

  // If we reached here without handler running, fail
  j   test_fail

  .align 2
post_irq_resume:
  // Verify trap handler ran and set s4
  li  t0, 0xdeadbeef
  bne s4, t0, test_fail

  // --------------------------------------------------------------------------
  // Test 2: Interrupt Masking via mstatus.MIE and Deferred Delivery
  // --------------------------------------------------------------------------
  li  gp, 2

  // Globally disable interrupts
  li  t0, (1 << 3)
  csrc mstatus, t0

  // Clear s4
  li  s4, 0

  // Trigger MSIP while MIE is disabled
  li  a1, 1
  sw  a1, 0(a0)

  // Execute some instructions; trap must NOT be taken
  li  s5, 0
mask_loop:
  addi s5, s5, 1
  li   t1, 20
  blt  s5, t1, mask_loop

  // Verify trap did not run yet
  bnez s4, test_fail

  // Verify MSIP bit in mip is set (bit 3)
  csrr t0, mip
  andi t0, t0, (1 << 3)
  beqz t0, test_fail

  // Now enable mstatus.MIE; trap must fire immediately!
  li  t0, (1 << 3)
  csrs mstatus, t0

  // Instruction right after csrs or next should be interrupted
  nop
  nop
  nop

post_irq_resume2:
  // Verify trap handler ran
  li  t0, 0xdeadbeef
  bne s4, t0, test_fail

  // Clean up
  csrw mie, zero
  csrc mstatus, (1 << 3)

test_pass:
  RVTEST_PASS

test_fail:
  mv  a0, gp
  RVTEST_FAIL

  // --------------------------------------------------------------------------
  // Machine Trap Handler
  // --------------------------------------------------------------------------
  .align 4
trap_handler:
  // Verify mcause has interrupt bit (bit 63) set and exception code 3 (MSIP)
  csrr t2, mcause
  li   t3, 1
  slli t3, t3, 63
  ori  t3, t3, 3
  bne  t2, t3, test_fail

  // Verify mepc is non-zero
  csrr t2, mepc
  beqz t2, test_fail

  // Clear CLINT MSIP by writing 0
  li   t4, 0x02000000
  sw   zero, 0(t4)

  // Mark that interrupt was successfully processed
  li   s4, 0xdeadbeef

  // For Test 1, if we were in wait_irq, skip ahead to post_irq_resume
  li   t5, 1
  bne  gp, t5, 1f
  la   t2, post_irq_resume
  csrw mepc, t2
  mret

1:
  // For Test 2, return directly to post_irq_resume2
  la   t2, post_irq_resume2
  csrw mepc, t2
  mret

RVTEST_CODE_END
