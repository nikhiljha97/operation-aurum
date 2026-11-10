#!/usr/bin/env python3
"""Rebuild the single-file macOS installer eie_setup.sh from the repo's files.
Run after changing anything in watcher/ or scripts/:   python3 scripts/pack-standalone.py
eie_setup.sh embeds each file as a heredoc; this replaces each embedded copy with the current file."""
import os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETUP = os.path.join(ROOT, 'eie_setup.sh')
EMBED = {  # heredoc tag → repo file
    'EOF_WATCH': 'watcher/eie-watch.mjs', 'EOF_MD': 'watcher/CLAUDE.md', 'EOF_UI': 'watcher/ui.html',
    'EOF_PROBE': 'watcher/probe-trading.mjs', 'EOF_MCW': 'watcher/mc-worker.mjs',
    'EOF_START': 'scripts/start.sh', 'EOF_DOC': 'scripts/doctor.mjs',
}
s = open(SETUP, encoding='utf-8').read()
if "<<'EOF_DOC'" not in s:   # doctor.mjs was added later: insert its block after start.sh
    s = s.replace('chmod +x "$HOME/eie-watch/start.sh"\n',
                  'chmod +x "$HOME/eie-watch/start.sh"\ncat > "$HOME/eie-watch/doctor.mjs" <<\'EOF_DOC\'\nEOF_DOC\n', 1)
for tag, rel in EMBED.items():
    body = open(os.path.join(ROOT, rel), encoding='utf-8').read()
    if not body.endswith('\n'): body += '\n'
    if re.search(r'^' + tag + r'$', body, re.M): sys.exit(f'{rel} contains the line {tag}; cannot embed')
    pat = re.compile(r"(<<'" + tag + r"'\n)(.*?)(^" + tag + r"$)", re.S | re.M)
    if len(pat.findall(s)) != 1: sys.exit(f'heredoc {tag} not found exactly once in eie_setup.sh')
    s = pat.sub(lambda m: m.group(1) + body + m.group(3), s)
open(SETUP, 'w', encoding='utf-8').write(s)
print('eie_setup.sh rebuilt from:', ', '.join(EMBED.values()))
