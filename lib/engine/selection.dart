import '../config/config.dart';
import '../repository/subject_repository.dart';
import '../repository/kp_repository.dart';
import '../repository/kp_state_repository.dart';
import '../repository/practice_repository.dart';
import 'mastery.dart';
import 'zones.dart';

/// 对应设计文档第四节"三层筛选流程"。
///
/// 第三层（生成提示词）在 [PromptBuilder] 中单独实现，
/// 因为它是纯字符串拼接，不涉及"选择哪个"的决策逻辑。
class SelectionEngine {
  SelectionEngine({
    SubjectRepository? subjectRepo,
    KpRepository? kpRepo,
    KpStateRepository? kpStateRepo,
    PracticeRepository? practiceRepo,
  })  : _subjectRepo = subjectRepo ?? SubjectRepository(),
        _kpRepo = kpRepo ?? KpRepository(),
        _kpStateRepo = kpStateRepo ?? KpStateRepository(),
        _practiceRepo = practiceRepo ?? PracticeRepository();

  final SubjectRepository _subjectRepo;
  final KpRepository _kpRepo;
  final KpStateRepository _kpStateRepo;
  final PracticeRepository _practiceRepo;

  /// 4.1 第一层：选科目。返回得分最高的 subject_id。
  Future<int> selectSubject(int userId) async {
    final subjects = await _subjectRepo.getAllSubjects();
    if (subjects.isEmpty) {
      throw StateError('没有任何科目，无法选择。请先创建科目。');
    }
    final n = subjects.length;
    // 最近 n 题涉及的科目 id（最新的在前）
    final recentSubjects = await _practiceRepo.getRecentSubjectIds(userId, limit: n);

    double freshness(int subjectId) {
      final halfN = (0.5 * n).floor();
      if (recentSubjects.take(halfN).contains(subjectId)) return 0.0;
      if (recentSubjects.take(n).contains(subjectId)) return 0.1;
      return 0.2;
    }

    Future<double> gap(Map<String, dynamic> subj) async {
      final avg = await _averageMasteryOfSubject(userId, subj);
      return (subj['target_mastery'] as num).toDouble() - avg;
    }

    int bestId = subjects.first['id'] as int;
    double bestScore = double.negativeInfinity;
    for (final subj in subjects) {
      final id = subj['id'] as int;
      final importance = (subj['importance'] as num).toDouble();
      final g = await gap(subj);
      final f = freshness(id);
      final score = importance * 0.4 + g * 0.4 + f * 0.2;
      if (score > bestScore) {
        bestScore = score;
        bestId = id;
      }
    }
    return bestId;
  }

  Future<double> _averageMasteryOfSubject(int userId, Map<String, dynamic> subject) async {
    final subjectId = subject['id'] as int;
    final kps = await _kpRepo.getKpsBySubject(subjectId);
    if (kps.isEmpty) return 0.0;

    double sum = 0;
    for (final kp in kps) {
      final state = await _kpStateRepo.getOrCreateState(
        userId: userId,
        kpId: kp['id'] as int,
        subject: subject,
      );
      sum += compositeMastery(state, subject);
    }
    return sum / kps.length;
  }

  /// 4.2 第二层：四区调度选知识点。返回选中的 kp_id。
  Future<int> selectKp(int userId, int subjectId, int questionIndex) async {
    final subject = await _subjectRepo.getSubjectById(subjectId);
    if (subject == null) throw StateError('科目 $subjectId 不存在');

    final statesWithEff = await _statesWithEffectiveMastery(userId, subjectId, subject);
    if (statesWithEff.isEmpty) {
      throw StateError('科目 $subjectId 下没有知识点');
    }

    // 1. 复习队列优先：effective_mastery < 0.5 的自动入队，取最低分那个
    final reviewQueue = statesWithEff
        .where((s) => (s['effective_mastery'] as double) < 0.5)
        .toList()
      ..sort((a, b) =>
          (a['effective_mastery'] as double).compareTo(b['effective_mastery'] as double));
    if (reviewQueue.isNotEmpty) {
      return reviewQueue.first['kp_id'] as int;
    }

    // 2. 维护穿插（每 5 题）
    if (questionIndex % EngineConstants.maintenanceInterval == 0) {
      final pool = _inZone(statesWithEff, Zones.maintenance, questionIndex);
      if (pool.isNotEmpty) {
        return _lowestEffective(pool)['kp_id'] as int;
      }
    }

    // 3. 安全穿插（每 15 题）
    if (questionIndex % EngineConstants.safeInterval == 0) {
      final pool = _inZone(statesWithEff, Zones.safe, questionIndex);
      if (pool.isNotEmpty) {
        return _lowestEffective(pool)['kp_id'] as int;
      }
    }

    // 4. 攻坚当前知识点：优先落在"攻坚"区、effective_mastery 最低的知识点；
    //    若当前没有知识点被采样到攻坚区，退化为全局 effective_mastery 最低者。
    final attackPool = _inZone(statesWithEff, Zones.breakthrough, questionIndex);
    if (attackPool.isNotEmpty) {
      return _lowestEffective(attackPool)['kp_id'] as int;
    }
    return _lowestEffective(statesWithEff)['kp_id'] as int;
  }

  Future<List<Map<String, dynamic>>> _statesWithEffectiveMastery(
    int userId,
    int subjectId,
    Map<String, dynamic> subject,
  ) async {
    final kps = await _kpRepo.getKpsBySubject(subjectId);
    final result = <Map<String, dynamic>>[];
    for (final kp in kps) {
      final kpId = kp['id'] as int;
      final state = await _kpStateRepo.getOrCreateState(userId: userId, kpId: kpId, subject: subject);
      final raw = compositeMastery(state, subject);
      final withEff = _kpStateRepo.withEffectiveMastery(state, subject, raw);
      result.add({...withEff, 'kp_id': kpId});
    }
    return result;
  }

  List<Map<String, dynamic>> _inZone(List<Map<String, dynamic>> states, String zone, int questionIndex) {
    return states.where((s) {
      final mastery = s['effective_mastery'] as double;
      return pickZone(mastery, questionIndex) == zone;
    }).toList();
  }

  Map<String, dynamic> _lowestEffective(List<Map<String, dynamic>> states) {
    return states.reduce((a, b) =>
        (a['effective_mastery'] as double) <= (b['effective_mastery'] as double) ? a : b);
  }
}
