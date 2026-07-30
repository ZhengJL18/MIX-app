"""MIX 学习助手 — Hermes Agent 插件。

本插件注册 MIX 专有工具到 Hermes Agent，实现：
- 掌握度查询与更新
- 科目/知识点 CRUD
- Vault 文件读写
- 记忆系统桥接

所有工具通过 Hermes 的 decorator 自动注册。
"""


def register_tools(registry):
    """Hermes 插件入口：加载 MIX 所有工具。

    Hermes Agent 在启动时会扫描 plugins/ 目录，
    调用每个插件的 register_tools(registry) 注册工具。
    """
    from . import mastery_tools
    from . import subject_tools
    from . import file_tools

    mastery_tools.register_tools(registry)
    subject_tools.register_tools(registry)
    file_tools.register_tools(registry)
