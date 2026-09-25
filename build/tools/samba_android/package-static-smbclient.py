"""Compatibility entry point: publish the single shared Samba build kit."""
from pathlib import Path
import runpy

print('Client and server packaging are unified; creating the complete Samba build kit.')
# Preserve --profile arguments; the shared packager defaults to the size profile.
runpy.run_path(str(Path(__file__).with_name('package-server-release.py')), run_name='__main__')
