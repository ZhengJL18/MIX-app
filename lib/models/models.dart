/// 与设计文档第二节保持一致的原则：
/// "dataclass 只放 ID，数据全在 SQLite"。
///
/// 这些类是内存中传递的"引用"，不缓存易变字段（权重、掌握度、连续正确数等）。
/// 需要具体字段时，通过对应 Repository 按 ID 查询 SQLite，
/// 避免出现内存态与数据库态不一致的情况。
class Subject {
  final int id;
  const Subject({required this.id});
}

class KnowledgePoint {
  final int id;
  final int subjectId;
  const KnowledgePoint({required this.id, required this.subjectId});
}

class KPUserState {
  final int id; // 其余字段在 SQLite 中，需要时通过 ID 查询
  const KPUserState({required this.id});
}

class Question {
  final int id;
  final int kpId;
  const Question({required this.id, required this.kpId});
}

class PracticeRecord {
  final int id;
  const PracticeRecord({required this.id});
}
