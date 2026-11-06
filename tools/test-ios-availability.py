#!/usr/bin/env python3
"""Cross-codegen availability checks; no Apple SDK or target execution needed."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).absolute().parent.parent
os.chdir(root)
compiler = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/ablac')
directory = root / 'build/ios-availability-test'
directory.mkdir(parents=True, exist_ok=True)
cases = {
    'command': 'process creation/execution',
    'signals': 'signals',
    'signal-callback': 'signals',
    'device': 'device I/O',
    'serial': 'serial I/O',
    'execute': 'process creation/execution',
    'native-fork': 'process creation/execution',
    'native-signal': 'signals',
    'host-extern': 'runtime compiler-host evaluation',
    'orc': 'runtime LLVM/JIT',
    'host-only': None,
    'ct-callback': None,
    'unused-imports': None,
}
for target, helper in [('device', 'iosDeviceTarget'), ('simulator', 'iosSimulatorTarget')]:
    for name, category in cases.items():
        entry = f'tests/cases/ios-target/availability/{name}.ab'
        obj = directory / f'{target}-{name}.o'
        obj.unlink(missing_ok=True)
        driver = directory / f'{target}-{name}.ab'
        driver.write_text(f'''import "abla/build"
import "abla/ios/build"
compile fun checkAvailability(): bool {{
    val target = {helper}()
    buildProgram("availability-{name}", "{entry}", "{obj.relative_to(root)}", target, "object", true, false)
}}
val accepted = #checkAvailability()
fun main(): int = if (accepted) 0 else 1
''')
        result = subprocess.run([compiler, 'build', str(driver), '-o',
                                 str(directory / f'{target}-{name}-driver'), '--fast', '--no-cache'],
                                capture_output=True, text=True, timeout=180)
        text = result.stdout + result.stderr
        (directory / f'{target}-{name}.log').write_text(text)
        if category is None:
            assert result.returncode == 0 and obj.is_file(), (target, name, result.returncode, text)
            symbols = subprocess.check_output(['llvm-nm', '--undefined-only', str(obj)], text=True)
            assert not any(line.split()[-1].lstrip('_').startswith(('LLVM', 'LLJIT'))
                           for line in symbols.splitlines() if line.split()), symbols
        else:
            assert result.returncode != 0 and not obj.exists(), (target, name, text)
            assert 'error[E_TARGET_IOS_UNSUPPORTED]' in text, (target, name, text)
            assert category in text and 'source[target]:' in text, (target, name, text)
        print(f'iOS availability: {target} {name} passed', flush=True)
print('iOS availability: typed runtime refusals, unused imports and compile-time host work passed')
