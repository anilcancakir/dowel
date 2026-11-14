/// dowel: a composable CLI framework and stdio MCP server for Dart and Flutter.
///
/// Single barrel entry. Every export names its symbols with `show`, except the
/// install manifest model and the install operations, which are exported whole.
/// The public surface is a deliberate list: what plugins extend or call, plus
/// the types those signatures expose. Anything else under `src/` is internal
/// and may change in a minor release.
///
/// dowel is framework-agnostic: framework generators (Magic's `make:*`) live
/// in the framework's own package as a `DowelServiceProvider`.
library;

// The argument parser types that `DowelCommand.configure` and `ArgvInput`
// expose, so a plugin needs no direct `args` dependency for them.
export 'package:args/args.dart' show ArgParser, ArgParserException, ArgResults;

// Console: application, command bases, boot mode, I/O, context, provider,
// registry and the collision errors the registry throws.
export 'src/console/command_boot.dart' show CommandBoot;
export 'src/console/command_signature.dart'
    show ArgumentSpec, CommandSignature, OptionSpec;
export 'src/console/dowel_application.dart' show DowelApplication;
export 'src/console/dowel_command.dart' show DowelCommand;
export 'src/console/dowel_command_collision_exception.dart'
    show DowelCommandCollisionException;
export 'src/console/dowel_context.dart' show DowelContext;
export 'src/console/dowel_generator_command.dart' show DowelGeneratorCommand;
export 'src/console/dowel_input.dart' show ArgvInput, DowelInput, MapInput;
export 'src/console/dowel_output.dart' show BufferedOutput, DowelOutput;
export 'src/console/dowel_registry.dart' show DowelRegistry;
export 'src/console/dowel_service_provider.dart' show DowelServiceProvider;
export 'src/console/process_alive.dart' show processAlive;
export 'src/console/prompt.dart' show Prompt;
export 'src/console/run_dowel.dart'
    show DelegateStrategy, WrapperExistsCheck, WrapperNameResolver, runDowel;
export 'src/console/string_helper.dart' show StringHelper;

// Helpers a plugin's own install command calls directly.
export 'src/helpers/config_editor.dart' show ConfigEditor;
export 'src/helpers/console_style.dart' show ConsoleStyle;
export 'src/helpers/file_helper.dart' show FileHelper;
export 'src/helpers/html_editor.dart' show HtmlEditor;
export 'src/helpers/json_editor.dart' show JsonEditor;
export 'src/helpers/main_dart_editor.dart' show MainDartEditor;
export 'src/helpers/platform_helper.dart' show PlatformHelper;
export 'src/helpers/plist_writer.dart' show PlistWriter;
export 'src/helpers/xcode_project_editor.dart' show XcodeProjectEditor;

// Session state, the VM Service client and in-app extension registration.
export 'src/extensions/register_extension_idempotent.dart'
    show registerExtensionIdempotent;
export 'src/state/state_file.dart' show StateFile, sessionOwnershipError;
export 'src/stubs/stub_loader.dart' show StubLoader;
export 'src/vm/extension_not_registered_exception.dart'
    show ExtensionNotRegisteredException;
export 'src/vm/vm_service_client.dart' show VmServiceClient;

// Builtin commands that plugins run in-process or build on.
export 'src/commands/hot_restart_command.dart' show HotRestartCommand;
export 'src/commands/install_command.dart' show InstallDowelCommand;
export 'src/commands/make_fast_cli_command.dart' show MakeFastCliCommand;
export 'src/commands/restart_command.dart' show RestartCommand;
export 'src/commands/start_command.dart'
    show
        CdpChromeBinaryResolver,
        CdpChromeNavigator,
        CdpChromeProber,
        CdpFifoMaker,
        CdpKillPid,
        CdpPortProbe,
        CdpProcessRunner,
        CdpProcessStarter,
        CdpVmServiceScraper,
        CdpWebServerReadyWaiter,
        StartCommand;
export 'src/commands/stop_command.dart' show StopCommand;
export 'src/commands/tinker_command.dart' show TinkerCommand;

// Installer: the fluent DSL, the manifest pipeline, the operation and result
// taxonomies, the driver and filesystem seams, and their exceptions.
export 'src/installer/android_intent_filter.dart'
    show AndroidIntentData, AndroidIntentFilter;
export 'src/installer/conflict_detector.dart'
    show ConflictDetector, FileConflict;
export 'src/installer/dowel_install_command.dart' show DowelInstallCommand;
export 'src/installer/install_context.dart' show InstallContext;
export 'src/installer/install_exception.dart'
    show InstallException, ManifestValidationException;
export 'src/installer/install_manifest.dart';
export 'src/installer/install_operation.dart';
export 'src/installer/install_transaction.dart'
    show
        InstallConflict,
        InstallDryRun,
        InstallError,
        InstallSuccess,
        TransactionResult;
export 'src/installer/manifest_installer.dart' show ManifestInstaller;
export 'src/installer/manifest_parser.dart' show ManifestParser;
export 'src/installer/plugin_installer.dart' show PluginInstaller;
export 'src/installer/prompt_driver.dart' show PromptDriver;
export 'src/installer/stub_driver.dart' show RealStubDriver, StubDriver;
export 'src/installer/virtual_fs.dart' show InMemoryFs, RealFs, VirtualFs;

// MCP: the tool descriptor a provider returns and the collision error the
// registry throws for it.
export 'src/mcp/mcp_tool_collision_exception.dart'
    show DowelMcpToolCollisionException;
export 'src/mcp/mcp_tool_descriptor.dart' show McpToolDescriptor;

// Tinker REPL hooks. An integration package fills `Tinker.autocompleteCorpus`,
// `classAliases` and `casters` from its host-side install entry.
export 'src/tinker/tinker.dart' show Tinker, TinkerCaster;
