"""Run pinned engine Git objects in an isolated in-memory harness. No listener or live tree imports."""
import argparse,hashlib,json,subprocess,tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--engine-repo',required=True);p.add_argument('--output',required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[2]
commit=next(s['commit'] for s in json.loads((root/'contracts/ios-first/manifest.json').read_text())['sources'] if s['repo']=='valence')
names=subprocess.check_output(['git','-C',a.engine_repo,'ls-tree','-r','--name-only',commit,'engine/src','engine/test/helpers.ts'],text=True).splitlines()
with tempfile.TemporaryDirectory(prefix='atarasy-response-check-') as d:
 target=Path(d);hashes={}
 for name in names:
  data=subprocess.check_output(['git','-C',a.engine_repo,'show',commit+':'+name]);dest=target/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data);hashes[name]=hashlib.sha256(data).hexdigest()
 harness=root/'scripts/ios-first/capture-responses.ts';(target/'capture.ts').write_bytes(harness.read_bytes())
 output=Path(a.output).resolve();output.parent.mkdir(parents=True,exist_ok=True)
 subprocess.run(['bun',str(target/'capture.ts'),str(output)],check=True)
 record=json.loads(output.read_text());record['source']={'commit':commit,'files':hashes,'harness_sha256':hashlib.sha256(harness.read_bytes()).hexdigest()};output.write_text(json.dumps(record,indent=2)+'\n')
