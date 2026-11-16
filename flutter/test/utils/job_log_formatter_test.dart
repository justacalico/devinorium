import 'package:devinorium_frontend/utils/job_log_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JobLogFormatter', () {
    test('normalises line endings', () {
      expect(JobLogFormatter.normalize('a\r\nb\rc'), 'a\nb\nc');
    });

    test('strips SGR ANSI colour codes', () {
      expect(
        JobLogFormatter.normalize('\u{001B}[31mred\u{001B}[0m text'),
        'red text',
      );
    });

    test('strips multi-code ANSI escape sequences', () {
      expect(
        JobLogFormatter.normalize('\u{001B}[1;31;40mbold red\u{001B}[0m'),
        'bold red',
      );
    });

    test('strips erase-line ANSI codes', () {
      expect(JobLogFormatter.normalize('line\u{001B}[K'), 'line');
    });

    test('strips private CSI sequences like cursor hide', () {
      expect(
        JobLogFormatter.normalize('\u{001B}[?25lshow\u{001B}[?25h'),
        'show',
      );
    });

    test('strips OSC terminal title sequences', () {
      expect(
        JobLogFormatter.normalize('\u{001B}]0;my title\u0007text'),
        'text',
      );
    });

    test('strips OSC sequences terminated with ESC backslash', () {
      expect(
        JobLogFormatter.normalize('\u{001B}]0;my title\u{001B}\\text'),
        'text',
      );
    });

    test('strips CSI sequences with private parameter characters', () {
      expect(
        JobLogFormatter.normalize('\u{001B}[>4;2mtext\u{001B}[4:3m'),
        'text',
      );
    });

    test('strips an unterminated escape truncated at the end', () {
      expect(
        JobLogFormatter.normalize('log line\u{001B}]8;;https://x'),
        'log line',
      );
      expect(JobLogFormatter.normalize('log line\u{001B}[31'), 'log line');
      expect(JobLogFormatter.normalize('log line\u{001B}'), 'log line');
    });

    test('strips a truncated CSI that ends on an intermediate byte', () {
      const text = 'ok[1;38;5;';
      expect(JobLogFormatter.normalize(text), 'ok');
      const spaced = 'ok[1;38;5 ';
      expect(JobLogFormatter.normalize(spaced), 'ok');
    });

    test('truncates to the last N characters when maxLength is set', () {
      final input = 'a' * 100;
      final result = JobLogFormatter.normalize(input, maxLength: 10);
      expect(result, startsWith('... (log truncated'));
      expect(result, endsWith('a' * 10));
    });
  });
}
