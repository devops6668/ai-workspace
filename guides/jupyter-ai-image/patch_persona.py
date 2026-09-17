#!/usr/bin/env python3
"""Patch persona-manager send_message signature.

jupyternaut calls send_message(body, subtitle) two args,
but base_persona.py only accepts one — upstream bug.
"""
import pathlib
import jupyter_ai_persona_manager

bp = pathlib.Path(jupyter_ai_persona_manager.__file__).parent / 'base_persona.py'
s = bp.read_text()
s = s.replace(
    'def send_message(self, body: str) -> None:',
    'def send_message(self, body: str, subtitle: str = "") -> None:'
)
bp.write_text(s)
print('Patched send_message')
