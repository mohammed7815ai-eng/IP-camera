import 'dart:io';

import 'package:flutter/material.dart';

import '../services/snapshots.dart';

class SnapshotsPage extends StatefulWidget {
  const SnapshotsPage({super.key});
  @override
  State<SnapshotsPage> createState() => _SnapshotsPageState();
}

class _SnapshotsPageState extends State<SnapshotsPage> {
  late Future<List<File>> _files = listSnapshots();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Snapshots')),
      body: FutureBuilder<List<File>>(
        future: _files,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final files = snap.data!;
          if (files.isEmpty) return const Center(child: Text('No snapshots yet. Open a camera and tap the camera icon.'));
          return GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 320, childAspectRatio: 16 / 9, mainAxisSpacing: 8, crossAxisSpacing: 8),
            itemCount: files.length,
            itemBuilder: (context, i) => GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(
                    title: Text(files[i].uri.pathSegments.last),
                    actions: [
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final nav = Navigator.of(context);
                          await files[i].delete();
                          setState(() => _files = listSnapshots());
                          nav.pop();
                        },
                      ),
                    ],
                  ),
                  body: InteractiveViewer(maxScale: 8, child: Center(child: Image.file(files[i]))),
                ),
              )),
              child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(files[i], fit: BoxFit.cover)),
            ),
          );
        },
      ),
    );
  }
}
