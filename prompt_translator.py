#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
提示词数据翻译器 — 把四维系数 0~1 数字翻译成 AI 能理解的具象描述。

用法：
    # 命令行（JSON 输入）
    python prompt_translator.py --input '{"complexity": 0.9, "understand": 0.3, "redundancy": 0.6, "coverage": 0.7}'

    # 管道模式
    echo '{"complexity": 0.85, "understand": 0.2}' | python prompt_translator.py

    # 作为模块 import
    from prompt_translator import describe_all, build_full_context

角色：
    Mix 算法引擎（Flutter）产出的四维数值对 AI 模型来说只是冰冷数字。
    这个脚本的作用是"胶水翻译层"：把 0.9 翻译成"步骤复杂度极高，
    至少需要 5 个关键推理节点"，AI 才能真的按这个难度标准出题。

与 Dart 端 PromptTranslator 的关系：
    - 逻辑完全一致，这里用 Python 实现方便数据 pipeline 集成
    - Dart 端是运行时 inline 调用，Python 端是离线 / 服务端调用
"""

import json
import sys
from typing import Optional


# ── 维度翻译函数（0~1 → 具象描述） ──


def complexity_level(v: float) -> str:
    """处理步骤复杂度 — 关键节点数量 / 嵌套深度"""
    if v >= 0.85:
        return ("极高：需要 **5 个以上关键推理节点**，涉及多步嵌套、"
                "中间结果传递或分支处理。学生必须能维护完整的解题链，"
                "适合出需要逐步推导的大题或证明题")
    if v >= 0.65:
        return ("较高：需要 **3-4 个关键步骤**，涉及中等程度的"
                "逻辑嵌套或中间计算。适合出多步应用题")
    if v >= 0.40:
        return ("中等：**2-3 步**可解，步骤链短，"
                "不需要长时间的工作记忆维持。适合出标准计算题")
    if v >= 0.20:
        return ("较低：**1-2 步**直接推理，几乎不需要中间状态，"
                "适合出基础概念题")
    return "极低：单步直接得出，无嵌套无分支，适合出填空题"


def understand_level(v: float) -> str:
    """概念理解难度 — 抽象程度 / 公式复杂度"""
    if v >= 0.85:
        return ("极高：需要深层概念理解，涉及**抽象定理、多步推导证明"
                "或跨章节知识迁移**。学生需要能灵活运用多个公式")
    if v >= 0.65:
        return ("较高：需要理解核心定理的**适用条件**，"
                "涉及公式变形或中等推理。适合出需要判断用哪个公式的题")
    if v >= 0.40:
        return ("中等：需要**基本概念理解**，套用标准公式即可解答。"
                "适合出直接应用题")
    if v >= 0.20:
        return ("较低：只需**识别概念**和直接应用定义，"
                "适合出概念辨析题")
    return "极低：考查基本术语认知，无需深度理解，适合出名词解释"


def redundancy_level(v: float) -> str:
    """信息冗余度 — 干扰信息密度"""
    if v >= 0.85:
        return ("极高：题目包含**大量无关条件/干扰信息**，"
                "学生需要从噪声中筛选关键数据，"
                "适合出需要提取有效条件的应用题")
    if v >= 0.65:
        return ("较高：包含**中等程度干扰项**，"
                "部分条件多余但不过分隐蔽")
    if v >= 0.40:
        return ("中等：**少数干扰信息**，大部分条件直接有用。"
                "题干中可加入 1-2 条无关条件")
    if v >= 0.20:
        return ("较低：题干**简洁**，几乎无冗余信息，每句话都关键")
    return "极低：条件极少且全部直接相关"


def coverage_level(v: float) -> str:
    """知识覆盖率 — 跨知识点综合程度"""
    if v >= 0.85:
        return ("极高：需要**综合运用多个章节/模块**的知识点，"
                "跨领域联系。适合出综合性大题")
    if v >= 0.65:
        return ("较高：涉及该章节内 **2-3 个知识点的综合运用**，"
                "需要学生建立知识点之间的联系")
    if v >= 0.40:
        return ("中等：主要考查当前知识点，可能涉及**前置依赖概念**。"
                "可以适当联系已学过的内容")
    if v >= 0.20:
        return ("较低：**聚焦单一知识点**，不涉及知识迁移")
    return "极低：考查单一子概念的最基础层面"


# ── 组合函数 ──


def describe_all(complexity: float, understand: float,
                 redundancy: float, coverage: float) -> str:
    """返回四个维度的完整描述，适合拼入 system prompt。"""
    return (
        f"- 处理步骤复杂度：{complexity:.2f}（{complexity_level(complexity)}）\n"
        f"- 概念理解难度：{understand:.2f}（{understand_level(understand)}）\n"
        f"- 信息冗余度：{redundancy:.2f}（{redundancy_level(redundancy)}）\n"
        f"- 知识覆盖率：{coverage:.2f}（{coverage_level(coverage)}）"
    )


def summary(complexity: float, understand: float,
            redundancy: float, coverage: float) -> str:
    """紧凑单行摘要"""
    return (f"复杂度{complexity:.2f} · 理解{understand:.2f} · "
            f"冗余{redundancy:.2f} · 覆盖{coverage:.2f}")


def weakest_dim(complexity: float, understand: float,
                redundancy: float, coverage: float) -> str:
    """返回最弱维度的中文描述"""
    dims = {
        'complexity': ('步骤复杂度方向', complexity),
        'understand': ('概念理解方向', understand),
        'redundancy': ('抗干扰方向', redundancy),
        'coverage': ('知识边界扩展方向', coverage),
    }
    weakest = min(dims.items(), key=lambda x: x[1][1])
    return weakest[1][0]


# ── 完整上下文构建 ──


def build_full_context(
    subject_name: str,
    kp_name: str,
    composite_mastery: float,
    complexity: float,
    understand: float,
    redundancy: float,
    coverage: float,
    error_distribution: Optional[dict[str, int]] = None,
    extra_instructions: Optional[str] = None,
) -> str:
    """
    构建完整的出题上下文提示词。

    参数：
        subject_name: 科目名（如"药理学"）
        kp_name: 知识点名
        composite_mastery: 综合掌握度 0~1
        complexity/understand/redundancy/coverage: 四维系数
        error_distribution: 错因分布 {"complexity": 3, "understand": 1}
        extra_instructions: 额外的格式/内容要求

    返回：
        完整的 system prompt 文本，可直接发给 AI。
    """
    parts = [
        "你是一位经验丰富的大学出题教师。请为以下知识点生成一道练习题。\n",
        "## 学生当前状态\n",
        describe_all(complexity, understand, redundancy, coverage),
        "",
        f"## 综合掌握度\n{composite_mastery * 100:.0f}分（满分100）",
    ]

    if error_distribution:
        total = sum(error_distribution.values())
        error_lines = []
        cause_labels = {
            'complexity': '步骤型错误（复杂度）',
            'understand': '理解型错误',
            'redundancy': '干扰型错误（冗余度）',
            'coverage': '边界型错误（覆盖率）',
        }
        for cause, count in sorted(error_distribution.items(),
                                    key=lambda x: x[1], reverse=True):
            label = cause_labels.get(cause, cause)
            pct = count / total * 100
            error_lines.append(f"- {label}：{count}次（{pct:.0f}%）")
        parts.append("\n## 历史错因\n学生过去做错的主要类型：")
        parts.extend(error_lines)

    parts.extend([
        "",
        "## 格式铁律（严格遵循）",
        "",
        "1. **所有数学公式必须用 $...$ 包裹**，块级公式用 $$...$$。**绝对禁止**裸写公式。",
        "2. 用 **加粗** 标核心概念，用 - 列表组织要点。",
        "3. 不寒暄，不写\"同学你好\"，直接出题。",
        "4. 题干简洁清晰，接近真实考试风格。",
        "5. 答案可以详细展开（含解题步骤、易错提醒）。",
        "",
        "## 输出格式（严格按此顺序）",
        "",
        "请以 Markdown 格式返回，且严格按以下顺序：",
        "",
        "## 题目",
        "[题目内容，公式用 $...$ 包裹]",
        "",
        "## 系数",
        "- 复杂度：X.XX",
        "- 理解难度：X.XX",
        "- 冗余度：X.XX",
        "- 覆盖率：X.XX",
        "",
        "## 答案",
        "[标准答案，可以详细展开，含解题步骤]",
        "",
        "---",
        f"科目：{subject_name}",
        f"知识点：{kp_name}",
        f"出题依据：当前掌握度 {composite_mastery * 100:.0f}分，",
        f"重点考察 {weakest_dim(complexity, understand, redundancy, coverage)}",
    ])

    if extra_instructions:
        parts.append(f"\n## 额外要求\n{extra_instructions}")

    return "\n".join(parts)


# ── CLI 入口 ──


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--input':
        raw = sys.argv[2]
    else:
        raw = sys.stdin.read().strip()

    if not raw:
        print("用法：echo '{\"complexity\": 0.8}' | python prompt_translator.py", file=sys.stderr)
        sys.exit(1)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"JSON 解析失败：{e}", file=sys.stderr)
        sys.exit(1)

    complexity = data.get('complexity', 0.5)
    understand = data.get('understand', 0.5)
    redundancy = data.get('redundancy', 0.5)
    coverage = data.get('coverage', 0.5)

    # 检查是否包含完整上下文所需字段
    if all(k in data for k in ('subject_name', 'kp_name', 'composite_mastery')):
        result = build_full_context(
            subject_name=data['subject_name'],
            kp_name=data['kp_name'],
            composite_mastery=data['composite_mastery'],
            complexity=complexity,
            understand=understand,
            redundancy=redundancy,
            coverage=coverage,
            error_distribution=data.get('error_distribution'),
            extra_instructions=data.get('extra_instructions'),
        )
    else:
        # 简单模式：只输出维度描述
        result = json.dumps({
            'dimensions': {
                'complexity': {'value': complexity, 'description': complexity_level(complexity)},
                'understand': {'value': understand, 'description': understand_level(understand)},
                'redundancy': {'value': redundancy, 'description': redundancy_level(redundancy)},
                'coverage': {'value': coverage, 'description': coverage_level(coverage)},
            },
            'summary': summary(complexity, understand, redundancy, coverage),
            'weakest_dimension': weakest_dim(complexity, understand, redundancy, coverage),
        }, ensure_ascii=False, indent=2)

    print(result)


if __name__ == '__main__':
    main()
