import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/core/env.dart';
import 'package:loopland/core/privacy.dart';
import 'package:loopland/core/providers.dart';
import 'package:loopland/run/location_source.dart';

void main() {
  tearDown(() {
    LaunchPrivacy.onAgreed = null;
    LaunchPrivacy.agreed = false;
  });

  test('SDK init and location wait for the first-launch privacy agreement', () async {
    final cache = MemoryCache();
    var inits = 0;
    LaunchPrivacy.onAgreed = () => inits++;
    final c = ProviderContainer(overrides: [kvCacheProvider.overrideWithValue(cache)]);
    addTearDown(c.dispose);

    expect(c.read(launchPrivacyProvider), isNull);
    await c.read(launchPrivacyProvider.notifier).load();
    expect(c.read(launchPrivacyProvider), isFalse);
    expect(inits, 0);
    // geolocator is not touched before consent.
    expect(await GeolocatorSource().ensurePermission(), LocationPermissionResult.denied);
    expect(await GeolocatorSource().current(), isNull);

    await c.read(launchPrivacyProvider.notifier).accept();
    expect(c.read(launchPrivacyProvider), isTrue);
    expect(inits, 1);
    expect(await cache.read(LaunchPrivacy.key), Env.privacyVersion);

    // Next launch: stored agreement → SDKs init right away.
    final c2 = ProviderContainer(overrides: [kvCacheProvider.overrideWithValue(cache)]);
    addTearDown(c2.dispose);
    await c2.read(launchPrivacyProvider.notifier).load();
    expect(c2.read(launchPrivacyProvider), isTrue);
    expect(inits, 2);

    // A new policy version asks again.
    await cache.write(LaunchPrivacy.key, '2000-01');
    await c2.read(launchPrivacyProvider.notifier).load();
    expect(c2.read(launchPrivacyProvider), isFalse);
  });
}
