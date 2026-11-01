/// 输出模式选择与回落判定测试
///
/// 锁定 spec「输出模式选择」：只在供应商**明确**表示不支持严格 Schema 时回落一次
/// `json_object`；截断、空正文、非 JSON、校验失败等一律判失败，不得借回落把坏结果
/// 变成「成功」。
library;

import 'package:echo_loop/services/provider/output_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fallbackOutputMode', () {
    test('严格 Schema 被明确拒绝时回落 json_object 一次', () {
      expect(
        fallbackOutputMode(
          current: OutputMode.jsonSchema,
          failure: OutputFailureKind.unsupportedOutputMode,
        ),
        OutputMode.jsonObject,
      );
    });

    test('已经是 json_object 时不再回落', () {
      expect(
        fallbackOutputMode(
          current: OutputMode.jsonObject,
          failure: OutputFailureKind.unsupportedOutputMode,
        ),
        isNull,
      );
    });

    test('finish_reason=length 不回落', () {
      expect(
        fallbackOutputMode(
          current: OutputMode.jsonSchema,
          failure: OutputFailureKind.truncated,
        ),
        isNull,
      );
    });

    test('空正文不回落', () {
      expect(
        fallbackOutputMode(
          current: OutputMode.jsonSchema,
          failure: OutputFailureKind.emptyBody,
        ),
        isNull,
      );
    });

    test('顶层非 JSON 对象不回落', () {
      expect(
        fallbackOutputMode(
          current: OutputMode.jsonSchema,
          failure: OutputFailureKind.notJsonObject,
        ),
        isNull,
      );
    });

    test('字段类型或枚举或守恒校验失败不回落', () {
      expect(
        fallbackOutputMode(
          current: OutputMode.jsonSchema,
          failure: OutputFailureKind.invalidResult,
        ),
        isNull,
      );
    });

    test('传输层错误不回落（由重试策略处理）', () {
      expect(
        fallbackOutputMode(
          current: OutputMode.jsonSchema,
          failure: OutputFailureKind.transport,
        ),
        isNull,
      );
    });
  });

  group('indicatesUnsupportedOutputMode', () {
    test('400 且错误体点名 response_format 不支持时判为明确不支持', () {
      expect(
        indicatesUnsupportedOutputMode(
          statusCode: 400,
          errorBody:
              '{"error":{"message":"response_format is not supported",'
              '"type":"invalid_request_error"}}',
        ),
        isTrue,
      );
    });

    test('422 且错误体点名 json_schema 不支持时判为明确不支持', () {
      expect(
        indicatesUnsupportedOutputMode(
          statusCode: 422,
          errorBody: '{"error":"json_schema is not supported by this model"}',
        ),
        isTrue,
      );
    });

    test('大小写不敏感', () {
      expect(
        indicatesUnsupportedOutputMode(
          statusCode: 400,
          errorBody: '{"error":"Response_Format unsupported"}',
        ),
        isTrue,
      );
    });

    test('400 但是别的参数问题时不判为不支持输出模式', () {
      expect(
        indicatesUnsupportedOutputMode(
          statusCode: 400,
          errorBody: '{"error":{"message":"model not found"}}',
        ),
        isFalse,
      );
    });

    test('5xx 不判为不支持（交给重试）', () {
      expect(
        indicatesUnsupportedOutputMode(
          statusCode: 500,
          errorBody: '{"error":"response_format is not supported"}',
        ),
        isFalse,
      );
    });

    test('schema 本身非法不能误判为不支持', () {
      expect(
        indicatesUnsupportedOutputMode(
          statusCode: 400,
          errorBody:
              'invalid json_schema: required must include every property',
        ),
        isFalse,
      );
    });

    test('缺少状态码或错误体时不判为不支持', () {
      expect(
        indicatesUnsupportedOutputMode(statusCode: null, errorBody: 'oops'),
        isFalse,
      );
      expect(
        indicatesUnsupportedOutputMode(statusCode: 400, errorBody: null),
        isFalse,
      );
    });
  });
}
