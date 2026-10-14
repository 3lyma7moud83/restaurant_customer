import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/stability/session_security_service.dart';

void main() {
  group('revocation fallback', () {
    test('uses Realtime when healthy and falls back after a disconnect', () {
      expect(
        shouldRunRevocationFallbackCheck(
          hasSession: true,
          realtimeHealthy: true,
        ),
        isFalse,
      );
      expect(
        shouldRunRevocationFallbackCheck(
          hasSession: true,
          realtimeHealthy: false,
        ),
        isTrue,
      );
      expect(
        shouldRunRevocationFallbackCheck(
          hasSession: true,
          realtimeHealthy: true,
        ),
        isFalse,
      );
    });

    test('applies revocation only to the matching session or device', () {
      expect(
        revocationSignalApplies(
          globalRevoke: false,
          remoteSessionId: 'other',
          localSessionId: 'current',
          remoteFingerprint: 'other-device',
          localFingerprint: 'this-device',
        ),
        isFalse,
      );
      expect(
        revocationSignalApplies(
          globalRevoke: false,
          remoteSessionId: 'current',
          localSessionId: 'current',
          remoteFingerprint: '',
          localFingerprint: 'this-device',
        ),
        isTrue,
      );
    });
  });

  test('session maintenance is deferred but restores a missing record', () {
    final now = DateTime.utc(2026, 10, 11, 12);

    expect(
      shouldMaintainRemoteSession(
        remoteRecordExists: true,
        lastMaintenanceAt: now.subtract(const Duration(minutes: 9)),
        now: now,
      ),
      isFalse,
    );
    expect(
      shouldMaintainRemoteSession(
        remoteRecordExists: true,
        lastMaintenanceAt: now.subtract(const Duration(minutes: 10)),
        now: now,
      ),
      isTrue,
    );
    expect(
      shouldMaintainRemoteSession(
        remoteRecordExists: false,
        lastMaintenanceAt: now,
        now: now,
      ),
      isTrue,
    );
  });
}
