import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/stability/stability_metrics_service.dart';

void main() {
  test('security metrics aggregate by event type and severity', () {
    final metrics = aggregateSecurityEventMetricSamples([
      const SecurityEventMetricSample(
        eventKey: 'session_revoked_remote',
        severity: 'high',
        value: 1,
      ),
      const SecurityEventMetricSample(
        eventKey: 'session_revoked_remote',
        severity: 'high',
        value: 2,
      ),
      const SecurityEventMetricSample(
        eventKey: 'session_revoked_remote',
        severity: 'medium',
        value: 1,
      ),
    ]);

    expect(metrics, hasLength(2));
    expect(
      metrics.singleWhere((metric) => metric.severity == 'high').value,
      3,
    );
    expect(
      metrics.singleWhere((metric) => metric.severity == 'medium').value,
      1,
    );
  });
}
