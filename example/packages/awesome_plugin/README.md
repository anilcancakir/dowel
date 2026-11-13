# awesome_plugin

A dowel plugin.

## Install

```bash
# In your Flutter app:
dart pub add awesome_plugin
dart run dowel plugin:install awesome_plugin
```

## Commands

- `dowel awesome_plugin:install`, install awesome_plugin
- `dowel awesome_plugin:uninstall`, uninstall awesome_plugin

## Authoring

Edit `install.yaml` to declare what gets published, injected, and configured.
Edit `lib/src/commands/install_command.dart` for procedural overrides.

See the [dowel plugin authoring guide](https://anilcancakir.com/dowel/docs/plugins).
