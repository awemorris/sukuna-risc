#ifndef _RISCV_TEST_H
#define _RISCV_TEST_H

#define RVTEST_CODE_BEGIN \
  .section .text.init;    \
  .align  4;              \
  .globl _start;          \
_start:                   \
  csrr  t6, mhartid;      \
  bnez  t6, 99f;          \
  j     98f;              \
99:                       \
  wfi;                    \
  j     99b;              \
98:

#define RVTEST_PASS       \
  li  a0, 0;              \
  ecall;                  \
1: j 1b;

#define RVTEST_FAIL       \
  ecall;                  \
1: j 1b;

#define RVTEST_CODE_END

// ----------------------------------------------------------------------------
// Test Macros
// ----------------------------------------------------------------------------

#define TEST_CASE(testnum, testreg, correctval, code...) \
  li  gp, testnum;                                       \
  code;                                                  \
  li  t0, correctval;                                    \
  bne testreg, t0, test_fail;

#define TEST_IMM_OP(testnum, inst, result, val, imm)     \
  TEST_CASE(testnum, a1, result,                         \
    li  a2, val;                                         \
    inst a1, a2, imm;                                    \
  )

#define TEST_RR_OP(testnum, inst, result, val1, val2)    \
  TEST_CASE(testnum, a1, result,                         \
    li  a2, val1;                                        \
    li  a3, val2;                                        \
    inst a1, a2, a3;                                     \
  )

#define TEST_BR_TAKEN(testnum, inst, val1, val2)         \
  li  gp, testnum;                                       \
  li  a2, val1;                                          \
  li  a3, val2;                                          \
  inst a2, a3, 1f;                                       \
  j test_fail;                                           \
1:

#define TEST_BR_NOT_TAKEN(testnum, inst, val1, val2)     \
  li  gp, testnum;                                       \
  li  a2, val1;                                          \
  li  a3, val2;                                          \
  inst a2, a3, 2f;                                       \
  j 1f;                                                  \
2: j test_fail;                                          \
1:

#endif
