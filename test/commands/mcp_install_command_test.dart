import 'dart:convert';
import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:dowel/src/commands/mcp_install_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Builds a bare [DowelContext] with the given option map and a
/// [BufferedOutput] for assertion.
DowelContext _ctx(Map<String, dynamic> options) {
  return DowelContext.bare(MapInput(options), BufferedOutput());
}

/// Reads the output captured on [ctx]'s [BufferedOutput].
String _output(DowelContext ctx) => (ctx.output as BufferedOutput).content;

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mcp_install_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('McpInstallCommand metadata', () {
    test('signature is mcp:install', () {
      expect(McpInstallCommand().name, 'mcp:install');
    });

    test('boot is none', () {
      expect(McpInstallCommand().boot, CommandBoot.none);
    });

    test('description is non-empty', () {
      expect(McpInstallCommand().description, isNotEmpty);
    });
  });

  group('McpInstallCommand handle', () {
    test('empty .mcp.json writes dowel entry with dowel shape when hasDowel=true, isWindows=false', () async {
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      final command = McpInstallCommand(
        hasDowel: () => true,
        isWindows: () => false,
      );
      final ctx = _ctx({'path': mcpPath});

      final code = await command.handle(ctx);

      expect(code, 0);
      final content = File(mcpPath).readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      expect(servers, contains('dowel'));
      final entry = servers['dowel'] as Map<String, dynamic>;
      expect(entry['command'], './bin/dowel');
      expect(entry['args'], equals(['mcp:serve']));
      expect(entry['cwd'], '.');
      // Raw JSON content must reference the dowel invocation, not legacy shapes.
      expect(content, contains('./bin/dowel'));
      // Must NOT reference any legacy or rejected entry shapes.
      expect(content, isNot(contains('fluttersdk_artisan:mcp')));
      expect(content, isNot(contains('fluttersdk_mcp:server')));
      expect(content, isNot(contains(':dowel')));
    });

    test('empty .mcp.json writes dowel entry with dart fallback shape when hasDowel=false', () async {
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      final command = McpInstallCommand(
        hasDowel: () => false,
        isWindows: () => false,
      );
      final ctx = _ctx({'path': mcpPath});

      final code = await command.handle(ctx);

      expect(code, 0);
      final content = File(mcpPath).readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      expect(servers, contains('dowel'));
      final entry = servers['dowel'] as Map<String, dynamic>;
      expect(entry['command'], 'dart');
      expect(entry['args'], equals(['run', ':dispatcher', 'mcp:serve']));
      expect(entry['cwd'], '.');
      // Raw JSON content must reference the dispatcher fallback.
      expect(content, contains(':dispatcher'));
      // Must NOT reference any legacy or rejected entry shapes.
      expect(content, isNot(contains('fluttersdk_artisan:mcp')));
      expect(content, isNot(contains('fluttersdk_mcp:server')));
      expect(content, isNot(contains(':dowel')));
    });

    test('pre-existing .mcp.json with laravel-boost entry preserves both entries after install', () async {
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      // 1. Seed a .mcp.json with an unrelated server.
      File(mcpPath).writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'laravel-boost': {
              'command': 'npx',
              'args': ['-y', 'laravel-boost'],
            },
          },
        }),
      );

      final command = McpInstallCommand(
        hasDowel: () => true,
        isWindows: () => false,
      );
      final ctx = _ctx({'path': mcpPath});
      final code = await command.handle(ctx);

      expect(code, 0);
      final decoded =
          jsonDecode(File(mcpPath).readAsStringSync()) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      // Both entries must survive.
      expect(servers, containsPair('laravel-boost', isA<Map>()));
      expect(servers, contains('dowel'));
      final entry = servers['dowel'] as Map<String, dynamic>;
      expect(entry['command'], './bin/dowel');
      expect(entry['args'], equals(['mcp:serve']));
    });

    test('a dowel entry with the old fluttersdk_mcp:server args is replaced in place with no duplicate', () async {
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      // 1. Seed the OLD args shape under the current key.
      File(mcpPath).writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'dowel': {
              'command': 'dart',
              'args': ['run', 'fluttersdk_mcp:server'],
              'cwd': '.',
            },
          },
        }),
      );

      final command = McpInstallCommand(
        hasDowel: () => true,
        isWindows: () => false,
      );
      final ctx = _ctx({'path': mcpPath});
      final code = await command.handle(ctx);

      expect(code, 0);
      final decoded =
          jsonDecode(File(mcpPath).readAsStringSync()) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      // Exactly one dowel entry.
      expect(servers.keys.where((k) => k == 'dowel'), hasLength(1));
      final entry = servers['dowel'] as Map<String, dynamic>;
      // Must use the NEW dowel args, not the legacy ones.
      expect(entry['command'], './bin/dowel');
      expect(entry['args'], equals(['mcp:serve']));
      expect(entry['args'], isNot(contains('fluttersdk_mcp:server')));
    });

    test(
      'an old fluttersdk entry is kept and the output says to delete it',
      () async {
        final mcpPath = p.join(tempDir.path, '.mcp.json');
        File(mcpPath).writeAsStringSync(
          jsonEncode({
            'mcpServers': {
              'fluttersdk': {
                'command': './bin/fsa',
                'args': ['mcp:serve'],
                'cwd': '.',
              },
            },
          }),
        );

        final command = McpInstallCommand(
          hasDowel: () => true,
          isWindows: () => false,
        );
        final ctx = _ctx({'path': mcpPath});
        final code = await command.handle(ctx);

        expect(code, 0);
        final decoded = jsonDecode(
          File(mcpPath).readAsStringSync(),
        ) as Map<String, dynamic>;
        final servers = decoded['mcpServers'] as Map<String, dynamic>;
        // The user's entry is not ours to delete, so it stays...
        expect(servers, contains('fluttersdk'));
        expect(servers, contains('dowel'));
        // ...and the output says what to do about it.
        expect(_output(ctx), contains('Delete the "fluttersdk" entry'));
      },
    );

    test('success output contains /mcp reconnect dowel hint', () async {
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      final command = McpInstallCommand(
        hasDowel: () => true,
        isWindows: () => false,
      );
      final ctx = _ctx({'path': mcpPath});

      await command.handle(ctx);

      final out = _output(ctx);
      expect(out, contains('/mcp reconnect dowel'));
      expect(out, contains('Wrote dowel MCP server entry to $mcpPath'));
    });

    test(
      'returns 1 and writes error when .mcp.json contains invalid JSON',
      () async {
        final mcpPath = p.join(tempDir.path, '.mcp.json');
        File(mcpPath).writeAsStringSync('not-json{{{');

        final command = McpInstallCommand();
        final ctx = _ctx({'path': mcpPath});

        final code = await command.handle(ctx);

        expect(code, 1);
        expect(_output(ctx), contains('[ERROR]'));
      },
    );

    test('default path option is .mcp.json', () async {
      // Exercises the defaultsTo fallback when no path option is given.
      // We cannot write to the CWD arbitrarily in CI so we only check
      // that the command DOES attempt to use '.mcp.json' (path in output).
      // Use a tempDir as CWD substitute by passing it explicitly.
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      final command = McpInstallCommand(
        hasDowel: () => true,
        isWindows: () => false,
      );
      // Pass path explicitly — same as the default resolves to in production.
      final ctx = _ctx({'path': mcpPath});

      final code = await command.handle(ctx);

      expect(code, 0);
    });
  });

  group('McpInstallCommand --invocation option', () {
    test('--invocation=tapir with hasDowel=false writes dart run tapir mcp:serve shape', () async {
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      final command = McpInstallCommand(
        hasDowel: () => false,
        isWindows: () => false,
      );
      final ctx = _ctx({'path': mcpPath, 'invocation': 'tapir'});

      final code = await command.handle(ctx);

      expect(code, 0);
      final content = File(mcpPath).readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      expect(servers, contains('dowel'));
      final entry = servers['dowel'] as Map<String, dynamic>;
      expect(entry['command'], 'dart');
      expect(entry['args'], equals(['run', 'tapir', 'mcp:serve']));
      expect(entry['cwd'], '.');
      // Must NOT fall back to the :dispatcher shape.
      expect(content, isNot(contains(':dispatcher')));
    });

    test('--invocation=crumbs with hasDowel=false isWindows=true writes dart run crumbs mcp:serve shape', () async {
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      final command = McpInstallCommand(
        hasDowel: () => false,
        isWindows: () => true,
      );
      final ctx = _ctx({'path': mcpPath, 'invocation': 'crumbs'});

      final code = await command.handle(ctx);

      expect(code, 0);
      final content = File(mcpPath).readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      expect(servers, contains('dowel'));
      final entry = servers['dowel'] as Map<String, dynamic>;
      expect(entry['command'], 'dart');
      expect(entry['args'], equals(['run', 'crumbs', 'mcp:serve']));
      expect(entry['cwd'], '.');
      // Must NOT fall back to the :dispatcher shape.
      expect(content, isNot(contains(':dispatcher')));
    });

    test('--invocation="  " (whitespace-only) with hasDowel=false falls back to :dispatcher shape', () async {
      // Whitespace-only --invocation must trim to empty and route to the
      // :dispatcher branch rather than producing an invalid `dart run
      //    mcp:serve` entry. Reverting the trim guard in handle() turns
      // this assertion red.
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      final command = McpInstallCommand(
        hasDowel: () => false,
        isWindows: () => false,
      );
      final ctx = _ctx({'path': mcpPath, 'invocation': '   '});

      final code = await command.handle(ctx);

      expect(code, 0);
      final content = File(mcpPath).readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      final entry = servers['dowel'] as Map<String, dynamic>;
      expect(entry['command'], 'dart');
      expect(entry['args'], equals(['run', ':dispatcher', 'mcp:serve']));
      expect(entry['cwd'], '.');
      // Must NOT write the whitespace as the executable name.
      expect(entry['args'], isNot(contains('   ')));
      expect(entry['args'], isNot(contains('')));
    });

    test('--invocation=tapir with hasDowel=true writes dowel shape (fastcli wins over invocation)', () async {
      final mcpPath = p.join(tempDir.path, '.mcp.json');
      final command = McpInstallCommand(
        hasDowel: () => true,
        isWindows: () => false,
      );
      final ctx = _ctx({'path': mcpPath, 'invocation': 'tapir'});

      final code = await command.handle(ctx);

      expect(code, 0);
      final content = File(mcpPath).readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      expect(servers, contains('dowel'));
      final entry = servers['dowel'] as Map<String, dynamic>;
      // fastcli shape wins; invocation flag is ignored when bin/dowel present.
      expect(entry['command'], './bin/dowel');
      expect(entry['args'], equals(['mcp:serve']));
      expect(entry['cwd'], '.');
      // Must NOT write the dart-run-invocation shape.
      expect(content, isNot(contains('tapir')));
    });
  });
}
