import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/run/device.dart';

void main() {
  const pkg = 'com.loopland.app';
  test('multi-open heuristic from the private data directory', () {
    expect(multiOpenFromDataDir('/data/user/0/$pkg/files', pkg), isFalse);
    expect(multiOpenFromDataDir('/data/data/$pkg/files', pkg), isFalse);
    expect(multiOpenFromDataDir('/mnt/expand/1234-abcd/user/0/$pkg/files', pkg), isFalse);
    // MIUI / ColorOS 双开, Samsung Dual Messenger
    expect(multiOpenFromDataDir('/data/user/999/$pkg/files', pkg), isTrue);
    expect(multiOpenFromDataDir('/data/user/95/$pkg/files', pkg), isTrue);
    // VirtualApp-style containers (平行空间 / 多开分身)
    expect(multiOpenFromDataDir('/data/user/0/io.va.exposed/virtual/data/user/0/$pkg/files', pkg), isTrue);
    expect(multiOpenFromDataDir('/data/data/com.lbe.parallel/parallel/0/$pkg', pkg), isTrue);
    // Unknown layout → no claim
    expect(multiOpenFromDataDir('/var/mobile/Containers/Data/Application/X', pkg), isFalse);
  });
}
