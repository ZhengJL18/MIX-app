import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import '../db/database_helper.dart';

/// 设置页 — 主题切换 + AI 接口配置 + Hermes 连接配置
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.onThemeChanged});

  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ThemeMode _themeMode = ThemeMode.dark;
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  bool _saving = false;
  String? _saveStatus;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('app_config');
    for (final row in rows) {
      final key = row['key'] as String;
      final value = row['value'] as String;
      switch (key) {
        case 'theme_mode':
          setState(() {
            _themeMode = value == 'light' ? ThemeMode.light
                : value == 'system' ? ThemeMode.system
                : ThemeMode.dark;
          });
          break;
        case 'api_key':
          _apiKeyController.text = value;
          break;
        case 'api_base_url':
          _baseUrlController.text = value;
          break;
      }
    }
  }

  Future<void> _saveConfig() async {
    setState(() { _saving = true; _saveStatus = null; });
    final db = await DatabaseHelper.instance.database;

    final inserts = <Map<String, String>>[
      {'key': 'theme_mode', 'value': _themeMode.name},
      {'key': 'api_key', 'value': _apiKeyController.text.trim()},
      {'key': 'api_base_url', 'value': _baseUrlController.text.trim()},
    ];
    for (final entry in inserts) {
      await db.insert('app_config', entry, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    widget.onThemeChanged(_themeMode);

    setState(() {
      _saving = false;
      _saveStatus = '已保存';
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _themeMode == ThemeMode.dark;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7),
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: isDark ? const Color(0xFF16213E) : const Color(0xFFF5ECD7),
        foregroundColor: isDark ? Colors.white : const Color(0xFF3A3A3A),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── 主题 ──
          _sectionHeader('显示', isDark),
          Card(
            color: isDark ? const Color(0xFF16213E) : const Color(0xFFFEF9EF),
            child: Column(
              children: [
                RadioGroup<ThemeMode>(
                  groupValue: _themeMode,
                  onChanged: (v) => setState(() { if (v != null) _themeMode = v; }),
                  child: Column(
                    children: [
                      RadioListTile<ThemeMode>(
                        title: const Text('深色模式'),
                        value: ThemeMode.dark,
                      ),
                      RadioListTile<ThemeMode>(
                        title: const Text('浅色模式'),
                        value: ThemeMode.light,
                      ),
                      RadioListTile<ThemeMode>(
                        title: const Text('跟随系统'),
                        value: ThemeMode.system,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── AI 接口配置 ──
          _sectionHeader('AI 接口（出题用）', isDark),
          Card(
            color: isDark ? const Color(0xFF16213E) : const Color(0xFFFEF9EF),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('API Key', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _apiKeyController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      hintText: '输入 Anthropic / OpenAI API Key',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('API 地址（可选）', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                      hintText: 'https://api.anthropic.com/v1/messages',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '留空则使用默认地址。可通过反向代理中转访问受限区域的 API。',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ── 保存按钮 ──
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF8C42),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _saving ? null : _saveConfig,
              child: Text(
                _saving ? '保存中...' : '保存设置',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
          if (_saveStatus != null) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                _saveStatus!,
                style: TextStyle(color: isDark ? Colors.greenAccent : Colors.green),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
    );
  }
}
