/*
 * vdot_ref.h —— vdot 指令族位精确参考模型（C11，无外部依赖）
 *
 * 作用：本文件及 vdot_ref.c 是 vdot / vdotacc / vdot4a 三条指令语义的
 *       **唯一事实来源（Single Source of Truth）**。
 *       RTL 测试平台（C++）、NEMU 扩展、测试向量生成器全部引用此实现，
 *       任何语义调整只改这一处。
 *
 * 规范依据：
 *   - MASTER_PLAN.md 决策 D2（指令族语义规范定义）
 *   - RISC-V "V" Vector Extension v1.0（frozen for public review）
 *       §3.4.3  vta / vma 定义
 *       §3.7    vstart CSR
 *       §5.3    Vector Masking
 *       §5.4    Prestart / Active / Inactive / Body / Tail 定义
 *       §14     Vector Reduction Operations
 *   - Zvdot4a8i (原 Zvqdotq) draft v0.1，vdot4a.vv 伪代码
 *
 * 可移植性：
 *   - 仅用 <stdint.h>/<stddef.h>，C11；clang(macOS/arm64) 与 gcc(Linux/arm64) 均可编译
 *   - 用 extern "C" 包裹，可直接并入 C++ 测试平台
 *   - 所有算术在 uint32_t 上完成后再按需解释为有符号数，不依赖有符号溢出行为（避免 UB）
 *   - 不依赖宿主机字节序：向量寄存器是显式的 uint8_t[16] 字节数组
 */
#ifndef VDOT_REF_H
#define VDOT_REF_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ *
 * 1. 向量寄存器布局约定（务必与 RTL / NEMU 保持一致）
 *
 *   VLEN = 128，LMUL = 1，一个向量寄存器 = 16 字节 = vreg128_t.v[0..15]
 *
 *   【字节 / 元素映射】element i 占据 byte[i*EEW/8 .. (i+1)*EEW/8-1]，
 *   寄存器内部按 **小端** 组织（与 RVV 规范 §4 "Mapping of Vector Elements
 *   to Vector Register State" 一致：元素 i 的最低有效字节在最低字节地址）。
 *
 *     EEW=8 : element i  == v[i]                         , i = 0..15
 *     EEW=32: element i  == v[4i] | v[4i+1]<<8 | v[4i+2]<<16 | v[4i+3]<<24
 *
 *   【掩码寄存器 v0】mask bit i == (v0.v[i/8] >> (i%8)) & 1   （RVV §4.5）
 *
 *   【十六进制文本表示】测试向量文件中 32 个十六进制字符按 **v[0] 在最左**
 *   的顺序书写，即 s[0:2]=v[0]、s[2:4]=v[1]、…、s[30:32]=v[15]。
 *   注意这与"把寄存器当成一个 128 位大整数打印"的习惯**相反**，
 *   请统一使用本文件提供的 vdot_hex_parse / vdot_hex_format。
 *   例：element0(e8)=0x80、其余为 0 的寄存器写作
 *       "80000000000000000000000000000000"
 *   例：element0(e32)=0x00040000、其余为 0 写作
 *       "00000400000000000000000000000000"
 * ------------------------------------------------------------------ */

#define VDOT_VLEN   128
#define VDOT_VLENB  (VDOT_VLEN / 8)          /* 16 字节 */

typedef struct {
    uint8_t v[VDOT_VLENB];
} vreg128_t;

/* ------------------------------------------------------------------ *
 * 2. 状态码：非法配置一律通过返回值报告，不使用 assert
 * ------------------------------------------------------------------ */
enum vdot_status {
    VDOT_OK                = 0,  /* 正常执行（含"按规范不写回"的情形）      */
    VDOT_ILLEGAL_VSTART    = 1,  /* vstart!=0 → Illegal Instruction。
                                    vdot/vdotacc：RVV v1.0 §14 原文「Vector
                                      reduction operations raise an illegal
                                      instruction exception if vstart is
                                      non-zero.」（裁定 S-1）
                                    vdot4a   ：平台约束（裁定 S-7'），见下文
                                      vdot4a_vv 的说明                        */
    VDOT_ERR_SEW           = 2,  /* vtype.vsew 与指令要求不符 → Illegal Instr */
    VDOT_ERR_VL            = 3,  /* vl > VLMAX，架构上不可能，视为调用错误    */
    VDOT_ERR_VSTART_RANGE  = 4,  /* vstart 超出当前 SEW 的最大元素下标（§3.7
                                    "reserved"，本模型按建议报错）            */
    VDOT_ERR_ARG           = 5,  /* 空指针 / 非法 vta,vma 取值                */
    VDOT_ERR_POLICY        = 6,  /* 未知的 vstart 策略                        */
    VDOT_ERR_OP            = 7   /* 未知的 op 编号                            */
};

/* vstart 策略（见 docs/stage2/13 「语义裁定记录」S-1 / S-7'） */
enum vdot_vstart_policy {
    VDOT_VSTART_STRICT = 0,  /* 本项目的规范语义：三条指令 vstart!=0 一律 Illegal
                                Instruction（默认）。vdot/vdotacc 的依据是 RVV §14，
                                vdot4a 的依据是平台约束（裁定 S-7'）              */
    VDOT_VSTART_SKIP   = 1   /* 放宽：按 §5.4 prestart 规则跳过 i<vstart 的源元素。
                                仅供在支持 vstart 重启的实现上做数据通路测试，
                                不参与规范一致性判定                              */
};

/* 指令编号（测试向量文件中的 op 字段） */
enum vdot_op {
    VDOT_OP_VDOT    = 0,   /* vdot.vv    , 要求 vsew = 8  */
    VDOT_OP_VDOTACC = 1,   /* vdotacc.vv , 要求 vsew = 8  */
    VDOT_OP_VDOT4A  = 2    /* vdot4a.vv  , 要求 vsew = 32 */
};

/* ------------------------------------------------------------------ *
 * 3. 类型化访问器（全部按上文布局约定实现，不依赖宿主字节序）
 * ------------------------------------------------------------------ */
static inline uint8_t vreg_u8(const vreg128_t *r, int i) {
    return r->v[i];
}
static inline int32_t vreg_i8(const vreg128_t *r, int i) {
    /* uint8 -> int8 的可移植符号扩展（不依赖实现定义的窄化转换） */
    uint32_t b = r->v[i];
    return (int32_t)(b ^ 0x80u) - 128;
}
static inline uint32_t vreg_u32(const vreg128_t *r, int i) {
    return (uint32_t)r->v[4*i]
         | ((uint32_t)r->v[4*i+1] << 8)
         | ((uint32_t)r->v[4*i+2] << 16)
         | ((uint32_t)r->v[4*i+3] << 24);
}
static inline void vreg_set_u32(vreg128_t *r, int i, uint32_t x) {
    r->v[4*i]   = (uint8_t)(x        & 0xFFu);
    r->v[4*i+1] = (uint8_t)((x >> 8) & 0xFFu);
    r->v[4*i+2] = (uint8_t)((x >> 16)& 0xFFu);
    r->v[4*i+3] = (uint8_t)((x >> 24)& 0xFFu);
}
/* 掩码位：RVV §4.5，mask bit i 位于 v0 的第 i 个比特（字节 i/8 的第 i%8 位） */
static inline int vreg_mask_bit(const vreg128_t *v0, int i) {
    return (v0->v[i >> 3] >> (i & 7)) & 1;
}

/* ------------------------------------------------------------------ *
 * 4. 指令级参考模型
 *
 *   参数约定：
 *     vd      [in,out] 目的寄存器；vdotacc/vdot4a 同时作为第三源读取
 *     vs2,vs1 [in]     源寄存器
 *     vstart  [in]     vstart CSR 当前值
 *     vl      [in]     vl CSR 当前值
 *     vm_mask [in]     NULL 表示指令的 vm 位为 1（不使用掩码）；
 *                      非 NULL 表示 vm 位为 0，用 *vm_mask 作为 v0 掩码寄存器
 *     vta,vma [in]     vtype.vta / vtype.vma，取值 0/1
 *
 *   返回：enum vdot_status。返回非 VDOT_OK 时 *vd 保持不变。
 * ------------------------------------------------------------------ */

/* vdot.vv vd, vs2, vs1, vm —— SEW=8，四倍宽全向量归约，不累加
 *   vd.u32[0] = Σ_{i∈active} sext32(vs2.i8[i]) * sext32(vs1.i8[i])
 *   vd.u32[1..3] = 0（vstart < vl 时无条件清零，与 vta/vma 无关，裁定 S-3'）；
 *   vstart >= vl（含 vl == 0）时 vd 完全不写   */
int vdot_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
            uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
            int vta, int vma);

/* vdotacc.vv vd, vs2, vs1, vm —— 同上，但以 vd.u32[0] 原值为累加初值
 *   （32 位回绕；vd.u32[1..3] 同样清零） */
int vdotacc_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
               uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
               int vta, int vma);

/* vdot4a.vv vd, vs2, vs1, vm —— SEW=32，逐 32 位元素的 4 路 int8 点积累加
 *   ∀i∈active: vd.u32[i] += Σ_{j=0}^{3} sext(vs2.i8[4i+j]) * sext(vs1.i8[4i+j])
 *   注意：虽然本指令是逐元素形态，vstart!=0 仍然 Illegal Instruction（裁定 S-7'，
 *   平台约束优先原则；详见 vdot_ref.c 的 vdot4a 行为表第 2 条） */
int vdot4a_vv(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
              uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
              int vta, int vma);

/* 带 vstart 策略参数的扩展入口（上面三个函数等价于 policy=VDOT_VSTART_STRICT） */
int vdot_vv_ex(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
               uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
               int vta, int vma, int vstart_policy);
int vdotacc_vv_ex(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                  uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                  int vta, int vma, int vstart_policy);
int vdot4a_vv_ex(vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
                 uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
                 int vta, int vma, int vstart_policy);

/* 统一派发入口：额外校验 vtype.vsew 是否与指令匹配。
 *   op   : enum vdot_op
 *   vsew : 元素位宽，取 8 / 16 / 32 / 64（注意不是 vtype.vsew 的 3 位编码） */
int vdot_exec(int op, int vsew,
              vreg128_t *vd, const vreg128_t *vs2, const vreg128_t *vs1,
              uint32_t vstart, uint32_t vl, const vreg128_t *vm_mask,
              int vta, int vma, int vstart_policy);

/* 当前 op 在 VLEN=128 / LMUL=1 下的 VLMAX（vdot/vdotacc=16，vdot4a=4），
 * 非法 op 返回 0 */
uint32_t vdot_vlmax(int op);

/* ------------------------------------------------------------------ *
 * 5. 文本 I/O 辅助（测试向量文件与 C/C++ 消费端共用，避免各自造轮子）
 * ------------------------------------------------------------------ */
/* 解析 32 个十六进制字符（v[0] 在最左）。成功返回 0，失败返回 -1。 */
int vdot_hex_parse(const char *s, vreg128_t *out);
/* 输出 32 个小写十六进制字符 + '\0'，共 33 字节。 */
void vdot_hex_format(const vreg128_t *r, char out[33]);
/* 状态码 <-> 名字（测试向量文件 status 字段） */
const char *vdot_status_name(int status);
int         vdot_status_from_name(const char *name);
/* 指令名 <-> 编号（测试向量文件 op 字段） */
const char *vdot_op_name(int op);
int         vdot_op_from_name(const char *name);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* VDOT_REF_H */
