import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:path/path.dart';
import 'package:skynet/skynet.dart';
import 'package:xdg_directories/xdg_directories.dart';
import 'package:ansicolor/ansicolor.dart';

AnsiPen greenBold = AnsiPen()..green(bold: true);
AnsiPen magenta = AnsiPen()..magenta();
AnsiPen red = AnsiPen()..red();

String directoryPath;

Map<String, Stream<List<int>>> fileStreams = {};
Map<String, int> lengths = {};

void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    exitWithHelp();
  }
  directoryPath = arguments.first;

  final dir = Directory(directoryPath);

  if (!dir.existsSync()) {
    print(red('Directory ${dir.path} does not exist!'));
    exit(1);
  }

  final configFile = File(join(configHome.path, 'skydeploy', 'auth.json'));

  if (!configFile.existsSync()) {
    await configFile.createSync(recursive: true);
  }
  print('Using config');
  print('Auth: ${configFile.path}');

  var config = {};

  try {
    config = json.decode(configFile.readAsStringSync());
  } catch (e, st) {}
  
  if (!config.containsKey('seed')) {
    final key = SkynetUser.generateSeed();
    config['seed'] = hex.encode(key);
    await configFile.writeAsStringSync(json.encode(config));
  }

  final skynetUser = SkynetUser.fromSeed(hex.decode(config['seed']));

  print('User: ${skynetUser.id}...');
  print('');

  print(
      'Uploading ${magenta(directoryPath)} to ${greenBold(SkynetConfig.host)}...');
  print('');

  processDirectory(dir);

  final skylink = await uploadDirectory(
    fileStreams,
    lengths,
    'web',
  );

  print('');
  print('Skylink: ${greenBold("sia://${skylink}")}');

  final datakey = 'project-${dir.absolute.path}';

  print('');

  print('Setting ${magenta('skyns://')} record...');
  print('Using datakey ${greenBold(datakey)}...');
  print('');

  SignedRegistryEntry existing;

  try {
    // fetch the current value to find out the revision
    final res = await getEntry(skynetUser, datakey);

    existing = res;

    print(
        'Revision ${existing.entry.revision} -> ${existing.entry.revision + 1}');
  } catch (e) {
    existing = null;

    print('Revision 1');
  }

  // build the registry value
  final rv = RegistryEntry(
    datakey: datakey,
    data: utf8.encode(skylink),
    revision: (existing?.entry?.revision ?? 0) + 1,
  );

  // sign it
  final sig = await skynetUser.sign(rv.hash());

  final srv = SignedRegistryEntry(signature: sig, entry: rv);

  // update the registry
  final updated = await setEntry(skynetUser, datakey, srv);

  if (updated) {
    final skynsRecord =
        'skyns://ed25519%3A${skynetUser.id}/${hex.encode(hashDatakey(datakey))}';

    print('');

    print(
        '${greenBold('Success!')} Please put this ${magenta('TXT')} record on your Handshake domain: ${greenBold(skynsRecord)}');
    print(
        'Hint: If you already used SkyDeploy in this project directory, the TXT record is most likely already set!');

    exit(0);
  } else {
    print(red('Something went wrong'));
  }
}

void processDirectory(Directory dir) {
  for (final entity in dir.listSync()) {
    if (entity is Directory) {
      processDirectory(entity);
    } else if (entity is File) {
      final file = entity;
      String path = file.path;

      path = path.substring(directoryPath.length);

      if (path.startsWith('/')) path = path.substring(1);

      print(path);

      lengths[path] = file.lengthSync();
      fileStreams[path] = file.openRead();
    }
  }
}

void exitWithHelp() {
  print(greenBold('SkyDeploy CLI v1.0.1'));

  print('');

  print('Usage: ' + magenta('skydeploy') + ' path/to/web/directory');

  exit(0);
}
