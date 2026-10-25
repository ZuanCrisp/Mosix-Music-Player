import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/local_library_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/services/music_player_service.dart';
import 'package:mosix/services/network_storage_service.dart';
import 'package:mosix/services/network_storage_error.dart';
import 'package:mosix/services/network_certificate.dart';
import 'package:mosix/utils/nav_bar_inset.dart';
import 'package:mosix/widgets/app_sliver_header.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/widgets/app_action_button.dart';
import 'package:mosix/widgets/expressive_icon_button.dart';
import 'package:mosix/widgets/mornye_chrome.dart';
import 'package:mosix/widgets/settings_group.dart';

class NetworkStorageScreen extends ConsumerStatefulWidget {
  const NetworkStorageScreen({
    super.key,
    this.connection,
    this.path = '',
    this.service,
  });
  final NetworkConnection? connection;
  final String path;
  final NetworkStorageService? service;

  @override
  ConsumerState<NetworkStorageScreen> createState() =>
      _NetworkStorageScreenState();
}

class _NetworkStorageScreenState extends ConsumerState<NetworkStorageScreen> {
  NetworkStorageService get service =>
      widget.service ?? NetworkStorageService.instance;
  List<NetworkConnection> _connections = [];
  List<NetworkEntry> _entries = [];
  bool _loading = true;
  bool _failed = false;
  NetworkStorageError _failure = NetworkStorageError.unknown;
  bool _starting = false;
  bool _adding = false;
  bool _added = false;
  bool _selectingDestination = false;
  int _loadGeneration = 0;

  Future<void> _useForDownloads() async {
    final connection = widget.connection;
    if (connection == null || _selectingDestination) return;
    setState(() => _selectingDestination = true);
    try {
      final source = NetworkStorageService.source(connection.id, widget.path);
      await service.checkUploadAccess(source);
      if (!mounted) return;
      await ref
          .read(settingsProvider.notifier)
          .setNetworkDownloadFolder(
            source,
            '${connection.name}${widget.path.isEmpty ? '' : ' / ${widget.path}'}',
          );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${context.l10n.networkDownloadAccessFailed} ${_networkErrorMessage(context, classifyNetworkStorageError(error))}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _selectingDestination = false);
    }
  }

  Future<void> _addToLibrary() async {
    final connection = widget.connection;
    if (connection == null || _adding) return;
    setState(() => _adding = true);
    try {
      final library = ref.read(localLibraryProvider.notifier);
      if (ref.read(localLibraryProvider).isScanning) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.libraryScanning)));
        return;
      }
      final folder = widget.path
          .split('/')
          .where((s) => s.isNotEmpty)
          .lastOrNull;
      final source = await library.addSource(
        path: NetworkStorageService.source(connection.id, widget.path),
        displayName: folder == null
            ? connection.name
            : '${connection.name} / $folder',
      );
      if (!mounted) return;
      ref.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
      setState(() => _added = true);
      await library.startSourceScan(source.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _networkErrorMessage(context, classifyNetworkStorageError(error)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant NetworkStorageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection != widget.connection ||
        oldWidget.path != widget.path ||
        oldWidget.service != widget.service) {
      _added = false;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    bool isCurrent() => mounted && generation == _loadGeneration;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final connection = widget.connection;
      if (connection == null) {
        final connections = await service.connections();
        if (isCurrent()) _connections = connections;
      } else {
        final entries = await service.list(connection, widget.path);
        if (isCurrent()) _entries = entries;
      }
    } catch (error) {
      if (isCurrent()) {
        _failed = true;
        _failure = classifyNetworkStorageError(error);
      }
    } finally {
      if (isCurrent()) setState(() => _loading = false);
    }
  }

  Future<void> _edit([NetworkConnection? connection]) async {
    await Navigator.of(context).push(
      _networkRoute(
        context,
        builder: (_) =>
            _NetworkConnectionForm(service: service, connection: connection),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _open(NetworkConnection connection, [String path = '']) async {
    await Navigator.of(context).push(
      _networkRoute(
        context,
        builder: (_) => NetworkStorageScreen(
          connection: connection,
          path: path,
          service: service,
        ),
      ),
    );
  }

  Future<void> _play(NetworkEntry selected) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final connection = widget.connection!;
      final tracks = _entries.where((e) => e.audio).toList();
      final cover = _entries
          .where(
            (e) =>
                !e.directory &&
                const {
                  'cover.jpg',
                  'folder.jpg',
                  'front.jpg',
                  'cover.png',
                  'folder.png',
                }.contains(e.name.toLowerCase()),
          )
          .firstOrNull;
      final artwork = cover == null
          ? null
          : Uri.parse(
              await service.resolve(
                NetworkStorageService.source(connection.id, cover.path),
              ),
            );
      if (!mounted) return;
      await ref.read(musicPlayerControllerProvider).playAll([
        for (final entry in tracks)
          PlayableMedia(
            id: NetworkStorageService.source(connection.id, entry.path),
            source: NetworkStorageService.source(connection.id, entry.path),
            title: entry.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
            artist: connection.name,
            album:
                widget.path.split('/').where((p) => p.isNotEmpty).lastOrNull ??
                '',
            artUri: artwork?.toString(),
            networkArtworkSource: cover == null
                ? null
                : NetworkStorageService.source(connection.id, cover.path),
            format: entry.extension,
          ),
      ], initialIndex: tracks.indexOf(selected));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _networkErrorMessage(context, classifyNetworkStorageError(error)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = widget.connection;
    final isDownloadDestination =
        connection != null &&
        ref.watch(settingsProvider.select((s) => s.networkDownloadFolder)) ==
            NetworkStorageService.source(connection.id, widget.path);
    final title = connection == null
        ? context.l10n.networkStorage
        : widget.path.isEmpty
        ? connection.name
        : widget.path.split('/').where((p) => p.isNotEmpty).last;
    final visible = _entries.where((e) => e.directory || e.audio).toList();
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: title,
            actions: [
              if (connection == null)
                _NetworkIconAction(
                  tooltip: context.l10n.networkAddConnection,
                  onPressed: () => _edit(),
                  icon: Icons.add,
                  cupertinoIcon: CupertinoIcons.add,
                ),
              _NetworkIconAction(
                tooltip: context.l10n.networkRefresh,
                onPressed: _loading ? null : _load,
                icon: Icons.refresh,
                cupertinoIcon: CupertinoIcons.refresh,
              ),
            ],
          ),
          if (_loading || _starting)
            SliverToBoxAdapter(child: _NetworkProgress()),
          if (!_loading &&
              !_failed &&
              connection != null &&
              connection.protocol != NetworkProtocol.http)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppActionButton(
                      onPressed: _adding || _added ? null : _addToLibrary,
                      icon: Icon(
                        _added ? Icons.check : Icons.library_add_outlined,
                      ),
                      label: Text(
                        _added
                            ? context.l10n.networkLibraryAdded
                            : context.l10n.networkAddToLibrary,
                      ),
                      tonal: true,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.networkLibraryDescription,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    AppActionButton(
                      onPressed: _selectingDestination || isDownloadDestination
                          ? null
                          : _useForDownloads,
                      icon: Icon(
                        isDownloadDestination
                            ? Icons.check
                            : Icons.download_outlined,
                      ),
                      label: Text(
                        isDownloadDestination
                            ? context.l10n.networkDownloadSelected
                            : context.l10n.networkUseForDownloads,
                      ),
                      tonal: true,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.networkDownloadDescription,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_selectingDestination) const LinearProgressIndicator(),
                    if (_adding)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
            ),
          if (_failed)
            SliverToBoxAdapter(
              child: _NetworkMessage(
                icon: context.isMornye
                    ? CupertinoIcons.wifi_exclamationmark
                    : Icons.wifi_off_rounded,
                message: _networkErrorMessage(context, _failure),
                action: AppActionButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: Text(context.l10n.dialogRetry),
                  tonal: true,
                ),
              ),
            ),
          if (!_loading && !_failed && connection == null) ...[
            SliverToBoxAdapter(
              child: _NetworkMessage(
                icon: context.isMornye
                    ? CupertinoIcons.cloud
                    : Icons.dns_outlined,
                message: context.l10n.networkStorageDescription,
                action: AppActionButton(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add),
                  label: Text(context.l10n.networkAddConnection),
                ),
              ),
            ),
            if (_connections.isNotEmpty)
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.networkConnections,
                ),
              ),
            SliverList.builder(
              itemCount: _connections.length,
              itemBuilder: (context, index) {
                final c = _connections[index];
                return SettingsGroup(
                  children: [
                    SettingsItem(
                      icon: context.isMornye
                          ? CupertinoIcons.cloud
                          : Icons.dns_outlined,
                      showIconInMornye: true,
                      title: c.name,
                      subtitle:
                          '${_protocolLabel(c.protocol)} · ${c.root.host}',
                      onTap: () => _open(c),
                      showDivider: false,
                      trailing: _NetworkIconAction(
                        tooltip: context.l10n.networkEditConnection,
                        onPressed: () => _edit(c),
                        icon: Icons.edit_outlined,
                        cupertinoIcon: CupertinoIcons.pencil,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
          if (!_loading && !_failed && connection != null) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
                child: Text(
                  '${_protocolLabel(connection.protocol)} · ${connection.root.host}'
                  '\n/${widget.path}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (visible.isEmpty)
              SliverToBoxAdapter(
                child: _NetworkMessage(
                  icon: context.isMornye
                      ? CupertinoIcons.folder
                      : Icons.folder_open_rounded,
                  message: context.l10n.networkNoFiles,
                ),
              ),
            SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final entry = visible[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Material(
                    color: settingsGroupColor(context),
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(
                        index == 0
                            ? (context.isMornye
                                  ? 28
                                  : context.tokens.radiusCard)
                            : 0,
                      ),
                      bottom: Radius.circular(
                        index == visible.length - 1
                            ? (context.isMornye
                                  ? 28
                                  : context.tokens.radiusCard)
                            : 0,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SettingsItem(
                      icon: entry.directory
                          ? Icons.folder_outlined
                          : Icons.music_note,
                      showIconInMornye: true,
                      title: entry.name,
                      subtitle: entry.directory
                          ? null
                          : entry.extension.toUpperCase(),
                      showDivider: index != visible.length - 1,
                      trailing: entry.directory
                          ? null
                          : _NetworkIconAction(
                              tooltip: context.l10n.tooltipPlay,
                              icon: Icons.play_arrow_rounded,
                              cupertinoIcon: CupertinoIcons.play_fill,
                              onPressed: _starting ? null : () => _play(entry),
                            ),
                      onTap: _starting
                          ? null
                          : () => entry.directory
                                ? _open(connection, entry.path)
                                : _play(entry),
                    ),
                  ),
                );
              },
            ),
          ],
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}

class _NetworkConnectionForm extends StatefulWidget {
  const _NetworkConnectionForm({required this.service, this.connection});
  final NetworkStorageService service;
  final NetworkConnection? connection;
  @override
  State<_NetworkConnectionForm> createState() => _NetworkConnectionFormState();
}

class _NetworkConnectionFormState extends State<_NetworkConnectionForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.connection?.name);
  late final _address = TextEditingController(text: widget.connection?.address);
  late final _user = TextEditingController(text: widget.connection?.username);
  late final _password = TextEditingController(
    text: widget.connection?.password,
  );
  late final _domain = TextEditingController(text: widget.connection?.domain);
  late var _protocol = widget.connection?.protocol ?? NetworkProtocol.smb;
  late String? _trustedCertificate =
      widget.connection?.trustedCertificateSha256;
  late String? _trustedOrigin = widget.connection?.root.scheme == 'https'
      ? widget.connection!.root.origin
      : null;
  NetworkCertificateException? _pendingCertificate;
  bool _busy = false;
  bool _failed = false;
  NetworkStorageError _failure = NetworkStorageError.unknown;

  @override
  void dispose() {
    for (final controller in [_name, _address, _user, _password, _domain]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _failed = false;
      _pendingCertificate = null;
    });
    try {
      final c = NetworkConnection(
        id: widget.connection?.id ?? NetworkStorageService.newId(),
        name: _name.text.trim(),
        address: _address.text.trim(),
        protocol: _protocol,
        username: _user.text,
        password: _password.text,
        domain: _domain.text.trim(),
        trustedCertificateSha256:
            Uri.tryParse(_address.text.trim())?.scheme == 'https' &&
                Uri.parse(_address.text.trim()).origin == _trustedOrigin
            ? _trustedCertificate
            : null,
      );
      c.validate();
      await widget.service.list(c);
      await widget.service.save(c);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failure = classifyNetworkStorageError(error);
          _pendingCertificate = error is NetworkCertificateException
              ? error
              : null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await widget.service.remove(widget.connection!.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
          _failure = classifyNetworkStorageError(error);
        });
      }
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool secret = false,
    String? hint,
  }) {
    String? validate(String? value) =>
        required && (value == null || value.trim().isEmpty)
        ? context.l10n.extensionAccountRequiredValue
        : null;
    if (context.isMornye) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            CupertinoTextFormFieldRow(
              key: ValueKey(label),
              controller: controller,
              enabled: !_busy,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: false,
              placeholder: hint,
              padding: const EdgeInsets.symmetric(vertical: 10),
              style: Theme.of(context).textTheme.bodyLarge,
              validator: validate,
              textInputAction: TextInputAction.next,
            ),
            const Divider(height: 0.5),
          ],
        ),
      );
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          Semantics(
            label: label,
            child: TextFormField(
              key: ValueKey(label),
              controller: controller,
              enabled: !_busy,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: false,
              cursorColor: colors.primary,
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: hint,
                filled: true,
                fillColor: theme.brightness == Brightness.dark
                    ? Color.alphaBlend(
                        Colors.white.withValues(alpha: 0.05),
                        colors.surface,
                      )
                    : colors.surface,
                isDense: true,
                border: border,
                enabledBorder: border,
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: colors.primary, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 15,
                ),
              ),
              validator: validate,
              textInputAction: TextInputAction.next,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: CustomScrollView(
      slivers: [
        AppSliverHeader.page(
          title: widget.connection == null
              ? context.l10n.networkAddConnection
              : context.l10n.networkEditConnection,
        ),
        SliverToBoxAdapter(
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsSectionHeader(title: context.l10n.networkProtocol),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AbsorbPointer(
                    absorbing: _busy,
                    child: context.isMornye
                        ? MornyeSegmentedControl(
                            labels: NetworkProtocol.values
                                .map(_protocolLabel)
                                .toList(),
                            selectedIndex: _protocol.index,
                            onChanged: (index) => setState(
                              () => _protocol = NetworkProtocol.values[index],
                            ),
                          )
                        : Row(
                            children: [
                              for (final protocol in NetworkProtocol.values)
                                Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.only(
                                      right: protocol == NetworkProtocol.http
                                          ? 0
                                          : 8,
                                    ),
                                    child: SettingsChoiceChip(
                                      label: protocol == NetworkProtocol.http
                                          ? 'HTTP(S)'
                                          : _protocolLabel(protocol),
                                      isSelected: _protocol == protocol,
                                      onTap: () =>
                                          setState(() => _protocol = protocol),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
                SettingsSectionHeader(title: context.l10n.networkServer),
                SettingsGroup(
                  children: [
                    _field(
                      _name,
                      context.l10n.networkConnectionName,
                      required: true,
                    ),
                    _field(
                      _address,
                      context.l10n.networkAddress,
                      required: true,
                      hint: _protocol == NetworkProtocol.smb
                          ? 'smb://server/Music/'
                          : 'https://server/music/',
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
                SettingsSectionHeader(title: context.l10n.networkCredentials),
                SettingsGroup(
                  children: [
                    _field(_user, context.l10n.networkUsername),
                    _field(
                      _password,
                      context.l10n.networkPassword,
                      secret: true,
                    ),
                    if (_protocol == NetworkProtocol.smb)
                      _field(_domain, context.l10n.networkDomain),
                    const SizedBox(height: 12),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    context.l10n.networkStorageDescription,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_failed)
                  _NetworkMessage(
                    icon: context.isMornye
                        ? CupertinoIcons.exclamationmark_circle
                        : Icons.error_outline,
                    message: switch (_pendingCertificate) {
                      final certificate? =>
                        '${context.l10n.networkCertificatePrompt}\n\n'
                            '${certificate.origin}\nSHA-256:\n'
                            '${certificate.fingerprint}',
                      null => _networkErrorMessage(context, _failure),
                    },
                  ),
                if (_pendingCertificate != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                    child: AppActionButton(
                      onPressed: _busy
                          ? null
                          : () {
                              final certificate = _pendingCertificate!;
                              _trustedCertificate = certificate.fingerprint;
                              _trustedOrigin = certificate.origin;
                              _save();
                            },
                      icon: const Icon(Icons.verified_user_outlined),
                      label: Text(context.l10n.networkTrustCertificate),
                    ),
                  ),
                if (_busy) _NetworkProgress(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                  child: AppActionButton(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.check),
                    label: Text(context.l10n.networkConnectSave),
                  ),
                ),
                if (widget.connection != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    child: context.isMornye
                        ? CupertinoButton(
                            onPressed: _busy ? null : _remove,
                            child: Text(
                              context.l10n.networkRemoveConnection,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          )
                        : TextButton.icon(
                            onPressed: _busy ? null : _remove,
                            icon: const Icon(Icons.link_off),
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.error,
                            ),
                            label: Text(context.l10n.networkRemoveConnection),
                          ),
                  ),
              ],
            ),
          ),
        ),
        const NavBarSliverSpacer(),
      ],
    ),
  );
}

PageRoute<void> _networkRoute(
  BuildContext context, {
  required WidgetBuilder builder,
}) => context.isMornye
    ? CupertinoPageRoute<void>(builder: builder)
    : MaterialPageRoute<void>(builder: builder);

String _protocolLabel(NetworkProtocol protocol) => switch (protocol) {
  NetworkProtocol.smb => 'SMB',
  NetworkProtocol.webdav => 'WebDAV',
  NetworkProtocol.http => 'HTTP / HTTPS',
};

String _networkErrorMessage(BuildContext context, NetworkStorageError error) =>
    switch (error) {
      NetworkStorageError.unreachable => context.l10n.networkErrorUnreachable,
      NetworkStorageError.timeout => context.l10n.networkErrorTimeout,
      NetworkStorageError.authentication =>
        context.l10n.networkErrorAuthentication,
      NetworkStorageError.permission => context.l10n.networkErrorPermission,
      NetworkStorageError.missingShare => context.l10n.networkErrorShare,
      NetworkStorageError.incompatible => context.l10n.networkErrorProtocol,
      NetworkStorageError.invalidAddress => context.l10n.networkErrorAddress,
      NetworkStorageError.certificate => context.l10n.networkErrorCertificate,
      NetworkStorageError.unknown => context.l10n.networkConnectionError,
    };

class _NetworkIconAction extends StatelessWidget {
  const _NetworkIconAction({
    required this.tooltip,
    required this.icon,
    required this.cupertinoIcon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final IconData cupertinoIcon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => context.isMornye
      ? Tooltip(
          message: tooltip,
          child: CupertinoButton(
            onPressed: onPressed,
            padding: const EdgeInsets.all(12),
            child: Icon(
              cupertinoIcon,
              size: 24,
              semanticLabel: tooltip,
              color: onPressed == null
                  ? Theme.of(context).disabledColor
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        )
      : ExpressiveIconButton(
          icon: Icon(icon),
          tooltip: tooltip,
          onPressed: onPressed,
        );
}

class _NetworkProgress extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Center(
      child: context.isMornye
          ? const CupertinoActivityIndicator()
          : const CircularProgressIndicator(),
    ),
  );
}

class _NetworkMessage extends StatelessWidget {
  const _NetworkMessage({
    required this.icon,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.isMornye
                        ? MornyeTheme.controlFill(context)
                        : scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(
                      context.isMornye ? 16 : 24,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Icon(
                      icon,
                      size: 32,
                      color: context.isMornye
                          ? scheme.primary
                          : scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              if (action != null) ...[const SizedBox(height: 24), action!],
            ],
          ),
        ),
      ],
    );
  }
}
