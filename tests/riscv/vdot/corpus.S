/* =========================================================================
 * corpus.S —— 把打包好的共享语料嵌入镜像的只读数据段
 *
 * build/corpus.bin 由 pack_corpus.py 从 tests/vectors 下的 .txt 转换而来，
 * 期望值与状态码全部原样来自 tests/golden/vdot_ref.c 生成的文本语料。
 * 用 .incbin 而不是 C 数组，是为了让 30663 条用例的嵌入不拖慢编译。
 * ========================================================================= */
    .section .rodata.corpus, "a"
    .balign 16
    .globl vdot_corpus
vdot_corpus:
    .incbin "build/corpus.bin"
    .globl vdot_corpus_end
vdot_corpus_end:
    .byte 0
