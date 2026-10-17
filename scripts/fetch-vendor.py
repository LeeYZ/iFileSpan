import hashlib, json, os, subprocess, tarfile, urllib.parse
from pathlib import Path
project = Path(__file__).resolve().parent.parent
root = project / '.build' / 'vendor-downloads'
root.mkdir(parents=True, exist_ok=True)
vendor = project / 'Vendor'
for folder in ['Frameworks', 'Licenses', 'Sources', 'Manifests']:
    (vendor / folder).mkdir(parents=True, exist_ok=True)
(root/'downloads').mkdir(exist_ok=True)
(root/'unpacked').mkdir(exist_ok=True)

def fetch(url, target, headers=None):
    target=Path(target)
    if target.exists(): return target
    cmd=['/usr/bin/curl','--fail','--location','--silent','--show-error','--retry','2','--connect-timeout','20','--max-time','240']
    for k,v in (headers or {}).items(): cmd.extend(['-H',k+': '+v])
    subprocess.run(cmd+[url,'-o',str(target)],check=True)
    return target

def digest(file):
    h=hashlib.sha256()
    with open(file,'rb') as f:
        while b:=f.read(1024*1024): h.update(b)
    return h.hexdigest()

pending=['libimobiledevice']; formulas={}; records=[]
while pending:
    name=pending.pop(0)
    if name in formulas: continue
    path=fetch('https://formulae.brew.sh/api/formula/'+name+'.json', vendor/'Manifests'/(name+'.json'))
    obj=json.loads(path.read_text()); formulas[name]=obj
    pending.extend(obj['dependencies'])
    print('Formula:',name,obj['versions']['stable'],flush=True)

runtime_names = {'libimobiledevice', 'libimobiledevice-glue', 'libplist', 'libusbmuxd', 'openssl@4'}
for name,obj in formulas.items():
    if name not in runtime_names: continue
    files=obj['bottle']['stable']['files']
    tag='arm64_sequoia' if 'arm64_sequoia' in files else 'all'
    if tag not in files: raise RuntimeError('No compatible bottle for '+name)
    bottle=files[tag]
    archive=root/'downloads'/(name+'-'+bottle['sha256']+'.tar.gz')
    parsed=urllib.parse.urlparse(bottle['url'])
    repository=parsed.path.split('/blobs/')[0].removeprefix('/v2/')
    token_url='https://ghcr.io/token?service=ghcr.io&scope='+urllib.parse.quote('repository:'+repository+':pull',safe='')
    token_path=root/'downloads'/(name+'.anonymous-token.json')
    if token_path.exists(): token_path.unlink()
    fetch(token_url,token_path)
    token=json.loads(token_path.read_text())['token']; token_path.unlink()
    fetch(bottle['url'], archive, {'Authorization':'Bearer '+token})
    if digest(archive)!=bottle['sha256']: raise RuntimeError('Bottle checksum mismatch '+name)
    dest=root/'unpacked'/name; dest.mkdir(exist_ok=True)
    # Use system tar for ordinary Homebrew layout, after checking entry paths.
    with tarfile.open(archive,'r:gz') as tf:
        for member in tf.getmembers():
            path=Path(member.name)
            if path.is_absolute() or '..' in path.parts: raise RuntimeError('Unsafe archive path')
    subprocess.run(['/usr/bin/tar','-xzf',str(archive),'-C',str(dest)],check=True)
    version_root=next((dest/name).iterdir())
    formula_licenses=vendor/'Licenses'/name; formula_licenses.mkdir(exist_ok=True)
    import shutil
    for item in version_root.iterdir():
        if item.is_file() and (item.name.upper().startswith(('LICENSE','COPYING','NOTICE','AUTHORS'))):
            shutil.copy2(item,formula_licenses/item.name)
    embedded_formula=version_root/'.brew'/(name+'.rb')
    if embedded_formula.exists(): shutil.copy2(embedded_formula,vendor/'Sources'/(name+'.rb'))
    dylibs=[]
    for item in version_root.rglob('*.dylib'):
        # Only libraries, not optional OpenSSL providers.
        if item.is_symlink() or item.parent.name != 'lib' or item.name.startswith('libplist++'): continue
        target=vendor/'Frameworks'/item.name
        shutil.copyfile(item,target); os.chmod(target,0o755); dylibs.append(item.name)
    # Preserve dylib aliases for clients that use the unversioned library name.
    for item in version_root.rglob('*.dylib'):
        if not item.is_symlink() or item.parent.name!='lib': continue
        resolved=item.resolve()
        if resolved.name not in dylibs: continue
        target=vendor/'Frameworks'/item.name
        if target.is_symlink() or target.exists(): target.unlink()
        target.symlink_to(resolved.name)
    stable=obj['urls']['stable']
    record={'name':name,'version':obj['versions']['stable'],'revision':obj['revision'],'license':obj['license'],
            'homepage':obj['homepage'],'bottleTag':tag,'bottleURL':bottle['url'],'bottleSHA256':bottle['sha256'],
            'sourceURL':stable['url'],'sourceSHA256':stable['checksum'],'libraries':dylibs}
    # Ship corresponding LGPL sources with the binary delivery.
    if 'LGPL' in str(obj['license']):
        source=vendor/'Sources'/Path(urllib.parse.urlparse(stable['url']).path).name
        fetch(stable['url'],source)
        if stable['checksum'] and digest(source)!=stable['checksum']: raise RuntimeError('Source checksum mismatch '+name)
        record['includedSource']=source.name
    records.append(record)
    print('Fetched:',name,', '.join(dylibs) or '(no dylib)',flush=True)
(vendor/'manifest.json').write_text(json.dumps(records,ensure_ascii=False,indent=2)+'\n')
print('Runtime dependencies ready:',len(records),flush=True)
