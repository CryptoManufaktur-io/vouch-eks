#!/usr/bin/python3
import sys
import os
import json
import shlex
import subprocess

content = sys.stdin.read()
data = json.loads(content)

port = 8888

args = shlex.split(f"ssh -o \"StrictHostKeyChecking=no\" {data['ssh_user']}@{data['instance']} -i {data['ssh_private_key']} {data['ssh_extra_args']} -L {port}:localhost:8888 -N -q -f")
subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

sys.stdout.write('{"port":"%(port)s"}\n' % {'port': port})
sys.stdout.flush()

os._exit(0)
