import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/widgets/keynest_search_bar.dart';
import 'package:keynest/ui/widgets/keynest_settings_tile.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:provider/provider.dart';

class RecordTypeItem {
  const RecordTypeItem({
    required this.name,
    required this.icon,
    required this.category,
    required this.templateFields,
  });

  final String name;
  final IconData icon;
  final String category;
  final Map<String, bool> templateFields; // field name -> isProtected
}

class AddRecordCatalogScreen extends StatefulWidget {
  const AddRecordCatalogScreen({
    super.key,
    this.initialFile,
    this.initialGroup,
  });

  final KdbxFile? initialFile;
  final KdbxGroup? initialGroup;

  static Route<void> route({
    KdbxFile? initialFile,
    KdbxGroup? initialGroup,
  }) => KeyNestPlatform.isDesktopOrWeb
      ? KeyNestDesktopDialogRoute<void>(
          settings: const RouteSettings(name: '/addRecord'),
          maxWidth: 520,
          maxHeight: 600,
          builder: (context) => AddRecordCatalogScreen(
            initialFile: initialFile,
            initialGroup: initialGroup,
          ),
        )
      : KeyNestPushPageRoute(
          settings: const RouteSettings(name: '/addRecord'),
          builder: (context) => AddRecordCatalogScreen(
            initialFile: initialFile,
            initialGroup: initialGroup,
          ),
        );

  @override
  State<AddRecordCatalogScreen> createState() => _AddRecordCatalogScreenState();
}

class _AddRecordCatalogScreenState extends State<AddRecordCatalogScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  static const List<RecordTypeItem> allRecordTypes = [
    // SECURITY
    RecordTypeItem(
      name: 'Wi-Fi Password',
      icon: Icons.wifi_rounded,
      category: 'SECURITY',
      templateFields: {
        'Network SSID': false,
        'Password': true,
        'Security Type': false,
        'Router IP / Admin URL': false,
        'Hidden Network': false,
      },
    ),
    RecordTypeItem(
      name: 'SSH Key',
      icon: Icons.terminal_rounded,
      category: 'SECURITY',
      templateFields: {
        'Key Name': false,
        'Private Key': true,
        'Public Key': false,
        'Passphrase': true,
        'Host Server': false,
        'Port': false,
      },
    ),
    RecordTypeItem(
      name: 'Software License',
      icon: Icons.verified_rounded,
      category: 'SECURITY',
      templateFields: {
        'Product Name': false,
        'License Key': true,
        'Licensed Email': false,
        'Version': false,
        'Order / Invoice No': false,
      },
    ),
    RecordTypeItem(
      name: 'API Credential',
      icon: Icons.key_rounded,
      category: 'SECURITY',
      templateFields: {
        'Service Name': false,
        'API Key': true,
        'API Secret': true,
        'Endpoint URL': false,
        'Access Token': true,
      },
    ),
    RecordTypeItem(
      name: 'Combination Lock',
      icon: Icons.lock_rounded,
      category: 'SECURITY',
      templateFields: {
        'Location / Purpose': false,
        'Combination Code': true,
        'Instructions': false,
      },
    ),

    // PERSONAL & IDENTITY
    RecordTypeItem(
      name: 'ID Card',
      icon: Icons.badge_rounded,
      category: 'PERSONAL',
      templateFields: {
        'Full Name': false,
        'ID Number': true,
        'Issuing Authority': false,
        'Issue Date': false,
        'Expiry Date': false,
        'Date of Birth': false,
      },
    ),
    RecordTypeItem(
      name: 'Passport',
      icon: Icons.public_rounded,
      category: 'PERSONAL',
      templateFields: {
        'Full Name': false,
        'Passport Number': true,
        'Issuing Country': false,
        'Nationality': false,
        'Date of Birth': false,
        'Issue Date': false,
        'Expiry Date': false,
      },
    ),
    RecordTypeItem(
      name: "Driver's Licence",
      icon: Icons.directions_car_rounded,
      category: 'PERSONAL',
      templateFields: {
        'Full Name': false,
        'Licence Number': true,
        'Classes / Endorsements': false,
        'Issuing State / Country': false,
        'Issue Date': false,
        'Expiry Date': false,
      },
    ),
    RecordTypeItem(
      name: 'Social Security Number',
      icon: Icons.groups_rounded,
      category: 'PERSONAL',
      templateFields: {
        'Full Name': false,
        'SSN Number': true,
      },
    ),
    RecordTypeItem(
      name: 'National Insurance No',
      icon: Icons.shield_rounded,
      category: 'PERSONAL',
      templateFields: {
        'Full Name': false,
        'NI Number': true,
      },
    ),
    RecordTypeItem(
      name: 'Tax Number',
      icon: Icons.receipt_long_rounded,
      category: 'PERSONAL',
      templateFields: {
        'Taxpayer / Entity Name': false,
        'Tax ID / TIN': true,
        'Tax Authority': false,
      },
    ),
    RecordTypeItem(
      name: 'Birth Certificate',
      icon: Icons.face_rounded,
      category: 'PERSONAL',
      templateFields: {
        'Full Name': false,
        'Registration Number': false,
        'Date of Birth': false,
        'Place of Birth': false,
        'Parents Names': false,
      },
    ),
    RecordTypeItem(
      name: 'Marriage Certificate',
      icon: Icons.favorite_rounded,
      category: 'PERSONAL',
      templateFields: {
        'Spouse 1': false,
        'Spouse 2': false,
        'Certificate Number': false,
        'Marriage Date': false,
        'Place of Marriage': false,
      },
    ),

    // TECHNOLOGY / IT
    RecordTypeItem(
      name: 'Database',
      icon: Icons.storage_rounded,
      category: 'TECHNOLOGY / IT',
      templateFields: {
        'Database Name': false,
        'Host / Server': false,
        'Port': false,
        'Database User': false,
        'Password': true,
        'Database Engine': false,
      },
    ),
    RecordTypeItem(
      name: 'Server',
      icon: Icons.dns_rounded,
      category: 'TECHNOLOGY / IT',
      templateFields: {
        'Server Name': false,
        'IP Address / Host': false,
        'SSH Port': false,
        'Admin Username': false,
        'Admin Password': true,
        'Root Password': true,
      },
    ),
    RecordTypeItem(
      name: 'FTP Info',
      icon: Icons.folder_shared_rounded,
      category: 'TECHNOLOGY / IT',
      templateFields: {
        'Host / Server': false,
        'Port': false,
        'Protocol (FTP/SFTP)': false,
        'Username': false,
        'Password': true,
      },
    ),
    RecordTypeItem(
      name: 'Internet Provider',
      icon: Icons.router_rounded,
      category: 'TECHNOLOGY / IT',
      templateFields: {
        'Provider Name': false,
        'Account Number': false,
        'Plan Details': false,
        'Support Phone': false,
        'Static IP': false,
      },
    ),
    RecordTypeItem(
      name: 'Web Hosting',
      icon: Icons.cloud_rounded,
      category: 'TECHNOLOGY / IT',
      templateFields: {
        'Hosting Provider': false,
        'Control Panel URL': false,
        'Username': false,
        'Password': true,
        'Server IP': false,
      },
    ),
    RecordTypeItem(
      name: 'Wireless Router',
      icon: Icons.settings_input_antenna_rounded,
      category: 'TECHNOLOGY / IT',
      templateFields: {
        'Router Model': false,
        'Gateway IP (e.g. 192.168.1.1)': false,
        'Admin Username': false,
        'Admin Password': true,
        'Wi-Fi SSID': false,
      },
    ),

    // MEMBERSHIP & SERVICES
    RecordTypeItem(
      name: 'Reward Program',
      icon: Icons.card_giftcard_rounded,
      category: 'MEMBERSHIP & SERVICES',
      templateFields: {
        'Program Name': false,
        'Member ID / Number': false,
        'PIN': true,
        'Associated Email': false,
      },
    ),
    RecordTypeItem(
      name: 'Membership',
      icon: Icons.military_tech_rounded,
      category: 'MEMBERSHIP & SERVICES',
      templateFields: {
        'Organization Name': false,
        'Member ID': false,
        'Expiry Date': false,
        'Contact Phone': false,
      },
    ),

    // ASSETS
    RecordTypeItem(
      name: 'Vehicle',
      icon: Icons.directions_car_rounded,
      category: 'ASSETS',
      templateFields: {
        'Make & Model': false,
        'License Plate': false,
        'VIN Number': true,
        'Model Year': false,
        'Vehicle Color': false,
        'Insurance Policy No': false,
      },
    ),
  ];

  Future<void> _onSelectRecordType(RecordTypeItem type) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final entry = kdbxBloc.createEntry(
      file: widget.initialFile,
      group: widget.initialGroup,
    );

    // Set initial title and record type attribute
    entry.setString(KdbxKeyCommon.TITLE, PlainValue(type.name));
    entry.setString(KdbxKey('RecordType'), PlainValue(type.name));
    KeyNestItemTypeHelper.setItemType(entry, KeyNestItemType.record);
    if (entry.getString(KdbxKey('ItemCategory')) == null) {
      entry.setString(KdbxKey('ItemCategory'), PlainValue('Record'));
    }

    // Initialize template fields
    for (final field in type.templateFields.entries) {
      if (field.value) {
        entry.setString(KdbxKey(field.key), ProtectedValue.fromString(''));
      } else {
        entry.setString(KdbxKey(field.key), PlainValue(''));
      }
    }

    if (KeyNestPlatform.isDesktopOrWeb) {
      Navigator.of(context).pop(entry);
      return;
    }

    final saved = await Navigator.of(context).push<bool>(
      EntryDetailsScreen.route(entry: entry, isNew: true),
    );

    if (saved == true) {
      KeyNestVaultScope.instance.notifyScopeChanged();
    }

    if (mounted) {
      Navigator.of(context).pop(saved == true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final query = _searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? allRecordTypes
        : allRecordTypes
              .where(
                (r) =>
                    r.name.toLowerCase().contains(query) ||
                    r.category.toLowerCase().contains(query),
              )
              .toList();

    // Group by category
    final Map<String, List<RecordTypeItem>> grouped = {};
    for (final item in filtered) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: const Text(
          'Add Record',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        leading: IconButton(
          icon: Icon(
            KeyNestPlatform.isDesktopOrWeb
                ? Icons.close_rounded
                : Icons.arrow_back_rounded,
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: KeyNestTokens.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              // Search record types input
              KeyNestSearchBar(
                controller: _searchController,
                hintText: 'Search record types...',
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                onChanged: (val) => setState(() => _searchQuery = val),
                onClear: () => setState(() => _searchQuery = ''),
              ),

              // Categories and cards
              ...grouped.entries.map(
                (entry) => KeyNestSettingsGroup(
                  header: entry.key,
                  children: entry.value.map((type) {
                    return KeyNestSettingsTile(
                      title: type.name,
                      icon: type.icon,
                      trailing: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.lightIcon)
                                  .withValues(alpha: isDark ? 0.16 : 0.10),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.add_rounded,
                          size: 20,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.lightIcon,
                        ),
                      ),
                      onTap: () => _onSelectRecordType(type),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RecordTypeHelper {
  static RecordTypeItem? findType(String? name) {
    if (name == null || name.isEmpty) {
      return null;
    }
    final lower = name.toLowerCase().trim();
    for (final t in _AddRecordCatalogScreenState.allRecordTypes) {
      if (t.name.toLowerCase() == lower) {
        return t;
      }
    }
    return null;
  }

  static IconData iconForType(String? name) {
    return findType(name)?.icon ?? Icons.description_rounded;
  }

  static String? findPrimaryFieldValue(KdbxEntry entry, [String? typeName]) {
    typeName ??= entry.getString(KdbxKey('RecordType'))?.getText();
    final type = findType(typeName);
    if (type != null && type.templateFields.isNotEmpty) {
      final firstKey = type.templateFields.keys.first;
      final val = entry.getString(KdbxKey(firstKey))?.getText()?.trim();
      if (val != null && val.isNotEmpty) {
        return val;
      }
    }
    for (final field in const [
      'Network SSID',
      'Service Name',
      'Product Name',
      'Key Name',
      'Full Name',
      'Server Name',
      'Database Name',
      'Make & Model',
      'Provider Name',
      'Organization Name',
      'Program Name',
      'Hosting Provider',
    ]) {
      final val = entry.getString(KdbxKey(field))?.getText()?.trim();
      if (val != null && val.isNotEmpty) {
        return val;
      }
    }
    return null;
  }
}
