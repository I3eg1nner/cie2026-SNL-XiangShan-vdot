/* =========================================================================
 * vdot_wave.S —— 全核波形抓取用的最小程序
 *
 * 只做一件事：准备好 v8..v11 的已知数据后，连续执行
 *     vadd.vv v1, v8, v9        (e8, vl=16)
 *     vdot.vv v3, v2=v10, v1    (RAW：vs1 = 上一条 vadd 的结果)
 *     vdotacc.vv v3, v11, v8    (RAW：vd 累加 = 上一条 vdot 的结果)
 *     vsetivli e32, vl=4
 *     vdot4a.vv v4, v3, v9      (RAW：vs2 = 上一条 vdotacc 的结果)
 * 期望值（裁定 S-3'：vdot / vdotacc 的 vd[127:32] 一律清零，与 vta 无关；
 *        vdot4a 仍按标准 tail 规则，本程序 vl=4 无 tail）：
 *     v1 = 3..18；vdot: v3 = {0xffffff58, 0, 0, 0}（-(3+...+18) = -168）
 *     vdotacc: v3.u32[0] += sum(v11*v8) = -128*64 + 127*72 = 952 -> v3 = {0x00000310, 0, 0, 0}
 *     vdot4a: v4.u32[0] = (0x10+0x03)*2 = 38 = 0x26，v4.u32[1..3] = 0（v3 的元素 1..3 已为 0）
 *     （原裁定 S-3 下 v3.u32[1..3] 为全 1，v4.u32[1..3] = 4*(-1*2) = -8 = 0xfffffff8）
 * 然后把结果存回内存并以 nemu_trap(a0=0) 结束。程序很短，复位后几千个周期内
 * 就会执行到被测指令，便于用 emu 的 -b / -e 只抓一个小窗口的波形。
 * 编码公式同 vdot_dep_kernels.S。
 * ========================================================================= */
    .macro VDOT vd, vs2, vs1, vm=1
    .4byte (0x39 << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm
    .macro VDOTACC vd, vs2, vs1, vm=1
    .4byte (0x3a << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm
    .macro VDOT4A vd, vs2, vs1, vm=1
    .4byte (0x3b << 26) | (\vm << 25) | (\vs2 << 20) | (\vs1 << 15) | (\vd << 7) | 0x57
    .endm

    .section .text.init, "ax"
    .globl _start
_start:
    li      t0, (3 << 13) | (3 << 9)      /* mstatus.FS = VS = Dirty */
    csrs    mstatus, t0
    la      a0, data
    vsetivli x0, 16, e8, m1, ta, ma
    vle8.v  v8, (a0)
    addi    a1, a0, 16
    vle8.v  v9, (a1)
    addi    a1, a0, 32
    vle8.v  v10, (a1)
    addi    a1, a0, 48
    vle8.v  v11, (a1)
    vmv.v.i v3, 0                          /* vd 初值清零，便于在波形里核对 vdot4a 的累加 */
    vmv.v.i v4, 0
    fence                                  /* 让被测序列从空流水线开始 */
    .globl wave_begin
wave_begin:
    vadd.vv v1, v8, v9
    VDOT    3, 10, 1
    VDOTACC 3, 11, 8
    vsetivli x0, 4, e32, m1, ta, ma
    VDOT4A  4, 3, 9
    .globl wave_end
wave_end:
    la      a1, result
    vsetivli x0, 16, e8, m1, ta, ma
    vse8.v  v3, (a1)
    addi    a1, a1, 16
    vse8.v  v4, (a1)
    fence
    li      a0, 0
    .word   0x0000006b                     /* nemu_trap：a0=0 -> HIT GOOD TRAP */
1:  j       1b

    .section .data
    .balign 16
data:   /* v8 = 1..16, v9 = 全 2, v10 = 全 0xff(-1), v11 = 0x80 交替 0x7f */
    .byte 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
    .byte 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0x80,0x7f,0x80,0x7f,0x80,0x7f,0x80,0x7f,0x80,0x7f,0x80,0x7f,0x80,0x7f,0x80,0x7f
    .balign 16
result: .space 32
