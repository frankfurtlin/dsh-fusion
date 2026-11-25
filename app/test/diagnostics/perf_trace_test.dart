// 性能账本本身：顺序、计数、上限、失败也记。
// 只量的是「记下来」这件事；真实耗时由装机后的诊断页给。

import 'package:dsh_app/diagnostics/perf_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(PerfTrace.reset);

  test('spans keep the order they ended in, with their fields', () async {
    PerfTrace.begin('boot');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    PerfTrace.end('boot', {'phase': 'frame'});
    PerfTrace.note('session_list', 233, {'rows': 186});

    expect(PerfTrace.spans.map((s) => s.name), ['boot', 'session_list']);
    expect(PerfTrace.spans.first.ms, greaterThanOrEqualTo(5));
    expect(PerfTrace.spans.last.fields['rows'], 186);
    expect(PerfTrace.spans.last.toString(), 'session_list 233ms rows=186');
  });

  test('an end without a begin is ignored, not an error', () {
    PerfTrace.end('never_started');
    expect(PerfTrace.isEmpty, isTrue);
  });

  test('the ledger is bounded', () {
    for (var i = 0; i < PerfTrace.maxSpans + 5; i++) {
      PerfTrace.note('span_$i', i);
    }
    expect(PerfTrace.spans.length, PerfTrace.maxSpans);
    // 旧的先丢：最后一条是刚记的。
    expect(PerfTrace.spans.last.name, 'span_${PerfTrace.maxSpans + 4}');
  });

  test('measure returns the value, and a failure is recorded and rethrown', () async {
    final value = await PerfTrace.measure('read', () async => 42, fields: (v) => {'value': v});
    expect(value, 42);
    expect(PerfTrace.spans.single.fields['value'], 42);

    await expectLater(
      PerfTrace.measure<int>('read', () async => throw StateError('nope\nsecond line')),
      throwsStateError,
    );
    expect(PerfTrace.spans.last.fields['error'], 'Bad state: nope');
  });

  test('text carries the boot line and one line per span', () {
    expect(PerfTrace.text(), isEmpty);
    PerfTrace.note('boot', 1);
    final lines = PerfTrace.text().split('\n');
    expect(lines.first, startsWith('boot '));
    expect(lines, hasLength(2));
  });
}
