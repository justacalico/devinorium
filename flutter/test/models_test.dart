import 'package:devinorium_frontend/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('User', () {
    test('parses provider_id with default fallback', () {
      final user = User.fromJson({
        'id': 1,
        'username': 'owner',
        'role': 'user',
        'totp_enabled': false,
      });
      expect(user.providerId, 'devin-cli');
    });

    test('parses explicit provider_id', () {
      final user = User.fromJson({
        'id': 1,
        'username': 'owner',
        'role': 'user',
        'totp_enabled': false,
        'provider_id': 'devin-cli',
      });
      expect(user.providerId, 'devin-cli');
    });

    test('copyWith updates providerId', () {
      final user = User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        providerId: 'devin-cli',
      );
      final updated = user.copyWith(providerId: 'other');
      expect(updated.providerId, 'other');
    });
  });

  group('ProviderInfo', () {
    test('parses id and name', () {
      final p = ProviderInfo.fromJson({
        'id': 'devin-cli',
        'name': 'Devin CLI',
      });
      expect(p.id, 'devin-cli');
      expect(p.name, 'Devin CLI');
    });

    test('falls back to id when name is missing', () {
      final p = ProviderInfo.fromJson({'id': 'devin-cli'});
      expect(p.name, 'devin-cli');
    });
  });
}
