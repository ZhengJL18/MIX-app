import 'dart:math';

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// 趣味结果类型
enum FunResultType { skip, correct, wrong }

/// 趣味结果页 — 做题后下滑第一屏看到的趣味化反馈。
///
/// 在正常对错提示之上叠加表情包 + 配文，让刷题更有趣味：
/// - 未做（skip）：鼓励先蒙一个再对答案，下滑 = 跳过本题
/// - 做对（correct）：斯国一！ / 如此强劲！ 二选一
/// - 做错（wrong）：啊咧咧？ / 欸呀欸呀，做错了吗？ 二选一
///
/// 图片从 assets/memes/ 加载，缺失时用 emoji 兜底，不阻塞显示。
class FunResultCard extends StatefulWidget {
  final FunResultType type;

  const FunResultCard({super.key, required this.type});

  @override
  State<FunResultCard> createState() => _FunResultCardState();
}

class _FunResultCardState extends State<FunResultCard> {
  // 每次进入固定选择的表情（对/错二选一），避免 rebuild 时随机跳动
  late final bool _useVariantB;

  @override
  void initState() {
    super.initState();
    _useVariantB = Random().nextBool();
  }

  FunContent get _content {
    switch (widget.type) {
      case FunResultType.skip:
        return FunContent(
          imageAsset: 'assets/memes/skip.png',
          emoji: '🤔',
          tagline: '还没做题怎么能看答案呢，高低蒙一个啊喂！',
          subText: '下滑可跳过本题',
          accentColor: AppColors.lightTextMuted,
        );
      case FunResultType.correct:
        return _useVariantB
            ? FunContent(
                imageAsset: 'assets/memes/correct2.png',
                emoji: '💪',
                tagline: '如此强劲！',
                subText: '回答正确',
                accentColor: AppColors.correct,
              )
            : FunContent(
                imageAsset: 'assets/memes/correct1.png',
                emoji: '🎉',
                tagline: '斯国一！',
                subText: '回答正确',
                accentColor: AppColors.correct,
              );
      case FunResultType.wrong:
        return _useVariantB
            ? FunContent(
                imageAsset: 'assets/memes/wrong2.png',
                emoji: '😬',
                tagline: '欸呀欸呀，做错了吗？',
                subText: '回答错误',
                accentColor: AppColors.wrong,
              )
            : FunContent(
                imageAsset: 'assets/memes/wrong1.png',
                emoji: '🙃',
                tagline: '啊咧咧？',
                subText: '回答错误',
                accentColor: AppColors.wrong,
              );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _content;
    return Container(
      color: AppColors.lightBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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
          // 趣味配文
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
            style: TextStyle(color: AppColors.lightTextMuted, fontSize: 13),
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
