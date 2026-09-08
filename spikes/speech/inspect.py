import json,sys
mode=sys.argv[1]; d=json.load(open(sys.argv[2]))
if mode=="dictation":
    for s in d['segments']:
        print(round(s['start'],2),round(s['end'],2),s['isFinal'],len(s['words']),'words; first3:',s['words'][:3]); print('  ',s['text'][:120])
elif mode=="volatile":
    for s in d['segments'][:14]: print("  [%.2f-%.2f] final=%s fin=%.2f %r"%(s['start'],s['end'],s['isFinal'],s['finalizationTime'],s['text']))
    fin=[s for s in d['segments'] if s['isFinal']]; print('finals:',len(fin),'words:',len(d['words']))
