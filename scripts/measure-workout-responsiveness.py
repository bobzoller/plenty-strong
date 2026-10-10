#!/usr/bin/env python3
"""Bounded synthetic Debug macOS MainActor/runloop proof; never opens an app store.

Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3
  scripts/measure-workout-responsiveness.py --output /tmp/plenty-responsiveness

Requires installed Xcode. Retains every build/run log and exact source/object hashes.
The fresh-program admission mirrors AppComposition's pure fresh-store checks;
Start/load use the actual WorkoutViewModel. XCTest separately exercises confirm.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
OUT = args.output.resolve()
OUT.mkdir(parents=True, exist_ok=False)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')


def command(argv, name, extra=None):
    with (OUT / f'{name}.log').open('w') as log:
        result = subprocess.run(argv, cwd=ROOT, env=env | (extra or {}), stdout=log, stderr=subprocess.STDOUT)
    (OUT / f'{name}.exit').write_text(f'{result.returncode}\n')
    if result.returncode:
        raise SystemExit(f'{name} failed ({result.returncode}); see {OUT / (name + ".log")}')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


derived = OUT / 'DerivedData'
command(['xcodebuild', 'build', '-project', 'PlentyStrong.xcodeproj', '-scheme', 'PlentyStrongCrashHarness',
         '-configuration', 'Debug', '-destination', 'platform=macOS', '-derivedDataPath', str(derived),
         'CODE_SIGNING_ALLOWED=NO'], 'build-crash-sources')
products = derived / 'Build/Products/Debug'
file_lists = list(derived.glob('Build/Intermediates.noindex/PlentyStrong.build/Debug/PlentyStrongCrashHarness.build/Objects-normal/*/PlentyStrongCrashHarness.SwiftFileList'))
if len(file_lists) != 1:
    raise SystemExit('Expected exactly one native architecture source list')
files = [Path(p) for p in file_lists[0].read_text().splitlines() if not p.endswith('/main.swift')]
files += [ROOT / p for p in ['Features/Workout/WorkoutViewModel.swift', 'Features/Workout/RestTimer.swift', 'Features/Workout/MovementPrescriptionSummary.swift']]
sources = OUT / 'sources'
sources.mkdir(exist_ok=True)
manifest = []
compiled = []
for original in files:
    content = original.read_text()
    manifest.append({'path': str(original.relative_to(ROOT)), 'sha256': digest(original)})
    names = []
    if original.name == 'TrainingRepository.swift':
        names = ['snapshotBody', 'capturedBackup', 'admittedBackup', 'saveDraftBody', 'initializeBody', 'prepareReturnBody', 'activateFlexibleScheduleBody']
        content = content.replace('try modelContext.save()', 'let saveStart = Diag.shared.enter("modelContext.save"); try modelContext.save(); Diag.shared.leave("modelContext.save", saveStart)')
    if original.name == 'BackupService.swift':
        names = ['validate', 'rules', 'archiveHash', 'bytes']
    for name in names:
        pattern = r'(    (?:private )?(?:static )?func ' + name + r'(?:<[^\n]+?>)?\([^\n]*\) throws -> [^\n{]+\{)'
        label = ('BackupService.' if original.name == 'BackupService.swift' else '') + name
        content, count = re.subn(pattern, lambda match: match[0] + f'\n        let diagStart = Diag.shared.enter("{label}"); defer {{ Diag.shared.leave("{label}", diagStart) }}', content)
        if count != 1:
            raise SystemExit(f'Instrumentation source binding changed: {name}, matches={count}')
    # Instrumentation turns these single-expression bodies into multiple statements.
    content = content.replace('        try apply(', '        return try apply(')
    content = content.replace('        try transaction {\n            guard let id = UUID(uuidString: draft.programID)', '        return try transaction {\n            guard let id = UUID(uuidString: draft.programID)')
    content = content.replace('        try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)))', '        return try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)))')
    target = sources / original.name
    target.write_text(content)
    compiled.append(str(target))
composition = ROOT / 'PlentyStrong/AppComposition.swift'
compatibility = composition.read_text().split('enum AppTrainingCompatibility {', 1)[1]
compatibility_path = sources / 'AppTrainingCompatibility.swift'
compatibility_path.write_text('import TrainingCore\n' + 'enum AppTrainingCompatibility {' + compatibility)
compiled.append(str(compatibility_path))
manifest.append({'path': str(composition.relative_to(ROOT)), 'sha256': digest(composition), 'extracted': 'AppTrainingCompatibility'})
harness = ROOT / 'PlentyStrongTests/Support/ResponsivenessHarness/main.swift'
manifest.append({'path': str(harness.relative_to(ROOT)), 'sha256': digest(harness)})
compiled.append(str(harness))
response = OUT / 'sources.txt'
response.write_text('\n'.join('"' + path + '"' for path in compiled) + '\n')
core_object = products / 'TrainingCore.o'
(OUT / 'source-binding.json').write_text(json.dumps({'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'sources': manifest, 'trainingCoreObjectSHA256': digest(core_object)}, indent=2) + '\n')
binary = OUT / 'responsiveness-debug'
command(['xcrun', 'swiftc', '-Onone', '-DDEBUG', '-swift-version', '6', '-module-name', 'ResponsivenessHarness',
         '-target', 'arm64-apple-macos15.0', '-I', str(products), '@' + str(response), str(core_object), '-o', str(binary)], 'compile-native')
measurements = {}
for mode in ['main', 'ui']:
    store = OUT / ('synthetic-' + mode)
    if store.exists():
        raise SystemExit(f'Refusing to reuse a store: {store}; choose a new output directory')
    command([str(binary), mode, str(store), str(ROOT)], 'native-' + mode, {'PACKAGE_RESOURCE_BUNDLE_PATH': str(products)})
    results = []
    for line in (OUT / f'native-{mode}.log').read_text().splitlines():
        match = re.fullmatch(r'RESULT operation=(\S+) wall=(\S+) cpu=(\S+) maxMainHeartbeatGap=(\S+) stats=(.*)', line)
        if match:
            name, wall, cpu, gap, stats = match.groups()
            results.append({'operation': name, 'wallSeconds': float(wall), 'cpuSeconds': float(cpu), 'maxMainHeartbeatGapSeconds': float(gap), 'stats': json.loads(stats)})
    measurements[mode] = results
(OUT / 'measurements.json').write_text(json.dumps(measurements, indent=2) + '\n')
for mode, results in measurements.items():
    if len(results) != 5:
        raise SystemExit(f'{mode}: missing completed action measurements')
    for result in results:
        if any(value['main'] for value in result['stats'].values()):
            raise SystemExit(f'{mode}/{result["operation"]}: heavy work reached physical main')
        if result['maxMainHeartbeatGapSeconds'] > 0.1:
            raise SystemExit(f'{mode}/{result["operation"]}: runloop gap exceeded 100ms; inspect load and retained log')
        maximum = 5 if 'firstStart' in result['operation'] else 3 if 'ConfirmProgram' in result['operation'] else 1
        if result['stats']['BackupService.validate']['count'] > maximum:
            raise SystemExit(f'{mode}/{result["operation"]}: duplicate full replay regression')
print(f'PASS: 10 synthetic Debug Mac actions, off-main entries, <=100ms heartbeat gaps, bounded validations; evidence: {OUT}')
