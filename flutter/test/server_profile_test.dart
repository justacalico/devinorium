import 'package:devinorium_frontend/servers/server_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerProfile', () {
    test('generateId produces a 16-character string', () {
      final id = ServerProfile.generateId();
      expect(id.length, 16);
      expect(RegExp(r'^[A-Za-z0-9]{16}$').hasMatch(id), isTrue);
    });

    test('two generated ids are different', () {
      final a = ServerProfile.generateId();
      final b = ServerProfile.generateId();
      expect(a, isNot(b));
    });

    test('copyWith creates a new profile preserving unchanged values', () {
      final p = ServerProfile(
        id: 'a',
        label: 'old',
        baseUrl: 'http://old',
        token: 't',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      final updated = p.copyWith(label: 'new', token: 't2');
      expect(updated.id, 'a');
      expect(updated.label, 'new');
      expect(updated.baseUrl, 'http://old');
      expect(updated.token, 't2');
      expect(updated.username, 'u');
      expect(updated.isPrimary, isTrue);
    });

    test('round-trips through JSON', () {
      final p = ServerProfile(
        id: 'abc',
        label: 'home',
        baseUrl: 'http://localhost:7878',
        token: 'tok',
        username: 'owner',
        createdAt: DateTime(2024, 1, 2, 3, 4, 5).toUtc(),
        isPrimary: false,
      );
      final json = p.toJson();
      final restored = ServerProfile.fromJson(json);
      expect(restored.id, p.id);
      expect(restored.label, p.label);
      expect(restored.baseUrl, p.baseUrl);
      expect(restored.token, p.token);
      expect(restored.username, p.username);
      expect(restored.createdAt, p.createdAt);
      expect(restored.isPrimary, p.isPrimary);
    });
  });
}
