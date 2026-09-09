"""Build and launch the real SwiftUI app on iPhone and Watch; retain QA screenshots."""
import json, subprocess, pathlib, time
out=pathlib.Path('qa-screenshots'); out.mkdir(exist_ok=True)
def run(*args):
    print(' '.join(args), flush=True)
    return subprocess.check_output(args, text=True, timeout=180).strip()
devices=json.loads(run('xcrun','simctl','list','devices','available','--json'))['devices']
for platform, needle, target, bundle in [('iOS','iPhone','Chyme','com.connor.chyme'),('watchOS','Apple Watch','ChymeWatch','com.connor.chyme.watchkitapp')]:
    candidates=[d for runtime,ds in devices.items() if platform in runtime for d in ds if needle in d['name']]
    if not candidates: raise RuntimeError('No '+platform+' simulator')
    d=candidates[0]; udid=d['udid']
    if d['state']!='Booted': run('xcrun','simctl','boot',udid)
    run('xcrun','simctl','bootstatus',udid,'-b')
    derived='/tmp/chyme-sim-'+platform
    with open(out/(platform+'-build.log'),'w') as log:
        subprocess.run(['xcodebuild','-project','Chyme.xcodeproj','-scheme',target,'-destination','id='+udid,'-derivedDataPath',derived,'CODE_SIGNING_ALLOWED=NO','ONLY_ACTIVE_ARCH=YES','build'],stdout=log,stderr=subprocess.STDOUT,check=False,timeout=600)
        log.flush()
        content=(out/(platform+'-build.log')).read_text()
        if '** BUILD SUCCEEDED **' not in content:
            print('\n'.join(line for line in content.splitlines() if 'error:' in line or 'note:' in line), flush=True)
            raise RuntimeError(platform+' build failed; see retained log')
    suffix='Debug-iphonesimulator' if platform=='iOS' else 'Debug-watchsimulator'
    app=pathlib.Path(derived)/'Build/Products'/suffix/(target+'.app')
    run('xcrun','simctl','install',udid,str(app))
    run('xcrun','simctl','launch',udid,bundle)
    time.sleep(3)
    for route in ['timers','alarms','stopwatch','settings']:
        run('xcrun','simctl','terminate',udid,bundle)
        run('xcrun','simctl','launch',udid,bundle,'--qa-screen',route)
        time.sleep(2)
        run('xcrun','simctl','io',udid,'screenshot',str(out/(platform+'-'+route+'.png')))
    run('xcrun','simctl','shutdown',udid)
