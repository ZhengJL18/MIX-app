"""MIX 文件工具 — Vault 文件读写。"""

import os
from pathlib import Path

VAULT_ROOT = os.environ.get(
    "MIX_VAULT_ROOT",
    "/data/data/com.mix.mix_app/files/MIX"
)


def register_tools(registry):
    registry.register_tool(
        name="read_vault_file",
        description="读取 vault 中的一个文件（讲义/笔记/素材）。路径格式为「科目名/文件名」。",
        parameters={
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "文件路径，如「药理学/药物代谢动力学.md」"
                }
            },
            "required": ["path"]
        },
        handler=read_vault_file,
    )

    registry.register_tool(
        name="write_vault_file",
        description="写入内容到 vault 文件。可用于保存笔记、总结等。",
        parameters={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "文件路径"},
                "content": {"type": "string", "description": "文件内容"},
            },
            "required": ["path", "content"]
        },
        handler=write_vault_file,
    )

    registry.register_tool(
        name="list_vault_dir",
        description="列出 vault 根目录下的所有科目文件夹。",
        parameters={"type": "object", "properties": {}},
        handler=list_vault_dir,
    )


def read_vault_file(path: str) -> str:
    full = os.path.join(VAULT_ROOT, path)
    if not os.path.exists(full):
        return f"文件不存在: {path}"
    try:
        with open(full, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        return f"读取失败: {e}"


def write_vault_file(path: str, content: str) -> str:
    full = os.path.join(VAULT_ROOT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    try:
        with open(full, "w", encoding="utf-8") as f:
            f.write(content)
        return f"已保存: {path}"
    except Exception as e:
        return f"写入失败: {e}"


def list_vault_dir() -> str:
    if not os.path.exists(VAULT_ROOT):
        return "（空目录）"
    try:
        items = os.listdir(VAULT_ROOT)
        if not items:
            return "（空目录）"
        return "\n".join(f"- {item}" for item in sorted(items))
    except Exception as e:
        return f"读取失败: {e}"
