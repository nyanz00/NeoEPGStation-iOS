"""Select only SDKs whose framework identity could not be verified on Linux."""
import json
import os


def missing_sdks(requested, device, simulator):
    if requested not in ('all','iphoneos','iphonesimulator'):
        raise ValueError('Unexpected SDK selection')
    selected=('iphoneos','iphonesimulator') if requested=='all' else (requested,)
    usable={'iphoneos':device,'iphonesimulator':simulator}
    return [sdk for sdk in selected if usable[sdk]!='true']


if __name__=='__main__':
    value=json.dumps(missing_sdks(os.environ['REQUESTED_SDK'],os.environ.get('DEVICE_USABLE',''),os.environ.get('SIMULATOR_USABLE','')),separators=(',',':'))
    with open(os.environ['GITHUB_OUTPUT'],'a',encoding='utf-8') as out:
        out.write('missing='+value+'\n')
    print('SDKs needing a Mac library job:',value)
