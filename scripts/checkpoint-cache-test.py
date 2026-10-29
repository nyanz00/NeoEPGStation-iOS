"""Compile the actual patched packet-cache implementation, without media/UI dependencies."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--engine')
args = parser.parse_args()
checkout = Path(args.engine) if args.engine else next(p for p in Path('build/SourcePackages/checkouts').iterdir()
                                                   if p.name.lower() == 'aetherengine')
engine = checkout/'Sources/AetherEngine/Native'
names = ['SoftwareStoredPacket', 'SoftwarePacketDiskFIFO', 'SoftwarePacketStore',
         'SoftwarePacketCoverage', 'SoftwareAudioPacketCoverage', 'SoftwareVideoPacketCoverage',
         'SoftwarePacketReadAhead']
Path('build/native-tests').mkdir(parents=True, exist_ok=True)
Path('dist').mkdir(exist_ok=True)
binary = 'build/native-tests/checkpoint-cache'
subprocess.run(['swiftc', *[str(engine/(name+'.swift')) for name in names],
                'tests/checkpoint-cache/main.swift', '-o', binary], check=True)
result = subprocess.check_output([binary], text=True)
Path('dist/checkpoint-cache.txt').write_text(result)
print(result, end='')
