import 'package:lpinyin/lpinyin.dart';

class SearchText {
  const SearchText(this.original, this.normalized, this.pinyin, this.initials);
  final String original;
  final String normalized;
  final String pinyin;
  final String initials;
}

class PinyinUtils {
  const PinyinUtils._();

  static SearchText index(String value) {
    final normalized = _traditionalToSimplified(value).toLowerCase();
    String pinyin;
    String initials;
    try {
      pinyin = PinyinHelper.getPinyin(normalized, separator: '');
      initials = PinyinHelper.getShortPinyin(normalized).toLowerCase();
    } catch (_) {
      pinyin = normalized;
      initials = normalized;
    }
    return SearchText(value, normalized, pinyin.toLowerCase(), initials);
  }

  static bool matches(String query, Iterable<String> fields) {
    final q = _traditionalToSimplified(query).trim().toLowerCase();
    if (q.isEmpty) return true;
    final tokens = q.split(RegExp(r'\s+'));
    final indexedFields = fields.map(index).toList(growable: false);
    return tokens.every((token) => indexedFields.any((indexed) => indexed.normalized.contains(token) || indexed.pinyin.contains(token) || indexed.initials.contains(token)));
  }

  static String _traditionalToSimplified(String value) {
    const map = {'傑': '杰', '倫': '伦', '風': '风', '樂': '乐', '愛': '爱', '學': '学', '國': '国', '語': '语', '臺': '台', '後': '后', '萬': '万', '與': '与'};
    return value.split('').map((c) => map[c] ?? c).join();
  }
}
