#!/usr/bin/env python3
"""Read-only preflight; never download runtimes, sign in or change xcode-select."""
import argparse
import json
import os
import subprocess
import sys


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', action='append', default=[])
    parser.add_argument('--required-ios-major', type=int, choices=[18, 27])
    args = parser.parse_args()
    developer = os.environ.get('DEVELOPER_DIR')
    if not developer or not os.path.isdir(developer):
        raise ValueError('DEVELOPER_DIR must name an installed Xcode Developer directory')
    version = run('xcodebuild', '-version')
    swift = run('xcrun', 'swift', '--version')
    print(version, swift, sep='\n', flush=True)
    if version != 'Xcode 27.0\nBuild version 27A266a' or 'Apple Swift version 6.4 ' not in swift:
        raise ValueError('required toolchain is Xcode 27.0 build 27A266a / Apple Swift 6.4')
    print('simctl:', run('xcrun', '--find', 'simctl'), flush=True)
    if not args.destination:
        return
    inventory = json.loads(run('xcrun', 'simctl', 'list', '--json'))
    runtimes = {item['identifier']: item for item in inventory['runtimes'] if item.get('isAvailable')}
    for destination in args.destination:
        values = dict(part.split('=', 1) for part in destination.split(','))
        if values.get('platform') != 'iOS Simulator':
            raise ValueError(f'expected iOS Simulator destination: {destination}')
        matches = []
        for runtime_id, devices in inventory['devices'].items():
            runtime = runtimes.get(runtime_id)
            if not runtime or not runtime_id.startswith('com.apple.CoreSimulator.SimRuntime.iOS-'):
                continue
            for device in devices:
                if not device.get('isAvailable'):
                    continue
                if 'id' in values and device['udid'] != values['id']:
                    continue
                if 'name' in values and device['name'] != values['name']:
                    continue
                if 'OS' in values and runtime['version'] != values['OS']:
                    continue
                matches.append((device, runtime))
        if len(matches) != 1:
            raise ValueError(f'required destination unavailable or ambiguous ({len(matches)} matches): {destination}; install/select it explicitly; no automatic download')
        device, runtime = matches[0]
        if args.required_ios_major is not None and int(runtime['version'].split('.')[0]) != args.required_ios_major:
            raise ValueError(f"required iOS {args.required_ios_major} runtime, selected iOS {runtime['version']}: {destination}")
        print(f"Selected {device['name']} iOS {runtime['version']} ({runtime['buildversion']}) id={device['udid']}", flush=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError, FileNotFoundError) as error:
        print(f'PRECHECK FAILED: {error}', file=sys.stderr)
        sys.exit(1)
