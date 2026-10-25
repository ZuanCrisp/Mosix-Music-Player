import 'package:flutter/material.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/artist_concert.dart';
import 'package:mosix/screens/artist_concerts_screen.dart';
import 'package:mosix/widgets/animation_utils.dart';

class ArtistConcertsButton extends StatelessWidget {
  const ArtistConcertsButton({
    super.key,
    required this.artistName,
    required this.concerts,
    this.coverUrl,
    this.providerId,
  });

  final String artistName;
  final List<ArtistConcert> concerts;
  final String? coverUrl;
  final String? providerId;

  @override
  Widget build(BuildContext context) {
    if (concerts.isEmpty) return const SizedBox.shrink();
    return TextButton.icon(
      onPressed: () => Navigator.of(context).push(
        slidePageRoute<void>(
          page: ArtistConcertsScreen(
            artistName: artistName,
            concerts: concerts,
            coverUrl: coverUrl,
            providerId: providerId,
          ),
        ),
      ),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        minimumSize: const Size(0, 24),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        tapTargetSize: MaterialTapTargetSize.padded,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
        ),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      icon: const Icon(Icons.confirmation_number_rounded, size: 16),
      label: Text(
        context.l10n.artistUpcomingConcerts,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
