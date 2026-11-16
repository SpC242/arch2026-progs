#include "rubik.h"
#include "ida-tables.h"

/*
 * Optimal 2x2x2 solver: IDA* over two coordinates, the permutation of the
 * seven free cubies (a Lehmer code in [0, 5040)) and their orientation (six
 * base-3 digits in [0, 729)). The heuristic is the larger of two pattern
 * database distances, so it never overestimates and the first solution found
 * is a shortest one. Ported from the Homework 1 solver with the host-side
 * I/O, statistics and self-test removed.
 */

enum {
    CUBIES = 7,
    PERMUTATIONS = 5040,
    ORIENTATIONS = 729,
    FACES = 3,
    TURNS_PER_FACE = 3,
    MOVES = FACES * TURNS_PER_FACE,
    FACE_NONE = FACES,
    MAX_SOLUTION = 11
};

typedef struct {
    uint8_t p[CUBIES], o[CUBIES];
} state_t;

typedef struct {
    uint16_t p, o;
    uint16_t next_p, next_o;
    uint8_t next_move;
    uint8_t previous_face;
} search_frame_t;

static const char *const move_names[MOVES] = {"R",  "R2", "R'", "B", "B2",
                                              "B'", "D",  "D2", "D'"};
static const uint8_t move_face[MOVES] = {0, 0, 0, 1, 1, 1, 2, 2, 2};
static const uint8_t move_turn[MOVES] = {0, 1, 2, 0, 1, 2, 0, 1, 2};

/*
 * The orientation sum is kept reduced modulo 3 by conditional subtraction.
 * Each digit is at most 2 and the running sum is at most 2 before the add,
 * so the sum never exceeds 4 and one subtraction always suffices.
 */
static int valid(const state_t *state)
{
    uint32_t sum = 0;
    for (uint32_t i = 0; i < CUBIES; ++i) {
        if (state->p[i] >= CUBIES || state->o[i] >= 3)
            return 0;
        for (uint32_t j = 0; j < i; ++j)
            if (state->p[j] == state->p[i])
                return 0;
        sum += state->o[i];
        if (sum >= 3)
            sum -= 3;
    }
    return sum == 0;
}

/*
 * The first seven digits are the permutation and the last seven the
 * orientation. A NUL inside the string fails the digit test, so a short
 * input is rejected without reading past its end.
 */
static int parse_state(const char *input, state_t *state)
{
    for (uint32_t i = 0; i < CUBIES; ++i) {
        if (input[i] < '1' || input[i] > '7')
            return 0;
        state->p[i] = (uint8_t) (input[i] - '1');
    }
    for (uint32_t i = 0; i < CUBIES; ++i) {
        char digit = input[CUBIES + i];
        if (digit < '1' || digit > '3')
            return 0;
        state->o[i] = (uint8_t) (digit - '1');
    }
    return input[2 * CUBIES] == '\0' && valid(state);
}

/*
 * Rank a state into its two coordinates without multiplication or division.
 * The permutation is a Lehmer code evaluated by Horner's rule with the
 * multipliers 6, 5, 4, 3 and 2 written as shifts and adds. The orientation
 * keeps six base-3 digits; the seventh follows from the zero-sum rule.
 */
static void rank_coordinates(const state_t *state,
                             uint16_t *permutation,
                             uint16_t *orientation)
{
    uint32_t digit[CUBIES - 1];
    for (uint32_t i = 0; i < CUBIES - 1; ++i) {
        uint32_t smaller = 0;
        for (uint32_t j = i + 1; j < CUBIES; ++j)
            if (state->p[j] < state->p[i])
                ++smaller;
        digit[i] = smaller;
    }

    uint32_t p = digit[0];
    p = (p << 2) + (p << 1) + digit[1]; /* * 6 */
    p = (p << 2) + p + digit[2];        /* * 5 */
    p = (p << 2) + digit[3];            /* * 4 */
    p = (p << 1) + p + digit[4];        /* * 3 */
    p = (p << 1) + digit[5];            /* * 2 */

    uint32_t o = 0;
    for (uint32_t i = 0; i < CUBIES - 1; ++i)
        o = (o << 1) + o + state->o[i]; /* * 3 */

    *permutation = (uint16_t) p;
    *orientation = (uint16_t) o;
}

static uint8_t heuristic(uint16_t p, uint16_t o)
{
    uint8_t permutation = ida_permutation_distance[p];
    uint8_t orientation = ida_orientation_distance[o];
    return permutation > orientation ? permutation : orientation;
}

/*
 * Iterative IDA* with an explicit stack, so the search uses a fixed 12-frame
 * array instead of recursion. A frame tries its moves in order; the quarter
 * turn of a face starts from the parent, and the half and inverse turns
 * apply one more quarter turn to the previous child. Turning the same face
 * twice in a row is skipped.
 */
static int solve_ida(uint16_t initial_p,
                     uint16_t initial_o,
                     uint8_t path[MAX_SOLUTION])
{
    search_frame_t stack[MAX_SOLUTION + 1];
    uint8_t bound = heuristic(initial_p, initial_o);

    if (initial_p == 0 && initial_o == 0)
        return 0;

    while (bound <= MAX_SOLUTION) {
        uint8_t next_bound = UINT8_MAX;
        uint8_t depth = 0;
        stack[0] = (search_frame_t) {initial_p, initial_o, initial_p,
                                     initial_o, 0,         FACE_NONE};

        for (;;) {
            search_frame_t *frame = &stack[depth];
            if (frame->next_move >= MOVES) {
                if (depth == 0)
                    break;
                --depth;
                continue;
            }

            uint8_t move = frame->next_move++;
            uint8_t face = move_face[move];
            if (face == frame->previous_face) {
                frame->next_move = (uint8_t) ((face + 1U) * TURNS_PER_FACE);
                continue;
            }

            if (move_turn[move] == 0) {
                frame->next_p = frame->p;
                frame->next_o = frame->o;
            }
            frame->next_p = ida_permutation_transition[face][frame->next_p];
            frame->next_o = ida_orientation_transition[face][frame->next_o];

            uint8_t child_depth = (uint8_t) (depth + 1U);
            uint8_t child_f =
                (uint8_t) (child_depth +
                           heuristic(frame->next_p, frame->next_o));
            if (child_f > bound) {
                if (child_f < next_bound)
                    next_bound = child_f;
                continue;
            }

            path[depth] = move;
            if (frame->next_p == 0 && frame->next_o == 0)
                return child_depth;

            if (child_depth >= MAX_SOLUTION)
                continue;

            depth = child_depth;
            stack[depth] = (search_frame_t) {
                frame->next_p, frame->next_o, frame->next_p, frame->next_o, 0,
                face};
        }

        if (next_bound > MAX_SOLUTION)
            return -1;
        bound = next_bound;
    }
    return -1;
}

int rubik_solve(const char *state, char *out, size_t cap)
{
    state_t s;
    uint16_t p, o;
    uint8_t path[MAX_SOLUTION];

    if (!parse_state(state, &s))
        return -1; /* out stays untouched */

    rank_coordinates(&s, &p, &o);
    int length = solve_ida(p, o, path);
    if (length < 0)
        return -1; /* unreachable for a valid state */

    /* Each name is one or two characters, joined by single spaces. */
    size_t need = 1;
    for (int i = 0; i < length; ++i)
        need += (move_names[path[i]][1] ? 2U : 1U) + (i > 0 ? 1U : 0U);
    if (need > cap) {
        if (cap >= 1)
            out[0] = '\0';
        return -2;
    }

    char *w = out;
    for (int i = 0; i < length; ++i) {
        const char *name = move_names[path[i]];
        if (i > 0)
            *w++ = ' ';
        *w++ = name[0];
        if (name[1])
            *w++ = name[1];
    }
    *w = '\0';
    return length;
}
