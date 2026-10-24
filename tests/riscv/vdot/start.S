/* =========================================================================
 * start.S —— 裸机 RV64 启动代码 + M 态异常处理（NEMU riscv64-xs-kmhv2）
 *
 * 复位路径与 tests/riscv/hello/start.S 相同：
 *   CONFIG_RESET_FROM_MMIO=y, CONFIG_MMIO_RESET_VECTOR=0x10000000
 *   -> src/isa/riscv64/init.c  cpu.pc = CONFIG_MMIO_RESET_VECTOR
 *   -> CONFIG_FLASH_PRESET_CONTENT 作为 bootrom，最后 jalr 到 CONFIG_MBASE
 *
 * 本程序比 hello 多一件事：**安装 M 态 trap handler**。
 * vdot 指令族在 vtype.vsew 不匹配、或归约形态遇到 vstart != 0 时必须抛出
 * Illegal Instruction（MASTER_PLAN 裁定 S-1 / R1）。测试程序需要能观测到
 * 这个异常，因此装一个 direct 模式的 mtvec，处理流程：
 *   记录 mcause -> 置 vdot_trap_flag=1 -> mepc += 4 -> mret
 * 被测指令一律是 4 字节的 .word，所以 +4 必然落在下一条指令上。
 * ========================================================================= */

    .section .text.init, "ax"
    .globl _start
    .type  _start, @function
_start:
    /* 关中断：本测试为纯计算 + 串口输出 */
    csrw    mie, zero

    /* 使能浮点与向量单元。NEMU 复位后 mstatus.FS = mstatus.VS = Off
     * (src/isa/riscv64/init.c:72-73)，不置位则 vsetvl / csrr vlenb 会触发
     * 非法指令异常。FS=Dirty(3)<<13, VS=Dirty(3)<<9 */
    li      t0, (3 << 13) | (3 << 9)
    csrs    mstatus, t0

    /* 安装 trap handler（direct 模式，mtvec[1:0] = 00，BASE 需 4 字节对齐） */
    la      t0, trap_entry
    csrw    mtvec, t0

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

    /* 退出：main 的返回值作为 nemu_trap 的退出码（a0=0 -> HIT GOOD TRAP）。
     * nemu_trap 编码 0x0000006b，见
     *   NEMU src/isa/riscv64/instr/decode.c:107
     *     def_INSTR_TAB("0000000 00000 ????? 000 00000 11010 ??", nemu_trap)
     *   NEMU src/isa/riscv64/instr/special.h:36  (HOSTCALL_EXIT) */
    .word   0x0000006b
3:  j       3b
    .size _start, . - _start

/* -------------------------------------------------------------------------
 * trap_entry —— M 态异常入口
 * 只会被被测的 vdot 指令触发；其余任何异常都会被如实记录 mcause，由 C 侧
 * 报成失败，不会被静默吞掉。
 * ---------------------------------------------------------------------- */
    .balign 4
    .globl trap_entry
    .type  trap_entry, @function
trap_entry:
    addi    sp, sp, -32
    sd      t0, 0(sp)
    sd      t1, 8(sp)
    sd      t2, 16(sp)

    csrr    t0, mcause
    la      t1, vdot_trap_mcause
    sd      t0, 0(t1)
    csrr    t0, mepc
    la      t1, vdot_trap_mepc
    sd      t0, 0(t1)
    la      t1, vdot_trap_flag
    li      t2, 1
    sd      t2, 0(t1)

    /* 跳过触发异常的那条 4 字节指令 */
    addi    t0, t0, 4
    csrw    mepc, t0

    ld      t0, 0(sp)
    ld      t1, 8(sp)
    ld      t2, 16(sp)
    addi    sp, sp, 32
    mret
    .size trap_entry, . - trap_entry
