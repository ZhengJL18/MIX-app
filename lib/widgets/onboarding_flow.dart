import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_state.dart';
import '../services/agent_bridge.dart';
import '../services/ai_service.dart';
import '../repository/subject_repository.dart';
import '../repository/kp_repository.dart';
import '../repository/kp_state_repository.dart';
import '../theme/app_colors.dart';
import '../data/preset_data.dart';
import 'swipeable_stack.dart';
import 'ai_progress_slider.dart';

/// 冷启动 4 步引导的组装器
class OnboardingFlow extends StatefulWidget {
  final VoidCallback onComplete;

  /// 可选：Hermes Agent 桥接层。传入后在引导期间显示
  /// 后台解压进度横幅（首次启动时）。
  final AgentBridge? agent;

  const OnboardingFlow({super.key, required this.onComplete, this.agent});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  /// 冷启动数据收集
  String? _selectedVendorId;
  String? _selectedModel;
  String? _apiKey;
  String? _customBaseUrl; // 自定义厂商的 base URL
  SubIdentity? _selectedIdentity;
  final Map<String, int> _subjectProgress = {}; // 科目名 → 档位索引
  final List<String> _customSubjects = [];

  // Hermes 后台解压进度（0~100，null = 尚未开始/已完成）
  int? _agentProgress;
  String _agentStatus = '';
  StreamSubscription? _agentSub;

  // AI 推荐缓存的科目和档位
  List<Map<String, dynamic>> _aiRecommendedSubjects = [];
  bool _aiLoading = false;

  // 各步的模型列表（选厂商后填充）
  List<String> _availableModels = [];

  @override
  void initState() {
    super.initState();
    // 订阅 Hermes 后台解压进度，显示顶部横幅
    final agent = widget.agent;
    if (agent != null) {
      _agentSub = agent.events.listen((e) {
        if (!mounted) return;
        if (e is AgentBridgeProgress) {
          setState(() {
            _agentProgress = e.percent;
            _agentStatus = e.status;
          });
        } else if (e is AgentBridgeStatus && e.type == 'agent_ready') {
          // 已就绪 → 收起横幅
          setState(() => _agentProgress = null);
        }
      });
    }
  }

  @override
  void dispose() {
    _agentSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 4 步页面
    final pages = <Widget>[
      _StepAiConfig(
        selectedVendorId: _selectedVendorId,
        selectedModel: _selectedModel,
        apiKey: _apiKey,
        customBaseUrl: _customBaseUrl,
        availableModels: _availableModels,
        onVendorChanged: (id, models) {
          setState(() {
            _selectedVendorId = id;
            _availableModels = models;
            _selectedModel = models.isNotEmpty ? models.first : null;
          });
        },
        onModelChanged: (m) => setState(() => _selectedModel = m),
        onKeyChanged: (k) => setState(() => _apiKey = k),
        onCustomBaseUrlChanged: (url) => setState(() => _customBaseUrl = url),
      ),
      _StepIdentity(
        selectedIdentity: _selectedIdentity,
        onIdentityChanged: (id) {
          setState(() {
            _selectedIdentity = id;
            _aiLoading = true;
          });
          _loadAiRecommendations(id);
        },
      ),
      _StepSubjects(
        identity: _selectedIdentity,
        subjectProgress: _subjectProgress,
        customSubjects: _customSubjects,
        aiSubjects: _aiRecommendedSubjects,
        aiLoading: _aiLoading,
        onProgressChanged: (subject, stop) {
          setState(() => _subjectProgress[subject] = stop);
        },
        onAddCustom: (name) {
          setState(() {
            if (!_customSubjects.contains(name)) {
              _customSubjects.add(name);
            }
          });
        },
        onRemoveCustom: (name) {
          setState(() {
            _customSubjects.remove(name);
            _subjectProgress.remove(name);
          });
        },
      ),
      _StepComplete(
        // 自定义科目也写入了 _subjectProgress（onProgressChanged），
        // 只数 _subjectProgress 避免重复计数（预设勾选 + 自定义）
        subjectCount: _subjectProgress.length,
        vendorName: _selectedVendorId,
        onFinish: _onFinish,
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            SwipeableStack(pages: pages),
            // 跳过引导（右上角）— 不配 AI 也能进 App，随时可去「AI 设置」补配
            Positioned(
              top: 8,
              right: 12,
              child: TextButton(
                onPressed: () => widget.onComplete(),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.lightTextMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                child: const Text('跳过', style: TextStyle(fontSize: 14)),
              ),
            ),
            // 后台解压进度横幅（首次启动，Hermes 未就绪时）
            if (_agentProgress != null)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: _AgentPrepBanner(percent: _agentProgress!),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadAiRecommendations(SubIdentity identity) async {
    // 模拟 AI 推荐（后续接入真实 API）
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    setState(() {
      _aiRecommendedSubjects = [];
      _aiLoading = false;
    });
  }

  Future<void> _onFinish() async {
    // 保存配置到 SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_vendor', _selectedVendorId ?? '');
    await prefs.setString('ai_model', _selectedModel ?? '');
    await prefs.setString('api_key', _apiKey ?? '');
    if (_selectedVendorId == 'custom' && _customBaseUrl != null && _customBaseUrl!.isNotEmpty) {
      await prefs.setString('ai_base_url', _customBaseUrl!);
    }
    await prefs.setString('identity', _selectedIdentity?.name ?? '');
    await prefs.setBool('onboarding_complete', true);

    // ── 让 AI 服务真正生效：用配置的真实客户端替换 MockAiService ──
    final vendorId = _selectedVendorId;
    final model = _selectedModel;
    final key = _apiKey;
    if (vendorId != null && model != null && key != null && key.isNotEmpty) {
      final vendor = kAiVendors.where((v) => v.id == vendorId).firstOrNull;
      final base = vendorId == 'custom'
          ? _customBaseUrl
          : vendor?.baseUrl;
      if (base != null && base.isNotEmpty) {
        // 预设厂商 baseUrl 形如 https://api.deepseek.com/v1 → 拼 chat/completions
        final url = base.endsWith('/chat/completions') ? base : '$base/chat/completions';
        final ai = OpenAiCompatibleAiService(baseUrl: url, model: model, apiKey: key);
        if (mounted) context.read<AppState>().configureAiService(ai);
      }
    }

    // 创建科目和知识点
    final subjectRepo = SubjectRepository();
    final kpRepo = KpRepository();
    final kpStateRepo = KpStateRepository();

    if (_selectedIdentity != null) {
      final presets = presetSubjectsFor(_selectedIdentity!);

      for (final preset in presets) {
        // 只创建用户勾选了的科目（subjectProgress 中包含的）
        final progressStop = _subjectProgress[preset.name];
        if (progressStop == null) continue;

        final subjectId = await subjectRepo.insertSubject(name: preset.name);
        final stops = preset.progressStops;

        for (var i = 0; i < stops.length; i++) {
          final kpId = await kpRepo.insertKp(subjectId: subjectId, name: stops[i]);
          // 已学到的进度之前的知识点初始化为 0.5，之后的 0.3
          final initialMastery = (i <= progressStop && progressStop > 0) ? 0.5 : 0.3;
          await kpStateRepo.createState(userId: 1, kpId: kpId, initialMastery: initialMastery);
        }
      }
    }

    // 自定义科目：用户手动添加的科目也真实创建（带一个默认知识点）
    for (final name in _customSubjects) {
      final subjectId = await subjectRepo.insertSubject(name: name);
      final kpId = await kpRepo.insertKp(subjectId: subjectId, name: '综合');
      await kpStateRepo.createState(userId: 1, kpId: kpId, initialMastery: 0.3);
    }

    if (!mounted) return;
    widget.onComplete();
  }
}

// ─── 各步骤卡片 ──────────────────────────────────

// ─── Step 1: AI 配置 ───

class _StepAiConfig extends StatelessWidget {
  final String? selectedVendorId;
  final String? selectedModel;
  final String? apiKey;
  final String? customBaseUrl;
  final List<String> availableModels;
  final void Function(String id, List<String> models) onVendorChanged;
  final ValueChanged<String>? onModelChanged;
  final ValueChanged<String>? onKeyChanged;
  final ValueChanged<String>? onCustomBaseUrlChanged;

  const _StepAiConfig({
    required this.selectedVendorId,
    required this.selectedModel,
    required this.apiKey,
    required this.customBaseUrl,
    required this.availableModels,
    required this.onVendorChanged,
    required this.onModelChanged,
    required this.onKeyChanged,
    required this.onCustomBaseUrlChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      color: AppColors.lightBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('🎯', style: TextStyle(fontSize: 28)),
              const SizedBox(width: 12),
              Expanded(child: Text('选择 AI 模型', style: t.headlineMedium)),
              Text('1/4', style: t.labelLarge),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Text('需要 AI 才能给你出题哦', style: t.labelLarge),
          ),
          // 进度点
          const SizedBox(height: 12),
          _ProgressDots(count: 4, current: 0),
          const SizedBox(height: 24),
          Expanded(
            child: ListView(
              children: [
                // 厂商列表
                ...kAiVendors.map((v) => _VendorCard(
                  vendor: v,
                  selected: selectedVendorId == v.id,
                  onTap: () => onVendorChanged(v.id, v.models),
                )),
                // 自定义厂商
                _CustomVendorCard(
                  selected: selectedVendorId == 'custom',
                  baseUrl: customBaseUrl,
                  onBaseUrlChanged: (url) => onCustomBaseUrlChanged?.call(url),
                  onSelect: (id, models) {
                    onVendorChanged(id, models);
                    onCustomBaseUrlChanged?.call(customBaseUrl ?? '');
                  },
                ),
                const SizedBox(height: 20),
                // 模型选择
                if (selectedVendorId != null && availableModels.isNotEmpty) ...[
                  Text('选择模型', style: t.titleMedium),
                  SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: availableModels.map((m) => ChoiceChip(
                      label: Text(m),
                      selected: selectedModel == m,
                      onSelected: (_) => onModelChanged?.call(m),
                      selectedColor: AppColors.primary.withValues(alpha: 0.15),
                      labelStyle: TextStyle(
                        color: selectedModel == m ? AppColors.primary : null,
                        fontWeight: selectedModel == m ? FontWeight.w600 : null,
                      ),
                    )).toList(),
                  ),
                ],
                SizedBox(height: 20),
                // API Key 输入
                Text('API Key', style: t.titleMedium),
                SizedBox(height: 8),
                TextField(
                  decoration: InputDecoration(
                    hintText: '粘贴 API Key',
                    hintStyle: TextStyle(color: AppColors.lightTextMuted.withValues(alpha: 0.5)),
                    filled: true,
                    fillColor: AppColors.lightSurface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppColors.lightDivider),
                    ),
                    contentPadding: const EdgeInsets.all(16),
                  ),
                  obscureText: true,
                  onChanged: (v) => onKeyChanged?.call(v),
                ),
                if (apiKey != null && apiKey!.isNotEmpty) ...[
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.check_circle, color: AppColors.correct, size: 16),
                      SizedBox(width: 6),
                      Text('Key 已配置（仅存本地）', style: TextStyle(color: AppColors.correct, fontSize: 13)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          _SwipeHint(),
        ],
      ),
    );
  }
}

// ─── Step 2: 身份选择 ───

class _StepIdentity extends StatelessWidget {
  final SubIdentity? selectedIdentity;
  final ValueChanged<SubIdentity> onIdentityChanged;

  const _StepIdentity({
    required this.selectedIdentity,
    required this.onIdentityChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      color: AppColors.lightBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('👤', style: TextStyle(fontSize: 28)),
              const SizedBox(width: 12),
              Expanded(child: Text('选择你的身份', style: t.headlineMedium)),
              Text('2/4', style: t.labelLarge),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Text('选择最适合你的标签', style: t.labelLarge),
          ),
          const SizedBox(height: 12),
          _ProgressDots(count: 4, current: 1),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  // 按身份类别分组
                  for (final cat in IdentityCategory.values) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(cat.label, style: t.titleMedium?.copyWith(
                          color: AppColors.lightTextMuted, fontSize: 14,
                        )),
                      ),
                    ),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: SubIdentity.values
                          .where((s) => s.category == cat)
                          .map((s) => _IdentityChip(
                        label: s.label,
                        selected: selectedIdentity == s,
                        onTap: () => onIdentityChanged(s),
                      )).toList(),
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
          ),
          _SwipeHint(),
        ],
      ),
    );
  }
}

// ─── Step 3: 科目+进度 ───

class _StepSubjects extends StatefulWidget {
  final SubIdentity? identity;
  final Map<String, int> subjectProgress;
  final List<String> customSubjects;
  final List<Map<String, dynamic>> aiSubjects;
  final bool aiLoading;
  final void Function(String subject, int stopIndex) onProgressChanged;
  final ValueChanged<String> onAddCustom;
  final ValueChanged<String> onRemoveCustom;

  const _StepSubjects({
    required this.identity,
    required this.subjectProgress,
    required this.customSubjects,
    required this.aiSubjects,
    required this.aiLoading,
    required this.onProgressChanged,
    required this.onAddCustom,
    required this.onRemoveCustom,
  });

  @override
  State<_StepSubjects> createState() => _StepSubjectsState();
}

class _StepSubjectsState extends State<_StepSubjects> {
  final _customCtrl = TextEditingController();
  List<SubjectPreset> _presets = [];

  @override
  void didUpdateWidget(_StepSubjects old) {
    super.didUpdateWidget(old);
    if (widget.identity != old.identity) {
      _presets = widget.identity != null
          ? presetSubjectsFor(widget.identity!)
          : [];
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.identity != null) {
      _presets = presetSubjectsFor(widget.identity!);
    }
  }

  bool get _hasIdentity => widget.identity != null;

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;

    return Container(
      color: AppColors.lightBg,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                const Text('📚', style: TextStyle(fontSize: 28)),
                const SizedBox(width: 12),
                Expanded(child: Text('设置你的科目', style: t.headlineMedium)),
                Text('3/4', style: t.labelLarge),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 40),
                  child: Text('选择科目并拖动进度条标注学习进度', style: t.labelLarge),
                ),
              ],
            ),
          ),
          SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _ProgressDots(count: 4, current: 2),
          ),
          SizedBox(height: 8),
          // ───────── 卡片内滚动区域（卡中卡核心） ─────────
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.lightSurface,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 预设科目（需要先选身份）
                      if (_hasIdentity) ...[
                        ..._presets.map((s) => Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: AiProgressSlider(
                            subjectName: s.name,
                            stops: s.progressStops,
                            initialStop: widget.subjectProgress.containsKey(s.name)
                                ? widget.subjectProgress[s.name]!
                                : -1,
                            onStopChanged: (stop) {
                              widget.onProgressChanged(s.name, stop);
                            },
                          ),
                        )),
                      ] else
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text('请先在「选择身份」页设置你的身份',
                              style: TextStyle(color: AppColors.lightTextMuted),
                            ),
                          ),
                        ),

                      // 分隔 + AI 推荐区
                      if (widget.aiSubjects.isNotEmpty) ...[
                        const Divider(height: 24),
                        Text('🤖 AI 推荐', style: t.titleMedium),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: widget.aiSubjects.map((s) => ActionChip(
                            label: Text(s['name'] as String),
                            avatar: const Icon(Icons.add, size: 16),
                            onPressed: () {
                              widget.onProgressChanged(s['name'] as String, 0);
                            },
                          )).toList(),
                        ),
                      ],

                      if (widget.aiLoading) ...[
                        const Divider(height: 24),
                        Text('🤖 AI 正在推荐...', style: t.labelLarge),
                        SizedBox(height: 8),
                        LinearProgressIndicator(color: AppColors.primary),
                      ],

                      // 自定义添加
                      const Divider(height: 24),
                      Text('✏️ 自定义', style: t.titleMedium),
                      SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 44,
                              child: TextField(
                                controller: _customCtrl,
                                decoration: InputDecoration(
                                  hintText: '输入科目名',
                                  hintStyle: TextStyle(color: AppColors.lightTextMuted.withValues(alpha: 0.5)),
                                  filled: true,
                                  fillColor: AppColors.lightSurfaceAlt,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide.none,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () {
                              final name = _customCtrl.text.trim();
                              if (name.isNotEmpty) {
                                widget.onAddCustom(name);
                                widget.onProgressChanged(name, 0);
                                _customCtrl.clear();
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              minimumSize: const Size(0, 44),
                            ),
                            child: const Text('添加'),
                          ),
                        ],
                      ),

                      // 已添加的自定义科目（带删除，避免"添加了却看不到"）
                      if (widget.customSubjects.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: widget.customSubjects.map((name) => InputChip(
                            label: Text(name),
                            onDeleted: () => widget.onRemoveCustom(name),
                            deleteIconColor: AppColors.wrong,
                          )).toList(),
                        ),
                      ],

                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 下滑提示
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: _SwipeHint(),
          ),
        ],
      ),
    );
  }
}

// ─── Step 4: 完成页 ───

class _StepComplete extends StatelessWidget {
  final int subjectCount;
  final String? vendorName;
  final VoidCallback onFinish;

  const _StepComplete({
    required this.subjectCount,
    required this.vendorName,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final vendorLabel = vendorName == null
        ? '未配置（可稍后在 AI 设置中补配）'
        : (kAiVendors.where((v) => v.id == vendorName).firstOrNull?.name ?? vendorName);

    return Container(
      color: AppColors.lightBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          const Text('🎉', style: TextStyle(fontSize: 64)),
          const SizedBox(height: 20),
          Text('全部设置完成！', style: t.headlineLarge),
          const SizedBox(height: 24),
          _StatLine(icon: '📚', text: '$subjectCount 个科目'),
          const SizedBox(height: 8),
          _StatLine(icon: '🎯', text: '个性化进度已初始化'),
          const SizedBox(height: 8),
          _StatLine(icon: '🤖', text: vendorName == null ? '$vendorLabel' : '$vendorLabel AI 已就绪'),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              '你的信息仅保存在本地设备上，Hermes 随时为你服务',
              textAlign: TextAlign.center,
              style: t.labelLarge,
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: onFinish,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text('🚀 开始刷题！', style: TextStyle(fontSize: 18, color: Colors.white)),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ─── 小组件 ──────────────────────────────────

class _ProgressDots extends StatelessWidget {
  final int count;
  final int current;
  const _ProgressDots({required this.count, required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(count, (i) {
        final active = i == current;
        final done = i < current;
        return Expanded(
          child: Container(
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: done
                  ? AppColors.primary
                  : active
                      ? AppColors.primary.withValues(alpha: 0.6)
                      : AppColors.lightDivider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}

class _SwipeHint extends StatelessWidget {
  const _SwipeHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '下滑下一步 ➡',
            style: TextStyle(
              color: AppColors.lightTextMuted.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _VendorCard extends StatelessWidget {
  final AiVendorPreset vendor;
  final bool selected;
  final VoidCallback onTap;

  const _VendorCard({
    required this.vendor,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected ? AppColors.primaryLight : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.lightDivider,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              if (vendor.recommended) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.gold,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('推荐', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black)),
                ),
                SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(vendor.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(vendor.keyHint, style: TextStyle(fontSize: 12, color: AppColors.lightTextMuted)),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle, color: AppColors.primary, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomVendorCard extends StatefulWidget {
  final bool selected;
  final String? baseUrl;
  final ValueChanged<String> onBaseUrlChanged;
  final void Function(String id, List<String> models) onSelect;

  const _CustomVendorCard({
    required this.selected,
    required this.baseUrl,
    required this.onBaseUrlChanged,
    required this.onSelect,
  });

  @override
  State<_CustomVendorCard> createState() => _CustomVendorCardState();
}

class _CustomVendorCardState extends State<_CustomVendorCard> {
  final _urlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = widget.baseUrl ?? '';
  }

  @override
  void didUpdateWidget(_CustomVendorCard old) {
    super.didUpdateWidget(old);
    if (widget.baseUrl != old.baseUrl && _urlCtrl.text != widget.baseUrl) {
      _urlCtrl.text = widget.baseUrl ?? '';
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  void _maybeSelect() {
    if (_urlCtrl.text.trim().isNotEmpty && _modelCtrl.text.trim().isNotEmpty) {
      widget.onSelect('custom', [_modelCtrl.text.trim()]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: _maybeSelect,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: widget.selected ? AppColors.primaryLight : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.selected ? AppColors.primary : AppColors.lightDivider,
              width: widget.selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.edit, size: 18),
                  SizedBox(width: 8),
                  Text('✏️ 自定义', style: TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  hintText: 'Base URL（如 https://api.example.com/v1）',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                onChanged: (v) {
                  setState(() {});
                  widget.onBaseUrlChanged(v.trim());
                },
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _modelCtrl,
                decoration: const InputDecoration(
                  hintText: 'Model Name（如 my-model）',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IdentityChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _IdentityChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.lightSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.lightDivider,
            width: selected ? 2 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.lightText,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _StatLine extends StatelessWidget {
  final String icon;
  final String text;
  const _StatLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(icon, style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 10),
        Text(text, style: const TextStyle(fontSize: 16)),
      ],
    );
  }
}

/// 引导页顶部的小进度横幅 — 显示后台解压学习环境的进度
class _AgentPrepBanner extends StatelessWidget {
  final int percent;
  const _AgentPrepBanner({required this.percent});

  @override
  Widget build(BuildContext context) {
    final pct = percent.clamp(0, 100);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.lightSurface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
            ),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                '学习环境准备中 $pct%',
                style: TextStyle(color: AppColors.lightTextMuted, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
