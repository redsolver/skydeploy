// @dart=2.9

import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:path/path.dart';
import 'package:skynet/skynet.dart';
import 'package:skynet/src/registry_classes.dart';
import 'package:skynet/src/crypto.dart';
import 'package:xdg_directories/xdg_directories.dart';
import 'package:ansicolor/ansicolor.dart';
import 'package:skynet/src/utils/convert.dart';

AnsiPen greenBold = AnsiPen()..green(bold: true);
AnsiPen magenta = AnsiPen()..magenta();
AnsiPen red = AnsiPen()..red();
AnsiPen gray = AnsiPen()..gray();

String directoryPath;

Map<String, Stream<List<int>>> fileStreams = {};
Map<String, int> lengths = {};

var client = SkynetClient();

void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    exitWithHelp();
  }

  String confDatakey;

  List<String> tryFiles;
  Map errorPages;

  final localConfigFile = File('skydeploy.json');

  if (localConfigFile.existsSync()) {
    final key = arguments.first;
    final data = json.decode(localConfigFile.readAsStringSync());

    if (!data.containsKey(key)) {
      throw 'Deploy profile "$key" not found in skydeploy.json file';
    }

    print('Using deploy profile "$key" from skydeploy.json file...');

    final conf = data[key];

    directoryPath = canonicalize(conf['dir']);
    confDatakey = conf['datakey'];
    tryFiles = conf['tryFiles']?.cast<String>();
    errorPages = conf['errorPages'];
  } else {
    directoryPath = canonicalize(arguments.first);
  }

  final dir = Directory(directoryPath);

  String datakey = confDatakey ?? 'project-${dir.absolute.path}';

  if (!dir.existsSync()) {
    print(red('Directory ${dir.path} does not exist!'));
    exit(1);
  }
  final configDir = Directory(
    join(
      Platform.isWindows ? Platform.environment['homepath'] : configHome.path,
      'skydeploy',
    ),
  );

  final oldConfigFile = File(
    join(
      configDir.path,
      'auth.json',
    ),
  );

  final configFile = File(
    join(
      configDir.path,
      'config.json',
    ),
  );

  if (!configFile.existsSync()) {
    configFile.createSync(recursive: true);
    if (oldConfigFile.existsSync()) {
      configFile.writeAsBytesSync(oldConfigFile.readAsBytesSync());
    }
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

  client = SkynetClient(portal: config['portal'], cookie: config['cookie']);

  final skynetUser =
      await SkynetUser.createFromSeedAsync(hex.decode(config['seed']));

  print('User: ${skynetUser.id}...');
  print('');

  print(
      'Uploading ${magenta(directoryPath)} to ${greenBold(client.portalHost)}...');
  print('');

  processDirectory(dir);

  final skylink = await client.upload.uploadDirectory(
    fileStreams,
    lengths,
    'web',
    tryFiles: tryFiles,
    errorPages: errorPages,
    /*   errorPages: {
      '404': '/404.html',
    }, */
  );

  print('');
  print('Static Skylink: ${greenBold("sia://${skylink}")}');

  print('');

  print('Setting ${magenta('Skylink v2')}...');
  print('Using datakey ${greenBold(datakey)}...');
  print('');

  SignedRegistryEntry existing;

  try {
    // fetch the current value to find out the revision
    final res = await client.registry.getEntry(skynetUser, datakey);

    existing = res;

    print(
        'Revision ${existing.entry.revision} -> ${existing.entry.revision + 1}');
  } catch (e) {
    existing = null;

    print('Revision 1');
  }

  // update the registry
  final updated = await client.registry.setEntry(
      skynetUser,
      datakey,
      convertSkylinkToUint8List(
        skylink,
      ));

  if (updated) {
    final skylinkV2 = 'sia://' +
        client.registry.getEntryLink(
          skynetUser.id,
          datakey,
        );
    /* final skynsRecord =
        'skyns://ed25519%3A${skynetUser.id}/${hex.encode(hashDatakey(datakey))}'; */

    print('');

    print(
        '${greenBold('Success!')} Please put this ${magenta('TXT')} record on your Handshake domain: ${greenBold(skylinkV2)}');

    // print('Deprecated skyns:// record: ${gray(skynsRecord)}');
    print(
        'Hint: If you already used SkyDeploy in this project directory, the TXT record is most likely already set!');
    print('');

    final url =
        'https://${encodeSkylinkToBase32(convertSkylinkToUint8List(skylinkV2.substring(6)))}.${client.portalHost}';

    print(
        'You can directly access your uploaded directory using this link: ${greenBold(url)}');
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

      path = path.substring(directoryPath.length).replaceAll('\\', '/');

      if (path.startsWith('/')) path = path.substring(1);

      print(path);

      lengths[path] = file.lengthSync();
      fileStreams[path] = file.openRead();
    }
  }
}

void exitWithHelp() {
  print(greenBold('SkyDeploy CLI v2.1.0'));

  print('');

  print('Usage: ' + magenta('skydeploy') + ' path/to/web/directory');

  exit(0);
}
