import 'dart:convert';

import 'package:path/path.dart' as p;

import 'virtual_fs.dart';

/// Schema version of `.dowel/installed/<plugin>.json`.
///
/// Version 1 stores `stubHashes` under project-relative, forward-slash keys so
/// a record survives a moved checkout. A record without it predates that
/// format and is refused rather than read: its absolute keys would report
/// every file as unmanaged, and its dependency entries do not say whether the
/// dependency was the user's before the install.
const int installRecordVersion = 1;

/// Absolute path of the install record for [pluginName] under [projectRoot].
String installRecordPath(String projectRoot, String pluginName) {
  return p.join(projectRoot, '.dowel', 'installed', '$pluginName.json');
}

/// The `stubHashes` key for [absPath]: relative to [projectRoot], with forward
/// slashes on every platform so the record reads the same everywhere.
String installRecordKey(String projectRoot, String absPath) {
  return p.posix.joinAll(p.split(p.relative(absPath, from: projectRoot)));
}

/// Outcome of [readInstallRecord]: the decoded record, or why it was refused.
typedef InstallRecordRead = ({Map<String, dynamic>? record, String? problem});

/// Reads and validates the install record at [recordPath].
///
/// The record is untrusted input (anyone can edit `.dowel/`), so every shape
/// it can take maps to an answer: a missing file is `(null, null)`, a valid
/// one carries `record`, and anything else carries a one-line `problem` naming
/// the fix, with `record` null.
InstallRecordRead readInstallRecord(VirtualFs fs, String recordPath) {
  if (!fs.exists(recordPath)) return (record: null, problem: null);

  final Object? decoded;
  try {
    decoded = jsonDecode(fs.readAsString(recordPath));
  } on FormatException {
    return (record: null, problem: _refusal(recordPath, 'is not valid JSON'));
  }
  if (decoded is! Map<String, dynamic>) {
    return (
      record: null,
      problem: _refusal(recordPath, 'is not a JSON object'),
    );
  }

  final version = decoded['version'];
  if (version != installRecordVersion) {
    return (
      record: null,
      problem: _refusal(
        recordPath,
        version == null
            ? 'has no "version" (an older dowel wrote it)'
            : 'has version $version, this dowel reads $installRecordVersion',
      ),
    );
  }

  final hashes = decoded['stubHashes'];
  if (hashes is! Map ||
      hashes.keys.any((key) => key is! String || _isAbsoluteKey(key))) {
    return (
      record: null,
      problem: _refusal(
        recordPath,
        'does not store project-relative "stubHashes" keys',
      ),
    );
  }

  // Uninstall deletes the paths a record names, and the record is committed,
  // so a pull request can point it anywhere: refuse one that leaves the
  // project rather than reverse it.
  final ops = decoded['ops'];
  final paths = <Object?>[
    ...hashes.keys,
    if (ops is List)
      for (final op in ops.whereType<Map>()) ...<Object?>[
        op['targetPath'],
        op['sourcePath'],
      ],
  ];
  final escaping = paths.whereType<String>().where(
    (path) => !isInsideProject(path),
  );
  if (escaping.isNotEmpty) {
    return (
      record: null,
      problem: _refusal(
        recordPath,
        'names a path outside the project ("${escaping.first}")',
      ),
    );
  }

  return (record: decoded, problem: null);
}

/// Whether [path], resolved against the project root, names something inside
/// it: not absolute on any platform and not climbing out through `..`.
/// Backslashes count as separators so a record written on Windows is judged
/// the way Windows would resolve it.
bool isInsideProject(String path) {
  if (_isAbsoluteKey(path)) return false;
  const root = '/project';
  final resolved = p.posix.normalize(
    p.posix.join(root, path.replaceAll(r'\', '/')),
  );
  return p.posix.isWithin(root, resolved);
}

/// Whether [key] names an absolute path on any platform: a POSIX root, a
/// drive letter or a UNC prefix all tie the record to one checkout.
bool _isAbsoluteKey(String key) {
  return p.posix.isAbsolute(key) || p.windows.isAbsolute(key);
}

String _refusal(String recordPath, String reason) {
  return 'The install record $recordPath $reason. Re-run the install with '
      '--force to rewrite it.';
}
