#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
with open(os.environ['MACDM_VIDEO_LOG'], 'a') as output:
    output.write(json.dumps(args) + '\n')
if '--list-impersonate-targets' in args:
    print('none'); sys.exit(0)
if '--flat-playlist' in args:
    print(json.dumps({'entries': [{'title':'One','url':'https://example.test/one'}, {'title':'Two','url':'https://example.test/two'}]})); sys.exit(0)
if '-J' in args:
    print(json.dumps({'title':'Fixture','formats':[{'height':720,'vcodec':'h264'}]})); sys.exit(0)
if 'https://example.test/slow' in args:
    time.sleep(15)
path = os.path.join(os.environ['MACDM_VIDEO_DIR'], 'fixture.mp4')
with open(path, 'wb') as output: output.write(b'fixture')
sys.stdout.write('[download]  50.0% of 1.00MiB\n'); sys.stdout.flush()
# Split output, including an incomplete final line, to exercise pipe framing.
sys.stdout.write(path[:8]); sys.stdout.flush(); time.sleep(.02)
sys.stdout.write(path[8:]); sys.stdout.flush()
