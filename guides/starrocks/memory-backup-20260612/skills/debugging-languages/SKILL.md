---
name: debugging-languages
description: "Debug Python and Node.js code: pdb, debugpy, node inspect, CDP, remote-pdb, and post-mortem debugging."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [debugging, python, nodejs, pdb, debugpy, node-inspect, cdp, breakpoints]
    related_skills: [systematic-debugging, debugging-hermes-tui-commands]
---

# Debugging Languages (Python & Node.js)

Pick the right tool for the language and situation.

---

## Python Debugging

### pdb Quick Reference

| Command | Action |
|---|---|
| `n` | next line (step over) |
| `s` | step into |
| `c` | continue |
| `r` | return from function |
| `b file:line` | set breakpoint |
| `b func` | break on function entry |
| `p expr` | print expression |
| `pp expr` | pretty-print |
| `w` | where (stack trace) |
| `interact` | drop into full REPL |
| `q` | quit |

### Usage Patterns

**Local breakpoint:**
```python
def compute(x, y):
    result = some_helper(x)
    breakpoint()           # drops into pdb here
    return result + y
```

**Launch without source edits:**
```bash
python -m pdb script.py arg1 arg2
(Pdb) b script.py:42
(Pdb) c
```

**Post-mortem:**
```bash
python -m pdb -c continue script.py
# On crash, pdb catches and you're in the exception frame
```

**Debug pytest:**
```bash
python -m pytest test_file.py::test_name --pdb -p no:xdist
```

### debugpy (Remote Debugging)

For long-running processes: gateway, daemon, already-misbehaving code.

```bash
# Pattern A: Source edit
import debugpy
debugpy.listen(("127.0.0.1", 5678))
debugpy.wait_for_client()
debugpy.breakpoint()

# Pattern B: No source edit
python -m debugpy --listen 127.0.0.1:5678 --wait-for-client script.py

# Pattern C: Attach to running process
python -m debugpy --listen 127.0.0.1:5678 --pid <pid>
```

**For terminal-friendly remote debugging, use `remote-pdb` instead of debugpy:**
```bash
pip install remote-pdb
from remote_pdb import set_trace; set_trace(host="127.0.0.1", port=4444)
nc 127.0.0.1 4444  # (Pdb) prompt
```

### Pitfalls

1. **pdb under pytest-xdist silently does nothing.** Always `-p no:xdist`.
2. **`breakpoint()` in CI hangs.** Never commit it. Check with `rg -n 'breakpoint()' --type py`.
3. **`PYTHONBREAKPOINT=0` disables breakpoints.** Check env if not hitting.
4. **Threads:** pdb only debugs current thread. Use debugpy for multithreaded.
5. **asyncio:** pdb works in coroutines but `await` requires Python 3.13+ or `interact` mode.

---

## Node.js Debugging

### node inspect REPL

```bash
node inspect script.js
# debug> c (continue)  n (next)  s (step)  o (out)
# debug> sb('file.js', 42)  breakpoints  bt  list(5)
# debug> repl  (drop into JS REPL for scope inspection)
```

**TypeScript:**
```bash
node --inspect-brk --import tsx script.ts
node inspect -p <pid>
```

### Attaching to Running Process

```bash
kill -SIGUSR1 <pid>  # enable inspector on running process
node inspect -p <pid>
```

### CDP (Chrome DevTools Protocol) for Automation

```bash
npm i -g chrome-remote-interface
node --inspect-brk=9229 target.js &
node /tmp/cdp-debug.js  # automated breakpoint + scope capture
```

### Pitfalls

1. **Line numbers in TS → JS.** Breakpoints hit emitted JS. Use `--enable-source-maps` or break in `dist/`.
2. **`--inspect` vs `--inspect-brk`.** The latter pauses on first line; needed when you must set breakpoints before code runs.
3. **Port collisions.** Use `--inspect=0` for random port; check `curl http://127.0.0.1:9229/json/list`.
4. **Child processes don't inherit `--inspect`.** Use `NODE_OPTIONS='--inspect-brk' node parent.js`.
5. **PTY required.** Launch with `pty=true` in Hermes or `background=true` + `submit`.
