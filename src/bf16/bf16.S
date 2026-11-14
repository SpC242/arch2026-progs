# BFloat16 routines: hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)   a0 -> a0
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)  a0, a1 -> a0
# uint16_t bf16_sqrt_asm(uint16_t a)             a0 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tbf16.c.

    .text

    .globl  bf16_from_f32_asm
    .type   bf16_from_f32_asm, @function
    .align  2
bf16_from_f32_asm:
    slli t0, a0, 1    # Drop the sign: exponent in bits 31..24
    lui t3, 0xFF000    # t3 = 0xFF000000
    bgeu t0, t3, .bf16_f32_done    # Exponent field is 0xFF: Inf or NaN
    
    srli t1, a0, 16
    andi t1, t1, 1
    li  t2, 0x7FFF
    add t2, t1, t2
    add a0, a0, t2

.bf16_f32_done:
    srli a0, a0, 16
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    # -----
    # 1. Extract fields
    # -----

    # result_sign = (a ^ b) & 0x8000
    xor t0, a0, a1    # t0 = result_sign
    srli t0, t0, 15
    slli t0, t0, 15

    # exp_a = (a >> 7) & 0xFF
    # exp_b = (b >> 7) & 0xFF
    srli t1, a0, 7    # t1 = exp_a
    andi t1, t1, 0xFF
    srli t2, a1, 7    # t2 = exp_b
    andi t2, t2, 0xFF

    # mant_a = a & 0x7F
    # mant_b = b & 0x7F
    andi t3, a0, 0x7F    # t3 = mant_a
    andi t4, a1, 0x7F    # t4 = mant_b

    # -----
    # 2. Handle NaN and Infinity
    # -----
    li t6, 0xFF
    beq t1, t6, .bf16_check_a_special
    beq t2, t6, .bf16_check_b_special

    jal x0, .bf16_check_zero

.bf16_check_a_special:
    bne t3, x0, .bf16_mul_return_a
    or t6, t2, t4
    beq t6, x0, .bf16_mul_return_nan
    jal x0, .bf16_mul_return_inf

.bf16_check_b_special:
    bne t4, x0, .bf16_mul_return_b
    or t6, t1, t3
    beq t6, x0, .bf16_mul_return_nan
    jal x0, .bf16_mul_return_inf

    # -----
    # 3. Handle zeros
    # -----
.bf16_check_zero:
    # if (exp_a == 0 && mant_a == 0)
    #     return result_sign
    or t6, t1, t3
    beq t6, x0, .bf16_mul_return_zero

    # if (exp_b == 0 && mant_b == 0)
    #     return result_sign
    or t6, t2, t4
    beq t6, x0, .bf16_mul_return_zero

    # -----
    # 4. Normalize operands
    # -----
    li t5, 0    # exp_adjust = 0

    # Normalize a
    beq t1, zero, .bf16_normalize_a

    ori t3, t3, 0x80       # Add hidden bit
    jal x0, .bf16_a_done

.bf16_normalize_a:
    # while (mant_a && (mant_a & 0x80) == 0)
    #     mant_a <<= 1
    #     exp_adjust--
    slli t3, t3, 1
    addi t5, t5, -1
    andi t6, t3, 0x80
    beq t6, x0, .bf16_normalize_a    # repeat until bit 7 is set
    addi t1, x0, 1    # exp_a = 1

.bf16_a_done:
    # Normalize b
    beq t2, zero, .bf16_normalize_b

    ori t4, t4, 0x80    # Add hidden bit
    jal x0, .bf16_b_done

.bf16_normalize_b:
    # while (mant_b && (mant_b & 0x80) == 0) {
    #        mant_b <<= 1;
    #        exp_adjust--;
    #    }
    slli t4, t4, 1    # mant_b <<= 1
    addi t5, t5, -1    # exp_adjust--
    andi t6, t4, 0x80
    beq t6, x0, .bf16_normalize_b    # Repeat until bit 7 is set
    addi t2, x0, 1    # exp_b = 1

.bf16_b_done:
    # -----
    # 5. Multiply significands
    # -----

    # result_exp = exp_a + exp_b - 127 + exp_adjust
    add a3, t1, t2    # a3 = exp_a + exp_b
    addi a3, a3, -127
    add a3, a3, t5

    # result_mant = mant_a * mant_b
    li a2, 0    # a2 = result_mant = 0

.bf16_mul_loop:
    andi t6, t4, 1
    beq t6, zero, .bf16_mul_shift

    add a2, a2, t3

.bf16_mul_shift:
    slli t3, t3, 1
    srli t4, t4, 1
    bne t4, zero, .bf16_mul_loop

    # -----
    # 6. Renormalize product
    # -----
.bf16_renormalize:
    li t6, 0x8000 
    and t6, t6, a2
    beq t6, x0, .bf16_shift_7

    # Product bit 15 = 1
    srli a2, a2, 8
    addi a3, a3, 1

    jal x0, .bf16_check_exp

.bf16_shift_7:
    # Product bit 15 = 0
    srli a2, a2, 7

    # -----
    # 7. Check overflow / underflow
    # -----
.bf16_check_exp:
    # if (result_exp >= 0xFF)
    li t6, 0xFF
    bge a3, t6, .bf16_mul_return_inf

    # if (result_exp <= 0)
    li t6, 0
    bge t6, a3, .bf16_subnormal

    # -----
    # 8. Pack normal result
    # -----

.bf16_pack_normal:
    # return (result_sign << 15) | (result_exp << 7) | (result_mant & 0x7F)
    slli a3, a3, 7    # result_exp << 7
    andi a2, a2, 0x7F    # result_mant & 0x7F
    or a0, a2, a3
    or a0, a0, t0
    ret

.bf16_subnormal:
    # if (result_exp < -6)
    #     return signed zero
    li t6, -6
    blt a3, t6, .bf16_mul_return_zero

    # result_mant = (result_mant & 0x7F) >> (1 - result_exp)
    # return sign | result_mant
    andi a2, a2, 0x7F    # result_mant & 0x7F
    sub  t6, x0, a3     # t6 = -result_exp
    addi t6, t6, 1      # t6 = 1 - result_exp
    srl a2, a2, t6

    or a0, t0, a2
    ret

    # -----
    # Return labels
    # -----

.bf16_mul_return_a:
    ret

.bf16_mul_return_b:
    mv a0, a1
    ret

.bf16_mul_return_inf:
    li a0, 0x7F80     # BF16_INF
    or a0, a0, t0     # Combine sign and Inf
    ret

.bf16_mul_return_nan:
    li a0, 0x7FC0
    ret

.bf16_mul_return_zero:
    add a0, t0, x0
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm

    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2


bf16_sqrt_asm:
    # -----
    # 1. Extract BF16 fields
    # -----

    # t0 = sign
    # sign = (a >> 15) & 1
    srli t0, a0, 15
    andi t0, t0, 1

    # t1 = exp
    # exp = (a >> 7) & 0xFF
    srli t1, a0, 7
    andi t1, t1, 0xFF

    #t2 = mant
    # mant = a & 0x7F
    andi t2, a0, 0x7F

    # -----
    # 2. Handle special values
    # -----
    li  t6, 0xFF
    beq t1, t6, .bf16_sqrt_special

    # if exp == 0 && mant == 0
    #     return zero
    bne  t1, x0, .bf16_sqrt_check_sign
    beq  t2, x0, .bf16_sqrt_return_zero

.bf16_sqrt_check_sign:
    # if (sign != 0)
    #     return BF16_NAN
    bne  t0, x0, .bf16_sqrt_return_nan

    # if (exp == 0)
    #     return BF16_ZERO
    beq  t1, x0, .bf16_sqrt_return_zero

    # Continue normal calculation
    jal x0, .bf16_sqrt_prepare

.bf16_sqrt_special:
    bne t2, x0, .bf16_sqrt_return_a
    bne t0, x0, .bf16_sqrt_return_nan
    jal x0, .bf16_sqrt_return_a

    # -----
    # 3. Prepare exponent and mantissa
    # -----
.bf16_sqrt_prepare:
    # t3 = e
    addi t3, t1, -127    # e = exp - BF16_EXP_BIAS

    # t5 = m 
    # m = 0x80 | mant
    li t5, 0x80
    or t5, t5, t2

    # Check whether e is odd or even
    andi t6, t3, 1
    bne  t6, x0, .bf16_sqrt_odd_exp

.bf16_sqrt_even_exp:
    # new_exp = (e >> 1) + 127
    srai t4, t3, 1
    addi t4, t4, 127

    jal x0, .bf16_sqrt_init_search

.bf16_sqrt_odd_exp:
    # m <<= 1
    slli t5, t5, 1

    # new_exp = ((e - 1) >> 1) + 127
    addi t4, t3, -1
    srai t4, t4, 1
    addi t4, t4, 127

    # -----
    # 4. Initialize Binary Search
    # -----
.bf16_sqrt_init_search:
    li a1, 90    # a1 = low
    li a2, 256    # a2 = high
    li a3, 128    # a3 = result

    # -----
    # 5. Binary Search
    # -----
.bf16_sqrt_binary_search:
    # while (low <= high)
    bltu a2, a1, .bf16_sqrt_pack

    # mid = (low + high) >> 1
    add a4, a1, a2
    srli a4, a4, 1

    # mid * mid
    addi a5, x0, 0    # product = 0
    addi a6, a4, 0    # x = mid
    addi a7, a4, 0    # y = mid

.bf16_sqrt_mul_loop:
    andi t6, a7, 1    # Check lowest bit of y
    beq t6, x0, .bf16_sqrt_mul_shift

    add a5, a5, a6    # product += x

.bf16_sqrt_mul_shift:
    slli a6, a6, 1    # x <<= 1
    srli a7, a7, 1    # y >>= 1
    bne a7, x0, .bf16_sqrt_mul_loop

    # (mid * mid) / 128 <= m
    srli a5, a5, 7
    bgeu t5, a5, .bf16_sqrt_binary_accept

.bf16_sqrt_binary_reject:
    addi a2, a4, -1   # high = mid - 1
    jal x0, .bf16_sqrt_binary_search

.bf16_sqrt_binary_accept:
    # result = mid
    addi a3, a4, 0

    # low = mid + 1
    addi a1, a4, 1

    jal x0, .bf16_sqrt_binary_search

    # -----
    # 6. Pack BF16 result
    # -----
.bf16_sqrt_pack:
    andi a3, a3, 0x7F    # new_mant = result & 0x7F

    # Check overflow
    li t6, 0xFF
    bge t4, t6, .bf16_sqrt_return_inf

    # Check underflow
    bge  x0, t4, .bf16_sqrt_return_zero

    # Pack BF16
    slli t4, t4, 7    # new_exp << 7
    or a0, t4, a3    # (new_exp << 7) | new_mant

    ret

    # -----
    # Return labels
    # -----

.bf16_sqrt_return_a:
    ret

.bf16_sqrt_return_nan:
    li a0, 0x7FC0
    ret

.bf16_sqrt_return_zero:
    addi a0, x0, 0 
    ret

.bf16_sqrt_return_inf:
    li a0, 0x7F80
    ret

    .size   bf16_sqrt_asm, .-bf16_sqrt_asm
