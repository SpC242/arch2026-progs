# rubik_solve_asm: optimal 2x2x2 cube solver, hand-written RV32I.
#
# int rubik_solve_asm(const char *state, char *out, size_t cap)
#                                   a0 = state, a1 = out, a2 = cap; result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions, no heap, no recursion. Tests: tests/trubik.c.
#
# Stack frame (224 bytes, 16-byte aligned):
#     0..143   search frames, 12 bytes each, depth 0..11 (C: stack[])
#                +0 P   +2 O   +4 child P   +6 child O   (halfwords)
#                +8 F   +9 T   +10 parent face          (bytes)
#   144..157   parsed permutation p[7] at 144 and orientation o[7] at 151
#              (C: state_t s); after ranking, the root P and O are kept at
#              144 and 146 (C: initial_p, initial_o)
#   160, 164   out, cap
#   168..215   s0..s11
#
# Registers during the search, with the C variable each one stands for:
#   s0 frame->p            s1 frame->o
#   s2 frame->next_p       s3 frame->next_o
#   s4 move_face[move]     s5 move_turn[move]     s6 frame->previous_face
#   s7 depth               s8 bound - (depth + 1)
#   s9 bound               s10 next_bound - bound
#   s11 frame = &stack[depth]
#   a2 row table           a3 ida_permutation_transition[face]
#   a4 ida_orientation_transition[face]
#   a5 ida_permutation_distance              a6 ida_orientation_distance
#   t6 the constant 3 (TURNS_PER_FACE and FACES)

    .equ FRAME, 224
    .equ FRM_SIZE, 12
    .equ PARSE_P, 144
    .equ PARSE_O, 151
    .equ ROOT_P, 144
    .equ ROOT_O, 146
    .equ SAVE_OUT, 160
    .equ SAVE_CAP, 164
    .equ NO_EXCESS, 255

# C (inner loop of rank_coordinates):
#     uint32_t smaller = 0;
#     for (uint32_t j = i + 1; j < CUBIES; ++j)
#         if (state->p[j] < state->p[i])
#             ++smaller;
# Unrolled at assembly time; the result is left in t3.
.macro COUNT_SMALLER i
    lbu t1, (PARSE_P + \i)(sp)    # t1 = state->p[i]
    addi t3, x0, 0    # smaller = 0
    .set .Lj, \i + 1    # j = i + 1
    .rept 6 - \i    # for (; j < CUBIES; ++j)
    lbu t4, (PARSE_P + .Lj)(sp)    # t4 = state->p[j]
    sltu t4, t4, t1    # t4 = state->p[j] < state->p[i]
    add t3, t3, t4    # smaller += t4   (++smaller)
    .set .Lj, .Lj + 1
    .endr
.endm

# C: row = &ida_permutation_transition[face][0];
#    row = &ida_orientation_transition[face][0];
.macro LOAD_ROWS
    slli t0, s4, 2    # t0 = face * sizeof(uint32_t)
    add t0, t0, a2    # t0 = &rows[face]
    lw a3, 0(t0)    # a3 = ida_permutation_transition[face]
    lw a4, 12(t0)    # a4 = ida_orientation_transition[face]
.endm

    .text

    .globl rubik_solve_asm
    .type rubik_solve_asm, @function
    .align 2
rubik_solve_asm:                            # int rubik_solve(const char *state, char *out, size_t cap)
    addi sp, sp, -FRAME    # {  /* room for stack[], state_t s and the saves */
    sw s0, 168(sp)    # (callee-saved registers, no C counterpart)
    sw s1, 172(sp)
    sw s2, 176(sp)
    sw s3, 180(sp)
    sw s4, 184(sp)
    sw s5, 188(sp)
    sw s6, 192(sp)
    sw s7, 196(sp)
    sw s8, 200(sp)
    sw s9, 204(sp)
    sw s10, 208(sp)
    sw s11, 212(sp)
    sw a1, SAVE_OUT(sp)    # out and cap are needed again at the end
    sw a2, SAVE_CAP(sp)

    # ---- parse_state(): the permutation half ----
    # C:  for (uint32_t i = 0; i < CUBIES; ++i) {
    #         if (input[i] < '1' || input[i] > '7')
    #             return 0;
    #         state->p[i] = (uint8_t) (input[i] - '1');
    #     }
    # and from valid():  for (j < i) if (state->p[j] == state->p[i]) return 0;
    addi t0, x0, 0    # i = 0
    addi t2, x0, 7    # t2 = CUBIES
    addi t5, x0, 0    # seen = 0   (bit k set: cubie k already used)
.Lparse_perm:
    add t1, a0, t0    # t1 = &input[i]
    lbu t3, 0(t1)    # t3 = input[i]
    addi t3, t3, -49    # t3 = input[i] - '1'
    bgeu t3, t2, .Linvalid    # if (input[i] < '1' || input[i] > '7') return -1;
    addi t4, x0, 1
    sll t4, t4, t3    # t4 = 1u << state->p[i]
    and t1, t5, t4
    bne t1, x0, .Linvalid    # if (seen & t4) return -1;   /* repeated cubie */
    or t5, t5, t4    # seen |= t4
    add t1, sp, t0
    sb t3, PARSE_P(t1)    # state->p[i] = input[i] - '1'
    addi t0, t0, 1    # ++i
    bne t0, t2, .Lparse_perm    # while (i < CUBIES)

    # ---- parse_state(): the orientation half, with the sum of valid() ----
    # C:  for (uint32_t i = 0; i < CUBIES; ++i) {
    #         char digit = input[CUBIES + i];
    #         if (digit < '1' || digit > '3')
    #             return 0;
    #         state->o[i] = (uint8_t) (digit - '1');
    #     }
    #     sum += state->o[i]; if (sum >= 3) sum -= 3;     (from valid())
    addi t0, x0, 0    # i = 0
    addi t2, x0, 3    # t2 = 3
    addi t4, x0, 7    # t4 = CUBIES
    addi t5, x0, 0    # sum = 0
.Lparse_orient:
    add t1, a0, t0
    lbu t3, 7(t1)    # digit = input[CUBIES + i]
    addi t3, t3, -49    # digit - '1'
    bgeu t3, t2, .Linvalid    # if (digit < '1' || digit > '3') return -1;
    add t1, sp, t0
    sb t3, PARSE_O(t1)    # state->o[i] = digit - '1'
    add t5, t5, t3    # sum += state->o[i]
    bltu t5, t2, 1f    # if (sum >= 3)
    sub t5, t5, t2    # sum -= 3;
1:
    addi t0, t0, 1    # ++i
    bne t0, t4, .Lparse_orient    # while (i < CUBIES)
    lbu t3, 14(a0)
    bne t3, x0, .Linvalid    # if (input[2 * CUBIES] != '\0') return -1;
    bne t5, x0, .Linvalid    # if (sum != 0) return -1;   /* end of valid() */

    # ---- rank_coordinates(): the permutation ----
    # C:  uint32_t p = digit[0];
    #     p = (p << 2) + (p << 1) + digit[1]; /* * 6 */
    #     p = (p << 2) + p + digit[2];        /* * 5 */
    #     p = (p << 2) + digit[3];            /* * 4 */
    #     p = (p << 1) + p + digit[4];        /* * 3 */
    #     p = (p << 1) + digit[5];            /* * 2 */
    COUNT_SMALLER 0    # t3 = digit[0]
    add s0, t3, x0    # p = digit[0]
    COUNT_SMALLER 1    # t3 = digit[1]
    slli t0, s0, 1    # t0 = p << 1
    slli s0, s0, 2    # p = p << 2
    add s0, s0, t0    # p = (p << 2) + (p << 1)
    add s0, s0, t3    # + digit[1]
    COUNT_SMALLER 2    # t3 = digit[2]
    slli t0, s0, 2    # t0 = p << 2
    add s0, s0, t0    # p = (p << 2) + p
    add s0, s0, t3    # + digit[2]
    COUNT_SMALLER 3    # t3 = digit[3]
    slli s0, s0, 2    # p = p << 2
    add s0, s0, t3    # + digit[3]
    COUNT_SMALLER 4    # t3 = digit[4]
    slli t0, s0, 1    # t0 = p << 1
    add s0, s0, t0    # p = (p << 1) + p
    add s0, s0, t3    # + digit[4]
    COUNT_SMALLER 5    # t3 = digit[5]
    slli s0, s0, 1    # p = p << 1
    add s0, s0, t3    # + digit[5]

    # ---- rank_coordinates(): the orientation ----
    # C:  uint32_t o = 0;
    #     for (uint32_t i = 0; i < CUBIES - 1; ++i)
    #         o = (o << 1) + o + state->o[i]; /* * 3 */
    addi s1, x0, 0    # o = 0
    .set .Lk, 0
    .rept 6    # for (i = 0; i < CUBIES - 1; ++i)
    lbu t3, (PARSE_O + .Lk)(sp)    # t3 = state->o[i]
    slli t0, s1, 1    # t0 = o << 1
    add s1, s1, t0    # o = (o << 1) + o
    add s1, s1, t3    # + state->o[i]
    .set .Lk, .Lk + 1
    .endr

    sh s0, ROOT_P(sp)    # initial_p = p   (*permutation = p)
    sh s1, ROOT_O(sp)    # initial_o = o   (*orientation = o)

    # ---- Constants for the search (no C counterpart: C indexes the arrays) ----
    la a5, rubik_asm_perm_dist    # a5 = ida_permutation_distance
    la a6, rubik_asm_orient_dist    # a6 = ida_orientation_distance
    la a2, .Lrows    # a2 = rows of both transition tables
    addi t6, x0, 3    # t6 = TURNS_PER_FACE = FACES = 3

    # C (solve_ida):  if (initial_p == 0 && initial_o == 0) return 0;
    or t0, s0, s1
    bne t0, x0, .Lstart    # if (initial_p != 0 || initial_o != 0) search
    addi a7, x0, 0    # length = 0
    jal x0, .Lwrite

.Lstart:
    # C:  uint8_t bound = heuristic(initial_p, initial_o);
    #     heuristic(): permutation > orientation ? permutation : orientation
    add t0, a5, s0
    lbu t0, 0(t0)    # permutation = ida_permutation_distance[p]
    add t1, a6, s1
    lbu t1, 0(t1)    # orientation = ida_orientation_distance[o]
    bgeu t0, t1, 1f    # if (permutation < orientation)
    add t0, t1, x0    # permutation = orientation;
1:
    add s9, t0, x0    # bound = max(...)

    # ---- One IDA* iteration ----
    # C:  while (bound <= MAX_SOLUTION) {
    #         uint8_t next_bound = UINT8_MAX;
    #         uint8_t depth = 0;
    #         stack[0] = (search_frame_t) {
    #             initial_p, initial_o, initial_p, initial_o, 0, FACE_NONE};
.Literation:
    lhu s0, ROOT_P(sp)    # frame->p = initial_p
    lhu s1, ROOT_O(sp)    # frame->o = initial_o
    add s11, sp, x0    # frame = &stack[0]
    addi s7, x0, 0    # depth = 0
    addi s8, s9, -1    # rem = bound - (depth + 1)
    addi s10, x0, NO_EXCESS    # next_bound = UINT8_MAX  (kept as next_bound - bound)
    addi s6, x0, 3    # frame->previous_face = FACE_NONE
    addi s4, x0, 0    # frame->next_move = 0: face R ...
    addi s5, x0, 0    # ... quarter turn
    LOAD_ROWS    # rows of face R

    # C (body of for (;;)):
    #     if (move_turn[move] == 0) {
    #         frame->next_p = frame->p;
    #         frame->next_o = frame->o;
    #     }
    #     frame->next_p = ida_permutation_transition[face][frame->next_p];
    #     frame->next_o = ida_orientation_transition[face][frame->next_o];
.Lgen:
    bne s5, x0, 1f    # if (move_turn[move] == 0) {
    add s2, s0, x0    # frame->next_p = frame->p;
    add s3, s1, x0    # frame->next_o = frame->o;
1:
    slli t0, s2, 1    # t0 = next_p * sizeof(uint16_t)
    add t0, t0, a3
    lhu s2, 0(t0)    # next_p = ida_permutation_transition[face][next_p]
    slli t1, s3, 1    # t1 = next_o * sizeof(uint16_t)
    add t1, t1, a4
    lhu s3, 0(t1)    # next_o = ida_orientation_transition[face][next_o]

    # C:  uint8_t child_f = child_depth + heuristic(frame->next_p, frame->next_o);
    #     if (child_f > bound) { ... continue; }
    add t0, a5, s2
    lbu t0, 0(t0)    # permutation = ida_permutation_distance[next_p]
    add t1, a6, s3
    lbu t1, 0(t1)    # orientation = ida_orientation_distance[next_o]
    bgeu t0, t1, 2f    # if (permutation < orientation)
    add t0, t1, x0    # permutation = orientation;
2:                                          # t0 = h = heuristic(next_p, next_o)
    bltu s8, t0, .Lprune    # if (child_f > bound)  <=>  if (h > rem)

    # C:  path[depth] = move;   (here: F and T are stored in the frame below)
    #     if (frame->next_p == 0 && frame->next_o == 0)
    #         return child_depth;
    or t1, s2, s3
    beq t1, x0, .Lfound    # if (next_p == 0 && next_o == 0) found

    # C:  if (child_depth >= MAX_SOLUTION) continue;
    #     A child that passes the bound at depth 11 has rem <= 0, so h = 0 and
    #     it is the solved cube, already handled above: the test is dropped.
    #
    # C:  depth = child_depth;
    #     stack[depth] = (search_frame_t) {frame->next_p, frame->next_o,
    #                                       frame->next_p, frame->next_o, 0, face};
    # Here the parent frame is saved first, because it lives in registers.
    sh s0, 0(s11)    # stack[depth].p = frame->p
    sh s1, 2(s11)    # stack[depth].o = frame->o
    sh s2, 4(s11)    # stack[depth].next_p = frame->next_p
    sh s3, 6(s11)    # stack[depth].next_o = frame->next_o
    sb s4, 8(s11)    # stack[depth].next_move (face part)
    sb s5, 9(s11)    # stack[depth].next_move (turn part)
    sb s6, 10(s11)    # stack[depth].previous_face
    add s0, s2, x0    # new frame->p = next_p
    add s1, s3, x0    # new frame->o = next_o
    add s6, s4, x0    # new frame->previous_face = face
    addi s7, s7, 1    # depth = child_depth
    addi s8, s8, -1    # rem = bound - (depth + 1)
    addi s11, s11, FRM_SIZE    # frame = &stack[depth]
    # C:  next_move = 0, then the same-face test skips face previous_face:
    #     if (face == frame->previous_face)
    #         frame->next_move = (face + 1U) * TURNS_PER_FACE;
    sltiu s4, s6, 1    # face = (previous_face == R) ? B : R
    addi s5, x0, 0    # turn = 0
    LOAD_ROWS
    jal x0, .Lgen

    # C:  if (child_f > bound) {
    #         if (child_f < next_bound)
    #             next_bound = child_f;
    #         continue;
    #     }
    # child_f = bound + (h - rem), so the smallest h - rem is kept instead.
.Lprune:
    sub t0, t0, s8    # t0 = child_f - bound
    bgeu t0, s10, .Ladvance    # if (child_f < next_bound)
    add s10, t0, x0    # next_bound = child_f;

    # C:  uint8_t move = frame->next_move++;
    #     if (face == frame->previous_face) { frame->next_move = (face + 1) * 3; continue; }
    #     if (frame->next_move >= MOVES) { ... back up ... }
.Ladvance:
    addi s5, s5, 1    # ++turn   (next_move++ within the face)
    bne s5, t6, .Lgen    # if (turn < TURNS_PER_FACE) try it
    addi s5, x0, 0    # turn = 0
    addi s4, s4, 1    # ++face
    bne s4, s6, 3f    # if (face == frame->previous_face)
    addi s4, s4, 1    # ++face;   /* skip the same face */
3:
    bgeu s4, t6, .Lbacktrack    # if (frame->next_move >= MOVES): face 3, or 4
                                            #   past the root's FACE_NONE
    LOAD_ROWS    # rows of the new face
    jal x0, .Lgen

    # C:  if (frame->next_move >= MOVES) {
    #         if (depth == 0)
    #             break;
    #         --depth;
    #         continue;
    #     }
.Lbacktrack:
    beq s7, x0, .Literation_end    # if (depth == 0) break;
    addi s7, s7, -1    # --depth;
    addi s8, s8, 1    # rem = bound - (depth + 1)
    addi s11, s11, -FRM_SIZE    # frame = &stack[depth]
    lhu s0, 0(s11)    # frame->p
    lhu s1, 2(s11)    # frame->o
    lhu s2, 4(s11)    # frame->next_p
    lhu s3, 6(s11)    # frame->next_o
    lbu s4, 8(s11)    # face of frame->next_move
    lbu s5, 9(s11)    # turn of frame->next_move
    lbu s6, 10(s11)    # frame->previous_face
    LOAD_ROWS
    jal x0, .Ladvance    # continue;   (the parent tries its next move)

    # C:  if (next_bound > MAX_SOLUTION)
    #         return -1;
    #     bound = next_bound;
    # }   (end of while (bound <= MAX_SOLUTION))
.Literation_end:
    addi t0, x0, NO_EXCESS
    beq s10, t0, .Linvalid    # next_bound == UINT8_MAX: unreachable
    add s9, s9, s10    # bound = next_bound
    addi t0, x0, 11
    bltu t0, s9, .Linvalid    # if (bound > MAX_SOLUTION) return -1;  (unreachable)
    jal x0, .Literation

    # C:  path[depth] = move;
    #     ... return child_depth;
.Lfound:
    sb s4, 8(s11)    # path[depth]: face of the last move
    sb s5, 9(s11)    # path[depth]: turn of the last move
    addi a7, s7, 1    # length = child_depth = depth + 1

    # ---- Output, the second half of rubik_solve() ----
.Lwrite:
    lw a1, SAVE_OUT(sp)    # out
    lw a2, SAVE_CAP(sp)    # cap

    # C:  size_t need = 1;
    #     for (int i = 0; i < length; ++i)
    #         need += (move_names[path[i]][1] ? 2U : 1U) + (i > 0 ? 1U : 0U);
    addi t0, x0, 1    # need = 1
    addi t1, x0, 0    # i = 0
    add t2, sp, x0    # t2 = &stack[i]  (holds path[i])
.Lneed_loop:
    beq t1, a7, .Lneed_done    # for (; i < length; ...)
    lbu t3, 9(t2)    # turn of path[i]
    sltu t3, x0, t3    # t3 = move_names[path[i]][1] != 0
    add t0, t0, t3    # need += (name is 2 characters)
    addi t0, t0, 1    # need += 1   (the face letter)
    beq t1, x0, 4f    # if (i > 0)
    addi t0, t0, 1    # need += 1;   (the space)
4:
    addi t1, t1, 1    # ++i
    addi t2, t2, FRM_SIZE
    jal x0, .Lneed_loop
.Lneed_done:
    # C:  if (need > cap) {
    #         if (cap >= 1)
    #             out[0] = '\0';
    #         return -2;
    #     }
    bgeu a2, t0, .Lfits    # if (need > cap) {
    beq a2, x0, 5f    # if (cap >= 1)
    sb x0, 0(a1)    # out[0] = '\0';
5:
    addi a0, x0, -2    # return -2;
    jal x0, .Lreturn

    # C:  char *w = out;
    #     for (int i = 0; i < length; ++i) {
    #         const char *name = move_names[path[i]];
    #         if (i > 0)
    #             *w++ = ' ';
    #         *w++ = name[0];
    #         if (name[1])
    #             *w++ = name[1];
    #     }
    #     *w = '\0';
    #     return length;
.Lfits:
    la t4, .Lface_char    # name[0] of each face
    la t5, .Lturn_char    # name[1] of each turn
    addi t1, x0, 0    # i = 0   (a1 serves as w)
    add t2, sp, x0    # t2 = &stack[i]
.Lwrite_loop:
    beq t1, a7, .Lwrite_done    # for (; i < length; ...)
    beq t1, x0, 6f    # if (i > 0)
    addi t3, x0, 32
    sb t3, 0(a1)    # *w = ' ';
    addi a1, a1, 1    # w++;
6:
    lbu t3, 8(t2)    # face of path[i]
    add t3, t3, t4
    lbu t3, 0(t3)    # name[0]
    sb t3, 0(a1)    # *w = name[0];
    addi a1, a1, 1    # w++;
    lbu t3, 9(t2)    # turn of path[i]
    beq t3, x0, 7f    # if (name[1])
    add t3, t3, t5
    lbu t3, 0(t3)    # name[1]
    sb t3, 0(a1)    # *w = name[1];
    addi a1, a1, 1    # w++;
7:
    addi t1, t1, 1    # ++i
    addi t2, t2, FRM_SIZE
    jal x0, .Lwrite_loop
.Lwrite_done:
    sb x0, 0(a1)    # *w = '\0';
    add a0, a7, x0    # return length;
    jal x0, .Lreturn

.Linvalid:
    addi a0, x0, -1    # return -1;   /* out stays untouched */
.Lreturn:
    lw s0, 168(sp)    # (restore the callee-saved registers)
    lw s1, 172(sp)
    lw s2, 176(sp)
    lw s3, 180(sp)
    lw s4, 184(sp)
    lw s5, 188(sp)
    lw s6, 192(sp)
    lw s7, 196(sp)
    lw s8, 200(sp)
    lw s9, 204(sp)
    lw s10, 208(sp)
    lw s11, 212(sp)
    addi sp, sp, FRAME
    ret
    .size rubik_solve_asm, .-rubik_solve_asm

    .section .rodata
    .align 2
# &ida_permutation_transition[face][0] and &ida_orientation_transition[face][0]
# for face 0, 1, 2: rows of 5040 and 729 halfwords. C reaches a row by adding
# count once or twice; a table of pointers avoids even that.
.Lrows:
    .word rubik_asm_perm_move    # ida_permutation_transition[0]
    .word rubik_asm_perm_move + 10080    # ida_permutation_transition[1]
    .word rubik_asm_perm_move + 20160    # ida_permutation_transition[2]
    .word rubik_asm_orient_move    # ida_orientation_transition[0]
    .word rubik_asm_orient_move + 1458    # ida_orientation_transition[1]
    .word rubik_asm_orient_move + 2916    # ida_orientation_transition[2]
# move_names[] split into its two characters: the face letter and the
# suffix of the turn, so "R'" is .Lface_char[0] followed by .Lturn_char[2].
.Lface_char:
    .byte 82, 66, 68    # 'R', 'B', 'D'
.Lturn_char:
    .byte 0, 50, 39    # none, '2', '\''
    