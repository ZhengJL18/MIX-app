import 'package:flutter/material.dart';

import '../data/preset_data.dart';
import '../models/ai_settings.dart';
import '../services/agent_bridge.dart';
import '../theme/app_colors.dart';

/// AI 设置页（二级页面）— 配置对话与本地 Hermes Agent 共用的模型。
class AiSettingsScreen extends StatefulWidget {
  final AgentBridge agent;
  const AiSettingsScreen({super.key, required this.agent});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late AiVendorPreset _vendor;
  late TextEditingController _modelCtrl;
  late TextEditingController _keyCtrl;
  bool _obscureKey = true;
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _modelCtrl = TextEditingController();
    _keyCtrl = TextEditingController();
    _loadCurrent();
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCurrent() async {
    final existing = await widget.agent.readAiSettings();
    final vendorId = existing?.vendorId ?? kAiVendors.first.id;
    _vendor = kAiVendors.firstWhere((v) => v.id == vendorId,
        orElse: () => kAiVendors.first);
    _modelCtrl.text = existing?.model ?? _vendor.models.first;
    _keyCtrl.text = existing?.apiKey ?? '';
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final model = _modelCtrl.text.trim();
    final key = _keyCtrl.text.trim();
    if (model.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写模型和 API Key')),
      );
      return;
    }
    setState(() => _saving = true);
    final settings = AiSettings(
      vendorId: _vendor.id,
      model: model,
      apiKey: key,
      baseUrl: _vendor.baseUrl,
    );
    await widget.agent.applyAiSettings(settings);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存，对话与本地 Hermes 将使用此模型')),
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
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: AppColors.primary, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '这里配置的模型会同时用于「AI 对话」和本地 Hermes Agent，两处共用同一个模型与 Key。',
                          style: TextStyle(color: Color(0xFF2D1810), fontSize: 13, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── 厂商选择 ──
                const Text('AI 厂商',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.lightTextMuted)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _vendor.id,
                  isExpanded: true,
                  decoration: _fieldDecoration('选择厂商'),
                  items: kAiVendors
                      .map((v) => DropdownMenuItem(value: v.id, child: Text(v.name)))
                      .toList(),
                  onChanged: (id) {
                    final next = kAiVendors.firstWhere((v) => v.id == id);
                    setState(() {
                      _vendor = next;
                      // 切换厂商时若模型输入还是旧厂商的，则用新厂商默认模型
                      final presetModels = next.models;
                      if (!presetModels.contains(_modelCtrl.text)) {
                        _modelCtrl.text = presetModels.first;
                      }
                    });
                  },
                ),
                const SizedBox(height: 20),

                // ── 模型 ──
                const Text('模型',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.lightTextMuted)),
                const SizedBox(height: 8),
                TextField(
                  controller: _modelCtrl,
                  decoration: _fieldDecoration('如 ${_vendor.models.first}'),
                ),
                const SizedBox(height: 6),
                Text(
                  '推荐：${_vendor.models.join('、')}',
                  style: const TextStyle(fontSize: 12, color: AppColors.lightTextMuted),
                ),
                const SizedBox(height: 20),

                // ── API Key ──
                const Text('API Key',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.lightTextMuted)),
                const SizedBox(height: 8),
                TextField(
                  controller: _keyCtrl,
                  obscureText: _obscureKey,
                  decoration: _fieldDecoration(_vendor.keyHint).copyWith(
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureKey ? Icons.visibility_off : Icons.visibility,
                        color: AppColors.lightTextMuted,
                      ),
                      onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                ),
                const SizedBox(height: 32),

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
      hintStyle: const TextStyle(color: AppColors.lightTextMuted),
      filled: true,
      fillColor: AppColors.lightSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.lightDivider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.lightDivider),
      ),
    );
  }
}
