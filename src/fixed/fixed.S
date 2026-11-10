# op1, op2, op3 and q_mul: hand-written RV32I.
#
# uint32_t op1_asm(uint32_t a, uint32_t b, int *n)   a0, a1, a2 -> a0
# uint32_t op2_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# uint32_t op3_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# int32_t  q_mul_asm(int32_t a, int32_t b)           a0, a1 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. q_mul forms a 64-bit product in a register pair. Tests:
# tests/tfixed.c.

    .text

    .globl  op1_asm
    .type   op1_asm, @function
    .align  2
op1_asm:
    addi t0, x0, 0    # n = Pass count
    beq a1, x0, op1_done

op1_loop:
    and t1, a0, a1    # t1 = a & b
    slli t1, t1, 1    # t1 = (a & b) << 1

    xor a0, a0, a1
    addi a1, t1, 0
    addi t0, t0, 1    # ++n
    bne a1, x0, op1_loop

op1_done:
    sw t0, 0(a2)     # *n = pass count
    ret
    .size   op1_asm, .-op1_asm

    .globl  op2_asm
    .type   op2_asm, @function
    .align  2
op2_asm:
    sub a0, a0, a1
    ret
    .size   op2_asm, .-op2_asm

    .globl  op3_asm
    .type   op3_asm, @function
    .align  2
op3_asm:
    and t0, a0, a1
    xor t1, a0, a1
    srli t1, t1, 1
    add a0, t0, t1 
    ret
    .size   op3_asm, .-op3_asm

    .globl  q_mul_asm
    .type   q_mul_asm, @function
    .align  2
q_mul_asm:
    # Check sign of b
    slt t0, a1, x0    # t0 = (b < 0) (negative)
    beq t0, x0, positive_b

    sub a1, x0, a1    # b = -b

positive_b:
    # Initialize 64-bit x
    addi t1, a0, 0    # x_lo = a
    srai t2, a0, 31   # x_hi = sign extension

    # result = 0
    addi t3, x0, 0    # result_lo
    addi t4, x0, 0    # result_hi

    beq  a1, x0, q_mul_sign

q_mul_loop:
    # Check lowest bit of y
    andi t5, a1, 1
    beq t5, x0, q_mul_shift

    # result += x (64-bit)
    add t3, t3, t1
    sltu t5, t3, t1   # Carry from low 32-bit
    add t4, t4, t2
    add t4, t4, t5

q_mul_shift:
    # x <<= 1 (64-bit)
    srli t5, t1, 31
    slli t2, t2, 1
    or t2, t2, t5
    slli t1, t1, 1

    # y >>= 1
    srli a1, a1, 1

    bne a1, x0, q_mul_loop

q_mul_sign:
    beq t0, x0, q_mul_round

    # result = -result (64-bit)
    sub t3, x0, t3   
    sltu t5, x0, t3    # t5 = 1 if t3 != 0
    sub t4, x0, t4
    sub t4, t4, t5

q_mul_round:
    # Add rounding bias 2^19
    lui t5, 0x80       # t5 = 0x00080000
    add t3, t3, t5
    sltu t5, t3, t5    # Carry
    add t4, t4, t5

    # result >> 20
    srli a0, t3, 20
    slli t5, t4, 12
    or a0, a0, t5

    ret
    .size   q_mul_asm, .-q_mul_asm
