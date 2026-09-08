import json,re,sys
def norm(s):
    s=s.lower().replace("’","'")
    s=re.sub(r"[^a-z0-9' ]+"," ",s)
    return s.split()
def wer(ref,hyp):
    d=[[0]*(len(hyp)+1) for _ in range(len(ref)+1)]
    for i in range(len(ref)+1): d[i][0]=i
    for j in range(len(hyp)+1): d[0][j]=j
    for i in range(1,len(ref)+1):
        for j in range(1,len(hyp)+1):
            d[i][j]=min(d[i-1][j]+1,d[i][j-1]+1,d[i-1][j-1]+(ref[i-1]!=hyp[j-1]))
    return d[-1][-1]/len(ref)
ref=norm(open('script.txt').read())
digits={"ninety second":"92nd","four hundred":"400","twelve":"12","seven":"7","twenty four":"24","one hundred and eighteen":"118","ninety six":"96","twenty six":"26"}
r2=open('script.txt').read().lower()
for k,v in digits.items(): r2=r2.replace(k,v)
ref2=norm(r2)
for f in sys.argv[1:]:
    hyp=norm(json.load(open(f))['transcript'])
    print(f"{f}: ref={len(ref)} hyp={len(hyp)} words  WER(raw)={wer(ref,hyp):.1%}  WER(number-normalized ref)={wer(ref2,hyp):.1%}")
