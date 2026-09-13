"""Read a pinned Git object into temporary files; never start or mutate an engine."""
import argparse,json,subprocess,tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--engine-repo',required=True);args=p.parse_args()
root=Path(__file__).resolve().parents[2]
manifest=json.loads((root/'contracts/ios-first/manifest.json').read_text())
commit=next(s['commit'] for s in manifest['sources'] if s['repo']=='valence')
files=['engine/src/shared/decisions.ts','engine/src/shared/statement.ts','engine/src/hub/mandates.ts','engine/src/common/errors.ts','engine/src/common/store.ts']
with tempfile.TemporaryDirectory(prefix='atarasy-vector-check-') as directory:
    target=Path(directory)
    for name in files:
        dest=target/name;dest.parent.mkdir(parents=True,exist_ok=True)
        dest.write_bytes(subprocess.check_output(['git','-C',args.engine_repo,'show',commit+':'+name]))
    (target/'check.ts').write_text('''import { canonicalDecisions } from './engine/src/shared/decisions.ts';
import { canonicalStatement } from './engine/src/shared/statement.ts';
import { canonicalMandate } from './engine/src/hub/mandates.ts';
const vectors = await Bun.file(process.argv[2]).json();
for(const v of vectors){const b=v.kind==='decision'?canonicalDecisions(v.offer,v.decisions):v.kind==='statement'?canonicalStatement(v.offer,v.carriage,v.lines):canonicalMandate(v.mandate);if(b.toString('utf8')!==v.canonical)throw new Error(v.id);}
console.log(JSON.stringify({vectors:vectors.length,result:'matched pinned engine bytes',serverStarted:false}));
''')
    subprocess.run(['bun',str(target/'check.ts'),str(root/'contracts/ios-first/canonical-vectors.json')],check=True)
