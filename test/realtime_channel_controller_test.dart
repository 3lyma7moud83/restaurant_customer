import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/realtime/realtime_channel_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('realtimeStatusRequiresRecovery', () {
    test('keeps a stable subscription connected regardless of elapsed time',
        () {
      expect(
        realtimeStatusRequiresRecovery(RealtimeSubscribeStatus.subscribed),
        isFalse,
      );
    });

    test('recovers after channel errors, timeouts, and closes', () {
      expect(
        realtimeStatusRequiresRecovery(RealtimeSubscribeStatus.channelError),
        isTrue,
      );
      expect(
        realtimeStatusRequiresRecovery(RealtimeSubscribeStatus.timedOut),
        isTrue,
      );
      expect(
        realtimeStatusRequiresRecovery(RealtimeSubscribeStatus.closed),
        isTrue,
      );
    });
  });
}
