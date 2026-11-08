# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2

gcd_u32_asm:
    beq a0, x0, return_b
    beq a1, x0, done

    # Initialize shift
    addi t0, x0, 0

common_factor:
    or t1, a0, a1
    andi t1, t1, 1
    bne t1, x0, make_a_odd

    srli a0, a0, 1  # a >>= 1
    srli a1, a1, 1  # b >>= 1
    addi t0, t0, 1  # shift ++

    jal x0, common_factor

make_a_odd:
    andi t2, a0, 1
    bne t2, x0, b_entry
    srli a0, a0, 1  # a >>= 1
    jal x0, make_a_odd

b_entry:    # Runs once on entry: b may already be odd
    andi t3, a1, 1
    bne  t3, x0, compare_and_swap

strip_b:    # b is always even here
    srli a1, a1, 1
    andi t3, a1, 1
    beq  t3, x0, strip_b    # Keep shifting while b is still even

compare_and_swap:
    bgeu a1, a0, subtract
    
    # Swap a0 and a1
    add t2, a0, x0         # temp = a
    add a0, a1, x0         # a = b
    add a1, t2, x0         # b = temp

subtract:
    sub  a1, a1, a0
    bne  a1, x0, strip_b    # Nonzero and even: shift without testing first
                            # Zero: fall through to restore

restore:
    sll a0, a0, t0  # a = a << shift 
    ret

return_b:
    add a0, a1, x0    # a is zero: the answer is b

done:
    ret    # b is zero: the answer is already in a0
    .size   gcd_u32_asm, .-gcd_u32_asm
