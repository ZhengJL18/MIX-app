import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/preset_data.dart';
import '../models/ai_settings.dart';
import '../providers/app_state.dart';
import '../services/agent_bridge.dart';
import '../services/ai_service.dart';
import '../theme/app_colors.dart';

/// AI 设置页（二级页面）— 配置对话与本地 Hermes Agent 共用的模型。
class AiSettingsScreen extends StatefulWidget {
  final AgentBridge agent;
  const AiSettingsScreen({super.key, required this.agent});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  String _vendorId = kAiVendors.first.id;
  late TextEditingController _modelCtrl;
  late TextEditingController _keyCtrl;
  late TextEditingController _baseUrlCtrl;
  bool _obscureKey = true;
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _modelCtrl = TextEditingController();
    _keyCtrl = TextEditingController();
    _baseUrlCtrl = TextEditingController();
    _loadCurrent();
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCurrent() async {
    final existing = await widget.agent.readAiSettings();
    _vendorId = existing?.vendorId ?? kAiVendors.first.id;
    _modelCtrl.text = existing?.model ?? kAiVendors.first.models.first;
    _keyCtrl.text = existing?.apiKey ?? '';
    _baseUrlCtrl.text = existing?.baseUrl ?? '';
    if (mounted) setState(() => _loaded = true);
  }

  bool get _isCustom => _vendorId == 'custom';

  AiVendorPreset? get _preset =>
      kAiVendors.where((v) => v.id == _vendorId).firstOrNull;

  Future<void> _save() async {
    final model = _modelCtrl.text.trim();
    final key = _keyCtrl.text.trim();
    final base = _isCustom
        ? _baseUrlCtrl.text.trim()
        : _preset?.baseUrl ?? '';
    if (model.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写模型和 API Key')),
      );
      return;
    }
    if (base.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写 Base URL')),
      );
      return;
    }

    setState(() => _saving = true);
    final settings = AiSettings(
      vendorId: _vendorId,
      model: model,
      apiKey: key,
      baseUrl: base,
    );

    // 同步给刷题出题（AppState）与 Hermes 本地 Agent
    final url = base.endsWith('/chat/completions') ? base : '$base/chat/completions';
    if (mounted) {
      context.read<AppState>().configureAiService(
        OpenAiCompatibleAiService(baseUrl: url, model: model, apiKey: key),
      );
    }
    await widget.agent.applyAiSettings(settings);

    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存，刷题出题与本地 Hermes 将使用此模型')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: AppColors.lightBg,
        title: const Text('AI 设置'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: AppColors.primary, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '这里配置的模型会同时用于「刷题出题」「AI 对话」和本地 Hermes Agent，三处共用同一个模型与 Key。',
                          style: TextStyle(color: AppColors.lightText, fontSize: 13, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 24),

                // ── 厂商选择 ──
                Text('AI 厂商',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.lightTextMuted)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _vendorId,
                  isExpanded: true,
                  decoration: _fieldDecoration('选择厂商'),
                  items: [
                    ...kAiVendors.map((v) => DropdownMenuItem(value: v.id, child: Text(v.name))),
                    const DropdownMenuItem(value: 'custom', child: Text('✏️ 自定义')),
                  ],
                  onChanged: (id) {
                    setState(() => _vendorId = id!);
                  },
                ),
                SizedBox(height: 20),

                // ── 模型 ──
                Text('模型',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.lightTextMuted)),
                SizedBox(height: 8),
                TextField(
                  controller: _modelCtrl,
                  decoration: _fieldDecoration(_isCustom ? '如 my-model' : '如 ${_preset?.models.first}'),
                ),
                if (_preset != null) ...[
                  SizedBox(height: 6),
                  Text(
                    '推荐：${_preset!.models.join('、')}',
                    style: TextStyle(fontSize: 12, color: AppColors.lightTextMuted),
                  ),
                ],
                SizedBox(height: 20),

                // ── Base URL（仅自定义厂商） ──
                if (_isCustom) ...[
                  Text('Base URL',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.lightTextMuted)),
                  SizedBox(height: 8),
                  TextField(
                    controller: _baseUrlCtrl,
                    decoration: _fieldDecoration('如 https://api.example.com/v1'),
                  ),
                  SizedBox(height: 20),
                ],

                // ── API Key ──
                Text('API Key',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.lightTextMuted)),
                SizedBox(height: 8),
                TextField(
                  controller: _keyCtrl,
                  obscureText: _obscureKey,
                  decoration: _fieldDecoration(_isCustom ? '粘贴 API Key' : (_preset?.keyHint ?? '粘贴 API Key')).copyWith(
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureKey ? Icons.visibility_off : Icons.visibility,
                        color: AppColors.lightTextMuted,
                      ),
                      onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                ),
                SizedBox(height: 32),

                // ── 保存 ──
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('保存', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
    );
  }

  InputDecoration _fieldDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.lightTextMuted),
      filled: true,
      fillColor: AppColors.lightSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.lightDivider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.lightDivider),
      ),
    );
  }
}
