#!/usr/bin/env python3
"""从设计母版导出 macOS 多尺寸图标，并将 PNG 图层封装为 ICNS。"""
from pathlib import Path
import struct
import subprocess

root = Path(__file__).resolve().parents[1]
assets = root / 'Assets'
iconset = assets / 'AppIcon.iconset'
iconset.mkdir(exist_ok=True)
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        output = iconset / f'icon_{size}x{size}{suffix}.png'
        subprocess.run(['sips', '-z', str(size * scale), str(size * scale),
                        str(assets / 'AppIcon-master.png'), '--out', str(output)],
                       check=True, stdout=subprocess.DEVNULL)

# PNG-backed ICNS types, including Retina representations.
layers = [('icp4', '16x16'), ('icp5', '32x32'), ('icp6', '32x32@2x'),
          ('ic07', '128x128'), ('ic08', '256x256'), ('ic09', '512x512'),
          ('ic10', '512x512@2x'), ('ic11', '16x16@2x'),
          ('ic12', '32x32@2x'), ('ic13', '128x128@2x'), ('ic14', '256x256@2x')]
payload = b''
for kind, name in layers:
    png = (iconset / f'icon_{name}.png').read_bytes()
    payload += kind.encode('ascii') + struct.pack('>I', len(png) + 8) + png
(assets / 'AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
print('Created Assets/AppIcon.icns')
