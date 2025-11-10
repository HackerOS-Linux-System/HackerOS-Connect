// main.dart
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

void main() {
  runApp(const HackerOSApp());
}

class HackerOSApp extends StatelessWidget {
  const HackerOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HackerOS App',
      theme: ThemeData(
        primaryColor: const Color(0xFF121212),
        scaffoldBackgroundColor: const Color(0xFF1C2526),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF121212),
          elevation: 4,
          shadowColor: Colors.black54,
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Color(0xFFB0B0B0)),
          titleLarge: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFB0B0B0),
            foregroundColor: const Color(0xFF121212),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
            elevation: 2,
          ),
        ),
        colorScheme: ColorScheme.fromSwatch().copyWith(secondary: const Color(0xFFB0B0B0)),
      ),
      home: const WallpapersScreen(),
    );
  }
}

class WallpapersScreen extends StatefulWidget {
  const WallpapersScreen({super.key});

  @override
  State<WallpapersScreen> createState() => _WallpapersScreenState();
}

class _WallpapersScreenState extends State<WallpapersScreen> {
  final List<String> wallpaperUrls = [
    'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-App/main/wallpapers/wallpaper.png',
    'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-App/main/wallpapers/wallpaper1.png',
    'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-App/main/wallpapers/wallpaper2.png',
    'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-App/main/wallpapers/wallpaper3.png',
    'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-App/main/wallpapers/wallpaper4.png',
    'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-App/main/wallpapers/wallpaper5.png',
  ];

  Future<void> _downloadWallpaper(String url) async {
    final status = await Permission.storage.request();
    if (status.isGranted) {
      try {
        final tempDir = await getTemporaryDirectory();
        final filePath = '${tempDir.path}/${url.split('/').last}';
        await Dio().download(url, filePath);
        final result = await GallerySaver.saveImage(filePath);
        if (result == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tapeta pobrana i zapisana w galerii!')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Błąd podczas zapisywania tapety.')),
          );
        }
        await File(filePath).delete(); // Clean up temp file
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Błąd pobierania: $e')),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Brak uprawnień do zapisu.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HackerOS App - Tapety'),
        centerTitle: true,
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 0.6,
        ),
        itemCount: wallpaperUrls.length,
        itemBuilder: (context, index) {
          final url = wallpaperUrls[index];
          return Card(
            color: const Color(0xFF2F3A44),
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                    child: Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => const Icon(Icons.error, color: Colors.red),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ElevatedButton(
                    onPressed: () => _downloadWallpaper(url),
                    child: const Text('Pobierz'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
