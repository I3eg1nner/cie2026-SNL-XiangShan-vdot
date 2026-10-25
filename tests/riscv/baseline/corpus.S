/* =========================================================================
 * corpus.S —— 把打包好的共享语料嵌入基线等价性测试镜像的只读数据段
 *
 * 与 tests/riscv/vdot/corpus.S 相同的做法：$(BUILD)/corpus.bin 由
 * tests/riscv/vdot/pack_corpus.py 从 tests/vectors 下的 .txt 转换而来，
 * 期望值与状态码全部原样来自 tests/golden/vdot_ref.c 生成的文本语料。
 *
 * 语料路径由 Makefile 以 -DCORPUS_BIN='"$(abspath $(BUILD))/corpus.bin"' 传入，
 * 因此 `make BUILD=<任意目录>` 可用；单独汇编本文件时退回 build/corpus.bin。
 * ========================================================================= */
#ifndef CORPUS_BIN
#define CORPUS_BIN "build/corpus.bin"
#endif
    .section .rodata.corpus, "a"
    .balign 16
    .globl vdot_corpus
vdot_corpus:
    .incbin CORPUS_BIN
    .globl vdot_corpus_end
vdot_corpus_end:
    .byte 0
