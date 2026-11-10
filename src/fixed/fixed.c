#include "fixed.h"

uint32_t op1(uint32_t a, uint32_t b, int *n)
{
    *n = 0;
    while (b) {
        unsigned c = (a & b) << 1;
        a = a ^ b;
        b = c;
        ++*n;
    }
    return a;
}

uint32_t op2(uint32_t a, uint32_t b)
{
    /* int n;
    return op1(a, op1( ~b, 1, &n), &n); */
    return a - b;
}

uint32_t op3(uint32_t a, uint32_t b)
{
    /* return (a >> 1) + (b >> 1) + (a & b & 1); */
    return (a & b) + ((a ^ b) >> 1);
}

int32_t q_mul(int32_t a, int32_t b)
{
    /* return (int32_t)(((int64_t)a * b + (1 << 19)) >> 20); */
    /* x = a, sign-extended to 64 bits */
    uint32_t x_lo = (uint32_t) a;
    uint32_t x_hi = a < 0 ? UINT32_MAX : 0;

    /* y = |b|, sign applied at the end */
    uint32_t y = (uint32_t) b;
    int negative = b < 0;

    if (negative) {
        y = 0U - y;
    }

    uint32_t result_lo = 0;
    uint32_t result_hi = 0;

    /* Shift and add over the set bits of y */
    while (y) {
        if (y & 1U) {
            uint32_t old = result_lo;
            result_lo += x_lo;
            result_hi += x_hi + (result_lo < old); /* carry */
        }

        x_hi = (x_hi << 1) | (x_lo >> 31);
        x_lo <<= 1;
        y >>= 1;
    }

    /* 64-bit negate */
    if (negative) {
        uint32_t borrow = result_lo != 0;
        result_lo = 0U - result_lo;
        result_hi = 0U - result_hi - borrow;
    }

    /* Add 2^19 to round */
    uint32_t carry = result_lo > UINT32_MAX - (1U << 19);
    result_lo += 1U << 19;
    result_hi += carry;

    return (int32_t) ((result_hi << 12) | (result_lo >> 20));
}
