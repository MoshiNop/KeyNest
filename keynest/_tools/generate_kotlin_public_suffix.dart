// ignore_for_file: avoid_print
import 'dart:io';
import 'package:autofill_shared/src/public_suffix_list.g.dart';

void main() {
  final lines = publicSuffixListData.split('\n');
  final multiLabelSuffixes = <String>{};
  final wildcards = <String>{};
  final exceptions = <String>{};

  for (final raw in lines) {
    final line = raw.trim().toLowerCase();
    if (line.isEmpty || line.startsWith('//')) {
      continue;
    }
    if (line.startsWith('!')) {
      exceptions.add(line.substring(1));
    } else if (line.startsWith('*.')) {
      wildcards.add(line.substring(2));
    } else if (line.contains('.')) {
      multiLabelSuffixes.add(line);
    }
  }

  print('Multi-label suffixes: ${multiLabelSuffixes.length}');
  print('Wildcards: ${wildcards.length}');
  print('Exceptions: ${exceptions.length}');

  // Generate Kotlin file: deps/autofill_service/android/src/main/kotlin/com/moshinop/autofill_service/PublicSuffixData.kt
  final outPath = '../deps/autofill_service/android/src/main/kotlin/com/moshinop/autofill_service/PublicSuffixData.kt';
  final buffer = StringBuffer();
  buffer.writeln('package com.moshinop.autofill_service');
  buffer.writeln();
  buffer.writeln('// GENERATED FROM autofill_shared/lib/src/public_suffix_list.g.dart');
  buffer.writeln('// Single source of truth for Public Suffix List across Flutter and Native Android');
  buffer.writeln('object PublicSuffixData {');

  void writeChunkedSet(String propName, List<String> items, String prefix) {
    const chunkSize = 200;
    final numChunks = (items.length / chunkSize).ceil();
    if (numChunks <= 1) {
      buffer.writeln('    val $propName: Set<String> = hashSetOf(');
      for (final s in items) {
        buffer.writeln('        "$s",');
      }
      buffer.writeln('    )');
      return;
    }

    for (var i = 0; i < numChunks; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize < items.length) ? start + chunkSize : items.length;
      final chunk = items.sublist(start, end);
      buffer.writeln('    private fun $prefix$i(set: MutableSet<String>) {');
      for (final s in chunk) {
        buffer.writeln('        set.add("$s")');
      }
      buffer.writeln('    }');
      buffer.writeln();
    }

    buffer.writeln('    val $propName: Set<String> = HashSet<String>(${items.length}).apply {');
    for (var i = 0; i < numChunks; i++) {
      buffer.writeln('        $prefix$i(this)');
    }
    buffer.writeln('    }');
  }

  buffer.writeln('    // Multi-part public suffixes (eTLDs containing at least one dot)');
  writeChunkedSet('MULTI_PART_SUFFIXES', multiLabelSuffixes.toList(), 'populateMultiPart');
  buffer.writeln();

  buffer.writeln('    // Wildcard suffix roots (e.g. *.jp, *.ck)');
  writeChunkedSet('WILDCARD_ROOTS', wildcards.toList(), 'populateWildcard');
  buffer.writeln();

  buffer.writeln('    // Exception rules (e.g. !city.kawasaki.jp)');
  writeChunkedSet('EXCEPTION_RULES', exceptions.toList(), 'populateExceptions');
  buffer.writeln('}');

  File(outPath).writeAsStringSync(buffer.toString());
  print('Wrote PublicSuffixData.kt to $outPath');
}
