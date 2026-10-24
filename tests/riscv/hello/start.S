/* =========================================================================
 * start.S —— 裸机 RV64 启动代码（NEMU riscv64-xs-kmhv2 独立解释器）
 *
 * 复位路径（见 NEMU 源码）：
 *   CONFIG_RESET_FROM_MMIO=y, CONFIG_MMIO_RESET_VECTOR=0x10000000
 *   -> src/isa/riscv64/init.c:57  cpu.pc = CONFIG_MMIO_RESET_VECTOR
 *   -> Flash 预置内容 CONFIG_FLASH_PRESET_CONTENT 作为 bootrom 执行：
 *        csrrsi  x0, mnstatus, 4     # 置 NMIE
 *        addiw   x5, x0, 1
 *        slli    x6, x5, 42
 *        csrrc   x0, mstatus, x6     # 清 mstatus.MDT (bit42, Smdbltrp)
 *        slli    x5, x5, 31          # x5 = 0x8000_0000
 *        jalr    x0, 0(x5)           # 跳到 MBASE
 *   因此本程序被链接到 CONFIG_MBASE(=0x80000000)，入口 _start，M 态执行。
 * ========================================================================= */

    .section .text.init, "ax"
    .globl _start
    .type  _start, @function
_start:
    /* 关中断：本测试为纯计算 + 串口输出，不需要任何中断 */
    csrw    mie, zero

    /* 使能浮点与向量单元。NEMU 复位后 mstatus.FS = mstatus.VS = Off
     * (src/isa/riscv64/init.c:72-73)，不置位则 vsetivli/csrr vlenb 会触发
     * 非法指令异常。FS=Dirty(3)<<13, VS=Dirty(3)<<9 */
    li      t0, (3 << 13) | (3 << 9)
    csrs    mstatus, t0

    /* 建立栈 */
    la      sp, _stack_top

    /* 清零 .bss */
    la      t0, _bss_start
    la      t1, _bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:

    call    main

    /* 正常退出：a0 = 0 交给 nemu_trap。
     * nemu_trap 的编码为 0x0000006b，见
     *   NEMU src/isa/riscv64/instr/decode.c:107
     *     def_INSTR_TAB("0000000 00000 ????? 000 00000 11010 ??", nemu_trap)
     * 处理逻辑见 src/isa/riscv64/instr/special.h:36 (HOSTCALL_EXIT) */
    li      a0, 0
    .word   0x0000006b
3:  j       3b
    .size _start, . - _start
