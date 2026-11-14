#include "bf16.h"

#define BF16_EXP_BIAS 127

#define BF16_NAN 0x7FC0
#define BF16_ZERO 0x0000
#define BF16_INF 0x7F80

uint16_t bf16_from_f32(uint32_t f32bits)
{
    /* Handle NaN and Infinity */
    if (((f32bits >> 23) & 0xFF) == 0xFF) {
        return (uint16_t) (f32bits >> 16);
    }

    /* Round to nearest, ties to Even */
    f32bits += ((f32bits >> 16) & 1) + 0x7FFF;

    return (uint16_t) (f32bits >> 16);
}

uint16_t bf16_mul(uint16_t a, uint16_t b)
{
    uint16_t sign_a = (a >> 15) & 1;
    uint16_t sign_b = (b >> 15) & 1;
    int16_t exp_a = (a >> 7) & 0xFF;
    int16_t exp_b = (b >> 7) & 0xFF;
    uint16_t mant_a = a & 0x7F;
    uint16_t mant_b = b & 0x7F;

    uint16_t result_sign = sign_a ^ sign_b;

    if (exp_a == 0xFF) {
        if (mant_a)
            return a; /* NaN */
        if (exp_b == 0 && mant_b == 0)
            return BF16_NAN;                   /* Inf * 0 = NaN */
        return (result_sign << 15) | BF16_INF; /* Inf * finite = Inf */
    }
    if (exp_b == 0xFF) {
        if (mant_b)
            return b; /* NaN */
        if (exp_a == 0 && mant_a == 0)
            return BF16_NAN;                   /* 0 * Inf = NaN */
        return (result_sign << 15) | BF16_INF; /* finite * Inf = Inf */
    }

    if ((exp_a == 0 && mant_a == 0) || (exp_b == 0 && mant_b == 0)) {
        return (result_sign << 15); /* Zero result */
    }

    int16_t exp_adjust = 0;
    if (exp_a == 0) {
        while (mant_a && (mant_a & 0x80) == 0) {
            mant_a <<= 1;
            exp_adjust--;
        }
        exp_a = 1;
    } else {
        mant_a |= 0x80; /* Normalize */
    }
    if (exp_b == 0) {
        while (mant_b && (mant_b & 0x80) == 0) {
            mant_b <<= 1;
            exp_adjust--;
        }
        exp_b = 1;
    } else {
        mant_b |= 0x80; /* Normalize */
    }


    uint16_t result_mant = mant_a * mant_b; /* 8-bit by 8-bit product */

    int16_t result_exp = exp_a + exp_b - 127 + exp_adjust;

    if (result_mant & 0x8000) { /* Renormalize if needed */
        result_mant = result_mant >> 8;
        result_exp++;
    } else {
        result_mant = result_mant >> 7;
    }

    if (result_exp >= 0xFF) {
        return (result_sign << 15) | BF16_INF; /* Overflow to Inf */
    }
    if (result_exp <= 0) {
        if (result_exp < -6) {
            return (result_sign << 15); /* Underflow to zero */
        }
        result_mant = (result_mant & 0x7F) >> (1 - result_exp);
        return (result_sign << 15) | result_mant;
    }
    return (result_sign << 15) | (result_exp << 7) | (result_mant & 0x7F);
}

uint16_t bf16_sqrt(uint16_t a)
{
    uint16_t sign = (a >> 15) & 1;
    int16_t exp = (a >> 7) & 0xFF;
    uint16_t mant = a & 0x7F;

    /* Handle special cases */
    if (exp == 0xFF) {
        if (mant)
            return a; /* NaN propagation */
        if (sign)
            return BF16_NAN; /* sqrt(-Inf) = NaN */
        return a;            /* sqrt(+Inf) = +Inf */
    }
    /* sqrt(0) = 0 */
    if (!exp && !mant)
        return BF16_ZERO;

    /* sqrt(-finite) = NaN */
    if (sign)
        return BF16_NAN;

    /* Flush denormals to zero */
    if (!exp)
        return BF16_ZERO;

    /* Direct bit manipulation square root algorithm */
    /* For sqrt: new_exp = (old_exp - bias) / 2 + bias */
    int32_t e = exp - BF16_EXP_BIAS;
    int32_t new_exp;

    /* Normalize mantissa */
    uint32_t m = 0x80 | mant;  // Add implicit leading 1

    /* Adjust for odd exponents: sqrt(2^odd * m) = 2^((odd-1)/2) * sqrt(2*m) */
    if (e & 1) {
        m <<= 1;  // Make exponent even
        new_exp = ((e - 1) >> 1) + BF16_EXP_BIAS;
    } else {
        new_exp = (e >> 1) + BF16_EXP_BIAS;
    }

    /* Now m is in range [128, 256) or [256, 512) if exponent was odd */
    /* Binary search for integer square root */
    /* We want result where result^2 = m * 128 (since 128 represents 1.0) */

    uint32_t low = 90;     /* Min sqrt */
    uint32_t high = 256;   /* Max sqrt */
    uint32_t result = 128; /* Default */

    /* Binary search for square root of m */
    while (low <= high) {
        uint32_t mid = (low + high) >> 1;

        if ((mid * mid) / 128 <= m) { /* Compare mid^2 with m*128 */
            result = mid;             /* This could be our answer */
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    /* Extract 7-bit mantissa (remove implicit 1) */
    uint16_t new_mant = result & 0x7F;

    /* Check for overflow/underflow */
    if (new_exp >= 0xFF)
        return 0x7F80; /* +Inf */
    if (new_exp <= 0)
        return BF16_ZERO; /* Underflow to zero */

    return (uint16_t) ((new_exp << 7) | new_mant);
}
