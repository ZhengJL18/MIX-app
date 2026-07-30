"""MIX 掌握度工具 — 查询/更新掌握度数据。"""

import sqlite3
import os

DB_PATH = os.environ.get("MIX_DB_PATH", "/data/data/com.mix.mix_app/databases/mix.db")


def register_tools(registry):
    """Hermes 插件入口：向 registry 注册工具。"""
    registry.register_tool(
        name="get_subject_mastery",
        description="查看科目所有知识点的掌握度。返回每个知识点的掌握度分数和星级。",
        parameters={
            "type": "object",
            "properties": {
                "subject_name": {
                    "type": "string",
                    "description": "科目名称，如「药理学」"
                }
            },
            "required": ["subject_name"]
        },
        handler=get_subject_mastery,
    )

    registry.register_tool(
        name="get_weak_points",
        description="获取所有薄弱知识点（掌握度低于 40%）。按掌握度从低到高排序。",
        parameters={
            "type": "object",
            "properties": {},
        },
        handler=get_weak_points,
    )


def get_subject_mastery(subject_name: str) -> str:
    """查询科目各知识点的掌握度数据。"""
    try:
        db = sqlite3.connect(DB_PATH)
        cursor = db.cursor()

        # 查科目
        cursor.execute("SELECT id FROM subjects WHERE name = ?", (subject_name,))
        row = cursor.fetchone()
        if not row:
            return f"未找到科目「{subject_name}」"
        subject_id = row[0]

        # 查知识点 + 掌握度
        cursor.execute("""
            SELECT kp.name, kus.star_level, kus.mastery_score,
                   kus.complexity, kus.understand, kus.redundancy, kus.coverage,
                   kus.streak_correct, kus.streak_wrong, kus.review_count
            FROM knowledge_points kp
            LEFT JOIN kp_user_state kus ON kus.kp_id = kp.id AND kus.user_id = 1
            WHERE kp.subject_id = ?
            ORDER BY kus.mastery_score ASC
        """, (subject_id,))

        rows = cursor.fetchall()
        if not rows:
            return f"科目「{subject_name}」下没有知识点"

        lines = [f"# {subject_name} 掌握度\n"]
        for r in rows:
            name, star, score, cpx, und, red, cov, sc, sw, rc = r
            star_str = "⭐" * (star or 0) + "☆" * (5 - (star or 0))
            score_str = f"{score * 100:.0f}%" if score else "暂无数据"
            lines.append(f"- {name} {star_str} {score_str}")
            if score and score < 0.4:
                lines.append(f"  ⚠️ 薄弱点 — 建议优先复习")

        db.close()
        return "\n".join(lines)

    except Exception as e:
        return f"查询失败: {e}"


def get_weak_points() -> str:
    """获取所有薄弱知识点列表。"""
    try:
        db = sqlite3.connect(DB_PATH)
        cursor = db.cursor()

        cursor.execute("""
            SELECT s.name, kp.name, kus.mastery_score, kus.review_count
            FROM kp_user_state kus
            JOIN knowledge_points kp ON kp.id = kus.kp_id
            JOIN subjects s ON s.id = kp.subject_id
            WHERE kus.user_id = 1 AND kus.mastery_score < 0.4 AND kus.mastery_score > 0
            ORDER BY kus.mastery_score ASC
            LIMIT 10
        """)

        rows = cursor.fetchall()
        db.close()

        if not rows:
            return "暂无薄弱知识点，继续保持！"

        lines = ["# ⚠️ 薄弱知识点\n"]
        for r in rows:
            subject, kp, score, rc = r
            lines.append(f"- **{subject}** — {kp}（掌握度 {score * 100:.0f}%，已复习 {rc} 次）")

        return "\n".join(lines)

    except Exception as e:
        return f"查询失败: {e}"
