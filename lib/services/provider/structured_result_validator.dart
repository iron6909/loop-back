/// 结构化 AI 结果的严格校验器
///
/// 校验发生在反序列化**之前**：现有 `fromJson` 为「流式半成品展示」设计，缺字段与
/// 类型不符一律回退空值，能解析不等于有效（spike 实测：空对象与类型错误均可通过
/// `fromJson`）；`SenseGroupResult.fromJson` 反而会对非数组 `medium`/`fine` 抛
/// `TypeError`。因此这里先做类型与必填检查，再交给 `fromJson` 构造领域对象。
///
/// 判定语义（与 spec「结果校验」表一致）：
/// - 必填字段缺失、或为空白字符串 → [ValidationFailureReason.missingField]；
/// - 字段存在但类型不符 → [ValidationFailureReason.fieldType]；
/// - 枚举字段缺失或取值不在枚举内 → [ValidationFailureReason.invalidEnum]；
/// - 意群与原文不守恒（含大小写与词序） → [ValidationFailureReason.notConserved]；
/// - 响应正文为空 / 顶层非 JSON 对象 → [ValidationFailureReason.emptyBody] /
///   [ValidationFailureReason.notJsonObject]。
///
/// 本模块只判真假，不回落输出模式、不写缓存：回落与缓存由调用方按失败原因决定。
library;

import '../../models/dictionary/dictionary_entry.dart';
import '../../models/retell_review_evaluation.dart';
import '../../models/sense_group_result.dart';
import '../../models/sentence_ai_result.dart';
import '../../utils/sense_group_validate.dart';

/// 校验失败原因。
///
/// 校验失败一律不能触发回落；只有传输层明确报告不支持输出模式才能回落。
enum ValidationFailureReason {
  /// 响应正文为空（含纯空白）。
  emptyBody,

  /// 正文不是 JSON 对象（顶层为数组、标量或无法解析）。
  notJsonObject,

  /// 字段存在但类型不符。
  fieldType,

  /// 必填字段缺失，或必填文本为空白。
  missingField,

  /// 枚举字段缺失或取值不在枚举内。
  invalidEnum,

  /// 意群拼接无法还原原文。
  notConserved,

  /// 响应因输出预算耗尽被截断（`finish_reason=length`）。
  truncated,
}

/// 校验结果：成功携带领域对象，失败携带原因。
sealed class ValidationOutcome<T> {
  const ValidationOutcome();
}

/// 校验通过，[value] 为可直接使用的领域对象。
final class ValidationSuccess<T> extends ValidationOutcome<T> {
  const ValidationSuccess(this.value);

  final T value;
}

/// 校验失败，[reason] 用于用户提示；结果不能落缓存。
final class ValidationFailure<T> extends ValidationOutcome<T> {
  const ValidationFailure(this.reason);

  final ValidationFailureReason reason;
}

/// 校验句子翻译结果。
ValidationOutcome<SentenceTranslation> validateTranslation(Object? decoded) =>
    _withObject(decoded, (json) {
      final reason = _requiredText(json, 'translation');
      if (reason != null) return ValidationFailure(reason);
      return ValidationSuccess(SentenceTranslation.fromJson(json));
    });

/// 校验句子解析结果。
///
/// `grammar` 与 `listening` 必须非空且每项文本齐备；`vocabulary` 可为空列表，但已有
/// 项必须字段齐备（避免出现只有词没有释义的半成品）。
ValidationOutcome<SentenceAnalysis> validateAnalysis(
  Object? decoded,
) => _withObject(decoded, (json) {
  final grammar = _objectList(json, 'grammar', requireNonEmpty: true);
  if (grammar.reason case final reason?) return ValidationFailure(reason);
  for (final item in grammar.items) {
    final reason = _requiredText(item, 'point') ?? _requiredText(item, 'note');
    if (reason != null) return ValidationFailure(reason);
  }

  final listening = _objectList(json, 'listening', requireNonEmpty: true);
  if (listening.reason case final reason?) return ValidationFailure(reason);
  for (final item in listening.items) {
    final reason = _requiredText(item, 'phrase') ?? _requiredText(item, 'note');
    if (reason != null) return ValidationFailure(reason);
  }

  final vocabulary = _objectList(json, 'vocabulary');
  if (vocabulary.reason case final reason?) return ValidationFailure(reason);
  for (final item in vocabulary.items) {
    final reason = _requiredText(item, 'term') ?? _requiredText(item, 'note');
    if (reason != null) return ValidationFailure(reason);
  }

  return ValidationSuccess(SentenceAnalysis.fromJson(json));
});

/// 校验单词深度解析结果。
ValidationOutcome<DictionaryEntry> validateWordEntry(Object? decoded) =>
    _withObject(decoded, (json) {
      final headword = _requiredText(json, 'headword');
      if (headword != null) return ValidationFailure(headword);

      final meanings = _objectList(json, 'meanings', requireNonEmpty: true);
      if (meanings.reason case final reason?) return ValidationFailure(reason);
      for (final meaning in meanings.items) {
        final reason =
            _requiredText(meaning, 'partOfSpeech') ??
            _requiredText(meaning, 'definition');
        if (reason != null) return ValidationFailure(reason);
        final translation = _stringList(
          meaning,
          'translation',
          requireNonEmpty: true,
        );
        if (translation != null) return ValidationFailure(translation);
      }

      return ValidationSuccess(DictionaryEntry.fromJson(json));
    });

/// 校验多词表达（短语）解析结果。
ValidationOutcome<MultiWordDictionaryEntry> validatePhraseEntry(
  Object? decoded,
) => _withObject(decoded, (json) {
  final expression = _requiredText(json, 'originalExpression');
  if (expression != null) return ValidationFailure(expression);
  final category = _requiredText(json, 'category');
  if (category != null) return ValidationFailure(category);

  final keyPoints = _objectList(json, 'keyPoints', requireNonEmpty: true);
  if (keyPoints.reason case final reason?) return ValidationFailure(reason);
  for (final point in keyPoints.items) {
    final reason = _requiredText(point, 'point');
    if (reason != null) return ValidationFailure(reason);
  }

  final meanings = _objectList(json, 'meanings');
  if (meanings.reason case final reason?) return ValidationFailure(reason);
  for (final meaning in meanings.items) {
    final reason = _stringList(meaning, 'translation', requireNonEmpty: true);
    if (reason != null) return ValidationFailure(reason);
  }

  return ValidationSuccess(MultiWordDictionaryEntry.fromJson(json));
});

/// 校验意群拆分结果。
///
/// [original] 为被拆分的原句；两种粒度都必须能逐字还原它（[validateSenseGroupChunks]
/// 的快/慢两条路径均大小写敏感）。
ValidationOutcome<SenseGroupResult> validateSenseGroups(
  Object? decoded, {
  required String original,
}) => _withObject(decoded, (json) {
  final medium = _stringList(json, 'medium', requireNonEmpty: true);
  if (medium != null) return ValidationFailure(medium);
  final fine = _stringList(json, 'fine', requireNonEmpty: true);
  if (fine != null) return ValidationFailure(fine);

  final result = SenseGroupResult.fromJson(json);
  if (!validateSenseGroupChunks(result.medium, original) ||
      !validateSenseGroupChunks(result.fine, original)) {
    return const ValidationFailure(ValidationFailureReason.notConserved);
  }
  return ValidationSuccess(result);
});

/// 校验复述评估结果。
///
/// 枚举合法性复用 [RetellReviewEvaluation.fromJson] 的映射（未知取值落 null），
/// 避免在本地再抄一份枚举表。
ValidationOutcome<RetellReviewEvaluation> validateRetell(Object? decoded) =>
    _withObject(decoded, (json) {
      final summary = _requiredText(json, 'summary');
      if (summary != null) return ValidationFailure(summary);

      final keyPoints = _objectList(json, 'keyPoints', requireNonEmpty: true);
      if (keyPoints.reason case final reason?) return ValidationFailure(reason);
      for (final point in keyPoints.items) {
        final reason = _requiredText(point, 'keyPoint');
        if (reason != null) return ValidationFailure(reason);
      }

      final corrections = _objectList(json, 'corrections');
      if (corrections.reason case final reason?) {
        return ValidationFailure(reason);
      }
      for (final correction in corrections.items) {
        final reason =
            _requiredText(correction, 'transcript') ??
            _requiredText(correction, 'correction');
        if (reason != null) return ValidationFailure(reason);
      }

      final evaluation = RetellReviewEvaluation.fromJson(json);
      if (evaluation.rating == null ||
          evaluation.keyPoints.any((point) => point.status == null) ||
          evaluation.corrections.any((item) => item.type == null)) {
        return const ValidationFailure(ValidationFailureReason.invalidEnum);
      }
      return ValidationSuccess(evaluation);
    });

/// 统一处理输入形态，再把已确认为对象的 JSON 交给 [body]。
ValidationOutcome<T> _withObject<T>(
  Object? decoded,
  ValidationOutcome<T> Function(Map<String, dynamic> json) body,
) {
  if (decoded == null) {
    return const ValidationFailure(ValidationFailureReason.emptyBody);
  }
  if (decoded is String) {
    if (decoded.trim().isEmpty) {
      return const ValidationFailure(ValidationFailureReason.emptyBody);
    }
    return const ValidationFailure(ValidationFailureReason.notJsonObject);
  }
  if (decoded is! Map<String, dynamic>) {
    return const ValidationFailure(ValidationFailureReason.notJsonObject);
  }
  return body(decoded);
}

/// 读取必填非空文本字段；返回 null 表示通过。
ValidationFailureReason? _requiredText(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) return ValidationFailureReason.missingField;
  final value = json[key];
  if (value is! String) return ValidationFailureReason.fieldType;
  if (value.trim().isEmpty) return ValidationFailureReason.missingField;
  return null;
}

/// 读取对象数组字段。
///
/// 返回的元素已确认是 `Map<String, dynamic>`；[requireNonEmpty] 为 true 时空列表
/// 视为缺失。
({ValidationFailureReason? reason, List<Map<String, dynamic>> items})
_objectList(
  Map<String, dynamic> json,
  String key, {
  bool requireNonEmpty = false,
}) {
  if (!json.containsKey(key)) {
    return (reason: ValidationFailureReason.missingField, items: const []);
  }
  final value = json[key];
  if (value is! List) {
    return (reason: ValidationFailureReason.fieldType, items: const []);
  }
  if (requireNonEmpty && value.isEmpty) {
    return (reason: ValidationFailureReason.missingField, items: const []);
  }
  final items = <Map<String, dynamic>>[];
  for (final item in value) {
    if (item is! Map<String, dynamic>) {
      return (reason: ValidationFailureReason.fieldType, items: const []);
    }
    items.add(item);
  }
  return (reason: null, items: items);
}

/// 读取字符串数组字段；返回 null 表示通过。
ValidationFailureReason? _stringList(
  Map<String, dynamic> json,
  String key, {
  required bool requireNonEmpty,
}) {
  if (!json.containsKey(key)) return ValidationFailureReason.missingField;
  final value = json[key];
  if (value is! List) return ValidationFailureReason.fieldType;
  if (requireNonEmpty && value.isEmpty) {
    return ValidationFailureReason.missingField;
  }
  for (final item in value) {
    if (item is! String) return ValidationFailureReason.fieldType;
    if (item.trim().isEmpty) return ValidationFailureReason.missingField;
  }
  return null;
}
