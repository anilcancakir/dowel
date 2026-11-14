import '../console/dowel_context.dart';
import '../console/dowel_input.dart';
import '../console/dowel_output.dart';
import '../helpers/file_helper.dart';
import 'prompt_driver.dart';
import 'stub_driver.dart';
import 'virtual_fs.dart';

/// Dependency-injection container handed to every install operation in the
/// PluginInstaller DSL.
///
/// Composes (never inherits) [DowelContext] so command-side concerns
/// (input / output / VM client) stay reachable while the installer adds its
/// own four-way seam: [VirtualFs] for filesystem access, [PromptDriver] for
/// interactive prompts, [StubDriver] for template resolution, and a [clock]
/// callback for time-sensitive metadata (record timestamps, dry-run headers).
///
/// Two named constructors target the two consumption modes:
///
/// - [InstallContext.real] wires production drivers ([RealFs] /
///   [RealPromptDriver] / [RealStubDriver] / `() => DateTime.now()`) and
///   resolves [projectRoot] via [FileHelper.findProjectRoot] when not
///   supplied.
/// - [InstallContext.test] accepts every dependency explicitly so tests can
///   run the full installer lifecycle in-memory.
///
/// Every field is `final` + non-nullable so install operations can read
/// the context without null checks at every call site.
///
/// ## Usage
///
/// ```dart
/// // production
/// final ctx = InstallContext.real(dowelCtx);
/// final installer = PluginInstaller(ctx);
///
/// // tests
/// final ctx = InstallContext.test(
///   fs: InMemoryFs(),
///   prompt: FakePromptDriver(['y']),
///   stubs: FakeStubDriver({'config': '...'}),
///   clock: () => DateTime.utc(2025, 1, 1),
/// );
/// ```
final class InstallContext {
  /// Wires the production stack: [RealFs] for filesystem access,
  /// [RealPromptDriver] for stdin prompts, [RealStubDriver] for asset
  /// resolution, and `DateTime.now` as the clock source.
  ///
  /// When [projectRoot] is `null`, falls back to [FileHelper.findProjectRoot]
  /// from the current working directory so commands invoked via
  /// `dart run dowel ...` always pick up the right repository root.
  ///
  /// @param dowelContext  The already-constructed [DowelContext] handed
  ///                        to the active command's `handle()` method.
  /// @param projectRoot     Optional explicit override of the project root.
  /// @return A fully wired [InstallContext] ready for production install ops.
  InstallContext.real(DowelContext dowelContext, {String? projectRoot})
    : this._(
        dowelContext: dowelContext,
        fs: const RealFs(),
        prompt: const RealPromptDriver(),
        stubs: const RealStubDriver(),
        clock: DateTime.now,
        projectRoot: projectRoot ?? FileHelper.findProjectRoot(),
      );

  /// Wires a fully injectable [InstallContext] for tests.
  ///
  /// Every collaborator can be replaced. When [input] / [output] are absent
  /// the wrapping [DowelContext] is constructed as a bare context backed by
  /// an empty [MapInput] and a [BufferedOutput] so tests can introspect the
  /// captured output via `ctx.dowelContext.output as BufferedOutput`.
  ///
  /// @param fs           In-memory or stub [VirtualFs] implementation.
  /// @param prompt       Fake / recording [PromptDriver].
  /// @param stubs        Fake / fixture-backed [StubDriver].
  /// @param clock        Optional deterministic clock; defaults to
  ///                     [DateTime.now] when omitted.
  /// @param input        Optional pre-built [DowelInput]; defaults to an
  ///                     empty [MapInput].
  /// @param output       Optional pre-built [DowelOutput]; defaults to a
  ///                     [BufferedOutput] for assertions.
  /// @param projectRoot  Logical project root used by relative-path
  ///                     resolution; defaults to `/test`.
  /// @return A wired test context with all dependencies injectable.
  factory InstallContext.test({
    required VirtualFs fs,
    required PromptDriver prompt,
    required StubDriver stubs,
    DateTime Function()? clock,
    DowelInput? input,
    DowelOutput? output,
    String projectRoot = '/test',
  }) {
    final wrappedInput = input ?? MapInput(const <String, dynamic>{});
    final wrappedOutput = output ?? BufferedOutput();
    return InstallContext._(
      dowelContext: DowelContext.bare(wrappedInput, wrappedOutput),
      fs: fs,
      prompt: prompt,
      stubs: stubs,
      clock: clock ?? DateTime.now,
      projectRoot: projectRoot,
    );
  }

  /// Private canonical constructor; both [InstallContext.real] and
  /// [InstallContext.test] funnel through here to guarantee identical field
  /// initialisation semantics.
  InstallContext._({
    required this.dowelContext,
    required this.fs,
    required this.prompt,
    required this.stubs,
    required this.clock,
    required this.projectRoot,
  });

  /// The wrapping command context (input / output / optional VM client).
  /// Composed, not inherited, so install ops can reach the command surface
  /// without polluting the [InstallContext] API.
  final DowelContext dowelContext;

  /// Filesystem seam. Production wiring uses [RealFs]; tests typically pass
  /// an [InMemoryFs].
  final VirtualFs fs;

  /// Interactive-prompt seam. Wraps the static [Prompt] helper in production
  /// and a recording fake in tests.
  final PromptDriver prompt;

  /// Stub-template seam. Wraps the static `StubLoader` helper in production
  /// and a fixture-backed fake in tests.
  final StubDriver stubs;

  /// Clock callback used for any time-stamped metadata (e.g. the
  /// `installedAt` field in `.dowel/installed/<plugin>.json`).
  /// Injectable so tests can pin the time to a fixed value.
  final DateTime Function() clock;

  /// Absolute path to the consumer project root. Install ops resolve target
  /// paths relative to this directory.
  final String projectRoot;
}
