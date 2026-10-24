/* =========================================================================
 * corpus.S —— 把打包好的共享语料嵌入基线等价性测试镜像的只读数据段
 *
 * 与 tests/riscv/vdot/corpus.S 完全相同的做法：build/corpus.bin 由
 * tests/riscv/vdot/pack_corpus.py 从 tests/vectors 下的 .txt 转换而来，
 * 期望值与状态码全部原样来自 tests/golden/vdot_ref.c 生成的文本语料。
 * ========================================================================= */
    .section .rodata.corpus, "a"
    .balign 16
    .globl vdot_corpus
vdot_corpus:
    .incbin "build/corpus.bin"
    .globl vdot_corpus_end
vdot_corpus_end:
    .byte 0
