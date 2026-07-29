# Mix 算法引擎 - 最终设计文档 v6

> 编写日期：2026-07-29  
> 技术栈：Python 3.11+ + SQLite（纯sqlite3，无ORM）  
> 原则：dataclass只放ID，数据全在SQLite；权重属科目字段；预留AI微调接口

---

## 一、数据结构（5张SQLite表）

### 1.1 subjects（科目表）

```sql
CREATE TABLE subjects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    importance REAL NOT NULL DEFAULT 0.4,       -- 科目重要性(0~1)
    w_complexity REAL NOT NULL DEFAULT 0.4,     -- 四维权重
    w_understand REAL NOT NULL DEFAULT 0.3,
    w_redundancy REAL NOT NULL DEFAULT 0.1,
    w_coverage REAL NOT NULL DEFAULT 0.2,
    target_mastery REAL NOT NULL DEFAULT 0.9,   -- 目标掌握度
    mastery_initial REAL NOT NULL DEFAULT 0.3,  -- 四维初始值
    ebbinghaus_base REAL NOT NULL DEFAULT 30,   -- 艾宾浩斯公式参数
    ebbinghaus_power REAL NOT NULL DEFAULT 3,
    fb_correct_bonus REAL NOT NULL DEFAULT 0.3,  -- 反馈参数
    fb_main_penalty REAL NOT NULL DEFAULT 0.2,
    fb_minor_penalty REAL NOT NULL DEFAULT 0.05
);
```

### 1.2 knowledge_points（知识点表）

```sql
CREATE TABLE knowledge_points (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subject_id INTEGER NOT NULL REFERENCES subjects(id),
    name TEXT NOT NULL
);
CREATE INDEX idx_kp_subject ON knowledge_points(subject_id);
```

### 1.3 kp_user_state（用户-知识点状态表）

```sql
CREATE TABLE kp_user_state (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    kp_id INTEGER NOT NULL REFERENCES knowledge_points(id),
    complexity REAL NOT NULL DEFAULT 0.3,       -- 处理步骤复杂度
    understand REAL NOT NULL DEFAULT 0.3,        -- 理解难度
    redundancy REAL NOT NULL DEFAULT 0.3,        -- 信息冗余度
    coverage REAL NOT NULL DEFAULT 0.3,          -- 知识覆盖率
    streak_correct INTEGER NOT NULL DEFAULT 0,   -- 连续正确次数
    streak_wrong INTEGER NOT NULL DEFAULT 0,     -- 连续错误次数
    review_count INTEGER NOT NULL DEFAULT 0,     -- 总复习次数
    last_review_at TEXT,                         -- ISO8601时间戳
    review_interval REAL NOT NULL DEFAULT 1.0,   -- 复习间隔(天)
    UNIQUE(user_id, kp_id)
);
CREATE INDEX idx_kpu_user ON kp_user_state(user_id);
CREATE INDEX idx_kpu_kp ON kp_user_state(kp_id);
```

### 1.4 questions（题目表）

```sql
CREATE TABLE questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kp_id INTEGER NOT NULL REFERENCES knowledge_points(id),
    content TEXT NOT NULL,           -- Markdown格式题干
    answer TEXT NOT NULL,            -- 答案
    cplx_coef REAL,                  -- AI生成的四维系数(0~1)
    und_coef REAL,
    red_coef REAL,
    cov_coef REAL,
    is_seed INTEGER NOT NULL DEFAULT 0,  -- 0=AI生成, 1=种子题(人工录入)
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX idx_q_kp ON questions(kp_id);
```

### 1.5 practice_records（做题记录表）

```sql
CREATE TABLE practice_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    question_id INTEGER NOT NULL REFERENCES questions(id),
    correct INTEGER NOT NULL,                -- 0=错, 1=对
    main_cause TEXT,                         -- complexity/understand/redundancy/coverage
    minor_cause TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX idx_pr_user_correct ON practice_records(user_id, correct);
CREATE INDEX idx_pr_question ON practice_records(question_id);
```

---

## 二、Python dataclass（只放ID）

```python
from dataclasses import dataclass

@dataclass
class Subject:
    id: int

@dataclass
class KnowledgePoint:
    id: int
    subject_id: int

@dataclass
class KPUserState:
    id: int  # 其余字段在SQLite中，需要时通过ID查询

@dataclass
class Question:
    id: int
    kp_id: int

@dataclass
class PracticeRecord:
    id: int
```

---

## 三、核心算法公式

### 3.1 综合掌握度

```python
def composite_mastery(state: dict, weights: dict) -> float:
    """计算综合掌握度 raw = 加权平均 + 短板惩罚"""
    raw = (
        weights['w_complexity'] * state['complexity'] +
        weights['w_understand']  * state['understand'] +
        weights['w_redundancy']  * state['redundancy'] +
        weights['w_coverage']    * state['coverage']
    )
    worst = min(state['complexity'], state['understand'],
                state['redundancy'], state['coverage'])
    if worst < 0.5:
        raw *= (0.5 + 0.5 * worst / 0.5)  # 短板惩罚
    return raw
```

### 3.2 艾宾浩斯衰减

```python
import math

def effective_mastery(raw: float, days_since_review: float,
                      review_count: int, base: float, power: float) -> float:
    """计算有效掌握度 = raw × e^(-days / S)"""
    S = max(30 * (raw ** 3), 0.02) * (1.3 ** min(review_count, 20))
    if review_count == 1:
        S = min(S * 2, 3.0)  # 首次成功复习翻倍，上限3天
    if days_since_review == 0:
        return raw
    return raw * math.exp(-days_since_review / S)
```

### 3.3 四区软分区

```python
import math, random

def sigmoid(x: float) -> float:
    return 1 / (1 + math.exp(-x))

def gaussian(x: float, mu: float, sigma: float) -> float:
    return math.exp(-((x - mu) ** 2) / (2 * sigma ** 2))

def zone_weights(mastery: float) -> dict:
    """返回四个区的概率分布（归一化后总和=1）"""
    raw = {
        '攻坚': sigmoid((0.5 - mastery) / 0.07),
        '复习': gaussian(mastery, mu=0.6, sigma=0.06),
        '维护': sigmoid((mastery - 0.7) / 0.05) * (1 - sigmoid((mastery - 0.9) / 0.05)),
        '安全': sigmoid((mastery - 0.9) / 0.05),
    }
    total = sum(raw.values())
    return {k: v / total for k, v in raw.items()}

def pick_zone(mastery: float, question_index: int) -> str:
    """确定性采样：同状态同输出"""
    weights = zone_weights(mastery)
    seed = hash((round(mastery, 3), question_index))
    rng = random.Random(seed)
    return rng.choices(list(weights.keys()), weights=list(weights.values()))[0]
```

### 3.4 自适应反馈

```python
def apply_feedback(state: dict, subject: dict, correct: bool,
                   main_cause: str = None, minor_cause: str = None) -> dict:
    """根据答题结果更新四维状态，返回更新后的state"""
    raw = composite_mastery(state, subject)

    if correct:
        # 连续正确加速
        streak = state['streak_correct']
        bonus = 1.0 + 0.15 * min(streak, 4)       # streak≥4时最多1.6倍
        delta = (1 - raw) * subject['fb_correct_bonus'] * bonus

        for dim in ['complexity', 'understand', 'redundancy', 'coverage']:
            state[dim] = min(state[dim] + delta, 1.0)

        state['streak_correct'] += 1
        state['streak_wrong'] = 0
        state['review_count'] += 1
    else:
        # 错误扣分
        delta = raw * subject['fb_main_penalty']

        # 主因扣分
        if main_cause:
            dim_map = {
                'complexity': 'complexity', 'understand': 'understand',
                'redundancy': 'redundancy', 'coverage': 'coverage'
            }
            main_dim = dim_map.get(main_cause)
            if main_dim:
                state[main_dim] = max(state[main_dim] - delta, 0.01)

        # 辅因扣分
        if minor_cause:
            minor_dim = dim_map.get(minor_cause)
            if minor_dim:
                state[minor_dim] = max(state[minor_dim] - delta * 0.25, 0.01)

        state['streak_wrong'] += 1
        state['streak_correct'] = 0

    # 更新时间
    from datetime import datetime, timezone
    state['last_review_at'] = datetime.now(timezone.utc).isoformat()

    return state
```

---

## 四、三层筛选流程

### 4.1 第一层：选科目

```python
def select_subject(subjects: list, kp_states: dict) -> int:
    """返回得分最高的subject_id"""
    n = len(subjects)  # 科目总数，新鲜度分母
    recent_subjects = []  # 最近0.5n题涉及的科目ID

    def freshness(subj_id):
        if subj_id in recent_subjects[:int(0.5 * n)]:
            return 0.0
        elif subj_id in recent_subjects[:n]:
            return 0.1
        return 0.2

    def gap(subj):
        avg_mastery = average_mastery_of_subject(subj['id'], kp_states)
        return subj['target_mastery'] - avg_mastery

    def score(subj):
        return (subj['importance'] * 0.4 +
                gap(subj) * 0.4 +
                freshness(subj['id']) * 0.2)

    return max(subjects, key=score)['id']
```

### 4.2 第二层：四区调度选知识点

```python
def select_kp(subject_id: int, kp_states: list, question_index: int) -> int:
    """返回选中的kp_id"""
    # 1. 复习队列优先（effective_mastery < 0.5 的自动入队）
    review_queue = get_review_queue(subject_id)
    if review_queue:
        return review_queue.pop(0)

    # 2. 维护穿插（每5题）
    if question_index % 5 == 0:
        maintenance_pool = get_kps_in_zone('维护', subject_id, kp_states)
        if maintenance_pool:
            return min(maintenance_pool, key=lambda kp: kp['effective_mastery'])

    # 3. 安全穿插（每15题）
    if question_index % 15 == 0:
        safe_pool = get_kps_in_zone('安全', subject_id, kp_states)
        if safe_pool:
            return min(safe_pool, key=lambda kp: kp['effective_mastery'])

    # 4. 攻坚当前知识点
    return get_current_kp(subject_id)
```

### 4.3 第三层：生成提示词

```python
def build_prompt(kp_id: int, subject: dict, state: dict) -> str:
    """拼接提示词，喂给AI生成题目"""
    # 查错因分布
    error_dist = get_error_distribution(kp_id)

    prompt = f"""请为以下知识点生成一道练习题：

科目：{subject['name']}
知识点：{get_kp_name(kp_id)}

学生当前状态：
- 处理步骤复杂度：{state['complexity']:.2f}
- 理解难度：{state['understand']:.2f}
- 信息冗余度：{state['redundancy']:.2f}
- 知识覆盖率：{state['coverage']:.2f}
- 综合掌握度：{composite_mastery(state, subject):.2f}

历史错因分布：{error_dist}

请以Markdown格式返回：
## 题目
[题目内容]

## 答案
[标准答案]

## 系数
- 复杂度：X.XX
- 理解难度：X.XX
- 冗余度：X.XX
- 覆盖率：X.XX
"""
    return prompt
```

---

## 五、冷启动 & 预生成

### 5.1 种子题

每个知识点手动录入1-2道种子题（`is_seed=1`）。新用户首次接触某个知识点时使用。

### 5.2 提前一题生成

```
用户做第N道题 → 后台调用AI生成第N+1道 → questions表 + next_pool
用户切下一题 → 直接从next_pool取出（零延迟） → 后台生成第N+2道
```

next_pool为单题队列，用户做完当前题后立刻补充。

---

## 六、错因标注（UI层）

做错后弹出四选项：

| 选项 | 映射维度 | 子选项 |
|------|---------|--------|
| A. 步骤型错误 | complexity | 步骤遗漏 / 顺序错误 / 中间计算错 |
| B. 理解型错误 | understand | 概念理解错 / 公式记错 / 原理不理解 |
| C. 干扰型错误 | redundancy | 被无关信息干扰 / 漏关键条件 |
| D. 边界型错误 | coverage | 不知道用哪个知识点 / 边界不清晰 |

选一个主因 + 一个辅因。系统根据映射更新对应维度。

---

## 七、科目权重

选科目公式：`score = 重要性×0.4 + 预期差×0.4 + 新鲜度×0.2`

- 重要性：subjects.importance字段
- 预期差 = target_mastery - 科目平均掌握度
- 新鲜度：同一科目在0.5n题内重复出现→0分，在0.5n~n题内→0.1分，n题外→0.2分（n=科目总数）

---

## 八、文件结构

```
mix_engine/
├── config.py        # 默认权重常量（所有可改参数）
├── db.py            # SQLite建表+CRUD（纯sqlite3，无ORM）
├── models.py        # dataclass（只放ID字段）
├── engine.py        # 算法核心：掌握度/艾宾浩斯/四区/反馈/筛选/提示词
└── seed_data.py     # 种子题导入脚本
```

### 模块职责

| 文件 | 职责 | 依赖 |
|------|------|------|
| models.py | 5个dataclass | 无 |
| config.py | 默认参数常量 | 无 |
| db.py | 建表/CRUD/事务管理 | models, sqlite3 |
| engine.py | 所有算法逻辑 | db, config, models |
| seed_data.py | 种子题批量导入 | db |

---

## 九、AI微调预留

所有权重是 `subjects` 表的字段。未来AI微调：

```sql
-- AI可一键调整某科目的权重
UPDATE subjects SET w_complexity = 0.35, w_understand = 0.35
WHERE id = 2;
```

无需ALTER TABLE，无需新增配置表。每个科目独立权重，全局无约束。

---

## 十、关键技术决策速查

| 决策 | 方案 | 原因 |
|------|------|------|
| S_min | 0.02（~30min半衰期） | barely-encoded记忆合理衰减 |
| review_count cap | 20 | 防指数爆炸(1.3^20≈190×) |
| 首次复习翻倍 | S×2, 上限3天 | savings效应，首次成功大幅提S |
| 短板惩罚 | worst<0.5时压制raw | 防伪高分蒙混 |
| 四区 | 软分区+确定性种子 | 平滑过渡+可重现 |
| 提前生成 | next_pool深度=1 | 切题零延迟 |
| 错因 | 四维度×3子选项 | 结构化标注，元认知训练 |
| streak | 连续对加速(最多1.6×)，连续错3次降级 | SM-2 + BKT混合 |
