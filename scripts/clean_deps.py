import re

with open(r'C:\Users\24368\Desktop\MIX\claude最新修正版\build\hermes-core-deps.txt', 'r') as f:
    lines = f.readlines()

clean = []
for l in lines:
    s = l.strip().rstrip('"').strip(',').strip()
    s = s.replace('"', '')
    # Handle extras like httpx[socks]==0.28.1
    s = re.sub(r',\s*#.*$', '', s).strip()
    if s and not s.startswith('#'):
        clean.append(s)

with open(r'C:\Users\24368\Desktop\MIX\claude最新修正版\build\hermes-core-deps-cleaned.txt', 'w') as f:
    f.write('\n'.join(clean))

print(f'{len(clean)} deps cleaned')
for d in clean:
    print(f'  {d}')
