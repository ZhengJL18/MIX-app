# Mix — 自适应刷题 App

会出题的 AI 教练。四维掌握度 + 艾宾浩斯遗忘曲线 + 四区软分区 + 三层筛选。

## 技术栈

- **语言**：Dart 3.12+ · Flutter 3.44
- **架构**：Provider 状态管理 + sqflite 持久化
- **AI**：Anthropic Claude API（自带 API Key，可替换）
- **算法**：自主研发展开（综合掌握度 · 艾宾浩斯衰减 · SM-2 变体 · 确定性四区采样）

## 核心流程

```
选科目 → 四区调度选知识点 → PromptTranslator 数值→描述 → AI 出题
         ↓                                                     ↓
      预习生成（next_pool, 零延迟切题） ←──── AI 返回 → 自评对错 + 错因标注
                                                         ↓
                                                   掌握度更新（差异化/等量bonus）
```

## 快速开始

```bash
# 1. 安装依赖
flutter pub get

# 2. 配置 AI（可选，不配也能运行演示模式）
#    修改 lib/screens/settings 或在运行后通过 App 内设置填入 API Key

# 3. 运行
flutter run

# 4. 构建 APK
flutter build apk --debug
```

APK 输出到 `build/app/outputs/flutter-apk/app-debug.apk`

## 设计文档

详见 [`DESIGN.md`](DESIGN.md) 和 [`IDEA.md`](IDEA.md)。

## 提示词胶水层

Mix 使用 `PromptTranslator`（Dart + Python 双实现）把 0~1 四维系数翻译成 AI 能理解的具象描述：

```
复杂度 0.85 → "需要 5 个以上关键推理节点，涉及多步嵌套"
理解度 0.30 → "只需识别概念和直接应用定义"
```

Python 版可独立运行：
```bash
python prompt_translator.py --input '{"complexity":0.9,"understand":0.3}'
```
