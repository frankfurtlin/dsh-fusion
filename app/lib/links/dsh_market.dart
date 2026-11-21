// The plugin market this build uses: the dsh-market plugin already installed on the person's own
// DSH (`/dsh-market`), opened in the browser that is already signed in — not a catalogue bundled
// with the app, and not the upstream project's market.
//
// Change [dshMarketOrigin] (or pass `--dart-define=DSH_MARKET_ORIGIN=…`) to point it elsewhere.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';

/// Where the person's own DSH lives, and the market path on it.
const dshMarketOrigin = String.fromEnvironment(
  'DSH_MARKET_ORIGIN',
  defaultValue: 'https://dsh.frankfurtlin.top',
);

/// The market page on that instance (dsh-market mounts itself under `/dsh-market`).
final dshMarketUri = Uri.parse('$dshMarketOrigin/dsh-market');

/// Opens the person's own market in the browser. The gateway session there is already signed in,
/// so the market loads straight onto the page it would show in DSH's own web interface.
Future<void> openDshMarket(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.l10n;
  var opened = false;
  try {
    opened = await launchUrl(dshMarketUri, mode: LaunchMode.externalApplication);
  } catch (_) {
    opened = false;
  }
  if (!opened) messenger?.showSnackBar(SnackBar(content: Text(l10n.pluginsOpenMarketFailed)));
}
