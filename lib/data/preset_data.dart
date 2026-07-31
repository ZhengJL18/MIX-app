/// 冷启动预设数据 — 三明治策略的"预设层"
///
/// 结构：身份 → 子身份 → 科目列表 → 每个科目的进度档位
/// AI 推荐层在冷启动运行时异步加载，不在这里。
/// "其他（自定义）"入口在每个选择页面底部内联处理。

// ─── 身份枚举 ───

enum IdentityCategory {
  middleSchool('初中生'),
  highSchool('高中生'),
  college('大学生'),
  professional('职场人'),
  other('其他');

  final String label;
  const IdentityCategory(this.label);
}

enum SubIdentity {
  // 初中生
  middleGeneral('初中（通用）', IdentityCategory.middleSchool),

  // 高中生
  highScience('理科倾向', IdentityCategory.highSchool),
  highArts('文科倾向', IdentityCategory.highSchool),

  // 大学生
  collegeEngineer('工科生', IdentityCategory.college),
  collegeMedical('医学生', IdentityCategory.college),
  collegeScience('理学生', IdentityCategory.college),
  collegeSocial('社科学生', IdentityCategory.college),

  // 职场人
  profProgrammer('程序员', IdentityCategory.professional),
  profPM('产品经理', IdentityCategory.professional),
  profDesigner('设计师', IdentityCategory.professional),
  profOps('运营', IdentityCategory.professional),
  profOther('其他', IdentityCategory.professional);

  final String label;
  final IdentityCategory category;
  const SubIdentity(this.label, this.category);
}

/// AI 厂商预设
class AiVendorPreset {
  final String id;
  final String name;
  final String baseUrl;
  final List<String> models;
  final String keyHint;
  final bool recommended;

  const AiVendorPreset({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.models,
    required this.keyHint,
    this.recommended = false,
  });
}

const List<AiVendorPreset> kAiVendors = [
  AiVendorPreset(
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    models: ['deepseek-v4-flash', 'deepseek-v4-pro'],
    keyHint: '在 platform.deepseek.com 获取 API Key',
    recommended: true,
  ),
  AiVendorPreset(
    id: 'qwen',
    name: '通义千问（百炼）',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    models: ['qwen-turbo', 'qwen-plus', 'qwen-max'],
    keyHint: '在阿里云百炼控制台获取 API Key',
  ),
  AiVendorPreset(
    id: 'openai',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    models: ['gpt-4o-mini', 'gpt-4o', 'o3-mini'],
    keyHint: '在 platform.openai.com 获取 API Key',
  ),
  AiVendorPreset(
    id: 'moonshot',
    name: '月之暗面（Kimi）',
    baseUrl: 'https://api.moonshot.cn/v1',
    models: ['moonshot-v1-8k', 'moonshot-v1-32k'],
    keyHint: '在 kimi.moonshot.cn 获取 API Key',
  ),
  AiVendorPreset(
    id: 'zhipu',
    name: '智谱 AI',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    models: ['glm-4-plus', 'glm-4-air', 'glm-4-flash'],
    keyHint: '在 open.bigmodel.cn 获取 API Key',
  ),
  AiVendorPreset(
    id: 'gemini',
    name: 'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    models: ['gemini-2.0-flash', 'gemini-2.0-pro'],
    keyHint: '在 aistudio.google.com 获取 API Key',
  ),
];

// ─── 每个身份 → 子身份 → 默认科目 + 进度档位 ───

class SubjectPreset {
  final String name;
  final List<String> progressStops;

  const SubjectPreset({required this.name, required this.progressStops});
}

/// 获取某子身份的预设科目列表
List<SubjectPreset> presetSubjectsFor(SubIdentity sub) {
  switch (sub) {
    case SubIdentity.middleGeneral:
      return _middleSchool;
    case SubIdentity.highScience:
      return _highSchoolScience;
    case SubIdentity.highArts:
      return _highSchoolArts;
    case SubIdentity.collegeEngineer:
      return _collegeEngineer;
    case SubIdentity.collegeMedical:
      return _collegeMedical;
    case SubIdentity.collegeScience:
      return _collegeScience;
    case SubIdentity.collegeSocial:
      return _collegeSocial;
    case SubIdentity.profProgrammer:
      return _programmer;
    case SubIdentity.profPM:
      return _pm;
    case SubIdentity.profDesigner:
      return _designer;
    case SubIdentity.profOps:
      return _ops;
    case SubIdentity.profOther:
      return _professionalGeneral;
  }
}

// ─── 预设数据 ───

const List<SubjectPreset> _middleSchool = [
  SubjectPreset(name: '语文', progressStops: ['还没开始', '基础字词', '古诗文', '阅读理解', '写作', '已经学完']),
  SubjectPreset(name: '数学', progressStops: ['还没开始', '有理数', '方程与不等式', '几何初步', '函数', '统计概率', '已经学完']),
  SubjectPreset(name: '英语', progressStops: ['还没开始', '词汇', '语法', '阅读理解', '听力', '写作', '已经学完']),
  SubjectPreset(name: '物理', progressStops: ['还没开始', '声现象', '光现象', '力与运动', '压强浮力', '功与能', '已经学完']),
  SubjectPreset(name: '化学', progressStops: ['还没开始', '物质构成', '化学方程式', '碳和碳的氧化物', '燃料与能源', '已经学完']),
];

const List<SubjectPreset> _highSchoolScience = [
  SubjectPreset(name: '数学', progressStops: ['还没开始', '集合与函数', '三角函数', '数列', '导数', '解析几何', '概率统计', '已经学完']),
  SubjectPreset(name: '物理', progressStops: ['还没开始', '力学', '电磁学', '热学', '光学', '原子物理', '已经学完']),
  SubjectPreset(name: '化学', progressStops: ['还没开始', '物质结构与性质', '化学反应原理', '有机化学', '化学实验', '已经学完']),
  SubjectPreset(name: '生物', progressStops: ['还没开始', '细胞', '遗传变异', '稳态环境', '生物工程', '已经学完']),
  SubjectPreset(name: '英语', progressStops: ['还没开始', '词汇', '语法', '阅读', '听力', '写作', '已经学完']),
];

const List<SubjectPreset> _highSchoolArts = [
  SubjectPreset(name: '语文', progressStops: ['还没开始', '古代诗词', '文言文', '现代文阅读', '写作', '已经学完']),
  SubjectPreset(name: '英语', progressStops: ['还没开始', '词汇', '语法', '阅读', '听力', '写作', '已经学完']),
  SubjectPreset(name: '历史', progressStops: ['还没开始', '中国古代', '中国近现代', '世界古代', '世界近现代', '已经学完']),
  SubjectPreset(name: '政治', progressStops: ['还没开始', '经济生活', '政治生活', '文化生活', '哲学', '已经学完']),
  SubjectPreset(name: '地理', progressStops: ['还没开始', '自然地理', '人文地理', '区域发展', '地理信息', '已经学完']),
];

const List<SubjectPreset> _collegeEngineer = [
  SubjectPreset(name: '高等数学', progressStops: ['还没开始', '函数与极限', '导数与微分', '中值定理', '不定积分', '定积分', '微分方程', '级数', '已经学完']),
  SubjectPreset(name: '线性代数', progressStops: ['还没开始', '行列式', '矩阵', '向量组', '线性方程组', '特征值', '二次型', '已经学完']),
  SubjectPreset(name: '概率论与数理统计', progressStops: ['还没开始', '随机事件', '随机变量', '数字特征', '大数定律', '参数估计', '假设检验', '已经学完']),
  SubjectPreset(name: '大学物理', progressStops: ['还没开始', '力学', '热学', '电磁学', '波动光学', '量子物理', '已经学完']),
  SubjectPreset(name: 'C语言', progressStops: ['还没开始', '基础语法', '数组与指针', '函数', '结构体', '文件操作', '已经学完']),
  SubjectPreset(name: '数据结构', progressStops: ['还没开始', '线性表', '栈与队列', '树', '图', '排序', '查找', '已经学完']),
];

const List<SubjectPreset> _collegeMedical = [
  SubjectPreset(name: '人体解剖学', progressStops: ['还没开始', '运动系统', '内脏学', '脉管系统', '神经系统', '感觉器', '已经学完']),
  SubjectPreset(name: '生理学', progressStops: ['还没开始', '细胞生理', '血液循环', '呼吸', '消化吸收', '泌尿', '神经内分泌', '已经学完']),
  SubjectPreset(name: '病理学', progressStops: ['还没开始', '损伤修复', '炎症', '肿瘤', '心血管病理', '呼吸病理', '消化病理', '已经学完']),
  SubjectPreset(name: '药理学', progressStops: ['还没开始', '总论', '外周神经', '中枢神经', '心血管', '化学治疗', '已经学完']),
  SubjectPreset(name: '生物化学', progressStops: ['还没开始', '蛋白质', '核酸', '酶', '糖代谢', '脂代谢', '氨基酸代谢', '已经学完']),
];

const List<SubjectPreset> _collegeScience = [
  SubjectPreset(name: '数学分析', progressStops: ['还没开始', '实数理论', '极限', '连续', '微分', '积分', '级数', '已经学完']),
  SubjectPreset(name: '高等代数', progressStops: ['还没开始', '多项式', '行列式', '矩阵', '线性空间', '线性变换', '欧氏空间', '已经学完']),
  SubjectPreset(name: '解析几何', progressStops: ['还没开始', '向量代数', '直线与平面', '曲面', '二次曲线', '二次曲面', '已经学完']),
  SubjectPreset(name: '概率论', progressStops: ['还没开始', '事件与概率', '随机变量', '分布函数', '数字特征', '极限定理', '已经学完']),
  SubjectPreset(name: '普通物理', progressStops: ['还没开始', '力学', '热学', '电磁学', '光学', '原子核物理', '已经学完']),
];

const List<SubjectPreset> _collegeSocial = [
  SubjectPreset(name: '微观经济学', progressStops: ['还没开始', '供给需求', '消费者行为', '生产者行为', '市场结构', '要素市场', '已经学完']),
  SubjectPreset(name: '宏观经济学', progressStops: ['还没开始', '国民收入', 'IS-LM模型', 'AD-AS模型', '失业通胀', '经济增长', '已经学完']),
  SubjectPreset(name: '社会学概论', progressStops: ['还没开始', '社会结构', '社会化', '社会分层', '社会组织', '社会变迁', '已经学完']),
  SubjectPreset(name: '统计学', progressStops: ['还没开始', '描述统计', '概率基础', '参数估计', '假设检验', '回归分析', '已经学完']),
  SubjectPreset(name: '政治学原理', progressStops: ['还没开始', '政治学基本概念', '国家与政府', '政治制度', '政党与选举', '国际政治', '已经学完']),
];

const List<SubjectPreset> _programmer = [
  SubjectPreset(name: '数据结构与算法', progressStops: ['还没开始', '数组链表', '栈队列', '树', '图', '动态规划', '字符串', '已经学完']),
  SubjectPreset(name: '操作系统', progressStops: ['还没开始', '进程线程', '内存管理', '文件系统', 'IO', '死锁', '已经学完']),
  SubjectPreset(name: '计算机网络', progressStops: ['还没开始', '应用层', '传输层', '网络层', '链路层', '网络安全', '已经学完']),
  SubjectPreset(name: '数据库', progressStops: ['还没开始', '关系模型', 'SQL', '范式', '索引', '事务', '已经学完']),
  SubjectPreset(name: '设计模式', progressStops: ['还没开始', '创建型', '结构型', '行为型', '架构模式', '已经学完']),
];

const List<SubjectPreset> _pm = [
  SubjectPreset(name: '产品思维', progressStops: ['还没开始', '需求分析', '用户研究', '产品设计', '数据驱动', '增长策略', '已经学完']),
  SubjectPreset(name: '项目管理', progressStops: ['还没开始', '敏捷方法', 'Scrum', '需求管理', '风险管理', '团队协作', '已经学完']),
  SubjectPreset(name: '数据分析', progressStops: ['还没开始', 'Excel', 'SQL', 'BI工具', 'A/B测试', '统计学基础', '已经学完']),
];

const List<SubjectPreset> _designer = [
  SubjectPreset(name: 'UI设计', progressStops: ['还没开始', '设计基础', '色彩', '排版', '组件设计', '响应式', '已经学完']),
  SubjectPreset(name: 'UX设计', progressStops: ['还没开始', '用户研究', '信息架构', '交互设计', '可用性测试', '设计系统', '已经学完']),
  SubjectPreset(name: '设计工具', progressStops: ['还没开始', 'Figma基础', '组件库', '原型', '切图标注', '插件开发', '已经学完']),
];

const List<SubjectPreset> _ops = [
  SubjectPreset(name: '用户运营', progressStops: ['还没开始', '用户分层', '拉新', '留存', '促活', '转化', '已经学完']),
  SubjectPreset(name: '内容运营', progressStops: ['还没开始', '内容策划', '写作', 'SEO', '社交媒体', '数据分析', '已经学完']),
  SubjectPreset(name: '数据分析', progressStops: ['还没开始', 'Excel', 'SQL', '指标体系', 'A/B测试', '可视化', '已经学完']),
];

const List<SubjectPreset> _professionalGeneral = [];

// ─── AI 推荐 prompt 模板 ───

/// 生成 AI 推荐科目的 prompt
String kAiSubjectPrompt(String subIdentityLabel) => '''
你是一个教育规划专家。用户身份是"$subIdentityLabel"。

请推荐 3-5 个该身份常见的学习科目。
对每个科目，列出 5-8 个典型学习阶段（从入门到学完）。

返回 JSON 格式（纯 JSON，不要 markdown 包裹）：
{
  "subjects": [
    {
      "name": "科目名",
      "stops": ["阶段1", "阶段2", ..., "学完"]
    }
  ]
}
每个阶段名 ≤ 6 个字。
''';

/// 生成某科目进度档位的 prompt
String kAiStopsPrompt(String subjectName) => '''
为"$subjectName"列出 5-8 个典型学习阶段，从入门到学完。
返回纯 JSON 数组：["阶段1","阶段2",...,"学完"]
每项 ≤ 6 个字。
''';
