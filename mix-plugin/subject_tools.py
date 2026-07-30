"""MIX 科目工具 — 科目/知识点 CRUD。"""

import sqlite3
import os

DB_PATH = os.environ.get("MIX_DB_PATH", "/data/data/com.mix.mix_app/databases/mix.db")


def register_tools(registry):
    registry.register_tool(
        name="list_subjects",
        description="列出所有科目及其包含的知识点数量。",
        parameters={"type": "object", "properties": {}},
        handler=list_subjects,
    )

    registry.register_tool(
        name="get_subject_detail",
        description="查看某个科目的详细信息：知识点列表、题目数量、学习记录。",
        parameters={
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "科目名称"
                }
            },
            "required": ["name"]
        },
        handler=get_subject_detail,
    )


def list_subjects() -> str:
    try:
        db = sqlite3.connect(DB_PATH)
        cursor = db.cursor()

        cursor.execute("""
            SELECT s.name,
                   COUNT(DISTINCT kp.id) as kp_count,
                   COUNT(DISTINCT q.id) as q_count
            FROM subjects s
            LEFT JOIN knowledge_points kp ON kp.subject_id = s.id
            LEFT JOIN questions q ON q.subject_id = s.id
            WHERE s.is_active = 1
            GROUP BY s.id
            ORDER BY s.order_index
        """)

        rows = cursor.fetchall()
        db.close()

        if not rows:
            return "还没有科目，先去科目管理创建一个吧。"

        lines = ["## 科目列表\n"]
        for r in rows:
            name, kp, q = r
            lines.append(f"- **{name}** — {kp} 个知识点，{q} 道题目")

        return "\n".join(lines)

    except Exception as e:
        return f"查询失败: {e}"


def get_subject_detail(name: str) -> str:
    try:
        db = sqlite3.connect(DB_PATH)
        cursor = db.cursor()

        cursor.execute("SELECT id FROM subjects WHERE name = ?", (name,))
        row = cursor.fetchone()
        if not row:
            return f"未找到科目「{name}」"
        sid = row[0]

        # 知识点
        cursor.execute("""
            SELECT kp.name, kus.mastery_score, kus.star_level
            FROM knowledge_points kp
            LEFT JOIN kp_user_state kus ON kus.kp_id = kp.id AND kus.user_id = 1
            WHERE kp.subject_id = ?
            ORDER BY kp.name
        """, (sid,))
        kps = cursor.fetchall()

        # 题目数
        cursor.execute("SELECT COUNT(*) FROM questions WHERE subject_id = ?", (sid,))
        q_count = cursor.fetchone()[0]

        # 练习记录
        cursor.execute("""
            SELECT COUNT(*), SUM(correct)
            FROM practice_records pr
            JOIN questions q ON q.id = pr.question_id
            WHERE q.subject_id = ?
        """, (sid,))
        prac = cursor.fetchone()
        total, correct = prac[0] or 0, prac[1] or 0

        db.close()

        lines = [f"# {name}\n"]
        lines.append(f"- 知识点数：{len(kps)}")
        lines.append(f"- 题目数：{q_count}")
        lines.append(f"- 练习记录：{total} 次（正确率 {correct / total * 100:.0f}% 当 total > 0 时）")
        lines.append("")
        lines.append("## 知识点\n")
        for kp in kps:
            kp_name, score, star = kp
            s = f"{score * 100:.0f}%" if score else "暂无数据"
            lines.append(f"- {kp_name} — {s}")

        return "\n".join(lines)

    except Exception as e:
        return f"查询失败: {e}"
