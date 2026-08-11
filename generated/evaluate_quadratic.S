.syntax unified
.arch armv7-a
.fpu vfpv3-d16
.thumb
.text

@ Runtime-free Idris numerical leaves for Android armeabi-v7a.
@ C ABI: softfp at the boundary, hardware Float32 internally.

        .p2align 2
        .global evaluate_quadratic
        .type evaluate_quadratic, %function
        .thumb_func
evaluate_quadratic:
        sub.w   sp, sp, #48
        str     r0, [sp, #0]
        str     r1, [sp, #4]
        movw    r0, #0
        movt    r0, #0
        str     r0, [sp, #8]
        ldr     r0, [sp, #0]
        ldr     r1, [sp, #8]
        add.w   r0, r0, r1, lsl #2
        vldr    s0, [r0]
        vstr    s0, [sp, #12]
        movw    r0, #1
        movt    r0, #0
        str     r0, [sp, #16]
        ldr     r0, [sp, #0]
        ldr     r1, [sp, #16]
        add.w   r0, r0, r1, lsl #2
        vldr    s0, [r0]
        vstr    s0, [sp, #20]
        movw    r0, #2
        movt    r0, #0
        str     r0, [sp, #24]
        ldr     r0, [sp, #0]
        ldr     r1, [sp, #24]
        add.w   r0, r0, r1, lsl #2
        vldr    s0, [r0]
        vstr    s0, [sp, #28]
        vldr    s0, [sp, #12]
        vldr    s1, [sp, #4]
        vmul.f32 s0, s0, s1
        vstr    s0, [sp, #32]
        vldr    s0, [sp, #32]
        vldr    s1, [sp, #20]
        vadd.f32 s0, s0, s1
        vstr    s0, [sp, #36]
        vldr    s0, [sp, #36]
        vldr    s1, [sp, #4]
        vmul.f32 s0, s0, s1
        vstr    s0, [sp, #40]
        vldr    s0, [sp, #40]
        vldr    s1, [sp, #28]
        vadd.f32 s0, s0, s1
        vstr    s0, [sp, #44]
        ldr     r0, [sp, #44]
        add.w   sp, sp, #48
        bx      lr
        .size evaluate_quadratic, .-evaluate_quadratic

.section .note.GNU-stack,"",%progbits
