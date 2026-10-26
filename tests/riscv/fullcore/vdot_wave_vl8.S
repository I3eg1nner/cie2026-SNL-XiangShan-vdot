/* =========================================================================
 * vdot_wave_vl8.S —— 全核 vl=8 主演示程序（与赛题官方伪代码逐位等价）
 *
 * 赛题官方伪代码（docs/_recon/figures/vdot_official_semantics.jpg）：
 *     result = 0
 *     for i in range(8): result += sign_extend(vs1[i]) * sign_extend(vs2[i])
 *     vd[0] = result ; vd[1..VLEN-1] = 0
 * 本项目对元素 0..vl-1 求和，vl=8 时与上式逐位等价。本程序用
 *     vsetivli zero, 8, e8, m1, ta, ma        （vta=1）
 * 执行一条 vdot.vv 与一条 vdotacc.vv，并在程序内自检结果：
 *
 *   输入（高 8 个元素故意填非零的无关值，证明它们不参与求和）：
 *     v8 (vs1) = [1,2,3,4,5,6,7,8 | 0x7f x 8]     （高 8 个 = +127）
 *     v9 (vs2) = [1,2,3,4,5,6,7,8 | 0x80 x 8]     （高 8 个 = -128）
 *     v3 (vd 旧值，vdot 用)    = u32 {0xdeadbeef, 0xcafebabe, 0x8badf00d, 0xfeedface}
 *     v4 (vd 旧值，vdotacc 用) = u32 {0x000003e8 (=1000), 0x5a5a5a5a, 0xa5a5a5a5, 0x0badc0de}
 *
 *   手算（按官方伪代码，只取元素 0..7）：
 *     sum = 1*1 + 2*2 + ... + 8*8 = 204 = 0xcc
 *     vdot.vv    v3, v9, v8 : v3 = {0x000000cc, 0, 0, 0}
 *                             = 0x00000000_00000000_00000000_000000cc
 *     vdotacc.vv v4, v9, v8 : v4.u32[0] = 1000 + 204 = 1204 = 0x4b4
 *                             v4 = 0x00000000_00000000_00000000_000004b4
 *     （vdotacc 是本项目的扩展指令，伪代码未涉及；初值取 vd.u32[0]，尾部同样清零）
 *   元素 1..3 由非零旧值变为 0：裁定 S-3'，与 vta 无关（这里 vta=1 也照样清零）。
 *   对照：若错误地把 16 个元素都加进来，结果是 204 + 8*127*(-128) = -129844
 *         = 0xfffe04cc，与 0xcc 截然不同，自检会失败。
 *
 * 自检：结果存回内存后逐个 64 位比较；全部一致 a0=0（HIT GOOD TRAP），
 *       否则 a0 = 出错项编号（非 0 -> BAD TRAP）。第 1 项检查被测指令执行时 vl=8。
 * 编码公式同 vdot_dep_kernels.S / vdot_wave.S。
 * ========================================================================= */
    .macro VDOT vd, vs2, vs1, vm=1
    .4byte (0x39 << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm
    .macro VDOTACC vd, vs2, vs1, vm=1
    .4byte (0x3a << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm

    .section .text.init, "ax"
    .globl _start
_start:
    li      t0, (3 << 13) | (3 << 9)      /* mstatus.FS = VS = Dirty */
    csrs    mstatus, t0
    la      a0, data
    vsetivli x0, 16, e8, m1, ta, ma        /* 装载时按整个寄存器（16 字节）写入 */
    vle8.v  v8, (a0)
    addi    a1, a0, 16
    vle8.v  v9, (a1)
    addi    a1, a0, 32
    vle8.v  v3, (a1)
    addi    a1, a0, 48
    vle8.v  v4, (a1)
    fence                                  /* 让被测序列从空流水线开始 */
    .globl wave_begin
wave_begin:
    vsetivli x0, 8, e8, m1, ta, ma         /* vl = 8，vta = 1 */
    VDOT    3, 9, 8                        /* vdot.vv    v3, v9, v8 */
    VDOTACC 4, 9, 8                        /* vdotacc.vv v4, v9, v8 */
    .globl wave_end
wave_end:
    csrr    s1, vl                         /* 被测指令执行时的 vl */
    la      a1, result
    vsetivli x0, 16, e8, m1, ta, ma        /* 整个寄存器存回，核对元素 1..3 */
    vse8.v  v3, (a1)
    addi    a2, a1, 16
    vse8.v  v4, (a2)
    fence

    /* ---------------- 自检 ---------------- */
    li      a0, 1
    li      t1, 8
    bne     s1, t1, fail                   /* 1: vl 必须为 8 */
    li      a0, 2
    ld      t0, 0(a1)
    li      t1, 0x00000000000000cc
    bne     t0, t1, fail                   /* 2: v3[63:0]   = 0x00000000_000000cc */
    li      a0, 3
    ld      t0, 8(a1)
    bnez    t0, fail                       /* 3: v3[127:64] = 0 */
    li      a0, 4
    ld      t0, 16(a1)
    li      t1, 0x00000000000004b4
    bne     t0, t1, fail                   /* 4: v4[63:0]   = 0x00000000_000004b4 */
    li      a0, 5
    ld      t0, 24(a1)
    bnez    t0, fail                       /* 5: v4[127:64] = 0 */
    li      a0, 0
fail:
    .word   0x0000006b                     /* nemu_trap：a0=0 -> HIT GOOD TRAP，否则 BAD TRAP */
1:  j       1b

    .section .data
    .balign 16
data:
    /* v8 (vs1)：低 8 个 = 1..8（参与求和），高 8 个 = 0x7f（无关值） */
    .byte 1,2,3,4,5,6,7,8, 0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f
    /* v9 (vs2)：低 8 个 = 1..8（参与求和），高 8 个 = 0x80（无关值） */
    .byte 1,2,3,4,5,6,7,8, 0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80
    /* v3 旧值（vdot 的 vd）：元素 0..3 全是非零垃圾值 */
    .word 0xdeadbeef, 0xcafebabe, 0x8badf00d, 0xfeedface
    /* v4 旧值（vdotacc 的 vd）：元素 0 = 1000 作为累加初值，元素 1..3 是非零垃圾值 */
    .word 0x000003e8, 0x5a5a5a5a, 0xa5a5a5a5, 0x0badc0de
    .balign 16
result: .space 32
