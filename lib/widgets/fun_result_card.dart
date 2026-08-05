import 'dart:math';

import 'package:flutter/material.dart';
import '../theme/app_palette.dart';

/// 趣味结果类型
enum FunResultType { skip, correct, wrong }

/// 趣味结果页 — 做题后第一屏看到的趣味化反馈。
///
/// 每类（对/错/跳过）有多张图，随机挑一张，配文 = 图片文件名。
/// 图片来自用户提供的 assets/memes/，缺失时用 emoji 兜底。
class FunResultCard extends StatefulWidget {
  final FunResultType type;

  /// 紧凑模式：嵌入外层滚动容器（连续流）时不用 center 撑满。
  final bool compact;

  const FunResultCard({super.key, required this.type, this.compact = false});

  @override
  State<FunResultCard> createState() => _FunResultCardState();
}

class _FunResultCardState extends State<FunResultCard> {
  // 每次进入固定选择一张（随机），避免 rebuild 时跳动
  late final FunContent _content;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首次能拿 context 时选一张固定（静态方法拿不到 context，需传 palette）
    if (!_initialized) {
      _initialized = true;
      _content = _pickContent(widget.type, context.appPalette);
    }
  }

  bool _initialized = false;

  /// 按情境随机选一张图。
  static FunContent _pickContent(FunResultType type, AppPalette palette) {
    final random = Random();
    switch (type) {
      case FunResultType.skip:
        final pool = [
          _fc('skip_weizuowan', '诶呀还没做完呢', '下滑可跳过本题', palette.textMuted, '🤔'),
        ];
        return pool[random.nextInt(pool.length)];
      case FunResultType.correct:
        final pool = [
          _fc('correct_tiancai', '天才！', '回答正确', palette.correct, '🎉'),
          _fc('correct_zhenbang', '真棒', '回答正确', palette.correct, '💪'),
          _fc('correct_wenzhenbang', '我真棒', '回答正确', palette.correct, '😎'),
          _fc('correct_qiangqiang', '！？强强？！', '回答正确', palette.correct, '🔥'),
        ];
        return pool[random.nextInt(pool.length)];
      case FunResultType.wrong:
        final pool = [
          _fc('wrong_alie', '啊咧，错了吗', '回答错误', palette.wrong, '🙃'),
          _fc('wrong_ah', '啊！错了！', '回答错误', palette.wrong, '😬'),
        ];
        return pool[random.nextInt(pool.length)];
    }
  }

  static FunContent _fc(String name, String tagline, String sub, Color color, String emoji) {
    return FunContent(
      imageAsset: 'assets/memes/$name.png',
      emoji: emoji,
      tagline: tagline,
      subText: sub,
      accentColor: color,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _content;
    return Container(
      color: context.appPalette.bg,
      padding: EdgeInsets.all(widget.compact ? 0 : 24),
      child: Column(
        mainAxisAlignment: widget.compact ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: [
          // 图片（缺失时 emoji 兜底）
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.asset(
              c.imageAsset,
              width: 220,
              height: 220,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: 220,
                height: 220,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(c.emoji, style: const TextStyle(fontSize: 96)),
              ),
            ),
          ),
          const SizedBox(height: 28),
          // 趣味配文（图片名）
          Text(
            c.tagline,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: c.accentColor,
            ),
          ),
          const SizedBox(height: 12),
          // 正常对错提示（不替代，而是补充）
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: c.accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              c.subText,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.accentColor,
              ),
            ),
          ),
          SizedBox(height: 8),
          Text(
            '下滑${widget.type == FunResultType.skip ? '跳过本题' : '查看解析'} ➡',
            style: TextStyle(color: context.appPalette.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class FunContent {
  final String imageAsset;
  final String emoji;
  final String tagline;
  final String subText;
  final Color accentColor;

  const FunContent({
    required this.imageAsset,
    required this.emoji,
    required this.tagline,
    required this.subText,
    required this.accentColor,
  });
}
