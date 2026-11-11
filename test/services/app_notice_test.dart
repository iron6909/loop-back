import 'package:loop_back/services/app_notice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('应用级通知总线向任意订阅者发布标准通知', () async {
    final bus = AppNoticeBus();
    final received = bus.notices.first;
    const notice = AppNotice(
      message: AppNoticeMessage.playbackFailed,
      dedupeKey: 'media-kit-initialize-failed',
    );

    bus.publish(notice);

    expect(await received, same(notice));
  });
}
