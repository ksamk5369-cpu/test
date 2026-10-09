"""Runs el_printer's server scripts against tests/fivem_mock.lua using an embedded Lua 5.4 (pip install lupa)."""
import os
import re
import sys

from lupa import lua54

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCE = os.path.join(ROOT, 'el_printer')


def manifest_scripts():
    text = open(os.path.join(RESOURCE, 'fxmanifest.lua')).read()

    def block(name):
        match = re.search(name + r"\s*\{(.*?)\}", text, re.S)
        return re.findall(r"'([^']+\.lua)'", match.group(1)) if match else []

    return block('shared_scripts') + [s for s in block('server_scripts') if not s.startswith('@')]


def main():
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    run = lua.eval('function(src, name) local f, err = load(src, "@" .. name) if not f then error(err) end return f() end')
    run(open(os.path.join(ROOT, 'tests', 'fivem_mock.lua')).read(), 'fivem_mock.lua')
    for script in manifest_scripts():
        run(open(os.path.join(RESOURCE, script)).read(), script)
    ok = run(open(os.path.join(ROOT, 'tests', 'server_tests.lua')).read(), 'server_tests.lua')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
